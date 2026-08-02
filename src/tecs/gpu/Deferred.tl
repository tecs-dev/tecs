--[=[
The standard deferred pipeline, assembled on a PassGraph.

Five passes: geometry fills a G-buffer, lighting resolves it against a
buffer of lights, composite turns that into the frame's image in the
`scene` target, forward blends what the G-buffer could not hold over that
image, and present copies `scene` to the swapchain. Geometry and forward are
callbacks because what to draw is the caller's problem; everything else is
the engine's opinion and is built in.

Four more when `shadows` is set, all of them between geometry and lighting,
because a shadow is not something done to a finished image. Three build the
occluder mask: one draw of every occluder's silhouette, then a separable
blur across and down. The fourth fills the drop-shadow target. Lighting
reads both, and reads them as one mask marched by every light rather than as
a pass per light, which is what makes the cost independent of how many
lights the scene holds.

The two are not the same feature at different strengths. The mask is inside
the light loop and blocks a light's own contribution; the drop-shadow target
multiplies the sum, ambient included, so in a scene lit mostly by ambient
the mask has no output at all and the other one is the whole effect. That is
also why an occluder and a drop-shadow caster are exclusive roles rather
than two flags: a thing that wants to be grounded is exactly the thing that
must not put a light-blocking silhouette in the mask, because a crowd of
them merges under the mask's max blend into one flat mat of darkness.

One different pass runs before geometry when the mesh domain enables its
directional shadow map. Meshes compact against that light volume on the GPU,
then the pass writes their nearest depth into a single-channel target. Opaque
and masked geometry samples it while filling the G-buffer; blended geometry
samples it in forward. A renderer without that option keeps the original
targets, shader variants, and pass list.

Composite and present are two passes rather than one because a pass writing
the swapchain is the end of the frame: the swapchain texture belongs to the
presenter once submitted, is not created with the sampled usage bit, and is
not a target the graph owns, so nothing can read it and nothing can follow
it. `scene` is the seam that buys the gap. It is a graph target like any
other, frame sized, sampled, and readable between frames, and everything
declared between composite and present sees it. `forward` is the first such
pass and the shape the rest take:

* A post-process reading `scene` and writing it back, or reading it and
  writing a target of its own that a later pass folds in.
* A second view compositing into a rectangle of the same `scene`.

`scene` declares no clear, so every pass that writes it loads what is
already there and each of those adds to the last. Composite is what makes
that defined: it covers every pixel and runs first, so nothing downstream
reads memory no frame has written. Where a shared target does declare a
clear, as `lit` does, a pass that must not clear it says
`clear = PassGraph.LOAD`.

Deferred is what makes light count independent of object count: geometry is
rasterised once regardless of how many lights touch it, and lighting runs
once per pixel regardless of how many objects overlap it.

The G-buffer uses all four color attachments a render pass allows: albedo, a
normal with the lit flag in its alpha, ORM surface properties, and emission.
ORM carries ambient occlusion, roughness and metallic in RGB. Occlusion
multiplies ambient light. Mesh surfaces consume roughness and metallic through
Cook-Torrance; sprite surfaces retain their established Lambert term.

Emission is the one attachment lighting does not treat as a surface input. It is added to the
resolved result rather than multiplied into it, so it survives ambient of
zero and an occluder's shadow both, and it sits in a target of its own so a
later pass can blur a scene's glow without picking it back out of a finished
image.

Geometry owns the depth attachment, testing and writing, so wherever two
instances overlap the nearer one is what the G-buffer keeps. Forward tests
against the same attachment and writes none of it, which is what puts
blended geometry behind the opaque geometry in front of it and leaves it
unable to hide another blended fragment from the blend. The three
fullscreen passes have none: each covers every pixel exactly once and has
nothing to be occluded by, so an attachment there would be state to keep in
step for no result.

One compute dispatch runs ahead of the graph, binning the lights into a
grid over what the camera can see so the lighting pass reads a tile's worth
rather than the whole buffer. It is here rather than in the graph because
the graph is a graph of render passes; the same is true of the instance
cull, which runs ahead of `render` for the same reason.

When the mesh domain enables local lights, a second optional dispatch bins
world-space point and spot lights for the active 3D view. Its buffers and
shader bindings are separate from the established 2D light records, and are
absent when the option is omitted. Opaque and transparent mesh material paths
apply the same Cook-Torrance direct-light function to directional, point, and
spot lights.
]=]

local loader <const> = require("tecs.ffi.loader")
local sdl <const> = require("tecs.ffi.sdl3")
local PassGraph <const> = require("tecs.gpu.PassGraph")
local Shader <const> = require("tecs.gpu.Shader")
local Buffer <const> = require("tecs.gpu.Buffer")
local GraphicsPipeline <const> = require("tecs.gpu.GraphicsPipeline")
local Frame <const> = require("tecs.gpu.Frame")
local ComputePipeline <const> = require("tecs.gpu.ComputePipeline")
local ComputePass <const> = require("tecs.gpu.ComputePass")
local lightlayout <const> = require("tecs.gpu.lightlayout")
local meshlightlayout <const> = require("tecs.gpu.meshlightlayout")

local C <const> = sdl.C

--- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local RGBA8 <const> = 4

--- Packed positive HDR color. It has the same four-byte footprint as RGBA8,
--- and bloom does not need alpha in its lighting or blur intermediates.
local R11G11B10 <const> = tonumber(C.SDL_GPU_TEXTUREFORMAT_R11G11B10_UFLOAT) as integer

--- One channel, which is all the drop-shadow target has to say. Read from the
--- generated cdef rather than copied out of the header, for the reason the
--- blend factors are.
local R8 <const> = tonumber(C.SDL_GPU_TEXTUREFORMAT_R8_UNORM) as integer
local R16 <const> = tonumber(C.SDL_GPU_TEXTUREFORMAT_R16_UNORM) as integer

local MAX_LIGHTS <const> = lightlayout.MAX
local LIGHT_FLOATS <const> = lightlayout.FLOATS
local LIGHT_STRIDE <const> = lightlayout.BYTES
local TILE_COUNT <const> = lightlayout.TILE_COUNT
local TILE_SLOTS <const> = lightlayout.TILE_SLOTS
local MESH_LIGHT_STRIDE <const> = meshlightlayout.BYTES

--- Threads per binning workgroup, matching the shader's local size.
local BIN_GROUP <const> = 64

--- Floats the block a pass shading against the lights reads the scene from
--- holds: ambient, target size, view, the tile grid's rectangle, and the
--- transform from the world into the occluder mask, each padded to a vec4.
local SCENE_FLOATS <const> = 24
local SCENE_BYTES <const> = SCENE_FLOATS * 4
local MESH_SHADOW_SCENE_FLOATS <const> = 32
local MESH_PBR_FLOATS <const> = 20
local MESH_PROBE_FLOATS <const> = 24
local MESH_FOG_FLOATS <const> = 4

--- Floats the block a shadow draw is placed from holds: a matrix and four
--- parameters.
local CAST_FLOATS <const> = 20
local CAST_BYTES <const> = CAST_FLOATS * 4

--- Which of the three shadow draws a caster pass is recording, as
--- `assets/shaders/cast.vert.glsl` reads them.
---
--- One shader places all three because all three place a quad from the same
--- instance against the same list. What differs is where it goes and what it
--- rejects, and that is one number rather than three shaders.
local MASK <const> = 0
local SHADOW <const> = 1
local STAMP <const> = 2

local function alwaysEnabled(): boolean
    return true
end

--- One point light, positioned in the world the camera is looking at.
---
--- World units rather than target pixels, because a light is a thing in the
--- scene: the view carries it the way it carries geometry, and a light left in
--- target pixels would sit still on screen while everything around it panned.
--- `setView` is what the lighting pass inverts to put a fragment back in this
--- space, and a pipeline that never sets one treats world units as target
--- pixels, which is the same default the renderer's camera takes.
local record Light
    --- Position in world units. Y runs down, as it does everywhere else here.
    x: number
    y: number
    --- Height above the surface, in world units. Zero puts the light in the
    --- surface plane, where a surface facing the viewer receives nothing from
    --- it, since the direction to the light is then perpendicular to the
    --- normal.
    z: number
    --- Reach in world units. Falloff runs smoothly to zero at the radius, so
    --- this bounds what the light costs as well as how far it carries. Values
    --- below one are treated as one, and zoom scales what it covers on screen
    --- rather than what it covers in the world.
    radius: number
    --- Color, in 0..1 per channel.
    r: number
    g: number
    b: number
    --- Multiplies the color before it accumulates. Above one is useful: what
    --- clamps is the target, once the sum has been applied to albedo, so a
    --- bright light saturates towards the surface's own color rather than
    --- being cut off on its way in.
    intensity: number
end

--- What a pipeline that casts shadows tunes them with.
---
--- Every field has a default, so an empty table is the whole of what a scene
--- that wants shadows and no opinion about them passes. One record rather than
--- seven fields spread through the option records above it, because these are
--- forwarded twice on the way down and a second listing of them is a second
--- thing to keep in step.
local record ShadowOptions
    --- Size of the occluder mask relative to the frame. Defaults to one.
    --- Halving it quarters two full targets and costs a shadow its crisp edge,
    --- since the mask is sampled at the resolution it was written.
    maskScale: number
    --- Samples a shadow march takes at full attenuation, and the ceiling the
    --- adaptive count is clamped to. Defaults to 24.
    steps: number
    --- How far outside the view, in world units, a caster is still kept.
    --- Defaults to 200. A wall just off the left edge throws a shadow that
    --- falls on screen, and this is what stops the cull dropping it. It also
    --- widens the mask's projection by the same amount, so what is kept lands
    --- inside the mask rather than off its edge.
    margin: number
    --- World height a caster at `height` one stands, which is the one number
    --- that puts a light's height and a caster's zero-to-one height in the
    --- same space. Defaults to 64, which is `PointLight2D`'s own default height,
    --- so an occluder at height one and a light at its default are level and
    --- the shadow runs to the horizon.
    height: number
    --- Size of the drop-shadow target relative to the frame. Defaults to a
    --- half: it holds one soft channel, so the resolution it is read at is not
    --- the resolution it has to be drawn at.
    dropScale: number
    --- How dark a drop shadow is where the light throwing it is at full
    --- strength. Defaults to 0.4.
    dropOpacity: number
    --- Longest a drop shadow may be, in world units. Defaults to 512. The
    --- projection that places the tip divides by the light's height above the
    --- caster's, so a light barely clearing a tall caster throws a shadow to
    --- the horizon, and this is what bounds it.
    dropLength: number
