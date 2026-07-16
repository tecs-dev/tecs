local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local mcp <const> = require("tecs2d.mcp")
local lg <const> = love.graphics

local Text <const> = gfx.Text
local FONT_PATH <const> = "assets/press-start-2p.fnt"
local VIRTUAL_HEIGHT <const> = 600
local HUD_LAYER <const> = 5

-- Enable MCP for debugging

-- Configuration
local CAMERA_SPEED <const> = 300

-- Create a particle image programmatically
local function createParticleImage(): love.graphics.Image
    local size = 32
    local imageData = love.image.newImageData(size, size)

    -- Draw a radial gradient circle
    local centerX, centerY = size / 2, size / 2
    local radius = size / 2

    for x = 0, size - 1 do
        for y = 0, size - 1 do
            local dx = x - centerX
            local dy = y - centerY
            local dist = math.sqrt(dx * dx + dy * dy)

            if dist <= radius then
                -- Smooth gradient from center to edge
                local alpha = 1 - (dist / radius)
                alpha = alpha * alpha -- Quadratic falloff for smoother look
                imageData:setPixel(x, y, 1, 1, 1, alpha)
            else
                imageData:setPixel(x, y, 0, 0, 0, 0)
            end
        end
    end

    local image = lg.newImage(imageData) as love.graphics.Image
    -- Try setting the image to not use premultiplied alpha
    -- This might help with color blending
    return image
end

local record AppState
    pipeline: gfx.Pipeline
    emitterEntity: integer
    emitterX: number
    emitterY: number
    positionText: integer
end

local STATE_KEY <const> = tecs.newKey("state") as tecs.Key<AppState>
local Transform <const> = tecs.builtins.Transform
local ParticleEmitter <const> = gfx.ParticleEmitter

local function particlesPlugin(world: tecs.World)
    -- Add plugins
    world:addPlugin(mcp.new())
    world:addPlugin(require("tecs2d.debug").new())

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline

    -- Create particle image
    local particleImage = createParticleImage()

    -- Create particle system
    local particleSystem = lg.newParticleSystem(particleImage, 1000)

    -- Configure particle system
    particleSystem:setParticleLifetime(2, 4)  -- Longer lifetime so particles stay visible
    particleSystem:setEmissionRate(200)  -- More particles per second
    particleSystem:setEmissionArea("normal", 20, 20)
    particleSystem:setSizeVariation(1)
    particleSystem:setLinearAcceleration(-20, -20, 20, 20)  -- Less acceleration so particles stay closer
    -- Use very bright, solid colors - no alpha transparency
    particleSystem:setColors(
        1, 1, 0, 1,      -- Pure bright yellow
        1, 0.5, 0, 1,    -- Pure bright orange
        1, 0, 0, 1,      -- Pure red
        0.5, 0, 0, 0     -- Dark red fade
    )
    particleSystem:setSizes(1.0, 2.0, 1.5)  -- Larger particles
    particleSystem:setSpeed(30, 100)  -- Slower speed so particles don't fly away
    particleSystem:setSpread(math.pi * 2)

    -- Set insert mode to 'top' for proper rendering
    particleSystem:setInsertMode("top")

    -- Set the position before starting
    particleSystem:setPosition(0, 0)

    particleSystem:start()

    -- Create emitter entity at world center (0, 0 in world coordinates)
    local startX, startY = 0, 0
    local emitterEntity = world:spawn(
        Transform(startX, startY, 1),
        ParticleEmitter(particleSystem),
        gfx.Unlit
    )

    -- HUD text entities
    local goldColor <const> = gfx.Color(0.95, 0.65, 0.25, 1)
    world:spawn(
        Transform(20, 20, 0, HUD_LAYER),
        Text(FONT_PATH, "Arrow Keys: Move Emitter", 0.5),
        goldColor, gfx.Pivot(0, 0)
    )
    world:spawn(
        Transform(20, 32, 0, HUD_LAYER),
        Text(FONT_PATH, "ESC: Quit", 0.5),
        goldColor, gfx.Pivot(0, 0)
    )
    local positionText = world:spawn(
        Transform(20, 44, 0, HUD_LAYER),
        Text(FONT_PATH, string.format("Position: (%.0f, %.0f)", startX, startY), 0.5),
        goldColor, gfx.Pivot(0, 0)
    )

    -- Store state
    local state: AppState = {
        pipeline = pipeline,
        emitterEntity = emitterEntity,
        emitterX = startX,
        emitterY = startY,
        positionText = positionText
    }

    pipeline:getCamera():setPosition(startX, startY)
    world.resources[STATE_KEY] = state

    -- Movement query
    local emitterQuery = world:query({
        name = "EmitterQuery",
        include = {Transform, ParticleEmitter}
    })

    -- Movement system
    world:addSystem({
        name = "EmitterMovement",
        phase = tecs.phases.Update,
        run = function(dt: number)
            local input = require("tecs2d.input")
            local s = world.resources[STATE_KEY]

            -- Move emitter with arrow keys
            local dx, dy = 0.0, 0.0
            if input.isKeyDown("left") then dx = -1 end
            if input.isKeyDown("right") then dx = 1 end
            if input.isKeyDown("up") then dy = -1 end
            if input.isKeyDown("down") then dy = 1 end

            if dx ~= 0 or dy ~= 0 then
                s.emitterX = s.emitterX + dx * CAMERA_SPEED * dt
                s.emitterY = s.emitterY + dy * CAMERA_SPEED * dt
                -- Update emitter transform directly in query
                for archetype, len in emitterQuery:iter() do
                    local transforms = archetype:getMut(Transform)
                    for i = 1, len do
                        transforms[i].x = s.emitterX
                        transforms[i].y = s.emitterY
                    end
                end
            end

        end
    })

    -- Background rendering
    world:addSystem({
        name = "RenderBackground",
        phase = tecs.phases.Render,
        run = function()
            lg.clear(0.05, 0.05, 0.1, 1)
        end
    })

    -- HUD text update
    world:addSystem({
        name = "UpdateHUD",
        phase = tecs.phases.Update,
        run = function()
            local s = world.resources[STATE_KEY]
            if not s then return end

            local posText = world:get(s.positionText, Text)
            if posText then
                posText:setText(string.format("Position: (%.0f, %.0f)", s.emitterX, s.emitterY))
            end
        end
    })
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = function(world: tecs.World)
        world:addPlugin(particlesPlugin)
    end,
    render = {
        virtualHeight = VIRTUAL_HEIGHT,
        pixelMode = false,
        lightingMode = "none",
        lerpingEnabled = false,
        layers = {
            [HUD_LAYER] = { name = "hud", space = "virtual" },
        },
    },
})
