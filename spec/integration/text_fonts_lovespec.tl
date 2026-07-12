--- Love2D integration suite: text rendering with runtime-built bitmap
--- fonts. Each glyph is a solid color block so pixel probes identify
--- exactly which glyph rendered:
---   - non-ASCII text must decode UTF-8 (codepoint lookup, not bytes)
---   - fonts with different atlas sizes must coexist (per-layer UV
---     scaling into the max-sized atlas array)
---
--- Run via `make test-love FILE_MATCH='text_fonts'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/compliance"

local function classify(p: {number}): string
    if p[1] > 0.7 and p[2] < 0.3 and p[3] < 0.3 then return "red" end
    if p[2] > 0.7 and p[1] < 0.3 and p[3] < 0.3 then return "green" end
    if p[3] > 0.7 and p[1] < 0.3 and p[2] < 0.3 then return "blue" end
    return "none"
end

local function expectGlyph(app: fixture.App, fx: number, fy: number, color: string, what: string)
    local seen: string = nil
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        seen = classify(fixture.probePixels(app, {{fx, fy}})[1])
        if seen == color then return true end
        return nil
    end)
    luassert.is_true(ok == true,
        what .. ": expected " .. color .. " glyph, got " .. tostring(seen))
end

describe("text fonts: UTF-8 and multi-font atlases", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        -- Build two bitmap fonts on disk. Font A (32x32 atlas): 'A' is a
        -- red 8x8 block, U+00E9 'é' a blue one. Font B (64x64 atlas):
        -- 'B' is a green 16x16 block.
        fixture.runLua(app, [[
            local function solid(d, x0, y0, w, h, r, g, b)
                for y = y0, y0 + h - 1 do
                    for x = x0, x0 + w - 1 do
                        d:setPixel(x, y, r, g, b, 1)
                    end
                end
            end

            local atlasA = love.image.newImageData(32, 32)
            solid(atlasA, 0, 0, 8, 8, 1, 0, 0)
            solid(atlasA, 8, 0, 8, 8, 0, 0, 1)
            love.filesystem.write("testfontA.png", atlasA:encode("png"))
            love.filesystem.write("testfontA.fnt", table.concat({
                'info face="TestA" size=8',
                'common lineHeight=10 base=8 scaleW=32 scaleH=32 pages=1',
                'page id=0 file="testfontA.png"',
                'chars count=2',
                'char id=65 x=0 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=9 page=0 chnl=15',
                'char id=233 x=8 y=0 width=8 height=8 xoffset=0 yoffset=0 xadvance=9 page=0 chnl=15',
            }, "\n"))

            local atlasB = love.image.newImageData(64, 64)
            solid(atlasB, 0, 0, 16, 16, 0, 1, 0)
            love.filesystem.write("testfontB.png", atlasB:encode("png"))
            love.filesystem.write("testfontB.fnt", table.concat({
                'info face="TestB" size=16',
                'common lineHeight=18 base=14 scaleW=64 scaleH=64 pages=1',
                'page id=0 file="testfontB.png"',
                'chars count=1',
                'char id=66 x=0 y=0 width=16 height=16 xoffset=0 yoffset=0 xadvance=17 page=0 chnl=15',
            }, "\n"))
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("renders ASCII glyphs from font A", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(Transform(60, 60, 0, 1), gfx.Text("testfontA.fnt", "A", 4, 4))
            return true
        ]])
        expectGlyph(app, 60 / 320, 60 / 240, "red", "font A 'A'")
    end)

    it("renders non-ASCII glyphs (UTF-8 decode)", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(Transform(60, 180, 0, 1), gfx.Text("testfontA.fnt", "\195\169", 4, 4))
            return true
        ]])
        expectGlyph(app, 60 / 320, 180 / 240, "blue", "font A U+00E9")
    end)

    it("keeps both fonts correct when atlases differ in size", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(Transform(240, 60, 0, 1), gfx.Text("testfontB.fnt", "B", 4, 4))
            return true
        ]])
        -- Font B (the larger atlas) renders...
        expectGlyph(app, 240 / 320, 60 / 240, "green", "font B 'B'")
        -- ...and font A's glyphs must survive the atlas array growing to
        -- font B's size (per-layer UV scaling).
        expectGlyph(app, 60 / 320, 60 / 240, "red", "font A 'A' after array rebuild")
        expectGlyph(app, 60 / 320, 180 / 240, "blue", "font A U+00E9 after array rebuild")
    end)
end)
