-- #region tecs.math.vec2.add
local vec2 <const> = require("tecs.math.vec2")
local x, y = vec2.add(1, 2, 3, 4)

assert(x == 4 and y == 6)
-- #endregion tecs.math.vec2.add

-- #region tecs.math.vec2.subtract
local vec2 <const> = require("tecs.math.vec2")
local x, y = vec2.subtract(5, 4, 1, 2)

assert(x == 4 and y == 2)
-- #endregion tecs.math.vec2.subtract

-- #region tecs.math.vec2.scale
local vec2 <const> = require("tecs.math.vec2")
local x, y = vec2.scale(2, 3, 4)

assert(x == 8 and y == 12)
-- #endregion tecs.math.vec2.scale

-- #region tecs.math.vec2.dot
local vec2 <const> = require("tecs.math.vec2")

assert(vec2.dot(2, 3, 4, 5) == 23)
-- #endregion tecs.math.vec2.dot

-- #region tecs.math.vec2.cross
local vec2 <const> = require("tecs.math.vec2")

assert(vec2.cross(1, 0, 0, 1) == 1)
-- #endregion tecs.math.vec2.cross

-- #region tecs.math.vec2.lengthSquared
local vec2 <const> = require("tecs.math.vec2")

assert(vec2.lengthSquared(3, 4) == 25)
-- #endregion tecs.math.vec2.lengthSquared

-- #region tecs.math.vec2.length
local vec2 <const> = require("tecs.math.vec2")

assert(vec2.length(3, 4) == 5)
-- #endregion tecs.math.vec2.length

-- #region tecs.math.vec2.distanceSquared
local vec2 <const> = require("tecs.math.vec2")

assert(vec2.distanceSquared(1, 2, 4, 6) == 25)
-- #endregion tecs.math.vec2.distanceSquared

-- #region tecs.math.vec2.distance
local vec2 <const> = require("tecs.math.vec2")

assert(vec2.distance(1, 2, 4, 6) == 5)
-- #endregion tecs.math.vec2.distance

-- #region tecs.math.vec2.normalize
local vec2 <const> = require("tecs.math.vec2")
local x, y = vec2.normalize(3, 4)

assert(x == 0.6 and y == 0.8)
-- #endregion tecs.math.vec2.normalize

-- #region tecs.math.vec2.lerp
local vec2 <const> = require("tecs.math.vec2")
local x, y = vec2.lerp(2, 4, 6, 8, 0.5)

assert(x == 4 and y == 6)
-- #endregion tecs.math.vec2.lerp

-- #region tecs.math.vec2.moveTowards
local vec2 <const> = require("tecs.math.vec2")
local x, y = vec2.moveTowards(0, 0, 3, 4, 2)

assert(x == 1.2 and y == 1.6)
-- #endregion tecs.math.vec2.moveTowards

-- #region tecs.math.vec2.rotate
local vec2 <const> = require("tecs.math.vec2")
local x, y = vec2.rotate(1, 0, math.pi / 2)

assert(math.abs(x) < 0.000001 and math.abs(y - 1) < 0.000001)
-- #endregion tecs.math.vec2.rotate

-- #region tecs.math.vec2.angle
local vec2 <const> = require("tecs.math.vec2")

assert(vec2.angle(0, 1) == math.pi / 2)
-- #endregion tecs.math.vec2.angle

-- #region tecs.math.vec2.angleBetween
local vec2 <const> = require("tecs.math.vec2")

assert(vec2.angleBetween(1, 0, 0, 1) == math.pi / 2)
-- #endregion tecs.math.vec2.angleBetween

-- #region tecs.math.vec2.signedAngleBetween
local vec2 <const> = require("tecs.math.vec2")

assert(vec2.signedAngleBetween(1, 0, 0, 1) == math.pi / 2)
-- #endregion tecs.math.vec2.signedAngleBetween

-- #region tecs.math.vec2.project
local vec2 <const> = require("tecs.math.vec2")
local x, y = vec2.project(3, 4, 1, 0)

assert(x == 3 and y == 0)
-- #endregion tecs.math.vec2.project

-- #region tecs.math.vec2.reflect
local vec2 <const> = require("tecs.math.vec2")
local x, y = vec2.reflect(1, -1, 0, 1)

assert(x == 1 and y == 1)
-- #endregion tecs.math.vec2.reflect
