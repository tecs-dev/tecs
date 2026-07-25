---
description: "The tecs2d.tween animation system: data timelines, easing, targets, playback modes, channels, events, presets, and snapshot-safe cursors"
outline: deep
---

# Tween

`tecs2d.tween` animates numeric ECS component fields from declarative data timelines.
The plugin is installed automatically by `tecs2d`.

```teal
local tween = require("tecs2d.tween")

local slide = tween.timeline({
    tween.to(0.5, "quadOut", "transform.x", 200),
})

slide:play(world, entity)
```

A timeline is a reusable finite clip. Playing it adds `tween.TweenPlayback`
while the timeline is active. Playback tracks elapsed time, mode, delay, speed,
direction, and values captured when operations start.

## Timeline Data

Operation constructors provide typed arguments and return positional data
tables. `tween.timeline` compiles the supplied root and operation tables in
place, returning the root as a `tween.Timeline`. Nothing is copied. Do not
mutate or compile those tables again afterward.

```teal
function tween.timeline(spec: tween.TimelineSpec): tween.Timeline
```

Positional entries in the root run sequentially:

```teal
local entrance = tween.timeline({
    tween.to(0.4, "backOut", "transform.x", 200),
    tween.wait(0.2),
    tween.to(0.3, "linear", "color.a", 1),
})
```

Use `tween.parallel` when operations should start together. The next entry
begins after the longest parallel branch finishes.

```teal
local entrance = tween.timeline({
    tween.parallel(
        tween.to(0.4, "backOut", "transform.xy", 200, 100),
        tween.to(0.3, "linear", "color.a", 1)
    ),
    tween.emit("entered"),
})
```

The root is already an implicit sequence. There is no `sequence` constructor or
named `sequence` field; only parallel execution needs an explicit constructor.

Named timeline configuration shares the root table with positional entries:

```teal
local move = tween.timeline({
    channel = "movement",
    tween.to(0.5, "quadOut", "transform.x", 200),
})
```

## Operations

### `to`

Interpolates from the field value captured when the operation starts to an
absolute destination.

```teal
function tween.to(
    duration: number,
    easing: tween.EasingName | tween.EasingFunction,
    target: tween.TargetName | tween.Target,
    value1: number,
    value2?: number,
    value3?: number,
    value4?: number
): tween.TimelineNode
```

```teal
local resize = tween.timeline({
    tween.to(0.5, "quadOut", "transform.scaleXY", 2, 2),
})
```

### `adjust`

Adds relative deltas to the values captured at the start of the operation.

```teal
function tween.adjust(
    duration: number,
    easing: tween.EasingName | tween.EasingFunction,
    target: tween.TargetName | tween.Target,
    delta1: number,
    delta2?: number,
    delta3?: number,
    delta4?: number
): tween.TimelineNode
```

```teal
local nudge = tween.timeline({
    tween.adjust(0.2, "quadOut", "transform.x", 20),
    tween.adjust(0.2, "quadIn", "transform.y", -10),
})
```

### `track`

Reads a destination from ECS state every frame and writes it through a target.

```teal
function tween.track(
    duration: number,
    easing: tween.EasingName | tween.EasingFunction,
    target: tween.TargetName | tween.Target,
    source: tween.TrackSource
): tween.TimelineNode
```

```teal
-- Follow the entity registered as "player", reading its position each frame.
world:set(missile, tween.TrackingTarget(0, "player"))

local follow = tween.timeline({
    tween.track(0.25, "linear", "transform.xy",
        tween.sourceTrackingTarget(tecs.builtins.Transform, {"x", "y"})),
})

follow:play(world, missile, {mode = "loop"})
```

Tracking sources are serializable ECS descriptors:

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

`sourceSelf` reads the animated entity. `sourceKey` resolves a durable ECS key.
`sourceTrackingTarget` reads the entity or key in `TrackingTarget`.
`sourceRelationship` follows an ECS relationship and reads its target entity.

### `wait`

Advances the timeline clock without writing components.

```teal
function tween.wait(duration: number): tween.TimelineNode
```

### `emit`

Emits `tween.TweenEvent` at the current timeline position.

```teal
function tween.emit(name: string): tween.TimelineNode
```

```teal
local flash = tween.timeline({
    tween.to(0.2, "quadOut", "transform.scaleXY", 1.2, 1.2),
    tween.emit("flash"),
    tween.to(0.2, "quadIn", "transform.scaleXY", 1, 1),
})
```

### `run`

Runs another compiled timeline as a sequential entry.

```teal
function tween.run(
    timeline: tween.Timeline,
    options?: tween.RunOptions
): tween.TimelineNode
```

```teal
local pulse = tween.timeline({
    tween.to(0.8, "sineInOut", "transform.scaleXY", 1.5, 1.5),
})

local entrance = tween.timeline({
    tween.to(0.5, "quadOut", "transform.x", 200),
    tween.run(pulse, {mode = "pingPong", count = 4}),
    tween.to(0.3, "linear", "color.a", 0),
})
```