end

--- Configures the optional bloom branch.
---
--- Enabling bloom keeps the lighting and blur intermediates in packed HDR so
--- values above white reach extraction without increasing bytes per pixel.
local record BloomOptions
    --- Caller-writable. Sets both bloom targets relative to the frame and
    --- defaults to 0.5. It must be positive.
    scale: number
    --- Caller-writable. Sets the non-negative HDR brightness threshold and
    --- defaults to 0.8.
    threshold: number
    --- Caller-writable. Sets the non-negative HDR width of the threshold's
    --- soft knee and defaults to 0.1.
    knee: number
    --- Caller-writable. Scales the blurred contribution and defaults to 0.7.
    intensity: number
end

local record DeferredOptions
    --- Draws into the G-buffer. Writes location 0 for albedo, location 1 for a
    --- normal biased into unsigned range, location 2 for ORM, and location 3
    --- for emission.
    ---
    --- Location 1's alpha is what decides lighting: a fragment carrying less
    --- than a half passes through at its own albedo, and one at or above a
    --- half is lit. Geometry that writes a normal and leaves that alpha at
    --- zero is drawn unlit, which reads as lighting doing nothing.
    ---
    --- Location 2 carries ambient occlusion, roughness and metallic in RGB.
    --- Ambient occlusion multiplies ambient lighting; roughness and metallic
    --- are reserved for the physically based light term. Geometry must write
    --- the neutral `(1, 0.5, 0, 1)` when it has no authored surface properties.
    ---
    --- Location 3 is a color in rgb and how much of it in alpha, and the resolve
    --- adds the product on top of the lighting rather than through it. Geometry
    --- must write zero when it emits nothing. A fragment shader that declares
    --- fewer than all four outputs leaves the omitted attachments undefined;
    --- the render pass clear is not a substitute for an output.
    geometry: function(context: PassGraph.PassContext)
    --- Draws blended geometry over the composited image, back to front.
    ---
    --- Runs with the geometry pass's depth attached and not written, and with
    --- the lights already bound: call `bindLighting` after binding a pipeline
    --- and the fragment stage has what it needs to shade itself. A pipeline
    --- drawn here is built against `forwardFormat` and `forwardDepth` with
    --- blending on, and nothing here writes the G-buffer.
    forward: function(context: PassGraph.PassContext)
    --- Ambient color, added to every lit fragment before any light is.
    --- Defaults to a dim neutral. A fragment that asked not to be lit does not
    --- receive it, and neither does a pixel nothing drew over.
    ambient: {number}

    --- Build the occluder mask and the drop-shadow target, and tune them.
    ---
    --- Nil, which is the default, costs a pipeline nothing: three targets go
    --- unallocated, four passes go undeclared, and the resolve is built from
    --- the variant of its shader that samples neither. An empty table turns
    --- shadows on with every default. `shadowActive` can skip all four passes
    --- on a frame with no casters while retaining those fixed resources.
    ---
    --- A setting rather than a count taken off a frame, because the alternative
    --- is a pass graph whose shape depends on what a world happens to hold this
    --- frame, and a resolve pipeline rebuilt the first time something casts.
    shadows: ShadowOptions
    --- Reports whether this frame has shadow casters. Defaults to true.
    ---
    --- Returning false skips all four shadow passes and makes lighting ignore
    --- their retained targets. Ignored unless `shadows` is set.
    shadowActive: function(): boolean
    --- Draws the shadow lane's list into the occluder mask, at the mask's own
    --- widened projection. Called with the pass begun; `castUniform` is what
    --- says where to put a caster. Ignored unless `shadows` is set.
    occluders: function(context: PassGraph.PassContext)
    --- Draws the same list into the drop-shadow target, twice: the stretched
    --- copies with min blending, then the casters themselves with max, which is
    --- what puts a caster back on top of the shadow it threw across its own
    --- feet. Ignored unless `shadows` is set.
    dropShadows: function(context: PassGraph.PassContext)
    --- Engine-owned. Enables the mesh domain's directional shadow-map target
    --- at this scale. Nil omits the target, pass, and shader variant.
    meshShadowScale: number
    --- Engine-owned. Reports whether opaque mesh casters exist this frame.
    meshShadowActive: function(): boolean
    --- Engine-owned. Draws mesh depth into the directional shadow map.
    meshShadowMap: function(context: PassGraph.PassContext)
    --- Engine-owned. Enables mesh fog decoding in the lighting resolve.
    meshFog: boolean
    --- Engine-owned. Enables depth reconstruction and Cook-Torrance shading
    --- for opaque mesh surfaces.
    meshPBR: boolean
    --- Engine-owned. Enables mesh-only ambient-cube probe shading.
    meshProbe: boolean
    --- Engine-owned. Enables optional 3D point and spot light resources at
    --- this fixed capacity. Nil omits every related buffer and shader variant.
    meshLightCapacity: integer
    --- Engine-owned. Enables repeated view composition through shared
    --- intermediate targets.
    multiCamera: boolean
    --- Enables an optional packed-HDR bloom branch. Nil omits both targets
    --- and all three passes.
    bloom: BloomOptions
end

