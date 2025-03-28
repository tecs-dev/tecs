--[[
    pool.tl - Table pooling abstraction for Tecs

    This module provides a simple object pooling system for arrays and maps to reduce garbage collection pressure.
    Tables are cleared when returned to the pool and reused when requested.

    WARNING: This is an internal module and should not be required directly.
]]

local compat <const> = require("tecs.internal.utils.compat")
local table_clear <const> = compat.clear
local table_new <const> = compat.new

local MAX_ARRAY_SIZE <const> = 256
local MAX_POOL_SIZE <const> = 64

local record pool
    --- A global immutable empty table that can be used as a placeholder.
    EMPTY: {any}

    --- Acquire an array from the pool or create a new one
    --- @param sizeHint Optional hint for expected array size
    --- @return An empty array
    acquireArray: function<T>(sizeHint?: integer): {T}

    --- Release an array back to the pool
    --- Arrays larger than MAX_ARRAY_SIZE are not pooled
    --- @param array The array to release
    releaseArray: function<T>(array: {T})

    --- Acquire a map from the pool or create a new one
    --- @param sizeHint Optional hint for expected number of hash entries
    --- @return An empty map
    acquireMap: function<T>(sizeHint?: integer): T

    --- Release a map back to the pool
    --- @param map The map to release
    releaseMap: function(map: any)

    --- Clear all pools, releasing all pooled tables
    clear: function()

    --- Create a custom pool for arbitrary objects
    --- @param maxSize Maximum number of items to pool
    --- @param clearFn Optional function to clear/reset items when released
    --- @return A new custom pool
    createCustomPool: function<T>(maxSize: integer, clearFn?: function(T)): CustomPool<T>

    --- A generic pool for custom objects
    record CustomPool<T>
        items: {T}
        size: integer
        maxSize: integer
        clearFn: function(T)

        --- Acquire an item from the pool or return nil if empty
        --- @return An item from the pool or nil
        acquire: function(self: CustomPool<T>): T

        --- Release an item back to the pool
        --- @param item The item to release
        release: function(self: CustomPool<T>, item: T)
    end
end

-------------------------------------------------------------------------------
-- EMPTY implementation
-------------------------------------------------------------------------------

-- Global immutable empty table with protection against modifications
local READONLY_MT <const> = {
    __newindex = function(_t: any, _k: any, _v: any)
        error("Attempt to modify read-only EMPTY table")
    end,
    __metatable = "protected"
}

local GLOBAL_EMPTY <const> = setmetatable({}, READONLY_MT)
pool.EMPTY = GLOBAL_EMPTY

-------------------------------------------------------------------------------
-- Global pool implementation
-------------------------------------------------------------------------------

local arrayPool: {table} = {}
local arrayPoolSize = 0
local mapPool: {table} = {}
local mapPoolSize = 0

function pool.acquireArray<T>(sizeHint?: integer): {T}
    local n = arrayPoolSize
    if n > 0 then
        local array = arrayPool[n] as {T}
        arrayPool[n] = nil
        arrayPoolSize = n - 1
        return array
    elseif sizeHint then
        return table_new(sizeHint, 0) as {T}
    else
        return {}
    end
end

function pool.releaseArray<T>(array: {T})
    if arrayPoolSize >= MAX_POOL_SIZE or not array or #array > MAX_ARRAY_SIZE then
        return
    end

    table_clear(array as table)
    arrayPoolSize = arrayPoolSize + 1
    arrayPool[arrayPoolSize] = array as table
end

function pool.acquireMap<T>(sizeHint?: integer): T
    local n = mapPoolSize
    if n > 0 then
        local map = mapPool[n] as T
        mapPool[n] = nil
        mapPoolSize = n - 1
        return map
    elseif sizeHint then
        return table_new(0, sizeHint) as T
    else
        return {} as T
    end
end

function pool.releaseMap(map: any)
    if mapPoolSize < MAX_POOL_SIZE then
        table_clear(map as table)
        mapPoolSize = mapPoolSize + 1
        mapPool[mapPoolSize] = map as table
    end
end

function pool.clear()
    table_clear(arrayPool)
    arrayPoolSize = 0
    table_clear(mapPool)
    mapPoolSize = 0
end

-------------------------------------------------------------------------------
-- Custom pool implementation
-------------------------------------------------------------------------------

local type CustomPool = pool.CustomPool

function pool.CustomPool.acquire<T>(self: CustomPool<T>): T
    if self.size > 0 then
        local item = self.items[self.size]
        self.items[self.size] = nil
        self.size = self.size - 1
        return item
    end
    return nil
end

function pool.CustomPool.release<T>(self: CustomPool<T>, item: T)
    if self.size < self.maxSize then
        if self.clearFn then
            self.clearFn(item)
        end
        self.size = self.size + 1
        self.items[self.size] = item
    end
end

function pool.createCustomPool<T>(maxSize: integer, clearFn?: function(T)): CustomPool<T>
    return {
        items = {},
        size = 0,
        maxSize = maxSize,
        clearFn = clearFn,
        acquire = pool.CustomPool.acquire,
        release = pool.CustomPool.release
    }
end

return pool