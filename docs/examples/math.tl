-- #region tecs.math.wrapAngle
local mathModule <const> = require("tecs.math")

assert(mathModule.wrapAngle(math.pi) == -math.pi)
-- #endregion tecs.math.wrapAngle

-- #region tecs.math.deltaAngle
local mathModule <const> = require("tecs.math")

assert(mathModule.deltaAngle(0, math.pi) == -math.pi)
-- #endregion tecs.math.deltaAngle
