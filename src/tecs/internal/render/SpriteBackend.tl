--[=[
Turns a frame packet into a submitted frame.

The device-facing half of rendering. It owns the device buffers, the
staging slots, the cull, the deferred pass graph and the image array. It
knows nothing about worlds, queries, archetypes or components: everything it
draws arrives as bytes already in staging plus a packet saying what changed,
so it is testable against a device with no world behind it.

Images live in one array texture, so the texture is a per-instance integer
and the whole scene is one draw. That is also what frees the instance
layout: with nothing to sort by, each archetype keeps a contiguous run, and
a run whose components did not change does not have to be rewritten.

What is drawn is decided on the GPU. A compute pass tests each instance
against the view, compacts the survivors into an index list, and writes the
draw arguments, so the draw touches only what is visible and the CPU never
learns how many that was. The instance buffer stays archetype-contiguous
for the dirty gate; the compacted list is rebuilt every frame and is a
separate array, so the two do not fight.
]=]

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
local Camera2D <const> = require("tecs.gfx.Camera2D")
local SpriteFramePacket <const> = require("tecs.internal.render.SpriteFramePacket")
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

--- Bytes every cull dispatch is pushed: three vec4s, and the same block every
--- one of the shaders declares.
local CULL_BYTES <const> = 48

--- Which lane's rank a compaction reads out of a packed slot. `LANE_OPAQUE`,
--- `LANE_BLEND` and `LANE_CAST` in `assets/shaders/include/cull.glsl` are the
--- same three indices, and the set only works while they agree.
local LANE_OPAQUE <const> = 0
local LANE_BLEND <const> = 1
local LANE_CAST <const> = 2

--- Entries the shadow lane emits per caster, and `instancelayout.CAST_FANOUT`.
local CAST_FANOUT <const> = instancelayout.CAST_FANOUT

--- Casters the shadow lane holds, whatever the instance buffer holds.
---
--- A ceiling rather than a hint, for the reason `MAX_BLEND` is one. A shadow
--- list as long as a four million instance world times the fan-out would be
--- sixty-four megabytes to describe a scene whose casters are a handful of
--- walls and a crowd, and past this the remainder is dropped rather than
--- reported: a caster's whole run is dropped rather than half of it, since half
--- a run would leave the rest holding an earlier frame's entries.
local MAX_CAST <const> = 16384

--- Depth buckets the forward list is sorted into, and the same number as
--- `BUCKETS` in `assets/shaders/instance.rank.comp.glsl`. It is also that
--- shader's workgroup size, because a thread there owns a bucket, and the three
--- only work while they agree.
---
--- What it costs is a uint per bucket per block of the forward list, and what
--- it buys is the resolution the sort has: two blended instances whose depths
--- differ by less than one part in this many draw in the order the compaction
--- gave them, which is the order the depth test already resolves opaque
--- geometry in.
local BLEND_BUCKETS <const> = 256

--- Instances the forward list holds, whatever the instance buffer holds.
---
--- A ceiling rather than a hint. The sort's counts table is a bucket per block
--- of this, so a forward list as long as a four million instance world would be
--- a table larger than the world and a scan nobody could afford. Blended
--- content is a minority of a scene by construction, and past this the
--- remainder is dropped rather than reported, for the reason `setLightData`
--- drops a light: the alternative is a frame that raises over geometry nobody
--- would have picked out of the image.
local MAX_BLEND <const> = 65536

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
    --- Caller-writable. Sets the left edge in target pixels.
    x: number
    --- Caller-writable. Sets the top edge in target pixels.
    y: number
    --- Caller-writable. Sets the width in target pixels.
    width: number
    --- Caller-writable. Sets the height in target pixels.
    height: number
end

--- Something that writes instances with compute before the cull runs.
---
--- The pool a particle emitter draws from is the caller this exists for. Its
--- contents outlive the frame, so it is not written through staging the way an
--- archetype run is, and what it writes has to land before the mark pass reads
--- the bounds beside it. A stage is recorded on the frame's command buffer
--- between the staging flush and the cull, and SDL orders all three because
--- each declares what it writes.
local record ComputeStage
    --- Whether this stage has anything to record this frame.
    ---
    --- Asked every frame rather than derived from a dirty bit, because the
    --- thing this exists for dirties nothing: an emitter's whole field moves
    --- every frame while the world holding it reports no change at all. There
    --- is no bit to read, so the stage has to publish the answer.
    active: function(self: ComputeStage): boolean

    --- Records its dispatches onto `frame`'s command buffer.
    ---
    --- The instance and bounds buffers are handed over rather than reached
    --- for, because writing them is the whole point of being here and a stage
    --- that had to find them would be a stage that could find something else.
    record: function(self: ComputeStage, frame: Frame, instances: Buffer, bounds: Buffer)

    --- Releases what the stage owns, called when the backend is destroyed.
    ---
    --- A stage's buffers and pipelines are built on the backend's device, so
    --- they cannot outlive it and nothing else is holding them: a world that
    --- installed a stage and then dropped its renderer would leak every one of
    --- them otherwise. Must be safe to call more than once.
    destroy: function(self: ComputeStage)
end

--- What a backend is built with. Required, unlike most options tables here:
--- `capacity` has no default at this level and the renderer above always
--- supplies one.
local record SpriteBackendOptions
    --- Instances the buffers are sized for. A ceiling: nothing grows to admit
    --- a row past it.
    capacity: integer
    --- Cell size of the image array, in pixels, square. Defaults to 512, and
    --- no image may exceed it.
    cell: integer
    --- Layers the image array holds, including the white default in layer
    --- zero. Defaults to 64, and a count above `instancelayout.LAYER_SLOTS`
    --- fails at construction because a layer number shares its float with the
    --- clip index.
    layers: integer
    --- Fit many images into each layer rather than one. Defaults to false.
    packImages: boolean
end

