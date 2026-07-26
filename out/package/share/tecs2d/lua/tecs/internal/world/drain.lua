



local types = require("tecs.types")
local internal = require("tecs.internal.types")
local IdAllocator = require("tecs.internal.IdAllocator")
local bundlecodegen = require("tecs.internal.bundlecodegen")
local pool = require("tecs.utils.pool")
local table_clear = require("table.clear")
local shared = require("tecs.internal.world.shared")






local WorldImpl = internal.WorldImpl

local STATE_DESPAWN = shared.STATE_DESPAWN

local copyPlanRow = shared.copyPlanRow
local applyPendingVals = shared.applyPendingVals
local applyPendingScalars = shared.applyPendingScalars
local bumpTransactionEpoch = shared.bumpTransactionEpoch

local pairs = pairs

function WorldImpl:_truncateArchetype(arch)
   local entities = arch.entities
   local archCount = entities[0]
   if archCount == 0 then return end

   local arena = self.allocator
   local observer = self._transitionObserver
   if observer then
      for r = 1, archCount do
         observer.entity(entities[r], arch, nil)
      end
   end



   arch:notifyRemoved(0, archCount, nil)
   for r = 1, archCount do
      IdAllocator.freeSlot(arena, entities[r] % 2 ^ 22)
   end
   entities[0] = 0
   if arch.observerCount > 0 then
      arch:notifyDeactivatedExternal()
   end
end

function WorldImpl:_drainPendingSpawns(arch)
   local slots = self.allocator.slots
   local pendingArchArr = self._pendingArchArr
   local stateArr = self._stateArr
   local slotStamp = self._slotStamp
   local epoch = self._transactionEpoch
   local archId = arch.id

   local ids = arch.pendingSpawnIds
   local count = arch.pendingSpawnCount
   local hasScalarPending = arch.hasScalarPending
   local archPendingScalarTypes = arch.pendingScalarTypes
   local archPendingScalarValues = arch.pendingScalarValues
   if count > 0 then
      arch:reserveCapacity((arch.entities[0]) + count)
      local entities = arch.entities
      local startRow = entities[0]
      local cols = arch.columns

      local placed = 0
      for k = 1, count do

         local packedId = ids[k]
         local slot = packedId % 2 ^ 22
         if slotStamp[slot] ~= epoch or
            pendingArchArr[slot] ~= archId or
            stateArr[slot] == STATE_DESPAWN then
            goto nextSpawn
         end

         local row = startRow + placed
         local es = slots[slot]
         es.archetypeId = archId
         es.row = row
         entities[row + 1] = packedId

         local vals = arch:getPendingValues(slot)
         if vals then
            applyPendingVals(vals, cols, row + 1)
         end
         if hasScalarPending then
            local scalarTypes = archPendingScalarTypes[slot]
            if scalarTypes then
               applyPendingScalars(scalarTypes, archPendingScalarValues[slot], cols, row + 1)
            end
         end



         slotStamp[slot] = 0
         self.entityStateCount = self.entityStateCount - 1

         placed = placed + 1
         local observer = self._transitionObserver
         if observer then observer.entity(packedId, nil, arch) end
         ::nextSpawn::
      end

      entities[0] = startRow + placed

      arch:onRowsAdded(startRow, placed, nil)
   end
end

