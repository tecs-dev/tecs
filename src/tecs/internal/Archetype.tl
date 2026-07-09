local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")
local frameworkbehavior <const> = require("tecs.internal.frameworkbehavior")
local ffi <const> = require("tecs.internal.ffi")
local Bitset <const> = require("tecs.utils.Bitset")
local RelationshipStore <const> = require("tecs.internal.RelationshipStore")
local cffi <const> = require("ffi")
local bit <const> = require("bit")
local table_new <const> = require("table.new")
local table_clear <const> = require("table.clear")
local table_move <const> = table.move

local table_insert, table_concat <const> = table.insert, table.concat
local rawget <const> = rawget
local ensureCapacityDouble, setDoubleArraySize <const> = ffi.ensureCapacityDouble, ffi.setDoubleArraySize
local rshift <const> = bit.rshift

local type Component = types.components.Component
local type Relationship = types.components.Relationship
local type ArchetypeEntityObserver = types.ArchetypeEntityObserver
local type ComponentInternal = internal.ComponentInternal
local type MovePlan = internal.MovePlan
local type ArchetypeIndexInternal = internal.ArchetypeIndexInternal
local type ArchetypeInternal = internal.ArchetypeInternal

-- The auto-incrementing ID for archetypes.
local AUTO_ID = 0

local record Archetype is ArchetypeInternal
    onDespawnComponents: {Component}
    onDespawnCount: integer

    withComponent: function(self, component: Component, archetypeIndex: ArchetypeIndexInternal): ArchetypeInternal
    withoutComponent: function(self, component: Component, archetypeIndex: ArchetypeIndexInternal): ArchetypeInternal

    _observers: {ArchetypeEntityObserver}

    -- Per-archetype, per-component dirty bitset, keyed by 1-based
    -- column index (matches `columnIndexByComponent`). A bit is set
    -- by `getMut`, `set`, structural changes (spawn/move-in/swap-pop),
    -- or explicit `markComponentDirty`. Cleared by `world:update` at
    -- end of frame via `clearDirtyComponents`.
    _componentDirty: Bitset
    -- True once markAllComponentsDirty ran this frame; cleared with the
    -- dirty bits so repeat calls short-circuit.
    _allDirty: boolean
    -- Dense relationship instance components keyed by container; nil when
    -- the archetype carries none. Built once at construction.
    _relInstancesByContainer: {Component: {Component}}

    _dirtySet: {Archetype: boolean}

    movePlansOut: {ArchetypeInternal: any}

    -- Layout / storage
    signatureBits: Bitset
    signatureWordBits: Bitset
    columnArray: {{Component}}
    columnIndexByComponent: {Component: integer}
    columnsCount: integer
    dataColumnsCount: integer
    capacity: integer

    -- Observer registration / counters
    observerCount: integer
    hasRemoveObservers: integer
    hasAddObservers: integer
    hasMoveObservers: integer
    addEntityObserver: function(self, observer: ArchetypeEntityObserver)

    -- Transaction / drain staging state
    isEphemeral: boolean
    pendingWrites: integer
    pendingDespawn: {integer}
    pendingDespawnCount: integer
    pendingClear: boolean
    pendingSpawnIds: {integer}
    pendingSpawnCount: integer
    pendingValues: {integer: {any}}
    pendingValueSlots: {integer}
    pendingValueCount: integer
    pendingScalarTypes: {integer: {Component}}
    pendingScalarValues: {integer: {any}}
    hasScalarPending: boolean
    hasPendingDespawns: boolean
    hasPendingSpawns: boolean
    hasPendingMoveOut: boolean
    dirtyQueuedEpoch: integer
    pendingBundleDrains: {any}
    pendingBundleDrainCount: integer
    batchSpawnQueue: {any}
    batchSpawnQueueCount: integer
    batchSpawnAtQueue: {any}
    batchSpawnAtQueueCount: integer

    -- Archetype graph edges
    addEdges: {Component: ArchetypeInternal}
    removeEdges: {Component: ArchetypeInternal}

    -- Cache / invalidation
    generation: integer

    -- Mutation / drain methods
    reserveCapacity: function(self, targetRows: integer)
    removeEntity: function(self, row: integer, destArchetype?: Archetype): integer, integer
    onRowsAdded: function(self, rowStart: integer, count: integer, sourceArchetype?: Archetype)
    notifyAdded: function(self, rowStart: integer, count: integer, sourceArchetype?: Archetype)
    notifyRemoved: function(self, rowStart: integer, count: integer, destArchetype?: Archetype)
    notifyDeactivatedExternal: function(self)
    notifyArchetypeDestroyed: function(self)
    clearEntities: function(self)
    compact: function(self)
    resetPending: function(self)
    appendPendingValue: function(self, slot: integer, value: any, vals?: {any})
    getPendingValues: function(self, slot: integer): {any}
    findPendingValue: function(self, slot: integer, componentType: Component): any
    movePendingValuesTo: function(self, dst: Archetype, slot: integer)
