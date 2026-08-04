-- The collider overlay, held to the property it was designed around.
--
-- The overlay tessellates every physics collider into textured quads and hands
-- them to the sprite path as an instance producer. What makes that affordable
-- in a world of a hundred thousand static colliders is not the tessellation but
-- the gate in front of it: each archetype owns a contiguous span of the run, and
-- a span whose columns are clean is left exactly as it was written.
--
-- Nothing about that survives type checking, and nothing about it is visible in
-- a screenshot, so it is what this spec pins. The cases below spend most of
-- their assertions on what the overlay does *not* rewrite.
--
-- The overlay reaches the renderer for two things only, a camera zoom and a
-- producer list, so the renderer here is a stub, and the stub is also how the
-- spec gets hold of the producer the module hands over.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local ecs = require("tecs.ecs")
local physics = require("tecs.physics")
local colliders = require("tecs.debug.internal.colliders")

local Transform2D = tecs.Transform2D

-- Quads one collider costs, from the module's own tessellation: a box is its
-- four sides, a circle is one segment per point, and a capsule is the circle's
-- points plus the two straight sides that join its caps. Sixteen segments is
-- the overlay's default.
local SEGMENTS = 16
local BOX = 4
local CIRCLE = SEGMENTS
local CAPSULE = SEGMENTS + 2

-- A tag that exists to split archetypes. Colliders differing only in body kind
-- or shape share one archetype, because both are field values rather than
-- components, and a spec that wants to watch one body's span move while its
-- neighbors' stay put needs the two in separate columns.
local Ground = {}
ecs.newComponent({
    name = "SpecColliderGround",
    container = Ground,
    fields = { "value" },
    defaults = { 0 },
})

-- Every world built here, so teardown can shut all of them down: the simulation
-- is per world, so a world nobody shuts down keeps its Rapier world and its
-- hold on the solver's thread pool for the rest of the run.
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

