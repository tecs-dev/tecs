---
title: tecs.math
description: Allocation-free two-dimensional vector and angle math.
outline: [2, 3]
---

# tecs.math

`tecs.math` is the two-dimensional vector and angle arithmetic game code keeps
reaching for: lengths and distances, normalizing, interpolating, rotating,
projecting and reflecting, and the angle math that goes with them.

Every one of them is an expression a caller could have written inline, and that
is the argument for the module rather than against it. The expressions are
short and the mistakes in them are the same ones every time: a normalize that
divides by the length of a zero vector, an angle difference that jumps by a
whole turn as it crosses pi, a chase step that overshoots its target on a long
frame. Each of those has one right answer, that answer does not vary by caller,
and settling it once means the boundary cases are settled once. Naming is the
other half of it. A call to `moveTowards` says what the line is for, where the
same arithmetic spelled out says only what it computes.

## Calling convention

`tecs.math` operates on separate numeric coordinates and returns vector results
as two values:

```lua
local directionX, directionY = tecs.math.normalize(targetX - x, targetY - y)
local nextX, nextY = tecs.math.moveTowards(x, y, targetX, targetY, speed * dt)
```

There is no vector object to allocate or convert. The caller decides whether
the result goes into locals, an ordinary component, or an FFI component.
Squared length and distance functions avoid a square root when only a
comparison is needed.

A vector type is the obvious alternative and it loses on the one axis that
decides something called this often: every operation would allocate its result,
or every caller would keep a pool of them alive. Two numbers in and two numbers
out allocate nothing, and LuaJIT compiles the arithmetic into the caller's own
trace, so the call costs what the expression it replaced would have cost.

## A homing system

A game writes this shape, moving an entity toward what it is chasing and
turning it to face the way it went:

```teal
local record Homing is tecs.ecs.Component
    targetX: number
    targetY: number
    speed: number
end

tecs.ecs.newFFIComponent({
    name = "Homing",
    container = Homing,
    fields = {{"targetX", "float"}, {"targetY", "float"}, {"speed", "float"}},
})

local homing <const> = world:query({include = {tecs.Transform, Homing}})

world:addSystem({
    name = "game.Homing",
    phase = tecs.ecs.phases.Update,
    run = function(dt: number)
        for archetype, length in homing:iter() do
            local transforms = archetype:getMut(tecs.Transform)
            local targets = archetype:get(Homing)
            for row = 1, length do
                local transform = transforms[row]
                local target = targets[row]
                transform.x, transform.y = tecs.math.moveTowards(
                    transform.x, transform.y,
                    target.targetX, target.targetY,
                    target.speed * dt
                )
                transform.rotation = tecs.math.angle(
                    target.targetX - transform.x,
                    target.targetY - transform.y
                )
            end
        end
    end,
})
```

Nothing in that loop allocates, which is what lets it run over every row of
every matching archetype each frame. The two writes go to a column taken with
[`getMut`](/ecs/mutation-model), while the component read beside it uses `get`:
taking `getMut` to read would mark it dirty every frame and defeat the
consumers that skip clean columns.

## Angles and screen coordinates

Every angle is in radians. A positive quarter turn maps `(1, 0)` to `(0, 1)`.
That appears clockwise in the usual screen coordinate system, where y grows
downward. `angleBetween` discards direction, while `signedAngleBetween` uses
the same sign convention as `rotate`.

## Degenerate inputs

Operations with no unique geometric answer use stable values:

| Operation           | Degenerate input       | Result              |
| ------------------- | ---------------------- | ------------------- |
| `normalize`         | zero vector            | `(0, 0)`            |
| `angle`             | zero vector            | `0`                 |
| angle-between forms | either vector is zero  | `0`                 |
| `project`           | zero projection axis   | `(0, 0)`            |
| `reflect`           | zero reflecting normal | the original vector |

`project` and `reflect` accept axes and normals of any nonzero length.
`lerp` is unclamped and may extrapolate. `moveTowards` never overshoots and a
nonpositive distance leaves the starting point unchanged.

## Numeric range

The functions use direct Lua-number arithmetic for ordinary game-coordinate
magnitudes. Values near the limits of an IEEE double may overflow when squared
or underflow to zero, just as the equivalent inline expression would. Engine
component coordinates are single-precision values, so their squares remain
well inside Lua numbers during ordinary use.
