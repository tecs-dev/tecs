






local Context = require("tecs.internal.Context")
local types = require("tecs.types")
local internal = require("tecs.internal.types")

local ArchetypeIndex = require("tecs.internal.ArchetypeIndex")
local RelationshipStore = require("tecs.internal.RelationshipStore")
local pipeline = require("tecs.internal.pipeline")
local pool = require("tecs.utils.pool")
local builtins = require("tecs.internal.builtins")
local components = require("tecs.internal.components")
local QueryImpl = require("tecs.internal.QueryImpl")
local phases = require("tecs.internal.phases")
local events = require("tecs.internal.events")
local FFIEvents = require("tecs.internal.ffi.FFIEvents")
local bundleModule = require("tecs.internal.bundle")
local snapshotModule = require("tecs.internal.snapshot")
local IdAllocator = require("tecs.internal.IdAllocator")
local table_clear = require("table.clear")
local C = require("ffi")
local GLOBAL_FFI_EVENTS = FFIEvents.global()



















local UINT8_ARR_T = C.typeof("uint8_t[?]")
local UINT32_ARR_T = C.typeof("uint32_t[?]")





local WorldImpl = internal.WorldImpl

local WORLD_MT = { __index = WorldImpl }


local function makeRelationshipStoresMT(world)
   local refCounts = world._targetRefCounts
   local onAdded = function(targetId)
      refCounts[targetId] = (refCounts[targetId] or 0) + 1
   end
   local onRemoved = function(targetId)
      local c = refCounts[targetId]
      if c and c <= 1 then
         refCounts[targetId] = nil
      elseif c then
         refCounts[targetId] = c - 1
      end
   end
   return {
      __index = function(t, container)
         local containerI = container
         local store = RelationshipStore.create({
            sparse = containerI.isSparse,
            reverseIndex = containerI.reverseIndex,
            exclusive = container.exclusiveRelationship,
            onTargetAdded = onAdded,
            onTargetRemoved = onRemoved,
         })
         if store then
            rawset(t, container, store)



            world._hasRelationshipStores = true
         end
         return store
      end,
   }
end

function WorldImpl.new(config)
   config = config or {}
   local dirtyArchetypes = {}
   local allocator = IdAllocator.new(config.maxEntities)
   local archetypeIndex = ArchetypeIndex.new(dirtyArchetypes)
   local maxSlotCount = allocator.maxSlotCount

   local instance = setmetatable({
      resources = Context.new(),
      messages = events.MessageBus.new(),
      _ffiSliceId = GLOBAL_FFI_EVENTS:acquireSlice(),
      _eventPool = pool.newTablePool({ clearOn = "acquire", maxSize = 32 }),
      allocator = allocator,
      _slots = allocator.slots,
      archetypeIndex = archetypeIndex,
      _targetRefCounts = {},
      _hasRelationshipStores = false,
      relationshipStores = nil,
      _bundles = {},
      _dirtyArchetypes = dirtyArchetypes,
      _stateStack = {},
      _stateComponents = {},
      _statePolicies = {},
      _keyIndex = {},
      _transitionObserver = nil,
      _archetypeSnapshotPool = pool.newTablePool({ clearOn = "release" }),
      _scopeDepth = 0,


      _dirtyEpoch = 1,
      dirtyArchetypeList = {},
      dirtyArchetypeCount = 0,





      _stateArr = C.new(UINT8_ARR_T, maxSlotCount + 1),
      _pendingArchArr = C.new(UINT32_ARR_T, maxSlotCount + 1),
      _slotStamp = C.new(UINT32_ARR_T, maxSlotCount + 1),
      _transactionEpoch = 1,
      _maxSlotCount = maxSlotCount,
      entityStateCount = 0,
      sparseSets = {},
      sparseSetCount = 0,
      _swapRemoveQueue = {},
      batchMutations = {},
      batchMutationCount = 0,
      _valsPool = {},
      _valsPoolSize = 0,
      _valsPoolNext = 1,
      _sparseArraysPool = pool.newTablePool({ clearOn = "release" }),
      _exclusivePool = pool.newTablePool({ clearOn = "acquire" }),
      isDirty = false,
      emptyArchetype = archetypeIndex.emptyArchetype,
   }, WORLD_MT)

   instance.relationshipStores = setmetatable({}, makeRelationshipStoresMT(instance))


   archetypeIndex.relationshipStoreGetter = function(c)
      return instance.relationshipStores[c]
   end


   config.pipelineFactory = config.pipelineFactory or pipeline.new
   instance.pipeline = config.pipelineFactory(config.timestep)


   instance.archetypeIndex.onNewArchetype = function(archetype)
      (instance):emit(0, builtins.ArchetypeCreated(archetype))
   end


   builtins.plugin(instance)
   return instance
