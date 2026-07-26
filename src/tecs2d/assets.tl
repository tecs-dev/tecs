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

local ffi <const> = require("ffi")
local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")
local workers <const> = require("tecs2d.workers")
local Texture <const> = require("tecs2d.gpu.Texture")

local C <const> = sdl.C

--- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM, which every decode is converted to
--- so the upload path has one layout to handle.
local RGBA8 <const> = 4

--- Runs on the worker. Decodes to RGBA and returns the surface address.
local DECODER <const> = [==[
local sdl = require("tecs2d.ffi.sdl3")
local image = require("tecs2d.ffi.sdl3image")
local workers = require("tecs2d.workers")

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
            })
        end
    end
end
]==]

local record Handle
    --- "loading", "ready", or "failed".
    status: string
    path: string
    --- Set once loading succeeds.
    texture: Texture
    --- Set if loading failed.
    error: string
end

local record assets
    Handle: Handle
end

local pending: {integer: Handle} = {}
local nextId = 1
local worker: workers.Worker = nil
local device: loader.CPtr = nil

--- Starts the loading worker.
function assets.install(gpuDevice: loader.CPtr, luaPath?: string)
    device = gpuDevice
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

    local handle: Handle = { status = "loading", path = path }
    local id = nextId
    nextId = nextId + 1
    pending[id] = handle
    worker:send({ id = id, path = path })
    return handle
end

--- Resolves one decode result into its handle.
---
--- Uploading here rather than on the worker is not a limitation to route
--- around: GPU resource creation belongs to the thread that owns the device.
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

    local surface = ffi.cast("SDL_Surface *",
        ffi.cast("uintptr_t", result.surface)) as loader.CValue
    local width = result.width as integer
    local height = result.height as integer

    local texture = Texture.create(device, {
        width = width,
        height = height,
        format = RGBA8,
        usage = { "sampled" },
    })
    texture:upload(surface.pixels as loader.CValue, width * height * 4)

    -- Ownership arrived with the address, so it is released here.
    C.SDL_DestroySurface(surface)

    handle.texture = texture
    handle.status = "ready"
    return true
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
