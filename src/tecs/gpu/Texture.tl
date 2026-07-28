--- A GPU texture.
---
--- Usage is declared rather than assumed. SDL_GPU validates that a texture is
--- only used the ways it was created for, and the flags are not in the order
--- one would guess, so they are taken from the generated constants.
---
--- Readback exists so rendering can be asserted on rather than eyeballed. A
--- pass that silently produces nothing still runs at full frame rate.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local layers <const> = require("tecs.gfx.layers")

local C <const> = sdl.C
local K <const> = sdl.K

--- One pixel out of a readback, as eight-bit channels in 0..255.
---
--- Read as stored rather than converted, so a format whose channels are not
--- RGBA in that order reads as whatever the bytes were.
local record Pixel
    r: integer
    g: integer
    b: integer
    a: integer
end

local record TextureOptions
    --- Size in pixels, fixed for the texture's life. Resizing means creating
    --- another one and destroying this, which is what `PassGraph` does when
    --- the window changes.
    width: integer
    height: integer
    --- An `SDL_GPU_TEXTUREFORMAT_*` value. What the swapchain takes comes from
    --- `Device:getSwapchainFormat` and a depth format from `Texture.depthFormat`;
    --- neither is safe to assume, since backends differ about both.
    format: integer
    --- Any of "colorTarget", "sampled", "depthTarget", "computeRead",
    --- "computeWrite", "graphicsRead". Defaults to a samplable colour target.
    usage: {string}
    --- Label handed to SDL, which a graphics debugger shows against the
    --- resource. Optional; a texture created without one is unnamed there.
    name: string
end

--- A single-layer, single-mip 2D texture, and the type `create` returns.
---
--- Size, format and usage are fixed when it is made, so anything that has to
--- change one of them is a different texture. The caller owns it and calls
--- `destroy`; nothing releases it on collection.
local record Texture
    --- The `SDL_GPUTexture`. Nil once `destroy` has run, and the field every
    --- binding call reads, so a released texture cannot be bound by accident.
    handle: loader.CPtr
    --- Size in pixels, as created.
    width: integer
    --- Height in pixels, as created.
    height: integer
    --- Format as created. A pipeline drawing into this texture has to be
    --- created against the same value.
    format: integer
    --- The name SDL was given, or nil when none was asked for.
    name: string
    --- The `SDL_GPUDevice` the texture was created against, and the one
    --- `destroy` releases it from.
    _device: loader.CPtr
    --- Download staging, created by the first `readback` and kept for the ones
    --- after it. A texture nobody reads back never allocates one.
    _transfer: loader.CPtr
    --- Bytes that staging holds. Recorded and read nowhere: the size is fixed
    --- by the texture's own dimensions, which cannot change.
    _transferSize: integer
    --- Set by the first `destroy`, so a second one releases nothing again.
    _destroyed: boolean
end

local TextureMT <const>: metatable<Texture> = {__index = Texture}

local USAGE_FLAGS <const>: {string: integer} = {
    sampled = K.SDL_GPU_TEXTUREUSAGE_SAMPLER,
    colorTarget = K.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
    depthTarget = K.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
    computeRead = K.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_READ,
    computeWrite = K.SDL_GPU_TEXTUREUSAGE_COMPUTE_STORAGE_WRITE,
    graphicsRead = K.SDL_GPU_TEXTUREUSAGE_GRAPHICS_STORAGE_READ,
}

local DEFAULT_USAGE <const>: {string} = {"colorTarget", "sampled"}

--- SDL_GPU_TEXTURETYPE_2D
local TEXTURE_TYPE_2D <const> = 0

--- A depth format and what it can tell apart.
local record DepthFormat
    --- An `SDL_GPU_TEXTUREFORMAT_*` value.
    format: integer
    --- What it is called, so a diagnostic names something a reader can look
    --- up rather than an enum value.
    name: string
    --- The smallest difference the format keeps anywhere in zero to one.
    ---
    --- A normalised integer steps uniformly, so this is one over the values it
    --- has. A float does not: its step is finest near zero and coarsest at the
    --- top of the range, so what is quoted is the step at the top, which is
    --- the one the far layers are drawn at.
    resolution: number
