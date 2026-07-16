--- JSON serializer using LuaJIT StringBuffer and FFI.
---
--- Note: The compact and pretty serializers are intentionally duplicated rather than
--- sharing code paths with conditionals. This avoids branching overhead in hot loops
--- and allows each path to be optimized independently.

local C <const> = require("ffi")
local buffer <const> = require("string.buffer")
local bit <const> = require("bit")
local table_clear <const> = require("table.clear")

local rshift <const> = bit.rshift as function(integer, integer): integer
local band <const> = bit.band as function(integer, integer): integer
local huge <const> = math.huge

local serializer = {}

-- NULL sentinel (will be set from main module)
local NULL_SENTINEL: any = nil

-- EMPTY_OBJECT sentinel (will be set from main module)
local EMPTY_OBJECT_SENTINEL: any = nil

--- Set the NULL sentinel used to distinguish JSON null from Lua nil
function serializer.setNullSentinel(sentinel: any)
    NULL_SENTINEL = sentinel
end

--- Set the EMPTY_OBJECT sentinel used to force {} instead of [] for empty tables
function serializer.setEmptyObjectSentinel(sentinel: any)
    EMPTY_OBJECT_SENTINEL = sentinel
end

-- Marker metatable the parser stamps on empty JSON objects, so a
-- parse -> serialize round trip keeps {} as {} (an unmarked empty table
-- serializes as []). Set from the main module.
local OBJECT_MARKER: any = nil

--- Set the marker metatable identifying parsed empty objects.
function serializer.setObjectMarker(marker: any)
    OBJECT_MARKER = marker
end

-- True for an empty table that must serialize as {}: the EMPTY_OBJECT
-- sentinel, or a parser-marked object that is still empty (a marked table
-- that gained keys serializes through the normal object path).
local function isEmptyObject(tbl: {any}): boolean
    if tbl == EMPTY_OBJECT_SENTINEL then return true end
    if OBJECT_MARKER == nil or (getmetatable(tbl) as any) ~= OBJECT_MARKER then
        return false
    end
    return next(tbl as {any:any}) == nil
end

-- Character constants
local CHAR_QUOTE <const> = 34
local CHAR_BACKSLASH <const> = 92
local EMPTY_STRING <const> = '""'

-- String constants (avoid table lookups for punctuation)
local S_QUOTE <const> = "\""
local S_LBRACE <const> = "{"
local S_RBRACE <const> = "}"
local S_LBRACKET <const> = "["
local S_RBRACKET <const> = "]"
local S_COMMA <const> = ","
local S_COLON <const> = ":"
local S_COLON_SPACE <const> = ": "
local S_NL <const> = "\n"
local S_TRUE <const> = "true"
local S_FALSE <const> = "false"
local S_NULL <const> = "null"
local S_EMPTY_ARRAY <const> = "[]"
local S_EMPTY_OBJECT <const> = "{}"

-- Error messages
local ERR_CIRCULAR_REF <const> = "Circular reference detected"
local ERR_UNSUPPORTED_TYPE <const> = "Unsupported type for JSON serialization"
local ERR_INVALID_NUMBER <const> = "Invalid number (NaN or Inf)"

-- Escape lookup table
local NEEDS_ESCAPE = C.new("bool[256]") as {boolean}
NEEDS_ESCAPE[CHAR_QUOTE] = true
NEEDS_ESCAPE[CHAR_BACKSLASH] = true
-- Mark control characters 0--31
C.fill(C.cast("uint8_t*", NEEDS_ESCAPE) as C.CData, 32, 1)

-- Prebuilt escape fragments
local ESC_SIMPLE: {string} = {}
ESC_SIMPLE[34] = "\\\""  -- "
ESC_SIMPLE[92] = "\\\\"  -- \
ESC_SIMPLE[8] = "\\b"
ESC_SIMPLE[9] = "\\t"
ESC_SIMPLE[10] = "\\n"
ESC_SIMPLE[12] = "\\f"
ESC_SIMPLE[13] = "\\r"

-- Prebuilt \u00XX for control characters
local HEX <const> = "0123456789abcdef"
local ESC_U00: {string} = {}
do
    for c = 0, 31 do
        local hi = string.sub(HEX, rshift(c, 4) + 1, rshift(c, 4) + 1)
        local lo = string.sub(HEX, band(c, 0xF) + 1, band(c, 0xF) + 1)
        ESC_U00[c] = "\\u00" .. hi .. lo
    end
end

-- Reused across calls; public entry points reset both before serializing.
local BUF: buffer = buffer.new()
local SEEN: {any: boolean} = {}

local put = BUF.put
local putcdata = BUF.putcdata

