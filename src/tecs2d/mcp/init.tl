--- tecs2d.mcp: MCP integration for tecs games.
--- Provides an HTTP server implementing the MCP Streamable HTTP transport.
---
--- Usage:
---   local mcp = require("tecs2d.mcp")
---   world:addPlugin(mcp.new())              -- default port 19999
---   world:addPlugin(mcp.new({port = 12345})) -- custom port
---
--- End users configure Claude Code with: {"type":"http","url":"http://localhost:19999/mcp"}

local tecs <const> = require("tecs")
local socket <const> = require("socket")
local json <const> = require("tecs.utils.json")
local mcpTools <const> = require("tecs2d.mcp.tools")
local IdAllocator <const> = require("tecs.internal.IdAllocator")
local pipeline_key <const> = require("tecs2d.gfx.internal.pipeline_key")
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

-- Pause/step state
local paused = false
local savedTimeScale: number = nil
local stepsRemaining = 0

-- Debug draw state
local enum DebugDrawType
    "rect"
    "circle"
    "text"
    "line"
end

local record DebugDrawCommand
    id: integer
    type: DebugDrawType
    x: number
    y: number
    w: number
    h: number
    radius: number
    text: string
    x2: number
    y2: number
    color: {number}
    tag: string
    expiresAt: number  -- wall-clock time, nil = persistent
    lineWidth: number
    fontSize: number
end

local debugDrawCommands: {DebugDrawCommand} = {}
local nextDebugDrawId = 1

-- Cache of fonts keyed by pixel size. Debug text commands persist across
-- frames, so without this cache the DebugDraw system would call
-- love.graphics.newFont(size) every frame per text draw and churn font
-- objects in a hot path.
local debugFontCache: {number: love.graphics.Font} = {}

local function getDebugFont(size: number): love.graphics.Font
    local f = debugFontCache[size]
    if not f then
        f = lg.newFont(size)
        debugFontCache[size] = f
    end
    return f
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
    sendResponse(id, {content = {{type = "text", text = json.serialize(payload)}}, isError = isError})
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
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end
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

