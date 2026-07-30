local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")
local builtins <const> = require("tecs.internal.builtins")
local StringBuffer <const> = require("string.buffer")
local Bitset <const> = require("tecs.utils.Bitset")
local bit <const> = require("bit")

local table_insert, table_remove <const> = table.insert, table.remove
local floor <const> = math.floor
local rshift <const> = bit.rshift

local STRING_BUFFER <const> = StringBuffer.new()

local type ArchetypeEntityObserver = types.ArchetypeEntityObserver
local type QueryDescriptor = types.Query.Descriptor
local type Query = types.Query
local type QueryCursor = types.Query.Cursor
local type Archetype = types.Archetype
local type ArchetypeInternal = internal.ArchetypeInternal
local type ComponentInternal = internal.ComponentInternal
local type CompiledQueryMasks = internal.CompiledQueryMasks
local type World = types.World
local type WorldImpl = internal.WorldImpl

-------------------------------------------------------------------------------
-- Query Implementation
-------------------------------------------------------------------------------

local record QueryImpl is Query, ArchetypeEntityObserver
    _world: WorldImpl

    _archetypes: {Archetype}
    _archetypeIndices: {Archetype: integer}
    _archetypeGroups: {Archetype: integer}
    _includeBits: Bitset
    _includeWordBits: Bitset
    _includeAnyBits: Bitset
    _includeAnyWordBits: Bitset
    _excludeBits: Bitset
    _excludeWordBits: Bitset

    -- Non-empty archetypes currently visible to iteration.
    _activeItems: {Archetype}
    _activeIndices: {Archetype: integer}
    _activeGroupItems: {integer: {Archetype}}
    _activeGroupIndices: {integer: {Archetype: integer}}
    _activeGroupList: {integer}
    _activeGroupListIndices: {integer: integer}

    -- Start state for group() iteration; the group id only exists at the
    -- group() call, so the first step reads it from here. Resume steps
    -- derive their position from the loop control variable instead.
    _iterGroupSelected: {Archetype}

    _groupBy: function(Archetype): integer
end

local record QueryCursorImpl is QueryCursor
    _query: QueryImpl
    _open: boolean
    _closed: boolean
    _prepared: boolean
    _selectedGroup: {Archetype}
end

local QUERY_MT <const>: metatable<QueryImpl> = {__index = QueryImpl}
local QUERY_CURSOR_MT <const>: metatable<QueryCursorImpl> = {__index = QueryCursorImpl}

-------------------------------------------------------------------------------
-- Iteration
-------------------------------------------------------------------------------

-- Iterator steps derive their resume position from the loop control
-- variable (the current archetype or group id) through the active reverse
-- indices, so nested or interleaved iteration of one query stays correct.
-- The lookups are stable mid-loop: iteration holds a query scope, so
-- structural changes stay deferred until the scope pops.

local function simpleIterStep(self: QueryImpl, var: any): (Archetype, integer, any)
    local idx: integer
    if var == nil then
        idx = 1
        self._world:_pushQueryScope()
    else
        idx = self._activeIndices[var as Archetype] + 1
    end
    local archetype = self._activeItems[idx]
    if not archetype then
        self._world:_popQueryScope()
        return
    end
    return archetype, archetype.entities[0] as integer, archetype.entities
end

local function groupedIterStep(self: QueryImpl, var: any): (Archetype, integer, any)
    local groupList = self._activeGroupList
    local groupItems = self._activeGroupItems
    local gi, ai: integer, integer
    if var == nil then
        gi, ai = 1, 1
        self._world:_pushQueryScope()
    else
        local arch = var as Archetype
        local groupId = self._archetypeGroups[arch]
        gi = self._activeGroupListIndices[groupId]
        ai = self._activeGroupIndices[groupId][arch] + 1
    end

    while gi <= #groupList do
        local items = groupItems[groupList[gi]]
        if items and ai <= #items then
            local archetype = items[ai]
            return archetype, archetype.entities[0] as integer, archetype.entities
        end
        gi = gi + 1
        ai = 1
    end
    self._world:_popQueryScope()
end

local function openCursor(self: QueryCursorImpl): boolean
    if self._closed then
        return false
    end
    if not self._open then
        self._query._world:_pushQueryScope()
        self._open = true
    end
    return true
end

