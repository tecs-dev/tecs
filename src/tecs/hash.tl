--- Content hashes over byte strings.
---
--- What a hash is for decides what belongs here, and two callers ask for
--- different things.
---
--- A build artifact carries a hash of the source it was built from, so a pack
--- that no longer matches its shaders is detected rather than trusted. That
--- wants speed, and a collision rate low enough that an accident never reaches
--- it. It does not want resistance to a collision built on purpose: the source
--- and the artifact are produced by the same build, on the same machine, from
--- a tree the person running it already controls.
---
--- A compressed stream carries a checksum of what it decompresses to, and the
--- checksum is fixed by the format rather than chosen. `tecs.compress` hands
--- zlib whole streams, so the trailer is verified inside zlib and nothing here
--- sits on that path. Adler-32 lives here anyway, because it is a hash function
--- and it is the one RFC 1950 names: a caller holding a stream it has not
--- inflated, or bytes that came out of one by some other route, wants a way to
--- check the two against each other. It is zlib's implementation, since zlib is
--- a pinned dependency of this tree and is thirteen times faster over the same
--- bytes.
---
--- **`fnv1a64` is not an integrity primitive.** Sixty-four bits puts an
--- accidental collision far beyond anything a build will produce, and puts a
--- deliberate one within reach of anyone who wants one. Establishing that a
--- downloaded asset is the asset that was published is a different question
--- with a different answer: a cryptographic digest over the bytes and a
--- signature over the manifest that lists them. Nothing here asks that
--- question yet, so nothing here answers it, and the day something does it
--- gets its own function rather than a wider version of this one.
---
--- **The algorithm is in the name on purpose.** A hash produced here is
--- written into files that outlive the process. Called `hash.content`, a
--- change to what it computes would invalidate every stored value with nothing
--- at any call site to notice; called `hash.fnv1a64`, the format is part of
--- the signature and a change is a rename that every caller is rechecked
--- against.

local ffi <const> = require("ffi")
local bit <const> = require("bit")
local zlib <const> = require("tecs.ffi.zlib")
local loader <const> = require("tecs.ffi.loader")

local sbyte <const> = string.byte

--- A 64-bit unsigned integer, as FFI cdata.
---
--- FNV-1a is defined over 64-bit arithmetic and there is no other way to spell
--- that here: a double holds integers exactly only to 2^53, and doing it in two
--- 32-bit halves costs a carry, two moduli and a division per byte. Handing it
--- to the FFI instead is the same three lines the specification is written in,
--- and it is measured at four times the throughput of the halves and two and a
--- half times that of the 32-bit hash this replaces.
---
--- That rests on LuaJIT sinking the box, which it does inside a compiled trace
--- and not in the interpreter, so the first few dozen bytes of a call allocate
--- and the rest do not. Bounded by the trace threshold rather than by the input,
--- so it does not grow with what is being hashed.
local record U64
    metamethod __mul: function(self: U64, other: U64): U64
end

--- LuaJIT widens the bit operations to 64 bits when they are handed cdata, and
--- `tohex` takes the digit count that goes with it. Declared here because the
--- library is typed over Lua numbers, which is what it does for everything else.
local u64 <const> = ffi.typeof("uint64_t") as function(value: number): U64
local bxor <const> = bit.bxor as function(value: U64, byte: integer): U64
local lshift <const> = bit.lshift as function(value: U64, bits: integer): U64
local bor <const> = bit.bor as function(value: U64, other: number): U64
local tohex <const> = bit.tohex as function(value: U64, digits: integer): string

--- FNV-1a's 64-bit prime, 0x100000001b3, and its offset basis,
--- 0xcbf29ce484222325. Assembled from 32-bit halves because the basis is larger
--- than a double holds exactly, so no Lua number names it and it cannot simply
--- be written down.
local PRIME <const> = bor(lshift(u64(0x100), 32), 0x1b3)
local BASIS <const> = bor(lshift(u64(0xcbf29ce4), 32), 0x84222325)

--- zlib's Adler-32, taken once rather than looked up per call.
---
--- `adler32_z` rather than `adler32` because the second takes its length as a
--- `uInt`, which is 32 bits: a string past 4 GB would wrap it and check out
--- against the wrong bytes. The `_z` form takes a `z_size_t` and has been in
--- zlib since 1.2.9, which is older than any revision this tree resolves.
---
--- Typed over Lua numbers on the way in, since LuaJIT converts an integer
--- argument to the parameter's type. The result is a `uLong`, 64 bits on every
--- target here, so it comes back as cdata and has to be converted.
local adler32 <const> = zlib.C.adler32_z as function(seed: integer, bytes: string, length: integer): loader.CValue
local crc32 <const> = zlib.C.crc32_z as function(seed: integer, bytes: string, length: integer): loader.CValue

local record hash
end

--- FNV-1a over the bytes of `text`, 64-bit, as sixteen lowercase hex digits.
---
--- @param text Any string. NUL and bytes above 127 hash like any other.
--- @return Sixteen hex digits, high half first, so hashes sort as their values
---     do and two of them compare as strings.
function hash.fnv1a64(text: string): string
    local state = BASIS
    for index = 1, #text do
        state = bxor(state, sbyte(text, index)) * PRIME
    end
    return tohex(state, 16)
end

--- Adler-32 over the bytes of `text`, as a number in [0, 2^32).
---
--- The checksum RFC 1950 puts in a zlib stream's trailer, which is the only
--- reason it is here. It is a poor content hash and is not offered as one: it
--- is a sum of a sum, it barely mixes on short inputs, and two files that
--- differ by reordering equal-length runs collide outright. Use `fnv1a64` for
--- identity and this only for the format that specifies it.
---
--- zlib computes it. The seed is 1, which is what RFC 1950 starts from and
--- what zlib's own documentation says to pass for the first call.
function hash.adler32(text: string): integer
    return tonumber(adler32(1, text, #text)) as integer
end

--- CRC-32 over the bytes of `text`, as a number in [0, 2^32).
---
--- The checksum PNG, gzip and ZIP put beside compressed bytes. It detects
--- accidental corruption and is not a cryptographic digest; use it only where
--- a format specifies CRC-32 or where an error-detecting checksum is enough.
function hash.crc32(text: string): integer
    return tonumber(crc32(0, text, #text)) as integer
end

return hash
