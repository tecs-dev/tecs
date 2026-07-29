--- Allocation-free two-dimensional vector and angle math.
---
--- Vectors are separate `x, y` numbers rather than tables or cdata. Functions
--- return vector results as two values, so they allocate no temporary objects
--- and LuaJIT can compile their arithmetic into a caller's trace. Every angle
--- is in radians. A positive quarter turn maps `(1, 0)` to `(0, 1)`, which
--- appears clockwise in screen coordinates whose y-axis points down.
---
--- Operations use direct Lua-number arithmetic for game-coordinate magnitudes.
--- As with writing the expressions directly, values near the limits of an
--- IEEE double can overflow when squared or underflow to zero.

local abs <const> = math.abs
local atan2 <const> = math.atan2
local cos <const> = math.cos
local sin <const> = math.sin
local sqrt <const> = math.sqrt

local PI <const> = math.pi
local TWO_PI <const> = PI * 2.0

--- Allocation-free two-dimensional vector and angle math.
---
--- A vector is passed as separate x and y coordinates and returned as two
--- numbers. The module creates and retains no vector objects.
---
--- Named `vectorMath` internally because `math` is Lua's standard library.
--- Shadowing it makes every project's otherwise-clean type-check warn; the
--- public name and module path remain `tecs.math`.
local record vectorMath
    --- Adds two vectors.
    ---
    --- @param ax First vector's x coordinate.
    --- @param ay First vector's y coordinate.
    --- @param bx Second vector's x coordinate.
    --- @param by Second vector's y coordinate.
    --- @return The sum's x coordinate.
    --- @return The sum's y coordinate.
    add: function(ax: number, ay: number, bx: number, by: number): number, number

    --- Subtracts the second vector from the first.
    ---
    --- @param ax First vector's x coordinate.
    --- @param ay First vector's y coordinate.
    --- @param bx Second vector's x coordinate.
    --- @param by Second vector's y coordinate.
    --- @return The difference's x coordinate.
    --- @return The difference's y coordinate.
    subtract: function(ax: number, ay: number, bx: number, by: number): number, number

    --- Multiplies both coordinates by a scalar.
    ---
    --- @param x Vector's x coordinate.
    --- @param y Vector's y coordinate.
    --- @param factor Multiplier applied to both coordinates.
    --- @return The scaled x coordinate.
    --- @return The scaled y coordinate.
    scale: function(x: number, y: number, factor: number): number, number

    --- Computes the dot product of two vectors.
    ---
    --- @param ax First vector's x coordinate.
    --- @param ay First vector's y coordinate.
    --- @param bx Second vector's x coordinate.
    --- @param by Second vector's y coordinate.
    --- @return `ax * bx + ay * by`.
    dot: function(ax: number, ay: number, bx: number, by: number): number

    --- Computes the scalar two-dimensional cross product.
    ---
    --- @param ax First vector's x coordinate.
    --- @param ay First vector's y coordinate.
    --- @param bx Second vector's x coordinate.
    --- @param by Second vector's y coordinate.
    --- @return `ax * by - ay * bx`; positive puts the second vector on the
    ---     positive rotation side of the first.
    cross: function(ax: number, ay: number, bx: number, by: number): number

    --- Computes squared vector length without taking a square root.
    ---
    --- Prefer this to `length` when comparing magnitudes.
    ---
    --- @param x Vector's x coordinate.
    --- @param y Vector's y coordinate.
    --- @return `x * x + y * y`.
    lengthSquared: function(x: number, y: number): number

    --- Computes vector length.
    ---
    --- @param x Vector's x coordinate.
    --- @param y Vector's y coordinate.
    --- @return The nonnegative Euclidean length.
    length: function(x: number, y: number): number

    --- Computes squared distance without taking a square root.
    ---
    --- Prefer this to `distance` for radius tests.
    ---
    --- @param ax First point's x coordinate.
    --- @param ay First point's y coordinate.
    --- @param bx Second point's x coordinate.
    --- @param by Second point's y coordinate.
    --- @return The squared Euclidean distance between the points.
    distanceSquared: function(ax: number, ay: number, bx: number, by: number): number

    --- Computes the distance between two points.
    ---
    --- @param ax First point's x coordinate.
    --- @param ay First point's y coordinate.
    --- @param bx Second point's x coordinate.
    --- @param by Second point's y coordinate.
    --- @return The nonnegative Euclidean distance between the points.
    distance: function(ax: number, ay: number, bx: number, by: number): number

    --- Produces a unit vector in the same direction.
    ---
    --- @param x Vector's x coordinate.
    --- @param y Vector's y coordinate.
    --- @return The normalized x coordinate. A zero vector returns zero
    ---     because it has no direction.
    --- @return The normalized y coordinate, with the same zero-vector rule.
    normalize: function(x: number, y: number): number, number

    --- Interpolates linearly between two points.
    ---
    --- @param ax Starting point's x coordinate.
    --- @param ay Starting point's y coordinate.
    --- @param bx Destination point's x coordinate.
    --- @param by Destination point's y coordinate.
    --- @param t Unclamped interpolation amount. Zero returns the start, one
    ---     returns the destination, and values outside that interval extrapolate.
    --- @return The interpolated x coordinate.
    --- @return The interpolated y coordinate.
    lerp: function(ax: number, ay: number, bx: number, by: number, t: number): number, number

    --- Moves a point toward another by at most a given distance.
    ---
    --- @param x Starting point's x coordinate.
    --- @param y Starting point's y coordinate.
    --- @param targetX Destination point's x coordinate.
    --- @param targetY Destination point's y coordinate.
    --- @param maxDistance Greatest distance to travel. A nonpositive value
    ---     leaves the starting point unchanged.
    --- @return The moved x coordinate. Reaching the destination returns it
    ---     exactly and never overshoots.
    --- @return The moved y coordinate, with the same endpoint rule.
    moveTowards: function(x: number, y: number, targetX: number, targetY: number, maxDistance: number): number, number

    --- Rotates a vector around the origin.
    ---
    --- @param x Vector's x coordinate.
    --- @param y Vector's y coordinate.
    --- @param radians Rotation in radians. A positive quarter turn maps
    ---     `(1, 0)` to `(0, 1)`.
    --- @return The rotated x coordinate.
    --- @return The rotated y coordinate.
    rotate: function(x: number, y: number, radians: number): number, number

    --- Computes a vector's direction.
    ---
    --- @param x Vector's x coordinate.
    --- @param y Vector's y coordinate.
    --- @return `atan2(y, x)` in `[-pi, pi]`. A zero vector returns zero.
    angle: function(x: number, y: number): number

    --- Computes the smaller unsigned angle between two vectors.
    ---
    --- @param ax First vector's x coordinate.
    --- @param ay First vector's y coordinate.
    --- @param bx Second vector's x coordinate.
    --- @param by Second vector's y coordinate.
    --- @return Radians in `[0, pi]`. If either vector is zero, returns zero.
    angleBetween: function(ax: number, ay: number, bx: number, by: number): number

    --- Computes the smaller signed angle from one vector to another.
    ---
    --- @param ax Starting vector's x coordinate.
    --- @param ay Starting vector's y coordinate.
    --- @param bx Destination vector's x coordinate.
    --- @param by Destination vector's y coordinate.
    --- @return Radians in `[-pi, pi)`, positive in the same sense as `rotate`.
    ---     If either vector is zero, returns zero; an exact half-turn is
    ---     negative pi.
    signedAngleBetween: function(ax: number, ay: number, bx: number, by: number): number

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

    --- Projects a vector onto another vector.
    ---
    --- @param x Vector being projected's x coordinate.
    --- @param y Vector being projected's y coordinate.
    --- @param ontoX Projection axis's x coordinate.
    --- @param ontoY Projection axis's y coordinate.
    --- @return The projected x coordinate. The axis need not be normalized;
    ---     a zero axis returns zero.
    --- @return The projected y coordinate, with the same zero-axis rule.
    project: function(x: number, y: number, ontoX: number, ontoY: number): number, number

    --- Reflects a vector across the line perpendicular to a normal.
    ---
    --- @param x Vector being reflected's x coordinate.
    --- @param y Vector being reflected's y coordinate.
    --- @param normalX Surface normal's x coordinate.
    --- @param normalY Surface normal's y coordinate.
    --- @return The reflected x coordinate. The normal need not be normalized;
    ---     a zero normal returns the original x coordinate.
    --- @return The reflected y coordinate, with the same zero-normal rule.
    reflect: function(x: number, y: number, normalX: number, normalY: number): number, number
