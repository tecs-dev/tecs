--- Encoding a rendered texture as PNG bytes.
---
--- Readback is synchronous: a screenshot asks for the frame that has already
--- been submitted, so the CPU waits for those pixels before libpng can read
--- them. The Rust encoder returns an owned byte allocation, which is copied
--- into Lua before Rust releases it. The resulting bytes go through
--- `filesystem`, keeping writes behind the platform storage seam.

local rust <const> = require("tecs.ffi.rust")
local loader <const> = require("tecs.ffi.loader")
local Texture <const> = require("tecs.gpu.Texture")
local filesystem <const> = require("tecs.platform.filesystem")

local RUST <const> = rust.C

local record screenshot
end

--- Encodes `texture` as PNG.
---
--- The alpha channel is ignored. The composited target carries intermediate
--- alpha values and a screenshot represents what reached the display, not a
--- transparent layer for another compositor.
function screenshot.encode(texture: Texture): string, string
    if texture == nil then
        return nil, "no texture to capture"
    end

    local ok, value = pcall(function(): loader.CArray return texture:readback() end) as (boolean, any)
    if not ok then
        return nil, tostring(value)
    end
    local pixels = value as loader.CArray
    local width, height = texture.width, texture.height
    local encoded = RUST.tecsImageEncodePngRgbx(pixels as loader.CValue, width * height * 4, width, height, width * 4)
    if encoded == nil then
        return nil, "PNG encode failed: " .. loader.toString(RUST.tecsRustError())
    end
    local bytes = loader.toBytes(
        RUST.tecsBytesData(encoded) as loader.CValue, tonumber(RUST.tecsBytesLength(encoded)) as integer
    )
    RUST.tecsBytesDestroy(encoded)
    return bytes
end

--- Encodes `texture` and writes it through the installed storage backend.
function screenshot.save(texture: Texture, path: string): boolean, string
    local bytes, reason = screenshot.encode(texture)
    if bytes == nil then
        return false, reason
    end
    return filesystem.write(path, bytes)
end

return screenshot
