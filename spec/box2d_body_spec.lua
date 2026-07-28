-- What a body is in ECS terms.
--
-- A body's description is in columns rather than inside Box2D: `Body` and
-- `Collider` are what a game asked for, `Motion` is the store that carries a
-- velocity out of the solve, and nothing can rebuild a body from a save until
-- all three are there. The units are pinned here too, because every number
-- this module takes and returns is pixels.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local components = require("tecs.components")
local ecs = require("tecs.ecs")
local box2d = require("tecs.box2d")

local Transform = tecs.Transform

-- Every world built here, so teardown can shut all of them down. A world
-- nobody shuts down keeps its Box2D world and its hold on the solver's thread
-- pool for the rest of the run.
local built = {}

local function newWorld(options)
    local world = tecs.ecs.newWorld()
    world:addPlugin(box2d.plugin(options or { gravity = { 0, 980 } }))
    built[#built + 1] = world
    return world
end

after_each(function()
    for _, world in ipairs(built) do
        world:shutdown()
    end
    built = {}
end)

describe("ecs.box2d declaration", function()
    it("records the body a game asked for", function()
        local world = newWorld()
        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, entity, { type = "kinematic", radius = 8, fixedRotation = true })

        local body = world:get(entity, box2d.Body)
        assert.is_not_nil(body, "attach must leave the declaration in a column")
        -- 1 is b2_kinematicBody. The column holds the integer so a query over
        -- bodies never compares strings.
        assert.equal(1, body.kind)
        assert.equal(1, body.fixedRotation)
        assert.equal(1, body.sleepEnabled)
        assert.equal(1, body.gravityScale)
    end)

    it("records the collider a game asked for", function()
        local world = newWorld()
        local round = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, round, { type = "dynamic", radius = 8, density = 2, friction = 0.25 })

        local circle = world:get(round, box2d.Collider)
        assert.equal(1, circle.shape, "a radius selects the circle shape")
        assert.equal(8, circle.radius)
        assert.equal(2, circle.density)
        assert.is_true(math.abs(circle.friction - 0.25) < 1e-6)

        local square = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, square, { type = "static", halfWidth = 20, halfHeight = 3 })

        local box = world:get(square, box2d.Collider)
        assert.equal(0, box.shape, "no radius leaves the box shape")
        assert.equal(20, box.halfWidth)
        assert.equal(3, box.halfHeight)
        assert.equal(0, box.radius)
        -- Box2D's own shape defaults, so the column and the simulation agree
        -- about a body nobody configured.
        assert.equal(1, box.density)
        assert.is_true(math.abs(box.friction - 0.6) < 1e-6)
        assert.equal(0, box.restitution)
        assert.equal(0, box.isSensor)
    end)

    -- The description has to survive a save for anything to rebuild from it
    -- later. It is a column, so the snapshot writer needs nothing taught to
    -- it; this asserts that is actually true rather than assumed.
    it("carries the description through a snapshot", function()
        local first = newWorld()
        local entity = first:spawn(Transform(40, 60, 0, 1, 0, 16, 16))
        box2d.attach(first, entity, { type = "static", halfWidth = 12, halfHeight = 7, restitution = 0.5 })
        local snapshot = first:saveSnapshot({ format = "table" }).snapshot

        local second = newWorld()
        second:loadSnapshot(snapshot)

        local restored
        for _, length, entities in second:query({ include = { box2d.Collider } }):iter() do
            for row = 1, length do
                restored = entities[row]
            end
        end
        assert.is_not_nil(restored, "the collider column must come back")

        local collider = second:get(restored, box2d.Collider)
        assert.equal(0, collider.shape)
        assert.equal(12, collider.halfWidth)
        assert.equal(7, collider.halfHeight)
        assert.is_true(math.abs(collider.restitution - 0.5) < 1e-6)
        assert.equal(0, second:get(restored, box2d.Body).kind)
    end)

    -- A body with no pose has nothing to write back to, so it is not a legal
    -- entity. `requires` is what makes it unrepresentable rather than a nil
    -- test in every function that reads the pose.
    it("gains a Transform and a Motion from Body alone", function()
        local world = newWorld()
        local entity = world:spawn()
        world:set(entity, box2d.Body())

        assert.is_not_nil(world:get(entity, Transform), "Body requires Transform")
        assert.is_not_nil(world:get(entity, box2d.Motion), "Body requires Motion")
        assert.equal(0, world:get(entity, Transform).x)
    end)

    -- Before this, `attach` guarded for a missing Transform and then read
    -- `transform.x` anyway, so an entity without one crashed rather than
    -- being told what was wrong.
    it("attaches to an entity that had no Transform", function()
        local world = newWorld()
        local entity = world:spawn()
        box2d.attach(world, entity, { type = "dynamic", radius = 8, density = 1 })

        world:update(1 / 60)
        assert.is_true(box2d.hasBody(world, entity))
        for _ = 1, 30 do
            world:update(1 / 60)
        end
        assert.is_true(world:get(entity, Transform).y > 10, "a body given a default pose still simulates")
    end)

    it("refuses a body type it cannot name", function()
        local world = newWorld()
        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        assert.has_error(function()
            box2d.attach(world, entity, { type = "floaty" })
        end)
    end)
end)

describe("ecs.box2d velocity", function()
    -- Every other number this module takes and returns is pixels: the extents
    -- and radius `attach` is given, the impulse components, the plugin's
    -- gravity. Meters was the outlier, and the difference is a factor of 32:
    -- half a second under 980 px/s^2 reads 490, not 15.3.
    it("reads a falling body's velocity in pixels", function()
        local world = newWorld()
        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, entity, { type = "dynamic", radius = 8, density = 1 })

        for _ = 1, 30 do
            world:update(1 / 60)
        end

        local _, vy = box2d.velocity(world, entity)
        assert.is_true(vy > 450 and vy < 530, ("expected about 490 px/s after half a second, got %.2f"):format(vy))
    end)

    it("sets a velocity in pixels and the body moves by it", function()
        local world = newWorld()
        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.attach(world, entity, { type = "dynamic", radius = 8, density = 1 })

        world:update(1 / 60)
        box2d.setVelocity(world, entity, 320, 0)
        local vx = box2d.velocity(world, entity)
        assert.is_true(math.abs(vx - 320) < 1e-3, ("expected 320 px/s back, got %.4f"):format(vx))

        for _ = 1, 60 do
            world:update(1 / 60)
        end
        -- A second at 320 px/s, minus nothing: gravity is vertical.
        assert.is_true(
            math.abs(world:get(entity, Transform).x - 320) < 8,
            ("expected about 320 px of travel, got %.1f"):format(world:get(entity, Transform).x)
        )
    end)

    it("leaves an entity with no body alone", function()
        local world = newWorld()
        local entity = world:spawn(Transform(0, 0, 0, 1, 0, 16, 16))
        box2d.setVelocity(world, entity, 100, 100)
        local vx, vy = box2d.velocity(world, entity)
        assert.equal(0, vx)
        assert.equal(0, vy)
    end)
end)