function QueryCursorImpl:close()
    if self._closed then
        return
    end
    self._closed = true
    if self._open then
        self._open = false
        self._query._world:_popQueryScope()
    end
end

local function cursorIterStep(self: QueryCursorImpl, var: any): (Archetype, integer, any)
    if not openCursor(self) then
        return
    end

    local query = self._query
    local idx: integer
    if var == nil then
        idx = 1
    else
        idx = query._activeIndices[var as Archetype] + 1
    end

    local archetype = query._activeItems[idx]
    if not archetype then
        self:close()
        return
    end
    return archetype, archetype.entities[0] as integer, archetype.entities
end

local function cursorGroupedIterStep(self: QueryCursorImpl, var: any): (Archetype, integer, any)
    if not openCursor(self) then
        return
    end

    local query = self._query
    local groupList = query._activeGroupList
    local groupItems = query._activeGroupItems
    local gi, ai: integer, integer
    if var == nil then
        gi, ai = 1, 1
    else
        local arch = var as Archetype
        local groupId = query._archetypeGroups[arch]
        gi = query._activeGroupListIndices[groupId]
        ai = query._activeGroupIndices[groupId][arch] + 1
    end

    while gi <= #groupList do
        local items = groupItems[groupList[gi]]
        if items and ai <= #items then
            local archetype = items[ai]
            return archetype, archetype.entities[0] as integer, archetype.entities
        end
        gi = gi + 1
        ai = 1
    end
    self:close()
end

local function cursorGroupsStep(self: QueryCursorImpl, prev: any): integer
    if not openCursor(self) then
        return
    end

    local query = self._query
    local i: integer
    if prev == nil then
        i = 1
    else
        i = query._activeGroupListIndices[prev as integer] + 1
    end
    local list = query._activeGroupList
    if i <= #list then
        return list[i]
    end
    self:close()
    return nil
end

local function cursorGroupStep(self: QueryCursorImpl, prev: any): (Archetype, integer, {integer})
    if not openCursor(self) then
        return
    end

    local items = self._selectedGroup
    local i: integer
    if prev == nil then
        i = 1
    else
        local query = self._query
        local arch = prev as Archetype
        local groupId = query._archetypeGroups[arch]
        i = query._activeGroupIndices[groupId][arch] + 1
    end
    if items and i <= #items then
        local archetype = items[i]
        return archetype, archetype.entities[0] as integer, archetype.entities as {integer}
    end
    self:close()
end

local function prepareCursor(self: QueryCursorImpl)
    if self._closed then
        error("query cursor is closed")
    end
    if self._prepared then
        error("query cursor already has a traversal")
    end
    self._prepared = true
end

function QueryCursorImpl:iter(): (QueryCursor.IterFn, QueryCursor, any)
    prepareCursor(self)
    if self._query._archetypeGroups then
        return cursorGroupedIterStep as QueryCursor.IterFn, self, nil
    else
        return cursorIterStep as QueryCursor.IterFn, self, nil
    end
end

function QueryCursorImpl:groups(): (QueryCursor.GroupsIterFn, QueryCursor, any)
    prepareCursor(self)
    return cursorGroupsStep, self, nil
end

function QueryCursorImpl:group(groupId: integer): (QueryCursor.GroupIterFn, QueryCursor, any)
    prepareCursor(self)
    self._selectedGroup = self._query._activeGroupItems[groupId]
    return cursorGroupStep, self, nil
end

-------------------------------------------------------------------------------
-- Formatting
-------------------------------------------------------------------------------

local function formatQuery(query: QueryImpl): string
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

-------------------------------------------------------------------------------
-- Grouping
-------------------------------------------------------------------------------

function QueryImpl:iter(): (Query.IterFn, Query, any)
    if self._archetypeGroups then
        return groupedIterStep as Query.IterFn, self, nil
    else
        return simpleIterStep as Query.IterFn, self, nil
    end
end

function QueryImpl:newCursor(): QueryCursor
    local cursor: QueryCursorImpl = setmetatable(
        {
            _query = self,
            _open = false,
            _closed = false,
            _prepared = false,
        },
        QUERY_CURSOR_MT
    )
    return cursor
end

function QueryImpl:getGroup(archetype: Archetype): integer
    if not self._archetypeGroups then
        return nil
    else
        return self._archetypeGroups[archetype]
    end
