local types = require("tecs.types")
local internal = require("tecs.internal.types")
local behavior = require("tecs.internal.behavior")
local fixedtracking = require("tecs.internal.fixedtracking")
local ffi = require("tecs.internal.ffi")
local Bitset = require("tecs.utils.Bitset")
local RelationshipStore = require("tecs.internal.RelationshipStore")
local cffi = require("ffi")
local bit = require("bit")
local table_new = require("table.new")
local table_clear = require("table.clear")
local table_move = table.move

local table_insert, table_concat = table.insert, table.concat
local rawget = rawget
local ensureCapacityDouble, setDoubleArraySize = ffi.ensureCapacityDouble, ffi.setDoubleArraySize
local rshift = bit.rshift










local AUTO_ID = 0

local Archetype = {}



























































































local ARCHETYPE_MT = {
   __index = Archetype,
   __tostring = function(self)
      local compList = self.componentList
      local n = self.columnsCount
      local buf = {}
      table_insert(buf, "Archetype([")
      for i = 1, n do
         if i > 1 then
            table_insert(buf, ", ")
         end
         table_insert(buf, tostring(compList[i]))
      end
      table_insert(buf, "])")
      return table_concat(buf)
   end,
}





function Archetype:get(component)
   local proxy = rawget(self, component)
   if proxy ~= nil then return proxy end
   return rawget(self.columns, component)
end



function Archetype:getMut(component)
   local column = rawget(self.columns, component)
   if column then
      if self._fixedTracking then
         fixedtracking.mark(self, component)
      end
      local idx = self.columnIndexByComponent[component]
      if idx and not self._componentDirty:get(idx) then
         self._componentDirty:set(idx)
         self._dirtySet[self] = true
      end
   end
   local proxy = rawget(self, component)
   if proxy ~= nil then return proxy end
   return column
end






function Archetype:withComponent(component, archetypeIndex)
   if self.columns[component] then
      return self
   end

   local cached = self.addEdges[component]
   if cached then
      return cached
   end

   local n = self.columnsCount
   local dest = table_new(n + 1, 0)
   local componentList = self.componentList
   table_move(componentList, 1, n, 1, dest)
   dest[n + 1] = component

   local idx = archetypeIndex
   local getOrCreate = idx.getOrCreate
   local target = getOrCreate(idx, dest)
   self.addEdges[component] = target
   target.removeEdges[component] = self
   return target
end

function Archetype:withoutComponent(component, archetypeIndex)
   if not self.columns[component] then
      return self
   end

   local cached = self.removeEdges[component]
   if cached then
      return cached
   end

   local n = self.columnsCount
   local dest = table_new(n - 1, 0)
   local componentList = self.componentList
   local j = 0
   for i = 1, n do
      local c = componentList[i]
      if c ~= component then
         j = j + 1
         dest[j] = c
      end
   end

   local idx = archetypeIndex
   local getOrCreate = idx.getOrCreate
   local target = getOrCreate(idx, dest)
   self.removeEdges[component] = target
   target.addEdges[component] = self
   return target
end






function Archetype:getMovePlanTo(dstArch)
   local plans = self.movePlansOut
   local plan = plans[dstArch]
   if plan and plan.srcGen == self.generation and plan.dstGen == dstArch.generation then
      return plan
   end

   local sourceColumns = self.columns
   local sourceColumnIndex = self.columnIndexByComponent
   local destColumnArray = dstArch.columnArray
   local destComponentList = dstArch.componentList
   local srcCols = {}
   local dstCols = {}
   local structSizes = {}
   local comps = {}
   local srcColIndices = {}
   local dstColIndices = {}
   local count = 0
   for j = 1, dstArch.columnsCount do
      local comp = destComponentList[j]
      local sourceCol = sourceColumns[comp]
      if sourceCol and (comp).storageType ~= "tag" then
         count = count + 1
         srcCols[count] = sourceCol
         dstCols[count] = destColumnArray[j]
         structSizes[count] = (comp).structSize or 0
         comps[count] = comp
         dstColIndices[count] = j
         srcColIndices[count] = sourceColumnIndex[comp]
      end
   end

   plan = {
      srcGen = self.generation,
      dstGen = dstArch.generation,
      count = count,
      srcCols = srcCols,
      dstCols = dstCols,
      structSizes = structSizes,
      comps = comps,
      srcColIndices = srcColIndices,
      dstColIndices = dstColIndices,
   }
   plans[dstArch] = plan
   return plan
