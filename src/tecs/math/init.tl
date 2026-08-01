--[=[
Angle math and the two-dimensional geometry beneath it.

`wrapAngle` and `deltaAngle` operate on angles rather than vectors, so they
remain directly on `tecs.math`. Vector and point operations live under
`tecs.math.vec2`; native procedural fields live under `tecs.math.noise`.

```teal
local correction <const> = tecs.math.deltaAngle(rotation, targetRotation)
rotation = tecs.math.wrapAngle(rotation + correction * response)

local directionX, directionY =
    tecs.math.vec2.normalize(targetX - x, targetY - y)
```

Every angle uses radians. Both functions return a value in `[-pi, pi)`, so an
exact positive half-turn becomes negative pi.

Naming `tecs.math` does not load either subordinate module. Reading `vec2` or
`noise` loads that child once and returns its module table.
]=]

-- Type-only, so naming `tecs.math` leaves its subordinate modules unloaded.
-- Neither subordinate requires this parent, which keeps the dependency
-- direction free of the cycle Teal rejects.
local type vec2Module = require("tecs.math.vec2")
local type noiseModule = require("tecs.math.noise")

local PI <const> = math.pi
local TWO_PI <const> = PI * 2.0

-- Implementation details: The internal name avoids shadowing Lua's `math`
-- standard library and colliding with its public field in `tecs`.
local record angleMath
    --- Read-only. `vec2` provides allocation-free vector and point operations
    --- over separate coordinates.
    vec2: vec2Module

    --- Read-only. `noise` provides native procedural scalar fields over two
    --- and three-dimensional coordinates.
    noise: noiseModule

    --- Wraps an angle to one turn centered on zero.
    ---
    --- @param radians A finite angle in radians.
    --- @return The equivalent angle in `[-pi, pi)`, so positive pi becomes
    ---     negative pi.
    wrapAngle: function(radians: number): number

    --- Computes the shortest signed turn from one angle to another.
    ---
    --- @param from Starting angle in radians.
    --- @param to Destination angle in radians.
    --- @return `to - from` wrapped to `[-pi, pi)`. An exact half-turn is
    ---     negative pi.
    deltaAngle: function(from: number, to: number): number
end

function angleMath.wrapAngle(radians: number): number
    return (radians + PI) % TWO_PI - PI
end

function angleMath.deltaAngle(from: number, to: number): number
    return angleMath.wrapAngle(to - from)
end

return angleMath