end

local function groupsNext(self: QueryImpl, prev: any): integer
    local i: integer
    if prev == nil then
        i = 1
        self._world:_pushQueryScope()
    else
        i = self._activeGroupListIndices[prev as integer] + 1
    end
    local list = self._activeGroupList
    if i <= #list then
        return list[i]
    end
    self._world:_popQueryScope()
    return nil
end

local function groupNext(self: QueryImpl, prev: any): (Archetype, integer, {integer})
    local items: {Archetype}
    local i: integer
    if prev == nil then
        items = self._iterGroupSelected
        if not items then
            -- First-call with no matching group: still needs a
            -- balanced push/pop pair so we don't leave dangling
            -- scope state.
            self._world:_pushQueryScope()
            self._world:_popQueryScope()
            return
        end
        self._world:_pushQueryScope()
        i = 1
    else
        local arch = prev as Archetype
        local groupId = self._archetypeGroups[arch]
        items = self._activeGroupItems[groupId]
        i = self._activeGroupIndices[groupId][arch] + 1
    end
    if i <= #items then
        local archetype = items[i]
        return archetype, archetype.entities[0] as integer, archetype.entities
    end
    self._world:_popQueryScope()
end

function QueryImpl:groups(): (Query.GroupsIterFn, Query, any)
    return groupsNext, self, nil
end

function QueryImpl:group(groupId: integer): (Query.GroupIterFn, Query, any)
    self._iterGroupSelected = self._activeGroupItems[groupId]
    return groupNext, self, nil
end

function QueryImpl:count(): integer
    local total = 0
    if self._archetypeGroups then
        local groupList = self._activeGroupList
        for gi = 1, #groupList do
            local items = self._activeGroupItems[groupList[gi]]
            for ai = 1, #items do
                total = total + (items[ai].entities[0] as integer)
            end
        end
    else
        local items = self._activeItems
        for i = 1, #items do
            total = total + (items[i].entities[0] as integer)
        end
    end
    return total
end

function QueryImpl:getGroupCount(groupId: integer): integer
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

-------------------------------------------------------------------------------
-- Matching
-------------------------------------------------------------------------------

local function archetypeMatches(query: QueryImpl, archetype: Archetype): boolean
    local arch = archetype as ArchetypeInternal
    local signatureWordBits = arch.signatureWordBits
    local signatureBits = arch.signatureBits

    if not signatureWordBits:containsAll(query._includeWordBits) then
        return false
    end
    if not query._includeBits:isEmpty() and not signatureBits:containsAll(query._includeBits) then
        return false
    end
    if not query._includeAnyWordBits:isEmpty() and signatureWordBits:disjoint(query._includeAnyWordBits) then
        return false
    end
    if not query._includeAnyBits:isEmpty() and signatureBits:disjoint(query._includeAnyBits) then
        return false
    end
    if
        not query._excludeWordBits:isEmpty()
        and not signatureWordBits:disjoint(query._excludeWordBits)
        and signatureBits:overlaps(query._excludeBits)
    then
        return false
    end

    return true
end

local function compileMasksFor(components?: {types.components.Component}): Bitset, Bitset
    if not components or #components == 0 then
        return Bitset.new(), Bitset.new()
    end

    local maxSignatureIndex = 0
    local maxWordIndex = 0

    for i = 1, #components do
        local component = components[i] as ComponentInternal
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
        local component = components[i] as ComponentInternal
        signatureBits:set(component.signatureIndex or (component.componentId - 1))
        wordBits:set(component.signatureWordIndex or rshift(component.componentId - 1, 5))
    end

    return signatureBits, wordBits
end

local function compileQueryMasks(
    include?: {types.components.Component},
    includeAny?: {types.components.Component},
    exclude?: {types.components.Component}
): CompiledQueryMasks
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

-------------------------------------------------------------------------------
-- ArchetypeEntityObserver implementation
-------------------------------------------------------------------------------

local function queryOnEntitiesAdded(
    self: QueryImpl,
    archetype: Archetype,
    firstRow: integer,
    lastRow: integer,
    count: integer,
    sourceArchetype?: Archetype
)
    if not (sourceArchetype and self._archetypeIndices[sourceArchetype]) then
        self.descriptor.onEntitiesAdded(archetype, firstRow, lastRow, count)
    end
