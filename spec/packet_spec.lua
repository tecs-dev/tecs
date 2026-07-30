-- The seam between extraction and rendering.
--
-- The renderer specs assert that a world reaches the screen. These assert that
-- the two halves of getting it there are actually separable: the extractor is
-- driven with no device anywhere in the test, and the backend is driven from a
-- packet built by hand with no world anywhere in the test. If either could
-- reach the other, one of these two would need what it does not have.

-- Our build first, so it wins over the ECS repo's own engine tree.
-- The build directory is the build system's to choose, so it is passed in.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local loader = require("tecs.ffi.loader")
local newWindow = require("tecs.platform.window").newWindow
local Device = require("tecs.gpu.Device")
local Texture = require("tecs.gpu.Texture")
local Extractor = require("tecs.Extractor")
local Backend = require("tecs.Backend")
local FramePacket = require("tecs.FramePacket")
local components = require("tecs.components")
local ecs = require("tecs.ecs")
local instancelayout = require("tecs.gpu.instancelayout")

local C = sdl.C
local FORMAT = 4 -- SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM
local SIZE = 64

local Transform = tecs.Transform
local Tint = components.Tint
local Clip = components.Clip
local Renderable = components.Renderable
local PointLight = components.PointLight

local INSTANCE_FLOATS = instancelayout.FLOATS
local INSTANCE_BYTES = instancelayout.BYTES
local BOUND_BYTES = instancelayout.BOUND_BYTES

describe("render extraction", function()
    local CAPACITY = 64

    -- Staging is a pair of addresses to the extractor and nothing more, so a
    -- plain C array is the whole of what a device supplies it with.
    local function newExtraction()
        local world = tecs.ecs.newWorld()
        local extractor = Extractor.create({
            capacity = CAPACITY,
            whiteU0 = 0.0,
            whiteV0 = 0.0,
            whiteU1 = 1 / 512,
            whiteV1 = 1 / 512,
        })
        local packet = FramePacket.create()
        local instances = loader.newArray("float[?]", CAPACITY * INSTANCE_FLOATS)
        local bounds = loader.newArray("float[?]", CAPACITY * 4)
        extractor:setStaging(0, instances, bounds)
        extractor:install(world, packet)
        return world, extractor, packet, instances
    end

    it("reports what it laid out from a known world", function()
        local world, _, packet = newExtraction()
        for _ = 1, 3 do
            world:spawn(Transform(8, 8, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), Renderable())
        end

        world:update(1 / 60)

        assert.are.equal(3, packet.count)
        assert.are.equal(0, packet.dropped)
        assert.are.equal(3, packet.rewritten, "the first frame lays the whole run out")
        assert.are.equal(0, packet.slot, "into the slot it was pointed at")
    end)

    it("marks the bytes it wrote and nothing else", function()
        local world, _, packet = newExtraction()
        for _ = 1, 3 do
            world:spawn(Transform(8, 8, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), Renderable())
        end

        world:update(1 / 60)

        assert.are.equal(1, packet.instanceRanges.count, "one archetype is one contiguous run")
        local offset, size = packet.instanceRanges:at(0)
        assert.are.equal(0, offset)
        assert.are.equal(3 * INSTANCE_BYTES, size)

        local boundsOffset, boundsSize = packet.boundsRanges:at(0)
        assert.are.equal(0, boundsOffset)
        assert.are.equal(3 * BOUND_BYTES, boundsSize)
    end)

    it("marks nothing on a frame where nothing changed", function()
        local world, _, packet = newExtraction()
        world:spawn(Transform(8, 8, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), Renderable())

        world:update(1 / 60)
        world:update(1 / 60)

        assert.are.equal(1, packet.count, "the instance is still resident")
        assert.are.equal(0, packet.rewritten)
        assert.are.equal(0, packet.instanceRanges.count, "a still frame gives the backend nothing to copy")
    end)

    it("counts the blended instances the scene holds, and stops counting them", function()
        -- One packet is created per renderer and reused for the life of it, so
        -- the count has to describe the frame rather than the history: totalled
        -- from what each run last wrote, and assigned rather than added to. An
        -- accumulator here reads as "anything has ever blended", which pins the
        -- backend's forward lane on for every later frame including the ones with
        -- nothing in it to blend.
        local world, _, packet = newExtraction()
        local entity = world:spawn(Transform(8, 8, 0, 1, 0, 4, 4), Tint(1, 1, 1, 0.5), Renderable())

        world:update(1 / 60)
        assert.are.equal(1, packet.blendCount)

        -- A second frame that rewrites nothing. The row is still resident and
        -- still blended, so the count is what it was and not twice it.
        world:update(1 / 60)
        assert.are.equal(0, packet.rewritten, "and the run was not rewritten to arrive at it")
        assert.are.equal(1, packet.blendCount)

        world:getMut(entity, Tint).a = 1.0
        world:update(1 / 60)
        assert.are.equal(0, packet.blendCount, "an opaque scene reports nothing blended")
    end)

    it("reports rows it could not fit", function()
        local world, _, packet = newExtraction()
        for _ = 1, CAPACITY + 6 do
            world:spawn(Transform(0, 0, 0, 1, 0, 1, 1), Tint(1, 1, 1, 1), Renderable())
        end

        world:update(1 / 60)

        assert.are.equal(CAPACITY, packet.count)
        assert.are.equal(6, packet.dropped)
    end)

    it("writes instances into the staging it was handed", function()
        local world, _, packet, instances = newExtraction()
        world:spawn(Transform(12, 34, 0, 1, 0, 4, 4), Tint(0.25, 0.5, 0.75, 1), Renderable())

        world:update(1 / 60)

        assert.are.equal(12, instances[4], "the origin is where the row said")
        assert.are.equal(34, instances[5])
        assert.are.equal(0.25, instances[8])
        assert.are.equal(1, packet.count)
    end)

    it("copies the camera rather than referring to it", function()
        local world, extractor, packet = newExtraction()
        extractor.camera.x = 200
        extractor.camera.y = 100
        extractor.camera.zoom = 2.0

        world:update(1 / 60)
        assert.are.equal(200, packet.cameraX)
        assert.are.equal(100, packet.cameraY)
        assert.are.equal(2.0, packet.cameraZoom)

        -- Moving it afterwards must not move the frame that was already built.
        extractor.camera.x = 999
        assert.are.equal(200, packet.cameraX)
    end)

    it("packs light entities into the packet's own storage", function()
        local world, _, packet = newExtraction()
        world:spawn(Transform(10, 20, 0, 1, 0, 1, 1), PointLight(12.0, 30.0, 1.0, 0.5, 0.25, 4.0))

        world:update(1 / 60)

        assert.are.equal(1, packet.lightCount)
        assert.are.equal(10, packet.lights[0])
        assert.are.equal(20, packet.lights[1])
        assert.are.equal(12, packet.lights[2], "height")
        assert.are.equal(30, packet.lights[3], "radius")
        assert.are.equal(4, packet.lights[7], "intensity")

        -- Cleared rather than accumulated, so a light that went away goes away.
        world:update(1 / 60)
        assert.are.equal(1, packet.lightCount)
    end)

    it("tells whoever owns the packet that it is filled", function()
        local world = tecs.ecs.newWorld()
        local extractor = Extractor.create({
            capacity = CAPACITY,
            whiteU0 = 0.0,
            whiteV0 = 0.0,
            whiteU1 = 1.0,
            whiteV1 = 1.0,
        })
        local packet = FramePacket.create()
        extractor:setStaging(
            0,
            loader.newArray("float[?]", CAPACITY * INSTANCE_FLOATS),
            loader.newArray("float[?]", CAPACITY * 4)
        )

        local seen = 0
        extractor:install(world, packet, function()
            seen = seen + 1
        end)
        world:update(1 / 60)
        world:update(1 / 60)
        assert.are.equal(2, seen, "once per frame, after the packet is filled")
    end)
end)

