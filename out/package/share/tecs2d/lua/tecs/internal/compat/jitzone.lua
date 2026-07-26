








local loaded = package.loaded
local preload = package.preload

if not loaded["jit.zone"] and not preload["jit.zone"] then
   preload["jit.zone"] = function()
      local remove = table.remove

      local noopCall = function(_t, _name) end
      local realCall = function(t, name)
         local arr = t
         if name then
            arr[#arr + 1] = name
         else
            return remove(arr)
         end
      end

      local tbl = {
         flush = function(t)
            local arr = t
            for i = #arr, 1, -1 do arr[i] = nil end
         end,
         get = function(t)
            local arr = t
            return arr[#arr]
         end,
      }
      local mt = {
         __call = noopCall,
         __realCall = realCall,
         __noopCall = noopCall,
      }
      return (setmetatable)(tbl, mt)
   end
end

return true
