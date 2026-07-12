--- Engine-facing MCP tool handlers: ping, screenshots and pixel sampling,
--- LÖVE events and window info, pause/resume/step through the shared freeze
--- controller, time scale, camera conversion, log reads, and the debugger
--- context snapshot.

local rpc <const> = require("tecs2d.mcp.internal.rpc")
local state <const> = require("tecs2d.mcp.internal.state")
local logtap <const> = require("tecs2d.mcp.internal.logtap")
local transport <const> = require("tecs2d.mcp.internal.transport")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")
local debugapi <const> = require("tecs2d.debug.context")

local lg <const> = love.graphics
local le <const> = love.event
local lt <const> = love.timer

local record enginetools
    install: function(ctx: state.Context)
end

local ctx: state.Context = nil

local sendResponse <const> = rpc.sendResponse
local sendToolOK <const> = rpc.sendToolOK
local sendToolError <const> = rpc.sendToolError
local requireWorld <const> = rpc.requireWorld
local requireArg <const> = rpc.requireArg

local handlers: {string: rpc.Handler} = {}

handlers["ping"] = function(_: {string:any}, id: number)
    sendToolOK(id, {
        running = true,
        port = (transport.getBoundPort() or 0) as integer,
        time = lt.getTime()
    })
end

handlers["screenshot"] = function(args: {string:any}, id: number)
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

handlers["sample_pixels"] = function(args: {string:any}, id: number)
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

handlers["send_love_event"] = function(args: {string:any}, id: number)
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

handlers["get_window_size"] = function(_: {string:any}, id: number)
    local w, h = lg.getDimensions()
    sendToolOK(id, {width = w, height = h})
end

handlers["get_fps"] = function(_: {string:any}, id: number)
    sendToolOK(id, {fps = lt.getFPS()})
end

handlers["get_debug_context"] = function(_: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end
    -- The payload is built by the shared debug-context report so this tool
    -- and the `context` debugger command can never drift apart.
    local payload = debugapi.report(world)
    if not payload then
        sendToolError(id, "debugger_disabled",
            "In-game debugger is not enabled; add the debug plugin " ..
            "(require(\"tecs2d.debug\").new()).")
        return
    end
    sendToolOK(id, payload)
end

handlers["quit"] = function(_: {string:any}, id: number)
    sendToolOK(id, {quitting = true})
    le.push("quit")
end

handlers["restart"] = function(_: {string:any}, id: number)
    sendToolOK(id, {restarting = true})
    -- Abort this connection with RST so the restarted instance can
    -- rebind the port immediately (see the transport's close rules).
    ctx.rstOnClose = true
    le.quit("restart")
end

handlers["screen_to_world"] = function(args: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end

    local screenX = args.x as number
    local screenY = args.y as number
    if not screenX or not screenY then
        sendToolError(id, "missing_parameter", "Missing x or y coordinate")
        return
    end

    -- The render pipeline resource is the canonical camera owner; scanning
    -- all resources is a fallback for games without the standard pipeline
    -- (standalone Camera resources or custom pipelines under other keys).
    local camera: any = nil
    local renderPipeline = world.resources[pipelinekey.PIPELINE]
    if renderPipeline then
        camera = renderPipeline:getCamera()
    end

    if not camera then
        local resources = world.resources as {any: any}
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
    end

    if not camera then
        sendToolError(id, "camera_not_found", "No camera found in resources")
        return
    end

    local toWorldFn = (camera as {string: any}).toWorld as function(any, number, number): (number, number)
    local worldX, worldY = toWorldFn(camera, screenX, screenY)
    sendToolOK(id, {
        screen = {x = screenX, y = screenY},
        world = {x = worldX, y = worldY}
    })
end

handlers["set_time_scale"] = function(args: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end

    local scale = requireArg(args, "scale", id) as number
    if not scale then return end

    -- Clamp to reasonable range (0.0 = fully paused, 10.0 = 10x speed)
    scale = math.max(0.0, math.min(10.0, scale))

    -- Get the render pipeline from resources (not world.pipeline which is the system scheduler)
    local renderPipeline = world.resources[pipelinekey.PIPELINE] as {string: any}
    if not renderPipeline then
        sendToolError(id, "render_pipeline_not_found", "Render pipeline not found")
        return
    end

    -- Set the pipeline's time scale (affects animation timing)
    if renderPipeline.setTimeScale then
        (renderPipeline.setTimeScale as function(any, number))(renderPipeline, scale)
    else
        -- Fallback: set directly
        renderPipeline.timeScale = scale
    end

    sendToolOK(id, {scale = scale, gameTime = renderPipeline.gameTime or 0})
end

-- Pause/step goes through the shared freeze controller (one owner of
-- "gameplay is stopped" for both MCP pause and the debugger's open panel).

handlers["pause"] = function(_: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end
    local fz = debugapi.ensureFreeze(world)
    if fz:heldBy("mcp") then
        sendToolOK(id, {paused = true, alreadyPaused = true})
        return
    end
    fz:acquire("mcp")
    sendToolOK(id, {paused = true, savedTimeScale = fz.savedTimeScale})
end

handlers["resume"] = function(_: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end
    local fz = debugapi.ensureFreeze(world)
    if not fz:heldBy("mcp") then
        sendToolOK(id, {paused = false, alreadyResumed = true})
        return
    end
    local restoredTimeScale = fz.savedTimeScale
    fz:release("mcp")
    -- Still frozen when another holder (the open debugger) remains.
    sendToolOK(id, {paused = false, restoredTimeScale = restoredTimeScale,
        stillFrozen = fz:isFrozen()})
end

handlers["step"] = function(args: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end
    local fz = debugapi.ensureFreeze(world)
    if not fz:isFrozen() then
        sendToolError(id, "not_paused", "Must be paused to step")
        return
    end

    local frames = (args.frames as integer) or 1
    if frames < 1 then frames = 1 end
    fz:step(frames)

    sendToolOK(id, {stepping = true, frames = frames})
end

handlers["get_logs"] = function(args: {string:any}, id: number)
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

function enginetools.install(c: state.Context)
    ctx = c
    for name, fn in pairs(handlers) do
        rpc.handlers[name] = fn
    end
end

return enginetools
