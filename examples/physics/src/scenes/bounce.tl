-- Restitution (bounce) scene (Box2D version)

local tecs = require("tecs")
local gfx = require("tecs2d.gfx")

local physics = require("tecs2d.physics")

local common = require("scenes.common")

local Transform = tecs.builtins.Transform
local Collider = physics.Collider
local RigidBody = physics.RigidBody
local StaticBody = physics.StaticBody

local record bounce
    name: string
    setup: function(world: tecs.World, spawn: function(tecs.World, tecs.Component...): integer, WINDOW_WIDTH: number, WINDOW_HEIGHT: number)
end

bounce.name = "Restitution"

function bounce.setup(
    world: tecs.World,
    spawn: function(tecs.World, tecs.Component...): integer,
    WINDOW_WIDTH: number,
    WINDOW_HEIGHT: number
)
    common.header(world, spawn, WINDOW_WIDTH, "Restitution (Bounciness)", "Left: dead weight (0.0) to Right: super bouncy (1.0)")
    common.footer(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT, "Higher restitution = more energy preserved on collision", "Press R to reset")

    -- Balls with varying restitution
    local numBalls = 7
    local startX = 120
    local spacing = (WINDOW_WIDTH - 240) / (numBalls - 1)

    for i = 1, numBalls do
        local restitution = (i - 1) / (numBalls - 1)
        local x = startX + (i - 1) * spacing
        local y = 200

        local r = 1 - restitution
        local g = restitution
        local b = 0.2

        spawn(world,
            Transform(x, y),
            Collider.new({ shape = "circle", radius = 25 }),
            RigidBody.new({ mass = 1, restitution = restitution, drag = 0.001 }),
            gfx.Circle(25),
            gfx.Color(r, g, b)
        )

        -- Label (rendered in PostRender via common.renderText)
        common.addLabel(x, 150, string.format("%.1f", restitution), 0.7, 0.7, 0.7)
    end

    -- Boxes with varying restitution
    local boxRestitutions = { 0.0, 0.3, 0.6, 1.0 }
    local boxStartX = 200
    local boxSpacing = (WINDOW_WIDTH - 400) / (#boxRestitutions - 1)

    for i, rest in ipairs(boxRestitutions) do
        local x = boxStartX + (i - 1) * boxSpacing
        local y = 450

        local r = 1 - rest
        local g = rest
        local b = 0.3

        spawn(world,
            Transform(x, y),
            Collider.new({ shape = "rectangle", width = 60, height = 40 }),
            RigidBody.new({ mass = 3, restitution = rest, drag = 0.01 }),
            gfx.Rectangle(60, 40),
            gfx.Color(r, g, b)
        )
    end

    -- Static platform
    spawn(world,
        Transform(WINDOW_WIDTH / 2, 350),
        Collider.new({ shape = "rectangle", width = 300, height = 15 }),
        StaticBody(),
        gfx.Rectangle(300, 15),
        gfx.Color(0.4, 0.4, 0.45)
    )

    common.walls(world, spawn, WINDOW_WIDTH, WINDOW_HEIGHT)
end

return bounce
