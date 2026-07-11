--- tecs2d.mcp: MCP integration for tecs games.
--- Provides an HTTP server implementing the MCP Streamable HTTP transport.
---
--- Usage:
---   local mcp = require("tecs2d.mcp")
---   world:addPlugin(mcp.new())              -- default port 19999
---   world:addPlugin(mcp.new({port = 12345})) -- custom port
---
--- The in-game debugger overlay lives in the debug plugin
--- (require("tecs2d.debug").new()); the get_debug_context tool reads the
--- DebugContext resource that plugin publishes, and the debugger's command
--- registry is projected as debug_* tools (see tecs2d.debug.context).
---
--- End users configure Claude Code with: {"type":"http","url":"http://localhost:19999/mcp"}

local tecs <const> = require("tecs")
local socket <const> = require("socket")
local json <const> = require("tecs.utils.json")
local mcpTools <const> = require("tecs2d.mcp.tools")
local entityinfo <const> = require("tecs2d.internal.entityinfo")
local systemcontrol <const> = require("tecs2d.internal.systemcontrol")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")
local debugapi <const> = require("tecs2d.debug.context")
local mcpinfo <const> = require("tecs2d.internal.mcpinfo")
local logging <const> = require("tecs.utils.logging")
local StringBuffer <const> = require("string.buffer")

local lg <const> = love.graphics
local le <const> = love.event
local lt <const> = love.timer
local log <const> = logging.getLogger("tecs-mcp")

local record mcp
    record Config
        port: number
    end
    new: function(config?: Config): function(world: tecs.World)
    DEFAULT_PORT: integer
end

mcp.DEFAULT_PORT = 19999

-- JSON-RPC error codes
local ERR_PARSE <const> = -32700
local ERR_METHOD_NOT_FOUND <const> = -32601
local ERR_INVALID_PARAMS <const> = -32602
local ERR_INTERNAL <const> = -32603

local server: socket.tcp = nil
local client: socket.tcp = nil
-- When set, the next closeClient() aborts the connection with linger 0
-- (RST) instead of a FIN close. The restart handler sets this: a normal
-- close leaves the accepted socket in FIN_WAIT/TIME_WAIT, which can
-- block rebinding the same port for many seconds after the engine
-- restarts (SO_REUSEADDR does not bypass FIN_WAIT states).
local rstOnClose = false
-- Port the server still needs to bind (set when startServer exhausts
-- its retries after a restart); processCommands retries once per second.
local pendingBindPort: number = nil
local nextBindAttempt: number = 0
local world: tecs.World = nil
local boundPort: number = nil   -- The port we successfully bound to
local queuedWorldOps: {function(tecs.World)} = {}
local MAX_QUEUED_OP_PASSES <const> = 10

-- Pending screenshot info
local pendingScreenshotId: number = nil
-- Handlers that answer from a queued world op (run_lua) send their response a
-- step after the request handler returns. Keep the client socket open until that
-- deferred response is sent, mirroring the screenshot keep-alive above.
local pendingWorldOpResponse: boolean = false

