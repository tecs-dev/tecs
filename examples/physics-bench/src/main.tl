local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local mcp <const> = require("tecs2d.mcp")
local input <const> = require("tecs2d.input")
local floor <const> = require("floor")
local physics <const> = require("tecs2d.physics")

local lp <const> = love.physics

-- Configuration
local INITIAL_TARGET <const> = (tonumber(arg[2]) or 500) as integer
local WORLD_SIZE <const> = math.max(2000, math.floor(math.sqrt(INITIAL_TARGET) * 100))
local NORMAL_ADD <const> = 50
local BULK_ADD <const> = 200
local WALL_THICKNESS <const> = 50
local MOVE_FORCE <const> = 2000

-- Component shortcuts
local Transform <const> = tecs.builtins.Transform
local Collider <const> = physics.Collider
local RigidBody <const> = physics.RigidBody
local StaticBody <const> = physics.StaticBody
local Text <const> = gfx.Text

local FONT_PATH <const> = "assets/press-start-2p.fnt"
local VIRTUAL_HEIGHT <const> = 180
local HUD_LAYER <const> = 3

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local record BenchState
    pipeline: gfx.Pipeline
    targetEntityCount: integer
    currentEntityCount: integer
    playerId: integer
    fullscreen: boolean
    ballsText: integer
end

local STATE_KEY <const> = tecs.newKey() as tecs.Key<BenchState>

-------------------------------------------------------------------------------
-- Plugin
-------------------------------------------------------------------------------

