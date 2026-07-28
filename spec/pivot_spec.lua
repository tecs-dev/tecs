-- Where a pivoted quad lands, and what the cull is told about it.
--
-- The instance carries no pivot of its own. A pivot is an affine shift of the
-- basis the vertex shader already applies, so extraction folds it into the
-- origin and what reaches the GPU is a quad drawn somewhere else. That makes
-- these assertions about two numbers: the origin the instance carries, and the
-- centre of the bound the cull reads beside it.
--
-- A pivot is a fraction of the frame measured from its top left, and world Y
-- runs down the screen, so both axes read the same way. A pivot at the foot of
-- the frame is +0.5 in quad-local units, and putting that point on the entity
-- lifts the quad's middle half a height up the screen, which is to a smaller
-- Y. That is what a character standing on its position means.

-- The build directory is the build system's to choose, so it is passed in.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local loader = require("tecs.ffi.loader")
local Extractor = require("tecs.Extractor")
local FramePacket = require("tecs.FramePacket")
local components = require("tecs.components")
local builtins = require("tecs.ecs").builtins
local sheet = require("tecs.gfx.sheet")
local instancelayout = require("tecs.gpu.instancelayout")

local Transform = builtins.Transform
local Tint = components.Tint
local Renderable = components.Renderable
local Pivot = sheet.Pivot

local INSTANCE_FLOATS = instancelayout.FLOATS
local BOUND_FLOATS = instancelayout.BOUND_FLOATS

local EPSILON = 1e-4

local function near(actual, expected, what)
    assert.is_true(
        math.abs(actual - expected) < EPSILON,
        ("%s: expected %.6f, got %.6f"):format(what or "value", expected, actual)
    )
end

