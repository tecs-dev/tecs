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
--- loaded sound crosses the same way, as the address of its PCM.
---
--- Nothing here creates a GPU resource. Decoding and residency are separate
--- decisions: the renderer knows what layout its textures need, and an asset
--- that has been decoded is useful before anything has decided where it will
--- live.

local ffi <const> = require("ffi")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local workers <const> = require("tecs.workers")

local C <const> = sdl.C

--- Runs on the worker. Decodes to a normalised layout and returns an address.
local DECODER <const> = [==[
local ffi = require("ffi")
local sdl = require("tecs.ffi.sdl3")
local image = require("tecs.ffi.sdl3image")
local workers = require("tecs.workers")

local C = sdl.C
local IMG = image.C

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

-- Loaded and converted in one step, for the same reason an image is: the
-- caller then holds exactly one layout, and every voice that plays this clip
-- resamples nothing.
local function decodeSound(task)
    local spec = ffi.new("SDL_AudioSpec")
    local data = ffi.new("uint8_t *[1]")
    local length = ffi.new("Uint32[1]")
    if not C.SDL_LoadWAV(task.path, spec, data, length) then
        return { id = task.id, error = "cannot load " .. task.path }
    end

    local want = ffi.new("SDL_AudioSpec")
    want.format = C.SDL_AUDIO_F32
    want.channels = task.channels
    want.freq = task.frequency

    local samples = ffi.new("uint8_t *[1]")
    local bytes = ffi.new("int[1]")
    local ok = C.SDL_ConvertAudioSamples(spec, data[0], length[0],
        want, samples, bytes)
    C.SDL_free(data[0])
    if not ok then
        return { id = task.id, error = "cannot convert " .. task.path }
    end
    return {
        id = task.id,
        samples = tonumber(ffi.cast("uintptr_t", samples[0])),
        bytes = bytes[0],
    }
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
    --- Interleaved 32-bit float PCM, valid until `release`. Sounds only.
    samples: loader.CValue
    --- Bytes at `samples`.
    bytes: integer
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

--- Queues a WAV for loading and returns its handle immediately.
---
--- The PCM comes back converted to 32-bit float at `frequency` and
--- `channels`, so whatever the file happened to hold is not something the
--- caller has to handle.
function assets.loadSound(path: string, frequency: integer,
                          channels: integer): Handle
    local handle = setmetatable(
        { kind = "sound", status = "loading", path = path } as Handle, HandleMT)
    local id = queue(handle)
    worker:send({
        id = id, kind = "sound", path = path,
        frequency = frequency, channels = channels,
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
        -- Ownership arrived with the address, exactly as it does for a
        -- surface. SDL allocated this buffer, so SDL_free releases it.
        handle.samples = ffi.cast("uint8_t *",
            ffi.cast("uintptr_t", result.samples)) as loader.CValue
        handle.bytes = result.bytes as integer
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
--- after it has been uploaded. A sound is played straight out of this memory,
--- so it is released when nothing will play it again.
function Handle:release()
    if self.samples ~= nil then
        C.SDL_free(self.samples)
        self.samples = nil
        self.bytes = 0
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
