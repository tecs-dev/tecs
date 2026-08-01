--[=[
Typed stores, JSON, UTF-8, UUIDs, hashes, and checksums.

## JSON

Encode and decode complete documents:

```teal
local text <const> = tecs.data.encodeJSON({
    jsonrpc = "2.0",
    id = 1,
    result = {entities = {12, 24, 36}},
})
local value <const> = tecs.data.decodeJSON(text)
```

Both functions raise on invalid input. Protect untrusted documents with
`pcall`.

Lua needs sentinels for two JSON values:

```teal
local value <const> =
    tecs.data.decodeJSON('{"name":null,"rows":[]}')

assert(value.name == tecs.data.null)

local rows <const> = setmetatable({}, tecs.data.array_mt)
return tecs.data.encodeJSON({rows = rows})
```

`null` preserves a present key whose JSON value equals null. An empty Lua
table normally encodes as an object; `empty_array` and `array_mt` express an
empty list. `newJSON` creates an independent configuration for protocols that
must not share process-wide settings.

The sentinel and option names retain lua-cjson spelling because they belong to
that library's compatibility surface.

## UUIDs

Generate RFC 9562 identifiers without a central allocator:

```teal
local objectId <const> = tecs.data.uuid4()
local eventId <const> = tecs.data.uuid7()
```

`uuid4` draws its random bits from the operating system. `uuid7` starts with
the current Unix timestamp in milliseconds and orders calls made by this
process, which makes it suitable for identifiers stored in an ordered index.
Both return the canonical lowercase 8-4-4-4-12 representation.

UUIDs identify values; they do not authenticate a player or make an
unguessable credential.

## UTF-8

Codepoint operations live under `tecs.data.utf8`:

```teal
local utf8 <const> = tecs.data.utf8
local codepoint, nextOffset = utf8.decodeAt("A€", 2)
assert(codepoint == 0x20ac)
assert(nextOffset == 5)
```

The child works over explicit byte lengths in strings and ByteViews, so
embedded NUL is U+0000 rather than a terminator. Malformed bytes decode as
U+FFFD and remain traversable. These are codepoint operations, not grapheme
segmentation.

## Hashes and checksums

`fnv1a64` supplies fast process and build identity as 16 lowercase hexadecimal
digits. `sha256` supplies a cryptographic digest as 64 lowercase hexadecimal
digits. `adler32` and `crc32` implement checksums required by formats that
name them. Pass the checksum from one call as the second argument to continue
over the next chunk without joining the chunks into one string:

```teal
local checksum = tecs.data.crc32(header)
checksum = tecs.data.crc32(body, checksum)
```

SHA-256 authenticates nothing by itself. Verify downloaded artifacts against a
digest obtained through a trusted channel or a signed manifest.

## Typed stores

Create typed keys once and use them with independent stores:

```teal
local SPEED <const>: tecs.data.Key<number> =
    tecs.data.Store.newKey("game.speed")
local store <const> = tecs.data.newStore()
store[SPEED] = 120
```

`world.resources` is a `Store`. Stores are in-memory and independent; a named
key is the process-wide identity that lets hot reload and tooling find the same
value again. `Store.listKeys` reports the named keys registered by the process.
]=]

local ffi <const> = require("ffi")
local bit <const> = require("bit")
local loader <const> = require("tecs.ffi.loader")
local binding <const> = require("tecs.ffi.rust")
local zlib <const> = require("tecs.ffi.zlib")
local type ioTypes = require("tecs.io.types")
local type utf8Module = require("tecs.data.utf8")
local storekeys <const> = require("tecs.internal.storekeys")
local type ByteView = ioTypes.ByteView
local type ByteInput = string | ByteView

