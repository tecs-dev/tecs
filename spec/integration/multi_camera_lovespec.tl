--- Love2D integration suite: multi-camera rendering. A secondary camera
--- with a screen viewport renders its own view of the world (own
--- position, zoom, and layer mask) composited over the primary view.
--- Covers pipeline:newCamera, per-camera cull layer masks, and the
--- renderWithCamera path.
---
--- Run via `make test-love FILE_MATCH='multi_camera'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

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
local function isBlue(p: {number}): boolean return p[3] > 0.8 and p[1] < 0.2 end
local function notGreen(p: {number}): boolean return p[2] < 0.5 end

describe("multi camera: secondary viewport with its own view", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        -- World content: red marker on layer 1 in the primary view, and
        -- a green marker on layer 2 far away at (1000, 1000), visible
        -- only through the secondary camera.
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(Transform(80, 120, 0, 1), gfx.Rectangle(20, 20), gfx.Color(1, 0, 0, 1))
            world:spawn(Transform(1000, 1000, 0, 2), gfx.Rectangle(30, 30), gfx.Color(0, 1, 0, 1))
            local imageData = love.image.newImageData(16, 16)
            imageData:mapPixel(function(_x, _y, _r, _g, _b, _a)
                return 0, 0, 1, 1
            end)
            world:spawn(
                Transform(1090, 992, 0.2, 2),
                gfx.Image(love.graphics.newImage(imageData)))
            return true
        ]])
        waitPixel(app, 80, 120, isRed, "primary view marker")
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("a secondary camera renders its own world position in its viewport", function()
        fixture.runLua(app, [[
            local gfx = require("tecs.gfx")
            local pipeline = world.resources[gfx.PIPELINE]
            local mini = pipeline:newCamera("mini", {
                viewport = {220, 10, 90, 70},
                layers = {2},
            })
            mini:setPosition(1000, 1000)
            return true
        ]])
        -- The green far-away marker appears at the viewport's center.
        waitPixel(app, 220 + 45, 10 + 35, isGreen, "secondary viewport should show the layer-2 marker")
        -- A direct Image outside the primary camera's view must still use
        -- the active secondary camera for culling and projection.
        -- The 320x240 virtual view scales into the 90x70 viewport. A
        -- 90-world-unit offset lands about 26 pixels right of center.
        waitPixel(app, 220 + 45 + 29, 10 + 35, isBlue,
            "secondary viewport should show the layer-2 Image")
        -- The primary view still renders its own content.
        waitPixel(app, 80, 120, isRed, "primary view should keep rendering")
    end)

    it("the secondary camera's layer mask filters content", function()
        -- Point the mini camera at the red layer-1 marker; the mask
        -- (layers = {2}) must hide it.
        fixture.runLua(app, [[
            local gfx = require("tecs.gfx")
            world.resources[gfx.PIPELINE]:getCamera("mini"):setPosition(80, 120)
            return true
        ]])
        local settled = fixture.eventually(fixture.callTimeout, function(): boolean
            local p = fixture.probePixels(app, {{(220 + 45) / W, (10 + 35) / H}})[1]
            if p[2] < 0.5 and p[1] < 0.5 then return true end
            return nil
        end)
        luassert.is_true(settled == true,
            "layer-1 content leaked into the layer-masked secondary camera")
    end)

    it("removing the camera restores the primary view in its viewport", function()
        fixture.runLua(app, [[
            local gfx = require("tecs.gfx")
            world.resources[gfx.PIPELINE]:removeCamera("mini")
            return true
        ]])
        -- The viewport area belongs to the primary view again; the
        -- world there is empty background.
        waitPixel(app, 220 + 45, 10 + 35, notGreen, "viewport area should revert to the primary view")
        waitPixel(app, 80, 120, isRed, "primary view intact after camera removal")
    end)
end)
