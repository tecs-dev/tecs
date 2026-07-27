--- DEFLATE decompression: zlib streams, and the raw form inside them.
---
--- Binary asset formats store their bulk payload compressed, and the engine has
--- to read them. That is the whole requirement, and it is one-directional:
--- nothing in this tree writes a compressed byte. Shader packs are LuaJIT's own
--- serialization, snapshots go through JSON, and a screenshot is compressed
--- inside `IMG_SavePNG` where SDL_image owns the encoder. So there is no
--- `deflate` here, and adding one before something needs it would be shipping a
--- second implementation of a format to have no callers verify it.
---
--- **Why this is Lua and not a library.** zlib is already in the process, as a
--- transitive dependency of SDL3_image, and it is deliberately neither in the
--- generated bindings nor linked by name. Reaching it would mean generating
--- cdefs for it, carrying it through the ABI check, and, for a packaged preset,
--- pinning and building it from source rather than resolving it from the
--- system: a dependency added to every target so that one loader can skip a few
--- hundred lines. Vendoring a small permissive decoder instead trades the
--- pinning for a source copy and keeps the rest.
---
--- What makes neither worth it is where this runs. Decompressing an asset
--- happens once, when the asset loads, on a worker, off the frame. A decoder
--- that is several times slower than C costs milliseconds nothing is waiting
--- on, and buys a build that is the same on every preset, needs no cdefs, and
--- has nothing to pin. If a profile ever shows load time dominated by this, the
--- functions below keep their names and their signatures and something else
--- answers them.
---
--- **What it costs.** Symbols are decoded a bit at a time against the canonical
--- code, which is the small, checkable form rather than the fast one. A
--- table-driven decoder is the upgrade if a caller ever needs it, and it is a
--- change to `decode` alone.
---
--- Streams are validated rather than trusted: an over-subscribed code table, a
--- distance reaching before the start of the output, a stored block whose
--- length disagrees with its complement, a truncated stream, and a zlib
--- trailer that does not match what came out all raise. A corrupt asset is a
--- file that fails to load, not a decoder that reads past its buffer.

local loader <const> = require("tecs.ffi.loader")
local hash <const> = require("tecs.hash")

local sbyte <const> = string.byte

--- The longest Huffman code DEFLATE permits.
local MAX_BITS <const> = 15

--- Symbols in the code-length alphabet, and the order RFC 1951 stores their
--- lengths in. Least-used lengths go last, so a table that does not use them
--- can stop early.
local CODE_ORDER <const>: {integer} = {
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
}
local CODE_COUNT <const> = 19

--- Copy length for symbols 257 to 285, and how many extra bits follow each.
local LENGTH_BASE <const>: {integer} = {
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51,
    59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
}
local LENGTH_EXTRA <const>: {integer} = {
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3,
    3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
}

--- Copy distance for symbols 0 to 29, and how many extra bits follow each.
local DISTANCE_BASE <const>: {integer} = {
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513,
    769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
}
local DISTANCE_EXTRA <const>: {integer} = {
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8,
    8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
}

--- Powers of two, indexed by exponent plus one. The bit reader shifts by
--- multiplying, because `bit.lshift` works in signed 32-bit and the buffer can
--- hold a value that reads negative there.
local POW2 <const>: {number} = {}
for exponent = 0, 32 do POW2[exponent + 1] = 2 ^ exponent end

--- Bytes the output starts with. It doubles from here, so a caller that knows
--- the answer's size should say so and skip the copies entirely.
local INITIAL_CAPACITY <const> = 4096

local record compress
end

--- A canonical Huffman code, in the form a bit-at-a-time walk consumes.
local record Huffman
    --- How many codes there are of each length, indexed by the length itself.
    counts: {integer: integer}
    --- Every symbol that has a code, ordered by that code, so a code's rank
    --- within its length indexes straight into this.
    symbols: {integer}
end

