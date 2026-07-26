




local types = require("tecs.types")
local internal = require("tecs.internal.types")
local events = require("tecs.internal.events")
local IdAllocator = require("tecs.internal.IdAllocator")
local builtins = require("tecs.internal.builtins")
local behavior = require("tecs.internal.behavior")
local shared = require("tecs.internal.world.shared")
local bit = require("bit")






local WorldImpl = internal.WorldImpl
local moveSingleEntity = shared.moveSingleEntity
local applyRequires = shared.applyRequires
local writeRequired = shared.writeRequired
local getEntityState = shared.getEntityState
local OnDespawn = builtins.OnDespawn
local band = bit.band

local select = select





























































































































local function deferSetScoped(self, id, componentType, value)
   self._scopeDepth = self._scopeDepth + 1
   self:_deferSet(id, componentType, value)
   self._scopeDepth = self._scopeDepth - 1
   if self._scopeDepth == 0 and self.isDirty then self:_drain() end
end

local function deferRemoveScoped(self, id, component)
   self._scopeDepth = self._scopeDepth + 1
   self:_deferRemove(id, component)
   self._scopeDepth = self._scopeDepth - 1
   if self._scopeDepth == 0 and self.isDirty then self:_drain() end
end




function WorldImpl:_instantSet(id, componentType, value)
   local behaviorBits = (componentType).frameworkBehaviorBits or 0
   if band(behaviorBits, behavior.MustDeferSet) ~= 0 then
      return deferSetScoped(self, id, componentType, value)
   end
   if band(behaviorBits, behavior.NeedsSet) ~= 0 then
      return behavior.set(self, id, componentType, value)
   end
   return self:instantSetRaw(id, componentType, value)
end


function WorldImpl:instantSetRaw(id, componentType, value)
   local slot = id % 2 ^ 22




   if getEntityState(self, slot) ~= 0 then
      return deferSetScoped(self, id, componentType, value)
   end

   local slots = self.allocator.slots
   local s = slots[slot]


   if math.floor(id / 2 ^ 22) ~= slots[slot].generation then
      error("Entity ID not found: " .. id)
   end
   local srcArch = self.archetypeIndex[s.archetypeId]



   if not srcArch then
      return deferSetScoped(self, id, componentType, value)
   end

   local srcRow = s.row
   local srcLuaRow = srcRow + 1

   local existingCol = srcArch.columns[componentType]
   if existingCol then



      existingCol[srcLuaRow] = value
      srcArch:markComponentDirty(componentType)
      return
   end

   local dstArch = srcArch:withComponent(componentType, self.archetypeIndex)

   local ci = componentType
   local requiredList
   if ci._hasRequires then
      dstArch, requiredList = applyRequires(dstArch, ci, self.archetypeIndex)
   end




   local addedContainer = nil
   local wildcard = ci.wildcardContainer
   if wildcard and dstArch.columns[wildcard] == nil then
      dstArch = dstArch:withComponent(wildcard, self.archetypeIndex)
      addedContainer = wildcard
   end

   if dstArch == srcArch then return end

   local newRow = (dstArch.entities)[0]
   if newRow + 1 > dstArch.capacity then
      dstArch:reserveCapacity(newRow + 1)
   end
   local dstEntities = dstArch.entities
   local dstLuaRow = newRow + 1

   local plan = srcArch:getMovePlanTo(dstArch)
   local planSrcCols = plan.srcCols
   local planDstCols = plan.dstCols
   for c = 1, plan.count do
      planDstCols[c][dstLuaRow] = planSrcCols[c][srcLuaRow]
   end

   local newCol = dstArch.columns[componentType]
   if newCol then
      newCol[dstLuaRow] = value
   end
   if addedContainer then
      local containerCol = dstArch.columns[addedContainer]
      if containerCol then
         containerCol[dstLuaRow] = addedContainer
      end
   end
   writeRequired(requiredList, dstArch, dstLuaRow)

   local packedId = (srcArch.entities)[srcLuaRow]
   dstEntities[dstLuaRow] = packedId
   dstEntities[0] = newRow + 1

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




