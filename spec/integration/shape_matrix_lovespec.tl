--- Love2D integration suite: SDF shape rendering matrix. Spawns every
--- shape type (circle, ellipse, arc, line, rectangle, rounded rectangle)
--- in filled and outlined variants plus rotation and scale cases, then
--- pixel-probes inside/outside points. This is the direct smoke test for
--- the per-shape cull + render shader pipeline; before it, shape
--- regressions only surfaced indirectly through other suites.
---
--- The fixture maps world coordinates 1:1 to the 320x240 screen with
--- full ambient, so a shape's world position is its probe position and
--- colors read back unmodified (background is black).
---
--- Run via `make test-love FILE_MATCH='shape_matrix'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local W <const> = 320.0
local H <const> = 240.0

local function probe(app: fixture.App, x: number, y: number): {number}
    return fixture.probePixels(app, {{x / W, y / H}})[1]
end

--- Poll until the pixel at (x, y) satisfies `check`.
local function waitPixel(app: fixture.App, x: number, y: number,
        check: function({number}): boolean, label: string)
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        if check(probe(app, x, y)) then return true end
        return nil
    end)
    local last = probe(app, x, y)
    luassert.is_true(ok == true, string.format(
        "%s: pixel (%d, %d) = (%.2f, %.2f, %.2f)",
        label, x as integer, y as integer, last[1], last[2], last[3]))
end

local function isBackground(p: {number}): boolean
    return p[1] < 0.1 and p[2] < 0.1 and p[3] < 0.1
end

local function isRed(p: {number}): boolean return p[1] > 0.8 and p[2] < 0.2 end
local function isGreen(p: {number}): boolean return p[2] > 0.8 and p[1] < 0.2 end
local function isBlue(p: {number}): boolean return p[3] > 0.8 and p[2] < 0.2 end
local function isYellow(p: {number}): boolean return p[1] > 0.8 and p[2] > 0.8 and p[3] < 0.2 end
local function isMagenta(p: {number}): boolean return p[1] > 0.8 and p[3] > 0.8 and p[2] < 0.2 end
local function isCyan(p: {number}): boolean return p[2] > 0.8 and p[3] > 0.8 and p[1] < 0.2 end
local function isWhite(p: {number}): boolean return p[1] > 0.8 and p[2] > 0.8 and p[3] > 0.8 end

describe("shape matrix: SDF shapes render where and how they should", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        -- One spawn batch; every case gets its own grid cell and color.
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform

            -- Row 1: filled circle, outlined circle, ellipse, arc
            world:spawn(Transform(40, 40, 0, 1), gfx.Circle(15), gfx.Color(1, 0, 0, 1))
            world:spawn(Transform(100, 40, 0, 1), gfx.Circle(15, 3), gfx.Color(0, 1, 0, 1))
            world:spawn(Transform(160, 40, 0, 1), gfx.Ellipse(22, 10), gfx.Color(0, 0, 1, 1))
            -- Quarter pie covering the +x..+y (screen: right-down) quadrant
            world:spawn(Transform(220, 40, 0, 1), gfx.Arc(16, 16, 0, math.pi / 2), gfx.Color(1, 1, 0, 1))

            -- Row 2: line, filled rect, rounded rect, rotated rect
            world:spawn(Transform(40, 100, 0, 1), gfx.Line(-18, 0, 18, 0, 4), gfx.Color(1, 0, 1, 1))
            world:spawn(Transform(100, 100, 0, 1), gfx.Rectangle(34, 22), gfx.Color(0, 1, 1, 1))
            world:spawn(Transform(160, 100, 0, 1), gfx.Rectangle(30, 30), gfx.RoundedCorners(13), gfx.Color(1, 1, 1, 1))
            local rotated = world:spawn(Transform(220, 100, 0, 1), gfx.Rectangle(36, 8), gfx.Color(1, 0, 0, 1))
            local rt = world:getMut(rotated, Transform)
            rt.rotation = math.pi / 2

            -- Row 3: scaled rect (x stretched 3x)
            local scaled = world:spawn(Transform(100, 170, 0, 1), gfx.Rectangle(10, 10), gfx.Color(0, 1, 0, 1))
            local st = world:getMut(scaled, Transform)
            st.scaleX = 3
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("fills a circle inside its radius and not outside", function()
        waitPixel(app, 40, 40, isRed, "circle center should be red")
        waitPixel(app, 40 + 25, 40, isBackground, "outside circle radius should be background")
    end)

    it("outlines a circle on its rim and leaves the center hollow", function()
        -- Probe just inside the radius: the stroke hugs the rim's inner
        -- side and the exact boundary pixel is anti-aliased.
        waitPixel(app, 100 + 13, 40, isGreen, "circle rim should carry the outline")
        waitPixel(app, 100, 40, isBackground, "outlined circle center should be hollow")
    end)

    it("stretches an ellipse along its radii", function()
        waitPixel(app, 160 + 18, 40, isBlue, "inside ellipse x-radius should be blue")
        waitPixel(app, 160, 40 - 16, isBackground, "beyond ellipse y-radius should be background")
    end)

    it("fills an arc only inside its angular range", function()
        -- Mid-angle (45 degrees, screen down-right), inside the radius
        waitPixel(app, 220 + 8, 40 + 8, isYellow, "inside the arc quadrant should be yellow")
        -- Opposite quadrant (up-left) at the same distance
        waitPixel(app, 220 - 8, 40 - 8, isBackground, "opposite arc quadrant should be background")
    end)

    it("draws a line along its endpoints with width", function()
        waitPixel(app, 40, 100, isMagenta, "line midpoint should be magenta")
        waitPixel(app, 40, 100 + 10, isBackground, "off the line should be background")
    end)

    it("fills a rectangle to its extents", function()
        waitPixel(app, 100, 100, isCyan, "rect center should be cyan")
        waitPixel(app, 100 + 14, 100 + 8, isCyan, "near rect corner should still be cyan")
        waitPixel(app, 100 + 22, 100, isBackground, "outside rect width should be background")
    end)

    it("cuts rounded rectangle corners", function()
        waitPixel(app, 160, 100, isWhite, "rounded rect center should be white")
        waitPixel(app, 160 - 13.5, 100 - 13.5, isBackground, "rounded corner should be cut away")
    end)

    it("applies Transform rotation", function()
        -- A 36x8 rect rotated 90 degrees reads tall, not wide.
        waitPixel(app, 220, 100 + 14, isRed, "rotated rect should extend vertically")
        waitPixel(app, 220 + 14, 100, isBackground, "rotated rect should not extend horizontally")
    end)

    it("applies Transform scale", function()
        -- A 10x10 rect with scaleX=3 spans 30x10.
        waitPixel(app, 100 + 12, 170, isGreen, "scaled rect should extend beyond its base width")
        waitPixel(app, 100, 170 + 9, isBackground, "scaled rect height should be unscaled")
    end)
end)
