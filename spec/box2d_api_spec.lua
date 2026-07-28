local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local components = require("tecs.components")
local builtins = require("tecs.ecs").builtins
local box2d = require("tecs.box2d")

local Transform = builtins.Transform
local Paused = tecs.ecs.builtins.Paused

local built = {}

local function newWorld(gravity)
    local world = tecs.ecs.newWorld()
    world:addPlugin(box2d.plugin({ gravity = gravity or { 0, 0 }, workerCount = 1 }))
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

describe("box2d declarations", function()
    it("reconciles declarations and detachments at a fixed step", function()
        local world = newWorld()
        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, entity, { radius = 8 })

        assert.is_false(box2d.hasBody(world, entity))
        step(world)
        assert.is_true(box2d.hasBody(world, entity))
        assert.equal(1, box2d.of(world):bodyCount())

        box2d.detach(world, entity)
        step(world)
        assert.is_false(box2d.hasBody(world, entity))
        assert.equal(0, box2d.of(world):bodyCount())
    end)

    it("rebuilds a saved body with its motion", function()
        local first = newWorld()
        local entity = first:spawn(Transform(20, 30, 0, 1, 0, 16, 16))
        box2d.attach(first, entity, { radius = 8 })
        step(first)
        box2d.setVelocity(first, entity, 120, -40)
        local snapshot = first:saveSnapshot({ format = "table" }).snapshot

        local second = newWorld()
        second:loadSnapshot(snapshot)
        local restored
        for _, length, entities in second:query({ include = { box2d.Body } }):iter() do
            if length > 0 then
                restored = entities[1]
            end
        end
        assert.is_false(box2d.hasBody(second, restored))
        step(second)
        assert.is_true(box2d.hasBody(second, restored))
        local vx, vy = box2d.velocity(second, restored)
        assert.is_true(math.abs(vx - 120) < 0.01)
        assert.is_true(math.abs(vy + 40) < 0.01)
    end)

    it("holds and restores a paused body's motion", function()
        local world = newWorld()
        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, entity, { radius = 8 })
        step(world)
        box2d.setVelocity(world, entity, 120, 0)
        world:set(entity, Paused)
        step(world, 30)
        assert.is_true(math.abs(world:get(entity, Transform).x) < 0.01)

        world:remove(entity, Paused)
        step(world, 30)
        assert.is_true(world:get(entity, Transform).x > 50)
    end)
end)

