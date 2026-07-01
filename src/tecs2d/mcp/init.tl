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
    local text = string.format("Game is running (port: %d, time: %.1fs)",
        (boundPort or 0) as integer, lt.getTime())
    sendResponse(id, {content = {{type = "text", text = text}}})
end

toolHandlers["screenshot"] = function(args: {string:any}, id: number)
    pendingScreenshotId = id
    local regionX = args.x as number
    local regionY = args.y as number
    local regionW = args.width as number
    local regionH = args.height as number

    love.graphics.captureScreenshot(function(imageData: love.image.ImageData)
        if pendingScreenshotId == id then
            local finalData = imageData
            if regionX and regionY and regionW and regionH then
                local maxW, maxH = imageData:getWidth(), imageData:getHeight()
                regionX = math.max(0, math.min(regionX, maxW - 1))
                regionY = math.max(0, math.min(regionY, maxH - 1))
                regionW = math.min(regionW, maxW - regionX)
                regionH = math.min(regionH, maxH - regionY)
                local cropped = love.image.newImageData(regionW, regionH)
                cropped:paste(imageData, 0, 0, regionX, regionY, regionW, regionH)
                finalData = cropped
            end
            local pngData = finalData:encode("png", "screenshot.png") as love.Data
            local base64 = love.data.encode("string", "base64", pngData:getString())
            sendResponse(id, {content = {{type = "image", data = base64, mimeType = "image/png"}}})
            pendingScreenshotId = nil
        end
    end)
end

toolHandlers["send_love_event"] = function(args: {string:any}, id: number)
    local eventName = args.event as string
    if not eventName then
        sendResponse(id, {content = {{type = "text", text = "Error: missing event name"}}, isError = true})
        return
    end
    -- Accept mixed-type payloads (numbers, booleans, strings). LÖVE events
    -- like resize, mousepressed, wheelmoved, focus, and touch events expect
    -- non-string arguments, and restricting to strings here sent them with
    -- the wrong types.
    local eventArgs = args.args as {any}
    if eventArgs and #eventArgs > 0 then
        le.push(eventName, table.unpack(eventArgs))
    else
        le.push(eventName)
    end
    sendResponse(id, {content = {{type = "text", text = "OK"}}})
end

toolHandlers["get_window_size"] = function(_: {string:any}, id: number)
    local w, h = lg.getDimensions()
    sendResponse(id, {content = {{type = "text", text = w .. "x" .. h}}})
end

toolHandlers["get_fps"] = function(_: {string:any}, id: number)
    sendResponse(id, {content = {{type = "text", text = "FPS: " .. lt.getFPS()}}})
end

