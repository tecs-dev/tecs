-- Physics driven from the world.
--
-- The handle round trip is the part worth pinning: a Box2D body id is stored
-- as three integers in an archetype column and rebuilt on every sync. If any
-- field were truncated or reordered the handle would still look plausible and
-- would address the wrong body, or none.

package.path = "build/?.lua;build/?/init.lua;"
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local tecs = require("tecs")
local components = require("tecs2d.ecs.components")
local physics = require("tecs2d.ecs.physics")

local Transform2D = components.Transform2D

describe("ecs.physics", function()
    local function newWorld(gravity)
        local world = tecs.newWorld()
        world:addPlugin(physics.plugin({ gravity = gravity or { 0, 980 } }))
        return world
    end

    it("leaves a static body where it was placed", function()
        local world = newWorld()
        local entity = world:spawn(Transform2D(100, 200, 0, 32, 32))
        physics.attach(world, entity, { type = "static", halfWidth = 16, halfHeight = 16 })

        for _ = 1, 60 do world:update(1 / 60) end

        local transform = world:get(entity, Transform2D)
        assert.is_true(math.abs(transform.x - 100) < 0.5)
        assert.is_true(math.abs(transform.y - 200) < 0.5)
    end)

    it("accelerates a dynamic body and writes it back to the transform", function()
        local world = newWorld()
        local entity = world:spawn(Transform2D(0, 0, 0, 16, 16))
        physics.attach(world, entity, { type = "dynamic", radius = 8, density = 1 })

        for _ = 1, 60 do world:update(1 / 60) end

        -- One second at 980 px/s^2 covers about half that in pixels.
        local transform = world:get(entity, Transform2D)
        assert.is_true(transform.y > 400 and transform.y < 550,
            ("expected roughly 490 px of fall, got %.1f"):format(transform.y))
    end)

    it("rests a falling body on a static one", function()
        local world = newWorld()
        local ground = world:spawn(Transform2D(100, 600, 0, 400, 32))
        physics.attach(world, ground, { type = "static", halfWidth = 200, halfHeight = 16 })

        local ball = world:spawn(Transform2D(100, 50, 0, 16, 16))
        physics.attach(world, ball, { type = "dynamic", radius = 8, density = 1,
                                       restitution = 0 })

        for _ = 1, 300 do world:update(1 / 60) end

        -- Ground surface at 584, ball radius 8, so contact rests near 576.
        local transform = world:get(ball, Transform2D)
        assert.is_true(math.abs(transform.y - 576) < 4,
            ("expected rest near 576, got %.1f"):format(transform.y))
    end)

    it("keeps each body addressed by its own stored handle", function()
        -- Two bodies at different heights must stay distinct. A truncated or
        -- reordered handle would make both rows read the same body.
        local world = newWorld()
        local high = world:spawn(Transform2D(50, 0, 0, 16, 16))
        local low = world:spawn(Transform2D(150, 200, 0, 16, 16))
        physics.attach(world, high, { type = "dynamic", radius = 8, density = 1 })
        physics.attach(world, low, { type = "dynamic", radius = 8, density = 1 })

        for _ = 1, 30 do world:update(1 / 60) end

        local a = world:get(high, Transform2D)
        local b = world:get(low, Transform2D)
        assert.is_true(math.abs(a.x - 50) < 0.5, "x must not drift between bodies")
        assert.is_true(math.abs(b.x - 150) < 0.5)
        assert.is_true(b.y > a.y, "the lower body must stay lower")
    end)

    it("holds rotation fixed when asked", function()
        local world = newWorld()
        local entity = world:spawn(Transform2D(0, 0, 0, 32, 8))
        physics.attach(world, entity, { type = "dynamic", halfWidth = 16,
                                        halfHeight = 4, density = 1,
                                        fixedRotation = true })

        for _ = 1, 120 do world:update(1 / 60) end

        assert.is_true(math.abs(world:get(entity, Transform2D).rotation) < 1e-3)
    end)
end)