end

local function queryOnEntitiesRemoved(
    self: QueryImpl,
    archetype: Archetype,
    firstRow: integer,
    lastRow: integer,
    count: integer,
    destArchetype?: Archetype
)
    if not (destArchetype and self._archetypeIndices[destArchetype]) then
        self.descriptor.onEntitiesRemoved(archetype, firstRow, lastRow, count)
    end
end

local function binarySearchInsertPos(arr: {integer}, value: integer): integer
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

local function onActivatedWithGroupBy(self: QueryImpl, archetype: Archetype)
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

function QueryImpl:onActivated(archetype: Archetype)
    if not self._activeIndices[archetype] then
        local idx = #self._activeItems + 1
        self._activeItems[idx] = archetype
        self._activeIndices[archetype] = idx
        if self._groupBy then
            onActivatedWithGroupBy(self, archetype)
        end
    end
end

local function onDeactivatedWithGroupBy(self: QueryImpl, archetype: Archetype)
    local groupId = self._archetypeGroups[archetype]
    local items = self._activeGroupItems[groupId]
    local indices = self._activeGroupIndices[groupId]
    if not items then
        return
    end

    local gidx = indices[archetype]
    if not gidx then
        return
    end

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

function QueryImpl:onDeactivated(archetype: Archetype)
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

function QueryImpl:onArchetypeDestroyed(archetype: Archetype)
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

    if self._archetypeGroups then
        self._archetypeGroups[archetype] = nil
    end
end

function QueryImpl:onNewArchetype(archetype: Archetype)
    -- Membership guard: tolerate any delivery ordering without
    -- double-adding an archetype.
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
    self._archetypeIndices[archetype] = idx

    (archetype as ArchetypeInternal):addEntityObserver(self)

    local count = archetype.entities[0]
    if count > 0 then
        self:onActivated(archetype)
        local onEntitiesAdded = descriptor.onEntitiesAdded
        if onEntitiesAdded then
            onEntitiesAdded(archetype, 1, count, count)
        end
    end
end

-------------------------------------------------------------------------------
-- Query factory
-------------------------------------------------------------------------------

local function subscribeQueryToArchetypeCreated(world: World, query: QueryImpl)
    world:observe(
        0,
        builtins.ArchetypeCreated,
        function(event: builtins.ArchetypeCreated) query:onNewArchetype(event.archetype) end
    )
end

local function newQuery(
    descriptor: QueryDescriptor, matchingArchetypes: {Archetype}, masks: CompiledQueryMasks, world: World
): Query
    local groupBy = descriptor.groupBy
    local archetypeIndices: {Archetype: integer} = {}
    local archetypeGroups: {Archetype: integer} = groupBy and {} or nil
    local activeItems: {Archetype} = {}
    local activeIndices: {Archetype: integer} = {}
    local activeGroupItems: {integer: {Archetype}} = {}
    local activeGroupIndices: {integer: {Archetype: integer}} = {}
    local activeGroupList: {integer} = {}
    local activeGroupListIndices: {integer: integer} = {}
    local wantAdd = descriptor.onEntitiesAdded ~= nil
    local wantRemove = descriptor.onEntitiesRemoved ~= nil
    local isTemp = descriptor.temp or false
    local onEntitiesAdded = descriptor.onEntitiesAdded

    local self: QueryImpl = setmetatable(
        {
            descriptor = descriptor,
            _world = world as WorldImpl,
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
        },
        QUERY_MT
    )

    if isTemp then
        if onEntitiesAdded or descriptor.onEntitiesRemoved then
            error("temp queries cannot have onEntitiesAdded / onEntitiesRemoved callbacks")
        end
    else
        for i = 1, #matchingArchetypes do
            local archetype = matchingArchetypes[i]
            (archetype as ArchetypeInternal):addEntityObserver(self)
        end
    end

    if groupBy then
        for i = 1, #matchingArchetypes do
            local archetype = matchingArchetypes[i]
            archetypeGroups[archetype] = groupBy(archetype)
        end
    end

    -- Subscribe before the initial callbacks run: an onEntitiesAdded
    -- callback can spawn an entity whose new archetype must reach this
    -- query; the membership guard in onNewArchetype absorbs overlap.
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