function WorldImpl:_instantRemove(id, component)
   local behaviorBits = (component).frameworkBehaviorBits or 0
   if band(behaviorBits, behavior.MustDeferRemove) ~= 0 then
      return deferRemoveScoped(self, id, component)
   end
   if band(behaviorBits, behavior.NeedsRemove) ~= 0 then
      return behavior.remove(self, id, component)
   end
   return self:instantRemoveRaw(id, component)
end


function WorldImpl:instantRemoveRaw(id, component)
   local slot = id % 2 ^ 22



   if getEntityState(self, slot) ~= 0 then
      return deferRemoveScoped(self, id, component)
   end

   local slots = self.allocator.slots
   local s = slots[slot]

   if math.floor(id / 2 ^ 22) ~= slots[slot].generation then return end
   local srcArch = self.archetypeIndex[s.archetypeId]
   if not srcArch then return end



   if not srcArch.columns[component] then return end
   local dstArch = srcArch:withoutComponent(component, self.archetypeIndex)
   if dstArch == srcArch then return end

   moveSingleEntity(self, slot, srcArch, s.row, dstArch, nil, nil)
end

local function instantSpawn1(self, c1)
   local target = self.emptyArchetype; local requiredList; local pendingKey
   do local comp = c1; local ct = comp.componentType; if ct.relationshipType ~= nil then return false, 0 elseif ct == (builtins.Key) then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; target = target:withComponent(ct, self.archetypeIndex); if ct._hasRequires then local extension; target, extension = applyRequires(target, ct, self.archetypeIndex); if extension then if requiredList == nil then requiredList = extension else for k = 1, #extension do requiredList[#requiredList + 1] = extension[k] end end end end end
   local autoState = self.autoStateComponent; if autoState then target = target:withComponent(autoState, self.archetypeIndex) end; local slot = IdAllocator.allocSlot(self.allocator); local slots = self.allocator.slots; local sSlot = slots[slot]; local id = slot + sSlot.generation * 2 ^ 22; if pendingKey ~= nil then self:_claimKey(id, pendingKey) end; local newRow = (target.entities)[0]; if newRow + 1 > target.capacity then target:reserveCapacity(newRow + 1) end; local dstEntities = target.entities; local dstLuaRow = newRow + 1; dstEntities[dstLuaRow] = id; dstEntities[0] = newRow + 1; sSlot.archetypeId = target.id; sSlot.row = newRow; writeRequired(requiredList, target, dstLuaRow)
   do local comp = c1; local ct = comp.componentType; local col = target.columns[ct]; if col then if (ct).storageType == "scalar" then col[dstLuaRow] = (comp).value else col[dstLuaRow] = comp end end end
   target:onRowsAdded(newRow, 1, nil); local transitionObserver = self._transitionObserver; if transitionObserver then transitionObserver.entity(id, nil, target) end; return true, id
end