--- The deferred pipeline: its pass graph, the pipelines it binds, and the
--- lights they shade with.
---
--- `create` builds one against a device and a swapchain format, `render` drives
--- it for one frame, and `destroy` releases the graph's targets, the pipelines
--- and the light buffers. Everything here is owned rather than borrowed, so a
--- second pipeline over the same device is a second G-buffer.
local record Deferred
    --- One light, as `setLights` takes them.
    Light: Light
    --- What turns shadows on, and the only place their numbers are described.
    ShadowOptions: ShadowOptions
    BloomOptions: BloomOptions
    --- The occluder mask draw, which puts a caster's own silhouette into the
    --- mask every light marches against.
    MASK: integer
    --- The drop-shadow draw, which puts a stretched copy of a caster along the
    --- ground away from one light.
    SHADOW: integer
    --- The draw that puts a caster back over its own shadow at full
    --- brightness.
    STAMP: integer
    --- What a geometry callback receives. Re-exported so callers need not
    --- reach into PassGraph for it.
    PassContext: PassGraph.PassContext
    --- The five passes, so a caller can add its own targets and passes around
    --- them or ask what a pass was built with.
    graph: PassGraph
    --- Lights the lighting pass reads. Set by `setLights` and kept until it is
    --- called again, so a frame that says nothing lights as the last one did.
    lightCount: integer
    --- Optional 3D point and spot lights written for the current frame.
    meshLightCount: integer
    --- Ambient color in use, as three components. Written by `create` and
    --- read at the top of every lighting pass, so assigning to it takes effect
    --- on the next frame without rebuilding anything.
    ambient: {number}
    --- The device every buffer, pipeline and target below was created against,
    --- and the one `destroy` releases them from.
    _device: loader.CPtr
    --- The lights themselves, as `MAX_LIGHTS` slots of `LIGHT_STRIDE` bytes.
    --- Written through slot zero and flushed by `render`.
    _lightBuffer: Buffer
    --- Where `setLights` packs records before handing them on, so the packed
    --- form has one writer.
    _lightScratch: loader.CArray
    --- Lights reaching each tile, as a count per tile and a list of slots per
    --- tile. Written by the binning dispatch and read by the lighting pass,
    --- and sized from a fixed grid so neither is ever reallocated under a
    --- frame that is still reading it.
    _tileCounts: Buffer
    --- The per-tile slot lists, `TILE_SLOTS` entries of four bytes per tile,
    --- indexed by the count `_tileCounts` holds for the same tile.
    _tileLights: Buffer
    --- The buffer lists the binning pass and the lighting pass hand the pass
    --- API, one per call site and each of a fixed length. Held rather than
    --- built per frame, and rewritten at every use, since a buffer that grew
    --- has a new handle.
    _binWrites: {loader.CValue}
    --- What the binning dispatch reads: the light buffer alone.
    _binReads: {loader.CValue}
    --- What the lighting pass's fragment stage reads, in binding order: the
    --- light buffer, the tile counts, then the tile slot lists.
    _lightingBuffers: {loader.CValue}
    --- The same three, for the forward pass's fragment stage. A second list
    --- rather than the same one, because both are rewritten at every use and
    --- sharing would mean the order of two passes decided what either bound.
    _forwardBuffers: {loader.CValue}
    _meshLights: boolean
    _meshLightCapacity: integer
    _meshLightBuffer: Buffer
    _meshTileCounts: Buffer
    _meshTileLights: Buffer
    _meshBinWrites: {loader.CValue}
    _meshBinReads: {loader.CValue}
    _meshBinPass: ComputePass
    _meshBinPipeline: ComputePipeline
    _meshBinUniform: loader.CArray
    --- The binning pass, begun again each frame rather than allocated per
    --- frame; see `ComputePass.begin` for what that asks of a caller.
    _binPass: ComputePass
    --- The compute pipeline that bins lights into the tile grid, rebuilt by
    --- `rebuildPipelines` along with the three graphics ones.
    _binPipeline: ComputePipeline
    --- Eight floats pushed to the binning dispatch: the world rectangle the
    --- grid covers, then the light count.
    _binUniform: loader.CArray
    --- Resolves the G-buffer against the binned lights into the `lit` target.
    _lightingPipeline: GraphicsPipeline
    --- Turns the `lit` target into the frame's image in `scene`.
    _compositePipeline: GraphicsPipeline
    --- Copies the scene target to the swapchain, and so the only pipeline here
    --- built against the swapchain's format.
    _presentPipeline: GraphicsPipeline
    _viewCompositePipeline: GraphicsPipeline
    _bloomExtractPipeline: GraphicsPipeline
    _bloomBlurPipeline: GraphicsPipeline
    _bloomUniform: loader.CArray
    _bloomStep: loader.CArray
    _bloom: boolean
    _lightingFormat: integer
    _multiCamera: boolean
    _firstView: boolean
    _lastView: boolean
    _viewportX: integer
    _viewportY: integer
    _viewportWidth: integer
    _viewportHeight: integer
    --- Blurs the occluder mask along one axis, bound by both blur passes and
    --- told which axis by the four floats it is pushed. Nil while shadows are
    --- off.
    _blurPipeline: GraphicsPipeline
    --- `SCENE_FLOATS` pushed to the lighting fragment stage: ambient, then the
    --- target size, then the view, then the grid's world rectangle, then the
    --- transform into the occluder mask, each padded out to a vec4. A
    --- mesh-shadow graph adds two light vec4s. Held rather than allocated per
    --- frame, since the pass runs every frame.
    _sceneUniform: loader.CArray
    --- One step along the axis a blur pass is blurring, in mask UV. Rewritten
    --- between the two passes, so it is one array and a push each.
    _blurUniform: loader.CArray
    --- The matrix and four parameters a shadow draw is placed from, rewritten
    --- for each of the three.
    _castUniform: loader.CArray
    --- Whether the mask and the drop-shadow target exist at all, as `create`
    --- was told. Read by everything that would otherwise have to test for a
    --- target that is not there.
    _shadows: boolean
    --- Whether the graph owns the optional mesh shadow-map lane.
    _meshShadows: boolean
    --- Whether the lighting resolve decodes mesh fog markers.
    _meshFog: boolean
    _meshPBR: boolean
    _meshProbe: boolean
    _meshProbeUniform: loader.CArray
    _meshCameraX: number
    _meshCameraY: number
    _meshCameraZ: number
    _inverseViewProjection: loader.CArray
    _meshViewProjection: loader.CArray
    _sceneBytes: integer
    _meshFogR: number
    _meshFogG: number
    _meshFogB: number
    --- Reports whether the current frame has an opaque mesh caster.
    _meshShadowActive: function(): boolean
    --- Direction from a surface toward the mesh domain's directional light.
    _meshLightX: number
    _meshLightY: number
    _meshLightZ: number
    --- Directional-light intensity and color.
    _meshLightIntensity: number
    _meshLightR: number
    _meshLightG: number
    _meshLightB: number
    --- Reports whether the current frame should build and sample shadows.
    _shadowActive: function(): boolean
    --- Size of the mask relative to the frame, as the targets were declared
    --- with. Kept because the mask's projection is derived from it.
    _shadowMaskScale: number
    --- Samples a march takes at full attenuation, pushed to the resolve.
    _shadowSteps: number
    --- How far outside the view a caster is kept, in world units, and how much
    --- wider than the view the mask's projection is.
    _shadowMargin: number
    --- World height a full-height occluder stands.
    _shadowHeight: number
    --- How dark a drop shadow is at full weight.
    _dropShadowOpacity: number
    --- Longest a drop shadow may be, in world units.
    _dropShadowLength: number
    --- Zoom the mask's projection uses, resolved with the view each frame. The
    --- camera's own, scaled so the margin lands inside the mask and so the
    --- mask's own size is covered rather than the frame's.
    _maskZoom: number
    --- The animation clock a caster's playback resolves against, as
    --- `setStepClock` left it. Here as well as in the layer uniform the geometry
    --- pass pushes, because a caster's silhouette is placed by a pass of its own
    --- and has to be showing the frame the geometry pass drew.
    _stepClock: number
    --- The view lights are placed against, as `setView` left it. Zoom and
    --- rotation are kept folded into the two components the shader multiplies
    --- by, so the trig is paid once a frame rather than once a fragment.
    _viewX: number
    --- Center of the view in world units, with Y running down.
    _viewY: number
    --- Cosine of the view's rotation, already divided by the zoom.
    _viewCos: number
    --- Sine of the view's rotation, already divided by the zoom.
    _viewSin: number
    --- The view's zoom and rotation as they arrived, kept alongside the folded
    --- pair because the mask's projection is the camera's at another zoom and
    --- cannot be recovered from two numbers that have one folded into them.
    _viewZoom: number
    --- Radians, the sense the camera turns in.
    _viewRotation: number
    --- Whether anything has set a view. Until something does, the frame
    --- centers one on its own target, so world units are target pixels and a
    --- pipeline driven without a camera behaves as it reads.
    _viewSet: boolean
    --- The view as `render` resolved it for the frame being drawn, and the
    --- world rectangle the tile grid covers under it. Resolved there rather
    --- than in each of the two places that need it, because the binning
    --- dispatch and the lighting pass have to agree about the grid exactly: a
    --- light binned against one rectangle and looked up against another lands
    --- in a tile nothing reads.
    _frameViewX: number
    --- The frame's view center in world units, Y running down.
    _frameViewY: number
    --- The frame's rotation cosine over its zoom, as the shaders multiply by.
    _frameViewCos: number
    --- The frame's rotation sine over its zoom, as the shaders multiply by.
    _frameViewSin: number
    --- The frame's view center, zoom and rotation as the mask's projection
    --- takes them. Resolved with everything else, because the pass that draws
    --- the mask and the pass that inverts it have to agree exactly: a
    --- silhouette drawn against one projection and marched against another is
    --- a shadow in the wrong place.
    _frameViewZoom: number
    --- The frame's rotation in radians, for the mask's projection.
    _frameViewRotation: number
    --- Least world X the grid covers this frame. The four bounds are the
    --- axis-aligned bound of what the camera sees, which is wider than the view
    --- itself once the camera is turned.
    _boundsMinX: number
    --- Least world Y the grid covers this frame.
    _boundsMinY: number
    --- Greatest world X the grid covers this frame.
    _boundsMaxX: number
    --- Greatest world Y the grid covers this frame.
    _boundsMaxY: number
    --- Set by the first `destroy`, so a second one releases nothing again.
    _destroyed: boolean
end

local DeferredMT <const>: metatable<Deferred> = {__index = Deferred}

Deferred.MASK = MASK
Deferred.SHADOW = SHADOW
Deferred.STAMP = STAMP

local function buildPipeline(
    device: loader.CPtr,
    fragmentName: string,
    format: integer,
    name: string,
    defines: {string: string},
    blendMode?: integer
): GraphicsPipeline
    local vertex = Shader.load(device, "deferred.fullscreen.vert", {})
    local fragment = Shader.load(device, fragmentName, {defines = defines})
    local pipeline = GraphicsPipeline.create(
        device,
        {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormat = format,
            blendMode = blendMode,
            name = name,
        }
    )
    vertex:destroy()
    fragment:destroy()
    return pipeline
end

--- Fills the block a pass shading against the lights reads the scene from.
---
--- One description of the scene for both passes that shade. The resolve and
--- the forward pass have to agree about where the camera is and which
--- rectangle the tile grid covers, because a fragment that looked a tile up
--- against a different rectangle than the binning dispatch filled reads a list
--- nothing wrote.
local function sceneUniform(self: Deferred, width: number, height: number): loader.CArray
    local scene <const> = self._sceneUniform
    scene[0] = self.ambient[1]
    scene[1] = self.ambient[2]
    scene[2] = self.ambient[3]
    scene[3] = self._shadows and self._shadowActive() and 1.0 or 0.0
    scene[4] = width
    scene[5] = height
    -- Out to the vec4 the block is laid out in. The light count is not here:
    -- what bounds a shading loop is a tile's own count, and a second number
    -- saying something close to it is a second number to keep in step.
    scene[6] = self._viewportX
    scene[7] = self._viewportY
    -- As `render` resolved them for this frame, so the grid a fragment looks a
    -- tile up in is the grid the dispatch filled.
    scene[8] = self._frameViewX
    scene[9] = self._frameViewY
    scene[10] = self._frameViewCos
    scene[11] = self._frameViewSin
    scene[12] = self._boundsMinX
    scene[13] = self._boundsMinY
    scene[14] = self._boundsMaxX
    scene[15] = self._boundsMaxY

    -- World to mask UV, which is `Camera2D:toScreen` against the mask's own
    -- projection divided through by the size that projection was built for.
    -- Clip space is what the two have in common, and it carries no resolution,
    -- so the mask's own scale drops out of this entirely: a mask at half size
    -- covers the same world over fewer pixels, and a UV is a fraction either
    -- way.
    local turn <const> = math.cos(self._frameViewRotation) * self._maskZoom
    local tilt <const> = math.sin(self._frameViewRotation) * self._maskZoom
    local acrossMask <const> = 1.0 / width
    local downMask <const> = 1.0 / height
    local maskA <const> = turn * acrossMask
    local maskB <const> = tilt * acrossMask
    local maskC <const> = -tilt * downMask
    local maskD <const> = turn * downMask
    scene[16] = maskA
    scene[17] = maskB
    scene[18] = maskC
    scene[19] = maskD
    scene[20] = 0.5 - (maskA * self._frameViewX + maskB * self._frameViewY)
    scene[21] = 0.5 - (maskC * self._frameViewX + maskD * self._frameViewY)
    scene[22] = self._shadowSteps
    scene[23] = self._shadowHeight
    if self._meshShadows then
        scene[24] = self._meshLightX
        scene[25] = self._meshLightY
        scene[26] = self._meshLightZ
        scene[27] = self._meshLightIntensity
        scene[28] = self._meshLightR
        scene[29] = self._meshLightG
        scene[30] = self._meshLightB
        scene[31] = 0.0
    end
    local at = self._meshShadows and MESH_SHADOW_SCENE_FLOATS or SCENE_FLOATS
    if self._meshPBR then
        scene[at], scene[at + 1], scene[at + 2], scene[at + 3] = self._meshCameraX,
            self._meshCameraY,
            self._meshCameraZ,
            0.0
        for lane = 0, 15 do
            scene[at + 4 + lane] = self._inverseViewProjection[lane]
        end
        at = at + MESH_PBR_FLOATS
    end
    if self._meshProbe then
        for lane = 0, MESH_PROBE_FLOATS - 1 do
            scene[at + lane] = self._meshProbeUniform[lane]
        end
        at = at + MESH_PROBE_FLOATS
    end
    if self._meshFog then
        scene[at] = self._meshFogR
        scene[at + 1] = self._meshFogG
        scene[at + 2] = self._meshFogB
        scene[at + 3] = 0.0
    end
    return scene
