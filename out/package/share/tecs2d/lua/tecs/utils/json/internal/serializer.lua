





local C = require("ffi")
local buffer = require("string.buffer")
local bit = require("bit")
local table_clear = require("table.clear")

local rshift = bit.rshift
local band = bit.band
local huge = math.huge

local serializer = {}


local NULL_SENTINEL = nil


local EMPTY_OBJECT_SENTINEL = nil


function serializer.setNullSentinel(sentinel)
   NULL_SENTINEL = sentinel
end


function serializer.setEmptyObjectSentinel(sentinel)
   EMPTY_OBJECT_SENTINEL = sentinel
end




local OBJECT_MARKER = nil


function serializer.setObjectMarker(marker)
   OBJECT_MARKER = marker
end




local function isEmptyObject(tbl)
   if tbl == EMPTY_OBJECT_SENTINEL then return true end
   if OBJECT_MARKER == nil or (getmetatable(tbl)) ~= OBJECT_MARKER then
      return false
   end
   return next(tbl) == nil
end


local CHAR_QUOTE = 34
local CHAR_BACKSLASH = 92
local EMPTY_STRING = '""'


local S_QUOTE = "\""
local S_LBRACE = "{"
local S_RBRACE = "}"
local S_LBRACKET = "["
local S_RBRACKET = "]"
local S_COMMA = ","
local S_COLON = ":"
local S_COLON_SPACE = ": "
local S_NL = "\n"
local S_TRUE = "true"
local S_FALSE = "false"
local S_NULL = "null"
local S_EMPTY_ARRAY = "[]"
local S_EMPTY_OBJECT = "{}"


local ERR_CIRCULAR_REF = "Circular reference detected"
local ERR_UNSUPPORTED_TYPE = "Unsupported type for JSON serialization"
local ERR_INVALID_NUMBER = "Invalid number (NaN or Inf)"


local NEEDS_ESCAPE = C.new("bool[256]")
NEEDS_ESCAPE[CHAR_QUOTE] = true
NEEDS_ESCAPE[CHAR_BACKSLASH] = true

C.fill(C.cast("uint8_t*", NEEDS_ESCAPE), 32, 1)


local ESC_SIMPLE = {}
ESC_SIMPLE[34] = "\\\""
ESC_SIMPLE[92] = "\\\\"
ESC_SIMPLE[8] = "\\b"
ESC_SIMPLE[9] = "\\t"
ESC_SIMPLE[10] = "\\n"
ESC_SIMPLE[12] = "\\f"
ESC_SIMPLE[13] = "\\r"


local HEX = "0123456789abcdef"
local ESC_U00 = {}
do
   for c = 0, 31 do
      local hi = string.sub(HEX, rshift(c, 4) + 1, rshift(c, 4) + 1)
      local lo = string.sub(HEX, band(c, 0xF) + 1, band(c, 0xF) + 1)
      ESC_U00[c] = "\\u00" .. hi .. lo
   end
end


local BUF = buffer.new()
local SEEN = {}

local put = BUF.put
local putcdata = BUF.putcdata

local function serializeStringSlow(p, len)
   put(BUF, S_QUOTE)
   local start = 0
   for j = 0, len - 1 do
      local c = p[j]
      if NEEDS_ESCAPE[c] then
         if j > start then
            putcdata(BUF, p + start, j - start)
         end
         put(BUF, ESC_SIMPLE[c] or ESC_U00[c])
         start = j + 1
      end
   end

   if start < len then
      putcdata(BUF, p + start, len - start)
   end

   put(BUF, S_QUOTE)
end


local function serializeString(str)
   local len = #str
   if len == 0 then
      put(BUF, EMPTY_STRING)
      return
   end


   local p = C.cast("const uint8_t*", str)
   for i = 0, len - 1 do
      if NEEDS_ESCAPE[p[i]] then
         serializeStringSlow(p, len)
         return
      end
   end

   put(BUF, S_QUOTE)
   putcdata(BUF, p, len)
   put(BUF, S_QUOTE)
end


local function validateNumber(num)
   if num ~= num or num == huge or num == -huge then
      error(ERR_INVALID_NUMBER)
   end
end


local function collectSortedKeys(tbl)
   local keys = {}
   local n = 0
   local k = next(tbl)
   while k ~= nil do
      if type(k) == "string" then
         n = n + 1
         keys[n] = k
      end
      k = next(tbl, k)
   end
   table.sort(keys)
   return keys, n
end






local serializeValueCompact

local function serializeArrayCompact(tbl, sortKeys)
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

local function serializeObjectCompact(tbl, sortKeys)
   local first = true
   local k = next(tbl)
   while k ~= nil do
      if type(k) == "string" then
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

local function serializeObjectCompactSorted(tbl, sortKeys)
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

local function serializeTableCompact(tbl, sortKeys)
   if SEEN[tbl] then
      error(ERR_CIRCULAR_REF)
   end
   SEEN[tbl] = true


   if isEmptyObject(tbl) then
      put(BUF, S_EMPTY_OBJECT)
   elseif rawget(tbl, 1) ~= nil or next(tbl) == nil then
      serializeArrayCompact(tbl, sortKeys)
   elseif sortKeys then
      serializeObjectCompactSorted(tbl, sortKeys)
   else
      serializeObjectCompact(tbl, sortKeys)
   end

   SEEN[tbl] = nil
end

function serializeValueCompact(value, sortKeys)
   local t = type(value)
   if t == "string" then
      serializeString(value)
   elseif t == "number" then
      local num = value
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
         serializeTableCompact(value, sortKeys)
      end
   else
      error(ERR_UNSUPPORTED_TYPE .. ": " .. t)
   end
end






local serializeValuePretty

local function serializeArrayPretty(
   tbl,
   currentIndent,
   indentStr,
   sortKeys)

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
   tbl,
   currentIndent,
   indentStr,
   sortKeys)

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
         if type(k) == "string" then
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
   tbl,
   currentIndent,
   indentStr,
   sortKeys)

   if SEEN[tbl] then
      error(ERR_CIRCULAR_REF)
   end
   SEEN[tbl] = true


   if isEmptyObject(tbl) then
      put(BUF, S_EMPTY_OBJECT)
   elseif rawget(tbl, 1) ~= nil or next(tbl) == nil then
      serializeArrayPretty(tbl, currentIndent, indentStr, sortKeys)
   else
      serializeObjectPretty(tbl, currentIndent, indentStr, sortKeys)
   end

   SEEN[tbl] = nil
end

function serializeValuePretty(
   value,
   currentIndent,
   indentStr,
   sortKeys)

   local t = type(value)
   if t == "string" then
      serializeString(value)
   elseif t == "number" then
      local num = value
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
         serializeTablePretty(value, currentIndent, indentStr, sortKeys)
      end
   else
      error(ERR_UNSUPPORTED_TYPE .. ": " .. t)
   end
end





function serializer.serialize(value, sortKeys)
   BUF:reset()
   table_clear(SEEN)
   serializeValueCompact(value, sortKeys and true or false)
   return BUF:get()
end

function serializer.serializePretty(value, sortKeys, indent)
   BUF:reset()
   table_clear(SEEN)
   local indentStr = indent or "  "
   local doSortKeys = sortKeys ~= false
   serializeValuePretty(value, "", indentStr, doSortKeys)
   return BUF:get()
end

return serializer
