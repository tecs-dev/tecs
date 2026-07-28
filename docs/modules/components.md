---
description: "The engine's render components: Transform, PreviousTransform, Tint, Sprite, Material, PointLight, Clip and Renderable"
outline: deep
---

# tecs.components

`tecs.components` is the set of components the engine itself reads. They describe what an entity looks like:
what colour it is, which image it samples, which material shades it, whether it is clipped, whether it lights
the scene, and whether it contributes geometry at all. Nothing here is required to use a world; an entity that
carries none of them is a position and some game state.

These are not the ECS builtins. `ChildOf`, `TTL`, `Paused`, `Disabled`, `Key` and the state transition events
are registered by every world whether or not a renderer exists, and they are documented at
[builtins](/ecs/builtins). The components on this page are registered when `tecs.components` first loads, which
is when the engine half is touched. The one overlap is `Transform`: it is an ECS builtin, and this module
re-exports it rather than declaring a second one.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it, so this module is `tecs.components`.
`tecs` is also set as a global, which makes the require line optional, and engine modules are resolved lazily
on first field access.

```teal
local components <const> = tecs.components

local entity <const> = world:spawn(
    tecs.ecs.builtins.Transform(120, 80),
    components.Tint(1, 0.4, 0.2, 1),
    components.Renderable()
)
```

## The set

| Component           | Storage           | Fields                                           | Read by                                       |
| ------------------- | ----------------- | ------------------------------------------------ | --------------------------------------------- |
| `Transform`         | FFI (ECS builtin) | `x` `y` `z` `layer` `rotation` `scaleX` `scaleY` | extraction, hierarchy, physics, tweening      |
| `PreviousTransform` | FFI               | `x` `y` `rotation`                               | extraction, for interpolation                 |
| `Tint`              | FFI               | `r` `g` `b` `a`                                  | extraction, into the G-buffer's albedo target |
| `Sprite`            | FFI               | `image` `u0` `v0` `u1` `v1` `slot`               | extraction, sprite sheets, animation          |
| `Material`          | FFI               | `id` `param`                                     | extraction, into the material dispatch        |
| `PointLight`        | FFI               | `height` `radius` `r` `g` `b` `intensity`        | extraction, into the frame's light list       |
| `Clip`              | FFI               | `index`                                          | extraction, then the fragment shader          |
| `Renderable`        | table, no fields  | none                                             | the extractor's renderable query              |

Everything except `Renderable` is an FFI component on purpose. Their columns are contiguous C memory, which is
what lets the sync walk rows and write straight into mapped GPU staging instead of reading fields one entity at
a time through a table.

::: warning Dirty bits decide whether a frame resyncs
Extraction rewrites an archetype's run only when one of `Transform`, `Tint`, `Sprite`, `Material`, `Clip` or
`Pivot` is dirty on it, or when the archetype carries `PreviousTransform` and the frame is interpolating. A
write through `world:getMut` marks the column; a cdata write reached through `world:get` does not, and needs
`world:markComponentDirty(entity, Component)` after it or the GPU keeps drawing the old value. `world:batchSpawn`
skips FFI defaults, so a callback has to set every field it cares about.
:::

## Transform

Position, rotation and scale in world units, which are pixels with the origin at the top left. Lighting works
in the same units, so a light's position needs no conversion.

This is the ECS builtin, re-exported: `tecs.components.Transform` and `tecs.ecs.builtins.Transform` are the same
component. It is a superset of what a renderer needs, carrying `z` and `layer` besides, and it is what the
hierarchy and the authoring systems already move. A renderer reading a transform of its own would draw an
entity where a parent transform or a tween had not put it.

| Field      | Type      | Default | Description                                                              |
| ---------- | --------- | ------- | ------------------------------------------------------------------------ |
| `x`        | `float`   | `0`     | World x, in pixels.                                                      |
| `y`        | `float`   | `0`     | World y, in pixels.                                                      |
| `z`        | `float`   | `0`     | World z.                                                                 |
| `layer`    | `int32_t` | `1`     | Layer band. Must be greater than zero; the constructor raises otherwise. |
| `rotation` | `float`   | `0`     | Radians.                                                                 |
| `scaleX`   | `float`   | `1`     | X scale.                                                                 |
| `scaleY`   | `float`   | `1`     | Y scale.                                                                 |

Which band a `layer` names, and how that band sorts and projects, is [`layers`](/modules/layers).

## PreviousTransform

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

## Tint

Base colour, and how much of what is behind the entity survives it.

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

## Sprite

Samples a texture instead of drawing flat colour.

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
range. A Sprite is normally not built by hand: [`Renderer`](/modules/renderer) hands one back when an image is
registered, and [`sheet`](/modules/sheet) builds them per frame and per slice.

**Pairs with:** `Renderable` and `Tint`, which the renderable query requires; `Animation` from
[`animation`](/modules/animation), which drives playback by writing the UV lanes. When an animation resolves on
the GPU those four lanes carry a playback rather than a rect, which is why a serialized Sprite in that state
writes the whole image and lets the animation put its own answer back on the first step after a load.

## Material

Which material shades a renderable's quad.

| Field   | Type      | Default | Description                                                                                                                  |
| ------- | --------- | ------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `id`    | `int32_t` | `0`     | Material id, from `tecs.materials.id(name)`.                                                                                 |
| `param` | `float`   | `0.25`  | Passed to the material, 0 to 1. What it means is the material's business; the rounded rectangle reads it as a corner radius. |

