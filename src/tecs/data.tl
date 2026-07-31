--[=[
Typed stores, JSON, byte encodings, DEFLATE, text transcoding, UTF-8, UUIDs,
hashes, and checksums.

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

## Byte encodings

Encode bytes for a JSON field or command-line value and restore them later:

```teal
local encoded <const> = tecs.data.base64Encode("\0sprite bytes")
local bytes <const> = tecs.data.base64Decode(encoded)
assert(bytes == "\0sprite bytes")
```

Base64 uses the padded RFC 4648 alphabet. Hexadecimal output is lowercase;
the decoder accepts either ASCII letter case. Both decoders reject malformed
or non-canonical input rather than recovering a different byte sequence.

The sentinel and option names retain lua-cjson spelling because they belong to
that library's compatibility surface.

## DEFLATE

Use zlib-wrapped streams unless another format supplies framing and a
checksum:

```teal
local bytes <const> = "snapshot bytes"
local compressed <const> = tecs.data.deflate(bytes, 6)
local restored <const> = tecs.data.inflate(compressed, #bytes)
assert(restored == bytes)
```

`inflateRaw` and `deflateRaw` handle RFC 1951 blocks without a zlib header or
trailer. The decompressed-size argument provides an allocation hint. A wrong
hint may cost a copy but does not weaken validation.

Inflation raises on malformed, truncated, or dictionary-dependent streams.
Treat zlib error text as a diagnostic, not a string-matching interface.

## Character transcoding

Convert a complete byte string when an asset or protocol uses an encoding
other than UTF-8:

```teal
local utf8 <const> = tecs.data.transcode(utf16Bytes, "UTF-16", "UTF-8")
```

The input and result are byte strings. Embedded NULs are ordinary bytes, so
binary encodings such as UTF-16 and UTF-32 round-trip without truncation.
Conversion raises for an unknown encoding name. UTF-8 and explicitly ordered
UTF-16 and UTF-32 input is validated strictly; other encodings use the
platform converter's substitution rules.

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

The child works over explicit Lua string lengths, so embedded NUL is U+0000
rather than a terminator. Malformed bytes decode as U+FFFD and remain
traversable. These are codepoint operations, not grapheme segmentation.

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
    tecs.data.newKey("game.speed")
local store <const> = tecs.data.newStore()
store[SPEED] = 120
```

`world.resources` is a `Store`. Stores are in-memory and independent; a named
key is the process-wide identity that lets hot reload and tooling find the same
value again. `Key.listKeys` reports the named keys registered by the process.
]=]

local ffi <const> = require("ffi")
local bit <const> = require("bit")
local loader <const> = require("tecs.ffi.loader")
local binding <const> = require("tecs.ffi.rust")
local zlib <const> = require("tecs.ffi.zlib")
local type TypedStore = require("tecs.data.Store")
local transcode <const> = require("tecs.data.transcode")
local type utf8Module = require("tecs.data.utf8")
local storekeys <const> = require("tecs.internal.storekeys")

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
--- carrying exactly these while the module carries them and compression and
--- hashing besides. One declaration, two things held to it, and no way for the
--- two to drift.
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
    --- `null` back, which says the caller included the field with no value:
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
    --- `array_mt` on a table the caller may fill when keeping the sparse-array
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
    --- @return A table carrying every name here and none of the compression or
    ---     hashing `tecs.data` also holds, since those have nothing to
    ---     configure. Every copy shares the sentinels because identity is
    ---     the whole point of them.
    newJSON: function(): JSON

    --- Read-only. Contains the library name, `"cjson"`.
    _NAME: string

    --- Read-only. Contains the library version.
    _VERSION: string
end

-- Implementation details: `adopt` adds lua-cjson's JSON interface to the
-- compression and hashing functions defined here.
local record data is JSON
    --- Read-only. `utf8` provides UTF-8 codepoint operations over Lua byte
    --- strings.
    utf8: utf8Module

    --- `Store` holds typed values under process-wide keys.
    type Store = TypedStore

    --- `Key` identifies one typed store value and exposes key discovery.
    record Key<T> is TypedStore.Key<T>
        --- Returns all named keys as name-to-id entries.
        ---
        --- @return Returns a fresh caller-owned process-wide table.
        listKeys: function(): {string: integer}
    end

    --- Creates an independent typed store.
    ---
    --- @return Returns an empty store. The caller owns it and its values.
    newStore: function(): TypedStore

    --- Creates a typed key.
    ---
    --- Always pass a name. Named keys are discoverable through `findKey` and
    --- `Key.listKeys`, and repeating a name returns the same key so values
    --- remain reachable when a module reloads.
    ---
    --- @param name The caller supplies a namespaced identity such as
    ---     `"game.state"`. Omitting it creates an anonymous key and warns.
    --- @param forType The caller passes `nil as T` when Teal needs the value
    ---     type carried explicitly. The function does not read it.
    --- @return Returns the stable key for a name or a fresh anonymous key.
    newKey: function<T>(name?: string, forType?: T): Key<T>

    --- Returns a named key created by `newKey`.
    ---
    --- @param name The caller supplies the name used during key creation.
    --- @return Returns the existing key, or nil before any module creates it.
    findKey: function<T>(name: string): Key<T> | nil

    --- Encodes bytes as lowercase hexadecimal text.
    ---
    --- @param bytes The caller supplies arbitrary bytes, including NUL.
    --- @return Returns two lowercase ASCII hex digits for every input byte.
    hexEncode: function(bytes: string): string

    --- Decodes lowercase or uppercase hexadecimal text into bytes.
    ---
    --- @param text The caller supplies an even number of ASCII hex digits.
    --- @return Returns the decoded bytes. Raises when `text` has an odd
    ---     length or contains a character outside the hexadecimal alphabet.
    hexDecode: function(text: string): string

    --- Encodes bytes with the padded RFC 4648 Base64 alphabet.
    ---
    --- @param bytes The caller supplies arbitrary bytes, including NUL.
    --- @return Returns ASCII Base64 text. The result has no line breaks and
    ---     uses `=` padding when its length is not divisible by three.
    base64Encode: function(bytes: string): string

    --- Decodes canonical padded RFC 4648 Base64 text into bytes.
    ---
    --- @param text The caller supplies Base64 text in groups of four ASCII
    ---     characters. It must use standard `+` and `/` characters and
    ---     required `=` padding.
    --- @return Returns the decoded bytes. Raises when `text` has invalid
    ---     characters, malformed padding, or non-zero unused bits.
    base64Decode: function(text: string): string

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

    --- Converts a complete byte string between character encodings.
    ---
    --- Encoding names use the platform iconv spelling, such as `"UTF-8"`,
    --- `"UTF-16LE"` and `"ISO-8859-1"`; the names available beyond SDL's
    --- Unicode encodings depend on the platform. UTF-8 and explicitly ordered
    --- UTF-16 and UTF-32 input is validated strictly; other encodings use the
    --- platform converter's substitution rules. Conversion raises for an
    --- unsupported name, invalid Unicode input, or an incomplete final
    --- sequence. The input and result are binary-safe Lua strings; neither
    --- stops at an embedded NUL. Byte order for the unsuffixed `"UTF-16"` and
    --- `"UTF-32"` names is platform iconv behavior, so use an explicit `LE` or
    --- `BE` suffix when a file format fixes it.
    ---
    --- @param bytes A complete byte string in `fromEncoding`.
    --- @param fromEncoding The source encoding name. It must be non-empty and
    ---     contain no NUL.
    --- @param toEncoding The target encoding name. It must be non-empty and
    ---     contain no NUL.
    --- @return Returns a fresh byte string in `toEncoding`, including any NUL
    ---     bytes the target representation requires.
    transcode: function(bytes: string, fromEncoding: string, toEncoding: string): string
end

function data.newStore(): TypedStore
    return {} as TypedStore
end

data.newKey = storekeys.newKey as function<T>(name?: string, forType?: T): data.Key<T>
data.findKey = storekeys.findKey as function<T>(name: string): data.Key<T> | nil
data.Key.listKeys = storekeys.listKeys
data.transcode = transcode

local sbyte <const> = string.byte
local schar <const> = string.char
local ssub <const> = string.sub
local concat <const> = table.concat

local HEX <const> = "0123456789abcdef"
local BASE64 <const> = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local BASE64_DECODE <const>: {integer: integer} = {}
for index = 1, #BASE64 do
    BASE64_DECODE[sbyte(BASE64, index)] = index - 1
end

--- Encodes bytes as lowercase hexadecimal text.
---
--- @param bytes The caller supplies arbitrary bytes, including NUL.
--- @return Returns two lowercase ASCII hex digits for every input byte.
function data.hexEncode(bytes: string): string
    local output: {string} = {}
    for index = 1, #bytes do
        local byte <const> = sbyte(bytes, index)
        output[index] = ssub(HEX, math.floor(byte / 16) + 1, math.floor(byte / 16) + 1)
            .. ssub(HEX, byte % 16 + 1, byte % 16 + 1)
    end
    return concat(output)
end

local function hexValue(byte: integer): integer | nil
    if byte >= 48 and byte <= 57 then
        return byte - 48
    end
    if byte >= 65 and byte <= 70 then
        return byte - 65 + 10
    end
    if byte >= 97 and byte <= 102 then
        return byte - 97 + 10
    end
    return nil
end

--- Decodes lowercase or uppercase hexadecimal text into bytes.
---
--- @param text The caller supplies an even number of ASCII hex digits.
--- @return Returns the decoded bytes. Raises when `text` has an odd length or
---     contains a character outside the hexadecimal alphabet.
function data.hexDecode(text: string): string
    if #text % 2 ~= 0 then
        error("tecs: hexadecimal text must contain an even number of digits", 2)
    end
    local output: {string} = {}
    local outputIndex = 1
    for index = 1, #text, 2 do
        local high <const> = hexValue(sbyte(text, index))
        local low <const> = hexValue(sbyte(text, index + 1))
        if high == nil or low == nil then
            error("tecs: hexadecimal text contains a non-hexadecimal character", 2)
        end
        output[outputIndex] = schar(high * 16 + low)
        outputIndex = outputIndex + 1
    end
    return concat(output)
end

--- Encodes bytes with the padded RFC 4648 Base64 alphabet.
---
--- @param bytes The caller supplies arbitrary bytes, including NUL.
--- @return Returns ASCII Base64 text. The result has no line breaks and uses
---     `=` padding when its length is not divisible by three.
function data.base64Encode(bytes: string): string
    local output: {string} = {}
    local outputIndex = 1
    for index = 1, #bytes, 3 do
        local first <const> = sbyte(bytes, index)
        local second = sbyte(bytes, index + 1)
        local third = sbyte(bytes, index + 2)
        output[outputIndex] = ssub(BASE64, math.floor(first / 4) + 1, math.floor(first / 4) + 1)
        output[outputIndex + 1] = ssub(
            BASE64,
            first % 4 * 16 + math.floor((second or 0) / 16) + 1,
            first % 4 * 16 + math.floor((second or 0) / 16) + 1
        )
        output[outputIndex + 2] = second ~= nil
            and ssub(
                BASE64,
                second % 16 * 4 + math.floor((third or 0) / 64) + 1,
                second % 16 * 4 + math.floor((third or 0) / 64) + 1
            ) or "="
        output[outputIndex + 3] = third ~= nil and ssub(BASE64, third % 64 + 1, third % 64 + 1) or "="
        outputIndex = outputIndex + 4
    end
    return concat(output)
end

local function base64Value(byte: integer): integer
    local value <const> = BASE64_DECODE[byte]
    if value == nil then
        error("tecs: Base64 text contains a character outside the RFC 4648 alphabet", 3)
    end
    return value
end

--- Decodes canonical padded RFC 4648 Base64 text into bytes.
---
--- @param text The caller supplies Base64 text in groups of four ASCII
---     characters. It must use standard `+` and `/` characters and required
---     `=` padding.
--- @return Returns the decoded bytes. Raises when `text` has invalid
---     characters, malformed padding, or non-zero unused bits.
function data.base64Decode(text: string): string
    local length <const> = #text
    if length % 4 ~= 0 then
        error("tecs: Base64 text must contain groups of four characters", 2)
    end

    local output: {string} = {}
    local outputIndex = 1
    for index = 1, length, 4 do
        local first <const> = base64Value(sbyte(text, index))
        local second <const> = base64Value(sbyte(text, index + 1))
        local thirdByte <const> = sbyte(text, index + 2)
        local fourthByte <const> = sbyte(text, index + 3)
        local final <const> = index + 3 == length

        if thirdByte == 61 then
            if not final or fourthByte ~= 61 or second % 16 ~= 0 then
                error("tecs: Base64 text has malformed padding", 2)
            end
            output[outputIndex] = schar(first * 4 + math.floor(second / 16))
            outputIndex = outputIndex + 1
        else
            local third <const> = base64Value(thirdByte)
            output[outputIndex] = schar(first * 4 + math.floor(second / 16))
            outputIndex = outputIndex + 1
            if fourthByte == 61 then
                if not final or third % 4 ~= 0 then
                    error("tecs: Base64 text has malformed padding", 2)
                end
                output[outputIndex] = schar(second % 16 * 16 + math.floor(third / 4))
                outputIndex = outputIndex + 1
            else
                local fourth <const> = base64Value(fourthByte)
                output[outputIndex] = schar(second % 16 * 16 + math.floor(third / 4))
                output[outputIndex + 1] = schar(third % 4 * 64 + fourth)
                outputIndex = outputIndex + 2
            end
        end
    end
    return concat(output)
end

local C <const> = zlib.C
local K <const> = zlib.K
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

-- The bindings are open namespaces, so these declarations type the entry
-- points explicitly.
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

-- `inflateInit2_` compares the generated cdef version's major digit and this
-- build's exact `z_stream` size. A mismatch fails the call before a binding
-- corrupts memory through a struct of the wrong shape.
local VERSION <const> = loader.textConstants("zlib").ZLIB_VERSION
local STREAM_SIZE <const> = ffi.sizeof("z_stream") as integer

-- DEFLATE's largest window, 32 KB. Negating it asks `inflateInit2_` for the
-- raw form: no header, trailer, or checksum.
local WINDOW_BITS <const> = 15

-- The output starts with this many bytes when the caller gives no hint.
local INITIAL_CAPACITY <const> = 4096

-- Most output offered to one `inflate` call. `avail_out` is a `uInt`, so the
-- loop splits larger output rather than wrapping the count.
local MAX_CHUNK <const> = 0x40000000

-- Meanings for return codes that carry no zlib message.
local CODE_NAMES <const>: {integer: string} = {
    [K.Z_STREAM_ERROR] = "its state is inconsistent",
    [K.Z_DATA_ERROR] = "it is corrupt",
    [K.Z_MEM_ERROR] = "zlib could not allocate",
    [K.Z_VERSION_ERROR] = "the zlib in this process is not the one these " .. "bindings were generated against",
}

-- Captures a decode failure before `inflateEnd` changes the stream and returns
-- it so the public function can raise at its own caller.
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
--- zlib checks the header before decoding and the Adler-32 trailer afterwards.
--- Invalid framing therefore raises a zlib-stream error rather than an error
--- from some block inside it, and a mismatched trailer prevents any return.
---
--- The decoder refuses a preset dictionary rather than ignoring it. The flag means the
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

-- FNV-1a needs 64-bit arithmetic. FFI cdata avoids the carries, moduli, and
-- division that two 32-bit halves require. LuaJIT sinks the cdata box after
-- compiling the trace, so allocation stays bounded by the trace threshold.
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
local adler32 <const> = zlib.C.adler32_z as function(seed: integer, bytes: string, length: integer): loader.CValue
local crc32 <const> = zlib.C.crc32_z as function(seed: integer, bytes: string, length: integer): loader.CValue
local floor <const> = math.floor
local MAX_U32 <const> = 4294967295

local function checksumSeed(previous: integer, algorithm: string): integer
    if previous < 0 or previous > MAX_U32 or previous ~= floor(previous) then
        error(("tecs: %s previous checksum must be an unsigned 32-bit integer"):format(algorithm), 3)
    end
    return previous
end

local sha256Text <const> = loader.newArray("char[65]")
local sha256 <const> = R.tecsSha256 as function(bytes: string, length: integer, output: loader.CArray): boolean

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

--- Computes SHA-256 over the bytes of `text`.
---
--- SHA-256 detects whether bytes match a trusted digest. It does not prove who
--- supplied either value, so artifact verification obtains the expected
--- digest through a trusted channel or a signed manifest.
---
--- @param text Any string. NUL and bytes above 127 hash like any other.
--- @return Sixty-four lowercase hexadecimal digits, high byte first.
function data.sha256(text: string): string
    if not sha256(text, #text, sha256Text) then
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
--- @param text Any string. NUL and bytes above 127 contribute like any other.
--- @param previous The checksum returned after all preceding bytes. Omit it
---     for the first chunk. Raises unless it is an unsigned 32-bit integer.
--- @return The checksum after `text`, as an exact Lua number in [0, 2^32).
function data.adler32(text: string, previous?: integer): integer
    local seed = 1
    if previous ~= nil then
        seed = checksumSeed(previous, "adler32")
    end
    return tonumber(adler32(seed, text, #text)) as integer
end

--- Computes CRC-32 over the bytes of `text` as a number in [0, 2^32).
---
--- The checksum PNG, gzip and ZIP put beside compressed bytes. It detects
--- accidental corruption and is not a cryptographic digest; use it only where
--- a format specifies CRC-32 or where an error-detecting checksum is enough.
--- Pass the return value back as `previous` to continue the checksum over
--- another chunk. An empty chunk leaves `previous` unchanged.
---
--- @param text Any string. NUL and bytes above 127 contribute like any other.
--- @param previous The checksum returned after all preceding bytes. Omit it
---     for the first chunk. Raises unless it is an unsigned 32-bit integer.
--- @return The checksum after `text`, as an exact Lua number in [0, 2^32).
function data.crc32(text: string, previous?: integer): integer
    local seed = 0
    if previous ~= nil then
        seed = checksumSeed(previous, "crc32")
    end
    return tonumber(crc32(seed, text, #text)) as integer
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
