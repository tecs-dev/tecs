



local types = require("tecs.types")
local internal = require("tecs.internal.types")
local IdAllocator = require("tecs.internal.IdAllocator")
local C = require("ffi")







local table_move = table.move

local ffi_copy = C.copy
local SIZEOF_DOUBLE = C.sizeof("double")


local ffi_add_rows
do
   local loadfn = rawget(_G, "load") or rawget(_G, "loadstring")
   local fn = (loadfn)(
   "return function(p, r) return p + r end")()

   ffi_add_rows = fn
end

local STATE_SPAWN = 1
local STATE_MUTATE = 2
local STATE_DESPAWN = 3












local function getEntityState(world, slot)
   if (world._slotStamp)[slot] == world._transactionEpoch then
      return (world._stateArr)[slot]
   end
   return 0
end


local function setEntityState(world, slot, state)
   local stamp = world._slotStamp
   local epoch = world._transactionEpoch
   local stateArr = world._stateArr
   if stamp[slot] ~= epoch then
      stamp[slot] = epoch;
      (world._pendingArchArr)[slot] = 0
   end
   stateArr[slot] = state
end



local function getPendingArch(world, slot)
   if (world._slotStamp)[slot] == world._transactionEpoch then
      local id = (world._pendingArchArr)[slot]
      if id ~= 0 then return world.archetypeIndex[id] end
   end
   return nil
end


local function setPendingArch(world, slot, arch)
   local stamp = world._slotStamp
   local epoch = world._transactionEpoch
   local pendingArchArr = world._pendingArchArr
   if stamp[slot] ~= epoch then
      stamp[slot] = epoch;
      (world._stateArr)[slot] = 0
   end
   pendingArchArr[slot] = arch.id
end




local function bumpTransactionEpoch(world)
   local e = world._transactionEpoch + 1
   if e == 0 or e > 0xFFFFFFFF then
      C.fill(world._slotStamp, (world._maxSlotCount + 1) * 4, 0)
      e = 1
   end
   world._transactionEpoch = e
end


local BATCH_OP_SET_CONST = 1
local BATCH_OP_SET_CALLBACK = 2
local BATCH_OP_REMOVE = 3













local function moveSingleEntity(
   self,
   slot,
   srcArch,
   srcRow,
   dstArch,
   newColumn,
   newValue)

   local newRow = (dstArch.entities)[0]
   if newRow + 1 > dstArch.capacity then
      dstArch:reserveCapacity(newRow + 1)
   end
   local dstEntities = dstArch.entities
   local dstLuaRow = newRow + 1
   local srcLuaRow = srcRow + 1

   local plan = srcArch:getMovePlanTo(dstArch)
   local planSrcCols = plan.srcCols
   local planDstCols = plan.dstCols
   for c = 1, plan.count do
      planDstCols[c][dstLuaRow] = planSrcCols[c][srcLuaRow]
   end

   if newColumn then
      newColumn[dstLuaRow] = newValue
   end

   local packedId = (srcArch.entities)[srcLuaRow]
   dstEntities[dstLuaRow] = packedId
   dstEntities[0] = newRow + 1

   local slots = self.allocator.slots
   local s = slots[slot]
   s.archetypeId = dstArch.id
   s.row = newRow

   dstArch:onRowsAdded(newRow, 1, srcArch)

   local movedEntId = srcArch:removeEntity(srcRow, dstArch)
   if movedEntId ~= 0 then
      local movedSlot = movedEntId % 2 ^ 22
      slots[movedSlot].row = srcRow
   end
   local observer = self._transitionObserver
   if observer then observer.entity(packedId, srcArch, dstArch) end
end