Absent means the default, which samples the image array and covers the whole quad, so an entity with neither a
`Sprite` nor a `Material` still draws. Present selects one of the materials found under `materials/`.

The id comes from [`materials`](/modules/materials) rather than being written as a number, because the numbering
depends on which material files exist and a literal would break the moment one was added ahead of it
alphabetically. One instance format either way: the batch, the cull and the draw do not know which material an
entity uses, which is what keeps the whole scene one draw.

## PointLight

A light resolved by the deferred lighting pass.

| Field       | Type    | Default | Description                     |
| ----------- | ------- | ------- | ------------------------------- |
| `height`    | `float` | `64`    | Height above the surface plane. |
| `radius`    | `float` | `256`   | Reach, in world units.          |
| `r`         | `float` | `1`     | Red, 0 to 1.                    |
| `g`         | `float` | `1`     | Green, 0 to 1.                  |
| `b`         | `float` | `1`     | Blue, 0 to 1.                   |
| `intensity` | `float` | `1`     | Multiplier on the colour.       |

At zero `height` the Lambert term vanishes and the light contributes nothing, which reads as the light being
broken rather than as a value being wrong.

**Pairs with:** `Transform`, and nothing else. Lights are collected by their own query, `Transform` and
`PointLight`, so a light needs neither `Renderable` nor `Tint` and an entity can be a light, a drawn thing, or
both. A light is placed in world units like everything else, so moving the camera moves what is lit and zoom
scales what a radius covers on screen rather than what it covers in the world.

## Clip

Which clip region a renderable's fragments are kept inside.

| Field   | Type      | Default | Description                                                                  |
| ------- | --------- | ------- | ---------------------------------------------------------------------------- |
| `index` | `int32_t` | `0`     | Names a rectangle set with `Renderer:setClipRegion`. Zero means no clipping. |

A component rather than a field on something every renderable has, because presence is the opt-in and absence is
the common case: an archetype without this column is written by a loop that never mentions clipping, and the
fragments it produces never read the region table. A world that clips nothing pays for this exactly nowhere.

Nesting is the caller's. A region is one rectangle, so a panel inside a panel is set up as the intersection of
the two rather than as two regions an instance sits in at once. The rectangle itself is set through
[`Renderer`](/modules/renderer).

## Renderable

Marks an entity as contributing geometry. Without it a `Transform` is just a position, which is what most
entities in a world actually are.

It carries no fields; presence is the whole of it. Together with `Transform` and `Tint` it is what the
extractor's renderable query includes, so those three are the minimum an entity needs to be drawn.

## Image names

An image's name is its identity, and a texture-array slot is not. A component is plain C memory and a string
does not fit there, so what a `Sprite` carries is the name's intern index. The index is process-local and never
leaves the process.

### imageId

Index of the given image name, assigning one the first time it is seen.

```teal
function components.imageId(name: string): integer
```

**Parameters:**

- `name`: the image's path. Empty or nil raises.

**Returns:** an index, starting at one, so zero is the index of no image at all and that is what a `Sprite`
carries until something names one.

The name is normalised lexically first, so what an image is identified by is the path it names rather than the
spelling it was named with: repeated separators, `.` segments and a trailing separator are dropped. Nothing here
reads the filesystem, so a name normalises the same before its file exists as after. Three things are
deliberately left alone: `..`, because resolving it without the filesystem renames a path across a symlink;
letter case, because folding it merges two files a case-sensitive filesystem keeps apart; and the asset root,
because stripping it would make an identity depend on process state that `TECS_ASSETS` and `paths.setAssets`
move.

### imageName

Name an index stands for.

```teal
function components.imageName(id: integer): string
```

**Returns:** the name, or nil when the index names nothing.

## Components declared elsewhere

Subsystems register components of their own, and they are documented with the subsystem rather than here:

| Component             | Module                                           | What it does                                          |
| --------------------- | ------------------------------------------------ | ----------------------------------------------------- |
| `Pivot`               | [`sheet`](/modules/sheet)                        | Hangs the quad off a point other than its middle.     |
| `Animation`           | [`animation`](/modules/animation)                | Sprite-sheet playback, resolved in the vertex shader. |
| `AnimationEvents`     | [`animation`](/modules/animation)                | Events derived from playback.                         |
| `Text`                | [`text`](/modules/text)                          | A run of distance-field text.                         |
| `ParticleEmitter`     | [`particles`](/modules/particles)                | An emitter, whose particles are not entities.         |
| `Sound`               | [`Audio`](/modules/audio)                        | A voice attached to an entity.                        |
| `RigidBody`           | [`physics`](/modules/physics)                    | The body an entity is.                                |
| `TweenTrackingTarget` | [`sequence`](/modules/sequence#tracking-sources) | Selects the entity a tracking tween chases.           |

## Design record

- [The Tecs binding](https://github.com/tecs-dev/tecs/blob/main/README.md#the-tecs-binding)
- [Clip regions](https://github.com/tecs-dev/tecs/blob/main/README.md#clip-regions)
- [Lights are in the world](https://github.com/tecs-dev/tecs/blob/main/README.md#lights-are-in-the-world)
- [Shapes are materials](https://github.com/tecs-dev/tecs/blob/main/README.md#shapes-are-materials)
- [Sprite sheets and playback](https://github.com/tecs-dev/tecs/blob/main/README.md#sprite-sheets-and-playback)