toolHandlers["get_stats"] = function(_: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end
    local stats = world:getStats()
    local memoryKB = collectgarbage("count")
    local memoryMB = memoryKB / 1024
    local text = string.format(
        "Entities: %d\nArchetypes: %d\nComponents: %d\nSystems: %d\nMemory: %.1f MB",
        stats.entities, stats.archetypes, stats.components, stats.systems, memoryMB
    )
    sendResponse(id, {content = {{type = "text", text = text}}})
end

toolHandlers["get_components"] = function(_: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
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
    local lines: {string} = {}
    for i = 1, #names do
        local name = names[i]
        table.insert(lines, string.format("%s (id=%d, entities=%d)", name, componentIds[name], componentCounts[name]))
    end
    sendResponse(id, {content = {{type = "text", text = table.concat(lines, "\n")}}})
end

toolHandlers["get_systems"] = function(_: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end
    local pipeline = (world as {string:any}).pipeline as {string:any}
    local pipelineSystems = pipeline.systems as {{tecs.SystemConfig}}

    -- Systems are already organized by phase position in pipelineSystems array
    local lines: {string} = {}
    for i = 1, #pipelineSystems do
        local phaseSystems = pipelineSystems[i]
        for j = 1, #phaseSystems do
            local config = phaseSystems[j]
            local name = config.name or "(anonymous)"
            local phaseName = config.phase and config.phase.name or "(unknown)"
            table.insert(lines, string.format("[%s] %s", phaseName, name))
        end
    end

    if #lines == 0 then
        sendResponse(id, {content = {{type = "text", text = "No systems registered"}}})
    else
        sendResponse(id, {content = {{type = "text", text = table.concat(lines, "\n")}}})
    end
end

toolHandlers["get_resources"] = function(_: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end

    local resources = world.resources as {any: any}
    local lines: {string} = {}

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

        table.insert(lines, string.format("%s: %s", keyStr, valueType))
    end

    table.sort(lines)

    if #lines == 0 then
        sendResponse(id, {content = {{type = "text", text = "No resources registered"}}})
    else
        sendResponse(id, {content = {{type = "text", text = table.concat(lines, "\n")}}})
    end
end

toolHandlers["despawn"] = function(args: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
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
        local err = "Missing entity ID(s) - provide 'id' or 'ids'"
        sendResponse(id, {content = {{type = "text", text = err}}, isError = true})
        return
    end

    -- Despawn all entities
    local succeeded: {integer} = {}
    local failed: {{integer, string}} = {}
    for i = 1, #entityIds do
        local entityId = entityIds[i]
        local results = {pcall(world.despawn, world, entityId)}
        if results[1] then
            table.insert(succeeded, entityId)
        else
            table.insert(failed, {entityId, tostring(results[2])})
        end
    end

    -- Build response
    local msg = "Despawned " .. #succeeded .. " entities"
    if #failed > 0 then
        msg = msg .. ", " .. #failed .. " failed"
    end
    sendResponse(id, {content = {{type = "text", text = msg}}})
end

toolHandlers["quit"] = function(_: {string:any}, id: number)
    sendResponse(id, {content = {{type = "text", text = "Quitting game"}}})
    le.push("quit")
end

toolHandlers["restart"] = function(_: {string:any}, id: number)
    sendResponse(id, {content = {{type = "text", text = "Restarting game"}}})
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
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end

    local entityId = args.id as integer
    if not entityId then
        sendResponse(id, {content = {{type = "text", text = "Missing 'id' parameter"}}, isError = true})
        return
    end

    if not world:isAlive(entityId) then
        sendResponse(id, {content = {{type = "text", text = "Entity " .. entityId .. " not found"}}, isError = true})
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
        sendResponse(id, {content = {{type = "text", text = "Entity " .. entityId .. " not committed yet"}}, isError = true})
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
    sendResponse(id, {content = {{type = "text", text = json.serialize(result)}}})
end

toolHandlers["query"] = function(args: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end

    local includeNames = args.include as {string}
    if not includeNames or #includeNames == 0 then
        sendResponse(id, {content = {{type = "text", text = "Missing 'include' parameter"}}, isError = true})
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
            sendResponse(id, {content = {{type = "text", text = "Unknown component: " .. name}}, isError = true})
            return
        end
        table.insert(includeComponents, comp)
    end

    for i = 1, #excludeNames do
        local name = excludeNames[i]
        local comp = componentMap[name]
        if not comp then
            sendResponse(id, {content = {{type = "text", text = "Unknown component: " .. name}}, isError = true})
            return
        end
        table.insert(excludeComponents, comp)
    end

    -- Create and execute query
    local query = world:query({
        include = includeComponents,
        exclude = excludeComponents
    })

    -- Iterate and collect results
    local results: {{string: any}} = {}
    local count = 0

    for archetype, len, entityList in query:iter() do
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
                -- components without a serialize hook). Without this guard
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
        if count >= limit then break end
    end

    local response = {count = count, entities = results}
    sendResponse(id, {content = {{type = "text", text = json.serialize(response)}}})
end

toolHandlers["get_archetypes"] = function(_: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
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

    local response = json.serialize({count = #archetypes, archetypes = archetypes})
    sendResponse(id, {content = {{type = "text", text = response}}})
end

toolHandlers["spawn"] = function(args: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end

    local componentsData = args.components as {string: {string: any}}
    if not componentsData then
        sendResponse(id, {content = {{type = "text", text = "Missing 'components' parameter"}}, isError = true})
        return
    end

    local componentMap = getComponentMap()
    local instances: {tecs.Component} = {}

    for compName, compData in pairs(componentsData) do
        local comp = componentMap[compName]
        if not comp then
            sendResponse(id, {content = {{type = "text", text = "Unknown component: " .. compName}}, isError = true})
            return
        end

        -- Use component's deserialize method to create instance from data
        local ok, instance = pcall(function(): tecs.Component
            return comp.deserialize(world, compData)
        end)
        if not ok then
            local err = "Failed to create " .. compName .. ": " .. tostring(instance)
            sendResponse(id, {content = {{type = "text", text = err}}, isError = true})
            return
        end
        table.insert(instances, instance)
    end

    -- Spawn entity
    local ok, result = pcall(function(): integer
        return world:spawn(table.unpack(instances))
    end)
    if ok then
        sendResponse(id, {content = {{type = "text", text = json.serialize({id = result})}}})
    else
        sendResponse(id, {content = {{type = "text", text = "Spawn failed: " .. tostring(result)}}, isError = true})
    end
end

toolHandlers["get_bundles"] = function(_: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
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

    sendResponse(id, {content = {{type = "text", text = json.serialize({bundles = result})}}})
end

toolHandlers["spawn_bundle"] = function(args: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end

    local bundleName = args.bundle as string
    if not bundleName then
        sendResponse(id, {content = {{type = "text", text = "Missing 'bundle' parameter"}}, isError = true})
        return
    end

    local componentsData = (args.components as {string: {string: any}}) or {}
    local componentMap = getComponentMap()
    local instances: {tecs.Component} = {}

    for compName, compData in pairs(componentsData) do
        local comp = componentMap[compName]
        if not comp then
            sendResponse(id, {content = {{type = "text", text = "Unknown component: " .. compName}}, isError = true})
            return
        end

        local ok, instance = pcall(function(): tecs.Component
            return comp.deserialize(world, compData)
        end)
        if not ok then
            local err = "Failed to create " .. compName .. ": " .. tostring(instance)
            sendResponse(id, {content = {{type = "text", text = err}}, isError = true})
            return
        end
        table.insert(instances, instance)
    end

    local ok, result = pcall(function(): integer
        return world:spawnBundle(bundleName, table.unpack(instances))
    end)
    if ok then
        sendResponse(id, {content = {{type = "text", text = json.serialize({id = result})}}})
    else
        local err = "Spawn bundle failed: " .. tostring(result)
        sendResponse(id, {content = {{type = "text", text = err}}, isError = true})
    end
end

toolHandlers["run_lua"] = function(args: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end

    local code = args.code as string
    if not code then
        sendResponse(id, {content = {{type = "text", text = "Missing 'code' parameter"}}, isError = true})
        return
    end

    -- Wrap user code in a function(world) body so they don't need boilerplate
    local wrapped <const> = "return function(world) " .. code .. " end"

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
        sendResponse(id, {content = {{type = "text", text = errMsg}}, isError = true})
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
            sendResponse(id, {content = {{type = "text", text = errMsg}}, isError = true})
            pendingWorldOpResponse = false
            return
        end
        local n = #results
        local parts: {string} = {}
        for i = 2, n do parts[i - 1] = tostring(results[i]) end
        local text = n > 1 and table.concat(parts, "\t") or "(no return value)"
        sendResponse(id, {content = {{type = "text", text = text}}})
        pendingWorldOpResponse = false
    end)
end

toolHandlers["patch_entities"] = function(args: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end

    -- Build list of entity IDs
    local entityIds: {integer} = {}
    if args.ids then
        local ids = args.ids as {integer}
        for i = 1, #ids do
            table.insert(entityIds, ids[i])
        end
    elseif args.id then
        table.insert(entityIds, args.id as integer)
    else
        local err = "Missing entity ID(s) - provide 'id' or 'ids'"
        sendResponse(id, {content = {{type = "text", text = err}}, isError = true})
        return
    end

    local setData = (args.set as {string: {string: any}}) or {}
    local removeNames = (args.remove as {string}) or {}
    local componentMap = getComponentMap()

    -- Validate components exist before making changes
    for compName in pairs(setData) do
        if not componentMap[compName] then
            sendResponse(id, {content = {{type = "text", text = "Unknown component: " .. compName}}, isError = true})
            return
        end
    end
    for i = 1, #removeNames do
        if not componentMap[removeNames[i]] then
            local err = "Unknown component: " .. removeNames[i]
            sendResponse(id, {content = {{type = "text", text = err}}, isError = true})
            return
        end
    end

    -- Apply patches in the MCP queued-op drain (Last phase).
    enqueueWorldOp(function(w: tecs.World)
        local patched = 0
        local errors: {string} = {}

        for i = 1, #entityIds do
            local entityId = entityIds[i]
            if not w:isAlive(entityId) then
                table.insert(errors, "Entity " .. entityId .. " not found")
            else
                -- Set/update components
                for compName, compData in pairs(setData) do
                    local comp = componentMap[compName]
                    local ok, instance = pcall(function(): tecs.Component
                        return comp.deserialize(w, compData)
                    end)
                    if ok then
                        w:set(entityId, instance)
                    else
                        local err = "Failed to set " .. compName .. " on " .. entityId ..
                            ": " .. tostring(instance)
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

    sendResponse(id, {content = {{type = "text", text = "Patch queued for " .. #entityIds .. " entities"}}})
end

toolHandlers["screen_to_world"] = function(args: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end

    local screenX = args.x as number
    local screenY = args.y as number
    if not screenX or not screenY then
        sendResponse(id, {content = {{type = "text", text = "Missing x or y coordinate"}}, isError = true})
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
        sendResponse(id, {content = {{type = "text", text = "No camera found in resources"}}, isError = true})
        return
    end

    local toWorldFn = (camera as {string: any}).toWorld as function(any, number, number): (number, number)
    local worldX, worldY = toWorldFn(camera, screenX, screenY)
    local result = json.serialize({
        screen = {x = screenX, y = screenY},
        world = {x = worldX, y = worldY}
    })
    sendResponse(id, {content = {{type = "text", text = result}}})
end

toolHandlers["query_in_bounds"] = function(args: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end

    local boundsX = args.x as number
    local boundsY = args.y as number
    local boundsW = args.width as number
    local boundsH = args.height as number
    if not boundsX or not boundsY or not boundsW or not boundsH then
        local err = "Missing bounds parameters (x, y, width, height)"
        sendResponse(id, {content = {{type = "text", text = err}}, isError = true})
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
        sendResponse(id, {content = {{type = "text",
            text = "Neither Position nor Transform component is registered; cannot run query_in_bounds."
        }}, isError = true})
        return
    end

    -- Build include list with the spatial component first
    local includeComponents: {tecs.Component} = {positionComp}
    for i = 1, #includeNames do
        local name = includeNames[i]
        if name ~= positionName then
            local comp = componentMap[name]
            if not comp then
                sendResponse(id, {content = {{type = "text", text = "Unknown component: " .. name}}, isError = true})
                return
            end
            table.insert(includeComponents, comp)
        end
    end

    -- Query and filter by bounds
    local query = world:query({include = includeComponents})
    local results: {{string: any}} = {}
    local count = 0
    local boundsX2 = boundsX + boundsW
    local boundsY2 = boundsY + boundsH

    for archetype, len, entityList in query:iter() do
        local posColumn = archetype:get(positionComp)
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
    sendResponse(id, {content = {{type = "text", text = json.serialize(response)}}})
end

-- Track disabled systems for toggle_system
local disabledSystems: {string: boolean} = {}

toolHandlers["toggle_system"] = function(args: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end

    local systemName = args.name as string
    local isEnabled = args.enabled as boolean
    if not systemName then
        sendResponse(id, {content = {{type = "text", text = "Missing 'name' parameter"}}, isError = true})
        return
    end
    if isEnabled == nil then
        sendResponse(id, {content = {{type = "text", text = "Missing 'enabled' parameter"}}, isError = true})
        return
    end

    -- Check if system exists in pipeline
    local pipeline = (world as {string:any}).pipeline as {string: any}
    local registry = pipeline.systemNameRegistry as {string: integer}
    if not registry[systemName] then
        local err = "System '" .. systemName .. "' not found"
        sendResponse(id, {content = {{type = "text", text = err}}, isError = true})
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
                -- Restore original runIf if we wrapped it
                if disabledSystems[systemName] then
                    disabledSystems[systemName] = nil
                    -- If we stored the original, restore it
                    local configAny = config as {string:any}
                    local originalRunIf = configAny._originalRunIf as function(number, tecs.World, string): boolean
                    if originalRunIf then
                        config.runIf = originalRunIf;
                        (config as {string:any})._originalRunIf = nil
                    end
                end
                sendResponse(id, {content = {{type = "text", text = "System '" .. systemName .. "' enabled"}}})
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
                sendResponse(id, {content = {{type = "text", text = "System '" .. systemName .. "' disabled"}}})
            end
            return
        end
    end

    local err = "System '" .. systemName .. "' not found in phase"
    sendResponse(id, {content = {{type = "text", text = err}}, isError = true})
end

toolHandlers["set_time_scale"] = function(args: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end

    local scale = args.scale as number
    if not scale then
        sendResponse(id, {content = {{type = "text", text = "Missing 'scale' parameter"}}, isError = true})
        return
    end

    -- Clamp to reasonable range (0.0 = fully paused, 10.0 = 10x speed)
    scale = math.max(0.0, math.min(10.0, scale))

    -- Get the render pipeline from resources (not world.pipeline which is the system scheduler)
    local renderPipeline = world.resources[pipeline_key.PIPELINE] as {string: any}
    if not renderPipeline then
        sendResponse(id, {content = {{type = "text", text = "Render pipeline not found"}}, isError = true})
        return
    end

    -- Set the pipeline's time scale (affects animation timing)
    if renderPipeline.setTimeScale then
        (renderPipeline.setTimeScale as function(any, number))(renderPipeline, scale)
    else
        -- Fallback: set directly
        renderPipeline.timeScale = scale
    end

    local resp = json.serialize({scale = scale, gameTime = renderPipeline.gameTime or 0})
    sendResponse(id, {content = {{type = "text", text = resp}}})
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
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end
    if paused then
        sendResponse(id, {content = {{type = "text", text = "Already paused"}}})
        return
    end

    savedTimeScale = getRenderTimeScale()
    setRenderTimeScale(0.0)
    disableGameplayPhases()
    paused = true
    stepsRemaining = 0

    sendResponse(id, {content = {{type = "text", text = "Game paused"}}})
end

toolHandlers["resume"] = function(_: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end
    if not paused then
        sendResponse(id, {content = {{type = "text", text = "Not paused"}}})
        return
    end

    if savedTimeScale then
        setRenderTimeScale(savedTimeScale)
    end
    savedTimeScale = nil
    enableGameplayPhases()
    paused = false
    stepsRemaining = 0

    sendResponse(id, {content = {{type = "text", text = "Game resumed"}}})
end

toolHandlers["step"] = function(args: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end
    if not paused then
        sendResponse(id, {content = {{type = "text", text = "Must be paused to step"}}, isError = true})
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

    sendResponse(id, {content = {{type = "text", text = "Stepping " .. frames .. " frame(s)"}}})
end

local DEFAULT_COLOR <const>: {number} = {1, 1, 0, 0.8}

toolHandlers["debug_draw"] = function(args: {string:any}, id: number)
    local drawType = args.type as DebugDrawType
    if not drawType then
        sendResponse(id, {content = {{type = "text", text = "Missing 'type' (rect, circle, text, line)"}}, isError = true})
        return
    end

    local color = (args.color as {number}) or DEFAULT_COLOR
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
    sendResponse(id, {content = {{type = "text", text = "Created debug draw " .. cmd.id}}})
end

toolHandlers["clear_debug_draw"] = function(args: {string:any}, id: number)
    local tag = args.tag as string
    local clearId = args.id as integer

    if not tag and not clearId then
        local count = #debugDrawCommands
        debugDrawCommands = {}
        sendResponse(id, {content = {{type = "text", text = "Cleared " .. count .. " debug draw command(s)"}}})
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
    sendResponse(id, {content = {{type = "text", text = "Cleared " .. removed .. " debug draw command(s)"}}})
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
        sendResponse(id, {content = {{type = "text", text = "Saved to " .. result}}})
    else
        sendResponse(id, {content = {{type = "text", text = result}}})
    end
end

toolHandlers["profiler_start"] = function(args: {string:any}, id: number)
    if not world then
        sendResponse(id, {content = {{type = "text", text = "World not initialized"}}, isError = true})
        return
    end
    if sampleSession then
        sendResponse(id, {content = {{type = "text",
            text = "Profiler is already running; call profiler_stop first"}}, isError = true})
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

    local desc = seconds and string.format("%.1fs duration", seconds) or "recording until stopped"
    sendResponse(id, {content = {{type = "text",
        text = "Profiler started: " .. desc
    }}})
end

toolHandlers["profiler_stop"] = function(args: {string:any}, id: number)
    local saveTo = args.save_to as string
    if pendingSampleResult then
        local text = pendingSampleResult
        pendingSampleResult = nil
        if saveTo then
            local f, openErr = io.open(saveTo, "w")
            if not f then
                sendResponse(id, {content = {{type = "text",
                    text = "Failed to write '" .. saveTo .. "': " .. (openErr or "unknown")}}, isError = true})
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
        sendResponse(id, {content = {{type = "text",
            text = "Profiler is not running"}}, isError = true})
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
        sendError(id, -32000, "No world available")
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
                sendResponse(id, {content = {{type = "text", text = "Failed to write: " .. tostring(err)}}, isError = true})
                return
            end
            local destPath = love.filesystem.getSaveDirectory() .. "/" .. saveTo
            log:info("snapshot_save: format=json entities=%d archetypes=%d bytes=%d dest=%s elapsed=%.2fms",
                entityCount, archCount, #payload, destPath, elapsedMs)
            sendResponse(id, {content = {{type = "text",
                text = string.format("Saved JSON snapshot: %d entities across %d archetypes, %d bytes, %.2fms -> %s",
                    entityCount, archCount, #payload, elapsedMs, destPath)}}})
        else
            log:info("snapshot_save: format=json entities=%d archetypes=%d bytes=%d dest=inline elapsed=%.2fms",
                entityCount, archCount, #payload, elapsedMs)
            sendResponse(id, {content = {{type = "text", text = payload}}})
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
                sendResponse(id, {content = {{type = "text", text = "Failed to write: " .. tostring(writeErr)}}, isError = true})
                return
            end
            local destPath = love.filesystem.getSaveDirectory() .. "/" .. saveTo
            log:info("snapshot_save: format=luajit entities=%d archetypes=%d bytes=%d dest=%s elapsed=%.2fms",
                entityCount, archCount, #binary, destPath, elapsedMs)
            sendResponse(id, {content = {{type = "text",
                text = string.format("Saved LuaJIT snapshot: %d entities across %d archetypes, %d bytes, %.2fms -> %s",
                    entityCount, archCount, #binary, elapsedMs, destPath)}}})
        else
            local encoded = love.data.encode("string", "base64", binary) as string
            log:info("snapshot_save: format=luajit entities=%d archetypes=%d bytes=%d dest=inline-base64 elapsed=%.2fms",
                entityCount, archCount, #binary, elapsedMs)
            sendResponse(id, {content = {{type = "text", text = encoded}}})
        end
    else
        sendError(id, -32602, "Unknown format: " .. tostring(format) .. " (expected 'json' or 'luajit')")
    end
end

toolHandlers["snapshot_load"] = function(args: {string:any}, id: number)
    if not world then
        sendError(id, -32000, "No world available")
        return
    end

    local format = (args.format as string) or "json"
    local payload = args.payload as string
    local loadFrom = args.load_from as string
    local source: string
    local payloadBytes = 0

    if not payload and loadFrom then
        if not love.filesystem.getInfo(loadFrom) then
            sendError(id, -32000, "File not found: " .. loadFrom)
            return
        end
        payload = love.filesystem.read(loadFrom)
        if not payload then
            sendError(id, -32000, "Failed to read file: " .. loadFrom)
            return
        end
        source = love.filesystem.getSaveDirectory() .. "/" .. loadFrom
    elseif payload then
        source = "inline-payload"
    end

    if not payload then
        sendError(id, -32602, "Either 'payload' or 'load_from' is required")
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
            sendError(id, -32000, "JSON parse failed: " .. tostring(parsed))
            return
        end
        local ok, err = pcall(function(): boolean
            world:loadSnapshot(parsed as tecs.Snapshot)
            return true
        end)
        if not ok then
            sendError(id, -32000, "Load failed: " .. tostring(err))
            return
        end
        local elapsedMs = (love.timer.getTime() - tStart) * 1000
        local entityCount, archCount = countEntities()
        log:info("snapshot_load: format=json source=%s bytes=%d entities=%d archetypes=%d elapsed=%.2fms",
            source, payloadBytes, entityCount, archCount, elapsedMs)
        sendResponse(id, {content = {{type = "text",
            text = string.format("Restored JSON snapshot: %d entities across %d archetypes, %.2fms from %s",
                entityCount, archCount, elapsedMs, source)}}})
    elseif format == "luajit" then
        local binary = payload
        -- Inline luajit payloads arrive base64-encoded; file reads are raw bytes.
        if not loadFrom then
            local decodedOk, decoded = pcall(function(): string
                return love.data.decode("string", "base64", payload) as string
            end)
            if not decodedOk then
                sendError(id, -32000, "Base64 decode failed: " .. tostring(decoded))
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
            sendError(id, -32000, "Load failed: " .. tostring(err))
            return
        end
        local elapsedMs = (love.timer.getTime() - tStart) * 1000
        local entityCount, archCount = countEntities()
        log:info("snapshot_load: format=luajit source=%s bytes=%d entities=%d archetypes=%d elapsed=%.2fms",
            source, payloadBytes, entityCount, archCount, elapsedMs)
        sendResponse(id, {content = {{type = "text",
            text = string.format("Restored LuaJIT snapshot: %d entities across %d archetypes, %.2fms from %s",
                entityCount, archCount, elapsedMs, source)}}})
    else
        sendError(id, -32602, "Unknown format: " .. tostring(format) .. " (expected 'json' or 'luajit')")
    end
end

-- MCP method handlers
local function handleInitialize(id: number, params: {string:any})
    local clientVersion = params and params.protocolVersion as string or "2024-11-05"
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
    local toolName = params.name as string
    local handler = toolHandlers[toolName]
    if not handler then
        sendError(id, ERR_INVALID_PARAMS, "Unknown tool: " .. toolName)
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

    w:addSystem({
        name = "mcp.StepCounter",
        phase = tecs.phases.PostRender,
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
        before = {"mcp.StepCounter"},
        run = function()
            if #debugDrawCommands == 0 then return end

            -- Find the active camera for world-to-screen conversion.
            -- Cameras aren't stored directly in resources; instead the
            -- render pipeline is, and it exposes getCamera(). We also keep
            -- the old toScreen-duck-type fallback for non-gfx setups.
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
        -- Process MCP HTTP requests in Last and enqueue world ops for
        -- same-frame execution by `mcp.DrainQueuedOps`.
        phase = tecs.phases.Last,
        before = {"mcp.DrainQueuedOps"},
        run = function()
            processCommands()
        end
    })

    w:addSystem({
        name = "mcp.DrainQueuedOps",
        phase = tecs.phases.Last,
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