toolHandlers["get_components"] = function(_: {string:any}, id: number)
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end
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
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end
    local pipeline = (world as {string:any}).pipeline as {string:any}
    local pipelineSystems = pipeline.systems as {{tecs.SystemConfig}}

    -- Systems are already organized by phase position in pipelineSystems array
    local systems: {{string: any}} = {}
    for i = 1, #pipelineSystems do
        local phaseSystems = pipelineSystems[i]
        for j = 1, #phaseSystems do
            local config = phaseSystems[j]
            local name = config.name or "(anonymous)"
            local phaseName = config.phase and config.phase.name or "(unknown)"
            table.insert(systems, {name = name, phase = phaseName})
        end
    end

    sendToolOK(id, {count = #systems, systems = systems}, nil)
end

toolHandlers["get_resources"] = function(_: {string:any}, id: number)
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end

    local resources = world.resources as {any: any}
    local result: {{string: any}} = {}

    for key, value in pairs(resources) do
        local keyStr: string
        local valueType: string

        -- Try to get a meaningful name for the key
        if type(key) == "table" and (key as {string:any}).name then
            keyStr = (key as {string:any}).name as string
        elseif type(key) == "table" then
            keyStr = tostring(key)
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
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end

    -- Build list of entity IDs to despawn
    local entityIds: {integer} = {}
    if args.ids then
        local ids = args.ids as {integer}
        for i = 1, #ids do
            table.insert(entityIds, ids[i])
        end
    elseif args.id then
        table.insert(entityIds, args.id as integer)
    else
        sendToolError(id, "missing_parameter", "Missing entity ID(s) - provide 'id' or 'ids'", nil)
        return
    end

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

toolHandlers["get_entity"] = function(args: {string:any}, id: number)
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end

    local entityId = args.id as integer
    if not entityId then
        sendToolError(id, "missing_parameter", "Missing 'id' parameter", nil)
        return
    end

    if not world:isAlive(entityId) then
        sendToolError(id, "entity_not_found", "Entity not found", {id = entityId})
        return
    end

    -- Look up entity location via the allocator. Decode the packed id
    -- to a slot (allocator.slots is indexed by slot, not packed id).
    local worldAny = world as {string:any}
    local allocator = worldAny.allocator as {string: any}
    local archetypeIndex = worldAny.archetypeIndex as {tecs.Archetype}
    local slot = IdAllocator.slotOf(entityId)
    local s = (allocator.slots as {integer: {string: integer}})[slot]
    local archetype = archetypeIndex[s.archetypeId]
    if archetype == nil then
        sendToolError(id, "entity_not_committed", "Entity not committed yet", {id = entityId})
        return
    end
    local row = s.row
    local components: {string: any} = {}

    local compList = archetype.componentList
    for i = 1, #compList do
        local comp = compList[i]
        if comp.componentName and comp.serialize then
            local column = archetype:get(comp) as {any}
            local instance = column and column[row + 1]
            if instance ~= nil then
                local serialize = comp.serialize as function(any): {string: any}
                local ok, serialized = pcall(serialize, instance)
                if ok and serialized then
                    components[comp.componentName] = serialized
                end
            end
        end
    end

    local result = {
        id = entityId,
        archetypeId = s.archetypeId,
        archetypeComponents = getArchetypeSignature(archetype),
        components = components
    }
    sendToolOK(id, result, nil)
end

toolHandlers["query"] = function(args: {string:any}, id: number)
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end

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
                    components = {}
                }
                local components: {string: any} = {}

                for ci = 1, #includeComponents do
                    local comp = includeComponents[ci]
                    local column = archetype:get(comp)
                    -- Skip non-serializable components (tag components, or
                    -- components without a serialize callback). Without this guard
                    -- any non-serializable entry in `include` crashes the tool
                    -- instead of returning the serializable fields.
                    if column and comp.componentName and comp.serialize then
                        local instance = column[row]
                        local serialize = comp.serialize as function(any): {string: any}
                        local ok, serialized = pcall(serialize, instance)
                        if ok and serialized then
                            components[comp.componentName] = serialized
                        end
                    end
                end

                entityData.components = components
                table.insert(results, entityData)
                count = count + 1
            end
        end
    end

    local response = {count = count, entities = results}
    sendToolOK(id, response, {limit = limit, truncated = count >= limit})
end

toolHandlers["get_archetypes"] = function(_: {string:any}, id: number)
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end

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
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end

    local componentsData = args.components as {string: {string: any}}
    if not componentsData then
        sendToolError(id, "missing_parameter", "Missing 'components' parameter", nil)
        return
    end

    local componentMap = getComponentMap()
    local instances: {tecs.Component} = {}

    for compName, compData in pairs(componentsData) do
        local comp = componentMap[compName]
        if not comp then
            sendToolError(id, "unknown_component", "Unknown component", {component = compName})
            return
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
            return
        end
        table.insert(instances, instance)
    end

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
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end

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
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end

    local bundleName = args.bundle as string
    if not bundleName then
        sendToolError(id, "missing_parameter", "Missing 'bundle' parameter", nil)
        return
    end

    local componentsData = (args.components as {string: {string: any}}) or {}
    local componentMap = getComponentMap()
    local instances: {tecs.Component} = {}

    for compName, compData in pairs(componentsData) do
        local comp = componentMap[compName]
        if not comp then
            sendToolError(id, "unknown_component", "Unknown component", {component = compName})
            return
        end

        local ok, instance = pcall(function(): tecs.Component
            return comp.deserialize(world, compData)
        end)
        if not ok then
            sendToolError(id, "component_deserialize_failed", "Failed to create component", {
                component = compName,
                error = tostring(instance)
            })
            return
        end
        table.insert(instances, instance)
    end

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
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end

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
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end

    -- Build list of entity IDs. Validate types here: the queued op runs
    -- in the drain outside any pcall, one frame after this tool already
    -- replied, so a bad id there would crash the frame.
    local entityIds: {integer} = {}
    if args.ids then
        if type(args.ids) ~= "table" then
            sendToolError(id, "invalid_parameter", "'ids' must be an array of numbers", nil)
            return
        end
        local ids = args.ids as {any}
        for i = 1, #ids do
            if type(ids[i]) ~= "number" then
                sendToolError(id, "invalid_parameter", "Entity ids must be numbers",
                    {index = i, value = tostring(ids[i])})
                return
            end
            table.insert(entityIds, ids[i] as integer)
        end
    elseif args.id then
        if type(args.id) ~= "number" then
            sendToolError(id, "invalid_parameter", "'id' must be a number",
                {value = tostring(args.id)})
            return
        end
        table.insert(entityIds, args.id as integer)
    else
        sendToolError(id, "missing_parameter", "Missing entity ID(s) - provide 'id' or 'ids'", nil)
        return
    end

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
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end

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
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end

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
                        components = {}
                    }
                    local components: {string: any} = {}

                    for ci = 1, #includeComponents do
                        local comp = includeComponents[ci]
                        local column = archetype:get(comp)
                        -- Skip non-serializable components so tag components
                        -- in the include list don't crash the tool.
                        if column and comp.componentName and comp.serialize then
                            local instance = column[row]
                            local serialize = comp.serialize as function(any): {string: any}
                            local ok, serialized = pcall(serialize, instance)
                            if ok and serialized then
                                components[comp.componentName] = serialized
                            end
                        end
                    end

                    entityData.components = components
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

