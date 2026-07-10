--[[
    Material System Demo

    Demonstrates GPU-batched material shaders on multiple shape types.
    Materials inject custom fragment and vertex functions into shape render
    shaders, staying fully GPU-batched with deferred lighting support.

    Controls:
    - WASD: Move camera
    - +/-: Zoom in/out
    - SPACE: Toggle dissolve direction
    - ESC: Quit
]]

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local mcp <const> = require("tecs2d.mcp")
local Transform <const> = tecs.builtins.Transform

local VIRTUAL_HEIGHT <const> = 360
local HUD_LAYER <const> = 4
local CAMERA_SPEED <const> = 400

-- Register materials (happens at load time, before world is created)
local lavaMat <const> = gfx.newMaterial("lava", {
    fragment = "shaders/lava.glsl",
})

local iceMat <const> = gfx.newMaterial("ice", {
    fragment = "shaders/ice.glsl",
})

local dissolveMat <const> = gfx.newMaterial("dissolve", {
    fragment = "shaders/dissolve.glsl",
})

local windMat <const> = gfx.newMaterial("wind_sway", {
    vertex = "shaders/wind_sway.glsl",
})

local record DemoState
    pipeline: gfx.Pipeline
    dissolveEntities: {integer}
    dissolveThreshold: number
    dissolveDirection: number
end

local STATE_KEY <const> = tecs.newKey() as tecs.Key<DemoState>

