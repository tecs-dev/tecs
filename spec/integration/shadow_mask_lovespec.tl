--- Love2D integration suite: occluder shadow-mask lifecycle. Boots the
--- lighting fixture (white surface, near-black ambient, deferred
--- lighting) and verifies through pixel probes that the shadow mask
--- tracks occluder changes: a spawned occluder darkens the pixels behind
--- it, moving it shifts the shadow, and despawning it clears the shadow.
--- This exercises the pipeline's shadow-mask reuse gate: the mask only
--- redraws when occluder state or the camera changes, so every
--- transition below must invalidate the cached mask.
---
--- Run via `make test-love`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/lighting"

local SETTLE <const> = fixture.callTimeout

-- Fixture layout: 320x240 window, white rect covering the view, light at
-- x=100. The occluder sits at x=160 between the light and the probe at
-- x=220, all on the horizontal centerline.
local PROBE_X <const> = 220 / 320
local PROBE_Y <const> = 0.5

local function probeBrightness(app: fixture.App): number
    local probe = fixture.probePixels(app, {{PROBE_X, PROBE_Y}})[1]
    return math.max(probe[1], probe[2], probe[3])
end

local function waitLevel(app: fixture.App, check: function(number): boolean): number
    return fixture.eventually(SETTLE, function(): number
        local level = probeBrightness(app)
        if check(level) then return level end
        return nil
    end)
end

describe("shadow mask: occluder lifecycle", function()
    local app: fixture.App
    local litLevel: number
    local shadowLevel: number

    setup(function()
        app = fixture.start(APP_DIR)
        -- A light to the left of the probe point, tall enough to reach it.
        fixture.runLua(app, [[
            local gfx = require("tecs.gfx")
            local Transform = require("tecs").builtins.Transform
            _G.tecsShadowLight = world:spawn(
                Transform(100, 120, 0, 1), gfx.Light(400, 2.0, 0.5))
            return true
        ]])
        -- The probe sits 120px from the light, so falloff applies; any
        -- clearly-above-ambient level works since later checks compare
        -- against this measured value.
        litLevel = waitLevel(app, function(level: number): boolean
            return level > 0.25
        end)
        luassert.is_number(litLevel, "surface never lit up")
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("a spawned occluder casts a shadow on pixels behind it", function()
        fixture.runLua(app, [[
            local gfx = require("tecs.gfx")
            local Transform = require("tecs").builtins.Transform
            _G.tecsShadowOccluder = world:spawn(
                Transform(160, 120, 0.1, 2),
                gfx.Rectangle(16, 60),
                gfx.Color(0.2, 0.2, 0.2, 1),
                gfx.Occluder(1.0))
            return true
        ]])
        shadowLevel = waitLevel(app, function(level: number): boolean
            return level < litLevel * 0.7
        end)
        luassert.is_number(shadowLevel,
            "probe never darkened after spawning an occluder (mask not redrawn?)")
    end)

    it("moving the occluder away restores the light", function()
        fixture.runLua(app, [[
            local Transform = require("tecs").builtins.Transform
            local t = world:getMut(_G.tecsShadowOccluder, Transform)
            t.y = 400
            return true
        ]])
        local level = waitLevel(app, function(level: number): boolean
            return level > litLevel * 0.8
        end)
        luassert.is_number(level,
            "shadow stuck after moving the occluder (stale cached mask)")
    end)

    it("a moved-back occluder darkens the probe again", function()
        fixture.runLua(app, [[
            local Transform = require("tecs").builtins.Transform
            local t = world:getMut(_G.tecsShadowOccluder, Transform)
            t.y = 120
            return true
        ]])
        local level = waitLevel(app, function(level: number): boolean
            return level < litLevel * 0.7
        end)
        luassert.is_number(level, "shadow did not return after moving the occluder back")
    end)

    it("despawning the occluder clears its shadow", function()
        fixture.runLua(app, "world:despawn(_G.tecsShadowOccluder) return true")
        local level = waitLevel(app, function(level: number): boolean
            return level > litLevel * 0.8
        end)
        luassert.is_number(level,
            "shadow persisted after despawning the occluder (stale cached mask)")
    end)
end)
