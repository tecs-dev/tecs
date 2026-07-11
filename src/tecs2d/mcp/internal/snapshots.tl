--- Snapshot MCP tools: snapshot_save and snapshot_load in JSON or compact
--- LuaJIT string.buffer form, inline or through LÖVE's save directory.

local tecs <const> = require("tecs")
local bit <const> = require("bit")
local json <const> = require("tecs.utils.json")
local logging <const> = require("tecs.utils.logging")
local StringBuffer <const> = require("string.buffer")
local rpc <const> = require("tecs2d.mcp.internal.rpc")
local state <const> = require("tecs2d.mcp.internal.state")

local lt <const> = love.timer
local log <const> = logging.getLogger("tecs-mcp")

local record snapshots
    install: function(ctx: state.Context)
end

local sendToolOK <const> = rpc.sendToolOK
local sendToolError <const> = rpc.sendToolError
local requireWorld <const> = rpc.requireWorld

local handlers: {string: rpc.Handler} = {}

--- Count live entities and non-empty archetypes.
local function countEntities(world: tecs.World): integer, integer
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

handlers["snapshot_save"] = function(args: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end

    local format = (args.format as string) or "json"
    local saveTo = args.saveTo as string
    local tStart = lt.getTime()

    -- Build the optional layer filter. When present we drive saveSnapshot
    -- through its options path (which bit-masks per entity); when absent we
    -- keep the fast unfiltered routes.
    local layers: {integer}
    if args.layers then
        layers = {}
        local rawLayers = args.layers as {number}
        for i = 1, #rawLayers do
            local layer = math.floor(rawLayers[i])
            if layer < 0 or layer > 31 then
                sendToolError(id, "invalid_layer", "Layer values must be in 0..31",
                    {layer = rawLayers[i]})
                return
            end
            layers[i] = layer as integer
        end
    end

    if format == "json" then
        -- A nil layers key simply falls off the options table, so the
        -- filtered and unfiltered paths share one call.
        local snap = ((world:saveSnapshot({format = "table", layers = layers})
            as {string: any}).snapshot) as tecs.Snapshot
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
        local elapsedMs = (lt.getTime() - tStart) * 1000
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
            })
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
            })
        end
    elseif format == "luajit" then
        local buf = StringBuffer.new()
        -- The writer doesn't know the filter; count what saveSnapshot will
        -- actually emit so the log stays truthful.
        local entityCount = 0
        local archCount = 0
        if layers then
            local Transform = tecs.builtins.Transform as tecs.Component
            local mask = 0
            for i = 1, #layers do mask = bit.bor(mask, bit.lshift(1, layers[i])) end
            world:forEachArchetype(function(arch: tecs.Archetype)
                local c = arch.entities[0]
                local transforms = arch:get(Transform) as {{string: integer}}
                if c == 0 or not transforms then return end
                local matched = 0
                for row = 1, c do
                    local layer = transforms[row].layer
                    if bit.band(bit.rshift(mask, layer), 1) == 1 then
                        matched = matched + 1
                    end
                end
                if matched > 0 then
                    entityCount = entityCount + matched
                    archCount = archCount + 1
                end
            end)
        else
            entityCount, archCount = countEntities(world)
        end
        local out = world:saveSnapshot({buffer = buf, layers = layers})
        local binary = tostring(out.buffer)
        local elapsedMs = (lt.getTime() - tStart) * 1000
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
            })
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
            })
        end
    else
        sendToolError(id, "unknown_format",
            "Unknown format: " .. tostring(format) .. " (expected 'json' or 'luajit')")
    end
end

handlers["snapshot_load"] = function(args: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end

    local format = (args.format as string) or "json"
    local payload = args.payload as string
    local loadFrom = args.loadFrom as string
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
        sendToolError(id, "missing_parameter", "Either 'payload' or 'loadFrom' is required")
        return
    end
    payloadBytes = #payload

    local tStart = lt.getTime()

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
        local elapsedMs = (lt.getTime() - tStart) * 1000
        local entityCount, archCount = countEntities(world)
        log:info("snapshot_load: format=json source=%s bytes=%d entities=%d archetypes=%d elapsed=%.2fms",
            source, payloadBytes, entityCount, archCount, elapsedMs)
        sendToolOK(id, {
            format = "json",
            source = source,
            bytes = payloadBytes,
            entities = entityCount,
            archetypes = archCount,
            elapsedMs = elapsedMs
        })
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
        local elapsedMs = (lt.getTime() - tStart) * 1000
        local entityCount, archCount = countEntities(world)
        log:info("snapshot_load: format=luajit source=%s bytes=%d entities=%d archetypes=%d elapsed=%.2fms",
            source, payloadBytes, entityCount, archCount, elapsedMs)
        sendToolOK(id, {
            format = "luajit",
            source = source,
            bytes = payloadBytes,
            entities = entityCount,
            archetypes = archCount,
            elapsedMs = elapsedMs
        })
    else
        sendToolError(id, "unknown_format",
            "Unknown format: " .. tostring(format) .. " (expected 'json' or 'luajit')")
    end
end

function snapshots.install(_: state.Context)
    for name, fn in pairs(handlers) do
        rpc.handlers[name] = fn
    end
end

return snapshots
