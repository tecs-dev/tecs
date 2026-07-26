--- An OS window.
---
--- The handle is owned by the platform layer and released by `destroy`, not
--- by a finalizer. Tying GPU-adjacent lifetimes to Lua's collector makes
--- hot reload either leak or double-free, depending on collection order.

local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K

local record Window
    handle: loader.CPtr
    title: string
    _destroyed: boolean
end

local record WindowOptions
    title: string
    width: integer
    height: integer
    resizable: boolean
    highPixelDensity: boolean
end

local WindowMT <const>: metatable<Window> = { __index = Window }

--- Creates a window. Requires `SDL_Init(SDL_INIT_VIDEO)` to have run.
function Window.create(options: WindowOptions): Window
    local flags = 0
    if options.resizable ~= false then
        flags = flags + K.SDL_WINDOW_RESIZABLE
    end
    if options.highPixelDensity ~= false then
        flags = flags + K.SDL_WINDOW_HIGH_PIXEL_DENSITY
    end

    local title = options.title or "tecs2d"
    local handle = C.SDL_CreateWindow(title,
        options.width or 1280, options.height or 720, flags)
    if handle == nil then sdl.fail("SDL_CreateWindow") end

    local self = setmetatable({} as Window, WindowMT)
    self.handle = handle
    self.title = title
    self._destroyed = false
    return self
end

-- Reused out-parameters. Window size is queried per resize, not per frame,
-- but there is no reason to allocate for it either.
local widthOut <const> = loader.newArray("int[1]")
local heightOut <const> = loader.newArray("int[1]")

--- Returns the window's size in screen coordinates.
function Window:getSize(): integer, integer
    C.SDL_GetWindowSize(self.handle, widthOut, heightOut)
    return widthOut[0] as integer, heightOut[0] as integer
end

--- Returns the drawable size in pixels, which differs from `getSize` on
--- high-density displays.
function Window:getPixelSize(): integer, integer
    C.SDL_GetWindowSizeInPixels(self.handle, widthOut, heightOut)
    return widthOut[0] as integer, heightOut[0] as integer
end

function Window:setTitle(title: string)
    self.title = title
    C.SDL_SetWindowTitle(self.handle, title)
end

--- Releases the window. Safe to call more than once.
function Window:destroy()
    if self._destroyed then return end
    self._destroyed = true
    C.SDL_DestroyWindow(self.handle)
    self.handle = nil
end

return Window
