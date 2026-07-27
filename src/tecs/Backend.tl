--- Turns a frame packet into a submitted frame.
---
--- The device-facing half of rendering, and the half that stays on the main
--- thread when the pipeline splits. It owns the device buffers, the staging
--- slots, the cull, the deferred pass graph and the image array. It knows
--- nothing about worlds, queries, archetypes or components: everything it draws
--- arrives as bytes already in staging plus a packet saying what changed.
---
--- Images live in one array texture, so the texture is a per-instance integer
--- and the whole scene is one draw. That is also what frees the instance
--- layout: with nothing to sort by, each archetype keeps a contiguous run, and
--- a run whose components did not change does not have to be rewritten.
---
--- What is drawn is decided on the GPU. A compute pass tests each instance
--- against the view, compacts the survivors into an index list, and writes the
--- draw arguments, so the draw touches only what is visible and the CPU never
--- learns how many that was. The instance buffer stays archetype-contiguous
--- for the dirty gate; the compacted list is rebuilt every frame and is a
--- separate array, so the two do not fight.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local Buffer <const> = require("tecs.gpu.Buffer")
local Shader <const> = require("tecs.gpu.Shader")
local Frame <const> = require("tecs.gpu.Frame")
local GraphicsPipeline <const> = require("tecs.gpu.GraphicsPipeline")
local Deferred <const> = require("tecs.gpu.Deferred")
local Sampler <const> = require("tecs.gpu.Sampler")
local ComputePipeline <const> = require("tecs.gpu.ComputePipeline")
local ComputePass <const> = require("tecs.gpu.ComputePass")
local TextureArray <const> = require("tecs.gpu.TextureArray")
local Texture <const> = require("tecs.gpu.Texture")
local Camera <const> = require("tecs.gfx.Camera")
local FramePacket <const> = require("tecs.FramePacket")
local layers <const> = require("tecs.gfx.layers")
local frametable <const> = require("tecs.gfx.frametable")
local instancelayout <const> = require("tecs.gpu.instancelayout")

local C <const> = sdl.C

local INSTANCE_BYTES <const> = instancelayout.BYTES
local BOUND_BYTES <const> = instancelayout.BOUND_BYTES

--- Floats in the layer uniform: the camera's parameters, the two fixed clip
--- scales, and four per layer.
local LAYER_FLOATS <const> = 8 + layers.MAX * 4
local LAYER_BYTES <const> = LAYER_FLOATS * 4

--- Floats in the clip uniform: a rectangle per region, as minimum xy and
--- maximum xy in target pixels. Region zero is never read, and its four floats
--- are kept so a region index is the array index and the shader needs no
--- subtraction to look one up.
local CLIP_FLOATS <const> = instancelayout.CLIPS * 4
local CLIP_BYTES <const> = CLIP_FLOATS * 4

--- Bound of a region that clips nothing. Finite, so the shader's comparisons
--- stay arithmetic, and beyond any target a fragment can land on.
local CLIP_UNBOUNDED <const> = 1e30

--- Indices per quad, over four distinct corners.
local QUAD_INDICES <const> = 6

--- Threads per cull workgroup, matching the scan shaders' local size.
local CULL_GROUP <const> = 256

--- Floats the animation frame table is sized for.
---
--- A ceiling rather than a hint, for the reason the instance capacity is one:
--- growing it would mean a second device buffer while a frame in flight is
--- still reading the first. A quarter of a megabyte holds a few hundred
--- animations, since a playback costs four floats of directory, one per
--- millisecond of its cycle, and eight per step it visits.
local PLAYBACK_FLOATS <const> = 65536

--- Layers the image array holds, including the white default in layer zero.
local MAX_LAYERS <const> = 64

--- Cell size of the image array. Every image must fit within it.
local DEFAULT_CELL <const> = 512

--- A clip rectangle, in target pixels measured from the top left.
---
--- Screen space rather than world space, because that is what a fragment is
--- tested in and what a scissor means: a panel occupies a part of the window
--- whether its contents are placed by the camera, in screen pixels, or in
--- virtual coordinates, and one rectangle is right for all three.
local record ClipRegion
    x: number
    y: number
    width: number
    height: number
