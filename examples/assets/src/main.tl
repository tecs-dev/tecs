local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local LoadingScreenPlugin <const> = require("loading")
local GameplayPlugin <const> = require("gameplay")

love.run = tecs2d.run({
    fps = 60,
    game = function(world: tecs.World)
        world:addPlugin(LoadingScreenPlugin.plugin())
        world:addPlugin(GameplayPlugin.plugin())
    end,
})