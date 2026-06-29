---
outline: deep
---

# Tween

`tecs2d.tween` is an animation system for Tecs. It provides typed interpolators, timeline composition, and easing
functions for smooth entity animations. The tween plugin is automatically registered by `tecs2d`.

```lua
local tween = require("tecs2d.tween")

-- Move an entity to x=200 over 0.5 seconds
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :once()
    :apply(world, entity)
```

## Interpolators

Interpolators are reusable function references that tween a single numeric field on a component.
The target value is passed separately to `:to()`, so the same interpolator can be used with
different targets without creating new closures.

### Canned interpolators

Pre-built interpolator references for common Transform and Color fields. These are created once
at module load time and shared everywhere.

| Interpolator             | Equivalent                                    |
| ------------------------ | --------------------------------------------- |
| `tween.translateX`       | `tween.field(Transform, "x")`                 |
| `tween.translateY`       | `tween.field(Transform, "y")`                 |
| `tween.translateXY`      | `tween.field2(Transform, "x", "y")`           |
| `tween.rotation`         | `tween.field(Transform, "rotation")`          |
| `tween.scaleX`           | `tween.field(Transform, "scaleX")`            |
| `tween.scaleY`           | `tween.field(Transform, "scaleY")`            |
| `tween.scaleXY`          | `tween.field2(Transform, "scaleX", "scaleY")` |
| `tween.alpha`            | `tween.field(Color, "a")`                     |
| `tween.color`            | Tweens RGBA in a single slot                  |
| `tween.rotationShortest` | Shortest-path angle interpolation             |

You can tween the X and Y position of an entity using `tween.translateXY`.

```lua
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateXY, 200, 100)
    :once()
    :apply(world, entity)
```

To tween multiple fields, use a parallel group:

```lua
-- Move and scale simultaneously
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateXY, 200, 100)
    :to(0.5, tween.quadOut, tween.scaleXY, 2)
    :once()
    :apply(world, entity)
```

`tween.color` makes it easy to tween the color of an entity to a target color.

```lua
tween.timeline()
    :to(0.5, tween.linear, tween.color, 1, 0, 0, 1) -- tween to red
    :once()
    :apply(world, entity)
```

### `tween.field(component, fieldName)`

Creates a reusable interpolator for a single numeric field. Uses state slots `s1` (start) and
`d1` (delta).

```lua
function tween.field(component: Component, fieldName: string): Interpolator
```

**Example:**

```lua
local tweenHealth = tween.field(HealthBar, "fill")

-- Reuse the same interpolator with different targets
tween.timeline()
    :to(0.3, tween.quadOut, tweenHealth, 1)
    :step()
    :to(0.3, tween.quadOut, tweenHealth, 0.5)
    :once()
    :apply(world, entity)
```

### `tween.field2(component, fieldA, fieldB)`

Creates a reusable interpolator for two numeric fields on the same component. Uses state slots
`s1`, `s2` (starts) and `d1`, `d2` (deltas). Accepts two target values via `:to()`.

```lua
function tween.field2(component: Component, fieldA: string, fieldB: string): Interpolator
```

**Example:**

```lua
local tweenSize = tween.field2(MyWidget, "width", "height")

tween.timeline()
    :to(0.5, tween.quadOut, tweenSize, 200, 100)
    :once()
    :apply(world, entity)
```

### `tween.track(base, getTargetFn)`

Wraps any interpolator to dynamically track a moving target each frame instead of tweening to a
fixed value. The `getTargetFn` returns up to 4 target values; the wrapper recalculates deltas
from the captured starting state every frame.

```lua
function tween.track(base: Interpolator, getTargetFn: TrackTargetFn): Interpolator
```

This works because all interpolators follow the standardized slot convention (`s1`-`s4` for
starts, `d1`-`d4` for deltas), so `track` can generically override the deltas regardless of
the underlying interpolator.

**Example: homing projectile**

```lua
local follow = tween.track(tween.translateXY, function(world: tecs.World, _entity: integer)
    local p = world:get(playerEntity, Transform)
    if p then return p.x, p.y end
    return nil, nil  -- nil falls back to original delta
end)

tween.timeline()
    :to(2.0, tween.linear, follow, 0, 0)
    :loop()
    :apply(world, missileEntity)
```

### Custom interpolators

For advanced use cases, you can write a custom interpolator. An interpolator is a record with
two methods: `init` captures starting state, `apply` writes the interpolated value each frame.

All interpolators follow the **slot convention**: `s1`-`s4` hold starting values, `d1`-`d4`
hold deltas. This uniform layout enables generic composition (e.g., dynamic tracking wrappers).

**`init(world, entity, relative, t1, t2, t3, t4) -> s1, s2, s3, s4, d1, d2, d3, d4`**

