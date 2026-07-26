--- Love2D integration suite: sprite occluder silhouettes. A sprite whose
--- top half is opaque and bottom half transparent casts a 2D shadow
--- shaped by its alpha channel: ground behind the opaque rows darkens,
--- ground behind the transparent rows stays lit. This is what separates
--- the sprite shadow-mask path (texture-alpha silhouette) from shape
--- occluders, and it exercises the mask gate's "sprite occluders redraw
--- every frame" contract.
---
--- Run via `make test-love FILE_MATCH='sprite_occluder'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/lighting"

local W <const> = 320.0
local H <const> = 240.0

-- Light at (80, 120); sprite centered at (160, 120), 32x32: opaque rows
-- world y 104..120, transparent rows 120..136. Probes sit behind it
-- (right side), inside each band.
local SHADOW_PROBE <const> = {{200 / W, 111 / H}}
local CLEAR_PROBE <const> = {{200 / W, 129 / H}}

local function level(app: fixture.App, point: {{number}}): number
    local p = fixture.probePixels(app, point)[1]
    return math.max(p[1], p[2], p[3])
end

describe("sprite occluders: alpha shapes the 2D shadow", function()
    local app: fixture.App
    local litShadowSide: number
    local litClearSide: number

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(Transform(80, 120, 0, 1), gfx.Light(400, 2.0, 0.5))
            return true
        ]])
        local lit = fixture.eventually(fixture.callTimeout, function(): boolean
            if level(app, SHADOW_PROBE) > 0.25 then return true end
            return nil
        end)
        luassert.is_true(lit == true, "surface never lit up")
        litShadowSide = level(app, SHADOW_PROBE)
        litClearSide = level(app, CLEAR_PROBE)
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("shadows only behind the opaque half of the sprite", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            local Transform = tecs.builtins.Transform
            local imgData = love.image.newImageData(32, 32)
            for y = 0, 15 do
                for x = 0, 31 do imgData:setPixel(x, y, 0.5, 0.5, 0.5, 1) end
            end
            -- Rows 16..31 stay alpha 0 (transparent)
            local sheet = gfx.SpriteSheet.fromTexture(love.graphics.newImage(imgData))
            _G.tecsSpriteOccluder = world:spawn(
                Transform(160, 120, 0.2, 2),
                gfx.Sprite.fromSheet(sheet, nil, {centered = true}),
                gfx.Occluder(1.0))
            return true
        ]])

        local shadowed = fixture.eventually(fixture.callTimeout, function(): boolean
            if level(app, SHADOW_PROBE) < litShadowSide * 0.7 then return true end
            return nil
        end)
        luassert.is_true(shadowed == true, string.format(
            "ground behind the opaque half never darkened (lit %.3f, now %.3f)",
            litShadowSide, level(app, SHADOW_PROBE)))

        -- The transparent half must NOT cast: its band stays lit.
        local clear = level(app, CLEAR_PROBE)
        luassert.is_true(clear > litClearSide * 0.75, string.format(
            "ground behind the transparent half darkened too (lit %.3f, now %.3f); " ..
            "the silhouette is not alpha-shaped", litClearSide, clear))
    end)

    it("despawning the sprite clears its shadow", function()
        fixture.runLua(app, "world:despawn(_G.tecsSpriteOccluder) return true")
        local restored = fixture.eventually(fixture.callTimeout, function(): boolean
            if level(app, SHADOW_PROBE) > litShadowSide * 0.85 then return true end
            return nil
        end)
        luassert.is_true(restored == true, "sprite shadow persisted after despawn")
    end)
end)
