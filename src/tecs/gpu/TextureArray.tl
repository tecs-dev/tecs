--- A 2D array texture: many images, one binding.
---
--- This exists to collapse draws. Binding samplers per pipeline means one
--- texture is one draw, so a scene with fifty images would be fifty draws and
--- the instance buffer would have to be sorted by texture to make them
--- contiguous. An array turns the texture into a per-instance integer, which
--- gives back both the single draw and the freedom to lay instances out in
--- whatever order suits the producer.
---
--- Every layer shares one size and format, which is the constraint arrays
--- carry. Images smaller than a cell are placed at its origin and their UV
--- range reports the fraction they occupy, so callers see the sub-rect rather
--- than having to know the padding is there.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K

--- SDL_GPU_TEXTURETYPE_2D_ARRAY
local TYPE_2D_ARRAY <const> = 1

--- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local RGBA8 <const> = 4



local record TextureArrayOptions
    --- Cell size in pixels. Every image must fit within it, and every layer
    --- costs this much whatever the image put in it is.
    width: integer
    height: integer
    --- Layers to allocate, all of them up front. The device decides how many
    --- an array may have, so a count past what it allows fails at creation
    --- rather than at the layer that crosses the line.
    layers: integer
end

local record TextureArray
    --- Where one image landed, and how to sample it back out.
    record Region
        --- Layer this image occupies, zero-based: the index a shader passes to
        --- the third component of an array sampler's coordinate.
        layer: integer
        --- Fraction of the cell the image covers, from its origin. UVs run
        --- from zero to these, and they are below one for any image smaller
        --- than the cell.
        u1: number
        v1: number
        --- Size in pixels as uploaded, for a caller that needs the image's own
        --- dimensions rather than its share of the cell.
        width: integer
        height: integer
    end

    --- The `SDL_GPUTexture`, of type 2D array. Nil once `destroy` has run.
    handle: loader.CPtr
    --- Cell size in pixels, shared by every layer.
    width: integer
    height: integer
    --- Layers allocated.
    layers: integer
    --- Layers handed out so far, and the index the next `add` takes. Layers
    --- are never reclaimed: an image uploaded is resident until the whole
    --- array is destroyed.
    used: integer
    _device: loader.CPtr
    --- Upload staging, kept between calls and grown when an image needs more
    --- than the last one did. Never shrunk, since the largest image is the one
    --- that decides the cost either way.
    _transfer: loader.CPtr
    _transferSize: integer
    _destroyed: boolean
end

local TextureArrayMT <const>: metatable<TextureArray> = { __index = TextureArray }

