--- Love2D integration suite: emission and bloom. A small shape with the
--- fixture's "testglow" material writes into the emission G-buffer lane;
--- with bloom enabled its glow spills past the shape's silhouette, and
--- disabling bloom removes the halo while the emissive core keeps
--- rendering. Covers the emission lane end to end plus the Dual Kawase
--- pyramid and its enable/disable path.
---
--- Run via `make test-love FILE_MATCH='bloom_emission'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local W <const> = 320.0
local H <const> = 240.0

-- Emissive 16x16 rect at screen center; the halo probe sits 20px to the
-- right: outside the rect (half extent 8) but inside a wide bloom.
local CORE <const> = {{160 / W, 120 / H}}
local HALO <const> = {{180 / W, 120 / H}}

local function brightness(app: fixture.App, point: {{number}}): number
    local p = fixture.probePixels(app, point)[1]
    return math.max(p[1], p[2], p[3])
end

describe("bloom: emission glows past the silhouette", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(Transform(160, 120, 0, 1),
                gfx.Rectangle(16, 16), gfx.Color(0, 0, 0, 1),
                _G.tecsGlowMaterial:withParams(0, 1, 0, 4))
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("renders the emissive core without bloom", function()
        local lit = fixture.eventually(fixture.callTimeout, function(): boolean
            if brightness(app, CORE) > 0.5 then return true end
            return nil
        end)
        luassert.is_true(lit == true, "emissive core never rendered")
        luassert.is_true(brightness(app, HALO) < 0.15,
            "halo probe should be dark with bloom disabled, got " ..
            tostring(brightness(app, HALO)))
    end)

    it("enabling bloom spills the glow past the shape", function()
        fixture.runLua(app, [[
            local gfx = require("tecs.gfx")
            world.resources[gfx.PIPELINE]:setBloom({
                enabled = true, intensity = 2.0, radius = 3.0,
            })
            return true
        ]])
        local glow = fixture.eventually(fixture.callTimeout, function(): boolean
            if brightness(app, HALO) > 0.1 then return true end
            return nil
        end)
        luassert.is_true(glow == true, "bloom halo never appeared beside the emissive shape")
        luassert.is_true(brightness(app, CORE) > 0.5, "emissive core dimmed when bloom enabled")
    end)

    it("disabling bloom removes the halo but keeps the core", function()
        fixture.runLua(app, [[
            local gfx = require("tecs.gfx")
            world.resources[gfx.PIPELINE]:setBloom({enabled = false})
            return true
        ]])
        local cleared = fixture.eventually(fixture.callTimeout, function(): boolean
            if brightness(app, HALO) < 0.15 then return true end
            return nil
        end)
        luassert.is_true(cleared == true, "bloom halo persisted after disabling")
        luassert.is_true(brightness(app, CORE) > 0.5, "emissive core vanished with bloom disabled")
    end)
end)
