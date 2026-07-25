--- Real-Love coverage for directly rendered Image components. Covers
--- repetition, oversized textures, renderer composition, camera/layer
--- filtering, and lighting shadows.
---
--- Run via `make test-love FILE_MATCH='image'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"
local W <const> = 320.0
local H <const> = 240.0

local function isRed(pixel: {number}): boolean
    return pixel[1] > 0.8 and pixel[2] < 0.2 and pixel[3] < 0.2
end

local function isBlue(pixel: {number}): boolean
    return pixel[3] > 0.8 and pixel[1] < 0.2 and pixel[2] < 0.2
end

local function isGreen(pixel: {number}): boolean
    return pixel[2] > 0.8 and pixel[1] < 0.2 and pixel[3] < 0.2
end

local function isMagenta(pixel: {number}): boolean
    return pixel[1] > 0.8 and pixel[2] < 0.2 and pixel[3] > 0.8
end

local function isDark(pixel: {number}): boolean
    return pixel[1] < 0.1 and pixel[2] < 0.1 and pixel[3] < 0.1
end

local function waitPixel(
    app: fixture.App,
    x: number,
    y: number,
    check: function({number}): boolean,
    label: string
)
    local point = {{x / W, y / H}}
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        if check(fixture.probePixels(app, point)[1]) then return true end
        return nil
    end)
    local pixel = fixture.probePixels(app, point)[1]
    luassert.is_true(ok == true, string.format(
        "%s: pixel (%d, %d) = (%.2f, %.2f, %.2f)",
        label, x as integer, y as integer,
        pixel[1], pixel[2], pixel[3]))
end

describe("Image rendering", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform

            local whiteData = love.image.newImageData(32, 32)
            whiteData:mapPixel(function(_x, _y, _r, _g, _b, _a)
                return 1, 1, 1, 1
            end)
            local white = love.graphics.newImage(whiteData)

            local repeatData = love.image.newImageData(8, 8)
            repeatData:mapPixel(function(_x, _y, _r, _g, _b, _a)
                return 1, 0, 0, 1
            end)
            world:spawn(
                Transform(12, 36, 0, 1),
                gfx.Image.fromTexture(love.graphics.newImage(repeatData), {
                    repeatX = true,
                }))

            local large = love.graphics.newCanvas(2050, 4)
            love.graphics.push("all")
            love.graphics.setCanvas(large)
            love.graphics.clear(0, 0, 1, 1)
            love.graphics.setCanvas()
            love.graphics.pop()
            world:spawn(Transform(-1000, 180, 0, 1), gfx.Image(large))

            -- A Material Image uses additive forward composition over a
            -- mid-gray deferred shape.
            world:spawn(
                Transform(64, 104, 0, 1),
                gfx.Rectangle(40, 40),
                gfx.Color(0.5, 0.5, 0.5, 1))
            world:spawn(
                Transform(48, 88, 0, 2),
                gfx.Image(white),
                gfx.Color(1, 0, 0, 1),
                _G.tecsFlatMaterial:withParams(1, 0, 0, 0),
                gfx.blend.AdditiveBlend())

            -- Clip the right half of a blue Image.
            world:spawn(
                Transform(112, 88, 0, 2),
                gfx.Image(white),
                gfx.Color(0, 0, 1, 1),
                gfx.ClipBounds(112, 88, 128, 120))

            -- The fixture material ignores Color and paints from params.
            world:spawn(
                Transform(176, 88, 0, 2),
                gfx.Image(white),
                gfx.Color(1, 0, 0, 1),
                _G.tecsFlatMaterial:withParams(0, 1, 0, 0))

            -- A vertex Material displaces Image geometry in world space.
            local offsetMaterial = gfx.newMaterial("testimageoffset", {
                vertex = "vec2 materialVertex(vec2 worldPos, "
                    .. "float time, vec4 params) { "
                    .. "return worldPos + params.xy; }",
            })
            world:spawn(
                Transform(16, 136, 0, 2),
                gfx.Image(white),
                gfx.Color(0, 0, 1, 1),
                offsetMaterial:withParams(32, 0, 0, 0))

            -- Layer visibility must filter direct Images.
            local pipeline = world.resources[gfx.PIPELINE]
            pipeline:setLayerVisibility(4, false)
            world:spawn(
                Transform(240, 88, 0, 4),
                gfx.Image(white),
                gfx.Color(0, 1, 1, 1))

            -- Starts outside the primary camera and becomes visible when
            -- the test moves the camera to this world position.
            world:spawn(
                Transform(984, 104, 0, 2),
                gfx.Image(white),
                gfx.Color(1, 0, 1, 1))
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("repeats the full image only on the requested axis", function()
        local points = {
            {16 / W, 40 / H},
            {160 / W, 40 / H},
            {304 / W, 40 / H},
            {160 / W, 56 / H},
        }
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            local pixels = fixture.probePixels(app, points)
            if isRed(pixels[1])
                    and isRed(pixels[2])
                    and isRed(pixels[3])
                    and isDark(pixels[4]) then
                return true
            end
            return nil
        end)
        luassert.is_true(ok == true, "repeated Image did not cover the visible row")
    end)

    it("renders a complete texture wider than sprite buckets", function()
        local point = {{160 / W, 182 / H}}
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            if isBlue(fixture.probePixels(app, point)[1]) then
                return true
            end
            return nil
        end)
        luassert.is_true(ok == true, "2050-pixel Image texture did not render")
    end)

    it("applies blend tags, ClipBounds, and Material output", function()
        waitPixel(app, 64, 104, function(pixel: {number}): boolean
            return pixel[1] > 0.85
                and pixel[2] > 0.35 and pixel[2] < 0.65
                and pixel[3] > 0.35 and pixel[3] < 0.65
        end, "additive Image")
        waitPixel(app, 120, 104, isBlue, "inside clipped Image")
        waitPixel(app, 136, 104, isDark, "outside clipped Image")
        waitPixel(app, 192, 104, isGreen, "material Image")
        waitPixel(app, 32, 152, isDark, "vertex Material source position")
        waitPixel(app, 64, 152, isBlue, "vertex Material displaced Image")
    end)

    it("obeys layer visibility and the active camera", function()
        waitPixel(app, 256, 104, isDark, "hidden Image layer")

        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            local pipeline = world.resources[gfx.PIPELINE]
            pipeline:setLayerVisibility(4, true)
            return true
        ]])
        waitPixel(app, 256, 104, function(pixel: {number}): boolean
            return pixel[2] > 0.8 and pixel[3] > 0.8 and pixel[1] < 0.2
        end, "visible Image layer")

        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            world.resources[gfx.PIPELINE]:getCamera():setPosition(1000, 120)
            return true
        ]])
        waitPixel(app, 160, 120, isMagenta, "Image through moved camera")
    end)
end)

local SHADOW_PROBE <const> = {{200 / W, 120 / H}}
local DROP_CANDIDATES <const>: {{number}} = {
    {180 / W, 120 / H}, {192 / W, 120 / H}, {208 / W, 120 / H},
    {180 / W, 132 / H}, {192 / W, 132 / H},
    {160 / W, 140 / H}, {160 / W, 152 / H},
    {172 / W, 140 / H}, {184 / W, 148 / H},
}

local function pixelLevel(pixel: {number}): number
    return math.max(pixel[1], pixel[2], pixel[3])
end

local function levels(app: fixture.App, points: {{number}}): {number}
    local pixels = fixture.probePixels(app, points)
    local result: {number} = {}
    for i = 1, #pixels do
        result[i] = pixelLevel(pixels[i])
    end
    return result
end

describe("Image lighting composition", function()
    local app: fixture.App
    local litShadowLevel: number
    local litDropLevels: {number}

    setup(function()
        app = fixture.start("build/test_deps/spec/integration/apps/lighting")
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(Transform(100, 120, 0, 1), gfx.Light(400, 2.0, 0.5))
            return true
        ]])
        local lit = fixture.eventually(fixture.callTimeout, function(): boolean
            if levels(app, SHADOW_PROBE)[1] > 0.25 then return true end
            return nil
        end)
        luassert.is_true(lit == true, "surface never lit up")
        litShadowLevel = levels(app, SHADOW_PROBE)[1]
        litDropLevels = levels(app, DROP_CANDIDATES)
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("uses Image alpha as an Occluder silhouette", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            local data = love.image.newImageData(32, 32)
            data:mapPixel(function(_x, _y, _r, _g, _b, _a)
                return 0.6, 0.6, 0.6, 1
            end)
            world:spawn(
                Transform(160, 120, 0.2, 2),
                gfx.Image(love.graphics.newImage(data)),
                gfx.Pivot(0.5, 0.5),
                gfx.Occluder(1.0))
            return true
        ]])

        local shadowed = fixture.eventually(fixture.callTimeout, function(): boolean
            if levels(app, SHADOW_PROBE)[1] < litShadowLevel * 0.7 then
                return true
            end
            return nil
        end)
        luassert.is_true(shadowed == true, string.format(
            "Image Occluder cast no shadow (lit %.3f, now %.3f)",
            litShadowLevel, levels(app, SHADOW_PROBE)[1]))
    end)

    it("projects an Image DropShadow beside the caster", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            local data = love.image.newImageData(24, 24)
            data:mapPixel(function(_x, _y, _r, _g, _b, _a)
                return 0.6, 0.6, 0.6, 1
            end)
            world:spawn(
                Transform(160, 120, 0.2, 2),
                gfx.Image(love.graphics.newImage(data)),
                gfx.Pivot(0.5, 0.5),
                gfx.DropShadow(0.6, 0.8))
            return true
        ]])

        local shadowedIndex = fixture.eventually(
            fixture.callTimeout,
            function(): integer
                local current = levels(app, DROP_CANDIDATES)
                for i = 1, #current do
                    if current[i] < litDropLevels[i] * 0.85 then return i end
                end
                return nil
            end
        )
        luassert.is_number(shadowedIndex,
            "no candidate ground pixel darkened for an Image DropShadow")
    end)
end)
