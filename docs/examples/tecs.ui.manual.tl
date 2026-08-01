-- #region tecs.ui.plugin
--[=[
Installs UI with explicit dependencies in a test or manually constructed world.
]=]
local tecs <const> = require("tecs")
local type Renderer = require("tecs.Renderer")
local type inputTypes = require("tecs.input")

local function installManualUi(
    world: tecs.World,
    renderer: Renderer,
    input: inputTypes.Input
)
    world:addPlugin(tecs.ui.plugin({
        renderer = renderer,
        input = input,
        firstClip = 32,
        lastClip = 63,
    }))
end
-- #endregion tecs.ui.plugin