--- The device half of the renderer, as one object.
---
--- Built once against a device and renderer-owned deferred pipeline, then
--- handed one packet per frame through `prepare`. Everything below is created
--- here and released by `destroy`, including any compute stage that was added;
--- nothing outlives it except the device and deferred pipeline it borrows.
local record SpriteBackend
    --- Re-exported so a caller naming a rectangle types it from the module
    --- that takes one, rather than reaching for a second require.
    type ClipRegion = ClipRegion
    --- Re-exported for whoever implements one and hands it to
    --- `addComputeStage`.
    type ComputeStage = ComputeStage
    --- Re-exported for whoever assembles the table `create` takes.
    type Options = SpriteBackendOptions

    --- The renderer-owned deferred pipeline whose sprite passes this backend
    --- records. The backend borrows it and never destroys it.
    deferred: Deferred
    --- The instance buffer the scene is drawn from, with the staging slots the
    --- extractor writes through behind it. A compute stage writes its own
    --- region of the device side directly instead.
    instances: Buffer
    --- Draws the compacted opaque list into the G-buffer, depth written and
    --- color replaced. Swapped in place by `rebuildPipelines`, so nothing may
    --- hold it across a reload.
    pipeline: GraphicsPipeline
    --- Draws the forward list over the composited image, with premultiplied
    --- blending baked in and the geometry pass's depth attached and not written.
    --- One pipeline for both blend modes: the fragment shader chooses between
    --- blending over and adding by what it writes into alpha.
    blendPipeline: GraphicsPipeline
    --- Nearest and clamped, and the only sampler the instance passes bind:
    --- every image shares one binding, so they share its filtering too.
    sampler: Sampler
    --- Every image, one binding, so the scene is one draw.
    images: TextureArray
    --- Instances the buffers are sized for. A ceiling, not a hint: rows past
    --- it are dropped upstream rather than grown into.
    capacity: integer
    --- Instances the forward list holds, which is `MAX_BLEND` or the whole
    --- buffer where that is smaller.
    blendCapacity: integer
    --- Entries the shadow list holds: `MAX_CAST` casters, or the whole buffer
    --- where that is smaller, times the fan-out.
    castCapacity: integer
    --- Copied from the packet at each `consume`, and what the geometry and
    --- forward passes test before they record anything: at zero both return
    --- without binding, and no cull is dispatched.
    count: integer
    --- UV extent of the white pixel within its cell, published to whoever
    --- writes instances: an image smaller than a cell does not reach the
    --- cell's edge, so sampling 0..1 would read the undefined remainder.
    whiteU0: number
    --- Top edge of that rect. V runs down, so this is the smaller of the two.
    whiteV0: number
    --- Right edge of it.
    whiteU1: number
    --- Bottom edge of it.
    whiteV1: number
    --- The opaque lane's three passes: the view test that packs a rank per
    --- lane into a slot, the single-workgroup scan that turns per-block counts
    --- into per-block bases, and the write of each survivor at its base plus
    --- its rank.
    _mark: ComputePipeline
    --- Dispatched three times a frame that blends: over the opaque lane's
    --- blocks, over the forward lane's, and over the forward lane's bucket
    --- table. What it folds arrives in the uniform, so one pipeline serves all
    --- three.
    _scan: ComputePipeline
    --- Dispatched once per lane, told by the uniform which of the two ranks
    --- packed into a slot it is reading.
    _compact: ComputePipeline
    --- The two passes that turn the compacted forward list into a sorted one.
    _rank: ComputePipeline
    --- Reads the bases the bucket scan left and writes each entry where its
    --- bucket and its rank put it.
    _place: ComputePipeline
    --- Center xy and half extent xy per instance, and the only buffer the view
    --- test reads. Apart from the instance because it is read for every entity
    --- every frame, drawn or not; the sign of the first half extent is also
    --- where the lane is read from.
    _bounds: Buffer
    --- A rank per lane per instance, packed into one word: the opaque lane in
    --- the low half and the forward lane in the high half. One buffer rather
    --- than two, because a rank is an offset within a workgroup of 256 and two
    --- of them fit in the word the mark pass already writes.
    _slots: Buffer
    --- Survivors of the opaque lane per workgroup of 256, rewritten in place
    --- by the scan as the offset each block's run starts at in `_visible`.
    _blocks: Buffer
    --- The compacted opaque list, an instance index per entry in instance
    --- order. As long as the instance buffer, and meaningful only up to the
    --- count the scan wrote into the draw arguments.
    _visible: Buffer
    --- The geometry draw's `SDL_GPUIndexedIndirectDrawCommand`. Every field
    --- but the instance count is seeded at creation and never touched again;
    --- the scan writes that one, and the CPU never reads it back.
    _drawArgs: Buffer
    --- Survivors of the forward lane per block, then the compacted list, then
    --- its draw arguments. The same three the opaque lane has, and the
    --- compaction that fills them is the same shader run against them.
    _blendBlocks: Buffer
    --- In instance order, which is where extraction put a row rather than
    --- where the scene put it, so this is what the sort reads and never what
    --- is drawn.
    _blendVisible: Buffer
    --- Also read by compute: the three passes after the scan take the entry
    --- count from here rather than being told it.
    _blendArgs: Buffer
    --- What the depth sort works in: a bucket and a within-bucket rank per
    --- entry, a count per bucket per block, and the list the sort produces.
    --- The last is what the forward draw walks; `_blendVisible` is what it was
    --- built from and is never drawn.
    _blendBucket: Buffer
    --- How many earlier entries of the same block share the entry's bucket,
    --- which is its offset within that block's run of it.
    _blendRank: Buffer
    --- Bucket major, a block per 256 entries, so folding the whole table puts
    --- every block of a farther bucket ahead of the first block of a nearer
    --- one. Rewritten in place by the scan as bases.
    _blendCounts: Buffer
    --- Back to front, and the only forward list the draw walks.
    _blendSorted: Buffer
    --- Fills the shadow list, one run of `CAST_FANOUT` entries per caster, and
    --- the only compaction that chooses what an entry says rather than copying
    --- an index. Nil while shadows are off.
    _castCompact: ComputePipeline
    --- Survivors of the shadow lane per block, allocated whatever the pipeline
    --- was configured with, because the mark pass writes it for every world.
    _castBlocks: Buffer
    --- The shadow list: an instance and a light per entry, four bytes each.
    --- Nil while shadows are off.
    _castList: Buffer
    --- Its draw arguments, shared by all three shadow draws: each walks the
    --- whole list and rejects what is not its own, so all three have the same
    --- instance count and it is the one the scan wrote.
    _castArgs: Buffer
    --- Draws a caster's silhouette into the occluder mask, resolving overlap by
    --- max so the tallest occluder wins. Nil while shadows are off.
    _maskPipeline: GraphicsPipeline
    --- Draws a stretched copy of a caster into the drop-shadow target,
    --- resolving overlap by min so the darkest shadow wins.
    _shadowPipeline: GraphicsPipeline
    --- Draws the caster back over its own shadow at full brightness, by max.
    _stampPipeline: GraphicsPipeline
    --- The camera the mask is drawn with, which is the scene's at another zoom.
    --- A second one rather than the scene's, because both are live within one
    --- frame and one of them would have to be put back.
    _maskView: Camera2D
    --- Blocks the forward list's own dispatches cover, which is its capacity
    --- rather than the frame's count: every block of the counts table has to be
    --- written every frame or the scan folds a stale one.
    _blendGroups: integer
    --- Whether the last packet said anything was blended. The whole forward
    --- lane is skipped when nothing is, so a world that blends nothing pays for
    --- this in one branch and one empty render pass.
    _blending: boolean
    --- Whether the last packet reported any sprite caster. The renderer keeps
    --- its shadow attachments valid every frame, but the sprite domain skips
    --- both caster compaction and pass recording when this is false.
    _casting: boolean
    --- Two triangles over four corners, uploaded once and never touched again.
    --- The only geometry either draw binds: there is no vertex stream, and a
    --- quad's corner comes from the vertex index while everything about the
    --- instance comes from a storage buffer.
    _indices: Buffer
    --- Frame tables every animated instance resolves against, and the revision
    --- the resident copy was uploaded from. Uploaded when it moves rather than
    --- per frame: it is content, and the frame that registers an animation is
    --- the rare one.
    _playbacks: Buffer
    --- Starts below every revision the table can report, so the first frame
    --- uploads whatever is there rather than leaving the buffer unwritten.
    _playbackRevision: integer
    --- Copied from the packet at each `consume` and pushed in the layer
    --- uniform, so every pass of one frame resolves an animation against one
    --- number.
    _stepClock: number
    --- Where the packet said the view was. A calculator for the matrix and the
    --- view bounds rather than the camera a game holds, which lives on the
    --- other side of the boundary and is copied into every packet.
    _view: Camera2D
    --- The eight floats every cull dispatch is pushed from: the world
    --- rectangle the view covers as minimum xy then maximum xy, then the
    --- instance count, the workgroups to fold over, the destination list's
    --- capacity, and which lane's rank a compaction reads. The last three are
    --- rewritten between dispatches, so it is one uniform and a push each.
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
    --- Stages recorded between the staging flush and the cull, in the order
    --- they were added. Empty on a world that installed nothing that writes
    --- instances with compute, which is what makes that world pay nothing.
    _stages: {ComputeStage}
    --- The buffer and texture lists the frame path hands the pass API, one per
    --- call site and each of a fixed length. Held rather than built per frame,
    --- and rewritten at every use rather than filled once: a buffer that grew
    --- has a new handle, and a list holding the old one binds freed memory.
    _geometryBuffers: {loader.CValue}
    --- The image array, which is the whole of the geometry pass's texture
    --- binding.
    _geometryTextures: {loader.CValue}
    --- The same three the geometry pass binds, with the sorted forward list in
    --- place of the compacted opaque one.
    _forwardBuffers: {loader.CValue}
    --- The image array again. A list of its own rather than the geometry
    --- pass's, since both are live within one frame.
    _forwardTextures: {loader.CValue}
    --- The slot table and both lanes' per-block counts.
    _markWrites: {loader.CValue}
    --- The bounds, which is everything the view test reads.
    _markReads: {loader.CValue}
    --- The opaque lane's block counts, rewritten in place as bases, and the
    --- draw arguments the total lands in.
    _scanWrites: {loader.CValue}
    --- The compacted opaque list.
    _compactWrites: {loader.CValue}
    --- The slot table and the bases the scan left in the opaque lane's blocks.
    _compactReads: {loader.CValue}
    --- The forward lane's block counts and draw arguments, the same pair the
    --- opaque scan writes.
    _blendScanWrites: {loader.CValue}
    --- The compacted forward list.
    _blendCompactWrites: {loader.CValue}
    --- The same slot table the opaque compaction read, and the forward lane's
    --- bases.
    _blendCompactReads: {loader.CValue}
    --- A bucket and a within-block rank per entry, and the counts table the
    --- bucket scan folds.
    _rankWrites: {loader.CValue}
    --- The instances, for the depth the bucket is derived from; the compacted
    --- forward list, for which instance an entry names; and its draw
    --- arguments, for how many entries there are.
    _rankReads: {loader.CValue}
    --- The counts table, rewritten as bases, and the draw arguments again.
    _bucketScanWrites: {loader.CValue}
    --- The sorted forward list.
    _placeWrites: {loader.CValue}
    --- Everything the two passes before it produced, plus the entry count.
    _placeReads: {loader.CValue}
    --- The shadow lane's block counts, rewritten in place as bases, and its
    --- draw arguments.
    _castScanWrites: {loader.CValue}
    --- The shadow list.
    _castCompactWrites: {loader.CValue}
    --- The slot table, the lane's bases, the bounds a role is read from, and
    --- the lights a caster chooses between.
    _castCompactReads: {loader.CValue}
    --- The instances, the shadow list, the frame tables and the lights, which
    --- is what places one entry.
    _castBuffers: {loader.CValue}
    --- The image array, for the coverage test a silhouette comes from.
    _castTextures: {loader.CValue}
    --- The cull passes, begun again each frame rather than allocated per
    --- frame; see `ComputePass.begin` for what that asks of a caller. Nil
    --- until the first frame that culls anything.
    _markPass: ComputePass
    --- One workgroup, whatever the world holds: it folds blocks, not
    --- instances.
    _scanPass: ComputePass
    --- Dispatched over every resident instance, as the mark pass is.
    _compactPass: ComputePass
    --- The forward lane's five, and nil until the first frame that blends
    --- anything rather than the first that culls.
    _blendScanPass: ComputePass
    --- Dispatched over every resident instance too: both lanes are packed into
    --- the one slot table, so both compactions walk all of it.
    _blendCompactPass: ComputePass
    --- Dispatched over the forward list's own blocks, all of them however few
    --- entries survived, because the scan below folds every entry of the
    --- counts table and a block left unwritten would fold a stale one.
    _rankPass: ComputePass
    --- One workgroup over the counts table, which is bucket major.
    _bucketScanPass: ComputePass
    --- Over the forward list's blocks again, as the rank pass was.
    _placePass: ComputePass
    --- The shadow lane's two, and nil until the first frame a pipeline with
    --- shadows on culls anything.
    _castScanPass: ComputePass
    --- Dispatched over every resident instance, as both other compactions are:
    --- all three lanes are packed into the one slot table.
    _castCompactPass: ComputePass
    --- The `SDL_GPUDevice` every handle here was created against. Not owned:
    --- `destroy` releases what was built on it and never the device itself.
    _device: loader.CPtr
    --- Set by the first `destroy`, which is what makes a second one return
    --- rather than release a handle twice.
    _destroyed: boolean
