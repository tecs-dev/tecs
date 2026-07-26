

local types = require("tecs.types")
local internal = require("tecs.internal.types")
local ArchetypeImpl = require("tecs.internal.Archetype")
local Bitset = require("tecs.utils.Bitset")







local COMPARE_BY_ID = function(a, b)
   return a.componentId < b.componentId
end

local ArchetypeIndex = {}

















local ARCHETYPE_INDEX_MT = {
   __index = ArchetypeIndex,
}

function ArchetypeIndex.new(dirtySet)
   local self = setmetatable({
      componentIndex = {},
      dirtySet = dirtySet,
      relationshipStoreGetter = nil,
      onNewArchetype = nil,
      emptyArchetype = nil,
      maxId = 0,
      freeIds = {},
      freeIdCount = 0,
   }, ARCHETYPE_INDEX_MT)


   do
      local empty = ArchetypeImpl.new({}, self.dirtySet, self.relationshipStoreGetter)
      self.maxId = 1
      empty.id = 1
      self[1] = empty
      self.emptyArchetype = empty
   end

   return self
end

local function acquireId(self)
   local fc = self.freeIdCount
   if fc > 0 then
      local id = self.freeIds[fc]
      self.freeIds[fc] = nil
      self.freeIdCount = fc - 1
      return id
   end
   local id = self.maxId + 1
   self.maxId = id
   return id
end

local function setSize(set)
   local n = 0
   for _ in pairs(set) do
      n = n + 1
   end
   return n
end

local function matchesQuerySignatures(
   archetype,
   includeBits,
   includeWordBits,
   includeAnyBits,
   includeAnyWordBits,
   excludeBits,
   excludeWordBits)

   local signatureWordBits = archetype.signatureWordBits
   local signatureBits = archetype.signatureBits
   if not signatureWordBits:containsAll(includeWordBits) then
      return false
   end
   if not (includeBits.count == 0) and not signatureBits:containsAll(includeBits) then
      return false
   end
   if not (includeAnyWordBits.count == 0) and not signatureWordBits:overlaps(includeAnyWordBits) then
      return false
   end
   if not (includeAnyBits.count == 0) and not signatureBits:overlaps(includeAnyBits) then
      return false
   end
   if not (excludeWordBits.count == 0) and not not signatureWordBits:overlaps(excludeWordBits) and
      not (excludeBits.count == 0) and signatureBits:overlaps(excludeBits) then

      return false
   end
   return true
end

local function filterMatchingBySignatures(
   result,
   count,
   includeBits,
   includeWordBits,
   includeAnyBits,
   includeAnyWordBits,
   excludeBits,
   excludeWordBits)

   local j = 1
   while j <= count do
      if not matchesQuerySignatures(
         result[j],
         includeBits,
         includeWordBits,
         includeAnyBits,
         includeAnyWordBits,
         excludeBits,
         excludeWordBits) then

         result[j] = result[count]
         result[count] = nil
         count = count - 1
      else
         j = j + 1
      end
   end
   return count
end

function ArchetypeIndex:getOrCreate(components)
   local n = #components
   if n == 0 then
      return self.emptyArchetype
   end

   table.sort(components, COMPARE_BY_ID)

   local compIndex = self.componentIndex
   local notify = self.onNewArchetype
   local dirtySet = self.dirtySet
   local relationshipStoreGetter = self.relationshipStoreGetter

   local target = self.emptyArchetype
   local prefix = {}

   for i = 1, n do
      local c = components[i]
      prefix[i] = c

      local edgeTarget = target.addEdges[c]
      if not edgeTarget then
         edgeTarget = ArchetypeImpl.new(prefix, dirtySet, relationshipStoreGetter)
         local nextId = acquireId(self)
         edgeTarget.id = nextId
         self[nextId] = edgeTarget

         for k = 1, i do
            local comp = prefix[k]
            local set = compIndex[comp]
            if not set then
               set = {}
               compIndex[comp] = set
            end
            set[edgeTarget] = true
         end

         target.addEdges[c] = edgeTarget
         edgeTarget.removeEdges[c] = target

         if notify then
            notify(edgeTarget)
         end
      end
      target = edgeTarget
   end

   return target
end

function ArchetypeIndex:findMatching(include, masks)
   local result = {}
   local includeBits = masks.includeBits
   local includeWordBits = masks.includeWordBits
   local includeAnyBits = masks.includeAnyBits
   local includeAnyWordBits = masks.includeAnyWordBits
   local excludeBits = masks.excludeBits
   local excludeWordBits = masks.excludeWordBits
   local includeCount = include == nil and 0 or #include

   if includeCount == 0 then
      local n = 0
      for i = 1, self.maxId do
         local arch = self[i]
         if arch then
            n = n + 1
            result[n] = arch
         end
      end
   else
      local seedComponent = include[1]
      local seedArchetypes = self.componentIndex[seedComponent]
      if not seedArchetypes then
         return result
      end
      local seedCount = setSize(seedArchetypes)

      for i = 2, includeCount do
         local component = include[i]
         local archetypes = self.componentIndex[component]
         if not archetypes then
            return result
         end
         local arcSize = setSize(archetypes)
         if arcSize < seedCount then
            seedComponent = component
            seedArchetypes = archetypes
            seedCount = arcSize
         end
      end

      local n = 0
      for archetype in pairs(seedArchetypes) do
         n = n + 1
         result[n] = archetype
      end

      n = filterMatchingBySignatures(
      result,
      n,
      includeBits,
      includeWordBits,
      includeAnyBits,
      includeAnyWordBits,
      excludeBits,
      excludeWordBits)

      if n == 0 then
         return result
      end
   end

   local n = #result
   n = filterMatchingBySignatures(
   result,
   n,
   includeBits,
   includeWordBits,
   includeAnyBits,
   includeAnyWordBits,
   excludeBits,
   excludeWordBits)


   return result
end

function ArchetypeIndex:getArchetypesWithComponent(component)
   return self.componentIndex[component]
end


function ArchetypeIndex:destroy(archetype)
   archetype:notifyArchetypeDestroyed()

   for c, neighbor in pairs(archetype.addEdges) do
      neighbor.removeEdges[c] = nil
   end
   for c, neighbor in pairs(archetype.removeEdges) do
      neighbor.addEdges[c] = nil
   end

   local compIndex = self.componentIndex
   for i = 1, archetype.columnsCount do
      local comp = archetype.componentList[i]
      local set = compIndex[comp]
      if set then
         set[archetype] = nil
         if next(set) == nil then
            compIndex[comp] = nil
         end
      end
   end

   local destroyedId = archetype.id
   self[destroyedId] = nil
   local fc = self.freeIdCount + 1
   self.freeIds[fc] = destroyedId
   self.freeIdCount = fc

   local dirtySet = self.dirtySet
   if dirtySet then
      dirtySet[archetype] = nil
   end


   local t = archetype
   t.columns = nil
   t.columnArray = nil
   t.componentList = nil
   t.signatureBits = nil
   t.signatureWordBits = nil
   t.movePlansOut = nil
   t.addEdges = nil
   t.removeEdges = nil
   t._observers = nil
   t.pendingSpawnIds = nil
   t.pendingValues = nil
   t.pendingScalarTypes = nil
   t.pendingScalarValues = nil
   t.pendingDespawn = nil
   t.pendingBundleDrains = nil
   t.batchSpawnQueue = nil
   t.batchSpawnAtQueue = nil
   t._componentDirty = nil
   t.entities = nil
   archetype.id = 0
end

return ArchetypeIndex
