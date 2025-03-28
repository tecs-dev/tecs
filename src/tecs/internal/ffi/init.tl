--- FFI utilities for high-performance arrays and component storage.
--- Optimized for LuaJIT with FFI, with automatic fallbacks for standard Lua.

local types <const> = require("tecs.types")
local table_clear <const> = require("tecs.internal.utils.compat").clear
local libffi <const> = require("tecs.internal.ffi.libffi")
local Arena <const> = require("tecs.internal.ffi.Arena")
local FFIStorage <const> = require("tecs.internal.ffi.FFIStorage")

local type Storage = types.Storage

-- Check FFI availability and setup fallback behavior
local ffiAvailable <const> = libffi.isFFIAvailable()
local ffi_native = ffiAvailable and libffi.getFFI() or nil
local ffi_new = ffiAvailable and ffi_native.new or nil
local ffi_copy = ffiAvailable and ffi_native.copy or nil
local ffi_fill = ffiAvailable and ffi_native.fill or nil
local ffi_sizeof = ffiAvailable and ffi_native.sizeof or nil

local max <const> = math.max
local min <const> = math.min
local floor <const> = math.floor

local type Int32Array = types.Int32Array
local type Float32Array  = types.Float32Array

-- Module definition with all public types and functions
local record ffi
    --- Create a new float32 array (implemented conditionally with pure Lua fallback)
    newFloat32: function(capacity: integer): Float32Array

    --- Create a new int32 array (implemented conditionally with pure Lua fallback)
    newInt32: function(capacity: integer): Int32Array

    --- Clear array data efficiently (implemented conditionally with pure Lua fallback)
    clear: function(array: {integer | number}, count: integer)

    --- Ensure int32 array has enough capacity (returns same or new array)
    ensureCapacityInt32: function(array: Int32Array, neededCount: integer): Int32Array

    --- Ensure float32 array has enough capacity (returns same or new array)
    ensureCapacityFloat32: function(array: Float32Array, neededCount: integer): Float32Array

    --- Adjust int32 array capacity based on usage (shrink if too large)
    adjustCapacityInt32: function(array: Int32Array, usedCount: integer): Int32Array

    --- Adjust float32 array capacity based on usage (shrink if too large)
    adjustCapacityFloat32: function(array: Float32Array, usedCount: integer): Float32Array

    --- Set the size/length of an integer FFI array in slot 0
    setIntArraySize: function(array: Int32Array, size: integer)

    --- Set the size/length of a numeric FFI array in slot 0
    setFloat32ArraySize: function(array: Float32Array, size: integer)

    --- Batch clear multiple arrays
    batchClear: function(count: integer, ...: {integer | number})

    --- Create a new FFI-based component storage.
    --- @param def FFIStorage.StructDefinition
    --- @return Storage (FFI-specific storage interface, but typed as Storage for compatibility)
    newFFIStorage: function(def: FFIStorage.StructDefinition): Storage

    --- Create a new Arena storage for FFI.
    newArena: function<T>(ffiType: string, elemSize: integer, initialPageSize?: integer): Arena<T>

    --- Array type constants
    TYPE_FLOAT32: integer
    TYPE_INT32: integer

    FFIStorage: FFIStorage
    libffi: libffi

    --- Check if FFI is available
    isFFIAvailable: function(): boolean
end

ffi.FFIStorage = FFIStorage
ffi.libffi = libffi
ffi.isFFIAvailable = function(): boolean
    return ffiAvailable
end

function ffi.newArena<T>(ffiType: string, elemSize: integer, initialPageSize?: integer): Arena<T>
    if not ffiAvailable then
        error("Arena requires FFI support - cannot create Arena when FFI is not available")
    end
    return Arena.new(ffiType, elemSize, initialPageSize)
end

local GROWTH_FACTOR <const> = 1.75
local MIN_GROWTH <const> = 64
local SHRINK_THRESHOLD <const> = 8          -- Shrink when using less than 1/8 capacity
local MIN_SHRINK_SIZE <const> = 512         -- Minimum capacity after shrinking
local MIN_SHRINK_CHECK_SIZE <const> = 2048  -- Only consider shrinking arrays this size or larger