end

--- Builds the pipeline and its graph.
---
--- The fullscreen shaders are loaded and their shader objects released here,
--- since SDL retains what a pipeline needs. What survives is the pipelines,
--- the light buffer and the graph's targets, all of which `destroy` releases.
--- @param device The `SDL_GPUDevice`, which is `Device.handle` and not the
---     wrapper around it.
--- @param swapchainFormat What present writes to, from
---     `Device:getSwapchainFormat`. Every other target's format is the
---     graph's; the G-buffer's four come back out of `geometryFormats`.
--- @return A pipeline that has allocated its light buffers but no targets;
---     those are sized on the first `render` from the frame it is given.
function Deferred.create(device: loader.CPtr, swapchainFormat: integer, options: DeferredOptions): Deferred
    options = options or {}

    local self = setmetatable({} as Deferred, DeferredMT)
    self._device = device
    self.lightCount = 0
    self.meshLightCount = 0
    self.ambient = options.ambient or {0.08, 0.08, 0.10}
    self._destroyed = false

    -- Read whether or not shadows are on, so the numbers a caller can ask back
    -- for are the numbers this would use, rather than nil until something
    -- turns the feature on.
    local tuning <const> = options.shadows or {}
    local shadows <const> = options.shadows ~= nil
    local meshShadows <const> = options.meshShadowScale ~= nil
    local meshFog <const> = options.meshFog == true
    local meshPBR <const> = options.meshPBR == true
    local meshProbe <const> = options.meshProbe == true
    local meshLights <const> = options.meshLightCapacity ~= nil
    local meshLightCapacity <const> = options.meshLightCapacity or 0
    if meshLights and (meshLightCapacity < 1 or meshLightCapacity ~= math.floor(meshLightCapacity)) then
        error("tecs: mesh light capacity must be a positive integer", 2)
    end
    local multiCamera <const> = options.multiCamera == true
    local bloom <const> = options.bloom ~= nil
    local bloomOptions <const> = options.bloom or {}
    local bloomScale <const> = bloomOptions.scale or 0.5
    local bloomThreshold <const> = bloomOptions.threshold or 0.8
    local bloomKnee <const> = bloomOptions.knee or 0.1
    local bloomIntensity <const> = bloomOptions.intensity or 0.7
    local lightingFormat <const> = bloom and R11G11B10 or RGBA8
    if bloomScale <= 0.0 then
        error("tecs: bloom scale must be greater than 0", 2)
    end
    if bloomThreshold < 0.0 or bloomKnee < 0.0 then
        error("tecs: bloom threshold and knee must be greater than or equal to 0", 2)
    end
    if bloomIntensity < 0.0 then
        error("tecs: bloom intensity must be greater than or equal to 0", 2)
    end
    self._shadows = shadows
    self._meshShadows = meshShadows
    self._meshFog = meshFog
    self._meshPBR = meshPBR
    self._meshProbe = meshProbe
    if meshProbe then
        self._meshProbeUniform = loader.newArray("float[24]")
    end
    self._meshLights = meshLights
    self._meshLightCapacity = meshLightCapacity
    self._meshCameraX, self._meshCameraY, self._meshCameraZ = 0.0, 0.0, 0.0
    self._inverseViewProjection = loader.newArray("float[16]")
    self._meshViewProjection = loader.newArray("float[16]")
    self._bloom = bloom
    self._lightingFormat = lightingFormat
    self._multiCamera = multiCamera
    self._firstView, self._lastView = true, true
    self._viewportX, self._viewportY, self._viewportWidth, self._viewportHeight = 0, 0, 0, 0
    self._meshFogR, self._meshFogG, self._meshFogB = 0.5, 0.6, 0.7
    self._shadowActive = options.shadowActive or alwaysEnabled
    self._meshShadowActive = options.meshShadowActive or alwaysEnabled
    self._meshLightX, self._meshLightY, self._meshLightZ = 0.0, 1.0, 0.0
    self._meshLightIntensity = 0.0
    self._meshLightR, self._meshLightG, self._meshLightB = 1.0, 1.0, 1.0
    self._shadowMaskScale = tuning.maskScale or 1.0
    self._shadowSteps = tuning.steps or 24
    self._shadowMargin = tuning.margin or 200.0
    self._shadowHeight = tuning.height or 64.0
    self._dropShadowOpacity = tuning.dropOpacity or 0.4
    self._dropShadowLength = tuning.dropLength or 512.0
    self._maskZoom = 1.0
    self._stepClock = 0.0
    self._blurUniform = loader.newArray("float[4]")
    self._castUniform = loader.newArray("float[?]", CAST_FLOATS)
    if bloom then
        self._bloomUniform = loader.newArray("float[4]")
        self._bloomUniform[0], self._bloomUniform[1], self._bloomUniform[2], self._bloomUniform[3] = bloomThreshold,
            bloomKnee,
            bloomIntensity,
            0.0
        self._bloomStep = loader.newArray("float[4]")
    end

    self._lightBuffer = Buffer.create(
        device,
        {
            -- Read by a compute pass as well as by the lighting pass, since the
            -- binning dispatch is what turns the buffer into per-tile lists.
            usage = {"storage", "computeRead"},
            size = MAX_LIGHTS * LIGHT_STRIDE,
        }
    )
    self._lightScratch = loader.newArray("float[?]", MAX_LIGHTS * LIGHT_FLOATS)
    local sceneFloats <const> = (meshShadows and MESH_SHADOW_SCENE_FLOATS or SCENE_FLOATS) + (
        meshPBR and MESH_PBR_FLOATS or 0
    ) + (meshProbe and MESH_PROBE_FLOATS or 0) + (meshFog and MESH_FOG_FLOATS or 0)
    self._sceneBytes = sceneFloats * 4
    self._sceneUniform = loader.newArray("float[?]", sceneFloats)
    self._binUniform = loader.newArray("float[8]")
    self._viewX = 0.0
    self._viewY = 0.0
    self._viewCos = 1.0
    self._viewSin = 0.0
    self._viewZoom = 1.0
    self._viewRotation = 0.0
    self._viewSet = false
    self._frameViewX = 0.0
    self._frameViewY = 0.0
    self._frameViewCos = 1.0
    self._frameViewSin = 0.0
    self._frameViewZoom = 1.0
    self._frameViewRotation = 0.0
    self._boundsMinX = 0.0
    self._boundsMinY = 0.0
    self._boundsMaxX = 0.0
    self._boundsMaxY = 0.0

    -- One binding for the pass that fills them and one for the pass that
    -- reads them, and a fixed size, so a resized window replaces the graph's
    -- targets and leaves these where they are.
    self._tileCounts = Buffer.create(
        device,
        {
            usage = {"storage", "computeWrite"},
            size = TILE_COUNT * 4,
            name = "tecs.lightTileCounts",
        }
    )
    self._tileLights = Buffer.create(
        device,
        {
            usage = {"storage", "computeWrite"},
            size = TILE_COUNT * TILE_SLOTS * 4,
            name = "tecs.lightTiles",
        }
    )
    self._binPipeline = ComputePipeline.load(device, "deferred.lightbin.comp", {})

    -- Seeded with what the buffers hold now, which gives each list its length.
    self._binWrites = {self._tileCounts.handle, self._tileLights.handle}
    self._binReads = {self._lightBuffer.handle}
    self._lightingBuffers = {self._lightBuffer.handle, self._tileCounts.handle, self._tileLights.handle}
    self._forwardBuffers = {self._lightBuffer.handle, self._tileCounts.handle, self._tileLights.handle}
    if meshLights then
        self._meshLightBuffer = Buffer.create(
            device,
            {
                usage = {"storage", "computeRead"},
                size = meshLightCapacity * MESH_LIGHT_STRIDE,
                name = "tecs.meshLights",
            }
        )
        self._meshTileCounts = Buffer.create(
            device, {usage = {"storage", "computeWrite"}, size = TILE_COUNT * 4, name = "tecs.meshLightTileCounts"}
        )
        self._meshTileLights = Buffer.create(
            device,
            {
                usage = {"storage", "computeWrite"},
                size = TILE_COUNT * TILE_SLOTS * 4,
                name = "tecs.meshLightTiles",
            }
        )
        self._meshBinPipeline = ComputePipeline.load(device, "mesh.lightbin.comp", {})
        self._meshBinUniform = loader.newArray("float[20]")
        self._meshBinWrites = {self._meshTileCounts.handle, self._meshTileLights.handle}
        self._meshBinReads = {self._meshLightBuffer.handle}
        self._lightingBuffers[4] = self._meshLightBuffer.handle
        self._lightingBuffers[5] = self._meshTileCounts.handle
        self._lightingBuffers[6] = self._meshTileLights.handle
        self._forwardBuffers[4] = self._meshLightBuffer.handle
        self._forwardBuffers[5] = self._meshTileCounts.handle
        self._forwardBuffers[6] = self._meshTileLights.handle
    end

    local graph = PassGraph.create(device, swapchainFormat)
    graph:target({
        name = "albedo",
        format = RGBA8,
        clear = {r = 0, g = 0, b = 0, a = 0},
    })
    graph:target({
        name = "normal",
        format = RGBA8,
        -- The alpha is what carries here. Zero marks a pixel as unlit, so
        -- anything nothing drew over composites as the albedo clear instead of
        -- picking up ambient over a normal it never wrote. The rgb encodes a
        -- surface facing the viewer, which is what geometry writes, so the
        -- attachment reads consistently either way.
        clear = {r = 0.5, g = 0.5, b = 1.0, a = 0},
    })
    graph:target({
        -- Surface properties in the established ORM order: ambient
        -- occlusion, roughness and metallic in RGB. Alpha is reserved.
        -- Fully unoccluded, medium roughness and non-metallic is the
        -- neutral material default as well as the attachment clear.
        name = "orm",
        format = RGBA8,
        clear = {r = 1, g = 0.5, b = 0, a = 1},
    })
    graph:target({
        -- What each surface gives off, as a color and how much of it. Its own
        -- attachment rather than a channel borrowed from the two above,
        -- because both of those are spent: the albedo carries an alpha the
        -- resolve passes through and the normal's alpha is the lit flag, and a
        -- glow's color is not its albedo. A lamp's glass is grey and glows
        -- warm.
        --
        -- A color and a strength in one RGBA8 rather than a premultiplied rgb
        -- in three channels, because eight bits a channel is what the format
        -- holds and a dim colored glow premultiplied quantises its hue away.
        -- Both clear to zero, which reads as emitting nothing.
        name = "emission",
        format = RGBA8,
        clear = {r = 0, g = 0, b = 0, a = 0},
    })
    graph:target({
        name = "lit",
        format = lightingFormat,
        clear = {r = 0, g = 0, b = 0, a = 1},
    })
    graph:target({
        -- No clear: this is what anything running between composite and
        -- present writes into, and a clear here would be applied by each of
        -- those passes in turn. Composite covers every pixel and goes first,
        -- so there is nothing undefined for a later pass to load.
        name = "scene",
        format = RGBA8,
    })
    if multiCamera then
        graph:target({
            name = "forwardView",
            format = RGBA8,
            clear = {r = 0, g = 0, b = 0, a = 0},
        })
    end

    if bloom then
        graph:target({
            -- Compatibility surface: games may add passes around this target
            -- by name, so the string stays stable if bloom moves internally.
            name = "bloomA",
            format = lightingFormat,
            scale = bloomScale,
            clear = {r = 0, g = 0, b = 0, a = 1},
        })
        graph:target({
            -- Compatibility surface: games may add passes around this target
            -- by name, so the string stays stable if bloom moves internally.
            name = "bloomB",
            format = lightingFormat,
            scale = bloomScale,
            clear = {r = 0, g = 0, b = 0, a = 1},
        })
    end

    if meshShadows then
        graph:target({
            -- Compatibility surface: games may add passes around this target
            -- by name, so the string stays stable if the mesh modules move.
            name = "meshShadowMap",
            format = R16,
            scale = options.meshShadowScale,
            clear = {r = 1, g = 1, b = 1, a = 1},
        })
    end

    if shadows then
        graph:target({
            -- One mask for every light, rather than a pass per light. Red
            -- carries how tall the occluder covering a pixel is and green marks
            -- that an occluder really covers it, so a march can tell a
            -- silhouette from the halo the blur spreads around one. Both clear
            -- to zero, which reads as no occluder anywhere.
            name = "occluders",
            format = RGBA8,
            scale = self._shadowMaskScale,
            clear = {r = 0, g = 0, b = 0, a = 0},
        })
        graph:target({
            -- Where the first blur pass puts its result so the second can read
            -- it. Nothing outside the two touches it.
            name = "occludersTemp",
            format = RGBA8,
            scale = self._shadowMaskScale,
            clear = {r = 0, g = 0, b = 0, a = 0},
        })
        graph:target({
            -- One channel: how much of all lighting reaches a pixel after every
            -- drop shadow thrown across it. Cleared to white, because a pixel
            -- no shadow lands on multiplies the light it receives by one, and
            -- half sized because it holds nothing sharp.
            name = "dropShadowAO",
            format = R8,
            scale = tuning.dropScale or 0.5,
            clear = {r = 1, g = 1, b = 1, a = 1},
        })
    end

    local lightingDefines: {string: string} = nil
    if shadows or meshShadows or meshFog or meshPBR or meshProbe or meshLights then
        lightingDefines = {}
        if shadows then
            lightingDefines.SHADOWS = "1"
        end
        if meshShadows then
            lightingDefines.MESH_SHADOWS = "1"
        end
        if meshFog then
            lightingDefines.MESH_FOG = "1"
        end
        if meshPBR then
            lightingDefines.MESH_PBR = "1"
        end
        if meshProbe then
            lightingDefines.MESH_PROBE = "1"
        end
        if meshLights then
            lightingDefines.MESH_LIGHTS = "1"
        end
    end
    self._lightingPipeline = buildPipeline(
        device, "deferred.lighting.frag", lightingFormat, "lighting", lightingDefines
    )
    if shadows then
        self._blurPipeline = buildPipeline(device, "occluder.blur.frag", RGBA8, "occluderBlur", nil)
    end
    if bloom then
        self._bloomExtractPipeline = buildPipeline(device, "bloom.extract.frag", lightingFormat, "bloomExtract", nil)
        self._bloomBlurPipeline = buildPipeline(device, "bloom.blur.frag", lightingFormat, "bloomBlur", nil)
    end
    self._compositePipeline = buildPipeline(
        device,
        "deferred.composite.frag",
        RGBA8,
        "composite",
        bloom and {BLOOM = "1"} or nil,
        multiCamera and GraphicsPipeline.BLEND_PREMULTIPLIED or nil
    )
    self._presentPipeline = buildPipeline(device, "deferred.present.frag", swapchainFormat, "present", nil)
    if multiCamera then
        self._viewCompositePipeline = buildPipeline(
            device, "deferred.present.frag", RGBA8, "forwardComposite", nil, GraphicsPipeline.BLEND_PREMULTIPLIED
        )
        graph:pass({
            name = "sceneClear",
            outputs = {"scene"},
            clear = {r = 0, g = 0, b = 0, a = 1},
            enabled = function(): boolean return self._firstView end,
            execute = function(_context: PassGraph.PassContext) end,
        })
    end

    if meshShadows then
        graph:pass({
            -- Compatibility surface: the mesh domain contributes the draw,
            -- while the frame-wide graph owns the target and ordering.
            name = "meshShadows",
            outputs = {"meshShadowMap"},
            enabled = self._meshShadowActive,
            execute = function(context: PassGraph.PassContext)
                if options.meshShadowMap ~= nil then
                    options.meshShadowMap(context)
                end
            end,
        })
    end

    graph:pass({
        name = "geometry",
        inputs = meshShadows and {"meshShadowMap"} or nil,
        outputs = {"albedo", "normal", "orm", "emission"},
        -- Cleared to the far plane every frame, and less-or-equal rather than
        -- "less" so equal depths still resolve to whatever drew last. Draw
        -- order is deterministic and means something here, so depth decides
        -- between instances that differ and leaves the rest alone.
        depth = {
            test = true,
            write = true,
            compare = GraphicsPipeline.COMPARE_LESS_OR_EQUAL,
            clear = 1.0,
        },
        execute = function(context: PassGraph.PassContext)
            if options.geometry ~= nil then
                options.geometry(context)
            end
        end,
    })

    if shadows then
        graph:pass({
            -- Before lighting rather than after, because the mask is what
            -- lighting reads. This is the seam shadows want, and it is a
            -- different one from the seam a post-process wants: a shadow is not
            -- something done to a finished image.
            name = "occluders",
            outputs = {"occluders"},
            enabled = self._shadowActive,
            execute = function(context: PassGraph.PassContext)
                if options.occluders ~= nil then
                    options.occluders(context)
                end
            end,
        })
        graph:pass({
            name = "occluderBlurH",
            inputs = {"occluders"},
            outputs = {"occludersTemp"},
            enabled = self._shadowActive,
            execute = function(context: PassGraph.PassContext)
                local blur <const> = self._blurUniform
                blur[0] = 1.0 / context.width
                blur[1] = 0.0
                blur[2] = 0.0
                blur[3] = 0.0
                context.pass:bindPipeline(self._blurPipeline.handle)
                C.SDL_PushGPUFragmentUniformData(context.commandBuffer, 0, blur, 16)
                context.pass:draw(3)
            end,
        })
        graph:pass({
            -- Back into the mask, which a target may be written twice for. The
            -- clear it declares is applied again and costs nothing: this covers
            -- every pixel of it, so there is nothing of the first write left to
            -- preserve.
            name = "occluderBlurV",
            inputs = {"occludersTemp"},
            outputs = {"occluders"},
            enabled = self._shadowActive,
            execute = function(context: PassGraph.PassContext)
                local blur <const> = self._blurUniform
                blur[0] = 0.0
                blur[1] = 1.0 / context.height
                blur[2] = 0.0
                blur[3] = 0.0
                context.pass:bindPipeline(self._blurPipeline.handle)
                C.SDL_PushGPUFragmentUniformData(context.commandBuffer, 0, blur, 16)
                context.pass:draw(3)
            end,
        })
        graph:pass({
            -- Reads no G-buffer target, so it introduces no dependency the
            -- graph has to resolve and could sit anywhere before lighting. It
            -- is here because that is where a reader looks for it.
            name = "dropShadowAO",
            outputs = {"dropShadowAO"},
            enabled = self._shadowActive,
            execute = function(context: PassGraph.PassContext)
                if options.dropShadows ~= nil then
                    options.dropShadows(context)
                end
            end,
        })
    end

    graph:pass({
        name = "lighting",
        -- Declaration order is binding order, and the shader numbers its
        -- samplers to match: the G-buffer's four first, then the two a
        -- pipeline built with shadows on adds.
        inputs = shadows and meshPBR and {"albedo", "normal", "orm", "emission", "depth", "occluders", "dropShadowAO"}
            or shadows and {"albedo", "normal", "orm", "emission", "occluders", "dropShadowAO"}
            or meshPBR and {"albedo", "normal", "orm", "emission", "depth"}
            or {"albedo", "normal", "orm", "emission"},
        outputs = {"lit"},
        execute = function(context: PassGraph.PassContext)
            local scene <const> = sceneUniform(
                self,
                self._multiCamera and self._viewportWidth or context.width,
                self._multiCamera and self._viewportHeight or context.height
            )

            local buffers <const> = self._lightingBuffers
            buffers[1] = self._lightBuffer.handle
            buffers[2] = self._tileCounts.handle
            buffers[3] = self._tileLights.handle
            if self._meshLights then
                buffers[4] = self._meshLightBuffer.handle
                buffers[5] = self._meshTileCounts.handle
                buffers[6] = self._meshTileLights.handle
            end

            context.pass:bindPipeline(self._lightingPipeline.handle)
            context.pass:bindFragmentStorageBuffers(0, buffers)
            C.SDL_PushGPUFragmentUniformData(context.commandBuffer, 0, scene, self._sceneBytes)
            context.pass:draw(3)
        end,
    })

    if bloom then
        graph:pass({
            -- Compatibility surface: games may place their own pass around
            -- this one by name, so the string remains stable.
            name = "bloomExtract",
            inputs = {"lit"},
            outputs = {"bloomA"},
            execute = function(context: PassGraph.PassContext)
                context.pass:bindPipeline(self._bloomExtractPipeline.handle)
                C.SDL_PushGPUFragmentUniformData(context.commandBuffer, 0, self._bloomUniform, 16)
                context.pass:draw(3)
            end,
        })
        graph:pass({
            -- Compatibility surface: games may place their own pass around
            -- this one by name, so the string remains stable.
            name = "bloomBlurX",
            inputs = {"bloomA"},
            outputs = {"bloomB"},
            execute = function(context: PassGraph.PassContext)
                local step <const> = self._bloomStep
                step[0], step[1], step[2], step[3] = 1.0 / context.width, 0.0, 0.0, 0.0
                context.pass:bindPipeline(self._bloomBlurPipeline.handle)
                C.SDL_PushGPUFragmentUniformData(context.commandBuffer, 0, step, 16)
                context.pass:draw(3)
            end,
        })
        graph:pass({
            -- Compatibility surface: games may place their own pass around
            -- this one by name, so the string remains stable.
            name = "bloomBlurY",
            inputs = {"bloomB"},
            outputs = {"bloomA"},
            execute = function(context: PassGraph.PassContext)
                local step <const> = self._bloomStep
                step[0], step[1], step[2], step[3] = 0.0, 1.0 / context.height, 0.0, 0.0
                context.pass:bindPipeline(self._bloomBlurPipeline.handle)
                C.SDL_PushGPUFragmentUniformData(context.commandBuffer, 0, step, 16)
                context.pass:draw(3)
            end,
        })
    end

    graph:pass({
        name = "composite",
        inputs = bloom and {"lit", "bloomA"} or {"lit"},
        outputs = {"scene"},
        clear = multiCamera and PassGraph.LOAD or nil,
        execute = function(context: PassGraph.PassContext)
            if self._multiCamera then
                context.pass:setViewport(self._viewportX, self._viewportY, self._viewportWidth, self._viewportHeight)
                context.pass:setScissor(self._viewportX, self._viewportY, self._viewportWidth, self._viewportHeight)
            end
            context.pass:bindPipeline(self._compositePipeline.handle)
            context.pass:draw(3)
        end,
    })

    graph:pass({
        -- Writes what composite left rather than clearing it, which `scene`
        -- gives for nothing by declaring no clear of its own.
        --
        -- Depth is attached without a clear, so what it loads is what geometry
        -- wrote, and without a write, so a blended fragment is rejected by the
        -- opaque geometry in front of it and rejects nothing itself. That is
        -- the whole of why blended content has to arrive sorted: depth decides
        -- it against the G-buffer and cannot decide it against itself.
        name = "forward",
        inputs = meshShadows and {"meshShadowMap"} or nil,
        outputs = multiCamera and {"forwardView"} or {"scene"},
        depth = {test = true, write = false},
        execute = function(context: PassGraph.PassContext)
            if options.forward ~= nil then
                options.forward(context)
            end
        end,
    })

    if multiCamera then
        graph:pass({
            name = "forwardComposite",
            inputs = {"forwardView"},
            outputs = {"scene"},
            clear = PassGraph.LOAD,
            execute = function(context: PassGraph.PassContext)
                context.pass:setViewport(self._viewportX, self._viewportY, self._viewportWidth, self._viewportHeight)
                context.pass:setScissor(self._viewportX, self._viewportY, self._viewportWidth, self._viewportHeight)
                context.pass:bindPipeline(self._viewCompositePipeline.handle)
                context.pass:draw(3)
            end,
        })
    end

    graph:pass({
        -- Declared last and executed last, since the graph runs passes in
        -- declaration order and this is the one that writes the swapchain.
        -- Anything added to the seam is declared above this, not after it.
        name = "present",
        inputs = {"scene"},
        outputs = {},
        enabled = multiCamera and function(): boolean return self._lastView end or nil,
        execute = function(context: PassGraph.PassContext)
            context.pass:bindPipeline(self._presentPipeline.handle)
            context.pass:draw(3)
        end,
    })

    self.graph = graph
    return self
