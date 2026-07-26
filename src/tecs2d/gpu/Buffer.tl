--- A GPU buffer.
---
--- The renderer is SSBO-driven, so this is the primary way data reaches the
--- GPU: instance data, draw arguments, and anything a compute pass produces.
---
--- Uploads take an explicit byte range rather than replacing the whole buffer,
--- because the engine above is dirty-gated and most frames change very little
--- of what is resident.

local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K

local record BufferOptions
    --- Any of "storage", "indirect", "vertex", "index", "computeWrite".
    --- A buffer written by compute and then drawn from needs both "indirect"
    --- and "computeWrite".
    usage: {string}
    --- Size in bytes.
    size: integer
    name: string
end

local record Buffer
    handle: loader.CPtr
    size: integer
    _device: loader.CPtr
    _transfer: loader.CPtr
    _transferSize: integer
    _destroyed: boolean
end

local BufferMT <const>: metatable<Buffer> = { __index = Buffer }

local USAGE_FLAGS <const>: {string: integer} = {
    vertex = K.SDL_GPU_BUFFERUSAGE_VERTEX,
    index = K.SDL_GPU_BUFFERUSAGE_INDEX,
    indirect = K.SDL_GPU_BUFFERUSAGE_INDIRECT,
    storage = K.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
    computeRead = K.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ,
    computeWrite = K.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE,
}

--- Creates a buffer.
function Buffer.create(device: loader.CPtr, options: BufferOptions): Buffer
    local flags = 0
    for _, name in ipairs(options.usage or { "storage" }) do
        local flag = USAGE_FLAGS[name]
        if flag == nil then
            error(("tecs2d: unknown buffer usage '%s'"):format(tostring(name)), 2)
        end
        flags = flags + flag
    end

    local info = loader.newArray("SDL_GPUBufferCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.usage = flags
    settings.size = options.size
    settings.props = 0

    local handle = C.SDL_CreateGPUBuffer(device, info)
    if handle == nil then sdl.fail("SDL_CreateGPUBuffer") end

    local self = setmetatable({} as Buffer, BufferMT)
    self.handle = handle
    self.size = options.size
    self._device = device
    self._transferSize = 0
    self._destroyed = false
    return self
end

--- Ensures a staging buffer of at least `size` bytes exists.
local function ensureTransfer(self: Buffer, size: integer)
    if self._transfer ~= nil and self._transferSize >= size then return end
    if self._transfer ~= nil then
        C.SDL_ReleaseGPUTransferBuffer(self._device, self._transfer)
    end
    local info = loader.newArray("SDL_GPUTransferBufferCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.usage = C.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD
    settings.size = size
    settings.props = 0
    self._transfer = C.SDL_CreateGPUTransferBuffer(self._device, info)
    if self._transfer == nil then sdl.fail("SDL_CreateGPUTransferBuffer") end
    self._transferSize = size
end

--- Uploads `byteCount` bytes from `source` into the buffer at `offset`.
---
--- Submits its own command buffer, so this is a setup and test path. Per-frame
--- uploads belong on the frame's command buffer.
function Buffer:upload(source: loader.CArray, byteCount: integer, offset?: integer)
    offset = offset or 0
    ensureTransfer(self, byteCount)

    local mapped = C.SDL_MapGPUTransferBuffer(self._device, self._transfer, false)
    if mapped == nil then sdl.fail("SDL_MapGPUTransferBuffer") end
    loader.copyBytes(mapped as loader.CArray, source as loader.CValue, byteCount)
    C.SDL_UnmapGPUTransferBuffer(self._device, self._transfer)

    local commandBuffer = C.SDL_AcquireGPUCommandBuffer(self._device)
    if commandBuffer == nil then sdl.fail("SDL_AcquireGPUCommandBuffer") end
    local copyPass = C.SDL_BeginGPUCopyPass(commandBuffer)

    local from = loader.newArray("SDL_GPUTransferBufferLocation[1]")
    local sourceLocation = from[0] as loader.CStruct
    sourceLocation.transfer_buffer = self._transfer
    sourceLocation.offset = 0

    local to = loader.newArray("SDL_GPUBufferRegion[1]")
    local destination = to[0] as loader.CStruct
    destination.buffer = self.handle
    destination.offset = offset
    destination.size = byteCount

    C.SDL_UploadToGPUBuffer(copyPass, from, to, false)
    C.SDL_EndGPUCopyPass(copyPass)
    sdl.check(C.SDL_SubmitGPUCommandBuffer(commandBuffer) as boolean,
        "SDL_SubmitGPUCommandBuffer")
end

--- Releases the buffer and any staging buffer. Safe to call more than once.
function Buffer:destroy()
    if self._destroyed then return end
    self._destroyed = true
    if self._transfer ~= nil then
        C.SDL_ReleaseGPUTransferBuffer(self._device, self._transfer)
        self._transfer = nil
    end
    C.SDL_ReleaseGPUBuffer(self._device, self.handle)
    self.handle = nil
end

return Buffer