local function serializeStringSlow(p: {integer}, len: integer)
    put(BUF, S_QUOTE)
    local start = 0
    for j = 0, len - 1 do
        local c = p[j]
        if NEEDS_ESCAPE[c] then
            if j > start then
                putcdata(BUF, p as integer + start, j - start)
            end
            put(BUF, ESC_SIMPLE[c] or ESC_U00[c])
            start = j + 1
        end
    end

    if start < len then
        putcdata(BUF, p as integer + start, len - start)
    end

    put(BUF, S_QUOTE)
end

-- Serialize a string with proper escaping
local function serializeString(str: string)
    local len = #str
    if len == 0 then
        put(BUF, EMPTY_STRING)
        return
    end

    -- Fast path: copy strings directly when no JSON escapes are needed.
    local p = C.cast("const uint8_t*", str) as {integer}
    for i = 0, len - 1 do
        if NEEDS_ESCAPE[p[i]] then
            serializeStringSlow(p, len)
            return
        end
    end

    put(BUF, S_QUOTE)
    putcdata(BUF, p as integer, len)
    put(BUF, S_QUOTE)
end

-- NaN and Inf check; JSON doesn't support these
local function validateNumber(num: number)
    if num ~= num or num == huge or num == -huge then
        error(ERR_INVALID_NUMBER)
    end
end

-- Collect and sort string keys from a table
local function collectSortedKeys(tbl: {any:any}): {string}, integer
    local keys: {string} = {}
    local n = 0
    local k = next(tbl)
    while k ~= nil do
        if k is string then
            n = n + 1
            keys[n] = k
        end
        k = next(tbl, k)
    end
    table.sort(keys)
    return keys, n
end

--------------------------------------------------------------------------------
-- Compact serializer
--------------------------------------------------------------------------------

-- Forward declaration
local serializeValueCompact: function(any, boolean)

local function serializeArrayCompact(tbl: {any}, sortKeys: boolean)
    local n = #tbl
    if n == 0 then
        put(BUF, S_EMPTY_ARRAY)
        return
    end

    put(BUF, S_LBRACKET)
    serializeValueCompact(tbl[1], sortKeys)
    for i = 2, n do
        put(BUF, S_COMMA)
        serializeValueCompact(tbl[i], sortKeys)
    end
    put(BUF, S_RBRACKET)
end

local function serializeObjectCompact(tbl: {any:any}, sortKeys: boolean)
    local first = true
    local k = next(tbl)
    while k ~= nil do
        if k is string then
            if first then
                put(BUF, S_LBRACE)
                first = false
            else
                put(BUF, S_COMMA)
            end
            serializeString(k)
            put(BUF, S_COLON)
            serializeValueCompact(tbl[k], sortKeys)
        end
        k = next(tbl, k)
    end

    if first then
        put(BUF, S_EMPTY_OBJECT)
    else
        put(BUF, S_RBRACE)
    end
end

local function serializeObjectCompactSorted(tbl: {any:any}, sortKeys: boolean)
    local keys, n = collectSortedKeys(tbl)
    if n == 0 then
        put(BUF, S_EMPTY_OBJECT)
        return
    end

    put(BUF, S_LBRACE)
    local key = keys[1]
    serializeString(key)
    put(BUF, S_COLON)
    serializeValueCompact(tbl[key], sortKeys)

    for i = 2, n do
        put(BUF, S_COMMA)
        key = keys[i]
        serializeString(key)
        put(BUF, S_COLON)
        serializeValueCompact(tbl[key], sortKeys)
    end
    put(BUF, S_RBRACE)
end

local function serializeTableCompact(tbl: {any}, sortKeys: boolean)
    if SEEN[tbl] then
        error(ERR_CIRCULAR_REF)
    end
    SEEN[tbl] = true

    -- EMPTY_OBJECT and parser-marked empty objects serialize as objects.
    if isEmptyObject(tbl) then
        put(BUF, S_EMPTY_OBJECT)
    elseif rawget(tbl, 1) ~= nil or next(tbl as {any:any}) == nil then
        serializeArrayCompact(tbl, sortKeys)
    elseif sortKeys then
        serializeObjectCompactSorted(tbl as {any:any}, sortKeys)
    else
        serializeObjectCompact(tbl as {any:any}, sortKeys)
    end

    SEEN[tbl] = nil
end

function serializeValueCompact(value: any, sortKeys: boolean)
    local t = type(value)
    if t == "string" then
        serializeString(value as string)
    elseif t == "number" then
        local num = value as number
        validateNumber(num)
        put(BUF, num)
    elseif t == "boolean" then
        put(BUF, value and S_TRUE or S_FALSE)
    elseif t == "nil" then
        put(BUF, S_NULL)
    elseif t == "table" then
        if value == NULL_SENTINEL then
            put(BUF, S_NULL)
        else
            serializeTableCompact(value as {any}, sortKeys)
        end
    else
        error(ERR_UNSUPPORTED_TYPE .. ": " .. t)
    end