end

local SpriteBackendMT <const>: metatable<SpriteBackend> = {__index = SpriteBackend}

--- Fills the uniform the vertex shader reads a layer's behavior from.
---
--- The camera's parameters rather than a matrix for each mode. Parallax
--- multiplies the camera's position, so a matrix per mode would have to be a
--- matrix per layer and be rebuilt every frame the camera moved. Passed this
--- way, the camera's position, its reciprocal zoom and two clip scales compose
--- all four cases in a handful of shader instructions, and the sixteen entries
--- stay what they were.
local function layerUniform(self: SpriteBackend, width: number, height: number): loader.CArray
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
            data[base], data[base + 1], data[base + 2], data[base + 3] = layers.entryOf(layer)
        end
    end

    return data
end

--- Builds the geometry pipeline against the G-buffer the deferred pass owns.
---
--- One description of it, shared by creation and by a reload, so the pipeline a
--- reload installs cannot disagree with the one the backend started with.
local function buildGeometry(self: SpriteBackend): GraphicsPipeline
    local device <const> = self._device
    local albedoFormat, normalFormat, ormFormat, emissionFormat = self.deferred:geometryFormats()
    local vertex = Shader.load(device, "instance.vert", {})
    local fragment = Shader.load(device, "instance.frag", {})
    local pipeline = GraphicsPipeline.create(
        device,
        {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormats = {albedoFormat, normalFormat, ormFormat, emissionFormat},
            depth = self.deferred:geometryDepth(),
            name = "ecs.instances",
        }
    )
    vertex:destroy()
    fragment:destroy()
    return pipeline
end

--- Builds one of the three pipelines a shadow draw binds. The fourth a scene
--- with shadows on builds is the mask blur, which draws no instances and so is
--- the deferred pipeline's rather than this half's.
---
--- One vertex shader and one fragment shader for all three, because all three
--- place a quad from the same instance against the same list and read the same
--- coverage out of the same material dispatch. What differs is the target and
--- the blend, which is what a pipeline is.
--- @param format The attachment's format, from `Deferred:castFormats`.
--- @param mode "max" for the mask and the stamp, "min" for the shadows
---     themselves, and neither may depend on which fragment the device
---     rasterised first.
local function buildCast(self: SpriteBackend, format: integer, mode: integer, name: string): GraphicsPipeline
    local device <const> = self._device
    local vertex = Shader.load(device, "cast.vert", {})
    local fragment = Shader.load(device, "cast.frag", {})
    local pipeline = GraphicsPipeline.create(
        device,
        {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormat = format,
            blendMode = mode,
            name = name,
        }
    )
    vertex:destroy()
    fragment:destroy()
    return pipeline
end

