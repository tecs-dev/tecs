--- Love2D integration suite: the screen phase must not re-render world
--- content. The fixture offsets the camera by 100 px so a screen-phase
--- ghost of the world-layer CPU draw would land at a probeable position
--- distinct from the legitimate draw.
---
--- Run via `make test-love FILE_MATCH='screen_phase'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/screenlayers"

local TOLERANCE <const> = 0.06

-- Screen positions (fractions of 320x240). The world rect sits at world
-- (110..150, 40..80); through the camera at (260, 120) it lands at screen
-- (10..50, 40..80). A screen-phase re-render draws with the camera at the
-- origin (screen = world + half window), landing at (270..310, 160..200).
local LEGIT <const> = {30 / 320, 60 / 240}
local GHOST <const> = {290 / 320, 180 / 240}
local SCREEN_RECT <const> = {280 / 320, 40 / 240}

describe("screen phase: world content renders exactly once", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("draws the world CPU rectangle at its camera-relative position", function()
        local level = fixture.eventually(fixture.callTimeout, function(): number
            local p = fixture.probePixels(app, {LEGIT})[1]
            if p[2] > 1 - TOLERANCE and p[1] < TOLERANCE then return p[2] end
            return nil
        end)
        luassert.is_number(level, "world-layer CPU draw never appeared")
    end)

    it("draws the screen-layer rectangle at its screen position", function()
        local level = fixture.eventually(fixture.callTimeout, function(): number
            local p = fixture.probePixels(app, {SCREEN_RECT})[1]
            if p[3] > 1 - TOLERANCE and p[2] < TOLERANCE then return p[3] end
            return nil
        end)
        luassert.is_number(level, "screen-layer rectangle never appeared")
    end)

    it("does not ghost the world draw in the screen phase", function()
        -- Steady state was established by the tests above; the ghost point
        -- must stay dark.
        local p = fixture.probePixels(app, {GHOST})[1]
        luassert.is_true(p[2] < TOLERANCE,
            "world CPU draw ghosted into the screen phase (green at identity-camera position: "
            .. tostring(p[2]) .. ")")
    end)

    it("rejects unnamed screen-space layers", function()
        local values = fixture.runLua(app, [[
            local gfx = require("tecs.gfx")
            local pipeline = world.resources[gfx.PIPELINE]
            local ok, err = pcall(function()
                pipeline:configureLayer(3, {space = "screen"})
            end)
            return tostring(ok), tostring(err)
        ]])
        luassert.are.equal("false", values[1],
            "unnamed screen layer accepted (it silently skips the screen phase)")
        luassert.matches("must be named", values[2])
    end)
end)
