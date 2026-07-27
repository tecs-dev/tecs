--- An OS window.
---
--- The handle is owned by the platform layer and released by `destroy`, not
--- by a finalizer. Tying GPU-adjacent lifetimes to Lua's collector makes
--- hot reload either leak or double-free, depending on collection order.

local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")

local C <const> = sdl.C
local K <const> = sdl.K

local record Window
    --- The `SDL_Window`. Nil once `destroy` has run, and what a device claims
    --- for presentation.
    handle: loader.CPtr
    --- The title last set, kept so reading it back does not cross the FFI.
    title: string
    _destroyed: boolean
end

local record WindowOptions
    --- Defaults to "tecs".
    title: string
    --- Size in screen coordinates, not pixels: on a high-density display the
    --- drawable is larger. Defaults to 1280 by 720.
    width: integer
    height: integer
    --- Defaults to true, so omitting it gives a resizable window. Only an
    --- explicit false turns it off.
    resizable: boolean
    --- Whether the drawable follows the display's density instead of being
    --- stretched to it. Defaults to true, on the same terms, which is what
    --- makes `getPixelSize` differ from `getSize`.
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

    local title = options.title or "tecs"
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
---
--- The units mouse, touch and pen positions arrive in, so this is what a
--- layout positioned against the pointer uses. `getPixelSize` is what a render
--- target is sized to.
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

--- Sets the window's title, and the copy `title` reports.
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
