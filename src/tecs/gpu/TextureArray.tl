--[=[
A 2D array texture: many images, one binding.

This exists to collapse draws. Binding samplers per pipeline means one
texture is one draw, so a scene with fifty images would be fifty draws and
the instance buffer would have to be sorted by texture to make them
contiguous. An array turns the texture into a per-instance integer, which
gives back both the single draw and the freedom to lay instances out in
whatever order suits the producer.

Every layer shares one size and format, which is the constraint arrays
carry. What a caller sees is a sub-rect of a layer rather than a layer, so
where inside one an image landed is this module's business alone. `replace`
is what that indirection buys: new pixels can be written over an image at
the texels it already occupies, and every instance sampling it goes on
naming the right ones.

Packing is what makes that indirection worth having. A layer holds one image
by default, which costs a whole cell for a sixteen-pixel icon and puts a
hard ceiling on how many distinct images a process can hold. With `pack` on,
a shelf allocator fits many images into each layer and the ceiling becomes
the array's area rather than its layer count.
]=]

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K

--- SDL_GPU_TEXTURETYPE_2D_ARRAY
local TYPE_2D_ARRAY <const> = 1

--- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local RGBA8 <const> = 4

--- Texels of gutter around every packed image, on all four sides.
---
--- Two placements are therefore twice this apart, which is what keeps a filter
--- that reaches past a texel edge from picking up its neighbor. The gutter is
--- written as a copy of the image's own edge rather than left undefined, so
--- what does reach into it is the color that was already there.
local PADDING <const> = 1

--- A row of a layer that images are placed along, left to right.
---
--- Shelves are the packing: an image either fits on one that is already open
--- and tall enough, or opens a new one below the last. It wastes the difference
--- between an image's height and its shelf's, which for sprite work is small
--- because frames of one sheet are the same size and arrive together.
local record Shelf
    --- Layer the shelf belongs to.
    layer: integer
    --- Top of the shelf within the layer, in texels.
    y: integer
    --- Its height, fixed by the first image placed on it.
    height: integer
    --- Where the next image goes, in texels from the layer's left edge.
    cursor: integer
end

local record TextureArrayOptions
    --- Cell size in pixels. Every image must fit within it, and every layer
    --- costs this much whatever the image put in it is.
    width: integer
    height: integer
    --- Layers to allocate, all of them up front. The device decides how many
    --- an array may have, so a count past what it allows fails at creation
    --- rather than at the layer that crosses the line.
    layers: integer
    --- Fit many images into each layer rather than one. Defaults to false,
    --- which is one image per layer at the layer's origin.
    pack: boolean
end

--- Many images behind one texture binding, addressed by layer and UV rect.
---
--- `add` puts an image in and answers where it went; `replace` writes over one
--- without moving it. Nothing is ever freed short of `destroy`, so an array is
--- sized for the images a process will hold rather than the ones it holds now.
local record TextureArray
    --- Where one image landed, and how to sample it back out.
    ---
    --- The caller's to keep: nothing here maps an image back to its region, and
    --- the values stay true for as long as the array lives, `replace` included.
    record Region
        --- Layer this image occupies, zero-based: the index a shader passes to
        --- the third component of an array sampler's coordinate.
        layer: integer
        --- The image's rectangle within its cell, as fractions of the cell.
        --- UVs run from the first pair to the second, and an image that does
        --- not fill its cell reaches neither zero nor one.
        u0: number
        --- Top edge, as a fraction of the cell's height.
        v0: number
        --- Right edge, as a fraction of the cell's width.
        u1: number
        --- Bottom edge, as a fraction of the cell's height.
        v1: number
        --- The image's own top-left within its layer, in texels, outside any
        --- gutter. Carried rather than recovered from the UVs, so writing over
        --- an image again lands on the texels it already occupies exactly.
        x: integer
        --- Top of the image within its layer, in texels, outside any gutter.
        y: integer
        --- Size in pixels as uploaded, for a caller that needs the image's own
        --- dimensions rather than its share of the cell.
        width: integer
        --- Height in pixels as uploaded, and what `replace` insists on.
        height: integer
    end

    --- The `SDL_GPUTexture`, of type 2D array. Nil once `destroy` has run.
    handle: loader.CPtr
    --- Cell size in pixels, shared by every layer.
    width: integer
    --- Cell height in pixels, shared by every layer.
    height: integer
    --- Layers allocated.
    layers: integer
    --- Layers holding something. Layers are never reclaimed: an image uploaded
    --- is resident until the whole array is destroyed. Unpacked, this is also
    --- the index the next `add` takes.
    used: integer
    --- Whether a layer holds many images.
    packed: boolean
    --- The `SDL_GPUDevice` the texture and its staging were created against.
    _device: loader.CPtr
    --- Upload staging, kept between calls and grown when an image needs more
    --- than the last one did. Never shrunk, since the largest image is the one
    --- that decides the cost either way.
    _transfer: loader.CPtr
    --- Bytes the staging buffer holds, and the test that decides whether the
    --- next image needs a larger one. Zero before the first upload.
    _transferSize: integer
    --- Set by the first `destroy`, so a second one releases nothing again.
    _destroyed: boolean
    --- Open shelves across every layer, oldest first. Packed only.
    _shelves: {Shelf}
    --- Texels of the newest layer already given to shelves, so a new shelf
    --- knows where it starts and whether it fits at all. Packed only.
    _shelfTop: integer
    --- Texels handed out, gutters included, for `usage`.
    _occupied: integer

    --- How much of the array's texels are occupied, counting gutters.
    ---
    --- For reporting what packing bought rather than for deciding anything: the
    --- allocator never consults it.
    --- @return Texels handed out, gutters counted.
    --- @return Texels the whole array holds, which is the cell area times the
    ---     layer count whether a layer is in use or not.
    usage: function(self): integer, integer
