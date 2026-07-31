-- #region tecs.regex.Regex.isMatch
local regex <const> = require("tecs.regex").compile([[\.(png|jpg)$]])

assert(regex:isMatch("sprite.png"))
-- #endregion tecs.regex.Regex.isMatch

-- #region tecs.regex.Regex.find
local regex <const> = require("tecs.regex").compile([[\d+]])
local found <const> = assert(regex:find("hp=100"))

assert(found.value == "100")
-- #endregion tecs.regex.Regex.find

-- #region tecs.regex.Regex.replace
local regex <const> = require("tecs.regex").compile([[(\w+)=(\d+)]])

assert(regex:replace("hp=100 mp=50", "$1: $2") == "hp: 100 mp=50")
-- #endregion tecs.regex.Regex.replace

-- #region tecs.regex.Regex.replaceAll
local regex <const> = require("tecs.regex").compile([[\d+]])

assert(regex:replaceAll("room 12, floor 3", "#") == "room #, floor #")
-- #endregion tecs.regex.Regex.replaceAll
