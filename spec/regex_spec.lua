-- Compiled Rust regular expressions through the LuaJIT FFI boundary.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")

describe("tecs.regex", function()
    it("compiles once and tests many subjects", function()
        local words = tecs.regex.compile([[\b[a-z]+\b]])

        assert.is_true(words:isMatch("one 2"))
        assert.is_true(words:isMatch("two 3"))
        assert.is_false(words:isMatch("123"))
        assert.are.equal([[\b[a-z]+\b]], words.pattern)
    end)

    it("reports parser failures at compilation", function()
        assert.has_error(function()
            tecs.regex.compile("(")
        end)
    end)

    it("finds with Lua byte positions and init rules", function()
        local digits = tecs.regex.compile([[\d+]])

        assert.same({ value = "12", first = 3, last = 4, index = 0 }, digits:find("ab12cd34"))
        assert.same({ value = "34", first = 7, last = 8, index = 0 }, digits:find("ab12cd34", 5))
        assert.same({ value = "34", first = 7, last = 8, index = 0 }, digits:find("ab12cd34", -2))
        assert.is_nil(digits:find("ab12cd34", 9))
        assert.is_nil(digits:find("ab12cd34", 10))
    end)

    it("represents empty matches like Lua string.find", function()
        local boundary = tecs.regex.compile("^")
        assert.same({ value = "", first = 1, last = 0, index = 0 }, boundary:find("abc"))
    end)

    it("returns numbered and named captures without inventing empty values", function()
        local pair = tecs.regex.compile([[(?<key>[a-z]+)=(\d+)(?:,([a-z]+))?]])
        local found = assert(pair:captures("hp=100"))

        assert.same({ value = "hp=100", first = 1, last = 6, index = 0 }, found.whole)
        assert.are.equal(3, found.groupCount)
        assert.same({ value = "hp", first = 1, last = 2, index = 1, name = "key" }, found.groups[1])
        assert.same({ value = "100", first = 4, last = 6, index = 2 }, found.groups[2])
        assert.is_nil(found.groups[3])
        assert.is_true(rawequal(found.groups[1], found.named.key))
    end)

    it("matches arbitrary subject bytes", function()
        local byte = tecs.regex.compile([[(?-u:\xFF)]])
        local found = assert(byte:find("a" .. string.char(0xFF) .. "b"))

        assert.are.equal(string.char(0xFF), found.value)
        assert.are.equal(2, found.first)
        assert.are.equal(2, found.last)
    end)

    it("uses inline flags rather than a second options surface", function()
        local insensitive = tecs.regex.compile("(?i)^hello$")
        assert.is_true(insensitive:isMatch("HELLO"))
    end)

    it("replaces the first match", function()
        local digits = tecs.regex.compile([[\d+]])
        assert.are.equal("one # two 2", digits:replace("one 1 two 2", "#"))
    end)

    it("replaces every non-overlapping match", function()
        local digits = tecs.regex.compile([[\d+]])
        assert.are.equal("one # two #", digits:replaceAll("one 1 two 2", "#"))
    end)

    it("expands numbered and named capture references", function()
        local name = tecs.regex.compile([[(?<last>[A-Za-z]+),\s+([A-Za-z]+)]])
        assert.are.equal("Ada Lovelace; $$; $", name:replace("Lovelace, Ada; $", "$2 $last; $$$$"))
    end)

    it("expands an unknown or unmatched capture as empty", function()
        local optional = tecs.regex.compile([[(a)?b]])
        assert.are.equal("<><>", optional:replace("b", "<$1><$missing>"))
    end)

    it("returns an unchanged subject when nothing matches", function()
        local digits = tecs.regex.compile([[\d+]])
        assert.are.equal("nothing", digits:replace("nothing", "#"))
        assert.are.equal("nothing", digits:replaceAll("nothing", "#"))
    end)

    it("replaces arbitrary bytes with arbitrary bytes", function()
        local byte = tecs.regex.compile([[(?-u:\xFF)]])
        assert.are.equal("a" .. string.char(0) .. "b", byte:replace("a" .. string.char(0xFF) .. "b", string.char(0)))
    end)
end)