describe("box2d colliders", function()
    it("supports capsule and offset geometry in raycasts", function()
        local world = newWorld()
        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, entity, {
            type = "static",
            radius = 5,
            capsuleLength = 30,
            offsetX = 40,
        })
        step(world)

        assert.is_nil(box2d.raycast(world, -20, 0, 20, 0))
        local hit = box2d.raycast(world, 20, 0, 60, 0)
        assert.equal(entity, hit.entity)
        assert.is_true(hit.x > 34 and hit.x < 46)
    end)

    it("applies collider edits to the live shape", function()
        local world = newWorld()
        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, entity, { type = "static", halfWidth = 8, halfHeight = 8 })
        step(world)
        assert.is_not_nil(box2d.raycast(world, -20, 0, 20, 0))

        local collider = world:getMut(entity, box2d.Collider)
        collider.offsetX = 100
        step(world)
        assert.is_nil(box2d.raycast(world, -20, 0, 20, 0))
        assert.equal(entity, box2d.raycast(world, 80, 0, 120, 0).entity)
    end)

    it("adds independently addressable secondary colliders", function()
        local world = newWorld()
        local body = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, body, { type = "static", halfWidth = 5, halfHeight = 5 })
        local secondary = world:spawn()
        box2d.attachCollider(world, secondary, body, {
            radius = 5,
            offsetX = 40,
            categoryBits = 4,
        })
        step(world)

        local hit = box2d.raycast(world, 20, 0, 60, 0, { maskBits = 4 })
        assert.equal(secondary, hit.entity)
        assert.equal(body, world:getFirstRelationship(secondary, box2d.ColliderOf).target)
    end)

    it("edits a body's own collider without taking a secondary one with it", function()
        -- Box2D links a new shape at the head of a body's list, so the
        -- secondary collider is what a body lists first. An edit that took the
        -- head would destroy the wrong entity's shape and leave its
        -- ColliderShape naming nothing, with no error anywhere.
        local world = newWorld()
        local body = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, body, { type = "static", halfWidth = 5, halfHeight = 5 })
        local secondary = world:spawn()
        box2d.attachCollider(world, secondary, body, {
            radius = 5,
            offsetX = 40,
            categoryBits = 4,
        })
        step(world)
        assert.equal(secondary, box2d.raycast(world, 20, 0, 60, 0, { maskBits = 4 }).entity)

        -- Move the body's own collider, which is what dirties the column.
        local collider = world:getMut(body, box2d.Collider)
        collider.halfWidth = 7
        step(world)

        local kept = box2d.raycast(world, 20, 0, 60, 0, { maskBits = 4 })
        assert.is_not_nil(kept, "editing a body's collider destroyed the secondary one's shape")
        assert.equal(secondary, kept.entity)
        -- And the body's own shape is the one that moved.
        assert.equal(body, box2d.raycast(world, -20, 0, 20, 0).entity)
    end)

    it("reports contact and sensor buffers as typed events", function()
        local world = newWorld()
        local contacts, sensors = 0, 0
        world:observe(0, box2d.ContactBegin, function()
            contacts = contacts + 1
        end)
        world:observe(0, box2d.SensorBegin, function()
            sensors = sensors + 1
        end)

        local solid = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, solid, { type = "static", radius = 10 })
        local visitor = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, visitor, { radius = 8 })
        local sensor = world:spawn(Transform(40, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, sensor, { type = "static", radius = 10, isSensor = true })
        local sensorVisitor = world:spawn(Transform(40, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, sensorVisitor, { radius = 8 })
        step(world, 2)

        assert.is_true(contacts > 0)
        assert.is_true(sensors > 0)
    end)
end)

describe("box2d body controls", function()
    it("sets angular velocity, applies force and teleports", function()
        local world = newWorld()
        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, entity, { radius = 8 })
        step(world)

        box2d.setAngularVelocity(world, entity, 2.5)
        assert.is_true(math.abs(box2d.angularVelocity(world, entity) - 2.5) < 1e-5)
        box2d.setAngularVelocity(world, entity, 0)
        box2d.applyImpulseAt(world, entity, 0, 100, 8, 0)
        assert.is_true(math.abs(box2d.angularVelocity(world, entity)) > 0.1)
        box2d.applyForce(world, entity, 3200, 0)
        step(world, 10)
        assert.is_true(box2d.velocity(world, entity) > 0)

        box2d.setAwake(world, entity, false)
        assert.is_false(box2d.isAwake(world, entity))
        box2d.setAwake(world, entity, true)
        assert.is_true(box2d.isAwake(world, entity))

        box2d.teleport(world, entity, 200, 300, 0.5)
        local transform = world:get(entity, Transform)
        assert.equal(200, transform.x)
        assert.equal(300, transform.y)
        assert.equal(0.5, transform.rotation)
    end)

    it("applies Body edits and Disabled to the live body", function()
        local world = newWorld({ 0, 600 })
        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, entity, { radius = 8 })
        step(world, 10)
        assert.is_true(select(2, box2d.velocity(world, entity)) > 50)

        local declaration = world:getMut(entity, box2d.Body)
        declaration.gravityScale = 0
        box2d.setVelocity(world, entity, 0, 0)
        step(world, 10)
        assert.is_true(math.abs(select(2, box2d.velocity(world, entity))) < 0.1)

        local y = world:get(entity, Transform).y
        world:set(entity, tecs.ecs.builtins.Disabled)
        step(world)
        assert.is_nil(box2d.raycast(world, -20, y, 20, y))
        world:remove(entity, tecs.ecs.builtins.Disabled)
        step(world)
        assert.equal(entity, box2d.raycast(world, -20, y, 20, y).entity)

        world:set(entity, tecs.ecs.builtins.Disabled)
        step(world)
        box2d.detach(world, entity)
        step(world)
        assert.equal(0, box2d.of(world):bodyCount())
    end)
end)
