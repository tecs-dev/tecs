





local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")

local C = sdl.C
local K = sdl.K

local Window = {}













local WindowMT = { __index = Window }


function Window.create(options)
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

   local self = setmetatable({}, WindowMT)
   self.handle = handle
   self.title = title
   self._destroyed = false
   return self
end



local widthOut = loader.newArray("int[1]")
local heightOut = loader.newArray("int[1]")


function Window:getSize()
   C.SDL_GetWindowSize(self.handle, widthOut, heightOut)
   return widthOut[0], heightOut[0]
end



function Window:getPixelSize()
   C.SDL_GetWindowSizeInPixels(self.handle, widthOut, heightOut)
   return widthOut[0], heightOut[0]
end

function Window:setTitle(title)
   self.title = title
   C.SDL_SetWindowTitle(self.handle, title)
end


function Window:destroy()
   if self._destroyed then return end
   self._destroyed = true
   C.SDL_DestroyWindow(self.handle)
   self.handle = nil
end

return Window
