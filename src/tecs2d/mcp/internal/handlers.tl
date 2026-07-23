--- Kernel MCP tool handlers: ping, screenshots and pixel sampling, LÖVE
--- events, log reads, and run_lua. Every other capability is served by the
--- debugger command registry's cmd_* tools (see tecs2d.debug.commands);
--- run_lua executes inside the frame through the shared queued-op drain.

local tecs <const> = require("tecs")
local buildinfo <const> = require("tecs2d.buildinfo")
local logging <const> = require("tecs.utils.logging")
local rpc <const> = require("tecs2d.mcp.internal.rpc")
local state <const> = require("tecs2d.mcp.internal.state")
local sandbox <const> = require("tecs2d.mcp.internal.sandbox")
local mcpTools <const> = require("tecs2d.mcp.tools")
local inputtape <const> = require("tecs2d.debug.internal.inputtape")
local suspension <const> = require("tecs2d.internal.suspension")
local logtap <const> = require("tecs2d.internal.logtap")
local transport <const> = require("tecs2d.mcp.internal.transport")

local lg <const> = love.graphics
local le <const> = love.event
local lt <const> = love.timer
local log <const> = logging.getLogger("tecs-mcp")

local record handlers
    install: function(ctx: state.Context)
    cleanup: function()
end

local ctx: state.Context = nil

local sendResponse <const> = rpc.sendResponse
local sendToolOK <const> = rpc.sendToolOK
local sendToolError <const> = rpc.sendToolError
local requireWorld <const> = rpc.requireWorld
local requireArg <const> = rpc.requireArg

local byName: {string: rpc.Handler} = {}

byName["ping"] = function(_: {string:any}, id: rpc.Id)
    local payload: {string: any} = {
        running = true,
        port = (transport.getBoundPort() or 0) as integer,
        time = lt.getTime(),
    }
    if ctx.crashed then
        payload.crashed = true
        payload.error = ctx.crashed
    end
    -- Build identity, so a caller can detect a stale process: if `build.built`
    -- predates the latest `tecs build`, the answers come from old code. Read
    -- fresh from disk -- hot reload swaps the manifest under the process, and
    -- the cached copy would report boot-time metadata ("my change didn't
    -- load") forever after.
    local info = buildinfo.fresh()
    if info then
        payload.build = {name = info.name, built = info.built, dev = info.dev}
    end
    sendToolOK(id, payload)
end

byName["screenshot"] = function(args: {string:any}, id: rpc.Id)
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
                "Region requires numeric x, y, width, and height")
            return
        end
        if regionW < 1 or regionH < 1 then
            sendToolError(id, "invalid_parameter",
                "Region width and height must be at least 1",
                {width = regionW, height = regionH})
            return
        end
    end

    ctx.pendingScreenshotId = id
    lg.captureScreenshot(function(imageData: love.image.ImageData)
        if ctx.pendingScreenshotId ~= id then return end
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
        ctx.pendingScreenshotId = nil
        if not ok then
            sendToolError(id, "screenshot_failed", captureErr)
        end
    end)
end

byName["sample_pixels"] = function(args: {string:any}, id: rpc.Id)
    local points = args.points as {{string: any}}
    if type(points) ~= "table" or #points == 0 then
        sendToolError(id, "missing_parameter", "Missing or empty 'points' array")
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
    ctx.pendingScreenshotId = id
    lg.captureScreenshot(function(imageData: love.image.ImageData)
        if ctx.pendingScreenshotId ~= id then return end
        -- Errors here would propagate into love.run; report them as a tool
        -- error and always release the pending slot, or the connection wedges.
        local captureErr: string = nil
        local ok = xpcall(function()
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
            sendToolOK(id, {width = w, height = h, pixels = samples})
        end, function(e: any): string
            captureErr = tostring(e)
            return captureErr
        end)
        ctx.pendingScreenshotId = nil
        if not ok then
            sendToolError(id, "sample_failed", captureErr)
        end
    end)
end