end

local record BackendOptions
    --- Ambient colour applied everywhere.
    ambient: {number}
    --- Instances the buffers are sized for.
    capacity: integer
    --- Cell size of the image array.
    cell: integer
    --- Layers the image array holds.
    layers: integer
    --- Fit many images into each layer rather than one.
    packImages: boolean
end

local record Backend
    type ClipRegion = ClipRegion
    type Options = BackendOptions

    deferred: Deferred
    instances: Buffer
    pipeline: GraphicsPipeline
    sampler: Sampler
    --- Every image, one binding, so the scene is one draw.
    images: TextureArray
    capacity: integer
    --- Instances the last consumed packet left resident, which is what the
    --- cull is dispatched over and what the geometry pass tests before it
    --- records anything.
    count: integer
    --- UV extent of the white pixel within its cell, published to whoever
    --- writes instances: an image smaller than a cell does not reach the
    --- cell's edge, so sampling 0..1 would read the undefined remainder.
    whiteU0: number
    whiteV0: number
    whiteU1: number
    whiteV1: number
    _mark: ComputePipeline
    _scan: ComputePipeline
    _compact: ComputePipeline
    _bounds: Buffer
    _slots: Buffer
    _blocks: Buffer
    _visible: Buffer
    _drawArgs: Buffer
    _indices: Buffer
    --- Frame tables every animated instance resolves against, and the revision
    --- the resident copy was uploaded from. Uploaded when it moves rather than
    --- per frame: it is content, and the frame that registers an animation is
    --- the rare one.
    _playbacks: Buffer
    _playbackRevision: integer
    --- Fixed steps the packet being drawn was extracted at, which is what an
    --- animated instance resolves its frame against.
    _stepClock: number
    --- Where the packet said the view was. A calculator for the matrix and the
    --- view bounds rather than the camera a game holds, which lives on the
    --- other side of the boundary and is copied into every packet.
    _view: Camera
    _cullUniform: loader.CArray
    --- What each layer does to its contents, in the shape the vertex shader
    --- reads it.
    _layerUniform: loader.CArray
    --- Revision the packed table was built from, so a frame that configured
    --- nothing repacks nothing.
    _layerRevision: integer
    --- The clip rectangles, in the shape the fragment shader reads them.
    --- Written in place as regions are set, so there is nothing to repack.
    _clipUniform: loader.CArray
    _device: loader.CPtr
    _destroyed: boolean
end

local BackendMT <const>: metatable<Backend> = { __index = Backend }

--- Fills the uniform the vertex shader reads a layer's behaviour from.
---
--- The camera's parameters rather than a matrix for each mode. Parallax
--- multiplies the camera's position, so a matrix per mode would have to be a
--- matrix per layer and be rebuilt every frame the camera moved. Passed this
--- way, the camera's position, its reciprocal zoom and two clip scales compose
--- all four cases in a handful of shader instructions, and the sixteen entries
--- stay what they were.
local function layerUniform(self: Backend, width: number,
                            height: number): loader.CArray
    local data = self._layerUniform
    local view = self._view
    data[0] = view.x
    data[1] = view.y
    -- The camera's matrix carries the zoom, so a layer that ignores zoom
    -- divides it back out rather than reaching for a second matrix.
    data[2] = view.zoom ~= 0.0 and 1.0 / view.zoom or 1.0
    -- The animation clock, in whole fixed steps. It rides the spare component
    -- of a block that is already pushed every frame, so playback on the GPU
    -- costs no binding and no second push.
    data[3] = self._stepClock
    -- Position to clip for the two fixed spaces, with Y negated because both
    -- run down from the top left while clip Y runs up.
    data[4] = 2.0 / width
    data[5] = -2.0 / height
    data[6] = 2.0 / layers.virtualWidth
    data[7] = -2.0 / layers.virtualHeight

    -- Packed when it changes rather than every frame: it is configuration, and
    -- the frame that configures a layer is the rare one.
    local revision = layers.revision()
    if revision ~= self._layerRevision then
        self._layerRevision = revision
        for layer = 1, layers.MAX do
            local base = 8 + (layer - 1) * 4
            data[base], data[base + 1], data[base + 2], data[base + 3] =
                layers.entryOf(layer)
        end
    end

    return data