--- Creates an array with `layers` cells of the given size.
---
--- RGBA8 and sampler usage, neither of which is an option: the point is one
--- binding for every image, and a second format would be a second binding.
function TextureArray.create(device: loader.CPtr,
                             options: TextureArrayOptions): TextureArray
    local info = loader.newArray("SDL_GPUTextureCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.type = TYPE_2D_ARRAY
    settings.format = RGBA8
    settings.usage = K.SDL_GPU_TEXTUREUSAGE_SAMPLER
    settings.width = options.width
    settings.height = options.height
    settings.layer_count_or_depth = options.layers
    settings.num_levels = 1
    settings.sample_count = 0
    settings.props = 0

    local handle = C.SDL_CreateGPUTexture(device, info)
    if handle == nil then sdl.fail("SDL_CreateGPUTexture") end

    local self = setmetatable({} as TextureArray, TextureArrayMT)
    self.handle = handle
    self.width = options.width
    self.height = options.height
    self.layers = options.layers
    self.used = 0
    self._device = device
    self._transferSize = 0
    self._destroyed = false
    return self
end

local function ensureTransfer(self: TextureArray, byteCount: integer)
    if self._transfer ~= nil and self._transferSize >= byteCount then return end
    if self._transfer ~= nil then
        C.SDL_ReleaseGPUTransferBuffer(self._device, self._transfer)
    end
    local info = loader.newArray("SDL_GPUTransferBufferCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.usage = C.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD
    settings.size = byteCount
    settings.props = 0
    self._transfer = C.SDL_CreateGPUTransferBuffer(self._device, info)
    if self._transfer == nil then sdl.fail("SDL_CreateGPUTransferBuffer") end
    self._transferSize = byteCount
end

--- Uploads RGBA pixels into the next free layer.
---
--- Submits its own command buffer, so this is a load-time path: an asset
--- arrives once, not once per frame.
---
--- Raises when the array is full or the image is larger than a cell. Both are
--- authoring mistakes with no useful runtime answer, and a silently dropped
--- image would surface as a sprite sampling whatever occupies layer zero.
--- @param pitch The source's row stride in bytes, which is not always
---     `width * 4`: a decoder is free to pad rows, and copying as though it
---     never does shears the image.
--- @return Where the image landed, which the caller keeps: nothing here maps
---     an image back to its region.
function TextureArray:add(pixels: loader.CValue, width: integer,
                          height: integer, pitch: integer): TextureArray.Region
    if self.used >= self.layers then
        error(("tecs: texture array is full at %d layers"):format(self.layers), 2)
    end
    if width > self.width or height > self.height then
        error(("tecs: image %dx%d exceeds the %dx%d cell")
            :format(width, height, self.width, self.height), 2)
    end

    local rowBytes = width * 4
    local byteCount = rowBytes * height
    ensureTransfer(self, byteCount)

    local mapped = C.SDL_MapGPUTransferBuffer(self._device, self._transfer, true)
    if mapped == nil then sdl.fail("SDL_MapGPUTransferBuffer") end

    -- Repacked row by row so the upload sees tightly packed data regardless
    -- of what stride the source used.
    local source = loader.bytePointer(pixels)
    local destination = loader.bytePointer(mapped as loader.CValue)
    for row = 0, height - 1 do
        loader.copyTo(destination + row * rowBytes,
            (source + row * pitch) as loader.CValue, rowBytes)
    end
    C.SDL_UnmapGPUTransferBuffer(self._device, self._transfer)

    local layer = self.used
    self.used = layer + 1

    local commandBuffer = C.SDL_AcquireGPUCommandBuffer(self._device)
    if commandBuffer == nil then sdl.fail("SDL_AcquireGPUCommandBuffer") end
    local copyPass = C.SDL_BeginGPUCopyPass(commandBuffer)

    local from = loader.newArray("SDL_GPUTextureTransferInfo[1]")
    local sourceInfo = from[0] as loader.CStruct
    sourceInfo.transfer_buffer = self._transfer
    sourceInfo.offset = 0
    sourceInfo.pixels_per_row = width
    sourceInfo.rows_per_layer = height

    local to = loader.newArray("SDL_GPUTextureRegion[1]")
    local region = to[0] as loader.CStruct
    region.texture = self.handle
    region.mip_level = 0
    region.layer = layer
    region.x, region.y, region.z = 0, 0, 0
    region.w, region.h, region.d = width, height, 1

    C.SDL_UploadToGPUTexture(copyPass, from, to, false)
    C.SDL_EndGPUCopyPass(copyPass)
    sdl.check(C.SDL_SubmitGPUCommandBuffer(commandBuffer) as boolean,
        "SDL_SubmitGPUCommandBuffer")

    return {
        layer = layer,
        u1 = width / self.width,
        v1 = height / self.height,
        width = width,
        height = height,
    }
end

--- Releases the array. Safe to call more than once.
function TextureArray:destroy()
    if self._destroyed then return end
    self._destroyed = true
    if self._transfer ~= nil then
        C.SDL_ReleaseGPUTransferBuffer(self._device, self._transfer)
        self._transfer = nil
    end
    C.SDL_ReleaseGPUTexture(self._device, self.handle)
    self.handle = nil
end

return TextureArray