--- Records one shadow draw: the whole list, at the projection and the mode the
--- draw is.
---
--- The three differ in a pipeline and a number, so they are one function. Every
--- draw walks the whole list because an entry says which of the three it is
--- for, and the two it is not for reject it in the vertex shader at the cost of
--- four invocations that return an off-screen position.
local function recordCast(
    self: SpriteBackend, context: Deferred.PassContext, pipeline: GraphicsPipeline, matrix: loader.CArray, mode: integer
)
    context.pass:bindPipeline(pipeline.handle)
    context.pass:pushVertexUniform(0, self.deferred:castUniform(matrix, mode), Deferred.castUniformSize())

    local buffers <const> = self._castBuffers
    buffers[1] = self.instances.handle
    buffers[2] = self._castList.handle
    buffers[3] = self._playbacks.handle
    buffers[4] = self.deferred:lightHandle()
    context.pass:bindVertexStorageBuffers(0, buffers)

    local textures <const> = self._castTextures
    textures[1] = self.images.handle
    context.pass:bindTextures(0, textures, self.sampler.handle)
    context.pass:bindIndexBuffer(self._indices.handle)
    context.pass:drawIndexedIndirect(self._castArgs.handle, 0, 1)
end

--- Builds the forward pipeline against the target the composite pass wrote.
---
--- The same vertex shader the G-buffer pass uses, because a blended instance is
--- placed exactly as an opaque one is and only its shading and its blend
--- differ. What differs here is one color target instead of four, a blend
--- instead of replace, and depth tested but not written.
---
--- Premultiplied rather than straight alpha, and one pipeline rather than two.
--- The fragment shader scales its color by its own alpha either way; what it
--- writes into alpha is what chooses the mode, so blending over and adding come
--- out of this pipeline and are drawn in one indirect draw off one sorted list.
--- Two pipelines would mean two draws, and an additive instance would then land
--- after every alpha-blended one in the frame whatever their depths said.
local function buildForward(self: SpriteBackend): GraphicsPipeline
    local device <const> = self._device
    local vertex = Shader.load(device, "instance.vert", {})
    local fragment = Shader.load(device, "instance.forward.frag", {})
    local pipeline = GraphicsPipeline.create(
        device,
        {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormat = self.deferred:forwardFormat(),
            depth = self.deferred:forwardDepth(),
            blendMode = GraphicsPipeline.BLEND_PREMULTIPLIED,
            name = "ecs.forward",
        }
    )
    vertex:destroy()
    fragment:destroy()
    return pipeline
end

--- Records sprite silhouettes into the renderer-owned occluder pass.
--- @param context The deferred graph supplies the open pass and current frame.
function SpriteBackend:recordOccluders(context: Deferred.PassContext)
    if self.count == 0 or not self._casting then
        return
    end
    local view <const> = self._maskView
    view.x, view.y, view.zoom, view.rotation = self.deferred:maskView()
    local frame <const> = context.frame
    recordCast(self, context, self._maskPipeline, view:matrix(frame.width, frame.height), Deferred.MASK)
end

--- Records sprite drop shadows and their caster stamps.
--- @param context The deferred graph supplies the open pass and current frame.
function SpriteBackend:recordDropShadows(context: Deferred.PassContext)
    if self.count == 0 or not self._casting then
        return
    end
    local frame <const> = context.frame
    local matrix <const> = self._view:matrix(frame.width, frame.height)
    recordCast(self, context, self._shadowPipeline, matrix, Deferred.SHADOW)
    recordCast(self, context, self._stampPipeline, matrix, Deferred.STAMP)
end

--- Records the opaque sprite geometry pass after `prepare` has culled it.
--- @param context The deferred graph supplies the open pass and current frame.
function SpriteBackend:recordGeometry(context: Deferred.PassContext)
    if self.count == 0 then
        return
    end
    context.pass:bindPipeline(self.pipeline.handle)
    context.pass:pushVertexUniform(0, self._view:matrix(context.width, context.height), 64)
    context.pass:pushVertexUniform(1, layerUniform(self, context.width, context.height), LAYER_BYTES)
    context.pass:pushFragmentUniform(0, self._clipUniform, CLIP_BYTES)

    local buffers <const> = self._geometryBuffers
    buffers[1] = self.instances.handle
    buffers[2] = self._visible.handle
    buffers[3] = self._playbacks.handle
    context.pass:bindVertexStorageBuffers(0, buffers)

    local textures <const> = self._geometryTextures
    textures[1] = self.images.handle
    context.pass:bindTextures(0, textures, self.sampler.handle)
    context.pass:bindIndexBuffer(self._indices.handle)
    context.pass:drawIndexedIndirect(self._drawArgs.handle, 0, 1)
end

--- Records the sorted forward sprite pass after `prepare` has culled it.
--- @param context The deferred graph supplies the open pass and current frame.
function SpriteBackend:recordForward(context: Deferred.PassContext)
    if self.count == 0 or not self._blending then
        return
    end
    context.pass:bindPipeline(self.blendPipeline.handle)
    context.pass:pushVertexUniform(0, self._view:matrix(context.width, context.height), 64)
    context.pass:pushVertexUniform(1, layerUniform(self, context.width, context.height), LAYER_BYTES)
    context.pass:pushFragmentUniform(0, self._clipUniform, CLIP_BYTES)
    self.deferred:bindLighting(context)

    local buffers <const> = self._forwardBuffers
    buffers[1] = self.instances.handle
    buffers[2] = self._blendSorted.handle
    buffers[3] = self._playbacks.handle
    context.pass:bindVertexStorageBuffers(0, buffers)

    local textures <const> = self._forwardTextures
    textures[1] = self.images.handle
    context.pass:bindTextures(0, textures, self.sampler.handle)
    context.pass:bindIndexBuffer(self._indices.handle)
    context.pass:drawIndexedIndirect(self._blendArgs.handle, 0, 1)
end

