--- GPU column backing: marks a GPU-mirrored component's storage so its FFI
--- columns are allocated as love.data.ByteData. The shadow path then uploads
--- a column's backing straight to its SSBO with no staging copy.
---
--- Only identity-layout columns qualify (those whose canonical bytes already
--- match std430, so they upload without a repack). Must run before the
--- component's columns are created, i.e. at shadow registration (install),
--- which is before the game plugin spawns.

local ffi <const> = require("ffi")
local tecs <const> = require("tecs")

local gpu_backing = {}

-- Allocate a column's backing as a love.data.ByteData; return the typed
-- pointer plus the ByteData itself (the holder that keeps the memory alive).
local function byteDataColumn(nbytes: integer, structName: string): (any, any)
    local bd = love.data.newByteData(nbytes)
    local ptr = ffi.cast(structName .. "*", bd:getFFIPointer())
    return ptr, bd
end

--- Enable ByteData backing for `component`'s column storage when `layout` is
--- an identity layout. No-op otherwise, or if the storage has no custom
--- allocator hook (non-FFI storages). Idempotent.
function gpu_backing.enable(component: tecs.Component, layout: {string:any})
    if not layout or not layout.identity then return end
    local s = (component as {string:any}).storage as {string:any}
    if s and s.setColumnAllocator then
        local set = s.setColumnAllocator as function(any, function(integer, string): (any, any))
        set(s, byteDataColumn)
    end
end

return gpu_backing
