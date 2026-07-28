-- LOVE release packages may omit LuaJIT's jit/*.lua library files, so
-- require("jit.zone") can fail even though jit.profile is available. Register
-- a fallback in package.preload without replacing an already-loaded module or
-- an existing preload entry.
--
-- Based on LuaJIT 2.1/src/jit/zone.lua, with __call defaulting to a no-op.
-- The real/no-op handlers are kept on the metatable for compatibility with
-- code that wants to toggle zone recording explicitly.

local loaded = package.loaded as {string: any}
local preload = package.preload as {string: function(): any}

if not loaded["jit.zone"] and not preload["jit.zone"] then
    preload["jit.zone"] = function(): any
        local remove = table.remove

        local noopCall = function(_t: {any: any}, _name: any): any end
        local realCall = function(t: {any: any}, name: any): any
            local arr = t as {any}
            if name then
                arr[#arr + 1] = name
            else
                return remove(arr)
            end
        end

        local tbl = {
            flush = function(t: {any: any}) local arr = t as {any}; for i = #arr, 1, -1 do arr[i] = nil end end,
            get = function(t: {any: any}): any local arr = t as {any}; return arr[#arr] end,
        }
        local mt = {
            __call = noopCall,
            __realCall = realCall,
            __noopCall = noopCall,
        }
        return (setmetatable as function(any, any): any)(tbl, mt)
    end
end

return true
