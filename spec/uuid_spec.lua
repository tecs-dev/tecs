-- RFC 9562 UUID generation.
--
-- These assertions hold the native generator to the public text contract:
-- canonical lowercase form, the requested version and RFC variant, uniqueness
-- for random values, and ordering for values meant to sort by creation.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local data = require("tecs.data")

local function assertUUID(value, version)
    local first, second, third, fourth, fifth = value:match("^(%x+)%-(%x+)%-(%x+)%-(%x+)%-(%x+)$")
    assert.are.equal(36, #value)
    assert.are.equal(value:lower(), value)
    assert.are.equal(8, #first)
    assert.are.equal(4, #second)
    assert.are.equal(4, #third)
    assert.are.equal(4, #fourth)
    assert.are.equal(12, #fifth)
    assert.are.equal(version, value:sub(15, 15))
    assert.is_not_nil(value:sub(20, 20):match("[89ab]"))
end

describe("data.uuid4", function()
    it("generates canonical random UUIDs", function()
        local seen = {}
        for _ = 1, 128 do
            local value = data.uuid4()
            assertUUID(value, "4")
            assert.is_nil(seen[value])
            seen[value] = true
        end
    end)
end)

describe("data.uuid7", function()
    it("generates canonical UUIDs in creation order", function()
        local previous = data.uuid7()
        assertUUID(previous, "7")

        for _ = 1, 128 do
            local value = data.uuid7()
            assertUUID(value, "7")
            assert.is_true(previous < value)
            previous = value
        end
    end)
end)
