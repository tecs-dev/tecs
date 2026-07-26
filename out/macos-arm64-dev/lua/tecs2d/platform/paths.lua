










local sdl = require("tecs2d.ffi.sdl3")
local loader = require("tecs2d.ffi.loader")

local C = sdl.C

local paths = {}






paths.organisation = "tecs2d"
paths.application = "tecs2d"

local baseCache = nil
local prefCache = nil
local assetsCache = nil





function paths.base()
   if baseCache ~= nil then return baseCache end
   local given = C.SDL_GetBasePath()
   baseCache = given == nil and "" or loader.toString(given)
   return baseCache
end





function paths.pref()
   if prefCache ~= nil then return prefCache end
   local given = C.SDL_GetPrefPath(paths.organisation, paths.application)
   if given == nil then
      error(("tecs2d: no writable directory: %s"):format(sdl.error()), 2)
   end
   prefCache = loader.toString(given)
   C.SDL_free(given)
   return prefCache
end





function paths.assets()
   if assetsCache ~= nil then return assetsCache end
   local override = os.getenv("TECS2D_ASSETS")
   if override ~= nil and override ~= "" then
      assetsCache = override:sub(-1) == "/" and override or override .. "/"
   else
      assetsCache = paths.base()
   end
   return assetsCache
end


function paths.asset(relative)
   return paths.assets() .. relative
end


function paths.writable(relative)
   return paths.pref() .. relative
end


function paths.setAssets(root)
   assetsCache = root:sub(-1) == "/" and root or root .. "/"
end

return paths
