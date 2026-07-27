-- Decompression.
--
-- A decoder cannot be tested against itself. There is no encoder here to round
-- trip through, and there should not be: a bug an encoder and a decoder written
-- together share is exactly the bug a round trip cannot see. So every stream
-- below was produced by something else.
--
-- The PNG is a fixture already committed to this tree for another spec. Its
-- IDAT chunk is a zlib stream, written by whatever wrote the file, and what it
-- decompresses to is fixed by the image's own header rather than by anything
-- here: four rows of a four by four RGBA image, each preceded by a filter byte,
-- which is sixty-eight bytes. That one is the strongest evidence in this file,
-- because nothing about it was chosen to make this pass.
--
-- The hex literals are streams emitted by CPython's zlib module, which is zlib.
-- They are here because one file cannot cover the three block types DEFLATE
-- defines: the PNG uses fixed Huffman codes, and stored and dynamic blocks have
-- to be asked for. Each is asserted against text this file builds for itself,
-- so what is being checked is agreement with the compressor's input rather than
-- with a blob somebody pasted.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local compress = require("tecs.compress")

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

describe("compress.inflate", function()
    it("reads a zlib stream this tree did not produce", function()
        local stream = idatOf("spec/fixtures/split.png")
        assert.is_not_nil(stream, "the fixture has an IDAT chunk")

        local pixels = compress.inflate(stream)

        assert.are.equal(4 * (1 + 4 * 4), #pixels)
        -- Every row of that image carries filter type zero, which is the byte
        -- the rows are separated by and the cheapest thing to be certain of.
        for row = 0, 3 do
            assert.are.equal(0, pixels:byte(row * 17 + 1))
        end
    end)

    it("reads a stored block", function()
        assert.are.equal(STORED_TEXT, compress.inflate(STORED))
    end)

    it("reads a dynamic block", function()
        assert.are.equal(DYNAMIC_TEXT, compress.inflate(DYNAMIC))
    end)

    it("grows its output rather than truncating it", function()
        local unit = {}
        for index = 0, 63 do
            unit[#unit + 1] = string.char((index * 7 + 3) % 251)
        end
        local expected = string.rep(table.concat(unit), 512)
        assert.are.equal(32768, #expected)
        assert.are.equal(expected, compress.inflate(GROW))
    end)

    it("gets the same answer whatever the size hint says", function()
        -- The hint is an allocation and never a limit: too small still grows,
        -- and too large still stops where the stream does.
        assert.are.equal(STORED_TEXT, compress.inflate(STORED, 1))
        assert.are.equal(STORED_TEXT, compress.inflate(STORED, #STORED_TEXT))
        assert.are.equal(STORED_TEXT, compress.inflate(STORED, 1000000))
    end)

    it("refuses a stored block whose two lengths disagree", function()
        -- A stored block records its length twice, the second time inverted,
        -- which is the only integrity a stored block has. Flipping one bit of
        -- the inverted copy is a corrupt block that would otherwise be copied
        -- out at whatever length the first copy claimed.
        local broken = STORED:sub(1, 5) .. "\214" .. STORED:sub(7)
        local ok, reason = pcall(compress.inflate, broken)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("complement", 1, true))
    end)

    it("names bytes that are not a zlib stream as such", function()
        local ok, reason = pcall(compress.inflate, "not compressed at all")
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("not a zlib stream", 1, true))
    end)

    it("refuses a stream too short to be one", function()
        local ok, reason = pcall(compress.inflate, "\1\2\3")
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("longer than this", 1, true))
    end)

    it("refuses a header whose check word does not add up", function()
        -- Compression method still 8, flag byte adjusted so the two together
        -- are no longer a multiple of thirty-one.
        local ok, reason = pcall(compress.inflate, "\120\2" .. STORED:sub(3))
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("header check", 1, true))
    end)

    it("does not return output the checksum disagrees with", function()
        -- The last four bytes are the Adler-32 of what was compressed. A
        -- stream that decodes cleanly but came from different bytes is what
        -- the trailer exists to catch, so a mismatch must not return.
        local ok, reason = pcall(compress.inflate, STORED:sub(1, #STORED - 1) .. "\0")
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("checksum", 1, true))
    end)

    it("refuses a preset dictionary rather than decoding without it", function()
        -- The bytes the flag refers to are not in the stream, so decoding
        -- anyway produces wrong output that looks like output.
        local stream = withPresetDictionary()
        assert.is_not_nil(stream, "a valid header with FDICT set exists")

        local ok, reason = pcall(compress.inflate, stream)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("preset dictionary", 1, true))
    end)

    it("stops on a truncated stream instead of returning what it has", function()
        local ok, reason = pcall(compress.inflate, DYNAMIC:sub(1, 40))
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("ends inside", 1, true))
    end)
end)

describe("compress.inflateRaw", function()
    it("reads a stream with no wrapper", function()
        assert.are.equal(RAW_TEXT, compress.inflateRaw(RAW))
    end)

    it("does not read a wrapped stream as a raw one", function()
        -- The two header bytes are not a block header, so this fails inside
        -- the first block rather than producing something.
        local ok, reason = pcall(compress.inflateRaw, STORED)
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("tecs:", 1, true))
    end)

    it("refuses a code table with more codes than it has room for", function()
        -- Four bytes assembled by hand rather than compressed, because no
        -- compressor emits this. A final dynamic block, empty literal and
        -- distance counts, and a code-length alphabet declaring four one-bit
        -- codes, which is two more than one bit can distinguish. Decoding
        -- against it would return whichever symbol the walk reached first.
        local ok, reason = pcall(compress.inflateRaw, "\5\0\146\4")
        assert.is_false(ok)
        assert.is_truthy(tostring(reason):find("over-subscribed", 1, true))
    end)

    it("refuses an empty string", function()
        local ok = pcall(compress.inflateRaw, "")
        assert.is_false(ok)
    end)
end)
