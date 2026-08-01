--[=[
UTF-8 codepoint decoding, encoding, validation, and byte-safe truncation.

Offsets are one-based byte cursor positions, matching Lua string indices.
`decodeAt` reads the codepoint beginning at an offset and returns the cursor
after it. `decodeBefore` reads the codepoint before a cursor and returns its
starting offset:

```teal
local utf8 <const> = tecs.data.utf8
local text <const> = "A€"

local codepoint, nextOffset = utf8.decodeAt(text, 2)
assert(codepoint == 0x20ac)
assert(nextOffset == #text + 1)

codepoint, nextOffset = utf8.decodeBefore(text, nextOffset)
assert(codepoint == 0x20ac)
assert(nextOffset == 2)
```

The end cursor is the byte length plus one. `decodeAt` returns nil there, and
`decodeBefore` returns nil at cursor 1. An offset inside a multibyte sequence
is not moved to a boundary automatically. SDL reports the malformed fragment
at that exact position as U+FFFD.

Every inspection function accepts a Lua string or an open
[`ByteView`](tealdoc:tecs.io.ByteView). A view is read through its retained
pointer without first becoming a Lua string. `validPrefixLength` answers the
byte count a caller can use to retain a zero-copy view at a UTF-8 boundary.

Malformed UTF-8 is recoverable rather than exceptional. Forward decoding
returns U+FFFD and consumes one malformed byte, so callers can keep scanning.
A valid encoded U+FFFD remains indistinguishable by value but consumes its
three bytes. Embedded NUL is the valid U+0000 codepoint and does not terminate
a Lua string.

These functions operate on Unicode codepoints, not user-perceived characters.
A combining mark, variation selector, or member of an emoji sequence is a
separate result. Text editing that needs cursor movement by grapheme cluster
requires a Unicode segmentation implementation above this module.

]=]

local ffi <const> = require("ffi")
local loader <const> = require("tecs.ffi.loader")
local sdl <const> = require("tecs.ffi.sdl3")
local type ioTypes = require("tecs.io.types")
local type ByteView = ioTypes.ByteView
local type ByteInput = string | ByteView

local floor <const> = math.floor
local max <const> = math.max
local sub <const> = string.sub
local INVALID <const> = 0xfffd
local MAX_CODEPOINT <const> = 0x10ffff

local stepUTF8 <const> = sdl.C.SDL_StepUTF8 as function(cursor: loader.CArray, remaining: loader.CArray): integer
local encodeUTF8 <const> = sdl.C.SDL_UCS4ToUTF8 as function(codepoint: integer, destination: loader.CArray): any

local record ByteRange
    pointer: loader.BytePointer
    length: integer
    owner: ByteInput
end

