local types = require("tecs.types")
local logging = require("tecs.utils.logging")



local ContextModule = {}






local KEY_COUNTER = 0
local NAMED_KEYS = {}

function ContextModule.newKey(name, _forType)
   if name then


      local existing = NAMED_KEYS[name]
      if existing then
         return existing
      end
      KEY_COUNTER = KEY_COUNTER + 1
      NAMED_KEYS[name] = KEY_COUNTER
      return KEY_COUNTER
   end
   KEY_COUNTER = KEY_COUNTER + 1
   logging.getLogger("tecs.context"):warn(
   "Context key #%d created without a name; pass a name to newKey so " ..
   "tools (MCP inspect, tecs info --keys) can find it",
   KEY_COUNTER)


   return KEY_COUNTER
end

function ContextModule.findKey(name)
   local id = NAMED_KEYS[name]
   if id == nil then return nil end
   return id
end

function ContextModule.listKeys()
   local out = {}
   for name, id in pairs(NAMED_KEYS) do
      out[name] = id
   end
   return out
end

function ContextModule.new()
   return {}
end

return ContextModule
