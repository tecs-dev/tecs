--- JSON parser using LuaJIT and FFI

local C <const> = require("ffi")
local buffer <const> = require("string.buffer")
local bit <const> = require("bit")

local rshift <const> = bit.rshift as function(integer, integer): integer
local band <const> = bit.band as function(integer, integer): integer

C.cdef[[
    double strtod(const char *nptr, char **endptr);
    char *setlocale(int category, const char *locale);
]]

local type Ptr = {integer}
local parser = {}

-- NULL sentinel (will be set from main module)
local NULL_SENTINEL: any = nil

--- Set the NULL sentinel used to distinguish JSON null from Lua nil
function parser.setNullSentinel(sentinel: any)
    NULL_SENTINEL = sentinel
end

-- FFI lookup tables for ultra-fast character classification
local WHITESPACE_LUT = C.new("bool[256]") as {boolean}
local DIGIT_LUT = C.new("bool[256]") as {boolean}
local NUM_FLOAT_LUT = C.new("bool[256]") as {boolean}

-- Initialize lookup tables at module load time
do
    WHITESPACE_LUT[32] = true  -- ' '
    WHITESPACE_LUT[9] = true   -- '\t'
    WHITESPACE_LUT[10] = true  -- '\n'
    WHITESPACE_LUT[13] = true  -- '\r'
    -- Digits: 0-9
    C.fill(DIGIT_LUT as integer + 48, 10, 1)
    -- Float indicators
    NUM_FLOAT_LUT[46] = true   -- '.'
    NUM_FLOAT_LUT[101] = true  -- 'e'
    NUM_FLOAT_LUT[69] = true   -- 'E'
end

-- Fast hex value lookup table
local hexval = C.new("int8_t[256]") as {integer}
do
    for i = 0, 255 do hexval[i] = -1 end
    for i = 48, 57 do hexval[i] = i - 48 end        -- '0'-'9'
    for i = 65, 70 do hexval[i] = 10 + i - 65 end   -- 'A'-'F'
    for i = 97, 102 do hexval[i] = 10 + i - 97 end  -- 'a'-'f'
end

-- Escape character lookup table
local ESC = C.new("int16_t[256]") as {integer}
do
    for i = 0, 255 do ESC[i] = -1 end  -- default: emit raw
    ESC[34] = 34   -- '"'
    ESC[92] = 92   -- '\'
    ESC[47] = 47   -- '/'
    ESC[98] = 8    -- 'b' -> backspace
    ESC[102] = 12  -- 'f' -> form feed
    ESC[110] = 10  -- 'n' -> newline
    ESC[114] = 13  -- 'r' -> carriage return
    ESC[116] = 9   -- 't' -> tab
    ESC[117] = -2  -- 'u' -> unicode escape
end

-- Maps bytes (0-255) to chars, avoiding repeated string.char() calls when decoding escape sequences.
local CH1: {string} = {}
do
    for i = 0, 255 do CH1[i] = string.char(i) end
end

-- Reusable StringBuffer building strings
local stringBuffer = buffer.new()

-- Reusable 4-byte buffer for UTF-8 encoding (avoids allocating a 4-byte string for each \uXXXX escape).
local u8 = C.new("uint8_t[4]") as {integer}

local function putUtf8Bytes(putcdata: function, cp: integer)
    if cp < 0x80 then
        u8[0] = cp
        putcdata(stringBuffer, u8, 1)
    elseif cp < 0x800 then
        u8[0] = 0xC0 + rshift(cp, 6)
        u8[1] = 0x80 + band(cp, 0x3F)
        putcdata(stringBuffer, u8, 2)
    elseif cp < 0x10000 then
        u8[0] = 0xE0 + rshift(cp, 12)
        u8[1] = 0x80 + band(rshift(cp, 6), 0x3F)
        u8[2] = 0x80 + band(cp, 0x3F)
        putcdata(stringBuffer, u8, 3)
    else
        u8[0] = 0xF0 + rshift(cp, 18)
        u8[1] = 0x80 + band(rshift(cp, 12), 0x3F)
        u8[2] = 0x80 + band(rshift(cp, 6), 0x3F)
        u8[3] = 0x80 + band(cp, 0x3F)
        putcdata(stringBuffer, u8, 4)
    end