--- Builds a backend for `device`.
---
--- @param deferred The renderer-owned deferred pipeline this domain records into.
--- @param options Required, and `capacity` with it: there is no default at this
---     level, and the buffers are sized once here and never resized.
function SpriteBackend.create(device: loader.CPtr, deferred: Deferred, options: SpriteBackendOptions): SpriteBackend
    local self = setmetatable({} as SpriteBackend, SpriteBackendMT)
    self._device = device
    self.deferred = deferred
    self.capacity = options.capacity
    self.blendCapacity = math.min(self.capacity, MAX_BLEND)
    self.castCapacity = math.min(self.capacity, MAX_CAST) * CAST_FANOUT
    self._blendGroups = math.ceil(self.blendCapacity / CULL_GROUP)
    self._blending = false
    self._casting = false
    local shadows <const> = deferred:castsShadows()
    self.count = 0
    self._destroyed = false

    -- A layer number shares its float with the clip index, so a layer beyond
    -- the packing's stride would be read back as a different layer in a
    -- different region. Refused here rather than discovered as a wrong image.
    local layerCount <const> = options.layers or MAX_LAYERS
    if layerCount > instancelayout.LAYER_SLOTS then
        error(("tecs: the image array holds at most %d layers"):format(instancelayout.LAYER_SLOTS), 3)
    end

    self.sampler = Sampler.create(device, {})
    self.images = TextureArray.create(
        device,
        {
            width = options.cell or DEFAULT_CELL,
            height = options.cell or DEFAULT_CELL,
            layers = layerCount,
            pack = options.packImages,
        }
    )

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

    -- Written by compute as well as by the staging flush, because a producer
    -- whose contents outlive the frame writes its own region from a compute
    -- pass rather than through staging. Nothing dispatches over them until
    -- something adds a stage, so a world that never does pays only for the
    -- usage bit.
    self.instances = Buffer.create(
        device,
        {
            usage = {"storage", "computeRead", "computeWrite"},
            size = self.capacity * INSTANCE_BYTES,
        }
    )
    self._bounds = Buffer.create(
        device,
        {
            usage = {"computeRead", "computeWrite"},
            size = self.capacity * BOUND_BYTES,
        }
    )
    self._slots = Buffer.create(
        device,
        {
            usage = {"computeRead", "computeWrite"},
            size = self.capacity * 4,
        }
    )
    self._blocks = Buffer.create(
        device,
        {
            usage = {"computeRead", "computeWrite"},
            size = math.ceil(self.capacity / CULL_GROUP) * 4,
        }
    )
    self._visible = Buffer.create(
        device,
        {
            usage = {"storage", "computeWrite"},
            size = self.capacity * 4,
        }
    )
    self._drawArgs = Buffer.create(
        device,
        {
            -- Five uints: SDL_GPUIndexedIndirectDrawCommand.
            usage = {"indirect", "computeWrite"},
            size = 32,
        }
    )

    -- The forward lane. Its per-block counts are as long as the world's,
    -- because the lane it counts is scanned over every instance; everything
    -- after the compaction is as long as the list itself.
    self._blendBlocks = Buffer.create(
        device,
        {
            usage = {"computeRead", "computeWrite"},
            size = math.ceil(self.capacity / CULL_GROUP) * 4,
            name = "tecs.blendBlocks",
        }
    )
    self._blendVisible = Buffer.create(
        device,
        {
            usage = {"computeRead", "computeWrite"},
            size = self.blendCapacity * 4,
            name = "tecs.blendVisible",
        }
    )
    self._blendArgs = Buffer.create(
        device,
        {
            -- Read as well as written by compute, since the two passes after
            -- the scan read the count it wrote rather than being told it: the
            -- CPU never learns how many survived.
            usage = {"indirect", "computeRead", "computeWrite"},
            size = 32,
            name = "tecs.blendArgs",
        }
    )
    self._blendBucket = Buffer.create(
        device,
        {
            usage = {"computeRead", "computeWrite"},
            size = self.blendCapacity * 4,
            name = "tecs.blendBuckets",
        }
    )
    self._blendRank = Buffer.create(
        device,
        {
            usage = {"computeRead", "computeWrite"},
            size = self.blendCapacity * 4,
            name = "tecs.blendRanks",
        }
    )
    self._blendCounts = Buffer.create(
        device,
        {
            usage = {"computeRead", "computeWrite"},
            size = BLEND_BUCKETS * self._blendGroups * 4,
            name = "tecs.blendCounts",
        }
    )
    self._blendSorted = Buffer.create(
        device,
        {
            usage = {"storage", "computeWrite"},
            size = self.blendCapacity * 4,
            name = "tecs.blendSorted",
        }
    )
    -- The shadow lane. Its per-block counts exist whatever the pipeline was
    -- configured with, because the mark pass writes every block of them every
    -- frame and a buffer it wrote into that nothing allocated is not a pass
    -- that quietly does less.
    self._castBlocks = Buffer.create(
        device,
        {
            usage = {"computeRead", "computeWrite"},
            size = math.ceil(self.capacity / CULL_GROUP) * 4,
            name = "tecs.castBlocks",
        }
    )
    if shadows then
        self._castList = Buffer.create(
            device,
            {
                usage = {"storage", "computeWrite"},
                size = self.castCapacity * 4,
                name = "tecs.castList",
            }
        )
        self._castArgs = Buffer.create(
            device,
            {
                usage = {"indirect", "computeWrite"},
                size = 32,
                name = "tecs.castArgs",
            }
        )
    end

    self._playbacks = Buffer.create(
        device,
        {
            usage = {"storage"},
            size = PLAYBACK_FLOATS * 4,
            name = "tecs.playbacks",
        }
    )
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
    for slot = 1, 7 do
        args[slot] = 0
    end
    self._drawArgs:upload(args, 32)
    -- The forward draw's arguments start the same way, and matter before the
    -- first frame fills them: the pass runs whether or not the lane does, so
    -- an instance count of zero is what it has to find there.
    self._blendArgs:upload(args, 32)
    if shadows then
        -- And the shadow draws', for the same reason: their passes run on a
        -- frame that culls nothing at all, when no dispatch has written these.
        self._castArgs:upload(args, 32)
    end

    -- Two triangles over four corners, uploaded once and never touched again.
    self._indices = Buffer.create(
        device,
        {
            usage = {"index"},
            size = QUAD_INDICES * 2,
        }
    )
    local quad = loader.newArray("uint16_t[6]")
    quad[0], quad[1], quad[2] = 0, 1, 2
    quad[3], quad[4], quad[5] = 1, 3, 2
    self._indices:upload(quad, QUAD_INDICES * 2)

    self._view = Camera2D.newCamera2D()
    self._maskView = Camera2D.newCamera2D()
    -- Three vec4s: the world rectangle the camera sees, the counts, and what
    -- the shadow lane needs that the other two do not.
    self._cullUniform = loader.newArray("float[12]")
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

    self._stages = {}

    self._mark = ComputePipeline.load(device, "instance.mark.comp", {})
    self._scan = ComputePipeline.load(device, "instance.scan.comp", {})
    self._compact = ComputePipeline.load(device, "instance.compact.comp", {})
    self._rank = ComputePipeline.load(device, "instance.rank.comp", {})
    self._place = ComputePipeline.load(device, "instance.place.comp", {})
    if shadows then
        self._castCompact = ComputePipeline.load(device, "instance.cast.comp", {})
    end

    -- Seeded with what the buffers hold now, which gives each list its length,
    -- and rewritten wherever it is used.
    self._geometryBuffers = {self.instances.handle, self._visible.handle, self._playbacks.handle}
    self._geometryTextures = {self.images.handle}
    self._forwardBuffers = {self.instances.handle, self._blendSorted.handle, self._playbacks.handle}
    self._forwardTextures = {self.images.handle}
    self._markWrites = {self._slots.handle, self._blocks.handle, self._blendBlocks.handle, self._castBlocks.handle}
    self._markReads = {self._bounds.handle}
    self._scanWrites = {self._blocks.handle, self._drawArgs.handle}
    self._compactWrites = {self._visible.handle}
    self._compactReads = {self._slots.handle, self._blocks.handle}
    self._blendScanWrites = {self._blendBlocks.handle, self._blendArgs.handle}
    self._blendCompactWrites = {self._blendVisible.handle}
    self._blendCompactReads = {self._slots.handle, self._blendBlocks.handle}
    self._rankWrites = {self._blendBucket.handle, self._blendRank.handle, self._blendCounts.handle}
    self._rankReads = {self.instances.handle, self._blendVisible.handle, self._blendArgs.handle}
    self._bucketScanWrites = {self._blendCounts.handle, self._blendArgs.handle}
    self._placeWrites = {self._blendSorted.handle}
    self._placeReads = {
        self._blendVisible.handle,
        self._blendBucket.handle,
        self._blendRank.handle,
        self._blendCounts.handle,
        self._blendArgs.handle,
    }

    self.pipeline = buildGeometry(self)
    self.blendPipeline = buildForward(self)

    if shadows then
        local maskFormat, shadowFormat = self.deferred:castFormats()
        self._maskPipeline = buildCast(self, maskFormat, GraphicsPipeline.BLEND_MAX, "ecs.occluders")
        self._shadowPipeline = buildCast(self, shadowFormat, GraphicsPipeline.BLEND_MIN, "ecs.dropShadows")
        self._stampPipeline = buildCast(self, shadowFormat, GraphicsPipeline.BLEND_MAX, "ecs.dropShadowStamp")

        -- Seeded here rather than above because one of them is the light
        -- buffer, which the deferred pipeline owns and had not been built yet.
        self._castScanWrites = {self._castBlocks.handle, self._castArgs.handle}
        self._castCompactWrites = {self._castList.handle}
        self._castCompactReads = {
            self._slots.handle,
            self._castBlocks.handle,
            self._bounds.handle,
            self.deferred:lightHandle(),
        }
        self._castBuffers = {
            self.instances.handle,
            self._castList.handle,
            self._playbacks.handle,
            self.deferred:lightHandle(),
        }
        self._castTextures = {self.images.handle}
    end

    return self
