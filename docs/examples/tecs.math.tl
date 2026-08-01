-- #region tecs.math.wrapAngle
--[=[
Keeps a rotation within one turn before storing it.
]=]
assert(tecs.math.wrapAngle(math.pi) == -math.pi)
-- #endregion tecs.math.wrapAngle

-- #region tecs.math.deltaAngle
--[=[
Finds the shortest turn toward a target rotation.
]=]
assert(tecs.math.deltaAngle(0, math.pi) == -math.pi)
-- #endregion tecs.math.deltaAngle
