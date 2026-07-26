












local table_clear = require("table.clear")
local types = require("tecs.types")
local internal = require("tecs.internal.types")
local IdAllocator = require("tecs.internal.IdAllocator")



local WorldImpl = internal.WorldImpl

function WorldImpl:setSparseRaw(id, value)
   local slot = id % 2 ^ 22
   local sets = self.sparseSets[slot]
   if not sets then
      sets = self._sparseArraysPool:acquire()
      self.sparseSets[slot] = sets
      self.sparseSetCount = self.sparseSetCount + 1
   elseif (sets).id ~= id then


      table_clear(sets)
   end


   (sets).id = id
   sets[#sets + 1] = value
   self.isDirty = true
end




function WorldImpl:applySparseRaw(id, value)
   local rel = value
   local container = rel.relationshipType
   local store = self.relationshipStores[container]
   if store then
      store:set(id, value)
      local slot = id % 2 ^ 22
      local arch = self.archetypeIndex[
      (self.allocator.slots)[slot].archetypeId]
      if arch then
         arch:markComponentDirty(container)
      end
   end
end

function WorldImpl:removeSparseRaw(id, container)
   local slot = id % 2 ^ 22
   local sets = self.sparseSets[slot]
   if sets then
      local n = #sets
      local w = 0
      for i = 1, n do
         local v = sets[i]
         local rel = v
         if rel.relationshipType ~= container then
            w = w + 1
            if w ~= i then sets[w] = v end
         end
      end
      for i = w + 1, n do
         sets[i] = nil
      end
   end

   local store = self.relationshipStores[container]
   if store then
      store:remove(id)


      self:deferRemoveRaw(id, container)
   end
   self.isDirty = true
end

function WorldImpl:removeSparseOneRaw(id, container, targetId)



   local slot = id % 2 ^ 22
   local sets = self.sparseSets[slot]
   local stagedForContainer = false
   if sets then
      local n = #sets
      local w = 0
      for i = 1, n do
         local v = sets[i]
         local rel = v
         if rel.relationshipType ~= container or rel.target ~= targetId then
            if rel.relationshipType == container then
               stagedForContainer = true
            end
            w = w + 1
            if w ~= i then sets[w] = v end
         end
      end
      for i = w + 1, n do
         sets[i] = nil
      end
   end

   local store = self.relationshipStores[container]
   if store then
      store:removeOne(id, targetId)


      if not stagedForContainer and not store:has(id) then

         self:deferRemoveRaw(id, container)
      else


         local arch = self.archetypeIndex[
         (self.allocator.slots)[slot].archetypeId]
         if arch then
            arch:markComponentDirty(container)
         end
      end
   end
   self.isDirty = true
end

return {}