end

--------------------------------------------------------------------------------
-- Pretty serializer
--------------------------------------------------------------------------------

-- Forward declaration
local serializeValuePretty: function(any, string, string, boolean)

local function serializeArrayPretty(
    tbl: {any},
    currentIndent: string,
    indentStr: string,
    sortKeys: boolean
)
    local n = #tbl
    if n == 0 then
        put(BUF, S_EMPTY_ARRAY)
        return
    end

    local nextIndent = currentIndent .. indentStr
    put(BUF, S_LBRACKET)
    put(BUF, S_NL)
    put(BUF, nextIndent)
    serializeValuePretty(tbl[1], nextIndent, indentStr, sortKeys)
    for i = 2, n do
        put(BUF, S_COMMA)
        put(BUF, S_NL)
        put(BUF, nextIndent)
        serializeValuePretty(tbl[i], nextIndent, indentStr, sortKeys)
    end
    put(BUF, S_NL)
    put(BUF, currentIndent)
    put(BUF, S_RBRACKET)
end

local function serializeObjectPretty(
    tbl: {any:any},
    currentIndent: string,
    indentStr: string,
    sortKeys: boolean
)
    local nextIndent = currentIndent .. indentStr

    if sortKeys then
        local keys, n = collectSortedKeys(tbl)
        if n == 0 then
            put(BUF, S_EMPTY_OBJECT)
            return
        end

        put(BUF, S_LBRACE)
        put(BUF, S_NL)
        put(BUF, nextIndent)
        local key = keys[1]
        serializeString(key)
        put(BUF, S_COLON_SPACE)
        serializeValuePretty(tbl[key], nextIndent, indentStr, sortKeys)

        for i = 2, n do
            put(BUF, S_COMMA)
            put(BUF, S_NL)
            put(BUF, nextIndent)
            key = keys[i]
            serializeString(key)
            put(BUF, S_COLON_SPACE)
            serializeValuePretty(tbl[key], nextIndent, indentStr, sortKeys)
        end
    else
        local first = true
        local k = next(tbl)
        while k ~= nil do
            if k is string then
                if first then
                    put(BUF, S_LBRACE)
                    put(BUF, S_NL)
                    put(BUF, nextIndent)
                    first = false
                else
                    put(BUF, S_COMMA)
                    put(BUF, S_NL)
                    put(BUF, nextIndent)
                end
                serializeString(k)
                put(BUF, S_COLON_SPACE)
                serializeValuePretty(tbl[k], nextIndent, indentStr, sortKeys)
            end
            k = next(tbl, k)
        end

        if first then
            put(BUF, S_EMPTY_OBJECT)
            return
        end
    end

    put(BUF, S_NL)
    put(BUF, currentIndent)
    put(BUF, S_RBRACE)
end

local function serializeTablePretty(
    tbl: {any},
    currentIndent: string,
    indentStr: string,
    sortKeys: boolean
)
    if SEEN[tbl] then
        error(ERR_CIRCULAR_REF)
    end
    SEEN[tbl] = true

    -- EMPTY_OBJECT and parser-marked empty objects serialize as objects.
    if isEmptyObject(tbl) then
        put(BUF, S_EMPTY_OBJECT)
    elseif rawget(tbl, 1) ~= nil or next(tbl as {any:any}) == nil then
        serializeArrayPretty(tbl, currentIndent, indentStr, sortKeys)
    else
        serializeObjectPretty(tbl as {any:any}, currentIndent, indentStr, sortKeys)
    end

    SEEN[tbl] = nil
end

function serializeValuePretty(
    value: any,
    currentIndent: string,
    indentStr: string,
    sortKeys: boolean
)
    local t = type(value)
    if t == "string" then
        serializeString(value as string)
    elseif t == "number" then
        local num = value as number
        validateNumber(num)
        put(BUF, num)
    elseif t == "boolean" then
        put(BUF, value and S_TRUE or S_FALSE)
    elseif t == "nil" then
        put(BUF, S_NULL)
    elseif t == "table" then
        if value == NULL_SENTINEL then
            put(BUF, S_NULL)
        else
            serializeTablePretty(value as {any}, currentIndent, indentStr, sortKeys)
        end
    else
        error(ERR_UNSUPPORTED_TYPE .. ": " .. t)
    end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function serializer.serialize(value: any, sortKeys: any): string
    BUF:reset()
    table_clear(SEEN)
    serializeValueCompact(value, sortKeys and true or false)
    return BUF:get()
end

function serializer.serializePretty(value: any, sortKeys: any, indent: string): string
    BUF:reset()
    table_clear(SEEN)
    local indentStr = indent or "  "
    local doSortKeys = sortKeys ~= false  -- default true
    serializeValuePretty(value, "", indentStr, doSortKeys)
    return BUF:get()
end

return serializer