end





function WorldImpl:addPlugin(plugin)
   plugin(self)
end





function WorldImpl:get(id, component)
   local slot = id % 2 ^ 22
   local s = self._slots[slot]
   if (id - slot) / 2 ^ 22 ~= s.generation then
      return nil
   end
   local archetype = self.archetypeIndex[s.archetypeId]
   if archetype then


      local column = rawget(archetype, component)
      if column == nil then
         column = rawget(archetype.columns, component)
      end
      if column then
         return column[s.row + 1]
      elseif (component).isSparseInstance then
         return self.relationshipStores[component.relationshipType]:getTarget(id, component.target)
      end
   end
end

function WorldImpl:getMut(id, component)
   local slot = id % 2 ^ 22
   local s = self._slots[slot]
   if (id - slot) / 2 ^ 22 ~= s.generation then
      return nil
   end
   local archetype = self.archetypeIndex[s.archetypeId]
   if archetype then
      local column = rawget(archetype, component)
      if column == nil then
         column = rawget(archetype.columns, component)
      end
      if column then
         archetype:markComponentDirty(component)
         return column[s.row + 1]
      elseif (component).isSparseInstance then
         return self.relationshipStores[component.relationshipType]:getTarget(id, component.target)
      end
   end
end

function WorldImpl:has(id, component)
   local slot = id % 2 ^ 22
   local s = self._slots[slot]
   if (id - slot) / 2 ^ 22 ~= s.generation then
      return false
   end
   local archetype = self.archetypeIndex[s.archetypeId]
   if not archetype then return false end
   return rawget(archetype.columns, component) ~= nil or
   rawget(archetype, component) ~= nil or
   ((component).isSparseInstance ~= nil and
   self.relationshipStores[component.relationshipType]:getTarget(id, component.target) ~= nil)
end

function WorldImpl:getFirstRelationship(id, relationship)
   local slot = id % 2 ^ 22
   local s = self._slots[slot]
   if (id - slot) / 2 ^ 22 ~= s.generation then
      return nil
   end
   if (relationship).isSparse then
      return self.relationshipStores[relationship]:getFirst(id)
   else
      local archetype = self.archetypeIndex[s.archetypeId]
      if archetype then
         return archetype:getFirstRelationship(relationship, s.row + 1)
      end
   end
end





local function validateKey(key)
   if key == nil or key == "" then
      error("Key must be a non-empty string")
   end
end

function WorldImpl:byKey(key)
   return self._keyIndex[key]
end

function WorldImpl:requireKey(key)
   local id = self._keyIndex[key]
   if id == nil then
      error("No entity with Key '" .. tostring(key) .. "'")
   end
   return id
end

function WorldImpl:_claimKey(id, key)
   validateKey(key)
   local current = self._keyIndex[key]
   if current ~= nil and current ~= id then
      error("Key '" .. key .. "' is already claimed by entity " .. tostring(current))
   end

   local old = self:oldValueOf(id, builtins.Key)
   if old ~= nil and old ~= key then
      self._keyIndex[old] = nil
   end
   self._keyIndex[key] = id
end

function WorldImpl:_releaseKeyForEntity(id)
   local old = self:oldValueOf(id, builtins.Key)
   if old ~= nil and self._keyIndex[old] == id then
      self._keyIndex[old] = nil
   end
end

function WorldImpl:set(id, component, value)

   local componentType = component.componentType

   if value == nil then
      if (componentType).storageType == "scalar" then




         if component == componentType then
            value = (component).scalarDefault
         else
            value = (component).value
         end
      else
         value = component
      end
   end

   if self._scopeDepth > 0 then
      self:_deferSet(id, componentType, value)
   else
      self:_instantSet(id, componentType, value)
   end
end

function WorldImpl:remove(id, component)
   if self._scopeDepth > 0 then
      self:_deferRemove(id, component)
   else
      self:_instantRemove(id, component)
   end
end