end

-- Character constants grouped by category
local CHAR_QUOTE <const> = 34       -- '"'
local CHAR_BACKSLASH <const> = 92   -- '\'
local CHAR_LBRACE <const> = 123     -- '{'
local CHAR_RBRACE <const> = 125     -- '}'
local CHAR_LBRACKET <const> = 91    -- '['
local CHAR_RBRACKET <const> = 93    -- ']'
local CHAR_COMMA <const> = 44       -- ','
local CHAR_COLON <const> = 58       -- ':'
local CHAR_MINUS <const> = 45       -- '-'
local CHAR_DOT <const> = 46         -- '.'
local CHAR_E <const> = 101          -- 'e'
local CHAR_E_CAP <const> = 69       -- 'E'

-- Error messages for JIT hygiene
local ERR_UNTERMINATED_STRING <const> = "Unterminated string"
local ERR_INVALID_NUMBER <const> = "Invalid number"
local ERR_INVALID_FRAC <const> = "Invalid frac"
local ERR_UNESCAPED_CONTROL <const> = "Unescaped control character in string"
local ERR_INVALID_UNICODE <const> = "Invalid unicode escape"
local ERR_INVALID_ESCAPE <const> = "Invalid escape sequence"
local ERR_UNEXPECTED_END_ARRAY <const> = "Unexpected end in array"
local ERR_EXPECTED_COMMA_BRACKET <const> = "Expected ',' or ']' in array"
local ERR_EXPECTED_STRING_KEY <const> = "Expected string key"
local ERR_EXPECTED_COLON <const> = "Expected ':' after key"
local ERR_UNEXPECTED_END_OBJECT <const> = "Unexpected end in object"
local ERR_EXPECTED_COMMA_BRACE <const> = "Expected ',' or '}' in object"
local ERR_UNEXPECTED_END_INPUT <const> = "Unexpected end of input"
local ERR_INVALID_LITERAL_T <const> = "Invalid literal starting with 't'"
local ERR_INVALID_LITERAL_F <const> = "Invalid literal starting with 'f'"
local ERR_INVALID_LITERAL_N <const> = "Invalid literal starting with 'n'"
local ERR_INPUT_EMPTY <const> = "Input string cannot be nil or empty"
local ERR_CDATA_NIL <const> = "CData pointer cannot be nil"
local ERR_CDATA_EMPTY <const> = "CData length cannot be zero"
local ERR_UNEXPECTED_CONTENT <const> = "Unexpected content after JSON"
local ERR_UNEXPECTED_CHAR <const> = "Unexpected character"
local ERR_MAX_DEPTH <const> = "Maximum nesting depth exceeded"

local function skipWs(ptr: Ptr, len: integer, pos: integer): integer
    -- Fast path: check current byte, covering minified JSON
    if pos >= len or not WHITESPACE_LUT[ptr[pos]] then
        return pos
    end
    -- Slow path: multiple whitespace characters
    for i = pos + 1, len - 1 do
        if not WHITESPACE_LUT[ptr[i]] then
            return i
        end
    end
    return len
end

