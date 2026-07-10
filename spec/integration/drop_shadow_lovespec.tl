--- Love2D integration suite: drop-shadow AO. On the lighting fixture's
--- white surface, a sprite with a DropShadow component must darken the
--- ground somewhere adjacent to it (the exact projection depends on the
--- light direction and entity height, so a ring of candidate ground
--- pixels is searched), and the shadow must vanish when the component is
--- removed. Covers the per-light drop-shadow fan-out in the sprite cull,
--- the AO canvas, and its application in compose.
---
--- Run via `make test-love FILE_MATCH='drop_shadow'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("spec.integration.harness.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/lighting"

local W <const> = 320.0
local H <const> = 240.0

-- Caster: 24x24 sprite centered at (160, 120), light at (100, 120).
-- Candidate ground pixels ring the caster on the sides a shadow can
-- plausibly land (right of it, away from the light, and below it).
local CANDIDATES <const>: {{number}} = {
    {180 / W, 120 / H}, {192 / W, 120 / H}, {208 / W, 120 / H},
    {180 / W, 132 / H}, {192 / W, 132 / H},
    {160 / W, 140 / H}, {160 / W, 152 / H},
    {172 / W, 140 / H}, {184 / W, 148 / H},
}

local function brightnessLevels(app: fixture.App): {number}
    local pixels = fixture.probePixels(app, CANDIDATES)
    local levels: {number} = {}
    for i = 1, #pixels do
        levels[i] = math.max(pixels[i][1], pixels[i][2], pixels[i][3])
    end
    return levels
end

describe("drop shadow: AO darkens ground beside the caster", function()
    local app: fixture.App
    local litLevels: {number}

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(Transform(100, 120, 0, 1), gfx.Light(400, 2.0, 0.5))
            return true
        ]])
        local lit = fixture.eventually(fixture.callTimeout, function(): boolean
            if brightnessLevels(app)[1] > 0.25 then return true end
            return nil
        end)
        luassert.is_true(lit == true, "surface never lit up")
        litLevels = brightnessLevels(app)
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("a DropShadow sprite darkens a nearby ground pixel", function()
        -- Drop shadows are implemented for sprites (the per-light
        -- fan-out lives in the sprite cull), so the caster is a
        -- procedural opaque sprite.
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            local imgData = love.image.newImageData(24, 24)
            for y = 0, 23 do
                for x = 0, 23 do imgData:setPixel(x, y, 0.6, 0.6, 0.6, 1) end
            end
            local sheet = gfx.SpriteSheet.fromTexture(love.graphics.newImage(imgData))
            _G.tecsDropCaster = world:spawn(
                Transform(160, 120, 0.2, 2),
                gfx.Sprite.fromSheet(sheet, nil, {centered = true}),
                gfx.DropShadow(0.6, 0.8))
            return true
        ]])
        local shadowedIdx = fixture.eventually(fixture.callTimeout, function(): integer
            local levels = brightnessLevels(app)
            for i = 1, #levels do
                if levels[i] < litLevels[i] * 0.85 then return i end
            end
            return nil
        end)
        luassert.is_number(shadowedIdx,
            "no candidate ground pixel darkened after spawning a DropShadow sprite")
    end)

    it("disabling pipeline shadows also disables drop-shadow AO", function()
        -- The debugger's `light shadows off` flips this same field; drop
        -- shadows must go dark with the raymarch shadows, not outlive them.
        fixture.runLua(app, [[
            local pipelinekey = require("tecs2d.gfx.internal.pipelinekey")
            world.resources[pipelinekey.PIPELINE].shadowsEnabled = false
            return true
        ]])
        local cleared = fixture.eventually(fixture.callTimeout, function(): boolean
            local levels = brightnessLevels(app)
            for i = 1, #levels do
                if levels[i] < litLevels[i] * 0.9 then return nil end
            end
            return true
        end)
        luassert.is_true(cleared == true, "drop shadow survived shadowsEnabled = false")

        fixture.runLua(app, [[
            local pipelinekey = require("tecs2d.gfx.internal.pipelinekey")
            world.resources[pipelinekey.PIPELINE].shadowsEnabled = true
            return true
        ]])
        local back = fixture.eventually(fixture.callTimeout, function(): boolean
            local levels = brightnessLevels(app)
            for i = 1, #levels do
                if levels[i] < litLevels[i] * 0.85 then return true end
            end
            return nil
        end)
        luassert.is_true(back == true, "drop shadow did not return after re-enabling shadows")
    end)

    it("removing DropShadow restores the ground", function()
        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            world:remove(_G.tecsDropCaster, gfx.DropShadow)
            return true
        ]])
        local restored = fixture.eventually(fixture.callTimeout, function(): boolean
            local levels = brightnessLevels(app)
            for i = 1, #levels do
                if levels[i] < litLevels[i] * 0.9 then return nil end
            end
            return true
        end)
        luassert.is_true(restored == true, "ground stayed darkened after removing DropShadow")
    end)
end)
