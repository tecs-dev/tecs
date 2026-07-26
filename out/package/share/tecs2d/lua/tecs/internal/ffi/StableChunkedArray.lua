



local ffi = require("ffi")
local floor = math.floor

local ChunkedArray = {}


















local ChunkedArrayMT = {
   __index = ChunkedArray,
}

local module = {}







function module.new(ffiType, chunkSize)
   local size = chunkSize or 256
   if size <= 0 then
      error("StableChunkedArray.new: chunkSize must be a positive integer, got " .. tostring(size))
   end
   local arr = {
      chunks = {},
      chunkSize = size,
      ffiType = ffiType .. "[?]",
      nextId = 1,
      freeIds = {},
      alive = {},
   }
   return setmetatable(arr, ChunkedArrayMT)
end

function ChunkedArray:alloc()
   local id
   local freeIds = self.freeIds
   local n = #freeIds
   if n > 0 then
      id = freeIds[n]
      freeIds[n] = nil
   else
      id = self.nextId
      self.nextId = id + 1
      local zero = id - 1
      local chunkIndex = floor(zero / self.chunkSize) + 1
      if not self.chunks[chunkIndex] then
         self.chunks[chunkIndex] = ffi.new(self.ffiType, self.chunkSize)
      end
   end
   self.alive[id] = true
   return id
end

function ChunkedArray:free(id)
   if id < 1 or id >= self.nextId or not self.alive[id] then
      return
   end
   self.alive[id] = nil
   self.freeIds[#self.freeIds + 1] = id
end

function ChunkedArray:get(id)
   if not self.alive[id] then
      return nil
   end
   local zero = id - 1
   local chunkIndex = floor(zero / self.chunkSize) + 1
   local chunk = self.chunks[chunkIndex]
   local slot = zero % self.chunkSize
   return (chunk)[slot]
end

return module