Called once on first tick. Returns starting values and deltas.

| Parameter  | Type      | Description                                         |
| ---------- | --------- | --------------------------------------------------- |
| `world`    | `World`   | The ECS world                                       |
| `entity`   | `integer` | Target entity ID                                    |
| `relative` | `boolean` | `true` from `:adjust()`, `false` from `:to()`       |
| `t1`-`t4`  | `number`  | Target values passed from `:to()` or `:adjust()`    |

**`apply(world, entity, t, s1, s2, s3, s4, d1, d2, d3, d4)`**

Called every frame. `s1`-`s4` are starting values, `d1`-`d4` are deltas.

| Parameter  | Type      | Description                                         |
| ---------- | --------- | --------------------------------------------------- |
| `world`    | `World`   | The ECS world                                       |
| `entity`   | `integer` | Target entity ID                                    |
| `t`        | `number`  | Eased progress, 0 to 1                              |
| `s1`-`s4`  | `number`  | Starting values captured by `init`                  |
| `d1`-`d4`  | `number`  | Deltas computed by `init`                           |

```lua
local tweenInnerRadius: tween.Interpolator = {
    init = function(
        world: tecs.World, entity: integer, relative: boolean, t1: number
    ): number, number, number, number, number, number, number, number
        local shape = world:get(entity, MyRingComponent)
        if shape then
            local startVal = shape.inner.radius
            local delta = relative and t1 or (t1 - startVal)
            return startVal, 0, 0, 0, delta, 0, 0, 0
        end
        return 0, 0, 0, 0, 0, 0, 0, 0
    end,
    apply = function(
        world: tecs.World, entity: integer, t: number,
        s1: number, _s2: number, _s3: number, _s4: number, d1: number
    )
        local shape = world:get(entity, MyRingComponent)
        if shape then
            shape.inner.radius = s1 + d1 * t
            world:markComponentDirty(entity, MyRingComponent)
        end
    end
}

tween.timeline()
    :to(0.5, tween.quadOut, tweenInnerRadius, 50)
    :once()
    :apply(world, entity)
```

## Timeline builder

Timelines are created with `tween.timeline()` and built using a fluent API. Timelines essentially act as animation
templates that are applied to entities.

### `TimelineBuilder:to`

Adds an interpolation to the current parallel group. The interpolator is a reusable function
reference and `t1`-`t4` are the target values. Multiple `:to()` calls without a `:step()`
between them run simultaneously.

```lua
function TimelineBuilder:to(
    self,
    duration: number,
    easingFn: EasingFunction,
    interpolator: Interpolator,
    t1: number, t2?: number, t3?: number, t4?: number
): TimelineBuilder
```

**Example:**

```lua
-- These two run in parallel (same start time)
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :to(0.5, tween.linear, tween.alpha, 0)
    :once()
```

### `TimelineBuilder:adjust`

Like `:to()`, but relative: the values are added to the current values rather than replacing
them. Uses the same interpolators and participates in parallel groups the same way.

```lua
function TimelineBuilder:adjust(
    self,
    duration: number,
    easingFn: EasingFunction,
    interpolator: Interpolator,
    t1: number, t2?: number, t3?: number, t4?: number
): TimelineBuilder
```

**Example:**

```lua
-- Move 100 units right from wherever the entity currently is
tween.timeline()
    :adjust(0.5, tween.quadOut, tween.translateX, 100)
    :once()
    :apply(world, entity)

-- Chain relative adjustments: right 100, then down 50
tween.timeline()
    :adjust(0.5, tween.quadOut, tween.translateX, 100)
    :step()
    :adjust(0.5, tween.quadOut, tween.translateY, 50)
    :once()
    :apply(world, entity)
```

### `TimelineBuilder:step`

A step is a barrier that waits for the current parallel group to finish, then starts the next group.
Without `:step()`, multiple `:to()` calls run simultaneously. With it, they run sequentially.

#### step, no args

`step` can be called with no arguments.

```lua
function TimelineBuilder:step(self): TimelineBuilder
```

**Example:**

```lua
-- Move right, THEN move down (sequential)
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :step()
    :to(0.5, tween.quadOut, tween.translateY, 100)
    :once()
```

#### step with delay

You can provide an optional delay in seconds to wait between groups.

```lua
function TimelineBuilder:step(self, delay: number): TimelineBuilder
```

**Example:**

```lua
-- Move right, wait 0.2s, then fade out
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :step(0.2)
    :to(0.5, tween.linear, tween.alpha, 0)
    :once()
```

#### step with notification

You can provide an optional notification callback `function(world, entity)` that fires when playback reaches the step
boundary. This can be useful for triggering sounds, spawning particles, or changing animation frames at transition
points.