end

local TextureArrayMT <const>: metatable<TextureArray> = {__index = TextureArray}

--- Creates an array with `layers` cells of the given size.
---
--- RGBA8 and sampler usage, neither of which is an option: the point is one
--- binding for every image, and a second format would be a second binding.
--- @param device The `SDL_GPUDevice`, which is `Device.handle` and not the
---     wrapper around it.
--- @return An empty array whose layers are all allocated. Staging is not: the
---     first `add` sizes it to the image it is given.
function TextureArray.create(device: loader.CPtr, options: TextureArrayOptions): TextureArray
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
    if handle == nil then
        sdl.fail("SDL_CreateGPUTexture")
    end

    local self = setmetatable({} as TextureArray, TextureArrayMT)
    self.handle = handle
    self.width = options.width
    self.height = options.height
    self.layers = options.layers
    self.used = 0
    self.packed = options.pack == true
    self._device = device
    self._transferSize = 0
    self._destroyed = false
    self._shelves = {}
    self._shelfTop = 0
    self._occupied = 0
    return self
end

local function ensureTransfer(self: TextureArray, byteCount: integer)
    if self._transfer ~= nil and self._transferSize >= byteCount then
        return
    end
    if self._transfer ~= nil then
        C.SDL_ReleaseGPUTransferBuffer(self._device, self._transfer)
    end
    local info = loader.newArray("SDL_GPUTransferBufferCreateInfo[1]")
    local settings = info[0] as loader.CStruct
    settings.usage = C.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD
    settings.size = byteCount
    settings.props = 0
    self._transfer = C.SDL_CreateGPUTransferBuffer(self._device, info)
    if self._transfer == nil then
        sdl.fail("SDL_CreateGPUTransferBuffer")
    end
    self._transferSize = byteCount
end

--- Finds somewhere for an image of the given padded size, unpacked.
---
--- One image a layer, at its origin, which is what the array did before there
--- was a packer and what it still does unless asked otherwise.
local function placeUnpacked(
    self: TextureArray, width: integer, height: integer, level: integer
): integer, integer, integer
    if self.used >= self.layers then
        error(("tecs: texture array is full at %d layers"):format(self.layers), level)
    end
    if width > self.width or height > self.height then
        error(("tecs: image %dx%d exceeds the %dx%d cell"):format(width, height, self.width, self.height), level)
    end
    local layer <const> = self.used
    self.used = layer + 1
    self._occupied = self._occupied + width * height
    return layer, 0, 0
end