end

--- Builds the geometry pipeline against the G-buffer the deferred pass owns.
---
--- One description of it, shared by creation and by a reload, so the pipeline a
--- reload installs cannot disagree with the one the backend started with.
local function buildGeometry(self: Backend): GraphicsPipeline
    local device <const> = self._device
    local albedoFormat, normalFormat = self.deferred:geometryFormats()
    local vertex = Shader.load(device, "instance.vert", {})
    local fragment = Shader.load(device, "instance.frag", {})
    local pipeline = GraphicsPipeline.create(device, {
        vertexShader = vertex,
        fragmentShader = fragment,
        colorFormats = { albedoFormat, normalFormat },
        depth = self.deferred:geometryDepth(),
        name = "ecs.instances",
    })
    vertex:destroy()
    fragment:destroy()
    return pipeline
end

--- Builds a backend for `device`.
function Backend.create(device: loader.CPtr, swapchainFormat: integer,
                        options: BackendOptions): Backend
    local self = setmetatable({} as Backend, BackendMT)
    self._device = device
    self.capacity = options.capacity
    self.count = 0
    self._destroyed = false

    -- A layer number shares its float with the clip index, so a layer beyond
    -- the packing's stride would be read back as a different layer in a
    -- different region. Refused here rather than discovered as a wrong image.
    local layerCount <const> = options.layers or MAX_LAYERS
    if layerCount > instancelayout.LAYER_SLOTS then
        error(("tecs: the image array holds at most %d layers")
            :format(instancelayout.LAYER_SLOTS), 3)
    end

    self.sampler = Sampler.create(device, { filter = "nearest", address = "clamp" })
    self.images = TextureArray.create(device, {
        width = options.cell or DEFAULT_CELL,
        height = options.cell or DEFAULT_CELL,
        layers = layerCount,
        pack = options.packImages,
    })

    -- Layer zero is a single white pixel. Entities without a Sprite sample it,
    -- so textured and untextured geometry share one shader and one pipeline
    -- rather than needing a branch or a second path.
    local pixel = loader.newArray("uint8_t[4]")
    pixel[0], pixel[1], pixel[2], pixel[3] = 255, 255, 255, 255
    local white = self.images:add(pixel as loader.CValue, 1, 1, 4)
    self.whiteU0 = white.u0
    self.whiteV0 = white.v0
    self.whiteU1 = white.u1
    self.whiteV1 = white.v1

    self.instances = Buffer.create(device, {
        usage = { "storage", "computeRead" },
        size = self.capacity * INSTANCE_BYTES,
    })
    self._bounds = Buffer.create(device, {
        usage = { "computeRead" },
        size = self.capacity * BOUND_BYTES,
    })
    self._slots = Buffer.create(device, {
        usage = { "computeRead", "computeWrite" },
        size = self.capacity * 4,
    })
    self._blocks = Buffer.create(device, {
        usage = { "computeRead", "computeWrite" },
        size = math.ceil(self.capacity / CULL_GROUP) * 4,
    })
    self._visible = Buffer.create(device, {
        usage = { "storage", "computeWrite" },
        size = self.capacity * 4,
    })
    self._drawArgs = Buffer.create(device, {
        -- Five uints: SDL_GPUIndexedIndirectDrawCommand.
        usage = { "indirect", "computeWrite" },
        size = 32,
    })
    self._playbacks = Buffer.create(device, {
        usage = { "storage" },
        size = PLAYBACK_FLOATS * 4,
        name = "tecs.playbacks",
    })
    -- Below every revision the table can report, so the first frame uploads it
    -- even when nothing has registered and the buffer would otherwise be read
    -- before anything wrote it.
    self._playbackRevision = -1
    self._stepClock = 0.0

    -- Every field but the instance count is constant, and the scan writes that
    -- one. So the arguments are seeded once here rather than by a compute pass
    -- that reruns every frame to write the same five numbers back.
    local args = loader.newArray("uint32_t[8]")
    args[0] = QUAD_INDICES
    for slot = 1, 7 do args[slot] = 0 end
    self._drawArgs:upload(args, 32)

    -- Two triangles over four corners, uploaded once and never touched again.
    self._indices = Buffer.create(device, {
        usage = { "index" },
        size = QUAD_INDICES * 2,
    })
    local quad = loader.newArray("uint16_t[6]")
    quad[0], quad[1], quad[2] = 0, 1, 2
    quad[3], quad[4], quad[5] = 1, 3, 2
    self._indices:upload(quad, QUAD_INDICES * 2)

    self._view = Camera.create()
    -- Two vec4s: the world rectangle the camera sees, then the counts.
    self._cullUniform = loader.newArray("float[8]")
    self._layerUniform = loader.newArray("float[?]", LAYER_FLOATS)
    -- Below every revision the table can hold, so the first frame packs it.
    self._layerRevision = -1

    -- Every region starts clipping nothing, so an index nobody configured
    -- draws the same as region zero rather than making its contents vanish.
    self._clipUniform = loader.newArray("float[?]", CLIP_FLOATS)
    for entry = 0, instancelayout.CLIPS - 1 do
        local base = entry * 4
        self._clipUniform[base] = -CLIP_UNBOUNDED
        self._clipUniform[base + 1] = -CLIP_UNBOUNDED
        self._clipUniform[base + 2] = CLIP_UNBOUNDED
        self._clipUniform[base + 3] = CLIP_UNBOUNDED
    end

    self._mark = ComputePipeline.load(device, "instance.mark.comp", {})
    self._scan = ComputePipeline.load(device, "instance.scan.comp", {})
    self._compact = ComputePipeline.load(device, "instance.compact.comp", {})

    self.deferred = Deferred.create(device, swapchainFormat, {
        ambient = options.ambient,
        geometry = function(context: Deferred.PassContext)
            if self.count == 0 then return end
            context.pass:bindPipeline(self.pipeline.handle)

            context.pass:pushVertexUniform(0,
                self._view:matrix(context.width, context.height), 64)
            context.pass:pushVertexUniform(1,
                layerUniform(self, context.width, context.height), LAYER_BYTES)
            -- Once for the whole scene, and only the fragments of an instance
            -- that named a region ever read it.
            context.pass:pushFragmentUniform(0, self._clipUniform, CLIP_BYTES)
            context.pass:bindVertexStorageBuffers(0,
                { self.instances.handle, self._visible.handle,
                    self._playbacks.handle })
            context.pass:bindTextures(0, { self.images.handle }, self.sampler.handle)
            context.pass:bindIndexBuffer(self._indices.handle)
            -- One draw for the scene, with its instance count decided by the
            -- cull rather than by anything here.
            context.pass:drawIndexedIndirect(self._drawArgs.handle, 0, 1)
        end,
    })

    self.pipeline = buildGeometry(self)

    return self