local function physicsBenchPlugin(world: tecs.World)
    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline

    world:addPlugin(require("tecs2d.debug").new())
    world:addPlugin(mcp.new())

    lp.setMeter(64)
    world:addPlugin(physics.new({ world = lp.newWorld(0, 0, true) }))
    world:addPlugin(gfx.physicsDebug.new())

    -- Player
    local playerId = world:spawn(
        Transform(WORLD_SIZE / 2, WORLD_SIZE / 2, 0, 2),
        Collider.new({ shape = "circle", radius = 30 }),
        RigidBody.new({ mass = 5, restitution = 0.8, drag = 2 }),
        gfx.Circle(30),
        gfx.Color(0.9, 0.5, 0.2),
        gfx.CameraTarget.new({})
    )

    -- HUD
    local goldColor <const> = gfx.Color(0.95, 0.65, 0.25, 1)
    local pivot <const> = gfx.Pivot(0, 0)
    world:spawn(
        Transform(5, VIRTUAL_HEIGHT - 36, 0, HUD_LAYER),
        Text(FONT_PATH, "WASD: Move | +/-: Zoom | P: Debug | F: Fullscreen", 0.35),
        goldColor, pivot
    )
    world:spawn(
        Transform(5, VIRTUAL_HEIGHT - 28, 0, HUD_LAYER),
        Text(FONT_PATH, "I: Add " .. NORMAL_ADD .. " | U: Remove " .. NORMAL_ADD .. " (Shift: " .. BULK_ADD .. ")", 0.35),
        goldColor, pivot
    )
    local ballsText = world:spawn(
        Transform(5, VIRTUAL_HEIGHT - 20, 0, HUD_LAYER),
        Text(FONT_PATH, "Balls: 0 / " .. INITIAL_TARGET .. " | World: " .. WORLD_SIZE, 0.35),
        goldColor, pivot
    )

    local state: BenchState = {
        pipeline = pipeline,
        targetEntityCount = INITIAL_TARGET,
        currentEntityCount = 0,
        playerId = playerId,
        fullscreen = false,
        ballsText = ballsText,
    }
    pipeline:getCamera():setPosition(WORLD_SIZE / 2, WORLD_SIZE / 2)
    world.resources[STATE_KEY] = state

    -- Checkered floor
    floor.spawnCheckered(world, {
        worldWidth = WORLD_SIZE,
        worldHeight = WORLD_SIZE,
        tileSize = 400,
        layer = 1
    })

    -- Walls
    local wallColor <const> = gfx.Color(0.3, 0.3, 0.35)
    local hw <const> = WORLD_SIZE / 2
    local wh <const> = WALL_THICKNESS / 2
    world:spawn(Transform(hw, WORLD_SIZE - wh, 0, 2), Collider.new({ shape = "rectangle", width = WORLD_SIZE, height = WALL_THICKNESS }), StaticBody(), gfx.Rectangle(WORLD_SIZE, WALL_THICKNESS), wallColor)
    world:spawn(Transform(hw, wh, 0, 2), Collider.new({ shape = "rectangle", width = WORLD_SIZE, height = WALL_THICKNESS }), StaticBody(), gfx.Rectangle(WORLD_SIZE, WALL_THICKNESS), wallColor)
    world:spawn(Transform(wh, hw, 0, 2), Collider.new({ shape = "rectangle", width = WALL_THICKNESS, height = WORLD_SIZE }), StaticBody(), gfx.Rectangle(WALL_THICKNESS, WORLD_SIZE), wallColor)
    world:spawn(Transform(WORLD_SIZE - wh, hw, 0, 2), Collider.new({ shape = "rectangle", width = WALL_THICKNESS, height = WORLD_SIZE }), StaticBody(), gfx.Rectangle(WALL_THICKNESS, WORLD_SIZE), wallColor)

    -- Spawn initial balls immediately
    world:batchSpawn(INITIAL_TARGET,
        {Transform as tecs.Component, Collider as tecs.Component, RigidBody as tecs.Component, gfx.Circle as tecs.Component, gfx.Color as tecs.Component},
        function(arch: tecs.Archetype, startRow: integer, lastRow: integer, _batchCount: integer)
            for i = startRow, lastRow do
                local radius = math.random(10, 25)
                local margin = WALL_THICKNESS + radius + 10
                arch:set(i, Transform(math.random(margin, WORLD_SIZE - margin), math.random(margin, WORLD_SIZE - margin), 0, 2))
                arch:set(i, Collider.new({ shape = "circle", radius = radius }))
                arch:set(i, RigidBody.new({ mass = radius / 10, restitution = 0.8, drag = 1 }))
                arch:set(i, gfx.Circle(radius))
                arch:set(i, gfx.Color(math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5))
            end
        end)
    state.currentEntityCount = INITIAL_TARGET

    -- Queries
    local ballQuery <const> = world:query({
        include = { Transform, Collider, RigidBody, gfx.Circle },
        exclude = { StaticBody }
    })

    -- Spawn/despawn balls to match target count
    world:addSystem({
        name = "TargetEntityManager",
        phase = tecs.phases.FixedUpdate,
        run = function()
            local s = world.resources[STATE_KEY]
            if not s then return end

            local delta = s.targetEntityCount - s.currentEntityCount

            if delta > 0 then
                world:batchSpawn(delta,
                    {Transform as tecs.Component, Collider as tecs.Component, RigidBody as tecs.Component, gfx.Circle as tecs.Component, gfx.Color as tecs.Component},
                    function(arch: tecs.Archetype, startRow: integer, lastRow: integer, _batchCount: integer)
                        for i = startRow, lastRow do
                            local radius = math.random(10, 25)
                            local margin = WALL_THICKNESS + radius + 10
                            arch:set(i, Transform(math.random(margin, WORLD_SIZE - margin), math.random(margin, WORLD_SIZE - margin), 0, 2))
                            arch:set(i, Collider.new({ shape = "circle", radius = radius }))
                            arch:set(i, RigidBody.new({ mass = radius / 10, restitution = 0.8, drag = 1 }))
                            arch:set(i, gfx.Circle(radius))
                            arch:set(i, gfx.Color(math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5, math.random() * 0.5 + 0.5))
                        end
                    end)
                s.currentEntityCount = s.currentEntityCount + delta
            elseif delta < 0 then
                local toRemove = math.abs(delta)
                local count = 0
                for _, len, entities in ballQuery:iter() do
                    for row = 1, len do
                        local id = entities[row]
                        if id ~= s.playerId then
                            world:despawn(id)
                            s.currentEntityCount = s.currentEntityCount - 1
                            count = count + 1
                            if count >= toRemove then break end
                        end
                    end
                    if count >= toRemove then break end
                end
            end
        end
    })

    -- Player movement
    world:addSystem({
        name = "PlayerInput",
        phase = tecs.phases.FixedUpdate,
        run = function()
            local s = world.resources[STATE_KEY]
            if not s or not world:isAlive(s.playerId) then return end

            local c = world:get(s.playerId, Collider)
            if not c or not c.body then return end

            local fx, fy = 0, 0
            if input.isKeyDown("up") or input.isKeyDown("w") then fy = fy - MOVE_FORCE end
            if input.isKeyDown("down") or input.isKeyDown("s") then fy = fy + MOVE_FORCE end
            if input.isKeyDown("left") or input.isKeyDown("a") then fx = fx - MOVE_FORCE end
            if input.isKeyDown("right") or input.isKeyDown("d") then fx = fx + MOVE_FORCE end

            if fx ~= 0 or fy ~= 0 then
                c.body:applyForce(fx, fy)
            end
        end
    })

    -- Controls
    world:addSystem({
        name = "Controls",
        phase = tecs.phases.FixedUpdate,
        run = function()
            local s = world.resources[STATE_KEY]
            if not s then return end

            if input.isKeyReleased("f") then
                s.fullscreen = not s.fullscreen
                love.window.setFullscreen(s.fullscreen, "desktop")
            elseif input.isKeyReleased("p") then
                world:emit(0, gfx.PhysicsDebugToggle())
            elseif input.isKeyReleased("i") then
                local addCount = input.isKeyDown("lshift") and BULK_ADD or NORMAL_ADD
                s.targetEntityCount = s.targetEntityCount + addCount
            elseif input.isKeyReleased("u") then
                local removeCount = input.isKeyDown("lshift") and BULK_ADD or NORMAL_ADD
                s.targetEntityCount = math.max(0, s.targetEntityCount - removeCount)
            elseif input.isKeyDown("=") or input.isKeyDown("+") then
                local cam = s.pipeline:getCamera()
                cam:setZoom(math.min(cam:getZoom() * 1.1, 10))
            elseif input.isKeyDown("-") then
                local cam = s.pipeline:getCamera()
                cam:setZoom(cam:getZoom() * 0.9)
            end
        end
    })

    -- HUD update
    world:addSystem({
        name = "UpdateHUD",
        phase = tecs.phases.Update,
        run = function()
            local s = world.resources[STATE_KEY]
            if not s then return end

            local bt = world:get(s.ballsText, Text)
            if bt then
                bt:setText("Balls: " .. s.currentEntityCount .. " / " .. s.targetEntityCount .. " | World: " .. WORLD_SIZE)
            end
        end
    })
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = function(world: tecs.World)
        world:addPlugin(physicsBenchPlugin)
    end,
    render = {
        virtualHeight = VIRTUAL_HEIGHT,
        lightingMode = "none",
        lerpingEnabled = true,
        lerpSpeed = 8,
        ambientLight = {1, 1, 1},
        zoom = 0.3,
        layers = {
            [1] = { name = "ground" },
            [2] = { name = "entities" },
            [HUD_LAYER] = { name = "hud", space = "virtual" },
        },
    },
})
