--- FFI utilities for array-backed ECS internals.

local C <const> = require("ffi")
local types <const> = require("tecs.types")
local storage <const> = require("tecs.internal.storage")
local Arena <const> = require("tecs.internal.ffi.EpochArena")
local FFIStorage <const> = require("tecs.internal.ffi.FFIStorage")

local type Storage = storage.Storage

local max <const> = math.max

local type DoubleArray = types.DoubleArray
local type Float32Array  = types.Float32Array

local record ffi
    --- Create a float32 array with length stored at index 0.
    newFloat32: function(capacity: integer): Float32Array

    --- Create a new double (float64) array. Entity IDs live in these so
    --- the full 53-bit packed (slot, gen, flag) value survives
    --- round-trips without truncation.
    newDouble: function(capacity: integer): DoubleArray

    --- Ensure capacity, returning the original array or a resized copy.
    ensureCapacityDouble: function(array: DoubleArray, neededCount: integer): DoubleArray

    --- Ensure capacity, returning the original array or a resized copy.
    ensureCapacityFloat32: function(array: Float32Array, neededCount: integer): Float32Array

    --- Shrink an over-allocated array when usage is far below capacity.
    adjustCapacityDouble: function(array: DoubleArray, usedCount: integer): DoubleArray

    --- Shrink an over-allocated array when usage is far below capacity.
    adjustCapacityFloat32: function(array: Float32Array, usedCount: integer): Float32Array

    --- Return the logical capacity tracked for this array.
    getCapacityDouble: function(array: DoubleArray): integer

    --- Return the logical capacity tracked for this array.
    getCapacityFloat32: function(array: Float32Array): integer

    --- Set the size/length of a double FFI array in slot 0
    setDoubleArraySize: function(array: DoubleArray, size: integer)

    --- Set the size/length of a numeric FFI array in slot 0
    setFloat32ArraySize: function(array: Float32Array, size: integer)

    --- Create FFI-backed component storage.
    --- @param def FFIStorage.StructDefinition
    --- @return Storage (FFI-specific storage interface, but typed as Storage for compatibility)
    newFFIStorage: function(def: FFIStorage.StructDefinition): Storage

    --- Create an epoch arena for FFI values.
    newArena: function<T>(ffiType: string, initialPageSize?: integer): Arena<T>

    FFIStorage: FFIStorage

    --- Always true in supported runtimes; this module requires LuaJIT FFI.
    isFFIAvailable: function(): boolean
end

ffi.FFIStorage = FFIStorage
ffi.isFFIAvailable = function(): boolean
    return true
end

function ffi.newArena<T>(ffiType: string, initialPageSize?: integer): Arena<T>
    return Arena.new(ffiType, initialPageSize)
end

local SHRINK_THRESHOLD <const> = 8          -- Shrink when using less than 1/8 capacity
local MIN_SHRINK_SIZE <const> = 512         -- Minimum capacity after shrinking
local MIN_SHRINK_CHECK_SIZE <const> = 2048  -- Only consider shrinking arrays this size or larger

local SIZEOF_FLOAT <const> = C.sizeof("float")
local SIZEOF_DOUBLE <const> = C.sizeof("double")

local FLOAT_ARRAY_T <const> = C.typeof("float[?]")
local DOUBLE_ARRAY_T <const> = C.typeof("double[?]")

local record ArrayMeta
    capacity: integer
end

-- Capacity metadata keyed by cdata array. Weak keys allow old arrays to drop
-- after resize.
local arrayMetadata: {any:ArrayMeta} = setmetatable({}, {__mode = "k"})

ffi.newFloat32 = function(capacity: integer): Float32Array
    capacity = max(16, capacity)
    local data = C.new(FLOAT_ARRAY_T, capacity + 1) as Float32Array
    arrayMetadata[data] = { capacity = capacity }
    data[0] = 0  -- Initialize length to 0
    return data
end

