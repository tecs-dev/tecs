---
title: tecs.math
description: Allocation-free two-dimensional vector and angle math.
outline: [2, 3]
---

# tecs.math

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
