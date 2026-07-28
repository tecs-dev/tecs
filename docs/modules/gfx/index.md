---
description: "Drawing: the camera a frame is drawn from, the renderer that draws it, and the vocabularies a scene is described in"
outline: deep
---

# tecs.gfx

`tecs.gfx` is where drawing lives. Two things sit on it directly, because every scene reaches for both:
the [camera](#the-camera) a frame is drawn from, and the [renderer](#the-renderer) that draws it. The
vocabularies a scene is described in are each a module one level below, with a page of its own.

## What is under it

| Module                                         | What it is                                      |
| ---------------------------------------------- | ----------------------------------------------- |
| [`tecs.gfx.animation`](/modules/gfx/animation) | sprite sheets, and the playback that reads them |
| [`tecs.gfx.layers`](/modules/gfx/layers)       | z-ordering and per-layer behaviour              |
| [`tecs.gfx.materials`](/modules/gfx/materials) | the material a draw dispatches to               |
| [`tecs.gfx.particles`](/modules/gfx/particles) | emitters                                        |

`materials` stays a module of its own rather than a section of this page for a reason worth stating: the
record it hands back describes a material _file_, while `Material` is the component that selects one by
id. Two things named alike is how a reader ends up assigning the wrong one, and one extra segment is what
keeps them apart.

## One level, and no deeper

A public name goes at most one module below the root. `tecs.gfx.layers.configure` is a function on a
module inside a namespace; there is no third namespace under it, and a type a module owns sits on that
module's page rather than getting a level of its own. So a name a game writes is read left to right with
no guessing about where the module stops and the value starts.

## Reading one costs only that one

Each name under `tecs.gfx` resolves the first time it is read, and reading one does not resolve its
siblings. `tecs.gfx` on its own resolves nothing at all: it answers with a table whose members are filled
in one at a time.

That is what keeps `require("tecs")` usable with no graphics stack present. A resource pipeline, a
simulation server or a spec that names `tecs.gfx.layers` loads `src/tecs/gfx/layers.tl` and stops there,
and one that names nothing under `tecs.gfx` loads nothing under it. `spec/headless_spec.lua` is where that
is held to.

The module a name resolves to is the module itself and not a copy of it, so
`tecs.gfx.layers` and `require("tecs.gfx.layers")` are one table. A value written through one is read back
through the other, which matters for `layers.maxY` and `layers.maxZ`, the two module values a game is
expected to assign.

## The camera

A camera is what the view is looking at: a centre in world units, a zoom, a rotation, and a projection
mode. It is one type rather than a 2D camera and a 3D one, because the only thing that would differ
between them is how the matrix is built, and nothing reading the matrix, neither the vertex shader nor
the cull, cares which built it.

Position is the centre of the view rather than a corner, so a camera that has never been moved shows the
world origin in the middle of the window. The renderer centres a default camera on the first frame it
draws, so a scene that never mentions a camera behaves as though world coordinates were screen
coordinates. See [Renderer](/modules/gfx/) for how a camera reaches a frame.

### Creating a camera

#### newCamera

Creates a camera. Everything defaults to an unrotated, unzoomed view at the world origin.

```teal
function Camera.newCamera(options?: CameraOptions): Camera
```

**Parameters:**

- `options`: omit for the default view. No field is validated; the values are taken as given.

**Returns:** a camera whose fields are plain and meant to be assigned to directly, frame by frame.

**`CameraOptions` fields:**

| Field        | Type     | Default          | Description                                                                               |
| ------------ | -------- | ---------------- | ----------------------------------------------------------------------------------------- |
| `x`          | `number` | `0`              | Centre of the view in world units.                                                        |
| `y`          | `number` | `0`              | Centre of the view in world units.                                                        |
| `zoom`       | `number` | `1`              | Above one magnifies. Zero or less is not rejected.                                        |
| `rotation`   | `number` | `0`              | Radians.                                                                                  |
| `projection` | `string` | `"orthographic"` | Any string is accepted and stored; the projection built is orthographic whatever it says. |

**Example:**

```teal
local camera <const> = tecs.gfx.newCamera({ x = 400, y = 300, zoom = 2 })
```

### Camera fields

Every field is plain and assignable. A game moves a camera by writing to it, once per frame if it likes.

| Field        | Type     | Description                                                                                                                                                                                                             |
| ------------ | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `x`          | `number` | Centre of the view, in world units.                                                                                                                                                                                     |
| `y`          | `number` | Centre of the view, in world units.                                                                                                                                                                                     |
| `zoom`       | `number` | Above one magnifies. Applied about the centre, so zooming does not move what is under the middle of the window.                                                                                                         |
| `rotation`   | `number` | Radians. Positive turns the scene counter-clockwise on screen, which is the camera itself turning the other way: at a quarter turn, a point at +X from the camera in the world is drawn above the centre of the window. |
| `projection` | `string` | `"orthographic"` today. Nothing reads it yet, so setting anything else changes what the camera reports about itself and not what it draws.                                                                              |

The `projection` field exists so a perspective mode can be added without a second camera type, which is
the whole reason there is a mode rather than a name.

```teal
camera.x = player.x
camera.y = player.y
camera.zoom = camera.zoom * 1.01
```

### The viewport size is passed, never stored

Every method takes the viewport's width and height rather than the camera holding them, because a camera
outlives a window size and the pair a call is answered against has to be the pair the frame is being
drawn at.

::: warning
Passing one size to `matrix` and another to `toWorld` produces two mappings that do not invert. Use the
same width and height for every call about the same frame.
:::

### The Y flip

World Y runs down from the top left while clip Y runs up. The flip lives in this module and only here,
and the three things that have to agree about it are the matrix, `toScreen` and `toWorld`. They agree by
all deriving from the same negated Y scale, written out in each rather than shared, so a change to one
of them is visibly a change the other two have not had.

### Camera methods

#### matrix

Writes the world-to-clip matrix for a viewport of `width` by `height`.

```teal
function Camera:matrix(width: number, height: number): loader.CArray
```

**Parameters:**

- `width`: viewport width in pixels.
- `height`: viewport height in pixels.

**Returns:** the camera's own sixteen-float array, rewritten in place.

The matrix is column major, because that is how a GLSL `mat4` reads a uniform: the first four floats are
the first column, not the first row. Transposing these is a mistake that renders something plausible
rather than nothing, which is how it survives review.

Z passes through untouched and W stays one: depth is written by the vertex shader from the layer band
rather than projected from world space. See [layers](/modules/gfx/layers).

::: warning
The array is valid until the next call on this camera. A caller that needs to keep it copies it rather
than holding the pointer.
:::

#### viewBounds

The world-space rectangle this camera can see.

```teal
function Camera:viewBounds(width: number, height: number): {number}
```

**Parameters:**

- `width`: viewport width in pixels.
- `height`: viewport height in pixels.

**Returns:** the camera's own four-element table, rewritten in place, as `minX`, `minY`, `maxX`, `maxY`.

Conservative when rotated: the corners of the rotated view are bounded by an axis-aligned box, so the
cull keeps a little more than it must. Keeping too much costs a few instances; keeping too little drops
geometry that should have drawn, which is why the error goes this way.

::: warning
The table is valid until the next call on this camera. A caller that needs to keep it copies it rather
than holding the table.
:::

**Example:**

```teal
local bounds <const> = camera:viewBounds(width, height)
local minX <const>, minY <const>, maxX <const>, maxY <const> =
    bounds[1], bounds[2], bounds[3], bounds[4]
```

#### toWorld

Converts a screen point to world space.

```teal
function Camera:toWorld(screenX: number, screenY: number, width: number, height: number): number, number
```

**Parameters:**

- `screenX`: pixels from the left of the viewport.
- `screenY`: pixels from the top of the viewport, running down.
- `width`: viewport width in pixels, the same one the matrix was built with.
- `height`: viewport height in pixels, the same one the matrix was built with.

**Returns:** the world x, then the world y. Points outside the viewport convert too, and land outside the
view rectangle.

This is the inverse of what the matrix does, written out rather than inverted, so the Y flip appears once
here in the same place it appears in the matrix.

**Example:**

```teal
local worldX <const>, worldY <const> = camera:toWorld(mouseX, mouseY, width, height)
```

#### toScreen

Converts a world point to screen space.

```teal
function Camera:toScreen(worldX: number, worldY: number, width: number, height: number): number, number
```

**Parameters:**

- `worldX`: world x.
- `worldY`: world y, running down.
- `width`: viewport width in pixels, the same one the matrix was built with.
- `height`: viewport height in pixels, the same one the matrix was built with.

**Returns:** the screen x in pixels from the left, then the screen y in pixels from the top. Neither is
clamped to the viewport.

Exactly the inverse of `toWorld` at the same width and height, and the same mapping the matrix applies,
so a point round-trips.

### What lighting does with the view

Lights are placed in world units like everything else, and the lighting pass is handed the view so
it can take each fragment back out to the world rather than bringing the lights in. Moving the camera
therefore moves what is lit, and zoom scales what a light's radius covers on screen rather than what
it covers in the world. A light needs no conversion and no projection of its own; see
[`PointLight`](/modules/components#pointlight).

### What the camera does not place

A layer can ask to be positioned in screen pixels, in a virtual resolution, at its own parallax, or
outside the camera's zoom. Contents of such a layer are not placed where the camera would put them, and
the cull gives up on them rather than testing a world bound that does not describe where they draw.
[layers](/modules/gfx/layers) has the rules.

## The renderer

`tecs.gfx.Renderer` is the path from a world to the GPU. A game does not construct one: the
[application](/modules/application) does, and hands it over as `app.renderer`.

```teal
return tecs.application.create({
    plugin = function(world: tecs.World, app: tecs.application.Application)
        app.renderer.camera.zoom = 2.0
    end,
})
```

### Two halves and a seam

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

### Deferred, and GPU-driven

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

#### Adding a pass

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
[`depthSortCollapse`](#tecs.gfx.Renderer.depthSortCollapse) answers zero on a device whose depth target holds the sort and, on one
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

### Shadows

Off by default. Pass `shadows` to `Renderer.newRenderer` to turn them on, and an empty table is the whole of what a
scene with no opinion about them passes:

```teal
local renderer <const> = tecs.gfx.newRenderer(device, format, {shadows = {}})
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

### What feeds it

Everything the renderer draws is an entity in a world. The components it reads are on
[`tecs.components`](/modules/components) — `Transform`, `PreviousTransform`, `Tint`, `Sprite`, `Material`,
`PointLight`, `Clip`, `Occluder`, `DropShadow` and `Renderable` — and the modules that produce them have their
own pages:

- [`tecs.gfx.Camera`](/modules/gfx/), the view it draws from
- [`tecs.gfx.layers`](/modules/gfx/layers), z-ordering and per-layer behaviour
- [`tecs.gfx.animation`](/modules/gfx/animation), sprite sheets and playback
- [`tecs.text`](/modules/text), distance-field text drawn through an instance producer
- [`tecs.gfx.particles`](/modules/gfx/particles), emitters
- [`tecs.gfx.materials`](/modules/gfx/materials), the material a draw dispatches to

### What the renderer reports

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

### Images

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

### Extending a frame

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

### Interpolation

Simulation runs at a fixed step and the display does not, so an entity that moved once per step would visibly
step with it. The extractor interpolates instead: `PreviousTransform` holds where an entity was at the last fixed
step, and the extraction alpha is how far through the current step this frame sits. An entity carrying both is
drawn between the two.

The alpha is the fixed-step accumulator over the timestep, clamped to 1. An entity whose transform did not change
is still re-extracted while the alpha is moving, because its drawn position moves with alpha even when nothing
about the entity did.

Nothing has to be enabled: spawn `PreviousTransform` beside `Transform` and the entity interpolates.
<!-- @generated by docs/scripts/reference.py from src/tecs/gfx/Camera.tl, src/tecs/Renderer.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/gfx/Camera.tl` and `src/tecs/Renderer.tl`.

<a id="tecs.gfx.Camera.Options"></a>

### tecs.gfx.Camera.Options

<pre><code v-pre>type <a href="#tecs.gfx.Camera.Options">tecs.gfx.Camera.Options</a> = CameraOptions
</code></pre>

What `newCamera` takes, named here so a game can annotate the table it
passes without reaching into this file.
<a id="tecs.gfx.Camera.matrix"></a>

### tecs.gfx.Camera.matrix

<pre><code v-pre>function <a href="#tecs.gfx.Camera.matrix">tecs.gfx.Camera.matrix</a>(self: Camera, width: number, height: number): loader.CArray
</code></pre>

Writes the world-to-clip matrix for a viewport of `width` by `height`.

Column major, because that is how a GLSL `mat4` reads a uniform: the
first four floats are the first column, not the first row. Transposing
these is a mistake that renders something plausible rather than nothing,
which is how it survives review.

#### Parameters

| Type                      | Name                      | Description                |
| ------------------------- | ------------------------- | -------------------------- |
| <code v-pre>Camera</code> | <code v-pre>self</code>   |                            |
| <code v-pre>number</code> | <code v-pre>width</code>  | Viewport width in pixels.  |
| <code v-pre>number</code> | <code v-pre>height</code> | Viewport height in pixels. |

#### Returns

| Type                             | Description                                                                                                                                                                            |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>loader.CArray</code> | The camera's own sixteen-float array, rewritten in place. It is valid until the next call on this camera, so a caller that needs to keep it copies it rather than holding the pointer. |

<a id="tecs.gfx.Camera.newCamera"></a>

### tecs.gfx.Camera.newCamera

<pre><code v-pre>function <a href="#tecs.gfx.Camera.newCamera">tecs.gfx.Camera.newCamera</a>(options: CameraOptions): Camera
</code></pre>

Creates a camera. Everything defaults to an unrotated, unzoomed view at
the world origin, which a renderer then recentres if the game never
moves it.

#### Parameters

| Type                             | Name                       | Description                                                                      |
| -------------------------------- | -------------------------- | -------------------------------------------------------------------------------- |
| <code v-pre>CameraOptions</code> | <code v-pre>options</code> | Omit for the default view. No field is validated; the values are taken as given. |

#### Returns

| Type                      | Description                                                                           |
| ------------------------- | ------------------------------------------------------------------------------------- |
| <code v-pre>Camera</code> | A camera whose fields are plain and meant to be assigned to directly, frame by frame. |

<a id="tecs.gfx.Camera.projection"></a>

### tecs.gfx.Camera.projection

<pre><code v-pre><a href="#tecs.gfx.Camera.projection">tecs.gfx.Camera.projection</a>: string
</code></pre>

"orthographic" today. The field exists so a perspective mode can be
added without a second camera type, which is the whole reason there is
a mode rather than a name. Nothing reads it yet, so setting anything
else changes what the camera reports about itself and not what it draws.
<a id="tecs.gfx.Camera.rotation"></a>

### tecs.gfx.Camera.rotation

<pre><code v-pre><a href="#tecs.gfx.Camera.rotation">tecs.gfx.Camera.rotation</a>: number
</code></pre>

Radians. Positive turns the scene counter-clockwise on screen, which is
the camera itself turning the other way: at a quarter turn, a point at
+X from the camera in the world is drawn above the centre of the window.
<a id="tecs.gfx.Camera.toScreen"></a>

### tecs.gfx.Camera.toScreen

<pre><code v-pre>function <a href="#tecs.gfx.Camera.toScreen">tecs.gfx.Camera.toScreen</a>(self: Camera, worldX: number, worldY: number, width: number, height: number): number, number
</code></pre>

Converts a world point to screen space.

Exactly the inverse of `toWorld` at the same width and height, and the
same mapping the matrix applies, so a point round-trips.

#### Parameters

| Type                      | Name                      | Description                                                        |
| ------------------------- | ------------------------- | ------------------------------------------------------------------ |
| <code v-pre>Camera</code> | <code v-pre>self</code>   |                                                                    |
| <code v-pre>number</code> | <code v-pre>worldX</code> | World x.                                                           |
| <code v-pre>number</code> | <code v-pre>worldY</code> | World y, running down.                                             |
| <code v-pre>number</code> | <code v-pre>width</code>  | Viewport width in pixels, the same one the matrix was built with.  |
| <code v-pre>number</code> | <code v-pre>height</code> | Viewport height in pixels, the same one the matrix was built with. |

#### Returns

| Type                      | Description                                                                                                         |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>number</code> | The screen x in pixels from the left, then the screen y in pixels from the top. Neither is clamped to the viewport. |
| <code v-pre>number</code> |                                                                                                                     |

<a id="tecs.gfx.Camera.toWorld"></a>

### tecs.gfx.Camera.toWorld

<pre><code v-pre>function <a href="#tecs.gfx.Camera.toWorld">tecs.gfx.Camera.toWorld</a>(self: Camera, screenX: number, screenY: number, width: number, height: number): number, number
</code></pre>

Converts a screen point to world space.

The inverse of what the matrix does, written out rather than inverted,
so the Y flip appears once here in the same place it appears above.

#### Parameters

| Type                      | Name                       | Description                                                        |
| ------------------------- | -------------------------- | ------------------------------------------------------------------ |
| <code v-pre>Camera</code> | <code v-pre>self</code>    |                                                                    |
| <code v-pre>number</code> | <code v-pre>screenX</code> | Pixels from the left of the viewport.                              |
| <code v-pre>number</code> | <code v-pre>screenY</code> | Pixels from the top of the viewport, running down.                 |
| <code v-pre>number</code> | <code v-pre>width</code>   | Viewport width in pixels, the same one the matrix was built with.  |
| <code v-pre>number</code> | <code v-pre>height</code>  | Viewport height in pixels, the same one the matrix was built with. |

#### Returns

| Type                      | Description                                                                                                  |
| ------------------------- | ------------------------------------------------------------------------------------------------------------ |
| <code v-pre>number</code> | The world x, then the world y. Points outside the viewport convert too, and land outside the view rectangle. |
| <code v-pre>number</code> |                                                                                                              |

<a id="tecs.gfx.Camera.viewBounds"></a>

### tecs.gfx.Camera.viewBounds

<pre><code v-pre>function <a href="#tecs.gfx.Camera.viewBounds">tecs.gfx.Camera.viewBounds</a>(self: Camera, width: number, height: number): {number}
</code></pre>

The world-space rectangle this camera can see, as minX, minY, maxX,
maxY.

Conservative when rotated: the corners of the rotated view are bounded
by an axis-aligned box, so the cull keeps a little more than it must.
Keeping too much costs a few instances; keeping too little drops
geometry that should have drawn, which is why the error goes this way.

#### Parameters

| Type                      | Name                      | Description                |
| ------------------------- | ------------------------- | -------------------------- |
| <code v-pre>Camera</code> | <code v-pre>self</code>   |                            |
| <code v-pre>number</code> | <code v-pre>width</code>  | Viewport width in pixels.  |
| <code v-pre>number</code> | <code v-pre>height</code> | Viewport height in pixels. |

#### Returns

| Type                        | Description                                                                                                                                                                         |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{number}</code> | The camera's own four-element table, rewritten in place. It is valid until the next call on this camera, so a caller that needs to keep it copies it rather than holding the table. |

<a id="tecs.gfx.Camera.x"></a>

### tecs.gfx.Camera.x

<pre><code v-pre><a href="#tecs.gfx.Camera.x">tecs.gfx.Camera.x</a>: number
</code></pre>

Centre of the view, in world units.
<a id="tecs.gfx.Camera.y"></a>

### tecs.gfx.Camera.y

<pre><code v-pre><a href="#tecs.gfx.Camera.y">tecs.gfx.Camera.y</a>: number
</code></pre>

The other half of it, running down: increasing y moves the view towards
the bottom of the world.
<a id="tecs.gfx.Camera.zoom"></a>

### tecs.gfx.Camera.zoom

<pre><code v-pre><a href="#tecs.gfx.Camera.zoom">tecs.gfx.Camera.zoom</a>: number
</code></pre>

Above one magnifies. Applied about the centre, so zooming does not move
what is under the middle of the window.

<a id="tecs.gfx.Renderer.ClipRegion"></a>

### tecs.gfx.Renderer.ClipRegion

<pre><code v-pre>type <a href="#tecs.gfx.Renderer.ClipRegion">tecs.gfx.Renderer.ClipRegion</a> = ClipRegion
</code></pre>

Re-exported for whoever names a rectangle for `setClipRegion`.
<a id="tecs.gfx.Renderer.ComputeStage"></a>

### tecs.gfx.Renderer.ComputeStage

<pre><code v-pre>type <a href="#tecs.gfx.Renderer.ComputeStage">tecs.gfx.Renderer.ComputeStage</a> = ComputeStage
</code></pre>

Re-exported for whoever implements one and passes it to
`addComputeStage`.
<a id="tecs.gfx.Renderer.InstanceProducer"></a>

### tecs.gfx.Renderer.InstanceProducer

<pre><code v-pre>type <a href="#tecs.gfx.Renderer.InstanceProducer">tecs.gfx.Renderer.InstanceProducer</a> = InstanceProducer
</code></pre>

Re-exported for whoever writes one and passes it to `addProducer`.
<a id="tecs.gfx.Renderer.Options"></a>

### tecs.gfx.Renderer.Options

<pre><code v-pre>type <a href="#tecs.gfx.Renderer.Options">tecs.gfx.Renderer.Options</a> = RendererOptions
</code></pre>

What `newRenderer` takes, named here so a game can annotate the table it
passes without reaching into this file.
<a id="tecs.gfx.Renderer.addComputeStage"></a>

### tecs.gfx.Renderer.addComputeStage

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.addComputeStage">tecs.gfx.Renderer.addComputeStage</a>(self: Renderer, stage: <a href="#tecs.gfx.Renderer.ComputeStage">ComputeStage</a>)
</code></pre>

Adds a stage recorded between the staging flush and the cull.

What a producer whose instances are written on the GPU needs beyond the
run a producer already gets: the run reserves the slots, and this is where
something is put in them.

#### Parameters

| Type                                                                          | Name                     | Description                                                                      |
| ----------------------------------------------------------------------------- | ------------------------ | -------------------------------------------------------------------------------- |
| <code v-pre>Renderer</code>                                                   | <code v-pre>self</code>  |                                                                                  |
| <code v-pre><a href="#tecs.gfx.Renderer.ComputeStage">ComputeStage</a></code> | <code v-pre>stage</code> | Held until `destroy`, which calls its own. There is no way to take one back out. |

<a id="tecs.gfx.Renderer.addProducer"></a>

### tecs.gfx.Renderer.addProducer

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.addProducer">tecs.gfx.Renderer.addProducer</a>(self: Renderer, producer: <a href="#tecs.gfx.Renderer.InstanceProducer">InstanceProducer</a>)
</code></pre>

Adds a producer, laid out after the archetypes in the order added.

#### Parameters

| Type                                                                                  | Name                        | Description                                                              |
| ------------------------------------------------------------------------------------- | --------------------------- | ------------------------------------------------------------------------ |
| <code v-pre>Renderer</code>                                                           | <code v-pre>self</code>     |                                                                          |
| <code v-pre><a href="#tecs.gfx.Renderer.InstanceProducer">InstanceProducer</a></code> | <code v-pre>producer</code> | Held for the life of the renderer; there is no way to take one back out. |

<a id="tecs.gfx.Renderer.camera"></a>

### tecs.gfx.Renderer.camera

<pre><code v-pre><a href="#tecs.gfx.Renderer.camera">tecs.gfx.Renderer.camera</a>: Camera
</code></pre>

What the view is looking at. Centred on the viewport the first time a
frame is drawn, so a scene that never mentions a camera sees world
coordinates as screen coordinates.
<a id="tecs.gfx.Renderer.capacity"></a>

### tecs.gfx.Renderer.capacity

<pre><code v-pre><a href="#tecs.gfx.Renderer.capacity">tecs.gfx.Renderer.capacity</a>: integer
</code></pre>

Instances the buffers were sized for, fixed at creation. Nothing grows,
so this is what `dropped` counts against.
<a id="tecs.gfx.Renderer.captureTexture"></a>

### tecs.gfx.Renderer.captureTexture

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.captureTexture">tecs.gfx.Renderer.captureTexture</a>(self: Renderer): Texture
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

<a id="tecs.gfx.Renderer.clearClipRegion"></a>

### tecs.gfx.Renderer.clearClipRegion

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.clearClipRegion">tecs.gfx.Renderer.clearClipRegion</a>(self: Renderer, index: integer)
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

<a id="tecs.gfx.Renderer.count"></a>

### tecs.gfx.Renderer.count

<pre><code v-pre><a href="#tecs.gfx.Renderer.count">tecs.gfx.Renderer.count</a>: integer
</code></pre>

Instances the last sync left resident.
<a id="tecs.gfx.Renderer.deferred"></a>

### tecs.gfx.Renderer.deferred

<pre><code v-pre><a href="#tecs.gfx.Renderer.deferred">tecs.gfx.Renderer.deferred</a>: Deferred
</code></pre>

The pipeline the packet is drawn through, so a caller can add targets
and passes around the three it already has.
<a id="tecs.gfx.Renderer.depthSortCollapse"></a>

### tecs.gfx.Renderer.depthSortCollapse

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.depthSortCollapse">tecs.gfx.Renderer.depthSortCollapse</a>(self: Renderer): number
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

<a id="tecs.gfx.Renderer.destroy"></a>

### tecs.gfx.Renderer.destroy

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.destroy">tecs.gfx.Renderer.destroy</a>(self: Renderer)
</code></pre>

Releases everything the renderer owns. Safe to call more than once.

#### Parameters

| Type                        | Name                    | Description |
| --------------------------- | ----------------------- | ----------- |
| <code v-pre>Renderer</code> | <code v-pre>self</code> |             |

<a id="tecs.gfx.Renderer.device"></a>

### tecs.gfx.Renderer.device

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.device">tecs.gfx.Renderer.device</a>(self: Renderer): loader.CPtr
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

<a id="tecs.gfx.Renderer.dropped"></a>

### tecs.gfx.Renderer.dropped

<pre><code v-pre><a href="#tecs.gfx.Renderer.dropped">tecs.gfx.Renderer.dropped</a>: integer
</code></pre>

Instances the last sync could not fit.
<a id="tecs.gfx.Renderer.extractSeconds"></a>

### tecs.gfx.Renderer.extractSeconds

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.extractSeconds">tecs.gfx.Renderer.extractSeconds</a>(self: Renderer): number
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

<a id="tecs.gfx.Renderer.images"></a>

### tecs.gfx.Renderer.images

<pre><code v-pre><a href="#tecs.gfx.Renderer.images">tecs.gfx.Renderer.images</a>: TextureArray
</code></pre>

Every image, one binding, so the scene is one draw.
<a id="tecs.gfx.Renderer.install"></a>

### tecs.gfx.Renderer.install

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.install">tecs.gfx.Renderer.install</a>(self: Renderer, world: ecs.World)
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

<a id="tecs.gfx.Renderer.instances"></a>

### tecs.gfx.Renderer.instances

<pre><code v-pre><a href="#tecs.gfx.Renderer.instances">tecs.gfx.Renderer.instances</a>: Buffer
</code></pre>

The instance buffer the scene is drawn from, and the staging behind it.
<a id="tecs.gfx.Renderer.newRenderer"></a>

### tecs.gfx.Renderer.newRenderer

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.newRenderer">tecs.gfx.Renderer.newRenderer</a>(device: loader.CPtr, swapchainFormat: integer, options: RendererOptions): Renderer
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

<a id="tecs.gfx.Renderer.rebuildPipelines"></a>

### tecs.gfx.Renderer.rebuildPipelines

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.rebuildPipelines">tecs.gfx.Renderer.rebuildPipelines</a>(self: Renderer)
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

<a id="tecs.gfx.Renderer.regionOf"></a>

### tecs.gfx.Renderer.regionOf

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.regionOf">tecs.gfx.Renderer.regionOf</a>(self: Renderer, path: string): TextureArray.Region
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

<a id="tecs.gfx.Renderer.registerImage"></a>

### tecs.gfx.Renderer.registerImage

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.registerImage">tecs.gfx.Renderer.registerImage</a>(self: Renderer, handle: assets.Handle): components.Sprite, TextureArray.Region
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

<a id="tecs.gfx.Renderer.render"></a>

### tecs.gfx.Renderer.render

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.render">tecs.gfx.Renderer.render</a>(self: Renderer, frame: Frame)
</code></pre>

Draws the packet the last extraction produced.

#### Parameters

| Type                        | Name                     | Description                                                                                                                                                                                                                                               |
| --------------------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Renderer</code> | <code v-pre>self</code>  |                                                                                                                                                                                                                                                           |
| <code v-pre>Frame</code>    | <code v-pre>frame</code> | Recorded onto and not submitted, so a caller with passes of its own records them after this and submits once. Its width and height are what the camera's matrix and the view bounds are resolved against, which is why they are not stored on the camera. |

<a id="tecs.gfx.Renderer.replaceImage"></a>

### tecs.gfx.Renderer.replaceImage

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.replaceImage">tecs.gfx.Renderer.replaceImage</a>(self: Renderer, handle: assets.Handle): components.Sprite, TextureArray.Region
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

<a id="tecs.gfx.Renderer.reservesRuns"></a>

### tecs.gfx.Renderer.reservesRuns

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.reservesRuns">tecs.gfx.Renderer.reservesRuns</a>(self: Renderer): boolean
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

<a id="tecs.gfx.Renderer.rewritten"></a>

### tecs.gfx.Renderer.rewritten

<pre><code v-pre><a href="#tecs.gfx.Renderer.rewritten">tecs.gfx.Renderer.rewritten</a>: integer
</code></pre>

Instances the last sync actually rewrote. Zero on a still frame.
<a id="tecs.gfx.Renderer.saveScreenshot"></a>

### tecs.gfx.Renderer.saveScreenshot

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.saveScreenshot">tecs.gfx.Renderer.saveScreenshot</a>(self: Renderer, path: string): boolean, string
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

<a id="tecs.gfx.Renderer.screenshot"></a>

### tecs.gfx.Renderer.screenshot

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.screenshot">tecs.gfx.Renderer.screenshot</a>(self: Renderer): string, string
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

<a id="tecs.gfx.Renderer.setClipRegion"></a>

### tecs.gfx.Renderer.setClipRegion

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.setClipRegion">tecs.gfx.Renderer.setClipRegion</a>(self: Renderer, index: integer, region: <a href="#tecs.gfx.Renderer.ClipRegion">ClipRegion</a>)
</code></pre>

Points region `index` at a rectangle in target pixels.

Fragments of an instance carrying `Clip(index)` are kept where they land
inside the rectangle and thrown away where they do not. Region zero is not
a region and cannot be set: it is what an instance says when it wants no
clipping at all.

#### Parameters

| Type                                                                      | Name                      | Description                                                                         |
| ------------------------------------------------------------------------- | ------------------------- | ----------------------------------------------------------------------------------- |
| <code v-pre>Renderer</code>                                               | <code v-pre>self</code>   |                                                                                     |
| <code v-pre>integer</code>                                                | <code v-pre>index</code>  | 1 through 255. Zero, a fraction, or anything outside that raises.                   |
| <code v-pre><a href="#tecs.gfx.Renderer.ClipRegion">ClipRegion</a></code> | <code v-pre>region</code> | Nil raises rather than clearing; `clearClipRegion` is what stops a region clipping. |

<a id="tecs.gfx.Renderer.sprite"></a>

### tecs.gfx.Renderer.sprite

<pre><code v-pre>function <a href="#tecs.gfx.Renderer.sprite">tecs.gfx.Renderer.sprite</a>(self: Renderer, name: string, u0: number, v0: number, u1: number, v1: number): components.Sprite
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
