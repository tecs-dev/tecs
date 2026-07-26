

local C = require("ffi")
local types = require("tecs.types")
local FFIStorage = require("tecs.internal.ffi.FFIStorage")

local max = math.max



local ffi = {}






















ffi.FFIStorage = FFIStorage

local SHRINK_THRESHOLD = 8
local MIN_SHRINK_SIZE = 512
local MIN_SHRINK_CHECK_SIZE = 2048

local SIZEOF_DOUBLE = C.sizeof("double")

local DOUBLE_ARRAY_T = C.typeof("double[?]")







local arrayMetadata = setmetatable({}, { __mode = "k" })

ffi.newDouble = function(capacity)
   capacity = max(16, capacity)
   local data = C.new(DOUBLE_ARRAY_T, capacity + 1)
   arrayMetadata[data] = { capacity = capacity };
   (data)[0] = 0
   return data
end

function ffi.ensureCapacityDouble(array, neededCount)
   local meta = assert(arrayMetadata[array], "Missing array metadata")

   if neededCount > meta.capacity then
      local newData = C.new(DOUBLE_ARRAY_T, neededCount + 1)

      local currentLength = (array)[0]
      if currentLength > 0 then
         local copyBytes = (currentLength + 1) * SIZEOF_DOUBLE
         C.copy(newData, array, copyBytes)
      else
         (newData)[0] = currentLength
      end

      arrayMetadata[newData] = { capacity = neededCount }
      arrayMetadata[array] = nil
      return newData
   end
   return array
end

function ffi.setDoubleArraySize(array, size)
   (array)[0] = size
end

function ffi.adjustCapacityDouble(array, usedCount)
   local meta = assert(arrayMetadata[array], "Missing array metadata")

   if meta.capacity >= MIN_SHRINK_CHECK_SIZE and usedCount <= meta.capacity / SHRINK_THRESHOLD then
      local newCapacity = max(MIN_SHRINK_SIZE, usedCount * 2)
      local newData = C.new(DOUBLE_ARRAY_T, newCapacity + 1)

      if usedCount > 0 then
         local copyBytes = (usedCount + 1) * SIZEOF_DOUBLE
         C.copy(newData, array, copyBytes)
      end
      (newData)[0] = usedCount

      arrayMetadata[newData] = { capacity = newCapacity }
      arrayMetadata[array] = nil
      return newData
   end
   return array
end

function ffi.newFFIStorage(def)
   return FFIStorage.new(def)
end

return ffi
