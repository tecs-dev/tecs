--- Lighting fixture: a white surface under deferred lighting with a very
--- low ambient level, so light entities produce unambiguous pixel-probe
--- differences (dark without a light, bright with one). Driven by the
--- love2d integration suite over the tecs2d MCP HTTP server.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local mcp <const> = require("tecs2d.mcp")
local gfx <const> = require("tecs2d.gfx")

local Transform <const> = tecs.builtins.Transform

local WIDTH <const> = 320
local HEIGHT <const> = 240

local function gamePlugin(world: tecs.World)
    world:addPlugin(mcp.new({
        port = tonumber(os.getenv("TECS_MCP_PORT")) or mcp.DEFAULT_PORT,
    }))

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    pipeline:getCamera():setPosition(WIDTH / 2, HEIGHT / 2)
    pipeline:setAmbientLight(0.02, 0.02, 0.02)

    -- White surface covering most of the view; lights aimed at the
    -- center land on it.
    world:spawn(
        Transform(WIDTH / 2, HEIGHT / 2, 0, 1) as tecs.Component,
        gfx.Rectangle(280, 200) as tecs.Component,
        gfx.Color(1, 1, 1, 1) as tecs.Component
    )
end

love.run = tecs2d.run({
    fps = 60,
    game = gamePlugin,
    render = {
        virtualHeight = HEIGHT,
        lightingMode = "deferred",
    },
})
