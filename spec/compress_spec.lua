-- Decompression.
--
-- zlib does the decoding, so what a test here can establish divides in two, and
-- both halves are wanted.
--
-- The corpus is what says the format is read correctly, and none of it was
-- produced by this tree. The PNG is a fixture already committed for another
-- spec. Its IDAT chunk is a zlib stream, written by whatever wrote the file,
-- and what it decompresses to is fixed by the image's own header rather than by
-- anything here: four rows of a four by four RGBA image, each preceded by a
-- filter byte, which is sixty-eight bytes. The hex literals are streams emitted
-- by CPython's zlib module, and they are here because one file cannot cover the
-- three block types DEFLATE defines: the PNG uses fixed Huffman codes, and
-- stored and dynamic blocks have to be asked for. Each is asserted against text
-- this file builds for itself, so what is checked is agreement with the
-- compressor's input rather than with a blob somebody pasted.
--
-- The round trips are what says this module's own arithmetic is correct. They
-- establish nothing about the format, since zlib is on both ends of them; what
-- they exercise is the output buffer, which belongs to this module and not to
-- zlib, at the sizes where it starts, fills exactly, doubles repeatedly, and is
-- given a hint that is right, far too small, and far too large.
--
-- The refusals assert that a malformed stream raises, and deliberately not what
-- it raises. Every message now comes out of zlib's own taxonomy, and a suite
-- pinned to one implementation's strings is a suite that has to be rewritten
-- before the implementation can be, which is most of what made swapping this
-- decoder look expensive in the first place. What is being defended is that a
-- corrupt stream is a load that fails, not a decoder that reads past its
-- buffer; which sentence says so is not part of that.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local ffi = require("ffi")
local zlib = require("tecs.ffi.zlib")
local ioModule = require("tecs").io

local function bufferWriter(destination)
    return destination:newWriter()
end

local function sourceReader(bytes)
    if type(bytes) == "string" then
        return ioModule.newStringReader(bytes)
    end
    return bytes:newReader()
end

local function deflateInto(bytes, destination, level, raw)
    destination:clear()
    local writer = ioModule.newDeflateWriter(bufferWriter(destination), { level = level, raw = raw })
    local wrote, reason
    if type(bytes) == "string" then
        wrote, reason = writer:write(bytes)
    else
        wrote, reason = writer:writeView(bytes)
    end
    if not wrote then
        writer:close()
        error(reason, 0)
    end
    local closed, closeReason = writer:close()
    if not closed then
        error(closeReason, 0)
    end
    return destination
end

local function deflate(bytes, level)
    local destination = ioModule.newBuffer()
    deflateInto(bytes, destination, level, false)
    local result = destination:getString()
    destination:close()
    return result
end

local function deflateRaw(bytes, level)
    local destination = ioModule.newBuffer()
    deflateInto(bytes, destination, level, true)
    local result = destination:getString()
    destination:close()
    return result
end

local function inflateInto(bytes, destination, maxBytes, raw)
    destination:clear()
    local reader = ioModule.newInflateReader(sourceReader(bytes), { maxBytes = maxBytes, raw = raw })
    local writer = bufferWriter(destination)
    local copied, reason = reader:transferTo(writer)
    reader:close()
    writer:close()
    if copied == nil then
        destination:clear()
        error(reason, 0)
    end
    return destination
end

local function inflate(bytes, _sizeHint, maxBytes)
    local destination = ioModule.newBuffer()
    inflateInto(bytes, destination, maxBytes, false)
    local result = destination:getString()
    destination:close()
    return result
end

local function inflateRaw(bytes, _sizeHint, maxBytes)
    local destination = ioModule.newBuffer()
    inflateInto(bytes, destination, maxBytes, true)
    local result = destination:getString()
    destination:close()
    return result
end

