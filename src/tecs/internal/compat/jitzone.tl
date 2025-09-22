-- love2d doesn't bundle the jit/*.lua stdlib files in its release packages (see https://github.com/love2d/love/issues/1752),
-- so require("jit.zone") fails inside a love game even though jit.profile (C-baked) works fine. This registers the canonical
-- implementation on package.preload; on systems that ship the real file, Lua's loader still resolves to it first
-- (package.loaded is checked before preload, and if a user has already required jit.zone, their version is kept).
--
-- This is copied from LuaJIT 2.1/src/jit/zone.lua with one change: __call defaults to a no-op and the real push/pop
-- is stashed on the metatable so tecs.utils.profile can swap it in only while a profile session is active.
-- (MIT License, Copyright (C) 2005-2026 Mike Pall.)

local loaded = package.loaded as {string: any}
local preload = package.preload as {string: function(): any}

if not loaded["jit.zone"] and not preload["jit.zone"] then
    preload["jit.zone"] = function(): any
        local remove = table.remove

        local noopCall = function(_t: {any: any}, _name: any): any end
        -- Pop silently no-ops on an empty stack. flamegraph.start/stop can
        -- flip `__call` mid-frame (e.g. from inside a system running under
        -- MCP), leaving pipeline push/pop pairs asymmetric. Popping on empty
        -- then would crash the frame; returning nil lets the pipeline recover
        -- by the next balanced frame.
        local realCall = function(t: {any: any}, name: any): any
            local arr = t as {any}
            if name then
                arr[#arr + 1] = name
            else
                return remove(arr)
            end
        end

        local tbl = {
            flush = function(t: {any: any})
                local arr = t as {any}
                for i = #arr, 1, -1 do arr[i] = nil end
            end,
            get = function(t: {any: any}): any
                local arr = t as {any}
                return arr[#arr]
            end,
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
