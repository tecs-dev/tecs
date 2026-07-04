---
outline: deep
---

# Tween

`tecs2d.tween` is an animation system for Tecs. It provides typed tween targets,
timeline composition, easing functions, channels, events, and snapshot-safe
playback for entity animations. The tween plugin is registered automatically by
`tecs2d`.

Active tween state is ordinary ECS data. When a timeline is applied, the live
cursor is stored on the target entity as `tween.TweenPlayback`. Snapshot save/load
serializes that cursor and writes shared timeline templates once in snapshot
metadata, so hot reload can resume tweens in flight instead of restarting them.

```teal
local tween = require("tecs2d.tween")

-- Move an entity to x=200 over 0.5 seconds.
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :once()
    :apply(world, entity)
```

## Mental Model

A tween has two parts:

- A `Timeline` is the immutable animation template: targets, durations, easing,
  nesting, emits, repeat mode, and optional channel.
- A `TweenPlayback` component stores live per-entity cursor state: elapsed time,
  delay, speed, pause state, child cursors, and captured start/delta values.

That split is what makes tweens serializable without duplicating template data
for every entity. You can define one timeline and apply it to many entities; the
snapshot stores the template once and each entity stores only its playback cursor.

## Targets

Targets describe which component fields a timeline slot writes to. The target
value is passed separately to `:to()` or `:adjust()`, so the same target can be
reused with different values.

### Built-In Targets

Pre-built target descriptors cover common `Transform` and `Color` fields. These
are created once at module load time and shared everywhere.

| Target                   | Equivalent / behavior                           |
| ------------------------ | ----------------------------------------------- |
| `tween.translateX`       | `tween.field(Transform, "x")`                   |
| `tween.translateY`       | `tween.field(Transform, "y")`                   |
| `tween.translateXY`      | `tween.field2(Transform, "x", "y")`             |
| `tween.rotation`         | `tween.field(Transform, "rotation")`            |
| `tween.rotationShortest` | `tween.angle(Transform, "rotation")`            |
| `tween.scaleX`           | `tween.field(Transform, "scaleX")`              |
| `tween.scaleY`           | `tween.field(Transform, "scaleY")`              |
| `tween.scaleXY`          | `tween.field2(Transform, "scaleX", "scaleY")`   |
| `tween.alpha`            | `tween.field(Color, "a")`                       |
| `tween.color`            | Tweens `Color.r`, `g`, `b`, and `a` together    |

Tween X and Y position together:

```teal
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateXY, 200, 100)
    :once()
    :apply(world, entity)
```

Tween several fields in parallel:

```teal
-- Move and scale simultaneously.
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateXY, 200, 100)
    :to(0.5, tween.quadOut, tween.scaleXY, 2, 2)
    :once()
    :apply(world, entity)
```

Tween color:

```teal
tween.timeline()
    :to(0.5, tween.linear, tween.color, 1, 0, 0, 1)
    :once()
    :apply(world, entity)
```

### `tween.field(component, fieldName)`

Creates a reusable target for one numeric field.

```teal
function tween.field(component: Component, fieldName: string): tween.Target
```

```teal
local tweenHealth = tween.field(HealthBar, "fill")

tween.timeline()
    :to(0.3, tween.quadOut, tweenHealth, 1.0)
    :step()
    :to(0.3, tween.quadOut, tweenHealth, 0.5)
    :once()
    :apply(world, entity)
```

### `tween.field2(component, fieldA, fieldB)`

Creates a reusable target for two numeric fields on the same component.

```teal
function tween.field2(
    component: Component,
    fieldA: string,
    fieldB: string
): tween.Target
```

```teal
local tweenSize = tween.field2(MyWidget, "width", "height")

tween.timeline()
    :to(0.5, tween.quadOut, tweenSize, 200, 100)
    :once()
    :apply(world, entity)
```

### `tween.angle(component, fieldName)`

Creates a target that interpolates an angle over the shortest path. Use this for
rotation-like fields where wrapping from `359` degrees to `1` degree should move
through the two-degree path instead of spinning backward.

```teal
function tween.angle(component: Component, fieldName: string): tween.Target
```

### `tween.target(component, field)`

Creates a target for one numeric field or two numeric fields. This is the compact
form for custom component fields.

```teal
function tween.target(
    component: Component,
    field: string | {string}
): tween.Target
```

