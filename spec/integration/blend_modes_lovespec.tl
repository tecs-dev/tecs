--- Love2D integration suite: blend-mode rendering. Shapes tagged with
--- blend components render through the forward-blend pass after
--- lighting, compositing against a mid-gray background: additive
--- brightens only the source channels, multiply darkens, and an
--- untagged alpha shape replaces. Covers blend.groupBy tagging, the
--- blend-group tracking in the shape sync path, and the forward-blend
--- draw itself; none of which any other suite touches.
---
--- Run via `make test-love FILE_MATCH='blend_modes'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("spec.integration.harness.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local W <const> = 320.0
local H <const> = 240.0

-- Three gray panels, one blended circle each.
local ADD_PROBE <const> = {{60 / W, 120 / H}}
local MUL_PROBE <const> = {{160 / W, 120 / H}}
local ALPHA_PROBE <const> = {{260 / W, 120 / H}}

local function waitPixel(app: fixture.App, point: {{number}}, check: function({number}): boolean, label: string)
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        if check(fixture.probePixels(app, point)[1]) then return true end
        return nil
    end)
    local p = fixture.probePixels(app, point)[1]
    luassert.is_true(ok == true, string.format(
        "%s: pixel = (%.2f, %.2f, %.2f)", label, p[1], p[2], p[3]))
end

describe("blend modes: forward-blend composites over the lit scene", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform

            -- Mid-gray panels on layer 1
            for _, x in ipairs({60, 160, 260}) do
                world:spawn(Transform(x, 120, 0, 1),
                    gfx.Rectangle(70, 70), gfx.Color(0.5, 0.5, 0.5, 1))
            end

            -- Additive red circle: gray + red = (1.0, 0.5, 0.5)
            world:spawn(Transform(60, 120, 0.5, 2),
                gfx.Circle(20), gfx.Color(1, 0, 0, 1), gfx.blend.AdditiveBlend())

            -- Multiply (0.5, 1, 1) circle: gray * src = (0.25, 0.5, 0.5)
            world:spawn(Transform(160, 120, 0.5, 2),
                gfx.Circle(20), gfx.Color(0.5, 1, 1, 1), gfx.blend.MultiplyBlend())

            -- Untagged alpha circle: replaces with red
            world:spawn(Transform(260, 120, 0.5, 2),
                gfx.Circle(20), gfx.Color(1, 0, 0, 1))

            -- Second row: lighten and darken (LÖVE requires these run
            -- premultiplied; the non-premul tags must not crash)
            for _, x in ipairs({60, 160}) do
                world:spawn(Transform(x, 195, 0, 1),
                    gfx.Rectangle(70, 60), gfx.Color(0.5, 0.5, 0.5, 1))
            end
            world:spawn(Transform(60, 195, 0.5, 2),
                gfx.Circle(18), gfx.Color(1, 0, 0, 1), gfx.blend.LightenBlend())
            world:spawn(Transform(160, 195, 0.5, 2),
                gfx.Circle(18), gfx.Color(1, 0, 0, 1), gfx.blend.DarkenBlend())
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("renders the gray panels", function()
        -- Probe beside a circle, inside the left panel.
        waitPixel(app, {{(60 + 28) / W, 120 / H}}, function(p: {number}): boolean
            return p[1] > 0.35 and p[1] < 0.65
                and p[2] > 0.35 and p[2] < 0.65
                and p[3] > 0.35 and p[3] < 0.65
        end, "panel should read mid-gray")
    end)

    it("additive blend brightens only the source channels", function()
        waitPixel(app, ADD_PROBE, function(p: {number}): boolean
            return p[1] > 0.85              -- gray + full red saturates
                and p[2] > 0.35 and p[2] < 0.65  -- green stays at panel level
                and p[3] > 0.35 and p[3] < 0.65
        end, "additive circle should read (~1.0, ~0.5, ~0.5)")
    end)

    it("multiply blend darkens by the source color", function()
        waitPixel(app, MUL_PROBE, function(p: {number}): boolean
            return p[1] > 0.1 and p[1] < 0.4    -- 0.5 * 0.5 = 0.25
                and p[2] > 0.35 and p[2] < 0.65  -- 0.5 * 1.0 = 0.5
                and p[3] > 0.35 and p[3] < 0.65
        end, "multiply circle should read (~0.25, ~0.5, ~0.5)")
    end)

    it("untagged shapes alpha-replace the panel", function()
        waitPixel(app, ALPHA_PROBE, function(p: {number}): boolean
            return p[1] > 0.85 and p[2] < 0.15 and p[3] < 0.15
        end, "alpha circle should read pure red")
    end)

    it("lighten blend takes the channel max", function()
        -- max(gray 0.5, red 1/0/0) = (1.0, 0.5, 0.5)
        waitPixel(app, {{60 / W, 195 / H}}, function(p: {number}): boolean
            return p[1] > 0.85 and p[2] > 0.35 and p[2] < 0.65
        end, "lighten circle should read (~1.0, ~0.5, ~0.5)")
    end)

    it("darken blend takes the channel min", function()
        -- min(gray 0.5, red 1/0/0) = (0.5, 0, 0)
        waitPixel(app, {{160 / W, 195 / H}}, function(p: {number}): boolean
            return p[1] > 0.35 and p[1] < 0.65 and p[2] < 0.15 and p[3] < 0.15
        end, "darken circle should read (~0.5, 0, 0)")
    end)
end)
