





local internal = require("tecs.internal.types")
local IdAllocator = require("tecs.internal.IdAllocator")
local builtins = require("tecs.internal.builtins")



local WorldImpl = internal.WorldImpl

local function fail(msg)
   error("world integrity violation: " .. msg, 3)
end

function WorldImpl:_validateIntegrity()

   if self.isDirty then fail("isDirty on a quiet world") end
   if self._scopeDepth ~= 0 then
      fail("scopeDepth " .. self._scopeDepth .. " on a quiet world")
   end
   if self.entityStateCount ~= 0 then
      fail("entityStateCount " .. self.entityStateCount)
   end
   if self.batchMutationCount ~= 0 then
      fail("batchMutationCount " .. self.batchMutationCount)
   end
   if self.sparseSetCount ~= 0 then
      fail("sparseSetCount " .. self.sparseSetCount)
   end
   if self.dirtyArchetypeCount ~= 0 then
      fail("dirtyArchetypeCount " .. self.dirtyArchetypeCount)
   end

   local slots = self.allocator.slots
   local index = self.archetypeIndex
   local Key = builtins.Key

   local seen = {}

   local keyed = {}

   for i = 1, index.maxId do
      local arch = index[i]
      if arch then
         if arch.pendingWrites ~= 0 then
            fail("archetype " .. i .. " pendingWrites " .. arch.pendingWrites)
         end
         if arch.hasPendingSpawns or arch.hasPendingMoveOut or
            arch.hasPendingDespawns or arch.pendingClear then
            fail("archetype " .. i .. " has pending flags set")
         end
         if arch.pendingSpawnCount ~= 0 or arch.pendingDespawnCount ~= 0 or
            arch.batchSpawnQueueCount ~= 0 or
            arch.batchSpawnAtQueueCount ~= 0 or
            arch.pendingBundleDrainCount ~= 0 then
            fail("archetype " .. i .. " has pending queue entries")
         end

         local entities = arch.entities
         local count = entities[0]
         if count > arch.capacity then
            fail("archetype " .. i .. " count " .. count ..
            " exceeds capacity " .. arch.capacity)
         end

         local keyCol = arch.columns[Key]
         for row = 1, count do
            local id = entities[row]
            local slot = id % 2 ^ 22
            if seen[slot] then
               fail("slot " .. slot .. " placed in archetypes " ..
               seen[slot] .. " and " .. i)
            end
            seen[slot] = i
            local s = slots[slot]
            if s.archetypeId ~= arch.id then
               fail("slot " .. slot .. " records archetype " .. s.archetypeId ..
               " but its row lives in " .. arch.id)
            end
            if s.row ~= row - 1 then
               fail("slot " .. slot .. " records row " .. s.row ..
               " but sits at row " .. (row - 1))
            end
            if (id - slot) / 2 ^ 22 ~= s.generation then
               fail("slot " .. slot .. " generation mismatch")
            end
            if keyCol then
               local key = keyCol[row]
               if key == nil or key == "" then
                  fail("slot " .. slot .. " carries an empty Key value")
               end
               if keyed[key] then
                  fail("key '" .. key .. "' owned by two entities")
               end
               keyed[key] = id
            end
         end
      end
   end


   for key, id in pairs(self._keyIndex) do
      if keyed[key] ~= id then
         fail("key index entry '" .. key .. "' -> " .. id ..
         " not backed by a Key column")
      end
      keyed[key] = nil
   end
   local orphan = next(keyed)
   if orphan ~= nil then
      fail("key '" .. tostring(orphan) .. "' in a column but missing from the index")
   end
end

return {}