end

--- Depth formats, best precision first.
---
--- D16 is the only one SDL guarantees, so it is the floor rather than a
--- preference. The two above it are asked for and taken only if the backend
--- answers yes.
---
--- Each carries its resolution because the fallback is otherwise silent:
--- taking the floor costs the sort inside a layer, and a format added here
--- without saying what it resolves would go unchecked.
local DEPTH_FORMATS <const>: {DepthFormat} = {
    {
        format = tonumber(C.SDL_GPU_TEXTUREFORMAT_D32_FLOAT) as integer,
        name = "D32_FLOAT",
        resolution = 2 ^ (-24),
    },
    {
        format = tonumber(C.SDL_GPU_TEXTUREFORMAT_D24_UNORM) as integer,
        name = "D24_UNORM",
        resolution = 1.0 / (2 ^ 24 - 1),
    },
    {
        format = tonumber(C.SDL_GPU_TEXTUREFORMAT_D16_UNORM) as integer,
        name = "D16_UNORM",
        resolution = 1.0 / (2 ^ 16 - 1),
    },
}

--- Says so in the log when a depth format cannot hold the layer sort, and
--- answers by how much it misses.
---
--- The sort divides the depth range into bands and positions within a band,
--- and the finest distinction it draws is `layers.depthResolution`. A format
--- whose step is larger than that keeps the bands, so a HUD still covers a
--- world, and loses the sort inside them: entities closer together than one
--- step share a depth value and draw in the order they were written. Nothing
--- fails and nothing is dropped, so this is the only place it is visible.
---
--- Reports rather than raising. The shortfall is not fatal to every scene: a
--- layer sorted by z alone resolves in the shallowest format SDL guarantees
--- with room to spare, and a game whose world is smaller than the default
--- extents resolves whatever it configures. Refusing the depth target would
--- take a device those scenes render correctly on and leave it with no
--- picture at all, which is a worse answer than a wrong sort for a scene that
--- never sorts by position. So the engine says what is lost and draws.
--- @param format An `SDL_GPU_TEXTUREFORMAT_*` value. One whose step is not
---     known here answers zero, since there is nothing to compare against.
--- @return World units that collapse onto one depth value, or zero when the
---     format resolves everything the sort produces.
function Texture.checkDepthSorting(format: integer): number
    local known: DepthFormat = nil
    for _, entry in ipairs(DEPTH_FORMATS) do
        if entry.format == format then
            known = entry
            break
        end
    end
    if known == nil then
        return 0.0
    end

    local needed <const> = layers.depthResolution()
    if known.resolution <= needed then
        return 0.0
    end

    -- Required here rather than at the top. Logging reaches SDL through a
    -- native sink, and a texture is created by tools and tests that have no
    -- use for one; a depth format that falls short is a cold path met once.
    local log <const> = require("tecs.log")
    local collapsed <const> = known.resolution / needed
    log.get("tecs.gpu"):error(
        "the depth target is %s, which steps by %.3g, and the layer sort "
            .. "resolves to %.3g: entities within %.4g world units of each other "
            .. "share a depth value and draw in the order they were written "
            .. "rather than the order they were sorted into. Dividing "
            .. "layers.maxY and layers.maxZ by %.4g resolves the sort again",
        known.name,
        known.resolution,
        needed,
        collapsed,
        collapsed
    )
    return collapsed
end

--- The best depth format `device` supports as a depth target.
---
--- Asked rather than assumed. Backends disagree about which depth formats
--- exist at all: Metal has no D24_UNORM, and a Vulkan driver may have that one
--- and not D32_FLOAT. A hardcoded choice creates a texture on the machine it
--- was written on and returns nil on the next one.
---
--- Raises rather than returning nil when nothing in the list works, since a
--- device that supports no depth format at all cannot run the geometry pass
--- and there is nothing a caller could do with the answer.
---
--- Falling back is reported. What the depth target holds decides how finely a
--- layer sorts, so a device that offers only the floor draws a scene in an
--- order nobody asked for, and `checkDepthSorting` is what stops that being
--- the one thing about this choice nobody is told.
--- @param device The `SDL_GPUDevice`, which is `Device.handle` and not the
---     wrapper around it. Asked directly, so this is safe before any texture
---     exists.
--- @return An `SDL_GPU_TEXTUREFORMAT_*` value to create a depth target with.
function Texture.depthFormat(device: loader.CPtr): integer
    local usage = USAGE_FLAGS.depthTarget
    for _, entry in ipairs(DEPTH_FORMATS) do
        if C.SDL_GPUTextureSupportsFormat(device, entry.format, TEXTURE_TYPE_2D, usage) then
            Texture.checkDepthSorting(entry.format)
            return entry.format
        end
    end
    error("tecs: this device supports no depth format as a depth target", 2)
