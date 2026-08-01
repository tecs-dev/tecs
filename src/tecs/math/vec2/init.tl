--[=[
Allocation-free two-dimensional vector and point math.

`vec2` takes separate coordinates and returns multiple values, so a system
can update an archetype column without allocating vector objects:

```teal
local record Homing is tecs.ecs.Component
    targetX: number
    targetY: number
    speed: number
end

tecs.ecs.newFFIComponent({
    name = "Homing",
    container = Homing,
    fields = {
        {"targetX", "float"},
        {"targetY", "float"},
        {"speed", "float"},
    },
})

return tecs.newApplication({
    plugin = function(world: tecs.World)
        local homing <const> = world:newQuery({
            include = {tecs.Transform2D, Homing},
        })

        world:addSystem({
            name = "game.Homing",
            phase = tecs.ecs.phases.Update,
            run = function(dt: number)
                for archetype, length in homing:iter() do
                    local transforms <const> =
                        archetype:getMut(tecs.Transform2D)
                    local targets <const> = archetype:get(Homing)

                    for row = 1, length do
                        local transform <const> = transforms[row]
                        local target <const> = targets[row]

                        transform.x, transform.y = tecs.math.vec2.moveTowards(
                            transform.x,
                            transform.y,
                            target.targetX,
                            target.targetY,
                            target.speed * dt
                        )
                        transform.rotation = tecs.math.vec2.angle(
                            target.targetX - transform.x,
                            target.targetY - transform.y
                        )
                    end
                end
            end
        })
    end,
})
```

The writable [`Transform2D`](/modules/ecs/#tecs.ecs.Transform2D) column comes from `getMut`; the read-only target
column comes from `get`. Taking both through `getMut` would dirty `Homing`
every frame and defeat consumers that skip clean columns.

## Coordinates and boundaries

Every angle uses radians. A positive quarter turn maps `(1, 0)` to `(0, 1)`,
which appears clockwise when screen y grows downward.

Operations without a unique geometric answer return stable values.
`normalize(0, 0)`, either angle-between function with a zero vector, and
`project` onto a zero axis return zero. `reflect` with a zero normal returns
the original vector. `lerp` does not clamp, and `moveTowards` never
overshoots.
]=]

local abs <const> = math.abs
local atan2 <const> = math.atan2
local cos <const> = math.cos
local sin <const> = math.sin
local sqrt <const> = math.sqrt

local PI <const> = math.pi
-- Implementation details: The internal name avoids shadowing Lua's `math`
-- standard library and colliding with the public `vec2` field on its parent.
local record vec2Module
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
    --- Prefer this to `length` when comparing magnitudes: compare the answer
    --- with the other distance squared, such as `radius * radius`.
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
    --- A frame-rate-independent chase passes the speed for this frame:
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
    --- Use the answer directly as the shortest directional correction:
    ---
    --- @param ax Starting vector's x coordinate.
    --- @param ay Starting vector's y coordinate.
    --- @param bx Destination vector's x coordinate.
    --- @param by Destination vector's y coordinate.
    --- @return Radians in `[-pi, pi)`, positive in the same sense as `rotate`.
    ---     If either vector is zero, returns zero; an exact half-turn is
    ---     negative pi.
    signedAngleBetween: function(ax: number, ay: number, bx: number, by: number): number

    --- Projects a vector onto another vector.
    ---
    --- The projection axis may have any length:
    ---
    --- @param x The vector's x coordinate.
    --- @param y The vector's y coordinate.
    --- @param ontoX Projection axis's x coordinate.
    --- @param ontoY Projection axis's y coordinate.
    --- @return The projected x coordinate. The axis may have any length;
    ---     a zero axis returns zero.
    --- @return The projected y coordinate, with the same zero-axis rule.
    project: function(x: number, y: number, ontoX: number, ontoY: number): number, number

    --- Reflects a vector across the line perpendicular to a normal.
    ---
    --- The normal may have any length:
    ---
    --- @param x The vector's x coordinate.
    --- @param y The vector's y coordinate.
    --- @param normalX Surface normal's x coordinate.
    --- @param normalY Surface normal's y coordinate.
    --- @return The reflected x coordinate. The normal may have any length;
    ---     a zero normal returns the original x coordinate.
    --- @return The reflected y coordinate, with the same zero-normal rule.
    reflect: function(x: number, y: number, normalX: number, normalY: number): number, number
end

function vec2Module.add(ax: number, ay: number, bx: number, by: number): number, number
    return ax + bx, ay + by
end

function vec2Module.subtract(ax: number, ay: number, bx: number, by: number): number, number
    return ax - bx, ay - by
end

function vec2Module.scale(x: number, y: number, factor: number): number, number
    return x * factor, y * factor
end

function vec2Module.dot(ax: number, ay: number, bx: number, by: number): number
    return ax * bx + ay * by
end

function vec2Module.cross(ax: number, ay: number, bx: number, by: number): number
    return ax * by - ay * bx
end

function vec2Module.lengthSquared(x: number, y: number): number
    return x * x + y * y
end

function vec2Module.length(x: number, y: number): number
    return sqrt(x * x + y * y)
end

function vec2Module.distanceSquared(ax: number, ay: number, bx: number, by: number): number
    local dx <const> = bx - ax
    local dy <const> = by - ay
    return dx * dx + dy * dy
end

function vec2Module.distance(ax: number, ay: number, bx: number, by: number): number
    local dx <const> = bx - ax
    local dy <const> = by - ay
    return sqrt(dx * dx + dy * dy)
end

function vec2Module.normalize(x: number, y: number): number, number
    local magnitude <const> = sqrt(x * x + y * y)
    if magnitude == 0.0 then
        return 0.0, 0.0
    end
    return x / magnitude, y / magnitude
end

function vec2Module.lerp(ax: number, ay: number, bx: number, by: number, t: number): number, number
    if t == 0.0 then
        return ax, ay
    end
    if t == 1.0 then
        return bx, by
    end
    return ax + (bx - ax) * t, ay + (by - ay) * t
end

function vec2Module.moveTowards(
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

function vec2Module.rotate(x: number, y: number, radians: number): number, number
    local c <const> = cos(radians)
    local s <const> = sin(radians)
    return x * c - y * s, x * s + y * c
end

function vec2Module.angle(x: number, y: number): number
    if x == 0.0 and y == 0.0 then
        return 0.0
    end
    return atan2(y, x)
end

function vec2Module.angleBetween(ax: number, ay: number, bx: number, by: number): number
    if (ax == 0.0 and ay == 0.0) or (bx == 0.0 and by == 0.0) then
        return 0.0
    end
    return atan2(abs(ax * by - ay * bx), ax * bx + ay * by)
end

function vec2Module.signedAngleBetween(ax: number, ay: number, bx: number, by: number): number
    if (ax == 0.0 and ay == 0.0) or (bx == 0.0 and by == 0.0) then
        return 0.0
    end
    local angle <const> = atan2(ax * by - ay * bx, ax * bx + ay * by)
    return angle == PI and -PI or angle
end

function vec2Module.project(x: number, y: number, ontoX: number, ontoY: number): number, number
    local denominator <const> = ontoX * ontoX + ontoY * ontoY
    if denominator == 0.0 then
        return 0.0, 0.0
    end
    local factor <const> = (x * ontoX + y * ontoY) / denominator
    return ontoX * factor, ontoY * factor
end

function vec2Module.reflect(x: number, y: number, normalX: number, normalY: number): number, number
    local denominator <const> = normalX * normalX + normalY * normalY
    if denominator == 0.0 then
        return x, y
    end
    local factor <const> = 2.0 * (x * normalX + y * normalY) / denominator
    return x - normalX * factor, y - normalY * factor
end

return vec2Module
