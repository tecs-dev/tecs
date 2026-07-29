--- Turning bytes into other bytes: JSON in both directions, DEFLATE in both
--- directions, and a hash over either.
---
--- One module because each of these is a few functions over a byte string with
--- no state to carry, and a game reaching for one is nearly always about to
--- reach for another: a save is encoded, compressed and stamped, and a cache
--- entry is checked the other way round. Three modules of three functions each
--- would put that one job in three places.
---
--- The transformations name their format, because a merged module makes a bare
--- verb ambiguous and because a value produced here outlives the process. There
--- is no `encode`, and `fnv1a64` says which hash it is so that changing what it
--- computes is a rename every caller is rechecked against.
---
--- ## JSON
---
--- The parser and the encoder are lua-cjson, in C, so a snapshot, a debug
--- protocol frame or a sprite sheet crosses without a Lua parser in the way.
---
---     local text <const> = tecs.data.encodeJSON({name = "player", hp = 100})
---     local value <const> = tecs.data.decodeJSON(text)
---
--- Both raise rather than guess. `encodeJSON` raises on a value JSON has no
--- form for, a function or a cdata among them, so a field never silently
--- vanishes from a payload; `decodeJSON` raises on anything malformed, the
--- empty string included, and bounds its own nesting so a hostile document
--- cannot recurse a server to death.
---
--- What a Lua table cannot say for itself, two sentinels say. `null` is the
--- JSON null, which is not `nil`, so a decoded object keeps a key whose value
--- was null instead of losing it. `empty_array` encodes as `[]`, which an
--- empty table cannot: `{}` is ambiguous between an object and a list, and the
--- encoder writes an object.
---
--- Both are lua-cjson's own values rather than copies of them, because a
--- sentinel is compared by identity and a second null of this module's own
--- would be a bug factory: `tecs.data.null == require("cjson").null` and either
--- spelling tests the same thing.
---
--- The sentinels and the settings keep lua-cjson's own spelling, `empty_array`
--- and `encode_escape_forward_slash` among them, rather than this tree's
--- camelCase: they are that library's API, and renaming them would leave its
--- documentation describing names that do not exist here.
---
--- ## Compression
---
--- Binary asset formats store their bulk payload compressed, and the engine has
--- to read them. Games also write compressed save data, replays, caches and
--- network payloads, and those bytes need the matching encoder rather than a
--- private compressor in each caller.
---
--- **zlib does both.** It is pinned, generated into `tecs.ffi.zlib`, carried
--- through the ABI check and loaded the same way every other native library is,
--- because the engine exposes DEFLATE as a public byte service. Once it is in the
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
---
--- ## Hashing
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
--- checksum is fixed by the format rather than chosen. The compressors above
--- hand zlib whole streams, so the trailer is verified inside zlib and nothing
--- here sits on that path. Adler-32 is offered anyway, because it is a hash
--- function and it is the one RFC 1950 names: a caller holding a stream it has
--- not inflated, or bytes that came out of one by some other route, wants a way
--- to check the two against each other. It is zlib's implementation, since zlib
--- is a pinned dependency of this tree and is thirteen times faster over the
--- same bytes.
---
--- **`fnv1a64` is not an integrity primitive.** Sixty-four bits puts an
--- accidental collision far beyond anything a build will produce, and puts a
--- deliberate one within reach of anyone who wants one. Establishing that a
--- downloaded asset is the asset that was published is a different question
--- with a different answer: a cryptographic digest over the bytes and a
--- signature over the manifest that lists them. Nothing here asks that
--- question yet, so nothing here answers it, and the day something does it
--- gets its own function rather than a wider version of this one.

local ffi <const> = require("ffi")
local bit <const> = require("bit")
local loader <const> = require("tecs.ffi.loader")
local zlib <const> = require("tecs.ffi.zlib")

