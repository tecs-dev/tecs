package.path = package.path .. ";./vendor/share/lua/5.1/?.lua;./vendor/share/lua/5.1/?/init.lua"
package.cpath = package.cpath .. ";./vendor/lib/lua/5.1/?.so"

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local mcp <const> = require("tecs2d.mcp")
local debugPlugin <const> = require("tecs2d.debug")

local Transform <const> = tecs.builtins.Transform
local FONT <const> = "tecs2d/assets/fonts/tiny-font.fnt"
local VIRTUAL_WIDTH <const> = 480
local VIRTUAL_HEIGHT <const> = 360

local function gamePlugin(world: tecs.World)
    -- Adds a debug console and an integrated MCP tools to your game.
    -- Turn these off in production builds.
    world:addPlugin(mcp.new())
    world:addPlugin(debugPlugin.new())

    -- Spawn entities on startup
    world:addSystem({
        name = "SpawnHello",
        phase = tecs.phases.Startup,
        run = function()
            -- Background
            world:spawn(
                Transform(VIRTUAL_WIDTH / 2, VIRTUAL_HEIGHT / 2, 0, 1),
                gfx.Rectangle(VIRTUAL_WIDTH, VIRTUAL_HEIGHT),
                gfx.Color(0.08, 0.09, 0.12, 1),
                gfx.Pivot(0.5, 0.5)
            )

            -- Greeting text
            world:spawn(
                Transform(VIRTUAL_WIDTH / 2, VIRTUAL_HEIGHT / 2, 0, 2),
                gfx.Text(FONT, "HELLO TECS2D!", 4),
                gfx.Color(0.9, 0.96, 1.0, 1),
                gfx.Pivot(0.5, 0.5)
            )
        end,
    })
end

-- Setup the Love2D game.
love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = gamePlugin,
    render = {
        virtualHeight = VIRTUAL_HEIGHT,
        lightingMode = "none",
        layers = {
            [1] = {name = "background", space = "virtual"},
            [2] = {name = "content", space = "virtual"},
        },
    },
})
