---
description: "Turns a world into a frame, through an extractor that builds a frame packet and a backend that draws it"
outline: [2, 3]
---

# tecs.renderer.Renderer

`tecs.renderer.Renderer` is the path from a world to the GPU. A game does not construct one: the
[application](/modules/application) does, and hands it over as `app.renderer`.

```teal
return tecs.application.create({
    plugin = function(world: tecs.World, app: tecs.application.Application)
        app.renderer.camera.zoom = 2.0
    end,
})
```

## Two halves and a seam

The renderer owns two objects that never see each other's concerns.

**`Extractor` is world-facing.** Queries, archetype runs, relayout detection, dirty gating, instance producers
and the interpolation alpha. It writes instances straight into mapped staging memory.

**`Backend` is device-facing.** The buffers, the flush, the cull, the deferred pass graph and the image array.

**`FramePacket` is everything that crosses**, and neither half holds a reference to the other.

The line is a dependency rule, not a thread boundary. Both halves run on the main thread, one after the other:
the extractor inside `world:update`, in the `RenderFirst` phase, and the backend afterwards against an acquired
frame. What the rule buys is that extraction needs no command buffer and rendering needs no world, so a world
extracts with no device behind it and the backend is exercised with no world in front of it.

The renderer is what still sees both. It owns the packet, rotates the staging slot, and hands the backend's
mapped addresses to the extractor. `renderer.camera` is the extractor's camera and `renderer.images` is the
backend's array, named here so neither half has to be reached for.

## Deferred, and GPU-driven

Rendering is deferred: geometry is rasterised once regardless of how many lights touch it, and lighting runs over
the resulting G-buffer. That is what makes light count independent of object count.

It is GPU-driven: a compute pass culls and compacts a visible list, and one indirect draw consumes it. Compaction
is an ordered three-pass scan rather than an atomic append, because draw order has to be deterministic. Material
dispatch is compiled into a single fragment shader from the material set, so the scene is one draw.

Four passes:

| Pass        | What it does                                                  |
| ----------- | ------------------------------------------------------------- |
| `geometry`  | Fills the G-buffer from the compacted instance list           |
| `lighting`  | Resolves the G-buffer against a buffer of lights, tile-binned |
| `composite` | Turns that into the frame's image, in the `scene` target      |
| `present`   | Copies `scene` to the swapchain                               |

Composite and present are two passes rather than one because a pass writing directly to the swapchain writes to a
texture that cannot be sampled: it belongs to the presenter once submitted and is not created with the sampled
usage bit. `scene` is the seam that buys the gap. It is a graph target like any other, and anything declared
between composite and present can read it — a forward pass drawing blended geometry over the composited image
with depth from the geometry pass, a post-process reading `scene` and writing it back, or a second view
compositing into a rectangle of the same `scene`. `scene` declares no clear, so every pass that writes it loads
what is already there.

`renderer.deferred` is that pipeline, exposed so a caller can add targets and passes around the ones it has.

### Adding a pass

Passes name the targets they read and write, and the graph owns those targets: it resizes them with the frame,
begins and ends each pass, and binds each pass's inputs as fragment samplers, so a pass body only draws.

Four rules decide where a new pass goes and what it sees.

- **Execution follows declaration order**, not a topological sort. The order of a deferred pipeline is a design
  decision rather than something to rediscover every frame, and a graph that silently reordered would be harder
  to reason about than one that refuses to run. `present` is declared last because it is the pass that writes the
  swapchain, so anything added to the seam is declared above it.
- **Inputs are validated when the graph is built.** A pass reading a target no pass declares, or reading one
  before any pass writes it, raises there rather than drawing black later.
- **A colour clear comes from the target**, which is right while one pass writes a target and wrong as soon as
  two do, since the second would clear the first one's result away. A pass may name its own clear, which wins,
  and `PassGraph.LOAD` is how it says to load whatever the target holds. That is what a pass accumulating into a
  target an earlier pass filled needs.
- **A pass that should be skipped says so through `enabled`.** The graph knows nothing about entities,
  archetypes or dirtiness, so that is where a dirty gate plugs in without the graph learning what dirty means.

Depth state is declared per pass, and the depth attachment's format is discovered rather than assumed: Metal has
no `D24_UNORM` and a Vulkan driver may have that one and not `D32_FLOAT`, so the device is asked which it
supports. `D16_UNORM` is the floor SDL guarantees, and its step is coarser than the layer sort's own resolution:
on a device that offers nothing better, the bands still hold, so a HUD still covers a world, but entities close
together within a band share a depth value and draw in the order they were written rather than the order they
were sorted into. That is reported and drawn rather than raised, because refusing the depth target would leave a
device with no picture at all over a sort many scenes never use. The log line names the format, says how many
world units collapse onto one depth value, and says that dividing `layers.maxY` and `layers.maxZ` by that factor
resolves the sort again.