-- Size constants (FFI-based or fallback estimates)
local SIZEOF_FLOAT <const> = ffiAvailable and ffi_sizeof("float") or 4
local SIZEOF_INT32 <const> = ffiAvailable and ffi_sizeof("int32_t") or 4

-- Metadata record for array info (just capacity now)
local record ArrayMeta
    capacity: integer
end

-- Global metadata table - stores only capacity keyed by FFI cdata
-- Weak keys allow GC to clean up old cdata references
local arrayMetadata: {any:ArrayMeta} = setmetatable({}, {__mode = "k"})

-- Load-time function assignment for simple functions with no shared logic
if ffiAvailable then
    -- FFI implementations - no runtime checks
    function ffi.newFloat32(capacity: integer): Float32Array
        capacity = max(16, capacity)
        local data = ffi_new("float[?]", capacity + 1) as Float32Array
        arrayMetadata[data] = { capacity = capacity }
        data[0] = 0  -- Initialize length to 0
        return data
    end

    function ffi.newInt32(capacity: integer): Int32Array
        capacity = max(16, capacity)
        local data = ffi_new("int32_t[?]", capacity + 1) as Int32Array
        arrayMetadata[data] = { capacity = capacity }
        (data as {integer})[0] = 0  -- Initialize length to 0
        return data
    end

    function ffi.clear(array: {integer | number}, count: integer)
        if count > 0 then
            local meta = assert(arrayMetadata[array], "Missing array metadata")
            -- FFI implementation - bulk clear with ffi_fill
            local elemSize = max(SIZEOF_FLOAT, SIZEOF_INT32)
            local clearBytes = (min(count, meta.capacity) + 1) * elemSize
            ffi_fill(array as libffi.CData, clearBytes, 0 as libffi.CData)
        end
    end
else
    -- Table-based fallback implementations - no runtime checks
    function ffi.newFloat32(capacity: integer): Float32Array
        capacity = max(16, capacity)
        local data: {number} = {}
        data[0] = 0  -- Length at index 0
        arrayMetadata[data] = { capacity = capacity }
        return data as Float32Array
    end

    function ffi.newInt32(capacity: integer): Int32Array
        capacity = max(16, capacity)
        local data: {integer} = {}
        data[0] = 0  -- Length at index 0
        arrayMetadata[data] = { capacity = capacity }
        return data as Int32Array
    end

    function ffi.clear(array: {integer | number}, _count: integer)
        -- Clear the entire array. The `count` argument is only there because FFI knows capacity, not used count.
        table_clear(array as {any})
    end
end

function ffi.ensureCapacityInt32(array: Int32Array, neededCount: integer): Int32Array
    local meta = assert(arrayMetadata[array], "Missing array metadata")

    if neededCount > meta.capacity then
        local newCapacity = max(
            neededCount + MIN_GROWTH,
            floor(meta.capacity * GROWTH_FACTOR)
        )

        if ffiAvailable then
            -- FFI implementation
            local newData = ffi_new("int32_t[?]", newCapacity + 1) as Int32Array

            local currentLength = (array as {integer})[0]
            if currentLength > 0 then
                local copyBytes = (currentLength + 1) * SIZEOF_INT32
                ffi_copy(newData as libffi.CData, array as libffi.CData, copyBytes)
            else
                (newData as {integer})[0] = currentLength
            end

            arrayMetadata[newData] = { capacity = newCapacity }
            arrayMetadata[array] = nil
            return newData
        else
            -- Table-based fallback
            local newData: {integer} = {}
            local currentLength = (array as {integer})[0]

            -- Copy existing data including length at slot 0
            newData[0] = currentLength
            for i = 1, currentLength do
                newData[i] = (array as {integer})[i]
            end

            arrayMetadata[newData] = { capacity = newCapacity }
            arrayMetadata[array] = nil
            return newData as Int32Array
        end
    end
    return array
end