end

local ARCHETYPE_MT <const>: metatable<Archetype> = {
    __index = Archetype,
    __tostring = function(self: Archetype): string
        local compList = self.componentList
        local n = self.columnsCount
        local buf: {string} = {}
        table_insert(buf, "Archetype([")
        for i = 1, n do
            if i > 1 then
                table_insert(buf, ", ")
            end
            table_insert(buf, tostring(compList[i]))
        end
        table_insert(buf, "])")
        return table_concat(buf)
    end
}

--- Read-only column access. Returns the row-indexed column for the
--- given component type, or nil if the archetype doesn't carry it.
--- Does NOT mark the component dirty. Pair with `getMut` when
--- you intend to write.
---
--- Sparse relationships return a row-indexed proxy that resolves
--- through the world's relationship store; the proxy lives on the
--- archetype's raw table (set by `Archetype.new`). Dense components
--- return the underlying FFI cdata array or table from
--- `self.columns`.
function Archetype:get<T is Component>(component: T): {T}
    local proxy = rawget(self as table, component)
    if proxy ~= nil then return proxy as {T} end
    return rawget(self.columns, component) as {T}
end

--- Mutable column access. Returns the row-indexed column AND marks
--- the component dirty on this archetype, signalling incremental-sync
--- consumers (renderer shadow buffers, snapshot diffs) that this column's
--- bytes are about to change. Idempotent -- repeated calls are O(1)
--- after the first.
function Archetype:getMut<T is Component>(component: T): {T}
    local column = rawget(self.columns, component)
    if column then
        local idx = self.columnIndexByComponent[component]
        if idx and not self._componentDirty:get(idx) then
            self._componentDirty:set(idx)
            self._dirtySet[self] = true
        end
    end
    local proxy = rawget(self as table, component)
    if proxy ~= nil then return proxy as {T} end
    return column as {T}
end

-------------------------------------------------------------------------------
-- Archetype edge graph
-- Based on https://ajmmertens.medium.com/building-an-ecs-2-archetypes-and-vectorization-fe21690805f9
-------------------------------------------------------------------------------

function Archetype:withComponent(component: Component, archetypeIndex: ArchetypeIndexInternal): ArchetypeInternal
    if self.columns[component] then
        return self
    end

    local cached = self.addEdges[component] as Archetype
    if cached then
        return cached
    end

    local n = self.columnsCount
    local dest = table_new(n + 1, 0) as {Component}
    local componentList = self.componentList
    table_move(componentList, 1, n, 1, dest)
    dest[n + 1] = component

    local idx = archetypeIndex as {string:any}
    local getOrCreate = idx.getOrCreate as function(any, {Component}): Archetype
    local target = getOrCreate(idx, dest)
    self.addEdges[component] = target
    target.removeEdges[component] = self
    return target
end