end

--- Says where the view is, so the lighting pass can invert it.
---
--- Lights are placed in world units and the lighting pass runs over target
--- pixels, so something has to relate the two, and it has to be the same
--- relation the geometry pass drew with or a light lands away from what it is
--- lighting. Four numbers rather than a matrix, because the projection is
--- orthographic: its inverse is a rotation, a scale and an offset, and the
--- shader applies it in two multiply-adds.
---
--- Called every frame by whatever owns the camera. A pipeline nothing calls
--- this on centers a view on the target instead, which makes world units
--- target pixels.
--- @param x Center of the view in world units.
--- @param y Center of the view in world units, with Y running down.
--- @param zoom Above one magnifies. Zero is treated as one rather than
---     dividing through, since a view that shows nothing is not what a caller
---     assigning a zoom of zero meant.
--- @param rotation Radians, the same sense the camera turns in.
function Deferred:setView(x: number, y: number, zoom: number, rotation: number)
    self._viewSet = true
    self._viewX = x
    self._viewY = y
    local scale <const> = zoom ~= 0.0 and zoom or 1.0
    local inverse <const> = 1.0 / scale
    self._viewCos = math.cos(rotation) * inverse
    self._viewSin = math.sin(rotation) * inverse
    -- Kept unfolded as well, because the mask's projection is this camera at
    -- another zoom and a pair with the zoom already divided through cannot say
    -- which part of it was the zoom.
    self._viewZoom = scale
    self._viewRotation = rotation
