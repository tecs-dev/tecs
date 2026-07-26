--- MCP compliance fixture: a tiny deterministic Love app driven by the
--- love2d integration suite over the tecs2d MCP HTTP server.
---
--- The scene is one red 80x80 rectangle centered in a 320x240 window with
--- lighting disabled, so pixel probes have stable expectations. Test-visible
--- state (frame counter, last key) is exposed through the `tecsTest` global
--- so specs can read it via the run_lua MCP tool.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs")
local mcp <const> = require("tecs.mcp")
local gfx <const> = require("tecs.gfx")
local input <const> = require("tecs.input")

local Transform <const> = tecs.builtins.Transform

local WIDTH <const> = 320
local HEIGHT <const> = 240

local record TestState
    frames: integer
    lastKey: string
    -- Update-phase frames where input.isKeyPressed("up") was true: the
    -- input_tape acceptance probe (taped press must be visible inside the
    -- stepped frame's Update, not before or after).
    upFrames: integer
    -- Same probe from a FixedUpdate-phase system: the latched edge must be
    -- visible to the first fixed tick of the frame.
    upFixedFrames: integer
    -- Update-phase dt accumulator and FixedUpdate tick counter: the
    -- deterministic-step probes (stepped frames must carry 1/fps, or the
    -- cmd_step dt= override, on every machine).
    dtSum: number
    fixedTicks: integer
    -- Crash-handling probe: when set (via run_lua mutating this table),
    -- the next Update frame raises a deliberate error.
    crash: boolean
end

local function gamePlugin(world: tecs.World)
    world:addPlugin(mcp.new({
        port = tonumber(os.getenv("TECS_MCP_PORT")) or mcp.DEFAULT_PORT,
    }))

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    pipeline:getCamera():setPosition(WIDTH / 2, HEIGHT / 2)

    world:spawn(
        Transform(WIDTH / 2, HEIGHT / 2, 0, 1) as tecs.Component,
        gfx.Rectangle(80, 80) as tecs.Component,
        gfx.Color(1, 0, 0, 1) as tecs.Component
    )

    local state: TestState = {frames = 0, lastKey = nil, upFrames = 0,
        upFixedFrames = 0, dtSum = 0, fixedTicks = 0}
    local globals = _G as {string: any}
    globals.tecsTest = state

    world:addSystem({
        name = "test.FrameCounter",
        phase = tecs.phases.Update,
        run = function(dt: number)
            if state.crash then
                error("deliberate test crash")
            end
            state.frames = state.frames + 1
            state.dtSum = state.dtSum + dt
            if input.isKeyPressed("up") then
                state.upFrames = state.upFrames + 1
            end
        end,
    })

    world:addSystem({
        name = "test.FixedInputProbe",
        phase = tecs.phases.FixedUpdate,
        run = function()
            state.fixedTicks = state.fixedTicks + 1
            if input.isKeyPressed("up") then
                state.upFixedFrames = state.upFixedFrames + 1
            end
        end,
    })

    world:observe(0, tecs.KeyPressed, function(e: tecs.KeyPressed)
        state.lastKey = e.key
    end)
end

love.run = tecs.run({
    fps = 60,
    game = gamePlugin,
    render = {
        virtualHeight = HEIGHT,
        lightingMode = "none",
    },
})
