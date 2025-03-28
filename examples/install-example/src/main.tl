-- Simple Tecs install example demonstrating vendor directory usage

-- Add vendor modules to Lua path
local function addVendorPath(path: string)
    package.path = path .. "/share/lua/5.1/?.lua;" ..
                   path .. "/share/lua/5.1/?/init.lua;" .. package.path
    package.cpath = path .. "/lib/lua/5.1/?.so;" .. package.cpath
end

-- Add vendor directory to search paths. Path relative to build/ directory where Love2D runs from.
addVendorPath("../src/vendor")

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local render <const> = require("tecs_render")

local type Camera = render.Camera

-------------------------------------------------------------------------------
-- Demo constants
-------------------------------------------------------------------------------

local IMAGE_NAME, IMAGE_WIDTH, IMAGE_HEIGHT = "assets/sumox.png", 48, 48

-- Game constants
local CAMERA_WIDTH <const> = 800
local CAMERA_HEIGHT <const> = 400

-- Lighting constants
local AMBIENT_LIGHT_R <const> = 0.3
local AMBIENT_LIGHT_G <const> = 0.3
local AMBIENT_LIGHT_B <const> = 0.3

-- Entity constants
local SPRITE_COUNT <const> = 50
local SPRITE_SPEED_MIN <const> = -80
local SPRITE_SPEED_MAX <const> = 80
local LIGHT_RADIUS <const> = 100
local LIGHT_SPAWN_INTERVAL <const> = 10
local LIGHT_SPEED_MULTIPLIER <const> = 2

-- Spawn constants
local SPAWN_RANDOM_RANGE <const> = 30
local SPRITE_DISTRIBUTION_DIVISOR <const> = 10

-- Frame rate
local TARGET_FPS <const> = 60

-------------------------------------------------------------------------------
-- Demo components
-------------------------------------------------------------------------------

-- Simple component types
local record Position is tecs.Component
    x: number
    y: number
end

tecs.newFFIComponent({
    name = "Position",
    container = Position,
    fields = {
        {"x", "float"},
        {"y", "float"}
    }
})

local record Velocity is tecs.Component
    dx: number
    dy: number
end

tecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {
        {"dx", "float"},
        {"dy", "float"}
    }
})

local record LightCircle is tecs.Component
    radius: number
end

tecs.newFFIComponent({
    name = "LightCircle",
    container = LightCircle,
    fields = {
        {"radius", "float"}
    }
})

-------------------------------------------------------------------------------
-- Demo code
-------------------------------------------------------------------------------

-- Spawn entities based on camera visible area
local function spawnEntities(world: tecs.World, camera: Camera)
    -- Compute visible dimensions from camera
    local visibleWidth = CAMERA_WIDTH / camera:getZoom()
    local visibleHeight = CAMERA_HEIGHT / camera:getZoom()

    for i = 1, SPRITE_COUNT do
        -- Spread sprites more evenly across the visible area
        local x = (i - 1) * (visibleWidth / SPRITE_DISTRIBUTION_DIVISOR) + math.random(0, SPAWN_RANDOM_RANGE)
        local y = math.random(IMAGE_HEIGHT, visibleHeight as integer - IMAGE_HEIGHT)
        local dx = math.random(SPRITE_SPEED_MIN, SPRITE_SPEED_MAX)
        local dy = math.random(SPRITE_SPEED_MIN, SPRITE_SPEED_MAX)
        world:spawn(Position(x, y), Velocity(dx, dy))

        -- Spawn lights periodically
        if i % LIGHT_SPAWN_INTERVAL == 0 then
            world:spawn(
                Position(x, y),
                Velocity(dx * LIGHT_SPEED_MULTIPLIER, dy * LIGHT_SPEED_MULTIPLIER),
                LightCircle(LIGHT_RADIUS)
            )
        end
    end
end