local function parseString(ptr: Ptr, len: integer, pos: integer): string, integer
    local start = pos + 1 -- Skip opening quote
    local i = start
    local foundBackslash = false

    -- Fast path scan for common strings with no backslashes
    for j = start, len - 1 do
        local c = ptr[j]
        if c == CHAR_QUOTE then
            -- Found closing quote - fast path complete
            return C.string(ptr as integer + start, j - start), j + 1
        elseif c < 32 then
            -- Control character
            error(ERR_UNESCAPED_CONTROL)
        elseif c == CHAR_BACKSLASH then
            -- Hit escape - switch to slow path
            i = j
            foundBackslash = true
            break
        end
    end

    -- Either hit backslash or ran out of buffer
    if not foundBackslash then
        error(ERR_UNTERMINATED_STRING)
    end

    -- Slow path: handle escapes. We already scanned up to i, so copy that first chunk.
    stringBuffer:reset()
    if i > start then
        stringBuffer:putcdata(ptr as integer + start, i - start)
    end

    -- Now handle the backslash at position i and continue
    pos = i
    local chunk = i
    while pos < len do
        local c = ptr[pos]

        if c == CHAR_QUOTE then
            if pos > chunk then
                stringBuffer:putcdata(ptr as integer + chunk, pos - chunk)
            end
            return stringBuffer:get(), pos + 1
        elseif c < 32 then
            error(ERR_UNESCAPED_CONTROL)
        elseif c == CHAR_BACKSLASH then
            if pos > chunk then
                stringBuffer:putcdata(ptr as integer + chunk, pos - chunk)
            end
            pos = pos + 1
            if pos >= len then break end

            local e = ptr[pos]
            local m = ESC[e]

            if m >= 0 then
                stringBuffer:put(CH1[m])
            elseif m == -2 then  -- unicode escape
                if pos + 4 >= len then
                    error(ERR_INVALID_UNICODE)
                end

                local h1 = hexval[ptr[pos + 1]]
                local h2 = hexval[ptr[pos + 2]]
                local h3 = hexval[ptr[pos + 3]]
                local h4 = hexval[ptr[pos + 4]]

                if h1 < 0 or h2 < 0 or h3 < 0 or h4 < 0 then
                    error(ERR_INVALID_UNICODE)
                end

                local cp = ((h1 * 16 + h2) * 16 + h3) * 16 + h4
                pos = pos + 4

                -- Handle surrogate pairs
                if cp >= 0xD800 and cp <= 0xDBFF then
                    local paired = false
                    if pos + 6 < len and ptr[pos + 1] == 92 and ptr[pos + 2] == 117 then
                        local h5 = hexval[ptr[pos + 3]]
                        local h6 = hexval[ptr[pos + 4]]
                        local h7 = hexval[ptr[pos + 5]]
                        local h8 = hexval[ptr[pos + 6]]

                        if h5 >= 0 and h6 >= 0 and h7 >= 0 and h8 >= 0 then
                            local lo = ((h5 * 16 + h6) * 16 + h7) * 16 + h8
                            if lo >= 0xDC00 and lo <= 0xDFFF then
                                cp = 0x10000 + ((cp - 0xD800) * 0x400) + (lo - 0xDC00)
                                pos = pos + 6
                                paired = true
                            end
                        end
                    end
                    if not paired then
                        cp = 0xFFFD -- Replacement character for lone surrogate
                    end
                elseif cp >= 0xDC00 and cp <= 0xDFFF then
                    cp = 0xFFFD -- Lone low surrogate
                end

                putUtf8Bytes(stringBuffer.putcdata, cp)
            else
                error(ERR_INVALID_ESCAPE)
            end

            pos = pos + 1
            chunk = pos
        else
            pos = pos + 1
        end
    end

    error(ERR_UNTERMINATED_STRING)
end

-- Reusable endptr for strtod
local STRTOD_ENDPTR = C.new("char *[1]") as {integer}