function Archetype:withoutComponent(component: Component, archetypeIndex: ArchetypeIndexInternal): ArchetypeInternal
    if not self.columns[component] then
        return self
    end

    local cached = self.removeEdges[component] as Archetype
    if cached then
        return cached
    end

    local n = self.columnsCount
    local dest = table_new(n - 1, 0) as {Component}
    local componentList = self.componentList
    local j = 0
    for i = 1, n do
        local c = componentList[i]
        if c ~= component then
            j = j + 1
            dest[j] = c
        end
    end

    local idx = archetypeIndex as {string:any}
    local getOrCreate = idx.getOrCreate as function(any, {Component}): Archetype
    local target = getOrCreate(idx, dest)
    self.removeEdges[component] = target
    target.addEdges[component] = self
    return target
end

-------------------------------------------------------------------------------
-- Archetype move plans
-------------------------------------------------------------------------------

--- Build or reuse the cached `MovePlan` for `dstArch`.
function Archetype:getMovePlanTo(dstArch: ArchetypeInternal): MovePlan
    local plans = self.movePlansOut as {ArchetypeInternal: MovePlan}
    local plan = plans[dstArch]
    if plan and plan.srcGen == self.generation and plan.dstGen == dstArch.generation then
        return plan
    end

    local sourceColumns = self.columns
    local sourceColumnIndex = self.columnIndexByComponent as {types.components.Component: integer}
    local destColumnArray = dstArch.columnArray
    local destComponentList = dstArch.componentList
    local srcCols: {{types.components.Component}} = {}
    local dstCols: {{types.components.Component}} = {}
    local structSizes: {integer} = {}
    local comps: {types.components.Component} = {}
    local srcColIndices: {integer} = {}
    local dstColIndices: {integer} = {}
    local count = 0
    for j = 1, dstArch.columnsCount do
        local comp = destComponentList[j]
        local sourceCol = sourceColumns[comp]
        if sourceCol and (comp as ComponentInternal).storageType ~= "tag" then
            count = count + 1
            srcCols[count] = sourceCol
            dstCols[count] = destColumnArray[j]
            structSizes[count] = (comp as ComponentInternal).structSize or 0
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

-------------------------------------------------------------------------------
-- Relationships
-------------------------------------------------------------------------------

-- Lookups walk the construction-time instance list and resolve columns
-- per call: bulk moves and FFI growth swap column identities, so column
-- references must not be cached.

function Archetype:forEachRelationship<T is Relationship>(relContainer: T, row: integer, callback: function(T))
    local instances = self._relInstancesByContainer
    local list = instances and instances[relContainer as Component]
    if not list then return end
    local columns = self.columns
    for i = 1, #list do
        local col = columns[list[i]] as {Component}
        callback(col[row] as T)
    end
end

function Archetype:getFirstRelationship<T is Relationship>(relContainer: T, row: integer): T
    local instances = self._relInstancesByContainer
    local list = instances and instances[relContainer as Component]
    if not list then return nil end
    local col = self.columns[list[1]] as {Component}
    return col[row] as T
end

-------------------------------------------------------------------------------
-- observer notification
-------------------------------------------------------------------------------

function Archetype:addEntityObserver(observer: ArchetypeEntityObserver)
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

local function notifyMove(self: Archetype, entity: integer, fromRow: integer, toRow: integer)
    local observers = self._observers
    for i = 1, self.observerCount do
        local obs = observers[i]
        local cb = obs.onEntityMove
        if cb then cb(obs, self, entity, fromRow, toRow) end
    end
end

local function notifyActivated(self: Archetype)
    local observers = self._observers
    for i = 1, self.observerCount do
        local obs = observers[i]
        local cb = obs.onActivated
        if cb then cb(obs, self) end
    end
end

local function notifyDeactivated(self: Archetype)
    local observers = self._observers
    for i = 1, self.observerCount do
        local obs = observers[i]
        local cb = obs.onDeactivated
        if cb then cb(obs, self) end
    end
end

