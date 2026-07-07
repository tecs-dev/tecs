--- Screen-layer fixture: layer 1 is world space, layer 2 is screen space.
--- The camera is offset to (260, 120) so world coordinates and raw screen
--- coordinates disagree by 100 px in x, making a screen-phase ghost of
--- world content land at a distinct, probeable position.
---
--- Content:
---   - A green CPU Draw-phase rectangle at world (110..150, 40..80) on
---     layer 1. With the camera at (260, 120) it appears at screen
---     (10..50, 40..80). A double render in the screen phase (camera at
---     origin, so screen = world + half window) would ghost it at screen
---     (270..310, 160..200).
---   - A blue GPU rectangle on screen layer 2 at screen (280, 40).

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
    pipeline:getCamera():setPosition(260, 120)
    -- The layer must be named: the pipeline derives _firstScreenLayer
    -- (and therefore the screen render phase) from named layers only.
    pipeline:configureLayer(2, {name = "hud", space = "screen"})

    -- Screen-layer GPU content: blue square pinned to screen coordinates.
    world:spawn(
        Transform(280, 40, 0, 2) as tecs.Component,
        gfx.Rectangle(40, 40) as tecs.Component,
        gfx.Color(0, 0, 1, 1) as tecs.Component
    )

    -- World-layer CPU Draw-phase content: green square in world space.
    world:addSystem({
        name = "test.WorldDraw",
        phase = tecs.phases.Draw,
        run = function()
            pipeline:worldShader():at(1, 0, 130, 80):attach()
            love.graphics.setColor(0, 1, 0, 1)
            love.graphics.rectangle("fill", 110, 40, 40, 40)
            pipeline:detachWorldShader()
            love.graphics.setColor(1, 1, 1, 1)
        end,
    })
end

love.run = tecs2d.run({
    fps = 60,
    game = gamePlugin,
    render = {
        virtualHeight = HEIGHT,
        lightingMode = "none",
    },
})