end

--- Maps a staging slot and hands back the instance and bounds addresses.
---
--- Cycling is off: the slot being handed over is not the one a frame in flight
--- is copying out of, so there is nothing to move out of the way. Cycling would
--- pay for that guarantee with a fresh driver allocation every frame, which at
--- four million instances is over three hundred megabytes a frame retired and
--- reallocated, and the driver cannot reclaim it fast enough.
--- @return The instance staging as floats, then the bounds staging as floats.
function Backend:mapSlot(slot: integer): loader.CArray, loader.CArray
    return self.instances:mapSlotAs(slot, "float *", false),
        self._bounds:mapSlotAs(slot, "float *", false)
end

--- Uploads a decoded image into the array and returns the region it occupies.
function Backend:addImage(pixels: loader.CValue, width: integer,
                          height: integer,
                          pitch: integer): TextureArray.Region
    return self.images:add(pixels, width, height, pitch)
end

--- Writes a decoded image over one the array already holds.
---
--- The region is unchanged by this and stays the answer for that image, which
--- is why nothing outside has to hear about it. Raises on a size that would
--- need a different rect.
function Backend:replaceImage(region: TextureArray.Region,
                              pixels: loader.CValue, width: integer,
                              height: integer, pitch: integer)
    self.images:replace(region, pixels, width, height, pitch)
end

