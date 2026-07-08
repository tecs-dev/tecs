--- Love2D integration suite: material variants. Shapes carrying a
--- Material component render through per-material shader variants; the
--- fixture's "testflat" material paints albedo purely from the
--- per-entity params, so probes can verify variant dispatch, per-entity
--- params in the SSBO, and runtime param updates across shape types.
---
--- Run via `make test-love FILE_MATCH='material_variants'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("spec.integration.harness.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local W <const> = 320.0
local H <const> = 240.0

local function waitPixel(app: fixture.App, x: number, y: number,
        check: function({number}): boolean, label: string)
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        local p = fixture.probePixels(app, {{x / W, y / H}})[1]
        if check(p) then return true end
        return nil
    end)
    local p = fixture.probePixels(app, {{x / W, y / H}})[1]
    luassert.is_true(ok == true, string.format(
        "%s: pixel (%d, %d) = (%.2f, %.2f, %.2f)",
        label, x as integer, y as integer, p[1], p[2], p[3]))
end

local function isBlue(p: {number}): boolean return p[3] > 0.8 and p[1] < 0.2 and p[2] < 0.2 end
local function isYellow(p: {number}): boolean return p[1] > 0.8 and p[2] > 0.8 and p[3] < 0.2 end
local function isRed(p: {number}): boolean return p[1] > 0.8 and p[2] < 0.2 and p[3] < 0.2 end

describe("material variants: params drive shape albedo", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            local flat = _G.tecsFlatMaterial

            -- Both spawn with red Color; the material must override it.
            _G.tecsMatRect = world:spawn(Transform(80, 120, 0, 1),
                gfx.Rectangle(40, 40), gfx.Color(1, 0, 0, 1),
                flat:withParams(0, 0, 1, 0))
            _G.tecsMatCircle = world:spawn(Transform(240, 120, 0, 1),
                gfx.Circle(20), gfx.Color(1, 0, 0, 1),
                flat:withParams(1, 1, 0, 0))

            -- Control: an untagged red rect renders the standard path
            -- alongside material variants.
            world:spawn(Transform(160, 40, 0, 1),
                gfx.Rectangle(30, 30), gfx.Color(1, 0, 0, 1))
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("renders a rect through the material with param albedo", function()
        waitPixel(app, 80, 120, isBlue, "material rect should be params-blue, not Color-red")
    end)

    it("renders a circle through the same material with different params", function()
        waitPixel(app, 240, 120, isYellow, "material circle should be params-yellow")
    end)

    it("standard-path shapes still render beside material variants", function()
        waitPixel(app, 160, 40, isRed, "untagged rect should render its Color")
    end)

    it("updates per-entity params at runtime", function()
        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            local mat = world:getMut(_G.tecsMatRect, gfx.Material)
            mat.p0, mat.p1, mat.p2 = 1, 0, 0
            return true
        ]])
        waitPixel(app, 80, 120, isRed, "material rect should follow the param update")
    end)
end)
