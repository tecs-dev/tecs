local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local data = tecs.data
local transcode = data.transcode

describe("tecs.data.transcode", function()
    it("round-trips UTF-16LE without losing embedded NULs", function()
        local text = "A\0\195\169\240\157\132\158"
        local utf16 = transcode(text, "UTF-8", "UTF-16LE")

        assert.are.equal("A\0\0\0\233\0\052\216\030\221", utf16)
        assert.are.equal(text, transcode(utf16, "UTF-16LE", "UTF-8"))
    end)

    it("round-trips UTF-32BE as binary output", function()
        local text = "A\0\240\157\132\158"
        local utf32 = transcode(text, "UTF-8", "UTF-32BE")

        assert.are.equal("\0\0\0A\0\0\0\0\0\1\209\30", utf32)
        assert.are.equal(text, transcode(utf32, "UTF-32BE", "UTF-8"))
    end)

    it("converts output larger than the internal chunk", function()
        local text = string.rep("\195\169\0", 3000)
        local utf16 = transcode(text, "UTF-8", "UTF-16LE")

        assert.are.equal(12000, #utf16)
        assert.are.equal(text, transcode(utf16, "UTF-16LE", "UTF-8"))
    end)

    it("writes into a reusable buffer without intermediate output strings", function()
        local destination = tecs.io.newBuffer("discarded")
        local text = string.rep("\195\169\0", 3000)

        assert.are.equal(12000, data.transcodeInto(text, "UTF-8", "UTF-16LE", destination))
        local capacity = destination:capacity()
        assert.are.equal(text, transcode(destination:getString(), "UTF-16LE", "UTF-8"))

        assert.are.equal(2, data.transcodeInto("A", "UTF-8", "UTF-16LE", destination))
        assert.are.equal("A\0", destination:getString())
        assert.are.equal(capacity, destination:capacity())
        destination:close()
    end)

    it("leaves the destination empty when conversion fails", function()
        local destination = tecs.io.newBuffer("old bytes")
        assert.has_error(function()
            data.transcodeInto("\195(", "UTF-8", "UTF-16LE", destination)
        end)
        assert.are.equal(0, destination:length())
        destination:close()
    end)

    it("accepts empty input while still validating the encodings", function()
        assert.are.equal("", transcode("", "UTF-8", "UTF-16LE"))
        assert.has_error(function()
            transcode("", "TECS-NOT-AN-ENCODING", "UTF-8")
        end)
    end)

    it("rejects invalid and incomplete source sequences", function()
        assert.has_error(function()
            transcode("\195(", "UTF-8", "UTF-16LE")
        end, "tecs.data.transcode: invalid UTF-8 input at byte 1")

        assert.has_error(function()
            transcode("\226\130", "UTF-8", "UTF-16LE")
        end, "tecs.data.transcode: incomplete UTF-8 input at byte 1")

        assert.has_error(function()
            transcode("\0\216A\0", "UTF-16LE", "UTF-8")
        end, "tecs.data.transcode: invalid UTF-16LE input at byte 1")
    end)

    it("rejects unsupported and ambiguous encoding names", function()
        assert.has_error(function()
            transcode("text", "UTF-8", "TECS-NOT-AN-ENCODING")
        end)
        assert.has_error(function()
            transcode("text", "", "UTF-8")
        end, "tecs.data.transcode: fromEncoding must not be empty")
        assert.has_error(function()
            transcode("text", "UTF-8", "UTF-8\0UTF-16")
        end, "tecs.data.transcode: toEncoding must not contain NUL bytes")
    end)
end)