function ffi.ensureCapacityFloat32(array: Float32Array, neededCount: integer): Float32Array
    local meta = assert(arrayMetadata[array], "Missing array metadata")

    if neededCount > meta.capacity then
        local newCapacity = max(
            neededCount + MIN_GROWTH,
            floor(meta.capacity * GROWTH_FACTOR)
        )

        if ffiAvailable then
            -- FFI implementation
            local newData = ffi_new("float[?]", newCapacity + 1) as Float32Array

            local currentLength = array[0]
            if currentLength > 0 then
                local copyBytes = ((currentLength as integer) + 1) * SIZEOF_FLOAT
                ffi_copy(newData as libffi.CData, array as libffi.CData, copyBytes)
            else
                newData[0] = currentLength
            end

            arrayMetadata[newData] = { capacity = newCapacity }
            arrayMetadata[array] = nil
            return newData
        else
            -- Table-based fallback
            local newData: {number} = {}
            local currentLength = array[0]

            -- Copy existing data including length at slot 0
            newData[0] = currentLength
            for i = 1, currentLength as integer do
                newData[i] = array[i]
            end

            arrayMetadata[newData] = { capacity = newCapacity }
            arrayMetadata[array] = nil
            return newData as Float32Array
        end
    end
    return array
end

-- Simple assignment functions - same implementation for both FFI and fallback
function ffi.setIntArraySize(array: Int32Array, size: integer)
    (array as {integer})[0] = size
end

function ffi.setFloat32ArraySize(array: Float32Array, size: integer)
    array[0] = size as number
end

-- Package-private shared implementation for adjust capacity
local function adjustCapacityImpl(array: any, usedCount: integer, ffiType: string, elemSize: number): any
    local meta = assert(arrayMetadata[array], "Missing array metadata")

    -- Shrink if using less than 1/8 of capacity and capacity is large
    -- Hysteresis: new capacity is 2x used count to avoid oscillation
    if meta.capacity >= MIN_SHRINK_CHECK_SIZE and usedCount <= meta.capacity / SHRINK_THRESHOLD then
        local newCapacity = max(MIN_SHRINK_SIZE, usedCount * 2)

        if ffiAvailable then
            -- FFI implementation
            local newData = ffi_new(ffiType, newCapacity + 1)

            local currentLength = (array as {number})[0]
            if usedCount > 0 then
                local copyBytes = (usedCount + 1) * elemSize as integer
                ffi_copy(newData as libffi.CData, array as libffi.CData, copyBytes)
            else
                (newData as {number})[0] = currentLength
            end

            arrayMetadata[newData] = { capacity = newCapacity }
            arrayMetadata[array] = nil
            return newData
        else
            -- Table-based fallback
            local newData: {any} = {}
            local currentLength = (array as {number})[0]

            -- Copy used data including length at slot 0
            newData[0] = currentLength
            for i = 1, usedCount do
                newData[i] = (array as {any})[i]
            end

            arrayMetadata[newData] = { capacity = newCapacity }
            arrayMetadata[array] = nil
            return newData
        end
    end
    return array
end

function ffi.adjustCapacityInt32(array: Int32Array, usedCount: integer): Int32Array
    return adjustCapacityImpl(array, usedCount, "int32_t[?]", SIZEOF_INT32) as Int32Array
end

function ffi.adjustCapacityFloat32(array: Float32Array, usedCount: integer): Float32Array
    return adjustCapacityImpl(array, usedCount, "float[?]", SIZEOF_FLOAT) as Float32Array
end

function ffi.batchClear(count: integer, ...: {integer | number})
    local numArrays = select("#", ...)
    for i = 1, numArrays do
        ffi.clear(select(i, ...), count)
    end
end

function ffi.newFFIStorage(def: ffi.FFIStorage.StructDefinition): Storage
    if not ffiAvailable then
        -- This shouldn't be called when FFI is not available, but if it is,
        -- we need to error since we can't create a fallback without circular dependencies
        error("FFI is not available - cannot create FFI storage when FFI is not available")
    end
    return FFIStorage.new(def) as Storage
end

return ffi