--- The whole renderer surface the overlay uses: a camera to read a zoom off,
--- and a producer list to be added to.
local function newRenderer()
    local renderer = {
        sprites = {
            camera = { zoom = 1.0 },
            producers = {},
        },
    }
    renderer.sprites.addProducer = function(sprites, producer)
        sprites.producers[#sprites.producers + 1] = producer
    end
    return renderer
end

--- Quads the last sync would have to re-upload, and how many separate ranges
--- they arrive in.
---
--- `takeDirty` hands back the producer's own table and drops the ranges the
--- last take consumed, so the answer is summarized here rather than held on to.
local function taken(producer)
    local ranges = producer:takeDirty()
    local total = 0
    for index = 1, #ranges, 2 do
        total = total + (ranges[index + 1] - ranges[index] + 1)
    end
    return total, #ranges / 2
end

--- Spawns `count` static box colliders in one archetype.
local function spawnGround(world, count)
    for index = 1, count do
        local entity = world:spawn(Transform2D(index * 40, 500), Ground(index))
        physics.attach(world, entity, { type = "static", halfWidth = 16, halfHeight = 16 })
    end
end

local function step(world, frames)
    for _ = 1, frames or 1 do
        world:update(1 / 60)
    end
end

describe("the collider overlay", function()
    describe("installation", function()
        it("answers with one overlay per world however often it is installed", function()
            local world = newWorld()
            local renderer = newRenderer()

            local first = colliders.install(world, renderer)
            -- The second call's options are declined, and the layer is how a
            -- caller finds that out.
            local second = colliders.install(world, renderer, { layer = 3 })

            assert.are.equal(first, second)
            assert.are.equal(first, colliders.of(world))
            assert.are.equal(15, first:stats().layer)
            -- One producer, so a second install added no second overlay to draw.
            assert.are.equal(1, #renderer.sprites.producers)
        end)

        it("reports no overlay for a world nothing installed one in", function()
            assert.is_nil(colliders.of(newWorld()))
        end)

        it("refuses a malformed option at the call rather than at the next frame", function()
            local renderer = newRenderer()
            assert.has_error(function()
                colliders.install(nil, renderer)
            end)
            assert.has_error(function()
                colliders.install(tecs.ecs.newWorld(), nil)
            end)
            assert.has_error(function()
                colliders.install(tecs.ecs.newWorld(), renderer, { layer = 0 })
            end)
            assert.has_error(function()
                colliders.install(tecs.ecs.newWorld(), renderer, { thickness = 0 })
            end)
            assert.has_error(function()
                colliders.install(tecs.ecs.newWorld(), renderer, { segments = 3 })
            end)
            assert.has_error(function()
                colliders.install(tecs.ecs.newWorld(), renderer, { color = { 1, 1, 1 } })
            end)
        end)
    end)

    describe("before it is enabled", function()
        it("reserves nothing and counts nothing", function()
            local world = newWorld()
            local renderer = newRenderer()
            spawnGround(world, 4)

            local overlay = colliders.install(world, renderer)
            local producer = renderer.sprites.producers[1]
            step(world, 3)

            assert.is_false(overlay:isEnabled())
            assert.are.equal(0, producer:count())
            local counts = overlay:stats()
            assert.are.equal(0, counts.shapes)
            assert.are.equal(0, counts.instances)
            assert.are.equal(0, counts.reserved)
            assert.are.equal(0, counts.dropped)
        end)

        it("draws through the opaque lane and casts no shadow", function()
            local world = newWorld()
            local renderer = newRenderer()
            colliders.install(world, renderer)
            local producer = renderer.sprites.producers[1]

            assert.are.equal(0, producer:blended())
            assert.are.equal(0, producer:casting())
        end)
    end)

    describe("once it is enabled", function()
        it("tessellates every collider into the quads its shape costs", function()
            local world = newWorld()
            local renderer = newRenderer()

            for index = 1, 3 do
                local entity = world:spawn(Transform2D(index * 40, 100))
                physics.attach(world, entity, { type = "static", halfWidth = 16, halfHeight = 16 })
            end
            for index = 1, 2 do
                local entity = world:spawn(Transform2D(index * 40, 200))
                physics.attach(world, entity, { type = "static", radius = 12 })
            end
            local capsule = world:spawn(Transform2D(300, 300))
            physics.attach(world, capsule, { type = "static", radius = 8, capsuleLength = 24 })

            local overlay = colliders.install(world, renderer)
            overlay:setEnabled(true)
            assert.is_true(overlay:isEnabled())
            step(world, 3)

            local counts = overlay:stats()
            assert.are.equal(6, counts.shapes)
            -- 3 boxes + 2 circles + 1 capsule: 3*4 + 2*16 + 1*18 = 62.
            assert.are.equal(3 * BOX + 2 * CIRCLE + CAPSULE, counts.instances)
            assert.are.equal(62, counts.instances)
            assert.are.equal(0, counts.dropped)
        end)

        it("rounds an odd segment count up so a capsule's caps share the circle's points", function()
            local world = newWorld()
            local renderer = newRenderer()
            local entity = world:spawn(Transform2D(100, 100))
            physics.attach(world, entity, { type = "static", radius = 10 })

            local overlay = colliders.install(world, renderer, { segments = 5 })
            overlay:setEnabled(true)
            step(world, 3)

            -- Five is raised to six, so the circle is six segments and not five.
            assert.are.equal(6, overlay:stats().instances)
        end)
    end)

    describe("a frame that changed nothing", function()
        it("rewrites no span for a world of resting static colliders", function()
            -- The headline property. A static body's Transform2D is never
            -- written, so its archetype's column never goes dirty, so the span
            -- holding its outlines is written once and never again. That is
            -- what makes a hundred thousand static colliders cost nothing per
            -- frame, and it is the first thing a later change would break
            -- without any test noticing.
            local world = newWorld()
            local renderer = newRenderer()
            spawnGround(world, 8)

            local overlay = colliders.install(world, renderer)
            local producer = renderer.sprites.producers[1]
            overlay:setEnabled(true)
            -- Enough updates for physics to create the bodies and for the
            -- archetype those creations move the entities into to settle.
            step(world, 5)
            assert.are.equal(8 * BOX, overlay:stats().instances)

            -- Consume the build, which wrote the whole run once, then take one
            -- more ordinary frame.
            assert.are.equal(8 * BOX, (taken(producer)))
            step(world)

            local quads, ranges = taken(producer)
            assert.are.equal(0, quads, "a steady frame of static colliders rewrote quads")
            assert.are.equal(0, ranges)
        end)
    end)

    describe("a frame that moved one body", function()
        it("rewrites the moving body's span and leaves the resting ones alone", function()
            local world = newWorld()
            local renderer = newRenderer()
            spawnGround(world, 8)

            -- Its own archetype, through the tag, because a dirty column is an
            -- archetype-wide fact: a faller sharing an archetype with the
            -- ground would drag the whole span along with it.
            local faller = world:spawn(Transform2D(100, 0))
            physics.attach(world, faller, { type = "dynamic", halfWidth = 16, halfHeight = 16, density = 1 })

            local overlay = colliders.install(world, renderer)
            local producer = renderer.sprites.producers[1]
            overlay:setEnabled(true)
            step(world, 10)
            assert.are.equal(9 * BOX, overlay:stats().instances)

            assert.is_true(taken(producer) > 0, "the first build wrote nothing")
            step(world)

            -- One box, so four quads: the faller's span and nothing else. The
            -- assertion is on the length rather than on the offsets, because
            -- where a span lands is the module's business and a spec that
            -- pinned it would fail on any reordering.
            local quads, ranges = taken(producer)
            assert.are.equal(BOX, quads, "a moving body rewrote more than its own span")
            assert.are.equal(1, ranges)
        end)
    end)

    describe("a frame that moved the camera", function()
        it("rebuilds every outline when the zoom leaves the tolerance band", function()
            -- Thickness is constant in screen pixels, so every quad's height is
            -- a world-space length derived from the zoom. Nothing marks zoom
            -- dirty, so the overlay compares it and rebuilds the run itself.
            local world = newWorld()
            local renderer = newRenderer()
            spawnGround(world, 8)

            local overlay = colliders.install(world, renderer)
            local producer = renderer.sprites.producers[1]
            overlay:setEnabled(true)
            step(world, 5)
            taken(producer)

            -- Inside the band first: an easing camera must not rewrite the run
            -- for a change no pixel shows.
            renderer.sprites.camera.zoom = 1.0 + 1.0e-6
            step(world)
            assert.are.equal(0, (taken(producer)), "a zoom nudge inside the band rebuilt the run")

            renderer.sprites.camera.zoom = 2.0
            step(world)
            assert.are.equal(overlay:stats().instances, (taken(producer)))
        end)
    end)

    describe("the reservation", function()
        it("holds its high-water mark when the colliders it counted go away", function()
            -- The reserved count is what the renderer lays the run out from, so
            -- lowering it would move every later instance in the scene. A debug
            -- toggle may not cost the frame that much, so it only grows.
            local world = newWorld()
            local renderer = newRenderer()
            local entities = {}
            for index = 1, 6 do
                local entity = world:spawn(Transform2D(index * 40, 500), Ground(index))
                physics.attach(world, entity, { type = "static", halfWidth = 16, halfHeight = 16 })
                entities[index] = entity
            end

            local overlay = colliders.install(world, renderer)
            local producer = renderer.sprites.producers[1]
            overlay:setEnabled(true)
            step(world, 5)

            local peak = producer:count()
            assert.are.equal(6 * BOX, peak)
            assert.are.equal(peak, overlay:stats().reserved)

            for index = 1, 4 do
                world:despawn(entities[index])
            end
            step(world, 3)

            assert.are.equal(2 * BOX, overlay:stats().instances)
            assert.are.equal(peak, producer:count(), "the reservation fell when colliders went away")
        end)

        it("survives disabling, which hides the quads rather than handing them back", function()
            local world = newWorld()
            local renderer = newRenderer()
            spawnGround(world, 5)

            local overlay = colliders.install(world, renderer)
            local producer = renderer.sprites.producers[1]
            overlay:setEnabled(true)
            step(world, 5)
            local peak = producer:count()
            assert.are.equal(5 * BOX, peak)

            taken(producer)
            overlay:setEnabled(false)

            assert.is_false(overlay:isEnabled())
            assert.are.equal(peak, producer:count(), "disabling handed the reservation back")
            assert.are.equal(0, overlay:stats().instances)
            -- Hiding is a write, so the quads it hid are re-uploaded once.
            assert.are.equal(peak, (taken(producer)))

            -- And a disabled overlay builds nothing at all.
            step(world)
            assert.are.equal(0, (taken(producer)))
        end)

        it("goes back with the buffers when the renderer releases the producer", function()
            local world = newWorld()
            local renderer = newRenderer()
            spawnGround(world, 5)

            local overlay = colliders.install(world, renderer)
            local producer = renderer.sprites.producers[1]
            overlay:setEnabled(true)
            step(world, 5)
            assert.is_true(producer:count() > 0)

            producer:destroy()
            assert.are.equal(0, producer:count())
            assert.is_false(overlay:isEnabled())

            -- A released overlay cannot be enabled again, so nothing reaches
            -- the freed buffers on a later update.
            overlay:setEnabled(true)
            step(world)
            assert.is_false(overlay:isEnabled())
            assert.are.equal(0, producer:count())
        end)
    end)

    describe("a secondary collider", function()
        it("is drawn once, at the pose of the body it belongs to", function()
            -- The primary query excludes `ColliderOf` precisely so a secondary
            -- collider carrying a transform of its own is not drawn twice, at
            -- two different poses.
            local world = newWorld()
            local renderer = newRenderer()
            local body = world:spawn(Transform2D(100, 500), Ground(1))
            physics.attach(world, body, { type = "static", halfWidth = 16, halfHeight = 16 })
            local extra = world:spawn(Transform2D(100, 500))
            physics.attachCollider(world, extra, body, { halfWidth = 8, halfHeight = 8, offsetY = 24 })

            local overlay = colliders.install(world, renderer)
            local producer = renderer.sprites.producers[1]
            overlay:setEnabled(true)
            step(world, 5)

            assert.are.equal(2, overlay:stats().shapes)
            assert.are.equal(2 * BOX, overlay:stats().instances)

            -- A secondary collider's pose lives in an archetype its own span
            -- cannot see, so a clean column here says nothing, and the span is
            -- rewritten every frame. The body's own span still is not.
            taken(producer)
            step(world)
            assert.are.equal(BOX, (taken(producer)))
        end)
    end)
end)
