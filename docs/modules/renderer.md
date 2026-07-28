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

## What feeds it

Everything the renderer draws is an entity in a world. The components it reads are on
[`tecs.components`](/modules/components) — `Transform`, `PreviousTransform`, `Tint`, `Sprite`, `Material`,
`PointLight`, `Clip` and `Renderable` — and the modules that produce them have their own pages:

- [`tecs.camera.Camera`](/modules/camera), the view it draws from
- [`tecs.layers`](/modules/layers), z-ordering and per-layer behaviour
- [`tecs.sheet`](/modules/sheet) and [`tecs.animation`](/modules/animation), sprite sheets and playback
- [`tecs.text`](/modules/text), distance-field text drawn through an instance producer
- [`tecs.particles`](/modules/particles), emitters
- [`tecs.materials`](/modules/materials), the material a draw dispatches to

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

## Design record

- [GPU-driven by default](https://github.com/tecs-dev/tecs/blob/main/README.md#gpu-driven-by-default)
- [The pass graph](https://github.com/tecs-dev/tecs/blob/main/README.md#the-pass-graph)
- [The seam between composite and present](https://github.com/tecs-dev/tecs/blob/main/README.md#the-seam-between-composite-and-present)
- [Buffer writes](https://github.com/tecs-dev/tecs/blob/main/README.md#buffer-writes)
- [The shader pipeline](https://github.com/tecs-dev/tecs/blob/main/README.md#the-shader-pipeline)