local function instantSpawn2(self, c1, c2)
   local target = self.emptyArchetype; local requiredList; local pendingKey
   do local comp = c1; local ct = comp.componentType; if ct.relationshipType ~= nil then return false, 0 elseif ct == (builtins.Key) then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; target = target:withComponent(ct, self.archetypeIndex); if ct._hasRequires then local extension; target, extension = applyRequires(target, ct, self.archetypeIndex); if extension then if requiredList == nil then requiredList = extension else for k = 1, #extension do requiredList[#requiredList + 1] = extension[k] end end end end end
   do local comp = c2; local ct = comp.componentType; if ct.relationshipType ~= nil then return false, 0 elseif ct == (builtins.Key) then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; target = target:withComponent(ct, self.archetypeIndex); if ct._hasRequires then local extension; target, extension = applyRequires(target, ct, self.archetypeIndex); if extension then if requiredList == nil then requiredList = extension else for k = 1, #extension do requiredList[#requiredList + 1] = extension[k] end end end end end
   local autoState = self.autoStateComponent; if autoState then target = target:withComponent(autoState, self.archetypeIndex) end; local slot = IdAllocator.allocSlot(self.allocator); local slots = self.allocator.slots; local sSlot = slots[slot]; local id = slot + sSlot.generation * 2 ^ 22; if pendingKey ~= nil then self:_claimKey(id, pendingKey) end; local newRow = (target.entities)[0]; if newRow + 1 > target.capacity then target:reserveCapacity(newRow + 1) end; local dstEntities = target.entities; local dstLuaRow = newRow + 1; dstEntities[dstLuaRow] = id; dstEntities[0] = newRow + 1; sSlot.archetypeId = target.id; sSlot.row = newRow; writeRequired(requiredList, target, dstLuaRow)
   do local comp = c1; local ct = comp.componentType; local col = target.columns[ct]; if col then if (ct).storageType == "scalar" then col[dstLuaRow] = (comp).value else col[dstLuaRow] = comp end end end
   do local comp = c2; local ct = comp.componentType; local col = target.columns[ct]; if col then if (ct).storageType == "scalar" then col[dstLuaRow] = (comp).value else col[dstLuaRow] = comp end end end
   target:onRowsAdded(newRow, 1, nil); local transitionObserver = self._transitionObserver; if transitionObserver then transitionObserver.entity(id, nil, target) end; return true, id
end

local function instantSpawn3(self, c1, c2, c3)
   local target = self.emptyArchetype; local requiredList; local pendingKey
   do local comp = c1; local ct = comp.componentType; if ct.relationshipType ~= nil then return false, 0 elseif ct == (builtins.Key) then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; target = target:withComponent(ct, self.archetypeIndex); if ct._hasRequires then local extension; target, extension = applyRequires(target, ct, self.archetypeIndex); if extension then if requiredList == nil then requiredList = extension else for k = 1, #extension do requiredList[#requiredList + 1] = extension[k] end end end end end
   do local comp = c2; local ct = comp.componentType; if ct.relationshipType ~= nil then return false, 0 elseif ct == (builtins.Key) then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; target = target:withComponent(ct, self.archetypeIndex); if ct._hasRequires then local extension; target, extension = applyRequires(target, ct, self.archetypeIndex); if extension then if requiredList == nil then requiredList = extension else for k = 1, #extension do requiredList[#requiredList + 1] = extension[k] end end end end end
   do local comp = c3; local ct = comp.componentType; if ct.relationshipType ~= nil then return false, 0 elseif ct == (builtins.Key) then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; target = target:withComponent(ct, self.archetypeIndex); if ct._hasRequires then local extension; target, extension = applyRequires(target, ct, self.archetypeIndex); if extension then if requiredList == nil then requiredList = extension else for k = 1, #extension do requiredList[#requiredList + 1] = extension[k] end end end end end
   local autoState = self.autoStateComponent; if autoState then target = target:withComponent(autoState, self.archetypeIndex) end; local slot = IdAllocator.allocSlot(self.allocator); local slots = self.allocator.slots; local sSlot = slots[slot]; local id = slot + sSlot.generation * 2 ^ 22; if pendingKey ~= nil then self:_claimKey(id, pendingKey) end; local newRow = (target.entities)[0]; if newRow + 1 > target.capacity then target:reserveCapacity(newRow + 1) end; local dstEntities = target.entities; local dstLuaRow = newRow + 1; dstEntities[dstLuaRow] = id; dstEntities[0] = newRow + 1; sSlot.archetypeId = target.id; sSlot.row = newRow; writeRequired(requiredList, target, dstLuaRow)
   do local comp = c1; local ct = comp.componentType; local col = target.columns[ct]; if col then if (ct).storageType == "scalar" then col[dstLuaRow] = (comp).value else col[dstLuaRow] = comp end end end
   do local comp = c2; local ct = comp.componentType; local col = target.columns[ct]; if col then if (ct).storageType == "scalar" then col[dstLuaRow] = (comp).value else col[dstLuaRow] = comp end end end
   do local comp = c3; local ct = comp.componentType; local col = target.columns[ct]; if col then if (ct).storageType == "scalar" then col[dstLuaRow] = (comp).value else col[dstLuaRow] = comp end end end
   target:onRowsAdded(newRow, 1, nil); local transitionObserver = self._transitionObserver; if transitionObserver then transitionObserver.entity(id, nil, target) end; return true, id