ffi.newDouble = function(capacity: integer): DoubleArray
    capacity = max(16, capacity)
    local data = C.new(DOUBLE_ARRAY_T, capacity + 1) as DoubleArray
    arrayMetadata[data] = { capacity = capacity }
    (data as {integer: number})[0] = 0  -- Initialize length to 0
    return data
end

function ffi.ensureCapacityDouble(array: DoubleArray, neededCount: integer): DoubleArray
    local meta = assert(arrayMetadata[array], "Missing array metadata")

    if neededCount > meta.capacity then
        local newData = C.new(DOUBLE_ARRAY_T, neededCount + 1) as DoubleArray

        local currentLength = (array as {integer: number})[0] as integer
        if currentLength > 0 then
            local copyBytes = (currentLength + 1) * SIZEOF_DOUBLE
            C.copy(newData as C.CData, array as C.CData, copyBytes)
        else
            (newData as {integer: number})[0] = currentLength
        end

        arrayMetadata[newData] = { capacity = neededCount }
        arrayMetadata[array] = nil
        return newData
    end
    return array
end

function ffi.ensureCapacityFloat32(array: Float32Array, neededCount: integer): Float32Array
    local meta = assert(arrayMetadata[array], "Missing array metadata")

    if neededCount > meta.capacity then
        local newData = C.new(FLOAT_ARRAY_T, neededCount + 1) as Float32Array

        local currentLength = array[0]
        if currentLength > 0 then
            local copyBytes = ((currentLength as integer) + 1) * SIZEOF_FLOAT
            C.copy(newData as C.CData, array as C.CData, copyBytes)
        else
            newData[0] = currentLength
        end

        arrayMetadata[newData] = { capacity = neededCount }
        arrayMetadata[array] = nil
        return newData
    end
    return array
end

function ffi.setDoubleArraySize(array: DoubleArray, size: integer)
    (array as {integer: number})[0] = size
end

function ffi.setFloat32ArraySize(array: Float32Array, size: integer)
    array[0] = size as number
end

function ffi.adjustCapacityDouble(array: DoubleArray, usedCount: integer): DoubleArray
    local meta = assert(arrayMetadata[array], "Missing array metadata")

    if meta.capacity >= MIN_SHRINK_CHECK_SIZE and usedCount <= meta.capacity / SHRINK_THRESHOLD then
        local newCapacity = max(MIN_SHRINK_SIZE, usedCount * 2)
        local newData = C.new(DOUBLE_ARRAY_T, newCapacity + 1) as DoubleArray

        if usedCount > 0 then
            local copyBytes = (usedCount + 1) * SIZEOF_DOUBLE
            C.copy(newData as C.CData, array as C.CData, copyBytes)
        end
        (newData as {integer: number})[0] = usedCount

        arrayMetadata[newData] = { capacity = newCapacity }
        arrayMetadata[array] = nil
        return newData
    end
    return array
end

function ffi.adjustCapacityFloat32(array: Float32Array, usedCount: integer): Float32Array
    local meta = assert(arrayMetadata[array], "Missing array metadata")

    if meta.capacity >= MIN_SHRINK_CHECK_SIZE and usedCount <= meta.capacity / SHRINK_THRESHOLD then
        local newCapacity = max(MIN_SHRINK_SIZE, usedCount * 2)
        local newData = C.new(FLOAT_ARRAY_T, newCapacity + 1) as Float32Array

        if usedCount > 0 then
            local copyBytes = (usedCount + 1) * SIZEOF_FLOAT
            C.copy(newData as C.CData, array as C.CData, copyBytes)
        end
        newData[0] = usedCount as number

        arrayMetadata[newData] = { capacity = newCapacity }
        arrayMetadata[array] = nil
        return newData
    end
    return array
end

function ffi.getCapacityDouble(array: DoubleArray): integer
    local meta = arrayMetadata[array]
    return meta and meta.capacity or 0
end

function ffi.getCapacityFloat32(array: Float32Array): integer
    local meta = arrayMetadata[array]
    return meta and meta.capacity or 0
end

function ffi.newFFIStorage(def: ffi.FFIStorage.StructDefinition): Storage
    return FFIStorage.new(def) as Storage
end

return ffi
