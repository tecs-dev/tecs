--- Kernel MCP tool handlers: ping, screenshots and pixel sampling, LÖVE
--- events, log reads, and run_lua. Every other capability is served by the
--- debugger command registry's cmd_* tools (see tecs2d.debug.commands);
--- run_lua executes inside the frame through the shared queued-op drain.

local tecs <const> = require("tecs")
local logging <const> = require("tecs.utils.logging")
local rpc <const> = require("tecs2d.mcp.internal.rpc")
local state <const> = require("tecs2d.mcp.internal.state")
local logtap <const> = require("tecs2d.mcp.internal.logtap")
local transport <const> = require("tecs2d.mcp.internal.transport")

local lg <const> = love.graphics
local le <const> = love.event
local lt <const> = love.timer
local log <const> = logging.getLogger("tecs-mcp")

local record handlers
    install: function(ctx: state.Context)
end

local ctx: state.Context = nil

local sendResponse <const> = rpc.sendResponse
local sendToolOK <const> = rpc.sendToolOK
local sendToolError <const> = rpc.sendToolError
local requireWorld <const> = rpc.requireWorld
local requireArg <const> = rpc.requireArg

local byName: {string: rpc.Handler} = {}

byName["ping"] = function(_: {string:any}, id: number)
    sendToolOK(id, {
        running = true,
        port = (transport.getBoundPort() or 0) as integer,
        time = lt.getTime()
    })
end

byName["screenshot"] = function(args: {string:any}, id: number)
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

byName["sample_pixels"] = function(args: {string:any}, id: number)
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

byName["send_love_event"] = function(args: {string:any}, id: number)
    local eventName = requireArg(args, "event", id) as string
    if not eventName then return end
    -- Accept mixed-type payloads (numbers, booleans, strings). LÖVE events
    -- like resize, mousepressed, wheelmoved, focus, and touch events expect
    -- non-string arguments.
    local eventArgs = args.args as {any}
    if eventArgs and #eventArgs > 0 then
        le.push(eventName, table.unpack(eventArgs))
    else
        le.push(eventName)
    end
    sendToolOK(id, {event = eventName, args = eventArgs or {}})
end

byName["get_logs"] = function(args: {string:any}, id: number)
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

    local out, matched, captured, dropped, latest = logtap.query(minRank, contains, after, limit)
    -- `latest` is the newest captured seq: pass it back as `after` for
    -- incremental polling.
    sendToolOK(id, {logs = out, returned = #out, matched = matched,
        captured = captured, dropped = dropped, latest = latest})
end

byName["run_lua"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    local code = requireArg(args, "code", id) as string
    if not code then return end

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
        local values: {string} = {}
        for i = 2, n do values[i - 1] = tostring(results[i]) end
        sendToolOK(id, {
            returned = n - 1,
            values = values
        })
        ctx.pendingWorldOpResponse = false
    end)
end

function handlers.install(c: state.Context)
    ctx = c
    for name, fn in pairs(byName) do
        rpc.handlers[name] = fn
    end
end

return handlers