function WorldImpl:_drainPendingMoves(srcArch)


   srcArch.hasPendingMoveOut = false
   local srcEntities = srcArch.entities
   local srcCount = srcEntities[0]
   if srcCount == 0 then return end

   local slots = self.allocator.slots
   local pendingArchArr = self._pendingArchArr
   local stateArr = self._stateArr
   local slotStamp = self._slotStamp
   local epoch = self._transactionEpoch
   local archIndex = self.archetypeIndex
   local toRemove = self._swapRemoveQueue
   local srcHasScalarPending = srcArch.hasScalarPending
   local srcPendingScalarTypes = srcArch.pendingScalarTypes
   local srcPendingScalarValues = srcArch.pendingScalarValues
   local getMovePlanTo = srcArch.getMovePlanTo
   local removeCount = 0
   local lastPlanDst = nil
   local plan = nil
   local planCount = 0
   local planSrcCols = nil
   local planDstCols = nil
   local dstCols = nil
   local dstArchId = 0

   for r = srcCount, 1, -1 do
      local entId = srcEntities[r]
      local entSlot = entId % 2 ^ 22
      local dstArch = nil


      if slotStamp[entSlot] == epoch and stateArr[entSlot] ~= STATE_DESPAWN then
         local archId = pendingArchArr[entSlot]
         if archId ~= 0 then dstArch = archIndex[archId] end
      end

      if dstArch == srcArch then







         if srcArch.pendingWrites > 0 then
            srcArch.pendingWrites = srcArch.pendingWrites - 1
         end
         local vals = srcArch:getPendingValues(entSlot)
         if vals then
            applyPendingVals(vals, srcArch.columns, r)
            for v = 1, #vals do
               local ct = (vals[v]).componentType
               srcArch:markComponentDirty(ct)
            end
         end
         if srcHasScalarPending then
            local scalarTypes = srcPendingScalarTypes[entSlot]
            if scalarTypes then
               applyPendingScalars(scalarTypes, srcPendingScalarValues[entSlot],
               srcArch.columns, r)
               for v = 1, #scalarTypes do
                  srcArch:markComponentDirty(scalarTypes[v])
               end
            end
         end
      elseif dstArch ~= nil then

         if dstArch.pendingWrites > 0 then
            dstArch:reserveCapacity(dstArch.entities[0] + dstArch.pendingWrites)
            dstArch.pendingWrites = 0
         end
         local dstEntities = dstArch.entities



         if (dstEntities[0]) + 1 > dstArch.capacity then
            dstArch:reserveCapacity((dstEntities[0]) + 1)
            dstEntities = dstArch.entities

            lastPlanDst = nil
         end

         if dstArch ~= lastPlanDst then
            plan = getMovePlanTo(srcArch, dstArch)
            lastPlanDst = dstArch
            planCount = plan.count
            planSrcCols = plan.srcCols
            planDstCols = plan.dstCols
            dstCols = dstArch.columns
            dstArchId = dstArch.id
         end

         local newRow = dstEntities[0]
         local dLuaRow = newRow + 1

         copyPlanRow(planDstCols, planSrcCols, dLuaRow, r, planCount)

         local vals = srcArch:getPendingValues(entSlot)
         if vals then
            applyPendingVals(vals, dstCols, dLuaRow)
         end
         if srcHasScalarPending then
            local scalarTypes = srcPendingScalarTypes[entSlot]
            if scalarTypes then
               applyPendingScalars(scalarTypes, srcPendingScalarValues[entSlot], dstCols, dLuaRow)
            end
         end


         dstEntities[dLuaRow] = entId
         dstEntities[0] = newRow + 1
         local es = slots[entSlot]
         es.archetypeId = dstArchId
         es.row = newRow



         dstArch:onRowsAdded(newRow, 1, srcArch)
         local observer = self._transitionObserver
         if observer then observer.entity(entId, srcArch, dstArch) end

         removeCount = removeCount + 1
         toRemove[removeCount] = r
      end
   end

   if removeCount == 0 then return end

   if removeCount >= srcCount then
      if srcArch.observerCount > 0 then
         for r = 1, srcCount do
            local entSlot = srcEntities[r] % 2 ^ 22
            local dst = nil
            if slotStamp[entSlot] == epoch then
               local archId = pendingArchArr[entSlot]
               if archId ~= 0 then dst = archIndex[archId] end
            end
            srcArch:notifyRemoved(r - 1, 1, dst)
         end
         srcArch:notifyDeactivatedExternal()
      end
      srcEntities[0] = 0
   else
      for k = 1, removeCount do
         local row = toRemove[k]
         local srcEntSlot = srcEntities[row] % 2 ^ 22
         local entDst = nil
         if slotStamp[srcEntSlot] == epoch then
            local archId = pendingArchArr[srcEntSlot]
            if archId ~= 0 then entDst = archIndex[archId] end
         end
         local movedEntId = srcArch:removeEntity(row - 1, entDst)
         if movedEntId ~= 0 then

            local movedSlot = movedEntId % 2 ^ 22
            slots[movedSlot].row = row - 1
         end
      end
   end
end

function WorldImpl:_drainPendingDespawns(arch)
   local arena = self.allocator
   local slots = arena.slots

   if arch.pendingClear then
      self:_truncateArchetype(arch)
      arch.pendingClear = false
      arch.pendingDespawnCount = 0
   elseif arch.pendingDespawnCount > 0 then
      repeat
         local list = arch.pendingDespawn
         local removeCount = arch.pendingDespawnCount
         local entities = arch.entities
         local archCount = entities[0]

         if removeCount >= archCount then
            self:_truncateArchetype(arch)


            arch.pendingDespawnCount = 0
         else


            for i = 1, removeCount do
               local slotOfRow = list[i]
               local row = slots[slotOfRow].row + 1
               local observer = self._transitionObserver
               if observer then observer.entity(entities[row], arch, nil) end
               local movedEntId = arch:removeEntity(row - 1, nil)
               IdAllocator.freeSlot(arena, slotOfRow)
               if movedEntId ~= 0 then
                  slots[movedEntId % 2 ^ 22].row = row - 1
               end
               list[i] = nil
            end


            local staged = arch.pendingDespawnCount - removeCount
            if staged > 0 then
               for i = 1, staged do
                  list[i] = list[removeCount + i]
                  list[removeCount + i] = nil
               end
            end
            arch.pendingDespawnCount = staged
         end
      until arch.pendingDespawnCount == 0
   end
