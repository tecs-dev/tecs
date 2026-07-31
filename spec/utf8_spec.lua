-- UTF-8 codepoint operations.
--
-- These examples hold the Lua-facing cursor contract separately from SDL's C
-- pointer interface: offsets are one-based, the end cursor is #text + 1, NUL
-- is data, and malformed input is traversable one byte at a time.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local utf8 = require("tecs").data.utf8
local REPLACEMENT = 0xfffd

describe("tecs.data.utf8", function()
    it("decodes ASCII and every UTF-8 width with one-based cursors", function()
        local text = "A\194\162\226\130\172\240\144\141\136"
        assert.are.equal(10, #text)
        assert.are.equal(4, utf8.length(text))

        local codepoint, offset = utf8.decodeAt(text, 1)
        assert.are.equal(0x41, codepoint)
        assert.are.equal(2, offset)

        codepoint, offset = utf8.decodeAt(text, offset)
        assert.are.equal(0xa2, codepoint)
        assert.are.equal(4, offset)

        codepoint, offset = utf8.decodeAt(text, offset)
        assert.are.equal(0x20ac, codepoint)
        assert.are.equal(7, offset)

        codepoint, offset = utf8.decodeAt(text, offset)
        assert.are.equal(0x10348, codepoint)
        assert.are.equal(11, offset)

        codepoint, offset = utf8.decodeAt(text, offset)
        assert.is_nil(codepoint)
        assert.are.equal(11, offset)
    end)

    it("decodes the same codepoints backward", function()
        local text = "A\194\162\226\130\172\240\144\141\136"
        local codepoint, offset = utf8.decodeBefore(text, #text + 1)
        assert.are.equal(0x10348, codepoint)
        assert.are.equal(7, offset)

        codepoint, offset = utf8.decodeBefore(text, offset)
        assert.are.equal(0x20ac, codepoint)
        assert.are.equal(4, offset)

        codepoint, offset = utf8.decodeBefore(text, offset)
        assert.are.equal(0xa2, codepoint)
        assert.are.equal(2, offset)

        codepoint, offset = utf8.decodeBefore(text, offset)
        assert.are.equal(0x41, codepoint)
        assert.are.equal(1, offset)

        codepoint, offset = utf8.decodeBefore(text, offset)
        assert.is_nil(codepoint)
        assert.are.equal(1, offset)
    end)

    it("keeps embedded NUL as U+0000", function()
        local text = "A\0\226\130\172"
        assert.are.equal(3, utf8.length(text))
        assert.is_true(utf8.isValid(text))

        local codepoint, offset = utf8.decodeAt(text, 2)
        assert.are.equal(0, codepoint)
        assert.are.equal(3, offset)

        codepoint, offset = utf8.decodeAt(text, offset)
        assert.are.equal(0x20ac, codepoint)
        assert.are.equal(#text + 1, offset)

        codepoint, offset = utf8.decodeBefore(text, 3)
        assert.are.equal(0, codepoint)
        assert.are.equal(2, offset)
        assert.are.equal("\0", utf8.encode(0))
    end)

    it("replaces malformed input one byte at a time", function()
        local malformed = {
            "\128", -- stray continuation
            "\192\175", -- overlong slash
            "\237\160\128", -- UTF-16 surrogate
            "\226\130", -- truncated three-byte sequence
            "\244\144\128\128", -- above U+10FFFF
        }

        for _, text in ipairs(malformed) do
            assert.is_false(utf8.isValid(text))
            assert.are.equal(#text, utf8.length(text))
            local offset = 1
            while offset <= #text do
                local codepoint, nextOffset = utf8.decodeAt(text, offset)
                assert.are.equal(REPLACEMENT, codepoint)
                assert.are.equal(offset + 1, nextOffset)
                offset = nextOffset
            end

            offset = #text + 1
            while offset > 1 do
                local codepoint, startOffset = utf8.decodeBefore(text, offset)
                assert.are.equal(REPLACEMENT, codepoint)
                assert.are.equal(offset - 1, startOffset)
                offset = startOffset
            end
        end
    end)

    it("distinguishes an encoded U+FFFD from malformed input", function()
        local encoded = "\239\191\189"
        assert.is_true(utf8.isValid(encoded))
        assert.are.equal(1, utf8.length(encoded))

        local codepoint, offset = utf8.decodeAt(encoded, 1)
        assert.are.equal(REPLACEMENT, codepoint)
        assert.are.equal(4, offset)

        codepoint, offset = utf8.decodeBefore(encoded, 4)
        assert.are.equal(REPLACEMENT, codepoint)
        assert.are.equal(1, offset)
    end)

    it("follows backward resynchronization over invalid bytes", function()
        local text = "A\226\130\172\128\0"
        local codepoint, offset = utf8.decodeBefore(text, #text + 1)
        assert.are.equal(0, codepoint)
        assert.are.equal(6, offset)

        codepoint, offset = utf8.decodeBefore(text, offset)
        assert.are.equal(REPLACEMENT, codepoint)
        assert.are.equal(5, offset)

        codepoint, offset = utf8.decodeBefore(text, offset)
        assert.are.equal(0x20ac, codepoint)
        assert.are.equal(2, offset)

        -- Cursor 4 lies inside the euro encoding. SDL backs up to its leading
        -- byte but sees only two of the required three bytes before the cursor;
        -- the wrapper then recovers the final malformed byte on its own.
        codepoint, offset = utf8.decodeBefore(text, 4)
        assert.are.equal(REPLACEMENT, codepoint)
        assert.are.equal(3, offset)
    end)

    it("encodes every width and the Unicode boundary", function()
        assert.are.equal("A", utf8.encode(0x41))
        assert.are.equal("\194\162", utf8.encode(0xa2))
        assert.are.equal("\226\130\172", utf8.encode(0x20ac))
        assert.are.equal("\240\144\141\136", utf8.encode(0x10348))
        assert.are.equal("\244\143\191\191", utf8.encode(0x10ffff))
        assert.are.equal("\239\191\189", utf8.encode(REPLACEMENT))
    end)

    it("validates canonical UTF-8 without counting grapheme clusters", function()
        assert.is_true(utf8.isValid(""))
        assert.is_true(utf8.isValid("plain ASCII"))
        assert.is_true(utf8.isValid("e\204\129"))
        assert.are.equal(2, utf8.length("e\204\129"))
    end)

    it("truncates only at complete decoding units", function()
        local text = "A\226\130\172B"
        assert.are.equal("", utf8.truncate(text, 0))
        assert.are.equal("A", utf8.truncate(text, 1))
        assert.are.equal("A", utf8.truncate(text, 2))
        assert.are.equal("A", utf8.truncate(text, 3))
        assert.are.equal("A\226\130\172", utf8.truncate(text, 4))
        assert.are.equal(text, utf8.truncate(text, 5))
        assert.are.equal(text, utf8.truncate(text, 100))
    end)

    it("preserves complete NUL and malformed byte units when truncating", function()
        local text = "\0\128A"
        assert.are.equal("\0", utf8.truncate(text, 1))
        assert.are.equal("\0\128", utf8.truncate(text, 2))
        assert.are.equal(text, utf8.truncate(text, 3))

        local truncated = "\226\130"
        assert.are.equal("\226", utf8.truncate(truncated, 1))
        assert.are.equal(truncated, utf8.truncate(truncated, 2))
    end)

    it("rejects offsets, byte ceilings, and non-scalar codepoints", function()
        assert.has_error(function()
            utf8.decodeAt("a", 0)
        end)
        assert.has_error(function()
            utf8.decodeAt("a", 3)
        end)
        assert.has_error(function()
            utf8.decodeAt("a", 1.5)
        end)
        assert.has_error(function()
            utf8.decodeAt("a", "1")
        end)
        assert.has_error(function()
            utf8.decodeBefore("a", 0)
        end)
        assert.has_error(function()
            utf8.decodeBefore("a", 3)
        end)

        assert.has_error(function()
            utf8.truncate("a", -1)
        end)
        assert.has_error(function()
            utf8.truncate("a", 0.5)
        end)
        assert.has_error(function()
            utf8.truncate("a", "1")
        end)

        assert.has_error(function()
            utf8.encode(-1)
        end)
        assert.has_error(function()
            utf8.encode(0x110000)
        end)
        assert.has_error(function()
            utf8.encode(0xd800)
        end)
        assert.has_error(function()
            utf8.encode(0xdfff)
        end)
        assert.has_error(function()
            utf8.encode(1.5)
        end)
        assert.has_error(function()
            utf8.encode("65")
        end)
    end)
end)
