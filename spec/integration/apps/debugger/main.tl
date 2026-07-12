--- Debugger fixture: an empty deferred-lit scene with the debug plugin
--- (overlay + stats HUD) plus the MCP server. Backs the overlay toggle,
--- freeze, and cmd_context suite.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local mcp <const> = require("tecs2d.mcp")
local gfx <const> = require("tecs2d.gfx")
local physics <const> = require("tecs2d.physics")

local WIDTH <const> = 320
local HEIGHT <const> = 240

local function gamePlugin(world: tecs.World)
    world:addPlugin(mcp.new({
        port = tonumber(os.getenv("TECS_MCP_PORT")) or mcp.DEFAULT_PORT,
    }))
    world:addPlugin(require("tecs2d.debug").new())
    -- Physics (empty world, no gravity) so the debugger's physics verbs have
    -- a live plugin to talk to.
    world:addPlugin(physics.new({world = love.physics.newWorld(0, 0)}))

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    pipeline:getCamera():setPosition(WIDTH / 2, HEIGHT / 2)
end

love.run = tecs2d.run({
    fps = 60,
    game = gamePlugin,
    render = {
        virtualHeight = HEIGHT,
        lightingMode = "deferred",
        ambientLight = {1.0, 1.0, 1.0},
        lerpingEnabled = false,
    },
})
