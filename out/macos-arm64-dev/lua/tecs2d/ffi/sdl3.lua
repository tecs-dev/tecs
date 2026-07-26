





local loader = require("tecs2d.ffi.loader")

loader.declare("sdl3")

local namespace, libraryPath =
loader.library("SDL3", "sdl3", "TECS2D_SDL3_PATH", "sdl3")

local sdl3 = {}









sdl3.C = namespace
sdl3.K = loader.constants("sdl3")
sdl3.path = libraryPath


function sdl3.error()
   local message = sdl3.C.SDL_GetError()
   if message == nil then return "(no error)" end
   return loader.toString(message)
end


function sdl3.fail(what)
   error(("tecs2d: %s failed: %s"):format(what, sdl3.error()), 3)
end


function sdl3.check(ok, what)
   if not ok then sdl3.fail(what) end
end

return sdl3
