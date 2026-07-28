---
description: "Sprite-sheet playback: the Animation component, playing and restarting a tag, completion events, and resolving frames on the GPU or the host"
outline: deep
---

# animation

An `Animation` says which tag of a [sheet](/modules/sheet) is playing, how fast, whether it repeats,
whether it is running, and where in the tag it has got to. Loading and describing a sheet is the other
half; this page is playing one back.

The component carries a sheet id rather than a sheet. A component is plain C memory and a sheet is a
table, and the indirection is the point besides: every entity playing one walk cycle shares one sheet.

Playback is quantised to the fixed step, because animation is simulation. Two machines fed the same
recording have to show the same frame, and a system driven by frame time shows a different one on the
machine that drew more frames.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

`tecs.animation` is the module. `tecs` is also set as a global, so the require line is optional.

## Installing the systems

### plugin

Adds the system that advances playback.

```teal
function animation.plugin(world: World)
```

Not installed for you, so a world that draws no sprite sheets pays nothing for the query. Call it once; a
second call on the same world is ignored, because adding a system twice under one name is an error.

**Parameters:**

- `world`: the world to add the system to.

**Example:**

```teal
local world <const> = tecs.newWorld()
world:addPlugin(tecs.animation.plugin)
```

Which systems this installs depends on [`useGPU`](#usegpu):

| Path         | Systems                                             | Phase             |
| ------------ | --------------------------------------------------- | ----------------- |
| GPU, default | `tecs.EncodeAnimation`, then `tecs.ReportAnimation` | `PostUpdate`      |
| Host         | `tecs.AdvanceAnimation`                             | `FixedPostUpdate` |

`tecs.EncodeAnimation` writes nothing on a step where nothing changed what is playing.
`tecs.ReportAnimation` derives `Completed` and `Looped` for the entities carrying `AnimationEvents` and
writes nothing at all beyond the flag a finished one-shot parks behind. `tecs.AdvanceAnimation` runs on a
logic query, so a paused entity holds the frame it is on, and `FixedPostUpdate` is late enough that
gameplay logic in `FixedUpdate` has already chosen what should be playing.

## The Animation component

An entity also needs a [`Sprite`](/modules/components), which is what the query matches on and what
playback writes into. An `Animation` on its own advances nothing.

| Field     | Type      | Default | Description                                                                                                                                                                                                   |
| --------- | --------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sheet`   | `number`  | `0`     | Registration index of the sheet, from `Sheet.id`. Zero plays nothing.                                                                                                                                         |
| `tag`     | `number`  | `0`     | Index of the tag within that sheet, from `Sheet:tagId`. Zero plays the whole sheet in order.                                                                                                                  |
| `speed`   | `number`  | `1`     | Multiplier on the timing the sheet carries. One is the timing as authored, two is twice as fast. Zero or less holds the current frame and stops time advancing, which is a pause that leaves `playing` alone. |
| `time`    | `number`  | `0`     | Seconds into the cycle, which is the sum of the durations of the frames the tag visits.                                                                                                                       |
| `frame`   | `number`  | `0`     | Frame the `Sprite` currently shows, or zero for none yet.                                                                                                                                                     |
| `loop`    | `boolean` | `true`  | Whether the tag restarts after its last frame.                                                                                                                                                                |
| `playing` | `boolean` | `true`  | Whether time advances.                                                                                                                                                                                        |

How long each frame is held is the sheet's answer and not an entity's, because that is where an artist
sets it: a hold frame is a frame with a long duration, which no single rate can express. Changing `speed`
leaves `time` where it is, so playback carries on from the frame it was showing rather than jumping.

`time` stays inside the cycle: a looping animation wraps and a one-shot parks at the end, so it never
grows without bound and never loses precision to its own age.

`frame` is the frame the `Sprite` was last written from, as an index into the whole sheet rather than
into the tag. Zero means nothing has been written yet, which is how a fresh or restored `Animation` gets
its region on the first step it runs instead of drawing whatever the `Sprite` held.

::: info With playback on the GPU
`frame` stops being an index and keeps only the zero: the encoder writes a value no sheet numbers a frame
to say the `Sprite` carries a live playback, and zero still means the entity is to start its cycle again.
`time` stops being written too. Which frame is showing is [`frameOf`](#frameof) on either path.
:::

A snapshot carries the sheet's name and the tag's name rather than their indices, and resolves them again
on the way back in. The frame is deliberately dropped: zero makes the first step rewrite the region, so a
restored entity does not depend on the region its `Sprite` was saved holding.

## Authoring

### of

An `Animation` playing a named tag of a sheet, ready to spawn.

```teal
function animation.of(source: Sheet, tag?: string, options?: PlayOptions): Animation
```

**Parameters:**

- `source`: the sheet to play. Nil raises.
- `tag`: a tag the sheet names, or nil for the whole sheet in order. Fails on a tag the sheet does not
  carry, since the alternative is a typo that plays every frame.
- `options`: defaults are the sheet's own timing, looping, and playing.

**Returns:** a component value, not an entity: pass it to `world:spawn` or `world:set` yourself.

**`PlayOptions` fields:**

| Field     | Type      | Default | Description                                    |
| --------- | --------- | ------- | ---------------------------------------------- |
| `speed`   | `number`  | `1`     | Multiplier on the sheet's own timing.          |
| `loop`    | `boolean` | `true`  | Whether the tag restarts after its last frame. |
| `playing` | `boolean` | `true`  | Whether it starts running.                     |

**Example:**

```teal
local animation <const> = tecs.animation
local components <const> = tecs.components

local hero <const> = world:spawn(
    components.Transform(200, 140),
    components.Renderable,
    heroSheet:sprite(),
    animation.of(heroSheet, "walk"),
    heroSheet:pivot("feet")
)
```

### play

Points a live entity at a tag and restarts it there.

```teal
function animation.play(world: World, entity: integer, source: Sheet, tag?: string, options?: PlayOptions)
```

Restarting is the point: time and frame both reset, so the next step writes the tag's first frame whatever
the entity was showing. An entity carrying no `Animation` gets one.

**Parameters:**

- `world`: the world the entity lives in.
- `entity`: a live entity, which needs a `Sprite` for playback to reach it.
- `source`: the sheet to play. Nil raises.
- `tag`: a tag the sheet names, or nil for the whole sheet.
- `options`: defaults are the sheet's own timing, looping, and playing.

**Example:**

```teal
tecs.animation.play(world, hero, heroSheet, "attack", { loop = false })
```

### restart

Plays an entity's animation again from the start of its tag.

```teal
function animation.restart(world: World, entity: integer): boolean
```

The sheet, tag, speed and loop flag are left as they are; what resets is where in the cycle playback has
got to and whether it is running. For replaying a one-shot that has finished, and for rewinding one that
has not.

**Returns:** whether there was an `Animation` to restart. False leaves the entity untouched, since there
is nothing to say what it would play.

### Finding a parked one-shot playing

A tag that does not loop parks at the end of its cycle and stops. Finding one there and playing means
something set `playing` back to true, which reads as asking for the animation again, so it starts over.
Advancing from the end instead would park it again on that step and on every step after it, emitting
`Completed` each time. Both paths behave this way.

## Events

`animation.Completed` is emitted on the step a tag that does not loop runs past its last frame. The
animation stops and holds that frame, so it fires once per playthrough and never again until something
restarts it.

`animation.Looped` is emitted on the step a looping tag passes its last frame and restarts. Once per step
at most, not once per cycle: a step long enough to cover several cycles wraps the time once and reports
one loop, so counting these is not a way to count playthroughs.

Both are emitted at address zero, with these fields:

| Field    | Type      | Description                                             |
| -------- | --------- | ------------------------------------------------------- |
| `entity` | `integer` | The entity whose animation finished or wrapped.         |
| `sheet`  | `Sheet`   | The sheet it is playing.                                |
| `tag`    | `string`  | Name of the tag, or the empty string for a whole sheet. |

**Example:**

```teal
local animation <const> = tecs.animation

world:observe(0, animation.Completed, function(event: animation.Completed)
    if event.tag == "attack" then
        animation.play(world, event.entity, heroSheet, "idle")
    end
end)
```

### AnimationEvents

`animation.AnimationEvents` is a marker component that asks for `Completed` and `Looped` on an entity
when playback resolves on the GPU. Nothing is emitted for an entity that does not carry it, and the
reason is the archetype: a crowd of animating entities is visited by no query at all while the handful a
game listens to sit together and are walked on their own. Adding it costs an archetype move once and
nothing per step.

With playback resolved on the host the events are emitted whether or not this is carried, since the
system that advances the frame is already looking at the row when it wraps.

::: warning A one-shot only parks if something asked
On the GPU path, `playing` is what parks a finished one-shot and `Completed` is what clears `playing`.
With no `AnimationEvents` on the entity it stays true, so past its end and playing reads as asked-again
and the entity starts over. Carrying `AnimationEvents` parks it and holds it on the last frame.
:::

## Asking what an entity is showing

Both queries recompute on the call, against the same tick tables the shader reads, through the
`Sheet:frameAt` that already exists. No walk, no column and no readback. Keeping the answer in a column
instead means writing every animating entity on every step, and that is the cost the GPU path exists to
remove.

A few hundred calls a step is free; it stops being free somewhere in the tens of thousands, which is a
game asking a question this is the wrong shape for.

### frameOf

The sheet frame an entity's animation is showing.

```teal
function animation.frameOf(world: World, entity: integer): integer
```

**Returns:** a frame index into the whole sheet, counting from one, or zero for an entity with nothing to
play.

The same answer the vertex shader draws, because both are `frameAt` over the same tag: the shader reads a
table built from it and this calls it. What a hitbox on frame five, a footstep on frame three or a muzzle
on an animated hand asks for.

**Example:**

```teal
if tecs.animation.frameOf(world, hero) == 3 then
    footstep()
end
```

### timeOf

How far into its tag's cycle an entity's animation has got, in seconds.

```teal
function animation.timeOf(world: World, entity: integer): number
```

**Returns:** seconds into the cycle, wrapped for a looping tag and clamped at the end for a one-shot.
Zero for an entity carrying no `Animation` and for one whose sheet this run does not have.

## Where the frame is resolved

There are two paths from an `Animation` to a picture and `useGPU` chooses between them. They agree on the
frame and differ on what they write to reach it, and `frameOf` is what answers either way.

**On, which is the default.** `tecs.EncodeAnimation` writes which playback the entity is on into its
`Sprite`, and the vertex shader resolves the frame from a shared table and the world's count of fixed
steps. A frame changing then writes nothing at all, so what a step costs is what actually changed rather
than what is shaped like it.

**Off.** `tecs.AdvanceAnimation` walks every playing animation on every fixed step and writes the frame's
region into the `Sprite` itself. That marks the column dirty and has extraction rewrite every instance in
the archetype, so one animating sprite costs a rewrite of everything structurally like it, which is what
stops a large animated scene being affordable.

### useGPU

Chooses whether playback is resolved on the GPU.

```teal
function animation.useGPU(enabled: boolean)
```

**Parameters:**

- `enabled`: false puts playback back on the host, for a world that wants events and frame queries
  without opting in or recomputing and is small enough to pay a walk of every animation on every step.

::: warning Set it before `plugin`
It decides which systems that installs, and worlds already carrying them keep them.
:::

Three things read differently with this on:

- `Animation.frame` and `Animation.time` stop being written, and `frameOf` and `timeOf` answer from the
  clock instead.
- `Completed` and `Looped` reach only the entities carrying `AnimationEvents`, and a one-shot that
  finishes leaves `playing` alone unless something is listening for it.
- The `Sprite` carries a playback rather than a region, so its layer and image stop following the sheet:
  the frame table carries both and the shader reads them there.

The two paths anchor a fresh entity's cycle to the same step and agree frame for frame, except within a
millisecond of a boundary, which is a display difference of well under a fixed step.

### usesGPU

Whether playback resolves on the GPU.

```teal
function animation.usesGPU(): boolean
```

## Pausing

Time advances only while `playing` is true and `speed` is above zero, and the ECS builtin `Paused` holds
an entity too.

On the host path the advance runs on a logic query, so a paused entity is not visited and holds the frame
it is on. On the GPU path the world's clock does not stop for one entity, so holding is said rather than
assumed: the encoding carries a rate of zero and the tick to hold. `Paused` moves an entity to another
archetype, and a move marks every component on the destination dirty, so the freeze and the thaw both
reach the encoder without anything having to notice them.

The same re-encode is what makes a speed change hold its position: a new rate is applied from where the
cycle is rather than from where it began.

## The pivot that follows a moving slice

An entity carrying a [`Pivot`](/modules/sheet#the-pivot-component) bound to one of the sheet's slices has
it follow the slice, because an Aseprite slice moves from frame to frame and a pivot that did not follow
it would drift off the part of the drawing it names.

On the host that is a fresh resolve on every frame the sprite changes. On the GPU the entity carries the
middle of where the slice goes over the cycle and the frame table carries each step's offset from it, so
a frame changing still writes nothing; `Pivot.halfX` and `halfY` are how far either side of that middle
the quad can be drawn, and the cull bound grows by exactly that travel.

A pivot written directly and a slice with a single key offset nothing on every frame, so their bound is
exactly the quad's own. A slice bound to another sheet is left where it is: a frame index counts through
one sheet's frames and means something else in another's.

Because two playbacks of one tag bound to two slices want different offsets for the same frame, the slice
is part of a playback's key alongside the sheet and the tag, and the `Pivot` column joins the encoder's
gate: pointing an entity at another slice changes which playback it is on and nothing about its
`Animation` moved to say so.

## Design record

- [Sprite sheets and playback](https://github.com/tecs-dev/tecs/blob/main/README.md#sprite-sheets-and-playback)
- [Playback on the GPU](https://github.com/tecs-dev/tecs/blob/main/README.md#playback-on-the-gpu)
- [The pivot that follows a moving slice](https://github.com/tecs-dev/tecs/blob/main/README.md#the-pivot-that-follows-a-moving-slice)
- [Events, derived rather than observed](https://github.com/tecs-dev/tecs/blob/main/README.md#events-derived-rather-than-observed)
- [Asking what an entity is showing](https://github.com/tecs-dev/tecs/blob/main/README.md#asking-what-an-entity-is-showing)