```teal
local fill = tween.target(HealthBar, "fill")
local size = tween.target(WidgetBox, {"width", "height"})

tween.timeline()
    :to(0.3, tween.quadOut, fill, 1.0)
    :step()
    :to(0.3, tween.quadOut, size, 200, 100)
    :once()
    :apply(world, widget)
```

::: info Serializable target model
Targets are data descriptors. Built-in targets and targets made with `field`,
`field2`, `angle`, or `target` can be serialized because they identify a
component and field names.
:::

## Timeline Builder

Timelines are created with `tween.timeline()` and built using a fluent API.
Finalizing the builder returns an immutable `Timeline` that can be applied to
any number of entities.

### `TimelineBuilder:to`

Adds an interpolation to the current parallel group. Multiple `:to()` calls
without a `:step()` between them run simultaneously.

```teal
function TimelineBuilder:to(
    self,
    duration: number,
    easingFn: tween.EasingFunction,
    target: tween.Target,
    t1?: number,
    t2?: number,
    t3?: number,
    t4?: number
): TimelineBuilder
```

```teal
-- These two run in parallel.
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :to(0.5, tween.linear, tween.alpha, 0)
    :once()
```

### `TimelineBuilder:adjust`

Like `:to()`, but relative: the values are added to the current values captured
when the slot starts.

```teal
function TimelineBuilder:adjust(
    self,
    duration: number,
    easingFn: tween.EasingFunction,
    target: tween.Target,
    t1: number,
    t2?: number,
    t3?: number,
    t4?: number
): TimelineBuilder
```

```teal
-- Move 100 units right from wherever the entity currently is.
tween.timeline()
    :adjust(0.5, tween.quadOut, tween.translateX, 100)
    :once()
    :apply(world, entity)

-- Chain relative adjustments: right 100, then down 50.
tween.timeline()
    :adjust(0.5, tween.quadOut, tween.translateX, 100)
    :step()
    :adjust(0.5, tween.quadOut, tween.translateY, 50)
    :once()
    :apply(world, entity)
```

### `TimelineBuilder:track`

Tracks target values from ECS data each frame and writes them through an output
target.

```teal
function TimelineBuilder:track(
    self,
    duration: number,
    easingFn: tween.EasingFunction,
    target: tween.Target,
    source: tween.TrackSource
): TimelineBuilder
```

Example: a missile follows the entity whose key is stored in
`tween.TrackingTarget`.

```teal
world:set(missile, tween.TrackingTarget(0, "player"))

tween.timeline()
    :track(
        0.25,
        tween.linear,
        tween.translateXY,
        tween.sourceTrackingTarget(tecs.builtins.Transform, {"x", "y"})
    )
    :loop()
    :apply(world, missile)
```

### Tracking Sources

Tracking sources resolve numbers from ECS state. They are serializable because
they name a source kind, component, and field list.

```teal
function tween.sourceSelf(
    component: Component,
    field: string | {string}
): tween.TrackSource

function tween.sourceKey(
    key: string,
    component: Component,
    field: string | {string}
): tween.TrackSource

function tween.sourceTrackingTarget(
    component: Component,
    field: string | {string}
): tween.TrackSource

function tween.sourceRelationship(
    relationship: Component,
    component: Component,
    field: string | {string}
): tween.TrackSource
```

`sourceSelf` reads from the tweened entity:

```teal
tween.timeline()
    :track(0.2, tween.quadOut, tween.scaleXY, tween.sourceSelf(SizeGoal, {"x", "y"}))
    :loop()
```

`sourceKey` follows a keyed entity:

```teal
tween.timeline()
    :track(0.2, tween.linear, tween.translateXY, tween.sourceKey(
        "player",
        tecs.builtins.Transform,
        {"x", "y"}
    ))
    :loop()
```

`sourceTrackingTarget` reads `tween.TrackingTarget` from the tweened entity. The
component can point to an entity ID or a durable `Key`.

```teal
world:set(missile, tween.TrackingTarget(playerEntity, ""))
world:set(missile, tween.TrackingTarget(0, "player"))
```

`sourceRelationship` follows an entity reached through a relationship component.
Use it when the target is already modeled as ECS relationship data.

::: warning
Tracking sources are ECS descriptors. If a tween needs to follow runtime-only
state, put the durable source of truth in a component or reconstruct the
runtime-only state after load.
:::

