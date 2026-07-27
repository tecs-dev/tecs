-- Playback resolved on the GPU, and the two halves of it agreeing.
--
-- The load-bearing property is the first one here. A frame table says which
-- frame is showing at a millisecond, and `Sheet:frameAt` says which frame is
-- showing at a time; a shader reads the first and gameplay reads the second,
-- and a disagreement between them is a sprite whose hitbox is on a different
-- frame from its drawing. So the first case walks every tick of every tag and
-- holds the two to each other, and it is the case to keep working.
--
-- The second property is what the whole design is for: changing which frame is
-- showing must not write anything. The encode system runs on the `Animation`
-- column's dirty bit, so a step where nothing changed what is playing has to
-- leave every instance alone however many animations are running.

-- The build directory is the build system's to choose, so it is passed in.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local loader = require("tecs.ffi.loader")
local Extractor = require("tecs.Extractor")
local FramePacket = require("tecs.FramePacket")
local components = require("tecs.components")
local sheet = require("tecs.gfx.sheet")
local animation = require("tecs.gfx.animation")
local frametable = require("tecs.gfx.frametable")
local instancelayout = require("tecs.gpu.instancelayout")

local Transform = components.Transform
local Tint = components.Tint
local Renderable = components.Renderable
local Sprite = components.Sprite
local Animation = animation.Animation

local INSTANCE_FLOATS = instancelayout.FLOATS
local BOUND_FLOATS = instancelayout.BOUND_FLOATS

local STEP = 1 / 60
local TICK_HZ = frametable.TICK_HZ
local EPSILON = 1e-5

-- Sheet names are process wide, so each case takes a fresh one.
local nextName = 0
local function uniqueName(prefix)
    nextName = nextName + 1
    return ("%s%d"):format(prefix, nextName)
end

local function near(actual, expected, what)
    assert.is_true(
        math.abs(actual - expected) < EPSILON,
        ("%s: expected %.6f, got %.6f"):format(what or "value", expected, actual)
    )
end

-- Four frames in a row, tagged forward, reverse and pingpong over the same
-- span, so one sheet exercises all three orders. Frames are retimed unevenly
-- on purpose: a table that only ever sees equal durations would pass whatever
-- it did with the boundaries.
local function taggedSheet()
    local builder = sheet.build(uniqueName("tags"), 64, 16)
    builder:frame(0, 0, 16, 16, 40)
    builder:frame(16, 0, 16, 16, 100)
    builder:frame(32, 0, 16, 16, 30)
    builder:frame(48, 0, 16, 16, 130)
    builder:tag("forward", 1, 4, "forward")
    builder:tag("back", 1, 4, "reverse")
    builder:tag("pong", 1, 4, "pingpong")
    return builder:finish()
end