function WorldImpl:markComponentDirty(id, component)
   local slot = id % 2 ^ 22
   if slot < 1 or slot > self._maxSlotCount then return end
   local s = self._slots[slot]
   if (id - slot) / 2 ^ 22 ~= s.generation then
      return
   end
   local archetype = self.archetypeIndex[s.archetypeId]
   if archetype then
      archetype:markComponentDirty(component)
   end
end





function WorldImpl:setRaw(id, componentType, value)
   if self._scopeDepth > 0 then
      self:deferSetRaw(id, componentType, value)
   else
      self:instantSetRaw(id, componentType, value)
   end
end

function WorldImpl:removeRaw(id, component)
   if self._scopeDepth > 0 then
      self:deferRemoveRaw(id, component)
   else
      self:instantRemoveRaw(id, component)
   end
end





function WorldImpl:oldValueOf(id, component)
   local slot = id % 2 ^ 22
   local s = self._slots[slot]
   local srcArch = self.archetypeIndex[s.archetypeId]
   return self:findOldValue(slot, component, srcArch, s.row)
end





function WorldImpl:currentArchetype(id)
   local slot = id % 2 ^ 22


   if (self._slotStamp)[slot] == self._transactionEpoch then
      local pid = (self._pendingArchArr)[slot]
      if pid ~= 0 then return self.archetypeIndex[pid] end
   end
   local s = self._slots[slot]
   return self.archetypeIndex[s.archetypeId]
end





function WorldImpl:spawn(...)
   if self._scopeDepth > 0 then
      return self:_deferSpawn(...)
   end





   if not self:hasObservers(0, builtins.OnSpawn) then
      local ok, id = self:_instantSpawn(...)
      if ok then return id end
   end
   self._scopeDepth = 1
   local sid = self:_deferSpawn(...)
   self:_drain()
   self._scopeDepth = 0
   return sid
end





function WorldImpl:spawnAt(id, ...)
   if self._scopeDepth > 0 then
      self:_deferSpawnAt(id, ...)
      return
   end

   self._scopeDepth = 1
   self:_deferSpawnAt(id, ...)
   self:_drain()
   self._scopeDepth = 0
end

function WorldImpl:forEachArchetype(callback)
   local index = self.archetypeIndex

   for i = 1, index.maxId do
      local arch = index[i]
      if arch then callback(arch) end
   end
end

function WorldImpl:dirtyArchetypes()
   local set = self._dirtyArchetypes
   local nextFn, t = pairs(set)
   local key = nil
   return function()
      local k, _ = nextFn(t, key)
      key = k
      return k
   end
end

local function hasKeyBatch(componentTypes)
   local Key = builtins.Key
   for i = 1, #componentTypes do
      if componentTypes[i] == Key then
         return true
      end
   end
   return false
end

local function assertNoKeyBatch(componentTypes, op)
   if hasKeyBatch(componentTypes) then
      error(op .. " does not support Key because keys must be claimed per entity. " ..
      "Use world:spawn/world:spawnAt or add Key with world:set per entity.")
   end
end




function WorldImpl:batchSpawn(
   count,
   componentTypes,
   callback)

   assertNoKeyBatch(componentTypes, "batchSpawn")
   if self._scopeDepth > 0 then
      return self:_deferBatchSpawn(count, componentTypes, callback)
   end
   self._scopeDepth = 1
   local firstId, ids = self:_deferBatchSpawn(count, componentTypes, callback)
   self:_drain()
   self._scopeDepth = 0
   return firstId, ids
end

function WorldImpl:batchSpawnAt(
   ids,
   componentTypes,
   callback)

   assertNoKeyBatch(componentTypes, "batchSpawnAt")
   if self._scopeDepth > 0 then
      self:_deferBatchSpawnAt(ids, componentTypes, callback)
      return
   end
   self._scopeDepth = 1
   self:_deferBatchSpawnAt(ids, componentTypes, callback)
   self:_drain()
   self._scopeDepth = 0
end

function WorldImpl:batchSpawnAtRaw(
   ids,
   count,
   componentTypes,
   callback)

   local hasKey = hasKeyBatch(componentTypes)
   if self._scopeDepth > 0 then
      if hasKey then
         error("batchSpawnAtRaw with Key is only supported as a self-draining snapshot load operation")
      end
      self:_deferBatchSpawnAtRaw(ids, count, componentTypes, callback)
      return
   end
   self._scopeDepth = 1
   self:_deferBatchSpawnAtRaw(ids, count, componentTypes, callback)
   self:_drain()
   self._scopeDepth = 0
   if hasKey then
      self:_rebuildKeyIndex()
   end
