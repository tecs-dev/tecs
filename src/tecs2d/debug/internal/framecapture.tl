--- Permission-free video-frame encoder.
---
--- Captures the game's own framebuffer via love.graphics.captureScreenshot
--- (no macOS Screen Recording / TCC permission required) and hands each frame to
--- a single worker thread that encodes it to a numbered image on disk. A later
--- ffmpeg pass assembles the sequence into a video.
---
--- Ownership: ImageData objects are passed to the worker over a love.thread
--- Channel, so ownership travels with the object. Never pass a raw
--- getFFIPointer across the thread boundary; the main thread may reuse or GC the
--- backing buffer before the worker reads it (use-after-free, torn frames).
---
--- Backpressure: at most `ringSize` frames may be in flight (submitted but not
--- yet written). When the worker cannot keep up the ring fills and further
--- frames are dropped and counted, rather than blocking the game loop. On-disk
--- indices stay contiguous from 0 because an index is only consumed by a frame
--- that is actually submitted, so ffmpeg's `frame_%06d` demux never hits a gap.
--- The exception is a worker-side encode failure: its index is already consumed,
--- so the sequence has a hole. The failure is reported through `error`, and the
--- recording controller fails the whole recording rather than assembling a
--- silently truncated video.

local record framecapture
    record Options
        dir: string          -- save-dir-relative directory for the frame images
        format: string       -- "png" (default) | "tga" | "jpg" | "bmp"
        ringSize: integer     -- max frames in flight before dropping (default 8)
        token: string        -- unique suffix so channels never cross recordings
    end

    record Encoder
        thread: love.thread.Thread
        frames: love.thread.Channel
        done: love.thread.Channel
        dir: string
        format: string
        ringSize: integer
        nextIndex: integer
        inFlight: integer
        written: integer
        dropped: integer
        finishing: boolean
        finished: boolean
        error: string

        --- Queue one frame. Returns false (and counts a drop) if the ring is
        --- full or the encoder is already finishing. Consumes a contiguous
        --- on-disk index only on success.
        submit: function(self: Encoder, img: love.image.ImageData): boolean
        --- Non-blocking: apply worker acknowledgements to the in-flight/written
        --- counters. Call once per frame.
        drain: function(self: Encoder)
        --- Signal end of stream. The worker flushes every queued frame before
        --- acknowledging, so call this after the last submit.
        finish: function(self: Encoder)
        --- True once the worker has flushed all frames and exited.
        isDone: function(self: Encoder): boolean
        --- ffmpeg input pattern relative to `dir`, e.g. "frame_%06d.png".
        pattern: function(self: Encoder): string
        --- Force the worker down (used on hard shutdown). Blocks briefly.
        shutdown: function(self: Encoder)
    end

    new: function(opts: Options): Encoder
end

-- Worker: pop frames, encode each to its numbered path, ack on the done
-- channel. A {stop=true} sentinel flushes and exits. Runs in its own Lua state,
-- so it only touches love.image / love.filesystem, never love.graphics.
local WORKER_SOURCE <const> = [[
local frameName, doneName = ...
require("love.image")
require("love.filesystem")
local frames = love.thread.getChannel(frameName)
local done = love.thread.getChannel(doneName)
local written = 0
while true do
    local msg = frames:demand()
    if type(msg) == "table" then
        if msg.stop then
            done:push({done = true, written = written})
            return
        end
        local img = msg.img
        local ok, err = pcall(img.encode, img, msg.fmt, msg.path)
        if ok then
            written = written + 1
            done:push({i = msg.i})
        else
            done:push({i = msg.i, err = tostring(err)})
        end
    end
end
]]

local function extFor(format: string): string
    if format == "jpg" then return "jpg" end
    if format == "tga" then return "tga" end
    if format == "bmp" then return "bmp" end
    return "png"
end

function framecapture.new(opts: framecapture.Options): framecapture.Encoder
    local format = opts.format or "png"
    local token = opts.token or "rec"
    local frameName = "tecs.rec.frames." .. token
    local doneName = "tecs.rec.done." .. token
    local frames = love.thread.getChannel(frameName)
    local done = love.thread.getChannel(doneName)
    -- Drop any stale messages left by an aborted prior run sharing this token.
    frames:clear()
    done:clear()

    love.filesystem.createDirectory(opts.dir)

    local thread = love.thread.newThread(WORKER_SOURCE)
    thread:start(frameName, doneName)

    local self: framecapture.Encoder = {
        thread = thread,
        frames = frames,
        done = done,
        dir = opts.dir,
        format = format,
        ringSize = opts.ringSize and opts.ringSize > 0 and opts.ringSize or 8,
        nextIndex = 0,
        inFlight = 0,
        written = 0,
        dropped = 0,
        finishing = false,
        finished = false,
        error = "",
    } as framecapture.Encoder
    setmetatable(self as {string: any}, {__index = framecapture.Encoder})
    return self
end

function framecapture.Encoder:submit(img: love.image.ImageData): boolean
    if self.finishing then return false end
    if self.inFlight >= self.ringSize then
        self.dropped = self.dropped + 1
        return false
    end
    local idx = self.nextIndex
    self.nextIndex = idx + 1
    local path = string.format("%s/frame_%06d.%s", self.dir, idx, extFor(self.format))
    self.frames:push({i = idx, img = img, fmt = self.format, path = path})
    self.inFlight = self.inFlight + 1
    return true
end

function framecapture.Encoder:drain()
    while true do
        local raw = self.done:pop()
        if raw == nil then return end
        local msg = raw as {string: any}
        if msg.done then
            self.finished = true
        elseif msg.err then
            self.inFlight = self.inFlight - 1
            self.error = msg.err as string
        else
            self.inFlight = self.inFlight - 1
            self.written = self.written + 1
        end
    end
end

function framecapture.Encoder:finish()
    if self.finishing then return end
    self.finishing = true
    self.frames:push({stop = true})
end

function framecapture.Encoder:isDone(): boolean
    return self.finished
end

function framecapture.Encoder:pattern(): string
    return string.format("%s/frame_%%06d.%s", self.dir, extFor(self.format))
end

function framecapture.Encoder:shutdown()
    if not self.finishing then
        self.finishing = true
        self.frames:push({stop = true})
    end
    self.thread:wait()
    self:drain()
end

return framecapture
