local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")

local pool <const> = tecs.pool
local Transform <const> = tecs.builtins.Transform
local love_draw <const> = love.graphics.draw
local love_setTitle <const> = love.window.setTitle
local random <const> = love.math.random
local min <const> = math.min
local floor <const> = math.floor

-- Force enable LuaJIT if available
tecs.enableJit()

-- How often to update the window title in seconds
local WINDOW_TITLE_UPDATE_DELAY <const> = 0.5
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
    },
    recycle = true
})

local record Sprite is tecs.Component
    image: love.graphics.Image
end

-- Create a sprite component that also pools the table used to carry sprite data
tecs.newComponent({
    name = "Sprite",
    container = Sprite,
    constructor = function(image: love.graphics.Image): Sprite
        local tbl: Sprite = pool.acquireMap(1)
        tbl.image = image
        return tbl
    end,
    onRemove = pool.releaseMap
})

local record BallBenchPlugin
    world: tecs.World
    entityCount: integer
    testSprite: love.graphics.Image
    maxEntities: integer
    drawSprites: boolean
    spawnedCount: integer

    init: function(self, world: tecs.World)
    createTestSprite: function(self): love.graphics.Image
end

function BallBenchPlugin.new(maxEntities: integer, drawSprites: boolean): BallBenchPlugin
    local self = setmetatable({
        entityCount = 0,
        maxEntities = maxEntities or 50000,
        drawSprites = drawSprites,
        spawnedCount = 0,
        testSprite = nil as love.graphics.Image
    }, {__index = BallBenchPlugin}) as BallBenchPlugin

    self.testSprite = self:createTestSprite()
    return self
end

function BallBenchPlugin:createTestSprite(): love.graphics.Image
    love.graphics.push("all")
    local canvas = love.graphics.newCanvas(16, 16)
    love.graphics.setCanvas(canvas)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.circle("fill", 8, 8, 6)
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.circle("line", 8, 8, 6)
    love.graphics.circle("line", 10, 8, 1)
    love.graphics.pop()

    return love.graphics.newImage(canvas:newImageData())
end

function BallBenchPlugin:init(world: tecs.World)
    self.world = world
    local input = tecs2d.input
    local lastWindowUpdate = 0.0
    local stats: tecs.Stats = {}

    local movementQuery <const> = world:query({
        name = "move",
        include = {Velocity, Transform}
    })

    world:addSystem({
        phase = tecs.phases.FixedUpdate,
        run = function(dt: number)
            if input.isKeyReleased("escape") then
                tecs2d.quit(0)
                return
            end

            lastWindowUpdate = lastWindowUpdate - dt
            if lastWindowUpdate <= 0 then
                lastWindowUpdate = WINDOW_TITLE_UPDATE_DELAY
                world:getStats(stats)
                self.entityCount = stats.entities
                local title = string.format(
                    "Entities: %d | FPS: %d | Memory: %d MB",
                    self.entityCount,
                    floor(love.timer.getFPS()) as integer,
                    floor(collectgarbage('count') / 1024) as integer
                )
                love_setTitle(title)
            end

            -- Spawn entities in batches to avoid segfaults
            if self.spawnedCount < self.maxEntities then
                local toSpawn = min(SPAWN_BATCH_SIZE, self.maxEntities - self.spawnedCount)
                for _ = 1, toSpawn do
                    world:spawn(
                        Velocity(random(10, 30), random(10, 30)),
                        Transform(0, 0),
                        Sprite(self.testSprite)
                    )
                    self.spawnedCount = self.spawnedCount + 1
                end
            end

            -- Move entities and reset when out of bounds
            for archetype, len in movementQuery() do
                local transforms = archetype[Transform]
                local velocities = archetype[Velocity]
                for i = 1, len do
                    local transform, velocity = transforms[i], velocities[i]
                    transform.x = transform.x + (velocity.x * dt)
                    transform.y = transform.y + (velocity.y * dt)
                    -- Reset position and velocity when out of bounds
                    if transform.x > 640 or transform.y > 480 or transform.x < -50 or transform.y < -50 then
                        transform.x, transform.y = 0, 0
                    end
                end
            end
        end
    })

    if self.drawSprites then
        local renderQuery <const> = world:query({
            name = "draw",
            include = {Transform, Sprite}
        })

        world:addSystem({
            phase = tecs.phases.Render,
            run = function(_dt: number)
                for archetype, len in renderQuery() do
                    local transforms = archetype[Transform]
                    local sprites = archetype[Sprite]
                    for i = 1, len do
                        local transform = transforms[i]
                        local sprite = sprites[i]
                        if sprite and sprite.image then
                            love_draw(sprite.image as love.graphics.Drawable, transform.x, transform.y)
                        end
                    end
                end
            end
        })
    end
end

function love.run(): function(): string | number
    local maxEntities = 50000
    local drawSprites = true

    -- Parse command line arguments
    if arg then
        for i, v in ipairs(arg) do
            -- Find where our actual arguments start (after the dot)
            if v == "." and arg[i + 1] then
                maxEntities = tonumber(arg[i + 1]) as integer or 50000
                drawSprites = arg[i + 2] ~= "false"
                break
            end
        end
    end

    return tecs2d.run(1 / 60, function(world: tecs.World)
        local plugin = BallBenchPlugin.new(maxEntities, drawSprites)
        plugin:init(world)
    end)
end