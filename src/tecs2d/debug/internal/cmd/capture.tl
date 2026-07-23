--- Media capture commands: screenshots and recordings.
---
--- Everything shared with the core registry arrives through cmdtypes.Deps;
--- this module must not require tecs2d.debug.commands (a load cycle).

local logging <const> = require("tecs.utils.logging")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local artifacts <const> = require("tecs2d.debug.internal.artifacts")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

-- Same logger as the core registry so log filters see one command surface.
local LOGGER <const> = logging.getLogger("tecs2d.debug.commands")
local format <const> = string.format
local getTime <const> = love.timer.getTime

-- Nearest-neighbor ImageData downscale (pure love.image, safe inside the
-- captureScreenshot callback). Screenshots default to the pipeline's virtual
-- resolution: in pixel mode the window is an integer blowup of scaledWidth x
-- scaledHeight, so sampling back down recovers the game's actual pixels while
-- costing readers a fraction of the tokens.
local function downscaleImageData(src: love.image.ImageData, tw: integer, th: integer): love.image.ImageData
    local sw, sh = src:getWidth(), src:getHeight()
    if tw >= sw or th >= sh or tw < 1 or th < 1 then return src end
    local out = love.image.newImageData(tw, th)
    for y = 0, th - 1 do
        local sy = math.floor((y + 0.5) * sh / th)
        for x = 0, tw - 1 do
            local sx = math.floor((x + 0.5) * sw / tw)
            local r, g, b, a = src:getPixel(sx, sy)
            out:setPixel(x, y, r, g, b, a)
        end
    end
    return out
end

local record capture
    --- The Capture-section commands, in display order.
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

local recordSchema <const>: cmdargs.Schema = {
    args = {
        seconds = {default = 0, help = "auto-stop after N seconds; 0 records until stopped"},
        name = {help = "output filename"},
        fps = {default = 30, help = "capture frame rate"},
        scale = {kind = "number", help = "output size multiplier, e.g. 0.5; "
            .. "defaults to the virtual-resolution scale in pixel mode, else 1"},
        debug = {default = false, help = "keep the debugger visible and the game running"},
        countdown = {kind = "number", help = "seconds before recording starts (plugin default if omitted)"},
        stopOnDebugOpen = {kind = "boolean",
            help = "stop when the debugger opens (default: true only for untimed, non-debug recordings)"},
    },
    positional = {"seconds", "name"},
}



-- Shared ref schemas for the artifact verbs (profile/screenshot vs record).
local captureRefSchema <const>: cmdargs.Schema = {
    args = { ref = {help = "capture name or list index"} },
    positional = {"ref"},
}

local recordingRefSchema <const>: cmdargs.Schema = {
    args = { ref = {help = "recording name or list index"} },
    positional = {"ref"},
}

