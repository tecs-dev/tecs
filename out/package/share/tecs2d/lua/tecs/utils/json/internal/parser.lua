

local C = require("ffi")
local buffer = require("string.buffer")
local bit = require("bit")

local rshift = bit.rshift
local band = bit.band

C.cdef([[
    double strtod(const char *nptr, char **endptr);
    char *setlocale(int category, const char *locale);
]])


local parser = {}



local OBJECT_MARKER = nil


function parser.setObjectMarker(marker)
   OBJECT_MARKER = marker
end


local NULL_SENTINEL = nil


function parser.setNullSentinel(sentinel)
   NULL_SENTINEL = sentinel
end


local WHITESPACE_LUT = C.new("bool[256]")
local DIGIT_LUT = C.new("bool[256]")
local NUM_FLOAT_LUT = C.new("bool[256]")


do
   WHITESPACE_LUT[32] = true
   WHITESPACE_LUT[9] = true
   WHITESPACE_LUT[10] = true
   WHITESPACE_LUT[13] = true

   C.fill(DIGIT_LUT + 48, 10, 1)

   NUM_FLOAT_LUT[46] = true
   NUM_FLOAT_LUT[101] = true
   NUM_FLOAT_LUT[69] = true
end


local hexval = C.new("int8_t[256]")
do
   for i = 0, 255 do hexval[i] = -1 end
   for i = 48, 57 do hexval[i] = i - 48 end
   for i = 65, 70 do hexval[i] = 10 + i - 65 end
   for i = 97, 102 do hexval[i] = 10 + i - 97 end
end


local ESC = C.new("int16_t[256]")
do
   for i = 0, 255 do ESC[i] = -1 end
   ESC[34] = 34
   ESC[92] = 92
   ESC[47] = 47
   ESC[98] = 8
   ESC[102] = 12
   ESC[110] = 10
   ESC[114] = 13
   ESC[116] = 9
   ESC[117] = -2
end


local CH1 = {}
do
   for i = 0, 255 do CH1[i] = string.char(i) end
end


local stringBuffer = buffer.new()


local u8 = C.new("uint8_t[4]")

local function putUtf8Bytes(putcdata, cp)
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


local CHAR_QUOTE = 34
local CHAR_BACKSLASH = 92
local CHAR_LBRACE = 123
local CHAR_RBRACE = 125
local CHAR_LBRACKET = 91
local CHAR_RBRACKET = 93
local CHAR_COMMA = 44
local CHAR_COLON = 58
local CHAR_MINUS = 45
local CHAR_DOT = 46
local CHAR_E = 101
local CHAR_E_CAP = 69


local ERR_UNTERMINATED_STRING = "Unterminated string"
local ERR_INVALID_NUMBER = "Invalid number"
local ERR_INVALID_FRAC = "Invalid frac"
local ERR_UNESCAPED_CONTROL = "Unescaped control character in string"
local ERR_INVALID_UNICODE = "Invalid unicode escape"
local ERR_INVALID_ESCAPE = "Invalid escape sequence"
local ERR_UNEXPECTED_END_ARRAY = "Unexpected end in array"
local ERR_EXPECTED_COMMA_BRACKET = "Expected ',' or ']' in array"
local ERR_EXPECTED_STRING_KEY = "Expected string key"
local ERR_EXPECTED_COLON = "Expected ':' after key"
local ERR_UNEXPECTED_END_OBJECT = "Unexpected end in object"
local ERR_EXPECTED_COMMA_BRACE = "Expected ',' or '}' in object"
local ERR_UNEXPECTED_END_INPUT = "Unexpected end of input"
local ERR_INVALID_LITERAL_T = "Invalid literal starting with 't'"
local ERR_INVALID_LITERAL_F = "Invalid literal starting with 'f'"
local ERR_INVALID_LITERAL_N = "Invalid literal starting with 'n'"
local ERR_INPUT_EMPTY = "Input string cannot be nil or empty"
local ERR_CDATA_NIL = "CData pointer cannot be nil"
local ERR_CDATA_EMPTY = "CData length cannot be zero"
local ERR_UNEXPECTED_CONTENT = "Unexpected content after JSON"
local ERR_UNEXPECTED_CHAR = "Unexpected character"
local ERR_MAX_DEPTH = "Maximum nesting depth exceeded"

