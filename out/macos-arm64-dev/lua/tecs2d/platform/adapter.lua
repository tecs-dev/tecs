







































local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")
local events = require("tecs2d.platform.events")

local C = sdl.C

local adapter = { Platform = {} }






























local sdlPlatform = {
   name = "sdl",

   basePath = function()
      local given = C.SDL_GetBasePath()
      return given == nil and "" or loader.toString(given)
   end,

   prefPath = function(organisation, application)
      local given = C.SDL_GetPrefPath(organisation, application)
      if given == nil then
         error(("tecs2d: no writable directory: %s"):format(sdl.error()), 2)
      end
      local path = loader.toString(given)
      C.SDL_free(given)
      return path
   end,

   shaderFormat = function()

      local ffi = require("ffi")
      if ffi.os == "OSX" or ffi.os == "iOS" then
         return sdl.K.SDL_GPU_SHADERFORMAT_MSL
      end
      return sdl.K.SDL_GPU_SHADERFORMAT_SPIRV
   end,



   events = nil,

   dynamicLibraries = not loader.isStatic("sdl3"),
}

local installed = sdlPlatform






local generation = 0






function adapter.install(platform)
   if platform == nil then
      error("tecs2d: a platform is required", 2)
   end
   for _, required in ipairs({ "basePath", "prefPath", "shaderFormat" }) do
      if (platform)[required] == nil then
         error(("tecs2d: a platform must supply %s"):format(required), 2)
      end
   end
   installed = platform
   generation = generation + 1


   events.source = platform.events
end


function adapter.current()
   return installed
end


function adapter.reset()
   installed = sdlPlatform
   events.source = nil
   generation = generation + 1
end


function adapter.generation()
   return generation
end

return adapter