end

function vectorMath.add(ax: number, ay: number, bx: number, by: number): number, number
    return ax + bx, ay + by
end

function vectorMath.subtract(ax: number, ay: number, bx: number, by: number): number, number
    return ax - bx, ay - by
end

function vectorMath.scale(x: number, y: number, factor: number): number, number
    return x * factor, y * factor
end

function vectorMath.dot(ax: number, ay: number, bx: number, by: number): number
    return ax * bx + ay * by
end

function vectorMath.cross(ax: number, ay: number, bx: number, by: number): number
    return ax * by - ay * bx
end

function vectorMath.lengthSquared(x: number, y: number): number
    return x * x + y * y
end

function vectorMath.length(x: number, y: number): number
    return sqrt(x * x + y * y)
end

function vectorMath.distanceSquared(ax: number, ay: number, bx: number, by: number): number
    local dx <const> = bx - ax
    local dy <const> = by - ay
    return dx * dx + dy * dy
end

function vectorMath.distance(ax: number, ay: number, bx: number, by: number): number
    local dx <const> = bx - ax
    local dy <const> = by - ay
    return sqrt(dx * dx + dy * dy)
end

function vectorMath.normalize(x: number, y: number): number, number
    local magnitude <const> = sqrt(x * x + y * y)
    if magnitude == 0.0 then
        return 0.0, 0.0
    end
    return x / magnitude, y / magnitude
