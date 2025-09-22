--- Tecs "circles" example.
--- Spawns bouncing circles. Press F1 for FPS/memory overlay.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local stats <const> = require("tecs2d.stats")
local input <const> = require("tecs2d.input")

local Transform <const> = tecs.builtins.Transform
local random <const> = math.random

local SCREEN_WIDTH, SCREEN_HEIGHT, CIRCLE_RADIUS <const> = 640, 480, 5

-- Grab circle count from arg 1, default to 100K.
local CIRCLE_COUNT <const> = (function(): integer
    local args = love.arg.parseGameArguments(arg)
    if args[1] then
        local count = tonumber(args[1])
        if count and count > 0 then
            return count as integer
        end
    end
    return 500
end)()

-------------------------------------------------------------------------------
-- Create an FFI velocity component
-------------------------------------------------------------------------------

local record Velocity is tecs.Component
    x: number
    y: number
end

tecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {
        {"x", "float"},
        {"y", "float"}
    }
})

-------------------------------------------------------------------------------
-- Game code
-------------------------------------------------------------------------------

local function circlesPlugin(world: tecs.World)
    world:addPlugin(stats.newStatsPlugin()) -- so we can see FPS, memory, etc

    -- Setup the deferred rendering pipeline and camera.
    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    pipeline:getCamera():setPosition(SCREEN_WIDTH / 2, SCREEN_HEIGHT / 2)

    world:batchSpawn(CIRCLE_COUNT,
        {Transform as tecs.Component, Velocity as tecs.Component, gfx.Circle as tecs.Component},
        function(arch: tecs.Archetype, startRow: integer, lastRow: integer, batchCount: integer)
            local transforms = arch:getMut(Transform)
            local velocities = arch:getMut(Velocity)
            local circles = arch:getMut(gfx.Circle) as {gfx.Circle}
            for i = startRow, lastRow do
                local t = transforms[i]
                t.x = random() * SCREEN_WIDTH
                t.y = random() * SCREEN_HEIGHT
                t.layer = 1
                t.scaleX = 1
                t.scaleY = 1
                local v = velocities[i]
                v.x = random(-100, 100)
                v.y = random(-100, 100)
                circles[i].radius = CIRCLE_RADIUS
            end
        end)

    -- Reusable query for moving entities. The system below writes
    -- Transform and Velocity in-place via direct FFI writes; calling
    -- `archetype:getMut(Foo)` inside the loop marks the component
    -- dirty on the archetype so renderer shadow buffers re-upload only the
    -- columns that actually changed.
    local movementQuery <const> = world:query({
        name = "Move",
        include = {Transform, Velocity},
    })

    -- Move entities each frame, bouncing off the edges of the screen.
    world:addSystem({name = "Move", phase = tecs.phases.Update, run = function(dt: number)
        for archetype, len in movementQuery:iter() do
            local transforms = archetype:getMut(Transform)
            local velocities = archetype:getMut(Velocity)
            for i = 1, len do
                local t, v = transforms[i], velocities[i]
                local px = t.x + v.x * dt
                local py = t.y + v.y * dt
                local vx, vy = v.x, v.y

                if px < 0 and vx < 0 then
                    vx = -vx
                elseif px > SCREEN_WIDTH and vx > 0 then
                    vx = -vx
                end

                if py < 0 and vy < 0 then
                    vy = -vy
                elseif py > SCREEN_HEIGHT and vy > 0 then
                    vy = -vy
                end

                t.x, t.y = px, py
                v.x, v.y = vx, vy
            end
        end
    end})

    -- Listen for escape to quit.
    world:addSystem({name = "HandleInput", phase = tecs.phases.First, run = function()
        if input.isKeyPressed("escape") then
            love.event.quit()
            print(love.timer.getFPS() .. " FPS, " .. collectgarbage("count") / 1024 .. " MB")
        end
    end})
end

-------------------------------------------------------------------------------
-- Tecs Love2D setup
-------------------------------------------------------------------------------

love.run = tecs2d.run({
    fps = 60,
    game = circlesPlugin,
    render = {
        virtualHeight = SCREEN_HEIGHT,
        lightingMode = "none",
    }
})
