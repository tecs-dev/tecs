-- What a depth is allowed to be, whatever a scene puts in front of it.
--
-- The rendered behaviour of a layer is asserted in renderer_spec, which needs a
-- device to say anything. This is the arithmetic underneath it, and the one
-- thing that arithmetic must never do: a depth belongs to exactly one band,
-- because the vertex shader recovers the layer index by multiplying the depth
-- by the number of bands. A depth that spilled would draw the entity with a
-- different layer's positioning, parallax, zoom and lit flag, in the right
-- place, at the right size, on the wrong layer.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local layers = require("tecs.gfx.layers")

describe("a layer's depth", function()
    -- The half-open band a layer owns, as the shader divides it: floor of
    -- depth times MAX has to come back out as MAX - layer.
    local function bandOf(depth)
        return layers.MAX - math.floor(depth * layers.MAX)
    end

    local function restore(layer)
        layers.configure(layer, { sort = "topdown" })
    end

    it("stays inside its own band for a scene taller than maxY", function()
        -- Ten times the extent the module was told to expect, which is what a
        -- large world hands it without anyone having said anything wrong.
        local far = layers.maxY * 10.0
        for _, y in ipairs({ -far, -layers.maxY, 0.0, layers.maxY, far }) do
            local depth = layers.depthOf(8, 0.0, 0.0, y)
            assert.are.equal(8, bandOf(depth), "y = " .. y .. " left layer 8's band")
        end
    end)

    it("stays inside its own band for a z past maxZ", function()
        local far = layers.maxZ * 10.0
        for _, z in ipairs({ -far, 0.0, layers.maxZ, far }) do
            local depth = layers.depthOf(8, z, 0.0, 0.0)
            assert.are.equal(8, bandOf(depth), "z = " .. z .. " left layer 8's band")
        end
    end)

    it("stays inside its own band on a layer that sorts by z alone", function()
        layers.configure(2, { sort = "z" })
        local far = layers.maxZ * 10.0
        for _, z in ipairs({ -far, 0.0, layers.maxZ, far }) do
            local depth = layers.depthOf(2, z, 0.0, 0.0)
            assert.are.equal(2, bandOf(depth), "z = " .. z .. " left layer 2's band")
        end
        restore(2)
    end)

    it("stays inside its own band on an isometric layer", function()
        layers.configure(3, { sort = "isometric" })
        local far = layers.maxY * 10.0
        for _, x in ipairs({ -far, 0.0, far }) do
            for _, y in ipairs({ -far, 0.0, far }) do
                local depth = layers.depthOf(3, layers.maxZ * 10.0, x, y)
                assert.are.equal(3, bandOf(depth), "x = " .. x .. ", y = " .. y .. " left layer 3's band")
            end
        end
        restore(3)
    end)

    it("goes on sorting up to the edge of the extent it was given", function()
        -- The clamp costs order beyond the edge and must cost none before it,
        -- or it has traded one silent failure for another.
        local near = layers.depthOf(8, 0.0, 0.0, layers.maxY * 0.5)
        local far = layers.depthOf(8, 0.0, 0.0, layers.maxY * 0.9)
        assert.is_true(far < near, "lower on the screen is nearer, and nearer is a smaller depth")
    end)

    it("takes the nearest real layer for one outside the range", function()
        -- Layer zero would otherwise resolve above one and be clamped flat, so
        -- every entity on it would come out at the same depth and stop sorting
        -- against the others there.
        local high = layers.depthOf(0, 0.0, 0.0, -layers.maxY * 0.5)
        local low = layers.depthOf(0, 0.0, 0.0, layers.maxY * 0.5)
        assert.is_true(low < high, "an out-of-range layer still sorts within the band it lands in")
        assert.are.equal(1, bandOf(high), "and that band is layer one's")
        assert.are.equal(1, bandOf(low))

        local beyond = layers.depthOf(layers.MAX + 4, 0.0, 0.0, 0.0)
        assert.are.equal(layers.MAX, bandOf(beyond), "past the top it is the topmost layer's")
    end)

    it("keeps a higher layer in front of a lower one at every extreme", function()
        -- The property the bands exist for, stated over the inputs that used
        -- to break it rather than over the ones that never did.
        local far = layers.maxY * 10.0
        local above = layers.depthOf(9, -layers.maxZ * 10.0, 0.0, -far)
        local below = layers.depthOf(8, layers.maxZ * 10.0, 0.0, far)
        assert.is_true(above < below, "layer 9 is in front of layer 8 whatever either contains")
    end)
end)
