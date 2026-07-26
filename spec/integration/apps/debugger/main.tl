--- Debugger fixture: an empty deferred-lit scene with the debug plugin
--- (overlay + stats HUD) plus the MCP server. Backs the overlay toggle,
--- freeze, and cmd_context suite.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs")
local mcp <const> = require("tecs.mcp")
local gfx <const> = require("tecs.gfx")
local physics <const> = require("tecs.physics")

local WIDTH <const> = 320
local HEIGHT <const> = 240

-- Capabilities the lovespecs need beyond the run_lua sandbox (the debug
-- subtree is require-blocked there). The sandbox reads through to game
-- globals by design, so the app hands these out deliberately; agent-facing
-- games never define them.
local globals <const> = _G as {string: any}
globals.tecsTestHooks = {
    commands = require("tecs.debug.commands"),
    debugdraw = require("tecs.debug.internal.debugdraw"),
    toolworld = require("tecs.debug.internal.toolworld"),
}

local function gamePlugin(world: tecs.World)
    world:addPlugin(mcp.new({
        port = tonumber(os.getenv("TECS_MCP_PORT")) or mcp.DEFAULT_PORT,
    }))
    world:addPlugin(require("tecs.debug").new({uiHeight = HEIGHT}))
    -- Physics (empty world, no gravity) so the debugger's physics verbs have
    -- a live plugin to talk to.
    world:addPlugin(physics.new({world = love.physics.newWorld(0, 0)}))

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    pipeline:getCamera():setPosition(WIDTH / 2, HEIGHT / 2)
end

love.run = tecs.run({
    fps = 60,
    game = gamePlugin,
    render = {
        virtualHeight = HEIGHT,
        lightingMode = "deferred",
        ambientLight = {1.0, 1.0, 1.0},
        lerpingEnabled = false,
    },
})