local record dataUTF8
    --- Counts Unicode codepoints in bytes.
    ---
    --- This is not a byte count or a grapheme count. Each malformed byte
    --- contributes one U+FFFD result, while an embedded NUL contributes the
    --- valid U+0000 codepoint and does not end the input.
    ---
    --- @param bytes The caller supplies a complete byte string or open
    ---     [`ByteView`](tealdoc:tecs.io.ByteView), including embedded NUL.
    --- @return The number of forward decoding steps.
    length: function(bytes: ByteInput): integer

    --- Decodes the codepoint beginning at a byte offset.
    ---
    --- The function returns U+FFFD and advances one byte when the offset
    --- begins malformed or truncated UTF-8. It does not search for a nearby
    --- codepoint boundary when the caller supplies an offset inside a
    --- multibyte sequence.
    ---
    --- @param bytes The caller supplies a complete byte string or open
    ---     [`ByteView`](tealdoc:tecs.io.ByteView). Embedded NUL is U+0000.
    --- @param byteOffset A one-based byte cursor from 1 through the byte
    ---     length plus one. The final value is the end cursor. Other values
    ---     raise.
    --- @return The Unicode codepoint, or nil at the end cursor.
    --- @return The one-based cursor immediately after the result, or the
    ---     unchanged end cursor when no codepoint remains.
    decodeAt: function(bytes: ByteInput, byteOffset: integer): integer | nil, integer

    --- Decodes the codepoint before a byte cursor.
    ---
    --- The decoder searches backward for a possible sequence leader. When
    --- that candidate does not form one scalar ending at the cursor, it
    --- reports the final byte as U+FFFD instead. Forward and reverse scans
    --- therefore recover from malformed input one byte at a time.
    ---
    --- @param bytes The caller supplies a complete byte string or open
    ---     [`ByteView`](tealdoc:tecs.io.ByteView). Embedded NUL is U+0000.
    --- @param byteOffset A one-based byte cursor from 1 through the byte
    ---     length plus one. It points after the codepoint to read. Other
    ---     values raise.
    --- @return The preceding Unicode codepoint, or nil at cursor 1.
    --- @return The one-based starting offset of the result, or 1 when no
    ---     codepoint precedes the cursor.
    decodeBefore: function(bytes: ByteInput, byteOffset: integer): integer | nil, integer

    --- Encodes one Unicode scalar value as UTF-8.
    ---
    --- @param codepoint An integer from U+0000 through U+10FFFF, excluding the
    ---     UTF-16 surrogate range U+D800 through U+DFFF. Other values raise.
    --- @return One through four bytes. U+0000 returns a one-byte Lua string
    ---     containing NUL.
    encode: function(codepoint: integer): string

    --- Reports whether every byte forms canonical UTF-8.
    ---
    --- RFC 3629 rules reject overlong encodings, UTF-16 surrogate values,
    --- codepoints above U+10FFFF, stray continuation bytes, and truncated
    --- sequences. Embedded NUL and an encoded U+FFFD are valid.
    ---
    --- @param bytes The caller supplies a complete byte string or open
    ---     [`ByteView`](tealdoc:tecs.io.ByteView), including embedded NUL.
    --- @return True only when forward decoding never needs a replacement for
    ---     a malformed byte.
    isValid: function(bytes: ByteInput): boolean

    --- Returns the longest prefix ending at a complete UTF-8 decoding unit.
    ---
    --- The function returns a byte count and never copies the input. A caller
    --- can pass the result to `ByteView:view` to retain the prefix. Malformed
    --- bytes remain one-byte units and therefore fit whenever their byte does.
    ---
    --- @param bytes The caller supplies a complete byte string or open
    ---     [`ByteView`](tealdoc:tecs.io.ByteView).
    --- @param maxBytes A non-negative integer byte ceiling. Other values
    ---     raise.
    --- @return Returns the largest safe prefix length no greater than
    ---     `maxBytes`.
    validPrefixLength: function(bytes: ByteInput, maxBytes: integer): integer

    --- Truncates a string without splitting a valid UTF-8 sequence.
    ---
    --- The result is a byte prefix, not a normalization. Malformed bytes are
    --- one-byte decoding units and remain unchanged when they fit. The
    --- function does not combine marks or emoji into grapheme clusters.
    ---
    --- @param text The complete byte string.
    --- @param maxBytes A non-negative integer byte ceiling. Other values
    ---     raise.
    --- @return The longest prefix no larger than `maxBytes` whose final
    ---     decoding unit is complete. Returns `text` itself when it fits.
    truncate: function(text: string, maxBytes: integer): string
end

local function byteRange(value: ByteInput, level: integer): ByteRange
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
        error("tecs: UTF-8 needs a byte string or open io.ByteView", level)
    end
    local view <const> = value as ByteView
    return {
        pointer = view:getFFIPointer(),
        length = view:length(),
        owner = view,
    }
end

local function checkOffset(bytes: ByteRange, byteOffset: integer, level: integer)
    local maximum <const> = bytes.length + 1
    if type(byteOffset) ~= "number" or byteOffset ~= floor(byteOffset) or byteOffset < 1 or byteOffset > maximum then
        error(("tecs: UTF-8 byte offset must be an integer from 1 through %d"):format(maximum), level)
    end
end

--- Decodes forward with caller-owned scratch storage.
---
--- NUL has to be handled before SDL. Even with an explicit remaining length,
--- SDL uses codepoint zero as its end sentinel and deliberately leaves the
--- cursor unchanged. Lua strings are length-delimited, so zero is data here.
local function forward(
    bytes: ByteRange, byteOffset: integer, cursor: loader.CArray, remaining: loader.CArray
): integer, integer
    if bytes.pointer[byteOffset - 1] == 0 then
        return 0, byteOffset + 1
    end

    local available <const> = bytes.length - byteOffset + 1
    cursor[0] = ffi.cast("const char *", bytes.pointer + (byteOffset - 1))
    remaining[0] = available
    local codepoint <const> = stepUTF8(cursor, remaining)
    -- SDL 3.4.12's implementation accepts the unused historical four-byte
    -- range above U+10FFFF even though its public contract promises RFC 3629.
    -- Keep this API on the documented Unicode scalar boundary and recover one
    -- byte at a time, exactly as SDL documents for every other malformed
    -- sequence.
    if codepoint > MAX_CODEPOINT then
        return INVALID, byteOffset + 1
    end
    return codepoint, byteOffset + available - (tonumber(remaining[0]) as integer)
end

