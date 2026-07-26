















local types = require("tecs.types")
local internal = require("tecs.internal.types")
local IdAllocator = require("tecs.internal.IdAllocator")
local builtins = require("tecs.internal.builtins")
local behavior = require("tecs.internal.behavior")
local shared = require("tecs.internal.world.shared")








local WorldImpl = internal.WorldImpl

local STATE_SPAWN = shared.STATE_SPAWN
local STATE_MUTATE = shared.STATE_MUTATE
local STATE_DESPAWN = shared.STATE_DESPAWN
local BATCH_OP_SET_CONST = shared.BATCH_OP_SET_CONST
local BATCH_OP_SET_CALLBACK = shared.BATCH_OP_SET_CALLBACK
local BATCH_OP_REMOVE = shared.BATCH_OP_REMOVE

local applyBatchSet = shared.applyBatchSet
local applyBatchRemove = shared.applyBatchRemove
local applyRequires = shared.applyRequires
local writeRequiredRange = shared.writeRequiredRange

local table_clear = require("table.clear")
local floor = math.floor






local BATCH_SPAWN_SLOTS = 5
local BATCH_SPAWN_MODE_RANGE = 1
local BATCH_SPAWN_MODE_LIST = 2







local BATCH_SPAWN_AT_SLOTS = 4

local function validateBatchCount(name, count)
   if count < 1 or count ~= floor(count) then
      error(name .. ": count must be a positive integer, got " .. tostring(count))
   end
end





local function stakePendingSpawnAt(
   self,
   archetype,
   count,
   readId)

   local arena = self.allocator
   local slots = arena.slots


   local pendingArr = self._pendingArchArr
   local stateArr = self._stateArr
   local slotStamp = self._slotStamp
   local epoch = self._transactionEpoch
   local archId = archetype.id
   local stateCount = self.entityStateCount
   for i = 0, count - 1 do
      local id = readId(i)
      local slot = id % 2 ^ 22
      if slot >= arena.nextFreshSlot then
         arena.nextFreshSlot = slot + 1
      elseif arena.freeCount > 0 then


         IdAllocator.unfree(arena, slot)
      end
      slots[slot].generation = (id - slot) / 2 ^ 22
      if slotStamp[slot] ~= epoch then
         slotStamp[slot] = epoch
         pendingArr[slot] = archId
         stateArr[slot] = STATE_SPAWN
         stateCount = stateCount + 1
      else
         pendingArr[slot] = archId
         if stateArr[slot] == 0 then
            stateArr[slot] = STATE_SPAWN
            stateCount = stateCount + 1
         end
      end
   end
   self.entityStateCount = stateCount
end

local pairs = pairs



















































































