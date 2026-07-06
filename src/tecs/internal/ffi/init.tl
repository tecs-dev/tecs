--- FFI utilities for array-backed ECS internals.

local C <const> = require("ffi")
local types <const> = require("tecs.types")
local storage <const> = require("tecs.internal.storage")
local FFIStorage <const> = require("tecs.internal.ffi.FFIStorage")

local type Storage = storage.Storage

local max <const> = math.max

local type DoubleArray = types.DoubleArray

local record ffi
    --- Create a new double (float64) array. Entity IDs live in these so
    --- the full 53-bit packed (slot, gen, flag) value survives
    --- round-trips without truncation.
    newDouble: function(capacity: integer): DoubleArray

    --- Ensure capacity, returning the original array or a resized copy.
    ensureCapacityDouble: function(array: DoubleArray, neededCount: integer): DoubleArray

    --- Shrink an over-allocated array when usage is far below capacity.
    adjustCapacityDouble: function(array: DoubleArray, usedCount: integer): DoubleArray

    --- Set the size/length of a double FFI array in slot 0
    setDoubleArraySize: function(array: DoubleArray, size: integer)

    --- Create FFI-backed component storage.
    --- @param def FFIStorage.StructDefinition
    --- @return Storage (FFI-specific storage interface, but typed as Storage for compatibility)
    newFFIStorage: function(def: FFIStorage.StructDefinition): Storage

    FFIStorage: FFIStorage
end

ffi.FFIStorage = FFIStorage

local SHRINK_THRESHOLD <const> = 8          -- Shrink when using less than 1/8 capacity
local MIN_SHRINK_SIZE <const> = 512         -- Minimum capacity after shrinking
local MIN_SHRINK_CHECK_SIZE <const> = 2048  -- Only consider shrinking arrays this size or larger

local SIZEOF_DOUBLE <const> = C.sizeof("double")

local DOUBLE_ARRAY_T <const> = C.typeof("double[?]")

local record ArrayMeta
    capacity: integer
end

-- Capacity metadata keyed by cdata array. Weak keys allow old arrays to drop
-- after resize.
local arrayMetadata: {any:ArrayMeta} = setmetatable({}, {__mode = "k"})

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

function ffi.setDoubleArraySize(array: DoubleArray, size: integer)
    (array as {integer: number})[0] = size
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

function ffi.newFFIStorage(def: ffi.FFIStorage.StructDefinition): Storage
    return FFIStorage.new(def) as Storage
end

return ffi