```lua
function TimelineBuilder:step(
    self,
    notify: function(world: tecs.World, entity: integer, handle: tween.TweenHandle)
): TimelineBuilder
```

**Example:**

```lua
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :step(function(world: tecs.World, entity: integer, handle: tween.TweenHandle)
        playSound("whoosh")
    end)
    :to(0.5, tween.quadOut, tween.translateY, 100)
    :once()
```

#### step with delay and notification

Pause and callback can be combined.

```lua
function TimelineBuilder:step(
    self,
    delay: number,
    notify: function(world: tecs.World, entity: integer, handle: tween.TweenHandle)
): TimelineBuilder
```

**Example:**

```lua
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :step(0.2, function(world: tecs.World, entity: integer, handle: tween.TweenHandle)
        spawnParticles(world, entity)
    end)
    :to(0.3, tween.linear, tween.alpha, 0)
    :once()
```

### `TimelineBuilder:run`

Inlines another timeline at the current time offset. The sub-timeline's full behavior is
preserved: its entries, looping, and pingPong all run as defined. Sub-timelines can themselves
contain `:run()` calls, enabling arbitrary nesting.

```lua
function TimelineBuilder:run(self, schedule: Timeline, count?: integer): TimelineBuilder
```

**Example:**

```lua
-- Define a reusable movement pattern
local moveRight = tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :once()

-- Embed it in a larger sequence
local moveRightThenDown = tween.timeline()
    :run(moveRight)
    :step()
    :to(0.5, tween.linear, tween.translateY, 100)
    :once()

local handle = moveRightThenDown:apply(world, entity)
```

The optional `count` parameter overrides how many cycles the sub-timeline plays. This is
required for infinite sub-timelines, since their duration is unbounded (that is, timelines that loops or ping pongs).

```lua
-- An infinite pulse
local pulse = tween.timeline()
    :to(0.8, tween.sineInOut, tween.scaleX, 1.5)
    :to(0.8, tween.sineInOut, tween.scaleY, 1.5)
    :pingPong()

-- Cap it to 3 cycles within a sequence
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :step()
    :run(pulse, 3)
    :step()
    :to(0.5, tween.linear, tween.alpha, 0)
    :once()
    :apply(world, entity)
```

### `TimelineBuilder:channel`

Timelines may optionally declare a channel. Applying a timeline with a channel cancels any currently active tween on
the same entity and channel, then starts the new playback. Timelines without a channel never automatically cancel
other tweens.

```lua
function TimelineBuilder:channel(self, name: string): TimelineBuilder
```

**Example:**

```lua
local moveRight = tween.timeline()
    :channel("movement")
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :once()

local moveDown = tween.timeline()
    :channel("movement")
    :to(0.5, tween.quadOut, tween.translateY, 100)
    :once()

-- First apply starts the movement
moveRight:apply(world, entity)

-- Second apply on same channel cancels the first automatically
moveDown:apply(world, entity)
```

::: info
Channels are coarse-grained coordination, not per-field conflict detection.
:::

### `TimelineBuilder:onComplete`

Sets a callback for when the entire timeline finishes (after all repeats). Receives
`(world, entity, handle)`. Only meaningful for finite timelines; never fires on infinite loops.

This is distinct from a trailing `:step(fn)`, which fires at the end of *every* cycle
in a looping timeline.

```lua
function TimelineBuilder:onComplete(
    self, fn: function(world: World, entity: integer, handle: TweenHandle)
): TimelineBuilder
```

**Example:**

```lua
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :onComplete(function(world: tecs.World, entity: integer, handle: tween.TweenHandle)
        world:despawn(entity)
    end)
    :once()
    :apply(world, entity)
```

## TimelineBuilder finalizers

Finalizers freeze the builder and return a reusable `Timeline`. Further `:to()` calls on a
finalized builder will error.

### `TimelineBuilder:once`

Play through once.

```lua
function TimelineBuilder:once(self): Timeline
```

### `TimelineBuilder:loop`

Loop the timeline. `count` is the number of additional plays, so `loop(2)` plays 3 times total.
`loop()` with no argument loops infinitely.

```lua
function TimelineBuilder:loop(self, count?: integer): Timeline
```

### `TimelineBuilder:pingPong`

Like `loop()` but reverses direction each cycle. `pingPong()` with no argument loops infinitely.

```lua
function TimelineBuilder:pingPong(self, count?: integer): Timeline
```

## Applying timelines

