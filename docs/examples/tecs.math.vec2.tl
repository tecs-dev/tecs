-- #region tecs.math.vec2.add
--[=[
Combines a position with a per-frame velocity step.
]=]
local x, y = tecs.math.vec2.add(1, 2, 3, 4)

assert(x == 4 and y == 6)
-- #endregion tecs.math.vec2.add

-- #region tecs.math.vec2.subtract
--[=[
Finds the offset from a position to a target.
]=]
local x, y = tecs.math.vec2.subtract(5, 4, 1, 2)

assert(x == 4 and y == 2)
-- #endregion tecs.math.vec2.subtract

-- #region tecs.math.vec2.scale
--[=[
Turns a unit direction into a movement step.
]=]
local x, y = tecs.math.vec2.scale(2, 3, 4)

assert(x == 8 and y == 12)
-- #endregion tecs.math.vec2.scale

-- #region tecs.math.vec2.dot
--[=[
Tests how closely two directions face each other.
]=]
assert(tecs.math.vec2.dot(2, 3, 4, 5) == 23)
-- #endregion tecs.math.vec2.dot

-- #region tecs.math.vec2.cross
--[=[
Determines which side of a direction another vector lies on.
]=]
assert(tecs.math.vec2.cross(1, 0, 0, 1) == 1)
-- #endregion tecs.math.vec2.cross

-- #region tecs.math.vec2.lengthSquared
--[=[
Compares speed without taking a square root.
]=]
assert(tecs.math.vec2.lengthSquared(3, 4) == 25)
-- #endregion tecs.math.vec2.lengthSquared

-- #region tecs.math.vec2.length
--[=[
Measures a velocity's speed.
]=]
assert(tecs.math.vec2.length(3, 4) == 5)
-- #endregion tecs.math.vec2.length

-- #region tecs.math.vec2.distanceSquared
--[=[
Tests whether a target lies inside a radius without a square root.
]=]
assert(tecs.math.vec2.distanceSquared(1, 2, 4, 6) == 25)
-- #endregion tecs.math.vec2.distanceSquared

-- #region tecs.math.vec2.distance
--[=[
Measures how far apart two positions are.
]=]
assert(tecs.math.vec2.distance(1, 2, 4, 6) == 5)
-- #endregion tecs.math.vec2.distance

-- #region tecs.math.vec2.normalize
--[=[
Builds a unit direction toward a target.
]=]
local x, y = tecs.math.vec2.normalize(3, 4)

assert(x == 0.6 and y == 0.8)
-- #endregion tecs.math.vec2.normalize

-- #region tecs.math.vec2.lerp
--[=[
Blends halfway between two positions.
]=]
local x, y = tecs.math.vec2.lerp(2, 4, 6, 8, 0.5)

assert(x == 4 and y == 6)
-- #endregion tecs.math.vec2.lerp

-- #region tecs.math.vec2.moveTowards
--[=[
Moves toward a target without overshooting it.
]=]
local x, y = tecs.math.vec2.moveTowards(0, 0, 3, 4, 2)

assert(x == 1.2 and y == 1.6)
-- #endregion tecs.math.vec2.moveTowards

-- #region tecs.math.vec2.rotate
--[=[
Rotates a facing direction by a quarter turn.
]=]
local x, y = tecs.math.vec2.rotate(1, 0, math.pi / 2)

assert(math.abs(x) < 0.000001 and math.abs(y - 1) < 0.000001)
-- #endregion tecs.math.vec2.rotate

-- #region tecs.math.vec2.angle
--[=[
Converts a direction into a rotation for a sprite.
]=]
assert(tecs.math.vec2.angle(0, 1) == math.pi / 2)
-- #endregion tecs.math.vec2.angle

-- #region tecs.math.vec2.angleBetween
--[=[
Measures the unsigned separation of two facing directions.
]=]
assert(tecs.math.vec2.angleBetween(1, 0, 0, 1) == math.pi / 2)
-- #endregion tecs.math.vec2.angleBetween

-- #region tecs.math.vec2.signedAngleBetween
--[=[
Chooses the shortest directional correction toward a target.
]=]
assert(tecs.math.vec2.signedAngleBetween(1, 0, 0, 1) == math.pi / 2)
-- #endregion tecs.math.vec2.signedAngleBetween

-- #region tecs.math.vec2.project
--[=[
Keeps only the component of a velocity along an axis.
]=]
local x, y = tecs.math.vec2.project(3, 4, 1, 0)

assert(x == 3 and y == 0)
-- #endregion tecs.math.vec2.project

-- #region tecs.math.vec2.reflect
--[=[
Bounces a velocity from a surface normal.
]=]
local x, y = tecs.math.vec2.reflect(1, -1, 0, 1)

assert(x == 1 and y == 1)
-- #endregion tecs.math.vec2.reflect
