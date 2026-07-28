-- Content hashes.
--
-- A hash is only as good as its agreement with everyone else's, because what
-- it produces gets written into files and compared later, sometimes by
-- something that is not this code. So the test that matters is not that the
-- function is consistent with itself: it is that it produces the values the
-- published reference produces, for inputs published alongside them.
--
-- The FNV-1a vectors below are the reference set from the FNV specification
-- (draft-eastlake-fnv, Appendix C), which is also what the algorithm's own
-- reference implementation is checked against. The Adler-32 vectors are from
-- RFC 1950's definition and match what zlib returns.
--
-- Everything else here is about the parts an implementation gets wrong on its
-- own: an input that is not a multiple of the block the reader takes at a
-- time, bytes above 127 that a signed path would mangle, and an input long
-- enough to reach the point where a deferred modulus has to be applied.
--
-- The Adler-32 vectors below were written against a Lua implementation and are
-- unchanged now that zlib computes it. That is the point of them: they were
-- the evidence that the swap changed nothing, and they stay as the evidence
-- that nothing changes it back.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local ffi = require("ffi")
local data = require("tecs.data")
local zlib = require("tecs.ffi.zlib")

describe("data.fnv1a64", function()
    it("matches the published reference vectors", function()
        assert.are.equal("cbf29ce484222325", data.fnv1a64(""))
        assert.are.equal("af63dc4c8601ec8c", data.fnv1a64("a"))
        assert.are.equal("af63df4c8601f1a5", data.fnv1a64("b"))
        assert.are.equal("af63de4c8601eff2", data.fnv1a64("c"))
        assert.are.equal("af63d94c8601e773", data.fnv1a64("d"))
        assert.are.equal("85944171f73967e8", data.fnv1a64("foobar"))
    end)

    it("matches them across the boundary of the block it reads", function()
        -- Bytes are taken eight at a time with a tail loop for the rest, so
        -- the lengths either side of eight are where a reader that lost or
        -- repeated a byte would show it. "foobar" is six and covered above.
        assert.are.equal("a430d84680aabd0b", data.fnv1a64("hello"))
        assert.are.equal("7396e6eb4e2040df", data.fnv1a64("foobarfo"))
        assert.are.equal("89ab11d5c0cdeb10", data.fnv1a64("foobarfoo"))
    end)

    it("is sixteen hex digits, high half first", function()
        local digest = data.fnv1a64("#version 450\nvoid main() {}\n")
        assert.are.equal(16, #digest)
        assert.are.equal("aaaefb1e8cc8f7a3", digest)
        -- High half first, which the empty input shows outright: it hashes to
        -- the offset basis, whose halves are 0xcbf29ce4 and 0x84222325. So
        -- string order is value order, and two digests compare unparsed.
        assert.are.equal("cbf29ce4" .. "84222325", data.fnv1a64(""))
        assert.is_true(data.fnv1a64("foobar") < data.fnv1a64("a"))
    end)

    it("hashes bytes rather than characters", function()
        -- NUL does not terminate, and a byte above 127 is hashed as itself
        -- rather than sign-extended into the state.
        assert.are_not.equal(data.fnv1a64("a\0b"), data.fnv1a64("a"))
        assert.are_not.equal(data.fnv1a64("\255"), data.fnv1a64("\127"))
        assert.are.equal("af64724c8602eb6e", data.fnv1a64("\255"))
        assert.are.equal("e5d29919042666b2", data.fnv1a64("a\0b"))
    end)

    it("separates inputs that differ in one byte", function()
        local one = data.fnv1a64("#version 450\nvoid main() {}\n")
        assert.are.equal(one, data.fnv1a64("#version 450\nvoid main() {}\n"))
        assert.are_not.equal(one, data.fnv1a64("#version 450\nvoid main(){}\n"))
    end)
end)

describe("data.adler32", function()
    it("matches the values RFC 1950's definition produces", function()
        assert.are.equal(0x00000001, data.adler32(""))
        assert.are.equal(0x00620062, data.adler32("a"))
        assert.are.equal(0x024d0127, data.adler32("abc"))
        assert.are.equal(0x11e60398, data.adler32("Wikipedia"))
    end)

    it("agrees over an input that spans several deferred runs", function()
        -- Every Adler-32 implementation reduces its sums in blocks rather than
        -- per byte, because that is the only way to keep them in range, and a
        -- block boundary is where one that drops or repeats a byte shows it.
        -- 21000 bytes crosses several of any plausible block size.
        local long = string.rep("The quick brown fox. ", 1000)
        assert.are.equal(21000, #long)
        assert.is_true(#long > 3 * 5552)
        assert.are.equal(0x8454d48d, data.adler32(long))
    end)

    it("returns a value inside thirty-two bits", function()
        -- zlib returns a uLong, which is 64 bits here and arrives as cdata.
        -- A conversion that forgot that would hand back a boxed number that
        -- compares equal to nothing and indexes nothing.
        local checksum = data.adler32(string.rep("\255", 8192))
        assert.are.equal("number", type(checksum))
        assert.is_true(checksum >= 0 and checksum < 4294967296)
        assert.are.equal(checksum, math.floor(checksum))
    end)

    it("matches the trailer zlib itself writes into a stream", function()
        -- The strongest statement available about this function: RFC 1950 puts
        -- the Adler-32 of the uncompressed bytes in the last four bytes of a
        -- zlib stream, big-endian. Asking zlib to compress something and then
        -- reading what it put there checks this against the format rather than
        -- against another implementation of the same sum.
        local text = string.rep("compressible, and then some. ", 400)
        local bound = tonumber(zlib.C.compressBound(#text))
        local buffer = ffi.new("uint8_t[?]", bound)
        local size = ffi.new("unsigned long[1]", bound)
        assert.are.equal(0, tonumber(zlib.C.compress2(buffer, size, text, #text, 6)))

        local stream = ffi.string(buffer, tonumber(size[0]))
        assert.is_true(#stream < #text)
        local a, b, c, d = stream:byte(#stream - 3, #stream)
        local trailer = ((a * 256 + b) * 256 + c) * 256 + d
        assert.are.equal(trailer, data.adler32(text))
    end)
end)

describe("data.crc32", function()
    it("matches the published check value", function()
        assert.are.equal(0, data.crc32(""))
        assert.are.equal(0xcbf43926, data.crc32("123456789"))
    end)

    it("hashes every byte and returns a Lua number", function()
        assert.are.equal(0x352441c2, data.crc32("abc"))
        assert.are.not_equal(data.crc32("a\0b"), data.crc32("a"))
        local checksum = data.crc32(string.rep("\255", 8192))
        assert.are.equal("number", type(checksum))
        assert.is_true(checksum >= 0 and checksum < 4294967296)
    end)
end)
