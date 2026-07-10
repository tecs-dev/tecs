require("busted")

local luassert <const> = require("luassert")

_G.love = require("spec.love2d.love2d_mock")

local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local recording <const> = require("tecs2d.debug.internal.recording")

-- A minimal love.thread.Channel backed by a FIFO queue.
local function makeChannel(): any
    local q: {any} = {}
    return {
        push = function(_self: any, v: any) q[#q + 1] = v end,
        pop = function(_self: any): any return table.remove(q, 1) end,
        demand = function(_self: any): any return table.remove(q, 1) end,
        clear = function(_self: any) for i = #q, 1, -1 do q[i] = nil end end,
        getCount = function(_self: any): number return #q end,
    }
end

describe("tecs2d.debug.internal.recording", function()
    local oldFs: any
    local oldTimer: any
    local oldSystem: any
    local oldGraphics: any
    local oldThread: any
    local oldExecute: any
    local oldOpen: any
    local executeResult: any
    local processAlive: boolean
    local files: {string: string}
    local lastLaunchCommand: string
    local channels: {string: any}
    local frameName: string
    local doneName: string

    -- Simulate the encoder worker: drain queued frames, "write" each to disk,
    -- and acknowledge. A {stop} sentinel flushes and reports done.
    local function pumpWorker()
        local fc = love.thread.getChannel(frameName) as any
        local dc = love.thread.getChannel(doneName) as any
        while true do
            local msg = fc:pop() as {string: any}
            if msg == nil then break end
            if msg.stop then
                dc:push({done = true, written = 0})
            else
                files[msg.path as string] = "imgdata"
                dc:push({i = msg.i})
            end
        end
    end

    -- Deliver one captured frame end to end: advance the fps clock, capture,
    -- run the worker, and drain acknowledgements.
    local function captureOne(rec: any)
        love.timer.currentTime = love.timer.currentTime + 1
        rec:captureFrame()
        pumpWorker()
        rec:update(0)
    end

    before_each(function()
        oldFs = love.filesystem
        oldTimer = love.timer
        oldSystem = love.system
        oldGraphics = love.graphics
        oldThread = love.thread
        oldExecute = os.execute
        oldOpen = io.open

        files = {}
        channels = {}
        lastLaunchCommand = ""
        frameName = ""
        doneName = ""
        processAlive = false
        executeResult = 0

        love.timer = {currentTime = 0} as any
        love.timer.getTime = function(): number return love.timer.currentTime end

        love.filesystem = {
            getSaveDirectory = function(): string return "/tmp/tecs save" end,
            createDirectory = function(_path: string): boolean return true end,
            getInfo = function(path: string): any
                local data = files[path]
                if data == nil then return nil end
                return {size = #data}
            end,
            getDirectoryItems = function(dir: string): {string}
                local out: {string} = {}
                local prefix = dir .. "/"
                for path in pairs(files) do
                    if path:sub(1, #prefix) == prefix then
                        out[#out + 1] = path:sub(#prefix + 1)
                    end
                end
                return out
            end,
            remove = function(path: string): boolean
                files[path] = nil
                return true
            end,
        } as any

        love.system = {
            getOS = function(): string return "OS X" end,
            openURL = function(_url: string): boolean return true end,
        } as any

        love.graphics = {
            captureScreenshot = function(cb: function(any))
                cb({} as any)
            end,
        } as any

        love.thread = {
            getChannel = function(name: string): any
                if not channels[name] then channels[name] = makeChannel() end
                return channels[name]
            end,
            newThread = function(_src: string): any
                return {
                    start = function(_self: any, a: string, b: string)
                        frameName = a
                        doneName = b
                    end,
                    wait = function(_self: any) end,
                }
            end,
        } as any

        os.execute = function(cmd: string): any
            if cmd:match("^command %-v ") then
                return executeResult
            end
            local pidPath = cmd:match("> '([^']+%.ffmpeg%.pid)'")
            if pidPath then
                lastLaunchCommand = cmd
                files[pidPath] = "123"
                -- Mirror at the save-relative path, like the real save dir:
                -- love.filesystem sees the file the shell wrote absolutely.
                files[pidPath:gsub("^/tmp/tecs save/", "")] = "123"
                local outputPath = pidPath:gsub("^/tmp/tecs save/", ""):gsub("%.ffmpeg%.pid$", "")
                files[outputPath] = "video"
                processAlive = true
                return 0
            end
            if cmd:match("^kill %-0 ") then
                return processAlive and 0 or 1
            end
            if cmd:match("^kill %-") then
                processAlive = false
                return 0
            end
            return executeResult
        end

        io.open = function(path: string, mode: string): any
            if mode ~= "r" or not files[path] then return nil end
            return {
                read = function(_self: any, _what: string): string return files[path] end,
                close = function(_self: any): boolean return true end,
            }
        end
    end)

    after_each(function()
        love.filesystem = oldFs
        love.timer = oldTimer
        love.system = oldSystem
        love.graphics = oldGraphics
        love.thread = oldThread
        os.execute = oldExecute
        io.open = oldOpen
    end)

    it("arms and cancels a countdown", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 2})

        local started = rec:start({seconds = 5, name = "clip"})

        luassert.is_true(started.ok)
        luassert.equals("countdown", ctx.recording.status)
        luassert.equals("recordings/clip.mp4", ctx.recording.path)
        luassert.equals("frames", ctx.recording.backend)
        luassert.equals(5, ctx.recording.duration)

        local cancelled = rec:cancel()

        luassert.is_true(cancelled.ok)
        luassert.equals("idle", ctx.recording.status)
        luassert.equals("", ctx.recording.path)
    end)

    it("fails when ffmpeg is unavailable", function()
        executeResult = false
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "missing-ffmpeg", countdown = 0})

        local started = rec:start({seconds = 1, name = "clip"})

        luassert.is_false(started.ok)
        luassert.equals("failed", ctx.recording.status)
        luassert.matches("ffmpeg not found", ctx.recording.error)
    end)

    it("records the log path when armed", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 2})

        local started = rec:start({seconds = 1, name = "clip"})

        luassert.is_true(started.ok)
        luassert.equals("countdown", ctx.recording.status)
        luassert.equals("recordings/clip.mp4.ffmpeg.log", ctx.recording.logPath)
    end)

    it("does not stop timed captures on debug reopen by default", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 0})

        luassert.is_true(rec:start({seconds = 5, name = "clip"}).ok)

        local stopped = rec:stopForDebugOpen()

        luassert.is_true(stopped.ok)
        luassert.equals("recording", ctx.recording.status)
    end)

    it("keeps the debugger visible and running when hideDebugger is false", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 0})

        -- The "debug" record mode records with the debugger in-frame.
        luassert.is_true(rec:start({
            seconds = 0, name = "clip", hideDebugger = false, stopOnDebugOpen = false,
        }).ok)
        luassert.is_false(rec.hideDebuggerOnStart)

        -- Reopening the debugger must not stop this recording.
        local stopped = rec:stopForDebugOpen()
        luassert.is_true(stopped.ok)
        luassert.equals("recording", ctx.recording.status)
    end)

    it("keeps the original stop reason when stop is repeated", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 0})

        luassert.is_true(rec:start({seconds = 0, name = "clip"}).ok)
        luassert.is_true(rec:stop("debug_reopened").ok)
        luassert.is_true(rec:stop("manual").ok)

        luassert.equals("stopping", ctx.recording.status)
        luassert.equals("debug_reopened", ctx.recording.stopReason)
    end)

    it("captures frames, assembles a video, and deletes the frame images", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 0})

        luassert.is_true(rec:start({seconds = 0, name = "clip", fps = 30, scale = 0.5}).ok)
        luassert.equals("recording", ctx.recording.status)

        for _ = 1, 3 do captureOne(rec) end

        -- Frame images exist on disk mid-recording.
        luassert.equals(3, #love.filesystem.getDirectoryItems("recordings/clip.frames"))

        luassert.is_true(rec:stop("manual").ok)
        rec:update(0)          -- request worker flush
        pumpWorker()           -- worker acknowledges the stop sentinel
        rec:update(0)          -- worker done -> launch assembly
        luassert.matches("scale=trunc%(iw%*0%.5/2%)%*2", lastLaunchCommand)
        luassert.matches("frame_%%06d%.png", lastLaunchCommand)
        -- 3 frames captured across 3 seconds -> assemble the input at the
        -- achieved 1 fps (not the 30 fps target) so playback is real-time, then
        -- normalize the output container to 30 fps.
        luassert.matches("%-framerate 1%.0000", lastLaunchCommand)
        luassert.matches("%-r 30", lastLaunchCommand)

        processAlive = false
        rec:update(0)          -- assembly finished -> complete

        luassert.equals("completed", ctx.recording.status)
        luassert.equals("manual", ctx.recording.stopReason)
        luassert.equals(1, #ctx.recordings)
        luassert.equals("recordings/clip.mp4", ctx.recordings[1].path)
        -- Frame scratch directory and pid file have been cleaned up; the
        -- ffmpeg log is kept for diagnosis.
        luassert.equals(0, #love.filesystem.getDirectoryItems("recordings/clip.frames"))
        luassert.is_nil(love.filesystem.getInfo("recordings/clip.mp4.ffmpeg.pid"))
    end)

    it("drops frames when the ring is full", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 0, ringSize = 2})

        luassert.is_true(rec:start({seconds = 0, name = "clip", fps = 30}).ok)

        -- Capture without ever running the worker, so nothing drains: the ring
        -- fills at ringSize and further captures are dropped.
        for _ = 1, 5 do
            love.timer.currentTime = love.timer.currentTime + 1
            rec:captureFrame()
        end

        luassert.equals(2, rec.encoder.inFlight)
        luassert.equals(3, rec.encoder.dropped)
    end)

    it("throttles capture to the target fps", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 0, ringSize = 64})

        luassert.is_true(rec:start({seconds = 0, name = "clip", fps = 10}).ok)

        -- Advance only a fraction of the 1/10s interval each time: no capture.
        for _ = 1, 5 do
            love.timer.currentTime = love.timer.currentTime + 0.01
            rec:captureFrame()
        end
        luassert.equals(0, rec.encoder.nextIndex)

        -- One interval elapses -> exactly one capture.
        love.timer.currentTime = love.timer.currentTime + 0.2
        rec:captureFrame()
        luassert.equals(1, rec.encoder.nextIndex)
    end)

    it("marks only captured frames so overlays can exclude themselves", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 0, ringSize = 64})

        luassert.is_true(rec:start({seconds = 0, name = "clip", fps = 10}).ok)

        -- A full interval elapses: this frame is captured.
        love.timer.currentTime = love.timer.currentTime + 0.2
        rec:captureFrame()
        luassert.is_true(rec.capturedThisFrame)

        -- Too soon for the next capture: this frame is not captured, so an
        -- overlay may draw on it without landing in the recording.
        love.timer.currentTime = love.timer.currentTime + 0.01
        rec:captureFrame()
        luassert.is_false(rec.capturedThisFrame)
    end)

    it("fails when no frames were captured", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 0})

        luassert.is_true(rec:start({seconds = 0, name = "clip"}).ok)
        luassert.is_true(rec:stop("manual").ok)
        rec:update(0)          -- flush (nothing queued)
        pumpWorker()           -- worker acknowledges stop
        rec:update(0)          -- worker done, but zero frames -> fail

        luassert.equals("failed", ctx.recording.status)
        luassert.matches("no frames captured", ctx.recording.error)
    end)

    it("cancels an armed recording during shutdown", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 2})

        luassert.is_true(rec:start({seconds = 0, name = "clip"}).ok)

        rec:shutdown()

        luassert.equals("idle", ctx.recording.status)
        luassert.equals("", ctx.recording.path)
    end)

    it("discards and cleans up frames on shutdown during recording", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 0})

        luassert.is_true(rec:start({seconds = 0, name = "clip"}).ok)
        for _ = 1, 2 do captureOne(rec) end
        luassert.equals(2, #love.filesystem.getDirectoryItems("recordings/clip.frames"))

        rec:shutdown()

        luassert.equals("failed", ctx.recording.status)
        luassert.equals("shutdown", ctx.recording.stopReason)
        luassert.equals(0, #love.filesystem.getDirectoryItems("recordings/clip.frames"))
    end)

    it("refuses to record on a non-POSIX host", function()
        love.system = {
            getOS = function(): string return "Windows" end,
            openURL = function(_url: string): boolean return true end,
        } as any
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 0})

        local started = rec:start({seconds = 1, name = "clip"})

        luassert.is_false(started.ok)
        luassert.equals("failed", ctx.recording.status)
        luassert.matches("POSIX", ctx.recording.error)
    end)

    it("auto-stops a timed recording at its duration", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 0})

        luassert.is_true(rec:start({seconds = 2, name = "clip"}).ok)
        captureOne(rec)
        luassert.equals("recording", ctx.recording.status)

        love.timer.currentTime = love.timer.currentTime + 2
        rec:update(0)

        luassert.equals("stopping", ctx.recording.status)
        luassert.equals("timeout", ctx.recording.stopReason)
    end)

    it("fails when the ffmpeg assembly cannot be launched", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 0})

        luassert.is_true(rec:start({seconds = 0, name = "clip"}).ok)
        captureOne(rec)
        luassert.is_true(rec:stop("manual").ok)
        rec:update(0)          -- request worker flush
        pumpWorker()           -- worker acknowledges the stop sentinel

        -- The assembly launch writes no pid file: launching failed.
        executeResult = false
        local realExecute = os.execute
        os.execute = function(_cmd: string): any return false end
        rec:update(0)
        os.execute = realExecute

        luassert.equals("failed", ctx.recording.status)
        luassert.matches("failed to launch ffmpeg assembly", ctx.recording.error)
    end)

    it("keeps controller defaults when one recording overrides format and ring", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {
            ffmpegPath = "ffmpeg", countdown = 2, frameFormat = "png", ringSize = 8,
        })

        luassert.is_true(rec:start({seconds = 1, name = "clip", frameFormat = "tga", ringSize = 2}).ok)
        luassert.equals("tga", rec.currentFrameFormat)
        luassert.equals(2, rec.currentRingSize)
        luassert.equals("png", rec.defaultFrameFormat)
        luassert.equals(8, rec.defaultRingSize)
        rec:cancel()

        -- The next recording without overrides falls back to the defaults.
        luassert.is_true(rec:start({seconds = 1, name = "clip2"}).ok)
        luassert.equals("png", rec.currentFrameFormat)
        luassert.equals(8, rec.currentRingSize)
        rec:cancel()
    end)

    it("fails the recording when the worker reports an encode error", function()
        local ctx = debugcontext.new()
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg", countdown = 0})

        luassert.is_true(rec:start({seconds = 0, name = "clip"}).ok)
        love.timer.currentTime = love.timer.currentTime + 1
        rec:captureFrame()

        -- The worker acknowledges the frame with an error: its index is already
        -- consumed, so assembling would silently truncate at the gap.
        local dc = love.thread.getChannel(doneName) as any
        dc:push({i = 0, err = "boom"})
        rec:update(0)

        luassert.equals("failed", ctx.recording.status)
        luassert.matches("frame encoding failed", ctx.recording.error)
    end)

    it("opens the latest completed recording", function()
        local ctx = debugcontext.new()
        ctx.recordings[#ctx.recordings + 1] = {
            path = "recordings/clip.mp4", size = 10, time = 0, duration = 1, stopReason = "manual",
        }
        files["recordings/clip.mp4"] = "video"
        local rec = recording.new(ctx, {ffmpegPath = "ffmpeg"})

        local opened = rec:open("latest")

        luassert.is_true(opened.ok)
    end)
end)