end









function Archetype:forEachRelationship(relContainer, row, callback)
   local instances = self._relInstancesByContainer
   local list = instances and instances[relContainer]
   if not list then return end
   local columns = self.columns
   for i = 1, #list do
      local col = columns[list[i]]
      callback(col[row])
   end
end

function Archetype:getFirstRelationship(relContainer, row)
   local instances = self._relInstancesByContainer
   local list = instances and instances[relContainer]
   if not list then return nil end
   local col = self.columns[list[1]]
   return col[row]
end





function Archetype:addEntityObserver(observer)
   local nextSlot = self.observerCount + 1
   self.observerCount = nextSlot
   self._observers[nextSlot] = observer
   if observer.onEntitiesRemoved then
      self.hasRemoveObservers = self.hasRemoveObservers + 1
   end
   if observer.onEntitiesAdded then
      self.hasAddObservers = self.hasAddObservers + 1
   end
   if observer.onEntityMove then
      self.hasMoveObservers = self.hasMoveObservers + 1
   end
end

local function notifyMove(self, entity, fromRow, toRow)
   local observers = self._observers
   for i = 1, self.observerCount do
      local obs = observers[i]
      local cb = obs.onEntityMove
      if cb then cb(obs, self, entity, fromRow, toRow) end
   end
end

local function notifyActivated(self)
   local observers = self._observers
   for i = 1, self.observerCount do
      local obs = observers[i]
      local cb = obs.onActivated
      if cb then cb(obs, self) end
   end
end

local function notifyDeactivated(self)
   local observers = self._observers
   for i = 1, self.observerCount do
      local obs = observers[i]
      local cb = obs.onDeactivated
      if cb then cb(obs, self) end
   end
end

function Archetype:onRowsAdded(
   rowStart,
   count,
   sourceArchetype)

   if count <= 0 then return end




   self:markAllComponentsDirty()
   if self.observerCount > 0 then
      self:notifyAdded(rowStart, count, sourceArchetype)
   end
end

function Archetype:notifyAdded(rowStart, count, sourceArchetype)
   if count <= 0 then return end
   if self.hasAddObservers > 0 then
      local observers = self._observers
      local firstRow = rowStart + 1
      local lastRow = rowStart + count
      for i = 1, self.observerCount do
         local obs = observers[i]
         local cb = obs.onEntitiesAdded
         if cb then cb(obs, self, firstRow, lastRow, count, sourceArchetype) end
      end
   end
   if rowStart == 0 and self.observerCount > 0 then
      notifyActivated(self)
   end
end

function Archetype:notifyRemoved(rowStart, count, destArchetype)
   if count <= 0 or self.hasRemoveObservers == 0 then return end
   local observers = self._observers
   local firstRow = rowStart + 1
   local lastRow = rowStart + count
   for i = 1, self.observerCount do
      local obs = observers[i]
      local cb = obs.onEntitiesRemoved
      if cb then cb(obs, self, firstRow, lastRow, count, destArchetype) end
   end
end

function Archetype:notifyDeactivatedExternal()
   notifyDeactivated(self)
end

function Archetype:notifyArchetypeDestroyed()
   local observers = self._observers
   for i = 1, self.observerCount do
      local obs = observers[i]
      if obs.onArchetypeDestroyed then
         obs:onArchetypeDestroyed(self)
      end
   end
end


















function Archetype:reserveCapacity(targetRows)
   if targetRows <= self.capacity then return end

   local newCap = self.capacity * 2
   if newCap < targetRows + 64 then newCap = targetRows + 64 end

   local columns = self.columns
   local columnArray = self.columnArray
   local componentList = self.componentList
   local anySwapped = false
   for j = 1, self.columnsCount do
      local comp = componentList[j]
      local column = columns[comp]
      local storage = (comp).storage
      if storage.ensureCapacity then
         local ensureFn = storage.ensureCapacity
         local newColumn = ensureFn(storage, column, newCap)
         if newColumn ~= column then
            columns[comp] = newColumn
            columnArray[j] = newColumn
            anySwapped = true
         end
      end
   end
   self.entities = ensureCapacityDouble(self.entities, newCap)
   self.capacity = newCap

   if anySwapped then
      self.generation = self.generation + 1
   end
