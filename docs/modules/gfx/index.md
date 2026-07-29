---
description: "Drawing: the camera, the render components, the renderer, text, and the vocabularies a scene is described in"
outline: deep
---

# tecs.gfx

`tecs.gfx` is where drawing lives. Four things sit on it directly, because a scene that draws anything
at all reaches for them: the [camera](#the-camera) a frame is drawn from, the
[components](#the-components-a-scene-is-drawn-from) an entity carries to be drawn, the
[renderer](#the-renderer) that draws them, and [text](#text-and-fonts), which is a vocabulary small enough to
read here rather than a module of its own. The four larger vocabularies are each a module one level
below, with a page of its own.

## Modules

| Module                                         | What it is                                      |
| ---------------------------------------------- | ----------------------------------------------- |
| [`tecs.gfx.animation`](/modules/gfx/animation) | sprite sheets, and the playback that reads them |
| [`tecs.gfx.layers`](/modules/gfx/layers)       | z-ordering and per-layer behavior               |
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

The names on `tecs.gfx` itself resolve the same way, off whichever of the files below answers each one,
so reading `tecs.gfx.Tint` loads the render components and reading `tecs.gfx.loadFont` loads the text
module. `Camera` and `Renderer` are classes rather than modules of their own: they are reached through
this namespace, `tecs.gfx.Camera`, and documented here rather than on a page apiece, because a class is
a type its namespace owns.

## The camera

A camera is what the view is looking at: a center in world units, a zoom, a rotation, and a projection
mode. It is one type rather than a 2D camera and a 3D one, because the only thing that would differ
between them is how the matrix is built, and nothing reading the matrix, neither the vertex shader nor
the cull, cares which built it.

Position is the center of the view rather than a corner, so a camera that has never been moved shows the
world origin in the middle of the window. The renderer centers a default camera on the first frame it
draws, so a scene that never mentions a camera behaves as though world coordinates were screen
coordinates. See [the renderer](#the-renderer) for how a camera reaches a frame.

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
| `x`          | `number` | `0`              | Center of the view in world units.                                                        |
| `y`          | `number` | `0`              | Center of the view in world units.                                                        |
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
| `x`          | `number` | Center of the view, in world units.                                                                                                                                                                                     |
| `y`          | `number` | Center of the view, in world units.                                                                                                                                                                                     |
| `zoom`       | `number` | Above one magnifies. Applied about the center, so zooming does not move what is under the middle of the window.                                                                                                         |
| `rotation`   | `number` | Radians. Positive turns the scene counter-clockwise on screen, which is the camera itself turning the other way: at a quarter turn, a point at +X from the camera in the world is drawn above the center of the window. |
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
[`PointLight`](#pointlight).

### What the camera does not place

A layer can ask to be positioned in screen pixels, in a virtual resolution, at its own parallax, or
outside the camera's zoom. Contents of such a layer are not placed where the camera would put them, and
the cull gives up on them rather than testing a world bound that does not describe where they draw.
[layers](/modules/gfx/layers) has the rules.

## The components a scene is drawn from

The components the engine itself reads describe what an entity looks like: what color it is, which
image it samples, which material shades it, whether it is clipped, whether it lights the scene, and
whether it contributes geometry at all. None of them is required to use a world; an entity carrying none
is a position and some game state.

These are not the ECS builtins. `ChildOf`, `TTL`, `Paused`, `Disabled`, `EntityKey` and the state transition
events are registered by every world whether or not a renderer exists, and they are documented at
[builtins](/ecs/builtins). The ones here are registered when the engine half is first touched.

`Transform` is deliberately not among them. It positions everything a world holds rather than only what
draws, so it is the ECS builtin and is written `tecs.Transform`; a second spelling here would
say the hierarchy, physics and the tweens were moving a graphics component.

```teal
local entity <const> = world:spawn(
    tecs.Transform(120, 80),
    tecs.gfx.Tint(1, 0.4, 0.2, 1),
    tecs.gfx.Renderable()
)
```

### The set

| Component           | Storage          | Fields                                    | Read by                                       |
| ------------------- | ---------------- | ----------------------------------------- | --------------------------------------------- |
| `PreviousTransform` | FFI              | `x` `y` `rotation`                        | extraction, for interpolation                 |
| `Tint`              | FFI              | `r` `g` `b` `a`                           | extraction, into the G-buffer's albedo target |
| `Sprite`            | FFI              | `image` `u0` `v0` `u1` `v1` `slot`        | extraction, sprite sheets, animation          |
| `Material`          | FFI              | `id` `param`                              | extraction, into the material dispatch        |
| `PointLight`        | FFI              | `height` `radius` `r` `g` `b` `intensity` | extraction, into the frame's light list       |
| `Clip`              | FFI              | `index`                                   | extraction, then the fragment shader          |
| `Occluder`          | FFI              | `height`                                  | extraction, into the occluder mask            |
| `DropShadow`        | FFI              | `height`                                  | extraction, into the drop-shadow target       |
| `Renderable`        | table, no fields | none                                      | the extractor's renderable query              |

Everything except `Renderable` is an FFI component on purpose. Their columns are contiguous C memory, which is
what lets the sync walk rows and write straight into mapped GPU staging instead of reading fields one entity at
a time through a table.

::: warning Dirty bits decide whether a frame resyncs
Extraction rewrites an archetype's run only when one of `Transform`, `Tint`, `Sprite`, `Material`, `Clip`,
`Pivot`, `Occluder` or `DropShadow` is dirty on it, or when the archetype carries `PreviousTransform` and the
frame is interpolating. A write through `world:getMut` marks the column; a cdata write reached through
`world:get` does not, and needs `world:markComponentDirty(entity, Component)` after it or the GPU keeps drawing
the old value. `world:batchSpawn` skips FFI defaults, so a callback has to set every field it cares about.
:::

### PreviousTransform

The transform as it stood before the current fixed step.

Presence is the opt-in. An entity carrying it is drawn somewhere between this and its current transform,
according to how far through the step the frame falls. Simulation advances in fixed jumps and frames arrive
whenever the display asks for one, so without this an entity moved by physics steps visibly rather than moving.

| Field      | Type    | Default | Description                        |
| ---------- | ------- | ------- | ---------------------------------- |
| `x`        | `float` | `0`     | World x as of the last fixed step. |
| `y`        | `float` | `0`     | World y as of the last fixed step. |
| `rotation` | `float` | `0`     | Radians as of the last fixed step. |

Only the fields that move continuously are here. Scale and layer change by assignment rather than by
integration, and a half-applied assignment is not a value anything asked for.

**Pairs with:** `Transform`. The engine installs a `tecs.SnapshotTransforms` system in the `FixedFirst` phase
that copies `Transform` into `PreviousTransform` for every entity carrying both, before anything in the step
moves. Adding the component is all that is needed; the physics plugin adds it to bodies it creates.

### Tint

Base color, and how much of what is behind the entity survives it.

| Field | Type    | Default | Description                                 |
| ----- | ------- | ------- | ------------------------------------------- |
| `r`   | `float` | `1`     | Red, 0 to 1.                                |
| `g`   | `float` | `1`     | Green, 0 to 1.                              |
| `b`   | `float` | `1`     | Blue, 0 to 1.                               |
| `a`   | `float` | `1`     | Alpha, 0 to 1. At one the entity is opaque. |

**Required for drawing.** The extractor's renderable query is `Transform`, `Tint` and `Renderable` together, so
an entity missing a `Tint` is not extracted at all. It is also what the sequencer's built-in `color.a` and
`color.rgba` tween targets write; see [sequence](/modules/sequence#targets).

The alpha is what decides which pass draws the entity. At exactly one it is opaque and goes through the
G-buffer, where lighting resolves it once for the whole scene however many things overlap. Below one it goes
through the forward pass instead, which runs after the frame has been composited, blends straight alpha over it,
and lights itself out of the same lights and the same ambient the resolve used, so the only thing that changes as
alpha crosses one is how much of the fragment lands.

What crossing one gives up is the G-buffer. A blended entity writes no depth, so it hides nothing behind it and
nothing that reads a normal or an emission later can see it; blended entities are sorted back to front against
each other, and against opaque geometry the depth the G-buffer already holds decides. The forward list is shorter
than the instance buffer, so a scene with more than 65,536 blended entities visible at once draws the ones
earliest in the buffer and drops the rest. An entity meant to be solid should say so with an alpha of exactly one.

::: warning Not yet reachable from a world
The renderer half of this is in: the pass, the pipeline, the sort and the lane are built and covered by
`spec/blend_spec.lua`. What routes a row into the forward lane is extraction writing the cull bound's first half
extent negated, and extraction does not do that yet, so today an alpha below one is carried into the instance and
still drawn opaque. This note goes when `src/tecs/Extractor.tl` marks the row.
:::

### Sprite

Samples a texture instead of drawing flat color.

| Field   | Type      | Default | Description                                                            |
| ------- | --------- | ------- | ---------------------------------------------------------------------- |
| `image` | `int32_t` | `0`     | Intern index of the image's name, from `imageId`. Zero names no image. |
| `u0`    | `float`   | `0`     | UV rect, left.                                                         |
| `v0`    | `float`   | `0`     | UV rect, top.                                                          |
| `u1`    | `float`   | `1`     | UV rect, right.                                                        |
| `v1`    | `float`   | `1`     | UV rect, bottom.                                                       |
| `slot`  | `int32_t` | `-1`    | Texture-array layer the name resolved to. Negative means unresolved.   |

`image` names the image and `slot` is the texture-array layer the renderer resolved that name to. Both are here
because extraction reads the slot for every row it writes and wants a field rather than a lookup, while a
snapshot needs something a slot cannot give it: slots are handed out in registration order, so slot seven means
whichever image registered seventh, and a number that depends on load order cannot survive a round trip through
a save. Only the name is written to a snapshot, and `deserialize` interns it again on the way back.

A negative slot means unresolved. The renderer fills it in the first time it writes the row, so a Sprite
restored from a snapshot or built by hand resolves once rather than once per frame.

::: warning Repointing a live Sprite
Pointing a Sprite at another image means writing a negative `slot` along with the new `image`, or the row keeps
drawing the layer the old name resolved to.
:::

The UV rect selects a region, so an atlas is the same thing as a whole image with the rect set to the full
range. A Sprite is normally not built by hand: [the renderer](#images) hands one back when an image is
registered, and [`animation`](/modules/gfx/animation) builds them per frame and per slice.

**Pairs with:** `Renderable` and `Tint`, which the renderable query requires; `Animation` from
[`animation`](/modules/gfx/animation), which drives playback by writing the UV lanes. When an animation resolves on
the GPU those four lanes carry a playback rather than a rect, which is why a serialized Sprite in that state
writes the whole image and lets the animation put its own answer back on the first step after a load.

### Material

Which material shades a renderable's quad.

| Field   | Type      | Default | Description                                                                                                                  |
| ------- | --------- | ------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `id`    | `int32_t` | `0`     | Material id, from `tecs.gfx.materials.id(name)`.                                                                             |
| `param` | `float`   | `0.25`  | Passed to the material, 0 to 1. What it means is the material's business; the rounded rectangle reads it as a corner radius. |

Absent means the default, which samples the image array and covers the whole quad, so an entity with neither a
`Sprite` nor a `Material` still draws. Present selects one of the materials found under `materials/`.

The id comes from [`materials`](/modules/gfx/materials) rather than being written as a number, because the numbering
depends on which material files exist and a literal would break the moment one was added ahead of it
alphabetically. One instance format either way: the batch, the cull and the draw do not know which material an
entity uses, which is what keeps the whole scene one draw.

### PointLight

A light resolved by the deferred lighting pass.

| Field       | Type    | Default | Description                     |
| ----------- | ------- | ------- | ------------------------------- |
| `height`    | `float` | `64`    | Height above the surface plane. |
| `radius`    | `float` | `256`   | Reach, in world units.          |
| `r`         | `float` | `1`     | Red, 0 to 1.                    |
| `g`         | `float` | `1`     | Green, 0 to 1.                  |
| `b`         | `float` | `1`     | Blue, 0 to 1.                   |
| `intensity` | `float` | `1`     | Multiplier on the color.        |

At zero `height` the Lambert term vanishes and the light contributes nothing, which reads as the light being
broken rather than as a value being wrong.

**Pairs with:** `Transform`, and nothing else. Lights are collected by their own query, `Transform` and
`PointLight`, so a light needs neither `Renderable` nor `Tint` and an entity can be a light, a drawn thing, or
both. A light is placed in world units like everything else, so moving the camera moves what is lit and zoom
scales what a radius covers on screen rather than what it covers in the world.

### Clip

Which clip region a renderable's fragments are kept inside.

| Field   | Type      | Default | Description                                                                  |
| ------- | --------- | ------- | ---------------------------------------------------------------------------- |
| `index` | `int32_t` | `0`     | Names a rectangle set with `Renderer:setClipRegion`. Zero means no clipping. |

The rectangle is in target pixels measured from the top left, and each fragment is tested against where it
landed rather than against where the entity is in the world. That is what a scrollable list inside a panel
means, and it is one rectangle for all of it: a panel occupies a part of the window whether its contents are
placed by the camera, in screen pixels, or in virtual coordinates.

A component rather than a field on something every renderable has, because presence is the opt-in and absence is
the common case: an archetype without this column is written by a loop that never mentions clipping, and the
fragments it produces never read the region table. A world that clips nothing pays for this exactly nowhere.

Nesting is the caller's. A region is one rectangle, so a panel inside a panel is set up as the intersection of
the two rather than as two regions an instance sits in at once. The rectangle itself is set through
[the renderer](#extending-a-frame), and clearing one puts it back to clipping nothing, so an index handed out and
taken back leaves the instances still pointing at it drawing whole rather than silently gone.

### Occluder

Stands between a light and what is behind it.

| Field    | Type    | Default | Description                                                                    |
| -------- | ------- | ------- | ------------------------------------------------------------------------------ |
| `height` | `float` | `1.0`   | How tall the entity stands, 0 to 1 of the world height `shadows.height` names. |

The silhouette goes into one mask that every light marches against, so an entity blocks every light in the
scene at the cost of one drawing of itself rather than one drawing per light. What it takes away is a light's
own contribution and never the ambient term, because a mask read inside the light loop has no way to reach a
term that is not in it. `DropShadow` is the other half of that.

Coverage is the silhouette, so a circle, a rounded box or a glyph casts the shape it draws and there is no
alpha threshold to set: the material dispatch already decided which fragments the entity covers.

The height reads against `shadows.height` on the renderer, which defaults to 64, the same as a `PointLight`'s
default height. So an occluder at `1.0` under a default light is level with it and its shadow runs to the
horizon; at `0.5` the light clears it and the shadow ends.

**Pairs with:** `Transform`, `Tint`, `Renderable`, and shadows turned on. Without
[`shadows`](#shadows) on the renderer the entity draws exactly as it would without this
component. A translucent entity casts nothing whatever it carries: it is drawn forward over the composited
image and never reaches the G-buffer, so a hard silhouette of it would be a lie.

### DropShadow

Throws a stretched copy of the entity along the ground, away from the light.

| Field    | Type    | Default | Description                                                         |
| -------- | ------- | ------- | ------------------------------------------------------------------- |
| `height` | `float` | `1.0`   | How far off the ground the copy is thrown from, on the same 0 to 1. |

What this darkens is everything a light left, ambient included, which is exactly what `Occluder` cannot do and
the reason both exist. Under a black light and full ambient an occluder has nothing to take away and this still
throws a shadow.

It blocks no light in return, and that is the design rather than a limitation: a crowd of light-blocking
silhouettes merges under the mask into one flat mat of darkness, so the thing that wants a contact shadow is
exactly the thing that must not be an occluder. An entity carrying both components is an occluder, because
dropping that half would unblock a light without saying so.

The copy is thrown by the nearest few lights by weight rather than by every light, so a light spawned elsewhere
in the world does not move a shadow that had already settled. How dark it is and how long it may run are
`shadows.dropOpacity` and `shadows.dropLength` on the renderer.

**Pairs with:** the same as `Occluder`, under the same conditions.

### Renderable

Marks an entity as contributing geometry. Without it a `Transform` is just a position, which is what most
entities in a world actually are.

It carries no fields; presence is the whole of it. Together with `Transform` and `Tint` it is what the
extractor's renderable query includes, so those three are the minimum an entity needs to be drawn.

### Image names

An image's name is its identity, and a texture-array slot is not. A component is plain C memory and a string
does not fit there, so what a `Sprite` carries is the name's intern index. The index is process-local and never
leaves the process.

#### imageId

Index of the given image name, assigning one the first time it is seen.

```teal
function tecs.gfx.imageId(name: string): integer
```

**Parameters:**

- `name`: the image's path. Empty or nil raises.

**Returns:** an index, starting at one, so zero is the index of no image at all and that is what a `Sprite`
carries until something names one.

The name is normalized lexically first, so what an image is identified by is the path it names rather than the
spelling it was named with: repeated separators, `.` segments and a trailing separator are dropped. Nothing here
reads the filesystem, so a name normalizes the same before its file exists as after. Three things are
deliberately left alone: `..`, because resolving it without the filesystem renames a path across a symlink;
letter case, because folding it merges two files a case-sensitive filesystem keeps apart; and the asset root,
because stripping it would make an identity depend on process state that `TECS_ASSETS` and
`tecs.filesystem.setAssetRoot` move.

#### imageName

Name an index stands for.

```teal
function tecs.gfx.imageName(id: integer): string
```

**Returns:** the name, or nil when the index names nothing.

### Components declared elsewhere

Subsystems register components of their own, and they are documented with the subsystem rather than here:

| Component             | Module                                           | What it does                                          |
| --------------------- | ------------------------------------------------ | ----------------------------------------------------- |
| `Pivot`               | [`animation`](/modules/gfx/animation)            | Hangs the quad off a point other than its middle.     |
| `Animation`           | [`animation`](/modules/gfx/animation)            | Sprite-sheet playback, resolved in the vertex shader. |
| `AnimationEvents`     | [`animation`](/modules/gfx/animation)            | Events derived from playback.                         |
| `Text`                | [`text`](/modules/gfx/)                          | A run of distance-field text.                         |
| `ParticleEmitter`     | [`particles`](/modules/gfx/particles)            | An emitter, whose particles are not entities.         |
| `Sound`               | [`Audio`](/modules/audio)                        | A voice attached to an entity.                        |
| `RigidBody`           | [`physics`](/modules/physics)                    | The body an entity is.                                |
| `TweenTrackingTarget` | [`sequence`](/modules/sequence#tracking-sources) | Selects the entity a tracking tween chases.           |

## The renderer

`tecs.gfx.Renderer` is the path from a world to the GPU. A game does not construct one: the
[application](/modules/Application) does, and hands it over as `app.renderer`.

```teal
return tecs.newApplication({
    plugin = function(world: tecs.World, app: tecs.Application)
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
- **A color clear comes from the target**, which is right while one pass writes a target and wrong as soon as
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

On, an entity carrying [`Occluder`](#occluder) blocks light, and one carrying
[`DropShadow`](#dropshadow) darkens the ground away from it. Off, both components draw the
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

Everything the renderer draws is an entity in a world. The components it reads are
[above](#the-components-a-scene-is-drawn-from), together with the ECS builtin `Transform`, and the
modules that produce them have pages of their own:

- [`tecs.gfx.Camera`](#the-camera), the view it draws from
- [`tecs.gfx.layers`](/modules/gfx/layers), z-ordering and per-layer behavior
- [`tecs.gfx.animation`](/modules/gfx/animation), sprite sheets and playback
- [`tecs.gfx`](/modules/gfx/), distance-field text drawn through an instance producer
- [`tecs.gfx.particles`](/modules/gfx/particles), emitters
- [`tecs.gfx.materials`](/modules/gfx/materials), the material a draw dispatches to

### What the renderer reports

| Field                | What it is                                                             |
| -------------------- | ---------------------------------------------------------------------- |
| `renderer.camera`    | The view. Centerd on the viewport the first time a frame is drawn      |
| `renderer.capacity`  | Instances the buffers are sized for                                    |
| `renderer.count`     | Instances the last sync left resident                                  |
| `renderer.dropped`   | Instances the last sync could not fit                                  |
| `renderer.rewritten` | Instances the last sync actually rewrote. Zero on a still frame        |
| `renderer.images`    | The image array: every image, one binding, so the scene is one draw    |
| `renderer.instances` | The instance buffer the scene is drawn from, and the staging behind it |
| `renderer.deferred`  | The pass graph                                                         |

`dropped` is the one to watch. `capacity` is a ceiling rather than a hint, and rows past it are dropped rather
than growing a buffer mid-frame; a scene that is missing something and reports a non-zero `dropped` needs a
larger `capacity` in the [application config](/modules/Application#the-world-and-the-renderer).

`rewritten` being zero is the dirty model working. A frame in which nothing moved rewrites nothing.

The camera centers itself on the viewport the first time there is something to draw, because the size to center
on is only known once there is a frame to draw into. A scene that never mentions a camera therefore sees world
coordinates as screen coordinates.

### Images

An image is uploaded once and lives in the array for the life of the renderer.

```teal
local sprite, region = app.renderer:registerImage(handle)
world:spawn(tecs.Transform(100, 100), sprite)
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
neighbor. It also raises on a path nothing is registered under, since adding one would be `registerImage`.

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

Producers are how something that is not an archetype run gets instances into the frame; [`text`](/modules/gfx/)
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

## Text and fonts

`tecs.gfx` draws strings from a multi-channel signed distance field. A `Text` names a font and a
string, and it is one entity: its glyphs are not entities at all. The plugin registers an instance
producer with the [renderer](#the-renderer) and every text owns a span of that producer's run.

A glyph is still an ordinary textured quad, with a UV rect addressing the font atlas and a material
selecting the distance-field shader, so culling, depth, layers, clip regions and the indirect draw
all apply to it exactly as they apply to an entity. What the span buys is what per-archetype dirty
tracking cannot give an entity here: glyph entities would all share one archetype, so editing one
string would rewrite every glyph in the world, and spawning or despawning a glyph would move an
archetype's length and relay the whole scene out. A producer reports the sub-ranges it changed, so
editing one string rewrites that string.

### Fonts

A `Font` is metrics and an atlas path, and nothing about a device. Which texture-array layer the
atlas occupies is a renderer's answer, so the plugin holds that and one font can be shared by two
renderers. The metrics are read when the font is loaded, which is a few kilobytes of JSON; the atlas
is named rather than held, and a renderer decodes and uploads it the first frame a text needs it.

#### loadFont

Loads a font's metrics and names its atlas.

```teal
function tecs.gfx.loadFont(options: FontOptions): Font
```

**Parameters:**

- `options.metrics`: path to the metrics JSON, resolved against the asset root unless it already
  starts with `/`. Required; the call raises without it.
- `options.atlas`: path to the atlas image. Optional; defaults to the first page the metrics name,
  resolved beside them. The metrics naming no page and no `atlas` being passed is an error.

**Returns:** the font. A metrics path already loaded answers with the font it loaded, rather than
reading the file twice, so one path means one font for the life of the process however many times it
is asked for.

The document is BMFont-shaped JSON: an `info` block, a `common` block, a `distanceField` block
carrying `distanceRange`, a `chars` list and an optional `kernings` list. A document missing any of
the first three, or listing no glyphs, is refused by name.

**Example:**

```teal
local font <const> = tecs.gfx.loadFont({ metrics = "fonts/inter-msdf.json" })
```

#### defaultFont

The font the engine ships, loaded on first use.

```teal
function tecs.gfx.defaultFont(): Font
```

Equivalent to `tecs.gfx.loadFont({ metrics = "fonts/jetbrainsmono-extrabold-msdf.json" })`.

#### findFont

A loaded font by the metrics path it was loaded from, or nil.

```teal
function tecs.gfx.findFont(name: string): Font
```

This is what a snapshot resolves a font name back through.

#### reloadFont

Re-reads a font's metrics over the font already loaded from them.

```teal
function tecs.gfx.reloadFont(path: string): Font
```

**Parameters:**

- `path`: the metrics path the font was loaded under, or the file that path resolves to. Both
  spellings reach the same font, because a game names it the way it asked for it and a watcher names
  the file it looked at.

**Returns:** the font, which is the table it always was. Identity is the point: a `Text` names its
font by holding the table, so the metrics are read back into that table and every live text goes on
pointing at the font it was given.

Nothing can infer from identity that a re-read happened, so the texts naming that font are told
rather than left to notice, and exactly those: a text naming another font is not laid out again,
whatever archetype it shares. Metrics naming an atlas of another size are refused, because every
glyph already drawn carries UV extents measured against the size the atlas had. A malformed document
raises and leaves the font as it was.

::: tip
A font is two files and only the metrics reload as a font. The atlas is an image, was loaded as one,
and reloads as one under the rect it already occupies.
:::

#### The Font record

| Field           | Type                           | What it is                                                      |
| --------------- | ------------------------------ | --------------------------------------------------------------- |
| `name`          | `string`                       | Path the metrics came from, which is the font's identity        |
| `atlas`         | `string`                       | Path the atlas image is read from, and the name it registers as |
| `size`          | `number`                       | Em size the metrics were generated at                           |
| `lineHeight`    | `number`                       | Distance from one baseline to the next                          |
| `base`          | `number`                       | Baseline offset from the top of a line box                      |
| `atlasWidth`    | `number`                       | Atlas width in pixels                                           |
| `atlasHeight`   | `number`                       | Atlas height in pixels                                          |
| `distanceRange` | `number`                       | Width of the distance field, in atlas pixels                    |
| `glyphs`        | `{integer: GlyphMetrics}`      | Metrics by codepoint                                            |
| `kernings`      | `{integer: {integer: number}}` | Kerning by leading then trailing codepoint; empty when unused   |

Everything but `name` and `atlas` is in the units `size` was generated at, and scales by
`Text.size / Font.size`.

A `GlyphMetrics` is the glyph's rect within the atlas in atlas pixels (`x`, `y`, `width`, `height`),
the offset from the pen to its top-left corner (`xOffset`, `yOffset`), and how far the pen moves
after it (`xAdvance`).

#### Producing a font

A font is two files: the metrics JSON and the atlas image it names. The engine generates neither, so
one is produced ahead of time by whatever tool emits that pair.

The loader reads one shape, and the fields it needs are these:

| In the document               | Becomes                          |
| ----------------------------- | -------------------------------- |
| `info.size`                   | `Font.size`                      |
| `common.lineHeight`           | `Font.lineHeight`                |
| `common.base`                 | `Font.base`                      |
| `common.scaleW`, `.scaleH`    | `Font.atlasWidth`, `atlasHeight` |
| `distanceField.distanceRange` | `Font.distanceRange`             |
| `chars`                       | `Font.glyphs`, keyed by `id`     |
| `kernings`                    | `Font.kernings`, optional        |
| `pages[1]`                    | The atlas image's path           |

A document missing `info`, `common` or `distanceField`, or listing no glyphs, is refused by name. The
`distanceField` block is not optional: the glyph material reads a multi-channel distance field, so a
plain bitmap font has nothing for it to sample.

The font the engine ships was generated like this, which is recorded in full alongside it in
`assets/fonts/JetBrainsMono-NOTICE.md`:

```bash
npx --yes msdf-bmfont-xml@2.8.0 \
    -f json \
    -o jetbrainsmono-extrabold-msdf.png \
    -s 64 \
    -m 512,512 \
    -r 8 \
    --pot \
    --square \
    JetBrainsMono-ExtraBold.ttf
```

`-s` is the em size the metrics are generated at, which arrives as `info.size` and is what
`Text.size` is scaled against. `-m` bounds the atlas, arriving as `common.scaleW` and `common.scaleH`.
`-r` is the width of the distance field in atlas pixels, arriving as `distanceField.distanceRange`;
the material scales the field by how many screen pixels that range covers, which is what keeps the
outline exact at any size, so a range too narrow for how large the text is drawn sharpens noise
rather than the edge.

The image lands beside the metrics, which is where the loader looks for it when `atlas` is not
passed. The shipped font carries printable ASCII, `U+0020` through `U+007E`; a codepoint an atlas has
no glyph for advances the pen by the width of a space and draws nothing.

### The Text component

A string laid out into glyph instances.

```teal
local record Text is Component
    text: string
    font: Font
    size: number
    align: string
    lineSpacing: number
    tracking: number

    width: number
    height: number
end
```

| Field         | Default  | What it is                                                                      |
| ------------- | -------- | ------------------------------------------------------------------------------- |
| `text`        | `""`     | The string laid out. A newline starts a line; nothing else breaks one           |
| `font`        | none     | The font the glyphs come from. Without one the text draws nothing               |
| `size`        | `16`     | Em size in world units                                                          |
| `align`       | `"left"` | `"left"`, `"center"` or `"right"`, within the widest line of the block          |
| `lineSpacing` | `1.0`    | Multiplies the font's line height                                               |
| `tracking`    | `0.0`    | Extra advance between glyphs, in world units                                    |
| `width`       | `0.0`    | Extent of the last layout, written by the layout system; assigning does nothing |
| `height`      | `0.0`    | As `width`                                                                      |

An `align` that is none of the three raises where the component is constructed.

`Text` requires `Transform`, so one is never accidentally left off. The transform places the
top-left corner of the text block and orients and scales the whole block; a `Tint` colors every
glyph; a `Clip` keeps the glyphs inside a rectangle exactly as it would any other quad. All three
are ordinary components on an ordinary entity, so a text is moved, parented, tweened and layered
like anything else. See [components](#the-renderer) for `Tint` and `Clip`.

**Constructing one**, positionally or by name:

```teal
world:spawn(
    Transform(24, 24),
    Tint(0.92, 0.96, 1.0, 1.0),
    tecs.gfx.Text.new({
        text = "tecs\n1200 entities",
        font = tecs.gfx.defaultFont(),
        size = 28,
        align = "center",
    })
)
```

The positional form takes the authored fields in declaration order:
`tecs.gfx.Text(body, font, size, align, lineSpacing, tracking)`.

::: warning Write through getMut
Write through `world:getMut(entity, tecs.gfx.Text)`. A write through `world:get` leaves the column clean
and the glyphs stale.
:::

**Snapshots** carry the authored fields and the font by name. The span is one process's answer and
the font is a shared table, so neither is written. A font that was never loaded in this process
leaves the restored text without one, which lays out nothing rather than failing the load.

### What layout does

Layout is advances, kerning where the metrics carry it, explicit newlines and an alignment within
the block. Alignment moves whole lines within the widest line of the block, which is why it is
applied once the block width is known. A codepoint the font has no metrics for still takes the width
of a space rather than disappearing, and a byte that is not valid UTF-8 is laid out as itself, so a
string that is not UTF-8 renders as Latin-1 rather than failing.

Glyph positions are absolute, so a text composes its own transform: its position, rotation and scale
are applied to the glyph offsets. A text whose `Transform` moved is therefore as stale as one whose
string changed.

What layout does not do: wrapping to a width, anchoring anywhere but the block's top-left corner,
per-glyph styling, right-to-left or complex shaping, and any effect around the outline. Each of
those is a decision rather than an omission of effort.

Glyphs are drawn by the `glyph` material, which is unlit: text draws at its own color rather than
taking whatever the scene's lights leave it in. A label that should take the light is a material of
its own; see [materials](/modules/gfx/materials).

#### measureText

Extent of a `Text` in world units, without touching any entity.

```teal
function tecs.gfx.measureText(item: Text): number, number
```

**Returns:** width, then height. Zero and zero when the item, its font or its string is nil.

This runs the same layout the system runs, so a caller sizing a panel around a string gets the
number the glyphs will occupy.

**Example:**

```teal
local width, height = tecs.gfx.measureText(world:get(entity, tecs.gfx.Text))
```

### The text plugin

```teal
function tecs.gfx.textPlugin(options: TextOptions): function(World)
```

**Parameters:**

- `options.renderer`: the [renderer](#the-renderer) the font atlases upload into and the glyph
  instances are produced for. Required; the call raises without it.

**Example:**

```teal
world:addPlugin(tecs.gfx.textPlugin({ renderer = app.renderer }))
```

The plugin registers the producer on the renderer and adds one system, `tecs.TextLayout`, in
`PostUpdate` after `RelativeTransform`. That ordering is load-bearing: `RelativeTransform` composes a
parented text's own world transform in the same phase, and glyph positions are absolute, so a text
laid out before that composition would use the transform the previous frame left.

Layout runs every frame and almost no text changes, so it is gated twice. An archetype whose `Text`,
`Tint`, `Clip` and `Transform` columns are all clean is skipped whole, and within a dirty archetype a
row whose authored fields and transform match what its glyphs were built from is skipped too. A font
whose atlas has not finished decoding holds the gate open until it arrives.

The plugin also observes two events: `OnDespawn`, so a despawned text hands its span back, and
`FinishSnapshotLoad`, which gives up the whole run, because a load replaces the world in place rather
than despawning what was in it.

A `Text` taken off an entity with `world:remove` is not observed, so a span would otherwise outlive the
component that owned it. The plugin records which entity holds each span and sweeps the ones whose entity no
longer carries the same `Text`, gated on there being more spans held than there are texts to hold them and on
those two counts having moved since the last sweep. So a scene that keeps texts out of the query by disabling
them is walked once rather than every frame, and a scene that removes nothing is never walked.

::: info Spans and fragmentation
Spans come from a size-bucketed free list. Allocating takes an exact-size span off the free list when
one is there and extends the high-water mark otherwise, so short strings appearing and disappearing
reuse each other's spans exactly and the run's length stops moving after warmup. The tradeoff is
fragmentation: a text that grows past its span leaves a hole that only a text of that exact length
reclaims. There is no compaction, and there will not be one until a measurement asks for it.
:::

### Reading a laid-out text back

#### textLayouts

How many texts have been laid out in a world since it was created.

```teal
function tecs.gfx.textLayouts(world: World): integer
```

Laying out a string that did not change is the cost the dirty gates exist to avoid, and this is how
that is asserted rather than assumed.

**Example:**

```teal
local before <const> = tecs.gfx.textLayouts(world)
world:update(1 / 60)
assert(tecs.gfx.textLayouts(world) == before, "an unchanged string must not be laid out again")
```

#### glyphAt

Where a text's `index`th glyph landed.

```teal
function tecs.gfx.glyphAt(world: World, entity: integer,
                      index: integer): number, number, number, number
```

**Returns:** world x, y, width and height, read back out of the instance the producer wrote, so this
is where the glyph is drawn rather than where a layout intended it. Nothing when the world has no
text plugin installed or the text has no such glyph.
