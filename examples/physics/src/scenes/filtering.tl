-- Collision filtering scene (Box2D version)

local tecs = require("tecs")
local gfx = require("tecs2d.gfx")

local physics = require("tecs2d.physics")

local common = require("scenes.common")

local Transform = tecs.builtins.Transform
local Collider = physics.Collider
local RigidBody = physics.RigidBody

local record filtering
    name: string
    setup: function(world: tecs.World, spawn: function(tecs.World, tecs.Component...): integer, WINDOW_WIDTH: number, WINDOW_HEIGHT: number)
end

filtering.name = "Collision Filtering"

function filtering.setup(
    world: tecs.World,
    spawn: function(tecs.World, tecs.Component...): integer,
    WINDOW_WIDTH: number,
    WINDOW_HEIGHT: number
)
    common.header(world, spawn, WINDOW_WIDTH, "Collision Filtering", "Same-colored balls pass through each other")
    common.footer(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT, "Red group: -1 (never collide), Blue group: -2 (never collide)", "Different colors DO collide!")

    local centerX = WINDOW_WIDTH / 2
    local centerY = WINDOW_HEIGHT / 2

    -- Red group (groupIndex = -1, won't collide with each other)
    for i = 1, 5 do
        local x = 200 + (i - 1) * 60
        local y = centerY - 80 + math.random() * 40 - 20

        spawn(world,
            Transform(x, y),
            Collider.new({
                shape = "circle",
                radius = 25,
                groupIndex = -1,
            }),
            RigidBody.new({ mass = 1, restitution = 0.8, drag = 0.01 }),
            gfx.Circle(25),
            gfx.Color(0.9, 0.3, 0.3)
        )
    end

    -- Blue group (groupIndex = -2, won't collide with each other)
    for i = 1, 5 do
        local x = WINDOW_WIDTH - 200 - (i - 1) * 60
        local y = centerY + 80 + math.random() * 40 - 20

        spawn(world,
            Transform(x, y),
            Collider.new({
                shape = "circle",
                radius = 25,
                groupIndex = -2,
            }),
            RigidBody.new({ mass = 1, restitution = 0.8, drag = 0.01 }),
            gfx.Circle(25),
            gfx.Color(0.3, 0.3, 0.9)
        )
    end

    -- Green balls (groupIndex = 0, collide with everything)
    for i = 1, 3 do
        local x = centerX + (i - 2) * 80
        local y = centerY + math.random() * 40 - 20

        spawn(world,
            Transform(x, y),
            Collider.new({
                shape = "circle",
                radius = 30,
                groupIndex = 0,
            }),
            RigidBody.new({ mass = 1.5, restitution = 0.6, drag = 0.01 }),
            gfx.Circle(30),
            gfx.Color(0.3, 0.9, 0.3)
        )
    end

    common.walls(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT)
end

return filtering