### `TimelineBuilder:step`

A step is a barrier that waits for the current parallel group to finish, then
starts the next group. Without `:step()`, multiple slots run simultaneously. With
it, they run sequentially.

```teal
function TimelineBuilder:step(self, delay?: number): TimelineBuilder
```

Step with no delay:

```teal
-- Move right, then move down.
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :step()
    :to(0.5, tween.quadOut, tween.translateY, 100)
    :once()
```

Step with delay:

```teal
-- Move right, wait 0.2s, then fade out.
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :step(0.2)
    :to(0.5, tween.linear, tween.alpha, 0)
    :once()
```

### `TimelineBuilder:emit`

Schedules a named event at the current timeline boundary.

```teal
function TimelineBuilder:emit(self, name: string): TimelineBuilder
```

```teal
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :emit("whoosh")
    :step()
    :to(0.5, tween.quadOut, tween.translateY, 100)
    :once()
    :apply(world, entity)

world:observe(0, tween.TweenEvent, function(ev: tween.TweenEvent)
    if ev.name == "whoosh" then
        audioManager:play(whoosh)
    end
end)
```

### `TimelineBuilder:run`

Inlines another timeline at the current time offset. The sub-timeline's full
behavior is preserved: slots, emits, loops, and ping-pong playback all run as
defined. Sub-timelines can themselves contain `:run()` calls.

```teal
function TimelineBuilder:run(
    self,
    timeline: tween.Timeline,
    count?: integer
): TimelineBuilder
```

```teal
local moveRight = tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :once()

local moveRightThenDown = tween.timeline()
    :run(moveRight)
    :step()
    :to(0.5, tween.linear, tween.translateY, 100)
    :once()

moveRightThenDown:apply(world, entity)
```

The optional `count` parameter overrides how many cycles the sub-timeline plays.
It is required for infinite sub-timelines because their duration is unbounded.

```teal
local pulse = tween.timeline()
    :to(0.8, tween.sineInOut, tween.scaleXY, 1.5, 1.5)
    :pingPong()

tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :step()
    :run(pulse, 3)
    :step()
    :to(0.5, tween.linear, tween.alpha, 0)
    :once()
    :apply(world, entity)
```

Nested timelines are serialized as shared templates. A parent timeline references
the child template by ID in the snapshot rather than embedding a full copy for
every active cursor.

### `TimelineBuilder:channel`

Timelines may declare a channel. Applying a timeline with a channel cancels any
currently active tween on the same entity and channel, then starts the new
playback. Timelines without a channel never automatically cancel other tweens.

```teal
function TimelineBuilder:channel(self, name: string): TimelineBuilder
```

```teal
local moveRight = tween.timeline()
    :channel("movement")
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :once()

local moveDown = tween.timeline()
    :channel("movement")
    :to(0.5, tween.quadOut, tween.translateY, 100)
    :once()

moveRight:apply(world, entity)
moveDown:apply(world, entity) -- cancels moveRight on "movement"
```

::: info
Channels are coarse-grained coordination, not per-field conflict detection.
:::

## Completion And Events

Timeline side effects are expressed through events observed by normal ECS
systems.

### `tween.TweenEvent`

`TweenEvent` is emitted when playback reaches a named `:emit(name)` point.

```teal
local flash = tween.timeline()
    :to(0.2, tween.quadOut, tween.scaleXY, 1.2, 1.2)
    :emit("flash")
    :step()
    :to(0.2, tween.quadOut, tween.scaleXY, 1.0, 1.0)
    :once()

world:observe(0, tween.TweenEvent, function(ev: tween.TweenEvent)
    if ev.name == "flash" then
        world:set(ev.entity, HitFlash({timer = 0.1}))
    end
end)

flash:apply(world, enemy)
```

`TweenEvent` fields:

| Field        | Description                                    |
| ------------ | ---------------------------------------------- |
| `entity`     | Entity playing the tween                       |
| `name`       | Name passed to `:emit(name)`                   |
| `channel`    | Timeline channel, or `nil`                     |
| `timelineId` | World-local template ID for this timeline      |

### `tween.TweenComplete`

`TweenComplete` is emitted when a finite top-level cursor finishes all repeats.
It is not emitted for infinite loops unless they are cancelled by another
timeline and therefore do not naturally complete.