end

function Archetype:removeEntity(row, destArchetype)
   local entities = self.entities
   local lastIndex = self.entities[0]
   local luaRow = row + 1

   if self.hasRemoveObservers > 0 then
      local _observers = self._observers
      for _i = 1, self.observerCount do
         local _obs = _observers[_i]
         local _cb = _obs.onEntitiesRemoved
         if _cb then _cb(_obs, self, luaRow, luaRow, 1, destArchetype) end
      end
   end

   local columnArray = self.columnArray
   local dataColumnsCount = self.dataColumnsCount

   if luaRow == lastIndex then
      setDoubleArraySize(self.entities, lastIndex - 1)





      self:markAllComponentsDirty()

      if self.observerCount > 0 and lastIndex == 1 then
         notifyDeactivated(self)
      end

      return 0, 0
   else
      local movedEntityId = entities[lastIndex]
      entities[luaRow] = movedEntityId
      setDoubleArraySize(self.entities, lastIndex - 1)

      for j = 1, dataColumnsCount do
         local column = columnArray[j]
         column[luaRow] = column[lastIndex]
      end





      self:markAllComponentsDirty()

      if self.hasMoveObservers > 0 then
         notifyMove(self, movedEntityId, lastIndex - 1, row)
      end

      return movedEntityId, lastIndex - 1
   end
end


function Archetype:clearEntities()
   local hadEntities = (self.entities[0]) > 0
   local hasObservers = self.observerCount > 0
   if hadEntities and hasObservers then
      self:notifyRemoved(0, self.entities[0], nil)
   end
   ffi.setDoubleArraySize(self.entities, 0)
   for j = 1, self.columnsCount do
      local comp = self.componentList[j]
      local col = self.columnArray[j]
      local storage = comp.storage;
      (storage.clear)(storage, col)
   end
   self._componentDirty:clearAll()
   if hadEntities and hasObservers then
      notifyDeactivated(self)
   end
end


function Archetype:compact()
   local count = self.entities[0]
   local anySwapped = false

   local newEntities = ffi.adjustCapacityDouble(self.entities, count)
   if newEntities ~= self.entities then
      self.entities = newEntities
      anySwapped = true
   end

   for j = 1, self.columnsCount do
      local comp = self.componentList[j]
      local compStorage = comp.storage
      local adjust = compStorage.adjustCapacity
      if adjust then
         local col = self.columnArray[j]
         local newCol = adjust(compStorage, col, count)
         if newCol ~= col then
            self.columns[comp] = newCol
            self.columnArray[j] = newCol
            anySwapped = true
         end
      end
   end

   if anySwapped then
      self.capacity = count
      self.generation = self.generation + 1
   end
end

function Archetype:resetPending()
   self.pendingWrites = 0
   self.hasPendingDespawns = false
   self.pendingDespawnCount = 0
   table_clear(self.pendingDespawn)
   self.pendingClear = false
   self.hasPendingSpawns = false
   self.pendingSpawnCount = 0
   self.hasPendingMoveOut = false
   if self.pendingValueCount > 0 then
      local slots = self.pendingValueSlots
      local values = self.pendingValues
      for i = 1, self.pendingValueCount do
         local slot = slots[i]
         values[slot] = nil
         slots[i] = nil
      end
      self.pendingValueCount = 0
   end
   if self.hasScalarPending then
      table_clear(self.pendingScalarTypes)
      table_clear(self.pendingScalarValues)
      self.hasScalarPending = false
   end
   if self.batchSpawnQueueCount > 0 then
      local q = self.batchSpawnQueue
      for j = 1, self.batchSpawnQueueCount do q[j] = nil end
      self.batchSpawnQueueCount = 0
   end
   if self.batchSpawnAtQueueCount > 0 then
      local q = self.batchSpawnAtQueue
      for j = 1, self.batchSpawnAtQueueCount do q[j] = nil end
      self.batchSpawnAtQueueCount = 0
   end
   self.pendingBundleDrainCount = 0