--- Rebuilds every pipeline from the shader sources as they read now.
---
--- What makes a shader reload reach the screen. The sources are re-read by
--- whoever asked for the reload; this is the device's half, and it is the half
--- that has to know the formats the G-buffer was created with and which
--- compute shaders the cull is three passes of.
---
--- Every pass binds its pipeline through `self` as it executes, so swapping the
--- objects in place is picked up by the next frame and the pass graph is not
--- rebuilt. Must not run inside a pass: this releases handles a recorded pass
--- would still be reading, which is what the wait it opens with is for.
---
--- Nothing is released until everything has been built, so a source that no
--- longer compiles raises and leaves the process drawing exactly what it drew.
function Backend:rebuildPipelines()
    local device <const> = self._device
    C.SDL_WaitForGPUIdle(device)

    local pipeline: GraphicsPipeline = nil
    local mark: ComputePipeline = nil
    local scan: ComputePipeline = nil
    local compact: ComputePipeline = nil
    local built, reason = pcall(function(): string
        pipeline = buildGeometry(self)
        mark = ComputePipeline.load(device, "instance.mark.comp", {})
        scan = ComputePipeline.load(device, "instance.scan.comp", {})
        compact = ComputePipeline.load(device, "instance.compact.comp", {})
    end)
    if not built then
        if pipeline ~= nil then pipeline:destroy() end
        if mark ~= nil then mark:destroy() end
        if scan ~= nil then scan:destroy() end
        if compact ~= nil then compact:destroy() end
        error(reason, 0)
    end

    local oldPipeline <const> = self.pipeline
    local oldMark <const> = self._mark
    local oldScan <const> = self._scan
    local oldCompact <const> = self._compact
    self.pipeline = pipeline
    self._mark = mark
    self._scan = scan
    self._compact = compact
    oldPipeline:destroy()
    oldMark:destroy()
    oldScan:destroy()
    oldCompact:destroy()

    -- Last, because a failure above must leave the lighting and composite
    -- pipelines alone as well: half a reload is harder to reason about than
    -- none of one.
    self.deferred:rebuildPipelines()
end

--- Fails on a region index outside the table.
local function checkClipIndex(index: integer, level: integer)
    if index == nil or index ~= math.floor(index)
        or index < 1 or index >= instancelayout.CLIPS then
        error(("tecs: a clip region is numbered 1 to %d, not %s")
            :format(instancelayout.CLIPS - 1, tostring(index)), level + 1)
    end
end

--- Points region `index` at a rectangle in target pixels.
---
--- Fragments of an instance carrying `Clip(index)` are kept where they land
--- inside the rectangle and thrown away where they do not, whatever placed
--- them there. Region zero is not a region and cannot be set: it is what an
--- instance says when it wants no clipping at all.
---
--- A region is one rectangle. Whoever sets it up owns the nesting, so a panel
--- within a panel is set as the intersection of the two and the fragment tests
--- once rather than walking a chain.
function Backend:setClipRegion(index: integer, region: ClipRegion)
    checkClipIndex(index, 3)
    if region == nil then
        error("tecs: setClipRegion needs a rectangle; clearClipRegion "
            .. "is how a region stops clipping", 3)
    end

    -- Stored as bounds rather than as position and size, because that is what
    -- the comparison wants and the shader would otherwise redo the addition
    -- for every fragment.
    local base <const> = index * 4
    local data <const> = self._clipUniform
    data[base] = region.x
    data[base + 1] = region.y
    data[base + 2] = region.x + region.width
    data[base + 3] = region.y + region.height
end

--- Stops region `index` clipping anything.
---
--- The region goes back to what it was before anyone set it, so instances
--- still pointing at it draw whole rather than disappearing. An adapter handing
--- indices out and taking them back therefore leaves nothing behind that
--- silently removes content.
function Backend:clearClipRegion(index: integer)
    checkClipIndex(index, 3)
    local base <const> = index * 4
    local data <const> = self._clipUniform
    data[base] = -CLIP_UNBOUNDED
    data[base + 1] = -CLIP_UNBOUNDED
    data[base + 2] = CLIP_UNBOUNDED
    data[base + 3] = CLIP_UNBOUNDED
end