After a timeline is [finalized](#timelinebuilder-finalizers) using `:once`, `:loop`, or `:pingPong`, it can be applied to an entity
using `:apply`.

### `Timeline:apply`

Clones the frozen definition into a live timeline targeting a specific entity. Returns a handle
for cancellation. The same definition can be applied to multiple entities independently.

```lua
function Timeline:apply(
    self,
    world: World,
    entity: integer,
    speed?: number,
    delay?: number
): TweenHandle
```

The optional `speed` parameter sets the playback rate multiplier. Default is `1`. Use `2` for
double speed, `0.5` for half speed.

The optional `delay` parameter postpones the start of playback by the given number of seconds.
This is useful for staggering animations across multiple entities while sharing the same schedule.

```lua
local fadeOut = tween.timeline()
    :to(0.5, tween.linear, tween.alpha, 0)
    :once()

-- Apply to multiple entities
fadeOut:apply(world, entityA)
fadeOut:apply(world, entityB)

-- Same animation, different speeds
local fall = tween.timeline()
    :to(2.0, tween.bounceOut, tween.translateY, 0)
    :once()

fall:apply(world, entityA, 0.5)  -- slow
fall:apply(world, entityB, 2.0)  -- fast

-- Stagger 5 buttons sliding in, 0.1s apart, sharing one schedule
local slideIn = tween.timeline()
    :to(0.3, tween.quadOut, tween.translateX, 0)
    :once()

for i = 0, 4 do
    slideIn:apply(world, buttons[i + 1], 1, i * 0.1)
end
```

## Tween handles

[Applying a tween](#applying-timelines) returns a handle. You can pause, resume, and cancel a tween from this handle.

### `TweenHandle:cancel`

Removes the timeline from the active list, stopping the tween immediately.

```lua
function TweenHandle:cancel(self)
```

**Example:**

```lua
local handle = pulse:apply(world, entity)
-- Later...
handle:cancel()
```

### `TweenHandle:pause`

Pauses playback. While paused, the timeline doesn't advance but remains in the active list.

```lua
function TweenHandle:pause(self)
```

**Example:**

```lua
local handle = tween.timeline()
    :to(1.0, tween.quadOut, tween.translateX, 200)
    :once()
    :apply(world, entity)

handle:pause()   -- freezes at current position
handle:resume()  -- continues from where it left off
```

### `TweenHandle:resume`

Resumes playback.

```lua
function TweenHandle:resume(self)
```

### `TweenHandle:getElapsed`

Returns the total elapsed play time of the tween in seconds.

```lua
function TweenHandle:getElapsed(self): number
```

### `TweenHandle:getRate`

Gets the rate, or speed modifier, of the tween.

```lua
function TweenHandle:getRate(self): number
```

### `TweenHandle:getDirection`

Get the current playback direction: `1` for forward, `-1` for reverse.

```lua
function TweenHandle:getDirection(self): integer
```

### Self-modifying tweens

Step callbacks and `onComplete` receive the handle as a third argument. This enables tweens
that react to game state without capturing external variables.

```lua
tween.timeline()
    :to(0.5, tween.quadOut, tween.translateX, 200)
    :step(function(world: tecs.World, entity: integer, handle: tween.TweenHandle)
        print("elapsed:", handle:getElapsed(), "rate:", handle:getRate())

        if not isAttacking then
            handle:cancel()
        end
    end)
    :to(0.5, tween.quadOut, tween.translateX, 0)
    :once()
    :apply(world, entity)
```

## Cleanup

Timelines are automatically removed when:

- The timeline finishes (finite timelines)
- The target entity is no longer alive (checked each frame)

## Easing functions

All easing functions live directly on `tween` and have the signature `function(t: number): number`
where `f(0) = 0` and `f(1) = 1`.

`tween.linear` has no acceleration. All other families have four variants:

- **In**: Accelerates from zero velocity
- **Out**: Decelerates to zero velocity
- **InOut**: Accelerates in the first half, decelerates in the second
- **OutIn**: Decelerates in the first half, accelerates in the second

| Family    | In            | Out            | InOut            | OutIn            |
| --------- | ------------- | -------------- | ---------------- | ---------------- |
| Quad      | `quadIn`      | `quadOut`      | `quadInOut`      | `quadOutIn`      |
| Cubic     | `cubicIn`     | `cubicOut`     | `cubicInOut`     | `cubicOutIn`     |
| Quart     | `quartIn`     | `quartOut`     | `quartInOut`     | `quartOutIn`     |
| Quint     | `quintIn`     | `quintOut`     | `quintInOut`     | `quintOutIn`     |
| Sine      | `sineIn`      | `sineOut`      | `sineInOut`      | `sineOutIn`      |
| Expo      | `expoIn`      | `expoOut`      | `expoInOut`      | `expoOutIn`      |
| Back      | `backIn`      | `backOut`      | `backInOut`      | `backOutIn`      |
| Elastic   | `elasticIn`   | `elasticOut`   | `elasticInOut`   | `elasticOutIn`   |
| Bounce    | `bounceIn`    | `bounceOut`    | `bounceInOut`    | `bounceOutIn`    |
