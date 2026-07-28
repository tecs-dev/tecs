--- DEFLATE compression and decompression: zlib streams, and the raw form
--- inside them.
---
--- Binary asset formats store their bulk payload compressed, and the engine has
--- to read them. Games also write compressed save data, replays, caches and
--- network payloads, and those bytes need the matching encoder rather than a
--- private compressor in each caller.
---
--- **zlib does both.** It is pinned, generated into `tecs.ffi.zlib`, carried
--- through the ABI check and loaded the same way every other native library is,
--- because libcurl needs it to answer a `Content-Encoding`. Once it is in the
--- process for that, a decoder written here would be a second implementation of
--- the format to keep correct, and the slower one. It loads on a worker the way
--- every other binding does: `loader.declare` installs the cdef once per
--- `lua_State`, so a worker that requires this module gets it there rather than
--- inheriting anything from the thread that spawned it.
---
--- **`inflate` over a stream rather than `uncompress`.** `uncompress` wants the
--- decompressed size up front and treats a wrong one as a failure, and no caller
--- here has that number: `sizeHint` is a hint whose entire contract is that
--- being wrong costs a copy. It also reads only the wrapped form, so the raw
--- entry point would need a second mechanism regardless. `inflateInit2_` takes
--- the window size instead, and negating that selects the raw form, so one loop
--- answers both.
---
--- Streams are validated rather than trusted: an over-subscribed code table, a
--- distance reaching before the start of the output, a stored block whose
--- length disagrees with its complement, a truncated stream, and a zlib trailer
--- that does not match what came out all raise. A corrupt asset is a file that
--- fails to load, not a decoder that reads past its buffer. zlib decides every
--- one of those except the truncation, which is decided here: all of the input
--- is handed over at once, so a call that stops with output room to spare is
--- asking for more of a stream that has no more.
---
--- Failures carry zlib's own sentence where it wrote one, because it says which
--- structure was invalid rather than that one was. They are diagnostics and not
--- an interface; nothing should match against them.

local ffi <const> = require("ffi")
local loader <const> = require("tecs.ffi.loader")
local zlib <const> = require("tecs.ffi.zlib")

local C <const> = zlib.C
local K <const> = zlib.K

--- The three entry points, typed. The bindings are open namespaces, so the
--- signature is declared here rather than inferred, the way `tecs.hash` does it.
local inflateInit2 <const> = C.inflateInit2_ as function(
    stream: loader.CValue, windowBits: integer, version: string, size: integer
): integer
local inflate <const> = C.inflate as function(stream: loader.CValue, flush: integer): integer
local inflateEnd <const> = C.inflateEnd as function(stream: loader.CValue): integer
local deflateInit2 <const> = C.deflateInit2_ as function(
    stream: loader.CValue,
    level: integer,
    method: integer,
    windowBits: integer,
    memoryLevel: integer,
    strategy: integer,
    version: string,
    size: integer
): integer
local deflate <const> = C.deflate as function(stream: loader.CValue, flush: integer): integer
local deflateEnd <const> = C.deflateEnd as function(stream: loader.CValue): integer
local deflateBound <const> = C.deflateBound as function(stream: loader.CValue, size: integer): loader.CValue

--- What `inflateInit2_` checks itself against, and what it is checked against.
---
--- The version is the one the cdefs were generated from, and zlib compares its
--- major digit; the size is this build's `z_stream`, and zlib compares it
--- exactly. Together they are how a binding generated against one zlib and
--- linked against another fails at the call instead of corrupting memory
--- through a struct of the wrong shape.
local VERSION <const> = loader.textConstants("zlib").ZLIB_VERSION
local STREAM_SIZE <const> = ffi.sizeof("z_stream") as integer

--- DEFLATE's largest window, 32 KB. Negated, it asks `inflateInit2_` for the
--- raw form: no header, no trailer, and no checksum.
local WINDOW_BITS <const> = 15

--- Bytes the output starts with when the caller does not say. It doubles from
--- here, so a caller that knows the answer's size should say so and skip the
--- copies entirely.
local INITIAL_CAPACITY <const> = 4096

--- Most output offered to one `inflate` call. `avail_out` is a `uInt`, so a
--- size hint larger than one holds is answered in pieces rather than wrapped.
local MAX_CHUNK <const> = 0x40000000

--- What the return codes zlib writes no message for mean.
local CODE_NAMES <const>: {integer: string} = {
    [K.Z_STREAM_ERROR] = "its state is inconsistent",
    [K.Z_DATA_ERROR] = "it is corrupt",
    [K.Z_MEM_ERROR] = "zlib could not allocate",
    [K.Z_VERSION_ERROR] = "the zlib in this process is not the one these " .. "bindings were generated against",
}

local record compress
end

--- Why a stream did not decode.
---
--- Called before the stream is ended, which is the order that does not depend
--- on what `inflateEnd` leaves behind it. The reason is named rather than
--- raised so the public functions can blame their own caller rather than a
--- frame inside this file.
local function describe(fields: loader.CStruct, status: integer): string
    if status == K.Z_NEED_DICT then
        return "tecs: this zlib stream needs a preset dictionary, which is "
            .. "not carried in the stream and is not supported"
    end

    local message = fields.msg
    if message ~= nil then
        return ("tecs: the compressed stream is not valid: %s"):format(loader.toString(message as loader.CValue))
    end
    local named = CODE_NAMES[status] or ("zlib returned %d"):format(status)
    return ("tecs: the compressed stream is not valid: %s"):format(named)
end

