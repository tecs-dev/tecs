local types <const> = require("tecs.types")
local compat <const> = require("tecs.internal.utils.compat")
local logging = require("tecs.internal.utils.logging")

local table_clear, table_new <const> = compat.clear, compat.new
local bor, bnot, lshift, band, rshift <const> = compat.bor, compat.bnot, compat.lshift, compat.band, compat.rshift

local type Storage = types.Storage
local type Component = types.Component

local DEFAULT_RECYCLE_SIZE <const> = 64
local SMALL_ARRAY_THRESHOLD <const> = 1024  -- 2x growth threshold for small arrays
local LOGGER <const> = logging.getLogger("tecs.internal.storage")

local record storage
    --- Basic table storage with automatic growth.
    newTableStorage: function(): Storage

    --- Compact bitset storage for tag components (boolean presence only).
    newBitsetStorage: function(): Storage

    --- High-performance FFI storage with automatic fallback to table storage.
    --- @param def Configuration including fields, recycling options
    newFFIStorage: function(def: {string:any}): Storage

    --- Power-of-two capacity calculation for optimal memory allocation.
    --- @param needed Required capacity
    --- @param currentCapacity Current capacity
    --- @return Optimal new capacity
    calculateOptimalCapacity: function(needed: integer, currentCapacity: integer): integer
end

-- Calculate optimal capacity for storage allocation
-- Uses power-of-two sizing with padding for better memory alignment
function storage.calculateOptimalCapacity(needed: integer, currentCapacity: integer): integer
    -- Add 25% padding for growth headroom
    local paddedNeeded = math.floor(needed * 1.25)

    -- Round up to next power of two for better memory alignment
    -- This is good for memory allocators and reduces fragmentation
    if paddedNeeded > 0 then
        -- Bit trick: round up to next power of 2
        paddedNeeded = paddedNeeded - 1
        paddedNeeded = bor(paddedNeeded, rshift(paddedNeeded, 1))
        paddedNeeded = bor(paddedNeeded, rshift(paddedNeeded, 2))
        paddedNeeded = bor(paddedNeeded, rshift(paddedNeeded, 4))
        paddedNeeded = bor(paddedNeeded, rshift(paddedNeeded, 8))
        paddedNeeded = bor(paddedNeeded, rshift(paddedNeeded, 16))
        paddedNeeded = paddedNeeded + 1
    end

    -- Ensure minimum growth (at least 2x for small arrays)
    if currentCapacity > 0 and currentCapacity < SMALL_ARRAY_THRESHOLD and paddedNeeded < currentCapacity * 2 then
        paddedNeeded = currentCapacity * 2
    end

    -- Ensure we have at least the needed capacity
    return math.max(needed, paddedNeeded)
end

-- Initialize component with optional table argument copying
local function initializeComponentFromArgs<C is Component>(component: C, ...: any): C
    local nargs = select('#', ...)
    if nargs == 1 and type((...)) == "table" then
        -- Copy from table argument
        local value = (...) as {string:any}
        for k, v in pairs(value) do
            (component as {string:any})[k] = v
        end
    end
    return component
end

-- Generic table-based component constructor
-- This is used when a table-based component is created but doesn't provide a custom constructor.
local function createTableComponentConstructor(): function(...: any): types.Component
    return function(...: any): types.Component
        return initializeComponentFromArgs({}, ...)
    end
end

-- Table storage implementation
local TABLE_STORAGE <const>: Storage = {
    new = function(_self: Storage, size: integer): {Component}
        return table_new(size, 0) as {Component}
    end,

    clear = function(_self: Storage, column: {Component})
        table_clear(column)
    end,

    ensureCapacity = function(
        _self: Storage,
        column: {Component},
        _needed: integer
    ): {Component}
        -- Lua tables grow automatically, so just return the same column
        return column
    end,

    commitBatch = function(
        _self: types.Storage,
        column: {types.Component},
        startIndex: integer,
        componentList: {integer:types.Component}
    ): {types.Component}
        -- Simple assignment for table storage (handle sparse array)
        for i, component in pairs(componentList) do
            column[startIndex + i - 1] = component
        end
        return column
    end,

    postCommit = function(_self: types.Storage, _dt: number)
        -- Nothing to clean up for table storage
    end,

    recycle = function(_self: types.Storage, _component: types.Component)
        -- Basic table storage doesn't support recycling - no-op
    end,

    swap = function(_self: types.Storage, column: {types.Component}, indexA: integer, indexB: integer)
        -- Simple table swap (using 1-based indexing)
        local temp = (column as {any})[indexA]
        (column as {any})[indexA] = (column as {any})[indexB];
        (column as {any})[indexB] = temp
    end
}

function storage.newTableStorage(): Storage
    -- Create a copy of table storage and add createComponent method
    local enhancedStorage: Storage = {
        new = TABLE_STORAGE.new,
        clear = TABLE_STORAGE.clear,
        ensureCapacity = TABLE_STORAGE.ensureCapacity,
        commitBatch = TABLE_STORAGE.commitBatch,
        postCommit = TABLE_STORAGE.postCommit,
        recycle = TABLE_STORAGE.recycle,
        swap = TABLE_STORAGE.swap
    }

    -- Add createComponent method (cast to bypass type checking)
    local storageAny = enhancedStorage as {string: any}
    storageAny.createComponent = function(
        _self: types.Storage,
        _container: types.Component
    ): function(...: any): types.Component
        return createTableComponentConstructor()
    end

    return enhancedStorage
end