-- Track disabled systems for toggle_system
local disabledSystems: {string: boolean} = {}

toolHandlers["toggle_system"] = function(args: {string:any}, id: number)
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end

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

    -- Check if system exists in pipeline
    local pipeline = (world as {string:any}).pipeline as {string: any}
    local registry = pipeline.systemNameRegistry as {string: integer}
    if not registry[systemName] then
        sendToolError(id, "system_not_found", "System not found", {system = systemName})
        return
    end

    -- Find the system config and wrap its runIf
    local phasePosition = registry[systemName]
    local systems = pipeline.systems as {{tecs.SystemConfig}}
    local phaseSystems = systems[phasePosition]

    for i = 1, #phaseSystems do
        local config = phaseSystems[i]
        if config.name == systemName then
            if isEnabled then
                -- Restore the original runIf if we wrapped it. Always
                -- restore, even when the original was nil: leaving the
                -- wrapper installed makes the next disable capture the
                -- wrapper as the "original", nesting one closure per
                -- disable/enable cycle forever.
                if disabledSystems[systemName] then
                    disabledSystems[systemName] = nil
                    local configAny = config as {string:any}
                    config.runIf = configAny._originalRunIf as function(number, tecs.World, string): boolean
                    configAny._originalRunIf = nil
                end
                sendToolOK(id, {system = systemName, enabled = true}, nil)
            else
                -- Store original runIf and replace with disabled check
                if not disabledSystems[systemName] then
                    disabledSystems[systemName] = true
                    local originalRunIf = config.runIf;
                    (config as {string:any})._originalRunIf = originalRunIf
                    config.runIf = function(_dt: number, _world: tecs.World, name: string): boolean
                        if disabledSystems[name] then
                            return false
                        end
                        if not originalRunIf then
                            return true
                        end
                        return originalRunIf(_dt, _world, name)
                    end
                end
                sendToolOK(id, {system = systemName, enabled = false}, nil)
            end
            return
        end
    end

    sendToolError(id, "system_not_found", "System not found in phase", {system = systemName})
end