```teal
world:observe(0, tween.TweenComplete, function(ev: tween.TweenComplete)
    if ev.channel == "fade-out" then
        world:despawn(ev.entity)
    end
end)
```

`TweenComplete` fields:

| Field        | Description                                    |
| ------------ | ---------------------------------------------- |
| `entity`     | Entity whose tween completed                   |
| `channel`    | Timeline channel, or `nil`                     |
| `timelineId` | World-local template ID for this timeline      |

## Timeline Finalizers

Finalizers freeze the builder and return a reusable `Timeline`. Further builder
mutation after finalization errors.

### `TimelineBuilder:once`

Play through once.

```teal
function TimelineBuilder:once(self): tween.Timeline
```

### `TimelineBuilder:loop`

Loop the timeline. `loop(count)` treats `count` as the number of additional
plays, so `loop(2)` plays three times total. `loop()` with no argument loops
infinitely.

```teal
function TimelineBuilder:loop(self, count?: integer): tween.Timeline
```

### `TimelineBuilder:pingPong`

Like `loop()`, but reverses direction each cycle. `pingPong()` with no argument
loops infinitely.

```teal
function TimelineBuilder:pingPong(self, count?: integer): tween.Timeline
```

## Applying Timelines

After a timeline is finalized using `:once`, `:loop`, or `:pingPong`, apply it
to an entity with `:apply` or `:play`. The same template can be applied to
multiple entities independently.

### `Timeline:apply`

Starts playback on an entity.

```teal
function Timeline:apply(
    self,
    world: World,
    entity: integer,
    speed?: number,
    delay?: number
)
```

The optional `speed` parameter sets the playback rate multiplier. Default is
`1`. Use `2` for double speed, `0.5` for half speed.

The optional `delay` parameter postpones the start of playback by the given
number of seconds. This is useful for staggering animations across multiple
entities while sharing the same timeline template.

```teal
local fadeOut = tween.timeline()
    :to(0.5, tween.linear, tween.alpha, 0)
    :once()

fadeOut:apply(world, entityA)
fadeOut:apply(world, entityB)

local fall = tween.timeline()
    :to(2.0, tween.bounceOut, tween.translateY, 0)
    :once()

fall:apply(world, entityA, 0.5) -- slow
fall:apply(world, entityB, 2.0) -- fast

local slideIn = tween.timeline()
    :to(0.3, tween.quadOut, tween.translateX, 0)
    :once()

for i = 0, 4 do
    slideIn:apply(world, buttons[i + 1], 1, i * 0.1)
end
```

### `Timeline:play`

Alias for `Timeline:apply`.

```teal
function Timeline:play(
    self,
    world: World,
    entity: integer,
    speed?: number,
    delay?: number
)
```

### `tween.play`

Module-level helper for playing a timeline value, or a named preset that has
already been interned in the current world.

```teal
function tween.play(
    world: World,
    entity: integer,
    timelineOrName: tween.Timeline | string,
    speed?: number,
    delay?: number
)
```

The most explicit pattern is to keep the returned preset timeline and apply it:

```teal
local fadeOut = tween.registerPreset("ui.fadeOut", tween.timeline()
    :channel("visibility")
    :to(0.2, tween.linear, tween.alpha, 0)
    :once())

fadeOut:apply(world, panel)
```

## ECS Playback Control

The module helpers operate on the entity's `TweenPlayback` component and are
safe to call after snapshot load. They affect active cursors selected by entity
plus an optional selector.

```teal
function tween.cancel(world: World, entity: integer, selector?: string | tween.Timeline)
function tween.pause(world: World, entity: integer, selector?: string | tween.Timeline)
function tween.resume(world: World, entity: integer, selector?: string | tween.Timeline)
```

Without the optional selector, they affect every active cursor on the entity.

A string selector matches timeline channel first, then preset name. Channels are
the preferred durable control namespace because they are explicit on the timeline
and survive snapshot load as template data.

```teal
local slide = tween.timeline()
    :channel("visibility")
    :to(0.2, tween.quadOut, tween.alpha, 1)
    :once()

slide:apply(world, panel)

tween.pause(world, panel, "visibility")
tween.resume(world, panel, "visibility")
tween.cancel(world, panel, "ui.fadeOut")
```

A timeline selector matches active cursors created from that exact template in
the current world. This is useful for immediate same-process control, but string
selectors are the better choice for hot-reload-stable control.