function dataUTF8.length(value: ByteInput): integer
    local bytes <const> = byteRange(value, 2)
    local cursor <const> = loader.newArray("const char *[1]")
    local remaining <const> = loader.newArray("size_t[1]")
    local byteOffset = 1
    local count = 0
    while byteOffset <= bytes.length do
        local _, nextOffset = forward(bytes, byteOffset, cursor, remaining)
        byteOffset = nextOffset
        count = count + 1
    end
    return count
end

function dataUTF8.decodeAt(value: ByteInput, byteOffset: integer): integer | nil, integer
    local bytes <const> = byteRange(value, 2)
    checkOffset(bytes, byteOffset, 3)
    if byteOffset > bytes.length then
        return nil, byteOffset
    end

    local cursor <const> = loader.newArray("const char *[1]")
    local remaining <const> = loader.newArray("size_t[1]")
    return forward(bytes, byteOffset, cursor, remaining)
end

function dataUTF8.decodeBefore(value: ByteInput, byteOffset: integer): integer | nil, integer
    local bytes <const> = byteRange(value, 2)
    checkOffset(bytes, byteOffset, 3)
    if byteOffset == 1 then
        return nil, 1
    end
    if bytes.pointer[byteOffset - 2] == 0 then
        return 0, byteOffset - 1
    end

    local startOffset = byteOffset - 1
    local minimum <const> = max(1, byteOffset - 4)
    while startOffset > minimum do
        local byte <const> = bytes.pointer[startOffset - 1] as integer
        if byte < 0x80 or byte >= 0xc0 then
            break
        end
        startOffset = startOffset - 1
    end

    -- The candidate belongs to this cursor only when forward decoding ends
    -- exactly here. Otherwise the final byte is the malformed unit, which
    -- keeps reverse recovery symmetrical with forward recovery.
    local forwardCursor <const> = loader.newArray("const char *[1]")
    local remaining <const> = loader.newArray("size_t[1]")
    local codepoint, nextOffset = forward(bytes, startOffset, forwardCursor, remaining)
    if nextOffset ~= byteOffset then
        return INVALID, byteOffset - 1
    end
    return codepoint, startOffset
end

function dataUTF8.encode(codepoint: integer): string
    if
        type(codepoint) ~= "number"
        or codepoint ~= floor(codepoint)
        or codepoint < 0
        or codepoint > MAX_CODEPOINT
        or (codepoint >= 0xd800 and codepoint <= 0xdfff)
    then
        error("tecs: UTF-8 codepoint must be a Unicode scalar value", 2)
    end

    local destination <const> = loader.newArray("char[4]")
    encodeUTF8(codepoint, destination)
    local length <const> = codepoint <= 0x7f and 1 or codepoint <= 0x7ff and 2 or codepoint <= 0xffff and 3 or 4
    return loader.toBytes(destination as loader.CValue, length)
end

function dataUTF8.isValid(value: ByteInput): boolean
    local bytes <const> = byteRange(value, 2)
    local cursor <const> = loader.newArray("const char *[1]")
    local remaining <const> = loader.newArray("size_t[1]")
    local byteOffset = 1
    while byteOffset <= bytes.length do
        local codepoint, nextOffset = forward(bytes, byteOffset, cursor, remaining)
        if codepoint == INVALID and nextOffset == byteOffset + 1 then
            return false
        end
        byteOffset = nextOffset
    end
    return true
end

function dataUTF8.validPrefixLength(value: ByteInput, maxBytes: integer): integer
    if type(maxBytes) ~= "number" or maxBytes ~= floor(maxBytes) or maxBytes < 0 then
        error("tecs: UTF-8 maxBytes must be a non-negative integer", 2)
    end
    local bytes <const> = byteRange(value, 2)
    if bytes.length <= maxBytes then
        return bytes.length
    end
    if maxBytes == 0 then
        return 0
    end

    local endCursor <const> = maxBytes + 1
    local startOffset = maxBytes
    local minimum <const> = max(1, endCursor - 4)
    while startOffset > minimum do
        local byte <const> = bytes.pointer[startOffset - 1] as integer
        if byte < 0x80 or byte >= 0xc0 then
            break
        end
        startOffset = startOffset - 1
    end
    local cursor <const> = loader.newArray("const char *[1]")
    local remaining <const> = loader.newArray("size_t[1]")
    local _, nextOffset = forward(bytes, startOffset, cursor, remaining)
    if nextOffset > endCursor then
        return startOffset - 1
    end
    return maxBytes
end

function dataUTF8.truncate(text: string, maxBytes: integer): string
    local length <const> = dataUTF8.validPrefixLength(text, maxBytes)
    if length == #text then
        return text
    end
    return sub(text, 1, length)
end

return dataUTF8
