--- Asynchronous asset loading.
---
--- Decoding a PNG is milliseconds of pure CPU work with no GPU involvement,
--- so it happens on a worker and the main thread only uploads. A load never
--- blocks a frame; a handle reports that it is still loading and callers draw
--- something else until it is not.
---
--- The worker hands back the address of an `SDL_Surface` rather than the
--- pixels themselves. Surfaces live in process memory, so the pointer is
--- valid in either state, and passing it avoids copying a decoded image
--- through a serialized message only to copy it again into staging. Ownership
--- transfers with it: whoever receives the address destroys the surface.
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

--- Runs on the worker. Decodes to RGBA and returns the surface address.
local DECODER <const> = [==[
local sdl = require("tecs.ffi.sdl3")
local image = require("tecs.ffi.sdl3image")
local workers = require("tecs.workers")

local C = sdl.C
local IMG = image.C

-- SDL_PIXELFORMAT_RGBA32 is a byte-order alias resolved by the preprocessor,
-- so it never reaches the cdef. On a little-endian host it is ABGR8888.
local RGBA32 = C.SDL_PIXELFORMAT_ABGR8888

local self = workers.current()

while true do
    local task = self:receive()
    if task == nil then break end

    local surface = IMG.IMG_Load(task.path)
    if surface == nil then
        self:send({ id = task.id, error = "cannot decode " .. task.path })
    else
        -- Normalising here means the upload path handles exactly one layout,
        -- and the conversion cost lands off the main thread with the decode.
        local converted = C.SDL_ConvertSurface(surface, RGBA32)
        C.SDL_DestroySurface(surface)
        if converted == nil then
            self:send({ id = task.id, error = "cannot convert " .. task.path })
        else
            self:send({
                id = task.id,
                surface = tonumber(require("ffi").cast("uintptr_t", converted)),
                width = converted.w,
                height = converted.h,
                pitch = converted.pitch,
            })
        end
    end
end
]==]

local record Handle
    --- "loading", "ready", or "failed".
    status: string
    path: string
    --- Decoded RGBA pixels, valid until `release`.
    pixels: loader.CValue
    width: integer
    height: integer
    --- Row stride in bytes, which a decoder may pad beyond width * 4.
    pitch: integer
    --- Set if loading failed.
    error: string
    _surface: loader.CValue
end

local record assets
    Handle: Handle
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

--- Queues an image for loading and returns its handle immediately.
function assets.loadImage(path: string): Handle
    if worker == nil then
        error("tecs2d: assets.install must run before loading", 2)
    end

    local handle = setmetatable({ status = "loading", path = path } as Handle,
        HandleMT)
    local id = nextId
    nextId = nextId + 1
    pending[id] = handle
    worker:send({ id = id, path = path })
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

--- Frees the decoded pixels.
---
--- Called once whatever needed them has taken a copy, which for an image
--- means after it has been uploaded.
function Handle:release()
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
