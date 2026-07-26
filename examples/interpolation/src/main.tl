--- GPU Transform interpolation demo.
---
--- Rendering runs at 60 Hz while the simulation advances at 5 Hz. The
--- sprite and rectangle receive identical Transform samples in FixedUpdate:
--- the sprite uses GPU ping-pong interpolation, while the rectangle shows
--- the unsmoothed authoritative samples.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")

local lg <const> = love.graphics
local pi <const> = math.pi

local Transform <const> = tecs.builtins.Transform

local FIXED_HZ <const> = 5
local FIXED_STEP <const> = 1 / FIXED_HZ
local SAMPLE_DISTANCE <const> = 72
local LIMIT <const> = 252
local TOP_Y <const> = -62
local BOTTOM_Y <const> = 72

local function interpolationDemo(world: tecs.World)
    -- This example deliberately separates simulation frequency from render
    -- frequency so the interpolation is easy to see.
    local worldInternal = world as {string:any}
    local fixedPipeline = worldInternal.pipeline as {string:any}
    fixedPipeline.fixedTimestep = FIXED_STEP

    local sheet = gfx.SpriteSheet.fromFile("assets/running.png")

    -- Static tracks make the shared position of the two moving entities
    -- obvious. Shapes currently use the raw Transform path.
    world:spawn(
        Transform(0, TOP_Y, 0, 1),
        gfx.Rectangle(560, 2),
        gfx.Color(0.18, 0.25, 0.36, 1)
    )
    world:spawn(
        Transform(0, BOTTOM_Y, 0, 1),
        gfx.Rectangle(560, 2),
        gfx.Color(0.18, 0.25, 0.36, 1)
    )

    local spriteId = world:spawn(
        Transform(-LIMIT, TOP_Y, 0, 2, 0, 1.8, 1.8),
        gfx.Sprite.fromSheet(sheet, "run", {centered = true}),
        gfx.Color(1, 1, 1, 1)
    )
    local sampleId = world:spawn(
        Transform(-LIMIT, BOTTOM_Y, 0, 2),
        gfx.Rectangle(42, 28),
        gfx.Color(0.2, 0.85, 1, 1)
    )

    local position = -LIMIT
    local direction = 1
    local rotation: number = 0

    world:addSystem({
        name = "interpolation.AdvanceFixedSamples",
        phase = tecs.phases.FixedUpdate,
        run = function()
            position = position + SAMPLE_DISTANCE * direction
            if position >= LIMIT then
                position = LIMIT
                direction = -1
            elseif position <= -LIMIT then
                position = -LIMIT
                direction = 1
            end
            rotation = rotation + pi / 3

            local spriteTransform = world:getMut(spriteId, Transform)
            spriteTransform.x = position
            spriteTransform.rotation = rotation

            local sampleTransform = world:getMut(sampleId, Transform)
            sampleTransform.x = position
            sampleTransform.rotation = rotation
        end,
    })

    local titleFont = lg.newFont(24)
    local labelFont = lg.newFont(16)
    world:addSystem({
        name = "interpolation.Labels",
        phase = tecs.phases.Render,
        run = function()
            lg.reset()
            lg.setDepthMode()

            local width = lg.getWidth()
            lg.setFont(titleFont)
            lg.setColor(0.95, 0.97, 1, 1)
            local title = "GPU TRANSFORM PING-PONG"
            lg.print(title, (width - titleFont:getWidth(title)) / 2, 28)

            lg.setFont(labelFont)
            lg.setColor(0.65, 0.75, 0.9, 1)
            local timing = "5 Hz fixed simulation  |  60 Hz rendering"
            lg.print(timing, (width - labelFont:getWidth(timing)) / 2, 62)

            lg.setColor(0.8, 1, 0.85, 1)
            lg.print("GPU-interpolated sprite", 28, 150)
            lg.setColor(0.4, 0.9, 1, 1)
            lg.print("Raw fixed samples (comparison)", 28, 348)

            lg.setColor(0.55, 0.6, 0.7, 1)
            lg.print(
                "Both receive the same Transform writes in FixedUpdate",
                28,
                lg.getHeight() - 42
            )
        end,
    })
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = interpolationDemo,
    render = {
        virtualHeight = 360,
        lightingMode = "none",
        cameraPosition = {0, 0},
        lerpingEnabled = false,
        layers = {
            [1] = {name = "tracks"},
            [2] = {name = "movers"},
        },
    },
})