local function gamePlugin(world: tecs.World)
    local playerImage = love.graphics.newImage(IMAGE_NAME)
    -- Set pixel-perfect filtering for crisp pixel art
    (playerImage as love.graphics.Texture):setFilter("nearest", "nearest")

    -- Create simple camera without stretch aspect ratio
    local camera = render.newCamera({
        minWidth = 800,
        maxWidth = 800,
        height = 400,
        oversample = 2,
        scaleMode = "pixel"
    })

    camera:setZoom(2)
    camera:setClamp(true)
    camera:setPosition(0, 0)

    -- Create render pipeline (automatically registers with world)
    local pipeline = render.newPipeline({
        world = world,
        camera = camera
    })

    -- Add debug plugin for stats (toggle with F1, archetypes with F2)
    world:addPlugin(tecs2d.stats.newStatsPlugin())
    pipeline:nameLayer(1, "ground")
    pipeline:nameLayer(2, "entities")
    pipeline:setAmbientLight(AMBIENT_LIGHT_R, AMBIENT_LIGHT_G, AMBIENT_LIGHT_B)

    -- Spawn entities using dedicated function
    spawnEntities(world, camera)

    local spriteQuery = world:query({
        include = {Position, Velocity},
        exclude = {LightCircle}}
    )
    local lightQuery = world:query({
        include = {Position, Velocity, LightCircle}
    })

    -- Movement system
    world:addSystem({
        name = "Movement",
        phase = tecs.phases.Update,
        run = function(dt: number)
            -- Move sprites
            for archetype, length in spriteQuery() do
                local positions = archetype[Position]
                local velocities = archetype[Velocity]
                for i = 1, length do
                    local pos = positions[i]
                    local vel = velocities[i]
                    pos.x = pos.x + vel.dx * dt
                    pos.y = pos.y + vel.dy * dt
                    -- Bounce off edges (match clamped camera bounds)
                    local visibleWidth = CAMERA_WIDTH / camera:getZoom()
                    local visibleHeight = CAMERA_HEIGHT / camera:getZoom()

                    if pos.x < 0 or pos.x > visibleWidth - IMAGE_WIDTH then
                        vel.dx = -vel.dx
                        pos.x = math.max(0, math.min(visibleWidth - IMAGE_WIDTH, pos.x))
                    end
                    if pos.y < 0 or pos.y > visibleHeight - IMAGE_HEIGHT then
                        vel.dy = -vel.dy
                        pos.y = math.max(0, math.min(visibleHeight - IMAGE_HEIGHT, pos.y))
                    end
                end
            end

            -- Move light circles
            for archetype, length in lightQuery() do
                local positions = archetype[Position]
                local velocities = archetype[Velocity]
                for i = 1, length do
                    local pos = positions[i]
                    local vel = velocities[i]
                    pos.x = pos.x + vel.dx * dt
                    pos.y = pos.y + vel.dy * dt
                    -- Bounce off edges (match clamped camera bounds)
                    local visibleWidth = CAMERA_WIDTH / camera:getZoom()
                    local visibleHeight = CAMERA_HEIGHT / camera:getZoom()

                    if pos.x < 0 or pos.x > visibleWidth - IMAGE_WIDTH then
                        vel.dx = -vel.dx
                        pos.x = math.max(0, math.min(visibleWidth - IMAGE_WIDTH, pos.x))
                    end
                    if pos.y < 0 or pos.y > visibleHeight - IMAGE_HEIGHT then
                        vel.dy = -vel.dy
                        pos.y = math.max(0, math.min(visibleHeight - IMAGE_HEIGHT, pos.y))
                    end
                end
            end
        end
    })

    world:addSystem({
        name = "Render",
        phase = tecs.phases.Render,
        run = function()
            local entityCount = 0
            local visibleCount = 0

            -- Draw sprites
            for archetype, length in spriteQuery() do
                local positions = archetype[Position]
                for i = 1, length do
                    entityCount = entityCount + 1
                    local pos = positions[i]
                    -- Round positions to prevent pixel warping during movement
                    local roundX = math.floor(pos.x + 0.5)
                    local roundY = math.floor(pos.y + 0.5)
                    local drawResult = pipeline:draw("entities", roundX, roundY, IMAGE_WIDTH, IMAGE_HEIGHT, function()
                        love.graphics.setColor(1, 1, 1, 1)
                        love.graphics.draw(playerImage as love.graphics.Drawable, roundX, roundY)
                    end)
                    if drawResult > 0 then
                        visibleCount = visibleCount + 1
                    end
                end
            end

            -- Draw light circles
            for archetype, length in lightQuery() do
                local positions = archetype[Position]
                local lightCircles = archetype[LightCircle]
                for i = 1, length do
                    local pos = positions[i]
                    local light = lightCircles[i]
                    local roundX = math.floor(pos.x + 0.5)
                    local roundY = math.floor(pos.y + 0.5)
                    -- Draw light on same layer as sprites so it can illuminate them
                    pipeline:drawLight("entities", roundX, roundY, light.radius, light.radius, function()
                        love.graphics.setColor(1, 1, 0, 1)  -- Bright yellow light
                        love.graphics.circle("fill", roundX + light.radius/2, roundY + light.radius/2, light.radius/2)
                    end)
                end
            end

            -- Draw UI information (absolute positioning, outside camera)
            pipeline:drawAbsolute(function()
                love.graphics.setColor(1, 1, 1, 0.8)
                love.graphics.print("Tecs Install Example - ESC to quit, F1 for debug", 10, CAMERA_HEIGHT - 20)
            end)
        end
    })

    world:addSystem({
        name = "Input",
        phase = tecs.phases.Update,
        run = function()
            if tecs2d.input.isKeyPressed("escape") then
                tecs2d.quit(0)
            end
        end
    })
end

-------------------------------------------------------------------------------
-- Register demo with Love2D
-------------------------------------------------------------------------------

function love.run(): function(): string | number
    return tecs2d.run(1 / TARGET_FPS, gamePlugin)
end