end

function WorldImpl:despawn(id)
   if self._scopeDepth > 0 then
      self:_deferDespawn(id)
   elseif not self:_instantDespawn(id) then
      self._scopeDepth = 1
      self:_deferDespawn(id)
      self:_drain()
      self._scopeDepth = 0
   end
end




local function archetypesOf(world, query)
   local items = (query)._activeItems
   if not items then
      error("batch op requires a Query object (built via world:query(...)). " ..
      "Build the query once outside your hot loop and reuse it.")
   end
   local src = items



   local snapshot = world._archetypeSnapshotPool:acquire()
   local n = 0
   for i = 1, #src do
      local arch = src[i]
      if arch then
         n = n + 1
         snapshot[n] = arch
      end
   end
   return snapshot
end


function WorldImpl:batchDespawn(query)
   local targetArchetypes = archetypesOf(self, query)
   local inScope = self._scopeDepth > 0
   if not inScope then self._scopeDepth = 1 end
   self:_deferBatchDespawn(targetArchetypes)
   if not inScope then
      self:_drain()
      self._scopeDepth = 0
   end

   self._archetypeSnapshotPool:release(targetArchetypes)
end




function WorldImpl:batchSet(query, componentOrInstance, callback)
   local targetArchetypes = archetypesOf(self, query)








   local asAny = componentOrInstance
   local componentType = asAny.componentType
   local isContainer = componentType == componentOrInstance
   if not componentType then
      error("batchSet: second argument must be a component (container or instance with " ..
      "a `componentType` field)")
   end

   local inScope = self._scopeDepth > 0
   if not inScope then self._scopeDepth = 1 end
   if callback then

      if not isContainer then
         error("batchSet callback form requires the component type (container), not an " ..
         "instance. Pass `MyComponent` rather than `MyComponent(...)`.")
      end
      self:_deferBatchSetCallback(targetArchetypes, componentOrInstance, callback)
   else

      self:_deferBatchSet(targetArchetypes, componentType, componentOrInstance)
   end
   if not inScope then
      self:_drain()
      self._scopeDepth = 0
   end
end

function WorldImpl:batchRemove(query, componentType)
   local targetArchetypes = archetypesOf(self, query)
   local inScope = self._scopeDepth > 0
   if not inScope then self._scopeDepth = 1 end
   self:_deferBatchRemove(targetArchetypes, componentType)
   if not inScope then
      self:_drain()
      self._scopeDepth = 0
   end
end

function WorldImpl:clearEntities()
   local observer = self._transitionObserver
   if observer then
      local archetypeIndex = self.archetypeIndex
      for i = 1, archetypeIndex.maxId do
         local arch = archetypeIndex[i]
         if arch then
            local entities = arch.entities
            for row = 1, entities[0] do
               observer.entity(entities[row], arch, nil)
            end
         end
      end
   end



   IdAllocator.reset(self.allocator)
   self:_resetTxn()
   self._scopeDepth = 0

   local archetypeIndex = self.archetypeIndex

   for i = 1, archetypeIndex.maxId do
      local arch = archetypeIndex[i]
      if arch then arch:clearEntities() end
   end

   self.messages:clearEntityObservers()
   if self._ffiSliceId ~= 0 then
      GLOBAL_FFI_EVENTS:clearSlice(self._ffiSliceId)
   end
   self._eventPool:clear()
   table_clear(self._targetRefCounts)
   table_clear(self.relationshipStores)
   table_clear(self._keyIndex)




   local sparsePool = self._sparseArraysPool
   for slot, list in pairs(self.sparseSets) do
      self.sparseSets[slot] = nil
      sparsePool:release(list)
   end
   self.sparseSetCount = 0
   table_clear(self._dirtyArchetypes)
end

