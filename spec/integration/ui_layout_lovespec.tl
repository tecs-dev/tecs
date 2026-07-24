--- Love2D integration suite: UI layout. A Viewport container with
--- ChildOf + RelativeTransform children verifies parent-relative
--- positioning, scroll offsets moving children, and clip bounds hiding
--- content outside the container. Directly guards the layout systems'
--- dirty gates: scroll and container moves must keep propagating even
--- though static frames skip the passes.
---
--- Run via `make test-love FILE_MATCH='ui_layout'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local W <const> = 320.0
local H <const> = 240.0

-- Container: top-left origin at (100, 40), 120x160. One child at local
-- (10, 10) (a 100x24 bar), one child at local (10, 200) (outside the
-- container's height, so clipped).
local CONTAINER_X <const> = 100
local CONTAINER_Y <const> = 40

local function probe(app: fixture.App, x: number, y: number): {number}
    return fixture.probePixels(app, {{x / W, y / H}})[1]
end

local function waitPixel(app: fixture.App, x: number, y: number,
        check: function({number}): boolean, label: string)
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        if check(probe(app, x, y)) then return true end
        return nil
    end)
    local p = probe(app, x, y)
    luassert.is_true(ok == true, string.format(
        "%s: pixel (%d, %d) = (%.2f, %.2f, %.2f)",
        label, x as integer, y as integer, p[1], p[2], p[3]))
end

local function isGreen(p: {number}): boolean return p[2] > 0.8 and p[1] < 0.2 end
local function isRed(p: {number}): boolean return p[1] > 0.8 and p[2] < 0.2 end
local function notGreen(p: {number}): boolean return p[2] < 0.5 end

describe("ui layout: containers position, scroll, and clip children", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, string.format([[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local ui = require("tecs2d.ui")
            local Transform = tecs.builtins.Transform
            local ChildOf = tecs.builtins.ChildOf
            local RelativeTransform = tecs.builtins.RelativeTransform

            local container = world:spawn(
                Transform(%d, %d),
                gfx.Rectangle(120, 160),
                ui.LayoutBox(gfx.Rectangle, nil, 0, 0),
                ui.Viewport(0, 0, 120, 400),
                gfx.Color(0.2, 0.2, 0.3, 1))
            _G.tecsUiContainer = container

            local function bar(localY)
                return world:spawn(
                    Transform(0, 0, 1),
                    ChildOf(container),
                    RelativeTransform.new({x = 10, y = localY, z = 1}),
                    gfx.Rectangle(100, 24),
                    ui.LayoutBox(gfx.Rectangle, nil, 0, 0),
                    gfx.Color(0, 1, 0, 1))
            end
            _G.tecsUiBar = bar(10)
            _G.tecsUiClippedBar = bar(200)
            return true
        ]], CONTAINER_X, CONTAINER_Y))
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("positions children relative to the container's top-left", function()
        -- Child local (10, 10) -> world (110, 50); bar center ~ (160, 62)
        waitPixel(app, CONTAINER_X + 10 + 50, CONTAINER_Y + 10 + 12, isGreen,
            "child bar should render inside the container")
    end)

    it("renders a centered LayoutBox around its Transform exactly once", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local ui = require("tecs2d.ui")
            world:spawn(
                tecs.builtins.Transform(40, 210, 5),
                gfx.Rectangle(40, 20),
                ui.LayoutBox(gfx.Rectangle),
                gfx.Color(1, 0, 0, 1))
            return true
        ]])
        -- Center (40,210), width 40: x=55 is inside. Applying both the
        -- LayoutBox offset and its synchronized pivot would end at x=40.
        waitPixel(app, 55, 210, isRed,
            "centered rectangle should not receive its origin offset twice")
    end)

    it("clips children outside the container bounds", function()
        -- The second bar's local y=200 lands past the container height
        -- (160); its would-be world position must show no green.
        waitPixel(app, CONTAINER_X + 10 + 50, CONTAINER_Y + 200 + 12, notGreen,
            "out-of-bounds child should be clipped")
    end)

    it("scrolling moves children and reveals clipped content", function()
        fixture.runLua(app, [[
            local ui = require("tecs2d.ui")
            local viewport = world:getMut(_G.tecsUiContainer, ui.Viewport)
            viewport.scrollY = 150
            return true
        ]])
        -- First bar scrolled up out of view: old position empties.
        waitPixel(app, CONTAINER_X + 10 + 50, CONTAINER_Y + 10 + 12, notGreen,
            "scrolled-away bar should leave its old position")
        -- Second bar now at local y = 200 - 150 = 50 -> world y ~ 90.
        waitPixel(app, CONTAINER_X + 10 + 50, CONTAINER_Y + 50 + 12, isGreen,
            "scrolling should reveal the previously clipped bar")
    end)

    it("moving the container carries children with it", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local Transform = tecs.builtins.Transform
            local t = world:getMut(_G.tecsUiContainer, Transform)
            t.x = t.x + 60
            return true
        ]])
        -- The revealed bar follows: world x shifts by 60.
        waitPixel(app, CONTAINER_X + 60 + 10 + 50, CONTAINER_Y + 50 + 12, isGreen,
            "child should follow the container move")
        waitPixel(app, CONTAINER_X + 10 + 20, CONTAINER_Y + 50 + 12, notGreen,
            "child should leave the pre-move position")
    end)
end)
