local tecs <const> = require("tecs")
local logging <const> = require("tecs.utils.logging")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local framecapture <const> = require("tecs2d.debug.internal.framecapture")
local osopen <const> = require("tecs2d.debug.internal.osopen")

local LOGGER <const> = logging.getLogger("tecs2d.debug.recording")

-- Recording captures the app's own framebuffer via love.graphics.captureScreenshot,
-- hands each frame to a worker thread that writes numbered images to disk, then
-- runs a single ffmpeg pass to assemble them into a video. This needs no macOS
-- Screen Recording permission, works headless, and records exactly the window.
-- ffmpeg is still required, but only for the final offline assembly.

local record recording
    record Options
        ffmpegPath: string
        outputDir: string
        countdown: number
        fps: integer
        scale: number         -- output scale multiplier, 0 < scale (default 1)
        frameFormat: string   -- captured image format: "png" (default) | "tga" | "jpg"
        ringSize: integer      -- max frames in flight before dropping (default 8)
    end

    record StartOptions
        seconds: number
        name: string
        countdown: number
        stopOnDebugOpen: boolean
        hideDebugger: boolean
        fps: integer
        scale: number
        frameFormat: string
        ringSize: integer
    end

    record Result
        ok: boolean
        message: string
        state: debugcontext.RecordingState
        recordings: {debugcontext.RecordingEntry}
    end

    record Controller
        ctx: debugcontext.Context
        ffmpegPath: string
        outputDir: string
        defaultCountdown: number
        defaultFps: integer
        defaultScale: number
        defaultFrameFormat: string
        defaultRingSize: integer
        outputPath: string
        outputAbsPath: string
        logPath: string
        logAbsPath: string
        pidPath: string
        pidAbsPath: string
        processPid: integer
        hideDebuggerOnStart: boolean
        currentFps: integer
        currentScale: number
        currentFrameFormat: string
        currentRingSize: integer
        encoder: framecapture.Encoder
        framesDir: string
        lastCaptureAt: number
        capturedThisFrame: boolean
        recordedElapsed: number
        assembleLaunched: boolean
        start: function(self: Controller, opts?: StartOptions): Result
        stop: function(self: Controller, reason?: string): Result
        cancel: function(self: Controller): Result
        update: function(self: Controller, dt: number)
        captureFrame: function(self: Controller)
        open: function(self: Controller, name?: string): Result
        list: function(self: Controller): Result
        status: function(self: Controller): Result
        stopForDebugOpen: function(self: Controller): Result
        shutdown: function(self: Controller)
    end

    KEY: tecs.Key<Controller>
    new: function(ctx: debugcontext.Context, opts?: Options): Controller
end

recording.KEY = tecs.newKey()

local shellQuote <const> = osopen.shellQuote

