




local types = require("tecs.types")
local internal = require("tecs.internal.types")
local IdAllocator = require("tecs.internal.IdAllocator")
local builtins = require("tecs.internal.builtins")
local behavior = require("tecs.internal.behavior")
local table_clear = require("table.clear")
local shared = require("tecs.internal.world.shared")






local WorldImpl = internal.WorldImpl

local STATE_SPAWN = shared.STATE_SPAWN
local STATE_MUTATE = shared.STATE_MUTATE
local STATE_DESPAWN = shared.STATE_DESPAWN

local getRequiresClosure = shared.getRequiresClosure
local applyRequires = shared.applyRequires
local getEntityState = shared.getEntityState
local setEntityState = shared.setEntityState
local getPendingArch = shared.getPendingArch
local setPendingArch = shared.setPendingArch

local OnSpawn = builtins.OnSpawn
local OnDespawn = builtins.OnDespawn
local Key = builtins.Key

local pairs = pairs
local select = select

































































































































































local function borrowVals(self)
   local n = self._valsPoolNext
   self._valsPoolNext = n + 1
   local t
   if n <= self._valsPoolSize then
      t = self._valsPool[n]
      table_clear(t)
   else
      t = {}
      self._valsPool[n] = t
      self._valsPoolSize = n
   end
   return t
end