end

--- Creates a texture with one mip level and one layer.
---
--- The caller owns it and calls `destroy`; nothing is tied to the collector.
--- Size, format and usage are all fixed here, so a texture that has to change
--- any of them is a new texture.
--- @param device The `SDL_GPUDevice`, which is `Device.handle` and not the
---     wrapper around it.
--- @return A texture whose contents are undefined until something writes it,
---     so a pass that loads rather than clears reads whatever was in memory.
function Texture.create(device: loader.CPtr, options: TextureOptions): Texture
    local flags = 0
    for _, name in ipairs(options.usage or DEFAULT_USAGE) do
        local flag = USAGE_FLAGS[name]
        if flag == nil then
            error(("tecs: unknown texture usage '%s'"):format(tostring(name)), 2)
        end
        flags = flags + flag
    end

    local info = loader.newArray("SDL_GPUTextureCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.type = TEXTURE_TYPE_2D
    settings.format = options.format
    settings.usage = flags
    settings.width = options.width
    settings.height = options.height
    settings.layer_count_or_depth = 1
    settings.num_levels = 1
    settings.sample_count = 0
    settings.props = 0

    local handle = C.SDL_CreateGPUTexture(device, info)
    if handle == nil then
        sdl.fail("SDL_CreateGPUTexture")
    end

    -- A device created without debug mode keeps no names, so this is free in a
    -- release and the difference is only visible in a graphics debugger.
    if options.name ~= nil then
        C.SDL_SetGPUTextureName(device, handle, options.name)
    end

    local self = setmetatable({} as Texture, TextureMT)
    self.handle = handle
    self.name = options.name
    self.width = options.width
    self.height = options.height
    self.format = options.format
    self._device = device
    self._transferSize = 0
    self._destroyed = false
    return self
end

--- Uploads tightly packed RGBA pixels into the texture.
---
--- Submits its own command buffer, so this is a load-time path. It exists
--- because an asset arrives once, not once per frame.
---
--- Tightly packed means rows of exactly `width * 4` bytes with no padding: the
--- copy is described to SDL as `width` pixels per row, so a source that pads
--- its rows shears. `TextureArray:add` takes a pitch and repacks for that.
--- @param pixels Rows of RGBA bytes covering the whole texture.
--- @param byteCount Bytes to read, which is `width * height * 4`.
function Texture:upload(pixels: loader.CValue, byteCount: integer)
    local info = loader.newArray("SDL_GPUTransferBufferCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.usage = C.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD
    settings.size = byteCount
    settings.props = 0

    local transfer = C.SDL_CreateGPUTransferBuffer(self._device, info)
    if transfer == nil then
        sdl.fail("SDL_CreateGPUTransferBuffer")
    end

    local mapped = C.SDL_MapGPUTransferBuffer(self._device, transfer, true)
    if mapped == nil then
        sdl.fail("SDL_MapGPUTransferBuffer")
    end
    loader.copyBytes(mapped as loader.CArray, pixels, byteCount)
    C.SDL_UnmapGPUTransferBuffer(self._device, transfer)

    local commandBuffer = C.SDL_AcquireGPUCommandBuffer(self._device)
    if commandBuffer == nil then
        sdl.fail("SDL_AcquireGPUCommandBuffer")
    end
    local copyPass = C.SDL_BeginGPUCopyPass(commandBuffer)

    local source = loader.newArray("SDL_GPUTextureTransferInfo[1]")
    local from = source[0] as loader.CStruct
    from.transfer_buffer = transfer
    from.offset = 0
    from.pixels_per_row = self.width
    from.rows_per_layer = self.height

    local region = loader.newArray("SDL_GPUTextureRegion[1]")
    local to = region[0] as loader.CStruct
    to.texture = self.handle
    to.mip_level = 0
    to.layer = 0
    to.x, to.y, to.z = 0, 0, 0
    to.w, to.h, to.d = self.width, self.height, 1

    C.SDL_UploadToGPUTexture(copyPass, source, region, false)
    C.SDL_EndGPUCopyPass(copyPass)
    sdl.check(C.SDL_SubmitGPUCommandBuffer(commandBuffer) as boolean, "SDL_SubmitGPUCommandBuffer")

    C.SDL_ReleaseGPUTransferBuffer(self._device, transfer)
end

--- Copies the texture into a mapped transfer buffer and returns the pixels.
---
--- Blocks until the GPU has finished, so this is a diagnostic and test path,
--- not something a frame should call.
---
--- Four bytes a pixel is assumed, which is what makes this a colour-target
--- path: a depth texture reads back a byte count that does not describe it.
--- @return A fresh `width * height * 4` byte array the caller owns, with rows
---     running down from the top-left. Index it through `getPixel`.
function Texture:readback(): loader.CArray
    local byteCount = self.width * self.height * 4

    if self._transfer == nil then
        local info = loader.newArray("SDL_GPUTransferBufferCreateInfo[1]")
        local settings = info[0] as loader.CStruct
        settings.usage = C.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD
        settings.size = byteCount
        settings.props = 0
        self._transfer = C.SDL_CreateGPUTransferBuffer(self._device, info)
        if self._transfer == nil then
            sdl.fail("SDL_CreateGPUTransferBuffer")
        end
        self._transferSize = byteCount
    end

    local commandBuffer = C.SDL_AcquireGPUCommandBuffer(self._device)
    if commandBuffer == nil then
        sdl.fail("SDL_AcquireGPUCommandBuffer")
    end
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
    if fence == nil then
        sdl.fail("SDL_SubmitGPUCommandBufferAndAcquireFence")
    end
    local fences = loader.newArray("SDL_GPUFence*[1]")
    fences[0] = fence
    C.SDL_WaitForGPUFences(self._device, true, fences, 1)
    C.SDL_ReleaseGPUFence(self._device, fence)

    local mapped = C.SDL_MapGPUTransferBuffer(self._device, self._transfer, false)
    if mapped == nil then
        sdl.fail("SDL_MapGPUTransferBuffer")
    end
    local pixels = loader.newArray("uint8_t[?]", byteCount)
    loader.copyBytes(pixels, mapped as loader.CValue, byteCount)
    C.SDL_UnmapGPUTransferBuffer(self._device, self._transfer)

    return pixels
end

--- Reads one pixel out of a buffer returned by `readback`.
---
--- Coordinates are zero-based from the top-left, the same origin
--- `gl_FragCoord` has, so a shader that writes a gradient reads back in the
--- direction it wrote it. Unchecked: a coordinate outside the texture reads
--- whatever is at that offset.
--- @param pixels A buffer `readback` returned for this texture. One from
---     another texture is indexed by this texture's width, not its own.
--- @param x Column, zero to `width - 1`.
--- @param y Row, zero to `height - 1`.
--- @return A fresh record holding a copy of the four bytes; nothing reads the
---     buffer again afterwards.
function Texture:getPixel(pixels: loader.CArray, x: integer, y: integer): Pixel
    local offset = (y * self.width + x) * 4
    return {
        r = pixels[offset] as integer,
        g = pixels[offset + 1] as integer,
        b = pixels[offset + 2] as integer,
        a = pixels[offset + 3] as integer,
    }
end

--- Releases the texture and any transfer buffer. Safe to call more than once.
function Texture:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    if self._transfer ~= nil then
        C.SDL_ReleaseGPUTransferBuffer(self._device, self._transfer)
        self._transfer = nil
    end
    C.SDL_ReleaseGPUTexture(self._device, self.handle)
    self.handle = nil
end

return Texture
