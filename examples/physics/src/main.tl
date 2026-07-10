-- Box2D Physics Example
-- Same demo as physics example, but using LÖVE's Box2D bindings

local tecs = require("tecs")
local tecs2d = require("tecs2d")
local gfx = require("tecs2d.gfx")
local mcp <const> = require("tecs2d.mcp")

local physics = require("tecs2d.physics")
local input <const> = require("tecs2d.input")

local common = require("scenes.common")
local momentumScene = require("scenes.momentum")
local shapesScene = require("scenes.shapes")
local filteringScene = require("scenes.filtering")
local bounceScene = require("scenes.bounce")

local lg = love.graphics
local lp = love.physics

local Transform = tecs.builtins.Transform
local Collider = physics.Collider
local RigidBody = physics.RigidBody

local WINDOW_WIDTH, WINDOW_HEIGHT = 1024, 768
local BALL_COOLDOWN = 0.075

local record Scene
    name: string
    setup: function(world: tecs.World, spawn: function(tecs.World, tecs.Component...): integer, WINDOW_WIDTH: number, WINDOW_HEIGHT: number)
end

local scenes: {Scene} = {}
local currentSceneIndex = 1
local sceneEntities: {integer} = {}
local world: tecs.World

local DEFAULT_GRAVITY_Y = 300

local function setGravity(gx: number, gy: number)
    local physicsState = world.resources[physics]
    if physicsState and physicsState.world then
        physicsState.world:setGravity(gx, gy)
    end
end

local function getGravity(): number, number
    local physicsState = world.resources[physics]
    if physicsState and physicsState.world then
        return physicsState.world:getGravity()
    end
    return 0, DEFAULT_GRAVITY_Y
end

local function clearScene()
    for _, entityId in ipairs(sceneEntities) do
        if world:isAlive(entityId) then
            -- The Collider's onRemove hook handles body:destroy().
            world:despawn(entityId)
        end
    end
    world:commit()
    sceneEntities = {}

    setGravity(0, DEFAULT_GRAVITY_Y)
end

local function spawn(w: tecs.World, ...: tecs.Component): integer
    local id = w:spawn(...)
    sceneEntities[#sceneEntities + 1] = id
    return id
end

local function resetScene()
    clearScene()
    scenes[currentSceneIndex].setup(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT)
end

local function box2dExamplePlugin(w: tecs.World)
    world = w

    lg.setBackgroundColor(0.1, 0.1, 0.12)


    -- Add Box2D physics plugin
    lp.setMeter(64)
    world:addPlugin(physics.new({
        world = lp.newWorld(0, 300, true),
    }))

    -- Add MCP for debugging
    world:addPlugin(mcp.new())

    -- Add stats display
    world:addPlugin(require("tecs2d.debug").new())

    -- Add physics debug renderer (toggle with F2)
    world:addPlugin(gfx.physicsDebug.new())

    -- Define scenes
    scenes = {
        momentumScene as Scene,
        shapesScene as Scene,
        filteringScene as Scene,
        bounceScene as Scene,
    }

    -- Setup initial scene
    scenes[currentSceneIndex].setup(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT)

    -- Input handling system
    local spawnCooldown = 0.0
    world:addSystem({
        name = "HandleInput",
        phase = tecs.phases.Update,
        run = function(dt: number)
            spawnCooldown = math.max(0, spawnCooldown - dt)
            if input.isKeyPressed("right") then
                clearScene()
                currentSceneIndex = currentSceneIndex % #scenes + 1
                scenes[currentSceneIndex].setup(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT)
            elseif input.isKeyPressed("left") then
                clearScene()
                currentSceneIndex = (currentSceneIndex - 2) % #scenes + 1
                scenes[currentSceneIndex].setup(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT)
            end

            if input.isKeyPressed("r") then
                resetScene()
            end

            -- Adjust gravity
            if input.isKeyPressed("=") or input.isKeyPressed("kp+") then
                local gx, gy = getGravity()
                setGravity(gx, gy + 50)
            elseif input.isKeyPressed("-") or input.isKeyPressed("kp-") then
                local gx, gy = getGravity()
                setGravity(gx, gy - 50)
            end

            -- Toggle debug draw
            if input.isKeyPressed("f2") then
                local physicsState = world.resources[physics]
                if physicsState then
                    physicsState.debug = not physicsState.debug
                end
            end

            if input.isMouseDown(1) and spawnCooldown <= 0 then
                spawnCooldown = BALL_COOLDOWN
                local mx, my = input.mouseX, input.mouseY

                local centerX = WINDOW_WIDTH / 2
                local centerY = WINDOW_HEIGHT / 2
                local dx = mx - centerX
                local dy = my - centerY
                local len = math.sqrt(dx * dx + dy * dy)
                if len > 0 then
                    dx = dx / len
                    dy = dy / len
                end

                local speed = 600
                local id = world:spawn(
                    Transform(centerX, centerY),
                    Collider.new({ shape = "circle", radius = 15 }),
                    RigidBody.new({ mass = 2, restitution = 0.9, drag = 0.01, vx = dx * speed, vy = dy * speed }),
                    gfx.Circle(15),
                    gfx.Color(1, 0.8, 0.2)
                )
                sceneEntities[#sceneEntities + 1] = id
            end

        end,
    })

    -- Scene header/footer text
    world:addSystem({
        name = "DrawSceneText",
        phase = tecs.phases.PostRender,
        run = function()
            common.renderText(WINDOW_WIDTH, WINDOW_HEIGHT)
        end,
    })

    -- Scene indicator
    local indicatorFont = lg.newFont(22)
    world:addSystem({
        name = "DrawSceneIndicator",
        phase = tecs.phases.PostRender,
        run = function()
            lg.setColor(0.95, 0.65, 0.25)
            lg.setFont(indicatorFont)
            local text = string.format("< %d/%d: %s (Box2D) >", currentSceneIndex, #scenes, scenes[currentSceneIndex].name)
            lg.printf(text, 0, WINDOW_HEIGHT - 30, WINDOW_WIDTH, "center")
            lg.setColor(1, 1, 1)
        end,
    })

    -- Click hint
    local hintFont = lg.newFont(14)
    world:addSystem({
        name = "DrawClickHint",
        phase = tecs.phases.PostRender,
        run = function()
            lg.setColor(0.5, 0.5, 0.5)
            lg.setFont(hintFont)
            lg.printf("Click to launch projectile  |  F2 for debug", 0, 10, WINDOW_WIDTH, "right")
            lg.setColor(1, 1, 1)
        end,
    })
end


love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = box2dExamplePlugin,
    render = {
        virtualHeight = WINDOW_HEIGHT,
        pixelMode = false,
        lightingMode = "none",
        cameraPosition = { WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2 },
        layers = {
            [1] = { name = "default" },
        },
    },
})
