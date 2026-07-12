--- PNG header inspection for screenshot assertions.
--- Decodes base64 and parses the PNG signature + IHDR chunk. Full pixel
--- decoding is intentionally out of scope; pixel probes go through the
--- game via run_lua + love.graphics.captureScreenshot instead.

local record png_util
    record Header
        width: integer
        height: integer
        bitDepth: integer
        colorType: integer
    end

    base64Decode: function(data: string): string
    parseHeader: function(pngBytes: string): Header, string
end

local B64_CHARS <const> = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64Lookup: {string: integer} = {}
for i = 1, #B64_CHARS do
    b64Lookup[B64_CHARS:sub(i, i)] = i - 1
end

function png_util.base64Decode(data: string): string
    local cleaned = data:gsub("[^" .. B64_CHARS .. "=]", "")
    local out: {string} = {}
    for chunk in cleaned:gmatch("(....)") do
        local c1 = b64Lookup[chunk:sub(1, 1)] or 0
        local c2 = b64Lookup[chunk:sub(2, 2)] or 0
        local c3v = chunk:sub(3, 3)
        local c4v = chunk:sub(4, 4)
        local n = c1 * 262144 + c2 * 4096
            + (b64Lookup[c3v] or 0) * 64 + (b64Lookup[c4v] or 0)
        local b1 = math.floor(n / 65536) % 256
        local b2 = math.floor(n / 256) % 256
        local b3 = n % 256
        if c4v ~= "=" then
            out[#out + 1] = string.char(b1, b2, b3)
        elseif c3v ~= "=" then
            out[#out + 1] = string.char(b1, b2)
        else
            out[#out + 1] = string.char(b1)
        end
    end
    return table.concat(out)
end

local function readU32BE(bytes: string, offset: integer): integer
    local a, b, c, d = bytes:byte(offset, offset + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local PNG_MAGIC <const> = "\137PNG\r\n\26\n"

function png_util.parseHeader(pngBytes: string): png_util.Header, string
    if #pngBytes < 33 then
        return nil, "too short to be a PNG (" .. tostring(#pngBytes) .. " bytes)"
    end
    if pngBytes:sub(1, 8) ~= PNG_MAGIC then
        return nil, "bad PNG signature"
    end
    if pngBytes:sub(13, 16) ~= "IHDR" then
        return nil, "first chunk is not IHDR"
    end
    return {
        width = readU32BE(pngBytes, 17),
        height = readU32BE(pngBytes, 21),
        bitDepth = pngBytes:byte(25),
        colorType = pngBytes:byte(26),
    }, nil
end

return png_util
