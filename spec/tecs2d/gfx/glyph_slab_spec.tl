require("busted")

local luassert <const> = require("luassert")
local glyphslab <const> = require("tecs2d.gfx.internal.text.glyphslab")
local bmfontMod <const> = require("tecs2d.gfx.bmfont")

--- Build a minimal font table with one 8x8 glyph per given codepoint.
--- Distinct objects/atlases per font, but deliberately identical face/page
--- names (msdf-bmfont tools emit generic names).
local function makeFont(codepoints: {integer}, xadvance: number): bmfontMod.BMFont
    local chars: {integer: bmfontMod.BMFontChar} = {}
    for i, cp in ipairs(codepoints) do
        chars[cp] = {
            id = cp, x = (i - 1) * 8, y = 0, width = 8, height = 8,
            xoffset = 0, yoffset = 0, xadvance = xadvance, page = 0,
        }
    end
    local font: {string: any} = {
        type = "bitmap",
        face = "atlas",
        page = "atlas.png",
        size = 8,
        lineHeight = 10,
        base = 8,
        scaleW = 64,
        scaleH = 64,
        chars = chars,
        kernings = {},
        atlas = {},  -- identity used by getFontId; a table stands in for the Image
        getChar = function(self: {string: any}, cp: integer): bmfontMod.BMFontChar
            return (self.chars as {integer: bmfontMod.BMFontChar})[cp]
        end,
        getKerning = function(_self: {string: any}, _l: integer, _r: integer): number
            return 0
        end,
    }
    return font as bmfontMod.BMFont
end

describe("glyph slab registry", function()
    it("dedups identical (font, text, scale) requests", function()
        local slab = glyphslab.new(256)
        local font = makeFont({65}, 9)
        local a = slab:acquire(font, "A", 1, 1)
        local b = slab:acquire(font, "A", 1, 1)
        luassert.are.equal(a, b)
        luassert.are.equal(2, a.refCount)
        slab:release(b)
        luassert.are.equal(1, a.refCount)
        slab:release(a)
    end)

    it("does not share layouts between fonts with identical face and page names", function()
        local slab = glyphslab.new(256)
        local fontA = makeFont({65}, 9)
        local fontB = makeFont({65}, 20)  -- same face/page, different metrics
        local a = slab:acquire(fontA, "A", 1, 1)
        local b = slab:acquire(fontB, "A", 1, 1)
        luassert.is_true(a ~= b,
            "fonts with identical face/page names shared one layout")
        slab:release(a)
        slab:release(b)
    end)

    it("released entries can be re-acquired after churn", function()
        local slab = glyphslab.new(256)
        local font = makeFont({65, 66}, 9)
        for _ = 1, 20 do
            local e = slab:acquire(font, "AB", 1, 1)
            luassert.are.equal(2, e.count)
            slab:release(e)
        end
        local _, _, registryCount = slab:getStats()
        luassert.are.equal(0, registryCount, "registry leaked entries across churn")
    end)

    it("lays out UTF-8 text by codepoint", function()
        local slab = glyphslab.new(256)
        -- U+00E9 as the only glyph; the two UTF-8 bytes must decode to it.
        local font = makeFont({233}, 9)
        local e = slab:acquire(font, "\195\169\195\169", 1, 1)
        luassert.are.equal(2, e.count, "expected 2 decoded glyphs from 4 bytes")
        slab:release(e)
    end)
end)