-- Pause/step goes through the shared freeze controller (one owner of
-- "gameplay is stopped" for both MCP pause and the debugger's open panel).

-- Log capture for the get_logs tool: a tee sink forwards every line to the
-- original sink and keeps a bounded ring. Installed once per process at
-- mcp.new(); log writes are level-gated and not hot, so the extra table
-- insert per line is negligible.
local LOG_CAP <const> = 500
local capturedLogs: {{string: any}} = {}
local logsDropped = 0
local logSeq = 0
local logTapInstalled = false

local function installLogTap()
    if logTapInstalled then return end
    logTapInstalled = true
    local original = logging.sink
    local tee: {string: any} = {
        write = function(_self: any, ...: string): any
            original:write(...)
            -- Logger writes (dateStr, "name LEVEL: ", message, "\n").
            local dateStr, prefix, msg = ...
            local loggerName, level = (prefix or ""):match("^(.-) (%u+): $")
            logSeq = logSeq + 1
            capturedLogs[#capturedLogs + 1] = {
                seq = logSeq,
                time = (dateStr or ""):gsub("%s+$", ""),
                logger = loggerName or "",
                level = level or "",
                message = msg or "",
            }
            if #capturedLogs > LOG_CAP then
                table.remove(capturedLogs, 1)
                logsDropped = logsDropped + 1
            end
            return original
        end,
    }
    logging.setSink(tee as FILE)
end

-- HTTP response helpers
local function sendHttpResponse(statusCode: integer, statusText: string, body: string)
    if not client then return end
    local header = string.format(
        "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n",
        statusCode, statusText, #body
    )
    client:send(header .. body)
end

local function sendHttpAccepted()
    if not client then return end
    client:send("HTTP/1.1 202 Accepted\r\n\r\n")
end

-- MCP JSON-RPC response helpers
local function sendResponse(id: number, result: any)
    local body = json.serialize({jsonrpc = "2.0", id = id, result = result})
    sendHttpResponse(200, "OK", body)
end

local function sendError(id: number | nil, code: number, message: string)
    local body = json.serialize({
        jsonrpc = "2.0",
        id = id,
        error = {code = code, message = message}
    })
    sendHttpResponse(200, "OK", body)
end

local function sendToolJSON(id: number, payload: {string: any}, isError: boolean)
    -- The payload rides twice: serialized text for older clients, and the
    -- same object as structuredContent for clients that consume typed
    -- results directly.
    sendResponse(id, {
        content = {{type = "text", text = json.serialize(payload)}},
        structuredContent = payload,
        isError = isError,
    })
end

local function sendToolOK(id: number, result: any, meta?: {string: any})
    local payload: {string: any} = {ok = true, result = result}
    if meta then
        payload.meta = meta
    end
    sendToolJSON(id, payload, false)
end

local function sendToolError(id: number, code: string, message: string, details?: {string: any})
    local err: {string: any} = {code = code, message = message}
    if details then
        err.details = details
    end
    sendToolJSON(id, {ok = false, error = err}, true)
end

--- Returns the world when initialized, otherwise reports world_unavailable
--- to the client and returns nil so the handler can early-return.
local function requireWorld(id: number): tecs.World
    if world then
        return world
    end
    sendToolError(id, "world_unavailable", "World not initialized", nil)
    return nil
end

--- Collect entity IDs from the 'id' or 'ids' args, validating types at the
--- boundary. Reports a tool error and returns nil on invalid input.
local function collectEntityIds(args: {string:any}, id: number): {integer}
    local entityIds: {integer} = {}
    if args.ids then
        if type(args.ids) ~= "table" then
            sendToolError(id, "invalid_parameter", "'ids' must be an array of numbers", nil)
            return nil
        end
        local ids = args.ids as {any}
        for i = 1, #ids do
            if type(ids[i]) ~= "number" then
                sendToolError(id, "invalid_parameter", "Entity ids must be numbers",
                    {index = i, value = tostring(ids[i])})
                return nil
            end
            table.insert(entityIds, ids[i] as integer)
        end
    elseif args.id then
        if type(args.id) ~= "number" then
            sendToolError(id, "invalid_parameter", "'id' must be a number",
                {value = tostring(args.id)})
            return nil
        end
        table.insert(entityIds, args.id as integer)
    else
        sendToolError(id, "missing_parameter", "Missing entity ID(s) - provide 'id' or 'ids'", nil)
        return nil
    end
    return entityIds
end

local function enqueueWorldOp(op: function(tecs.World))
    queuedWorldOps[#queuedWorldOps + 1] = op
end

local function drainQueuedWorldOps(w: tecs.World)
    local pass = 0
    while #queuedWorldOps > 0 and pass < MAX_QUEUED_OP_PASSES do
        pass = pass + 1
        local ops = queuedWorldOps
        queuedWorldOps = {}
        for i = 1, #ops do
            ops[i](w)
        end
        w:commit()
    end
end

-- Tool handlers
local toolHandlers: {string: function(args: {string:any}, id: number)} = {}

toolHandlers["ping"] = function(_: {string:any}, id: number)
    sendToolOK(id, {
        running = true,
        port = (boundPort or 0) as integer,
        time = lt.getTime()
    }, nil)
end

toolHandlers["screenshot"] = function(args: {string:any}, id: number)
    -- Validate region params at the boundary: the capture callback runs
    -- during present, outside the tool-handler pcall, so bad values there
    -- crash the frame and wedge the connection.
    local regionX = args.x as number
    local regionY = args.y as number
    local regionW = args.width as number
    local regionH = args.height as number
    local hasRegion = regionX ~= nil or regionY ~= nil or regionW ~= nil or regionH ~= nil
    if hasRegion then
        if type(regionX) ~= "number" or type(regionY) ~= "number"
            or type(regionW) ~= "number" or type(regionH) ~= "number" then
            sendToolError(id, "invalid_parameter",
                "Region requires numeric x, y, width, and height", nil)
            return
        end
        if regionW < 1 or regionH < 1 then
            sendToolError(id, "invalid_parameter",
                "Region width and height must be at least 1",
                {width = regionW, height = regionH})
            return
        end
    end

    pendingScreenshotId = id
    love.graphics.captureScreenshot(function(imageData: love.image.ImageData)
        if pendingScreenshotId ~= id then return end
        -- Errors here would propagate into love.run; report them as a
        -- tool error and always release the pending slot.
        local captureErr: string = nil
        local ok = xpcall(function()
            local finalData = imageData
            if hasRegion then
                local maxW, maxH = imageData:getWidth(), imageData:getHeight()
                local cx = math.max(0, math.min(regionX, maxW - 1))
                local cy = math.max(0, math.min(regionY, maxH - 1))
                local cw = math.max(1, math.min(regionW, maxW - cx))
                local ch = math.max(1, math.min(regionH, maxH - cy))
                local cropped = love.image.newImageData(cw, ch)
                cropped:paste(imageData, 0, 0, cx, cy, cw, ch)
                finalData = cropped
            end
            local pngData = finalData:encode("png", "screenshot.png") as love.Data
            local base64 = love.data.encode("string", "base64", pngData:getString())
            sendResponse(id, {content = {{type = "image", data = base64, mimeType = "image/png"}}})
        end, function(e: any): string
            captureErr = tostring(e)
            return captureErr
        end)
        pendingScreenshotId = nil
        if not ok then
            sendToolError(id, "screenshot_failed", captureErr, nil)
        end
    end)
end

toolHandlers["sample_pixels"] = function(args: {string:any}, id: number)
    local points = args.points as {{string: any}}
    if type(points) ~= "table" or #points == 0 then
        sendToolError(id, "missing_parameter", "Missing or empty 'points' array", nil)
        return
    end
    if #points > 256 then
        sendToolError(id, "too_many_points", "At most 256 points per call", {count = #points})
        return
    end
    for i = 1, #points do
        local point = points[i]
        if type(point) ~= "table" or type(point.x) ~= "number" or type(point.y) ~= "number" then
            sendToolError(id, "invalid_point", "Each point must be an object with numeric x and y",
                {index = i})
            return
        end
    end
    local normalized = args.normalized as boolean

    -- Reuses the screenshot keep-alive: the response is sent from the capture
    -- callback one frame later, so the client socket stays open until then.
    pendingScreenshotId = id
    love.graphics.captureScreenshot(function(imageData: love.image.ImageData)
        if pendingScreenshotId ~= id then return end
        local w, h = imageData:getWidth(), imageData:getHeight()
        local samples: {{string: number}} = {}
        for i = 1, #points do
            local point = points[i]
            local x = point.x as number
            local y = point.y as number
            if normalized then
                x = x * (w - 1)
                y = y * (h - 1)
            end
            local px = math.floor(math.max(0, math.min(x, w - 1)) + 0.5)
            local py = math.floor(math.max(0, math.min(y, h - 1)) + 0.5)
            local r, g, b, a = imageData:getPixel(px, py)
            samples[i] = {x = px, y = py, r = r, g = g, b = b, a = a}
        end
        sendToolOK(id, {width = w, height = h, pixels = samples}, nil)
        pendingScreenshotId = nil
    end)
end

toolHandlers["send_love_event"] = function(args: {string:any}, id: number)
    local eventName = args.event as string
    if not eventName then
        sendToolError(id, "missing_parameter", "Missing 'event' parameter", nil)
        return
    end
    -- Accept mixed-type payloads (numbers, booleans, strings). LÖVE events
    -- like resize, mousepressed, wheelmoved, focus, and touch events expect
    -- non-string arguments.
    local eventArgs = args.args as {any}
    if eventArgs and #eventArgs > 0 then
        le.push(eventName, table.unpack(eventArgs))
    else
        le.push(eventName)
    end
    sendToolOK(id, {event = eventName, args = eventArgs or {}}, nil)
end

toolHandlers["get_window_size"] = function(_: {string:any}, id: number)
    local w, h = lg.getDimensions()
    sendToolOK(id, {width = w, height = h}, nil)
end

toolHandlers["get_fps"] = function(_: {string:any}, id: number)
    sendToolOK(id, {fps = lt.getFPS()}, nil)
end

toolHandlers["get_stats"] = function(_: {string:any}, id: number)
    if not requireWorld(id) then return end
    local stats = world:getStats()
    local memoryKB = collectgarbage("count")
    sendToolOK(id, {
        entities = stats.entities,
        archetypes = stats.archetypes,
        components = stats.components,
        systems = stats.systems,
        memoryKB = memoryKB,
        memoryMB = memoryKB / 1024
    }, nil)
end

-- Cap the artifact lists returned by get_debug_context so a long-running session
-- does not ship an unbounded history to the agent on every call.
local CONTEXT_LIST_LIMIT <const> = 5

local function lastN<T>(list: {T}, n: integer): {T}
    local total = #list
    if total <= n then return list end
    local out: {T} = {}
    for i = total - n + 1, total do
        out[#out + 1] = list[i]
    end
    return out
end

toolHandlers["get_debug_context"] = function(_: {string:any}, id: number)
    if not requireWorld(id) then return end
    local ctx = world.resources[debugapi.KEY]
    if not ctx then
        sendToolError(id, "debugger_disabled",
            "In-game debugger is not enabled; add the debug plugin " ..
            "(require(\"tecs2d.debug\").new()).", nil)
        return
    end
    -- Drop annotations on entities the game has since despawned.
    for eid in pairs(ctx.marks) do
        if not world:isAlive(eid) then ctx.marks[eid] = nil end
    end
    for eid in pairs(ctx.notes) do
        if not world:isAlive(eid) then ctx.notes[eid] = nil end
    end
    -- selection is an entity id; call get_entity with it for the components.
    -- marks/notes are keyed by name/message with compact id-range values.
    sendToolOK(id, {
        open = ctx.open,
        frozen = ctx.frozen,
        mode = ctx.mode,
        command = ctx.command,
        message = ctx.message,
        selected = ctx.selected,
        statsShown = ctx.statsShown,
        showIds = ctx.showIds,
        showBounds = ctx.showBounds,
        grid = ctx.gridEnabled and {w = ctx.gridW, h = ctx.gridH,
            offsetX = ctx.gridOX, offsetY = ctx.gridOY} or nil,
        rewind = {status = ctx.rewind.status, count = #ctx.rewind.entries,
            interval = ctx.rewind.interval, cap = ctx.rewind.cap, bytes = ctx.rewind.bytes},
        diffs = lastN(ctx.diffs as {any}, CONTEXT_LIST_LIMIT),
        menu = {open = ctx.menuOpen, target = ctx.menuTarget},
        marks = debugapi.encodeGroups(ctx.marks),
        notes = debugapi.encodeGroups(ctx.notes),
        snapshots = lastN(ctx.snapshots, CONTEXT_LIST_LIMIT),
        profiles = lastN(ctx.profiles, CONTEXT_LIST_LIMIT),
        screenshots = lastN(ctx.screenshots, CONTEXT_LIST_LIMIT),
        recording = ctx.recording,
        recordings = lastN(ctx.recordings, CONTEXT_LIST_LIMIT),
        profileTop = (#ctx.profileTop > 0) and ctx.profileTop or nil,
        entityCount = ctx.entityCount,
        area = ctx.hasArea and {
            x1 = ctx.areaX1, y1 = ctx.areaY1, x2 = ctx.areaX2, y2 = ctx.areaY2
        } or nil,
        mouse = {
            screenX = ctx.mouseScreenX, screenY = ctx.mouseScreenY,
            worldX = ctx.mouseWorldX, worldY = ctx.mouseWorldY
        },
        camera = {
            x = ctx.cameraX, y = ctx.cameraY, zoom = ctx.cameraZoom,
            rotation = ctx.cameraRotation, w = ctx.cameraW, h = ctx.cameraH
        }
    }, nil)
end

toolHandlers["get_components"] = function(_: {string:any}, id: number)
    if not requireWorld(id) then return end
    -- Access internal archetypeIndex (not on public interface)
    local archetypeIndex = (world as {string:any}).archetypeIndex as {tecs.Archetype}
    local componentIds: {string: integer} = {}
    local componentCounts: {string: integer} = {}
    for i = 1, #archetypeIndex do
        local archetype = archetypeIndex[i]
        local entityCount = archetype.entities[0] as integer
        local compList = archetype.componentList
        for j = 1, #compList do
            local comp = compList[j]
            local name = comp.componentName
            if name then
                if not componentIds[name] then
                    componentIds[name] = comp.componentId
                    componentCounts[name] = 0
                end
                componentCounts[name] = componentCounts[name] + entityCount
            end
        end
    end
    local names: {string} = {}
    for name in pairs(componentIds) do
        table.insert(names, name)
    end
    table.sort(names)
    local components: {{string: any}} = {}
    for i = 1, #names do
        local name = names[i]
        table.insert(components, {
            name = name,
            id = componentIds[name],
            entities = componentCounts[name]
        })
    end
    sendToolOK(id, {count = #components, components = components}, nil)
end

toolHandlers["get_systems"] = function(_: {string:any}, id: number)
    if not requireWorld(id) then return end
    local infos = systemcontrol.list(world)
    local systems: {{string: any}} = {}
    for i = 1, #infos do
        systems[i] = {name = infos[i].name, phase = infos[i].phase, enabled = infos[i].enabled}
    end
    sendToolOK(id, {count = #systems, systems = systems}, nil)
end

toolHandlers["get_resources"] = function(_: {string:any}, id: number)
    if not requireWorld(id) then return end

    local resources = world.resources as {any: any}
    local result: {{string: any}} = {}

    for key, value in pairs(resources) do
        local keyStr: string
        local valueType: string

        -- Try to get a meaningful name for the key
        if type(key) == "table" and (key as {string:any}).name then
            keyStr = (key as {string:any}).name as string
        else
            keyStr = tostring(key)
        end

        -- Get the type of the value
        if type(value) == "table" and getmetatable(value) then
            local mt = getmetatable(value)
            if mt.__name then
                valueType = mt.__name as string
            elseif mt.__index and type(mt.__index) == "table" and (mt.__index as {string:any}).__name then
                valueType = (mt.__index as {string:any}).__name as string
            else
                valueType = "table"
            end
        else
            valueType = type(value)
        end

        table.insert(result, {key = keyStr, type = valueType})
    end

    table.sort(result, function(a: {string: any}, b: {string: any}): boolean
        return (a.key as string) < (b.key as string)
    end)

    sendToolOK(id, {count = #result, resources = result}, nil)
end

toolHandlers["despawn"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    -- Build list of entity IDs to despawn
    local entityIds = collectEntityIds(args, id)
    if not entityIds then return end

    -- Despawn all entities
    local succeeded: {integer} = {}
    local failed: {{string: any}} = {}
    for i = 1, #entityIds do
        local entityId = entityIds[i]
        local results = {pcall(world.despawn, world, entityId)}
        if results[1] then
            table.insert(succeeded, entityId)
        else
            table.insert(failed, {id = entityId, error = tostring(results[2])})
        end
    end

    sendToolOK(id, {
        despawned = #succeeded,
        failed = #failed,
        ids = succeeded,
        errors = failed
    }, nil)
end

toolHandlers["quit"] = function(_: {string:any}, id: number)
    sendToolOK(id, {quitting = true}, nil)
    le.push("quit")
end

toolHandlers["restart"] = function(_: {string:any}, id: number)
    sendToolOK(id, {restarting = true}, nil)
    -- Abort this connection with RST so the restarted instance can
    -- rebind the port immediately (see closeClient).
    rstOnClose = true
    love.event.quit("restart")
end

-- Helper: Build component name → object lookup from global registry
local function getComponentMap(): {string: tecs.Component}
    local map: {string: tecs.Component} = {}
    local id = 1
    while true do
        local comp = tecs.getComponentById(id)
        if not comp then
            break
        end
        if comp.componentName then
            map[comp.componentName] = comp
        end
        id = id + 1
    end
    return map
end


-- Helper: Get archetype signature (sorted component names)
local function getArchetypeSignature(archetype: tecs.Archetype): string
    local names: {string} = {}
    local compList = archetype.componentList
    for i = 1, #compList do
        local comp = compList[i]
        if comp.componentName then
            table.insert(names, comp.componentName)
        end
    end
    table.sort(names)
    return table.concat(names, ", ")
end

--- Deserialize a component-name to component-data map into instances.
--- Reports a tool error and returns nil when a component is unknown or
--- fails to deserialize.
local function deserializeComponents(
    id: number,
    componentsData: {string: {string: any}},
    componentMap: {string: tecs.Component}
): {tecs.Component}
    local instances: {tecs.Component} = {}
    for compName, compData in pairs(componentsData) do
        local comp = componentMap[compName]
        if not comp then
            sendToolError(id, "unknown_component", "Unknown component", {component = compName})
            return nil
        end

        -- Use component's deserialize method to create instance from data
        local ok, instance = pcall(function(): tecs.Component
            return comp.deserialize(world, compData)
        end)
        if not ok then
            sendToolError(id, "component_deserialize_failed", "Failed to create component", {
                component = compName,
                error = tostring(instance)
            })
            return nil
        end
        table.insert(instances, instance)
    end
    return instances
end

local serializeRow <const> = entityinfo.serializeRow

toolHandlers["get_entity"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    local entityId = args.id as integer
    if not entityId then
        sendToolError(id, "missing_parameter", "Missing 'id' parameter", nil)
        return
    end

    local archetype, row, why = entityinfo.locate(world, entityId)
    if not archetype then
        if why == "not_alive" then
            sendToolError(id, "entity_not_found", "Entity not found", {id = entityId})
        else
            sendToolError(id, "entity_not_committed", "Entity not committed yet", {id = entityId})
        end
        return
    end
    local components = serializeRow(archetype, archetype.componentList, row)

    local result = {
        id = entityId,
        archetypeId = archetype.id,
        archetypeComponents = getArchetypeSignature(archetype),
        components = components
    }
    sendToolOK(id, result, nil)
end

toolHandlers["query"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    local includeNames = args.include as {string}
    if not includeNames or #includeNames == 0 then
        sendToolError(id, "missing_parameter", "Missing 'include' parameter", nil)
        return
    end

    local excludeNames = (args.exclude as {string}) or {}
    local limit = (args.limit as integer) or 100

    -- Resolve component names to objects
    local componentMap = getComponentMap()
    local includeComponents: {tecs.Component} = {}
    local excludeComponents: {tecs.Component} = {}

    for i = 1, #includeNames do
        local name = includeNames[i]
        local comp = componentMap[name]
        if not comp then
            sendToolError(id, "unknown_component", "Unknown component", {component = name})
            return
        end
        table.insert(includeComponents, comp)
    end

    for i = 1, #excludeNames do
        local name = excludeNames[i]
        local comp = componentMap[name]
        if not comp then
            sendToolError(id, "unknown_component", "Unknown component", {component = name})
            return
        end
        table.insert(excludeComponents, comp)
    end

    -- Create and execute query. temp avoids registering a persistent query
    -- (and its archetype observers) for every MCP call.
    local query = world:query({
        temp = true,
        include = includeComponents,
        exclude = excludeComponents
    })

    -- Iterate and collect results. Iterate to exhaustion even after hitting
    -- the limit: breaking out of query:iter() leaks the query scope and
    -- leaves the world deferred for the rest of the frame.
    local results: {{string: any}} = {}
    local count = 0

    for archetype, len, entityList in query:iter() do
        if count < limit then
            local archetypeSig = getArchetypeSignature(archetype)
            local archetypeId = archetype.id
            for row = 1, len do
                if count >= limit then break end
                local entityId = entityList[row]
                local entityData: {string: any} = {
                    id = entityId,
                    archetypeId = archetypeId,
                    archetypeComponents = archetypeSig,
                    components = serializeRow(archetype, includeComponents, row)
                }
                table.insert(results, entityData)
                count = count + 1
            end
        end
    end

    local response = {count = count, entities = results}
    sendToolOK(id, response, {limit = limit, truncated = count >= limit})
end

toolHandlers["get_archetypes"] = function(_: {string:any}, id: number)
    if not requireWorld(id) then return end

    local archetypeIndex = (world as {string:any}).archetypeIndex as {tecs.Archetype}
    local archetypes: {{string: any}} = {}

    for i = 1, #archetypeIndex do
        local archetype = archetypeIndex[i]
        local entityCount = archetype.entities[0] as integer

        local componentNames: {string} = {}
        local compList = archetype.componentList
        for j = 1, #compList do
            local comp = compList[j]
            if comp.componentName then
                table.insert(componentNames, comp.componentName)
            end
        end
        table.sort(componentNames)

        table.insert(archetypes, {
            id = i,
            entities = entityCount,
            components = componentNames
        })
    end

    sendToolOK(id, {count = #archetypes, archetypes = archetypes}, nil)
end

toolHandlers["spawn"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    local componentsData = args.components as {string: {string: any}}
    if not componentsData then
        sendToolError(id, "missing_parameter", "Missing 'components' parameter", nil)
        return
    end

    local instances = deserializeComponents(id, componentsData, getComponentMap())
    if not instances then return end

    -- Spawn entity
    local ok, result = pcall(function(): integer
        return world:spawn(table.unpack(instances))
    end)
    if ok then
        sendToolOK(id, {id = result}, nil)
    else
        sendToolError(id, "spawn_failed", "Spawn failed", {error = tostring(result)})
    end
end

toolHandlers["get_bundles"] = function(_: {string:any}, id: number)
    if not requireWorld(id) then return end

    local bundles = world:getBundles()
    local result: {string: {string: any}} = {}

    for name, bundle in pairs(bundles) do
        local bndl = bundle as tecs.Bundle
        result[name] = {
            required = bndl.required,
            defaulted = bndl.defaulted
        }
    end

    sendToolOK(id, {bundles = result}, nil)
end

toolHandlers["spawn_bundle"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    local bundleName = args.bundle as string
    if not bundleName then
        sendToolError(id, "missing_parameter", "Missing 'bundle' parameter", nil)
        return
    end

    local componentsData = (args.components as {string: {string: any}}) or {}
    local instances = deserializeComponents(id, componentsData, getComponentMap())
    if not instances then return end

    local ok, result = pcall(function(): integer
        return world:spawnBundle(bundleName, table.unpack(instances))
    end)
    if ok then
        sendToolOK(id, {id = result}, nil)
    else
        sendToolError(id, "spawn_bundle_failed", "Spawn bundle failed", {error = tostring(result)})
    end
end

toolHandlers["run_lua"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    local code = args.code as string
    if not code then
        sendToolError(id, "missing_parameter", "Missing 'code' parameter", nil)
        return
    end

    -- Wrap user code in a function(world) body so they don't need boilerplate
    -- Newline before "end" so code ending in a line comment still parses.
    local wrapped <const> = "return function(world) " .. code .. "\nend"

    -- Load the code
    local loadOk, loadResult = pcall(function(): function(tecs.World)
        local chunk, loadErr = load(wrapped, "mcp_lua", "t")
        if not chunk then
            error("Failed to load code: " .. tostring(loadErr))
        end
        local fn = chunk()
        if type(fn) ~= "function" then
            error("Code must return a function, got " .. type(fn))
        end
        return fn as function(tecs.World)
    end)

    if not loadOk then
        local errMsg = tostring(loadResult)
        log:error("run_lua load failed: %s", errMsg)
        sendToolError(id, "lua_load_failed", "Lua load failed", {error = errMsg})
        return
    end

    local fn = loadResult as function(tecs.World)

    -- Run in the queued-op drain and return the chunk's results. Keep the client
    -- socket open until this deferred response is sent (the request handler returns
    -- before the queued op runs).
    pendingWorldOpResponse = true
    enqueueWorldOp(function(w: tecs.World)
        local pcallAny = pcall as function(any, ...: any): boolean, any
        local results = {pcallAny(fn, w)} as {any}
        if not results[1] then
            local errMsg = tostring(results[2])
            log:error("run_lua execution failed: %s", errMsg)
            sendToolError(id, "lua_execution_failed", "Lua execution failed", {error = errMsg})
            pendingWorldOpResponse = false
            return
        end
        local n = #results
        local values: {string} = {}
        for i = 2, n do values[i - 1] = tostring(results[i]) end
        sendToolOK(id, {
            returned = n - 1,
            values = values
        }, nil)
        pendingWorldOpResponse = false
    end)
end

toolHandlers["patch_entities"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    -- Build list of entity IDs. Validation matters here: the queued op runs
    -- in the drain outside any pcall, one frame after this tool already
    -- replied, so a bad id there would crash the frame.
    local entityIds = collectEntityIds(args, id)
    if not entityIds then return end

    local setData = (args.set as {string: {string: any}}) or {}
    local removeNames = (args.remove as {string}) or {}
    local componentMap = getComponentMap()

    -- Validate components exist before making changes
    for compName in pairs(setData) do
        if not componentMap[compName] then
            sendToolError(id, "unknown_component", "Unknown component", {component = compName})
            return
        end
    end
    for i = 1, #removeNames do
        if not componentMap[removeNames[i]] then
            sendToolError(id, "unknown_component", "Unknown component", {component = removeNames[i]})
            return
        end
    end

    -- Apply patches in the MCP queued-op drain (RenderFirst phase).
    enqueueWorldOp(function(w: tecs.World)
        local patched = 0
        local errors: {string} = {}

        for i = 1, #entityIds do
            local entityId = entityIds[i]
            -- The drain runs outside any pcall; nothing per-entity may
            -- raise or the whole frame dies after the client already got
            -- a queued=true reply.
            local aliveOk, alive = pcall(w.isAlive, w, entityId)
            if not aliveOk or not alive then
                table.insert(errors, "Entity " .. entityId .. " not found")
            else
                -- Set/update components
                for compName, compData in pairs(setData) do
                    local comp = componentMap[compName]
                    local setErr: string = nil
                    local ok = xpcall(function()
                        w:set(entityId, comp.deserialize(w, compData))
                    end, function(e: any): string
                        setErr = tostring(e)
                        return setErr
                    end)
                    if not ok then
                        local err = "Failed to set " .. compName .. " on " .. entityId ..
                            ": " .. setErr
                        table.insert(errors, err)
                    end
                end

                -- Remove components
                for j = 1, #removeNames do
                    local comp = componentMap[removeNames[j]]
                    local removeResult = {pcall(w.remove, w, entityId, comp)}
                    if not removeResult[1] then
                        local err = "Failed to remove " .. removeNames[j] .. " from " ..
                            entityId .. ": " .. tostring(removeResult[2])
                        table.insert(errors, err)
                    end
                end

                patched = patched + 1
            end
        end

        local msg = "Patched " .. patched .. " entities"
        if #errors > 0 then
            msg = msg .. " with " .. #errors .. " errors: " .. table.concat(errors, "; ")
        end
        log:info(msg)
    end)

    sendToolOK(id, {queued = true, entities = #entityIds, ids = entityIds}, nil)
end

toolHandlers["screen_to_world"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    local screenX = args.x as number
    local screenY = args.y as number
    if not screenX or not screenY then
        sendToolError(id, "missing_parameter", "Missing x or y coordinate", nil)
        return
    end

    -- Find pipeline in resources, then get camera
    local resources = world.resources as {any: any}
    local camera: any = nil

    for _, value in pairs(resources) do
        if type(value) == "table" then
            local tbl = value as {string: any}
            -- Look for pipeline with getCamera method
            if type(tbl.getCamera) == "function" then
                local getCamFn = tbl.getCamera as function(any): any
                camera = getCamFn(value)
                break
            -- Fallback: direct toWorld method (e.g., standalone Camera)
            elseif type(tbl.toWorld) == "function" then
                camera = value
                break
            end
        end
    end

    if not camera then
        sendToolError(id, "camera_not_found", "No camera found in resources", nil)
        return
    end

    local toWorldFn = (camera as {string: any}).toWorld as function(any, number, number): (number, number)
    local worldX, worldY = toWorldFn(camera, screenX, screenY)
    sendToolOK(id, {
        screen = {x = screenX, y = screenY},
        world = {x = worldX, y = worldY}
    }, nil)
end

toolHandlers["query_in_bounds"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    local boundsX = args.x as number
    local boundsY = args.y as number
    local boundsW = args.width as number
    local boundsH = args.height as number
    if not boundsX or not boundsY or not boundsW or not boundsH then
        sendToolError(id, "missing_parameter", "Missing bounds parameters (x, y, width, height)", nil)
        return
    end

    local limit = (args.limit as integer) or 100
    local includeNames = (args.include as {string}) or {}
    local componentMap = getComponentMap()

    -- Spatial component: accept either "Position" or the built-in Transform.
    -- Many tecs games don't define their own Position component; tecs's
    -- Transform is the ubiquitous one. Prefer Position for backwards
    -- compatibility with games that do register it.
    local positionComp = componentMap["Position"]
    local positionName = "Position"
    if not positionComp then
        positionComp = componentMap["Transform"]
        positionName = "Transform"
    end
    if not positionComp then
        sendToolError(id, "spatial_component_not_found",
            "Neither Position nor Transform component is registered; cannot run query_in_bounds.", nil)
        return
    end

    -- Build include list with the spatial component first
    local includeComponents: {tecs.Component} = {positionComp}
    for i = 1, #includeNames do
        local name = includeNames[i]
        if name ~= positionName then
            local comp = componentMap[name]
            if not comp then
                sendToolError(id, "unknown_component", "Unknown component", {component = name})
                return
            end
            table.insert(includeComponents, comp)
        end
    end

    -- Query and filter by bounds. temp avoids registering a persistent query,
    -- and the loop runs to exhaustion because breaking out of query:iter()
    -- leaks the query scope and leaves the world deferred.
    local query = world:query({temp = true, include = includeComponents})
    local results: {{string: any}} = {}
    local count = 0
    local boundsX2 = boundsX + boundsW
    local boundsY2 = boundsY + boundsH

    for archetype, len, entityList in query:iter() do
        local posColumn = count < limit and archetype:get(positionComp)
        if posColumn then
            for row = 1, len do
                if count >= limit then break end
                local pos = posColumn[row]
                local posAny = pos as {string: number}
                local px, py = posAny.x, posAny.y

                -- Check bounds
                if px >= boundsX and px <= boundsX2 and py >= boundsY and py <= boundsY2 then
                    local entityId = entityList[row]
                    local entityData: {string: any} = {
                        id = entityId,
                        components = serializeRow(archetype, includeComponents, row)
                    }
                    table.insert(results, entityData)
                    count = count + 1
                end
            end
        end
        if count >= limit then break end
    end

    local response = {
        count = count, entities = results,
        bounds = {x = boundsX, y = boundsY, width = boundsW, height = boundsH}
    }
    sendToolOK(id, response, {limit = limit, truncated = count >= limit})
end

toolHandlers["toggle_system"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    local systemName = args.name as string
    local isEnabled = args.enabled as boolean
    if not systemName then
        sendToolError(id, "missing_parameter", "Missing 'name' parameter", nil)
        return
    end
    if isEnabled == nil then
        sendToolError(id, "missing_parameter", "Missing 'enabled' parameter", nil)
        return
    end

    local ok, err = systemcontrol.setEnabled(world, systemName, isEnabled)
    if not ok then
        sendToolError(id, "system_not_found", err, {system = systemName})
        return
    end
    sendToolOK(id, {system = systemName, enabled = isEnabled}, nil)
end

toolHandlers["set_time_scale"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    local scale = args.scale as number
    if not scale then
        sendToolError(id, "missing_parameter", "Missing 'scale' parameter", nil)
        return
    end

    -- Clamp to reasonable range (0.0 = fully paused, 10.0 = 10x speed)
    scale = math.max(0.0, math.min(10.0, scale))

    -- Get the render pipeline from resources (not world.pipeline which is the system scheduler)
    local renderPipeline = world.resources[pipelinekey.PIPELINE] as {string: any}
    if not renderPipeline then
        sendToolError(id, "render_pipeline_not_found", "Render pipeline not found", nil)
        return
    end

    -- Set the pipeline's time scale (affects animation timing)
    if renderPipeline.setTimeScale then
        (renderPipeline.setTimeScale as function(any, number))(renderPipeline, scale)
    else
        -- Fallback: set directly
        renderPipeline.timeScale = scale
    end

    sendToolOK(id, {scale = scale, gameTime = renderPipeline.gameTime or 0}, nil)
end

toolHandlers["pause"] = function(_: {string:any}, id: number)
    if not requireWorld(id) then return end
    local fz = debugapi.ensureFreeze(world)
    if fz:heldBy("mcp") then
        sendToolOK(id, {paused = true, alreadyPaused = true}, nil)
        return
    end
    fz:acquire("mcp")
    sendToolOK(id, {paused = true, savedTimeScale = fz.savedTimeScale}, nil)
end

toolHandlers["resume"] = function(_: {string:any}, id: number)
    if not requireWorld(id) then return end
    local fz = debugapi.ensureFreeze(world)
    if not fz:heldBy("mcp") then
        sendToolOK(id, {paused = false, alreadyResumed = true}, nil)
        return
    end
    local restoredTimeScale = fz.savedTimeScale
    fz:release("mcp")
    -- Still frozen when another holder (the open debugger) remains.
    sendToolOK(id, {paused = false, restoredTimeScale = restoredTimeScale,
        stillFrozen = fz:isFrozen()}, nil)
end

toolHandlers["step"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end
    local fz = debugapi.ensureFreeze(world)
    if not fz:isFrozen() then
        sendToolError(id, "not_paused", "Must be paused to step", nil)
        return
    end

    local frames = (args.frames as integer) or 1
    if frames < 1 then frames = 1 end
    fz:step(frames)

    sendToolOK(id, {stepping = true, frames = frames}, nil)
end

toolHandlers["get_logs"] = function(args: {string:any}, id: number)
    if args.clear == true then
        local n = #capturedLogs
        capturedLogs = {}
        logsDropped = 0
        sendToolOK(id, {cleared = n}, nil)
        return
    end
    local rank <const>: {string: integer} = {DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4}
    local minRank = 1
    local level = args.level as string
    if level then
        minRank = rank[level:upper()]
        if not minRank then
            sendToolError(id, "invalid_parameter",
                "'level' must be DEBUG, INFO, WARN, or ERROR", {value = level})
            return
        end
    end
    local contains = args.contains as string
    local after = (args.after as integer) or 0
    local limit = (args.limit as integer) or 50
    if limit < 1 then limit = 1 elseif limit > LOG_CAP then limit = LOG_CAP end

    local matched: {{string: any}} = {}
    for i = 1, #capturedLogs do
        local e = capturedLogs[i]
        local r = rank[e.level as string] or 2
        if (e.seq as integer) > after and r >= minRank and (not contains
            or (e.message as string):find(contains, 1, true)
            or (e.logger as string):find(contains, 1, true)) then
            matched[#matched + 1] = e
        end
    end
    -- Newest last; return at most `limit` from the tail. `latest` is the
    -- newest captured seq: pass it back as `after` for incremental polling.
    local total = #matched
    local out = matched
    if total > limit then
        out = {}
        for i = total - limit + 1, total do out[#out + 1] = matched[i] end
    end
    sendToolOK(id, {logs = out, returned = #out, matched = total,
        captured = #capturedLogs, dropped = logsDropped, latest = logSeq}, nil)
end

toolHandlers["get_component_schema"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end
    local name = args.name as string
    if not name then
        sendToolError(id, "missing_parameter", "Missing 'name' parameter", nil)
        return
    end
    local comp = getComponentMap()[name]
    if not comp then
        sendToolError(id, "unknown_component", "Unknown component", {component = name})
        return
    end
    local schema = entityinfo.componentSchema(comp)
    sendToolOK(id, {
        name = schema.name,
        id = schema.id,
        kind = schema.kind,
        fields = schema.fields,
        defaults = schema.defaults,
        serializable = schema.serializable,
    }, nil)
end

-- Profiler: thin pass-through over tecs.utils.profile.sample.
local profile <const> = require("tecs.utils.profile")

local AUTOSTOP_SYSTEM_NAME <const> = "_profilerAutoStop"

local sampleSession: profile.SampleSession = nil
-- When auto-stop fires, the captured collapsed-stack text is stashed here so
-- a later profiler_stop call can still retrieve the recording.
local pendingSampleResult: string = nil

local function removeAutostopSystem()
    if world then
        pcall(function() world:removeSystem(AUTOSTOP_SYSTEM_NAME) end)
    end
end

local function emitResult(id: number, result: string, saveTo: string)
    if saveTo then
        sendToolOK(id, {path = result}, nil)
    else
        sendToolOK(id, {format = "collapsed-stack", payload = result, bytes = #result}, nil)
    end
end

toolHandlers["profiler_start"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end
    if sampleSession then
        sendToolError(id, "profiler_already_running", "Profiler is already running; call profiler_stop first", nil)
        return
    end

    local seconds = args.seconds as number
    if seconds and seconds < 0.1 then seconds = 0.1 end
    if seconds and seconds > 60 then seconds = 60 end

    removeAutostopSystem()
    pendingSampleResult = nil
    sampleSession = profile.sample({
        intervalMs = args.interval_ms as integer,
        zone = args.zone as string,
    })

    if seconds then
        local deadline = love.timer.getTime() + seconds
        world:addSystem({
            name = AUTOSTOP_SYSTEM_NAME,
            phase = tecs.phases.First,
            runIf = function(): boolean
                return love.timer.getTime() >= deadline
            end,
            run = function(_dt: number, w: tecs.World)
                if sampleSession then
                    pendingSampleResult = sampleSession:stop()
                    sampleSession = nil
                end
                w:removeSystem(AUTOSTOP_SYSTEM_NAME)
            end,
        })
    end

    sendToolOK(id, {
        running = true,
        seconds = seconds,
        intervalMs = args.interval_ms as integer,
        zone = args.zone as string
    }, nil)
end

toolHandlers["profiler_stop"] = function(args: {string:any}, id: number)
    local saveTo = args.save_to as string
    if pendingSampleResult then
        local text = pendingSampleResult
        pendingSampleResult = nil
        if saveTo then
            local f, openErr = io.open(saveTo, "w")
            if not f then
                sendToolError(id, "write_failed", "Failed to write profiler output", {
                    path = saveTo,
                    error = openErr or "unknown"
                })
                return
            end
            f:write(text)
            f:close()
            emitResult(id, saveTo, saveTo)
        else
            emitResult(id, text, nil)
        end
        return
    end
    if not sampleSession then
        sendToolError(id, "profiler_not_running", "Profiler is not running", nil)
        return
    end
    local result = sampleSession:stop(saveTo)
    sampleSession = nil
    removeAutostopSystem()
    emitResult(id, result, saveTo)
end

-------------------------------------------------------------------------------
-- Snapshot tools
-------------------------------------------------------------------------------

toolHandlers["snapshot_save"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    local format = (args.format as string) or "json"
    local saveTo = args.save_to as string
    local tStart = love.timer.getTime()

    -- Build the optional layer filter. When present we drive saveSnapshot
    -- through its options path (which bit-masks per entity); when absent we
    -- keep the fast unfiltered routes.
    local layers: {integer}
    if args.layers then
        layers = {}
        local rawLayers = args.layers as {number}
        for i = 1, #rawLayers do layers[i] = math.floor(rawLayers[i]) as integer end
    end

    if format == "json" then
        local snap: tecs.Snapshot
        if layers then
            snap = ((world:saveSnapshot({format = "table", layers = layers}) as {string: any}).snapshot) as tecs.Snapshot
        else
            snap = ((world:saveSnapshot({format = "table"}) as {string: any}).snapshot) as tecs.Snapshot
        end
        local archs = snap.archetypes as {{string: any}}
        local archCount = #archs
        local entityCount = 0
        for i = 1, archCount do
            entityCount = entityCount + #(archs[i].entities as {any})
        end
        local pretty = args.pretty == true
        local payload: string
        if pretty then
            payload = json.serializePretty(snap as {string:any}, true)
        else
            payload = json.serialize(snap as {string:any})
        end
        local elapsedMs = (love.timer.getTime() - tStart) * 1000
        if saveTo then
            local ok, err = love.filesystem.write(saveTo, payload)
            if not ok then
                sendToolError(id, "write_failed", "Failed to write snapshot", {
                    path = saveTo,
                    error = tostring(err)
                })
                return
            end
            local destPath = love.filesystem.getSaveDirectory() .. "/" .. saveTo
            log:info("snapshot_save: format=json entities=%d archetypes=%d bytes=%d dest=%s elapsed=%.2fms",
                entityCount, archCount, #payload, destPath, elapsedMs)
            sendToolOK(id, {
                format = "json",
                path = destPath,
                entities = entityCount,
                archetypes = archCount,
                bytes = #payload,
                elapsedMs = elapsedMs
            }, nil)
        else
            log:info("snapshot_save: format=json entities=%d archetypes=%d bytes=%d dest=inline elapsed=%.2fms",
                entityCount, archCount, #payload, elapsedMs)
            sendToolOK(id, {
                format = "json",
                snapshot = snap,
                entities = entityCount,
                archetypes = archCount,
                bytes = #payload,
                elapsedMs = elapsedMs
            }, nil)
        end
    elseif format == "luajit" then
        local buf = StringBuffer.new()
        -- The writer doesn't know the filter; count what saveSnapshot will
        -- actually emit so the log stays truthful.
        local entityCount = 0
        local archCount = 0
        if layers then
            local Transform = tecs.builtins.Transform as tecs.Component
            local mask: number = 0
            for i = 1, #layers do mask = mask + 2 ^ layers[i] end
            world:forEachArchetype(function(arch: tecs.Archetype)
                local c = arch.entities[0]
                local transforms = arch:get(Transform) as {{string: integer}}
                if c == 0 or not transforms then return end
                local matched = 0
                for row = 1, c do
                    local layer = transforms[row].layer
                    if math.floor(mask / 2 ^ layer) % 2 == 1 then
                        matched = matched + 1
                    end
                end
                if matched > 0 then
                    entityCount = entityCount + matched
                    archCount = archCount + 1
                end
            end)
        else
            world:forEachArchetype(function(arch: tecs.Archetype)
                local c = arch.entities[0]
                if c > 0 then
                    entityCount = entityCount + c
                    archCount = archCount + 1
                end
            end)
        end
        local out = world:saveSnapshot({buffer = buf, layers = layers})
        local binary = tostring(out.buffer)
        local elapsedMs = (love.timer.getTime() - tStart) * 1000
        if saveTo then
            local writeOk, writeErr = love.filesystem.write(saveTo, binary)
            if not writeOk then
                sendToolError(id, "write_failed", "Failed to write snapshot", {
                    path = saveTo,
                    error = tostring(writeErr)
                })
                return
            end
            local destPath = love.filesystem.getSaveDirectory() .. "/" .. saveTo
            log:info("snapshot_save: format=luajit entities=%d archetypes=%d bytes=%d dest=%s elapsed=%.2fms",
                entityCount, archCount, #binary, destPath, elapsedMs)
            sendToolOK(id, {
                format = "luajit",
                path = destPath,
                entities = entityCount,
                archetypes = archCount,
                bytes = #binary,
                elapsedMs = elapsedMs
            }, nil)
        else
            local encoded = love.data.encode("string", "base64", binary) as string
            log:info("snapshot_save: format=luajit entities=%d archetypes=%d bytes=%d dest=inline-base64 elapsed=%.2fms",
                entityCount, archCount, #binary, elapsedMs)
            sendToolOK(id, {
                format = "luajit",
                encoding = "base64",
                payload = encoded,
                entities = entityCount,
                archetypes = archCount,
                bytes = #binary,
                elapsedMs = elapsedMs
            }, nil)
        end
    else
        sendToolError(id, "unknown_format",
            "Unknown format: " .. tostring(format) .. " (expected 'json' or 'luajit')", nil)
    end
end

toolHandlers["snapshot_load"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    local format = (args.format as string) or "json"
    local payload = args.payload as string
    local loadFrom = args.load_from as string
    local source: string
    local payloadBytes = 0

    if not payload and loadFrom then
        if not love.filesystem.getInfo(loadFrom) then
            sendToolError(id, "file_not_found", "File not found", {path = loadFrom})
            return
        end
        payload = love.filesystem.read(loadFrom)
        if not payload then
            sendToolError(id, "read_failed", "Failed to read file", {path = loadFrom})
            return
        end
        source = love.filesystem.getSaveDirectory() .. "/" .. loadFrom
    elseif payload then
        source = "inline-payload"
    end

    if not payload then
        sendToolError(id, "missing_parameter", "Either 'payload' or 'load_from' is required", nil)
        return
    end
    payloadBytes = #payload

    local function countEntities(): integer, integer
        local ec, ac = 0, 0
        world:forEachArchetype(function(arch: tecs.Archetype)
            local c = arch.entities[0]
            if c > 0 then
                ec = ec + c
                ac = ac + 1
            end
        end)
        return ec, ac
    end

    local tStart = love.timer.getTime()

    if format == "json" then
        local okParse, parsed = pcall(json.parse, payload)
        if not okParse then
            sendToolError(id, "json_parse_failed", "JSON parse failed", {error = tostring(parsed)})
            return
        end
        local ok, err = pcall(function(): boolean
            world:loadSnapshot(parsed as tecs.Snapshot)
            return true
        end)
        if not ok then
            sendToolError(id, "load_failed", "Load failed", {error = tostring(err)})
            return
        end
        local elapsedMs = (love.timer.getTime() - tStart) * 1000
        local entityCount, archCount = countEntities()
        log:info("snapshot_load: format=json source=%s bytes=%d entities=%d archetypes=%d elapsed=%.2fms",
            source, payloadBytes, entityCount, archCount, elapsedMs)
        sendToolOK(id, {
            format = "json",
            source = source,
            bytes = payloadBytes,
            entities = entityCount,
            archetypes = archCount,
            elapsedMs = elapsedMs
        }, nil)
    elseif format == "luajit" then
        local binary = payload
        -- Inline luajit payloads arrive base64-encoded; file reads are raw bytes.
        if not loadFrom then
            local decodedOk, decoded = pcall(function(): string
                return love.data.decode("string", "base64", payload) as string
            end)
            if not decodedOk then
                sendToolError(id, "base64_decode_failed", "Base64 decode failed", {error = tostring(decoded)})
                return
            end
            binary = decoded as string
            payloadBytes = #binary
        end
        -- loadSnapshot accepts a Lua string directly; it handles the
        -- buffer creation + put internally.
        local ok, err = pcall(function(): boolean
            world:loadSnapshot(binary)
            return true
        end)
        if not ok then
            sendToolError(id, "load_failed", "Load failed", {error = tostring(err)})
            return
        end
        local elapsedMs = (love.timer.getTime() - tStart) * 1000
        local entityCount, archCount = countEntities()
        log:info("snapshot_load: format=luajit source=%s bytes=%d entities=%d archetypes=%d elapsed=%.2fms",
            source, payloadBytes, entityCount, archCount, elapsedMs)
        sendToolOK(id, {
            format = "luajit",
            source = source,
            bytes = payloadBytes,
            entities = entityCount,
            archetypes = archCount,
            elapsedMs = elapsedMs
        }, nil)
    else
        sendToolError(id, "unknown_format",
            "Unknown format: " .. tostring(format) .. " (expected 'json' or 'luajit')", nil)
    end
end

-- MCP method handlers
local function handleInitialize(id: number, params: {string:any})
    local clientVersion = type(params) == "table" and params.protocolVersion as string or "2024-11-05"
    sendResponse(id, {
        protocolVersion = clientVersion,
        capabilities = {tools = {listChanged = false}},
        serverInfo = {name = "tecs-mcp", version = "1.0.0"}
    })
end

local function handleToolsList(id: number)
    -- Compose lazily per request: the debug plugin may install (and register
    -- its commands) after the MCP server starts, in either plugin order, and
    -- games may register custom commands at any time.
    local derived = world and debugapi.commandTools(world)
    if not derived or #derived == 0 then
        local body = '{"jsonrpc":"2.0","id":' .. tostring(id) .. ',"result":{"tools":' .. mcpTools.toJSON() .. '}}'
        sendHttpResponse(200, "OK", body)
        return
    end
    local all: {any} = {}
    for i = 1, #mcpTools.list do all[#all + 1] = mcpTools.list[i] end
    for i = 1, #derived do all[#all + 1] = derived[i] end
    local body = '{"jsonrpc":"2.0","id":' .. tostring(id) .. ',"result":{"tools":' .. json.serialize(all) .. '}}'
    sendHttpResponse(200, "OK", body)
end

--- Dispatch a registry-derived debug_* tool call. Returns false when the name
--- is not a debugger tool (so the caller reports unknown-tool).
local function callDebugTool(toolName: string, args: {string:any}, id: number): boolean
    if toolName:sub(1, 6) ~= "debug_" then return false end
    if not requireWorld(id) then return true end
    local result, err = debugapi.invokeCommand(world, toolName, args)
    if not result then
        if err == "disabled" then
            sendToolError(id, "debugger_disabled",
                "Debugger tools require the debug plugin (require(\"tecs2d.debug\").new()).", nil)
        else
            sendError(id, ERR_INVALID_PARAMS, err)
        end
        return true
    end
    if result.ok == false then
        sendToolError(id, result.code or "command_failed", result.message or "command failed", nil)
        return true
    end
    local payload: {string: any} = {}
    if result.data then
        for k, v in pairs(result.data) do payload[k] = v end
    end
    payload.message = result.message
    sendToolOK(id, payload, nil)
    return true
end

local function handleToolsCall(id: number, params: {string:any})
    if type(params) ~= "table" then
        sendError(id, ERR_INVALID_PARAMS, "params must be an object")
        return
    end
    local toolName = params.name
    if type(toolName) ~= "string" then
        sendError(id, ERR_INVALID_PARAMS, "params.name must be a string")
        return
    end
    local args = (params.arguments as {string:any}) or {}
    local handler = toolHandlers[toolName as string]
    if not handler then
        local results = {pcall(callDebugTool, toolName as string, args, id)}
        if not results[1] then
            local errStr = tostring(results[2])
            log:error("Tool execution failed: %s", errStr)
            sendError(id, ERR_INTERNAL, "Tool execution failed: " .. errStr)
        elseif results[2] == false then
            sendError(id, ERR_INVALID_PARAMS, "Unknown tool: " .. tostring(toolName))
        end
        return
    end
    local results = {pcall(handler, args, id)}
    if not results[1] then
        local errStr = tostring(results[2])
        log:error("Tool execution failed: %s", errStr)
        sendError(id, ERR_INTERNAL, "Tool execution failed: " .. errStr)
    end
end

-- Process one MCP message
local function processMessage(line: string)
    local ok, msg = pcall(json.parse, line)
    if not ok then
        sendError(nil, ERR_PARSE, "Parse error")
        return
    end

    -- Valid JSON is not necessarily an object (e.g. a bare number or bool);
    -- guard before indexing so a malformed envelope can't crash the frame.
    if type(msg) ~= "table" then
        sendError(nil, ERR_PARSE, "Request must be a JSON object")
        return
    end
    local parsed = msg as {string:any}
    local method = parsed.method as string
    local id = parsed.id as number

    if method == "initialize" then
        handleInitialize(id, parsed.params as {string:any})
    elseif method == "notifications/initialized" then
        sendHttpAccepted()
        return
    elseif method == "tools/list" then
        handleToolsList(id)
    elseif method == "tools/call" then
        handleToolsCall(id, parsed.params as {string:any})
    else
        sendError(id, ERR_METHOD_NOT_FOUND, "Method not found: " .. tostring(method))
    end
end

-- Read a complete HTTP request from a socket.
-- Returns method, path, headers, body (or nil on error).
local function readHttpRequest(sock: socket.tcp): (string, string, {string:string}, string)
    -- Read request line with short blocking timeout (full request arrives as one packet)
    sock:settimeout(0.05)

    local requestLine = sock:receive("*l")
    if not requestLine then
        return nil, nil, nil, nil
    end

    local httpMethod, path = requestLine:match("^(%S+)%s+(%S+)")
    if not httpMethod then
        return nil, nil, nil, nil
    end

    -- Read headers
    local headers: {string:string} = {}
    while true do
        local headerLine = sock:receive("*l")
        if not headerLine or headerLine == "" or headerLine == "\r" then
            break
        end
        -- Strip trailing \r if present
        headerLine = headerLine:gsub("\r$", "")
        local key, value = headerLine:match("^([^:]+):%s*(.*)")
        if key then
            headers[key:lower()] = value
        end
    end

    -- Read body based on Content-Length
    local body = ""
    local contentLength = tonumber(headers["content-length"])
    if contentLength and contentLength > 0 then
        body = sock:receive(contentLength as string) or ""
    end

    return httpMethod, path, headers, body
end

-- Close the current client connection (unless a screenshot is pending)
local function closeClient()
    if pendingScreenshotId then return end  -- keep connection open for async screenshot
    if pendingWorldOpResponse then return end  -- keep open for deferred world-op response
    if client then
        if rstOnClose then
            rstOnClose = false
            pcall(function()
                client:setoption("linger", {on = true, timeout = 0})
            end)
        end
        pcall(function() client:close() end)
        client = nil
    end
end

--- One bind attempt. Returns true and installs `server` on success;
--- returns false and the bind error otherwise.
local function tryBind(port: number): boolean, string
    server = socket.tcp()
    server:setoption("reuseaddr", true)
    pcall(function() server:setoption("reuseport", true) end)
    local ok, bindErr = server:bind("127.0.0.1", port)
    if not ok then
        server:close()
        server = nil
        return false, tostring(bindErr)
    end

    server:listen(5)
    server:settimeout(0)
    boundPort = port
    pendingBindPort = nil
    log:info("MCP HTTP server listening on port %d", port as integer)

    -- Update window title to show MCP port
    local currentTitle = love.window.getTitle()
    currentTitle = currentTitle:gsub("%s*%(MCP:.-%)%s*$", "")
    love.window.setTitle(currentTitle .. " (MCP:" .. port .. ")")
    return true, nil
end

-- Process pending HTTP requests from socket
local function processCommands()
    -- Background rebinder: the previous instance's kernel connection
    -- state can hold the port for up to ~30 seconds after a restart.
    if not server then
        if pendingBindPort and lt.getTime() >= nextBindAttempt then
            nextBindAttempt = lt.getTime() + 1.0
            tryBind(pendingBindPort)
        end
        return
    end

    -- If a pending screenshot was completed, the callback already sent the response
    -- and cleared pendingScreenshotId. Close that connection now.
    if client and not pendingScreenshotId and not pendingWorldOpResponse then
        pcall(function() client:close() end)
        client = nil
    end

    -- Don't accept new connections while a screenshot is pending
    if client then return end

    -- Accept a new connection for this request
    local newClient = server:accept()
    if not newClient then return end

    client = newClient

    local httpMethod, path, _, body = readHttpRequest(newClient)
    if not httpMethod then
        pcall(function() newClient:close() end)
        client = nil
        return
    end

    -- Only accept requests to /mcp
    if path ~= "/mcp" then
        sendHttpResponse(404, "Not Found", '{"error":"Not found"}')
        pcall(function() newClient:close() end)
        client = nil
        return
    end

    if httpMethod == "GET" then
        -- SSE not supported; return method not allowed
        sendHttpResponse(405, "Method Not Allowed", '{"error":"GET not supported, use POST"}')
    elseif httpMethod == "POST" then
        if body and body ~= "" then
            processMessage(body)
        else
            sendHttpResponse(400, "Bad Request", '{"error":"Empty body"}')
        end
    else
        sendHttpResponse(405, "Method Not Allowed", '{"error":"Method not allowed"}')
    end

    closeClient()
end

local function startServer(port: number)
    -- Rebinding the same port right after an engine restart can race
    -- kernel connection state from the previous instance (TIME_WAIT
    -- entries live up to 30 seconds on macOS and SO_REUSEADDR does not
    -- always bypass them). Retry briefly here, then hand off to the
    -- per-frame rebinder in processCommands so MCP always comes back
    -- once the kernel releases the port.
    local RETRIES <const> = 20
    local RETRY_DELAY <const> = 0.1

    local lastErr: string = nil
    for attempt = 1, RETRIES do
        local ok, bindErr = tryBind(port)
        if ok then return end
        lastErr = bindErr

        if attempt < RETRIES then
            lt.sleep(RETRY_DELAY)
        end
    end

    pendingBindPort = port
    nextBindAttempt = lt.getTime() + 1.0
    log:warn("MCP HTTP server could not bind port %d yet (%s); retrying in the background",
        port as integer, tostring(lastErr))
end

local function cleanup()
    queuedWorldOps = {}
    if client then
        -- Linger 0 closes with RST instead of FIN, so the accepted
        -- socket leaves no FIN_WAIT/TIME_WAIT state behind. Without it,
        -- an engine restart can fail to rebind the port for seconds
        -- (SO_REUSEADDR does not bypass every lingering state on macOS)
        -- when the restart request's own connection is still draining.
        pcall(function()
            client:setoption("linger", {on = true, timeout = 0})
        end)
        pcall(function() client:close() end)
        client = nil
    end
    if server then
        pcall(function() server:close() end)
        server = nil
    end
    log:info("MCP server stopped")
end

function mcp.new(config?: mcp.Config): function(world: tecs.World)
    -- The MCP server is a process-global singleton: server socket, world
    -- pointer, pause state, debug draw commands, and screenshot state all
    -- live in module-level state. A second mcp.new() would silently stomp
    -- the first (second server, shared state races between the two worlds).
    -- Detect and reject duplicate initialization with a clear error.
    if server then
        error("tecs2d.mcp.new() already called; only one MCP server can be active per process. " ..
              "The previous server is still bound to port " .. tostring(boundPort) .. ".")
    end

    local port = (config and config.port) or mcp.DEFAULT_PORT
    installLogTap()
    startServer(port)

    return function(w: tecs.World)
    world = w

    -- Session info for the debugger's `agent` command.
    w.resources[mcpinfo.KEY] = {
        port = function(): integer
            return (boundPort or 0) as integer
        end,
        toolCount = function(): integer
            local n = #mcpTools.list
            local derived = debugapi.commandTools(w)
            if derived then n = n + #derived end
            return n
        end,
    }

    -- The MCP frame systems run in RenderFirst, not a gameplay phase:
    -- pause disables the gameplay phases (First..Last), and the server must
    -- keep answering resume/step/run_lua while paused. RenderFirst also runs
    -- before the render pipeline's PreRender sync, so world ops drained this
    -- frame render this frame; the component-dirty bits they set would
    -- otherwise be cleared at the end of world:update before the next sync
    -- could see them.
    --
    -- The freeze controller (shared with the debugger overlay) installs its
    -- own step-counting system; ensuring it here keeps pause/step working
    -- with or without the debug plugin.
    debugapi.ensureFreeze(w)

    w:addSystem({
        name = "mcp.ProcessCommands",
        -- Process MCP HTTP requests and enqueue world ops for same-frame
        -- execution by `mcp.DrainQueuedOps`. See the RenderFirst phase
        -- rationale on mcp.StepCounter above.
        phase = tecs.phases.RenderFirst,
        before = {"mcp.DrainQueuedOps"},
        run = function()
            processCommands()
        end
    })

    w:addSystem({
        name = "mcp.DrainQueuedOps",
        phase = tecs.phases.RenderFirst,
        run = function(_dt: number, ww: tecs.World)
            drainQueuedWorldOps(ww)
        end
    })

    w:addSystem({
        name = "mcp.Cleanup",
        phase = tecs.phases.Shutdown,
        run = cleanup
    })
    end
end

return mcp
