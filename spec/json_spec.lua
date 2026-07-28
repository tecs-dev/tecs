-- JSON.
--
-- The library is vendored rather than written, so this does not test JSON. It
-- tests the three things about *this* module that will bite callers: it is the
-- cjson table rather than a wrapper, so its sentinels are the identity a
-- caller compares against; an empty table has no distinguishable encoding
-- without one of those sentinels; and a value it cannot encode raises rather
-- than being skipped. All of it matters wherever a structure round-trips,
-- which is the MCP protocol and Tiled maps.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local json = require("tecs.json")
local cjson = require("cjson")

describe("json", function()
    it("is the cjson table rather than a wrapper around it", function()
        -- The typing describes the library; it does not stand in front of it.
        -- Anything holding one spelling is holding the other.
        assert.are.equal(cjson, json)
        assert.are.equal(cjson.encode, json.encode)
        assert.are.equal(cjson.decode, json.decode)
    end)

    it("round-trips the shapes a protocol uses", function()
        local original = {
            id = 7,
            method = "cmd_query",
            params = { include = { "Transform", "Sprite" }, limit = 50 },
            ok = true,
        }
        local decoded = json.decode(json.encode(original))

        assert.are.equal(7, decoded.id)
        assert.are.equal("cmd_query", decoded.method)
        assert.are.same({ "Transform", "Sprite" }, decoded.params.include)
        assert.is_true(decoded.ok)
    end)

    it("cannot tell an empty array from an empty object", function()
        -- The trap. An empty table encodes as an object, so a field that is
        -- sometimes a list comes back the wrong shape when it happens to be
        -- empty, and a client parsing it strictly will reject it.
        assert.are.equal("{}", json.encode({}))
        assert.are.equal("[]", json.encode(json.empty_array))

        -- Which means a result carrying a possibly-empty list has to say so.
        local function results(rows)
            return json.encode({ rows = #rows > 0 and rows or json.empty_array })
        end
        assert.are.equal('{"rows":[]}', results({}))
        assert.are.equal('{"rows":[1,2]}', results({ 1, 2 }))
    end)

    it("hands back the sentinels a caller compares against", function()
        -- A sentinel is tested by identity, so the one this module documents
        -- has to be the one the decoder produces and the one every other
        -- spelling of the module reaches. Two nulls would be a bug factory.
        assert.are.equal(cjson.null, json.null)
        assert.are.equal(cjson.empty_array, json.empty_array)

        local decoded = json.decode('{"name":null}')
        assert.are.equal(json.null, decoded.name)

        -- And a null key is present, which is the whole reason it is not nil:
        -- absent and null are different answers.
        assert.is_not_nil(decoded.name)
        assert.is_nil(decoded.missing)

        -- Encoding it writes null back rather than dropping the field.
        assert.are.equal('{"name":null}', json.encode({ name = json.null }))
    end)

    it("raises on a value it cannot represent", function()
        -- Not silently dropped, which is what makes it safe to hand arbitrary
        -- component data to: a cdata field fails loudly rather than vanishing
        -- from the payload.
        assert.has_error(function()
            json.encode({ f = print })
        end)
        assert.has_error(function()
            json.encode({ c = require("ffi").new("int[1]") })
        end)
    end)

    it("rejects malformed input rather than guessing", function()
        assert.has_error(function()
            json.decode("{")
        end)
        assert.has_error(function()
            json.decode("")
        end)
        assert.has_error(function()
            json.decode("{'single':1}")
        end)
    end)

    it("bounds nesting depth", function()
        -- A protocol server decodes whatever arrives, so unbounded recursion
        -- on a hostile payload would be a denial of service.
        local deep = string.rep("[", 2000) .. string.rep("]", 2000)
        assert.has_error(function()
            json.decode(deep)
        end)
    end)

    it("keeps integers exact through a round trip", function()
        -- Entity ids are integers and must not come back as 1.0 or drift.
        local ids = { 1, 4194303, 2147483647 }
        local decoded = json.decode(json.encode(ids))
        for index, id in ipairs(ids) do
            assert.are.equal(id, decoded[index])
            assert.are.equal(id, math.floor(decoded[index]))
        end
    end)
end)
