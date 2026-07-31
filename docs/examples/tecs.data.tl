-- #region tecs.data.hexEncodeInto
--[=[
Reuses a buffer for hexadecimal output.
]=]
local tecs <const> = require("tecs")
local output <const> = tecs.io.newBuffer()
tecs.data.hexEncodeInto("\0Tecs", output)
assert(output:getString() == "0054656373")
output:close()
-- #endregion tecs.data.hexEncodeInto

-- #region tecs.data.hexDecodeInto
--[=[
Decodes hexadecimal bytes without allocating a result string.
]=]
local tecs <const> = require("tecs")
local output <const> = tecs.io.newBuffer()
tecs.data.hexDecodeInto("0054656373", output)
assert(output:getString() == "\0Tecs")
output:close()
-- #endregion tecs.data.hexDecodeInto

-- #region tecs.data.base64EncodeInto
--[=[
Reuses a buffer for Base64 text.
]=]
local tecs <const> = require("tecs")
local output <const> = tecs.io.newBuffer()
tecs.data.base64EncodeInto("\0Tecs", output)
assert(output:getString() == "AFRlY3M=")
output:close()
-- #endregion tecs.data.base64EncodeInto

-- #region tecs.data.base64DecodeInto
--[=[
Decodes Base64 directly into owned binary memory.
]=]
local tecs <const> = require("tecs")
local output <const> = tecs.io.newBuffer()
tecs.data.base64DecodeInto("AFRlY3M=", output)
assert(output:getString() == "\0Tecs")
output:close()
-- #endregion tecs.data.base64DecodeInto

-- #region tecs.data.deflateInto
--[=[
Reuses one buffer for zlib-wrapped compressed output.
]=]
local tecs <const> = require("tecs")
local compressed <const> = tecs.io.newBuffer()
tecs.data.deflateInto("snapshot bytes", compressed)
local view <const> = compressed:view()
assert(tecs.data.inflate(view) == "snapshot bytes")
view:close()
compressed:close()
-- #endregion tecs.data.deflateInto

-- #region tecs.data.deflateRawInto
--[=[
Writes raw RFC 1951 DEFLATE bytes into a buffer.
]=]
local tecs <const> = require("tecs")
local compressed <const> = tecs.io.newBuffer()
tecs.data.deflateRawInto("block bytes", compressed)
local view <const> = compressed:view()
assert(tecs.data.inflateRaw(view) == "block bytes")
view:close()
compressed:close()
-- #endregion tecs.data.deflateRawInto

-- #region tecs.data.inflateInto
--[=[
Enforces an output ceiling while inflating into reusable memory.
]=]
local tecs <const> = require("tecs")
local compressed <const> = tecs.data.deflate("snapshot bytes")
local restored <const> = tecs.io.newBuffer()
tecs.data.inflateInto(compressed, restored, 14, 1024)
assert(restored:getString() == "snapshot bytes")
restored:close()
-- #endregion tecs.data.inflateInto

-- #region tecs.data.inflateRawInto
--[=[
Inflates raw DEFLATE into reusable memory.
]=]
local tecs <const> = require("tecs")
local compressed <const> = tecs.data.deflateRaw("block bytes")
local restored <const> = tecs.io.newBuffer()
tecs.data.inflateRawInto(compressed, restored, 11, 1024)
assert(restored:getString() == "block bytes")
restored:close()
-- #endregion tecs.data.inflateRawInto

-- #region tecs.data.transcodeInto
--[=[
Converts text directly into reusable binary memory.
]=]
local tecs <const> = require("tecs")
local utf16 <const> = tecs.io.newBuffer()
tecs.data.transcodeInto("A€", "UTF-8", "UTF-16LE", utf16)
local view <const> = utf16:view()
assert(tecs.data.transcode(view, "UTF-16LE", "UTF-8") == "A€")
view:close()
utf16:close()
-- #endregion tecs.data.transcodeInto