end

local function instantSpawn4(self,
   c1, c2, c3, c4)
   local target = self.emptyArchetype; local requiredList; local pendingKey
   do local comp = c1; local ct = comp.componentType; if ct.relationshipType ~= nil then return false, 0 elseif ct == (builtins.Key) then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; target = target:withComponent(ct, self.archetypeIndex); if ct._hasRequires then local extension; target, extension = applyRequires(target, ct, self.archetypeIndex); if extension then if requiredList == nil then requiredList = extension else for k = 1, #extension do requiredList[#requiredList + 1] = extension[k] end end end end end
   do local comp = c2; local ct = comp.componentType; if ct.relationshipType ~= nil then return false, 0 elseif ct == (builtins.Key) then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; target = target:withComponent(ct, self.archetypeIndex); if ct._hasRequires then local extension; target, extension = applyRequires(target, ct, self.archetypeIndex); if extension then if requiredList == nil then requiredList = extension else for k = 1, #extension do requiredList[#requiredList + 1] = extension[k] end end end end end
   do local comp = c3; local ct = comp.componentType; if ct.relationshipType ~= nil then return false, 0 elseif ct == (builtins.Key) then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; target = target:withComponent(ct, self.archetypeIndex); if ct._hasRequires then local extension; target, extension = applyRequires(target, ct, self.archetypeIndex); if extension then if requiredList == nil then requiredList = extension else for k = 1, #extension do requiredList[#requiredList + 1] = extension[k] end end end end end
   do local comp = c4; local ct = comp.componentType; if ct.relationshipType ~= nil then return false, 0 elseif ct == (builtins.Key) then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; target = target:withComponent(ct, self.archetypeIndex); if ct._hasRequires then local extension; target, extension = applyRequires(target, ct, self.archetypeIndex); if extension then if requiredList == nil then requiredList = extension else for k = 1, #extension do requiredList[#requiredList + 1] = extension[k] end end end end end
   local autoState = self.autoStateComponent; if autoState then target = target:withComponent(autoState, self.archetypeIndex) end; local slot = IdAllocator.allocSlot(self.allocator); local slots = self.allocator.slots; local sSlot = slots[slot]; local id = slot + sSlot.generation * 2 ^ 22; if pendingKey ~= nil then self:_claimKey(id, pendingKey) end; local newRow = (target.entities)[0]; if newRow + 1 > target.capacity then target:reserveCapacity(newRow + 1) end; local dstEntities = target.entities; local dstLuaRow = newRow + 1; dstEntities[dstLuaRow] = id; dstEntities[0] = newRow + 1; sSlot.archetypeId = target.id; sSlot.row = newRow; writeRequired(requiredList, target, dstLuaRow)
   do local comp = c1; local ct = comp.componentType; local col = target.columns[ct]; if col then if (ct).storageType == "scalar" then col[dstLuaRow] = (comp).value else col[dstLuaRow] = comp end end end
   do local comp = c2; local ct = comp.componentType; local col = target.columns[ct]; if col then if (ct).storageType == "scalar" then col[dstLuaRow] = (comp).value else col[dstLuaRow] = comp end end end
   do local comp = c3; local ct = comp.componentType; local col = target.columns[ct]; if col then if (ct).storageType == "scalar" then col[dstLuaRow] = (comp).value else col[dstLuaRow] = comp end end end
   do local comp = c4; local ct = comp.componentType; local col = target.columns[ct]; if col then if (ct).storageType == "scalar" then col[dstLuaRow] = (comp).value else col[dstLuaRow] = comp end end end
   target:onRowsAdded(newRow, 1, nil); local transitionObserver = self._transitionObserver; if transitionObserver then transitionObserver.entity(id, nil, target) end; return true, id
