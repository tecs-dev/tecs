-- `tecs.data`, and mostly the JSON half of it.
--
-- The library is vendored rather than written, so this does not test JSON. It
-- tests the three things about *this* module that will bite callers: its
-- functions and sentinels are lua-cjson's own values, so a caller comparing a
-- sentinel by identity compares against the right one; an empty table has no
-- distinguishable encoding without one of those sentinels; and a value it
-- cannot encode raises rather than being skipped. All of it matters wherever a
-- structure round-trips, which is the MCP protocol and sprite sheet metadata.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local data = tecs.data
local cjson = require("cjson")

describe("tecs.data", function()
    it("carries lua-cjson's own functions rather than wrapping them", function()
        -- The names are qualified because `tecs.data` also compresses and
        -- hashes; nothing stands between a caller and the library.
        assert.are.equal(cjson.encode, data.encodeJSON)
        assert.are.equal(cjson.decode, data.decodeJSON)
    end)

    it("carries byte transforms beside the JSON one", function()
        -- A save can be encoded, compressed and stamped in one place.
        assert.are.equal("function", type(data.deflate))
        assert.are.equal("function", type(data.inflate))
        assert.are.equal("function", type(data.deflateRaw))
        assert.are.equal("function", type(data.inflateRaw))
        assert.are.equal("function", type(data.fnv1a64))
        assert.are.equal("function", type(data.sha256))
        assert.are.equal("function", type(data.crc32))
        assert.are.equal("function", type(data.adler32))
        assert.are.equal("function", type(data.hexEncode))
        assert.are.equal("function", type(data.hexDecode))
        assert.are.equal("function", type(data.base64Encode))
        assert.are.equal("function", type(data.base64Decode))
        assert.are.equal("function", type(data.transcode))
        assert.are.equal("function", type(data.uuid4))
        assert.are.equal("function", type(data.uuid7))
    end)

    it("round-trips arbitrary bytes through hexadecimal", function()
        local bytes = "\0Tecs\255\n"
        assert.are.equal("0054656373ff0a", data.hexEncode(bytes))
        assert.are.equal(bytes, data.hexDecode("0054656373FF0a"))
    end)

    it("rejects malformed hexadecimal text", function()
        assert.has_error(function()
            data.hexDecode("0")
        end)
        assert.has_error(function()
            data.hexDecode("zz")
        end)
    end)

    it("round-trips arbitrary bytes through canonical Base64", function()
        assert.are.equal("", data.base64Encode(""))
        assert.are.equal("Zg==", data.base64Encode("f"))
        assert.are.equal("Zm8=", data.base64Encode("fo"))
        assert.are.equal("Zm9v", data.base64Encode("foo"))
        assert.are.equal("/wA=", data.base64Encode("\255\0"))
        assert.are.equal("\255\0", data.base64Decode("/wA="))
    end)

    it("consumes retained byte views without crossing through strings", function()
        local source = tecs.io.newBuffer("before:payload:after")
        local view = source:view(7, 7)
        view.getString = function()
            error("a byte transform copied its input")
        end

        source:setString("changed", 7)
        source:release()

        assert.are.equal("7061796c6f6164", data.hexEncode(view))
        assert.are.equal("cGF5bG9hZA==", data.base64Encode(view))
        assert.are.equal(data.fnv1a64("payload"), data.fnv1a64(view))
        assert.are.equal(data.sha256("payload"), data.sha256(view))
        assert.are.equal(data.adler32("payload"), data.adler32(view))
        assert.are.equal(data.crc32("payload"), data.crc32(view))
        assert.are.equal("payload", data.transcode(view, "UTF-8", "UTF-8"))

        local hex = tecs.io.newBuffer("7061796c6f6164")
        local base64 = tecs.io.newBuffer("cGF5bG9hZA==")
        local hexView = hex:view()
        local base64View = base64:view()
        hex:release()
        base64:release()
        assert.are.equal("payload", data.hexDecode(hexView))
        assert.are.equal("payload", data.base64Decode(base64View))

        hexView:release()
        base64View:release()
        view:release()
    end)

    it("rejects non-canonical or malformed Base64 text", function()
        for _, text in ipairs({ "Zg", "Zg=", "=g==", "Zg=A", "Zh==", "Zm9=" }) do
            assert.has_error(function()
                data.base64Decode(text)
            end)
        end
    end)

    it("answers an independent settings table from newJSON", function()
        local copy = data.newJSON()
        assert.are_not.equal(data, copy)

        -- Its own encoder, so a setting changed here changes nothing for
        -- anybody else. That is the whole reason the copy exists.
        local previous = copy.encode_number_precision(3)
        assert.are.equal(3, copy.encode_number_precision())
        assert.are_not.equal(3, data.encode_number_precision())
        copy.encode_number_precision(previous)

        -- The sentinels are shared, since identity is the whole point of them.
        assert.are.equal(data.null, copy.null)
        assert.are.equal(data.empty_array, copy.empty_array)
        assert.are.equal("cjson", copy._NAME)
    end)

    it("round-trips the shapes a protocol uses", function()
        local original = {
            id = 7,
            method = "cmd_query",
            params = { include = { "Transform", "Sprite" }, limit = 50 },
            ok = true,
        }
        local decoded = data.decodeJSON(data.encodeJSON(original))

        assert.are.equal(7, decoded.id)
        assert.are.equal("cmd_query", decoded.method)
        assert.are.same({ "Transform", "Sprite" }, decoded.params.include)
        assert.is_true(decoded.ok)
    end)

    it("cannot tell an empty array from an empty object", function()
        -- The trap. An empty table encodes as an object, so a field that is
        -- sometimes a list comes back the wrong shape when it happens to be
        -- empty, and a client parsing it strictly will reject it.
        assert.are.equal("{}", data.encodeJSON({}))
        assert.are.equal("[]", data.encodeJSON(data.empty_array))

        -- Which means a result carrying a possibly-empty list has to say so.
        local function results(rows)
            return data.encodeJSON({ rows = #rows > 0 and rows or data.empty_array })
        end
        assert.are.equal('{"rows":[]}', results({}))
        assert.are.equal('{"rows":[1,2]}', results({ 1, 2 }))
    end)

    it("hands back the sentinels a caller compares against", function()
        -- A sentinel is tested by identity, so the one this module documents
        -- has to be the one the decoder produces and the one every other
        -- spelling of the module reaches. Two nulls would be a bug factory.
        assert.are.equal(cjson.null, data.null)
        assert.are.equal(cjson.empty_array, data.empty_array)

        local decoded = data.decodeJSON('{"name":null}')
        assert.are.equal(data.null, decoded.name)

        -- And a null key is present, which is the whole reason it is not nil:
        -- absent and null are different answers.
        assert.is_not_nil(decoded.name)
        assert.is_nil(decoded.missing)

        -- Encoding it writes null back rather than dropping the field.
        assert.are.equal('{"name":null}', data.encodeJSON({ name = data.null }))
    end)

    it("raises on a value it cannot represent", function()
        -- Not silently dropped, which is what makes it safe to hand arbitrary
        -- component data to: a cdata field fails loudly rather than vanishing
        -- from the payload.
        assert.has_error(function()
            data.encodeJSON({ f = print })
        end)
        assert.has_error(function()
            data.encodeJSON({ c = require("ffi").new("int[1]") })
        end)
    end)

    it("rejects malformed input rather than guessing", function()
        assert.has_error(function()
            data.decodeJSON("{")
        end)
        assert.has_error(function()
            data.decodeJSON("")
        end)
        assert.has_error(function()
            data.decodeJSON("{'single':1}")
        end)
    end)

    it("bounds nesting depth", function()
        -- A protocol server decodes whatever arrives, so unbounded recursion
        -- on a hostile payload would be a denial of service.
        local deep = string.rep("[", 2000) .. string.rep("]", 2000)
        assert.has_error(function()
            data.decodeJSON(deep)
        end)
    end)

    it("keeps integers exact through a round trip", function()
        -- Entity ids are integers and must not come back as 1.0 or drift.
        local ids = { 1, 4194303, 2147483647 }
        local decoded = data.decodeJSON(data.encodeJSON(ids))
        for index, id in ipairs(ids) do
            assert.are.equal(id, decoded[index])
            assert.are.equal(id, math.floor(decoded[index]))
        end
    end)
end)
