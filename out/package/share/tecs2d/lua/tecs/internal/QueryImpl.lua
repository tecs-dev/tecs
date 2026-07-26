local types = require("tecs.types")
local internal = require("tecs.internal.types")
local builtins = require("tecs.internal.builtins")
local StringBuffer = require("string.buffer")
local Bitset = require("tecs.utils.Bitset")
local bit = require("bit")

local table_insert, table_remove = table.insert, table.remove
local floor = math.floor
local rshift = bit.rshift

local STRING_BUFFER = StringBuffer.new()
















local QueryImpl = {}




























local QueryCursorImpl = {}







local QUERY_MT = { __index = QueryImpl }
local QUERY_CURSOR_MT = { __index = QueryCursorImpl }











local function simpleIterStep(self, var)
   local idx
   if var == nil then
      idx = 1
      self._world:_pushQueryScope()
   else
      idx = self._activeIndices[var] + 1
   end
   local archetype = self._activeItems[idx]
   if not archetype then
      self._world:_popQueryScope()
      return
   end
   return archetype, archetype.entities[0], archetype.entities
end

local function groupedIterStep(self, var)
   local groupList = self._activeGroupList
   local groupItems = self._activeGroupItems
   local gi, ai
   if var == nil then
      gi, ai = 1, 1
      self._world:_pushQueryScope()
   else
      local arch = var
      local groupId = self._archetypeGroups[arch]
      gi = self._activeGroupListIndices[groupId]
      ai = self._activeGroupIndices[groupId][arch] + 1
   end

   while gi <= #groupList do
      local items = groupItems[groupList[gi]]
      if items and ai <= #items then
         local archetype = items[ai]
         return archetype, archetype.entities[0], archetype.entities
      end
      gi = gi + 1
      ai = 1
   end
   self._world:_popQueryScope()
end

local function openCursor(self)
   if self._closed then return false end
   if not self._open then
      self._query._world:_pushQueryScope()
      self._open = true
   end
   return true
end

function QueryCursorImpl:close()
   if self._closed then return end
   self._closed = true
   if self._open then
      self._open = false
      self._query._world:_popQueryScope()
   end
end

local function cursorIterStep(self, var)
   if not openCursor(self) then return end

   local query = self._query
   local idx
   if var == nil then
      idx = 1
   else
      idx = query._activeIndices[var] + 1
   end

   local archetype = query._activeItems[idx]
   if not archetype then
      self:close()
      return
   end
   return archetype, archetype.entities[0], archetype.entities
end

local function cursorGroupedIterStep(self, var)
   if not openCursor(self) then return end

   local query = self._query
   local groupList = query._activeGroupList
   local groupItems = query._activeGroupItems
   local gi, ai
   if var == nil then
      gi, ai = 1, 1
   else
      local arch = var
      local groupId = query._archetypeGroups[arch]
      gi = query._activeGroupListIndices[groupId]
      ai = query._activeGroupIndices[groupId][arch] + 1
   end

   while gi <= #groupList do
      local items = groupItems[groupList[gi]]
      if items and ai <= #items then
         local archetype = items[ai]
         return archetype, archetype.entities[0], archetype.entities
      end
      gi = gi + 1
      ai = 1
   end
   self:close()
end

local function cursorGroupsStep(self, prev)
   if not openCursor(self) then return end

   local query = self._query
   local i
   if prev == nil then
      i = 1
   else
      i = query._activeGroupListIndices[prev] + 1
   end
   local list = query._activeGroupList
   if i <= #list then return list[i] end
   self:close()
   return nil
end

local function cursorGroupStep(self, prev)
   if not openCursor(self) then return end

   local items = self._selectedGroup
   local i
   if prev == nil then
      i = 1
   else
      local query = self._query
      local arch = prev
      local groupId = query._archetypeGroups[arch]
      i = query._activeGroupIndices[groupId][arch] + 1
   end
   if items and i <= #items then
      local archetype = items[i]
      return archetype, archetype.entities[0], archetype.entities
   end
   self:close()
end

local function prepareCursor(self)
   if self._closed then
      error("query cursor is closed")
   end
   if self._prepared then
      error("query cursor already has a traversal")
   end
   self._prepared = true
end

function QueryCursorImpl:iter()
   prepareCursor(self)
   if self._query._archetypeGroups then
      return cursorGroupedIterStep, self, nil
   else
      return cursorIterStep, self, nil
   end
end

function QueryCursorImpl:groups()
   prepareCursor(self)
   return cursorGroupsStep, self, nil
end

function QueryCursorImpl:group(groupId)
   prepareCursor(self)
   self._selectedGroup = self._query._activeGroupItems[groupId]
   return cursorGroupStep, self, nil