local function closeInheritedFdsCommand(): string
    local parts: {string} = {}
    for fd = 3, 64 do
        parts[#parts + 1] = "exec " .. tostring(fd) .. "<&- " .. tostring(fd) .. ">&-"
    end
    return table.concat(parts, "; ")
end

local function sanitizeName(name: string): string
    local out = name:gsub("[^%w%._%-]", "_")
    if out == "" then out = "recording" end
    if not out:match("%.%w+$") then
        out = out .. ".mp4"
    end
    return out
end

-- Strip the output extension so the frames scratch dir reads as
-- "recording-123.frames" rather than "recording-123.mp4.frames".
local function baseName(name: string): string
    return (name:gsub("%.%w+$", ""))
end

local function absSavePath(rel: string): string
    return love.filesystem.getSaveDirectory() .. "/" .. rel
end

local function resetState(ctx: debugcontext.Context)
    ctx.recording.status = "idle"
    ctx.recording.path = ""
    ctx.recording.logPath = ""
    ctx.recording.startedAt = 0
    ctx.recording.duration = 0
    ctx.recording.countdown = 0
    ctx.recording.stopReason = ""
    ctx.recording.error = ""
    ctx.recording.name = ""
end

local function result(self: recording.Controller, ok: boolean, message: string): recording.Result
    return {
        ok = ok,
        message = message,
        state = self.ctx.recording,
        recordings = self.ctx.recordings,
    }
end

local function fileSize(rel: string): integer
    local info = love.filesystem.getInfo(rel)
    if info and info.size then return info.size as integer end
    return 0
end

local function fileExists(rel: string): boolean
    return love.filesystem.getInfo(rel) ~= nil
end

local function commandSucceeded(ok: any): boolean
    return ok == true or ok == 0
end

local function readPid(path: string): integer
    local f = io.open(path, "r")
    if not f then return 0 end
    local text = f:read("*a")
    f:close()
    local pid = tonumber(text or "")
    if not pid then return 0 end
    return math.floor(pid) as integer
end

local function processRunning(pid: integer): boolean
    if pid <= 0 then return false end
    return commandSucceeded(os.execute("kill -0 " .. tostring(pid) .. " >/dev/null 2>&1") as any)
end

local function signalProcess(pid: integer, signal: string): boolean
    if pid <= 0 then return false end
    return commandSucceeded(os.execute("kill -" .. signal .. " " .. tostring(pid) .. " >/dev/null 2>&1") as any)
end

-- Total bytes of the captured frame images currently on disk. This is the
-- peak transient disk cost of a recording (deleted after assembly).
local function framesDirBytes(self: recording.Controller): integer
    if self.framesDir == "" then return 0 end
    local files = love.filesystem.getDirectoryItems(self.framesDir)
    local total = 0
    for i = 1, #files do
        local info = love.filesystem.getInfo(self.framesDir .. "/" .. files[i])
        if info and info.size then total = total + (info.size as integer) end
    end
    return total
end

-- Delete the intermediate frame images. Safe to call in any terminal path.
local function cleanupFrames(self: recording.Controller)
    if self.framesDir == "" then return end
    local files = love.filesystem.getDirectoryItems(self.framesDir)
    for i = 1, #files do
        love.filesystem.remove(self.framesDir .. "/" .. files[i])
    end
    love.filesystem.remove(self.framesDir)
    self.framesDir = ""
end

-- The pid file only exists to hand the assembly pid to the state machine;
-- delete it in every terminal path (the .ffmpeg.log is kept for diagnosis).
local function cleanupPidFile(self: recording.Controller)
    if self.pidPath ~= "" then
        love.filesystem.remove(self.pidPath)
    end
end

local function complete(self: recording.Controller, reason: string)
    local ctx = self.ctx
    local elapsed = 0.0
    if ctx.recording.startedAt > 0 then
        elapsed = love.timer.getTime() - ctx.recording.startedAt
    end
    local size = fileSize(self.outputPath)
    self.processPid = 0
    cleanupFrames(self)
    cleanupPidFile(self)
    if size <= 0 then
        ctx.recording.status = "failed"
        ctx.recording.countdown = 0
        ctx.recording.stopReason = reason
        ctx.recording.error = "ffmpeg produced no output file; see " .. self.logPath
        LOGGER:error("recording produced no output reason=%s path=%s duration=%.3f size=%d log=%s",
            reason, self.outputPath, elapsed, size, self.logPath)
        return
    end
    ctx.recording.status = "completed"
    ctx.recording.countdown = 0
    ctx.recording.stopReason = reason
    ctx.recording.error = ""
    ctx.recordings[#ctx.recordings + 1] = {
        path = self.outputPath,
        size = size,
        time = os.time(),
        duration = elapsed,
        stopReason = reason,
    }
    debugcontext.setStatus(ctx, "recording saved at " .. self.outputAbsPath)
    debugcontext.pushEvent(ctx, "recording", {path = self.outputPath, stopReason = reason})
    LOGGER:info("recording completed reason=%s path=%s duration=%.3f size=%d log=%s",
        reason, self.outputPath, elapsed, size, self.logPath)
end

local function fail(self: recording.Controller, message: string)
    if self.processPid > 0 then signalProcess(self.processPid, "TERM") end
    self.processPid = 0
    cleanupFrames(self)
    cleanupPidFile(self)
    self.ctx.recording.status = "failed"
    self.ctx.recording.error = message
    self.ctx.recording.countdown = 0
    LOGGER:error("recording failed path=%s log=%s error=%s", self.outputPath, self.logPath, message)
end

local function ffmpegAvailable(path: string): boolean
    local cmd = "command -v " .. shellQuote(path) .. " >/dev/null 2>&1"
    return commandSucceeded(os.execute(cmd) as any)
end

-- Spawn the encoder worker. captureFrame() feeds it each frame from here on.
local function launchCapture(self: recording.Controller): boolean, string
    self.framesDir = self.outputDir .. "/" .. baseName(self.ctx.recording.name) .. ".frames"
    self.assembleLaunched = false
    self.lastCaptureAt = 0
    local ok, enc = pcall(framecapture.new, {
        dir = self.framesDir,
        format = self.currentFrameFormat,
        ringSize = self.currentRingSize,
        token = self.ctx.recording.name,
    })
    if not ok then
        return false, "failed to start frame encoder: " .. tostring(enc)
    end
    self.encoder = enc as framecapture.Encoder
    LOGGER:info("frame capture started dir=%s format=%s ring=%d fps=%d scale=%.3f",
        self.framesDir, self.currentFrameFormat, self.currentRingSize, self.currentFps, self.currentScale)
    return true, ""
end

-- Assemble the captured frame sequence into the output video. Runs ffmpeg as a
-- finite job (it exits on its own at end of input); the stopping state machine
-- watches its pid to know when the video is ready. The scale filter also rounds
-- dimensions to even numbers, which yuv420p requires.
-- The capture rate actually achieved. Frames are dropped when the encoder
-- cannot keep up (common at high-DPI resolutions), so the number written is
-- usually below currentFps * duration. Assembling at this real rate keeps the
-- video at real-time speed instead of playing fast.
local function achievedFps(self: recording.Controller): number
    if self.recordedElapsed > 0 and self.encoder.written > 0 then
        return self.encoder.written / self.recordedElapsed
    end
    return self.currentFps
end

local function buildAssembleCommand(self: recording.Controller): string
    local s = tostring(self.currentScale)
    local vf = "scale=trunc(iw*" .. s .. "/2)*2:trunc(ih*" .. s .. "/2)*2,format=yuv420p"
    local pattern = absSavePath(self.encoder:pattern())
    -- Read the sequence at the rate it was actually captured; normalize the
    -- output to the target fps (duplicating frames) for a clean container rate
    -- and correct duration.
    local cmd = {
        "(",
        closeInheritedFdsCommand() .. ";",
        shellQuote(self.ffmpegPath),
        "-y",
        "-nostdin",
        "-framerate", string.format("%.4f", achievedFps(self)),
        "-start_number", "0",
        "-i", shellQuote(pattern),
        "-vf", shellQuote(vf),
        "-r", tostring(self.currentFps),
        "-movflags", "+faststart",
        shellQuote(self.outputAbsPath),
        ">", shellQuote(self.logAbsPath), "2>&1",
        "&", "echo", "$!", ">", shellQuote(self.pidAbsPath),
        ")",
    }
    return table.concat(cmd, " ")
end

local function launchAssemble(self: recording.Controller): boolean, string
    local command = buildAssembleCommand(self)
    LOGGER:info("assembling frames dir=%s frames=%d dropped=%d framesBytes=%.1fMB elapsed=%.2fs achievedFps=%.2f output=%s",
        self.framesDir, self.encoder.written, self.encoder.dropped,
        framesDirBytes(self) / 1048576, self.recordedElapsed, achievedFps(self), self.outputPath)
    LOGGER:debug("ffmpeg assemble command: %s", command)
    if not commandSucceeded(os.execute(command) as any) then
        return false, "failed to launch ffmpeg assembly"
    end
    self.processPid = readPid(self.pidAbsPath)
    if self.processPid <= 0 then
        return false, "failed to read ffmpeg assembly pid"
    end
    return true, ""
end

function recording.new(ctx: debugcontext.Context, opts?: recording.Options): recording.Controller
    local cfg = opts or {}
    local ffmpegPath = cfg.ffmpegPath or "ffmpeg"
    local outputDir = cfg.outputDir or "recordings"
    local self: recording.Controller = {
        ctx = ctx,
        ffmpegPath = ffmpegPath,
        outputDir = outputDir,
        defaultCountdown = cfg.countdown or 3.0,
        defaultFps = cfg.fps or 30,
        defaultScale = cfg.scale and cfg.scale > 0 and cfg.scale or 1.0,
        defaultFrameFormat = cfg.frameFormat or "png",
        defaultRingSize = cfg.ringSize and cfg.ringSize > 0 and cfg.ringSize or 8,
        outputPath = "",
        outputAbsPath = "",
        logPath = "",
        logAbsPath = "",
        pidPath = "",
        pidAbsPath = "",
        processPid = 0,
        hideDebuggerOnStart = true,
        currentFps = cfg.fps or 30,
        currentScale = cfg.scale and cfg.scale > 0 and cfg.scale or 1.0,
        currentFrameFormat = cfg.frameFormat or "png",
        currentRingSize = cfg.ringSize and cfg.ringSize > 0 and cfg.ringSize or 8,
        encoder = nil,
        framesDir = "",
        lastCaptureAt = 0,
        capturedThisFrame = false,
        recordedElapsed = 0,
        assembleLaunched = false,
    } as recording.Controller
    setmetatable(self as {string: any}, {__index = recording.Controller})
    ctx.recording.backend = "frames"
    ctx.recording.ffmpegPath = ffmpegPath
    return self
end

function recording.Controller:start(opts?: recording.StartOptions): recording.Result
    local cfg = opts or {}
    local status = self.ctx.recording.status
    if status == "preparing" or status == "countdown" or status == "recording" or status == "stopping" then
        return result(self, false, "recording already active")
    end
    -- The capture pipeline shells out POSIX-style (command -v, kill, $!), so
    -- host recording works on macOS and Linux only.
    local osName = love.system.getOS()
    if osName ~= "OS X" and osName ~= "macOS" and osName ~= "Linux" then
        local err = "host recording requires a POSIX shell (macOS or Linux); not supported on " .. osName
        fail(self, err)
        return result(self, false, err)
    end
    if not ffmpegAvailable(self.ffmpegPath) then
        local err = "ffmpeg not found on PATH: " .. self.ffmpegPath
        fail(self, err)
        return result(self, false, err)
    end

    love.filesystem.createDirectory(self.outputDir)
    local name = sanitizeName(cfg.name or ("recording-" .. tostring(os.time())))
    self.outputPath = self.outputDir .. "/" .. name
    self.outputAbsPath = absSavePath(self.outputPath)
    self.logPath = self.outputDir .. "/" .. name .. ".ffmpeg.log"
    self.logAbsPath = absSavePath(self.logPath)
    self.pidPath = self.outputDir .. "/" .. name .. ".ffmpeg.pid"
    self.pidAbsPath = absSavePath(self.pidPath)
    self.processPid = 0
    -- Per-recording settings fall back to the controller defaults without
    -- mutating them: a one-off frameFormat or ringSize on one start() must not
    -- change what later recordings use.
    self.hideDebuggerOnStart = cfg.hideDebugger ~= false
    self.currentFps = cfg.fps or self.defaultFps
    self.currentScale = cfg.scale and cfg.scale > 0 and cfg.scale or self.defaultScale
    self.currentFrameFormat = cfg.frameFormat or self.defaultFrameFormat
    self.currentRingSize = cfg.ringSize and cfg.ringSize > 0 and cfg.ringSize or self.defaultRingSize

    local ctx = self.ctx
    ctx.recording.status = "countdown"
    ctx.recording.path = self.outputPath
    ctx.recording.logPath = self.logPath
    ctx.recording.startedAt = 0
    ctx.recording.duration = cfg.seconds or 0
    ctx.recording.countdown = cfg.countdown or self.defaultCountdown
    ctx.recording.stopOnDebugOpen = cfg.stopOnDebugOpen == true
    ctx.recording.stopReason = ""
    ctx.recording.error = ""
    ctx.recording.name = name
    ctx.recording.backend = "frames"
    ctx.recording.ffmpegPath = self.ffmpegPath
    LOGGER:info("recording armed path=%s countdown=%.3f duration=%.3f fps=%d scale=%.3f log=%s",
        self.outputPath, ctx.recording.countdown, ctx.recording.duration, self.currentFps,
        self.currentScale, self.logPath)
    if ctx.recording.countdown <= 0 then
        ctx.recording.countdown = 0
        local ok, err = launchCapture(self)
        if not ok then
            fail(self, err)
            return result(self, false, err)
        end
        ctx.recording.status = "recording"
        ctx.recording.startedAt = love.timer.getTime()
        return result(self, true, "recording started: " .. self.outputPath)
    end
    return result(self, true, "recording starts in " .. tostring(math.ceil(ctx.recording.countdown)) .. "s")
end

function recording.Controller:stop(reason?: string): recording.Result
    local status = self.ctx.recording.status
    if status == "countdown" then
        return self:cancel()
    end
    if status == "stopping" then
        LOGGER:info("recording stop already pending reason=%s path=%s",
            self.ctx.recording.stopReason, self.outputPath)
        return result(self, true, "stopping recording")
    end
    if status ~= "recording" then
        LOGGER:warn("recording stop ignored status=%s", status)
        return result(self, false, "no active recording")
    end
    -- No live capture process to interrupt: the worker keeps flushing queued
    -- frames, then update() runs the assembly pass.
    self.recordedElapsed = love.timer.getTime() - self.ctx.recording.startedAt
    self.ctx.recording.status = "stopping"
    self.ctx.recording.stopReason = reason or "manual"
    LOGGER:info("stopping recording reason=%s path=%s frames=%d", self.ctx.recording.stopReason,
        self.outputPath, self.encoder and self.encoder.written or 0)
    return result(self, true, "stopping recording")
end

function recording.Controller:cancel(): recording.Result
    local status = self.ctx.recording.status
    if status ~= "countdown" and status ~= "preparing" then
        LOGGER:warn("recording cancel ignored status=%s", status)
        return result(self, false, "no armed recording")
    end
    LOGGER:info("recording cancelled path=%s", self.outputPath)
    resetState(self.ctx)
    return result(self, true, "recording cancelled")
end

function recording.Controller:stopForDebugOpen(): recording.Result
    if self.ctx.recording.status == "recording" and self.ctx.recording.stopOnDebugOpen then
        return self:stop("debug_reopened")
    end
    return result(self, true, "no recording to stop")
end

function recording.Controller:shutdown()
    local status = self.ctx.recording.status
    if status == "countdown" then
        LOGGER:info("shutting down with armed recording; cancelling path=%s", self.outputPath)
        self:cancel()
        return
    end
    if status ~= "recording" and status ~= "stopping" then
        return
    end
    LOGGER:warn("shutting down with active recording; discarding path=%s", self.outputPath)
    if self.encoder then
        self.encoder:shutdown()
        self.encoder = nil
    end
    if self.processPid > 0 and processRunning(self.processPid) then
        signalProcess(self.processPid, "KILL")
    end
    self.processPid = 0
    cleanupFrames(self)
    cleanupPidFile(self)
    self.ctx.recording.status = "failed"
    self.ctx.recording.stopReason = "shutdown"
    self.ctx.recording.error = "recording aborted at shutdown"
end

-- Capture one frame if the fps interval has elapsed and the ring has room. The
-- screenshot resolves at end of frame (present); its callback hands the finished
-- ImageData to the worker. Called every frame from a render-phase system.
function recording.Controller:captureFrame()
    -- Cleared every frame; set true only on frames that schedule a screenshot,
    -- so overlays can draw themselves exclusively on non-captured frames and
    -- stay out of the recording.
    self.capturedThisFrame = false
    if self.ctx.recording.status ~= "recording" then return end
    local enc = self.encoder
    if not enc then return end
    local now = love.timer.getTime()
    local interval = self.currentFps > 0 and (1.0 / self.currentFps) or 0.0
    if now - self.lastCaptureAt < interval then return end
    self.lastCaptureAt = now
    if enc.inFlight >= enc.ringSize then
        enc.dropped = enc.dropped + 1
        return
    end
    self.capturedThisFrame = true
    love.graphics.captureScreenshot(function(img: love.image.ImageData)
        enc:submit(img)
    end)
end

function recording.Controller:update(dt: number)
    local ctx = self.ctx
    if ctx.recording.status == "countdown" then
        ctx.recording.countdown = math.max(0, ctx.recording.countdown - dt)
        if ctx.recording.countdown <= 0 then
            local ok, err = launchCapture(self)
            if not ok then
                fail(self, err)
                return
            end
            ctx.recording.status = "recording"
            ctx.recording.startedAt = love.timer.getTime()
            ctx.message = "recording: " .. self.outputPath
        else
            ctx.message = "recording in " .. tostring(math.ceil(ctx.recording.countdown)) .. "..."
        end
        return
    end

    local enc = self.encoder
    if enc then enc:drain() end

    -- A worker-side encode failure leaves a hole in the frame_%06d sequence,
    -- which would silently truncate the assembled video at the gap. Fail the
    -- recording explicitly instead.
    if enc and enc.error ~= "" and
        (ctx.recording.status == "recording" or ctx.recording.status == "stopping") then
        enc:shutdown()
        self.encoder = nil
        fail(self, "frame encoding failed: " .. enc.error)
        return
    end

    if ctx.recording.status == "recording" then
        local elapsed = love.timer.getTime() - ctx.recording.startedAt
        if ctx.recording.duration > 0 and elapsed >= ctx.recording.duration then
            self.recordedElapsed = elapsed
            ctx.recording.status = "stopping"
            ctx.recording.stopReason = "timeout"
            LOGGER:info("recording reached timeout path=%s frames=%d", self.outputPath,
                enc and enc.written or 0)
        end
        return
    end

    if ctx.recording.status ~= "stopping" then return end

    -- Wait for the worker to flush every queued frame before assembling.
    if enc and not enc:isDone() then
        if not enc.finishing then enc:finish() end
        ctx.message = "recording: flushing frames " ..
            tostring(enc.written) .. "/" .. tostring(enc.nextIndex)
        return
    end
    if not self.assembleLaunched then
        if not enc or enc.written <= 0 then
            fail(self, "no frames captured")
            return
        end
        local ok, err = launchAssemble(self)
        if not ok then
            fail(self, err)
            return
        end
        self.assembleLaunched = true
        ctx.message = "recording: encoding video"
        return
    end
    if self.processPid <= 0 or not processRunning(self.processPid) then
        complete(self, ctx.recording.stopReason ~= "" and ctx.recording.stopReason or "manual")
    end
end

function recording.Controller:open(name?: string): recording.Result
    local path = name
    if not path or path == "" or path == "latest" then
        local last = self.ctx.recordings[#self.ctx.recordings]
        path = last and last.path or self.ctx.recording.path
    end
    if not path or path == "" then
        LOGGER:warn("recording open ignored: no recording to open")
        return result(self, false, "no recording to open")
    end
    if not fileExists(path) then
        local msg = "recording file does not exist: " .. path .. " (log " .. self.ctx.recording.logPath .. ")"
        LOGGER:error("%s", msg)
        return result(self, false, msg)
    end
    local ok, detail = osopen.open(absSavePath(path))
    if not ok then
        LOGGER:error("recording open failed path=%s error=%s", path, detail)
        return result(self, false, "failed to open " .. path .. ": " .. detail)
    end
    LOGGER:info("opened recording path=%s", path)
    return result(self, true, "opening " .. path)
end

function recording.Controller:list(): recording.Result
    return result(self, true, tostring(#self.ctx.recordings) .. " recording(s)")
end

function recording.Controller:status(): recording.Result
    return result(self, true, self.ctx.recording.status)
end

return recording