local function resolveBatchSpawnArchetype(
   self,
   componentTypes)

   local archetypeIndex = self.archetypeIndex
   local archetype = archetypeIndex.emptyArchetype
   local requiredList = nil
   for i = 1, #componentTypes do
      local comp = componentTypes[i]
      local ci = comp
      archetype = archetype:withComponent(comp, archetypeIndex)
      if ci._hasRequires then
         local extension
         archetype, extension = applyRequires(archetype, ci, archetypeIndex)
         if extension then
            if requiredList == nil then
               requiredList = extension
            else
               local rl = requiredList
               for k = 1, #extension do
                  rl[#rl + 1] = extension[k]
               end
            end
         end
      end

      local wildcard = ci.wildcardContainer
      if wildcard then
         archetype = archetype:withComponent(wildcard, archetypeIndex)
      end
   end

   local autoState = self.autoStateComponent
   if autoState then
      archetype = archetype:withComponent(autoState, archetypeIndex)
   end
   return archetype, requiredList
end

function WorldImpl:_deferBatchSpawn(
   count,
   componentTypes,
   callback)

   validateBatchCount("World:batchSpawn", count)

   if self.allocator.nextFreshSlot + count > self.allocator.maxSlotCount + 1 then
      return nil, self:_deferBatchSpawnList(count, componentTypes, callback)
   end





   local genSlots = self.allocator.slots
   local nextFresh = self.allocator.nextFreshSlot
   local rangeGen = genSlots[nextFresh].generation
   if genSlots[nextFresh + count - 1].generation ~= rangeGen then
      return nil, self:_deferBatchSpawnList(count, componentTypes, callback)
   end

   local archetype, requiredList = resolveBatchSpawnArchetype(self, componentTypes)




   local firstSlot = IdAllocator.allocContiguousSlots(self.allocator, count)
   local pendingArr = self._pendingArchArr
   local stateArr = self._stateArr
   local slotStamp = self._slotStamp
   local epoch = self._transactionEpoch
   local archId = archetype.id
   for i = 0, count - 1 do
      local s = firstSlot + i
      if slotStamp[s] ~= epoch then
         slotStamp[s] = epoch
         stateArr[s] = 0
      end
      pendingArr[s] = archId
   end



   local firstId = firstSlot + rangeGen * 2 ^ 22

   local c = archetype.batchSpawnQueueCount
   local q = archetype.batchSpawnQueue
   q[c + 1] = count
   q[c + 2] = firstId
   q[c + 3] = callback
   q[c + 4] = BATCH_SPAWN_MODE_RANGE
   q[c + 5] = requiredList
   archetype.batchSpawnQueueCount = c + BATCH_SPAWN_SLOTS
   if archetype.dirtyQueuedEpoch ~= self._dirtyEpoch then archetype.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = archetype; self.dirtyArchetypeCount = __c end
   self.isDirty = true

   return firstId, nil
end

function WorldImpl:_deferBatchSpawnList(
   count,
   componentTypes,
   callback)

   local archetype, requiredList = resolveBatchSpawnArchetype(self, componentTypes)

   local allocator = self.allocator
   local pendingArr = self._pendingArchArr
   local stateArr = self._stateArr
   local slotStamp = self._slotStamp
   local epoch = self._transactionEpoch
   local archId = archetype.id
   local freshAvail = allocator.maxSlotCount - allocator.nextFreshSlot + 1
   local totalAvail = freshAvail + allocator.freeCount
   if count > totalAvail then
      error("entity slot exhaustion: maxSlotCount (" .. allocator.maxSlotCount .. ") reached")
   end

   local idsList = {}
   local n = 0

   if freshAvail > 0 then
      local takeFresh = freshAvail < count and freshAvail or count
      local firstFresh = IdAllocator.allocContiguousSlots(allocator, takeFresh)
      for i = 0, takeFresh - 1 do
         local slot = firstFresh + i

         local id = slot + allocator.slots[slot].generation * 2 ^ 22
         n = n + 1
         idsList[n] = id
         if slotStamp[slot] ~= epoch then
            slotStamp[slot] = epoch
            stateArr[slot] = 0
         end
         pendingArr[slot] = archId
      end
   end

   while n < count do
      local slot = IdAllocator.allocSlot(allocator)
      local id = slot + allocator.slots[slot].generation * 2 ^ 22
      n = n + 1
      idsList[n] = id
      if slotStamp[slot] ~= epoch then
         slotStamp[slot] = epoch
         stateArr[slot] = 0
      end
      pendingArr[slot] = archId
   end

   local c = archetype.batchSpawnQueueCount
   local q = archetype.batchSpawnQueue
   q[c + 1] = count
   q[c + 2] = idsList
   q[c + 3] = callback
   q[c + 4] = BATCH_SPAWN_MODE_LIST
   q[c + 5] = requiredList
   archetype.batchSpawnQueueCount = c + BATCH_SPAWN_SLOTS
   if archetype.dirtyQueuedEpoch ~= self._dirtyEpoch then archetype.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = archetype; self.dirtyArchetypeCount = __c end
   self.isDirty = true

   return idsList
end

function WorldImpl:_drainArchBatchSpawn(archetype)
   local slots = self.allocator.slots
   local stateArr = self._stateArr
   local slotStamp = self._slotStamp
   local epoch = self._transactionEpoch
   local archId = archetype.id
   local q = archetype.batchSpawnQueue

   local i = 1
   while i <= archetype.batchSpawnQueueCount do
      local count = q[i]
      local idsOrFirst = q[i + 1]
      local callback = q[i + 2]
      local mode = q[i + 3]
      local requiredList = q[i + 4]

      archetype:reserveCapacity((archetype.entities[0]) + count)
      local entities = archetype.entities
      local currentCount = entities[0]
      local entitiesArr = entities

      local placed = 0
      local stateCount = self.entityStateCount
      if mode == BATCH_SPAWN_MODE_RANGE then


         local firstId = idsOrFirst
         local firstSlot = firstId % 2 ^ 22
         if stateCount == 0 then
            for j = 0, count - 1 do
               do local entityId = firstId + j; local entSlot = firstSlot + j; local row = currentCount + placed; entitiesArr[row + 1] = entityId; local es = slots[entSlot]; es.archetypeId = archId; es.row = row; placed = placed + 1; slotStamp[entSlot] = 0 end
            end
         else
            for j = 0, count - 1 do
               do local entityId = firstId + j; local entSlot = firstSlot + j; local st = (slotStamp[entSlot] == epoch and stateArr[entSlot] or 0); if st == STATE_DESPAWN then slotStamp[entSlot] = 0 else local row = currentCount + placed; entitiesArr[row + 1] = entityId; local es = slots[entSlot]; es.archetypeId = archId; es.row = row; placed = placed + 1; if st == STATE_MUTATE then archetype.hasPendingMoveOut = true; if archetype.dirtyQueuedEpoch ~= self._dirtyEpoch then archetype.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = archetype; self.dirtyArchetypeCount = __c end else slotStamp[entSlot] = 0 end end end
            end
         end
      else
         local ids = idsOrFirst
         if stateCount == 0 then
            for j = 1, count do
               do local entityId = ids[j]; local entSlot = entityId % 2 ^ 22; local row = currentCount + placed; entitiesArr[row + 1] = entityId; local es = slots[entSlot]; es.archetypeId = archId; es.row = row; placed = placed + 1; slotStamp[entSlot] = 0 end
            end
         else
            for j = 1, count do
               do local entityId = ids[j]; local entSlot = entityId % 2 ^ 22; local st = (slotStamp[entSlot] == epoch and stateArr[entSlot] or 0); if st == STATE_DESPAWN then slotStamp[entSlot] = 0 else local row = currentCount + placed; entitiesArr[row + 1] = entityId; local es = slots[entSlot]; es.archetypeId = archId; es.row = row; placed = placed + 1; if st == STATE_MUTATE then archetype.hasPendingMoveOut = true; if archetype.dirtyQueuedEpoch ~= self._dirtyEpoch then archetype.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = archetype; self.dirtyArchetypeCount = __c end else slotStamp[entSlot] = 0 end end end
            end
         end
      end
      entitiesArr[0] = currentCount + placed

      if placed > 0 then



         if requiredList then
            writeRequiredRange(archetype, requiredList, currentCount + 1, currentCount + placed)
         end
         callback(archetype, currentCount + 1, currentCount + placed, placed)
      end

      archetype:onRowsAdded(currentCount, placed, nil)
      local observer = self._transitionObserver
      if observer then
         for row = currentCount + 1, currentCount + placed do
            observer.entity(entitiesArr[row], nil, archetype)
         end
      end

      i = i + BATCH_SPAWN_SLOTS
   end




   table_clear(archetype.batchSpawnQueue)
   archetype.batchSpawnQueueCount = 0
end

local function resolveBatchArchetype(
   self,
   componentTypes)

   local archetypeIndex = self.archetypeIndex
   local archetype = archetypeIndex.emptyArchetype
   local requiredList = nil
   for i = 1, #componentTypes do
      local comp = componentTypes[i]
      local ci = comp
      archetype = archetype:withComponent(comp, archetypeIndex)
      if ci._hasRequires then
         local extension
         archetype, extension = applyRequires(archetype, ci, archetypeIndex)
         if extension then
            if requiredList == nil then
               requiredList = extension
            else
               local rl = requiredList
               for k = 1, #extension do
                  rl[#rl + 1] = extension[k]
               end
            end
         end
      end
      local wildcard = ci.wildcardContainer
      if wildcard then
         archetype = archetype:withComponent(wildcard, archetypeIndex)
      end
   end
   local autoState = self.autoStateComponent
   if autoState then
      archetype = archetype:withComponent(autoState, archetypeIndex)
   end
   return archetype, requiredList
end

function WorldImpl:_deferBatchSpawnAt(
   ids,
   componentTypes,
   callback)

   local n = #ids
   if n == 0 then return end

   local archetype, requiredList = resolveBatchArchetype(self, componentTypes)
   stakePendingSpawnAt(self, archetype, n, function(i)
      return ids[i + 1]
   end)

   local c = archetype.batchSpawnAtQueueCount
   local q = archetype.batchSpawnAtQueue
   q[c + 1] = ids
   q[c + 2] = n
   q[c + 3] = callback
   q[c + 4] = requiredList
   archetype.batchSpawnAtQueueCount = c + BATCH_SPAWN_AT_SLOTS
   if archetype.dirtyQueuedEpoch ~= self._dirtyEpoch then archetype.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = archetype; self.dirtyArchetypeCount = __c end
   self.isDirty = true
end

function WorldImpl:_deferBatchSpawnAtRaw(
   ids,
   count,
   componentTypes,
   callback)

   if count == 0 then return end

   local archetype, requiredList = resolveBatchArchetype(self, componentTypes)
   local idsArr = ids
   stakePendingSpawnAt(self, archetype, count, function(i)
      return idsArr[i]
   end)

   local c = archetype.batchSpawnAtQueueCount
   local q = archetype.batchSpawnAtQueue
   q[c + 1] = ids
   q[c + 2] = count
   q[c + 3] = callback
   q[c + 4] = requiredList
   archetype.batchSpawnAtQueueCount = c + BATCH_SPAWN_AT_SLOTS
   if archetype.dirtyQueuedEpoch ~= self._dirtyEpoch then archetype.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = archetype; self.dirtyArchetypeCount = __c end
   self.isDirty = true
end

function WorldImpl:_drainArchBatchSpawnAt(archetype)
   local slots = self.allocator.slots
   local stateArr = self._stateArr
   local slotStamp = self._slotStamp
   local epoch = self._transactionEpoch
   local archId = archetype.id
   local q = archetype.batchSpawnAtQueue

   local i = 1
   while i <= archetype.batchSpawnAtQueueCount do
      local ids = q[i]
      local n = q[i + 1]
      local callback = q[i + 2]
      local requiredList = q[i + 3]

      archetype:reserveCapacity((archetype.entities[0]) + n)
      local entitiesArr = archetype.entities
      local currentCount = entitiesArr[0]



      local placed = 0
      local idsRaw = ids
      local isCdata = type(ids) == "cdata"
      if isCdata then
         for j = 0, n - 1 do
            do local entityId = idsRaw[j]; local entSlot = entityId % 2 ^ 22; local st = (slotStamp[entSlot] == epoch and stateArr[entSlot] or 0); if st == STATE_DESPAWN then slotStamp[entSlot] = 0 else local row = currentCount + placed; entitiesArr[row + 1] = entityId; local es = slots[entSlot]; es.archetypeId = archId; es.row = row; placed = placed + 1; if st == STATE_MUTATE then archetype.hasPendingMoveOut = true; if archetype.dirtyQueuedEpoch ~= self._dirtyEpoch then archetype.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = archetype; self.dirtyArchetypeCount = __c end else slotStamp[entSlot] = 0 end end end
         end
      else
         for j = 1, n do
            do local entityId = idsRaw[j]; local entSlot = entityId % 2 ^ 22; local st = (slotStamp[entSlot] == epoch and stateArr[entSlot] or 0); if st == STATE_DESPAWN then slotStamp[entSlot] = 0 else local row = currentCount + placed; entitiesArr[row + 1] = entityId; local es = slots[entSlot]; es.archetypeId = archId; es.row = row; placed = placed + 1; if st == STATE_MUTATE then archetype.hasPendingMoveOut = true; if archetype.dirtyQueuedEpoch ~= self._dirtyEpoch then archetype.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = archetype; self.dirtyArchetypeCount = __c end else slotStamp[entSlot] = 0 end end end
         end
      end
      entitiesArr[0] = currentCount + placed

      if placed > 0 then
         if requiredList then
            writeRequiredRange(archetype, requiredList, currentCount + 1, currentCount + placed)
         end
         callback(archetype, currentCount + 1, currentCount + placed, placed)
      end

      archetype:onRowsAdded(currentCount, placed, nil)
      local observer = self._transitionObserver
      if observer then
         for row = currentCount + 1, currentCount + placed do
            observer.entity(entitiesArr[row], nil, archetype)
         end
      end

      i = i + BATCH_SPAWN_AT_SLOTS
   end




   table_clear(archetype.batchSpawnAtQueue)
   archetype.batchSpawnAtQueueCount = 0
end

function WorldImpl:_deferBatchDespawn(archetypes)
   local world = self
   local refCounts = (world)._targetRefCounts


   local OnDespawnBuiltin = builtins.OnDespawn
   local despawnEventId = OnDespawnBuiltin.eventId
   local hasGlobalObs = world:hasObservers(0, OnDespawnBuiltin)
   local messagesAny = (world).messages
   local entityObsCount = messagesAny._entityObserverCount
   local busObservers = messagesAny._observers
   local anyPerEntityObs = false
   if entityObsCount > 0 then
      for addr, byEvent in pairs(busObservers) do
         if addr ~= 0 and byEvent[despawnEventId] then
            anyPerEntityObs = true
            break
         end
      end
   end


   local clearedArchIds = nil

   for a = 1, #archetypes do
      local arch = archetypes[a]
      local entities = arch.entities
      local count = entities[0]
      if count > 0 then



         local complex = arch.onDespawnCount > 0
         if not complex then
            for i = 1, count do
               if refCounts[entities[i]] then
                  complex = true
                  break
               end
            end
         end

         if complex then
            for i = count, 1, -1 do
               self:_deferDespawn(entities[i])
            end
         else





            if world._hasRelationshipStores then
               local list = arch.componentList
               for j = 1, arch.columnsCount do
                  local c = list[j]
                  if c.isSparse and c.isContainer then
                     local store = world.relationshipStores[c]
                     if store then
                        for i = 1, count do
                           store:remove(entities[i])
                        end
                     end
                  end
               end
            end

            if hasGlobalObs or anyPerEntityObs then
               for i = 1, count do
                  local id = entities[i]
                  if anyPerEntityObs and world:hasObservers(id, OnDespawnBuiltin) then
                     world:emit(id, OnDespawnBuiltin, id)
                  end
                  if hasGlobalObs then world:emit(0, OnDespawnBuiltin, id) end
               end
            end
            if entityObsCount > 0 then
               if not clearedArchIds then clearedArchIds = {} end
               clearedArchIds[arch.id] = true
            end
            arch.pendingClear = true
            arch.hasPendingDespawns = true; if arch.dirtyQueuedEpoch ~= self._dirtyEpoch then arch.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = arch; self.dirtyArchetypeCount = __c end
         end
      end
   end




   if clearedArchIds then
      local slots = self.allocator.slots
      for addr in pairs(busObservers) do
         if addr ~= 0 and clearedArchIds[slots[addr].archetypeId] then
            world:clearObservers(addr)
         end
      end
   end

   self.isDirty = true
end

local function canBulkBatchComponent(componentType)
   return not behavior.hasBits(componentType, behavior.NoBulkBatch)
end

local function batchMutationSlot(self, c)
   local q = self.batchMutations
   local mut = q[c]
   if not mut then
      mut = {}
      q[c] = mut
   end
   return mut
end

function WorldImpl:_deferBatchSet(
   archetypes,
   componentType,
   value)

   if #archetypes == 0 then return end
   local ci = componentType
   local storedValue = value
   if ci.storageType == "scalar" then
      if value == componentType then
         storedValue = (componentType).scalarDefault
      else
         storedValue = (value).value
      end
   end
   local c = self.batchMutationCount + 1
   local mut = batchMutationSlot(self, c)
   mut.op = BATCH_OP_SET_CONST
   mut.archetypes = archetypes
   mut.componentType = componentType
   mut.value = storedValue
   mut.callback = nil
   mut.isTag = ci.storageType == "tag"
   mut.canBulk = canBulkBatchComponent(componentType)
   self.batchMutationCount = c
   self.isDirty = true
end

function WorldImpl:_deferBatchSetCallback(
   archetypes,
   componentType,
   callback)

   if #archetypes == 0 then return end
   if not canBulkBatchComponent(componentType) then
      error("batchSet callback form requires a bulk-safe component. Use the constant-value form " ..
      "`world:batchSet(query, instance)` for relationship components.")
   end
   local c = self.batchMutationCount + 1
   local mut = batchMutationSlot(self, c)
   mut.op = BATCH_OP_SET_CALLBACK
   mut.archetypes = archetypes
   mut.componentType = componentType
   mut.callback = callback
   mut.value = nil
   mut.isTag = (componentType).storageType == "tag"
   mut.canBulk = true
   self.batchMutationCount = c
   self.isDirty = true
end

function WorldImpl:_deferBatchRemove(
   archetypes,
   componentType)

   if #archetypes == 0 then return end
   local c = self.batchMutationCount + 1
   local mut = batchMutationSlot(self, c)
   mut.op = BATCH_OP_REMOVE
   mut.archetypes = archetypes
   mut.componentType = componentType
   mut.value = nil
   mut.callback = nil
   mut.isTag = (componentType).storageType == "tag"
   mut.canBulk = canBulkBatchComponent(componentType)
   self.batchMutationCount = c
   self.isDirty = true
end




function WorldImpl:_resolveSpawnArchetype(componentTypes)
   return resolveBatchSpawnArchetype(self, componentTypes)
end

function WorldImpl:_drainBatchMutations()
   local count = self.batchMutationCount
   if count == 0 then return end
   local queue = self.batchMutations
   for i = 1, count do
      local mut = queue[i]
      local archetypes = mut.archetypes
      local op = mut.op
      if op == BATCH_OP_REMOVE then
         for a = 1, #archetypes do
            applyBatchRemove(self, mut, archetypes[a])
         end
      else
         for a = 1, #archetypes do
            applyBatchSet(self, mut, archetypes[a])
         end
      end
   end


   local dirtyList = self.dirtyArchetypeList
   for i = 1, self.dirtyArchetypeCount do
      local arch = dirtyList[i]
      if arch.hasPendingMoveOut then
         self:_drainPendingMoves(arch)
      end
   end



   local snapshotPool = self._archetypeSnapshotPool
   for i = 1, count do
      local mut = queue[i]
      snapshotPool:release(mut.archetypes)
      mut.archetypes = nil
   end
   local total = self.batchMutationCount
   if total > count then
      for i = 1, total - count do
         queue[i], queue[count + i] = queue[count + i], nil
      end
      self.batchMutationCount = total - count
   else
      self.batchMutationCount = 0
   end
end


return {}