describe("a pivoted quad", function()
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

    -- The origin the instance at `index` carries, and its depth.
    local function originAt(instances, index)
        local base = index * INSTANCE_FLOATS
        return instances[base + 4], instances[base + 5], instances[base + 3]
    end

    -- The centre and half extents of the bound at `index`.
    local function boundAt(bounds, index)
        local base = index * BOUND_FLOATS
        return bounds[base], bounds[base + 1], bounds[base + 2], bounds[base + 3]
    end

    -- A 40 by 60 quad at 100, 200, so a half height is thirty and a half
    -- width twenty.
    local function quad(rotation)
        return Transform(100, 200, 0, 1, rotation or 0, 40, 60)
    end

    it("hangs the quad off the point the pivot names", function()
        local world, _, instances = newExtraction()
        -- The foot of the frame. Standing that point on the entity lifts the
        -- middle half a height up the screen, so to a smaller Y.
        world:spawn(quad(), Tint(1, 1, 1, 1), Renderable(), Pivot(0.5, 1.0))

        world:update(1 / 60)

        local x, y = originAt(instances, 0)
        near(x, 100, "origin x")
        near(y, 170, "origin y")
    end)

    it("draws an entity carrying no pivot on its own position", function()
        local world, _, instances = newExtraction()
        world:spawn(quad(), Tint(1, 1, 1, 1), Renderable())

        world:update(1 / 60)

        local x, y = originAt(instances, 0)
        near(x, 100, "origin x")
        near(y, 200, "origin y")
    end)

    it("turns the quad about the pivot rather than about its middle", function()
        local world, _, instances = newExtraction()
        -- A quarter turn. Unpivoted the middle would not move at all; pivoted
        -- it swings a half height round the entity, from thirty up the screen
        -- to thirty along X.
        world:spawn(quad(math.pi / 2), Tint(1, 1, 1, 1), Renderable(), Pivot(0.5, 1.0))

        world:update(1 / 60)

        local x, y = originAt(instances, 0)
        near(x, 130, "origin x")
        near(y, 200, "origin y")
    end)

    it("turns a pivot off both axes to where the basis puts it", function()
        local world, _, instances = newExtraction()
        -- The frame's top left, which is off the quad's middle on both axes.
        -- Unturned the middle would land at 120, 230; a half turn negates the
        -- offset and puts it at 80, 170 instead.
        world:spawn(quad(math.pi), Tint(1, 1, 1, 1), Renderable(), Pivot(0.0, 0.0))

        world:update(1 / 60)

        local x, y = originAt(instances, 0)
        near(x, 80, "origin x")
        near(y, 170, "origin y")
    end)

    it("moves the cull bound with the quad and leaves its size alone", function()
        local world, _, _, bounds = newExtraction()
        world:spawn(quad(), Tint(1, 1, 1, 1), Renderable(), Pivot(0.5, 1.0))
        world:spawn(quad(), Tint(1, 1, 1, 1), Renderable())

        world:update(1 / 60)

        -- The two land in different archetypes and which run comes first is
        -- the world's business, so each is found by where its bound sits.
        local pivotedRow, plainRow
        for index = 0, 1 do
            local _, centreY = boundAt(bounds, index)
            if math.abs(centreY - 170) < EPSILON then
                pivotedRow = index
            else
                plainRow = index
            end
        end
        assert.is_not_nil(pivotedRow, "the pivoted bound follows the quad")
        assert.is_not_nil(plainRow)

        local px, py, pex, pey = boundAt(bounds, pivotedRow)
        near(px, 100, "pivoted bound centre x")
        near(py, 170, "pivoted bound centre y")

        local _, _, ex, ey = boundAt(bounds, plainRow)
        near(pex, ex, "half extent x is the quad's, whatever it hangs off")
        near(pey, ey, "half extent y")
        near(pex, 20, "and is half the scale")
        near(pey, 30)
    end)

    -- The one case where the shift is not known here. Playback on the GPU
    -- resolves the frame after this is written, so a pivot that follows a slice
    -- moving between frames carries how far it can travel and the bound covers
    -- all of it. Everything else, which is every pivot written directly and
    -- every slice with a single key, travels nothing and is the case above.
    it("grows the bound by exactly the travel of a moving pivot", function()
        local world, _, _, bounds = newExtraction()
        -- A tenth of the frame across and a quarter down, on a 40 by 60 quad,
        -- which is four world units and fifteen.
        world:spawn(quad(), Tint(1, 1, 1, 1), Renderable(), Pivot(0.5, 1.0, 0, 0, 0.1, 0.25))

        world:update(1 / 60)

        local cx, cy, ex, ey = boundAt(bounds, 0)
        near(cx, 100, "the centre is still the middle pivot's")
        near(cy, 170, "bound centre y")
        near(ex, 24, "half the width plus the travel across")
        near(ey, 45, "half the height plus the travel down")
    end)

    it("grows a turned bound in the safe direction", function()
        local world, _, _, bounds = newExtraction()
        world:spawn(quad(math.pi / 4), Tint(1, 1, 1, 1), Renderable(), Pivot(0.5, 1.0, 0, 0, 0.1, 0.25))

        world:update(1 / 60)

        -- A turned quad's bound is half the sum of both scales on both axes,
        -- and the travel is covered the same way: looser than the true extent
        -- and never smaller, so the cull can only keep what it might have
        -- dropped.
        -- Half of forty plus sixty is fifty, and the travel of eight by thirty
        -- world units adds nineteen the same way.
        local _, _, ex, ey = boundAt(bounds, 0)
        near(ex, 69, "half the sum of the scales, plus the travel's")
        near(ey, ex, "and the same on both axes")
    end)

    it("sorts on the entity's position rather than the quad's middle", function()
        local world, _, instances = newExtraction()
        -- Absurdly tall on purpose. The topdown sort spreads ten thousand
        -- world units across a sixteenth of the depth range, so a shift small
        -- enough to be a sprite moves the depth by less than a float shows.
        -- Four thousand of it does.
        world:spawn(Transform(100, 200, 0, 1, 0, 40, 8000), Tint(1, 1, 1, 1), Renderable(), Pivot(0.5, 1.0))
        world:spawn(Transform(100, 200, 0, 1, 0, 40, 8000), Tint(1, 1, 1, 1), Renderable())

        world:update(1 / 60)

        local _, firstY, firstDepth = originAt(instances, 0)
        local _, secondY, secondDepth = originAt(instances, 1)
        near(math.abs(firstY - secondY), 4000, "the two quads are drawn far apart")
        near(firstDepth, secondDepth, "and still sort together")
    end)

    it("rewrites the row when only the pivot moved", function()
        local world, packet, instances = newExtraction()
        local entity = world:spawn(quad(), Tint(1, 1, 1, 1), Renderable(), Pivot(0.5, 1.0))

        world:update(1 / 60)
        world:update(1 / 60)
        assert.are.equal(0, packet.rewritten, "a still frame gives the backend nothing to copy")

        world:getMut(entity, Pivot).y = 0.0
        world:update(1 / 60)

        assert.are.equal(1, packet.rewritten)
        local _, y = originAt(instances, 0)
        near(y, 230, "the quad hangs off the other end of the frame")
    end)
end)
