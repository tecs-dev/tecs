--- Love2D integration suite: GPU cull bounds must cover where the render
--- shaders actually draw. Each test spawns a shape whose transform origin
--- sits outside the culling viewport while its visible body (offset by
--- Pivot or swung by rotation) is on-screen, then asserts pixel probes see
--- it. A cull that ignores pivot/rotation removes these shapes entirely.
---
--- The window is 320x240 with the camera at (160, 120); the cull viewport
--- is the camera AABB padded by 50 px, so world x in [-50, 370] and
--- y in [-30, 270].
---
--- Run via `make test-love FILE_MATCH='shape_culling'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/compliance"

local TOLERANCE <const> = 0.06

describe("shape culling: bounds cover pivot and rotation", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
    end)

    teardown(function()
        fixture.stop(app)
    end)

    local function expectGreenAt(fx: number, fy: number, what: string)
        local level = fixture.eventually(fixture.callTimeout, function(): number
            local p = fixture.probePixels(app, {{fx, fy}})[1]
            if p[2] > 1 - TOLERANCE and p[1] < TOLERANCE then return p[2] end
            return nil
        end)
        luassert.is_number(level, what .. " never appeared (culled while visible?)")
    end

    it("draws a pivoted ellipse whose transform is off-screen", function()
        -- Pivot(0, 0.5) shifts the body +2*radiusX from the transform, so
        -- the body's center is at (-70, 120) with radius 150: on-screen up
        -- to x=80 while the transform (-220, 120) is far outside the
        -- padded viewport.
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(
                Transform(-220, 120, 0, 1),
                gfx.Ellipse(150, 150),
                gfx.Pivot(0, 0.5),
                gfx.Color(0, 1, 0, 1))
            return true
        ]])
        expectGreenAt(40 / 320, 120 / 240, "pivoted ellipse")
    end)

    it("draws a rotated rectangle pivoted from off-screen", function()
        -- Pivot(0, 0) + rotation pi: the body swings to [230..430, 80..120]
        -- while the unrotated center (530, 140) sits outside the padded
        -- viewport.
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(
                Transform(430, 120, 0, 1, math.pi),
                gfx.Rectangle(200, 40),
                gfx.Pivot(0, 0),
                gfx.Color(0, 1, 0, 1))
            return true
        ]])
        expectGreenAt(280 / 320, 100 / 240, "rotated rectangle")
    end)

    it("draws a rotated line whose unrotated span is off-screen", function()
        -- Horizontal 300px line at y=350 (below the padded viewport),
        -- rotated 90 degrees around its midpoint (160, 350): renders as a
        -- vertical line at x=160 spanning y in [200, 500].
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(
                Transform(10, 350, 0, 1, math.pi / 2),
                gfx.Line(0, 0, 300, 0, 20),
                gfx.Color(0, 1, 0, 1))
            return true
        ]])
        expectGreenAt(160 / 320, 220 / 240, "rotated line")
    end)

    it("draws a mirrored (negative scale) circle", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(
                Transform(280, 180, 0, 1, 0, -1, 1),
                gfx.Circle(30),
                gfx.Color(0, 1, 0, 1))
            return true
        ]])
        expectGreenAt(280 / 320, 180 / 240, "mirrored circle")
    end)
end)