end

--- Replaces the light set for subsequent frames.
---
--- One block copy into the buffer's mapped staging, because the caller's array
--- is already the shape the shader reads and the whole set is at most eight
--- kilobytes. The upload itself is deferred to `render`, so it rides the
--- frame's command buffer instead of submitting its own.
---
--- Past `lightlayout.MAX` the remainder is dropped rather than reported,
--- because the alternative is a frame that raises over a light nobody would
--- have picked out of the image.
--- @param data Lights already in `lightlayout` order, `FLOATS` per light.
--- @param count Lights in `data`. Zero leaves the buffer as it was and lights
---     nothing, since the count is what the shader loops over.
function Deferred:setLightData(data: loader.CArray, count: integer)
    if count > MAX_LIGHTS then
        count = MAX_LIGHTS
    end
    self.lightCount = count
    if count == 0 then
        return
    end

    local bytes <const> = count * LIGHT_STRIDE
    loader.copyTo(self._lightBuffer:map(), data as loader.CValue, bytes)
    self._lightBuffer:markDirty(0, bytes)
end

--- Replaces the optional mesh-local point and spot light set.
--- @param data Lights already packed in `meshlightlayout` order.
--- @param count Lights in `data`, clamped to the configured capacity.
function Deferred:setMeshLightData(data: loader.CArray, count: integer)
    if not self._meshLights then
        error("tecs: mesh local lights are not enabled", 2)
    end
    if count > self._meshLightCapacity then
        count = self._meshLightCapacity
    end
    self.meshLightCount = count
    if count == 0 then
        return
    end
    local bytes <const> = count * MESH_LIGHT_STRIDE
    loader.copyTo(self._meshLightBuffer:map(), data as loader.CValue, bytes)
    self._meshLightBuffer:markDirty(0, bytes)
end