--- Everything one call is decoding: where it is in the input, what bits it has
--- left over, and the output it is building.
local record State
    input: string
    --- Last input byte this call may read, so a zlib trailer is excluded
    --- without copying the body out of the stream.
    last: integer
    --- Next input byte to pull into the bit buffer, one-based.
    at: integer
    --- Bits read and not yet consumed, earliest in the low position. Carried
    --- as a number because consuming from it is a division.
    bits: number
    held: integer
    --- Output bytes, zero-indexed, in an FFI array that doubles when it fills.
    out: loader.CArray
    capacity: integer
    length: integer
end

--- Reads `want` bits, least significant first, which is the order DEFLATE
--- packs them in. `want` may be zero, which reads nothing and returns zero.
local function takeBits(state: State, want: integer): integer
    local bits = state.bits
    local held = state.held
    while held < want do
        if state.at > state.last then
            error("tecs: the compressed stream ends inside a block", 2)
        end
        bits = bits + sbyte(state.input, state.at) * POW2[held + 1]
        state.at = state.at + 1
        held = held + 8
    end
    local taken = bits % POW2[want + 1]
    state.bits = (bits - taken) / POW2[want + 1]
    state.held = held - want
    -- Whole by construction: a remainder of a sum of scaled bytes.
    return taken as integer
end

--- Builds a canonical code from one length per symbol, zero meaning unused.
---
--- Over-subscription raises: a set of lengths that describes more codes than
--- the tree has room for is a corrupt table, and decoding against it would
--- return whichever symbol the walk reached first. Under-subscription is
--- allowed, because a stream whose distance alphabet has a single symbol is
--- legal and common; a code the table leaves undefined raises when it is met,
--- in `decode`.
local function build(lengths: {integer}, count: integer): Huffman
    local counts: {integer: integer} = {}
    for length = 0, MAX_BITS do counts[length] = 0 end
    for symbol = 1, count do
        local length = lengths[symbol]
        counts[length] = counts[length] + 1
    end

    local room = 1
    for length = 1, MAX_BITS do
        room = room * 2 - counts[length]
        if room < 0 then
            error("tecs: the compressed stream has an over-subscribed code table", 2)
        end
    end

    local offsets: {integer: integer} = {}
    offsets[1] = 0
    for length = 1, MAX_BITS - 1 do
        offsets[length + 1] = offsets[length] + counts[length]
    end

    local symbols: {integer} = {}
    for symbol = 1, count do
        local length = lengths[symbol]
        if length ~= 0 then
            symbols[offsets[length] + 1] = symbol - 1
            offsets[length] = offsets[length] + 1
        end
    end

    return { counts = counts, symbols = symbols }
end

--- Reads one symbol.
---
--- The walk lengthens a candidate code a bit at a time and asks whether it has
--- fallen inside the range of codes of that length. Canonical codes are
--- assigned in increasing order within each length, so that range is
--- contiguous and the answer is one comparison and one index.
local function decode(state: State, huffman: Huffman): integer
    local counts = huffman.counts
    local symbols = huffman.symbols
    local code, first, index = 0, 0, 0
    for length = 1, MAX_BITS do
        code = code + takeBits(state, 1)
        local available = counts[length]
        if code - first < available then
            return symbols[index + code - first + 1]
        end
        index = index + available
        first = (first + available) * 2
        code = code * 2
    end
    error("tecs: the compressed stream uses a code its table does not define", 2)
end

--- Makes room for `extra` more output bytes.
local function reserve(state: State, extra: integer)
    local needed = state.length + extra
    if needed <= state.capacity then return end

    local capacity = state.capacity
    while capacity < needed do capacity = capacity * 2 end
    local grown = loader.newArray("uint8_t[?]", capacity)
    loader.copyBytes(grown, state.out as loader.CValue, state.length)
    state.out = grown
    state.capacity = capacity
end

--- Copies a block that was not compressed.
---
--- The bit buffer is discarded first: a stored block starts on a byte boundary,
--- and whatever is left over from the block header is padding.
local function stored(state: State)
    state.bits = 0
    state.held = 0
    if state.at + 3 > state.last then
        error("tecs: the compressed stream ends inside a stored block header", 2)
    end

    local input = state.input
    local size = sbyte(input, state.at) + sbyte(input, state.at + 1) * 256
    local complement = sbyte(input, state.at + 2) + sbyte(input, state.at + 3) * 256
    if complement ~= 65535 - size then
        error("tecs: a stored block's length disagrees with its complement", 2)
    end
    state.at = state.at + 4

    if state.at + size - 1 > state.last then
        error("tecs: a stored block runs past the end of the stream", 2)
    end
    reserve(state, size)
    local out = state.out
    local write = state.length
    local read = state.at
    for offset = 0, size - 1 do
        out[write + offset] = sbyte(input, read + offset)
    end
    state.length = write + size
    state.at = read + size