function Archetype:onRowsAdded(
    rowStart: integer,
    count: integer,
    sourceArchetype?: Archetype
)
    if count <= 0 then return end
    -- Newly-added rows are by definition new bytes for every column on
    -- this archetype, so consumers gated on per-component dirty
    -- (shadow buffers, incremental serialization, reactive systems) need to
    -- see every column as dirty.
    self:markAllComponentsDirty()
    if self.observerCount > 0 then
        self:notifyAdded(rowStart, count, sourceArchetype)
    end
end

function Archetype:notifyAdded(rowStart: integer, count: integer, sourceArchetype?: Archetype)
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

function Archetype:notifyRemoved(rowStart: integer, count: integer, destArchetype?: Archetype)
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

-------------------------------------------------------------------------------
-- Entity mutation methods
--
-- These methods assume the caller already validated entity IDs,
-- component types, and row indices.
--
-- Observer notification contract:
--   notifyAdded(rowStart, count)   -- after rows are added to the archetype
--   notifyRemoved(rowStart, count) -- before rows are removed from the archetype
--   notifyMove(entity, from, to)   -- after an entity's row changes due to compaction
--   notifyActivated()              -- when entity count transitions from 0 → non-zero (fired from notifyAdded)
--   notifyDeactivated()            -- when entity count transitions from non-zero → 0
--
-- Queries depend on activated/deactivated to maintain active archetype lists.
-------------------------------------------------------------------------------

--- Reserve column capacity for `targetRows`.
function Archetype:reserveCapacity(targetRows: integer)
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
        local storage = (comp as ComponentInternal).storage as {string:any}
        if storage.ensureCapacity then
            local ensureFn = storage.ensureCapacity as function(any, {Component}, integer): {Component}
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

function Archetype:removeEntity(row: integer, destArchetype?: Archetype): integer, integer
    local entities = self.entities as {integer}
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

        -- No swap-pop rewrite happened, but the live row range shrank;
        -- consumers gated on component dirty (shadow uploads, cached
        -- shadow masks, incremental serialization) must observe
        -- removals just like moves.
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
            local column = columnArray[j] as {any}
            column[luaRow] = column[lastIndex]
        end

        -- Swap-pop rewrote the bytes at `luaRow` with the moved
        -- entity's column data. Mark every component dirty so
        -- consumers (shadow buffers, incremental serialization) see the
        -- mutation. Observer notification remains gated below.
        self:markAllComponentsDirty()

        if self.hasMoveObservers > 0 then
            notifyMove(self, movedEntityId, lastIndex - 1, row)
        end

        return movedEntityId, lastIndex - 1
    end
end

--- Clear all entity rows while keeping the archetype structure intact.
function Archetype:clearEntities()
    local hadEntities = (self.entities[0] as integer) > 0
    local hasObservers = self.observerCount > 0
    if hadEntities and hasObservers then
        self:notifyRemoved(0, self.entities[0] as integer, nil)
    end
    ffi.setDoubleArraySize(self.entities, 0)
    for j = 1, self.columnsCount do
        local comp = self.componentList[j] as ComponentInternal
        local col = self.columnArray[j]
        local storage = comp.storage as {string:any}
        (storage.clear as function(any, any))(storage, col)
    end
    self._componentDirty:clearAll()
    if hadEntities and hasObservers then
        notifyDeactivated(self)
    end
end

--- Shrink storage to fit the current entity count.
function Archetype:compact()
    local count = self.entities[0] as integer
    local anySwapped = false

    local newEntities = ffi.adjustCapacityDouble(self.entities, count)
    if newEntities ~= self.entities then
        self.entities = newEntities
        anySwapped = true
    end

    for j = 1, self.columnsCount do
        local comp = self.componentList[j] as ComponentInternal
        local compStorage = comp.storage as {string:any}
        local adjust = compStorage.adjustCapacity as function(any, {Component}, integer): {Component}
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

function Archetype:getPendingValues(slot: integer): {any}
    return self.pendingValues[slot]