-- Implementation details: The parser and encoder are C, from `vendor/cjson`,
-- and the build produces them twice: linked into the host, where
-- `require("cjson")` is answered from `package.preload`, and as
-- `lib/cjson.so`, which a plain interpreter has to find on `package.cpath`.
-- A command line tool built on this ECS runs the second way, and the default
-- `cpath` reaches whatever the system happens to have installed rather than
-- the copy shipped beside the Lua.
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
-- suffix is `.so` on every platform, because that is what the Cargo build sets on the
-- module rather than what the platform would pick.
local candidates: {string} = {}
for _, directory in ipairs(loader.searchPaths) do
    if not directory:find("%%s") then
        candidates[#candidates + 1] = directory .. "?.so"
    end
end
candidates[#candidates + 1] = package.cpath
package.cpath = table.concat(candidates, ";")

--- Defines JSON encoding, decoding, sentinels and settings.
---
--- An interface rather than a record, because `newJSON` answers with a table
--- carrying exactly these while the module also carries identities, UTF-8,
--- and typed stores. One declaration keeps both JSON tables from drifting.
local interface JSON
    --- Represents `null` and `empty_array`, which Lua tables cannot express.
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
    ---     the empty string included, so code that accepts untrusted input
    ---     wraps this in `pcall`.
    decodeJSON: function(text: string): any

    --- Read-only. Represents JSON `null`, which is not `nil`.
    ---
    --- The decoder keeps a key whose JSON value equals null and gives it this,
    --- so an absent key and a null one stay apart: `value.name == nil` is
    --- absent and `value.name == data.null` is null. Encoding it writes
    --- `null` back, which says the field is present with no value:
    ---
    ---     return {world = worldContext() or data.null}
    null: Sentinel

    --- Read-only. Provides a value that encodes as `[]`.
    ---
    --- An empty Lua table has no distinguishable encoding, so a field that is
    --- sometimes a list comes back as `{}` exactly when it is empty, and a
    --- client parsing it strictly rejects it. Say which one is meant:
    ---
    ---     return {rows = #rows > 0 and rows or data.empty_array}
    empty_array: Sentinel

    --- Read-only. Provides a metatable that marks a table as an array whatever
    --- it holds.
    ---
    --- What `empty_array` is for a value nobody fills in, this is for a table
    --- that code builds and may leave empty: `setmetatable(rows, array_mt)`
    --- once, and it encodes as a list whether or not anything went in. The
    --- encoder then writes `#rows` entries and skips its sparse-array check,
    --- so the encoder truncates a table with a hole at that hole rather than raising.
    array_mt: metatable<{any}>

    --- Read-only. Provides a metatable that turns an otherwise empty table
    --- into `[]`.
    ---
    --- The encoder reaches this only after finding no entries at `1..n`, so
    --- it settles the empty case and changes nothing else. Set it rather than
    --- `array_mt` on a table you may fill when keeping the sparse-array
    --- check matters.
    empty_array_mt: metatable<{any}>

    --- Reads or sets whether `{}` encodes as an object rather than as `[]`.
    --- The setting defaults to on.
    ---
    --- Every setting reads the same way: called with no argument it answers
    --- the current value, called with one it sets it and answers the new one.
    --- They are process-wide, which is what `newJSON` exists to escape.
    ---
    --- @param setting Omitted only reads. A string is read as a boolean, which
    ---     is how lua-cjson takes a setting out of a configuration file.
    --- @return The setting after the call.
    encode_empty_table_as_object: function(setting?: boolean | string): boolean

    --- Reads or sets whether a decoded array carries `array_mt`, so it
    --- re-encodes as a list even when it decoded empty. The setting defaults
    --- to off.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    decode_array_with_array_mt: function(setting?: boolean | string): boolean

    --- Reads or sets whether input accepts `/* ... */` and `// ...` comments.
    --- The setting defaults to off because neither form belongs to JSON.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    decode_allow_comment: function(setting?: boolean | string): boolean

    --- Reads or sets sparse-array conversion and its thresholds.
    ---
    --- @param convert Omitted only reads, and reads all three.
    --- @param ratio The multiple of the entry count that the largest index may
    ---     reach before the encoder treats the array as sparse. 2 by default.
    --- @param safe A largest index below which an array never counts as
    ---     sparse. 10 by default.
    --- @return Whether conversion is on, off by default.
    --- @return The ratio after the call.
    --- @return The safe bound after the call.
    encode_sparse_array: function(
        convert?: boolean | string, ratio?: integer, safe?: integer
    ): boolean, integer, integer

    --- Reads or sets the nesting depth the encoder accepts before raising.
    --- The setting defaults to 1000.
    ---
    --- @param depth Omitted only reads.
    --- @return The depth after the call.
    encode_max_depth: function(depth?: integer): integer

    --- Reads or sets the nesting depth the decoder accepts before raising.
    --- The setting defaults to 1000 and keeps a hostile document from
    --- exhausting the C stack.
    ---
    --- @param depth Omitted only reads.
    --- @return The depth after the call.
    decode_max_depth: function(depth?: integer): integer

    --- Reads or sets the significant digits written for a number. The setting
    --- defaults to 14, which keeps an entity id exact rather than writing it
    --- back as `1.0`.
    ---
    --- @param precision Omitted only reads. 1 to 14.
    --- @return The precision after the call.
    encode_number_precision: function(precision?: integer): integer

    --- Reads or sets whether the encoder keeps its buffer between calls. The
    --- setting defaults to on and trades a resident buffer for avoiding one
    --- allocation per encode.
    ---
    --- @param keep Omitted only reads.
    --- @return The setting after the call.
    encode_keep_buffer: function(keep?: boolean | string): boolean

    --- Reads or sets what NaN and infinity encode as. Off by default, which raises;
    --- `"null"` writes them as null, and on writes them as `NaN` and
    --- `Infinity`, which no other parser reads.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call, which is `"null"` rather than a
    ---     boolean when that is what is in force.
    encode_invalid_numbers: function(setting?: boolean | string): boolean | string

    --- Reads or sets whether input accepts `nan` and `inf`. The setting
    --- defaults to on.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    decode_invalid_numbers: function(setting?: boolean | string): boolean

    --- Reads or sets whether the encoder writes `/` as `\/`. The setting
    --- defaults to on.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    encode_escape_forward_slash: function(setting?: boolean | string): boolean

    --- Reads or sets whether the encoder skips values JSON cannot represent
    --- rather than raising.
    --- Off by default, and worth leaving off: skipping is how a field goes
    --- missing from a payload with nothing said about it.
    ---
    --- @param setting Omitted only reads.
    --- @return The setting after the call.
    encode_skip_unsupported_value_types: function(setting?: boolean | string): boolean

    --- Reads or sets the indentation string for pretty output. The encoder
    --- writes compact JSON by default.
    ---
    --- @param indent Omitted only reads. Whitespace, one level's worth.
    --- @return The indent after the call.
    encode_indent: function(indent?: string): string

    --- Creates an independent JSON table with its own settings.
    ---
    --- The settings above are process-wide, so code that has to change one
    --- without changing it for everybody takes a copy.
    ---
    --- @return A table carrying every JSON name here and none of the other
    ---     `tecs.data` operations, since those have nothing to configure.
    ---     Every copy shares the sentinels because identity is the whole
    ---     point of them.
    newJSON: function(): JSON

    --- Read-only. Contains the library name, `"cjson"`.
    _NAME: string

    --- Read-only. Contains the library version.
    _VERSION: string
end

-- Implementation details: `adopt` adds lua-cjson's JSON interface to the
-- identities and stores defined here.
local record data is JSON
    --- Read-only. `utf8` provides UTF-8 codepoint operations over Lua byte
    --- strings.
    utf8: utf8Module

    --- `Key` identifies one typed store value across every store in the
    --- process.
    interface Key<T>
    end

    --- `Store` holds typed values under process-wide keys and exposes their
    --- process-wide registry.
    record Store
        --- Creates a typed key.
        ---
        --- Always pass a name. Named keys are discoverable through `findKey`
        --- and `listKeys`, and repeating a name returns the same key so values
        --- remain reachable when a module reloads.
        ---
        --- @param name The namespaced identity, such as
        ---     `"game.state"`. Omitting it creates an anonymous key and warns.
        --- @param forType Pass `nil as T` when Teal needs the value type
        ---     carried explicitly. The function does not read it.
        --- @return Returns the stable key for a name or a fresh anonymous key.
        newKey: function<T>(name?: string, forType?: T): Key<T>

        --- Returns a named key created by `newKey`.
        ---
        --- @param name The name used during key creation.
        --- @return Returns the existing key, or nil before any module creates it.
        findKey: function<T>(name: string): Key<T> | nil

        --- Returns all named keys as name-to-id entries.
        ---
        --- @return Returns a fresh process-wide table.
        listKeys: function(): {string: integer}

        --- Returns the value associated with a typed key. An unwritten key
        --- returns nil.
        ---
        --- ```teal
        --- local SPEED <const>: tecs.data.Key<number> =
        ---     tecs.data.Store.newKey("game.speed")
        --- local store <const> = tecs.data.newStore()
        --- local speed <const> = store[SPEED]
        --- ```
        ---
        --- @param self The Store to index.
        --- @param key The Key used to retrieve its value.
        --- @return Returns the value for `key`, or nil when no value has been
        ---     assigned.
        metamethod __index: function<T>(self: Store, key: Key<T>): T

        --- Associates a value with a typed key. Assigning nil removes the
        --- value.
        ---
        --- ```teal
        --- local SPEED <const>: tecs.data.Key<number> =
        ---     tecs.data.Store.newKey("game.speed")
        --- local store <const> = tecs.data.newStore()
        --- store[SPEED] = 120
        --- ```
        ---
        --- @param self The Store to index.
        --- @param key The Key used to associate the value.
        --- @param value The value to associate with `key`. Passing nil removes
        ---     the association.
        metamethod __newindex: function<T>(self: Store, key: Key<T>, value: T)
    end

    --- `ByteInput` accepts a Lua byte string or an open Buffer or ByteView.
    type ByteInput = ByteInput

    --- Creates an independent typed store.
    ---
    --- @return Returns an empty store. You own it and its values.
    newStore: function(): Store

    --- Generates a random RFC 9562 UUID version 4.
    ---
    --- @return Returns a fresh UUID in canonical lowercase 8-4-4-4-12 form.
    uuid4: function(): string

    --- Generates a time-ordered RFC 9562 UUID version 7.
    ---
    --- Calls made by this process remain ordered even when more than one falls
    --- in the same millisecond. The timestamp makes the result unsuitable for
    --- hiding when an identifier was created.
    ---
    --- @return Returns a fresh UUID in canonical lowercase 8-4-4-4-12 form.
    uuid7: function(): string
end

function data.newStore(): data.Store
    return {} as data.Store
end

data.Store.newKey = storekeys.newKey as function<T>(name?: string, forType?: T): data.Key<T>
data.Store.findKey = storekeys.findKey as function<T>(name: string): data.Key<T> | nil
data.Store.listKeys = storekeys.listKeys

local floor <const> = math.floor

local record ByteRange
    pointer: loader.BytePointer
    length: integer
    owner: ByteInput
end

local function byteRange(value: ByteInput, what: string, level: integer): ByteRange
    if type(value) == "string" then
        local text <const> = value as string
        return {
            pointer = ffi.cast("uint8_t *", text) as loader.BytePointer,
            length = #text,
            owner = text,
        }
    end
    local dynamic <const> = value as {string: any}
    if
        type(value) ~= "table"
        or type(dynamic.length) ~= "function"
        or type(dynamic.getFFIPointer) ~= "function"
        or type(dynamic.isReleased) ~= "function"
        or (dynamic.isReleased as function(any): boolean)(value)
    then
        error(("tecs: %s needs a byte string or open io.Buffer or io.ByteView"):format(what), level)
    end
    return {
        pointer = (dynamic.getFFIPointer as function(any): loader.BytePointer)(value),
        length = (dynamic.length as function(any): integer)(value),
        owner = value,
    }
end

local R <const> = binding.C

local uuidText <const> = loader.newArray("char[37]")
local generateUUID4 <const> = R.tecsUuid4 as function(loader.CArray): boolean
local generateUUID7 <const> = R.tecsUuid7 as function(loader.CArray): boolean

local function generateUUID(generate: function(loader.CArray): boolean): string
    if not generate(uuidText) then
        error("UUID output buffer is unavailable", 2)
    end
    return loader.toString(uuidText as loader.CValue)
end

function data.uuid4(): string
    return generateUUID(generateUUID4)
end

function data.uuid7(): string
    return generateUUID(generateUUID7)
end

local record U64
    metamethod __mul: function(self: U64, other: U64): U64
end

-- LuaJIT widens bit operations to 64 bits for cdata. These declarations
-- specialize a library otherwise typed over Lua numbers.
local u64 <const> = ffi.typeof("uint64_t") as function(value: number): U64
local bxor <const> = bit.bxor as function(value: U64, byte: integer): U64
local lshift <const> = bit.lshift as function(value: U64, bits: integer): U64
local bor <const> = bit.bor as function(value: U64, other: number): U64
local tohex <const> = bit.tohex as function(value: U64, digits: integer): string

-- FNV-1a's 64-bit prime and offset basis, assembled from exact 32-bit halves.
local PRIME <const> = bor(lshift(u64(0x100), 32), 0x1b3)
local BASIS <const> = bor(lshift(u64(0xcbf29ce4), 32), 0x84222325)

-- The `_z` checksum forms accept `z_size_t`, so a string past 4 GB cannot wrap
-- a 32-bit length. LuaJIT returns their `uLong` result as cdata.
local adler32 <const> = zlib.C.adler32_z as function(
    seed: integer, bytes: loader.CValue, length: integer
): loader.CValue
local crc32 <const> = zlib.C.crc32_z as function(seed: integer, bytes: loader.CValue, length: integer): loader.CValue
local MAX_U32 <const> = 4294967295

local function checksumSeed(previous: integer, algorithm: string): integer
    if previous < 0 or previous > MAX_U32 or previous ~= floor(previous) then
        error(("tecs: %s previous checksum must be an unsigned 32-bit integer"):format(algorithm), 3)
    end
    return previous
end

local sha256Text <const> = loader.newArray("char[65]")
local sha256 <const> = R.tecsSha256 as function(bytes: loader.CValue, length: integer, output: loader.CArray): boolean

--- FNV-1a over the bytes of `text`, 64-bit, as sixteen lowercase hex digits.
---
--- @param text A byte string or open
---     [`ByteView`](tealdoc:tecs.io.ByteView). NUL and bytes above 127 hash like any other.
--- @return Sixteen hex digits, high half first, so hashes sort as their values
---     do and two of them compare as strings.
function data.fnv1a64(text: ByteInput): string
    local input <const> = byteRange(text, "fnv1a64", 2)
    local state = BASIS
    for index = 0, input.length - 1 do
        state = bxor(state, input.pointer[index] as integer) * PRIME
    end
    return tohex(state, 16)
end

--- Computes SHA-256 over the bytes of `text`.
---
--- SHA-256 detects whether bytes match a trusted digest. It does not prove who
--- supplied either value, so artifact verification obtains the expected
--- digest through a trusted channel or a signed manifest.
---
--- @param text A byte string or open
---     [`ByteView`](tealdoc:tecs.io.ByteView). NUL and bytes above 127 hash like any other.
--- @return Sixty-four lowercase hexadecimal digits, high byte first.
function data.sha256(text: ByteInput): string
    local input <const> = byteRange(text, "sha256", 2)
    if not sha256(input.pointer as loader.CValue, input.length, sha256Text) then
        error("SHA-256 output buffer is unavailable", 2)
    end
    return loader.toString(sha256Text as loader.CValue)
end

--- Computes Adler-32 over the bytes of `text` as a number in [0, 2^32).
---
--- The checksum RFC 1950 puts in a zlib stream's trailer, which is the only
--- reason it is here. It is a poor content hash and is not offered as one: it
--- is a sum of a sum, it barely mixes on short inputs, and two files that
--- differ by reordering equal-length runs collide outright. Use `fnv1a64` for
--- identity and this only for the format that specifies it.
---
--- zlib computes it. The seed is 1, which is what RFC 1950 starts from and
--- what zlib's own documentation says to pass for the first call. Pass the
--- return value back as `previous` to continue the checksum over another
--- chunk. An empty chunk leaves `previous` unchanged.
---
--- @param text A byte string or open
---     [`ByteView`](tealdoc:tecs.io.ByteView). NUL and bytes above 127
---     contribute like any other.
--- @param previous The checksum returned after all preceding bytes. Omit it
---     for the first chunk. Raises unless it is an unsigned 32-bit integer.
--- @return The checksum after `text`, as an exact Lua number in [0, 2^32).
function data.adler32(text: ByteInput, previous?: integer): integer
    local input <const> = byteRange(text, "adler32", 2)
    local seed = 1
    if previous ~= nil then
        seed = checksumSeed(previous, "adler32")
    end
    return tonumber(adler32(seed, input.pointer as loader.CValue, input.length)) as integer
end

--- Computes CRC-32 over the bytes of `text` as a number in [0, 2^32).
---
--- The checksum PNG, gzip and ZIP put beside compressed bytes. It detects
--- accidental corruption and is not a cryptographic digest; use it only where
--- a format specifies CRC-32 or where an error-detecting checksum is enough.
--- Pass the return value back as `previous` to continue the checksum over
--- another chunk. An empty chunk leaves `previous` unchanged.
---
--- @param text A byte string or open
---     [`ByteView`](tealdoc:tecs.io.ByteView). NUL and bytes above 127
---     contribute like any other.
--- @param previous The checksum returned after all preceding bytes. Omit it
---     for the first chunk. Raises unless it is an unsigned 32-bit integer.
--- @return The checksum after `text`, as an exact Lua number in [0, 2^32).
function data.crc32(text: ByteInput, previous?: integer): integer
    local input <const> = byteRange(text, "crc32", 2)
    local seed = 0
    if previous ~= nil then
        seed = checksumSeed(previous, "crc32")
    end
    return tonumber(crc32(seed, input.pointer as loader.CValue, input.length)) as integer
end

-- Names adopted from lua-cjson. Listing them prevents upstream additions from
-- silently expanding the public surface and makes a removal searchable here.
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
