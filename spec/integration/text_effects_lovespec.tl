--- Love2D integration suite: MSDF text and TextEffects. Renders through
--- the real MSDF font asset (multichannel SDF decode in the text
--- shader), then layers TextEffects on: a glow tints pixels around the
--- glyphs and a colored offset shadow paints below-right of them.
--- First coverage of the MSDF path and the TextEffects SSBO lane.
---
--- Run via `make test-love FILE_MATCH='text_effects'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local W <const> = 320.0
local H <const> = 240.0

--- Count pixels in a box around (cx, cy) matching `check`.
local function countAround(app: fixture.App, cx: number, cy: number,
        reach: number, check: function({number}): boolean): integer
    local points: {{number}} = {}
    for dy = -reach, reach, 6 do
        for dx = -reach, reach, 6 do
            points[#points + 1] = {(cx + dx) / W, (cy + dy) / H}
        end
    end
    local pixels = fixture.probePixels(app, points)
    local count = 0
    for i = 1, #pixels do
        if check(pixels[i]) then count = count + 1 end
    end
    return count
end

local function isWhiteish(p: {number}): boolean
    return p[1] > 0.7 and p[2] > 0.7 and p[3] > 0.7
end
local function isGreenish(p: {number}): boolean
    return p[2] > 0.15 and p[2] > p[1] * 1.5 and p[2] > p[3] * 1.5
end
local function isRedish(p: {number}): boolean
    return p[1] > 0.3 and p[1] > p[2] * 2 and p[1] > p[3] * 2
end

local TEXT_X <const> = 140
local TEXT_Y <const> = 120

describe("text effects: MSDF glyphs, glow, and shadow", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, string.format([[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            _G.tecsFxText = world:spawn(
                Transform(%d, %d, 0, 1),
                gfx.Text("assets/firacode-nerd-msdf.json", "OO", 2, 2),
                gfx.Color(1, 1, 1, 1))
            return true
        ]], TEXT_X, TEXT_Y))
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("renders MSDF glyphs", function()
        local drawn = fixture.eventually(fixture.callTimeout, function(): integer
            local count = countAround(app, TEXT_X, TEXT_Y, 24, isWhiteish)
            if count > 0 then return count end
            return nil
        end)
        luassert.is_number(drawn, "MSDF text never rendered")
    end)

    -- Dense scan for the glow ring (it hugs the glyph edges, so a
    -- coarse grid can step straight over it).
    local function denseCount(app2: fixture.App, check: function({number}): boolean): integer
        local points: {{number}} = {}
        for dy = -18, 18, 3 do
            for dx = -18, 30, 3 do
                points[#points + 1] = {(TEXT_X + dx) / W, (TEXT_Y + dy) / H}
            end
        end
        local pixels = fixture.probePixels(app2, points)
        local count = 0
        for i = 1, #pixels do
            if check(pixels[i]) then count = count + 1 end
        end
        return count
    end

    it("a glow tints pixels around the glyphs", function()
        local before = denseCount(app, isGreenish)
        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            world:set(_G.tecsFxText, gfx.TextEffects.new({
                glow = {radius = 1.0, color = {0, 1, 0, 1}},
            }))
            return true
        ]])
        local glowing = fixture.eventually(fixture.callTimeout, function(): integer
            local count = denseCount(app, isGreenish)
            if count > before then return count end
            return nil
        end)
        luassert.is_number(glowing, "glow never tinted pixels around the text")
    end)

    it("an offset shadow paints beside the glyphs", function()
        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            world:set(_G.tecsFxText, gfx.TextEffects.new({
                shadow = {offset = {10, 10}, blur = 0, color = {1, 0, 0, 1}},
            }))
            return true
        ]])
        local shadowed = fixture.eventually(fixture.callTimeout, function(): integer
            local count = countAround(app, TEXT_X + 10, TEXT_Y + 10, 32, isRedish)
            if count > 0 then return count end
            return nil
        end)
        luassert.is_number(shadowed, "shadow never painted near the text")
    end)

    it("removing TextEffects returns to plain glyphs", function()
        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            world:remove(_G.tecsFxText, gfx.TextEffects)
            return true
        ]])
        local plain = fixture.eventually(fixture.callTimeout, function(): boolean
            if countAround(app, TEXT_X + 10, TEXT_Y + 10, 32, isRedish) == 0 then
                return true
            end
            return nil
        end)
        luassert.is_true(plain == true, "effects lingered after removing TextEffects")
        luassert.is_true(countAround(app, TEXT_X, TEXT_Y, 24, isWhiteish) > 0,
            "plain text vanished after removing TextEffects")
    end)
end)
