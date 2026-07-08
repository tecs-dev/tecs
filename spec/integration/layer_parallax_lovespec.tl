--- Love2D integration suite: layer ordering and parallax. Higher layers
--- draw over lower ones at the same world position, and a layer with a
--- 0.5 parallax factor shifts half as far as a normal layer when the
--- camera moves. Covers layer-based depth ordering in the cull/render
--- and the parallax matrix plumbing end to end.
---
--- Run via `make test-love FILE_MATCH='layer_parallax'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("spec.integration.harness.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local W <const> = 320.0
local H <const> = 240.0

local function waitPixel(app: fixture.App, x: number, y: number,
        check: function({number}): boolean, label: string)
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        if check(fixture.probePixels(app, {{x / W, y / H}})[1]) then return true end
        return nil
    end)
    local p = fixture.probePixels(app, {{x / W, y / H}})[1]
    luassert.is_true(ok == true, string.format(
        "%s: pixel (%d, %d) = (%.2f, %.2f, %.2f)",
        label, x as integer, y as integer, p[1], p[2], p[3]))
end

local function isRed(p: {number}): boolean return p[1] > 0.8 and p[2] < 0.2 end
local function isGreen(p: {number}): boolean return p[2] > 0.8 and p[1] < 0.2 end
local function isBlue(p: {number}): boolean return p[3] > 0.8 and p[2] < 0.2 end

describe("layers: ordering and parallax factors", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            -- Overlapping pair: red on layer 1 under green on layer 2.
            world:spawn(Transform(80, 60, 0, 1), gfx.Rectangle(40, 40), gfx.Color(1, 0, 0, 1))
            world:spawn(Transform(80, 60, 0, 2), gfx.Rectangle(24, 24), gfx.Color(0, 1, 0, 1))

            -- Parallax pair on the centerline: green control on layer 1,
            -- blue on layer 3 at half parallax.
            -- X-only parallax: the offset is cam * (1 - factor), so a
            -- reduced Y factor would push the marker below the 240px
            -- window before the test even starts.
            local pipeline = world.resources[gfx.PIPELINE]
            pipeline:setLayerParallax(3, 0.5, 1.0)
            world:spawn(Transform(160, 160, 0, 1), gfx.Rectangle(16, 16), gfx.Color(0, 1, 0, 1))
            world:spawn(Transform(160, 200, 0, 3), gfx.Rectangle(16, 16), gfx.Color(0, 0, 1, 1))
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("draws higher layers over lower ones", function()
        waitPixel(app, 80, 60, isGreen, "layer 2 should cover layer 1 where they overlap")
        -- The larger red rect still shows around the green one.
        waitPixel(app, 80 + 16, 60 + 16, isRed, "layer 1 should show outside the overlap")
    end)

    -- Scan a horizontal row for the screen x of the strongest match.
    local function findMarkerX(app2: fixture.App, y: number,
            channelCheck: function({number}): boolean): number
        local points: {{number}} = {}
        for x = 2, 318, 4 do
            points[#points + 1] = {x / W, y / H}
        end
        local pixels = fixture.probePixels(app2, points)
        for i = 1, #pixels do
            if channelCheck(pixels[i]) then
                return 2 + (i - 1) * 4
            end
        end
        return -1
    end

    it("half-parallax layers shift half as far as the camera", function()
        -- Locate both markers, move the camera +40, relocate them; the
        -- normal marker's screen shift must be ~40 and the parallax
        -- marker's ~20 (the anchor of the parallax offset is formula
        -- detail; the shift ratio is the contract).
        local greenBefore = fixture.eventually(fixture.callTimeout, function(): number
            local x = findMarkerX(app, 160, isGreen)
            if x >= 0 then return x end
            return nil
        end)
        local blueBefore = findMarkerX(app, 200, isBlue)
        luassert.is_number(greenBefore, "normal marker not found before the move")
        luassert.is_true(blueBefore >= 0, "parallax marker not found before the move")

        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            world.resources[gfx.PIPELINE]:getCamera():setPosition(200, 120)
            return true
        ]])

        local greenAfter = fixture.eventually(fixture.callTimeout, function(): number
            local x = findMarkerX(app, 160, isGreen)
            if x >= 0 and math.abs((greenBefore - x) - 40) <= 6 then return x end
            return nil
        end)
        luassert.is_number(greenAfter, string.format(
            "normal marker should shift ~40px left (before %d, now %d)",
            greenBefore, findMarkerX(app, 160, isGreen)))

        local blueAfter = findMarkerX(app, 200, isBlue)
        luassert.is_true(blueAfter >= 0, "parallax marker vanished after the move")
        local blueShift = blueBefore - blueAfter
        luassert.is_true(math.abs(blueShift - 20) <= 6, string.format(
            "half-parallax marker should shift ~20px, shifted %d (before %d, after %d)",
            blueShift, blueBefore, blueAfter))
    end)
end)