toolHandlers["set_time_scale"] = function(args: {string:any}, id: number)
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end

    local scale = args.scale as number
    if not scale then
        sendToolError(id, "missing_parameter", "Missing 'scale' parameter", nil)
        return
    end

    -- Clamp to reasonable range (0.0 = fully paused, 10.0 = 10x speed)
    scale = math.max(0.0, math.min(10.0, scale))

    -- Get the render pipeline from resources (not world.pipeline which is the system scheduler)
    local renderPipeline = world.resources[pipeline_key.PIPELINE] as {string: any}
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

-- Helpers to disable/enable gameplay phases for pause/step
local GAMEPLAY_PHASES <const> = {
    tecs.phases.First,
    tecs.phases.PreUpdate,
    tecs.phases.FixedUpdateGroup,
    tecs.phases.Update,
    tecs.phases.PostUpdate,
    tecs.phases.Last
}

local function disableGameplayPhases()
    for i = 1, #GAMEPLAY_PHASES do
        world:disablePhase(GAMEPLAY_PHASES[i])
    end
end

local function enableGameplayPhases()
    for i = 1, #GAMEPLAY_PHASES do
        world:enablePhase(GAMEPLAY_PHASES[i])
    end
end

local function setRenderTimeScale(scale: number)
    local renderPipeline = world.resources[pipeline_key.PIPELINE] as {string: any}
    if not renderPipeline then return end
    if renderPipeline.setTimeScale then
        (renderPipeline.setTimeScale as function(any, number))(renderPipeline, scale)
    else
        renderPipeline.timeScale = scale
    end
end

local function getRenderTimeScale(): number
    local renderPipeline = world.resources[pipeline_key.PIPELINE] as {string: any}
    if not renderPipeline then return 1.0 end
    return (renderPipeline.timeScale as number) or 1.0
end

toolHandlers["pause"] = function(_: {string:any}, id: number)
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end
    if paused then
        sendToolOK(id, {paused = true, alreadyPaused = true}, nil)
        return
    end

    savedTimeScale = getRenderTimeScale()
    setRenderTimeScale(0.0)
    disableGameplayPhases()
    paused = true
    stepsRemaining = 0

    sendToolOK(id, {paused = true, savedTimeScale = savedTimeScale}, nil)
end

toolHandlers["resume"] = function(_: {string:any}, id: number)
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end
    if not paused then
        sendToolOK(id, {paused = false, alreadyResumed = true}, nil)
        return
    end

    local restoredTimeScale = savedTimeScale
    if savedTimeScale then
        setRenderTimeScale(savedTimeScale)
    end
    savedTimeScale = nil
    enableGameplayPhases()
    paused = false
    stepsRemaining = 0

    sendToolOK(id, {paused = false, restoredTimeScale = restoredTimeScale}, nil)
end

toolHandlers["step"] = function(args: {string:any}, id: number)
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end
    if not paused then
        sendToolError(id, "not_paused", "Must be paused to step", nil)
        return
    end

    local frames = (args.frames as integer) or 1
    if frames < 1 then frames = 1 end

    -- Temporarily restore timeScale so stepped frames get real dt
    if savedTimeScale then
        setRenderTimeScale(savedTimeScale)
    end
    enableGameplayPhases()
    stepsRemaining = frames

    sendToolOK(id, {stepping = true, frames = frames}, nil)
end

local DEFAULT_COLOR <const>: {number} = {1, 1, 0, 0.8}