--- Uploads what a packet describes, culls, and runs the pipeline.
---
--- The cull runs on the frame's command buffer, after the upload and before
--- the passes that consume it, so SDL orders all three without anything here
--- having to wait.
---
--- The packet's ranges are what is copied. The device buffers are persistent
--- and hold every earlier frame's bytes, so a packet carries the delta and
--- never a snapshot.
function Backend:consume(packet: FramePacket, frame: Frame)
    local slot <const> = packet.slot
    self.instances:markSlotRanges(slot, packet.instanceRanges)
    self._bounds:markSlotRanges(slot, packet.boundsRanges)
    self.instances:flushSlot(slot, frame.commandBuffer)
    self._bounds:flushSlot(slot, frame.commandBuffer)

    -- Content rather than per-frame data, so it is written when it moves and
    -- not when it is read. The revision also moves when a sheet is rebound,
    -- since that changes every region the table copied, which is what makes a
    -- rebind cost one upload here instead of a write to every entity playing it.
    local revision <const> = frametable.revision()
    if revision ~= self._playbackRevision then
        self._playbackRevision = revision
        local data, count = frametable.floats()
        if count > PLAYBACK_FLOATS then
            error(("tecs: the animation frame table needs %d floats and the "
                .. "buffer holds %d"):format(count, PLAYBACK_FLOATS), 2)
        end
        self._playbacks:write(0, data as loader.CValue, count * 4)
        self._playbacks:flush(frame.commandBuffer)
    end

    self._stepClock = packet.stepClock
    self.count = packet.count
    local view <const> = self._view
    view.x = packet.cameraX
    view.y = packet.cameraY
    view.zoom = packet.cameraZoom
    view.rotation = packet.cameraRotation
    self.deferred:setLightData(packet.lights, packet.lightCount)

    if self.count > 0 then
        local groups = math.ceil(self.count / CULL_GROUP)
        local bounds = view:viewBounds(frame.width, frame.height)
        self._cullUniform[0] = bounds[1]
        self._cullUniform[1] = bounds[2]
        self._cullUniform[2] = bounds[3]
        self._cullUniform[3] = bounds[4]
        self._cullUniform[4] = self.count
        self._cullUniform[5] = groups

        -- Mark, scan, compact. Each pass reads what the one before it wrote,
        -- and SDL orders them because each declares what it writes.
        local mark = ComputePass.begin(frame.commandBuffer,
            { self._slots.handle, self._blocks.handle })
        mark:bindPipeline(self._mark.handle)
        mark:bindStorageBuffers(0, { self._bounds.handle })
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0,
            self._cullUniform, 32)
        mark:dispatch(groups)
        mark:finish()

        local scan = ComputePass.begin(frame.commandBuffer,
            { self._blocks.handle, self._drawArgs.handle })
        scan:bindPipeline(self._scan.handle)
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0,
            self._cullUniform, 32)
        scan:dispatch(1)
        scan:finish()

        local compact = ComputePass.begin(frame.commandBuffer,
            { self._visible.handle })
        compact:bindPipeline(self._compact.handle)
        compact:bindStorageBuffers(0,
            { self._slots.handle, self._blocks.handle })
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0,
            self._cullUniform, 32)
        compact:dispatch(groups)
        compact:finish()
    end

    self.deferred:render(frame)
end

--- The composited image the last frame produced.
---
--- The lit target rather than the swapchain, because a swapchain texture
--- belongs to the presenter once the frame is submitted while this one
--- persists and can be read at any point between frames. What it does not
--- include is anything drawn after compose, which today is nothing.
function Backend:captureTexture(): Texture
    return self.deferred.graph:texture("lit")
end

--- Releases everything the backend owns. Safe to call more than once.
function Backend:destroy()
    if self._destroyed then return end
    self._destroyed = true
    self.pipeline:destroy()
    self.deferred:destroy()
    self.instances:destroy()
    self.sampler:destroy()
    self.images:destroy()
    self._bounds:destroy()
    self._slots:destroy()
    self._blocks:destroy()
    self._visible:destroy()
    self._drawArgs:destroy()
    self._indices:destroy()
    self._playbacks:destroy()
    self._mark:destroy()
    self._scan:destroy()
    self._compact:destroy()
end

return Backend
