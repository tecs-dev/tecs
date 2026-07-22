-- Translation correctness for canonical → std430 layouts. Builds a
-- canonical FFI struct with known values, allocates a std430 shadow
-- buffer, runs the translate function, and asserts the std430 fields
-- match expectations. No LÖVE required -- translates are pure FFI.

local C <const> = require("ffi")
local std430 <const> = require("tecs2d.gfx.internal.gpu.std430")

describe("std430 translations", function()
    it("translates Transform via identity memcpy (int32 layer, no pad)", function()
        local cfg = std430.layouts.Transform
        assert.is_true(cfg.identity)

        local canonical = C.new("CanonicalTransform[?]", 4)
        local shadow = C.new("Std430Transform[?]", 4)

        canonical[1].x = 10.0
        canonical[1].y = 20.0
        canonical[1].z = 30.0
        canonical[1].layer = 7
        canonical[1].rotation = 1.5
        canonical[1].scaleX = 2.0
        canonical[1].scaleY = 3.0

        canonical[2].x = -1.5
        canonical[2].y = -2.5
        canonical[2].z = 0.0
        canonical[2].layer = 1
        canonical[2].rotation = 0.0
        canonical[2].scaleX = 1.0
        canonical[2].scaleY = 1.0

        cfg.translate(canonical, shadow, 1, 2)

        assert.equals(10.0, shadow[1].x)
        assert.equals(20.0, shadow[1].y)
        assert.equals(30.0, shadow[1].z)
        assert.equals(7, shadow[1].layer)
        assert.equals(1.5, shadow[1].rotation)
        assert.equals(2.0, shadow[1].scaleX)
        assert.equals(3.0, shadow[1].scaleY)

        assert.equals(-1.5, shadow[2].x)
        assert.equals(1, shadow[2].layer)
    end)

    it("translates Color via identity memcpy", function()
        local cfg = std430.layouts.Color

        local canonical = C.new("CanonicalColor[?]", 3)
        local shadow = C.new("Std430Color[?]", 3)

        -- Use values exactly representable in float32 to avoid double→float
        -- precision drift in the assertion. 0.5, 0.25 are exact; 0.1 isn't.
        canonical[1].r, canonical[1].g, canonical[1].b, canonical[1].a = 0.5, 0.25, 0.125, 1.0
        canonical[2].r, canonical[2].g, canonical[2].b, canonical[2].a = 1.0, 0.0, 0.0, 0.5

        cfg.translate(canonical, shadow, 1, 2)

        assert.equals(0.5,   shadow[1].r)
        assert.equals(0.25,  shadow[1].g)
        assert.equals(0.125, shadow[1].b)
        assert.equals(1.0,   shadow[1].a)
        assert.equals(1.0,   shadow[2].r)
        assert.equals(0.5,   shadow[2].a)
    end)

    it("translates ClipBounds via identity memcpy", function()
        local cfg = std430.layouts.ClipBounds

        local canonical = C.new("CanonicalClipBounds[?]", 2)
        local shadow = C.new("Std430ClipBounds[?]", 2)

        canonical[1].minX = -10
        canonical[1].minY = -20
        canonical[1].maxX = 30
        canonical[1].maxY = 40

        cfg.translate(canonical, shadow, 1, 1)

        assert.equals(-10.0, shadow[1].minX)
        assert.equals(-20.0, shadow[1].minY)
        assert.equals(30.0, shadow[1].maxX)
        assert.equals(40.0, shadow[1].maxY)
    end)

    it("translates Material with vec4 alignment padding", function()
        local cfg = std430.layouts.Material

        local canonical = C.new("CanonicalMaterial[?]", 2)
        local shadow = C.new("Std430Material[?]", 2)

        canonical[1].materialId = 5
        canonical[1].p0 = 0.5
        canonical[1].p1 = 0.25
        canonical[1].p2 = 0.125
        canonical[1].p3 = 0.0625

        cfg.translate(canonical, shadow, 1, 1)

        assert.equals(5,      shadow[1].materialId)
        assert.equals(0.5,    shadow[1].p0)
        assert.equals(0.0625, shadow[1].p3)
        assert.equals(0.0, shadow[1]._pad0)
        assert.equals(0.0, shadow[1]._pad1)
        assert.equals(0.0, shadow[1]._pad2)
    end)

    it("translates LayoutBox with vec4 alignment padding", function()
        local cfg = std430.layouts.LayoutBox

        local canonical = C.new("CanonicalLayoutBox[?]", 2)
        local shadow = C.new("Std430LayoutBox[?]", 2)

        canonical[1].width = 100
        canonical[1].height = 50
        canonical[1].offsetX = -50
        canonical[1].offsetY = -25
        canonical[1].originX = 0.5
        canonical[1].originY = 0.5
        canonical[1].sourceComponentId = 42
        canonical[1].inheritsOrigin = 1

        cfg.translate(canonical, shadow, 1, 1)

        assert.equals(100.0, shadow[1].width)
        assert.equals(50.0, shadow[1].height)
        assert.equals(-50.0, shadow[1].offsetX)
        assert.equals(-25.0, shadow[1].offsetY)
        assert.equals(0.5, shadow[1].originX)
        assert.equals(0.5, shadow[1].originY)
        assert.equals(42, shadow[1].sourceComponentId)
        assert.equals(1, shadow[1].inheritsOrigin)
    end)

    it("translates Circle via identity memcpy", function()
        local cfg = std430.layouts.Circle

        local canonical = C.new("CanonicalCircle[?]", 2)
        local shadow = C.new("Std430Circle[?]", 2)

        canonical[1].radius = 25
        canonical[1].lineWidth = 2

        cfg.translate(canonical, shadow, 1, 1)

        assert.equals(25.0, shadow[1].radius)
        assert.equals(2.0, shadow[1].lineWidth)
    end)

    it("only writes the requested row range", function()
        local cfg = std430.layouts.Transform
        local canonical = C.new("CanonicalTransform[?]", 5)
        local shadow = C.new("Std430Transform[?]", 5)

        for r = 1, 4 do
            canonical[r].x = r * 10.0
            canonical[r].y = r * 20.0
            canonical[r].layer = r
            canonical[r].rotation = 0
            canonical[r].scaleX = 1
            canonical[r].scaleY = 1
        end

        -- Only translate rows 2..3.
        cfg.translate(canonical, shadow, 2, 3)

        assert.equals(20.0, shadow[2].x)  -- row 2 written
        assert.equals(30.0, shadow[3].x)  -- row 3 written
        assert.equals(0.0, shadow[1].x)   -- row 1 untouched
        assert.equals(0.0, shadow[4].x)   -- row 4 untouched
    end)

    it("translates Occluder via identity memcpy", function()
        local cfg = std430.layouts.Occluder

        local canonical = C.new("CanonicalOccluder[?]", 2)
        local shadow = C.new("Std430Occluder[?]", 2)

        canonical[1].height = 0.75
        canonical[1].alphaThreshold = 0.5

        cfg.translate(canonical, shadow, 1, 1)

        assert.equals(0.75, shadow[1].height)
        assert.equals(0.5,  shadow[1].alphaThreshold)
    end)

    it("std430 element sizes match expected bytes", function()
        -- Transform is 28 bytes (7 scalars), byte-identical to the canonical
        -- column so the upload uses the identity bulk-memcpy path.
        assert.equals(28, std430.sizes.Transform)
        assert.equals(16, std430.sizes.Color)
        assert.equals(16, std430.sizes.ClipBounds)
        assert.equals(32, std430.sizes.Material)
        assert.equals(32, std430.sizes.LayoutBox)
        assert.equals(8,  std430.sizes.Circle)
        assert.equals(8,  std430.sizes.Occluder)
        -- world ownership reuses the existing uint32 entity lane; keeping the
        -- canonical Sprite at 24 bytes protects the 4M-entity hot path.
        assert.equals(24, std430.sizes.Sprite)
        -- TextEffects is 17 scalar floats. All three layers (FFI struct,
        -- BufferFormat, GLSL struct) must stay all-scalar at the natural
        -- 68-byte stride; a vec4-grouped layout rounds the std430 array
        -- stride up to 80 and misaligns every row past the first.
        assert.equals(68, std430.sizes.TextEffects)
    end)

    it("declares BufferFormat lane counts that sum to the FFI struct size", function()
        -- Guards against a format lane regrouping (e.g. scalars into
        -- vec4s) silently disagreeing with the FFI stride.
        local laneBytes: {string: integer} = {
            float = 4, floatvec2 = 8, floatvec3 = 12, floatvec4 = 16,
            uint32 = 4, int32 = 4,
        }
        for name, layout in pairs(std430.layouts) do
            local total = 0
            for _, lane in ipairs(layout.format as {{string: string}}) do
                local bytes = laneBytes[lane.format]
                assert.is_not_nil(bytes, name .. " has unknown lane format " .. tostring(lane.format))
                total = total + bytes
            end
            assert.equals(std430.sizes[name], total,
                name .. ": BufferFormat lanes sum to " .. total
                .. " but FFI struct is " .. tostring(std430.sizes[name]) .. " bytes")
        end
    end)
end)