end

function Archetype:getPendingValues(slot)
   return self.pendingValues[slot]
end

function Archetype:appendPendingValue(slot, value, newVals)
   local vals = self.pendingValues[slot]
   if vals then
      vals[#vals + 1] = value
      return
   end

   vals = newVals or {}
   vals[1] = value
   self.pendingValues[slot] = vals
   local count = self.pendingValueCount + 1
   self.pendingValueCount = count
   self.pendingValueSlots[count] = slot
end

function Archetype:findPendingValue(slot, componentType)
   local vals = self.pendingValues[slot]
   if not vals then return nil end
   for i = #vals, 1, -1 do
      local inst = vals[i]
      if ((inst).componentType) == componentType then
         return inst
      end
   end
   return nil
end

function Archetype:movePendingValuesTo(dst, slot)
   local vals = self.pendingValues[slot]
   if not vals then return end
   self.pendingValues[slot] = nil
   dst.pendingValues[slot] = vals
   local count = dst.pendingValueCount + 1
   dst.pendingValueCount = count
   dst.pendingValueSlots[count] = slot
end










function Archetype:isComponentDirty(component)
   local idx = self.columnIndexByComponent[component]
   if not idx then return false end
   return self._componentDirty:get(idx)
end

function Archetype:anyComponentDirty()
   return not (self._componentDirty.count == 0)
end

function Archetype:markComponentDirty(component)
   local idx = self.columnIndexByComponent[component]
   if not idx then return end
   if self._fixedTracking then
      fixedtracking.mark(self, component)
   end
   if not self._componentDirty:get(idx) then
      self._componentDirty:set(idx)
      self._dirtySet[self] = true
   end
end

function Archetype:markAllComponentsDirty()
   if self._fixedTracking then
      fixedtracking.markAll(self)
   end



   if self._allDirty then return end
   self._allDirty = true
   local bits = self._componentDirty
   local n = self.columnsCount
   for i = 1, n do
      if not bits:get(i) then bits:set(i) end
   end
   if n > 0 then self._dirtySet[self] = true end
end

function Archetype:clearDirtyComponents()
   self._allDirty = false
   self._componentDirty:clearAll()
end

function Archetype:dirtyComponents()
   local componentList = self.componentList
   local bits = self._componentDirty
   local i = 1
   local n = self.columnsCount
   return function()
      while i <= n do
         local idx = i
         i = i + 1
         if bits:get(idx) then
            return componentList[idx]
         end
      end
      return nil
   end
end

function Archetype:set(row, value)
   local valueAny = value
   local componentType = valueAny.componentType
   if not componentType then
      error("Component value must have a componentType field")
   end

   local column = self.columns[componentType]
   if not column then
      error("Archetype does not have component: " .. tostring(componentType))
   end

   local storage = (componentType).storage
   local storageAny = storage

   if storageAny._ffiConstructor and storageAny._sizeof then
      local dest = (column)[row]
      cffi.copy(dest, value, storageAny._sizeof)
   else
      (column)[row] = value
   end

   self:markComponentDirty(componentType)
end






local function createSparseColumnProxy(archetypeTable, store)
   local proxy = {}
   local mt = {
      __index = function(_self, row)
         local entities = (archetypeTable).entities
         local entityId = (entities)[row]
         return store:get(entityId)
      end,
      __newindex = function()
         error("Cannot write to sparse column via row index. Use world:set() instead.")
      end,
   }
   return setmetatable(proxy, mt)
end


function Archetype.new(
   components,
   dirtySet,
   relationshipStoreGetter)

   AUTO_ID = AUTO_ID + 1
   local columnsCount = #components
   local columns = table_new(0, columnsCount)
   local componentList = table_new(columnsCount, 0)
   local columnArray = table_new(columnsCount, 0)
   local columnIndexByComponent = table_new(0, columnsCount)
   local signatureBits = Bitset.new()
   local signatureWordBits = Bitset.new()

   local isEphemeral = false

   local dataColumnsCount = 0
   for i = 1, columnsCount do
      if (components[i]).storageType ~= "tag" then
         dataColumnsCount = dataColumnsCount + 1
      end
   end

   local onDespawnComponents = {}
   local onDespawnCount = 0
   local relInstancesByContainer = nil

   local nextDataIdx = 1
   local nextTagIdx = dataColumnsCount + 1
   for i = 1, columnsCount do
      local comp = components[i]
      local compI = comp
      local idx
      if compI.storageType == "tag" then
         idx = nextTagIdx
         nextTagIdx = nextTagIdx + 1
      else
         idx = nextDataIdx
         nextDataIdx = nextDataIdx + 1
      end
      componentList[idx] = comp
      columnIndexByComponent[comp] = idx

      local signatureIndex = compI.signatureIndex or (comp.componentId - 1)
      local signatureWordIndex = compI.signatureWordIndex or rshift(signatureIndex, 5)
      signatureBits:set(signatureIndex)
      signatureWordBits:set(signatureWordIndex)

      if comp.target ~= nil then isEphemeral = true end
      if behavior.hasBits(comp, behavior.NeedsDespawn) then
         onDespawnCount = onDespawnCount + 1
         onDespawnComponents[onDespawnCount] = comp
      end




      local rc = compI.relationshipType
      if rc ~= nil and (rc) ~= comp then
         if relInstancesByContainer == nil then
            relInstancesByContainer = {}
         end
         local list = relInstancesByContainer[rc]
         if not list then
            list = {}
            relInstancesByContainer[rc] = list
         end
         list[#list + 1] = comp
      end
   end

   local self = {
      id = AUTO_ID,
      entities = ffi.newDouble(16),
      signatureBits = signatureBits,
      signatureWordBits = signatureWordBits,
      columns = columns,
      columnArray = columnArray,
      componentList = componentList,
      columnIndexByComponent = columnIndexByComponent,
      columnsCount = columnsCount,
      dataColumnsCount = dataColumnsCount,
      pendingWrites = 0,
      capacity = 0,
      observerCount = 0,
      hasRemoveObservers = 0,
      hasAddObservers = 0,
      hasMoveObservers = 0,
      isEphemeral = isEphemeral,
      onDespawnComponents = onDespawnComponents,
      onDespawnCount = onDespawnCount,
      addEdges = {},
      removeEdges = {},
      movePlansOut = {},
      generation = 0,
      pendingDespawn = {},
      pendingDespawnCount = 0,
      pendingClear = false,
      pendingSpawnIds = {},
      pendingSpawnCount = 0,
      pendingValues = {},
      pendingValueSlots = {},
      pendingValueCount = 0,
      pendingScalarTypes = {},
      pendingScalarValues = {},
      hasScalarPending = false,
      hasPendingDespawns = false,
      hasPendingSpawns = false,
      hasPendingMoveOut = false,
      pendingBundleDrains = {},
      pendingBundleDrainCount = 0,
      batchSpawnQueue = {},
      batchSpawnQueueCount = 0,
      batchSpawnAtQueue = {},
      batchSpawnAtQueueCount = 0,
      _observers = {},
      _allDirty = false,
      _relInstancesByContainer = relInstancesByContainer,
      _componentDirty = Bitset.new(columnsCount + 1),
      _dirtySet = dirtySet,
      _fixedTracking = fixedtracking.enabled(dirtySet),
      dirtyQueuedEpoch = 0,
   }

   for i = 1, columnsCount do
      local comp = componentList[i]
      local compI = comp
      local compStorage = compI.storage
      local createColumn = compStorage.createColumn
      local store = createColumn(compStorage, 0)
      columns[comp] = store
      columnArray[i] = store










      if compI.isSparse and comp.relationshipType == comp and relationshipStoreGetter then
         local sparseStore = relationshipStoreGetter(comp);
         (self)[comp] = createSparseColumnProxy(self, sparseStore)
      end
   end

   return setmetatable(self, ARCHETYPE_MT)
end

return Archetype