byName["send_love_event"] = function(args: {string:any}, id: rpc.Id)
    local eventName = requireArg(args, "event", id) as string
    if not eventName then return end
    -- Accept mixed-type payloads (numbers, booleans, strings). LÖVE events
    -- like resize, mousepressed, wheelmoved, focus, and touch events expect
    -- non-string arguments.
    local eventArgs = args.args as {any}

    -- Unfrozen, a raw love.event.push lands mid-frame relative to the input
    -- latch (and un-defaulted args can leave the latch keyed on a nil
    -- scancode): the event "sends" but the Update-phase edge never sees it.
    -- Route tapeable events through the input tape at the next gameplay
    -- frame instead -- same real dispatch path, frame-aligned, args
    -- defaulted. Frozen, keep the raw push: the debugger overlay's typed
    -- console consumes love callbacks while gameplay phases are disabled.
    -- Crashed mode raw-pushes always: gameplay frames never run, so a taped
    -- row would sit forever; the error loop polls love events directly
    -- (quit/escape), which is exactly what a crashed game still needs.
    local w = ctx.world
    if w and not ctx.crashed and inputtape.tapeable(eventName) then
        local controller = w.resources[suspension.KEY]
        local frozen = controller ~= nil and controller:isSuspended()
        if not frozen then
            local tape = inputtape.ensure(w)
            local queued, qerr = tape:queue(
                {{at = 1, event = eventName, args = eventArgs or {}}}, true)
            if not queued then
                sendToolError(id, "invalid_event", "send_love_event: " .. qerr)
                return
            end
            sendToolOK(id, {event = eventName, args = eventArgs or {},
                dispatch = "next gameplay frame (input tape)"})
            return
        end
    end
    if eventArgs and #eventArgs > 0 then
        le.push(eventName, table.unpack(eventArgs))
    else
        le.push(eventName)
    end
    sendToolOK(id, {event = eventName, args = eventArgs or {}})
end

byName["get_logs"] = function(args: {string:any}, id: rpc.Id)
    if args.clear == true then
        sendToolOK(id, {cleared = logtap.clear()})
        return
    end
    local minRank = 1
    local level = args.level as string
    if level then
        minRank = logtap.levelRank(level)
        if not minRank then
            sendToolError(id, "invalid_parameter",
                "'level' must be DEBUG, INFO, WARN, or ERROR", {value = level})
            return
        end
    end
    local contains = args.contains as string
    local after = (args.after as integer) or 0
    local limit = (args.limit as integer) or 50

    local out, matched, captured, dropped, latest =
        logtap.query(minRank, contains, nil, after, 0, limit)
    -- `latest` is the newest captured seq: pass it back as `after` for
    -- incremental polling.
    sendToolOK(id, {logs = out, returned = #out, matched = matched,
        captured = captured, dropped = dropped, latest = latest})
end

byName["run_lua"] = function(args: {string:any}, id: rpc.Id)
    if not requireWorld(id) then return end

    local code = requireArg(args, "code", id) as string
    if not code then return end

    local fn, compileErr = sandbox.compile(code)
    if not fn then
        local errMsg = tostring(compileErr)
        log:error("run_lua load failed: %s", errMsg)
        sendToolError(id, "lua_load_failed", "Lua load failed", {error = errMsg})
        return
    end

    -- Run in the queued-op drain and return the chunk's results. Keep the client
    -- socket open until this deferred response is sent (the request handler returns
    -- before the queued op runs).
    ctx.pendingWorldOpResponse = true
    state.enqueue(ctx, function(w: tecs.World)
        local pcallAny = pcall as function(any, ...: any): boolean, any
        local results = {pcallAny(fn, w)} as {any}
        if not results[1] then
            local errMsg = tostring(results[2])
            log:error("run_lua execution failed: %s", errMsg)
            sendToolError(id, "lua_execution_failed", "Lua execution failed", {error = errMsg})
            ctx.pendingWorldOpResponse = false
            return
        end
        local n = #results
        -- JSON by default: keep JSON-representable values (numbers, strings,
        -- booleans, serializable tables) as-is so the response carries native
        -- JSON; fall back to tostring for anything else. `lua=true` opts into the
        -- raw Lua tostring form for every value.
        local raw = args.lua == true
        local values: {any} = {}
        for i = 2, n do
            local v = results[i]
            local vt = type(v)
            if raw then
                values[i - 1] = tostring(v)
            elseif vt == "number" or vt == "string" or vt == "boolean" then
                values[i - 1] = v
            elseif vt == "table" and pcall(tecs.json.serialize, v) then
                values[i - 1] = v
            else
                values[i - 1] = tostring(v)
            end
        end
        sendToolOK(id, {
            returned = n - 1,
            values = values
        })
        ctx.pendingWorldOpResponse = false
    end)
end

function handlers.install(c: state.Context)
    ctx = c
    for name in pairs(mcpTools.byName) do
        if not byName[name] then
            error("kernel MCP tool has no handler: " .. name)
        end
    end
    for name, fn in pairs(byName) do
        if not mcpTools.byName[name] then
            error("kernel MCP handler has no tool declaration: " .. name)
        end
        rpc.handlers[name] = fn
    end
end

function handlers.cleanup()
    ctx = nil
    sandbox.reset()
end

return handlers