Run options contain `mode` and `count`. A run defaults to one pass. Repeating
runs require a positive finite `count` so the containing timeline has a finite
duration.

### `parallel`

`parallel` starts all branches at the same time and advances by the longest
branch.

```teal
function tween.parallel(...: tween.TimelineNode): tween.TimelineNode
```

Put an untagged nested array inside it when one branch contains several
sequential entries:

```teal
local split = tween.timeline({
    tween.parallel(
        {
            tween.to(0.2, "quadOut", "transform.x", 200),
            tween.to(0.3, "quadIn", "transform.y", 100),
        },
        {
            tween.wait(0.1),
            tween.to(0.4, "linear", "color.a", 0),
        }
    ),
})
```

Both branches start together. The first moves on X and then Y, while the second
waits before fading out. Each branch lasts 0.5 seconds, so the parallel node
also lasts 0.5 seconds.

## Easing and Targets

Tween operations accept string names or the corresponding exported objects:

```teal
tween.to(0.5, "quadOut", "transform.x", 200)
tween.to(0.5, tween.quadOut, tween.translateX, 200)
```

### Built-in Targets

Built-in target names:

| Name | Export | Fields |
| --- | --- | --- |
| `transform.x` | `tween.translateX` | `Transform.x` |
| `transform.y` | `tween.translateY` | `Transform.y` |
| `transform.xy` | `tween.translateXY` | `Transform.x`, `y` |
| `transform.rotation` | `tween.rotation` | `Transform.rotation` |
| `transform.rotationShortest` | `tween.rotationShortest` | shortest angular path |
| `transform.scaleX` | `tween.scaleX` | `Transform.scaleX` |
| `transform.scaleY` | `tween.scaleY` | `Transform.scaleY` |
| `transform.scaleXY` | `tween.scaleXY` | `Transform.scaleX`, `scaleY` |
| `color.a` | `tween.alpha` | `Color.a` |
| `color.rgba` | `tween.color` | `Color.r`, `g`, `b`, `a` |

### `tween.field`

Creates a target for one numeric component field.

```teal
function tween.field(component: Component, fieldName: string): tween.Target
```

The following example tweens `HealthBar.fill` to `1`:

```teal
local fill <const> = tween.field(HealthBar, "fill")

local fillBar = tween.timeline({
    tween.to(0.3, "quadOut", fill, 1),
})
```

### `tween.field2`

Creates a target for two numeric fields on the same component.

```teal
function tween.field2(
    component: Component,
    fieldA: string,
    fieldB: string
): tween.Target
```

The following example tweens `WidgetBox.width` and `height` to `200` and `100`:

```teal
local size <const> = tween.field2(WidgetBox, "width", "height")

local resize = tween.timeline({
    tween.to(0.5, "quadOut", size, 200, 100),
})
```

### `tween.angle`

Creates a target that interpolates a numeric angle over the shortest path.

```teal
function tween.angle(component: Component, fieldName: string): tween.Target
```

The following example tweens `Direction.radians` to `math.pi` over the shortest
angular path:

```teal
local heading <const> = tween.angle(Direction, "radians")

local turn = tween.timeline({
    tween.to(0.4, "sineInOut", heading, math.pi),
})
```

### `tween.target`

Creates a target for either one field or a pair of fields. Use it when the
component fields to write are selected from data, so the same code can build a
target for one or two values at runtime.

`tween.target` chooses where values are written; it does not resolve a changing
destination. To follow a value from live ECS state, pass the target to
`tween.track` with a tracking source.

```teal
function tween.target(
    component: Component,
    field: string | {string}
): tween.Target
```

The following example builds a target from a data-selected field list, then
tweens `Position.x` and `y` to `200` and `100`:

```teal
local offset <const> = tween.target(Position, {"x", "y"})

local move = tween.timeline({
    tween.to(0.5, "quadOut", offset, 200, 100),
})
```

### Easing Functions

All easing functions live directly on `tween` and have the signature
`function(t: number): number`, where `f(0) = 0` and `f(1) = 1`.

`tween.linear` has no acceleration. All other families have four variants:

- **In**: Accelerates from zero velocity
- **Out**: Decelerates to zero velocity
- **InOut**: Accelerates in the first half, decelerates in the second
- **OutIn**: Decelerates in the first half, accelerates in the second

| Family | In | Out | InOut | OutIn |
| --- | --- | --- | --- | --- |
| Quad | `quadIn` | `quadOut` | `quadInOut` | `quadOutIn` |
| Cubic | `cubicIn` | `cubicOut` | `cubicInOut` | `cubicOutIn` |
| Quart | `quartIn` | `quartOut` | `quartInOut` | `quartOutIn` |
| Quint | `quintIn` | `quintOut` | `quintInOut` | `quintOutIn` |
| Sine | `sineIn` | `sineOut` | `sineInOut` | `sineOutIn` |
| Expo | `expoIn` | `expoOut` | `expoInOut` | `expoOutIn` |
| Back | `backIn` | `backOut` | `backInOut` | `backOutIn` |
| Elastic | `elasticIn` | `elasticOut` | `elasticInOut` | `elasticOutIn` |
| Bounce | `bounceIn` | `bounceOut` | `bounceInOut` | `bounceOutIn` |