local function bulkMoveEntireArchetype(
   self,
   srcArch,
   dstArch)

   local srcEntities = srcArch.entities
   local count = srcEntities[0]
   if count == 0 then return 0, 0 end
   local observer = self._transitionObserver
   if observer then
      for i = 1, count do
         observer.entity(srcEntities[i], srcArch, dstArch)
      end
   end

   local plan = srcArch:getMovePlanTo(dstArch)
   local planCount = plan.count
   local dstEntities = dstArch.entities
   local dstBase = dstEntities[0]
   local dstArchId = dstArch.id


   if dstBase == 0 then
      dstArch:reserveCapacity(count)
      dstEntities = dstArch.entities

      local planComps = plan.comps
      local planSrcIdx = plan.srcColIndices
      local planDstIdx = plan.dstColIndices
      local planSrcCols = plan.srcCols
      local planDstCols = plan.dstCols
      local srcColumns = srcArch.columns
      local dstColumns = dstArch.columns
      local srcColArr = srcArch.columnArray
      local dstColArr = dstArch.columnArray

      local srcArchTable = srcArch
      local dstArchTable = dstArch
      for c = 1, planCount do
         local comp = planComps[c]
         local srcCol = srcColumns[comp]
         local dstCol = dstColumns[comp]
         srcColumns[comp] = dstCol
         dstColumns[comp] = srcCol
         srcColArr[planSrcIdx[c]] = dstCol
         dstColArr[planDstIdx[c]] = srcCol
         local compI = comp
         if not (compI.isSparse and compI.relationshipType == comp) then
            srcArchTable[comp] = dstCol
            dstArchTable[comp] = srcCol
         end
         planSrcCols[c] = dstCol
         planDstCols[c] = srcCol
      end

      local srcEntitiesArr = srcArch.entities
      local dstEntitiesArr = dstArch.entities
      srcArch.entities = dstEntitiesArr
      dstArch.entities = srcEntitiesArr
      srcEntities[0] = count
      dstEntities[0] = 0






      local srcCap = srcArch.capacity
      local dstCap = dstArch.capacity
      local minCap = srcCap < dstCap and srcCap or dstCap
      srcArch.capacity = minCap
      dstArch.capacity = minCap

      local slots = self.allocator.slots

      for i = 1, count do
         local s = slots[srcEntities[i] % 2 ^ 22]
         s.archetypeId = dstArchId
         s.row = i - 1
      end

      local srcGen = srcArch.generation + 1
      local dstGen = dstArch.generation + 1
      srcArch.generation = srcGen
      dstArch.generation = dstGen
      plan.srcGen = srcGen
      plan.dstGen = dstGen

      dstArch:onRowsAdded(0, count, srcArch)
      if srcArch.observerCount > 0 then
         srcArch:notifyRemoved(0, count, dstArch)
         srcArch:notifyDeactivatedExternal()
      end

      return count, 1
   end

   dstArch:reserveCapacity(dstBase + count)
   dstEntities = dstArch.entities
   local dstColumnsNow = dstArch.columns

   local planSrcCols = plan.srcCols
   local planComps = plan.comps
   local planStructSizes = plan.structSizes
   for c = 1, planCount do
      local srcCol = planSrcCols[c]
      local dstCol = dstColumnsNow[planComps[c]]
      local structSize = planStructSizes[c]
      if structSize > 0 then
         ffi_copy(
         ffi_add_rows(dstCol, dstBase + 1),
         ffi_add_rows(srcCol, 1),
         count * structSize)
      else
         table_move(srcCol, 1, count, dstBase + 1, dstCol)
      end
   end

   ffi_copy(
   ffi_add_rows(dstEntities, dstBase + 1),
   ffi_add_rows(srcEntities, 1),
   count * SIZEOF_DOUBLE)
   dstEntities[0] = dstBase + count

   local slots = self.allocator.slots

   for i = 1, count do
      local s = slots[srcEntities[i] % 2 ^ 22]
      s.archetypeId = dstArchId
      s.row = dstBase + i - 1
   end

   dstArch:onRowsAdded(dstBase, count, srcArch)
   if srcArch.observerCount > 0 then
      srcArch:notifyRemoved(0, count, dstArch)
   end

   srcEntities[0] = 0
   if srcArch.observerCount > 0 then
      srcArch:notifyDeactivatedExternal()
   end

   return count, dstBase + 1
end

local function copyPlanRow(
   planDstCols,
   planSrcCols,
   dLuaRow,
   srcRow,
   count)

   for c = 1, count do
      planDstCols[c][dLuaRow] = planSrcCols[c][srcRow]
   end
end

local function applyPendingVals(
   vals,
   dstCols,
   dLuaRow)

   for v = 1, #vals do
      local inst = vals[v]
      local ct = (inst).componentType
      local col = dstCols[ct]
      if col and ct.storageType ~= "tag" then
         col[dLuaRow] = inst
      end
   end
end

local function applyPendingScalars(
   ctList,
   values,
   dstCols,
   dLuaRow)

   for i = 1, #ctList do
      local col = dstCols[ctList[i]]
      if col then
         col[dLuaRow] = values[i]
      end
   end
end