end





local function formatQuery(query)
   local buf = STRING_BUFFER
   buf:reset()
   buf:put(query.descriptor.name or "Query")
   local include = query.descriptor.include
   local includeAny = query.descriptor.includeAny
   local exclude = query.descriptor.exclude
   local wroteClause = false

   if #include > 0 then
      buf:put(" {include: ")
      for i = 1, #include do
         if i > 1 then
            buf:put(", ")
         end
         buf:put(tostring(include[i]))
      end
      wroteClause = true
   end

   if includeAny and #includeAny > 0 then
      if wroteClause then
         buf:put(", ")
      else
         buf:put(" {")
         wroteClause = true
      end
      buf:put("includeAny: ")
      for i = 1, #includeAny do
         if i > 1 then
            buf:put(", ")
         end
         buf:put(tostring(includeAny[i]))
      end
   end

   if exclude and #exclude > 0 then
      if wroteClause then
         buf:put(", ")
      else
         buf:put(" {")
         wroteClause = true
      end
      buf:put("exclude: ")
      for i = 1, #exclude do
         if i > 1 then
            buf:put(", ")
         end
         buf:put(tostring(exclude[i]))
      end
   end

   if wroteClause then
      buf:put("}")
   end

   buf:put(" [", #query._archetypes, " archetypes]")
   return tostring(buf)
end

QUERY_MT.__tostring = formatQuery





function QueryImpl:iter()
   if self._archetypeGroups then
      return groupedIterStep, self, nil
   else
      return simpleIterStep, self, nil
   end
end

function QueryImpl:cursor()
   local cursor = setmetatable({
      _query = self,
      _open = false,
      _closed = false,
      _prepared = false,
   }, QUERY_CURSOR_MT)
   return cursor
end

function QueryImpl:getGroup(archetype)
   if not self._archetypeGroups then
      return nil
   else
      return self._archetypeGroups[archetype]
   end
end

local function groupsNext(self, prev)
   local i
   if prev == nil then
      i = 1
      self._world:_pushQueryScope()
   else
      i = self._activeGroupListIndices[prev] + 1
   end
   local list = self._activeGroupList
   if i <= #list then return list[i] end
   self._world:_popQueryScope()
   return nil
end

local function groupNext(self, prev)
   local items
   local i
   if prev == nil then
      items = self._iterGroupSelected
      if not items then



         self._world:_pushQueryScope()
         self._world:_popQueryScope()
         return
      end
      self._world:_pushQueryScope()
      i = 1
   else
      local arch = prev
      local groupId = self._archetypeGroups[arch]
      items = self._activeGroupItems[groupId]
      i = self._activeGroupIndices[groupId][arch] + 1
   end
   if i <= #items then
      local archetype = items[i]
      return archetype, archetype.entities[0], archetype.entities
   end
   self._world:_popQueryScope()
end

function QueryImpl:groups()
   return groupsNext, self, nil
end

function QueryImpl:group(groupId)
   self._iterGroupSelected = self._activeGroupItems[groupId]
   return groupNext, self, nil
end

function QueryImpl:count()
   local total = 0
   if self._archetypeGroups then
      local groupList = self._activeGroupList
      for gi = 1, #groupList do
         local items = self._activeGroupItems[groupList[gi]]
         for ai = 1, #items do
            total = total + (items[ai].entities[0])
         end
      end
   else
      local items = self._activeItems
      for i = 1, #items do
         total = total + (items[i].entities[0])
      end
   end
   return total
end

function QueryImpl:getGroupCount(groupId)
   local items = self._activeGroupItems[groupId]
   if not items then
      return 0
   end
   local total = 0
   for i = 1, #items do
      total = total + items[i].entities[0]
   end
   return total
end





local function archetypeMatches(query, archetype)
   local arch = archetype
   local signatureWordBits = arch.signatureWordBits
   local signatureBits = arch.signatureBits

   if not signatureWordBits:containsAll(query._includeWordBits) then
      return false
   end
   if not (query._includeBits.count == 0) and not signatureBits:containsAll(query._includeBits) then
      return false
   end
   if not (query._includeAnyWordBits.count == 0) and not signatureWordBits:overlaps(query._includeAnyWordBits) then
      return false
   end
   if not (query._includeAnyBits.count == 0) and not signatureBits:overlaps(query._includeAnyBits) then
      return false
   end
   if not (query._excludeWordBits.count == 0) and not not signatureWordBits:overlaps(query._excludeWordBits) and
      signatureBits:overlaps(query._excludeBits) then

      return false
   end

   return true
end

local function compileMasksFor(components)
   if not components or #components == 0 then
      return Bitset.new(), Bitset.new()
   end

   local maxSignatureIndex = 0
   local maxWordIndex = 0

   for i = 1, #components do
      local component = components[i]
      local signatureIndex = component.signatureIndex or (component.componentId - 1)
      local wordIndex = component.signatureWordIndex or rshift(component.componentId - 1, 5)
      if signatureIndex > maxSignatureIndex then
         maxSignatureIndex = signatureIndex
      end
      if wordIndex > maxWordIndex then
         maxWordIndex = wordIndex
      end
   end

   local signatureBits = Bitset.new(maxSignatureIndex + 1)
   local wordBits = Bitset.new(maxWordIndex + 1)

   for i = 1, #components do
      local component = components[i]
      signatureBits:set(component.signatureIndex or (component.componentId - 1))
      wordBits:set(component.signatureWordIndex or rshift(component.componentId - 1, 5))
   end

   return signatureBits, wordBits
end

local function compileQueryMasks(
   include,
   includeAny,
   exclude)

   local includeBits, includeWordBits = compileMasksFor(include)
   local includeAnyBits, includeAnyWordBits = compileMasksFor(includeAny)
   local excludeBits, excludeWordBits = compileMasksFor(exclude)

   return {
      includeBits = includeBits,
      includeWordBits = includeWordBits,
      includeAnyBits = includeAnyBits,
      includeAnyWordBits = includeAnyWordBits,
      excludeBits = excludeBits,
      excludeWordBits = excludeWordBits,
   }
end





local function queryOnEntitiesAdded(
   self,
   archetype,
   firstRow,
   lastRow,
   count,
   sourceArchetype)

   if not (sourceArchetype and self._archetypeIndices[sourceArchetype]) then
      self.descriptor.onEntitiesAdded(archetype, firstRow, lastRow, count)
   end
end

local function queryOnEntitiesRemoved(
   self,
   archetype,
   firstRow,
   lastRow,
   count,
   destArchetype)

   if not (destArchetype and self._archetypeIndices[destArchetype]) then
      self.descriptor.onEntitiesRemoved(archetype, firstRow, lastRow, count)
   end
end

local function binarySearchInsertPos(arr, value)
   local lo, hi = 1, #arr
   while lo <= hi do
      local mid = floor((lo + hi) / 2)
      if arr[mid] < value then
         lo = mid + 1
      else
         hi = mid - 1
      end
   end
   return lo
end

local function onActivatedWithGroupBy(self, archetype)
   local groupId = self._archetypeGroups[archetype]
   local items = self._activeGroupItems[groupId]
   local indices = self._activeGroupIndices[groupId]

   if not items then
      items = {}
      indices = {}
      self._activeGroupItems[groupId] = items
      self._activeGroupIndices[groupId] = indices

      local groupList = self._activeGroupList
      local groupListIndices = self._activeGroupListIndices
      local pos = binarySearchInsertPos(groupList, groupId)
      table_insert(groupList, pos, groupId)

      for i = pos, #groupList do
         groupListIndices[groupList[i]] = i
      end
   end

   local gidx = #items + 1
   items[gidx] = archetype
   indices[archetype] = gidx
end

function QueryImpl:onActivated(archetype)
   if not self._activeIndices[archetype] then
      local idx = #self._activeItems + 1
      self._activeItems[idx] = archetype
      self._activeIndices[archetype] = idx
      if self._groupBy then
         onActivatedWithGroupBy(self, archetype)
      end
   end
end

local function onDeactivatedWithGroupBy(self, archetype)
   local groupId = self._archetypeGroups[archetype]
   local items = self._activeGroupItems[groupId]
   local indices = self._activeGroupIndices[groupId]
   if not items then return end

   local gidx = indices[archetype]
   if not gidx then return end

   local lastGIdx = #items
   if gidx ~= lastGIdx then
      local last = items[lastGIdx]
      items[gidx] = last
      indices[last] = gidx
   end
   items[lastGIdx] = nil
   indices[archetype] = nil

   if #items == 0 then
      local pos = self._activeGroupListIndices[groupId]
      table_remove(self._activeGroupList, pos)

      local groupList = self._activeGroupList
      local groupListIndices = self._activeGroupListIndices
      for i = pos, #groupList do
         groupListIndices[groupList[i]] = i
      end
      groupListIndices[groupId] = nil

      self._activeGroupItems[groupId] = nil
      self._activeGroupIndices[groupId] = nil
   end
end

function QueryImpl:onDeactivated(archetype)
   local idx = self._activeIndices[archetype]
   if idx then
      local lastIdx = #self._activeItems
      if idx ~= lastIdx then
         local last = self._activeItems[lastIdx]
         self._activeItems[idx] = last
         self._activeIndices[last] = idx
      end
      self._activeItems[lastIdx] = nil
      self._activeIndices[archetype] = nil
   end

   if self._groupBy then
      onDeactivatedWithGroupBy(self, archetype)
   end
end

function QueryImpl:onArchetypeDestroyed(archetype)
   self:onDeactivated(archetype)

   local archetypes = self._archetypes
   local indices = self._archetypeIndices
   local idx = indices[archetype]
   if idx then
      local n = #archetypes
      if idx ~= n then
         local last = archetypes[n]
         archetypes[idx] = last
         indices[last] = idx
      end
      archetypes[n] = nil
      indices[archetype] = nil
   end

   if self._archetypeGroups then self._archetypeGroups[archetype] = nil end
end

function QueryImpl:onNewArchetype(archetype)


   if self._archetypeIndices[archetype] then
      return
   end
   if not archetypeMatches(self, archetype) then
      return
   end

   local descriptor = self.descriptor

   local groupBy = descriptor.groupBy
   if groupBy then
      local groupId = groupBy(archetype)
      self._archetypeGroups[archetype] = groupId
   end

   local archetypes = self._archetypes
   local idx = #archetypes + 1
   archetypes[idx] = archetype
   self._archetypeIndices[archetype] = idx;

   (archetype):addEntityObserver(self)

   local count = archetype.entities[0]
   if count > 0 then
      self:onActivated(archetype)
      local onEntitiesAdded = descriptor.onEntitiesAdded
      if onEntitiesAdded then
         onEntitiesAdded(archetype, 1, count, count)
      end
   end
end





local function subscribeQueryToArchetypeCreated(world, query)
   world:observe(0, builtins.ArchetypeCreated, function(event)
      query:onNewArchetype(event.archetype)
   end)
end

local function newQuery(
   descriptor,
   matchingArchetypes,
   masks,
   world)

   local groupBy = descriptor.groupBy
   local archetypeIndices = {}
   local archetypeGroups = groupBy and {} or nil
   local activeItems = {}
   local activeIndices = {}
   local activeGroupItems = {}
   local activeGroupIndices = {}
   local activeGroupList = {}
   local activeGroupListIndices = {}
   local wantAdd = descriptor.onEntitiesAdded ~= nil
   local wantRemove = descriptor.onEntitiesRemoved ~= nil
   local isTemp = descriptor.temp or false
   local onEntitiesAdded = descriptor.onEntitiesAdded

   local self = setmetatable({
      descriptor = descriptor,
      _world = world,
      _archetypes = matchingArchetypes,
      _archetypeIndices = archetypeIndices,
      _archetypeGroups = archetypeGroups,
      _includeBits = masks.includeBits,
      _includeWordBits = masks.includeWordBits,
      _includeAnyBits = masks.includeAnyBits,
      _includeAnyWordBits = masks.includeAnyWordBits,
      _excludeBits = masks.excludeBits,
      _excludeWordBits = masks.excludeWordBits,
      _activeItems = activeItems,
      _activeIndices = activeIndices,
      _activeGroupItems = activeGroupItems,
      _activeGroupIndices = activeGroupIndices,
      _activeGroupList = activeGroupList,
      _activeGroupListIndices = activeGroupListIndices,
      _groupBy = groupBy,
      onEntitiesAdded = wantAdd and queryOnEntitiesAdded or nil,
      onEntitiesRemoved = wantRemove and queryOnEntitiesRemoved or nil,
   }, QUERY_MT)

   if isTemp then
      if onEntitiesAdded or descriptor.onEntitiesRemoved then
         error("temp queries cannot have onEntitiesAdded / onEntitiesRemoved callbacks")
      end
   else
      for i = 1, #matchingArchetypes do
         local archetype = matchingArchetypes[i];
         (archetype):addEntityObserver(self)
      end
   end

   if groupBy then
      for i = 1, #matchingArchetypes do
         local archetype = matchingArchetypes[i]
         archetypeGroups[archetype] = groupBy(archetype)
      end
   end




   if not isTemp then
      subscribeQueryToArchetypeCreated(world, self)
   end

   for i = 1, #matchingArchetypes do
      local archetype = matchingArchetypes[i]
      archetypeIndices[archetype] = i
      local count = archetype.entities[0]
      if count > 0 then
         self:onActivated(archetype)
         if onEntitiesAdded then
            onEntitiesAdded(archetype, 1, count, count)
         end
      end
   end

   return self
end

return {
   new = newQuery,
   compileMasks = compileQueryMasks,
}
