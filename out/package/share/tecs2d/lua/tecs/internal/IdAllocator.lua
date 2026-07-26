






















local C = require("ffi")

C.cdef([[
typedef struct TecsEntitySlot {
    uint32_t generation;
    uint32_t archetypeId;
    uint32_t row;
} TecsEntitySlot;
]])

local SLOT_ARRAY_T = C.typeof("TecsEntitySlot[?]")
local UINT32_ARRAY_T = C.typeof("uint32_t[?]")

local floor = math.floor

local SLOT_BITS = 22
local GEN_BITS = 31
local SLOT_COUNT = (2 ^ 22)
local GEN_COUNT = (2 ^ 31)




local ABSOLUTE_MAX_SLOT_COUNT = SLOT_COUNT - 1
local DEFAULT_MAX_SLOT_COUNT = 1048576

local IdAllocator = { EntitySlot = {} }











































































IdAllocator.SLOT_BITS = SLOT_BITS
IdAllocator.GEN_BITS = GEN_BITS
IdAllocator.SLOT_COUNT = SLOT_COUNT
IdAllocator.GEN_COUNT = GEN_COUNT
IdAllocator.ABSOLUTE_MAX_SLOT_COUNT = ABSOLUTE_MAX_SLOT_COUNT
IdAllocator.DEFAULT_MAX_SLOT_COUNT = DEFAULT_MAX_SLOT_COUNT

function IdAllocator.new(maxSlotCount)
   local n = maxSlotCount or DEFAULT_MAX_SLOT_COUNT
   if n < 1 or n ~= floor(n) then
      error("IdAllocator.new: maxSlotCount must be a positive integer, got " .. tostring(n))
   end
   if n > ABSOLUTE_MAX_SLOT_COUNT then
      error("IdAllocator.new: maxSlotCount " .. n ..
      " exceeds format limit " .. ABSOLUTE_MAX_SLOT_COUNT ..
      " (packed id has " .. SLOT_BITS .. " bits for slot)")
   end
   return {

      slots = C.new(SLOT_ARRAY_T, n + 1),
      maxSlotCount = n,
      nextFreshSlot = 1,
      freeStack = C.new(UINT32_ARRAY_T, n),
      freeCount = 0,
   }
end

function IdAllocator.allocSlot(allocator)
   local freeCount = allocator.freeCount
   if freeCount > 0 then
      freeCount = freeCount - 1
      allocator.freeCount = freeCount

      return allocator.freeStack[freeCount]
   end

   local slot = allocator.nextFreshSlot
   if slot > allocator.maxSlotCount then
      error("entity ID exhaustion: maxSlotCount (" .. allocator.maxSlotCount .. ") reached")
   end

   allocator.nextFreshSlot = slot + 1

   return slot
end

function IdAllocator.allocContiguousSlots(allocator, count)
   if count < 1 or count ~= floor(count) then
      error("IdAllocator.allocContiguousSlots: count must be a positive integer, got " .. tostring(count))
   end


   local firstSlot = allocator.nextFreshSlot
   local newNext = firstSlot + count
   if newNext > allocator.maxSlotCount + 1 then
      error("entity slot exhaustion: maxSlotCount (" .. allocator.maxSlotCount .. ") reached")
   end
   allocator.nextFreshSlot = newNext
   return firstSlot
end

function IdAllocator.freeSlot(allocator, slot)










   local s = allocator.slots[slot]
   s.archetypeId = 0
   local g = s.generation + 1
   if g == GEN_COUNT then
      g = 0
   end
   s.generation = g
   local freeCount = allocator.freeCount
   allocator.freeStack[freeCount] = slot
   allocator.freeCount = freeCount + 1
end




function IdAllocator.rebuildFreeStack(allocator)
   local slots = allocator.slots
   local stack = allocator.freeStack
   local n = 0
   for slot = 1, allocator.nextFreshSlot - 1 do
      if slots[slot].archetypeId == 0 then
         stack[n] = slot
         n = n + 1
      end
   end
   allocator.freeCount = n
end





function IdAllocator.unfree(allocator, slot)
   local stack = allocator.freeStack
   local n = allocator.freeCount
   for i = 0, n - 1 do
      if stack[i] == slot then
         stack[i] = stack[n - 1]
         allocator.freeCount = n - 1
         return
      end
   end
end

function IdAllocator.reset(allocator)





   local usedLimit = allocator.nextFreshSlot - 1
   if usedLimit > 0 then
      local slots = allocator.slots
      local maxGen = 0
      for slot = 1, usedLimit do
         local g = slots[slot].generation
         if g > maxGen then maxGen = g end
      end
      local newGen = maxGen + 1
      if newGen >= GEN_COUNT then
         newGen = 0
      end
      for slot = 1, usedLimit do
         local s = slots[slot]
         s.archetypeId = 0
         s.row = 0
         s.generation = newGen
      end
   end
   allocator.nextFreshSlot = 1
   allocator.freeCount = 0
end

return IdAllocator
