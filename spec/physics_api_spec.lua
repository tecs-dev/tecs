local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local components = require("tecs.components")
local ecs = require("tecs.ecs")
local physics = require("tecs.physics")

local Transform2D = tecs.Transform2D
local Paused = tecs.ecs.Paused

local built = {}

local function newWorld(gravity)
    local world = tecs.ecs.newWorld()
    world:addPlugin(physics.plugin({ gravity = gravity or { 0, 0 }, workerCount = 1 }))
    built[#built + 1] = world
    return world
end

local function step(world, count)
    for _ = 1, count or 1 do
        world:update(1 / 60)
    end
end

after_each(function()
    for _, world in ipairs(built) do
        world:shutdown()
    end
    built = {}
end)

describe("physics declarations", function()
    it("reconciles declarations and detachments at a fixed step", function()
        local world = newWorld()
        local entity = world:spawn(Transform2D(0, 0, 0, 1, 0, 16, 16))
        physics.attach(world, entity, { radius = 8 })

        assert.is_false(physics.hasBody(world, entity))
        step(world)
        assert.is_true(physics.hasBody(world, entity))
        assert.equal(1, physics.of(world):bodyCount())

        physics.detach(world, entity)
        step(world)
        assert.is_false(physics.hasBody(world, entity))
        assert.equal(0, physics.of(world):bodyCount())
    end)

    it("restores a saved body and its native motion", function()
        local first = newWorld()
        local entity = first:spawn(Transform2D(20, 30, 0, 1, 0, 16, 16))
        physics.attach(first, entity, { radius = 8 })
        step(first)
        physics.setVelocity(first, entity, 120, -40)
        local snapshot = first:saveSnapshot({ format = "table" }).snapshot

        local second = newWorld()
        second:loadSnapshot(snapshot)
        local restored
        for _, length, entities in second:newQuery({ include = { physics.Body } }):iter() do
            if length > 0 then
                restored = entities[1]
            end
        end
        assert.is_true(physics.hasBody(second, restored))
        local vx, vy = physics.velocity(second, restored)
        assert.is_true(math.abs(vx - 120) < 0.01)
        assert.is_true(math.abs(vy + 40) < 0.01)
    end)

    it("holds and restores a paused body's motion", function()
        local world = newWorld()
        local entity = world:spawn(Transform2D(0, 0, 0, 1, 0, 16, 16))
        physics.attach(world, entity, { radius = 8 })
        step(world)
        physics.setVelocity(world, entity, 120, 0)
        world:set(entity, Paused)
        step(world, 30)
        assert.is_true(math.abs(world:get(entity, Transform2D).x) < 0.01)

        world:remove(entity, Paused)
        step(world, 30)
        assert.is_true(world:get(entity, Transform2D).x > 50)
    end)
end)

describe("physics colliders", function()
    it("supports capsule and offset geometry in raycasts", function()
        local world = newWorld()
        local entity = world:spawn(Transform2D(0, 0, 0, 1, 0, 16, 16))
        physics.attach(world, entity, {
            type = "static",
            radius = 5,
            capsuleLength = 30,
            offsetX = 40,
        })
        step(world)

        assert.is_nil(physics.raycast(world, -20, 0, 20, 0))
        local hit = physics.raycast(world, 20, 0, 60, 0)
        assert.equal(entity, hit.entity)
        assert.is_true(hit.x > 34 and hit.x < 46)
    end)

    it("applies collider edits to the live shape", function()
        local world = newWorld()
        local entity = world:spawn(Transform2D(0, 0, 0, 1, 0, 16, 16))
        physics.attach(world, entity, { type = "static", halfWidth = 8, halfHeight = 8 })
        step(world)
        assert.is_not_nil(physics.raycast(world, -20, 0, 20, 0))

        local collider = world:getMut(entity, physics.Collider)
        collider.offsetX = 100
        step(world)
        assert.is_nil(physics.raycast(world, -20, 0, 20, 0))
        assert.equal(entity, physics.raycast(world, 80, 0, 120, 0).entity)
    end)

    it("adds independently addressable secondary colliders", function()
        local world = newWorld()
        local body = world:spawn(Transform2D(0, 0, 0, 1, 0, 16, 16))
        physics.attach(world, body, { type = "static", halfWidth = 5, halfHeight = 5 })
        local secondary = world:spawn()
        physics.attachCollider(world, secondary, body, {
            radius = 5,
            offsetX = 40,
            categoryBits = 4,
        })
        step(world)

        local hit = physics.raycast(world, 20, 0, 60, 0, { maskBits = 4 })
        assert.equal(secondary, hit.entity)
        assert.equal(body, world:getFirstRelationship(secondary, physics.ColliderOf).target)
    end)

    it("edits a body's own collider without taking a secondary one with it", function()
        -- Rapier links a new shape at the head of a body's list, so the
        -- secondary collider is what a body lists first. An edit that took the
        -- head would destroy the wrong entity's shape and leave its
        -- ColliderShape naming nothing, with no error anywhere.
        local world = newWorld()
        local body = world:spawn(Transform2D(0, 0, 0, 1, 0, 16, 16))
        physics.attach(world, body, { type = "static", halfWidth = 5, halfHeight = 5 })
        local secondary = world:spawn()
        physics.attachCollider(world, secondary, body, {
            radius = 5,
            offsetX = 40,
            categoryBits = 4,
        })
        step(world)
        assert.equal(secondary, physics.raycast(world, 20, 0, 60, 0, { maskBits = 4 }).entity)

        -- Move the body's own collider, which is what dirties the column.
        local collider = world:getMut(body, physics.Collider)
        collider.halfWidth = 7
        step(world)

        local kept = physics.raycast(world, 20, 0, 60, 0, { maskBits = 4 })
        assert.is_not_nil(kept, "editing a body's collider destroyed the secondary one's shape")
        assert.equal(secondary, kept.entity)
        -- And the body's own shape is the one that moved.
        assert.equal(body, physics.raycast(world, -20, 0, 20, 0).entity)
    end)

    it("reports contact and sensor buffers as typed events", function()
        local world = newWorld()
        local contacts, sensors = 0, 0
        world:observe(0, physics.ContactBegin, function()
            contacts = contacts + 1
        end)
        world:observe(0, physics.SensorBegin, function()
            sensors = sensors + 1
        end)
        local solid = world:spawn(Transform2D(0, 0, 0, 1, 0, 16, 16))
        physics.attach(world, solid, { type = "static", radius = 10 })
        local visitor = world:spawn(Transform2D(0, 0, 0, 1, 0, 16, 16))
        physics.attach(world, visitor, { radius = 8 })
        local sensor = world:spawn(Transform2D(40, 0, 0, 1, 0, 16, 16))
        physics.attach(world, sensor, { type = "static", radius = 10, isSensor = true })
        local sensorVisitor = world:spawn(Transform2D(40, 0, 0, 1, 0, 16, 16))
        physics.attach(world, sensorVisitor, { radius = 8 })
        step(world, 2)

        assert.is_true(contacts > 0)
        assert.is_true(sensors > 0)
    end)
end)

describe("physics body controls", function()
    it("sets angular velocity, applies force and teleports", function()
        local world = newWorld()
        local entity = world:spawn(Transform2D(0, 0, 0, 1, 0, 16, 16))
        physics.attach(world, entity, { radius = 8 })
        step(world)

        physics.setAngularVelocity(world, entity, 2.5)
        assert.is_true(math.abs(physics.angularVelocity(world, entity) - 2.5) < 1e-5)
        physics.setAngularVelocity(world, entity, 0)
        physics.applyImpulseAt(world, entity, 0, 100, 8, 0)
        assert.is_true(math.abs(physics.angularVelocity(world, entity)) > 0.1)
        physics.applyForce(world, entity, 3200, 0)
        step(world, 10)
        assert.is_true(physics.velocity(world, entity) > 0)

        physics.setAwake(world, entity, false)
        assert.is_false(physics.isAwake(world, entity))
        physics.setAwake(world, entity, true)
        assert.is_true(physics.isAwake(world, entity))

        physics.teleport(world, entity, 200, 300, 0.5)
        local transform = world:get(entity, Transform2D)
        assert.equal(200, transform.x)
        assert.equal(300, transform.y)
        assert.equal(0.5, transform.rotation)
    end)

    it("applies Body edits and Disabled to the live body", function()
        local world = newWorld({ 0, 600 })
        local entity = world:spawn(Transform2D(0, 0, 0, 1, 0, 16, 16))
        physics.attach(world, entity, { radius = 8 })
        step(world, 10)
        assert.is_true(select(2, physics.velocity(world, entity)) > 50)

        local declaration = world:getMut(entity, physics.Body)
        declaration.gravityScale = 0
        physics.setVelocity(world, entity, 0, 0)
        step(world, 10)
        assert.is_true(math.abs(select(2, physics.velocity(world, entity))) < 0.1)

        local y = world:get(entity, Transform2D).y
        world:set(entity, tecs.ecs.Disabled)
        step(world)
        assert.is_nil(physics.raycast(world, -20, y, 20, y))
        world:remove(entity, tecs.ecs.Disabled)
        step(world)
        assert.equal(entity, physics.raycast(world, -20, y, 20, y).entity)

        world:set(entity, tecs.ecs.Disabled)
        step(world)
        physics.detach(world, entity)
        step(world)
        assert.equal(0, physics.of(world):bodyCount())
    end)
end)
