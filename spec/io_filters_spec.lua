local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local ioModule = tecs.io

local function limitedReader(bytes, maximum)
    local source = ioModule.newStringReader(bytes)
    local reader = { closed = false }

    function reader:read(count)
        return source:read(math.min(count, maximum))
    end

    function reader:readInto(destination, count, offset)
        return source:readInto(destination, math.min(count, maximum), offset)
    end

    function reader:transferTo(destination)
        return source:transferTo(destination)
    end

    function reader:close()
        self.closed = true
        source:close()
    end

    return reader
end

local function readAll(reader, chunk)
    local pieces = {}
    while true do
        local piece = assert(reader:read(chunk))
        if piece == "" then
            break
        end
        pieces[#pieces + 1] = piece
    end
    return table.concat(pieces)
end

local function bufferWriter()
    local destination = ioModule.newBuffer()
    return destination, destination:newWriter()
end

local function transformedByWriter(constructor, pieces, ...)
    local result
    local arguments = { ... }
    tecs.scoped(function(scope)
        local destination = scope:own(ioModule.newBuffer())
        local writer = scope:own(constructor(destination:newWriter(), unpack(arguments)))

        for _, piece in ipairs(pieces) do
            assert(writer:write(piece))
        end
        assert(writer:close())

        result = destination:getString()
    end)
    return result
end

describe("io transform filters", function()
    it("hands retained memory directly to transform writers", function()
        local sourceBuffer = ioModule.newBuffer("payload")
        local sourceView = sourceBuffer:view()
        local reader = sourceView:newReader()
        sourceView:close()
        sourceBuffer:close()
        reader.readInto = function()
            error("the transfer copied its input through scratch")
        end
        local encoded, sink = bufferWriter()
        local writer = ioModule.newHexEncodeWriter(sink)

        local copied, reason = reader:transferTo(writer)

        assert.are.equal(7, copied, reason)
        assert(writer:close())
        assert.are.equal("7061796c6f6164", encoded:getString())

        reader:close()
        encoded:close()
    end)

    it("streams zlib compression and decompression", function()
        local expected = string.rep("blocks and literals \0 ", 10000)
        local compressed = transformedByWriter(
            ioModule.newDeflateWriter,
            { expected:sub(1, 7), expected:sub(8, 70000), expected:sub(70001) }
        )
        local source = limitedReader(compressed, 11)
        local reader = ioModule.newInflateReader(source)

        assert.are.equal(expected, readAll(reader, 13))

        reader:close()
        assert.is_true(source.closed)
    end)

    it("streams raw DEFLATE when both endpoints request it", function()
        local expected = string.rep("raw bytes", 1000)
        local compressed = transformedByWriter(ioModule.newDeflateWriter, { expected }, { raw = true })
        local source = limitedReader(compressed, 5)
        local reader = ioModule.newInflateReader(source, { raw = true })

        assert.are.equal(expected, readAll(reader, 17))

        reader:close()
    end)

    it("enforces the inflate reader output ceiling", function()
        local compressed = transformedByWriter(ioModule.newDeflateWriter, { string.rep("x", 1000) })
        local reader = ioModule.newInflateReader(limitedReader(compressed, 7), { maxBytes = 999 })

        local result, reason
        repeat
            result, reason = reader:read(2000)
        until result == nil or result == ""

        assert.is_nil(result)
        assert.matches("exceeds maxBytes", reason, 1, true)

        reader:close()
    end)

    it("encodes and decodes Base64 across quantum boundaries", function()
        local bytes = "A\0\255multibyte \195\169"
        local encoded =
            transformedByWriter(ioModule.newBase64EncodeWriter, { bytes:sub(1, 1), bytes:sub(2, 4), bytes:sub(5) })
        local source = limitedReader(encoded, 1)
        local reader = ioModule.newBase64DecodeReader(source)

        assert.are.equal(bytes, readAll(reader, 2))

        reader:close()
    end)

    it("reports an incomplete final Base64 quantum", function()
        local reader = ioModule.newBase64DecodeReader(limitedReader("YWJ", 1))

        local result, reason = reader:read(8)

        assert.is_nil(result)
        assert.matches("multiple of four", reason, 1, true)

        reader:close()
    end)

    it("rejects Base64 padding before the end of the source", function()
        local reader = ioModule.newBase64DecodeReader(limitedReader("YQ==Yg==", 8))

        local result, reason = reader:read(8)

        assert.is_nil(result)
        assert.matches("malformed padding", reason, 1, true)

        reader:close()
    end)

    it("encodes and decodes hexadecimal text across nibble boundaries", function()
        local bytes = "\0\1\254\255hex"
        local encoded = transformedByWriter(ioModule.newHexEncodeWriter, { bytes:sub(1, 2), bytes:sub(3) })
        local source = limitedReader(encoded, 3)
        local reader = ioModule.newHexDecodeReader(source)

        assert.are.equal("0001feff686578", encoded)
        assert.are.equal(bytes, readAll(reader, 1))

        reader:close()
    end)

    it("rejects an unmatched final hexadecimal nibble", function()
        local reader = ioModule.newHexDecodeReader(limitedReader("abc", 2))
        assert.are.equal("\171", assert(reader:read(1)))

        local result, reason = reader:read(1)

        assert.is_nil(result)
        assert.matches("whole byte pairs", reason, 1, true)

        reader:close()
    end)

    it("allows empty deflate writes and repeated synchronization flushes", function()
        local destination, sink = bufferWriter()
        local writer = ioModule.newDeflateWriter(sink)

        assert(writer:write(""))
        assert(writer:flush())
        assert(writer:flush())
        assert(writer:write("bytes"))
        assert(writer:close())

        local reader = ioModule.newInflateReader(limitedReader(destination:getString(), 3))
        assert.are.equal("bytes", readAll(reader, 2))

        reader:close()
        destination:close()
    end)

    it("streams transcoding through split multibyte characters", function()
        local utf8 = "A\195\169\240\157\132\158Z"
        local utf16 = transformedByWriter(
            ioModule.newTranscodeWriter,
            { utf8:sub(1, 2), utf8:sub(3, 4), utf8:sub(5, 7), utf8:sub(8) },
            "UTF-8",
            "UTF-16LE"
        )
        local source = limitedReader(utf16, 1)
        local reader = ioModule.newTranscodeReader(source, "UTF-16LE", "UTF-8")

        assert.are.equal(utf8, readAll(reader, 2))

        reader:close()
    end)

    it("rejects a truncated character when a transcode writer closes", function()
        local destination, sink = bufferWriter()
        local writer = ioModule.newTranscodeWriter(sink, "UTF-8", "UTF-16LE")
        assert(writer:write("\226\130"))

        local ok, reason = writer:close()

        assert.is_false(ok)
        assert.matches("incomplete UTF%-8", reason)

        destination:close()
    end)

    it("rejects an invalid character split across transcode writes", function()
        local destination, sink = bufferWriter()
        local writer = ioModule.newTranscodeWriter(sink, "UTF-8", "UTF-16LE")
        assert(writer:write("\195"))

        local ok, reason = writer:write("(")

        assert.is_false(ok)
        assert.matches("invalid UTF%-8 input at byte 1", reason)
        assert.is_false(writer:close())

        destination:close()
    end)
end)