--- Replaces the light set from records rather than from packed floats.
---
--- The record form is what a caller assembling a handful of lights by hand
--- wants. Anything producing a light per entity per frame packs directly and
--- calls `setLightData`, since a record per light per frame is an allocation
--- per light per frame.
--- @param lights Lights to light with, replacing the previous set entirely.
function Deferred:setLights(lights: {Light})
    local count = math.min(#lights, MAX_LIGHTS)
    local scratch = self._lightScratch
    for index = 1, count do
        local light = lights[index]
        local base = (index - 1) * LIGHT_FLOATS
        scratch[base] = light.x or 0.0
        scratch[base + 1] = light.y or 0.0
        scratch[base + 2] = light.z or 32.0
        scratch[base + 3] = light.radius or 128.0
        scratch[base + 4] = light.r or 1.0
        scratch[base + 5] = light.g or 1.0
        scratch[base + 6] = light.b or 1.0
        scratch[base + 7] = light.intensity or 1.0
    end
    self:setLightData(scratch, count)
end

--- Resolves the view for a frame of this size, and the grid it implies.
---
--- One derivation, read by the binning dispatch and by the lighting pass. The
--- world rectangle is the axis-aligned bound of what the camera can see, which
--- is wider than the view when the camera is turned: every fragment's world
--- position lands inside it either way, which is what a grid a fragment
--- indexes into has to promise.
local function resolveView(self: Deferred, width: number, height: number)
    if self._viewSet then
        self._frameViewX = self._viewX
        self._frameViewY = self._viewY
        self._frameViewCos = self._viewCos
        self._frameViewSin = self._viewSin
        self._frameViewZoom = self._viewZoom
        self._frameViewRotation = self._viewRotation
    else
        -- Centerd on the target at zoom one, which puts a world unit on a
        -- target pixel and the world origin in the corner. The size is only
        -- known here, which is why the default is applied per frame rather
        -- than at creation.
        self._frameViewX = width * 0.5
        self._frameViewY = height * 0.5
        self._frameViewCos = 1.0
        self._frameViewSin = 0.0
        self._frameViewZoom = 1.0
        self._frameViewRotation = 0.0
    end

    -- The mask's own zoom, widened so the shadow margin lands inside it. The
    -- widening is the smaller of what each axis asks for, so both get at least
    -- the margin and the projection stays uniform: two zooms would be a
    -- non-uniform scale, which a rotation does not survive.
    local margin <const> = 2.0 * self._shadowMargin
    local worldWidth <const> = width / self._frameViewZoom
    local worldHeight <const> = height / self._frameViewZoom
    local ratio <const> = math.min(worldWidth / (worldWidth + margin), worldHeight / (worldHeight + margin))
    self._maskZoom = self._frameViewZoom * ratio

    -- Half the target against the view's own axes. The two components already
    -- carry the reciprocal zoom, so this is the half extent in world units:
    -- the same `width / (2 * zoom)` the cull works from, with the rotation
    -- folded in rather than applied after.
    local halfWidth <const> = width * 0.5
    local halfHeight <const> = height * 0.5
    local across <const> = math.abs(self._frameViewCos)
    local down <const> = math.abs(self._frameViewSin)
    local extentX <const> = halfWidth * across + halfHeight * down
    local extentY <const> = halfWidth * down + halfHeight * across
    self._boundsMinX = self._frameViewX - extentX
    self._boundsMinY = self._frameViewY - extentY
    self._boundsMaxX = self._frameViewX + extentX
    self._boundsMaxY = self._frameViewY + extentY
end

--- Runs the pipeline for one frame.
---
--- Any pending light writes are flushed onto this frame's command buffer
--- first, so the copy is ordered against the binning dispatch and the lighting
--- pass that read it rather than racing a separately submitted upload.
---
--- Binning runs every frame, including one with nothing lighting anything. It
--- is the only writer of the tile counts, so a frame that skipped it would
--- leave the last frame's lists standing and light the scene by lights that
--- have gone. A thousand threads writing a zero is cheaper than the guard that
--- would be needed to make skipping safe.
--- @param frame The frame to record into. Present writes to its swapchain
---     texture and the graph sizes its targets to its width and height, so a
---     resized window is picked up here rather than announced.
function Deferred:render(
    frame: Frame,
    viewportX?: integer,
    viewportY?: integer,
    viewportWidth?: integer,
    viewportHeight?: integer,
    firstView?: boolean,
    lastView?: boolean
)
    self._lightBuffer:flush(frame.commandBuffer)
    if self._meshLights then
        self._meshLightBuffer:flush(frame.commandBuffer)
    end
    local width <const> = viewportWidth or frame.width
    local height <const> = viewportHeight or frame.height
    self._viewportX, self._viewportY = viewportX or 0, viewportY or 0
    self._viewportWidth, self._viewportHeight = width, height
    self._firstView = firstView ~= false
    self._lastView = lastView ~= false
    resolveView(self, width, height)

    local bin <const> = self._binUniform
    bin[0] = self._boundsMinX
    bin[1] = self._boundsMinY
    bin[2] = self._boundsMaxX
    bin[3] = self._boundsMaxY
    bin[4] = self.lightCount
    bin[5] = 0.0
    bin[6] = 0.0
    bin[7] = 0.0

    local writes <const> = self._binWrites
    writes[1] = self._tileCounts.handle
    writes[2] = self._tileLights.handle
    local reads <const> = self._binReads
    reads[1] = self._lightBuffer.handle

    local pass <const> = ComputePass.begin(frame.commandBuffer, writes, self._binPass)
    self._binPass = pass
    pass:bindPipeline(self._binPipeline.handle)
    pass:bindStorageBuffers(0, reads)
    C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, bin, 32)
    pass:dispatch(math.ceil(TILE_COUNT / BIN_GROUP))
    pass:finish()

    if self._meshLights then
        local meshBin <const> = self._meshBinUniform
        for lane = 0, 15 do
            meshBin[lane] = self._meshViewProjection[lane]
        end
        meshBin[16] = self.meshLightCount
        meshBin[17] = width
        meshBin[18] = height
        meshBin[19] = 0.0
        local meshWrites <const> = self._meshBinWrites
        meshWrites[1] = self._meshTileCounts.handle
        meshWrites[2] = self._meshTileLights.handle
        local meshReads <const> = self._meshBinReads
        meshReads[1] = self._meshLightBuffer.handle
        local meshPass <const> = ComputePass.begin(frame.commandBuffer, meshWrites, self._meshBinPass)
        self._meshBinPass = meshPass
        meshPass:bindPipeline(self._meshBinPipeline.handle)
        meshPass:bindStorageBuffers(0, meshReads)
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, meshBin, 80)
        meshPass:dispatch(math.ceil(TILE_COUNT / BIN_GROUP))
        meshPass:finish()
    end

    self.graph:execute(frame)
end

--- Rebuilds the pipelines this owns from their shaders.
---
--- The same formats and the same graph: only the pipeline objects change, and
--- every pass reads them through `self` when it executes, so the next frame
--- binds the new ones with nothing rebuilt around them.
---
--- All are built before any old one is released, so a shader that no longer
--- compiles leaves the pipelines exactly as they were and raises. Must not run
--- inside a pass: what it releases is what a recorded pass is still reading.
function Deferred:rebuildPipelines()
    local device <const> = self._device
    C.SDL_WaitForGPUIdle(device)

    local lighting: GraphicsPipeline = nil
    local composite: GraphicsPipeline = nil
    local present: GraphicsPipeline = nil
    local viewComposite: GraphicsPipeline = nil
    local blur: GraphicsPipeline = nil
    local bloomExtract: GraphicsPipeline = nil
    local bloomBlur: GraphicsPipeline = nil
    local bin: ComputePipeline = nil
    local meshBin: ComputePipeline = nil
    local built, reason = pcall(function(): string
        local defines: {string: string} = nil
        if
            self._shadows or self._meshShadows or self._meshFog or self._meshPBR or self._meshProbe or self._meshLights
        then
            defines = {}
            if self._shadows then
                defines.SHADOWS = "1"
            end
            if self._meshShadows then
                defines.MESH_SHADOWS = "1"
            end
            if self._meshFog then
                defines.MESH_FOG = "1"
            end
            if self._meshPBR then
                defines.MESH_PBR = "1"
            end
            if self._meshProbe then
                defines.MESH_PROBE = "1"
            end
            if self._meshLights then
                defines.MESH_LIGHTS = "1"
            end
        end
        local lightingFormat <const> = self._lightingFormat
        lighting = buildPipeline(device, "deferred.lighting.frag", lightingFormat, "lighting", defines)
        if self._bloom then
            bloomExtract = buildPipeline(device, "bloom.extract.frag", lightingFormat, "bloomExtract", nil)
            bloomBlur = buildPipeline(device, "bloom.blur.frag", lightingFormat, "bloomBlur", nil)
        end
        composite = buildPipeline(
            device,
            "deferred.composite.frag",
            RGBA8,
            "composite",
            self._bloom and {BLOOM = "1"} or nil,
            self._multiCamera and GraphicsPipeline.BLEND_PREMULTIPLIED or nil
        )
        present = buildPipeline(device, "deferred.present.frag", self.graph.swapchainFormat, "present", nil)
        if self._multiCamera then
            viewComposite = buildPipeline(
                device, "deferred.present.frag", RGBA8, "forwardComposite", nil, GraphicsPipeline.BLEND_PREMULTIPLIED
            )
        end
        if self._shadows then
            blur = buildPipeline(device, "occluder.blur.frag", RGBA8, "occluderBlur", nil)
        end
        bin = ComputePipeline.load(device, "deferred.lightbin.comp", {})
        if self._meshLights then
            meshBin = ComputePipeline.load(device, "mesh.lightbin.comp", {})
        end
    end)
    if not built then
        if lighting ~= nil then
            lighting:destroy()
        end
        if composite ~= nil then
            composite:destroy()
        end
        if present ~= nil then
            present:destroy()
        end
        if viewComposite ~= nil then
            viewComposite:destroy()
        end
        if blur ~= nil then
            blur:destroy()
        end
        if bloomExtract ~= nil then
            bloomExtract:destroy()
        end
        if bloomBlur ~= nil then
            bloomBlur:destroy()
        end
        if bin ~= nil then
            bin:destroy()
        end
        if meshBin ~= nil then
            meshBin:destroy()
        end
        error(reason, 0)
    end

    local oldLighting <const> = self._lightingPipeline
    local oldComposite <const> = self._compositePipeline
    local oldPresent <const> = self._presentPipeline
    local oldViewComposite <const> = self._viewCompositePipeline
    local oldBlur <const> = self._blurPipeline
    local oldBloomExtract <const> = self._bloomExtractPipeline
    local oldBloomBlur <const> = self._bloomBlurPipeline
    local oldBin <const> = self._binPipeline
    local oldMeshBin <const> = self._meshBinPipeline
    self._lightingPipeline = lighting
    self._compositePipeline = composite
    self._presentPipeline = present
    self._viewCompositePipeline = viewComposite
    self._blurPipeline = blur
    self._bloomExtractPipeline = bloomExtract
    self._bloomBlurPipeline = bloomBlur
    self._binPipeline = bin
    self._meshBinPipeline = meshBin
    oldLighting:destroy()
    oldComposite:destroy()
    oldPresent:destroy()
    if oldViewComposite ~= nil then
        oldViewComposite:destroy()
    end
    if oldBlur ~= nil then
        oldBlur:destroy()
    end
    if oldBloomExtract ~= nil then
        oldBloomExtract:destroy()
        oldBloomBlur:destroy()
    end
    oldBin:destroy()
    if oldMeshBin ~= nil then
        oldMeshBin:destroy()
    end
end

--- Returns the four formats a geometry pipeline must be created against.
---
--- In attachment order, so a pipeline passes them straight through as its
--- color formats and cannot get two of them the wrong way round. These use all
--- four color attachments a render pass allows.
--- @return The albedo target's format, which is color attachment zero.
--- @return The normal target's format, which is color attachment one.
--- @return The ORM target's format, which is color attachment two.
--- @return The emission target's format, which is color attachment three.
function Deferred:geometryFormats(): integer, integer, integer, integer
    return self.graph:formatOf("albedo"),
        self.graph:formatOf("normal"),
        self.graph:formatOf("orm"),
        self.graph:formatOf("emission")
end

--- Returns the depth state a geometry pipeline must be created with.
---
--- Taken from the pass rather than restated, so the pipeline cannot disagree
--- with the attachment it draws into.
function Deferred:geometryDepth(): GraphicsPipeline.DepthConfig
    return self.graph:depthOf("geometry")
end