--- Inflates all of `bytes` under `windowBits`, which is what selects the
--- wrapper. Returns the bytes, or nil and what went wrong.
local function run(bytes: string, windowBits: integer, sizeHint?: integer): string, string
    local capacity = sizeHint
    if capacity == nil or capacity < 1 then
        capacity = INITIAL_CAPACITY
    end

    local stream <const> = loader.newStruct("z_stream")
    local fields <const> = stream as loader.CStruct

    local status = inflateInit2(stream, windowBits, VERSION, STREAM_SIZE)
    if status ~= K.Z_OK then
        -- Nothing to end: an init that failed allocated nothing.
        return nil, describe(fields, status)
    end

    -- The pointer does not keep the string alive, but `bytes` is a parameter
    -- and stays reachable for as long as zlib is reading through it.
    fields.next_in = ffi.cast("uint8_t *", bytes)
    fields.avail_in = #bytes

    local out = loader.newArray("uint8_t[?]", capacity)
    local produced = 0

    while true do
        if produced == capacity then
            capacity = capacity * 2
            local grown = loader.newArray("uint8_t[?]", capacity)
            loader.copyBytes(grown, out as loader.CValue, produced)
            out = grown
        end

        local room = capacity - produced
        if room > MAX_CHUNK then
            room = MAX_CHUNK
        end
        fields.next_out = loader.bytePointer(out as loader.CValue) + produced
        fields.avail_out = room

        status = inflate(stream, K.Z_NO_FLUSH)
        local spare = fields.avail_out as integer
        produced = produced + room - spare

        if status == K.Z_STREAM_END then
            inflateEnd(stream)
            return loader.toBytes(out as loader.CValue, produced)
        end
        if status ~= K.Z_OK and status ~= K.Z_BUF_ERROR then
            local reason = describe(fields, status)
            inflateEnd(stream)
            return nil, reason
        end
        if spare ~= 0 then
            inflateEnd(stream)
            return nil, "tecs: the compressed stream ends inside a block"
        end
    end
end

--- Validates and normalises a compression level. Minus one asks zlib for its
--- default, and zero through nine run from stored bytes to the smallest output.
local function compressionLevel(level?: integer): integer
    local given = level
    if given == nil then
        return K.Z_DEFAULT_COMPRESSION
    end
    if given ~= math.floor(given) or given < -1 or given > 9 then
        error("tecs: compression level must be an integer from -1 to 9", 3)
    end
    return given
end

--- Deflates all of `bytes` under `windowBits`, returning the bytes or nil and
--- the native failure. `deflateBound` guarantees one output buffer is enough,
--- so encoding allocates once and never grows or copies.
local function encode(bytes: string, windowBits: integer, level?: integer): string, string
    local stream <const> = loader.newStruct("z_stream")
    local fields <const> = stream as loader.CStruct
    local status = deflateInit2(
        stream, compressionLevel(level), K.Z_DEFLATED, windowBits, 8, K.Z_DEFAULT_STRATEGY, VERSION, STREAM_SIZE
    )
    if status ~= K.Z_OK then
        return nil, describe(fields, status)
    end

    local capacity = tonumber(deflateBound(stream, #bytes)) as integer
    local out <const> = loader.newArray("uint8_t[?]", capacity)
    fields.next_in = ffi.cast("uint8_t *", bytes)
    fields.avail_in = #bytes
    fields.next_out = out
    fields.avail_out = capacity

    status = deflate(stream, K.Z_FINISH)
    if status ~= K.Z_STREAM_END then
        local reason = describe(fields, status)
        deflateEnd(stream)
        return nil, reason
    end
    local produced = capacity - (fields.avail_out as integer)
    deflateEnd(stream)
    return loader.toBytes(out as loader.CValue, produced)
end

--- Compresses bytes as a raw RFC 1951 DEFLATE stream.
---
--- @param level Minus one or omitted uses zlib's default. Zero stores without
---     compression; one through nine trade time for size.
function compress.deflateRaw(bytes: string, level?: integer): string
    local result, reason = encode(bytes, -WINDOW_BITS, level)
    if result == nil then
        error(reason, 2)
    end
    return result
end

--- Compresses bytes as an RFC 1950 zlib stream, including its header and
--- Adler-32 trailer.
---
--- @param level Minus one or omitted uses zlib's default. Zero stores without
---     compression; one through nine trade time for size.
function compress.deflate(bytes: string, level?: integer): string
    local result, reason = encode(bytes, WINDOW_BITS, level)
    if result == nil then
        error(reason, 2)
    end
    return result
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
    local result, reason = run(bytes, -WINDOW_BITS, sizeHint)
    if result == nil then
        error(reason, 2)
    end
    return result
end

--- Decompresses a zlib stream, the form RFC 1950 defines.
---
--- The header is checked before anything is decoded and the Adler-32 trailer
--- after, both inside zlib, so bytes that are not a zlib stream are named as
--- such rather than surfacing as a decode failure from somewhere inside a
--- block, and a stream that decoded into something other than what was
--- compressed does not return.
---
--- A preset dictionary is refused rather than ignored. The flag means the
--- compressor started from bytes that are not in the stream, so decoding
--- without them produces plausible-looking wrong output, which is the one
--- failure worth never returning. zlib stops and asks for the dictionary, and
--- since there is nowhere to get one, the ask is the refusal.
---
--- @param sizeHint The decompressed size, when the caller's format records it.
---     Only an allocation hint: a wrong one costs a copy, never an error.
function compress.inflate(bytes: string, sizeHint?: integer): string
    if #bytes == 0 then
        error("tecs: an empty string is not a zlib stream", 2)
    end
    local result, reason = run(bytes, WINDOW_BITS, sizeHint)
    if result == nil then
        error(reason, 2)
    end
    return result
end

return compress
