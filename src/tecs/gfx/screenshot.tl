--- Encoding a rendered texture as PNG bytes.
---
--- Readback is synchronous: a screenshot asks for the frame that has already
--- been submitted, so the CPU waits for those pixels before libpng can read
--- them. The resulting bytes go through `filesystem`, which keeps writing
--- behind the platform storage seam rather than handing SDL_image a host path.

local sdl <const> = require("tecs.ffi.sdl3")
local image <const> = require("tecs.ffi.sdl3image")
local loader <const> = require("tecs.ffi.loader")
local Texture <const> = require("tecs.gpu.Texture")
local filesystem <const> = require("tecs.platform.filesystem")

local C <const> = sdl.C
local IMG <const> = image.C

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
    local surface = C.SDL_CreateSurfaceFrom(width, height, C.SDL_PIXELFORMAT_XBGR8888, pixels, width * 4)
    if surface == nil then
        return nil, "SDL_CreateSurfaceFrom failed: " .. sdl.error()
    end

    local output = C.SDL_IOFromDynamicMem()
    if output == nil then
        C.SDL_DestroySurface(surface)
        return nil, "SDL_IOFromDynamicMem failed: " .. sdl.error()
    end

    local saved = IMG.IMG_SavePNG_IO(surface, output, false) as boolean
    C.SDL_DestroySurface(surface)
    if not saved then
        local reason = "IMG_SavePNG_IO failed: " .. sdl.error()
        C.SDL_CloseIO(output)
        return nil, reason
    end

    local size = tonumber(C.SDL_GetIOSize(output)) as integer
    if size < 0 or tonumber(C.SDL_SeekIO(output, 0, C.SDL_IO_SEEK_SET)) < 0 then
        local reason = "reading encoded PNG failed: " .. sdl.error()
        C.SDL_CloseIO(output)
        return nil, reason
    end

    local bytes = loader.newArray("uint8_t[?]", size)
    local read = tonumber(C.SDL_ReadIO(output, bytes, size)) as integer
    C.SDL_CloseIO(output)
    if read ~= size then
        return nil, ("reading encoded PNG stopped after %d of %d bytes"):format(read, size)
    end
    return loader.toBytes(bytes as loader.CValue, size)
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
