--- Declares the `tecs` global, so a game can write `tecs.ecs.newWorld()` in any
--- file with no require line.
---
--- The type is not restated here; it is read off `tecs/init.tl`, so the global
--- and the module cannot drift. `require("tecs")` sets the global as it
--- returns, so the two are the same table and either spelling works.
---
--- Reach it by naming this module to the type checker:
---
---     tl check --global-env-def tecs.global ...
---
--- or, in a game's `tlconfig.lua`:
---
---     global_env_def = "tecs.global"
local type TecsModule = require("tecs")

--- The `tecs` module, as a global.
---
--- The same table `require("tecs")` returns, metatable included, so the two spellings behave
--- identically. Nil until something has required `tecs`, directly or transitively, which an
--- entry file does before any game code runs.
global tecs: TecsModule