end



local function instantSpawnN(self, ...)
   local n = select('#', ...)
   local target = self.emptyArchetype; local requiredList; local pendingKey
   for i = 1, n do
      do local comp = select(i, ...); local ct = comp.componentType; if ct.relationshipType ~= nil then return false, 0 elseif ct == (builtins.Key) then if pendingKey ~= nil then error("spawn: entity cannot have more than one Key") end; pendingKey = (comp).value end; target = target:withComponent(ct, self.archetypeIndex); if ct._hasRequires then local extension; target, extension = applyRequires(target, ct, self.archetypeIndex); if extension then if requiredList == nil then requiredList = extension else for k = 1, #extension do requiredList[#requiredList + 1] = extension[k] end end end end end
   end
   local autoState = self.autoStateComponent; if autoState then target = target:withComponent(autoState, self.archetypeIndex) end; local slot = IdAllocator.allocSlot(self.allocator); local slots = self.allocator.slots; local sSlot = slots[slot]; local id = slot + sSlot.generation * 2 ^ 22; if pendingKey ~= nil then self:_claimKey(id, pendingKey) end; local newRow = (target.entities)[0]; if newRow + 1 > target.capacity then target:reserveCapacity(newRow + 1) end; local dstEntities = target.entities; local dstLuaRow = newRow + 1; dstEntities[dstLuaRow] = id; dstEntities[0] = newRow + 1; sSlot.archetypeId = target.id; sSlot.row = newRow; writeRequired(requiredList, target, dstLuaRow)
   for i = 1, n do
      do local comp = select(i, ...); local ct = comp.componentType; local col = target.columns[ct]; if col then if (ct).storageType == "scalar" then col[dstLuaRow] = (comp).value else col[dstLuaRow] = comp end end end
   end
   target:onRowsAdded(newRow, 1, nil); local transitionObserver = self._transitionObserver; if transitionObserver then transitionObserver.entity(id, nil, target) end; return true, id
end

function WorldImpl:_instantSpawn(...)
   local n = select('#', ...)
   if n == 1 then
      return instantSpawn1(self, select(1, ...))
   elseif n == 2 then
      return instantSpawn2(self, select(1, ...), select(2, ...))
   elseif n == 3 then
      return instantSpawn3(self, select(1, ...), select(2, ...), select(3, ...))
   elseif n == 4 then
      return instantSpawn4(self, select(1, ...), select(2, ...), select(3, ...), select(4, ...))
   else
      return instantSpawnN(self, ...)
   end
end

function WorldImpl:_instantDespawn(id)
   local slot = id % 2 ^ 22
   local slots = self.allocator.slots
   local s = slots[slot]


   if math.floor(id / 2 ^ 22) ~= slots[slot].generation then
      return true
   end
   local srcArch = self.archetypeIndex[s.archetypeId]



   if not srcArch or srcArch.onDespawnCount > 0 then
      return false
   end

   if self._hasRelationshipStores then
      if self._targetRefCounts[id] then
         return false
      end




      for _, store in pairs(self.relationshipStores) do
         store:remove(id)
      end
   end

   local messages = self.messages
   if (messages._totalObservers) > 0 then



      if self:hasObservers(0, OnDespawn) or self:hasObservers(id, OnDespawn) then
         return false
      end



      if (messages._entityObserverCount) > 0 then
         self:clearObservers(id)
      end
   end

   local observer = self._transitionObserver
   if observer then observer.entity(id, srcArch, nil) end
   local movedEntId = srcArch:removeEntity(s.row, nil)
   if movedEntId ~= 0 then
      local movedSlot = movedEntId % 2 ^ 22
      slots[movedSlot].row = s.row
   end

   IdAllocator.freeSlot(self.allocator, slot)
   return true
end

return {}
