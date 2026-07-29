-- What happens to a Rapier body when its entity's life changes.
--
-- A body is native and a `RigidBody` is three integers naming it, so every
-- edge here is a place where the two can disagree: a snapshot that carries
-- the integers into a run that never issued them, a despawn that takes the
-- entity and leaves the body, and a pause that stops one without stopping
-- the other. None of the three announces itself, so each is pinned here.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local components = require("tecs.components")
local ecs = require("tecs.ecs")
local physics = require("tecs.physics")

local Transform = tecs.Transform
local Paused = tecs.ecs.Paused

-- Every world built here, so teardown can shut all of them down. The
-- simulation is per world now: a world nobody shuts down keeps its Rapier world
-- and its hold on the solver's thread pool for the rest of the run, so a suite
-- that built one per case and dropped it would leak one per case.
local built = {}

local function newWorld()
    local world = tecs.ecs.newWorld()
    world:addPlugin(physics.plugin({ gravity = { 0, 980 } }))
    built[#built + 1] = world
    return world
end

after_each(function()
    for _, world in ipairs(built) do
        world:shutdown()
    end
    built = {}
end)

describe("ecs.physics snapshots", function()
    it("reconnects bodies and secondary colliders without duplicating them", function()
        local first = newWorld()
        local body = first:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        physics.attach(first, body, { type = "static", radius = 5 })
        local secondary = first:spawn()
        physics.attachCollider(first, secondary, body, {
            radius = 5,
            offsetX = 40,
            categoryBits = 4,
        })
        first:update(1 / 60)
        local snapshot = first:saveSnapshot({ format = "table" }).snapshot

        local second = newWorld()
        second:loadSnapshot(snapshot)
        assert.equal(1, physics.of(second):bodyCount())
        assert.is_true(physics.hasBody(second, body))
        assert.equal(secondary, physics.raycast(second, 20, 0, 60, 0, { maskBits = 4 }).entity)

        second:update(1 / 60)
        assert.equal(1, physics.of(second):bodyCount())
        assert.equal(secondary, physics.raycast(second, 20, 0, 60, 0, { maskBits = 4 }).entity)
    end)

    it("falls back to declarations for an incompatible native snapshot", function()
        local first = newWorld()
        local entity = first:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        physics.attach(first, entity, { type = "dynamic", radius = 8, density = 1 })
        first:update(1 / 60)
        physics.setVelocity(first, entity, 120, -40)
        local snapshot = first:saveSnapshot({ format = "table" }).snapshot

        for _, entry in ipairs(snapshot.data) do
            if entry.key == "tecs.physics" then
                entry.value.engine = "rapier2d-incompatible"
            end
        end

        local second = newWorld()
        second:loadSnapshot(snapshot)
        assert.is_false(physics.hasBody(second, entity))
        second:update(1 / 60)
        assert.is_true(physics.hasBody(second, entity))
        local vx, vy = physics.velocity(second, entity)
        assert.is_true(math.abs(vx - 120) < 0.01)
        -- The fallback recreates the body before this update's fixed step, so
        -- its restored velocity has already received one step of gravity.
        assert.is_true(vy > -40 and vy < 0)
    end)

    -- A handle is this run's numbering. Rapier hands out `index1` densely and
    -- reuses a slot the moment its body is gone, so a file that carried one
    -- would name whichever body the loading run happened to put there, and
    -- the sync would follow it: one body's pose written into a different
    -- entity's Transform, silently.
    it("does not follow a stranger's body after a load", function()
        local first = newWorld()
        local saved = first:spawn(Transform(100, 100, 0, 1, 0, 16, 16))
        physics.attach(first, saved, { type = "static", halfWidth = 8, halfHeight = 8 })
        first:update(1 / 60)
        assert.equal(1, first:get(saved, physics.RigidBody).index1)
        local snapshot = first:saveSnapshot({ format = "table" }).snapshot

        -- A second world in the same process, whose first body takes the
        -- same slot the saved one had.
        local second = newWorld()
        local stranger = second:spawn(Transform(900, 50, 0, 1, 0, 16, 16))
        physics.attach(second, stranger, { type = "dynamic", radius = 8, density = 1 })
        second:update(1 / 60)
        assert.equal(1, second:get(stranger, physics.RigidBody).index1)

        second:loadSnapshot(snapshot)
        for _ = 1, 30 do
            second:update(1 / 60)
        end

        local restored
        for _, length, entities in second:query({ include = { Transform, physics.RigidBody } }):iter() do
            for row = 1, length do
                restored = entities[row]
            end
        end
        assert.is_not_nil(restored)

        -- The stranger was falling from y=50. Reading its pose here is the
        -- failure this spec exists for.
        local transform = second:get(restored, Transform)
        assert.is_true(
            math.abs(transform.x - 100) < 1e-3 and math.abs(transform.y - 100) < 1e-3,
            ("restored entity must stay where it was saved, got (%.1f, %.1f)"):format(transform.x, transform.y)
        )
    end)

    it("reconnects transient handles from both snapshot formats", function()
        for _, options in ipairs({ { format = "table" }, {} }) do
            local first = newWorld()
            local entity = first:spawn(Transform(40, 60, 0, 1, 0, 16, 16))
            physics.attach(first, entity, { type = "dynamic", radius = 8, density = 1 })
            first:update(1 / 60)
            assert.is_true(physics.hasBody(first, entity))

            local written = first:saveSnapshot(options)
            local second = newWorld()
            second:loadSnapshot(written.snapshot or written.buffer)

            local restored
            for _, length, entities in second:query({ include = { physics.Body } }):iter() do
                if length > 0 then
                    restored = entities[1]
                end
            end
            assert.is_not_nil(second:get(restored, physics.RigidBody))
            assert.is_true(physics.hasBody(second, restored))
        end
    end)

    it("reports the native body restored with an entity", function()
        local first = newWorld()
        local entity = first:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        physics.attach(first, entity, { type = "dynamic", radius = 8, density = 1 })
        first:update(1 / 60)
        assert.is_true(physics.hasBody(first, entity))
        local snapshot = first:saveSnapshot({ format = "table" }).snapshot

        local second = newWorld()
        second:loadSnapshot(snapshot)

        local restored
        for _, length, entities in second:query({ include = { physics.Body } }):iter() do
            for row = 1, length do
                restored = entities[row]
            end
        end
        assert.is_true(physics.hasBody(second, restored))
        assert.is_false(physics.hasBody(second, second:spawn(Transform(0, 0, 0, 1, 0, 16, 16))))
    end)

    it("rebuilds before body controls reach a restored entity", function()
        local first = newWorld()
        local entity = first:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        physics.attach(first, entity, { type = "dynamic", radius = 8, density = 1 })
        first:update(1 / 60)
        local snapshot = first:saveSnapshot({ format = "table" }).snapshot

        local second = newWorld()
        second:loadSnapshot(snapshot)
        local restored
        for _, length, entities in second:query({ include = { physics.Body } }):iter() do
            for row = 1, length do
                restored = entities[row]
            end
        end

        assert.is_true(physics.hasBody(second, restored))
        physics.applyImpulse(second, restored, 500, -500)
        local vx, vy = physics.velocity(second, restored)
        assert.is_true(vx > 0)
        assert.is_true(vy < 0)
    end)
end)

describe("ecs.physics despawn", function()
    it("destroys the body when the entity goes", function()
        local world = newWorld()
        local baseline = physics.of(world):bodyCount()

        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        physics.attach(world, entity, { type = "dynamic", radius = 8, density = 1 })
        world:update(1 / 60)
        assert.equal(baseline + 1, physics.of(world):bodyCount())

        world:despawn(entity)
        world:update(1 / 60)
        assert.equal(baseline, physics.of(world):bodyCount())
    end)

    it("destroys every body a batch despawn takes", function()
        local world = newWorld()
        local baseline = physics.of(world):bodyCount()

        for index = 1, 8 do
            local entity = world:spawn(Transform(index * 40, 0, 0, 1, 0, 16, 16))
            physics.attach(world, entity, { type = "dynamic", radius = 8, density = 1 })
        end
        world:update(1 / 60)
        assert.equal(baseline + 8, physics.of(world):bodyCount())

        world:batchDespawn(world:query({ include = { physics.RigidBody } }))
        world:update(1 / 60)
        assert.equal(baseline, physics.of(world):bodyCount())
    end)

    -- A despawn inside a system runs against a deferred world, where the row
    -- is staged for removal before it is gone. The observer has to reach the
    -- component there too, or the body outlives an entity killed the ordinary
    -- way and only that way.
    it("destroys the body when a system despawns the entity", function()
        local world = newWorld()
        local baseline = physics.of(world):bodyCount()

        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        physics.attach(world, entity, { type = "dynamic", radius = 8, density = 1 })

        local killed = false
        world:addSystem({
            name = "spec.KillTheBody",
            phase = tecs.ecs.phases.Update,
            run = function()
                if killed then
                    return
                end
                killed = true
                world:despawn(entity)
            end,
        })

        world:update(1 / 60)
        world:update(1 / 60)
        assert.equal(baseline, physics.of(world):bodyCount())
    end)

    it("keeps other bodies when one entity goes", function()
        local world = newWorld()
        local baseline = physics.of(world):bodyCount()

        local kept = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        local gone = world:spawn(Transform(200, 0, 0, 1, 0, 16, 16))
        physics.attach(world, kept, { type = "dynamic", radius = 8, density = 1 })
        physics.attach(world, gone, { type = "dynamic", radius = 8, density = 1 })

        world:despawn(gone)
        world:update(1 / 60)
        assert.equal(baseline + 1, physics.of(world):bodyCount())
        assert.is_true(physics.hasBody(world, kept))

        for _ = 1, 30 do
            world:update(1 / 60)
        end
        assert.is_true(world:get(kept, Transform).y > 10, "the surviving body must still be simulated")
    end)
end)

describe("ecs.physics pausing", function()
    it("stops writing a paused entity's transform", function()
        local world = newWorld()
        local free = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        local held = world:spawn(Transform(200, 0, 0, 1, 0, 16, 16))
        physics.attach(world, free, { type = "dynamic", radius = 8, density = 1 })
        physics.attach(world, held, { type = "dynamic", radius = 8, density = 1 })
        world:set(held, Paused)

        for _ = 1, 30 do
            world:update(1 / 60)
        end

        assert.is_true(world:get(free, Transform).y > 10, "an unpaused body must be followed")
        assert.equal(0, world:get(held, Transform).y)
    end)

    it("holds a paused body in place and resumes from there", function()
        local world = newWorld()
        local free = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        local held = world:spawn(Transform(200, 0, 0, 1, 0, 16, 16))
        physics.attach(world, free, { type = "dynamic", radius = 8, density = 1 })
        physics.attach(world, held, { type = "dynamic", radius = 8, density = 1 })
        world:set(held, Paused)

        for _ = 1, 30 do
            world:update(1 / 60)
        end
        assert.equal(0, world:get(held, Transform).y)

        world:remove(held, Paused)
        world:update(1 / 60)

        local resumed = world:get(held, Transform).y
        local never = world:get(free, Transform).y
        assert.is_true(resumed < 10, ("a held body resumes where it paused, got %.1f"):format(resumed))
        assert.is_true(never > 100)
    end)

    it("still destroys a paused entity's body on despawn", function()
        local world = newWorld()
        local baseline = physics.of(world):bodyCount()

        local held = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        physics.attach(world, held, { type = "dynamic", radius = 8, density = 1 })
        world:set(held, Paused)
        world:update(1 / 60)

        world:despawn(held)
        world:update(1 / 60)
        assert.equal(baseline, physics.of(world):bodyCount())
    end)
end)
