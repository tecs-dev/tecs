--- Love2D integration suite: spot lights and cookies. A cone-constrained
--- light lights only inside its cone, and a light with a half-blocked
--- cookie texture projects that pattern onto the ground. Covers the
--- spotlight direction/cone-cosine precompute, and the cookie atlas
--- registration + per-light cookie sampling in the lighting shader.
---
--- Run via `make test-love FILE_MATCH='spot_cookie'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("spec.integration.harness.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/lighting"

local W <const> = 320.0
local H <const> = 240.0

local function level(app: fixture.App, x: number, y: number): number
    local p = fixture.probePixels(app, {{x / W, y / H}})[1]
    return math.max(p[1], p[2], p[3])
end

describe("spot lights and cookies", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("a spot light lights inside its cone only", function()
        -- Cone pointing right (+x) from (120, 120).
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            _G.tecsSpot = world:spawn(
                Transform(120, 120, 0, 1),
                gfx.Light.new({
                    radius = 300, intensity = 2.0, height = 0.5,
                    direction = 0, coneAngle = math.pi / 6,
                }))
            return true
        ]])
        local inCone = fixture.eventually(fixture.callTimeout, function(): boolean
            if level(app, 170, 120) > 0.25 then return true end
            return nil
        end)
        luassert.is_true(inCone == true, "spot cone never lit the surface")
        -- Same distance behind the light (outside the cone): near ambient.
        local behind = level(app, 70, 120)
        luassert.is_true(behind < 0.15, string.format(
            "surface behind the spot should stay dark, got %.3f", behind))
        fixture.runLua(app, "world:despawn(_G.tecsSpot) return true")
    end)

    it("a cookie masks the light's projection", function()
        -- Cookie: left half black (blocked), right half white (open).
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            local imgData = love.image.newImageData(64, 64)
            for y = 0, 63 do
                for x = 0, 31 do imgData:setPixel(x, y, 0, 0, 0, 1) end
                for x = 32, 63 do imgData:setPixel(x, y, 1, 1, 1, 1) end
            end
            local sheet = gfx.SpriteSheet.fromTexture(love.graphics.newImage(imgData))
            local pipeline = world.resources[gfx.PIPELINE]
            pipeline:registerCookie("halfmask", sheet)
            _G.tecsCookieLight = world:spawn(
                Transform(160, 120, 0, 1),
                gfx.Light.new({
                    radius = 200, intensity = 2.0, height = 0.5,
                    cookie = "halfmask", cookieScale = 1.0,
                }))
            return true
        ]])
        -- Open (right) half lights up; blocked (left) half stays dark.
        local openLit = fixture.eventually(fixture.callTimeout, function(): boolean
            if level(app, 200, 120) > 0.25 then return true end
            return nil
        end)
        luassert.is_true(openLit == true, "cookie's open half never lit the surface")
        local blocked = level(app, 120, 120)
        luassert.is_true(blocked < 0.15, string.format(
            "cookie's blocked half should stay dark, got %.3f", blocked))
    end)
end)
