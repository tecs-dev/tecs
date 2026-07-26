--- An offscreen colour target that can be rendered to and read back.
---
--- Readback exists so that rendering can be asserted on rather than eyeballed.
--- A draw that silently produces nothing (a mis-flattened binding, a pipeline
--- built against the wrong format) still runs at full frame rate, so "it did
--- not error" is not evidence that it drew.

local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K

-- Renderable and samplable. Taken from the generated constants rather than
-- written as literals: the usage bits are not in the order one would guess.
local USAGE_COLOR_TARGET <const> =
    K.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET + K.SDL_GPU_TEXTUREUSAGE_SAMPLER

local record Pixel
    r: integer
    g: integer
    b: integer
    a: integer
end

local record RenderTarget
    handle: loader.CPtr
    width: integer
    height: integer
    format: integer
    _device: loader.CPtr
    _transfer: loader.CPtr
    _destroyed: boolean
end

local RenderTargetMT <const>: metatable<RenderTarget> = { __index = RenderTarget }

--- Creates an offscreen colour target.
function RenderTarget.create(device: loader.CPtr, width: integer,
                             height: integer, format: integer): RenderTarget
    local info = loader.newArray("SDL_GPUTextureCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.type = 0                    -- SDL_GPU_TEXTURETYPE_2D
    settings.format = format
    settings.usage = USAGE_COLOR_TARGET
    settings.width = width
    settings.height = height
    settings.layer_count_or_depth = 1
    settings.num_levels = 1
    settings.sample_count = 0
    settings.props = 0

    local handle = C.SDL_CreateGPUTexture(device, info)
    if handle == nil then sdl.fail("SDL_CreateGPUTexture") end

    local self = setmetatable({} as RenderTarget, RenderTargetMT)
    self.handle = handle
    self.width = width
    self.height = height
    self.format = format
    self._device = device
    self._destroyed = false
    return self
end

--- Begins a render pass targeting this texture.
---
--- Mirrors `Frame:beginRenderPass`, taking the frame explicitly rather than
--- reaching for device state.
function RenderTarget:beginRenderPass(frame: loader.CValue,
                                      clear: {string: number}): loader.CValue
    local targets = loader.newArray("SDL_GPUColorTargetInfo[1]")
    local target = targets[0] as loader.CStruct
    target.texture = self.handle
    target.mip_level = 0
    target.layer_or_depth_plane = 0
    target.resolve_texture = nil
    target.cycle = false
    target.cycle_resolve_texture = false
    target.store_op = C.SDL_GPU_STOREOP_STORE

    if clear ~= nil then
        target.load_op = C.SDL_GPU_LOADOP_CLEAR
        local color = target.clear_color as loader.CStruct
        color.r = clear.r or 0.0
        color.g = clear.g or 0.0
        color.b = clear.b or 0.0
        color.a = clear.a or 1.0
    else
        target.load_op = C.SDL_GPU_LOADOP_LOAD
    end

    local handle = C.SDL_BeginGPURenderPass(frame, targets, 1, nil)
    if handle == nil then sdl.fail("SDL_BeginGPURenderPass") end
    return handle as loader.CValue
end

--- Copies the texture into a mapped transfer buffer and returns the pixels.
---
--- Blocks until the GPU has finished, so this is a diagnostic and test path,
--- not something a frame should call.
function RenderTarget:readback(): loader.CArray
    local byteCount = self.width * self.height * 4

    if self._transfer == nil then
        local info = loader.newArray("SDL_GPUTransferBufferCreateInfo[1]")
        local settings = info[0] as loader.CStruct
        settings.usage = C.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD
        settings.size = byteCount
        settings.props = 0
        self._transfer = C.SDL_CreateGPUTransferBuffer(self._device, info)
        if self._transfer == nil then sdl.fail("SDL_CreateGPUTransferBuffer") end
    end

    local commandBuffer = C.SDL_AcquireGPUCommandBuffer(self._device)
    if commandBuffer == nil then sdl.fail("SDL_AcquireGPUCommandBuffer") end

    local copyPass = C.SDL_BeginGPUCopyPass(commandBuffer)

    local region = loader.newArray("SDL_GPUTextureRegion[1]")
    local source = region[0] as loader.CStruct
    source.texture = self.handle
    source.mip_level = 0
    source.layer = 0
    source.x = 0
    source.y = 0
    source.z = 0
    source.w = self.width
    source.h = self.height
    source.d = 1

    local destination = loader.newArray("SDL_GPUTextureTransferInfo[1]")
    local sink = destination[0] as loader.CStruct
    sink.transfer_buffer = self._transfer
    sink.offset = 0
    sink.pixels_per_row = self.width
    sink.rows_per_layer = self.height

    C.SDL_DownloadFromGPUTexture(copyPass, region, destination)
    C.SDL_EndGPUCopyPass(copyPass)

    local fence = C.SDL_SubmitGPUCommandBufferAndAcquireFence(commandBuffer)
    if fence == nil then sdl.fail("SDL_SubmitGPUCommandBufferAndAcquireFence") end
    local fences = loader.newArray("SDL_GPUFence*[1]")
    fences[0] = fence
    C.SDL_WaitForGPUFences(self._device, true, fences, 1)
    C.SDL_ReleaseGPUFence(self._device, fence)

    local mapped = C.SDL_MapGPUTransferBuffer(self._device, self._transfer, false)
    if mapped == nil then sdl.fail("SDL_MapGPUTransferBuffer") end

    local pixels = loader.newArray("uint8_t[?]", byteCount)
    loader.copyBytes(pixels, mapped as loader.CValue, byteCount)
    C.SDL_UnmapGPUTransferBuffer(self._device, self._transfer)

    return pixels
end

--- Reads one pixel out of a buffer returned by `readback`.
function RenderTarget:getPixel(pixels: loader.CArray, x: integer, y: integer): Pixel
    local offset = (y * self.width + x) * 4
    return {
        r = pixels[offset] as integer,
        g = pixels[offset + 1] as integer,
        b = pixels[offset + 2] as integer,
        a = pixels[offset + 3] as integer,
    }
end

--- Releases the texture and any transfer buffer. Safe to call more than once.
function RenderTarget:destroy()
    if self._destroyed then return end
    self._destroyed = true
    if self._transfer ~= nil then
        C.SDL_ReleaseGPUTransferBuffer(self._device, self._transfer)
        self._transfer = nil
    end
    C.SDL_ReleaseGPUTexture(self._device, self.handle)
    self.handle = nil
end

return RenderTarget