local function skipWs(ptr, len, pos)

   if pos >= len or not WHITESPACE_LUT[ptr[pos]] then
      return pos
   end

   for i = pos + 1, len - 1 do
      if not WHITESPACE_LUT[ptr[i]] then
         return i
      end
   end
   return len
end

local function parseString(ptr, len, pos)
   local start = pos + 1
   local i = start
   local foundBackslash = false


   for j = start, len - 1 do
      local c = ptr[j]
      if c == CHAR_QUOTE then

         return C.string(ptr + start, j - start), j + 1
      elseif c < 32 then

         error(ERR_UNESCAPED_CONTROL)
      elseif c == CHAR_BACKSLASH then

         i = j
         foundBackslash = true
         break
      end
   end


   if not foundBackslash then
      error(ERR_UNTERMINATED_STRING)
   end


   stringBuffer:reset()
   if i > start then
      stringBuffer:putcdata(ptr + start, i - start)
   end


   pos = i
   local chunk = i
   while pos < len do
      local c = ptr[pos]

      if c == CHAR_QUOTE then
         if pos > chunk then
            stringBuffer:putcdata(ptr + chunk, pos - chunk)
         end
         return stringBuffer:get(), pos + 1
      elseif c < 32 then
         error(ERR_UNESCAPED_CONTROL)
      elseif c == CHAR_BACKSLASH then
         if pos > chunk then
            stringBuffer:putcdata(ptr + chunk, pos - chunk)
         end
         pos = pos + 1
         if pos >= len then break end

         local e = ptr[pos]
         local m = ESC[e]

         if m >= 0 then
            stringBuffer:put(CH1[m])
         elseif m == -2 then
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
                  cp = 0xFFFD
               end
            elseif cp >= 0xDC00 and cp <= 0xDFFF then
               cp = 0xFFFD
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


local STRTOD_ENDPTR = C.new("char *[1]")


local STRTOD_SCRATCH_SIZE = 64
local strtodScratch = C.new("char[?]", STRTOD_SCRATCH_SIZE)


local fromLuaString = true

local function callStrtod(ptr, start, len)
   local tokenLen = len - start
   local strStart

   if fromLuaString then

      strStart = C.cast("const char*", ptr) + start
   else

      if tokenLen >= STRTOD_SCRATCH_SIZE then
         STRTOD_SCRATCH_SIZE = tokenLen + 1
         strtodScratch = C.new("char[?]", STRTOD_SCRATCH_SIZE)
      end
      C.copy(strtodScratch, C.cast("const char*", ptr) + start, tokenLen)
      strtodScratch[tokenLen] = 0
      strStart = strtodScratch
   end


   local result = (C.C.strtod)(strStart, STRTOD_ENDPTR)
   local endPos
   if fromLuaString then
      endPos = tonumber(C.cast("intptr_t", STRTOD_ENDPTR[0]) - C.cast("intptr_t", ptr))
   else
      endPos = start + tonumber(C.cast("intptr_t", STRTOD_ENDPTR[0]) - C.cast("intptr_t", strtodScratch))
   end
   return result, endPos
end

local function parseFloat(
   ptr,
   len,
   pos,
   start,
   acc,
   neg)


   local c = ptr[pos]
   if c == CHAR_DOT then
      pos = pos + 1
      if pos >= len or not DIGIT_LUT[ptr[pos]] then
         error(ERR_INVALID_FRAC)
      end


      local frac = 0
      local divisor = 1
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


      if pos >= len then
         return neg and -acc or acc, pos
      end

      c = ptr[pos]
      if c ~= CHAR_E and c ~= CHAR_E_CAP then
         return neg and -acc or acc, pos
      end
   end


   return callStrtod(ptr, start, len)
end

local function parseNumber(ptr, len, pos)
   local start = pos


   local neg = ptr[pos] == CHAR_MINUS and true or false
   if neg then
      pos = pos + 1
      if pos >= len or not DIGIT_LUT[ptr[pos]] then
         error(ERR_INVALID_NUMBER)
      end
   end


   local firstDigit = ptr[pos]
   local acc = firstDigit - 48
   pos = pos + 1


   local c = 0
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

      error(ERR_INVALID_NUMBER)
   end


   if pos >= len or not NUM_FLOAT_LUT[ptr[pos]] then
      return neg and -acc or acc, pos
   end

   return parseFloat(ptr, len, pos, start, acc, neg)
end


local MAX_DEPTH = 100


local parseValue

