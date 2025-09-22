-- Animation Collision Example
-- Demonstrates slice-based collision boxes from Aseprite sprites

local tecs = require("tecs")
local tecs2d = require("tecs2d")
local gfx = require("tecs2d.gfx")
local SpriteSheet <const> = require("tecs2d.gfx.internal.sprite.sheet").SpriteSheet
local sprite_collision <const> = require("tecs2d.gfx.internal.sprite.collision")
local mcp <const> = require("tecs2d.mcp")

local physics = require("tecs2d.physics")
local stats = require("tecs2d.stats")
local input <const> = require("tecs2d.input")

local lg = love.graphics

local Transform = tecs.builtins.Transform
local Collider = physics.Collider
local StaticBody = physics.StaticBody
local Text <const> = gfx.Text

local FONT_PATH <const> = "assets/press-start-2p.fnt"
local HUD_LAYER <const> = 5

local WINDOW_WIDTH, WINDOW_HEIGHT = 800, 600

local function examplePlugin(w: tecs.World)
    lg.setBackgroundColor(0.15, 0.15, 0.2)

    -- Add Box2D physics
    local lp = love.physics
    lp.setMeter(64)
    local physicsWorld = lp.newWorld(0, 1800, true)  -- Higher gravity for snappier feel

    w:addPlugin(physics.new({ world = physicsWorld }))

    -- Add MCP for debugging
    w:addPlugin(mcp.new())

    -- Add stats display
    w:addPlugin(stats.newStatsPlugin())

    -- Add physics debug renderer (toggle with F2)
    w:addPlugin(gfx.physicsDebug.new())

    -- Register collision templates
    sprite_collision.addTemplate("PLAYER", {
        shape = "circle",
        restitution = 0.0,
        friction = 0.0
    })

    -- Load sprite sheet
    local sheet = SpriteSheet.fromFile("assets/running.png")

    -- Spawn player with animated sprite and slice-based collision
    local playerId = w:spawn(
        Transform(200, 100),
        gfx.Sprite.fromSheet(sheet, "run", { speed = 1.0 }),
        gfx.SpriteCollision.new({
            bodyType = "dynamic",
            slices = {
                collision = "PLAYER"
            }
        })
    )

    -- Spawn some static obstacles at varying heights in a staircase pattern
    local obstacleColor = gfx.Color(0.4, 0.5, 0.6)
    local heights = { 500, 450, 400, 350, 300 }
    for i = 1, 5 do
        local x = 100 + (i - 1) * 150
        w:spawn(
            Transform(x, heights[i]),
            Collider.new({ shape = "rectangle", width = 60, height = 30, restitution = 0, friction = 1 }),
            StaticBody(),
            gfx.Rectangle(60, 30),
            obstacleColor
        )
    end

    -- Floor
    w:spawn(
        Transform(WINDOW_WIDTH / 2, WINDOW_HEIGHT - 20),
        Collider.new({ shape = "rectangle", width = WINDOW_WIDTH, height = 40, restitution = 0, friction = 1 }),
        StaticBody(),
        gfx.Rectangle(WINDOW_WIDTH, 40),
        gfx.Color(0.3, 0.35, 0.4)
    )

    -- Walls (no friction so player doesn't stick)
    w:spawn(
        Transform(10, WINDOW_HEIGHT / 2),
        Collider.new({ shape = "rectangle", width = 20, height = WINDOW_HEIGHT, restitution = 0, friction = 0 }),
        StaticBody(),
        gfx.Rectangle(20, WINDOW_HEIGHT),
        gfx.Color(0.3, 0.35, 0.4)
    )
    w:spawn(
        Transform(WINDOW_WIDTH - 10, WINDOW_HEIGHT / 2),
        Collider.new({ shape = "rectangle", width = 20, height = WINDOW_HEIGHT, restitution = 0, friction = 0 }),
        StaticBody(),
        gfx.Rectangle(20, WINDOW_HEIGHT),
        gfx.Color(0.3, 0.35, 0.4)
    )

    -- Ceiling
    w:spawn(
        Transform(WINDOW_WIDTH / 2, 20),
        Collider.new({ shape = "rectangle", width = WINDOW_WIDTH, height = 40, restitution = 0, friction = 0 }),
        StaticBody(),
        gfx.Rectangle(WINDOW_WIDTH, 40),
        gfx.Color(0.3, 0.35, 0.4)
    )

    -- Track ground contacts by entity ID
    -- BeginContact decides IF it's ground (normalY > 0.5)
    -- EndContact just removes the entity - normal direction at separation is irrelevant
    local groundContactEntities: {integer:boolean} = {}
    local lastGroundedTime = 0.0
    local COYOTE_TIME <const> = 0.15
    local hasJumped = false

    local function countGroundContacts(): integer
        local count = 0
        for _ in pairs(groundContactEntities) do
            count = count + 1
        end
        return count
    end

    w:observe(playerId, physics.BeginContact, function(e: physics.BeginContact)
        if e.normalY > 0.5 then
            groundContactEntities[e.other] = true
            lastGroundedTime = love.timer.getTime()
        end
    end)
    w:observe(playerId, physics.EndContact, function(e: physics.EndContact)
        groundContactEntities[e.other] = nil
    end)

    -- Player movement system - arcade style
    local MOVE_SPEED <const> = 300
    local JUMP_VELOCITY <const> = 700
    local MAX_FALL_SPEED <const> = 600

    w:addSystem({
        name = "PlayerInput",
        phase = tecs.phases.Update,
        run = function(_dt: number)
            if not w:isAlive(playerId) then return end

            local c = w:get(playerId, Collider)
            if not c or not c.body then return end

            local body = c.body
            local getLinearVelocity = body.getLinearVelocity as function(any): number, number
            local setLinearVelocity = body.setLinearVelocity as function(any, number, number)
            local _, vy = getLinearVelocity(body)

            -- Horizontal movement
            local targetVx = 0
            if input.isKeyDown("left") or input.isKeyDown("a") then
                targetVx = -MOVE_SPEED
            elseif input.isKeyDown("right") or input.isKeyDown("d") then
                targetVx = MOVE_SPEED
            end

            -- Ground state
            local isGrounded = countGroundContacts() > 0
            local now = love.timer.getTime()

            -- Reset jump flag ONLY when grounded
            if isGrounded then
                hasJumped = false
                lastGroundedTime = now
            end

            -- Clamp fall speed
            if vy > MAX_FALL_SPEED then
                vy = MAX_FALL_SPEED
            end

            -- Jump with coyote time
            local timeSinceGrounded = now - lastGroundedTime
            local canJump = not hasJumped and (isGrounded or timeSinceGrounded < COYOTE_TIME)

            if input.isKeyPressed("space") or input.isKeyPressed("up") or input.isKeyPressed("w") then
                if canJump then
                    setLinearVelocity(body, targetVx, -JUMP_VELOCITY)
                    hasJumped = true
                    lastGroundedTime = 0  -- Clear coyote time
                end
            else
                setLinearVelocity(body, targetVx, vy)
            end

            if input.isKeyPressed("f2") then
                local physicsState = w.resources[physics]
                if physicsState then
                    physicsState.debug = not physicsState.debug
                end
            end

            if input.isKeyPressed("escape") then
                love.event.quit()
            end
        end,
    })

    -- HUD text entities
    w:spawn(
        Transform(10, 10, 0, HUD_LAYER),
        Text(FONT_PATH, "Arrow keys / WASD to move, Space to jump, F2 for debug", 0.5),
        gfx.Color(0.7, 0.7, 0.7, 1),
        gfx.Pivot(0, 0)
    )
    w:spawn(
        Transform(10, 22, 0, HUD_LAYER),
        Text(FONT_PATH, "Collision box defined from Aseprite slice", 0.5),
        gfx.Color(0.7, 0.7, 0.7, 1),
        gfx.Pivot(0, 0)
    )
end


love.run = tecs2d.run({
    fps = 60,
    game = examplePlugin,
    render = {
        virtualHeight = WINDOW_HEIGHT,
        pixelMode = false,
        lightingMode = "none",
        cameraPosition = { WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2 },
        layers = {
            [1] = { name = "default" },
            [HUD_LAYER] = { name = "hud", space = "virtual" },
        },
    },
})
