











local adapter = require("tecs2d.platform.adapter")

local paths = {}






paths.organisation = "tecs2d"
paths.application = "tecs2d"

local cachedGeneration = -1
local baseCache = nil
local prefCache = nil
local assetsCache = nil


local function fresh()
   local generation = adapter.generation()
   if generation == cachedGeneration then return end
   cachedGeneration = generation
   baseCache = nil
   prefCache = nil
   assetsCache = nil
end





function paths.base()
   fresh()
   if baseCache ~= nil then return baseCache end
   baseCache = adapter.current().basePath()
   return baseCache
end





function paths.pref()
   fresh()
   if prefCache ~= nil then return prefCache end
   prefCache = adapter.current().prefPath(paths.organisation, paths.application)
   return prefCache
end








function paths.assets()
   fresh()
   if assetsCache ~= nil then return assetsCache end

   local override = os.getenv("TECS2D_ASSETS")
   if override == nil or override == "" then
      override = (_G)["__tecs2dContent"]
   end
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


function paths.reset()
   cachedGeneration = adapter.generation()
   baseCache = nil
   prefCache = nil
   assetsCache = nil
end





function paths.setAssets(root)
   fresh()
   assetsCache = root:sub(-1) == "/" and root or root .. "/"
end

return paths