end

function vectorMath.lerp(ax: number, ay: number, bx: number, by: number, t: number): number, number
    if t == 0.0 then
        return ax, ay
    end
    if t == 1.0 then
        return bx, by
    end
    return ax + (bx - ax) * t, ay + (by - ay) * t
end

function vectorMath.moveTowards(
    x: number, y: number, targetX: number, targetY: number, maxDistance: number
): number, number
    if maxDistance <= 0.0 then
        return x, y
    end

    local dx <const> = targetX - x
    local dy <const> = targetY - y
    local distanceSquared <const> = dx * dx + dy * dy
    if distanceSquared == 0.0 or distanceSquared <= maxDistance * maxDistance then
        return targetX, targetY
    end

    local factor <const> = maxDistance / sqrt(distanceSquared)
    return x + dx * factor, y + dy * factor
end

function vectorMath.rotate(x: number, y: number, radians: number): number, number
    local c <const> = cos(radians)
    local s <const> = sin(radians)
    return x * c - y * s, x * s + y * c
end

function vectorMath.angle(x: number, y: number): number
    if x == 0.0 and y == 0.0 then
        return 0.0
    end
    return atan2(y, x)
end

function vectorMath.angleBetween(ax: number, ay: number, bx: number, by: number): number
    if (ax == 0.0 and ay == 0.0) or (bx == 0.0 and by == 0.0) then
        return 0.0
    end
    return atan2(abs(ax * by - ay * bx), ax * bx + ay * by)
end

function vectorMath.signedAngleBetween(ax: number, ay: number, bx: number, by: number): number
    if (ax == 0.0 and ay == 0.0) or (bx == 0.0 and by == 0.0) then
        return 0.0
    end
    local angle <const> = atan2(ax * by - ay * bx, ax * bx + ay * by)
    return angle == PI and -PI or angle
end

function vectorMath.wrapAngle(radians: number): number
    return (radians + PI) % TWO_PI - PI
end

function vectorMath.deltaAngle(from: number, to: number): number
    return vectorMath.wrapAngle(to - from)
end

function vectorMath.project(x: number, y: number, ontoX: number, ontoY: number): number, number
    local denominator <const> = ontoX * ontoX + ontoY * ontoY
    if denominator == 0.0 then
        return 0.0, 0.0
    end
    local factor <const> = (x * ontoX + y * ontoY) / denominator
    return ontoX * factor, ontoY * factor
end

function vectorMath.reflect(x: number, y: number, normalX: number, normalY: number): number, number
    local denominator <const> = normalX * normalX + normalY * normalY
    if denominator == 0.0 then
        return x, y
    end
    local factor <const> = 2.0 * (x * normalX + y * normalY) / denominator
    return x - normalX * factor, y - normalY * factor
end

return vectorMath