end

function Archetype:appendPendingValue(slot: integer, value: any, newVals?: {any})
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

function Archetype:findPendingValue(slot: integer, componentType: Component): any
    local vals = self.pendingValues[slot]
    if not vals then return nil end
    for i = #vals, 1, -1 do
        local inst = vals[i]
        if ((inst as {string:any}).componentType as Component) == componentType then
            return inst
        end
    end
    return nil
end

function Archetype:movePendingValuesTo(dst: Archetype, slot: integer)
    local vals = self.pendingValues[slot]
    if not vals then return end
    self.pendingValues[slot] = nil
    dst.pendingValues[slot] = vals
    local count = dst.pendingValueCount + 1
    dst.pendingValueCount = count
    dst.pendingValueSlots[count] = slot
end

-------------------------------------------------------------------------------
-- Component-dirty tracking (per-archetype, per-component)
--
-- A bit is set when a column's bytes change (or are about to via
-- `getMut`), and cleared by `world:update` at end of frame. The
-- archetype is registered in `_dirtySet` whenever any component bit
-- is set so the world's clear loop visits it.
-------------------------------------------------------------------------------

--- True if the given component's column on this archetype is marked dirty.
function Archetype:isComponentDirty(component: Component): boolean
    local idx = self.columnIndexByComponent[component]
    if not idx then return false end
    return self._componentDirty:get(idx)
end

--- True if any component on this archetype is currently marked dirty.
--- Useful for bulk re-sync paths that don't track dirty granularity
--- below the archetype level.
function Archetype:anyComponentDirty(): boolean
    return not self._componentDirty:isEmpty()
end

--- Mark a single component dirty. No-op if the archetype doesn't
--- carry the component or the bit is already set.
function Archetype:markComponentDirty(component: Component)
    local idx = self.columnIndexByComponent[component]
    if not idx then return end
    if not self._componentDirty:get(idx) then
        self._componentDirty:set(idx)
        self._dirtySet[self] = true
    end
end

--- Mark every component on this archetype dirty. Used by spawn,
--- archetype move-in, and swap-pop, where every column's bytes have
--- changed for at least one row.
function Archetype:markAllComponentsDirty()
    -- Runs per swap-pop and per move-in; after the first call in a frame
    -- every later call is a guaranteed no-op, so short-circuit on a flag
    -- instead of re-walking the bitset per entity.
    if self._allDirty then return end
    self._allDirty = true
    local bits = self._componentDirty
    local n = self.columnsCount
    for i = 1, n do
        if not bits:get(i) then bits:set(i) end
    end
    if n > 0 then self._dirtySet[self] = true end
end

--- Clear every component-dirty bit. Called by `world:update` at end
--- of frame for each archetype in the dirty set.
function Archetype:clearDirtyComponents()
    self._allDirty = false
    self._componentDirty:clearAll()
end

--- Iterate components currently marked dirty on this archetype.
function Archetype:dirtyComponents(): function(): Component
    local componentList = self.componentList
    local bits = self._componentDirty
    local i = 1
    local n = self.columnsCount
    return function(): Component
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

--- Set a component value at a row and mark it dirty.
function Archetype:set<C is Component>(row: integer, value: C)
    local valueAny = value as {string: any}
    local componentType = valueAny.componentType as C
    if not componentType then
        error("Component value must have a componentType field")
    end

    local column = self.columns[componentType]
    if not column then
        error("Archetype does not have component: " .. tostring(componentType))
    end

    local storage = (componentType as ComponentInternal).storage
    local storageAny = storage as {string: any}

    if storageAny._ffiConstructor and storageAny._sizeof then
        local dest = (column as {any})[row] as cffi.CData
        cffi.copy(dest, value as cffi.CData, storageAny._sizeof as integer)
    else
        (column as {any})[row] = value
    end

    self:markComponentDirty(componentType)
end

-------------------------------------------------------------------------------
-- Constructor
-------------------------------------------------------------------------------