```teal
local pulse = tween.timeline()
    :to(0.8, tween.sineInOut, tween.scaleXY, 1.5, 1.5)
    :pingPong()

pulse:apply(world, button)
tween.cancel(world, button, pulse)
```

## Presets

Presets give stable names to reusable timelines. A preset is pinned in the
world-local template registry while it is present, which makes it appropriate for
common UI and gameplay motion patterns.

```teal
local bounceIn = tween.registerPreset("ui.bounceIn", tween.timeline()
    :channel("overlay")
    :to(0.7, tween.elasticOut, tween.scaleXY, 1.0, 1.0)
    :once())

bounceIn:apply(world, titleText)
```

Use presets for animation shapes that are part of your app vocabulary: menu
transitions, damage flashes, standard fade-outs, alert pulses, and similar
reusable behavior.

Inline timelines are also serializable. You do not need to register every
one-off tween:

```teal
tween.timeline()
    :to(0.15, tween.quadOut, tween.scaleXY, 1.1, 1.1)
    :step()
    :to(0.15, tween.quadIn, tween.scaleXY, 1.0, 1.0)
    :once()
    :apply(world, button)
```

Anonymous templates are retained only while live cursors reference them. Named
presets are pinned.

## Snapshots

Tween snapshots are designed around shared immutable templates plus small
per-entity cursors.

On save:

- `TweenPlayback` serializes active cursors on each entity.
- Captured start/delta slot state is flattened from FFI into Lua data.
- The world-local registry writes timeline templates referenced by active
  cursors.
- One template applied to many entities is written once.

On load:

- Timeline IDs from the snapshot are restored as-is so cursors still point at the
  correct templates.
- The next runtime ID resumes above the highest loaded ID.
- Refcounts are rebuilt from restored live cursors.
- Captured start/delta slot state is rebuilt into FFI arrays.
- Playback control remains available through entity selectors: all, channel,
  preset name, or same-process timeline reference.

This preserves mid-flight continuity. If an entity is halfway through a
`rotationShortest` or relative `:adjust()` tween when the snapshot is saved, the
captured start/delta values are restored rather than recomputed from the post-load
world.

### What Is Serializable

Serializable:

- Built-in easing values such as `tween.quadOut` and `tween.elasticOut`
- Built-in targets such as `tween.translateXY` and `tween.color`
- Targets built with `field`, `field2`, `angle`, or one-/two-field `target`
- `:to`, `:adjust`, `:track`, `:step(delay)`, `:emit`, `:run`
- `:once`, `:loop`, `:pingPong`
- Channels, presets, cursor pause state, speed, delay, and elapsed time

## Cleanup

Timelines are automatically removed when:

- A finite timeline finishes
- A cursor is cancelled
- The target entity is no longer alive

When the last cursor for an anonymous template is removed, the world-local
registry can release that template. Pinned presets remain available.

## Easing Functions

All easing functions live directly on `tween` and have the signature
`function(t: number): number`, where `f(0) = 0` and `f(1) = 1`.

`tween.linear` has no acceleration. All other families have four variants:

- **In**: Accelerates from zero velocity
- **Out**: Decelerates to zero velocity
- **InOut**: Accelerates in the first half, decelerates in the second
- **OutIn**: Decelerates in the first half, accelerates in the second

| Family  | In          | Out          | InOut          | OutIn          |
| ------- | ----------- | ------------ | -------------- | -------------- |
| Quad    | `quadIn`    | `quadOut`    | `quadInOut`    | `quadOutIn`    |
| Cubic   | `cubicIn`   | `cubicOut`   | `cubicInOut`   | `cubicOutIn`   |
| Quart   | `quartIn`   | `quartOut`   | `quartInOut`   | `quartOutIn`   |
| Quint   | `quintIn`   | `quintOut`   | `quintInOut`   | `quintOutIn`   |
| Sine    | `sineIn`    | `sineOut`    | `sineInOut`    | `sineOutIn`    |
| Expo    | `expoIn`    | `expoOut`    | `expoInOut`    | `expoOutIn`    |
| Back    | `backIn`    | `backOut`    | `backInOut`    | `backOutIn`    |
| Elastic | `elasticIn` | `elasticOut` | `elasticInOut` | `elasticOutIn` |
| Bounce  | `bounceIn`  | `bounceOut`  | `bounceInOut`  | `bounceOutIn`  |
