--- Asynchronous asset loading.
---
--- Decoding a PNG is milliseconds of pure CPU work with no GPU involvement,
--- so it happens on a worker and the main thread only uploads. A load never
--- blocks a frame; a handle reports that it is still loading and callers draw
--- something else until it is not. Sound takes the same route for the same
--- reason: reading a file is a syscall a frame should not wait on.
---
--- The worker hands back the address of an `SDL_Surface` rather than the
--- pixels themselves. Surfaces live in process memory, so the pointer is
--- valid in either state, and passing it avoids copying a decoded image
--- through a serialized message only to copy it again into staging. Ownership
--- transfers with it: whoever receives the address destroys the surface. A
--- loaded sound crosses the same way, as the address of its `MIX_Audio`.
---
--- Nothing here creates a GPU resource. Decoding and residency are separate
--- decisions: the renderer knows what layout its textures need, and an asset
--- that has been decoded is useful before anything has decided where it will
--- live.

local ffi <const> = require("ffi")
local sdl <const> = require("tecs.ffi.sdl3")
local sdl3mixer <const> = require("tecs.ffi.sdl3mixer")
local loader <const> = require("tecs.ffi.loader")
local workers <const> = require("tecs.workers")

local C <const> = sdl.C
local MIX <const> = sdl3mixer.C

--- Runs on the worker. Decodes to a normalised layout and returns an address.
local DECODER <const> = [==[
local ffi = require("ffi")
local sdl = require("tecs.ffi.sdl3")
local image = require("tecs.ffi.sdl3image")
local mixer = require("tecs.ffi.sdl3mixer")
local workers = require("tecs.workers")

local C = sdl.C
local IMG = image.C
local MIX = mixer.C

-- SDL_PIXELFORMAT_RGBA32 is a byte-order alias resolved by the preprocessor,
-- so it never reaches the cdef. On a little-endian host it is ABGR8888.
local RGBA32 = C.SDL_PIXELFORMAT_ABGR8888

local self = workers.current()

local function decodeImage(task)
    local surface = IMG.IMG_Load(task.path)
    if surface == nil then
        return { id = task.id, error = "cannot decode " .. task.path }
    end

    -- Normalising here means the upload path handles exactly one layout,
    -- and the conversion cost lands off the main thread with the decode.
    local converted = C.SDL_ConvertSurface(surface, RGBA32)
    C.SDL_DestroySurface(surface)
    if converted == nil then
        return { id = task.id, error = "cannot convert " .. task.path }
    end
    return {
        id = task.id,
        surface = tonumber(ffi.cast("uintptr_t", converted)),
        width = converted.w,
        height = converted.h,
        pitch = converted.pitch,
    }
end

-- Length in milliseconds, or -1 when the container cannot say. A format that
-- only stores a bit rate is estimated from it, and one that streams forever
-- reports infinite; both are "unknown" as far as anything above cares.
local function durationOf(audio)
    local frames = MIX.MIX_GetAudioDuration(audio)
    if frames < 0 then return -1 end
    return tonumber(MIX.MIX_AudioFramesToMS(audio, frames))
end

-- Sound is read by the mixer's own decoders, which is what makes anything but
-- WAV loadable. No mixer is passed: a clip is independent of the output, so
-- loading works before one is open and on a machine that has none, and the
-- mixer converts what it reads either way.
--
-- `mode` decides whether the clip ends up resident:
--   "resident"  decoded once, up front, and held as PCM
--   "stream"    nothing held; each voice opens the file for itself
--   "auto"      resident under `streamMs`, streamed at or over it
--
-- The auto case reads the file twice when it turns out to be short: once
-- without decoding, to ask how long it is, and once to decode it. That is a
-- second read of a small file, off the main thread, against holding a decoded
-- copy of a piece of music.
local function decodeSound(task)
    local predecode = task.mode == "resident"
    local audio = MIX.MIX_LoadAudio(nil, task.path, predecode)
    if audio == nil then
        return { id = task.id, error = "cannot load " .. task.path }
    end

    local ms = durationOf(audio)
    if task.mode == "resident" then
        return {
            id = task.id, resident = true, durationMs = ms,
            audio = tonumber(ffi.cast("uintptr_t", audio)),
        }
    end

    if task.mode == "auto" and ms >= 0 and ms < task.streamMs then
        MIX.MIX_DestroyAudio(audio)
        audio = MIX.MIX_LoadAudio(nil, task.path, true)
        if audio == nil then
            return { id = task.id, error = "cannot decode " .. task.path }
        end
        return {
            id = task.id, resident = true, durationMs = ms,
            audio = tonumber(ffi.cast("uintptr_t", audio)),
        }
    end

    MIX.MIX_DestroyAudio(audio)
    return { id = task.id, resident = false, durationMs = ms }
end

while true do
    local task = self:receive()
    if task == nil then break end
    if task.kind == "sound" then
        self:send(decodeSound(task))
    else
        self:send(decodeImage(task))
    end
end
]==]

local record Handle
    --- What was asked for: "image" or "sound".
    kind: string
    --- "loading", "ready", or "failed".
    status: string
    path: string
    --- Decoded RGBA pixels, valid until `release`. Images only.
    pixels: loader.CValue
    width: integer
    height: integer
    --- Row stride in bytes, which a decoder may pad beyond width * 4.
    pitch: integer
    --- The loaded clip, valid until `release`. Sounds only, and nil for one
    --- that streams, which holds nothing.
    audio: loader.CValue
    --- Whether the clip is held in memory. Sounds only.
    resident: boolean
    --- Length in milliseconds, or -1 when the file cannot say. Sounds only.
    durationMs: integer
    --- Set if loading failed.
    error: string
    _surface: loader.CValue