local function buildRequiresClosure(comp)
   local entries = {}
   local visited = { [comp] = true }
   local stack = { comp }
   local top = 1

   while top > 0 do
      local cur = stack[top]
      top = top - 1
      local reqs = cur.requires
      if reqs then
         for i = 1, #reqs do
            local r = reqs[i]
            local rType
            local sharedValue
            local factory
            if (r.componentType) == r then

               rType = r
               if r.storageType == "tag" then
                  sharedValue = r
               else
                  factory = r
               end
            else

               rType = r.componentType
               sharedValue = r
            end
            if not visited[rType] then
               visited[rType] = true
               local entry = {
                  type = rType,
                  sharedValue = sharedValue,
                  factory = factory,
                  writeColumn = rType.storageType ~= "tag",
               }
               entries[#entries + 1] = entry
               top = top + 1
               stack[top] = rType
            end
         end
      end
   end

   return entries
end


local function getRequiresClosure(comp)
   local closure = comp._requiresClosure
   if closure == nil then
      closure = buildRequiresClosure(comp)
      comp._requiresClosure = closure
   end
   return closure
end


local function applyRequires(
   dstArch,
   comp,
   archetypeIndex)

   if not comp._hasRequires then return dstArch, nil end
   local closure = getRequiresClosure(comp)
   local missing = nil
   for i = 1, #closure do
      local entry = closure[i]
      if dstArch.columns[entry.type] == nil then
         dstArch = dstArch:withComponent(entry.type, archetypeIndex)
         if entry.writeColumn then
            missing = missing or {}
            missing[#missing + 1] = entry
         end
      end
   end
   return dstArch, missing
end




local function writeRequired(
   missing,
   dstArch,
   dLuaRow)

   if missing == nil then return end
   local cols = dstArch.columns
   for i = 1, #missing do
      local entry = missing[i]
      local col = cols[entry.type]
      if col then
         local v = entry.sharedValue
         if v == nil then
            v = (entry.factory)()
         end
         if (entry.type).storageType == "scalar" then
            col[dLuaRow] = (v).value
         else
            col[dLuaRow] = v
         end
      end
   end
end




local function writeRequiredRange(
   arch,
   requiredList,
   rStart,
   rEnd)

   local cols = arch.columns
   for k = 1, #requiredList do
      local entry = requiredList[k]
      local col = cols[entry.type]
      if col then
         local storage = (entry.type).storageType
         if storage == "table" then
            for r = rStart, rEnd do
               col[r] = (entry.factory)()
            end
         else
            local v = entry.sharedValue
            if v == nil then
               v = (entry.factory)()
            end
            if storage == "scalar" then
               v = (v).value
            end
            for r = rStart, rEnd do
               col[r] = v
            end
         end
      end
   end
end

local function applyBatchSet(self, mut, srcArch)
   local componentType = mut.componentType
   local archetypeIndex = self.archetypeIndex

   local entities = srcArch.entities
   local count = entities[0]
   if count == 0 then return end

   local hasComponent = srcArch.columns[componentType] ~= nil
   local fast = mut.canBulk
   local isTag = mut.isTag

   if not fast then

      local value = mut.value
      for i = count, 1, -1 do
         self:_instantSet(entities[i], componentType, value)
      end
      return
   end

   if hasComponent then
      if not isTag then
         local col = srcArch.columns[componentType]
         if mut.op == BATCH_OP_SET_CONST then
            local value = mut.value
            for row = 1, count do
               col[row] = value
            end
         else
            mut.callback(srcArch, 1, count, count)
         end
      end


      srcArch:markComponentDirty(componentType)
      return
   end

   local dstArch = srcArch:withComponent(componentType, archetypeIndex)
   local ci = componentType
   local requiredList = nil
   if ci._hasRequires then
      dstArch, requiredList = applyRequires(dstArch, ci, archetypeIndex)
   end
   if dstArch == srcArch then return end
   local moved, firstRow = bulkMoveEntireArchetype(self, srcArch, dstArch)
   if moved == 0 then return end
   local lastRow = firstRow + moved - 1


   if requiredList then
      writeRequiredRange(dstArch, requiredList, firstRow, lastRow)
   end
   if isTag then return end

   local newCol = dstArch.columns[componentType]
   if mut.op == BATCH_OP_SET_CONST then
      local value = mut.value
      for row = firstRow, lastRow do
         newCol[row] = value
      end
   else
      mut.callback(dstArch, firstRow, lastRow, moved)
   end
end

local function applyBatchRemove(self, mut, srcArch)
   local componentType = mut.componentType
   if srcArch.columns[componentType] == nil then return end

   local entities = srcArch.entities
   local count = entities[0]
   if count == 0 then return end

   if not mut.canBulk then

      for i = count, 1, -1 do
         self:_instantRemove(entities[i], componentType)
      end
      return
   end

   local archetypeIndex = self.archetypeIndex
   local dstArch = srcArch:withoutComponent(componentType, archetypeIndex)
   if dstArch == srcArch then return end
   bulkMoveEntireArchetype(self, srcArch, dstArch)
end

local shared = {}





































shared.STATE_SPAWN = STATE_SPAWN
shared.STATE_MUTATE = STATE_MUTATE
shared.STATE_DESPAWN = STATE_DESPAWN
shared.BATCH_OP_SET_CONST = BATCH_OP_SET_CONST
shared.BATCH_OP_SET_CALLBACK = BATCH_OP_SET_CALLBACK
shared.BATCH_OP_REMOVE = BATCH_OP_REMOVE
shared.SIZEOF_DOUBLE = SIZEOF_DOUBLE
shared.ffi_add_rows = ffi_add_rows
shared.moveSingleEntity = moveSingleEntity
shared.bulkMoveEntireArchetype = bulkMoveEntireArchetype
shared.applyBatchSet = applyBatchSet
shared.applyBatchRemove = applyBatchRemove
shared.copyPlanRow = copyPlanRow
shared.applyPendingVals = applyPendingVals
shared.applyPendingScalars = applyPendingScalars
shared.getRequiresClosure = getRequiresClosure
shared.applyRequires = applyRequires
shared.writeRequired = writeRequired
shared.writeRequiredRange = writeRequiredRange
shared.getEntityState = getEntityState
shared.setEntityState = setEntityState
shared.getPendingArch = getPendingArch
shared.setPendingArch = setPendingArch
shared.bumpTransactionEpoch = bumpTransactionEpoch

return shared