--- Finds somewhere for an image of the given padded size, packed.
---
--- An open shelf tall enough and with room left takes it, and the shortest such
--- shelf is chosen so a tall shelf is not spent on a short image. Failing that
--- a shelf opens below the last one on the newest layer, and failing that a new
--- layer starts. Nothing is ever reclaimed, which is the same bargain the
--- unpacked path makes.
local function placePacked(
    self: TextureArray, width: integer, height: integer, level: integer
): integer, integer, integer
    if width > self.width or height > self.height then
        error(("tecs: image %dx%d exceeds the %dx%d cell"):format(width, height, self.width, self.height), level)
    end

    local shelves <const> = self._shelves
    local best: Shelf = nil
    for index = 1, #shelves do
        local shelf = shelves[index]
        if
            shelf.height >= height
            and self.width - shelf.cursor >= width
            and (best == nil or shelf.height < best.height)
        then
            best = shelf
        end
    end

    if best ~= nil then
        local x <const> = best.cursor
        best.cursor = x + width
        self._occupied = self._occupied + width * height
        return best.layer, x, best.y
    end

    -- The first image of all, and every image that outgrows the layer it is
    -- being packed into, starts a layer of its own.
    if self.used == 0 or self._shelfTop + height > self.height then
        if self.used >= self.layers then
            error(("tecs: texture array is full at %d layers"):format(self.layers), level)
        end
        self.used = self.used + 1
        self._shelfTop = 0
    end

    local layer <const> = self.used - 1
    local y <const> = self._shelfTop
    shelves[#shelves + 1] = {
        layer = layer,
        y = y,
        height = height,
        cursor = width,
    }
    self._shelfTop = y + height
    self._occupied = self._occupied + width * height
    return layer, 0, y
end

--- Writes the image into the transfer buffer, with its edge repeated into the
--- gutter around it.
---
--- The gutter exists so a filter reaching past an image's edge finds the
--- image's own color rather than the neighbor packed beside it. Repeating the
--- edge is what makes what it finds harmless; leaving the gutter undefined
--- would only move the seam.
local function stage(
    self: TextureArray, pixels: loader.CValue, width: integer, height: integer, pitch: integer, pad: integer
): integer
    local rowTexels <const> = width + pad * 2
    local rowBytes <const> = rowTexels * 4
    ensureTransfer(self, rowBytes * (height + pad * 2))

    local mapped = C.SDL_MapGPUTransferBuffer(self._device, self._transfer, true)
    if mapped == nil then
        sdl.fail("SDL_MapGPUTransferBuffer")
    end

    -- Repacked row by row so the upload sees tightly packed data regardless
    -- of what stride the source used.
    local source <const> = loader.bytePointer(pixels)
    local destination <const> = loader.bytePointer(mapped as loader.CValue)
    for row = 0, height - 1 do
        local start <const> = destination + (row + pad) * rowBytes
        local target <const> = start + pad * 4
        loader.copyTo(target, (source + row * pitch) as loader.CValue, width * 4)
        for column = 1, pad do
            loader.copyTo(start + (pad - column) * 4, target as loader.CValue, 4)
            loader.copyTo(target + (width + column - 1) * 4, (target + (width - 1) * 4) as loader.CValue, 4)
        end
    end
    -- Top and bottom gutters are whole rows of what they abut, so they pick up
    -- the side gutters written above with no further work.
    for row = 1, pad do
        loader.copyTo(destination + (pad - row) * rowBytes, (destination + pad * rowBytes) as loader.CValue, rowBytes)
        loader.copyTo(
            destination + (pad + height + row - 1) * rowBytes,
            (destination + (pad + height - 1) * rowBytes) as loader.CValue,
            rowBytes
        )
    end

    C.SDL_UnmapGPUTransferBuffer(self._device, self._transfer)
    return rowTexels
end

--- Copies the staged rectangle onto a layer.
---
--- Its own command buffer, submitted here. That makes this a load-time path:
--- an image arrives once, not once per frame, and the copy is ordered against
--- everything after it without a frame having to carry it.
--- @param x The rectangle's left edge in the layer, gutter included, so this is
---     where the placement starts rather than where the image does.
local function upload(
    self: TextureArray, layer: integer, x: integer, y: integer, rowTexels: integer, width: integer, height: integer
)
    local commandBuffer = C.SDL_AcquireGPUCommandBuffer(self._device)
    if commandBuffer == nil then
        sdl.fail("SDL_AcquireGPUCommandBuffer")
    end
    local copyPass = C.SDL_BeginGPUCopyPass(commandBuffer)

    local from = loader.newArray("SDL_GPUTextureTransferInfo[1]")
    local sourceInfo = from[0] as loader.CStruct
    sourceInfo.transfer_buffer = self._transfer
    sourceInfo.offset = 0
    sourceInfo.pixels_per_row = rowTexels
    sourceInfo.rows_per_layer = height

    local to = loader.newArray("SDL_GPUTextureRegion[1]")
    local region = to[0] as loader.CStruct
    region.texture = self.handle
    region.mip_level = 0
    region.layer = layer
    region.x, region.y, region.z = x, y, 0
    region.w, region.h, region.d = width, height, 1

    C.SDL_UploadToGPUTexture(copyPass, from, to, false)
    C.SDL_EndGPUCopyPass(copyPass)
    sdl.check(C.SDL_SubmitGPUCommandBuffer(commandBuffer) as boolean, "SDL_SubmitGPUCommandBuffer")
