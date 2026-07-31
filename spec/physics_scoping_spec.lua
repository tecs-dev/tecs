-- Where a simulation lives.
--
-- The simulation is per world, so two worlds each installing the plugin get a
-- Rapier world each and neither sees the other's bodies. The solver's thread
-- pool goes the other way and is shared, because threads are the machine.
--
-- This file runs after the other physics suites, which is deliberate: the
-- thread count it asserts is zero catches a world any of them built and never
-- shut down.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local components = require("tecs.components")
local ecs = require("tecs.ecs")
local physics = require("tecs.physics")
local TaskPool = require("tecs.physics.TaskPool")

local Transform = tecs.Transform

-- Every world built here, so teardown can shut all of them down. A world
-- nobody shuts down keeps its Rapier world and its hold on the solver's thread
-- pool for the rest of the run.
local built = {}

local function newWorld(options)
    local world = tecs.ecs.newWorld()
    world:addPlugin(physics.plugin(options or { gravity = { 0, 980 } }))
    built[#built + 1] = world
    return world
end

after_each(function()
    for _, world in ipairs(built) do
        world:shutdown()
    end
    built = {}
end)

describe("ecs.physics world scoping", function()
    it("reports no simulation for a world that has none", function()
        assert.is_nil(physics.of(tecs.ecs.newWorld()))
    end)

    -- The key's name is the published part, because `listKeys` reverse-maps
    -- names to ids: that is what lets a debug tool answer what is installed
    -- into a world without every module exporting its key.
    it("names its resource key", function()
        assert.is_not_nil(tecs.data.findKey("tecs.physics"))
        assert.is_not_nil(tecs.data.listKeys()["tecs.physics"])
    end)

    -- Each world owns an independent simulation.
    it("gives two worlds a simulation each", function()
        local first = newWorld()
        local second = newWorld()

        assert.is_not_nil(physics.of(first))
        assert.is_not_nil(physics.of(second))
        assert.is_not.equal(physics.of(first), physics.of(second))

        local before = physics.of(second):bodyCount()
        local entity = first:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        physics.attach(first, entity, { type = "dynamic", radius = 8, density = 1 })
        first:update(1 / 60)

        assert.equal(1, physics.of(first):bodyCount())
        assert.equal(before, physics.of(second):bodyCount(), "a body must land in its own world's simulation")
    end)

    it("keeps two worlds' bodies apart as they step", function()
        local slow = newWorld({ gravity = { 0, 100 } })
        local fast = newWorld({ gravity = { 0, 2000 } })

        local a = slow:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        local b = fast:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        physics.attach(slow, a, { type = "dynamic", radius = 8, density = 1 })
        physics.attach(fast, b, { type = "dynamic", radius = 8, density = 1 })

        for _ = 1, 30 do
            slow:update(1 / 60)
            fast:update(1 / 60)
        end

        -- Each body fell under its own world's gravity, which it cannot do if
        -- both are in one simulation. The lower bound on the slow one is the
        -- half that catches `attach` reaching a shared simulation: a body
        -- created in the other world's is stepped by nobody and sits still.
        local slowY = slow:get(a, Transform).y
        local fastY = fast:get(b, Transform).y
        assert.is_true(slowY > 5, ("the slow body must be simulated too, got %.2f"):format(slowY))
        assert.is_true(
            fastY > slowY * 5,
            ("expected the heavier gravity to win: %.1f against %.1f"):format(fastY, slowY)
        )
    end)

    -- There is no `world:destroy` in the ECS. What exists is `world:shutdown`,
    -- which an application calls first and deliberately, so that is where the
    -- release goes.
    it("destroys the simulation on shutdown", function()
        local world = tecs.ecs.newWorld()
        world:addPlugin(physics.plugin({ gravity = { 0, 980 } }))
        assert.is_not_nil(physics.of(world))

        world:shutdown()
        assert.is_nil(physics.of(world))
        -- Twice, because an application that shut down twice must not join a
        -- pool it has already given back.
        world:shutdown()
    end)

    -- Asked of the pool rather than inferred from a clean exit. This is also
    -- the only observable a world nobody shut down has: nothing at this layer
    -- can act on one that is simply dropped.
    it("joins the solver threads once every world has shut down", function()
        local before = TaskPool.liveThreadCount()

        local first = tecs.ecs.newWorld()
        first:addPlugin(physics.plugin({ gravity = { 0, 980 }, workerCount = 4 }))
        local second = tecs.ecs.newWorld()
        second:addPlugin(physics.plugin({ gravity = { 0, 980 } }))

        -- One pool, shared, however many simulations hold it: threads are the
        -- machine and there is one of those.
        assert.equal(before + 3, TaskPool.liveThreadCount())

        first:shutdown()
        assert.equal(before + 3, TaskPool.liveThreadCount(), "the other world still holds the pool")
        second:shutdown()
        assert.equal(0, TaskPool.liveThreadCount())
    end)

    -- Two numbers that have to agree and can disagree is a defect waiting, so
    -- the second install says so rather than being silently ignored.
    it("raises when a second install asks for a different worker count", function()
        local first = newWorld({ gravity = { 0, 980 }, workerCount = 2 })
        assert.is_not_nil(physics.of(first))

        local second = tecs.ecs.newWorld()
        assert.has_error(function()
            second:addPlugin(physics.plugin({ gravity = { 0, 980 }, workerCount = 3 }))
        end)
        assert.is_nil(physics.of(second))
    end)
end)