end

function WorldImpl:_codegenBundleSpawn(
   typeArray,
   factoryArray,
   requiredCount)

   return bundlecodegen.codegenBundleSpawn(self, typeArray, factoryArray, requiredCount)
end

local function resetTransaction(self)





   bumpTransactionEpoch(self)
   self.entityStateCount = 0

   local sparsePool = self._sparseArraysPool
   for id, list in pairs(self.sparseSets) do
      self.sparseSets[id] = nil
      sparsePool:release(list)
   end
   self.sparseSetCount = 0

   self._valsPoolNext = 1
   self.lastArch = nil

   if self.batchMutationCount > 0 then
      local q = self.batchMutations

      local snapshotPool = self._archetypeSnapshotPool
      for i = 1, self.batchMutationCount do
         local mut = q[i]
         snapshotPool:release(mut.archetypes)
         mut.archetypes = nil
      end
      self.batchMutationCount = 0
   end

   local dirtyList = self.dirtyArchetypeList
   local dirtyCount = self.dirtyArchetypeCount
   for i = 1, dirtyCount do
      local arch = dirtyList[i]
      arch:resetPending()



      dirtyList[i] = nil
   end
   self.dirtyArchetypeCount = 0





   local e = self._dirtyEpoch + 1
   if e > 0xFFFFFFFF then
      local archetypeIndex = self.archetypeIndex
      for i = 1, archetypeIndex.maxId do
         local a = archetypeIndex[i]
         if a then a.dirtyQueuedEpoch = 0 end
      end
      e = 1
   end
   self._dirtyEpoch = e

   self.isDirty = false
end

local function commitSparseChanges(self)
   local stores = self.relationshipStores
   local stateArr = self._stateArr
   local slotStamp = self._slotStamp
   local epoch = self._transactionEpoch
   local slots = self.allocator.slots
   local sparsePool = self._sparseArraysPool
   for slot, sets in pairs(self.sparseSets) do
      local stagedId = (sets).id



      if not (math.floor(stagedId / 2 ^ 22) ~= slots[slot].generation) and
         not (slotStamp[slot] == epoch and stateArr[slot] == STATE_DESPAWN) then

         local arch = self.archetypeIndex[slots[slot].archetypeId]
         for si = 1, #sets do
            local value = sets[si]
            local rel = value
            local container = rel.relationshipType
            local store = stores[container]
            if store then
               store:set(stagedId, value)



               if arch then
                  arch:markComponentDirty(container)
               end
            end
         end
      end


      self.sparseSets[slot] = nil
      sparsePool:release(sets)
   end
   self.sparseSetCount = 0
end


local MAX_DRAIN_ITERATIONS = 64

function WorldImpl:_drain()
   if not self.isDirty then
      return
   end


   local outerDepth = self._scopeDepth
   self._scopeDepth = outerDepth + 1

   local dirtyList = self.dirtyArchetypeList
   local processed = 0
   local iterations = 0




   while true do
      iterations = iterations + 1
      if iterations > MAX_DRAIN_ITERATIONS then
         error("_drain exceeded MAX_DRAIN_ITERATIONS; likely an observer cascade with no fixed point")
      end

      local count = self.dirtyArchetypeCount
      if processed < count then



         for i = processed + 1, count do
            dirtyList[i].dirtyQueuedEpoch = 0
         end


         for i = processed + 1, count do
            local arch = dirtyList[i]
            if arch.hasPendingDespawns then
               self:_drainPendingDespawns(arch)
            end
         end


         for i = processed + 1, count do
            local arch = dirtyList[i]
            local pendingBundleDrainCount = arch.pendingBundleDrainCount
            if pendingBundleDrainCount > 0 then
               local drains = arch.pendingBundleDrains
               for j = 1, pendingBundleDrainCount do
                  (drains[j])()
               end
               table_clear(drains)
               arch.pendingBundleDrainCount = 0
            end
            if arch.batchSpawnQueueCount > 0 then
               self:_drainArchBatchSpawn(arch)
            end
            if arch.batchSpawnAtQueueCount > 0 then
               self:_drainArchBatchSpawnAt(arch)
            end
            if arch.hasPendingSpawns then
               self:_drainPendingSpawns(arch)
            end
         end


         for i = processed + 1, count do
            local arch = dirtyList[i]
            if arch.hasPendingMoveOut then
               self:_drainPendingMoves(arch)
            end
         end

         processed = count
      elseif self.batchMutationCount > 0 or self.sparseSetCount > 0 then


         if self.batchMutationCount > 0 then
            self:_drainBatchMutations()
         end
         if self.sparseSetCount > 0 then
            commitSparseChanges(self)
         end
      else
         break
      end
   end

   resetTransaction(self)
   self._scopeDepth = outerDepth
end

function WorldImpl:_resetTxn()
   if self.isDirty then
      resetTransaction(self)
   end
end


return {}