-- Streams are carried as hex so this file stays text and diffs like text.
local function bytes(hex)
    return (hex:gsub("%x%x", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

-- zlib.compress(STORED_TEXT, 0): one stored block.
local STORED = bytes(
    "7801012800d7ff73746f72656420626c6f636b7320636172727920746865" .. "697220627974657320766572626174696d3b930f6e"
)
local STORED_TEXT = "stored blocks carry their bytes verbatim"

-- zlib.compress(DYNAMIC_TEXT, 9): one dynamic block, whose two code tables are
-- themselves Huffman-coded ahead of the data by a third table.
local DYNAMIC = bytes(
    "78da3d8f4112c2201004bf32de2d3ee0cd93e5c92afd003104d610488040"
        .. "92d7bb2496e79e99de7d198569a6778f26f8e2d0f9059f7918237c560189"
        .. "b195db8ad66b8187e4dcb0a2e150a164d051568c36e560699a7de0ae8e02"
        .. "375f90d5424edbf537dfca2e61534d9071179cf01c0db905be4363ebf034"
        .. "cb90b633d356abaac9be08dc19b5b244583e68979346fc578f92c0359036"
        .. "099916e50ec1a51eb6f243c5d6d4bb17f802cc635570"
)
local DYNAMIC_TEXT = table.concat({
    "The quick brown fox jumps over the lazy dog. ",
    "Pack my box with five dozen liquor jugs. ",
    "How vexingly quick daft zebras jump! ",
    "Sphinx of black quartz, judge my vow. ",
    "Jackdaws love my big sphinx of quartz. ",
    "Bright vixens jump; dozy fowl quack. ",
})

-- Thirty-two kilobytes of a repeating pattern, which is eight times the buffer
-- the decoder starts with, so every copy that grows it has to land.
local GROW = bytes(
    "78daedcba17601000000c040b244224d22914824128944229148244b9348"
        .. "241289442291489aa6699aa689fec3bbeb170885a3bf8954265728556a8d"
        .. "56a737f81f4d668bd56677385daeb7fbe3f97a077f22b178329dcd17cbd5"
        .. "7ab3ddedff0dc7d3f972bddd1fcf01dff77ddff77ddff77ddff77ddff77d"
        .. "dff77ddff77ddff77ddff77ddff77ddff77ddff77ddff77ddff77ddff77d"
        .. "dff77ddff77ddff77ddff77ddff77ddff77ddff77ddff77ddff77ddff77d"
        .. "dff77ddff77ddff77ddff77ddff77ddff77ddfff82ff01081cdb49"
)

-- zlib.compressobj(9, DEFLATED, -15): the same codes with no wrapper.
local RAW = bytes("2b4a2c5748494dcb492c4955c8482c56c8cb57282f4a2c28482d0200")
local RAW_TEXT = "raw deflate has no wrapper"

-- Three bytes assembled bit by bit rather than compressed, because no
-- compressor emits this. A final fixed-Huffman block, one literal, and then a
-- copy of length three from distance two, when a single byte has been written.
-- Honoured, it would read whatever sat in memory before the output.
local TOO_FAR = bytes("730442")

--- The zlib stream inside a PNG's first IDAT chunk.
---
--- Past the eight-byte signature a PNG is chunks, and a chunk is a big-endian
--- length, a four-character kind, that many bytes, and a CRC.
local function idatOf(path)
    local file = assert(io.open(path, "rb"))
    local png = file:read("*a")
    file:close()

    local at = 9
    while at + 7 < #png do
        local a, b, c, d = png:byte(at, at + 3)
        local size = ((a * 256 + b) * 256 + c) * 256 + d
        if png:sub(at + 4, at + 7) == "IDAT" then
            return png:sub(at + 8, at + 7 + size)
        end
        at = at + 12 + size
    end
    return nil
end

--- A copy of `STORED`'s header with FDICT set and its check word repaired, so
--- what the refusal is about is the dictionary and not an invalid header.
local function withPresetDictionary()
    local method = STORED:byte(1)
    for candidate = 0, 255 do
        local hasDictionary = math.floor(candidate / 32) % 2 == 1
        if hasDictionary and (method * 256 + candidate) % 31 == 0 then
            return string.char(method, candidate) .. STORED:sub(3)
        end
    end
    return nil
end

--- `text` as a zlib stream, compressed by zlib itself.
local function deflated(text, level)
    local bound = tonumber(zlib.C.compressBound(#text))
    local buffer = ffi.new("uint8_t[?]", bound)
    local size = ffi.new("unsigned long[1]", bound)
    assert.are.equal(0, tonumber(zlib.C.compress2(buffer, size, text, #text, level)))
    return ffi.string(buffer, tonumber(size[0]))
end

--- Bytes that neither compress away to nothing nor resist compression, so a
--- round trip over them meets literals, matches and a non-trivial code table.
local function mixture(size)
    local pieces = {}
    local at = 0
    while at < size do
        pieces[#pieces + 1] = ("chunk %d of a mixture, "):format(at % 97)
        pieces[#pieces + 1] = string.char(at % 251, (at * 7 + 11) % 251)
        at = at + 1
    end
    return table.concat(pieces):sub(1, size)
end

describe("io.newInflateReader", function()
    it("reads a zlib stream this tree did not produce", function()
        local stream = idatOf("spec/fixtures/split.png")
        assert.is_not_nil(stream, "the fixture has an IDAT chunk")

        local pixels = inflate(stream)

        assert.are.equal(4 * (1 + 4 * 4), #pixels)
        -- Every row of that image carries filter type zero, which is the byte
        -- the rows are separated by and the cheapest thing to be certain of.
        for row = 0, 3 do
            assert.are.equal(0, pixels:byte(row * 17 + 1))
        end
    end)

    it("reads a stored block", function()
        assert.are.equal(STORED_TEXT, inflate(STORED))
    end)

    it("reads a dynamic block", function()
        assert.are.equal(DYNAMIC_TEXT, inflate(DYNAMIC))
    end)

    it("grows its output rather than truncating it", function()
        local unit = {}
        for index = 0, 63 do
            unit[#unit + 1] = string.char((index * 7 + 3) % 251)
        end
        local expected = string.rep(table.concat(unit), 512)
        assert.are.equal(32768, #expected)
        assert.are.equal(expected, inflate(GROW))
    end)

    it("returns the original bytes at every size around its buffer", function()
        -- The buffer starts at four kilobytes and doubles. These sit on both
        -- sides of that boundary and well past several of them, which is where
        -- an off-by-one in the growth arithmetic shows up as a short answer or
        -- a copy of the wrong length rather than as a failure.
        for _, size in ipairs({ 0, 1, 2, 4095, 4096, 4097, 8192, 100000 }) do
            local text = mixture(size)
            assert.are.equal(size, #text)
            assert.are.equal(text, inflate(deflated(text, 6)))
        end
    end)

    it("returns the original bytes whatever the stream is made of", function()
        -- Three shapes with nothing in common: incompressible bytes, which
        -- become stored or near-stored blocks; one byte repeated, which is a
        -- single long run of overlapping copies; and text, which is what a
        -- dynamic code table is for.
        local noise = {}
        local seed = 12345
        for index = 1, 20000 do
            seed = (seed * 1103515245 + 12345) % 2147483648
            noise[index] = string.char(math.floor(seed / 65536) % 256)
        end
        for _, text in ipairs({
            table.concat(noise),
            string.rep("\0", 70000),
            string.rep(DYNAMIC_TEXT, 40),
        }) do
            for _, level in ipairs({ 0, 1, 6, 9 }) do
                assert.are.equal(text, inflate(deflated(text, level)))
            end
        end
    end)

    it("refuses a stored block whose two lengths disagree", function()
        -- A stored block records its length twice, the second time inverted,
        -- which is the only integrity a stored block has. Flipping one bit of
        -- the inverted copy is a corrupt block that would otherwise be copied
        -- out at whatever length the first copy claimed.
        local broken = STORED:sub(1, 5) .. "\214" .. STORED:sub(7)
        assert.is_false(pcall(inflate, broken))
    end)

    it("refuses bytes that are not a zlib stream", function()
        assert.is_false(pcall(inflate, "not compressed at all"))
    end)

    it("refuses a stream too short to be one", function()
        assert.is_false(pcall(inflate, "\1\2\3"))
        assert.is_false(pcall(inflate, ""))
    end)

    it("refuses a header whose check word does not add up", function()
        -- Compression method still 8, flag byte adjusted so the two together
        -- are no longer a multiple of thirty-one.
        assert.is_false(pcall(inflate, "\120\2" .. STORED:sub(3)))
    end)

    it("does not return output the checksum disagrees with", function()
        -- The last four bytes are the Adler-32 of what was compressed. A
        -- stream that decodes cleanly but came from different bytes is what
        -- the trailer exists to catch, so a mismatch must not return.
        assert.is_false(pcall(inflate, STORED:sub(1, #STORED - 1) .. "\0"))
    end)

    it("refuses a preset dictionary rather than decoding without it", function()
        -- The bytes the flag refers to are not in the stream, so decoding
        -- anyway produces wrong output that looks like output.
        local stream = withPresetDictionary()
        assert.is_not_nil(stream, "a valid header with FDICT set exists")
        assert.is_false(pcall(inflate, stream))
    end)

    it("stops on a truncated stream instead of returning what it has", function()
        assert.is_false(pcall(inflate, DYNAMIC:sub(1, 40)))
        -- And at the other end: a whole stream missing only its trailer, which
        -- is the truncation a decoder is likeliest to accept by accident.
        assert.is_false(pcall(inflate, STORED:sub(1, #STORED - 4)))
    end)
end)

describe("io.newDeflateWriter", function()
    it("compresses and inflates retained views after their buffers close", function()
        local source = ioModule.newBuffer("payload")
        local sourceView = source:view()
        sourceView.getString = function()
            error("compression copied its input")
        end
        source:close()

        local wrapped = deflate(sourceView)
        local raw = deflateRaw(sourceView)
        local wrappedBuffer = ioModule.newBuffer(wrapped)
        local rawBuffer = ioModule.newBuffer(raw)
        local wrappedView = wrappedBuffer:view()
        local rawView = rawBuffer:view()
        wrappedBuffer:close()
        rawBuffer:close()

        assert.are.equal("payload", inflate(wrappedView))
        assert.are.equal("payload", inflateRaw(rawView))

        sourceView:close()
        wrappedView:close()
        rawView:close()
    end)

    it("round trips zlib and raw streams", function()
        local text = mixture(32768)
        assert.are.equal(text, inflate(deflate(text)))
        assert.are.equal(text, inflateRaw(deflateRaw(text)))
    end)

    it("writes a valid empty stream", function()
        assert.are.equal("", inflate(deflate("")))
        assert.are.equal("", inflateRaw(deflateRaw("")))
    end)

    it("pipelines caller-owned buffers for wrapped and raw streams", function()
        local text = mixture(32768)
        local compressed = ioModule.newBuffer("discarded")
        local restored = ioModule.newBuffer("discarded")

        assert.are.equal(compressed, deflateInto(text, compressed, nil, false))
        local capacity = compressed:capacity()
        local compressedView = compressed:view()
        assert.are.equal(restored, inflateInto(compressedView, restored, nil, false))
        compressedView:close()
        assert.are.equal(text, restored:getString())

        assert.are.equal(compressed, deflateInto(text, compressed, nil, true))
        assert.are.equal(capacity, compressed:capacity())
        compressedView = compressed:view()
        assert.are.equal(restored, inflateInto(compressedView, restored, nil, true))
        compressedView:close()
        assert.are.equal(text, restored:getString())

        compressed:close()
        restored:close()
    end)

    it("enforces a hard decompressed-output ceiling", function()
        local text = string.rep("expands", 100)
        local compressed = deflate(text)
        local destination = ioModule.newBuffer("old bytes")

        assert.has_error(function()
            inflate(compressed, nil, #text - 1)
        end)
        assert.has_error(function()
            inflateInto(compressed, destination, #text - 1, false)
        end)
        assert.are.equal(0, destination:length())
        assert.are.equal(text, inflate(compressed, #text, #text))
        destination:close()
    end)

    it("accepts every compression level and rejects invalid ones", function()
        local text = string.rep("compress me", 100)
        for level = 0, 9 do
            assert.are.equal(text, inflate(deflate(text, level)))
        end
        for _, level in ipairs({ 10, 1.5 }) do
            local destination = ioModule.newBuffer()
            local writer = bufferWriter(destination)
            assert.has_error(function()
                ioModule.newDeflateWriter(writer, { level = level })
            end)
            writer:close()
            destination:close()
        end
    end)
end)

describe("io.newInflateReader raw mode", function()
    it("reads a stream with no wrapper", function()
        assert.are.equal(RAW_TEXT, inflateRaw(RAW))
    end)

    it("reads the DEFLATE inside a zlib stream", function()
        -- A zlib stream is two header bytes, the raw form, and four bytes of
        -- checksum, so stripping the wrapper off one zlib wrote is a raw
        -- stream that no separate compressor had to be arranged to produce.
        for _, size in ipairs({ 1, 4096, 50000 }) do
            local text = mixture(size)
            local stream = deflated(text, 6)
            local raw = stream:sub(3, #stream - 4)
            assert.are.equal(text, inflateRaw(raw))
            assert.are.equal(text, inflateRaw(raw, #text))
        end
    end)

    it("does not read a wrapped stream as a raw one", function()
        -- The two header bytes are not a block header, so this fails inside
        -- the first block rather than producing something.
        assert.is_false(pcall(inflateRaw, STORED))
    end)

    it("refuses a code table with more codes than it has room for", function()
        -- Four bytes assembled by hand rather than compressed, because no
        -- compressor emits this. A final dynamic block, empty literal and
        -- distance counts, and a code-length alphabet declaring four one-bit
        -- codes, which is two more than one bit can distinguish. Decoding
        -- against it would return whichever symbol the walk reached first.
        assert.is_false(pcall(inflateRaw, "\5\0\146\4"))
    end)

    it("refuses a copy reaching before the start of the output", function()
        assert.is_false(pcall(inflateRaw, TOO_FAR))
    end)

    it("refuses an empty string", function()
        assert.is_false(pcall(inflateRaw, ""))
    end)
end)