end

local record assets
    Handle: Handle

    --- Whether the loading worker is running.
    installed: function(): boolean
end

local HandleMT <const>: metatable<Handle> = { __index = Handle }

local pending: {integer: Handle} = {}
local nextId = 1
local worker: workers.Worker = nil

--- Starts the loading worker.
function assets.install(luaPath?: string)
    worker = workers.spawn({
        source = DECODER,
        luaPath = luaPath or package.path,
    })
end

--- Whether the loading worker is running.
---
--- For a subsystem that loads an asset of its own and has no way of knowing
--- whether the game has started the worker yet.
function assets.installed(): boolean
    return worker ~= nil
end

--- Registers a handle and returns the id the worker will answer with.
local function queue(handle: Handle): integer
    if worker == nil then
        error("tecs: assets.install must run before loading", 3)
    end
    local id = nextId
    nextId = nextId + 1
    pending[id] = handle
    return id
end

--- Queues an image for loading and returns its handle immediately.
function assets.loadImage(path: string): Handle
    local handle = setmetatable(
        { kind = "image", status = "loading", path = path } as Handle, HandleMT)
    local id = queue(handle)
    worker:send({ id = id, kind = "image", path = path })
    return handle
end

--- Queues a sound for loading and returns its handle immediately.
---
--- Whatever the mixer's decoders can read loads, so the format is the file's
--- business rather than the caller's.
---
--- `mode` is "resident", "stream", or "auto", and auto keeps anything shorter
--- than `streamMs` resident.
---
--- The library is initialised here rather than on the worker: `MIX_Init` is
--- documented as not thread safe, and doing it before the task is sent puts it
--- in order ahead of every decode without a lock.
function assets.loadSound(path: string, mode: string,
                          streamMs: integer): Handle
    if not sdl3mixer.init() then
        local failed = setmetatable({
            kind = "sound", status = "failed", path = path,
            error = "cannot load " .. path,
        } as Handle, HandleMT)
        return failed
    end
    local handle = setmetatable(
        { kind = "sound", status = "loading", path = path } as Handle, HandleMT)
    local id = queue(handle)
    worker:send({
        id = id, kind = "sound", path = path,
        mode = mode, streamMs = streamMs,
    })
    return handle
end

--- Resolves one decode result into its handle.
local function complete(result: {string: any}): boolean
    local id = result.id as integer
    local handle = pending[id]
    pending[id] = nil
    if handle == nil then return false end

    if result.error ~= nil then
        handle.status = "failed"
        handle.error = result.error as string
        return true
    end

    if handle.kind == "sound" then
        handle.resident = result.resident as boolean
        handle.durationMs = result.durationMs as integer
        if handle.resident then
            -- Ownership arrived with the address, exactly as it does for a
            -- surface. The mixer allocated this, so the mixer frees it.
            handle.audio = ffi.cast("MIX_Audio *",
                ffi.cast("uintptr_t", result.audio)) as loader.CValue
        end
        handle.status = "ready"
        return true
    end

    -- Ownership arrived with the address. The surface stays alive until the
    -- handle is released, because the pixels are what the caller came for.
    local surface = ffi.cast("SDL_Surface *",
        ffi.cast("uintptr_t", result.surface)) as loader.CValue
    handle._surface = surface
    handle.pixels = surface.pixels as loader.CValue
    handle.width = result.width as integer
    handle.height = result.height as integer
    handle.pitch = result.pitch as integer
    handle.status = "ready"
    return true
end

--- Frees what was decoded.
---
--- Called once whatever needed it has taken a copy, which for an image means
--- after it has been uploaded. A voice reads a clip where it lies, so a clip is
--- released when nothing will play it again. A track holds its own reference,
--- so releasing one that is still sounding is safe: the mixer drops it when
--- the last track using it does.
function Handle:release()
    if self.audio ~= nil then
        MIX.MIX_DestroyAudio(self.audio)
        self.audio = nil
        self.resident = false
    end
    if self._surface == nil then return end
    C.SDL_DestroySurface(self._surface)
    self._surface = nil
    self.pixels = nil
end

--- Takes finished decodes and uploads them. Call once per frame.
function assets.update(): integer
    if worker == nil then return 0 end
    local completed = 0
    while true do
        local result = worker:receive(0)
        if result == nil then break end
        if complete(result as {string: any}) then completed = completed + 1 end
    end
    return completed
end

--- Handles still waiting on the worker.
function assets.pending(): integer
    local count = 0
    for _ in pairs(pending) do count = count + 1 end
    return count
end

--- Blocks until every queued load has finished.
---
--- For startup and tests. A frame should poll `update` instead.
function assets.waitAll(timeoutMs?: number)
    local remaining = timeoutMs or 5000
    while assets.pending() > 0 and remaining > 0 do
        local result = worker:receive(16)
        if result ~= nil then complete(result as {string: any}) end
        remaining = remaining - 16
    end
end

--- Stops the loading worker.
function assets.shutdown()
    if worker == nil then return end
    worker:stop()
    worker = nil
    pending = {}
end

return assets
