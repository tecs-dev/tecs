








local types = require("tecs.types")
local internal = require("tecs.internal.types")
local RelationshipStore = require("tecs.internal.RelationshipStore")
local bit = require("bit")






local band = bit.band
local bor = bit.bor

local Key = 1
local SparseRelationship = 2
local DenseRelationship = 3

local NeedsSet = 1
local NeedsRemove = 2
local NeedsDespawn = 4
local MustDeferSet = 8
local MustDeferRemove = 16
local NoBulkBatch = 32

local frameworkBehavior = {}


























frameworkBehavior.Key = Key
frameworkBehavior.SparseRelationship = SparseRelationship
frameworkBehavior.DenseRelationship = DenseRelationship
frameworkBehavior.NeedsSet = NeedsSet
frameworkBehavior.NeedsRemove = NeedsRemove
frameworkBehavior.NeedsDespawn = NeedsDespawn
frameworkBehavior.MustDeferSet = MustDeferSet
frameworkBehavior.MustDeferRemove = MustDeferRemove
frameworkBehavior.NoBulkBatch = NoBulkBatch








function frameworkBehavior.behaviorOwner(component)
   local componentType = component.componentType
   if componentType then
      local wildcard = componentType.wildcardContainer
      if wildcard then
         return wildcard
      end
      local cti = componentType
      if cti.frameworkBehavior ~= nil or cti.frameworkBehaviorBits ~= nil then
         return cti
      end
   end

   local wildcard = component.wildcardContainer
   if wildcard then
      return wildcard
   end

   return (componentType or component)
end

function frameworkBehavior.hasOwnerBits(owner, bits)
   return band(owner.frameworkBehaviorBits or 0, bits) ~= 0
end

function frameworkBehavior.hasBits(component, bits)
   return frameworkBehavior.hasOwnerBits(frameworkBehavior.behaviorOwner(component), bits)
end

function frameworkBehavior.keyBits()
   return bor(NeedsSet, NeedsRemove, NeedsDespawn, NoBulkBatch)
end

function frameworkBehavior.sparseRelationshipBits()
   return bor(NeedsSet, NeedsRemove, MustDeferSet, MustDeferRemove, NoBulkBatch)
end

function frameworkBehavior.denseExclusiveRelationshipBits()
   return bor(NeedsSet, NeedsRemove, NoBulkBatch)
end

function frameworkBehavior.densePlainRelationshipBits()
   return bor(NeedsRemove, NoBulkBatch)
end

function frameworkBehavior.denseReverseIndexRelationshipBits()
   return bor(NeedsSet, NeedsRemove, NeedsDespawn, NoBulkBatch)
end

local function denseStore(world, owner)
   return world.relationshipStores[owner]
end

local function denseUnlink(world, owner, id, value)
   if value ~= nil then
      local store = denseStore(world, owner)
      if store then
         store:unlink(id, (value).target)
      end
   end
end

local function denseReadOld(component, arch, row)
   local col = arch.columns[component]
   if col ~= nil then
      return col[row + 1]
   end
end








function frameworkBehavior.set(world, id, componentType, value)
   local owner = frameworkBehavior.behaviorOwner(componentType)
   local behavior = owner.frameworkBehavior or 0

   if behavior == Key then
      world:_claimKey(id, value)
      return world:setRaw(id, componentType, value)
   end

   if behavior == SparseRelationship then
      if (value).target ~= nil then
         world:setSparseRaw(id, value)
      end
      return world:deferSetRaw(id, owner, owner)
   end

   if behavior ~= DenseRelationship then
      return world:setRaw(id, componentType, value)
   end

   if (owner).exclusiveRelationship then
      local arch = world:currentArchetype(id)
      if arch then


         local list = arch.componentList
         for i = 1, arch.columnsCount do
            local existingComp = list[i]
            local existOwner = existingComp.wildcardContainer
            if existOwner == owner and existingComp ~= componentType then
               world:remove(id, existingComp)
            end
         end
      end
   end

   world:setRaw(id, componentType, value)
   if owner.reverseIndex then
      local store = denseStore(world, owner)
      if store then
         store:link(id, (value).target)
      end
   end
end








function frameworkBehavior.remove(world, id, component)
   local owner = frameworkBehavior.behaviorOwner(component)
   local behavior = owner.frameworkBehavior or 0

   if behavior == Key then
      world:_releaseKeyForEntity(id)
      return world:removeRaw(id, component)
   end

   if behavior == SparseRelationship then
      if component == owner then
         return world:removeSparseRaw(id, owner)
      end
      return world:removeSparseOneRaw(id, owner, component.target)
   end

   if behavior ~= DenseRelationship then
      return world:removeRaw(id, component)
   end

   local oldValue = nil
   if owner.reverseIndex then
      oldValue = world:oldValueOf(id, component)
   end
   world:removeRaw(id, component)
   if owner.reverseIndex then
      denseUnlink(world, owner, id, oldValue)
   end




   local ownerComp = owner
   if component ~= ownerComp then
      local arch = world:currentArchetype(id)
      if arch and arch.columns[ownerComp] ~= nil then
         local list = arch.componentList
         local hasSibling = false
         for i = 1, arch.columnsCount do
            if (list[i]).wildcardContainer == ownerComp then
               hasSibling = true
               break
            end
         end
         if not hasSibling then
            world:removeRaw(id, ownerComp)
         end
      end
   end
end

function frameworkBehavior.despawn(world, id, component, arch, row)
   local owner = frameworkBehavior.behaviorOwner(component)
   local behavior = owner.frameworkBehavior or 0
   if behavior == Key then
      return world:_releaseKeyForEntity(id)
   elseif behavior == DenseRelationship then
      denseUnlink(world, owner, id, denseReadOld(component, arch, row))
   end
end

return frameworkBehavior