The exported easing and target string types are enums, so Teal rejects unknown
names at type-check time.

## Playback

Playing a timeline once requires no options:

```teal
timeline:play(world, entity, options?)
```

Playback options are named:

```teal
timeline:play(world, entity, {
    mode = "pingPong",
    count = 4,
    speed = 2,
    delay = 0.1,
})
```

Available playback options:

| Option | Default | Meaning |
| --- | --- | --- |
| `mode` | `once` | `once`, `loop`, or `pingPong` |
| `count` | — | Total number of passes for repeating modes |
| `speed` | `1` | Timeline-time multiplier |
| `delay` | `0` | Seconds before playback starts |

Omitting `count` from `loop` or `pingPong` plays indefinitely. Ping-pong
alternates direction every pass. A count of three runs forward, reverse, then
forward.

The module helper accepts a timeline or registered preset name:

```teal
function tween.play(
    world: World,
    entity: integer,
    timelineOrName: tween.Timeline | string,
    options?: tween.PlaybackOptions
)
```

## Channels and Control

A channel replaces another active timeline on the same entity and channel:

```teal
local moveRight = tween.timeline({
    channel = "movement",
    tween.to(0.5, "quadOut", "transform.x", 200),
})

local moveDown = tween.timeline({
    channel = "movement",
    tween.to(0.5, "quadOut", "transform.y", 100),
})

moveRight:play(world, entity)
moveDown:play(world, entity)
```

Control helpers select all cursors, a channel or preset name, or an exact
timeline reference:

```teal
function tween.cancel(world: World, entity: integer, selector?: string | tween.Timeline)
function tween.pause(world: World, entity: integer, selector?: string | tween.Timeline)
function tween.resume(world: World, entity: integer, selector?: string | tween.Timeline)
```

The following example pauses and resumes the entity's `movement` channel, then
cancels playback started from the exact `moveRight` timeline:

```teal
tween.pause(world, entity, "movement")
tween.resume(world, entity, "movement")
tween.cancel(world, entity, moveRight)
```

## Events

`TweenEvent` is emitted by an `emit` operation.

The following observer handles the `flash` event emitted by a timeline:

```teal
world:observe(0, tween.TweenEvent, function(ev: tween.TweenEvent)
    if ev.name == "flash" then
        world:set(ev.entity, HitFlash({timer = 0.1}))
    end
end)
```

`TweenComplete` is emitted when a finite top-level playback finishes all its
passes. Infinite playback does not complete naturally.

Both events contain `entity`, optional `channel`, and `timelineId`; `TweenEvent`
also contains `name`. `channel` is `nil` for an unchanneled timeline.

```teal
local record TweenEvent is tecs.Event
    entity: integer
    name: string
    channel: string | nil
    timelineId: integer

    init: function(
        self: TweenEvent,
        entity: integer,
        name: string,
        channel: string | nil,
        timelineId: integer
    )
end
```

## Presets

Presets are useful when an animation is part of the application's shared
vocabulary rather than a one-off effect. A preset's stable name lets systems
play it without sharing the original timeline reference, and keeps its template
available in the world registry even when no entity is currently playing it.

```teal
function tween.registerPreset(
    world: World,
    name: string,
    timeline: tween.Timeline
): tween.Timeline
```

The following example registers a reusable UI entrance preset, then plays it
both through its timeline and by name:

```teal
local bounceIn = tween.registerPreset(world, "ui.bounceIn", tween.timeline({
    channel = "overlay",
    tween.to(0.7, "elasticOut", "transform.scaleXY", 1, 1),
}))

bounceIn:play(world, titleText)
tween.play(world, titleText, "ui.bounceIn", {delay = 0.1})
```

Anonymous templates remain registered only while live cursors reference them.
Use them for one-off animations that do not need a durable name.

## Snapshots

Tweens can be snapshotted in the middle of playback and restored at the same
point in the animation. Elapsed time, direction, remaining passes, speed,
delay, and captured values are preserved, so playback continues after load
instead of restarting or jumping.

Snapshot support includes:

- Active tweens preserve elapsed time, mode, remaining passes, direction,
  speed, delay, pause state, and captured values.
- Shared timeline templates and nested run templates are serialized once in
  snapshot metadata.
- Built-in names and custom target/source descriptors are restored through
  component names and fields.
- Registry reference counts are rebuilt after load, so selectors and cleanup
  continue to work.

Relative adjustments, shortest-angle interpolation, tracking, finite repeats,
and ping-pong playback resume from their captured state rather than restarting.

## Cleanup

Playback cursors are removed when they complete, are cancelled, or lose their
target entity. `TweenPlayback` is removed when its last cursor is gone.