end

--- Maps a staging slot and hands back the instance and bounds addresses.
---
--- Cycling is off: the slot being handed over is not the one a frame in flight
--- is copying out of, so there is nothing to move out of the way. Cycling would
--- pay for that guarantee with a fresh driver allocation every frame, which at
--- four million instances is over three hundred megabytes a frame retired and
--- reallocated, and the driver cannot reclaim it fast enough.
---
--- @param slot Zero-based, below `Buffer.slotCount`.
--- @return The instance staging as floats, valid until this slot is mapped
---     again.
--- @return The bounds staging as floats, on the same terms.
function SpriteBackend:mapSlot(slot: integer): loader.CArray, loader.CArray
    return self.instances:mapSlotAs(slot, "float *", false), self._bounds:mapSlotAs(slot, "float *", false)
end

--- Adds a stage recorded between the staging flush and the cull.
---
--- Order is the order they were added, and each is asked whether it has
--- anything to do before it is asked to do it. A backend nothing was added to
--- records nothing and dispatches nothing.
---
--- @param stage Held until `destroy`, which calls its own. There is no way to
---     take one back out.
function SpriteBackend:addComputeStage(stage: ComputeStage)
    self._stages[#self._stages + 1] = stage
end

--- The device this backend was built for.
---
--- For a stage building its own pipelines and buffers, which it has to do
--- before there is a frame to record onto.
function SpriteBackend:device(): loader.CPtr
    return self._device
end

--- Returns whether extraction found a caster for the current frame.
function SpriteBackend:castsThisFrame(): boolean
    return self._casting
end

--- Uploads a decoded image into the array and returns the region it occupies.
function SpriteBackend:addImage(
    pixels: loader.CValue, width: integer, height: integer, pitch: integer
): TextureArray.Region
    return self.images:add(pixels, width, height, pitch)
end

--- Writes a decoded image over one the array already holds.
---
--- The region is unchanged by this and stays the answer for that image, which
--- is why nothing outside has to hear about it. Raises on a size that would
--- need a different rect.
function SpriteBackend:replaceImage(
    region: TextureArray.Region, pixels: loader.CValue, width: integer, height: integer, pitch: integer
)
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
function SpriteBackend:rebuildPipelines()
    local device <const> = self._device
    C.SDL_WaitForGPUIdle(device)

    local pipeline: GraphicsPipeline = nil
    local blend: GraphicsPipeline = nil
    local mark: ComputePipeline = nil
    local scan: ComputePipeline = nil
    local compact: ComputePipeline = nil
    local rank: ComputePipeline = nil
    local place: ComputePipeline = nil
    local castCompact: ComputePipeline = nil
    local mask: GraphicsPipeline = nil
    local shadow: GraphicsPipeline = nil
    local stamp: GraphicsPipeline = nil
    local built, reason = pcall(function(): string
        pipeline = buildGeometry(self)
        blend = buildForward(self)
        mark = ComputePipeline.load(device, "instance.mark.comp", {})
        scan = ComputePipeline.load(device, "instance.scan.comp", {})
        compact = ComputePipeline.load(device, "instance.compact.comp", {})
        rank = ComputePipeline.load(device, "instance.rank.comp", {})
        place = ComputePipeline.load(device, "instance.place.comp", {})
        if self._castCompact ~= nil then
            castCompact = ComputePipeline.load(device, "instance.cast.comp", {})
            local maskFormat, shadowFormat = self.deferred:castFormats()
            mask = buildCast(self, maskFormat, GraphicsPipeline.BLEND_MAX, "ecs.occluders")
            shadow = buildCast(self, shadowFormat, GraphicsPipeline.BLEND_MIN, "ecs.dropShadows")
            stamp = buildCast(self, shadowFormat, GraphicsPipeline.BLEND_MAX, "ecs.dropShadowStamp")
        end
    end)
    if not built then
        if pipeline ~= nil then
            pipeline:destroy()
        end
        if blend ~= nil then
            blend:destroy()
        end
        if mark ~= nil then
            mark:destroy()
        end
        if scan ~= nil then
            scan:destroy()
        end
        if compact ~= nil then
            compact:destroy()
        end
        if rank ~= nil then
            rank:destroy()
        end
        if place ~= nil then
            place:destroy()
        end
        if castCompact ~= nil then
            castCompact:destroy()
        end
        if mask ~= nil then
            mask:destroy()
        end
        if shadow ~= nil then
            shadow:destroy()
        end
        if stamp ~= nil then
            stamp:destroy()
        end
        error(reason, 0)
    end

    local oldPipeline <const> = self.pipeline
    local oldBlend <const> = self.blendPipeline
    local oldMark <const> = self._mark
    local oldScan <const> = self._scan
    local oldCompact <const> = self._compact
    local oldRank <const> = self._rank
    local oldPlace <const> = self._place
    self.pipeline = pipeline
    self.blendPipeline = blend
    self._mark = mark
    self._scan = scan
    self._compact = compact
    self._rank = rank
    self._place = place
    oldPipeline:destroy()
    oldBlend:destroy()
    oldMark:destroy()
    oldScan:destroy()
    oldCompact:destroy()
    oldRank:destroy()
    oldPlace:destroy()

    if castCompact ~= nil then
        local oldCastCompact <const> = self._castCompact
        local oldMask <const> = self._maskPipeline
        local oldShadow <const> = self._shadowPipeline
        local oldStamp <const> = self._stampPipeline
        self._castCompact = castCompact
        self._maskPipeline = mask
        self._shadowPipeline = shadow
        self._stampPipeline = stamp
        oldCastCompact:destroy()
        oldMask:destroy()
        oldShadow:destroy()
        oldStamp:destroy()
    end

    -- Last, because a failure above must leave the lighting and composite
    -- pipelines alone as well: half a reload is harder to reason about than
    -- none of one.
    self.deferred:rebuildPipelines()
end

--- Fails on a region index outside the table.
local function checkClipIndex(index: integer, level: integer)
    if index == nil or index ~= math.floor(index) or index < 1 or index >= instancelayout.CLIPS then
        error(
            ("tecs: a clip region is numbered 1 to %d, not %s"):format(instancelayout.CLIPS - 1, tostring(index)),
            level + 1
        )
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
---
--- @param index 1 through `instancelayout.CLIPS - 1`. Zero, a fraction, or
---     anything outside that raises.
--- @param region Nil raises rather than clearing; `clearClipRegion` is what
---     stops a region clipping.
function SpriteBackend:setClipRegion(index: integer, region: ClipRegion)
    checkClipIndex(index, 3)
    if region == nil then
        error("tecs: setClipRegion needs a rectangle; clearClipRegion " .. "is how a region stops clipping", 3)
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
---
--- @param index The same range `setClipRegion` takes. Clearing one nobody set
---     is not an error.
function SpriteBackend:clearClipRegion(index: integer)
    checkClipIndex(index, 3)
    local base <const> = index * 4
    local data <const> = self._clipUniform
    data[base] = -CLIP_UNBOUNDED
    data[base + 1] = -CLIP_UNBOUNDED
    data[base + 2] = CLIP_UNBOUNDED
    data[base + 3] = CLIP_UNBOUNDED
end

--- Compacts the forward lane and sorts it back to front.
---
--- Five dispatches after the opaque lane's three, and every one of them is
--- about order. The first two are the same compaction the opaque lane just ran,
--- against the other half of the slots the mark pass packed, which produces the
--- blended survivors in instance order: deterministic, and no use, because
--- instance order is where extraction put a row rather than where the scene put
--- it. The last three are the counting sort that turns that into depth order,
--- which is what blending needs and what the depth attachment cannot supply for
--- geometry that does not write it.
---
--- The sort works over the compacted list rather than over the world, which is
--- the whole reason it is affordable: its counts table is a bucket per block,
--- and a block per 256 instances of a four million instance world would be a
--- table larger than the list it describes.
--- @param groups Workgroups covering every resident instance, as the opaque
---     lane's dispatches used.
--- @param cull The uniform both lanes are pushed from, rewritten here.
local function sortForward(self: SpriteBackend, frame: Frame, groups: integer, cull: loader.CArray)
    local commandBuffer <const> = frame.commandBuffer
    local blendGroups <const> = self._blendGroups

    -- The forward list's own ceiling from here on, so the scan bounds the draw
    -- to what the compaction can place.
    cull[6] = self.blendCapacity

    local scanWrites <const> = self._blendScanWrites
    scanWrites[1] = self._blendBlocks.handle
    scanWrites[2] = self._blendArgs.handle

    local scan = ComputePass.begin(commandBuffer, scanWrites, self._blendScanPass)
    self._blendScanPass = scan
    scan:bindPipeline(self._scan.handle)
    C.SDL_PushGPUComputeUniformData(commandBuffer, 0, cull, CULL_BYTES)
    scan:dispatch(1)
    scan:finish()

    cull[7] = LANE_BLEND
    local compactWrites <const> = self._blendCompactWrites
    compactWrites[1] = self._blendVisible.handle
    local compactReads <const> = self._blendCompactReads
    compactReads[1] = self._slots.handle
    compactReads[2] = self._blendBlocks.handle

    local compact = ComputePass.begin(commandBuffer, compactWrites, self._blendCompactPass)
    self._blendCompactPass = compact
    compact:bindPipeline(self._compact.handle)
    compact:bindStorageBuffers(0, compactReads)
    C.SDL_PushGPUComputeUniformData(commandBuffer, 0, cull, CULL_BYTES)
    compact:dispatch(groups)
    compact:finish()

    -- The sort is laid out against the forward list's blocks rather than the
    -- world's, and covers all of them however few survived: the scan below
    -- folds every entry of the counts table, so every one has to have been
    -- written this frame.
    cull[5] = blendGroups
    local rankWrites <const> = self._rankWrites
    rankWrites[1] = self._blendBucket.handle
    rankWrites[2] = self._blendRank.handle
    rankWrites[3] = self._blendCounts.handle
    local rankReads <const> = self._rankReads
    rankReads[1] = self.instances.handle
    rankReads[2] = self._blendVisible.handle
    rankReads[3] = self._blendArgs.handle

    local rank = ComputePass.begin(commandBuffer, rankWrites, self._rankPass)
    self._rankPass = rank
    rank:bindPipeline(self._rank.handle)
    rank:bindStorageBuffers(0, rankReads)
    C.SDL_PushGPUComputeUniformData(commandBuffer, 0, cull, CULL_BYTES)
    rank:dispatch(blendGroups)
    rank:finish()

    -- Bucket major, so folding the whole table puts every block of a farther
    -- bucket ahead of the first block of a nearer one.
    cull[5] = BLEND_BUCKETS * blendGroups
    local bucketWrites <const> = self._bucketScanWrites
    bucketWrites[1] = self._blendCounts.handle
    bucketWrites[2] = self._blendArgs.handle

    local buckets = ComputePass.begin(commandBuffer, bucketWrites, self._bucketScanPass)
    self._bucketScanPass = buckets
    buckets:bindPipeline(self._scan.handle)
    C.SDL_PushGPUComputeUniformData(commandBuffer, 0, cull, CULL_BYTES)
    buckets:dispatch(1)
    buckets:finish()

    cull[5] = blendGroups
    local placeWrites <const> = self._placeWrites
    placeWrites[1] = self._blendSorted.handle
    local placeReads <const> = self._placeReads
    placeReads[1] = self._blendVisible.handle
    placeReads[2] = self._blendBucket.handle
    placeReads[3] = self._blendRank.handle
    placeReads[4] = self._blendCounts.handle
    placeReads[5] = self._blendArgs.handle

    local place = ComputePass.begin(commandBuffer, placeWrites, self._placePass)
    self._placePass = place
    place:bindPipeline(self._place.handle)
    place:bindStorageBuffers(0, placeReads)
    C.SDL_PushGPUComputeUniformData(commandBuffer, 0, cull, CULL_BYTES)
    place:dispatch(blendGroups)
    place:finish()
end

--- Compacts the shadow lane into the list the three shadow draws walk.
---
--- Two dispatches after the opaque lane's three, and no mark pass of its own:
--- the lane was scanned in the same dispatch the other two were, over the one
--- bound read that pass already pays for. What the compaction does that the
--- other two do not is choose, once per caster, which lights it throws a copy
--- by, and write a fixed run of entries whether or not it found that many.
--- @param groups Workgroups covering every resident instance, as the opaque
---     lane's dispatches used.
--- @param cull The uniform every lane is pushed from, rewritten here.
local function compactCasters(self: SpriteBackend, frame: Frame, groups: integer, cull: loader.CArray)
    local commandBuffer <const> = frame.commandBuffer

    cull[5] = groups
    cull[6] = self.castCapacity
    cull[7] = LANE_CAST

    local scanWrites <const> = self._castScanWrites
    scanWrites[1] = self._castBlocks.handle
    scanWrites[2] = self._castArgs.handle

    local scan = ComputePass.begin(commandBuffer, scanWrites, self._castScanPass)
    self._castScanPass = scan
    scan:bindPipeline(self._scan.handle)
    C.SDL_PushGPUComputeUniformData(commandBuffer, 0, cull, CULL_BYTES)
    scan:dispatch(1)
    scan:finish()

    local compactWrites <const> = self._castCompactWrites
    compactWrites[1] = self._castList.handle
    local compactReads <const> = self._castCompactReads
    compactReads[1] = self._slots.handle
    compactReads[2] = self._castBlocks.handle
    compactReads[3] = self._bounds.handle
    compactReads[4] = self.deferred:lightHandle()

    local compact = ComputePass.begin(commandBuffer, compactWrites, self._castCompactPass)
    self._castCompactPass = compact
    compact:bindPipeline(self._castCompact.handle)
    compact:bindStorageBuffers(0, compactReads)
    C.SDL_PushGPUComputeUniformData(commandBuffer, 0, cull, CULL_BYTES)
    compact:dispatch(groups)
    compact:finish()
end

--- Uploads what a packet describes and records sprite preparation passes.
---
--- The cull runs on the frame's command buffer, after the upload and before
--- the passes that consume it, so SDL orders all three without anything here
--- having to wait.
---
--- The packet's ranges are what is copied. The device buffers are persistent
--- and hold every earlier frame's bytes, so a packet carries the delta and
--- never a snapshot.
---
--- @param packet Read and not kept: everything taken from it is copied here,
---     so the caller is free to refill it as soon as this returns.
--- @param frame Recorded onto and not submitted. Submitting it is the caller's,
---     after every pass it wants in the frame has been recorded.
function SpriteBackend:prepare(packet: SpriteFramePacket, frame: Frame)
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
            error(
                ("tecs: the animation frame table needs %d floats and the " .. "buffer holds %d"):format(
                    count, PLAYBACK_FLOATS
                ),
                2
            )
        end
        self._playbacks:write(0, data as loader.CValue, count * 4)
        self._playbacks:flush(frame.commandBuffer)
    end

    -- After the flush and before the cull. A stage owns a region of the same
    -- two buffers the flush just wrote, so what it writes has to land on top
    -- of whatever staging left there, and it has to land before the mark pass
    -- reads the bounds beside it. Both fall out of the recording order.
    local stages <const> = self._stages
    for index = 1, #stages do
        local stage = stages[index]
        if stage:active() then
            stage:record(frame, self.instances, self._bounds)
        end
    end

    self._stepClock = packet.stepClock
    self.count = packet.count
    local view <const> = self._view
    view.x = packet.cameraX
    view.y = packet.cameraY
    view.zoom = packet.cameraZoom
    view.rotation = packet.cameraRotation
    -- The same view the geometry pass draws with, handed to the pass that has
    -- to invert it. Lights arrive in world units, so a lighting pass working
    -- in target pixels needs this to put a fragment back where its geometry
    -- came from, and taking it from the one camera is what stops the two
    -- spaces drifting apart.
    self.deferred:setView(view.x, view.y, view.zoom, view.rotation)
    self.deferred:setLightData(packet.lights, packet.lightCount)
    -- The clock the shadow passes resolve a caster's playback against, so an
    -- animated caster's silhouette is the frame the geometry pass drew.
    self.deferred:setStepClock(packet.stepClock)
    -- Ahead of the cull rather than inside the deferred pipeline's own render,
    -- because the shadow lane's compaction reads the lights to decide which
    -- ones a caster throws a copy by. A pass reading a buffer whose upload has
    -- not been recorded reads the frame before, and a shadow one frame behind
    -- its light is a shadow that lags every time a light moves.
    self.deferred:flushLights(frame)

    -- Nothing routes into the forward lane unless extraction said something is
    -- blended, and the whole lane is skipped when nothing is: five compute
    -- passes and a draw are not a cost a world that blends nothing should pay
    -- to find out it has nothing to blend.
    self._blending = packet.blendCount > 0
    self._casting = packet.castCount > 0

    if self.count > 0 then
        local groups = math.ceil(self.count / CULL_GROUP)
        local bounds = view:viewBounds(frame.width, frame.height)
        local cull <const> = self._cullUniform
        cull[0] = bounds[1]
        cull[1] = bounds[2]
        cull[2] = bounds[3]
        cull[3] = bounds[4]
        cull[4] = self.count
        cull[5] = groups
        cull[6] = self.capacity
        cull[7] = LANE_OPAQUE
        -- What only the shadow lane reads: how far outside the view a caster is
        -- still kept, and how many lights it chooses between.
        cull[8] = self.deferred:shadowMargin()
        cull[9] = self.deferred.lightCount
        cull[10] = 0.0
        cull[11] = 0.0

        -- Mark, scan, compact. Each pass reads what the one before it wrote,
        -- and SDL orders them because each declares what it writes. The buffer
        -- lists are the backend's own, rewritten here because a buffer that
        -- grew since the last frame has a new handle.
        local markWrites <const> = self._markWrites
        markWrites[1] = self._slots.handle
        markWrites[2] = self._blocks.handle
        markWrites[3] = self._blendBlocks.handle
        markWrites[4] = self._castBlocks.handle
        local markReads <const> = self._markReads
        markReads[1] = self._bounds.handle

        local mark = ComputePass.begin(frame.commandBuffer, markWrites, self._markPass)
        self._markPass = mark
        mark:bindPipeline(self._mark.handle)
        mark:bindStorageBuffers(0, markReads)
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, cull, CULL_BYTES)
        mark:dispatch(groups)
        mark:finish()

        local scanWrites <const> = self._scanWrites
        scanWrites[1] = self._blocks.handle
        scanWrites[2] = self._drawArgs.handle

        local scan = ComputePass.begin(frame.commandBuffer, scanWrites, self._scanPass)
        self._scanPass = scan
        scan:bindPipeline(self._scan.handle)
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, cull, CULL_BYTES)
        scan:dispatch(1)
        scan:finish()

        local compactWrites <const> = self._compactWrites
        compactWrites[1] = self._visible.handle
        local compactReads <const> = self._compactReads
        compactReads[1] = self._slots.handle
        compactReads[2] = self._blocks.handle

        local compact = ComputePass.begin(frame.commandBuffer, compactWrites, self._compactPass)
        self._compactPass = compact
        compact:bindPipeline(self._compact.handle)
        compact:bindStorageBuffers(0, compactReads)
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, cull, CULL_BYTES)
        compact:dispatch(groups)
        compact:finish()

        if self._blending then
            sortForward(self, frame, groups, cull)
        end
        -- Last, because both of the above rewrite the uniform's back half and
        -- this rewrites it again for a lane of its own. Gated on the pipeline
        -- rather than on the frame: a backend built without shadows has no list
        -- to compact into and no pass that would read one.
        if self._castCompact ~= nil and self._casting then
            compactCasters(self, frame, groups, cull)
        end
    end
