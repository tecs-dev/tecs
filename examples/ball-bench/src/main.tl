local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local SpriteSheet <const> = gfx.SpriteSheet
local mcp <const> = require("tecs2d.mcp")
local stats <const> = require("tecs2d.stats")

local Transform <const> = tecs.builtins.Transform
local random <const> = love.math.random
local min <const> = math.min

local SPAWN_BATCH_SIZE <const> = 100

local record Velocity is tecs.Component
    x: number
    y: number
end

-- Create FFI storage for Velocity
tecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {
        {"x", "float"},
        {"y", "float"}
    }
})

-- Create a ball sprite texture
local function createBallTexture(): love.graphics.Texture
    love.graphics.push("all")
    local canvas = love.graphics.newCanvas(16, 16)
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.circle("fill", 8, 8, 6)
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.circle("line", 8, 8, 6)
    love.graphics.circle("fill", 10, 6, 1.5)  -- Eye
    love.graphics.pop()
    return love.graphics.newImage(love.graphics.readbackTexture(canvas) as love.image.ImageData) as love.graphics.Texture
end

-- Get spawn count from command line args or use default
local function getSpawnCount(): integer
    local args = love.arg.parseGameArguments(arg)
    if args[1] then
        local count = tonumber(args[1])
        if count and count > 0 then
            return count as integer
        end
    end
    return 50000
end

local SPAWN_COUNT <const> = getSpawnCount()

local function ballBenchPlugin(world: tecs.World)
    local maxEntities = SPAWN_COUNT
    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline

    -- Position camera so (0,0) is at top-left
    pipeline:getCamera():setPosition(320, 240)

    world:addPlugin(stats.newStatsPlugin())

    -- Create ball sprite sheet once and reuse for all sprites
    local ballTexture = createBallTexture()
    local ballSheet = SpriteSheet.fromTexture(ballTexture)

    local spawnedCount = 0

    -- Movement query
    local movementQuery <const> = world:query({
        name = "move",
        include = {Velocity, Transform}
    })

    -- Spawn system (runs first, commits before Move)
    -- We use Update instead of FixedUpdate to match https://github.com/Keyslam/love-ecs-benchmarks
    world:addSystem({
        name = "Spawn",
        phase = tecs.phases.Update,
        run = function()
            if spawnedCount < maxEntities then
                local toSpawn = min(SPAWN_BATCH_SIZE, maxEntities - spawnedCount)
                world:batchSpawn(toSpawn,
                    {Velocity as tecs.Component, Transform as tecs.Component, gfx.Sprite as tecs.Component},
                    function(arch: tecs.Archetype, startRow: integer, lastRow: integer, _batchCount: integer)
                        for i = startRow, lastRow do
                            arch:set(i, Velocity(random(10, 30), random(10, 30)))
                            arch:set(i, Transform(0, 0, 0, 1))
                            arch:set(i, gfx.Sprite.fromSheet(ballSheet))
                        end
                    end)
                spawnedCount = spawnedCount + toSpawn
            end
        end
    })

    -- Move system (sees entities spawned by Spawn system)
    world:addSystem({
        name = "Move",
        phase = tecs.phases.Update,
        run = function(dt: number)
            for archetype, len in movementQuery:iter() do
                local transforms = archetype:getMut(Transform)
                local velocities = archetype:get(Velocity)
                for i = 1, len do
                    local transform, velocity = transforms[i], velocities[i]
                    transform.x = transform.x + (velocity.x * dt)
                    transform.y = transform.y + (velocity.y * dt)
                    if transform.x > 656 or transform.y > 496 or transform.x < -16 or transform.y < -16 then
                        transform.x, transform.y = 0, 0
                    end
                end
            end
        end
    })
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = function(world: tecs.World)
        world:addPlugin(mcp.new())
        world:addPlugin(ballBenchPlugin)
    end,
    render = {
        virtualHeight = 480,
        lightingMode = "none",
        sizeHints = { sprites = SPAWN_COUNT + 1000 },
    },
})