--- Returns the color format a forward pipeline must be created against.
---
--- One target rather than the G-buffer's four: the forward pass draws onto the
--- composited image, which is a picture and not a description of a surface. A
--- blended fragment therefore adds its own emission to its own color and reaches
--- the emission attachment not at all.
function Deferred:forwardFormat(): integer
    return self.graph:formatOf("scene")
end

--- Returns the depth state a forward pipeline must be created with.
---
--- Taken from the pass, like `geometryDepth`, so the pipeline cannot disagree
--- with the attachment it draws into. It is the geometry pass's attachment with
--- writing turned off, which is the state the pass declares.
function Deferred:forwardDepth(): GraphicsPipeline.DepthConfig
    return self.graph:depthOf("forward")
end

--- Binds the lights and the scene block a forward fragment stage shades with.
---
--- Called from inside the forward callback, after its pipeline is bound. The
--- lights are this module's and the geometry is the caller's, so the split is
--- here rather than in the callback reaching for buffers it does not own.
---
--- Fragment uniform slot one remains fixed. Fragment storage starts at
--- `firstSlot`, which defaults to zero so a domain can reserve its material
--- table ahead of the shared light buffers.
--- @param context The deferred graph supplies the open pass and current frame.
--- @param firstSlot The caller optionally reserves earlier fragment storage
---     slots for its own data. It defaults to zero.
function Deferred:bindLighting(context: PassGraph.PassContext, firstSlot?: integer)
    local buffers <const> = self._forwardBuffers
    buffers[1] = self._lightBuffer.handle
    buffers[2] = self._tileCounts.handle
    buffers[3] = self._tileLights.handle
    if self._meshLights then
        buffers[4] = self._meshLightBuffer.handle
        buffers[5] = self._meshTileCounts.handle
        buffers[6] = self._meshTileLights.handle
    end
    context.pass:bindFragmentStorageBuffers(firstSlot or 0, buffers)
    C.SDL_PushGPUFragmentUniformData(
        context.commandBuffer,
        1,
        sceneUniform(
            self,
            self._multiCamera and self._viewportWidth or context.width,
            self._multiCamera and self._viewportHeight or context.height
        ),
        SCENE_BYTES
    )
end

--- Flushes any pending light writes onto a frame's command buffer.
---
--- Called by whoever is about to dispatch compute that reads the lights, which
--- is ahead of where `render` would have flushed them: the shadow lane's
--- compaction picks which lights a caster throws a copy by, and a pass reading
--- a buffer whose upload has not been recorded reads the frame before. Safe to
--- call more than once, since a flush with nothing dirty records nothing.
--- @param frame The frame whose command buffer the copy rides.
function Deferred:flushLights(frame: Frame)
    self._lightBuffer:flush(frame.commandBuffer)
end

--- The buffer the lights are packed into.
---
--- For a pass that has to read them and is not one of this pipeline's own: the
--- shadow lane's compaction runs on the other side of the boundary and still
--- has to choose by the same lights the resolve shades with.
function Deferred:lightHandle(): loader.CValue
    return self._lightBuffer.handle
end

--- How far outside the view a caster is still kept, in world units.
---
--- Asked rather than restated, because the cull that keeps one and the
--- projection that has to have room for it are on opposite sides of the
--- boundary, and a caster kept by a wider rectangle than the mask covers is a
--- silhouette drawn off the edge of the mask.
function Deferred:shadowMargin(): number
    return self._shadowMargin
end

--- Whether this pipeline has an occluder mask and a drop-shadow target.
---
--- Asked rather than assumed, because everything the shadow lane costs on the
--- other side of the boundary is gated on the same answer: a backend that
--- allocated a shadow list for a pipeline with nowhere to draw it would be
--- paying for a list nothing reads.
function Deferred:castsShadows(): boolean
    return self._shadows
end

--- Reports whether the graph owns the mesh directional-shadow target.
--- @return Returns true only when renderer creation enabled mesh shadows.
function Deferred:castsMeshShadows(): boolean
    return self._meshShadows
end

--- Returns the format a mesh shadow-map pipeline must write.
--- @return Returns the graph-owned single-channel normalized format.
function Deferred:meshShadowFormat(): integer
    return self.graph:formatOf("meshShadowMap")
end

--- Updates the directional light applied only to shadow-enabled mesh pixels.
--- @param x Normalized direction from a surface toward the light.
--- @param y Normalized direction from a surface toward the light.
--- @param z Normalized direction from a surface toward the light.
--- @param intensity Non-negative directional-light intensity.
--- @param r Directional-light red.
--- @param g Directional-light green.
--- @param b Directional-light blue.
function Deferred:setMeshLight(x: number, y: number, z: number, intensity: number, r: number, g: number, b: number)
    self._meshLightX, self._meshLightY, self._meshLightZ = x, y, z
    self._meshLightIntensity = intensity
    self._meshLightR, self._meshLightG, self._meshLightB = r, g, b
end

--- Updates the color used for mesh fog in the next lighting resolve.
--- @param r The mesh domain supplies normalized red.
--- @param g The mesh domain supplies normalized green.
--- @param b The mesh domain supplies normalized blue.
function Deferred:setMeshFog(r: number, g: number, b: number)
    self._meshFogR, self._meshFogG, self._meshFogB = r, g, b
end

--- Updates the six RGB faces of the mesh ambient-cube probe.
--- @param values The mesh domain supplies six padded RGB vectors in positive
---     X, negative X, positive Y, negative Y, positive Z, negative Z order.
function Deferred:setMeshProbe(values: loader.CArray)
    if not self._meshProbe then
        return
    end
    for lane = 0, MESH_PROBE_FLOATS - 1 do
        self._meshProbeUniform[lane] = values[lane]
    end
end

--- Updates the perspective view used to reconstruct opaque mesh positions.
--- @param x World-space camera x.
--- @param y World-space camera y.
--- @param z World-space camera z.
--- @param viewProjection Sixteen column-major world-to-clip floats.
--- @param inverseViewProjection Sixteen column-major clip-to-world floats.
function Deferred:setMeshView(
    x: number, y: number, z: number, viewProjection: loader.CArray, inverseViewProjection: loader.CArray
)
    self._meshCameraX, self._meshCameraY, self._meshCameraZ = x, y, z
    for lane = 0, 15 do
        self._meshViewProjection[lane] = viewProjection[lane]
        self._inverseViewProjection[lane] = inverseViewProjection[lane]
    end
end

--- The color format a pipeline drawing into the occluder mask must be created
--- against, and the one drawing into the drop-shadow target.
---
--- Both from the graph rather than restated, so a pipeline cannot disagree with
--- the attachment it draws into. Raises when shadows are off, since there is no
--- target to answer for.
--- @return The occluder mask's format.
--- @return The drop-shadow target's format, which is one channel.
function Deferred:castFormats(): integer, integer
    return self.graph:formatOf("occluders"), self.graph:formatOf("dropShadowAO")
end

--- The camera the occluder mask is drawn with, as four numbers.
---
--- The scene's own camera at a wider zoom: wide enough that the shadow margin
--- lands inside the mask rather than off its edge, and scaled to the mask's own
--- size rather than the frame's. Resolved once a frame beside everything else,
--- because the pass that draws the mask and the pass that inverts it have to
--- agree exactly, and two derivations of one projection are two things that can
--- disagree.
---
--- Valid only during a frame's passes: it is what `render` resolved for the
--- frame being drawn.
--- @return Center of the view in world units.
--- @return Center of the view in world units, with Y running down.
--- @return Zoom the mask is drawn at, which is not the camera's. It is meant
---     for a matrix built at the frame's size and not at the mask's: clip space
---     carries no resolution, so the mask's own scale is not in this and must
---     not be applied to it.
--- @return Rotation in radians, which is the camera's.
function Deferred:maskView(): number, number, number, number
    return self._frameViewX, self._frameViewY, self._maskZoom, self._frameViewRotation
end

--- Fills the block one of the three shadow draws is placed from.
---
--- The matrix is the caller's, because only the caller knows what size target
--- the pass is writing; everything else is this pipeline's configuration and is
--- filled in here so a draw cannot be issued at an opacity or a length the
--- resolve was not told about.
--- @param matrix World to clip for the target being drawn into, which for the
---     mask is `maskView` at the pass's own width and height and for the other
---     two is the scene camera's.
--- @param mode `Deferred.MASK`, `Deferred.SHADOW` or `Deferred.STAMP`.
--- @return The block to push, which is this pipeline's and is rewritten by the
---     next call.
function Deferred:castUniform(matrix: loader.CArray, mode: integer): loader.CArray
    local block <const> = self._castUniform
    for slot = 0, 15 do
        block[slot] = matrix[slot]
    end
    block[16] = self._stepClock
    block[17] = mode
    block[18] = self._dropShadowOpacity
    block[19] = self._dropShadowLength
    return block
end

--- Bytes `castUniform` fills, for the caller that pushes it.
function Deferred.castUniformSize(): integer
    return CAST_BYTES
end

--- Says what the animation clock reads, so a caster's silhouette is the frame
--- it is showing.
---
--- Set once per frame by whoever owns the clock, before the passes run. A
--- pipeline nothing calls this on resolves every playback at step zero, which
--- is the first frame of every animation.
--- @param clock Whole fixed steps since the world started.
function Deferred:setStepClock(clock: number)
    self._stepClock = clock
end

--- Releases everything the pipeline owns. Safe to call more than once.
function Deferred:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    self.graph:destroy()
    self._lightingPipeline:destroy()
    self._compositePipeline:destroy()
    if self._bloom then
        self._bloomExtractPipeline:destroy()
        self._bloomBlurPipeline:destroy()
    end
    self._presentPipeline:destroy()
    if self._viewCompositePipeline ~= nil then
        self._viewCompositePipeline:destroy()
    end
    if self._blurPipeline ~= nil then
        self._blurPipeline:destroy()
    end
    self._binPipeline:destroy()
    if self._meshLights then
        self._meshBinPipeline:destroy()
        self._meshLightBuffer:destroy()
        self._meshTileCounts:destroy()
        self._meshTileLights:destroy()
    end
    self._lightBuffer:destroy()
    self._tileCounts:destroy()
    self._tileLights:destroy()
end

return Deferred