describe("a frame table", function()
    describe("as the host reads it", function()
        it("answers the frame Sheet:frameAt does, at every tick of every tag",
        function()
            local source = taggedSheet()

            -- Tag zero is the whole sheet, and the three named tags follow it.
            for _, name in ipairs({ nil, "forward", "back", "pong" }) do
                local tag = source:tagId(name)
                local id = frametable.register(source, tag)
                local ticks = frametable.tickCount(id)
                assert.is_true(ticks > 0, "a tag runs for at least one tick")

                for tick = 0, ticks - 1 do
                    -- The middle of the tick, which is where the table samples
                    -- and the only point the two are asked to agree on: a
                    -- boundary authored in whole milliseconds falls between two
                    -- samples rather than on one.
                    local time = (tick + 0.5) / TICK_HZ
                    assert.are.equal(source:frameAt(tag, time),
                        frametable.frameAt(id, tick, true),
                        ("tag '%s' tick %d"):format(name or "whole", tick))
                end
            end
        end)

        it("gives one index to a sheet and tag however often it is asked",
        function()
            local source = taggedSheet()
            local first = frametable.register(source, source:tagId("forward"))
            assert.are.equal(first,
                frametable.register(source, source:tagId("forward")))
            assert.are_not.equal(first,
                frametable.register(source, source:tagId("back")))
        end)

        it("wraps a looping tag and parks a one-shot at its last frame",
        function()
            local source = taggedSheet()
            local id = frametable.register(source, source:tagId("forward"))
            local ticks = frametable.tickCount(id)

            assert.are.equal(frametable.frameAt(id, 0, true),
                frametable.frameAt(id, ticks, true))
            assert.are.equal(4, frametable.frameAt(id, ticks * 3, false))
        end)

        it("counts a pingpong cycle without repeating either end", function()
            local source = taggedSheet()
            local id = frametable.register(source, source:tagId("pong"))
            -- 40 + 100 + 30 + 130 forward, then 30 + 100 coming back.
            assert.are.equal(430, frametable.tickCount(id))
        end)

        it("moves its revision when a sheet is bound to an image", function()
            local source = taggedSheet()
            frametable.register(source, 0)
            local before = frametable.revision()
            source:bind(components.Sprite(1, 0.0, 0.0, 0.5, 0.5, 3))
            assert.are_not.equal(before, frametable.revision())
        end)

        it("lays the regions out where the directory says", function()
            local source = taggedSheet()
            source:bind(components.Sprite(1, 0.0, 0.0, 1.0, 1.0, 3))
            local id = frametable.register(source, source:tagId("forward"))

            local data = frametable.floats()
            local entry = (id - 1) * frametable.DIRECTORY_FLOATS
            local entryBase = data[entry]
            local tickBase = data[entry + 1]
            local ticks = data[entry + 2]

            assert.are.equal(frametable.tickCount(id), ticks)

            -- What the shader does: read the tick, then read the entry it
            -- names, and land on the first frame's region and layer.
            local at = data[tickBase]
            assert.are.equal(entryBase, at)
            local u0, v0, u1, v1 = source:uv(1)
            near(data[at], u0, "u0")
            near(data[at + 1], v0, "v0")
            near(data[at + 2], u1, "u1")
            near(data[at + 3], v1, "v1")
            near(data[at + 4], 3, "array layer")
        end)
    end)

    describe("the encoding an instance carries", function()
        it("is a region until something says otherwise", function()
            local target = Sprite(1, 0.25, 0.25, 0.5, 0.5, 2)
            assert.is_false(frametable.isPlayback(target))
            assert.are.equal(0, frametable.playbackOf(target))
        end)

        it("says which playback, from a sign a region cannot have", function()
            local target = Sprite(1, 0.25, 0.25, 0.5, 0.5, 2)
            frametable.encode(target, 7, 120, 16.5, true)
            assert.is_true(frametable.isPlayback(target))
            assert.are.equal(7, frametable.playbackOf(target))
            near(target.v0, 120, "start")
            near(target.u1, 16.5, "rate")
            near(target.v1, 1.0, "loop")
        end)
    end)
end)