end

--- Decodes symbols until the end-of-block code, writing what they mean.
local function codes(state: State, literals: Huffman, distances: Huffman)
    while true do
        local symbol = decode(state, literals)

        if symbol < 256 then
            reserve(state, 1)
            state.out[state.length] = symbol
            state.length = state.length + 1
        elseif symbol == 256 then
            return
        else
            local lengthCode = symbol - 256
            if lengthCode > 29 then
                error("tecs: the compressed stream uses an undefined length code", 2)
            end
            local size = LENGTH_BASE[lengthCode]
                + takeBits(state, LENGTH_EXTRA[lengthCode])

            local distanceCode = decode(state, distances) + 1
            if distanceCode > 30 then
                error("tecs: the compressed stream uses an undefined distance code", 2)
            end
            local distance = DISTANCE_BASE[distanceCode]
                + takeBits(state, DISTANCE_EXTRA[distanceCode])

            local from = state.length - distance
            if from < 0 then
                error("tecs: a copy reaches before the start of the output", 2)
            end

            -- Forward, byte by byte, and deliberately so. A copy is allowed to
            -- overlap what it is writing, which is how DEFLATE spells a run:
            -- distance one and length two hundred is one byte repeated.
            reserve(state, size)
            local out = state.out
            local write = state.length
            for offset = 0, size - 1 do
                out[write + offset] = out[from + offset]
            end
            state.length = write + size
        end
    end
end

--- The code every fixed-Huffman block uses, built once and shared.
local fixedLiterals: Huffman = nil
local fixedDistances: Huffman = nil

local function fixed(): Huffman, Huffman
    if fixedLiterals ~= nil then return fixedLiterals, fixedDistances end

    local lengths: {integer} = {}
    for symbol = 1, 144 do lengths[symbol] = 8 end
    for symbol = 145, 256 do lengths[symbol] = 9 end
    for symbol = 257, 280 do lengths[symbol] = 7 end
    for symbol = 281, 288 do lengths[symbol] = 8 end
    fixedLiterals = build(lengths, 288)

    local distances: {integer} = {}
    for symbol = 1, 32 do distances[symbol] = 5 end
    fixedDistances = build(distances, 32)

    return fixedLiterals, fixedDistances
end

--- Reads the two code tables a dynamic block carries ahead of its data.
---
--- The lengths are themselves Huffman-coded, by a third table whose own lengths
--- are three bits each, so this reads a code to read a code to read the data.
local function dynamic(state: State): Huffman, Huffman
    local literalCount = takeBits(state, 5) + 257
    local distanceCount = takeBits(state, 5) + 1
    local codeCount = takeBits(state, 4) + 4
    if literalCount > 286 or distanceCount > 30 then
        error("tecs: the compressed stream declares too many codes", 2)
    end

    local codeLengths: {integer} = {}
    for symbol = 1, CODE_COUNT do codeLengths[symbol] = 0 end
    for index = 1, codeCount do
        codeLengths[CODE_ORDER[index] + 1] = takeBits(state, 3)
    end
    local lengthCode = build(codeLengths, CODE_COUNT)

    local total = literalCount + distanceCount
    local lengths: {integer} = {}
    local index = 1
    while index <= total do
        local symbol = decode(state, lengthCode)
        if symbol < 16 then
            lengths[index] = symbol
            index = index + 1
        else
            local value = 0
            local repeats: integer
            if symbol == 16 then
                if index == 1 then
                    error("tecs: a code length repeats with nothing before it", 2)
                end
                value = lengths[index - 1]
                repeats = 3 + takeBits(state, 2)
            elseif symbol == 17 then
                repeats = 3 + takeBits(state, 3)
            else
                repeats = 11 + takeBits(state, 7)
            end
            if index + repeats - 1 > total then
                error("tecs: the code lengths overrun their alphabet", 2)
            end
            for _ = 1, repeats do
                lengths[index] = value
                index = index + 1
            end
        end
    end

    local literals: {integer} = {}
    for symbol = 1, literalCount do literals[symbol] = lengths[symbol] end
    local distances: {integer} = {}
    for symbol = 1, distanceCount do
        distances[symbol] = lengths[literalCount + symbol]
    end

    return build(literals, literalCount), build(distances, distanceCount)
