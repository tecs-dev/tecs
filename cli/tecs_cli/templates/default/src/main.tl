package.path = package.path .. ";./vendor/share/lua/5.1/?.lua;./vendor/share/lua/5.1/?/init.lua"
package.cpath = package.cpath .. ";./vendor/lib/lua/5.1/?.so"

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local mcp <const> = require("tecs2d.mcp")
local debugPlugin <const> = require("tecs2d.debug")

local lg <const> = love.graphics

local function gamePlugin(world: tecs.World)
    world:addPlugin(mcp.new())
    world:addPlugin(debugPlugin.new())

    local font = lg.newFont(48)

    world:addSystem({
        name = "DrawHello",
        phase = tecs.phases.Render,
        run = function()
            lg.clear(0.08, 0.09, 0.12, 1)
            lg.setFont(font)
            lg.setColor(0.9, 0.96, 1.0, 1)
            lg.printf("Hello Tecs2D!", 0, lg.getHeight() * 0.5 - font:getHeight() * 0.5, lg.getWidth(), "center", 0, 1, 1, 0, 0, 0, 0)
        end
    })
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = gamePlugin,
})
