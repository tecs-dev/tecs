-- #region tecs.data.utf8.length
--[=[
Counts Unicode codepoints rather than bytes.
]=]
local utf8 <const> = require("tecs.data.utf8")
assert(utf8.length("A€") == 2)
-- #endregion tecs.data.utf8.length

-- #region tecs.data.utf8.decodeAt
--[=[
Reads forward from a one-based byte offset.
]=]
local utf8 <const> = require("tecs.data.utf8")
local codepoint, nextOffset = utf8.decodeAt("A€", 2)
assert(codepoint == 0x20ac)
assert(nextOffset == 5)
-- #endregion tecs.data.utf8.decodeAt

-- #region tecs.data.utf8.decodeBefore
--[=[
Reads backward from the end cursor.
]=]
local utf8 <const> = require("tecs.data.utf8")
local codepoint, startOffset = utf8.decodeBefore("A€", 5)
assert(codepoint == 0x20ac)
assert(startOffset == 2)
-- #endregion tecs.data.utf8.decodeBefore

-- #region tecs.data.utf8.encode
--[=[
Encodes a Unicode scalar value.
]=]
local utf8 <const> = require("tecs.data.utf8")
assert(utf8.encode(0x20ac) == "€")
-- #endregion tecs.data.utf8.encode

-- #region tecs.data.utf8.isValid
--[=[
Rejects malformed UTF-8 bytes.
]=]
local utf8 <const> = require("tecs.data.utf8")
assert(utf8.isValid("café"))
assert(not utf8.isValid("\xff"))
-- #endregion tecs.data.utf8.isValid

-- #region tecs.data.utf8.validPrefixLength
--[=[
Retains a zero-copy prefix at a complete codepoint boundary.
]=]
local tecs <const> = require("tecs")
local bytes <const> = tecs.io.newBuffer("A€B")
local all <const> = bytes:view()
local count <const> = tecs.data.utf8.validPrefixLength(all, 3)
local prefix <const> = all:view(0, count)
assert(prefix:getString() == "A")
prefix:close()
all:close()
bytes:close()
-- #endregion tecs.data.utf8.validPrefixLength

-- #region tecs.data.utf8.truncate
--[=[
Leaves a multibyte codepoint intact at the byte limit.
]=]
local utf8 <const> = require("tecs.data.utf8")
assert(utf8.truncate("A€B", 4) == "A€")
-- #endregion tecs.data.utf8.truncate