local function appendPendingValue(self, arch, slot, value)
   local vals = arch:getPendingValues(slot)
   if vals then
      vals[#vals + 1] = value
   else
      arch:appendPendingValue(slot, value, borrowVals(self))
   end
end



local function stageScalar(
   self,
   arch,
   slot,
   componentType,
   value)

   local ctList = arch.pendingScalarTypes[slot]
   local values
   if ctList then
      values = arch.pendingScalarValues[slot]
   else
      ctList = borrowVals(self)
      values = borrowVals(self)
      arch.pendingScalarTypes[slot] = ctList
      arch.pendingScalarValues[slot] = values
      arch.hasScalarPending = true
   end
   local n = #ctList + 1
   ctList[n] = componentType
   values[n] = value
end





local function stageRequiredDefaults(
   self,
   missing,
   stagingArch,
   slot)

   for i = 1, #missing do
      local entry = missing[i]
      local rType = entry.type
      local v = entry.sharedValue
      if v == nil then
         v = (entry.factory)()
      end
      if (rType).storageType == "scalar" then
         stageScalar(self, stagingArch, slot, rType, (v).value)
      elseif entry.writeColumn then
         appendPendingValue(self, stagingArch, slot, v)
      end
   end
end





local function migratePending(src, dst, slot)
   src:movePendingValuesTo(dst, slot)
   if not src.hasScalarPending then return end
   local ctList = src.pendingScalarTypes[slot]
   if ctList then
      local values = src.pendingScalarValues[slot]
      src.pendingScalarTypes[slot] = nil
      src.pendingScalarValues[slot] = nil
      dst.pendingScalarTypes[slot] = ctList
      dst.pendingScalarValues[slot] = values
      dst.hasScalarPending = true
   end
end










































































local function deferSpawn1(self, slot, id, c1)
   local world = self; local archetypeIndex = self.archetypeIndex; setEntityState(self, slot, STATE_SPAWN); self.entityStateCount = self.entityStateCount + 1; self.isDirty = true; local arch = self.emptyArchetype; local vals = borrowVals(self); local valCount = 0; local pendingKey; local scalarTypes; local scalarValues; local scalarCount = 0; local exclusiveByContainer = nil
   do local comp = c1; local ct = comp.componentType; local relType = ct.relationshipType; if relType and relType.isSparse then if (comp).target ~= nil then self:setSparseRaw(id, comp) end; ct = relType; comp = relType end; if ct == Key then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; local container = ct.wildcardContainer; if container and (ct).exclusiveRelationship then exclusiveByContainer = exclusiveByContainer or (self._exclusivePool:acquire()); local priorIdx = exclusiveByContainer[container]; if priorIdx then local priorComp = vals[priorIdx]; local priorCt = priorComp.componentType; if priorCt ~= ct then if priorIdx ~= valCount then vals[priorIdx] = vals[valCount]; local movedCt = (vals[priorIdx]).componentType; local movedContainer = movedCt.wildcardContainer; if movedContainer and (movedCt).exclusiveRelationship and exclusiveByContainer[movedContainer] == valCount then exclusiveByContainer[movedContainer] = priorIdx end end; vals[valCount] = nil; valCount = valCount - 1; arch = arch:withoutComponent(priorCt, archetypeIndex); if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:unlink(id, (priorComp).target) end end end end end; arch = arch:withComponent(ct, archetypeIndex); if ct.storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = ct; scalarValues[scalarCount] = (comp).value else valCount = valCount + 1; vals[valCount] = comp end; if container and (ct).exclusiveRelationship then exclusiveByContainer[container] = valCount end; if container then if arch.columns[container] == nil then arch = arch:withComponent(container, archetypeIndex); valCount = valCount + 1; vals[valCount] = container end; if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:link(id, comp.target) end end end; local cti = ct; if cti._hasRequires then local closure = getRequiresClosure(cti); for j = 1, #closure do local entry = closure[j]; local rType = entry.type; if arch.columns[rType] == nil then arch = arch:withComponent(rType, archetypeIndex); local v = entry.sharedValue; if v == nil then v = (entry.factory)() end; if (rType).storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = rType; scalarValues[scalarCount] = (v).value else valCount = valCount + 1; vals[valCount] = v end end end end end
   local autoState = self.autoStateComponent; if autoState then arch = arch:withComponent(autoState, archetypeIndex); valCount = valCount + 1; vals[valCount] = autoState end; if pendingKey ~= nil then self:_claimKey(id, pendingKey) end; setPendingArch(self, slot, arch); for i = 1, valCount do appendPendingValue(self, arch, slot, vals[i]) end; for i = 1, scalarCount do stageScalar(self, arch, slot, scalarTypes[i], scalarValues[i]) end; local c = arch.pendingSpawnCount + 1; arch.pendingSpawnCount = c; (arch.pendingSpawnIds)[c] = id; arch.hasPendingSpawns = true; if arch.dirtyQueuedEpoch ~= self._dirtyEpoch then arch.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = arch; self.dirtyArchetypeCount = __c end; world:emit(0, OnSpawn, id); if exclusiveByContainer then self._exclusivePool:release(exclusiveByContainer) end
end

local function deferSpawn2(self, slot, id, c1, c2)
   local world = self; local archetypeIndex = self.archetypeIndex; setEntityState(self, slot, STATE_SPAWN); self.entityStateCount = self.entityStateCount + 1; self.isDirty = true; local arch = self.emptyArchetype; local vals = borrowVals(self); local valCount = 0; local pendingKey; local scalarTypes; local scalarValues; local scalarCount = 0; local exclusiveByContainer = nil
   do local comp = c1; local ct = comp.componentType; local relType = ct.relationshipType; if relType and relType.isSparse then if (comp).target ~= nil then self:setSparseRaw(id, comp) end; ct = relType; comp = relType end; if ct == Key then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; local container = ct.wildcardContainer; if container and (ct).exclusiveRelationship then exclusiveByContainer = exclusiveByContainer or (self._exclusivePool:acquire()); local priorIdx = exclusiveByContainer[container]; if priorIdx then local priorComp = vals[priorIdx]; local priorCt = priorComp.componentType; if priorCt ~= ct then if priorIdx ~= valCount then vals[priorIdx] = vals[valCount]; local movedCt = (vals[priorIdx]).componentType; local movedContainer = movedCt.wildcardContainer; if movedContainer and (movedCt).exclusiveRelationship and exclusiveByContainer[movedContainer] == valCount then exclusiveByContainer[movedContainer] = priorIdx end end; vals[valCount] = nil; valCount = valCount - 1; arch = arch:withoutComponent(priorCt, archetypeIndex); if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:unlink(id, (priorComp).target) end end end end end; arch = arch:withComponent(ct, archetypeIndex); if ct.storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = ct; scalarValues[scalarCount] = (comp).value else valCount = valCount + 1; vals[valCount] = comp end; if container and (ct).exclusiveRelationship then exclusiveByContainer[container] = valCount end; if container then if arch.columns[container] == nil then arch = arch:withComponent(container, archetypeIndex); valCount = valCount + 1; vals[valCount] = container end; if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:link(id, comp.target) end end end; local cti = ct; if cti._hasRequires then local closure = getRequiresClosure(cti); for j = 1, #closure do local entry = closure[j]; local rType = entry.type; if arch.columns[rType] == nil then arch = arch:withComponent(rType, archetypeIndex); local v = entry.sharedValue; if v == nil then v = (entry.factory)() end; if (rType).storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = rType; scalarValues[scalarCount] = (v).value else valCount = valCount + 1; vals[valCount] = v end end end end end
   do local comp = c2; local ct = comp.componentType; local relType = ct.relationshipType; if relType and relType.isSparse then if (comp).target ~= nil then self:setSparseRaw(id, comp) end; ct = relType; comp = relType end; if ct == Key then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; local container = ct.wildcardContainer; if container and (ct).exclusiveRelationship then exclusiveByContainer = exclusiveByContainer or (self._exclusivePool:acquire()); local priorIdx = exclusiveByContainer[container]; if priorIdx then local priorComp = vals[priorIdx]; local priorCt = priorComp.componentType; if priorCt ~= ct then if priorIdx ~= valCount then vals[priorIdx] = vals[valCount]; local movedCt = (vals[priorIdx]).componentType; local movedContainer = movedCt.wildcardContainer; if movedContainer and (movedCt).exclusiveRelationship and exclusiveByContainer[movedContainer] == valCount then exclusiveByContainer[movedContainer] = priorIdx end end; vals[valCount] = nil; valCount = valCount - 1; arch = arch:withoutComponent(priorCt, archetypeIndex); if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:unlink(id, (priorComp).target) end end end end end; arch = arch:withComponent(ct, archetypeIndex); if ct.storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = ct; scalarValues[scalarCount] = (comp).value else valCount = valCount + 1; vals[valCount] = comp end; if container and (ct).exclusiveRelationship then exclusiveByContainer[container] = valCount end; if container then if arch.columns[container] == nil then arch = arch:withComponent(container, archetypeIndex); valCount = valCount + 1; vals[valCount] = container end; if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:link(id, comp.target) end end end; local cti = ct; if cti._hasRequires then local closure = getRequiresClosure(cti); for j = 1, #closure do local entry = closure[j]; local rType = entry.type; if arch.columns[rType] == nil then arch = arch:withComponent(rType, archetypeIndex); local v = entry.sharedValue; if v == nil then v = (entry.factory)() end; if (rType).storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = rType; scalarValues[scalarCount] = (v).value else valCount = valCount + 1; vals[valCount] = v end end end end end
   local autoState = self.autoStateComponent; if autoState then arch = arch:withComponent(autoState, archetypeIndex); valCount = valCount + 1; vals[valCount] = autoState end; if pendingKey ~= nil then self:_claimKey(id, pendingKey) end; setPendingArch(self, slot, arch); for i = 1, valCount do appendPendingValue(self, arch, slot, vals[i]) end; for i = 1, scalarCount do stageScalar(self, arch, slot, scalarTypes[i], scalarValues[i]) end; local c = arch.pendingSpawnCount + 1; arch.pendingSpawnCount = c; (arch.pendingSpawnIds)[c] = id; arch.hasPendingSpawns = true; if arch.dirtyQueuedEpoch ~= self._dirtyEpoch then arch.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = arch; self.dirtyArchetypeCount = __c end; world:emit(0, OnSpawn, id); if exclusiveByContainer then self._exclusivePool:release(exclusiveByContainer) end
end

local function deferSpawn3(self, slot, id, c1, c2, c3)
   local world = self; local archetypeIndex = self.archetypeIndex; setEntityState(self, slot, STATE_SPAWN); self.entityStateCount = self.entityStateCount + 1; self.isDirty = true; local arch = self.emptyArchetype; local vals = borrowVals(self); local valCount = 0; local pendingKey; local scalarTypes; local scalarValues; local scalarCount = 0; local exclusiveByContainer = nil
   do local comp = c1; local ct = comp.componentType; local relType = ct.relationshipType; if relType and relType.isSparse then if (comp).target ~= nil then self:setSparseRaw(id, comp) end; ct = relType; comp = relType end; if ct == Key then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; local container = ct.wildcardContainer; if container and (ct).exclusiveRelationship then exclusiveByContainer = exclusiveByContainer or (self._exclusivePool:acquire()); local priorIdx = exclusiveByContainer[container]; if priorIdx then local priorComp = vals[priorIdx]; local priorCt = priorComp.componentType; if priorCt ~= ct then if priorIdx ~= valCount then vals[priorIdx] = vals[valCount]; local movedCt = (vals[priorIdx]).componentType; local movedContainer = movedCt.wildcardContainer; if movedContainer and (movedCt).exclusiveRelationship and exclusiveByContainer[movedContainer] == valCount then exclusiveByContainer[movedContainer] = priorIdx end end; vals[valCount] = nil; valCount = valCount - 1; arch = arch:withoutComponent(priorCt, archetypeIndex); if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:unlink(id, (priorComp).target) end end end end end; arch = arch:withComponent(ct, archetypeIndex); if ct.storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = ct; scalarValues[scalarCount] = (comp).value else valCount = valCount + 1; vals[valCount] = comp end; if container and (ct).exclusiveRelationship then exclusiveByContainer[container] = valCount end; if container then if arch.columns[container] == nil then arch = arch:withComponent(container, archetypeIndex); valCount = valCount + 1; vals[valCount] = container end; if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:link(id, comp.target) end end end; local cti = ct; if cti._hasRequires then local closure = getRequiresClosure(cti); for j = 1, #closure do local entry = closure[j]; local rType = entry.type; if arch.columns[rType] == nil then arch = arch:withComponent(rType, archetypeIndex); local v = entry.sharedValue; if v == nil then v = (entry.factory)() end; if (rType).storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = rType; scalarValues[scalarCount] = (v).value else valCount = valCount + 1; vals[valCount] = v end end end end end
   do local comp = c2; local ct = comp.componentType; local relType = ct.relationshipType; if relType and relType.isSparse then if (comp).target ~= nil then self:setSparseRaw(id, comp) end; ct = relType; comp = relType end; if ct == Key then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; local container = ct.wildcardContainer; if container and (ct).exclusiveRelationship then exclusiveByContainer = exclusiveByContainer or (self._exclusivePool:acquire()); local priorIdx = exclusiveByContainer[container]; if priorIdx then local priorComp = vals[priorIdx]; local priorCt = priorComp.componentType; if priorCt ~= ct then if priorIdx ~= valCount then vals[priorIdx] = vals[valCount]; local movedCt = (vals[priorIdx]).componentType; local movedContainer = movedCt.wildcardContainer; if movedContainer and (movedCt).exclusiveRelationship and exclusiveByContainer[movedContainer] == valCount then exclusiveByContainer[movedContainer] = priorIdx end end; vals[valCount] = nil; valCount = valCount - 1; arch = arch:withoutComponent(priorCt, archetypeIndex); if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:unlink(id, (priorComp).target) end end end end end; arch = arch:withComponent(ct, archetypeIndex); if ct.storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = ct; scalarValues[scalarCount] = (comp).value else valCount = valCount + 1; vals[valCount] = comp end; if container and (ct).exclusiveRelationship then exclusiveByContainer[container] = valCount end; if container then if arch.columns[container] == nil then arch = arch:withComponent(container, archetypeIndex); valCount = valCount + 1; vals[valCount] = container end; if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:link(id, comp.target) end end end; local cti = ct; if cti._hasRequires then local closure = getRequiresClosure(cti); for j = 1, #closure do local entry = closure[j]; local rType = entry.type; if arch.columns[rType] == nil then arch = arch:withComponent(rType, archetypeIndex); local v = entry.sharedValue; if v == nil then v = (entry.factory)() end; if (rType).storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = rType; scalarValues[scalarCount] = (v).value else valCount = valCount + 1; vals[valCount] = v end end end end end
   do local comp = c3; local ct = comp.componentType; local relType = ct.relationshipType; if relType and relType.isSparse then if (comp).target ~= nil then self:setSparseRaw(id, comp) end; ct = relType; comp = relType end; if ct == Key then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; local container = ct.wildcardContainer; if container and (ct).exclusiveRelationship then exclusiveByContainer = exclusiveByContainer or (self._exclusivePool:acquire()); local priorIdx = exclusiveByContainer[container]; if priorIdx then local priorComp = vals[priorIdx]; local priorCt = priorComp.componentType; if priorCt ~= ct then if priorIdx ~= valCount then vals[priorIdx] = vals[valCount]; local movedCt = (vals[priorIdx]).componentType; local movedContainer = movedCt.wildcardContainer; if movedContainer and (movedCt).exclusiveRelationship and exclusiveByContainer[movedContainer] == valCount then exclusiveByContainer[movedContainer] = priorIdx end end; vals[valCount] = nil; valCount = valCount - 1; arch = arch:withoutComponent(priorCt, archetypeIndex); if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:unlink(id, (priorComp).target) end end end end end; arch = arch:withComponent(ct, archetypeIndex); if ct.storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = ct; scalarValues[scalarCount] = (comp).value else valCount = valCount + 1; vals[valCount] = comp end; if container and (ct).exclusiveRelationship then exclusiveByContainer[container] = valCount end; if container then if arch.columns[container] == nil then arch = arch:withComponent(container, archetypeIndex); valCount = valCount + 1; vals[valCount] = container end; if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:link(id, comp.target) end end end; local cti = ct; if cti._hasRequires then local closure = getRequiresClosure(cti); for j = 1, #closure do local entry = closure[j]; local rType = entry.type; if arch.columns[rType] == nil then arch = arch:withComponent(rType, archetypeIndex); local v = entry.sharedValue; if v == nil then v = (entry.factory)() end; if (rType).storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = rType; scalarValues[scalarCount] = (v).value else valCount = valCount + 1; vals[valCount] = v end end end end end
   local autoState = self.autoStateComponent; if autoState then arch = arch:withComponent(autoState, archetypeIndex); valCount = valCount + 1; vals[valCount] = autoState end; if pendingKey ~= nil then self:_claimKey(id, pendingKey) end; setPendingArch(self, slot, arch); for i = 1, valCount do appendPendingValue(self, arch, slot, vals[i]) end; for i = 1, scalarCount do stageScalar(self, arch, slot, scalarTypes[i], scalarValues[i]) end; local c = arch.pendingSpawnCount + 1; arch.pendingSpawnCount = c; (arch.pendingSpawnIds)[c] = id; arch.hasPendingSpawns = true; if arch.dirtyQueuedEpoch ~= self._dirtyEpoch then arch.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = arch; self.dirtyArchetypeCount = __c end; world:emit(0, OnSpawn, id); if exclusiveByContainer then self._exclusivePool:release(exclusiveByContainer) end
end

local function deferSpawn4(self, slot, id,
   c1, c2, c3, c4)
   local world = self; local archetypeIndex = self.archetypeIndex; setEntityState(self, slot, STATE_SPAWN); self.entityStateCount = self.entityStateCount + 1; self.isDirty = true; local arch = self.emptyArchetype; local vals = borrowVals(self); local valCount = 0; local pendingKey; local scalarTypes; local scalarValues; local scalarCount = 0; local exclusiveByContainer = nil
   do local comp = c1; local ct = comp.componentType; local relType = ct.relationshipType; if relType and relType.isSparse then if (comp).target ~= nil then self:setSparseRaw(id, comp) end; ct = relType; comp = relType end; if ct == Key then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; local container = ct.wildcardContainer; if container and (ct).exclusiveRelationship then exclusiveByContainer = exclusiveByContainer or (self._exclusivePool:acquire()); local priorIdx = exclusiveByContainer[container]; if priorIdx then local priorComp = vals[priorIdx]; local priorCt = priorComp.componentType; if priorCt ~= ct then if priorIdx ~= valCount then vals[priorIdx] = vals[valCount]; local movedCt = (vals[priorIdx]).componentType; local movedContainer = movedCt.wildcardContainer; if movedContainer and (movedCt).exclusiveRelationship and exclusiveByContainer[movedContainer] == valCount then exclusiveByContainer[movedContainer] = priorIdx end end; vals[valCount] = nil; valCount = valCount - 1; arch = arch:withoutComponent(priorCt, archetypeIndex); if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:unlink(id, (priorComp).target) end end end end end; arch = arch:withComponent(ct, archetypeIndex); if ct.storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = ct; scalarValues[scalarCount] = (comp).value else valCount = valCount + 1; vals[valCount] = comp end; if container and (ct).exclusiveRelationship then exclusiveByContainer[container] = valCount end; if container then if arch.columns[container] == nil then arch = arch:withComponent(container, archetypeIndex); valCount = valCount + 1; vals[valCount] = container end; if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:link(id, comp.target) end end end; local cti = ct; if cti._hasRequires then local closure = getRequiresClosure(cti); for j = 1, #closure do local entry = closure[j]; local rType = entry.type; if arch.columns[rType] == nil then arch = arch:withComponent(rType, archetypeIndex); local v = entry.sharedValue; if v == nil then v = (entry.factory)() end; if (rType).storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = rType; scalarValues[scalarCount] = (v).value else valCount = valCount + 1; vals[valCount] = v end end end end end
   do local comp = c2; local ct = comp.componentType; local relType = ct.relationshipType; if relType and relType.isSparse then if (comp).target ~= nil then self:setSparseRaw(id, comp) end; ct = relType; comp = relType end; if ct == Key then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; local container = ct.wildcardContainer; if container and (ct).exclusiveRelationship then exclusiveByContainer = exclusiveByContainer or (self._exclusivePool:acquire()); local priorIdx = exclusiveByContainer[container]; if priorIdx then local priorComp = vals[priorIdx]; local priorCt = priorComp.componentType; if priorCt ~= ct then if priorIdx ~= valCount then vals[priorIdx] = vals[valCount]; local movedCt = (vals[priorIdx]).componentType; local movedContainer = movedCt.wildcardContainer; if movedContainer and (movedCt).exclusiveRelationship and exclusiveByContainer[movedContainer] == valCount then exclusiveByContainer[movedContainer] = priorIdx end end; vals[valCount] = nil; valCount = valCount - 1; arch = arch:withoutComponent(priorCt, archetypeIndex); if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:unlink(id, (priorComp).target) end end end end end; arch = arch:withComponent(ct, archetypeIndex); if ct.storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = ct; scalarValues[scalarCount] = (comp).value else valCount = valCount + 1; vals[valCount] = comp end; if container and (ct).exclusiveRelationship then exclusiveByContainer[container] = valCount end; if container then if arch.columns[container] == nil then arch = arch:withComponent(container, archetypeIndex); valCount = valCount + 1; vals[valCount] = container end; if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:link(id, comp.target) end end end; local cti = ct; if cti._hasRequires then local closure = getRequiresClosure(cti); for j = 1, #closure do local entry = closure[j]; local rType = entry.type; if arch.columns[rType] == nil then arch = arch:withComponent(rType, archetypeIndex); local v = entry.sharedValue; if v == nil then v = (entry.factory)() end; if (rType).storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = rType; scalarValues[scalarCount] = (v).value else valCount = valCount + 1; vals[valCount] = v end end end end end
   do local comp = c3; local ct = comp.componentType; local relType = ct.relationshipType; if relType and relType.isSparse then if (comp).target ~= nil then self:setSparseRaw(id, comp) end; ct = relType; comp = relType end; if ct == Key then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; local container = ct.wildcardContainer; if container and (ct).exclusiveRelationship then exclusiveByContainer = exclusiveByContainer or (self._exclusivePool:acquire()); local priorIdx = exclusiveByContainer[container]; if priorIdx then local priorComp = vals[priorIdx]; local priorCt = priorComp.componentType; if priorCt ~= ct then if priorIdx ~= valCount then vals[priorIdx] = vals[valCount]; local movedCt = (vals[priorIdx]).componentType; local movedContainer = movedCt.wildcardContainer; if movedContainer and (movedCt).exclusiveRelationship and exclusiveByContainer[movedContainer] == valCount then exclusiveByContainer[movedContainer] = priorIdx end end; vals[valCount] = nil; valCount = valCount - 1; arch = arch:withoutComponent(priorCt, archetypeIndex); if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:unlink(id, (priorComp).target) end end end end end; arch = arch:withComponent(ct, archetypeIndex); if ct.storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = ct; scalarValues[scalarCount] = (comp).value else valCount = valCount + 1; vals[valCount] = comp end; if container and (ct).exclusiveRelationship then exclusiveByContainer[container] = valCount end; if container then if arch.columns[container] == nil then arch = arch:withComponent(container, archetypeIndex); valCount = valCount + 1; vals[valCount] = container end; if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:link(id, comp.target) end end end; local cti = ct; if cti._hasRequires then local closure = getRequiresClosure(cti); for j = 1, #closure do local entry = closure[j]; local rType = entry.type; if arch.columns[rType] == nil then arch = arch:withComponent(rType, archetypeIndex); local v = entry.sharedValue; if v == nil then v = (entry.factory)() end; if (rType).storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = rType; scalarValues[scalarCount] = (v).value else valCount = valCount + 1; vals[valCount] = v end end end end end
   do local comp = c4; local ct = comp.componentType; local relType = ct.relationshipType; if relType and relType.isSparse then if (comp).target ~= nil then self:setSparseRaw(id, comp) end; ct = relType; comp = relType end; if ct == Key then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; local container = ct.wildcardContainer; if container and (ct).exclusiveRelationship then exclusiveByContainer = exclusiveByContainer or (self._exclusivePool:acquire()); local priorIdx = exclusiveByContainer[container]; if priorIdx then local priorComp = vals[priorIdx]; local priorCt = priorComp.componentType; if priorCt ~= ct then if priorIdx ~= valCount then vals[priorIdx] = vals[valCount]; local movedCt = (vals[priorIdx]).componentType; local movedContainer = movedCt.wildcardContainer; if movedContainer and (movedCt).exclusiveRelationship and exclusiveByContainer[movedContainer] == valCount then exclusiveByContainer[movedContainer] = priorIdx end end; vals[valCount] = nil; valCount = valCount - 1; arch = arch:withoutComponent(priorCt, archetypeIndex); if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:unlink(id, (priorComp).target) end end end end end; arch = arch:withComponent(ct, archetypeIndex); if ct.storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = ct; scalarValues[scalarCount] = (comp).value else valCount = valCount + 1; vals[valCount] = comp end; if container and (ct).exclusiveRelationship then exclusiveByContainer[container] = valCount end; if container then if arch.columns[container] == nil then arch = arch:withComponent(container, archetypeIndex); valCount = valCount + 1; vals[valCount] = container end; if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:link(id, comp.target) end end end; local cti = ct; if cti._hasRequires then local closure = getRequiresClosure(cti); for j = 1, #closure do local entry = closure[j]; local rType = entry.type; if arch.columns[rType] == nil then arch = arch:withComponent(rType, archetypeIndex); local v = entry.sharedValue; if v == nil then v = (entry.factory)() end; if (rType).storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = rType; scalarValues[scalarCount] = (v).value else valCount = valCount + 1; vals[valCount] = v end end end end end
   local autoState = self.autoStateComponent; if autoState then arch = arch:withComponent(autoState, archetypeIndex); valCount = valCount + 1; vals[valCount] = autoState end; if pendingKey ~= nil then self:_claimKey(id, pendingKey) end; setPendingArch(self, slot, arch); for i = 1, valCount do appendPendingValue(self, arch, slot, vals[i]) end; for i = 1, scalarCount do stageScalar(self, arch, slot, scalarTypes[i], scalarValues[i]) end; local c = arch.pendingSpawnCount + 1; arch.pendingSpawnCount = c; (arch.pendingSpawnIds)[c] = id; arch.hasPendingSpawns = true; if arch.dirtyQueuedEpoch ~= self._dirtyEpoch then arch.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = arch; self.dirtyArchetypeCount = __c end; world:emit(0, OnSpawn, id); if exclusiveByContainer then self._exclusivePool:release(exclusiveByContainer) end
end




local function deferSpawnN(self, slot, id, ...)
   local n = select("#", ...)
   local world = self; local archetypeIndex = self.archetypeIndex; setEntityState(self, slot, STATE_SPAWN); self.entityStateCount = self.entityStateCount + 1; self.isDirty = true; local arch = self.emptyArchetype; local vals = borrowVals(self); local valCount = 0; local pendingKey; local scalarTypes; local scalarValues; local scalarCount = 0; local exclusiveByContainer = nil
   for i = 1, n do
      do local comp = select(i, ...); local ct = comp.componentType; local relType = ct.relationshipType; if relType and relType.isSparse then if (comp).target ~= nil then self:setSparseRaw(id, comp) end; ct = relType; comp = relType end; if ct == Key then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; local container = ct.wildcardContainer; if container and (ct).exclusiveRelationship then exclusiveByContainer = exclusiveByContainer or (self._exclusivePool:acquire()); local priorIdx = exclusiveByContainer[container]; if priorIdx then local priorComp = vals[priorIdx]; local priorCt = priorComp.componentType; if priorCt ~= ct then if priorIdx ~= valCount then vals[priorIdx] = vals[valCount]; local movedCt = (vals[priorIdx]).componentType; local movedContainer = movedCt.wildcardContainer; if movedContainer and (movedCt).exclusiveRelationship and exclusiveByContainer[movedContainer] == valCount then exclusiveByContainer[movedContainer] = priorIdx end end; vals[valCount] = nil; valCount = valCount - 1; arch = arch:withoutComponent(priorCt, archetypeIndex); if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:unlink(id, (priorComp).target) end end end end end; arch = arch:withComponent(ct, archetypeIndex); if ct.storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = ct; scalarValues[scalarCount] = (comp).value else valCount = valCount + 1; vals[valCount] = comp end; if container and (ct).exclusiveRelationship then exclusiveByContainer[container] = valCount end; if container then if arch.columns[container] == nil then arch = arch:withComponent(container, archetypeIndex); valCount = valCount + 1; vals[valCount] = container end; if (container).reverseIndex then local store = world.relationshipStores[container]; if store then store:link(id, comp.target) end end end; local cti = ct; if cti._hasRequires then local closure = getRequiresClosure(cti); for j = 1, #closure do local entry = closure[j]; local rType = entry.type; if arch.columns[rType] == nil then arch = arch:withComponent(rType, archetypeIndex); local v = entry.sharedValue; if v == nil then v = (entry.factory)() end; if (rType).storageType == "scalar" then if scalarTypes == nil then scalarTypes = borrowVals(self); scalarValues = borrowVals(self) end; scalarCount = scalarCount + 1; scalarTypes[scalarCount] = rType; scalarValues[scalarCount] = (v).value else valCount = valCount + 1; vals[valCount] = v end end end end end
   end
   local autoState = self.autoStateComponent; if autoState then arch = arch:withComponent(autoState, archetypeIndex); valCount = valCount + 1; vals[valCount] = autoState end; if pendingKey ~= nil then self:_claimKey(id, pendingKey) end; setPendingArch(self, slot, arch); for i = 1, valCount do appendPendingValue(self, arch, slot, vals[i]) end; for i = 1, scalarCount do stageScalar(self, arch, slot, scalarTypes[i], scalarValues[i]) end; local c = arch.pendingSpawnCount + 1; arch.pendingSpawnCount = c; (arch.pendingSpawnIds)[c] = id; arch.hasPendingSpawns = true; if arch.dirtyQueuedEpoch ~= self._dirtyEpoch then arch.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = arch; self.dirtyArchetypeCount = __c end; world:emit(0, OnSpawn, id); if exclusiveByContainer then self._exclusivePool:release(exclusiveByContainer) end
end

local function deferSpawn(self, slot, id, ...)
   local n = select("#", ...)
   if n == 1 then
      deferSpawn1(self, slot, id, select(1, ...))
   elseif n == 2 then
      deferSpawn2(self, slot, id, select(1, ...), select(2, ...))
   elseif n == 3 then
      deferSpawn3(self, slot, id, select(1, ...), select(2, ...), select(3, ...))
   elseif n == 4 then
      deferSpawn4(self, slot, id, select(1, ...), select(2, ...), select(3, ...), select(4, ...))
   else
      deferSpawnN(self, slot, id, ...)
   end
end

function WorldImpl:_deferSpawn(...)
   local allocator = self.allocator
   local slot = IdAllocator.allocSlot(allocator)
   local generation = (allocator.slots)[slot].generation
   local id = slot + generation * 2 ^ 22
   deferSpawn(self, slot, id, ...)
   return id
end

function WorldImpl:_deferSpawnAt(id, ...)
   local slot = id % 2 ^ 22
   local generation = (id - slot) / 2 ^ 22
   local allocator = self.allocator

   if slot < 1 or slot > allocator.maxSlotCount then
      error("spawnAt: id " .. tostring(id) .. " decodes to slot " .. tostring(slot) ..
      " which is outside the configured slot range [1, " ..
      tostring(allocator.maxSlotCount) .. "]. Check the encoding " ..
      "(IdAllocator.encodeId: slot + generation * 2^22).")
   end
   if slot >= allocator.nextFreshSlot then
      allocator.nextFreshSlot = slot + 1
   elseif allocator.freeCount > 0 then


      IdAllocator.unfree(allocator, slot)
   end
   (allocator.slots)[slot].generation = generation
   deferSpawn(self, slot, id, ...)
end

function WorldImpl:findOldValue(
   slot,
   componentType,
   sourceArch,
   sourceRow)


   local pendingArch = getPendingArch(self, slot)
   if pendingArch then
      local st = getEntityState(self, slot)
      local stageArch
      if st == STATE_SPAWN then
         stageArch = pendingArch
      else
         stageArch = sourceArch
      end
      if stageArch then
         if (componentType).storageType == "scalar" then
            local ctList = stageArch.pendingScalarTypes[slot]
            if ctList then
               local values = stageArch.pendingScalarValues[slot]
               for i = #ctList, 1, -1 do
                  if ctList[i] == componentType then
                     return values[i]
                  end
               end
            end
         else
            return stageArch:findPendingValue(slot, componentType)
         end
      end
   end
   if sourceArch then
      local sourceCol = sourceArch.columns[componentType]
      if sourceCol then
         return (sourceCol)[sourceRow + 1]
      end
   end
   return nil
end




function WorldImpl:_deferSet(id, componentType, value)
   if behavior.hasBits(componentType, behavior.NeedsSet) then
      return behavior.set(self, id, componentType, value)
   end
   return self:deferSetRaw(id, componentType, value)
end



function WorldImpl:deferSetRaw(id, componentType, value)
   local slot = id % 2 ^ 22


   if getEntityState(self, slot) == 0 then
      local slots = self.allocator.slots


      if math.floor(id / 2 ^ 22) ~= slots[slot].generation then
         error("Entity ID not found: " .. id)
      end
      local s = slots[slot]
      local archetype = self.archetypeIndex[s.archetypeId]
      if archetype then
         local row = s.row

         local column
         if archetype == self.lastArch and componentType == self.lastCompType then
            column = self.lastColumn
         else
            column = archetype.columns[componentType]
            self.lastCompType = componentType
            self.lastArch = archetype
            self.lastColumn = column
         end
         if column then

            local luaRow = row + 1
            column[luaRow] = value
            archetype:markComponentDirty(componentType)
            return
         elseif componentType.relationshipType == nil then

            local newArch = archetype:withComponent(componentType, self.archetypeIndex)
            if newArch ~= archetype then
               local ci = componentType
               if ci._hasRequires then
                  local missing
                  newArch, missing = applyRequires(newArch, ci, self.archetypeIndex)
                  if missing then
                     stageRequiredDefaults(self, missing, archetype, slot)
                  end
               end
               if ci.storageType == "scalar" then
                  stageScalar(self, archetype, slot, componentType, value)
               else
                  appendPendingValue(self, archetype, slot, value)
               end
               newArch.pendingWrites = newArch.pendingWrites + 1
               archetype.hasPendingMoveOut = true; if archetype.dirtyQueuedEpoch ~= self._dirtyEpoch then archetype.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = archetype; self.dirtyArchetypeCount = __c end
               setPendingArch(self, slot, newArch)
            end
            setEntityState(self, slot, STATE_MUTATE)
            self.entityStateCount = self.entityStateCount + 1
            self.isDirty = true
            return
         end
      end
   end

   self:_deferSetSlow(id, componentType, value)
end

function WorldImpl:_deferSetSlow(
   id,
   componentType,
   value)

   local slot = id % 2 ^ 22
   local st = getEntityState(self, slot)
   if st == STATE_DESPAWN then return end



   if math.floor(id / 2 ^ 22) ~= self.allocator.slots[slot].generation then
      error("Entity ID not found: " .. id)
   end


   local ctI = componentType
   local isTag = ctI.storageType == "tag"
   local isScalar = ctI.storageType == "scalar"

   do
      local pendingArch = getPendingArch(self, slot)
      if pendingArch and (st == STATE_SPAWN or st == STATE_MUTATE) then
         local newArch = pendingArch:withComponent(componentType, self.archetypeIndex)




         local missing
         if newArch ~= pendingArch and ctI._hasRequires then
            newArch, missing = applyRequires(newArch, ctI, self.archetypeIndex)
         end





         local wildcard = ctI.wildcardContainer
         if wildcard and newArch.columns[wildcard] == nil then
            newArch = newArch:withComponent(wildcard, self.archetypeIndex)
         end

         if st == STATE_SPAWN then
            if newArch ~= pendingArch then
               local c = newArch.pendingSpawnCount + 1
               newArch.pendingSpawnCount = c;
               (newArch.pendingSpawnIds)[c] = id
               newArch.hasPendingSpawns = true; if newArch.dirtyQueuedEpoch ~= self._dirtyEpoch then newArch.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = newArch; self.dirtyArchetypeCount = __c end
               migratePending(pendingArch, newArch, slot)
               if isScalar then
                  stageScalar(self, newArch, slot, componentType, value)
               elseif not isTag then
                  appendPendingValue(self, newArch, slot, value)
               end
               if missing then
                  stageRequiredDefaults(self, missing, newArch, slot)
               end
            elseif isScalar then
               stageScalar(self, pendingArch, slot, componentType, value)
            elseif not isTag then
               appendPendingValue(self, pendingArch, slot, value)
            end
         else

            local srcSlot = (self.allocator.slots)[slot]
            local srcArch = self.archetypeIndex[srcSlot.archetypeId]
            if newArch ~= pendingArch then


               if srcArch then
                  pendingArch.pendingWrites = pendingArch.pendingWrites - 1
                  newArch.pendingWrites = newArch.pendingWrites + 1

                  srcArch.hasPendingMoveOut = true; if srcArch.dirtyQueuedEpoch ~= self._dirtyEpoch then srcArch.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = srcArch; self.dirtyArchetypeCount = __c end
               end
            end
            if isScalar then
               if srcArch then
                  stageScalar(self, srcArch, slot, componentType, value)
               end
            elseif not isTag then



               if srcArch then
                  appendPendingValue(self, srcArch, slot, value)
               end
            end
            if missing and srcArch then
               stageRequiredDefaults(self, missing, srcArch, slot)
            end
         end

         setPendingArch(self, slot, newArch)
         self.isDirty = true
         return
      end


      local srcSlot = (self.allocator.slots)[slot]
      local startArch
      local committedMove = false
      if st == STATE_SPAWN then
         startArch = self.archetypeIndex[srcSlot.archetypeId] or self.emptyArchetype
      else
         startArch = getPendingArch(self, slot)
         if not startArch then
            startArch = self.archetypeIndex[srcSlot.archetypeId]
            if not startArch then
               error("Entity ID not found: " .. id)
            end
            committedMove = true
         end
      end

      local newArch = startArch:withComponent(componentType, self.archetypeIndex)


      local missing
      if newArch ~= startArch and ctI._hasRequires then
         newArch, missing = applyRequires(newArch, ctI, self.archetypeIndex)
      end



      if committedMove then
         newArch.pendingWrites = newArch.pendingWrites + 1
      end
      setPendingArch(self, slot, newArch)
      if st == 0 then
         setEntityState(self, slot, STATE_MUTATE)
         self.entityStateCount = self.entityStateCount + 1
      end
      if st == STATE_SPAWN then
         local sc = newArch.pendingSpawnCount + 1
         newArch.pendingSpawnCount = sc;
         (newArch.pendingSpawnIds)[sc] = id
         newArch.hasPendingSpawns = true; if newArch.dirtyQueuedEpoch ~= self._dirtyEpoch then newArch.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = newArch; self.dirtyArchetypeCount = __c end
         if isScalar then
            stageScalar(self, newArch, slot, componentType, value)
         elseif not isTag then
            appendPendingValue(self, newArch, slot, value)
         end
         if missing then
            stageRequiredDefaults(self, missing, newArch, slot)
         end
      else
         startArch.hasPendingMoveOut = true; if startArch.dirtyQueuedEpoch ~= self._dirtyEpoch then startArch.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = startArch; self.dirtyArchetypeCount = __c end
         if isScalar then
            stageScalar(self, startArch, slot, componentType, value)
         elseif not isTag then
            appendPendingValue(self, startArch, slot, value)
         end
         if missing then
            stageRequiredDefaults(self, missing, startArch, slot)
         end
      end
      self.isDirty = true
   end

   local hadComponent = false
   if st ~= STATE_SPAWN then
      local srcSlot = (self.allocator.slots)[slot]
      local sourceArch = self.archetypeIndex[srcSlot.archetypeId]
      if sourceArch and sourceArch.columns[componentType] ~= nil then
         hadComponent = true
      end
   end

   if hadComponent then

      return
   end




   local container = componentType.wildcardContainer
   if container then
      local curArch = getPendingArch(self, slot)
      if curArch.columns[container] == nil then
         self:_deferSetSlow(id, container, container)
      end
   end
end



function WorldImpl:_deferRemove(id, component)
   if behavior.hasBits(component, behavior.NeedsRemove) then
      return behavior.remove(self, id, component)
   end
   return self:deferRemoveRaw(id, component)
end


function WorldImpl:deferRemoveRaw(id, component)
   local slot = id % 2 ^ 22
   local st = getEntityState(self, slot)


   if component.relationshipType == nil then
      if st == 0 then
         local slots = self.allocator.slots

         if math.floor(id / 2 ^ 22) ~= slots[slot].generation then return end
         local s = slots[slot]
         local archetype = self.archetypeIndex[s.archetypeId]
         if archetype then
            if archetype.columns[component] == nil then
               return
            end

            local newArch = (archetype.removeEdges)[component]
            if newArch == nil then
               newArch = archetype:withoutComponent(component, self.archetypeIndex)
            end
            if newArch == archetype then
               return
            end

            newArch.pendingWrites = newArch.pendingWrites + 1
            archetype.hasPendingMoveOut = true; if archetype.dirtyQueuedEpoch ~= self._dirtyEpoch then archetype.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = archetype; self.dirtyArchetypeCount = __c end
            setEntityState(self, slot, STATE_MUTATE)
            self.entityStateCount = self.entityStateCount + 1
            setPendingArch(self, slot, newArch)
            self.isDirty = true
            return
         end
      elseif st ~= STATE_DESPAWN then
         local pendingArch = getPendingArch(self, slot)
         if pendingArch then
            if pendingArch.columns[component] == nil then
               return
            end
            local newArch = (pendingArch.removeEdges)[component]
            if newArch == nil then
               newArch = pendingArch:withoutComponent(component, self.archetypeIndex)
            end
            if newArch ~= pendingArch then
               if st == STATE_SPAWN then
                  local c = newArch.pendingSpawnCount + 1
                  newArch.pendingSpawnCount = c;
                  (newArch.pendingSpawnIds)[c] = id
                  newArch.hasPendingSpawns = true; if newArch.dirtyQueuedEpoch ~= self._dirtyEpoch then newArch.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = newArch; self.dirtyArchetypeCount = __c end
                  migratePending(pendingArch, newArch, slot)
               elseif (self.allocator.slots)[slot].archetypeId ~= 0 then

                  pendingArch.pendingWrites = pendingArch.pendingWrites - 1
                  newArch.pendingWrites = newArch.pendingWrites + 1
               end
            end
            setPendingArch(self, slot, newArch)
            self.isDirty = true
            return
         end
      end
   end

   if st == STATE_DESPAWN then return end




   local prevArch = getPendingArch(self, slot)
   local hadPendingArch = prevArch ~= nil
   if not prevArch then
      local slots = self.allocator.slots

      if math.floor(id / 2 ^ 22) ~= slots[slot].generation then return end
      if st == STATE_SPAWN then
         prevArch = self.emptyArchetype
      else
         prevArch = self.archetypeIndex[slots[slot].archetypeId]
      end
   end


   if not prevArch then
      return
   end

   if prevArch.columns[component] == nil then
      return
   end

   local newArch = prevArch:withoutComponent(component, self.archetypeIndex)
   if newArch ~= prevArch then
      if st == STATE_SPAWN then
         local c = newArch.pendingSpawnCount + 1
         newArch.pendingSpawnCount = c;
         (newArch.pendingSpawnIds)[c] = id
         newArch.hasPendingSpawns = true; if newArch.dirtyQueuedEpoch ~= self._dirtyEpoch then newArch.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = newArch; self.dirtyArchetypeCount = __c end
         migratePending(prevArch, newArch, slot)
      else
         local s = (self.allocator.slots)[slot]
         local srcArch = self.archetypeIndex[s.archetypeId]
         if srcArch then

            srcArch.hasPendingMoveOut = true; if srcArch.dirtyQueuedEpoch ~= self._dirtyEpoch then srcArch.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = srcArch; self.dirtyArchetypeCount = __c end
            if hadPendingArch then
               prevArch.pendingWrites = prevArch.pendingWrites - 1
            end
            newArch.pendingWrites = newArch.pendingWrites + 1
         end
      end
   end
   setPendingArch(self, slot, newArch)
   if st == 0 then
      setEntityState(self, slot, STATE_MUTATE)
      self.entityStateCount = self.entityStateCount + 1
   end
   self.isDirty = true
end

function WorldImpl:_deferDespawn(id)
   local slot = id % 2 ^ 22
   local st = getEntityState(self, slot)
   if st == STATE_DESPAWN then
      return
   end

   local world = self
   local slots = self.allocator.slots


   if math.floor(id / 2 ^ 22) ~= slots[slot].generation then
      return
   end
   local s = slots[slot]
   local sourceArch = self.archetypeIndex[s.archetypeId]
   local pendingArch = getPendingArch(self, slot)



   if not sourceArch and not pendingArch and st == 0 then
      return
   end




   if st == 0 then self.entityStateCount = self.entityStateCount + 1 end
   setEntityState(self, slot, STATE_DESPAWN)
   self.isDirty = true


   local hasGlobalObs = world:hasObservers(0, OnDespawn)
   local hasObs = world:hasObservers(id, OnDespawn)

   local sourceRow = sourceArch and s.row or 0

   local logicalArch = nil
   if pendingArch then
      logicalArch = pendingArch
   elseif sourceArch then
      logicalArch = sourceArch
   end

   local relationshipStores = world.relationshipStores





   if logicalArch and logicalArch.onDespawnCount > 0 then
      local list = logicalArch.onDespawnComponents
      for i = 1, logicalArch.onDespawnCount do
         local comp = list[i]
         behavior.despawn(world, id, comp, logicalArch, sourceRow)
      end
   end






   if self._hasRelationshipStores then
      local isTargeted = self._targetRefCounts[id] ~= nil
      for container, store in pairs(relationshipStores) do
         local contRel = container
         if isTargeted and contRel.cascadeDelete then
            local sources = store:removeTarget(id)
            for sourceId in pairs(sources) do
               local sourceSlot = sourceId % 2 ^ 22
               if getEntityState(self, sourceSlot) ~= STATE_DESPAWN then
                  self:_deferDespawn(sourceId)
               end
            end
         elseif isTargeted and not contRel.isSparse then
            local sources = store:removeTarget(id)
            if next(sources) ~= nil then
               local instance = (container)(id)
               for sourceId in pairs(sources) do
                  local sourceSlot = sourceId % 2 ^ 22
                  if getEntityState(self, sourceSlot) ~= STATE_DESPAWN then
                     self:_deferRemove(sourceId, instance)
                  end
               end
            end
         end
         store:remove(id)
      end
   end




   if hasObs then world:emit(id, OnDespawn, id) end
   if hasGlobalObs then world:emit(0, OnDespawn, id) end
   if (((world.messages)._entityObserverCount)) > 0 then
      world:clearObservers(id)
   end



   if pendingArch and sourceArch then
      pendingArch.pendingWrites = pendingArch.pendingWrites - 1
   end
   if sourceArch then


      local c = sourceArch.pendingDespawnCount + 1
      sourceArch.pendingDespawnCount = c
      sourceArch.pendingDespawn[c] = slot
      sourceArch.hasPendingDespawns = true; if sourceArch.dirtyQueuedEpoch ~= self._dirtyEpoch then sourceArch.dirtyQueuedEpoch = self._dirtyEpoch; local __c = self.dirtyArchetypeCount + 1; self.dirtyArchetypeList[__c] = sourceArch; self.dirtyArchetypeCount = __c end
   end
end

return {}