local function parseArray(ptr, len, pos, depth)
   if depth >= MAX_DEPTH then
      error(ERR_MAX_DEPTH)
   end

   pos = pos + 1
   pos = skipWs(ptr, len, pos)


   if pos >= len then
      error(ERR_UNEXPECTED_END_ARRAY)
   end


   if ptr[pos] == CHAR_RBRACKET then
      return {}, pos + 1
   end

   local result = {}
   local index = 1

   while true do
      local value
      value, pos = parseValue(ptr, len, pos, depth + 1)


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

local function parseObject(ptr, len, pos, depth)
   if depth >= MAX_DEPTH then
      error(ERR_MAX_DEPTH)
   end

   pos = pos + 1
   pos = skipWs(ptr, len, pos)


   if pos >= len then
      error(ERR_UNEXPECTED_END_OBJECT)
   end


   if ptr[pos] == CHAR_RBRACE then
      if OBJECT_MARKER then
         return setmetatable({}, OBJECT_MARKER), pos + 1
      end
      return {}, pos + 1
   end

   local result = {}
   while true do

      if ptr[pos] ~= CHAR_QUOTE then
         error(ERR_EXPECTED_STRING_KEY)
      end


      local key
      key, pos = parseString(ptr, len, pos)


      pos = skipWs(ptr, len, pos)
      if pos >= len or ptr[pos] ~= CHAR_COLON then
         error(ERR_EXPECTED_COLON)
      end
      pos = pos + 1


      pos = skipWs(ptr, len, pos)
      local value
      value, pos = parseValue(ptr, len, pos, depth + 1)

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
         return result, pos
      elseif c == CHAR_COMMA then
         pos = skipWs(ptr, len, pos)
      else
         error(ERR_EXPECTED_COMMA_BRACE)
      end
   end
end

function parseValue(ptr, len, pos, depth)
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
   elseif c == 116 then
      if pos + 3 < len and ptr[pos + 1] == 114 and ptr[pos + 2] == 117 and ptr[pos + 3] == 101 then
         return true, pos + 4
      end
      error(ERR_INVALID_LITERAL_T)
   elseif c == 102 then
      if pos + 4 < len and
         ptr[pos + 1] == 97 and
         ptr[pos + 2] == 108 and
         ptr[pos + 3] == 115 and
         ptr[pos + 4] == 101 then

         return false, pos + 5
      end
      error(ERR_INVALID_LITERAL_F)
   elseif c == 110 then
      if pos + 3 < len and ptr[pos + 1] == 117 and ptr[pos + 2] == 108 and ptr[pos + 3] == 108 then
         return nil, pos + 4
      end
      error(ERR_INVALID_LITERAL_N)
   else
      error(ERR_UNEXPECTED_CHAR)
   end
end




local LC_NUMERIC = (C.os == "Linux") and 1 or 4
local _setlocale = C.C.setlocale






































function parser.parse(jsonStr)
   if not jsonStr or #jsonStr == 0 then
      error(ERR_INPUT_EMPTY)
   end

   fromLuaString = true
   local strPtr = C.cast("uint8_t*", jsonStr)
   local len = #jsonStr
   local result
   local pos

   local _oldLocale = _setlocale(LC_NUMERIC, nil); if _oldLocale ~= nil then local _s = C.string(_oldLocale); if _s ~= "C" and _s ~= "POSIX" then _setlocale(LC_NUMERIC, "C") else _oldLocale = nil end end; result, pos = parseValue(strPtr, len, 0, 0); if _oldLocale ~= nil then _setlocale(LC_NUMERIC, _oldLocale) end

   if result == nil then
      result = NULL_SENTINEL
   end

   pos = skipWs(strPtr, len, pos)
   if pos < len then
      error(ERR_UNEXPECTED_CONTENT)
   end

   return result
end


function parser.parseCData(cdataPtr, length)
   if not cdataPtr then
      error(ERR_CDATA_NIL)
   elseif length <= 0 then
      error(ERR_CDATA_EMPTY)
   end

   fromLuaString = false
   local dataPtr = C.cast("uint8_t*", cdataPtr)
   local result
   local pos

   local _oldLocale = _setlocale(LC_NUMERIC, nil); if _oldLocale ~= nil then local _s = C.string(_oldLocale); if _s ~= "C" and _s ~= "POSIX" then _setlocale(LC_NUMERIC, "C") else _oldLocale = nil end end; result, pos = parseValue(dataPtr, length, 0, 0); if _oldLocale ~= nil then _setlocale(LC_NUMERIC, _oldLocale) end

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