-- The parser and encoder are C, from `vendor/cjson`, and the build produces
-- them twice: linked into the host, where `require("cjson")` is answered from
-- `package.preload`, and as `lib/cjson.so`, which a plain interpreter has to
-- find on `package.cpath`. A command line tool built on this ECS runs the
-- second way, and the default `cpath` reaches whatever the system happens to
-- have installed rather than the copy shipped beside the Lua.
--
-- So the tree's own library directories go on the front of `cpath` before the
-- module is asked for. Ahead of the default rather than behind it: a
-- system-wide cjson of some other version otherwise answers first and the
-- pinned copy is never the one that runs. Under the host `package.preload`
-- wins whatever `cpath` says, and none of this is consulted.
--
-- The directories come from the loader, so where this build put its native
-- code is described once. Entries there carrying `%s` are `ffi.load` patterns
-- for a named dependency and match no Lua module, so they are skipped. The
-- suffix is `.so` on every platform, because that is what CMake sets on the
-- module rather than what the platform would pick.
local candidates: {string} = {}
for _, directory in ipairs(loader.searchPaths) do
    if not directory:find("%%s") then
        candidates[#candidates + 1] = directory .. "?.so"
    end
end
candidates[#candidates + 1] = package.cpath
package.cpath = table.concat(candidates, ";")

--- JSON encoding and decoding, and the sentinels and settings lua-cjson carries
--- with them.
---
--- An interface rather than a record, because `newJSON` answers with a table
--- carrying exactly these while the module carries them and compression and
--- hashing besides. One declaration, two things held to it, and no way for the
--- two to drift.
local interface JSON
    --- A value standing for something a Lua table cannot express: `null` and
    --- `empty_array`, and nothing else.
    ---
    --- Opaque, and named rather than typed. It is a C light userdata, which
    --- Teal has no name for, and the only things done with one are `==` and
    --- putting it in a payload beside values of every other type. A record
    --- would make `#rows > 0 and rows or data.empty_array`, which is how the
    --- sentinel is nearly always reached, fail to type-check for expressing
    --- exactly what it is for.
    type Sentinel = any

    --- Encodes a Lua value as JSON text.
    ---
    --- Raises on a value JSON has no form for: a function, a coroutine, a
    --- cdata, or a number that is NaN or infinite unless
    --- `encode_invalid_numbers` says otherwise. A table is an array when its
    --- keys run `1..n` and an object otherwise, so an empty one is an object
    --- and `empty_array` is how to say the other thing.
    ---
    --- @param value Any Lua value JSON has a form for. Reached recursively, so
    ---     a table holding itself raises at `encode_max_depth` rather than
    ---     running out of stack.
    --- @return The document, compact unless `encode_indent` says otherwise.
    encodeJSON: function(value: any): string

    --- Decodes JSON text into a Lua value.
    ---
    --- @param text A whole document. Objects and arrays both answer as tables,
    ---     and a JSON null answers as `null`.
    --- @return The value. Raises on malformed input rather than returning nil,
    ---     the empty string included, so code that expects to be handed rubbish
    ---     wraps this in `pcall`.
    decodeJSON: function(text: string): any

    --- JSON `null`, which is not `nil`.
    ---
    --- A decoded object keeps a key whose value was null and gives it this,
    --- so an absent key and a null one stay apart: `value.name == nil` is
    --- absent and `value.name == data.null` is null. Encoding it writes
    --- `null` back, which is how a field says that it was asked and the
    --- answer is nothing:
    ---
    ---     return {world = worldContext() or data.null}
    null: Sentinel

    --- A value that encodes as `[]`.
    ---
    --- An empty Lua table has no distinguishable encoding, so a field that is
    --- sometimes a list comes back as `{}` exactly when it is empty, and a
    --- client parsing it strictly rejects it. Say which one is meant:
    ---
    ---     return {rows = #rows > 0 and rows or data.empty_array}
    empty_array: Sentinel

    --- Metatable marking a table as an array whatever it holds.
    ---
    --- What `empty_array` is for a value nobody fills in, this is for a table
    --- that is built and may come out empty: `setmetatable(rows, array_mt)`
    --- once, and it encodes as a list whether or not anything went in. The
    --- encoder then writes `#rows` entries and skips its sparse-array check,
    --- so a table with a hole is truncated at the hole rather than raising.
    array_mt: metatable<{any}>

    --- Metatable turning an otherwise empty table into `[]`.
    ---
    --- Reached only once the table has been found to hold no entries at
    --- `1..n`, so it settles the empty case and changes nothing else. Set it
    --- rather than `array_mt` on a table that will be filled and might not
    --- be, when keeping the sparse-array check matters.
    empty_array_mt: metatable<{any}>

    --- Whether `{}` encodes as an object rather than as `[]`. On by default.
    ---
    --- Every setting reads the same way: called with no argument it answers
    --- the current value, called with one it sets it and answers the new one.
    --- They are process-wide, which is what `newJSON` exists to escape.
    ---
    --- @param setting Omitted only reads. A string is read as a boolean, which
    ---     is how lua-cjson takes a setting out of a configuration file.
    --- @return The setting after the call.
    encode_empty_table_as_object: function(setting?: boolean | string): boolean

    --- Whether a decoded array carries `array_mt`, so that it re-encodes as a
    --- list even when it decoded empty. Off by default.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    decode_array_with_array_mt: function(setting?: boolean | string): boolean

    --- Whether `/* ... */` and `// ...` are tolerated in input. Off by
    --- default, since neither is JSON.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    decode_allow_comment: function(setting?: boolean | string): boolean

    --- Whether a sparse array is converted to an object rather than raising,
    --- and when an array counts as sparse.
    ---
    --- @param convert Omitted only reads, and reads all three.
    --- @param ratio The multiple of the entry count that the largest index may
    ---     reach before the array is called sparse. 2 by default.
    --- @param safe A largest index below which an array never counts as
    ---     sparse. 10 by default.
    --- @return Whether conversion is on, off by default.
    --- @return The ratio after the call.
    --- @return The safe bound after the call.
    encode_sparse_array: function(
        convert?: boolean | string, ratio?: integer, safe?: integer
    ): boolean, integer, integer

    --- Nesting the encoder accepts before raising. 1000 by default.
    ---
    --- @param depth Omitted only reads.
    --- @return The depth after the call.
    encode_max_depth: function(depth?: integer): integer

    --- Nesting the decoder accepts before raising. 1000 by default, and what
    --- keeps a hostile document from exhausting the C stack.
    ---
    --- @param depth Omitted only reads.
    --- @return The depth after the call.
    decode_max_depth: function(depth?: integer): integer

    --- Significant digits written for a number. 14 by default, which is what
    --- keeps an entity id exact rather than writing it back as `1.0`.
    ---
    --- @param precision Omitted only reads. 1 to 14.
    --- @return The precision after the call.
    encode_number_precision: function(precision?: integer): integer

    --- Whether the encode buffer is kept between calls rather than freed. On
    --- by default: it trades a resident buffer for not reallocating one per
    --- encode.
    ---
    --- @param keep Omitted only reads.
    --- @return The setting after the call.
    encode_keep_buffer: function(keep?: boolean | string): boolean

    --- What NaN and infinity encode as. Off by default, which raises;
    --- `"null"` writes them as null, and on writes them as `NaN` and
    --- `Infinity`, which no other parser reads.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call, which is `"null"` rather than a
    ---     boolean when that is what is in force.
    encode_invalid_numbers: function(setting?: boolean | string): boolean | string

    --- Whether `nan` and `inf` are accepted in input. On by default.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    decode_invalid_numbers: function(setting?: boolean | string): boolean

    --- Whether `/` is written as `\/`. On by default.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    encode_escape_forward_slash: function(setting?: boolean | string): boolean

    --- Whether a value JSON has no form for is skipped rather than raising.
    --- Off by default, and worth leaving off: skipping is how a field goes
    --- missing from a payload with nothing said about it.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    encode_skip_unsupported_value_types: function(setting?: boolean | string): boolean

    --- Indent string for pretty output. Unset, and by default, the encoder
    --- writes compact JSON.
    ---
    --- @param indent Omitted only reads. Whitespace, one level's worth.
    --- @return The indent after the call.
    encode_indent: function(indent?: string): string

    --- An independent JSON table with its own settings.
    ---
    --- The settings above are process-wide, so code that has to change one
    --- without changing it for everybody takes a copy.
    ---
    --- @return A table carrying every name here and none of the compression or
    ---     hashing `tecs.data` also holds, since those have nothing to
    ---     configure. The sentinels are shared with every copy, as identity is
    ---     the whole point of them.
    newJSON: function(): JSON

    --- The library's own name, `"cjson"`.
    _NAME: string

    --- The library's version.
    _VERSION: string
end

--- JSON, compression and hashing, over byte strings.
---
--- The JSON half arrives from lua-cjson through `adopt` at the foot of this
--- file; the two below it are written here.
local record data is JSON
end

local C <const> = zlib.C
local K <const> = zlib.K

--- The three entry points, typed. The bindings are open namespaces, so the
--- signature is declared here rather than inferred, the way `hash.tl` does it.
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

--- Validates and normalizes a compression level. Minus one asks zlib for its
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
function data.deflateRaw(bytes: string, level?: integer): string
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
function data.deflate(bytes: string, level?: integer): string
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
--- @param bytes The whole stream, compressed. An empty string raises, since it is not one.
--- @param sizeHint The decompressed size, when the caller's format records it.
---     Only an allocation hint: a wrong one costs a copy, never an error.
--- @return The decompressed bytes, which may be empty. Never nil: a stream that does not
---     decode raises.
function data.inflateRaw(bytes: string, sizeHint?: integer): string
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
--- @param bytes The whole stream, header and Adler-32 trailer included. An empty string
---     raises, since it is not one.
--- @param sizeHint The decompressed size, when the caller's format records it.
---     Only an allocation hint: a wrong one costs a copy, never an error.
--- @return The decompressed bytes, which may be empty. Never nil: a bad header, a corrupt
---     block, a truncated stream and a trailer that disagrees all raise.
function data.inflate(bytes: string, sizeHint?: integer): string
    if #bytes == 0 then
        error("tecs: an empty string is not a zlib stream", 2)
    end
    local result, reason = run(bytes, WINDOW_BITS, sizeHint)
    if result == nil then
        error(reason, 2)
    end
    return result
end

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

--- FNV-1a over the bytes of `text`, 64-bit, as sixteen lowercase hex digits.
---
--- @param text Any string. NUL and bytes above 127 hash like any other.
--- @return Sixteen hex digits, high half first, so hashes sort as their values
---     do and two of them compare as strings.
function data.fnv1a64(text: string): string
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
function data.adler32(text: string): integer
    return tonumber(adler32(1, text, #text)) as integer
end

--- CRC-32 over the bytes of `text`, as a number in [0, 2^32).
---
--- The checksum PNG, gzip and ZIP put beside compressed bytes. It detects
--- accidental corruption and is not a cryptographic digest; use it only where
--- a format specifies CRC-32 or where an error-detecting checksum is enough.
function data.crc32(text: string): integer
    return tonumber(crc32(0, text, #text)) as integer
end

--- What comes straight off lua-cjson under the name that library gives it.
---
--- Listed rather than copied wholesale, so a member the library gains does not
--- appear on the public surface unannounced, and one it drops is a nil this
--- file can be searched for rather than a name that quietly stops resolving.
local CARRIED <const>: {string} = {
    "null",
    "empty_array",
    "array_mt",
    "empty_array_mt",
    "encode_empty_table_as_object",
    "decode_array_with_array_mt",
    "decode_allow_comment",
    "encode_sparse_array",
    "encode_max_depth",
    "decode_max_depth",
    "encode_number_precision",
    "encode_keep_buffer",
    "encode_invalid_numbers",
    "decode_invalid_numbers",
    "encode_escape_forward_slash",
    "encode_skip_unsupported_value_types",
    "encode_indent",
    "_NAME",
    "_VERSION",
}

--- Fills `into` with one lua-cjson table's members under this module's names.
---
--- Runs twice over: once onto the record below, which is what this module
--- returns, and once per `newJSON` onto a fresh table with settings of its own.
local function adopt(into: {string: any}, library: {string: any}): JSON
    for _, name in ipairs(CARRIED) do
        into[name] = library[name]
    end
    into.encodeJSON = library.encode
    into.decodeJSON = library.decode
    into.newJSON = function(): JSON return adopt({}, (library.new as function(): {string: any})()) end
    return into as JSON
end

adopt(data as {string: any}, require("cjson") as {string: any})

return data
