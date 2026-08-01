-- #region tecs.ui.plugin
--[=[
Installs UI from an application so roots follow its window and input.
]=]
local tecs <const> = require("tecs")

local function gamePlugin(world: tecs.World, app: tecs.Application)
    world:addPlugin(tecs.ui.plugin(
        app,
        {
            wheelStep = 36,
            dragThreshold = 4,
        }
    ))
end
-- #endregion tecs.ui.plugin