A log line is read by whoever is looking at one, so the same number is a question a game can ask.
[`depthSortCollapse`](#tecs.renderer.Renderer.depthSortCollapse) answers zero on a device whose depth target holds the sort and, on one
where it does not, answers the world units that collapse onto one depth value. That is the factor to divide both
extents by, after which it answers zero and the scene sorts again inside a world that much smaller:

```teal
local collapse <const> = renderer:depthSortCollapse()
if collapse > 0 then
    tecs.gfx.layers.maxY = tecs.gfx.layers.maxY / collapse
    tecs.gfx.layers.maxZ = tecs.gfx.layers.maxZ / collapse
end
```

A game that would rather keep its extents can put the layers that matter on the `z` sort instead, which resolves
in the floor format with room to spare. Either way it is a startup question: the answer is derived on the call
against the extents as they read then, not stored when the target was made.

## Shadows

Off by default. Pass `shadows` to `Renderer.create` to turn them on, and an empty table is the whole of what a
scene with no opinion about them passes:

```teal
local renderer <const> = tecs.renderer.Renderer.create(device, format, {shadows = {}})
```

On, an entity carrying [`Occluder`](/modules/components#occluder) blocks light, and one carrying
[`DropShadow`](/modules/components#dropshadow) darkens the ground away from it. Off, both components draw the
entity and cast nothing, so a scene can carry them before it can afford them.

The two are different things rather than one thing at two strengths. An occluder's silhouette goes into a mask
read inside the light loop, so it can only take away a light's own contribution. A drop shadow multiplies what
the whole loop produced, so it reaches the ambient term as well: under a black light and full ambient, the mask
has nothing to take away and the drop shadow still lands.

Neither costs a pass per light. One mask serves every light in the scene, and a caster throws its copies by the
nearest few lights by weight rather than by all of them, so the cost is a function of what casts rather than of
what lights it.

| Field         | Default | What it decides                                                                                       |
| ------------- | ------- | ----------------------------------------------------------------------------------------------------- |
| `maskScale`   | `1`     | Size of the occluder mask relative to the frame. Halving it quarters two targets and softens an edge. |
| `steps`       | `24`    | Samples a shadow march takes at full attenuation, and the ceiling the adaptive count clamps to.       |
| `margin`      | `200`   | How far outside the view, in world units, a caster is still kept so its shadow reaches the screen.    |
| `height`      | `64`    | World height a caster at `height` one stands, which is what puts casters and lights in one space.     |
| `dropScale`   | `0.5`   | Size of the drop-shadow target relative to the frame. It holds one soft channel.                      |
| `dropOpacity` | `0.4`   | How dark a drop shadow is where the light throwing it is at full strength.                            |
| `dropLength`  | `512`   | Longest a drop shadow may run, in world units.                                                        |

::: warning What turning them on costs
Three targets, four passes, four pipelines, two compute dispatches and one list, whether or not the scene casts
anything this frame. That is a setting rather than something taken off each frame on purpose: the alternative is
a pass graph whose shape depends on what a world happens to hold, and a lighting pipeline rebuilt the first time
something casts.

What it does not gate is the cull's share, which is one more count in a scan that is already running. A world
that never casts pays for that and for nothing else.
:::

## What feeds it

Everything the renderer draws is an entity in a world. The components it reads are on
[`tecs.components`](/modules/components) — `Transform`, `PreviousTransform`, `Tint`, `Sprite`, `Material`,
`PointLight`, `Clip`, `Occluder`, `DropShadow` and `Renderable` — and the modules that produce them have their
own pages:

- [`tecs.camera.Camera`](/modules/camera), the view it draws from
- [`tecs.gfx.layers`](/modules/gfx/layers), z-ordering and per-layer behaviour
- [`tecs.gfx.animation`](/modules/gfx/animation), sprite sheets and playback
- [`tecs.text`](/modules/text), distance-field text drawn through an instance producer
- [`tecs.gfx.particles`](/modules/gfx/particles), emitters
- [`tecs.gfx.materials`](/modules/gfx/materials), the material a draw dispatches to

## What it reports

| Field                | What it is                                                             |
| -------------------- | ---------------------------------------------------------------------- |
| `renderer.camera`    | The view. Centred on the viewport the first time a frame is drawn      |
| `renderer.capacity`  | Instances the buffers are sized for                                    |
| `renderer.count`     | Instances the last sync left resident                                  |
| `renderer.dropped`   | Instances the last sync could not fit                                  |
| `renderer.rewritten` | Instances the last sync actually rewrote. Zero on a still frame        |
| `renderer.images`    | The image array: every image, one binding, so the scene is one draw    |
| `renderer.instances` | The instance buffer the scene is drawn from, and the staging behind it |
| `renderer.deferred`  | The pass graph                                                         |

`dropped` is the one to watch. `capacity` is a ceiling rather than a hint, and rows past it are dropped rather
than growing a buffer mid-frame; a scene that is missing something and reports a non-zero `dropped` needs a
larger `capacity` in the [application config](/modules/application#the-world-and-the-renderer).

`rewritten` being zero is the dirty model working. A frame in which nothing moved rewrites nothing.

The camera centres itself on the viewport the first time there is something to draw, because the size to centre
on is only known once there is a frame to draw into. A scene that never mentions a camera therefore sees world
coordinates as screen coordinates.

## Images

An image is uploaded once and lives in the array for the life of the renderer.

```teal
local sprite, region = app.renderer:registerImage(handle)
world:spawn(tecs.ecs.builtins.Transform(100, 100), sprite)
```

`registerImage(handle)` takes a decoded [`assets.Handle`](/modules/assets), uploads it, and answers with a
`Sprite` component and the region it occupies. The image is registered under its path, which is what a `Sprite`
names it by and what a snapshot stores. Registering a path a second time answers with the layer it already holds
instead of consuming another, so a name means one image however many times it is asked for. The handle's pixels
are released here: the array holds them now.

A `Sprite` is returned rather than a bare region because an image smaller than a cell does not reach the cell's
edge, so the UV range is not 0..1 and a caller guessing it would sample the undefined remainder.

| Method                                  | What it does                                                      |
| --------------------------------------- | ----------------------------------------------------------------- |
| `renderer:registerImage(handle)`        | Uploads a decoded image; answers a `Sprite` and its region        |
| `renderer:replaceImage(handle)`         | Uploads over the image already registered under that path         |
| `renderer:regionOf(path)`               | The region a path occupies, or nil if nothing registered it       |
| `renderer:sprite(name, u0, v0, u1, v1)` | A `Sprite` for a registered image; UVs are fractions of the image |

`replaceImage` is what hot reload runs on. Identity is the point: the image keeps the layer and the rect it was
given at registration, so every `Sprite`, `Sheet` and glyph already spawned from it goes on naming the right
texels and the next frame simply draws the new pixels. Nothing in the world is touched and nothing has to be
invalidated. The size has to match — a larger or smaller image needs a different rect, and the old rect is
already copied into every instance that uses it, so a mismatch raises rather than silently drawing part of a
neighbour. It also raises on a path nothing is registered under, since adding one would be `registerImage`.

`regionOf` answers what `registerImage` would without a decoded handle to answer it with. A caller that has lost
its derived copy of a region, which a font atlas does when its metrics are re-read, would otherwise have to
decode the file again only to be handed back the layer it already had and have its pixels released undrawn.

## Extending a frame

| Method                                  | What it does                                                     |
| --------------------------------------- | ---------------------------------------------------------------- |
| `renderer:addProducer(producer)`        | Adds an instance producer, laid out after the archetypes         |
| `renderer:addComputeStage(stage)`       | Adds a stage recorded between the staging flush and the cull     |
| `renderer:setClipRegion(index, region)` | Points a clip region at a rectangle in target pixels             |
| `renderer:clearClipRegion(index)`       | Stops that region clipping anything                              |
| `renderer:device()`                     | The GPU device, for a stage that builds its own pipelines        |
| `renderer:captureTexture()`             | The composited image the last frame produced                     |
| `renderer:screenshot()`                 | Encodes that image as PNG bytes                                  |
| `renderer:saveScreenshot(path)`         | Encodes it and writes through `tecs.filesystem`                  |
| `renderer:rebuildPipelines()`           | Rebuilds every pipeline from the shader sources as they read now |

Producers are how something that is not an archetype run gets instances into the frame; [`text`](/modules/text)
is one. They are laid out after the archetypes, in the order they were added.

A compute stage is what a producer whose instances are written on the GPU needs beyond the run a producer already
gets: the run reserves the slots, and the stage is where something is put in them.

Clip regions cull fragments rather than geometry. Fragments of an instance carrying `Clip(index)` are kept where
they land inside the rectangle and thrown away where they do not. Region zero is not a region and cannot be set:
it is what an instance says when it wants no clipping at all.

Fragments rather than geometry is the whole of it: an instance entirely outside its region is still extracted,
still culled against the view, and still drawn, and the region only decides what survives rasterisation. A list
long enough for that to matter is cheaper spawned to the rows it shows than clipped to them.

`rebuildPipelines` is the device's half of a shader reload — whoever asked for one has already re-read the
sources, and this is what makes the next frame draw from them. A source that no longer compiles raises and
changes nothing. It must not be called from inside a pass: it waits for the device to go idle and releases
handles a recorded pass would still be reading.

`screenshot` performs a synchronous readback of the last composited image and returns `(png, nil)`, or
`(nil, error)` when readback or encoding fails. `saveScreenshot` returns `(true, nil)` or `(false, error)` and
writes through the installed storage backend. The debug server's screenshot tool calls this same public path;
there is no separate encoder hidden behind tooling.

## Interpolation

Simulation runs at a fixed step and the display does not, so an entity that moved once per step would visibly
step with it. The extractor interpolates instead: `PreviousTransform` holds where an entity was at the last fixed
step, and the extraction alpha is how far through the current step this frame sits. An entity carrying both is
drawn between the two.

The alpha is the fixed-step accumulator over the timestep, clamped to 1. An entity whose transform did not change
is still re-extracted while the alpha is moving, because its drawn position moves with alpha even when nothing
about the entity did.

Nothing has to be enabled: spawn `PreviousTransform` beside `Transform` and the entity interpolates.
<!-- @generated by docs/scripts/reference.py from src/tecs/Renderer.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/Renderer.tl`.

<a id="tecs.renderer.Renderer.ClipRegion"></a>

### tecs.renderer.Renderer.ClipRegion

<pre><code v-pre>type <a href="#tecs.renderer.Renderer.ClipRegion">tecs.renderer.Renderer.ClipRegion</a> = ClipRegion
</code></pre>

Re-exported for whoever names a rectangle for `setClipRegion`.
<a id="tecs.renderer.Renderer.ComputeStage"></a>

### tecs.renderer.Renderer.ComputeStage

<pre><code v-pre>type <a href="#tecs.renderer.Renderer.ComputeStage">tecs.renderer.Renderer.ComputeStage</a> = ComputeStage
</code></pre>

Re-exported for whoever implements one and passes it to
`addComputeStage`.
<a id="tecs.renderer.Renderer.InstanceProducer"></a>

### tecs.renderer.Renderer.InstanceProducer

<pre><code v-pre>type <a href="#tecs.renderer.Renderer.InstanceProducer">tecs.renderer.Renderer.InstanceProducer</a> = InstanceProducer
</code></pre>

Re-exported for whoever writes one and passes it to `addProducer`.
<a id="tecs.renderer.Renderer.addComputeStage"></a>

### tecs.renderer.Renderer.addComputeStage

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.addComputeStage">tecs.renderer.Renderer.addComputeStage</a>(self: Renderer, stage: <a href="#tecs.renderer.Renderer.ComputeStage">ComputeStage</a>)
</code></pre>

Adds a stage recorded between the staging flush and the cull.

What a producer whose instances are written on the GPU needs beyond the
run a producer already gets: the run reserves the slots, and this is where
something is put in them.

#### Parameters

| Type                                                                               | Name                     | Description                                                                      |
| ---------------------------------------------------------------------------------- | ------------------------ | -------------------------------------------------------------------------------- |
| <code v-pre>Renderer</code>                                                        | <code v-pre>self</code>  |                                                                                  |
| <code v-pre><a href="#tecs.renderer.Renderer.ComputeStage">ComputeStage</a></code> | <code v-pre>stage</code> | Held until `destroy`, which calls its own. There is no way to take one back out. |

<a id="tecs.renderer.Renderer.addProducer"></a>

### tecs.renderer.Renderer.addProducer

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.addProducer">tecs.renderer.Renderer.addProducer</a>(self: Renderer, producer: <a href="#tecs.renderer.Renderer.InstanceProducer">InstanceProducer</a>)
</code></pre>

Adds a producer, laid out after the archetypes in the order added.

#### Parameters

| Type                                                                                       | Name                        | Description                                                              |
| ------------------------------------------------------------------------------------------ | --------------------------- | ------------------------------------------------------------------------ |
| <code v-pre>Renderer</code>                                                                | <code v-pre>self</code>     |                                                                          |
| <code v-pre><a href="#tecs.renderer.Renderer.InstanceProducer">InstanceProducer</a></code> | <code v-pre>producer</code> | Held for the life of the renderer; there is no way to take one back out. |

<a id="tecs.renderer.Renderer.camera"></a>

### tecs.renderer.Renderer.camera

<pre><code v-pre><a href="#tecs.renderer.Renderer.camera">tecs.renderer.Renderer.camera</a>: Camera
</code></pre>

What the view is looking at. Centred on the viewport the first time a
frame is drawn, so a scene that never mentions a camera sees world
coordinates as screen coordinates.
<a id="tecs.renderer.Renderer.capacity"></a>

### tecs.renderer.Renderer.capacity

<pre><code v-pre><a href="#tecs.renderer.Renderer.capacity">tecs.renderer.Renderer.capacity</a>: integer
</code></pre>

Instances the buffers were sized for, fixed at creation. Nothing grows,
so this is what `dropped` counts against.
<a id="tecs.renderer.Renderer.captureTexture"></a>

### tecs.renderer.Renderer.captureTexture

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.captureTexture">tecs.renderer.Renderer.captureTexture</a>(self: Renderer): Texture
</code></pre>

The composited image the last frame produced.

#### Parameters

| Type                        | Name                    | Description |
| --------------------------- | ----------------------- | ----------- |
| <code v-pre>Renderer</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description                                                                                                                                                                                             |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Texture</code> | The scene target rather than the swapchain, so it can be read at any point between frames. The renderer goes on drawing into it, so the next frame overwrites what a caller has not already copied out. |

<a id="tecs.renderer.Renderer.clearClipRegion"></a>

### tecs.renderer.Renderer.clearClipRegion

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.clearClipRegion">tecs.renderer.Renderer.clearClipRegion</a>(self: Renderer, index: integer)
</code></pre>

Stops region `index` clipping anything.

Instances still naming it draw whole rather than disappearing, so an
adapter handing indices out and taking them back leaves nothing behind that
silently removes content.

#### Parameters

| Type                        | Name                     | Description                                                                    |
| --------------------------- | ------------------------ | ------------------------------------------------------------------------------ |
| <code v-pre>Renderer</code> | <code v-pre>self</code>  |                                                                                |
| <code v-pre>integer</code>  | <code v-pre>index</code> | The same range `setClipRegion` takes. Clearing one nobody set is not an error. |

<a id="tecs.renderer.Renderer.count"></a>

### tecs.renderer.Renderer.count

<pre><code v-pre><a href="#tecs.renderer.Renderer.count">tecs.renderer.Renderer.count</a>: integer
</code></pre>

Instances the last sync left resident.
<a id="tecs.renderer.Renderer.create"></a>

### tecs.renderer.Renderer.create

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.create">tecs.renderer.Renderer.create</a>(device: loader.CPtr, swapchainFormat: integer, options: RendererOptions): Renderer
</code></pre>

Builds a renderer for `device`.

#### Parameters

| Type                               | Name                               | Description                                                                                                    |
| ---------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| <code v-pre>loader.CPtr</code>     | <code v-pre>device</code>          |                                                                                                                |
| <code v-pre>integer</code>         | <code v-pre>swapchainFormat</code> | The `SDL_GPUTextureFormat` present copies into.                                                                |
| <code v-pre>RendererOptions</code> | <code v-pre>options</code>         | Every field has a default, and nil is accepted at runtime even though the signature does not mark it optional. |

#### Returns

| Type                        | Description |
| --------------------------- | ----------- |
| <code v-pre>Renderer</code> |             |

<a id="tecs.renderer.Renderer.deferred"></a>

### tecs.renderer.Renderer.deferred

<pre><code v-pre><a href="#tecs.renderer.Renderer.deferred">tecs.renderer.Renderer.deferred</a>: Deferred
</code></pre>

The pipeline the packet is drawn through, so a caller can add targets
and passes around the three it already has.
<a id="tecs.renderer.Renderer.depthSortCollapse"></a>

### tecs.renderer.Renderer.depthSortCollapse

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.depthSortCollapse">tecs.renderer.Renderer.depthSortCollapse</a>(self: Renderer): number
</code></pre>

World units that collapse onto one depth value on this device.

Zero on a device whose depth target holds everything the layer sort
produces, which is what a device offering `D32_FLOAT` or `D24_UNORM`
answers at any extents a scene is likely to use. Above zero, the target is
the floor SDL guarantees and its step is coarser than the sort's own: the
bands still hold, so a HUD still covers a world, and entities closer
together than this share a depth value and draw in the order they were
written rather than the order they were sorted into.

Reachable rather than only logged, because there is something to do about
it. Dividing `layers.maxY` and `layers.maxZ` by what this answers raises
the sort's own resolution by the same factor, after which this answers
zero and the scene sorts again inside a world that much smaller. A game
that would rather keep its extents can drop to the `z` sort on the layers
that matter, which resolves in the floor format with room to spare.

A startup question, asked once. It walks the format table and re-derives
what the sort resolves to, so it is not for a frame loop, and it reads the
extents as they are now rather than as they were when the target was
created, which is what makes asking again after narrowing them meaningful.

#### Parameters

| Type                        | Name                    | Description |
| --------------------------- | ----------------------- | ----------- |
| <code v-pre>Renderer</code> | <code v-pre>self</code> |             |

#### Returns

| Type                      | Description                                                                                                         |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>number</code> | Zero, or world units, which is also the factor `layers.maxY` and `layers.maxZ` divide by to resolve the sort again. |

<a id="tecs.renderer.Renderer.destroy"></a>

### tecs.renderer.Renderer.destroy

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.destroy">tecs.renderer.Renderer.destroy</a>(self: Renderer)
</code></pre>

Releases everything the renderer owns. Safe to call more than once.

#### Parameters

| Type                        | Name                    | Description |
| --------------------------- | ----------------------- | ----------- |
| <code v-pre>Renderer</code> | <code v-pre>self</code> |             |

<a id="tecs.renderer.Renderer.device"></a>

### tecs.renderer.Renderer.device

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.device">tecs.renderer.Renderer.device</a>(self: Renderer): loader.CPtr
</code></pre>

The GPU device this renderer draws through.

For a stage that has to build its own pipelines and buffers before there is
a frame to record onto.

#### Parameters

| Type                        | Name                    | Description |
| --------------------------- | ----------------------- | ----------- |
| <code v-pre>Renderer</code> | <code v-pre>self</code> |             |

#### Returns

| Type                           | Description                                                                                                                  |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>loader.CPtr</code> | The `SDL_GPUDevice` handed to `create`. Not owned here: `destroy` releases what was built on it and never the device itself. |

<a id="tecs.renderer.Renderer.dropped"></a>

### tecs.renderer.Renderer.dropped

<pre><code v-pre><a href="#tecs.renderer.Renderer.dropped">tecs.renderer.Renderer.dropped</a>: integer
</code></pre>

Instances the last sync could not fit.
<a id="tecs.renderer.Renderer.extractSeconds"></a>

### tecs.renderer.Renderer.extractSeconds

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.extractSeconds">tecs.renderer.Renderer.extractSeconds</a>(self: Renderer): number
</code></pre>

Seconds the last extraction took, or zero when nothing is being measured.

Read by the frame loop, which subtracts it from the update to leave
simulation on its own. Extraction runs inside `world:update`, so the two
are one number until something takes them apart.

#### Parameters

| Type                        | Name                    | Description |
| --------------------------- | ----------------------- | ----------- |
| <code v-pre>Renderer</code> | <code v-pre>self</code> |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>number</code> |             |

<a id="tecs.renderer.Renderer.images"></a>

### tecs.renderer.Renderer.images

<pre><code v-pre><a href="#tecs.renderer.Renderer.images">tecs.renderer.Renderer.images</a>: TextureArray
</code></pre>

Every image, one binding, so the scene is one draw.
<a id="tecs.renderer.Renderer.install"></a>

### tecs.renderer.Renderer.install

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.install">tecs.renderer.Renderer.install</a>(self: Renderer, world: ecs.World)
</code></pre>

Registers the sync system and queries on `world`.

Two systems, not one: the transform snapshot the interpolation reads runs
in FixedFirst, before anything in the step has moved, and the extraction
itself runs in RenderFirst. The counts above are published as the second
returns, so a system later in the frame reads this frame's numbers.

#### Parameters

| Type                         | Name                     | Description                                                                                                                                                 |
| ---------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Renderer</code>  | <code v-pre>self</code>  |                                                                                                                                                             |
| <code v-pre>ecs.World</code> | <code v-pre>world</code> | The queries and both systems are added here and nowhere else, so a renderer that was created and never installed draws an empty packet rather than failing. |

<a id="tecs.renderer.Renderer.instances"></a>

### tecs.renderer.Renderer.instances

<pre><code v-pre><a href="#tecs.renderer.Renderer.instances">tecs.renderer.Renderer.instances</a>: Buffer
</code></pre>

The instance buffer the scene is drawn from, and the staging behind it.
<a id="tecs.renderer.Renderer.rebuildPipelines"></a>

### tecs.renderer.Renderer.rebuildPipelines

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.rebuildPipelines">tecs.renderer.Renderer.rebuildPipelines</a>(self: Renderer)
</code></pre>

Rebuilds every pipeline from the shader sources as they read now.

The device's half of a shader reload: whoever asked for one has already
re-read the sources, and this is what makes the next frame draw from them.
A source that no longer compiles raises and changes nothing.

Not to be called from inside a pass. It waits for the device to go idle and
releases the handles a recorded pass would still be reading.

#### Parameters

| Type                        | Name                    | Description |
| --------------------------- | ----------------------- | ----------- |
| <code v-pre>Renderer</code> | <code v-pre>self</code> |             |

<a id="tecs.renderer.Renderer.regionOf"></a>

### tecs.renderer.Renderer.regionOf

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.regionOf">tecs.renderer.Renderer.regionOf</a>(self: Renderer, path: string): TextureArray.Region
</code></pre>

The region an image already occupies, or nil if none has registered it.

What `registerImage` answers, without a decoded handle to answer it with.
A caller that has lost its derived copy of a region, which a font atlas
does when its metrics are re-read, would otherwise have to decode the file
again only to be handed back the layer it already had and have its pixels
released undrawn.

#### Parameters

| Type                        | Name                    | Description                                                    |
| --------------------------- | ----------------------- | -------------------------------------------------------------- |
| <code v-pre>Renderer</code> | <code v-pre>self</code> |                                                                |
| <code v-pre>string</code>   | <code v-pre>path</code> | The path the image was registered under, spelled the same way. |

#### Returns

| Type                                   | Description                                                                                                                                                                            |
| -------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>TextureArray.Region</code> | The renderer's own record of where the image landed, not a copy. Nil says nothing is registered under that path, which is the one answer `registerImage` and `replaceImage` differ on. |

<a id="tecs.renderer.Renderer.registerImage"></a>

### tecs.renderer.Renderer.registerImage

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.registerImage">tecs.renderer.Renderer.registerImage</a>(self: Renderer, handle: assets.Handle): components.Sprite, TextureArray.Region
</code></pre>

Uploads a decoded image into the array and returns a Sprite for it.

The image is registered under its path, which is what a Sprite names it by
and what a snapshot stores. Registering a path a second time answers with
the layer it already holds instead of consuming another, so a name means
one image for the life of the renderer however many times it is asked for.
The path is what identifies it rather than the spelling of the path: two
ways of writing one path are one image, since the array's layers are few
and none of them is ever given back.

A Sprite is returned rather than a bare region because an image smaller
than a cell does not reach the cell's edge, so the UV range is not 0..1 and
a caller guessing it would sample the undefined remainder. The second
return is the region, which reports the size that was uploaded.

The handle's pixels are released here: the array holds them now.

#### Parameters

| Type                             | Name                      | Description                                                                                                            |
| -------------------------------- | ------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Renderer</code>      | <code v-pre>self</code>   |                                                                                                                        |
| <code v-pre>assets.Handle</code> | <code v-pre>handle</code> | Must have loaded: any other status raises, and the pixels are released whether the path was new or already registered. |

#### Returns

| Type                                   | Description                                                                                                              |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>components.Sprite</code>   | A Sprite selecting the whole image, ready to spawn.                                                                      |
| <code v-pre>TextureArray.Region</code> | Where it landed, which reports the size that was uploaded rather than the cell's. The renderer's own record, not a copy. |

<a id="tecs.renderer.Renderer.render"></a>

### tecs.renderer.Renderer.render

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.render">tecs.renderer.Renderer.render</a>(self: Renderer, frame: Frame)
</code></pre>

Draws the packet the last extraction produced.

#### Parameters

| Type                        | Name                     | Description                                                                                                                                                                                                                                               |
| --------------------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Renderer</code> | <code v-pre>self</code>  |                                                                                                                                                                                                                                                           |
| <code v-pre>Frame</code>    | <code v-pre>frame</code> | Recorded onto and not submitted, so a caller with passes of its own records them after this and submits once. Its width and height are what the camera's matrix and the view bounds are resolved against, which is why they are not stored on the camera. |

<a id="tecs.renderer.Renderer.replaceImage"></a>

### tecs.renderer.Renderer.replaceImage

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.replaceImage">tecs.renderer.Renderer.replaceImage</a>(self: Renderer, handle: assets.Handle): components.Sprite, TextureArray.Region
</code></pre>

Uploads a decoded image over the one already registered under its path.

Identity is the point. The image keeps the layer and the rect it was given
at registration, so every `Sprite`, `Sheet` and glyph already spawned from
it goes on naming the right texels and the next frame simply draws the new
pixels. Nothing in the world is touched and nothing has to be invalidated.

The size has to match. A larger or smaller image needs a different rect, and
the UVs of the old one are already copied into every instance that uses it,
so this refuses rather than silently drawing part of a neighbour.

Fails on a path nothing is registered under, since there is no rect to write
into and adding one would be `registerImage`.

The handle's pixels are released here: the array holds them now.

#### Parameters

| Type                             | Name                      | Description                                                                                                                                                                                   |
| -------------------------------- | ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Renderer</code>      | <code v-pre>self</code>   |                                                                                                                                                                                               |
| <code v-pre>assets.Handle</code> | <code v-pre>handle</code> | Must have loaded, must name a path already registered, and must be the same size it was registered at. Each of the three raises, and the pixels are only released once all three have passed. |

#### Returns

| Type                                   | Description                                                                                |
| -------------------------------------- | ------------------------------------------------------------------------------------------ |
| <code v-pre>components.Sprite</code>   | The same Sprite `registerImage` answered with, since neither the layer nor the rect moved. |
| <code v-pre>TextureArray.Region</code> | The region, unchanged, and still the renderer's own record.                                |

<a id="tecs.renderer.Renderer.reservesRuns"></a>

### tecs.renderer.Renderer.reservesRuns

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.reservesRuns">tecs.renderer.Renderer.reservesRuns</a>(self: Renderer): boolean
</code></pre>

Whether archetype runs are laid out with room to grow.

#### Parameters

| Type                        | Name                    | Description |
| --------------------------- | ----------------------- | ----------- |
| <code v-pre>Renderer</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.renderer.Renderer.rewritten"></a>

### tecs.renderer.Renderer.rewritten

<pre><code v-pre><a href="#tecs.renderer.Renderer.rewritten">tecs.renderer.Renderer.rewritten</a>: integer
</code></pre>

Instances the last sync actually rewrote. Zero on a still frame.
<a id="tecs.renderer.Renderer.saveScreenshot"></a>

### tecs.renderer.Renderer.saveScreenshot

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.saveScreenshot">tecs.renderer.Renderer.saveScreenshot</a>(self: Renderer, path: string): boolean, string
</code></pre>

Writes the composited image from the last frame as a PNG.

The path is passed through the installed storage backend unchanged.

#### Parameters

| Type                        | Name                    | Description |
| --------------------------- | ----------------------- | ----------- |
| <code v-pre>Renderer</code> | <code v-pre>self</code> |             |
| <code v-pre>string</code>   | <code v-pre>path</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |
| <code v-pre>string</code>  |             |

<a id="tecs.renderer.Renderer.screenshot"></a>

### tecs.renderer.Renderer.screenshot

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.screenshot">tecs.renderer.Renderer.screenshot</a>(self: Renderer): string, string
</code></pre>

Encodes the composited image from the last frame as PNG bytes.

Synchronous: texture readback waits for the GPU work producing that frame.

#### Parameters

| Type                        | Name                    | Description |
| --------------------------- | ----------------------- | ----------- |
| <code v-pre>Renderer</code> | <code v-pre>self</code> |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>string</code> |             |
| <code v-pre>string</code> |             |

<a id="tecs.renderer.Renderer.setClipRegion"></a>

### tecs.renderer.Renderer.setClipRegion

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.setClipRegion">tecs.renderer.Renderer.setClipRegion</a>(self: Renderer, index: integer, region: <a href="#tecs.renderer.Renderer.ClipRegion">ClipRegion</a>)
</code></pre>

Points region `index` at a rectangle in target pixels.

Fragments of an instance carrying `Clip(index)` are kept where they land
inside the rectangle and thrown away where they do not. Region zero is not
a region and cannot be set: it is what an instance says when it wants no
clipping at all.

#### Parameters

| Type                                                                           | Name                      | Description                                                                         |
| ------------------------------------------------------------------------------ | ------------------------- | ----------------------------------------------------------------------------------- |
| <code v-pre>Renderer</code>                                                    | <code v-pre>self</code>   |                                                                                     |
| <code v-pre>integer</code>                                                     | <code v-pre>index</code>  | 1 through 255. Zero, a fraction, or anything outside that raises.                   |
| <code v-pre><a href="#tecs.renderer.Renderer.ClipRegion">ClipRegion</a></code> | <code v-pre>region</code> | Nil raises rather than clearing; `clearClipRegion` is what stops a region clipping. |

<a id="tecs.renderer.Renderer.sprite"></a>

### tecs.renderer.Renderer.sprite

<pre><code v-pre>function <a href="#tecs.renderer.Renderer.sprite">tecs.renderer.Renderer.sprite</a>(self: Renderer, name: string, u0: number, v0: number, u1: number, v1: number): components.Sprite
</code></pre>

A resolved Sprite for a registered image, ready to spawn.

UVs are fractions of the image rather than of the cell it sits in. Omitted,
they select the whole image. Fails on a name nothing is registered under.

#### Parameters

| Type                        | Name                    | Description                                                                                         |
| --------------------------- | ----------------------- | --------------------------------------------------------------------------------------------------- |
| <code v-pre>Renderer</code> | <code v-pre>self</code> |                                                                                                     |
| <code v-pre>string</code>   | <code v-pre>name</code> | The path the image was registered under.                                                            |
| <code v-pre>number</code>   | <code v-pre>u0</code>   | Zero at the image's left edge and one at its right, not the cell's. Defaults to zero, as `v0` does. |
| <code v-pre>number</code>   | <code v-pre>v0</code>   |                                                                                                     |
| <code v-pre>number</code>   | <code v-pre>u1</code>   | Defaults to one, as `v1` does, so omitting all four is the whole image.                             |
| <code v-pre>number</code>   | <code v-pre>v1</code>   |                                                                                                     |

#### Returns

| Type                                 | Description                                                                                         |
| ------------------------------------ | --------------------------------------------------------------------------------------------------- |
| <code v-pre>components.Sprite</code> | A fresh Sprite, with the fractions already mapped into the rect the image occupies within its cell. |