local function demoPlugin(world: tecs.World)
    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline

    world:addPlugin(require("tecs2d.debug").new())
    world:addPlugin(mcp.new())

    local state: DemoState = {
        pipeline = pipeline,
        dissolveEntities = {},
        dissolveThreshold = 0.0,
        dissolveDirection = 1,
    }
    world.resources[STATE_KEY] = state

    local Text <const> = gfx.Text
    local FONT_PATH <const> = "assets/press-start-2p.fnt"
    local goldColor <const> = gfx.Color(0.95, 0.65, 0.25, 1)

    -- HUD text
    world:spawn(
        Transform(5, VIRTUAL_HEIGHT - 30, 0, HUD_LAYER),
        Text(FONT_PATH, "WASD: Move | +/-: Zoom | SPACE: Toggle dissolve | ESC: Quit", 0.25),
        goldColor, gfx.Pivot(0, 0)
    )

    -- Row 1: Lava material on rectangles (GPU-batched, with emission)
    for i = 0, 9 do
        world:spawn(
            Transform(100 + i * 60, 80, 0, 2),
            gfx.Rectangle(50, 50),
            gfx.Color(1, 1, 1, 1),
            lavaMat:withParams(0.5 + i * 0.1, 1.0 + i * 0.3, 0, 0)
        )
    end

    -- Row 2: Ice material on circles
    for i = 0, 9 do
        world:spawn(
            Transform(100 + i * 60, 180, 0, 2),
            gfx.Circle(25),
            gfx.Color(0.8, 0.9, 1.0, 1),
            iceMat:withParams(0.2 + i * 0.08, 0, 0, 0)
        )
    end

    -- Row 3: Dissolve material on rectangles (animated threshold)
    for i = 0, 9 do
        local e = world:spawn(
            Transform(100 + i * 60, 280, 0, 2),
            gfx.Rectangle(50, 50),
            gfx.Color(0.2, 0.8, 0.3, 1),
            dissolveMat:withParams(0, 0.05, 0, 0)
        )
        state.dissolveEntities[#state.dissolveEntities + 1] = e
    end

    -- Row 4: Dissolve material on sprites (animated threshold)
    for i = 0, 9 do
        local e = world:spawn(
            Transform(100 + i * 60, 380, 0, 2),
            gfx.Sprite.fromAseprite("assets/running.png", "run"),
            gfx.Color(1, 1, 1, 1),
            dissolveMat:withParams(0, 0.05, 0, 0)
        )
        state.dissolveEntities[#state.dissolveEntities + 1] = e
    end

    -- Row 5: Lava material on sprites
    for i = 0, 9 do
        world:spawn(
            Transform(100 + i * 60, 480, 0, 2),
            gfx.Sprite.fromAseprite("assets/running.png", "run"),
            lavaMat:withParams(0.5 + i * 0.1, 1.0 + i * 0.3, 0, 0)
        )
    end

    -- Row 6: Wind sway on sprites (vertex displacement)
    for i = 0, 9 do
        world:spawn(
            Transform(100 + i * 60, 580, 0, 2),
            gfx.Sprite.fromAseprite("assets/running.png", "run"),
            gfx.Color(1, 1, 1, 1),
            windMat:withParams(4.0 + i * 1.5, 0.8 + i * 0.15, 0, 0)
        )
    end

    -- Row 7: Wind sway on shapes (vertex displacement on rectangles and circles)
    for i = 0, 9 do
        if i % 2 == 0 then
            world:spawn(
                Transform(100 + i * 60, 680, 0, 2),
                gfx.Rectangle(50, 50),
                gfx.Color(0.4, 0.8, 0.3, 1),
                windMat:withParams(6.0 + i * 1.0, 1.0 + i * 0.1, 0, 0)
            )
        else
            world:spawn(
                Transform(100 + i * 60, 680, 0, 2),
                gfx.Circle(25),
                gfx.Color(0.3, 0.7, 0.4, 1),
                windMat:withParams(6.0 + i * 1.0, 1.0 + i * 0.1, 0, 0)
            )
        end
    end

    -- Row 8: Mixed shapes without materials (default rendering, no regression)
    for i = 0, 4 do
        world:spawn(
            Transform(100 + i * 120, 780, 0, 2),
            gfx.Rectangle(50, 50),
            gfx.Color(0.6, 0.4, 0.8, 1)
        )
        world:spawn(
            Transform(160 + i * 120, 780, 0, 2),
            gfx.Circle(25),
            gfx.Color(0.4, 0.8, 0.6, 1)
        )
    end

    -- Add a light to show deferred lighting integration
    world:spawn(
        Transform(320, 200, 0, 3),
        gfx.Light.new({
            radius = 600,
            intensity = 2.0,
            height = 0.4,
            r = 1.0, g = 0.95, b = 0.85,
        })
    )

    local input = require("tecs2d.input")

    -- Input system
    world:addSystem({
        name = "Input",
        phase = tecs.phases.FixedUpdate,
        run = function(dt: number)
            local s = world.resources[STATE_KEY]
            if not s then return end
            local p = s.pipeline
            local cam = p:getCamera()

            if input.isKeyDown("d") then cam:nudge(CAMERA_SPEED * dt, 0) end
            if input.isKeyDown("a") then cam:nudge(-CAMERA_SPEED * dt, 0) end
            if input.isKeyDown("s") then cam:nudge(0, CAMERA_SPEED * dt) end
            if input.isKeyDown("w") then cam:nudge(0, -CAMERA_SPEED * dt) end

            if input.isKeyDown("=") or input.isKeyDown("+") then
                cam:setZoom(math.min(cam:getZoom() * 1.05, 10))
            elseif input.isKeyDown("-") then
                cam:setZoom(math.max(cam:getZoom() * 0.95, 0.1))
            end

            -- Toggle dissolve animation direction
            if input.isKeyReleased("space") then
                s.dissolveDirection = -s.dissolveDirection
            end

        end
    })

    -- Dissolve animation system
    world:addSystem({
        name = "DissolveAnimation",
        phase = tecs.phases.Update,
        run = function(dt: number)
            local s = world.resources[STATE_KEY]
            if not s then return end

            s.dissolveThreshold = s.dissolveThreshold + dt * 0.8 * s.dissolveDirection
            if s.dissolveThreshold > 1.0 then
                s.dissolveThreshold = 1.0
                s.dissolveDirection = -1
            elseif s.dissolveThreshold < 0.0 then
                s.dissolveThreshold = 0.0
                s.dissolveDirection = 1
            end

            for _, entityId in ipairs(s.dissolveEntities) do
                local mat = world:get(entityId, gfx.Material)
                if mat then
                    mat.p0 = s.dissolveThreshold
                end
            end
        end
    })
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = function(world: tecs.World)
        world:addPlugin(demoPlugin)
    end,
    render = {
        virtualHeight = VIRTUAL_HEIGHT,
        lightingMode = "deferred",
        ambientLight = {0.3, 0.3, 0.35},
        cameraPosition = {320, 380},
        zoom = 1.0,
        layers = {
            [1] = { name = "background" },
            [2] = { name = "shapes" },
            [3] = { name = "lights" },
            [HUD_LAYER] = { name = "hud", space = "virtual", unlit = true },
        },
    },
})