describe("playback resolved on the GPU", function()
    local CAPACITY = 16

    -- Staging is a pair of addresses to the extractor and nothing more, so a
    -- plain C array is the whole of what a device supplies it with.
    local function newExtraction()
        local world = tecs.newWorld()
        local extractor = Extractor.create({
            capacity = CAPACITY,
            whiteU0 = 0.0,
            whiteV0 = 0.0,
            whiteU1 = 1.0,
            whiteV1 = 1.0,
        })
        local packet = FramePacket.create()
        local instances = loader.newArray("float[?]", CAPACITY * INSTANCE_FLOATS)
        local bounds = loader.newArray("float[?]", CAPACITY * BOUND_FLOATS)
        extractor:setStaging(0, instances, bounds)
        extractor:install(world, packet)
        world:addPlugin(animation.plugin)
        return world, packet, instances
    end

    -- The four region floats the instance at `index` carries, which is the
    -- playback when the first of them is negative.
    local function regionAt(instances, index)
        local base = index * INSTANCE_FLOATS
        return instances[base + 12], instances[base + 13],
            instances[base + 14], instances[base + 15]
    end

    before_each(function()
        animation.useGPU(true)
    end)

    after_each(function()
        animation.useGPU(false)
    end)

    it("writes the playback into the sprite instead of a region", function()
        local source = taggedSheet()
        source:bind(Sprite(1, 0.0, 0.0, 1.0, 1.0, 3))
        local world, _, instances = newExtraction()

        world:spawn(Transform(10, 20, 0, 1, 0, 16, 16), Tint(1, 1, 1, 1),
            Renderable(), source:sprite(1),
            animation.of(source, "forward"))
        world:update(STEP)

        local id, start, rate, flags = regionAt(instances, 0)
        assert.is_true(id < 0, "a playback is a negative first float")
        near(rate, STEP * TICK_HZ, "one step of clip time at speed one")
        near(flags, 1.0, "looping")
        -- Spawned at the top of its cycle on the step the world has run.
        near(start, world:fixedStepCount(), "start step")
    end)

    it("writes nothing on a step where nothing changed what is playing",
    function()
        local source = taggedSheet()
        source:bind(Sprite(1, 0.0, 0.0, 1.0, 1.0, 3))
        local world, packet = newExtraction()

        world:spawn(Transform(10, 20, 0, 1, 0, 16, 16), Tint(1, 1, 1, 1),
            Renderable(), source:sprite(1),
            animation.of(source, "forward"))

        -- Two updates to settle: the first lays the run out and encodes it.
        world:update(STEP)
        world:update(STEP)

        -- Far enough for the tag to have changed frame several times over.
        for _ = 1, 60 do
            world:update(STEP)
            assert.are.equal(0, packet.rewritten,
                "an animation advancing is not a write")
        end
    end)

    it("rewrites the row when something changes what is playing", function()
        local source = taggedSheet()
        source:bind(Sprite(1, 0.0, 0.0, 1.0, 1.0, 3))
        local world, packet, instances = newExtraction()

        local entity = world:spawn(Transform(10, 20, 0, 1, 0, 16, 16),
            Tint(1, 1, 1, 1), Renderable(), source:sprite(1),
            animation.of(source, "forward"))
        world:update(STEP)
        world:update(STEP)
        assert.are.equal(0, packet.rewritten)

        local before = select(1, regionAt(instances, 0))
        animation.play(world, entity, source, "back")
        world:update(STEP)

        assert.are.equal(1, packet.rewritten)
        local after = select(1, regionAt(instances, 0))
        assert.are_not.equal(before, after, "another tag is another playback")
    end)

    it("holds a paused entity by rate rather than by stopping the clock",
    function()
        local source = taggedSheet()
        source:bind(Sprite(1, 0.0, 0.0, 1.0, 1.0, 3))
        local world, _, instances = newExtraction()

        local entity = world:spawn(Transform(10, 20, 0, 1, 0, 16, 16),
            Tint(1, 1, 1, 1), Renderable(), source:sprite(1),
            animation.of(source, "forward"))
        world:update(STEP)

        world:set(entity, tecs.builtins.Paused)
        world:update(STEP)

        local _, held, rate = regionAt(instances, 0)
        near(rate, 0.0, "a held playback has no rate")
        assert.is_true(held >= 0.0, "and carries the tick it is holding")
    end)

    it("leaves a still sprite carrying its own region", function()
        local source = taggedSheet()
        source:bind(Sprite(1, 0.0, 0.0, 1.0, 1.0, 3))
        local world, _, instances = newExtraction()

        world:spawn(Transform(10, 20, 0, 1, 0, 16, 16), Tint(1, 1, 1, 1),
            Renderable(), source:sprite(2))
        world:update(STEP)

        local u0 = select(1, regionAt(instances, 0))
        assert.is_true(u0 >= 0.0, "no Animation means no playback")
        near(u0, select(1, source:uv(2)), "and the region it was given")
    end)
end)
