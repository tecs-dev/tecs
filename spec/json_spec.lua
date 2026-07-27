-- JSON.
--
-- The library is vendored rather than written, so this does not test JSON. It
-- tests the two things about *this* library that will bite callers: an empty
-- table has no distinguishable encoding without a sentinel, and a value it
-- cannot encode raises rather than being skipped. Both matter wherever a
-- structure round-trips, which is the MCP protocol and Tiled maps.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local cjson = require("cjson")

describe("json", function()
    it("round-trips the shapes a protocol uses", function()
        local original = {
            id = 7,
            method = "cmd_query",
            params = { include = { "Transform", "Sprite" }, limit = 50 },
            ok = true,
        }
        local decoded = cjson.decode(cjson.encode(original))

        assert.are.equal(7, decoded.id)
        assert.are.equal("cmd_query", decoded.method)
        assert.are.same({ "Transform", "Sprite" }, decoded.params.include)
        assert.is_true(decoded.ok)
    end)

    it("cannot tell an empty array from an empty object", function()
        -- The trap. An empty table encodes as an object, so a field that is
        -- sometimes a list comes back the wrong shape when it happens to be
        -- empty, and a client parsing it strictly will reject it.
        assert.are.equal("{}", cjson.encode({}))
        assert.are.equal("[]", cjson.encode(cjson.empty_array))

        -- Which means a result carrying a possibly-empty list has to say so.
        local function results(rows)
            return cjson.encode({ rows = #rows > 0 and rows or cjson.empty_array })
        end
        assert.are.equal('{"rows":[]}', results({}))
        assert.are.equal('{"rows":[1,2]}', results({ 1, 2 }))
    end)

    it("raises on a value it cannot represent", function()
        -- Not silently dropped, which is what makes it safe to hand arbitrary
        -- component data to: a cdata field fails loudly rather than vanishing
        -- from the payload.
        assert.has_error(function()
            cjson.encode({ f = print })
        end)
        assert.has_error(function()
            cjson.encode({ c = require("ffi").new("int[1]") })
        end)
    end)

    it("rejects malformed input rather than guessing", function()
        assert.has_error(function()
            cjson.decode("{")
        end)
        assert.has_error(function()
            cjson.decode("")
        end)
        assert.has_error(function()
            cjson.decode("{'single':1}")
        end)
    end)

    it("bounds nesting depth", function()
        -- A protocol server decodes whatever arrives, so unbounded recursion
        -- on a hostile payload would be a denial of service.
        local deep = string.rep("[", 2000) .. string.rep("]", 2000)
        assert.has_error(function()
            cjson.decode(deep)
        end)
    end)

    it("keeps integers exact through a round trip", function()
        -- Entity ids are integers and must not come back as 1.0 or drift.
        local ids = { 1, 4194303, 2147483647 }
        local decoded = cjson.decode(cjson.encode(ids))
        for index, id in ipairs(ids) do
            assert.are.equal(id, decoded[index])
            assert.are.equal(id, math.floor(decoded[index]))
        end
    end)
end)