toolHandlers["debug_draw"] = function(args: {string:any}, id: number)
    -- Validate everything at the boundary: commands persist and are
    -- consumed by the render system outside any pcall, where a bad value
    -- would crash the frame every frame until cleared.
    local drawType = args.type as DebugDrawType
    if not drawType then
        sendToolError(id, "missing_parameter", "Missing 'type' (rect, circle, text, line)", nil)
        return
    end
    if drawType ~= "rect" and drawType ~= "circle" and drawType ~= "text" and drawType ~= "line" then
        sendToolError(id, "invalid_parameter",
            "Unknown draw type (expected rect, circle, text, or line)",
            {type = tostring(drawType)})
        return
    end

    local numericArgs <const> = {"x", "y", "w", "h", "radius", "x2", "y2", "duration", "lineWidth", "fontSize"}
    for i = 1, #numericArgs do
        local name = numericArgs[i]
        local value = args[name]
        if value ~= nil and type(value) ~= "number" then
            sendToolError(id, "invalid_parameter",
                "'" .. name .. "' must be a number", {value = tostring(value)})
            return
        end
    end

    local color = DEFAULT_COLOR
    if args.color ~= nil then
        if type(args.color) ~= "table" then
            sendToolError(id, "invalid_parameter", "'color' must be an array of numbers", nil)
            return
        end
        local colorArr = args.color as {any}
        for i = 1, math.max(#colorArr, 3) do
            local channel = colorArr[i]
            if i <= 3 and type(channel) ~= "number" then
                sendToolError(id, "invalid_parameter",
                    "'color' must have at least numeric r, g, b entries", nil)
                return
            end
            if channel ~= nil and type(channel) ~= "number" then
                sendToolError(id, "invalid_parameter",
                    "'color' entries must be numbers", nil)
                return
            end
        end
        color = colorArr as {number}
    end
    if args.text ~= nil and type(args.text) ~= "string" then
        sendToolError(id, "invalid_parameter", "'text' must be a string", nil)
        return
    end
    if args.tag ~= nil and type(args.tag) ~= "string" then
        sendToolError(id, "invalid_parameter", "'tag' must be a string", nil)
        return
    end
    local duration = args.duration as number
    local expiresAt: number = nil
    if duration and duration > 0 then
        expiresAt = lt.getTime() + duration
    elseif duration and duration == 0 then
        -- Single frame: expire almost immediately, but render once
        expiresAt = lt.getTime() + 0.001
    end

    local cmd: DebugDrawCommand = {
        id = nextDebugDrawId,
        type = drawType,
        x = (args.x as number) or 0,
        y = (args.y as number) or 0,
        w = (args.w as number) or 0,
        h = (args.h as number) or 0,
        radius = (args.radius as number) or 0,
        text = (args.text as string) or "",
        x2 = (args.x2 as number) or 0,
        y2 = (args.y2 as number) or 0,
        color = color,
        tag = args.tag as string,
        expiresAt = expiresAt,
        lineWidth = (args.lineWidth as number) or 4,
        fontSize = (args.fontSize as number) or 14
    }
    nextDebugDrawId = nextDebugDrawId + 1

    table.insert(debugDrawCommands, cmd)
    sendToolOK(id, {id = cmd.id, type = cmd.type, tag = cmd.tag}, nil)
end

toolHandlers["clear_debug_draw"] = function(args: {string:any}, id: number)
    local tag = args.tag as string
    local clearId = args.id as integer

    if not tag and not clearId then
        local count = #debugDrawCommands
        debugDrawCommands = {}
        sendToolOK(id, {cleared = count}, nil)
        return
    end

    local removed = 0
    for i = #debugDrawCommands, 1, -1 do
        local cmd = debugDrawCommands[i]
        if (tag and cmd.tag == tag) or (clearId and cmd.id == clearId) then
            table.remove(debugDrawCommands, i)
            removed = removed + 1
        end
    end
    sendToolOK(id, {cleared = removed, id = clearId, tag = tag}, nil)
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
    if not world then
        sendToolError(id, "world_unavailable", "World not initialized", nil)
        return
    end
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
    if not world then
        sendToolError(id, "world_unavailable", "No world available", nil)
        return
    end

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
    if not world then
        sendToolError(id, "world_unavailable", "No world available", nil)
        return
    end

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
    -- Use mcpTools.toJSON() to avoid empty-table-as-array serialization issue
    -- (Lua's json.serialize turns {} into [] which is invalid for JSON Schema "properties")
    local body = '{"jsonrpc":"2.0","id":' .. tostring(id) .. ',"result":{"tools":' .. mcpTools.toJSON() .. '}}'
    sendHttpResponse(200, "OK", body)
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
    local handler = toolHandlers[toolName as string]
    if not handler then
        sendError(id, ERR_INVALID_PARAMS, "Unknown tool: " .. tostring(toolName))
        return
    end
    local args = (params.arguments as {string:any}) or {}
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

    local requestLine, err = sock:receive("*l")
    if not requestLine then
        if err ~= "timeout" then
            return nil, nil, nil, nil
        end
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
        pcall(function() client:close() end)
        client = nil
    end
end

-- Process pending HTTP requests from socket
local function processCommands()
    if not server then return end

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
    local RETRIES <const> = 3
    local RETRY_DELAY <const> = 0.1

    for attempt = 1, RETRIES do
        server = socket.tcp()
        server:setoption("reuseaddr", true)
        pcall(function() server:setoption("reuseport", true) end)
        local ok, _ = server:bind("127.0.0.1", port)
        if ok then
            server:listen(5)
            server:settimeout(0)
            boundPort = port
            log:info("MCP HTTP server listening on port %d", port as integer)

            -- Update window title to show MCP port
            local currentTitle = love.window.getTitle()
            currentTitle = currentTitle:gsub("%s*%(MCP:.-%)%s*$", "")
            love.window.setTitle(currentTitle .. " (MCP:" .. port .. ")")
            return
        end

        server:close()
        server = nil

        if attempt < RETRIES then
            lt.sleep(RETRY_DELAY)
        end
    end

    log:error("Failed to start MCP HTTP server on port %d", port as integer)
end

local function cleanup()
    queuedWorldOps = {}
    if client then
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
    startServer(port)

    return function(w: tecs.World)
    world = w

    -- The MCP frame systems run in RenderFirst, not a gameplay phase:
    -- pause disables the gameplay phases (First..Last), and the server must
    -- keep answering resume/step/run_lua while paused. RenderFirst also runs
    -- before the render pipeline's PreRender sync, so world ops drained this
    -- frame render this frame; the component-dirty bits they set would
    -- otherwise be cleared at the end of world:update before the next sync
    -- could see them.
    --
    -- Order within RenderFirst: StepCounter -> ProcessCommands ->
    -- DrainQueuedOps. StepCounter runs first so a step command processed
    -- this frame is not decremented until the next frame's gameplay phases
    -- actually ran, keeping `step N` at exactly N gameplay frames.
    w:addSystem({
        name = "mcp.StepCounter",
        phase = tecs.phases.RenderFirst,
        before = {"mcp.ProcessCommands"},
        run = function()
            if stepsRemaining > 0 then
                stepsRemaining = stepsRemaining - 1
                if stepsRemaining == 0 then
                    setRenderTimeScale(0.0)
                    disableGameplayPhases()
                end
            end
        end
    })

    w:addSystem({
        name = "mcp.DebugDraw",
        phase = tecs.phases.PostRender,
        run = function()
            if #debugDrawCommands == 0 then return end

            -- Find the active camera for world-to-screen conversion.
            -- Cameras aren't stored directly in resources; instead the
            -- render pipeline is, and it exposes getCamera(). A
            -- toScreen-duck-type fallback covers non-gfx setups.
            local resources = w.resources as {any: any}
            local camera: any = nil
            for _, value in pairs(resources) do
                if type(value) == "table" then
                    local tbl = value as {string: any}
                    if type(tbl.getCamera) == "function" then
                        local getCam = tbl.getCamera as function(any): any
                        local cam = getCam(value)
                        if cam and type((cam as {string: any}).toScreen) == "function" then
                            camera = cam
                            break
                        end
                    end
                    if type(tbl.toScreen) == "function" then
                        camera = value
                        break
                    end
                end
            end

            local toScreen: function(any, number, number): (number, number) = nil
            local worldScale = 1.0
            if camera then
                toScreen = (camera as {string: any}).toScreen as function(any, number, number): (number, number)
                -- Get effective zoom for scaling sizes
                local cam = camera as {string: any}
                local zoom = (cam.zoom as number) or 1.0
                local screenHeight = (cam.screenHeight as number) or lg.getHeight()
                local virtualHeight = (cam.virtualHeight as number) or screenHeight
                worldScale = zoom * (screenHeight / virtualHeight)
            end

            -- Save graphics state
            local prevR, prevG, prevB, prevA = lg.getColor()
            local prevLineWidth = lg.getLineWidth()
            local prevFont = lg.getFont()
            local prevBlendMode, prevAlphaMode = lg.getBlendMode()
            local prevShader = lg.getShader()
            local prevCanvas = lg.getCanvas()

            -- The render pipeline leaves the final screen canvas bound but
            -- may have a custom shader, blend mode, or even an offscreen
            -- canvas active depending on which pass ran last. Reset those to
            -- defaults so immediate-mode debug draws actually land on screen.
            lg.setCanvas()
            lg.setShader()
            lg.setBlendMode("alpha", "alphamultiply")

            local now <const> = lt.getTime()

            for i = #debugDrawCommands, 1, -1 do
                local cmd = debugDrawCommands[i]

                -- Prune expired commands
                if cmd.expiresAt and now >= cmd.expiresAt then
                    table.remove(debugDrawCommands, i)
                else
                    local c <const> = cmd.color
                    lg.setColor(c[1], c[2], c[3], c[4] or 0.8)
                    lg.setLineWidth(cmd.lineWidth)

                    if cmd.type == "rect" then
                        local sx, sy: number, number
                        local sw, sh: number, number
                        if toScreen then
                            sx, sy = toScreen(camera, cmd.x, cmd.y)
                            sw = cmd.w * worldScale
                            sh = cmd.h * worldScale
                        else
                            sx, sy = cmd.x, cmd.y
                            sw, sh = cmd.w, cmd.h
                        end
                        lg.rectangle("line", sx, sy, sw, sh)
                    elseif cmd.type == "circle" then
                        local sx, sy: number, number
                        if toScreen then
                            sx, sy = toScreen(camera, cmd.x, cmd.y)
                        else
                            sx, sy = cmd.x, cmd.y
                        end
                        lg.circle("line", sx, sy, cmd.radius * worldScale)
                    elseif cmd.type == "text" then
                        local sx, sy: number, number
                        if toScreen then
                            sx, sy = toScreen(camera, cmd.x, cmd.y)
                        else
                            sx, sy = cmd.x, cmd.y
                        end
                        lg.setFont(getDebugFont(cmd.fontSize))
                        lg.print(cmd.text, sx, sy)
                    elseif cmd.type == "line" then
                        local sx1, sy1, sx2, sy2: number, number, number, number
                        if toScreen then
                            sx1, sy1 = toScreen(camera, cmd.x, cmd.y)
                            sx2, sy2 = toScreen(camera, cmd.x2, cmd.y2)
                        else
                            sx1, sy1 = cmd.x, cmd.y
                            sx2, sy2 = cmd.x2, cmd.y2
                        end
                        lg.line(sx1, sy1, sx2, sy2)
                    end
                end
            end

            -- Restore graphics state
            lg.setColor(prevR, prevG, prevB, prevA)
            lg.setLineWidth(prevLineWidth)
            lg.setFont(prevFont)
            lg.setBlendMode(prevBlendMode, prevAlphaMode)
            lg.setShader(prevShader)
            lg.setCanvas(prevCanvas)
        end
    })

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
