local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local assets <const> = require("tecs_assets")
local LoadingScreenPlugin <const> = require("loading")
local GameplayPlugin <const> = require("gameplay")

function love.run(): function(): string | number
    return tecs2d.run(1 / 60, function(world: tecs.World)
        world:addPlugin(assets.plugin({root = "assets"}))
        world:addPlugin(LoadingScreenPlugin.plugin())
        world:addPlugin(GameplayPlugin.plugin())
    end)
end