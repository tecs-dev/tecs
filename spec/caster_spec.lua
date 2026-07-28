-- What extraction says an entity casts, and what it says nothing about.
--
-- A caster carries no field of its own on the instance. Its role is the two
-- signs of a cull bound whose magnitudes are the same lengths an opaque quad
-- writes, and its height rides above the clip region in the float that already
-- carried the texture-array layer. So every claim here is about three numbers:
-- the two half extents and the packed slot.
--
-- These assertions belong beside extraction rather than beside a rendered
-- pixel because a wrong sign here draws a perfectly ordinary frame: the quad
-- lands where it should, lit as it should be, and the only thing missing is
-- the shadow, which no image of the scene on its own can be checked against.

-- The build directory is the build system's to choose, so it is passed in.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local loader = require("tecs.ffi.loader")
local Extractor = require("tecs.Extractor")
local FramePacket = require("tecs.FramePacket")
local components = require("tecs.components")
local instancelayout = require("tecs.gpu.instancelayout")

local Transform = components.Transform
local Tint = components.Tint
local Renderable = components.Renderable
local Clip = components.Clip
local Occluder = components.Occluder
local DropShadow = components.DropShadow

local INSTANCE_FLOATS = instancelayout.FLOATS
local BOUND_FLOATS = instancelayout.BOUND_FLOATS
local TOP_STEP = instancelayout.HEIGHTS - 1

describe("what an entity casts", function()
    local CAPACITY = 16

    -- Staging is a pair of addresses to the extractor and nothing more, so a
    -- plain C array is the whole of what a device supplies it with.
    local function newExtraction()
        local world = tecs.ecs.newWorld()
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
        return world, packet, instances, bounds
    end

    -- The two half extents of the bound at `index`, signs and all.
    local function extentsAt(bounds, index)
        local base = index * BOUND_FLOATS
        return bounds[base + 2], bounds[base + 3]
    end

    -- The packed slot the instance at `index` carries.
    local function slotAt(instances, index)
        return instances[index * INSTANCE_FLOATS + 6]
    end

    -- A 40 by 60 quad, so a half width is twenty and a half height thirty.
    local function quad()
        return Transform(100, 200, 0, 1, 0, 40, 60)
    end

    it("says opaque with two positive extents", function()
        local world, _, _, bounds = newExtraction()
        world:spawn(quad(), Tint(1, 1, 1, 1), Renderable())

        world:update(1 / 60)

        local ex, ey = extentsAt(bounds, 0)
        assert.are.equal(20.0, ex)
        assert.are.equal(30.0, ey)
    end)

    it("says occluder by negating the second extent alone", function()
        local world, _, _, bounds = newExtraction()
        world:spawn(quad(), Tint(1, 1, 1, 1), Renderable(), Occluder(1.0))

        world:update(1 / 60)

        local ex, ey = extentsAt(bounds, 0)
        -- The magnitudes are an opaque quad's, because a sign is not a size:
        -- the cull tests one and lanes on the other.
        assert.are.equal(20.0, ex)
        assert.are.equal(-30.0, ey)
    end)

    it("says drop shadow by negating both", function()
        local world, _, _, bounds = newExtraction()
        world:spawn(quad(), Tint(1, 1, 1, 1), Renderable(), DropShadow(1.0))

        world:update(1 / 60)

        local ex, ey = extentsAt(bounds, 0)
        assert.are.equal(-20.0, ex)
        assert.are.equal(-30.0, ey)
    end)

    it("is an occluder when an entity asks to be both", function()
        local world, _, _, bounds = newExtraction()
        world:spawn(quad(), Tint(1, 1, 1, 1), Renderable(), Occluder(1.0), DropShadow(1.0))

        world:update(1 / 60)

        -- Occluder, because it is the half that changes what a light does and
        -- dropping it would unblock the light without saying so.
        local ex, ey = extentsAt(bounds, 0)
        assert.are.equal(20.0, ex)
        assert.are.equal(-30.0, ey)
    end)

    it("blends instead of casting when the tint is not opaque", function()
        local world, packet, _, bounds = newExtraction()
        world:spawn(quad(), Tint(1, 1, 1, 0.5), Renderable(), Occluder(1.0))

        world:update(1 / 60)

        -- A blended instance never reaches the G-buffer, so a hard silhouette
        -- of it would be a lie. The forward lane wins and nothing is cast.
        local ex, ey = extentsAt(bounds, 0)
        assert.are.equal(-20.0, ex)
        assert.are.equal(30.0, ey)
        assert.are.equal(1, packet.blendCount)
    end)

    it("quantises the height into the slot the layer already shared", function()
        local world, _, instances = newExtraction()
        world:spawn(quad(), Tint(1, 1, 1, 1), Renderable(), Occluder(0.5))

        world:update(1 / 60)

        local expected = math.floor(0.5 * TOP_STEP + 0.5)
        assert.are.equal(instancelayout.packSlot(0, 0, expected), slotAt(instances, 0))
    end)

    it("keeps the clip region and the layer beside the height", function()
        local world, _, instances = newExtraction()
        world:spawn(quad(), Tint(1, 1, 1, 1), Renderable(), Clip(3), Occluder(1.0))

        world:update(1 / 60)

        assert.are.equal(instancelayout.packSlot(3, 0, TOP_STEP), slotAt(instances, 0))
    end)

    it("clamps a height outside zero to one rather than packing into the clip", function()
        local world, _, instances = newExtraction()
        -- Two above the top step would land two clip regions along, drawing
        -- the entity through a rectangle nothing asked for.
        world:spawn(quad(), Tint(1, 1, 1, 1), Renderable(), Occluder(3.0))
        world:spawn(quad(), Tint(1, 1, 1, 1), Renderable(), Occluder(-1.0))

        world:update(1 / 60)

        assert.are.equal(instancelayout.packSlot(0, 0, TOP_STEP), slotAt(instances, 0))
        assert.are.equal(instancelayout.packSlot(0, 0, 0), slotAt(instances, 1))
    end)

    it("resyncs a run when only the height changed", function()
        local world, packet, instances = newExtraction()
        local entity = world:spawn(quad(), Tint(1, 1, 1, 1), Renderable(), Occluder(1.0))

        world:update(1 / 60)
        -- The frame after, with nothing touched: the gate holds the run still,
        -- which is what makes the next assertion mean anything.
        world:update(1 / 60)
        assert.are.equal(0, packet.rewritten)

        world:getMut(entity, Occluder).height = 0.0
        world:update(1 / 60)

        assert.are.equal(1, packet.rewritten)
        assert.are.equal(instancelayout.packSlot(0, 0, 0), slotAt(instances, 0))
    end)

    it("writes what it always wrote for an entity that casts nothing", function()
        local world, _, instances = newExtraction()
        world:spawn(quad(), Tint(1, 1, 1, 1), Renderable(), Clip(3))

        world:update(1 / 60)

        -- No height field at all, rather than a zero one: the two pack the
        -- same, and a caster left at zero throws a shadow of no length.
        assert.are.equal(instancelayout.packSlot(3, 0), slotAt(instances, 0))
    end)
end)