end

--- Runs the block loop over `input` between `from` and `last`, inclusive.
local function run(input: string, from: integer, last: integer,
                   sizeHint?: integer): string
    local capacity = sizeHint
    if capacity == nil or capacity < 1 then capacity = INITIAL_CAPACITY end

    local state: State = {
        input = input,
        last = last,
        at = from,
        bits = 0,
        held = 0,
        out = loader.newArray("uint8_t[?]", capacity),
        capacity = capacity,
        length = 0,
    }

    local final = 0
    repeat
        final = takeBits(state, 1)
        local kind = takeBits(state, 2)
        if kind == 0 then
            stored(state)
        elseif kind == 1 then
            codes(state, fixed())
        elseif kind == 2 then
            codes(state, dynamic(state))
        else
            error("tecs: the compressed stream has a block of no known type", 2)
        end
    until final == 1

    return loader.toBytes(state.out as loader.CValue, state.length)
end

--- Decompresses a raw DEFLATE stream, the form RFC 1951 defines.
---
--- No header and no checksum, so nothing here can tell a corrupt stream from a
--- stream of something else until the codes stop making sense. A container that
--- carries a length or a checksum of its own should check it.
---
--- @param sizeHint The decompressed size, when the caller's format records it.
---     Only an allocation hint: a wrong one costs a copy, never an error.
function compress.inflateRaw(bytes: string, sizeHint?: integer): string
    if #bytes == 0 then
        error("tecs: an empty string is not a DEFLATE stream", 2)
    end
    return run(bytes, 1, #bytes, sizeHint)
end

--- Decompresses a zlib stream, the form RFC 1950 defines.
---
--- The header is checked before anything is decoded and the Adler-32 trailer
--- after, so bytes that are not a zlib stream are named as such rather than
--- surfacing as a decode failure from somewhere inside a block, and a stream
--- that decoded into something other than what was compressed does not return.
---
--- A preset dictionary is refused rather than ignored. The flag means the
--- compressor started from bytes that are not in the stream, so decoding
--- without them produces plausible-looking wrong output, which is the one
--- failure worth never returning.
---
--- @param sizeHint The decompressed size, when the caller's format records it.
---     Only an allocation hint: a wrong one costs a copy, never an error.
function compress.inflate(bytes: string, sizeHint?: integer): string
    local size = #bytes
    -- Two header bytes, four trailer bytes, and a block of at least one.
    if size < 7 then
        error("tecs: a zlib stream is longer than this", 2)
    end

    local method = sbyte(bytes, 1)
    local flags = sbyte(bytes, 2)
    if method % 16 ~= 8 then
        error(("tecs: this is not a zlib stream; its compression method is %d, "
            .. "not 8"):format(method % 16), 2)
    end
    if (method * 256 + flags) % 31 ~= 0 then
        error("tecs: this is not a zlib stream; its header check fails", 2)
    end
    if (flags / 32) % 2 >= 1 then
        error("tecs: this zlib stream needs a preset dictionary, which is not "
            .. "carried in the stream and is not supported", 2)
    end

    local result = run(bytes, 3, size - 4, sizeHint)

    local trailer = sbyte(bytes, size - 3) * 16777216
        + sbyte(bytes, size - 2) * 65536
        + sbyte(bytes, size - 1) * 256
        + sbyte(bytes, size)
    local checksum = hash.adler32(result)
    if checksum ~= trailer then
        error(("tecs: the zlib stream decompressed to something else; its "
            .. "checksum is %08x and this is %08x"):format(trailer, checksum), 2)
    end

    return result
end

return compress
