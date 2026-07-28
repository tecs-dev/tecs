-- Physics driven from the world.
--
-- The handle round trip is the part worth pinning: a Box2D body id is stored
-- as three integers in an archetype column and rebuilt on every sync. If any
-- field were truncated or reordered the handle would still look plausible and
-- would address the wrong body, or none.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local components = require("tecs.components")
local physics = require("tecs.physics")

local Transform = components.Transform

-- Every world built here, so teardown can shut all of them down. The
-- simulation is per world now, so a world nobody shuts down keeps its Box2D
-- world and its hold on the solver's thread pool for the rest of the run.
local built = {}

local function newWorld(gravity)
    local world = tecs.ecs.newWorld()
    world:addPlugin(physics.plugin({ gravity = gravity or { 0, 980 } }))
    built[#built + 1] = world
    return world
end

after_each(function()
    for _, world in ipairs(built) do
        world:shutdown()
    end
    built = {}
end)

describe("ecs.physics", function()
    it("leaves a static body where it was placed", function()
        local world = newWorld()
        local entity = world:spawn(Transform(100, 200, 0, 1, 0, 32, 32))
        physics.attach(world, entity, { type = "static", halfWidth = 16, halfHeight = 16 })

        for _ = 1, 60 do
            world:update(1 / 60)
        end

        local transform = world:get(entity, Transform)
        assert.is_true(math.abs(transform.x - 100) < 0.5)
        assert.is_true(math.abs(transform.y - 200) < 0.5)
    end)

    it("accelerates a dynamic body and writes it back to the transform", function()
        local world = newWorld()
        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        physics.attach(world, entity, { type = "dynamic", radius = 8, density = 1 })

        for _ = 1, 60 do
            world:update(1 / 60)
        end

        -- One second at 980 px/s^2 covers about half that in pixels.
        local transform = world:get(entity, Transform)
        assert.is_true(
            transform.y > 400 and transform.y < 550,
            ("expected roughly 490 px of fall, got %.1f"):format(transform.y)
        )
    end)

    it("rests a falling body on a static one", function()
        local world = newWorld()
        local ground = world:spawn(Transform(100, 600, 0, 1, 0, 400, 32))
        physics.attach(world, ground, { type = "static", halfWidth = 200, halfHeight = 16 })

        local ball = world:spawn(Transform(100, 50, 0, 1, 0, 16, 16))
        physics.attach(world, ball, {
            type = "dynamic",
            radius = 8,
            density = 1,
            restitution = 0,
        })

        for _ = 1, 300 do
            world:update(1 / 60)
        end

        -- Ground surface at 584, ball radius 8, so contact rests near 576.
        local transform = world:get(ball, Transform)
        assert.is_true(math.abs(transform.y - 576) < 4, ("expected rest near 576, got %.1f"):format(transform.y))
    end)

    it("keeps each body addressed by its own stored handle", function()
        -- Two bodies at different heights must stay distinct. A truncated or
        -- reordered handle would make both rows read the same body.
        local world = newWorld()
        local high = world:spawn(Transform(50, 0, 0, 1, 0, 16, 16))
        local low = world:spawn(Transform(150, 200, 0, 1, 0, 16, 16))
        physics.attach(world, high, { type = "dynamic", radius = 8, density = 1 })
        physics.attach(world, low, { type = "dynamic", radius = 8, density = 1 })

        for _ = 1, 30 do
            world:update(1 / 60)
        end

        local a = world:get(high, Transform)
        local b = world:get(low, Transform)
        assert.is_true(math.abs(a.x - 50) < 0.5, "x must not drift between bodies")
        assert.is_true(math.abs(b.x - 150) < 0.5)
        assert.is_true(b.y > a.y, "the lower body must stay lower")
    end)

    it("holds rotation fixed when asked", function()
        local world = newWorld()
        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 32, 8))
        physics.attach(
            world,
            entity,
            { type = "dynamic", halfWidth = 16, halfHeight = 4, density = 1, fixedRotation = true }
        )

        for _ = 1, 120 do
            world:update(1 / 60)
        end

        assert.is_true(math.abs(world:get(entity, Transform).rotation) < 1e-3)
    end)
end)

describe("ecs.physics write-back", function()
    -- The sync takes a transform column mutable only for a body the step
    -- actually moved. Everything downstream is gated on that bit, so a world
    -- whose bodies have settled must stop re-uploading them; taking the column
    -- up front would leave every consumer working every frame forever.
    it("stops dirtying transforms once a body has settled", function()
        local world = newWorld()
        local ground = world:spawn(Transform(0, 400, 0, 1, 0, 2000, 40))
        physics.attach(world, ground, { type = "static", halfWidth = 1000, halfHeight = 20 })

        local entity = world:spawn(Transform(0, 100, 0, 1, 0, 20, 20))
        physics.attach(world, entity, {
            type = "dynamic",
            halfWidth = 10,
            halfHeight = 10,
            density = 1.0,
            friction = 0.9,
            restitution = 0.0,
        })

        local query = world:query({ include = { Transform, physics.RigidBody } })

        -- Sampled from inside the frame, because the dirty bits clear at the
        -- end of every update and a check afterwards reads false whatever
        -- happened.
        local dirty = false
        world:addSystem({
            name = "spec.ObserveDirty",
            phase = tecs.ecs.phases.Last,
            run = function()
                dirty = false
                for archetype in query:iter() do
                    if archetype:isComponentDirty(Transform) then
                        dirty = true
                    end
                end
            end,
        })

        local function step()
            world:update(1 / 60)
        end

        -- Falling: the column is dirty, because the body is moving.
        for _ = 1, 10 do
            step()
        end
        assert.is_true(dirty)

        -- Box2D puts a resting body to sleep, and a sleeping body reports no
        -- movement, so the column stops being taken mutable at all.
        for _ = 1, 600 do
            step()
        end
        assert.is_false(dirty)
    end)

    it("writes a moving body every step it moves", function()
        local world = newWorld()
        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 20, 20))
        physics.attach(world, entity, {
            type = "dynamic",
            halfWidth = 10,
            halfHeight = 10,
            density = 1.0,
        })

        world:update(1 / 60)
        local first = world:get(entity, Transform).y
        for _ = 1, 30 do
            world:update(1 / 60)
        end
        local later = world:get(entity, Transform).y

        -- Falling under gravity, so it is strictly lower than it was.
        assert.is_true(later > first)
    end)
end)
