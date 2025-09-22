-- Momentum transfer scene (Box2D version)

local tecs = require("tecs")
local gfx = require("tecs2d.gfx")

local physics = require("tecs2d.physics")

local common = require("scenes.common")

local Transform = tecs.builtins.Transform
local Collider = physics.Collider
local RigidBody = physics.RigidBody

local record momentum
    name: string
    setup: function(world: tecs.World, spawn: function(tecs.World, tecs.Component...): integer, WINDOW_WIDTH: number, WINDOW_HEIGHT: number)
end

momentum.name = "Momentum Transfer"

function momentum.setup(
    world: tecs.World,
    spawn: function(tecs.World, tecs.Component...): integer,
    WINDOW_WIDTH: number,
    WINDOW_HEIGHT: number
)
    common.header(world, spawn, WINDOW_WIDTH, "Momentum Transfer", "Heavy ball transfers momentum to light balls")
    common.footer(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT, "Mass affects collision response", "Press R to reset")

    local centerX = WINDOW_WIDTH / 2
    local centerY = WINDOW_HEIGHT / 2

    -- Spawn many small balls in a grid
    local cols = 15
    local rows = 10
    local spacing = 35
    local startX = centerX - (cols - 1) * spacing / 2
    local startY = centerY - (rows - 1) * spacing / 2

    for row = 1, rows do
        for col = 1, cols do
            local x = startX + (col - 1) * spacing
            local y = startY + (row - 1) * spacing
            local radius = 12 + math.random() * 4

            spawn(world,
                Transform(x, y),
                Collider.new({ shape = "circle", radius = radius }),
                RigidBody.new({ mass = 0.5, restitution = 0.8, drag = 0.02 }),
                gfx.Circle(radius),
                gfx.Color(0.4 + math.random() * 0.3, 0.5 + math.random() * 0.3, 0.7 + math.random() * 0.2)
            )
        end
    end

    -- Heavy ball on the left
    spawn(world,
        Transform(100, centerY),
        Collider.new({ shape = "circle", radius = 40 }),
        RigidBody.new({ mass = 10, restitution = 0.95, drag = 0.005, vx = 400, vy = 0 }),
        gfx.Circle(40),
        gfx.Color(0.9, 0.3, 0.2)
    )

    common.walls(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT)
end

return momentum