end

--- Uploads RGBA pixels into the array.
---
--- Raises when the array is full or the image is larger than a cell. Both are
--- authoring mistakes with no useful runtime answer, and a silently dropped
--- image would surface as a sprite sampling whatever occupies layer zero.
--- Submits its own command buffer and does not wait on it, so this is a
--- load-time path rather than something a frame carries.
--- @param pixels Tightly packed RGBA8 rows read during this call and not kept,
---     so the caller's memory may be reused as soon as it returns.
--- @param width Image width in pixels, which must fit inside a cell, and inside
---     a cell less two texels of gutter on a packed array.
--- @param height Image height in pixels, under the same limit.
--- @param pitch The source's row stride in bytes, which is not always
---     `width * 4`: a decoder is free to pad rows, and copying as though it
---     never does shears the image.
--- @return Where the image landed, which the caller keeps: nothing here maps
---     an image back to its region.
function TextureArray:add(pixels: loader.CValue, width: integer, height: integer, pitch: integer): TextureArray.Region
    local pad <const> = self.packed and PADDING or 0
    local layer, x, y = 0, 0, 0
    if self.packed then
        layer, x, y = placePacked(self, width + pad * 2, height + pad * 2, 3)
    else
        layer, x, y = placeUnpacked(self, width, height, 3)
    end

    local rowTexels <const> = stage(self, pixels, width, height, pitch, pad)
    upload(self, layer, x, y, rowTexels, width + pad * 2, height + pad * 2)

    -- The rect the caller samples is the image's own texels and never the
    -- gutter around them, so a neighbor packed one texel away is unreachable
    -- through this region however the sub-rect inside it is narrowed.
    local left <const> = x + pad
    local top <const> = y + pad
    return {
        layer = layer,
        u0 = left / self.width,
        v0 = top / self.height,
        u1 = (left + width) / self.width,
        v1 = (top + height) / self.height,
        x = left,
        y = top,
        width = width,
        height = height,
    }
end

--- Writes new pixels over an image already in the array.
---
--- Nothing moves. The region handed in is where the image is, the replacement
--- lands on those same texels, and the region is as true afterwards as it was
--- before. That is what makes this different from adding: every `Sprite`,
--- `Sheet` and glyph already holding a layer and a UV rect keeps holding the
--- right one, so there is nothing to invalidate and nothing in the world to
--- touch.
---
--- The gutter is rewritten too, since it is a copy of the image's own edge and
--- the new image's edge is a different color.
---
--- Raises where the replacement is not the size the region was cut for. A
--- different size is a different rect, packed or not, and the sprites holding
--- the old one have no way to be told.
--- @param region What `add` returned for this image, unchanged.
--- @param pitch The source's row stride in bytes, as `add` takes it.
function TextureArray:replace(
    region: TextureArray.Region, pixels: loader.CValue, width: integer, height: integer, pitch: integer
)
    if width ~= region.width or height ~= region.height then
        error(
            ("tecs: an image occupying %dx%d texels cannot be replaced by a " .. "%dx%d one"):format(
                region.width, region.height, width, height
            ),
            2
        )
    end

    local pad <const> = self.packed and PADDING or 0
    local rowTexels <const> = stage(self, pixels, width, height, pitch, pad)
    upload(self, region.layer, region.x - pad, region.y - pad, rowTexels, width + pad * 2, height + pad * 2)
end

function TextureArray:usage(): integer, integer
    return self._occupied, self.width * self.height * self.layers
end

--- Releases the array. Safe to call more than once.
function TextureArray:destroy()
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

return TextureArray