--- Create table storage with object pooling for reduced allocations.
--- Useful for components that are frequently created/destroyed.
--- @param poolSize Maximum pool size (defaults to 64)
--- @param clearFn Custom function to clear component fields (optional)
function storage.newPooledTableStorage(poolSize?: integer, clearFn?: function(Component)): Storage
    poolSize = poolSize or DEFAULT_RECYCLE_SIZE
    local pool: {Component} = {}
    local poolCount = 0
    local maxPoolSize = poolSize

    local pooledStorage: Storage = {
        new = function(_self: Storage, size: integer): {Component}
            return table_new(size, 0) as {Component}
        end,

        clear = function(_self: Storage, column: {Component})
            -- Return components to pool before clearing
            for i = 1, #column do
                local component = column[i]
                if component and poolCount < maxPoolSize then
                    -- Clear the component if a clear function is provided
                    if clearFn then
                        clearFn(component)
                    else
                        -- Default: clear all fields to nil
                        for k in pairs(component as {string:any}) do
                            (component as {string:any})[k] = nil
                        end
                    end
                    poolCount = poolCount + 1
                    pool[poolCount] = component
                end
            end
            table_clear(column)
        end,

        ensureCapacity = function(
            _self: Storage,
            column: {Component},
            _needed: integer
        ): {Component}
            return column  -- Lua tables grow automatically
        end,

        commitBatch = function(
            _self: types.Storage,
            column: {types.Component},
            startIndex: integer,
            componentList: {integer:types.Component}
        ): {types.Component}
            for i, component in pairs(componentList) do
                column[startIndex + i - 1] = component
            end
            return column
        end,

        postCommit = function(_self: types.Storage, _dt: number)
            -- Nothing to clean up
        end
    }

    -- Add createComponent method that uses pooling
    local storageAny = pooledStorage as {string: any}
    storageAny.createComponent = function(
        _self: types.Storage,
        _container: types.Component
    ): function(...: any): types.Component
        return function(...: any): types.Component
            local component: Component
            if poolCount > 0 then
                -- Reuse from pool
                component = pool[poolCount]
                poolCount = poolCount - 1
            else
                component = {}
            end
            return initializeComponentFromArgs(component, ...)
        end
    end

    -- Add recycle method for explicit recycling
    storageAny.recycle = function(_self: types.Storage, component: types.Component)
        if poolCount < maxPoolSize then
            if clearFn then
                clearFn(component)
            else
                for k in pairs(component as {string:any}) do
                    (component as {string:any})[k] = nil
                end
            end
            poolCount = poolCount + 1
            pool[poolCount] = component
        end
    end

    -- Add swap method
    storageAny.swap = function(_self: types.Storage, column: {types.Component}, indexA: integer, indexB: integer)
        -- Simple table swap (using 1-based indexing)
        local temp = (column as {any})[indexA]
        (column as {any})[indexA] = (column as {any})[indexB];
        (column as {any})[indexB] = temp
    end

    return pooledStorage
end

--- Bitset storage implementation for tag components.
--- Uses bit manipulation for extremely compact boolean storage.
--- 32 components per integer, automatic growth.
local BITSET_STORAGE: Storage = {
    new = function(_self: Storage, _size: integer): {Component}
        local bitsets: {integer} = {}
        local bits_per_int <const> = 32
        local data = {__bitsets = bitsets, __max_index = 0}

        return setmetatable(data as {Component}, {
            __index = function(_t: {Component}, index: integer): boolean
                local chunk = math.floor((index - 1) / bits_per_int) + 1
                local bit_pos = (index - 1) % bits_per_int
                return band(bitsets[chunk] or 0, lshift(1, bit_pos)) ~= 0
            end,

            __newindex = function(_t: {Component}, index: integer, value: boolean)
                local chunk = math.floor((index - 1) / bits_per_int) + 1
                local bit_pos = (index - 1) % bits_per_int

                if value then
                    -- Ensure bitset array is large enough
                    while #bitsets < chunk do
                        bitsets[#bitsets + 1] = 0
                    end

                    bitsets[chunk] = bor(bitsets[chunk], lshift(1, bit_pos))
                    if index > data.__max_index then
                        data.__max_index = index
                    end
                elseif bitsets[chunk] then
                    bitsets[chunk] = band(bitsets[chunk], bnot(lshift(1, bit_pos)))
                end
            end,

            __len = function(_t: {Component}): integer
                return data.__max_index
            end
        })
    end,

    clear = function(_self: Storage, column: {Component})
        local data = column as table
        table_clear(data.__bitsets as table)
        data.__max_index = 0
    end,

    ensureCapacity = function(
        _self: Storage,
        column: {Component},
        _needed: integer
    ): {Component}
        -- Bitsets grow automatically when accessed, so just return the same column
        return column
    end,

}

function storage.newBitsetStorage(): Storage
    return BITSET_STORAGE
end

--- FFI storage factory with automatic graceful fallback.
--- Attempts to create high-performance FFI storage, falls back to table storage if FFI unavailable.
--- Fallback chain: FFI → Pooled Table (if recycling) → Basic Table
function storage.newFFIStorage(def: {string:any}): Storage
    local ffi = require("tecs.internal.ffi" as string) as {string:any}
    local isFFIAvailable = ffi.isFFIAvailable as function(): boolean

    if isFFIAvailable() then
        local newFFIStorage = ffi.newFFIStorage as function({string:any}): Storage
        return newFFIStorage(def)
    end

    -- Graceful fallback to table storage
    local componentName = (def as {string:any}).name as string or "unknown"
    LOGGER:debug("FFI not available for component '%s'. Fallback to table storage.", componentName)
    local recycle = (def as {string:any}).recycle as boolean

    if recycle then
        local recyclePoolSize = (def as {string:any}).recyclePoolSize as integer
        return storage.newPooledTableStorage(recyclePoolSize or DEFAULT_RECYCLE_SIZE)
    end

    return storage.newTableStorage()
end

return storage