-- Runs with room to grow in them.
--
-- Packed, a run cannot grow without shifting every run after it, so one spawn
-- rewrites the whole scene. These assert the other layout: what a spawn costs,
-- what the slack costs, and that the slack cannot draw.
describe("reserved instance runs", function()
    local CAPACITY = 4096

    local function newExtraction(reserveRuns, capacity)
        capacity = capacity or CAPACITY
        local world = tecs.ecs.newWorld()
        local extractor = Extractor.create({
            capacity = capacity,
            reserveRuns = reserveRuns,
            whiteU0 = 0.0,
            whiteV0 = 0.0,
            whiteU1 = 1 / 512,
            whiteV1 = 1 / 512,
        })
        local packet = FramePacket.create()
        local instances = loader.newArray("float[?]", capacity * INSTANCE_FLOATS)
        local bounds = loader.newArray("float[?]", capacity * 4)
        extractor:setStaging(0, instances, bounds)
        extractor:install(world, packet)
        return world, extractor, packet, instances, bounds
    end

    -- A slot whose bound is out where no finite view reaches. Read back
    -- through float32, so the constant does not survive as itself.
    local function isHidden(bounds, slot)
        return bounds[slot * 4] > 1e29 and bounds[slot * 4 + 1] > 1e29
    end

    -- Two archetypes that differ by a column the write path reads, so the one
    -- that is not spawned into is a real run and not a bookkeeping entry.
    local function scatter(world, count, clipped)
        for _ = 1, count do
            if clipped then
                world:spawn(Transform(8, 8, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), Clip(0), Renderable())
            else
                world:spawn(Transform(8, 8, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), Renderable())
            end
        end
    end

    -- A run apiece for as many archetypes as a scene wants. Sixteen slots is
    -- the floor a compaction reserves each of them, and five hundred and
    -- twelve slots is the least it will rewrite the scene to reclaim, so a
    -- buffer only wide enough for the rows themselves takes more than
    -- thirty-two runs to arrive at. Forty-one is the first round number past
    -- that with one left over to drift the extent with.
    local TAGS = {}
    for index = 1, 41 do
        local container = {}
        ecs.newComponent({
            name = "PacketRunTag" .. index,
            container = container,
            fields = { "value" },
            defaults = { 0 },
        })
        TAGS[index] = container
    end

    local function scatterTagged(world, tag, count)
        local ids = {}
        for _ = 1, count do
            ids[#ids + 1] = world:spawn(Transform(8, 8, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), TAGS[tag](1), Renderable())
        end
        return ids
    end

    it("charges a spawn the archetype it spawned into and no other", function()
        local world, _, packet = newExtraction(true)
        scatter(world, 40, false)
        scatter(world, 40, true)
        world:update(1 / 60)
        world:update(1 / 60)
        assert.are.equal(0, packet.rewritten, "a still frame writes nothing")

        scatter(world, 1, false)
        world:update(1 / 60)

        assert.are.equal(41, packet.rewritten, "the archetype that grew, and only it")
    end)

    it("charges the same spawn the whole scene when the runs are packed", function()
        -- The measurement the reservation exists to change, asserted so the
        -- one above is a difference rather than a number.
        local world, _, packet = newExtraction(false)
        scatter(world, 40, false)
        scatter(world, 40, true)
        world:update(1 / 60)
        world:update(1 / 60)

        scatter(world, 1, false)
        world:update(1 / 60)

        assert.are.equal(81, packet.rewritten, "one spawn shifts every run after it")
    end)

    it("dispatches the cull over the slack as well as the rows", function()
        local world, _, packet = newExtraction(true)
        scatter(world, 40, false)
        world:update(1 / 60)

        -- A quarter, and never fewer than sixteen slots.
        assert.are.equal(56, packet.count, "the extent is the run, its room to grow included")
        assert.are.equal(40, packet.rewritten, "and only the rows are written as instances")
    end)

    it("puts a slot nothing owns where no view can see it", function()
        local world, _, packet, instances, bounds = newExtraction(true)
        scatter(world, 4, false)
        world:update(1 / 60)

        assert.are.equal(20, packet.count)
        for slot = 4, 19 do
            assert.is_true(isHidden(bounds, slot), "a center no view reaches")
            assert.are.equal(0, bounds[slot * 4 + 2], "and no extent to overlap a view with")
            assert.are.equal(0, bounds[slot * 4 + 3])

            local base = slot * INSTANCE_FLOATS
            assert.are.equal(0, instances[base + 1], "a zeroed instance has no size")
            assert.is_true(instances[base + 3] > 0.99, "and occludes nothing")
        end
    end)

    it("marks the hidden slots so they reach the device once", function()
        local world, _, packet = newExtraction(true)
        scatter(world, 4, false)
        world:update(1 / 60)

        local offset, size = packet.instanceRanges:at(0)
        assert.are.equal(0, offset)
        assert.are.equal(20 * INSTANCE_BYTES, size, "the rows and the slack in one span")

        world:update(1 / 60)
        assert.are.equal(0, packet.instanceRanges.count, "and never again while they stay unused")
    end)

    it("hides the rows a despawn gave back", function()
        local world, _, packet, _, bounds = newExtraction(true)
        local ids = {}
        for _ = 1, 8 do
            ids[#ids + 1] = world:spawn(Transform(8, 8, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), Renderable())
        end
        world:update(1 / 60)
        assert.are.equal(24, packet.count)

        world:despawn(ids[8])
        world:despawn(ids[7])
        world:update(1 / 60)

        assert.are.equal(24, packet.count, "the run keeps the slots it was given")
        assert.is_true(isHidden(bounds, 6), "and the rows it gave back stop drawing")
        assert.is_true(isHidden(bounds, 7))
    end)

    it("hides a run whose archetype went away", function()
        local world, _, packet, _, bounds = newExtraction(true)
        local ids = {}
        for _ = 1, 8 do
            ids[#ids + 1] = world:spawn(Transform(8, 8, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), Renderable())
        end
        world:update(1 / 60)

        for _, id in ipairs(ids) do
            world:despawn(id)
        end
        world:update(1 / 60)

        for slot = 0, packet.count - 1 do
            assert.is_true(isHidden(bounds, slot), "every slot the run held")
        end
    end)

    it("moves a run that outgrew its reservation and leaves the rest alone", function()
        local world, _, packet = newExtraction(true)
        scatter(world, 100, false)
        scatter(world, 100, true)
        world:update(1 / 60)
        assert.are.equal(232, packet.count, "two runs and the floor each was given")

        scatter(world, 30, false)
        world:update(1 / 60)

        assert.are.equal(130, packet.rewritten, "the run that moved, whole, and nothing else")
        assert.is_true(packet.count > 232, "and it was given room again where it landed")
    end)

    it("reclaims an extent that growth left behind", function()
        local world, _, packet = newExtraction(true)
        local ids = {}
        for _ = 1, 1000 do
            ids[#ids + 1] = world:spawn(Transform(8, 8, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), Renderable())
        end
        world:update(1 / 60)
        assert.are.equal(1016, packet.count)

        for index = 101, 1000 do
            world:despawn(ids[index])
        end
        world:update(1 / 60)

        assert.are.equal(116, packet.count, "a hundred rows occupy what a hundred rows need")
        assert.are.equal(100, packet.rewritten, "which costs the rows it moved")

        world:update(1 / 60)
        assert.are.equal(116, packet.count)
        assert.are.equal(0, packet.rewritten, "and a compaction cannot ask for another one")
    end)

    it("reclaims one a compaction would lay out below its widest reservation", function()
        -- Forty-one runs in a buffer with no room for a reservation apiece, so
        -- a compaction gives up the slack and lays the rows out packed. What
        -- the runs would like is therefore not what they would get, and
        -- measuring the extent against the wider of the two says a compaction
        -- would make things worse: the gap reads as negative and the voluntary
        -- reclaim never fires, leaving the cull dispatched over an extent two
        -- and a half times the rows in it for as long as the scene lasts.
        local world, _, packet = newExtraction(true, 1024)
        for tag = 1, 40 do
            scatterTagged(world, tag, 10)
        end
        local drifting = scatterTagged(world, 41, 600)
        world:update(1 / 60)
        assert.are.equal(1000, packet.count, "no room for slack, so the rows and nothing else")

        for _, id in ipairs(drifting) do
            world:despawn(id)
        end
        world:update(1 / 60)
        assert.are.equal(400, packet.count, "the rows that are left occupy what they need")

        world:update(1 / 60)
        assert.are.equal(400, packet.count)
        assert.are.equal(0, packet.rewritten, "and a compaction cannot ask for another one")
    end)

    it("drops exactly what a packed layout would have dropped", function()
        local reserved, _, reservedPacket = newExtraction(true, 64)
        scatter(reserved, 70, false)
        reserved:update(1 / 60)

        local packed, _, packedPacket = newExtraction(false, 64)
        scatter(packed, 70, false)
        packed:update(1 / 60)

        assert.are.equal(packedPacket.dropped, reservedPacket.dropped, "slack is never taken from the rows")
        assert.are.equal(6, reservedPacket.dropped)
        assert.are.equal(64, reservedPacket.count)
    end)

    it("leaves a producer's run alone when an archetype grows", function()
        -- Producers are laid out after the archetypes, so packed they move
        -- whenever anything spawns. Reserved they move when the extent does,
        -- which a spawn into a run with room in it does not.
        local world, extractor, packet, instances = newExtraction(true)
        local writes = 0
        local producer = {
            count = function()
                return 4
            end,
            takeDirty = function()
                return {}
            end,
            blended = function()
                return 0
            end,
            write = function(_, floats, bounds, base, first, last)
                writes = writes + 1
                for slot = base + first - 1, base + last - 1 do
                    floats[slot * INSTANCE_FLOATS + 4] = 7.0
                    bounds[slot * 4] = 1.0
                end
            end,
        }
        extractor:addProducer(producer)

        scatter(world, 40, false)
        world:update(1 / 60)
        assert.are.equal(1, writes, "the first sync lays the producer's run out")
        assert.are.equal(60, packet.count, "and it sits after the archetype's room to grow")
        assert.are.equal(7.0, instances[56 * INSTANCE_FLOATS + 4], "where the producer wrote it")

        scatter(world, 1, false)
        world:update(1 / 60)
        assert.are.equal(1, writes, "a spawn the run had room for does not move it")

        -- Past the reservation, so the extent moves and the producer with it.
        scatter(world, 30, false)
        world:update(1 / 60)
        assert.are.equal(2, writes, "and one that moves the extent does")
    end)

    it("keeps giving the same answer as the buffer fills", function()
        -- Growing into a buffer with nothing left is where the reservation has
        -- to give way frame after frame, so this is run rather than sampled.
        local reserved, _, reservedPacket = newExtraction(true, 64)
        local packed, _, packedPacket = newExtraction(false, 64)
        for _ = 1, 12 do
            scatter(reserved, 9, false)
            scatter(reserved, 3, true)
            reserved:update(1 / 60)
            scatter(packed, 9, false)
            scatter(packed, 3, true)
            packed:update(1 / 60)
            assert.are.equal(packedPacket.dropped, reservedPacket.dropped, "the same rows are dropped")
            assert.is_true(reservedPacket.count <= 64, "and the extent stays inside the buffer")
        end
        assert.is_true(reservedPacket.dropped > 0, "the buffer did fill")
    end)
end)

-- Rewriting the rows a structural change wrote rather than the archetype's run.
--
-- A row moving into an archetype has every column newly written at that row, so
-- the ECS dirties every column and the extractor resyncs the whole run. These
-- assert the other reading of the same fact: which rows moved is recorded, the
-- rest of the run did not change, and a spawn can cost what it wrote. The last
-- test is the guard the rest of them are not -- it compares the bytes both paths
-- leave behind, because a rewrite that is narrower than the truth produces a
-- stale instance and no error anywhere.
describe("partial structural rewrites", function()
    local CAPACITY = 1024

    local function newExtraction(partial, reserveRuns)
        local world = tecs.ecs.newWorld()
        local extractor = Extractor.create({
            capacity = CAPACITY,
            reserveRuns = reserveRuns ~= false,
            partialRewrites = partial,
            whiteU0 = 0.0,
            whiteV0 = 0.0,
            whiteU1 = 1 / 512,
            whiteV1 = 1 / 512,
        })
        local packet = FramePacket.create()
        local instances = loader.newArray("float[?]", CAPACITY * INSTANCE_FLOATS)
        local bounds = loader.newArray("float[?]", CAPACITY * 4)
        extractor:setStaging(0, instances, bounds)
        extractor:install(world, packet)
        return {
            world = world,
            packet = packet,
            instances = instances,
            bounds = bounds,
            live = {},
        }
    end

    -- One archetype throughout, which is the case reserving cannot help with
    -- and the one this whole block exists for.
    -- Opaque unless an alpha is named. A translucent row is routed to the forward
    -- pass, which is a second thing a rewrite of it settles besides its bytes:
    -- how many of the run's rows the frame reports as blended.
    local function spawn(side, alpha)
        local id = side.world:spawn(Transform(8, 8, 0, 1, 0, 4, 4), Tint(1, 1, 1, alpha or 1), Renderable())
        side.live[#side.live + 1] = id
        return id
    end

    it("charges one spawn into a large archetype the row it wrote", function()
        local side = newExtraction(true)
        for _ = 1, 200 do
            spawn(side)
        end
        side.world:update(1 / 60)
        side.world:update(1 / 60)
        assert.are.equal(0, side.packet.rewritten, "a still frame writes nothing")

        spawn(side)
        side.world:update(1 / 60)
        assert.are.equal(1, side.packet.rewritten, "the row the placement wrote, not the archetype's population")
        assert.are.equal(1, side.packet.instanceRanges.count, "and one span names it")
        local offset, size = side.packet.instanceRanges:at(0)
        assert.are.equal(200 * INSTANCE_BYTES, offset, "at the row it landed on")
        assert.are.equal(INSTANCE_BYTES, size)
    end)

    it("charges the same spawn the whole run without it", function()
        -- The measurement above is a difference rather than a number only if
        -- this is what it is a difference from.
        local side = newExtraction(false)
        for _ = 1, 200 do
            spawn(side)
        end
        side.world:update(1 / 60)
        side.world:update(1 / 60)

        spawn(side)
        side.world:update(1 / 60)
        assert.are.equal(201, side.packet.rewritten, "one spawn rewrites the archetype it spawned into")
    end)

    it("charges churn the rows it moved and the rows it appended", function()
        local side = newExtraction(true)
        for _ = 1, 200 do
            spawn(side)
        end
        side.world:update(1 / 60)
        side.world:update(1 / 60)

        -- The two lowest rows, so each removal swaps the run's last row down
        -- rather than popping from the end, and the two placements then land as
        -- a suffix where the removals left room.
        side.world:despawn(side.live[1])
        side.world:despawn(side.live[2])
        spawn(side)
        spawn(side)
        side.world:update(1 / 60)

        assert.are.equal(4, side.packet.rewritten, "two swap-pop rows and two appended rows")
    end)

    it("still rewrites the run for a value write", function()
        -- A value write names a column and says nothing about which rows it
        -- touched, so there is nothing narrower to do than the run.
        local side = newExtraction(true)
        for _ = 1, 200 do
            spawn(side)
        end
        side.world:update(1 / 60)
        side.world:update(1 / 60)

        side.world:set(side.live[5], Transform(9, 9, 0, 1, 0, 4, 4))
        side.world:update(1 / 60)
        assert.are.equal(200, side.packet.rewritten)
    end)

    it("still rewrites the run for markAllComponentsDirty", function()
        -- The one way a game can say it wrote raw cdata across every row of
        -- every column, so it has to defeat the narrower path outright: the
        -- rows it wrote are exactly what it did not say.
        local side = newExtraction(true)
        for _ = 1, 200 do
            spawn(side)
        end
        side.world:update(1 / 60)
        side.world:update(1 / 60)

        local marked = false
        side.world:forEachArchetype(function(archetype)
            if not marked and archetype.entities[0] == 200 then
                archetype:markAllComponentsDirty()
                marked = true
            end
        end)
        assert.is_true(marked, "the run's archetype was found")

        side.world:update(1 / 60)
        assert.are.equal(200, side.packet.rewritten)
    end)

    it("hides the rows a despawn gave back", function()
        local side = newExtraction(true)
        for _ = 1, 8 do
            spawn(side)
        end
        side.world:update(1 / 60)

        side.world:despawn(side.live[8])
        side.world:despawn(side.live[7])
        side.world:update(1 / 60)

        assert.is_true(side.bounds[6 * 4] > 1e29, "a slot the run gave back stops drawing")
        assert.is_true(side.bounds[7 * 4] > 1e29)
    end)

    ---------------------------------------------------------------------------
    -- The blend count under a partial rewrite
    --
    -- A partial rewrite writes some of a run's rows, so the blended rows it
    -- counts are that subset's and not the run's. Storing the subset's answer
    -- reports fewer blended instances than the frame holds, and the backend
    -- skips the entire forward lane at zero, so under-reporting here is every
    -- blended instance in the scene going missing. These are the cases where the
    -- two features have to be right together rather than each on its own.
    ---------------------------------------------------------------------------

    it("keeps a resident blended row counted when a spawn elsewhere is all that moved", function()
        local side = newExtraction(true)
        spawn(side, 0.5)
        for _ = 1, 32 do
            spawn(side)
        end
        side.world:update(1 / 60)
        assert.are.equal(1, side.packet.blendCount, "the translucent row is routed forward")

        -- One placement, landing as a suffix well past the blended row at row
        -- one. The partial path rewrites the appended row and nothing else, so a
        -- count taken from what it wrote would be zero and the lane would be
        -- skipped with the blended row still resident.
        spawn(side)
        side.world:update(1 / 60)

        assert.are.equal(1, side.packet.rewritten, "the placement wrote one row")
        assert.are.equal(1, side.packet.blendCount, "and the blended row it did not touch is still counted")
    end)

    it("counts a blended row a swap-pop moved to another slot", function()
        -- The despawn takes row one, so the run's last row is swapped down into
        -- it. Both the row that left and the row that arrived are opaque, and the
        -- blended row at row two neither moves nor is rewritten: what the count
        -- has to survive is the run's rows being shuffled underneath it.
        local side = newExtraction(true)
        local first = spawn(side)
        spawn(side, 0.5)
        for _ = 1, 16 do
            spawn(side)
        end
        side.world:update(1 / 60)
        assert.are.equal(1, side.packet.blendCount)

        side.world:despawn(first)
        side.world:update(1 / 60)

        assert.are.equal(1, side.packet.rewritten, "one swap-pop row")
        assert.are.equal(1, side.packet.blendCount, "and the blended row is still one of the run's")
    end)

    it("stops counting a blended row a swap-pop wrote over", function()
        -- The other direction, and the reason a run that holds a blended row is
        -- recounted rather than adjusted by what the residue wrote. The blended
        -- row is the run's last, so despawning row one swaps it down into row one
        -- and the run gives up the slot it came from. Nothing was added and one
        -- row was written, and the answer has to be one rather than two.
        local side = newExtraction(true)
        local first = spawn(side)
        for _ = 1, 16 do
            spawn(side)
        end
        local translucent = spawn(side, 0.5)
        side.world:update(1 / 60)
        assert.are.equal(1, side.packet.blendCount)

        side.world:despawn(first)
        side.world:update(1 / 60)
        assert.are.equal(1, side.packet.blendCount, "the row moved rather than multiplied")

        -- And now the blended row itself, which is row one: the run's opaque last
        -- row swaps down over it and the scene blends nothing.
        side.world:despawn(translucent)
        side.world:update(1 / 60)
        assert.are.equal(0, side.packet.blendCount, "a blended row the run gave up stops being counted")
    end)

    -- One seeded op stream, generated once and applied to two worlds, so the
    -- pair differs in nothing but which rows each sync decided to write. Every
    -- float of both buffers is compared after every frame: a row the partial
    -- path skipped and should not have is a difference here and nothing
    -- anywhere else.
    --
    -- A third of the spawns are translucent, and the frame's blended count is
    -- compared beside the bytes. That is not decoration: the count is derived
    -- from the rows a sync wrote, so a partial rewrite has a subset's answer
    -- where a whole-run rewrite has the run's, and the two features are wrong
    -- together in a way neither is wrong alone. Every combination this reaches
    -- for is here, because the stream shuffles blended rows between slots,
    -- appends them past opaque ones, and drops them off the end of a run.
    --
    -- One renderable archetype, which is the case reserving cannot help with
    -- and the one this exists for. It is also what makes the comparison sound:
    -- a reserved layout hands out offsets while walking a table keyed by
    -- archetype, so two worlds holding two archetypes apiece can lay their runs
    -- out in either order and the buffers would differ over that rather than
    -- over anything either path decided.
    local function differential(reserveRuns)
        local seed = 20260729
        local function nextInt(bound)
            seed = (seed * 1103515245 + 12345) % 2147483648
            return math.floor(seed / 65536) % bound + 1
        end

        local ops = {}
        local population = 0
        for frame = 1, 80 do
            for _ = 1, nextInt(8) - 1 do
                if population > 0 then
                    ops[#ops + 1] = { "despawn", nextInt(population) }
                    population = population - 1
                end
            end
            for _ = 1, nextInt(8) - 1 do
                -- Translucent every third spawn or so, which is what makes a run
                -- hold a mix and makes the blended count something a partial
                -- rewrite can get wrong.
                ops[#ops + 1] = { "spawn", nextInt(3) == 1 and 0.5 or 1 }
                population = population + 1
            end
            if population > 0 and nextInt(4) == 1 then
                ops[#ops + 1] = { "move", nextInt(population), nextInt(64), nextInt(64) }
            end
            -- A value write to Tint, which flips a row's lane and takes the
            -- whole-run path on both sides: it is the case the partial path is
            -- not allowed to narrow, and the count has to follow it too.
            if population > 0 and nextInt(6) == 1 then
                ops[#ops + 1] = { "tint", nextInt(population), nextInt(2) == 1 and 0.25 or 1 }
            end
            ops[#ops + 1] = { "frame", frame }
        end

        local full = newExtraction(false, reserveRuns)
        local part = newExtraction(true, reserveRuns)

        local function apply(side, op)
            if op[1] == "spawn" then
                spawn(side, op[2])
            elseif op[1] == "despawn" then
                local index = op[2]
                local live = side.live
                side.world:despawn(live[index])
                live[index] = live[#live]
                live[#live] = nil
            elseif op[1] == "move" then
                side.world:set(side.live[op[2]], Transform(op[3], op[4], 0, 1, 0, 4, 4))
            elseif op[1] == "tint" then
                side.world:getMut(side.live[op[2]], Tint).a = op[3]
            else
                side.world:update(1 / 60)
            end
        end

        local savings = 0
        local blended = 0
        for _, op in ipairs(ops) do
            apply(full, op)
            apply(part, op)
            if op[1] == "frame" then
                assert.are.equal(full.packet.count, part.packet.count, "frame " .. op[2] .. ": the same extent")
                -- Exact rather than at least, because the partial path can be
                -- exact and settling for a bound would let it drift up to the
                -- run's whole length under churn and stop meaning anything.
                assert.are.equal(
                    full.packet.blendCount,
                    part.packet.blendCount,
                    "frame " .. op[2] .. ": the same blended count"
                )
                for index = 0, full.packet.count * INSTANCE_FLOATS - 1 do
                    if full.instances[index] ~= part.instances[index] then
                        assert.are.equal(
                            full.instances[index],
                            part.instances[index],
                            ("frame %d: instance float %d"):format(op[2], index)
                        )
                    end
                end
                for index = 0, full.packet.count * 4 - 1 do
                    if full.bounds[index] ~= part.bounds[index] then
                        assert.are.equal(
                            full.bounds[index],
                            part.bounds[index],
                            ("frame %d: bounds float %d"):format(op[2], index)
                        )
                    end
                end
                savings = savings + (full.packet.rewritten - part.packet.rewritten)
                if part.packet.blendCount > blended then
                    blended = part.packet.blendCount
                end
            end
        end
        return savings, blended
    end

    it("writes the same bytes as a whole-run rewrite, reserved", function()
        local savings, blended = differential(true)
        assert.is_true(savings > 0, "and wrote fewer rows somewhere, or this proves nothing")
        assert.is_true(blended > 1, "and blended something while doing it, or the count proves nothing")
    end)

    it("writes the same bytes as a whole-run rewrite, packed", function()
        -- Packed, a length that moved relays the scene out and the partial path
        -- almost never runs. What this covers is that it never runs wrongly.
        local savings, blended = differential(false)
        assert.is_true(savings >= 0)
        assert.is_true(blended > 1)
    end)
end)

-- A structural change in a phase after RenderFirst, which is the phase
-- extraction runs in.
--
-- The frame that made the change has already extracted, so the rows it moved
-- are owed to the next frame's sync; the component bits it set are cleared at
-- the end of the same update, before that sync ever looks at them. A despawn
-- and a spawn together leave the run the length it already was, so the run's
-- extent says nothing either, and the row a swap-pop overwrote keeps drawing
-- the entity the world despawned.
describe("structural change after extraction", function()
    local CAPACITY = 64
    local POPULATION = 8

    local function newExtraction(partial)
        local world = tecs.ecs.newWorld()
        local extractor = Extractor.create({
            capacity = CAPACITY,
            partialRewrites = partial,
            whiteU0 = 0.0,
            whiteV0 = 0.0,
            whiteU1 = 1 / 512,
            whiteV1 = 1 / 512,
        })
        local packet = FramePacket.create()
        local instances = loader.newArray("float[?]", CAPACITY * INSTANCE_FLOATS)
        local bounds = loader.newArray("float[?]", CAPACITY * 4)
        extractor:setStaging(0, instances, bounds)
        extractor:install(world, packet)
        return world, packet, bounds
    end

    -- A bound's center is the quad's middle, and an unpivoted quad's middle is
    -- its position, so x names which entity a row is holding.
    local function centerX(bounds, row)
        return bounds[(row - 1) * 4]
    end

    local function spawnAt(world, x)
        return world:spawn(Transform(x, 0, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), Renderable())
    end

    -- Despawns the run's first row and spawns a replacement, once, from a
    -- system in `phase`. The despawn swaps the last row down into row one and
    -- the spawn appends where the despawn left room, so two rows are holding
    -- something else and the length is what it was.
    local function churn(partial, phase)
        local world, packet, bounds = newExtraction(partial)
        local ids = {}
        for row = 1, POPULATION do
            ids[row] = spawnAt(world, row * 10)
        end

        local churned = false
        world:addSystem({
            name = "spec.ChurnAfterExtraction",
            phase = phase,
            run = function()
                if churned then
                    return
                end
                churned = true
                world:despawn(ids[1])
                spawnAt(world, 999)
            end,
        })

        world:update(1 / 60)
        assert.are.equal(POPULATION, packet.count, "the first frame lays the population out")
        assert.are.equal(10, centerX(bounds, 1), "and the churn lands after it extracted")

        world:update(1 / 60)
        assert.is_true(churned, "the churning system ran")
        assert.are.equal(POPULATION, packet.count, "the churn nets no length change")
        assert.are.equal(POPULATION * 10, centerX(bounds, 1), "the swap-pop's row draws what moved into it")
        assert.are.equal(999, centerX(bounds, POPULATION), "and the appended row draws the spawn")
    end

    for _, phase in ipairs({ "PostRender", "RenderLast", "Last" }) do
        it("rewrites a swap-pop made in " .. phase, function()
            churn(false, tecs.ecs.phases[phase])
        end)

        it("rewrites a swap-pop made in " .. phase .. ", partial", function()
            -- The narrower path already survives this: the structural count is
            -- monotonic, and the residue window opened where the frame's clear
            -- closed the last one, so a count from before that window is
            -- refused rather than believed.
            churn(true, tecs.ecs.phases[phase])
        end)
    end
end)

-- A value write in a phase after RenderFirst, which is the phase extraction
-- runs in.
--
-- The frame that made the write has already extracted, so what it changed is
-- owed to the next frame's sync; the component bit it set is cleared at the end
-- of the same update, before that sync ever looks at it. A value write moves no
-- row and changes no length, so the bit was the only evidence it ever happened:
-- the row keeps drawing the value the entity held before it, and keeps drawing
-- it forever rather than one frame late.
describe("value write after extraction", function()
    local CAPACITY = 64
    local POPULATION = 8

    local function newExtraction(partial)
        local world = tecs.ecs.newWorld()
        local extractor = Extractor.create({
            capacity = CAPACITY,
            partialRewrites = partial,
            whiteU0 = 0.0,
            whiteV0 = 0.0,
            whiteU1 = 1 / 512,
            whiteV1 = 1 / 512,
        })
        local packet = FramePacket.create()
        local instances = loader.newArray("float[?]", CAPACITY * INSTANCE_FLOATS)
        local bounds = loader.newArray("float[?]", CAPACITY * 4)
        extractor:setStaging(0, instances, bounds)
        extractor:install(world, packet)
        return world, packet, bounds
    end

    -- A bound's center is the quad's middle, and an unpivoted quad's middle is
    -- its position, so x names which entity a row is holding and what it holds.
    local function centerX(bounds, row)
        return bounds[(row - 1) * 4]
    end

    local function spawnAt(world, x)
        return world:spawn(Transform(x, 0, 0, 1, 0, 4, 4), Tint(1, 1, 1, 1), Renderable())
    end

    local function population(world)
        local ids = {}
        for row = 1, POPULATION do
            ids[row] = spawnAt(world, row * 10)
        end
        return ids
    end

    -- Moves one row of the run, once, from a system in `phase`.
    local function move(partial, phase)
        local world, packet, bounds = newExtraction(partial)
        local ids = population(world)

        local wrote = false
        world:addSystem({
            name = "spec.WriteAfterExtraction",
            phase = phase,
            run = function()
                if wrote then
                    return
                end
                wrote = true
                world:getMut(ids[3], Transform).x = 555
            end,
        })

        world:update(1 / 60)
        assert.are.equal(POPULATION, packet.count, "the first frame lays the population out")
        assert.are.equal(30, centerX(bounds, 3), "and the write lands after it extracted")

        world:update(1 / 60)
        assert.is_true(wrote, "the writing system ran")
        assert.are.equal(555, centerX(bounds, 3), "the next sync writes what the frame's bits were cleared of")
        assert.are.equal(POPULATION, packet.rewritten, "as the run, because a value write names no rows")

        -- The count is monotonic rather than carried forward, so the write stops
        -- being owed once it has been paid: a run nothing has written since is
        -- left alone, which is the property a carry-forward bit would lose.
        world:update(1 / 60)
        assert.are.equal(0, packet.rewritten, "and the frame after it writes nothing")
    end

    for _, phase in ipairs({ "PostRender", "RenderLast", "Last" }) do
        it("rewrites a value write made in " .. phase, function()
            move(false, tecs.ecs.phases[phase])
        end)

        it("rewrites a value write made in " .. phase .. ", partial", function()
            -- A value write says nothing about which rows it touched, so the
            -- narrower path has nothing to offer it either way: what this pins
            -- is that the write is noticed at all, and that noticing it does not
            -- let the residue answer for it.
            move(true, tecs.ecs.phases[phase])
        end)
    end

    -- Two writes to one column in one frame, one on each side of extraction.
    --
    -- The first sets the frame's dirty bit and the second finds it already set,
    -- so a count bumped only where that bit goes from clear to set does not move
    -- for the second write at all. The sync has already read the first by then,
    -- and the second is the one it has not seen: deduplicating the count against
    -- a bit whose window is the frame loses it outright, which is the defect
    -- rather than a narrower version of it.
    local function moveTwice(partial)
        local world, packet, bounds = newExtraction(partial)
        local ids = population(world)

        local wrote = false
        world:addSystem({
            name = "spec.WriteBeforeExtraction",
            phase = tecs.ecs.phases.PostUpdate,
            run = function()
                if wrote then
                    return
                end
                world:getMut(ids[3], Transform).x = 111
            end,
        })
        world:addSystem({
            name = "spec.WriteAfterExtraction",
            phase = tecs.ecs.phases.Last,
            run = function()
                if wrote then
                    return
                end
                wrote = true
                world:getMut(ids[3], Transform).x = 555
            end,
        })

        world:update(1 / 60)
        assert.are.equal(111, centerX(bounds, 3), "the sync took the write from before it ran")

        world:update(1 / 60)
        assert.is_true(wrote, "both systems ran")
        assert.are.equal(555, centerX(bounds, 3), "and the next one takes the write from after")
    end

    it("takes the second of two writes to one column in one frame", function()
        moveTwice(false)
    end)

    it("takes the second of two writes to one column in one frame, partial", function()
        moveTwice(true)
    end)

    it("counts a blended row an alpha write after extraction created, partial", function()
        -- The residue path's blend count is exact only while every column a row
        -- is drawn from is clean, because a row it did not write is then
        -- carrying the tint it carried before and cannot have changed pass. An
        -- alpha write is the one that changes which pass a row draws in, so what
        -- holds that reasoning up is that a write from any phase, including one
        -- after the sync, sends the run down the whole-run path instead.
        local world, packet, bounds = newExtraction(true)
        local ids = population(world)

        local wrote = false
        world:addSystem({
            name = "spec.FadeAfterExtraction",
            phase = tecs.ecs.phases.Last,
            run = function()
                if wrote then
                    return
                end
                wrote = true
                world:getMut(ids[3], Tint).a = 0.5
            end,
        })

        world:update(1 / 60)
        assert.are.equal(0, packet.blendCount, "an opaque scene routes nothing forward")

        world:update(1 / 60)
        assert.are.equal(POPULATION, packet.rewritten, "the alpha write rewrites the run rather than a residue")
        assert.are.equal(1, packet.blendCount, "so the faded row is counted")
        assert.are.equal(30, centerX(bounds, 3), "and it is still the row it was")
    end)
end)

describe("render backend", function()
    local window, device, screen

    setup(function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        window = newWindow({ title = "packet", width = SIZE, height = SIZE })
        device = Device.create(window, { debug = true })
        screen = Texture.create(device.handle, { width = SIZE, height = SIZE, format = FORMAT })
    end)

    teardown(function()
        if screen then
            screen:destroy()
        end
        if device then
            device:destroy()
        end
        if window then
            window:destroy()
        end
        C.SDL_Quit()
    end)

    local function newBackend()
        return Backend.create(device.handle, FORMAT, {
            ambient = { 1.0, 1.0, 1.0 },
            capacity = 16,
        })
    end

    -- One instance covering the whole target, written by hand into the staging
    -- the backend mapped. This is exactly what an extractor writes and is
    -- deliberately written without one.
    local function writeQuad(backend, packet, x, y, r, g, b)
        local instances, bounds = backend:mapSlot(0)
        instances[0] = 0.0 -- rotation
        instances[1] = SIZE * 2 -- scale
        instances[2] = SIZE * 2
        instances[3] = 0.5 -- depth
        instances[4] = x
        instances[5] = y
        instances[6] = 0.0 -- white layer, no clip region
        instances[7] = 0.0 -- default material
        instances[8], instances[9] = r, g
        instances[10], instances[11] = b, 1.0
        instances[12], instances[13] = 0.0, 0.0
        instances[14], instances[15] = backend.whiteU1, backend.whiteV1

        bounds[0], bounds[1] = x, y
        bounds[2], bounds[3] = SIZE, SIZE

        packet:begin(0)
        packet.count = 1
        packet.dropped = 0
        packet.rewritten = 1
        packet.instanceRanges:mark(0, INSTANCE_BYTES)
        packet.boundsRanges:mark(0, BOUND_BYTES)
    end

    local function consume(backend, packet)
        local commandBuffer = C.SDL_AcquireGPUCommandBuffer(device.handle)
        backend:consume(packet, {
            width = SIZE,
            height = SIZE,
            commandBuffer = commandBuffer,
            swapchainTexture = screen.handle,
        })
        assert(C.SDL_SubmitGPUCommandBuffer(commandBuffer))
        return screen:readback()
    end

    it("draws a packet built by hand, with no world anywhere", function()
        local backend = newBackend()
        local packet = FramePacket.create()
        writeQuad(backend, packet, SIZE / 2, SIZE / 2, 1.0, 0.0, 0.0)
        packet.cameraX = SIZE / 2
        packet.cameraY = SIZE / 2
        packet.cameraZoom = 1.0

        local center = screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2)
        assert.are.equal(255, center.r, "the packet's instance reached the screen")
        assert.are.equal(0, center.g)
        backend:destroy()
    end)

    it("draws from where the packet says the camera was", function()
        local backend = newBackend()
        local packet = FramePacket.create()
        writeQuad(backend, packet, SIZE / 2, SIZE / 2, 0.0, 1.0, 0.0)
        packet.cameraX = SIZE / 2
        packet.cameraY = SIZE / 2
        packet.cameraZoom = 1.0
        assert.are.equal(255, screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2).g)

        -- Far enough away that the quad leaves the view entirely, which also
        -- pins that the cull reads the packet's camera and not a stale one.
        writeQuad(backend, packet, SIZE / 2, SIZE / 2, 0.0, 1.0, 0.0)
        packet.cameraX = SIZE * 20
        assert.are.equal(
            0,
            screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2).g,
            "the camera the packet carried is the one that was drawn from"
        )
        backend:destroy()
    end)

    it("copies only the ranges the packet named", function()
        local backend = newBackend()
        local packet = FramePacket.create()
        writeQuad(backend, packet, SIZE / 2, SIZE / 2, 0.0, 0.0, 1.0)
        packet.cameraX = SIZE / 2
        packet.cameraY = SIZE / 2
        packet.cameraZoom = 1.0
        consume(backend, packet)

        -- A second frame that names no range at all. The device buffer is
        -- persistent, so the instance is still there and still draws; a backend
        -- that uploaded whatever it found in staging would draw the same thing,
        -- so the claim is checked from the other end below.
        packet:begin(0)
        assert.are.equal(0, packet.instanceRanges.count)
        assert.are.equal(
            255,
            screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2).b,
            "what an earlier packet uploaded stays resident"
        )

        -- Now the staging is changed without the packet saying so. Nothing may
        -- reach the device until a range names those bytes.
        local instances = backend:mapSlot(0)
        instances[8], instances[9], instances[10] = 1.0, 0.0, 0.0
        packet:begin(0)
        assert.are.equal(
            255,
            screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2).b,
            "an unnamed write must not be copied"
        )

        packet:begin(0)
        packet.instanceRanges:mark(0, INSTANCE_BYTES)
        assert.are.equal(
            255,
            screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2).r,
            "and must be copied once a range names it"
        )
        backend:destroy()
    end)

    it("lights a packet from the light array it carries", function()
        local backend = Backend.create(device.handle, FORMAT, {
            ambient = { 0.0, 0.0, 0.0 },
            capacity = 16,
        })
        local packet = FramePacket.create()
        writeQuad(backend, packet, SIZE / 2, SIZE / 2, 1.0, 1.0, 1.0)
        packet.cameraX = SIZE / 2
        packet.cameraY = SIZE / 2
        packet.cameraZoom = 1.0

        assert.are.equal(
            0,
            screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2).r,
            "no ambient and no lights is black"
        )

        writeQuad(backend, packet, SIZE / 2, SIZE / 2, 1.0, 1.0, 1.0)
        packet.cameraX = SIZE / 2
        packet.cameraY = SIZE / 2
        packet.cameraZoom = 1.0
        packet:addLight(SIZE / 2, SIZE / 2, 12.0, 30.0, 1.0, 1.0, 1.0, 4.0)

        local pixels = consume(backend, packet)
        assert.is_true(screen:getPixel(pixels, SIZE / 2, SIZE / 2).r > 180, "the packet's light lit its own frame")
        assert.is_true(screen:getPixel(pixels, 2, 2).r < 60, "and only as far as its radius")
        backend:destroy()
    end)

    -- The line is only where it is claimed to be if the backend cannot reach
    -- across it, and a pixel test cannot tell you that: a module can require
    -- the ECS and still draw the right thing. This reads the module the build
    -- produced, so a require added later fails here rather than being found
    -- when the two halves are moved onto different threads.
    it("names nothing from the ECS", function()
        local forbidden = {
            "tecs%.ecs",
            "tecs%.components",
            "tecs%.internal",
            "tecs%.Extractor",
        }
        for _, module in ipairs({ "Backend", "FramePacket" }) do
            local file = assert(io.open(root .. "/tecs/" .. module .. ".lua"))
            local source = file:read("*a")
            file:close()
            for _, name in ipairs(forbidden) do
                assert.is_nil(
                    source:match('require%("' .. name .. '[%."]'),
                    ("tecs.%s must not require %s"):format(module, name:gsub("%%", ""))
                )
            end
        end
    end)

    it("draws nothing for a packet that counted nothing", function()
        local backend = newBackend()
        local packet = FramePacket.create()
        packet:begin(0)
        packet.count = 0
        packet.cameraX = SIZE / 2
        packet.cameraY = SIZE / 2
        packet.cameraZoom = 1.0

        assert.are.equal(0, screen:getPixel(consume(backend, packet), SIZE / 2, SIZE / 2).r)
        backend:destroy()
    end)
end)