function WorldImpl:compact()
   assert(not self.isDirty, "compact requires a committed world")

   local index = self.archetypeIndex
   local pruned = 0
   local compacted = 0



   local slots = self._slots
   local toDestroy = {}
   local destroyedSet = {}
   for i = 2, index.maxId do
      local arch = index[i]
      if arch and arch.isEphemeral and arch.entities[0] == 0 then

         for j = 1, arch.columnsCount do
            local comp = arch.componentList[j]
            local target = comp.target
            if target ~= nil then
               local targetSlot = target % 2 ^ 22
               local s = slots[targetSlot]

               if s.archetypeId == 0 or
                  (target - targetSlot) / 2 ^ 22 ~= s.generation then
                  toDestroy[#toDestroy + 1] = arch
                  destroyedSet[arch] = true
                  break
               end
            end
         end
      end
   end


   if #toDestroy > 0 then
      for i = 1, #toDestroy do
         index:destroy(toDestroy[i])
      end
      pruned = #toDestroy


      for i = 1, index.maxId do
         local arch = index[i]
         if arch then
            local plans = (arch).movePlansOut

            if plans then
               for target in pairs(plans) do
                  if destroyedSet[target] then
                     plans[target] = nil
                  end
               end
            end
         end
      end


      if destroyedSet[self.lastArch] then
         self.lastArch = nil
         self.lastCompType = nil
         self.lastColumn = nil
      end
   end


   for i = 1, index.maxId do
      local arch = index[i]
      if arch and arch.capacity > 0 then
         local before = arch.capacity
         arch:compact()
         if arch.capacity < before then
            compacted = compacted + 1
         end
      end
   end

   return pruned, compacted
end

function WorldImpl:isAlive(id)
   local slot = id % 2 ^ 22
   local s = self._slots[slot]
   if s.archetypeId == 0 then return false end



   return (id - slot) / 2 ^ 22 == s.generation
end









local function snapshotStateArchetypes(
   self,
   component)

   local archs = {}
   local lens = {}
   for archetype, len in self:findArchetypes(component) do
      archs[#archs + 1] = archetype
      lens[#lens + 1] = len
   end
   return archs, lens
end

local ACTIONS = {
   pause = function(self, stateComponent)
      local Paused = builtins.Paused
      local archs, lens = snapshotStateArchetypes(self, stateComponent)
      for k = 1, #archs do
         local archetype = archs[k]
         if not archetype.columns[Paused] then
            local entities = archetype.entities
            for i = 1, lens[k] do
               self:set(entities[i], Paused)
            end
         end
      end
   end,
   resume = function(self, stateComponent)
      local Paused = builtins.Paused
      local archs, lens = snapshotStateArchetypes(self, stateComponent)
      for k = 1, #archs do
         local archetype = archs[k]
         if archetype.columns[Paused] then
            local entities = archetype.entities
            for i = 1, lens[k] do
               self:remove(entities[i], Paused)
            end
         end
      end
   end,
   despawn = function(self, stateComponent)
      local archs, lens = snapshotStateArchetypes(self, stateComponent)
      for k = 1, #archs do
         local entities = archs[k].entities
         for i = 1, lens[k] do
            self:despawn(entities[i])
         end
      end
   end,
   disable = function(self, stateComponent)
      local Disabled = builtins.Disabled
      local archs, lens = snapshotStateArchetypes(self, stateComponent)
      for k = 1, #archs do
         local archetype = archs[k]
         if not archetype.columns[Disabled] then
            local entities = archetype.entities
            for i = 1, lens[k] do
               self:set(entities[i], Disabled)
            end
         end
      end
   end,
}


local function executeAction(self, actionStr, stateComponent)
   local actionFunc = ACTIONS[actionStr]
   if not actionFunc then
      error("Unknown state policy action: " .. actionStr)
   end
   actionFunc(self, stateComponent)
end

local function executePolicy(self, action, stateName)
   if not action then
      return
   end

   self:defer()
   local stateComponent = self._stateComponents[stateName]


   if type(action) == "string" then
      if stateComponent then
         executeAction(self, action, stateComponent)
      end
   elseif type(action) == "function" then
      action(self)
   else

      local policyAction = action
      if policyAction.apply and stateComponent then
         executeAction(self, policyAction.apply, stateComponent)
      end
      if policyAction.call then
         policyAction.call(self)
      end
   end

   self:commit()
end

function WorldImpl:createState(name, policy)
   if self._stateComponents[name] then
      error("State '" .. name .. "' already exists")
   end


   local componentName = name .. "State"
   local stateComponent = components.registeredComponents[componentName]
   if not stateComponent then
      stateComponent = components.newTagComponent({ name = componentName })
   end
   self._stateComponents[name] = stateComponent

   policy = policy or {}
   if not policy.onExit then
      policy.onExit = "despawn"
   end

   self._statePolicies[name] = policy
   return stateComponent
end

function WorldImpl:pushState(name)
   local stateComponent = self._stateComponents[name]
   if not stateComponent then
      error("State '" .. name .. "' not found. Call createState('" .. name .. "') first.")
   end

   local stack = self._stateStack
   local before = stack[#stack]


   if #stack > 0 then
      local currentTop = stack[#stack]
      local currentPolicy = self._statePolicies[currentTop]
      if currentPolicy and currentPolicy.onBlur then
         executePolicy(self, currentPolicy.onBlur, currentTop)
      end
      self:emit(0, builtins.StateBlur(currentTop, name))
   end


   stack[#stack + 1] = name
   self.autoStateComponent = stateComponent


   local policy = self._statePolicies[name]
   if policy and policy.onEnter then
      executePolicy(self, policy.onEnter, name)
   end
   self:emit(0, builtins.StateEnter(name))
   local observer = self._transitionObserver
   if observer then observer.state("push", before, name, name) end
end

function WorldImpl:popState()
   local stack = self._stateStack
   if #stack == 0 then
      error("Cannot pop state: state stack is empty")
   end

   local poppedName = stack[#stack]


   local policy = self._statePolicies[poppedName]
   if policy and policy.onExit then
      executePolicy(self, policy.onExit, poppedName)
   end
   self:emit(0, builtins.StateExit(poppedName))


   stack[#stack] = nil


   if #stack > 0 then
      local newTop = stack[#stack]
      self.autoStateComponent = self._stateComponents[newTop]
      local newTopPolicy = self._statePolicies[newTop]
      if newTopPolicy and newTopPolicy.onFocus then
         executePolicy(self, newTopPolicy.onFocus, newTop)
      end
      self:emit(0, builtins.StateFocus(newTop, poppedName))
   else
      self.autoStateComponent = nil
   end
   local observer = self._transitionObserver
   if observer then observer.state("pop", poppedName, stack[#stack], poppedName) end
end

function WorldImpl:peekState()
   local stack = self._stateStack
   return stack[#stack]
end





function WorldImpl:targets(id, relationship, callback, context)
   local store = self.relationshipStores[relationship]
   if not store then
      error("targets() requires a relationship with reverseIndex = true, but given " .. relationship.componentName)
   end
   store:forEachSource(id, callback, context)
end

function WorldImpl:walkUp(
   id,
   relationship,
   callback,
   context,
   maxDepth)

   local cap = (maxDepth or 100)
   local current = id
   for depth = 1, cap do
      local rel = self:getFirstRelationship(current, relationship)
      if not rel then return end
      current = rel.target
      if callback(current, depth, context) == false then
         return
      end
   end
   error(string.format(
   "world:walkUp exceeded maxDepth %d from id %d via %s (likely a cycle)",
   cap, id, tostring(relationship.componentName)))

end

function WorldImpl:traverse(root, relationship)
   local store = self.relationshipStores[relationship]
   if not store then
      error("traverse() requires a relationship with reverseIndex = true, but given " .. relationship.componentName)
   end


   local dfsStack = {}



   local function seedCollector(child, stack)
      local s = stack
      s[#s + 1] = { child, 0 }
   end
   local pendingChildren = {}
   local function childCollector(child, buf)
      local b = buf
      b[#b + 1] = child
   end

   store:forEachSource(root, seedCollector, dfsStack)

   return function()
      while #dfsStack > 0 do
         local top = dfsStack[#dfsStack]
         dfsStack[#dfsStack] = nil
         local entityId = top[1]
         local depth = top[2]

         for i = #pendingChildren, 1, -1 do pendingChildren[i] = nil end
         store:forEachSource(entityId, childCollector, pendingChildren)
         for i = #pendingChildren, 1, -1 do
            dfsStack[#dfsStack + 1] = { pendingChildren[i], depth + 1 }
         end
         return depth, entityId
      end
      return nil, nil
   end
end





function WorldImpl:addSystem(config)
   self.pipeline:addSystem(assert(config, "Missing system config"))
end

function WorldImpl:removeSystem(systemName)
   self.pipeline:removeSystem(systemName)
end





local function hasComponentInList(componentList, target)
   if componentList then
      for i = 1, #componentList do
         if componentList[i] == target then
            return true
         end
      end
   end
   return false
end

local function autoExcludeComponent(descriptor, component)
   if hasComponentInList(descriptor.include, component) then

   elseif not descriptor.exclude then
      descriptor.exclude = { component }
   elseif not hasComponentInList(descriptor.exclude, component) then
      descriptor.exclude[#descriptor.exclude + 1] = component
   end
end

function WorldImpl:query(descriptor)

   autoExcludeComponent(descriptor, builtins.Disabled)


   local kind = descriptor.type
   if kind == "logic" then
      autoExcludeComponent(descriptor, builtins.Paused)
   elseif kind ~= nil and kind ~= "render" then
      error("query type must be \"logic\" or \"render\", got: " .. tostring(kind))
   end

   local masks = QueryImpl.compileMasks(descriptor.include, descriptor.includeAny, descriptor.exclude)
   local matchingArchetypes = self.archetypeIndex:findMatching(descriptor.include, masks)
   return QueryImpl.new(descriptor, matchingArchetypes, masks, self)
end

local NO_ENTITY_FUNCTION = function()
   return nil, 0, nil
end

function WorldImpl:findArchetypes(component)
   local archetypes = self.archetypeIndex:getArchetypesWithComponent(component)
   if archetypes then
      local key = next(archetypes)
      if key then
         return function()
            local archetype = key
            if archetype then
               key = next(archetypes, key)
               local entities = archetype.entities
               return archetype, entities[0], entities
            end
            return nil, 0, nil
         end
      end
   end
   return NO_ENTITY_FUNCTION
end








function WorldImpl:observe(address, eventType, observer, id)
   local slot = address % 2 ^ 22
   self.messages:observe(slot, eventType, observer, id)
end

function WorldImpl:stopObserving(address, eventType, observer)
   self.messages:stopObserving(address % 2 ^ 22, eventType, observer)
end

function WorldImpl:hasObservers(address, eventType)
   return self.messages:hasObservers(address % 2 ^ 22, eventType)
end

function WorldImpl:emit(address, eventOrType, ...)
   local slot = address % 2 ^ 22
   local messages = self.messages


   if type(eventOrType) == "table" and rawget(eventOrType, "init") ~= nil then

      if not messages:hasObservers(slot, eventOrType) then
         return
      end

      if eventOrType.__tecs_ffi then
         local ffiEvent = GLOBAL_FFI_EVENTS:vendEvent(self._ffiSliceId, eventOrType)
         ffiEvent.eventId = eventOrType.eventId
         ffiEvent.typeId = eventOrType.__tecs_ffi_typeId;
         (eventOrType.init)(ffiEvent, ...)
         messages:emit(slot, ffiEvent)
      else
         local eventId = eventOrType.eventId
         local pooled = self._eventPool:acquire()
         local eventTable = pooled
         eventTable.eventId = eventId
         setmetatable(eventTable, eventOrType.__tecs_mt);
         (eventOrType.init)(eventTable, ...)
         messages:emit(slot, eventTable)
         self._eventPool:release(eventTable)
      end
   else
      messages:emit(slot, eventOrType)
   end
end

function WorldImpl:clearObservers(address)
   self.messages:clearAddress(address % 2 ^ 22)
end

function WorldImpl:addSnapshotHandler(handler)
   if handler.name == nil or handler.name == "" then
      error("snapshot handler requires a non-empty name", 2)
   end

   local key = handler.name
   local save = handler.save
   if save then
      self:observe(0, builtins.OnSnapshotSave, function(ev)
         local value = save(self)
         if value ~= nil then
            ev:addData(key, value)
         end
      end)
   end

   local loadHandler = handler.load
   if loadHandler then
      local loadFn = loadHandler
      self:observe(0, builtins.StartSnapshotLoad, function(ev)
         ev:onData(key, function(value)
            loadFn(self, value)
         end)
      end)
   end

   local finish = handler.finish
   if finish then
      local finishFn = finish
      self:observe(0, builtins.FinishSnapshotLoad, function(ev)
         finishFn(self, ev.prelude)
      end)
   end
end






function WorldImpl:_pushQueryScope()
   self._scopeDepth = self._scopeDepth + 1
end


function WorldImpl:_popQueryScope()
   local depth = self._scopeDepth - 1
   self._scopeDepth = depth
   if depth == 0 and self.isDirty then self:_drain() end
end

function WorldImpl:defer()
   self._scopeDepth = self._scopeDepth + 1
end

function WorldImpl:commit()
   if self._scopeDepth > 0 then
      self._scopeDepth = self._scopeDepth - 1
   end
   if self._scopeDepth == 0 and self.isDirty then self:_drain() end
end

function WorldImpl:update(dt)
   self:commit()
   if self._ffiSliceId ~= 0 then
      GLOBAL_FFI_EVENTS:clearSlice(self._ffiSliceId)
   end
   self.pipeline:update(dt, self)




   for archetype in pairs(self._dirtyArchetypes) do
      archetype:clearDirtyComponents()
   end
   table_clear(self._dirtyArchetypes)
end

function WorldImpl:getFixedTiming()
   local timestep = self.pipeline.fixedTimestep
   local accumulator = self.pipeline.fixedAccumulator
   local alpha = accumulator / timestep
   if alpha < 0 then
      alpha = 0
   elseif alpha > 1 then
      alpha = 1
   end
   return timestep, accumulator, alpha
end

function WorldImpl:enablePhase(phase)
   self.pipeline:enablePhase(phase)
end

function WorldImpl:disablePhase(phase)
   self.pipeline:disablePhase(phase)
end

function WorldImpl:registerPhase(phase)
   self.pipeline:registerPhase(phase)
end

function WorldImpl:startup()
   self.pipeline:run(phases.StartupGroup, 0, self)
end

function WorldImpl:shutdown()
   self.pipeline:run(phases.ShutdownGroup, 0, self)
   local sliceId = self._ffiSliceId
   if sliceId ~= 0 then
      GLOBAL_FFI_EVENTS:releaseSlice(sliceId)
      self._ffiSliceId = 0
   end
end

function WorldImpl:runPhase(phase, dt)
   self.pipeline:run(phase, dt or 0, self)
end





function WorldImpl:newBundle(name, def)
   return bundleModule.create(self, name, def)
end

function WorldImpl:spawnBundle(name, ...)
   local bndl = self._bundles[name]
   if not bndl then
      error("Unknown bundle: " .. name)
   end
   return bndl:spawn(...)
end

function WorldImpl:getBundles()
   local result = {}
   for name, bndl in pairs(self._bundles) do
      result[name] = bndl
   end
   return result
end

function WorldImpl:getBundle(name)
   return self._bundles[name]
end





function WorldImpl:getStats(fill)
   fill = fill or {}



   local actualEntityCount = 0
   local archetypeCount = 0
   local componentTypes = {}

   local index = self.archetypeIndex
   for i = 1, index.maxId do
      local archetype = index[i]
      if archetype then
         archetypeCount = archetypeCount + 1
         actualEntityCount = actualEntityCount + archetype.entities[0]
         for component in pairs(archetype.columns) do
            componentTypes[component] = true
         end
      end
   end

   local componentCount = 0
   for _ in pairs(componentTypes) do
      componentCount = componentCount + 1
   end

   fill.entities = actualEntityCount
   fill.archetypes = archetypeCount
   fill.components = componentCount
   fill.systems = self.pipeline.count
   return fill
end

function WorldImpl:saveSnapshot(opts)
   return snapshotModule.saveSnapshot(self, opts)
end

function WorldImpl:loadSnapshot(source)
   local prelude = snapshotModule.loadSnapshot(self, source)
   self:_rebuildKeyIndex()
   return prelude
end

function WorldImpl:_rebuildKeyIndex()
   local nextIndex = {}
   local Key = builtins.Key
   self:forEachArchetype(function(arch)
      local col = arch.columns[Key]
      if col then
         local entities = arch.entities
         for row = 1, entities[0] do
            local key = col[row]
            validateKey(key)
            local owner = nextIndex[key]
            if owner ~= nil and owner ~= entities[row] then
               error("Key '" .. key .. "' is already claimed by entity " .. tostring(owner))
            end
            nextIndex[key] = entities[row]
         end
      end
   end)
   table_clear(self._keyIndex)
   for key, id in pairs(nextIndex) do
      self._keyIndex[key] = id
   end
end


require("tecs.internal.world.shared")
require("tecs.internal.world.instant")
require("tecs.internal.world.deferred")
require("tecs.internal.world.batch")
require("tecs.internal.world.drain")
require("tecs.internal.world.sparse")
require("tecs.internal.world.validate")

return WorldImpl