-- Scratch buffer for NUL-terminating number tokens from cdata (bug #3: strtod needs NUL)
local STRTOD_SCRATCH_SIZE = 64
local strtodScratch = C.new("char[?]", STRTOD_SCRATCH_SIZE) as {integer}

-- Whether the current parse is from a Lua string (NUL-terminated) or cdata (not necessarily)
local fromLuaString = true

local function callStrtod(ptr: Ptr, start: integer, len: integer): number, integer
    local tokenLen = len - start
    local strStart: integer

    if fromLuaString then
        -- Lua strings are NUL-terminated in memory; safe to pass directly
        strStart = C.cast("const char*", ptr) as integer + start
    else
        -- CData buffer may not be NUL-terminated; copy token to scratch buffer
        if tokenLen >= STRTOD_SCRATCH_SIZE then
            STRTOD_SCRATCH_SIZE = tokenLen + 1
            strtodScratch = C.new("char[?]", STRTOD_SCRATCH_SIZE) as {integer}
        end
        C.copy(strtodScratch as C.CData, C.cast("const char*", ptr) as integer + start, tokenLen)
        strtodScratch[tokenLen] = 0
        strStart = strtodScratch as integer
    end

    -- Locale is already set to C by enterCLocale() at the start of parse
    local result = (C.C.strtod as function(...: any): number)(strStart, STRTOD_ENDPTR)
    local endPos: integer
    if fromLuaString then
        endPos = tonumber(C.cast("intptr_t", STRTOD_ENDPTR[0]) - C.cast("intptr_t", ptr)) as integer
    else
        endPos = start + tonumber(C.cast("intptr_t", STRTOD_ENDPTR[0]) - C.cast("intptr_t", strtodScratch)) as integer
    end
    return result, endPos
end

local function parseFloat(
    ptr: Ptr,
    len: integer,
    pos: integer,
    start: integer,
    acc: number,
    neg: boolean
): number, integer
    -- Handle float: try fast path for simple floats without exponent
    local c = ptr[pos]
    if c == CHAR_DOT then
        pos = pos + 1
        if pos >= len or not DIGIT_LUT[ptr[pos]] then
            error(ERR_INVALID_FRAC)
        end

        -- Parse fractional part manually
        local frac: number = 0
        local divisor: number = 1
        for i = pos, len - 1 do
            c = ptr[i]
            if DIGIT_LUT[c] then
                frac = frac * 10 + (c - 48)
                divisor = divisor * 10
                pos = i + 1
            else
                pos = i
                break
            end
        end

        acc = acc + (frac / divisor)

        -- Check for exponent
        if pos >= len then
            return neg and -acc or acc, pos
        end

        c = ptr[pos]
        if c ~= CHAR_E and c ~= CHAR_E_CAP then
            return neg and -acc or acc, pos
        end
    end

    -- Has exponent (or integer with exponent like "123e10"), use strtod
    return callStrtod(ptr, start, len)
end

local function parseNumber(ptr: Ptr, len: integer, pos: integer): number, integer
    local start = pos

    -- Check if it's negative, and skip "-".
    local neg = ptr[pos] == CHAR_MINUS and true or false
    if neg then
        pos = pos + 1
        if pos >= len or not DIGIT_LUT[ptr[pos]] then
            error(ERR_INVALID_NUMBER)
        end
    end

    -- Now parse the integer part and accumulate while parsing.
    local firstDigit = ptr[pos]
    local acc: number = firstDigit - 48
    pos = pos + 1

    -- Check for leading zero (JSON doesn't allow "01")
    local c: integer = 0
    if firstDigit ~= 48 then
        for i = pos, len - 1 do
            c = ptr[i]
            if DIGIT_LUT[c] then
                acc = acc * 10 + (c - 48)
                pos = i + 1
            else
                pos = i
                break
            end
        end
    elseif pos < len and DIGIT_LUT[ptr[pos]] then
        -- If it's just '0', that's fine, but '0' followed by more digits is invalid
        error(ERR_INVALID_NUMBER)
    end

    -- If at EOF or not a float indicator, return integer
    if pos >= len or not NUM_FLOAT_LUT[ptr[pos]] then
        return neg and -acc or acc, pos
    end

    return parseFloat(ptr, len, pos, start, acc, neg)
end

-- Maximum nesting depth to prevent stack overflow
local MAX_DEPTH <const> = 100

-- Forward declaration for recursive parsing
local parseValue: function({integer}, integer, integer, integer): any, integer

local function parseArray(ptr: Ptr, len: integer, pos: integer, depth: integer): {any}, integer
    if depth >= MAX_DEPTH then
        error(ERR_MAX_DEPTH)
    end

    pos = pos + 1 -- Skip '['
    pos = skipWs(ptr, len, pos)

    -- Check for unexpected end
    if pos >= len then
        error(ERR_UNEXPECTED_END_ARRAY)
    end

    -- Is it an empty array?
    if ptr[pos] == CHAR_RBRACKET then
        return {}, pos + 1
    end

    local result: {any} = {}
    local index = 1

    while true do
        local value: any
        value, pos = parseValue(ptr, len, pos, depth + 1)

        -- Replace nil with NULL sentinel if configured
        if value == nil then
            value = NULL_SENTINEL
        end

        result[index] = value
        index = index + 1

        pos = skipWs(ptr, len, pos)
        if pos >= len then
            error(ERR_UNEXPECTED_END_ARRAY)
        end

        local c = ptr[pos]
        pos = pos + 1
        if c == CHAR_RBRACKET then
            return result, pos
        elseif c == CHAR_COMMA then
            pos = skipWs(ptr, len, pos)
        else
            error(ERR_EXPECTED_COMMA_BRACKET)
        end
    end
end

local function parseObject(ptr: Ptr, len: integer, pos: integer, depth: integer): {string: any}, integer
    if depth >= MAX_DEPTH then
        error(ERR_MAX_DEPTH)
    end

    pos = pos + 1  -- Skip '{'
    pos = skipWs(ptr, len, pos)

    -- Check for unexpected end
    if pos >= len then
        error(ERR_UNEXPECTED_END_OBJECT)
    end

    -- Empty object?
    if ptr[pos] == CHAR_RBRACE then
        return {}, pos + 1
    end

    local result: {string: any} = {}
    while true do
        -- Parse key (must be string)
        if ptr[pos] ~= CHAR_QUOTE then
            error(ERR_EXPECTED_STRING_KEY)
        end

        -- Read the key as a string.
        local key: string
        key, pos = parseString(ptr, len, pos)

        -- Skip ws, expect colon
        pos = skipWs(ptr, len, pos)
        if pos >= len or ptr[pos] ~= CHAR_COLON then
            error(ERR_EXPECTED_COLON)
        end
        pos = pos + 1

        -- Skip ws, read value
        pos = skipWs(ptr, len, pos)
        local value: any
        value, pos = parseValue(ptr, len, pos, depth + 1)
        -- Replace nil (JSON null) with sentinel so the key is preserved
        if value == nil then
            value = NULL_SENTINEL
        end
        result[key] = value

        pos = skipWs(ptr, len, pos)
        if pos >= len then
            error(ERR_UNEXPECTED_END_OBJECT)
        end

        local c = ptr[pos]
        pos = pos + 1
        if c == CHAR_RBRACE then
            return result, pos -- end of object
        elseif c == CHAR_COMMA then
            pos = skipWs(ptr, len, pos) -- comma, read more
        else
            error(ERR_EXPECTED_COMMA_BRACE)
        end
    end
end

function parseValue(ptr: Ptr, len: integer, pos: integer, depth: integer): any, integer
    pos = skipWs(ptr, len, pos)
    if pos >= len then
        error(ERR_UNEXPECTED_END_INPUT)
    end

    local c = ptr[pos]
    if c == CHAR_QUOTE then
        return parseString(ptr, len, pos)
    elseif c == CHAR_LBRACE then
        return parseObject(ptr, len, pos, depth)
    elseif c == CHAR_LBRACKET then
        return parseArray(ptr, len, pos, depth)
    elseif DIGIT_LUT[c] or c == CHAR_MINUS then
        return parseNumber(ptr, len, pos)
    elseif c == 116 then -- 't' for true, then look for "rue".
        if pos + 3 < len and ptr[pos + 1] == 114 and ptr[pos + 2] == 117 and ptr[pos + 3] == 101 then
            return true, pos + 4
        end
        error(ERR_INVALID_LITERAL_T)
    elseif c == 102 then -- 'f' for false, then look for "alse".
        if pos + 4 < len and
            ptr[pos + 1] == 97 and
            ptr[pos + 2] == 108 and
            ptr[pos + 3] == 115 and
            ptr[pos + 4] == 101
        then
            return false, pos + 5
        end
        error(ERR_INVALID_LITERAL_F)
    elseif c == 110 then -- 'n' for null, then look for "ull".
        if pos + 3 < len and ptr[pos + 1] == 117 and ptr[pos + 2] == 108 and ptr[pos + 3] == 108 then
            return nil, pos + 4
        end
        error(ERR_INVALID_LITERAL_N)
    else
        error(ERR_UNEXPECTED_CHAR)
    end
end

-- LC_NUMERIC's integer value differs by C library: glibc (and musl) number it
-- 1, while macOS/BSD and the Windows CRT use 4 (where 1 is LC_COLLATE). Pick by
-- OS so the locale guard below targets the real numeric category.
local LC_NUMERIC <const> = (C.os == "Linux") and 1 or 4
local _setlocale <const> = C.C.setlocale as function(...: any): C.CData

--[[ withCLocale!(result, pos = parseValue(ptr, len, 0, 0)) expands to:
    local _oldLocale = _setlocale(LC_NUMERIC, nil)
    if _oldLocale ~= nil then
        local _s = C.string(_oldLocale)
        if _s ~= "C" and _s ~= "POSIX" then
            _setlocale(LC_NUMERIC, "C")
        else
            _oldLocale = nil
        end
    end
    result, pos = parseValue(ptr, len, 0, 0)
    if _oldLocale ~= nil then
        _setlocale(LC_NUMERIC, _oldLocale)
    end
]]
local macro withCLocale!(body: Statement)
    local out = block("statements")
    table.insert(out, ```
        local _oldLocale = _setlocale(LC_NUMERIC, nil)
        if _oldLocale ~= nil then
            local _s = C.string(_oldLocale)
            if _s ~= "C" and _s ~= "POSIX" then
                _setlocale(LC_NUMERIC, "C")
            else
                _oldLocale = nil
            end
        end
    ```)
    table.insert(out, body)
    table.insert(out, ```
        if _oldLocale ~= nil then
            _setlocale(LC_NUMERIC, _oldLocale)
        end
    ```)
    return out
end

function parser.parse(jsonStr: string): any
    if not jsonStr or #jsonStr == 0 then
        error(ERR_INPUT_EMPTY)
    end

    fromLuaString = true
    local strPtr = C.cast("uint8_t*", jsonStr) as {integer}
    local len = #jsonStr
    local result: any
    local pos: integer

    withCLocale!(result, pos = parseValue(strPtr, len, 0, 0))

    if result == nil then
        result = NULL_SENTINEL
    end

    pos = skipWs(strPtr, len, pos)
    if pos < len then
        error(ERR_UNEXPECTED_CONTENT)
    end

    return result
end

--- Parse JSON from FFI cdata pointer (useful for Love2D ByteData or other FFI buffers).
function parser.parseCData(cdataPtr: C.CData, length: integer): any
    if not cdataPtr then
        error(ERR_CDATA_NIL)
    elseif length <= 0 then
        error(ERR_CDATA_EMPTY)
    end

    fromLuaString = false
    local dataPtr = C.cast("uint8_t*", cdataPtr) as {integer}
    local result: any
    local pos: integer

    withCLocale!(result, pos = parseValue(dataPtr, length, 0, 0))

    if result == nil then
        result = NULL_SENTINEL
    end

    pos = skipWs(dataPtr, length, pos)
    if pos < length then
        error(ERR_UNEXPECTED_CONTENT)
    end

    return result
end

return parser