--- Row-indexed proxy for sparse relationship columns.
local function createSparseColumnProxy(archetypeTable: table, store: RelationshipStore): {Component}
    local proxy: {Component} = {}
    local mt: metatable<{Component}> = {
        __index = function(_self: {Component}, row: integer): Component
            local entities = (archetypeTable as Archetype).entities
            local entityId = (entities as {integer})[row]
            return store:get(entityId) as Component
        end,
        __newindex = function()
            error("Cannot write to sparse column via row index. Use world:set() instead.")
        end,
    }
    return setmetatable(proxy, mt)
end

--- Construct an archetype for a sorted component list.
function Archetype.new(
    components: {Component},
    dirtySet: {Archetype: boolean},
    relationshipStoreGetter?: function(Component): any
): Archetype
    AUTO_ID = AUTO_ID + 1
    local columnsCount = #components
    local columns = table_new(0, columnsCount) as {Component:{Component}}
    local componentList: {Component} = table_new(columnsCount, 0) as {Component}
    local columnArray: {{Component}} = table_new(columnsCount, 0) as {{Component}}
    local columnIndexByComponent = table_new(0, columnsCount) as {Component: integer}
    local signatureBits = Bitset.new()
    local signatureWordBits = Bitset.new()

    local isEphemeral = false

    local dataColumnsCount = 0
    for i = 1, columnsCount do
        if (components[i] as ComponentInternal).storageType ~= "tag" then
            dataColumnsCount = dataColumnsCount + 1
        end
    end

    local onDespawnComponents: {Component} = {}
    local onDespawnCount = 0
    local relInstancesByContainer: {Component: {Component}} = nil

    local nextDataIdx = 1
    local nextTagIdx = dataColumnsCount + 1
    for i = 1, columnsCount do
        local comp = components[i]
        local compI = comp as ComponentInternal
        local idx: integer
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
        if frameworkbehavior.hasBits(comp, frameworkbehavior.NeedsDespawn) then
            onDespawnCount = onDespawnCount + 1
            onDespawnComponents[onDespawnCount] = comp
        end

        -- Dense relationship instance columns per container, so lookups
        -- avoid a pairs() scan of every column. The column SET is
        -- immutable, so this is build-once.
        local rc = compI.relationshipType
        if rc ~= nil and (rc as Component) ~= comp then
            if relInstancesByContainer == nil then
                relInstancesByContainer = {}
            end
            local list = relInstancesByContainer[rc as Component]
            if not list then
                list = {}
                relInstancesByContainer[rc as Component] = list
            end
            list[#list + 1] = comp
        end
    end

    local self: Archetype = {
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
        _dirtySet = dirtySet as {Archetype: boolean},
        dirtyQueuedEpoch = 0,
    }

    for i = 1, columnsCount do
        local comp = componentList[i]
        local compI = comp as ComponentInternal
        local compStorage = compI.storage as {string:any}
        local createColumn = compStorage.createColumn as function(any, integer): {Component}
        local store = createColumn(compStorage, 0)
        columns[comp] = store
        columnArray[i] = store

        -- Sparse relationships store their per-row data in the world's
        -- relationship store; column writes through `columns[comp]`
        -- (instant/deferred set, applyPendingVals, etc.) silently land
        -- in the empty `store` and the sparse-set fast path routes the
        -- value into the relationship store instead. Reads through
        -- `:get` / `:getMut` should return a proxy that resolves
        -- per-row to the relationship; we stash the proxy on the
        -- archetype's raw table so `:get`'s rawget(self) fallback finds
        -- it without inflating `columns` with a non-writable proxy.
        if compI.isSparse and comp.relationshipType == comp and relationshipStoreGetter then
            local sparseStore = relationshipStoreGetter(comp as Component) as RelationshipStore
            (self as table)[comp] = createSparseColumnProxy(self as table, sparseStore)
        end
    end

    return setmetatable(self, ARCHETYPE_MT)
end

return Archetype