end

--- Releases everything the backend owns. Safe to call more than once.
function SpriteBackend:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    -- First, because a stage's buffers were built on this device and releasing
    -- the device out from under them is the one order that cannot work.
    local stages <const> = self._stages
    for index = 1, #stages do
        stages[index]:destroy()
    end
    self.pipeline:destroy()
    self.blendPipeline:destroy()
    self.instances:destroy()
    self.sampler:destroy()
    self.images:destroy()
    self._bounds:destroy()
    self._slots:destroy()
    self._blocks:destroy()
    self._visible:destroy()
    self._drawArgs:destroy()
    self._blendBlocks:destroy()
    self._blendVisible:destroy()
    self._blendArgs:destroy()
    self._blendBucket:destroy()
    self._blendRank:destroy()
    self._blendCounts:destroy()
    self._blendSorted:destroy()
    self._indices:destroy()
    self._playbacks:destroy()
    self._mark:destroy()
    self._scan:destroy()
    self._compact:destroy()
    self._rank:destroy()
    self._place:destroy()
    self._castBlocks:destroy()
    if self._castCompact ~= nil then
        self._castCompact:destroy()
        self._castList:destroy()
        self._castArgs:destroy()
        self._maskPipeline:destroy()
        self._shadowPipeline:destroy()
        self._stampPipeline:destroy()
    end
end

return SpriteBackend