function capture.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    -- The shared context, aliased once so command bodies stay terse.
    local w <const> = d.world
    local ctx <const> = d.ctx
    local reg <const> = d.reg
    local env <const> = d.env
    local pipeline <const> = d.pipeline


    return {
        {
            name = "screenshot",
            section = "Capture",
            shortHelp = "capture the screen (or drag area) to a PNG",
            mcpHelp = "Capture the screen (or the marked drag area) to a PNG at the end "
                .. "of the next rendered frame. In pixel mode the capture is downscaled "
                .. "to the game's VIRTUAL resolution by default (the window is just an "
                .. "integer blowup, so this loses nothing and costs a fraction of the "
                .. "tokens to read); pass full=true for the native window pixels. The "
                .. "result's data.full is the absolute host path where the file appears "
                .. "-- read it from there; data.path is the save-directory-relative "
                .. "name. For point checks sample_pixels is still cheaper.",
            schema = {
                args = {
                    name = {help = "output filename"},
                    panel = {kind = "boolean", help = "keep the debug panel visible in the shot"},
                    delay = {kind = "number", help = "seconds to wait before capturing"},
                    full = {kind = "boolean",
                        help = "capture at native window resolution instead of virtual scale"},
                },
                positional = {"name"},
            },
            examples = {"screenshot", "screenshot boss.png", "screenshot panel=true delay=2",
                "screenshot list"},
            subcommands = {
                artifacts.list("screenshots",
                    function(): {any} return ctx.screenshots as {any} end,
                    function(e: any): string
                        local s = e as debugcontext.ScreenshotEntry
                        return format("  %.1f KB\t%s\t%s",
                            s.size / 1024, os.date("%Y-%m-%d %H:%M:%S", s.time) as string, s.path)
                    end),
                artifacts.clear("screenshots",
                    function(): {any} return ctx.screenshots as {any} end,
                    function(path: string) love.filesystem.remove(path) end,
                    function() ctx.screenshots = {} end),
                artifacts.open("screenshot", "ref", "capture name or list index",
                    function(ref: string): string
                        local e = artifacts.find(ctx.screenshots as {any}, ref)
                        return e and e.path as string
                    end),
                artifacts.path("screenshot", "ref", "capture name or list index",
                    function(ref: string): string
                        local e = artifacts.find(ctx.screenshots as {any}, ref)
                        return e and e.path as string
                    end,
                    debugcontext.savePath),
                artifacts.info("screenshot", "capture",
                    "show one capture's details with a thumbnail (latest if omitted)",
                    captureRefSchema,
                    function(): {any} return ctx.screenshots as {any} end, false,
                    function(e: {string: any}): cmdtypes.Result
                        local abs = debugcontext.savePath(e.path as string)
                        local lines = artifacts.infoLines("screenshot", e, abs)
                        return {ok = true, popup = lines,
                            -- The overlay renders the file as a thumbnail for
                            -- the popup's lifetime.
                            popupImagePath = e.path as string,
                            data = {path = e.path, full = abs, size = e.size, time = e.time}}
                    end),
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                reg.shotCounter = reg.shotCounter + 1
                local name = (v.name as string) or ("debug-shot-" .. tostring(reg.shotCounter) .. ".png")
                -- The file is encoded as PNG regardless; a bare name would
                -- write an extensionless file that viewers then hunt for.
                if not name:lower():match("%.png$") then
                    name = name .. ".png"
                end
                local p = pipeline()
                local hasArea = ctx.hasArea and p ~= nil
                local ax1, ay1, ax2, ay2 = 0.0, 0.0, 0.0, 0.0
                if hasArea then
                    local cam = p:getCamera()
                    ax1, ay1 = cam:toScreen(ctx.areaX1, ctx.areaY1)
                    ax2, ay2 = cam:toScreen(ctx.areaX2, ctx.areaY2)
                end
                local keepPanel = v.panel == true
                local delay = (v.delay as number) or 0
                -- Virtual-scale target, resolved at schedule time. nil means
                -- keep the native capture (full=true, or the pipeline defines
                -- no smaller virtual resolution). The virtual resolution is
                -- the game's logical pixel space whether it scales smoothly
                -- (virtualHeight) or in integer pixel mode.
                local virtH: integer = nil
                if v.full ~= true and p then
                    local pAny = p as {string: any}
                    local vh = pAny.pixelMode and pAny.scaledHeight as number
                        or pAny.virtualHeight as number
                    if vh and vh >= 1 then
                        virtH = math.floor(vh) as integer
                    end
                end
                local function fire()
                    -- Hide the overlay chrome for this one frame so the shot is
                    -- the game only (unless panel=true); the capture runs at
                    -- end of frame.
                    if not keepPanel then
                        reg.signals.hideOverlay = true
                    end
                    love.graphics.captureScreenshot(function(imageData: love.image.ImageData)
                        local captureErr: string = nil
                        local ok = xpcall(function()
                            local finalData = imageData
                            local fullW = imageData:getWidth()
                            local fullH = imageData:getHeight()
                            if hasArea then
                                local pw = fullW
                                local ph = fullH
                                local scaleX = pw / love.graphics.getWidth()
                                local scaleY = ph / love.graphics.getHeight()
                                local cx = math.max(0, math.min(math.floor(math.min(ax1, ax2) * scaleX) as integer, pw - 1))
                                local cy = math.max(0, math.min(math.floor(math.min(ay1, ay2) * scaleY) as integer, ph - 1))
                                local cw = math.max(1, math.min(math.floor(math.abs(ax2 - ax1) * scaleX) as integer, pw - cx))
                                local ch = math.max(1, math.min(math.floor(math.abs(ay2 - ay1) * scaleY) as integer, ph - cy))
                                local cropped = love.image.newImageData(cw, ch)
                                cropped:paste(imageData, 0, 0, cx, cy, cw, ch)
                                finalData = cropped
                            end
                            if virtH and fullH > virtH then
                                -- Same shrink ratio for full frames and area
                                -- crops, so a crop's pixels line up with the
                                -- equivalent region of a full virtual shot.
                                local ratio = virtH / fullH
                                local tw = math.max(1, math.floor(finalData:getWidth() * ratio + 0.5)) as integer
                                local th = math.max(1, math.floor(finalData:getHeight() * ratio + 0.5)) as integer
                                finalData = downscaleImageData(finalData, tw, th)
                            end
                            finalData:encode("png", name)
                            local info = love.filesystem.getInfo(name)
                            local size = (info and info.size) or 0
                            ctx.screenshots[#ctx.screenshots + 1] =
                                {path = name, size = size as integer, time = os.time()}
                            w:emit(0, debugcontext.OnDebugContext("screenshot", name, 0))
                            debugcontext.pushEvent(ctx, "screenshot", {path = name})
                            debugcontext.setStatus(ctx, "screenshot saved at " .. debugcontext.savePath(name))
                        end, function(e: any): string
                            captureErr = tostring(e)
                            return captureErr
                        end)
                        if not ok then
                            LOGGER:error("screenshot capture failed name=%s error=%s", name, captureErr)
                            debugcontext.setStatus(ctx, "screenshot failed: " .. captureErr)
                        end
                    end)
                end
                -- `full` is the resolved host path the file will appear at once
                -- the end-of-frame capture callback runs -- returned up front so
                -- clients never have to hunt for the save directory.
                local full = debugcontext.savePath(name)
                if delay > 0 then
                    reg.pendingShots[#reg.pendingShots + 1] = {dueIn = delay, fire = fire}
                    return {ok = true,
                        message = format("capturing %s in %.1fs%s%s", name, delay,
                            hasArea and " (area)" or "", keepPanel and " (panel)" or ""),
                        data = {path = name, full = full, area = hasArea,
                            panel = keepPanel, delay = delay}}
                end
                fire()
                return {ok = true, message = "capturing " .. name .. (hasArea and " (area)" or "") ..
                        (keepPanel and " (panel)" or ""),
                    data = {path = name, full = full, area = hasArea, panel = keepPanel}}
            end,
        },
        {
            name = "record",
            section = "Capture",
            shortHelp = "record the window to a video",
            examples = {"record start 30 clip fps=60", "record start debug", "record stop", "record list"},
            subcommands = {
                {
                    name = "start",
                    shortHelp = "start recording the window",
                    schema = recordSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        -- `debug` keeps the debugger open and the game running so
                        -- it is captured in the recording without freezing.
                        local secs = v.seconds as number
                        local showDebug = v.debug as boolean
                        local stopOnOpen = v.stopOnDebugOpen as boolean
                        if stopOnOpen == nil then
                            stopOnOpen = secs <= 0 and not showDebug
                        end
                        -- Default the output to the game's virtual resolution:
                        -- the window is just a scale-up of the logical pixel
                        -- space, so encoding it wastes pixels (and reader
                        -- tokens) on blowup.
                        local scaleArg = v.scale as number
                        if scaleArg == nil then
                            local p = pipeline()
                            local pAny = p as {string: any}
                            if p then
                                local ph = love.graphics.getPixelHeight()
                                local sh = pAny.pixelMode and pAny.scaledHeight as number
                                    or pAny.virtualHeight as number
                                if ph > 0 and sh and sh > 0 and sh < ph then
                                    scaleArg = sh / ph
                                end
                            end
                        end
                        local out = env.recorder:start({
                            seconds = secs,
                            name = v.name as string,
                            fps = math.floor(v.fps as number) as integer,
                            scale = scaleArg,
                            countdown = v.countdown as number,
                            stopOnDebugOpen = stopOnOpen,
                            hideDebugger = not showDebug,
                        })
                        return {ok = out.ok, message = out.message,
                            data = {recording = out.state}}
                    end,
                },
                {
                    name = "stop",
                    shortHelp = "stop the active recording",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local out = env.recorder:stop("manual")
                        return {ok = out.ok, message = out.message,
                            data = {recording = out.state}}
                    end,
                },
                {
                    name = "cancel",
                    shortHelp = "cancel an armed countdown",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local out = env.recorder:cancel()
                        return {ok = out.ok, message = out.message,
                            data = {recording = out.state}}
                    end,
                },
                {
                    name = "status",
                    shortHelp = "show the current recording state",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local r = ctx.recording
                        local msg: string
                        if r.status == "countdown" then
                            msg = format("recording in %ds -> %s", math.ceil(r.countdown), r.path)
                        elseif r.status == "recording" then
                            msg = format("recording %.1fs -> %s (log %s)",
                                getTime() - r.startedAt, r.path, r.logPath)
                        elseif r.status == "failed" then
                            msg = "recording failed: " .. r.error .. " (log " .. r.logPath .. ")"
                        else
                            msg = "recording: " .. r.status
                        end
                        return {ok = true, message = msg, data = {recording = r}}
                    end,
                },
                artifacts.list("recordings",
                    function(): {any} return ctx.recordings as {any} end,
                    function(e: any): string
                        local rec = e as debugcontext.RecordingEntry
                        return format("  %.1f KB  %.1fs  %s  %s",
                            rec.size / 1024, rec.duration,
                            os.date("%Y-%m-%d %H:%M:%S", rec.time) as string, rec.path)
                    end),
                {
                    name = "open",
                    shortHelp = "open a completed recording (latest if omitted)",
                    schema = recordingRefSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local ref = v.ref as string
                        local e = artifacts.find(ctx.recordings as {any}, ref)
                        local out = env.recorder:open(e and e.path as string or ref)
                        return {ok = out.ok, message = out.message}
                    end,
                },
                artifacts.path("record", "ref", "recording name or list index",
                    function(ref: string): string
                        local e = artifacts.find(ctx.recordings as {any}, ref)
                        return e and e.path as string
                    end,
                    debugcontext.savePath),
                artifacts.info("record", "recording",
                    "show one completed recording's details (latest if omitted)",
                    recordingRefSchema,
                    function(): {any} return ctx.recordings as {any} end, false,
                    function(e: {string: any}): cmdtypes.Result
                        local abs = debugcontext.savePath(e.path as string)
                        local lines = artifacts.infoLines("recording", e, abs)
                        lines[#lines + 1] = format("  duration\t%.1fs", e.duration as number)
                        lines[#lines + 1] = "  stopped\t" .. tostring(e.stopReason)
                        lines[#lines + 1] = "  log\t" .. tostring(e.path) .. ".ffmpeg.log"
                        return {ok = true, popup = lines,
                            data = {path = e.path, full = abs, size = e.size, time = e.time,
                                duration = e.duration, stopReason = e.stopReason}}
                    end),
            },
        },
    }
end

return capture
