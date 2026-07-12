local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local mcp <const> = require("tecs2d.mcp")
local LoadingScreenPlugin <const> = require("loading")
local GameplayPlugin <const> = require("gameplay")

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = function(world: tecs.World)
        world:addPlugin(mcp.new())
        world:addPlugin(require("tecs2d.debug").new())

        world:addPlugin(LoadingScreenPlugin.plugin())
        world:addPlugin(GameplayPlugin.plugin())
    end,
})
