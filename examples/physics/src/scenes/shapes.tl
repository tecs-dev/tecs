-- Shapes scene (Box2D version)

local tecs = require("tecs")
local gfx = require("tecs2d.gfx")

local physics = require("tecs2d.physics")

local common = require("scenes.common")

local Transform = tecs.builtins.Transform
local Collider = physics.Collider
local RigidBody = physics.RigidBody
local StaticBody = physics.StaticBody

local record shapes
    name: string
    setup: function(world: tecs.World, spawn: function(tecs.World, tecs.Component...): integer, WINDOW_WIDTH: number, WINDOW_HEIGHT: number)
end

shapes.name = "Shapes"

function shapes.setup(
    world: tecs.World,
    spawn: function(tecs.World, tecs.Component...): integer,
    WINDOW_WIDTH: number,
    WINDOW_HEIGHT: number
)
    common.header(world, spawn, WINDOW_WIDTH, "Collision Shapes", "Circles and AABBs colliding")
    common.footer(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT, "Both shape types interact correctly", "Press R to reset")

    local centerX = WINDOW_WIDTH / 2
    local centerY = WINDOW_HEIGHT / 2

    -- Spawn circles
    for i = 1, 8 do
        local x = 150 + (i - 1) * 90
        local y = 200 + math.random() * 50
        local radius = 20 + math.random() * 15

        spawn(world,
            Transform(x, y),
            Collider.new({ shape = "circle", radius = radius }),
            RigidBody.new({ mass = 1, restitution = 0.7, drag = 0.01 }),
            gfx.Circle(radius),
            gfx.Color(0.3, 0.6, 0.9)
        )
    end

    -- Spawn rectangles
    for i = 1, 6 do
        local x = 200 + (i - 1) * 110
        local y = 350 + math.random() * 50
        local w = 40 + math.random() * 30
        local h = 30 + math.random() * 25

        spawn(world,
            Transform(x, y),
            Collider.new({ shape = "rectangle", width = w, height = h }),
            RigidBody.new({ mass = 1.5, restitution = 0.5, drag = 0.01 }),
            gfx.Rectangle(w, h),
            gfx.Color(0.9, 0.5, 0.3)
        )
    end

    -- Static platform in the middle
    spawn(world,
        Transform(centerX, centerY + 50),
        Collider.new({ shape = "rectangle", width = 200, height = 20 }),
        StaticBody(),
        gfx.Rectangle(200, 20),
        gfx.Color(0.4, 0.4, 0.45)
    )

    common.walls(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT)
end

return shapes
