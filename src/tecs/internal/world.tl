--[[
world.tl - World implementation and system orchestration.

WARNING: This is an internal module and should not be required directly.
Instead, import the `tecs` module and use the methods provided there.
]]

local Context <const> = require("tecs.internal.Context")
local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")

local ArchetypeIndex <const> = require("tecs.internal.ArchetypeIndex")
local RelationshipStore <const> = require("tecs.internal.RelationshipStore")
local pipeline <const> = require("tecs.internal.pipeline")
local pool <const> = require("tecs.utils.pool")
local builtins <const> = require("tecs.internal.builtins")
local components <const> = require("tecs.internal.components")
local QueryImpl <const> = require("tecs.internal.QueryImpl")
local phases <const> = require("tecs.internal.phases")
local events <const> = require("tecs.internal.events")
local FFIEvents <const> = require("tecs.internal.ffi.FFIEvents")
local bundleModule <const> = require("tecs.internal.bundle")
local snapshotModule <const> = require("tecs.internal.snapshot")
local IdAllocator <const> = require("tecs.internal.IdAllocator")
local table_clear <const> = require("table.clear")
local C <const> = require("ffi")
local GLOBAL_FFI_EVENTS <const> = FFIEvents.global()

local type EntitySlot = IdAllocator.EntitySlot
local type World = types.World
local type Component = types.components.Component
local type ComponentInternal = internal.ComponentInternal
local type Archetype = internal.ArchetypeInternal
local type Relationship = types.components.Relationship
local type Query = types.Query
local type QueryDescriptor = types.Query.Descriptor
local type DoubleArray = types.DoubleArray
local type StatePolicy = types.StatePolicy
local type Event = types.events.Event
local type Phase = types.Phase
local type Plugin = types.Plugin
local type StatePolicyAction = types.StatePolicy.Action

-- Cached ctypes for the epoch-stamped transaction state arrays.
-- Allocated once per World at construction, sized to `maxSlotCount+1`
-- (index 0 unused, slots start at 1).
local UINT8_ARR_T <const> = C.typeof("uint8_t[?]")
local UINT32_ARR_T <const> = C.typeof("uint32_t[?]")

-- Id packing helpers are macro-expanded by IdAllocator.

-- WorldImpl shape/signatures live in `internal/types.tl`; this file and
-- world/*.tl attach implementations.
local WorldImpl = internal.WorldImpl

local WORLD_MT <const>: metatable<WorldImpl> = { __index = WorldImpl }

-- Per-world relationshipStores map with lazy store creation.
local function makeRelationshipStoresMT(world: WorldImpl): metatable<{Component: RelationshipStore}>
    local refCounts = world._targetRefCounts
    local onAdded = function(targetId: integer)
        refCounts[targetId] = (refCounts[targetId] or 0) + 1
    end
    local onRemoved = function(targetId: integer)
        local c = refCounts[targetId]
        if c and c <= 1 then
            refCounts[targetId] = nil
        elseif c then
            refCounts[targetId] = c - 1
        end
    end
    return {
        __index = function(t: {Component: RelationshipStore}, container: Relationship): RelationshipStore
            local containerI = container as ComponentInternal
            local store = RelationshipStore.create({
                sparse = containerI.isSparse,
                reverseIndex = containerI.reverseIndex,
                exclusive = container.exclusiveRelationship,
                onTargetAdded = onAdded,
                onTargetRemoved = onRemoved,
            })
            if store then
                rawset(t as table, container, store)
                -- Gate for the instant despawn path's `_targetRefCounts[id]`
                -- lookup. Once any relationship store exists, targets may
                -- accumulate refs; before that, the map is always empty.
                world._hasRelationshipStores = true
            end
            return store
        end
    }
end

function WorldImpl.new(config?: types.World.Config): World
    config = config or {}
    local dirtyArchetypes: {Archetype: boolean} = {}
    local allocator = IdAllocator.new(config.maxEntities)
    local archetypeIndex = ArchetypeIndex.new(dirtyArchetypes)
    local maxSlotCount = allocator.maxSlotCount

    local instance: WorldImpl = setmetatable({
        resources = Context.new(),
        messages = events.MessageBus.new(),
        _ffiSliceId = GLOBAL_FFI_EVENTS:acquireSlice(),
        _eventPool = pool.newTablePool({ clearOn = "acquire", maxSize = 32 }),
        allocator = allocator,
        _slots = allocator.slots as {integer: EntitySlot},
        archetypeIndex = archetypeIndex,
        _targetRefCounts = {},
        _hasRelationshipStores = false,
        relationshipStores = nil as {Component: RelationshipStore},
        _bundles = {},
        _dirtyArchetypes = dirtyArchetypes,
        _stateStack = {},
        _stateComponents = {},
        _statePolicies = {},
        _keyIndex = {},
        _transitionObserver = nil,
        _archetypeSnapshotPool = pool.newTablePool({ clearOn = "release" }),
        _scopeDepth = 0,

        -- Transaction staging state.
        _dirtyEpoch = 1,
        dirtyArchetypeList = {},
        dirtyArchetypeCount = 0,
        -- Epoch-stamped slot arrays. uint8 state holds STATE_SPAWN/MUTATE/
        -- DESPAWN (1/2/3) or 0 for unset. uint32 pendingArch holds the
        -- target Archetype.id (0 for unset). A slot's value is only valid
        -- when the parallel stamp equals `_transactionEpoch`. Starting
        -- epoch is 1 so uninitialised memory (zero) compares unequal.
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

    -- Used by archetype creation during edge walks.
    archetypeIndex.relationshipStoreGetter = function(c: Component): any
        return instance.relationshipStores[c]
    end

    -- Create pipeline.
    config.pipelineFactory = config.pipelineFactory or pipeline.new
    instance.pipeline = config.pipelineFactory(config.timestep)

    -- Forward archetype creation into the world event bus.
    instance.archetypeIndex.onNewArchetype = function(archetype: Archetype)
        (instance as WorldImpl):emit(0, builtins.ArchetypeCreated(archetype))
    end

    -- Apply builtins
    builtins.plugin(instance)
    return instance
end

-------------------------------------------------------------------------------
-- Plugin methods
-------------------------------------------------------------------------------

function WorldImpl:addPlugin(plugin: Plugin)
    plugin(self)
end

-------------------------------------------------------------------------------
-- Component methods
-------------------------------------------------------------------------------

function WorldImpl:get<T is Component>(id: integer, component: T): T
    local slot = IdAllocator.slotOf(id)
    local s = self._slots[slot]
    if IdAllocator.generationOfWithSlot(id, slot) ~= s.generation then
        return nil
    end
    local archetype = self.archetypeIndex[s.archetypeId]
    if archetype then
        -- Sparse relationships keep their row-indexed proxy on the
        -- archetype's raw table; dense columns live in `archetype.columns`.
        local column = rawget(archetype as table, component) as {T}
        if column == nil then
            column = rawget(archetype.columns, component) as {T}
        end
        if column then
            return column[s.row + 1]
        elseif (component as ComponentInternal).isSparseInstance then
            return self.relationshipStores[component.relationshipType]:getTarget(id, component.target) as T
        end
    end
end

function WorldImpl:getMut<T is Component>(id: integer, component: T): T
    local slot = IdAllocator.slotOf(id)
    local s = self._slots[slot]
    if IdAllocator.generationOfWithSlot(id, slot) ~= s.generation then
        return nil
    end
    local archetype = self.archetypeIndex[s.archetypeId]
    if archetype then
        local column = rawget(archetype as table, component) as {T}
        if column == nil then
            column = rawget(archetype.columns, component) as {T}
        end
        if column then
            archetype:markComponentDirty(component)
            return column[s.row + 1]
        elseif (component as ComponentInternal).isSparseInstance then
            return self.relationshipStores[component.relationshipType]:getTarget(id, component.target) as T
        end
    end
end

function WorldImpl:has(id: integer, component: Component): boolean
    local slot = IdAllocator.slotOf(id)
    local s = self._slots[slot]
    if IdAllocator.generationOfWithSlot(id, slot) ~= s.generation then
        return false
    end
    local archetype = self.archetypeIndex[s.archetypeId]
    if not archetype then return false end
    return rawget(archetype.columns, component) ~= nil
        or rawget(archetype as table, component) ~= nil
        or ((component as ComponentInternal).isSparseInstance ~= nil
            and self.relationshipStores[component.relationshipType]:getTarget(id, component.target) ~= nil)
end

function WorldImpl:getFirstRelationship<T is Relationship>(id: integer, relationship: T): T
    local slot = IdAllocator.slotOf(id)
    local s = self._slots[slot]
    if IdAllocator.generationOfWithSlot(id, slot) ~= s.generation then
        return nil
    end
    if (relationship as ComponentInternal).isSparse then
        return self.relationshipStores[relationship]:getFirst(id) as T
    else
        local archetype = self.archetypeIndex[s.archetypeId]
        if archetype then
            return archetype:getFirstRelationship(relationship, s.row + 1)
        end
    end
end

-------------------------------------------------------------------------------
-- Key index
-------------------------------------------------------------------------------

local function validateKey(key: string)
    if key == nil or key == "" then
        error("Key must be a non-empty string")
    end
end

function WorldImpl:byKey(key: string): integer | nil
    return self._keyIndex[key]
end

function WorldImpl:requireKey(key: string): integer
    local id = self._keyIndex[key]
    if id == nil then
        error("No entity with Key '" .. tostring(key) .. "'")
    end
    return id
end

function WorldImpl:_claimKey(id: integer, key: string)
    validateKey(key)
    local current = self._keyIndex[key]
    if current ~= nil and current ~= id then
        error("Key '" .. key .. "' is already claimed by entity " .. tostring(current))
    end

    local old = self:oldValueOf(id, builtins.Key)
    if old ~= nil and old ~= key then
        self._keyIndex[old as string] = nil
    end
    self._keyIndex[key] = id
end

function WorldImpl:_releaseKeyForEntity(id: integer)
    local old = self:oldValueOf(id, builtins.Key)
    if old ~= nil and self._keyIndex[old as string] == id then
        self._keyIndex[old as string] = nil
    end
end

function WorldImpl:set(id: integer, component: Component, value?: any)

    local componentType: Component = component.componentType as Component

    if value == nil then
        if (componentType as ComponentInternal).storageType == "scalar" then
            -- `set(id, ScalarType)` (the type itself is its own componentType)
            -- means "add with default"; `set(id, ScalarType("Frank"))` (a
            -- wrapper) means "add with this value". Distinguish by identity
            -- and unwrap at the boundary so internals see raw scalars.
            if component == componentType then
                value = (component as types.components.ScalarComponent<any>).scalarDefault
            else
                value = (component as {string:any}).value
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

function WorldImpl:remove(id: integer, component: Component)
    if self._scopeDepth > 0 then
        self:_deferRemove(id, component)
    else
        self:_instantRemove(id, component)
    end
end

function WorldImpl:markComponentDirty(id: integer, component: Component)
    local slot = IdAllocator.slotOf(id)
    if slot < 1 or slot > self._maxSlotCount then return end
    local s = self._slots[slot]
    if IdAllocator.generationOfWithSlot(id, slot) ~= s.generation then
        return
    end
    local archetype = self.archetypeIndex[s.archetypeId]
    if archetype then
        archetype:markComponentDirty(component)
    end
end

-- Raw set: invoke default set behavior without dispatcher recursion.
-- Scope-aware: routes to deferSetRaw or instantSetRaw based on current
-- scope depth. Called from component-specific callbacks that want default
-- semantics without recursing into themselves.
function WorldImpl:setRaw(id: integer, componentType: Component, value: any)
    if self._scopeDepth > 0 then
        self:deferSetRaw(id, componentType, value)
    else
        self:instantSetRaw(id, componentType, value)
    end
end

function WorldImpl:removeRaw(id: integer, component: Component)
    if self._scopeDepth > 0 then
        self:deferRemoveRaw(id, component)
    else
        self:instantRemoveRaw(id, component)
    end
end

-- Read the current (staging-reconciled) component value for `id`. Returns
-- nil if the entity doesn't carry the component. Component-specific
-- callbacks use this before invoking removeRaw, satisfying the
-- "value-still-readable" ordering invariant.
function WorldImpl:oldValueOf(id: integer, component: Component): any
    local slot = IdAllocator.slotOf(id)
    local s = self._slots[slot]
    local srcArch = self.archetypeIndex[s.archetypeId]
    return self:findOldValue(slot, component, srcArch, s.row)
end

-- Return the entity's current archetype as the dispatcher sees it:
-- pending archetype if one exists (entity is mid-transaction), else the
-- committed archetype. Component-specific callbacks that need to iterate
-- siblings (exclusive-relationship eviction, cascade cleanup) call this.
function WorldImpl:currentArchetype(id: integer): Archetype
    local slot = IdAllocator.slotOf(id)
    -- _slotStamp/_pendingArchArr resolution inlined rather than calling
    -- getPendingArch to avoid the shared.tl import dance here.
    if (self._slotStamp as {integer:integer})[slot] == self._transactionEpoch then
        local pid = (self._pendingArchArr as {integer:integer})[slot]
        if pid ~= 0 then return self.archetypeIndex[pid] end
    end
    local s = self._slots[slot]
    return self.archetypeIndex[s.archetypeId]
end

-------------------------------------------------------------------------------
-- Spawn/despawn methods
-------------------------------------------------------------------------------

function WorldImpl:spawn(...: Component): integer
    if self._scopeDepth > 0 then
        return self:_deferSpawn(...)
    end

    -- OnSpawn observers require the staged path: the event contract is a
    -- staged entity (not alive until commit) whose further mutations defer.
    -- The fallback drains before returning, so the caller still receives a
    -- committed entity.
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

-- Spawn at a specific packed id. Used by snapshot loading to restore
-- entities at their original (slot, generation). No instant fast path --
-- the id+gen arithmetic + free-stack reconciliation lives on the staged
-- path, so we self-scope stage + drain (or stage only under a scope).
function WorldImpl:spawnAt(id: integer, ...: Component)
    if self._scopeDepth > 0 then
        self:_deferSpawnAt(id, ...)
        return
    end

    self._scopeDepth = 1
    self:_deferSpawnAt(id, ...)
    self:_drain()
    self._scopeDepth = 0
end

function WorldImpl:forEachArchetype(callback: function(Archetype))
    local index = self.archetypeIndex
    -- `maxId` + nil-check tolerates holes left by compact().
    for i = 1, index.maxId do
        local arch = index[i]
        if arch then callback(arch) end
    end
end

function WorldImpl:dirtyArchetypes(): function(): Archetype
    local set = self._dirtyArchetypes
    local nextFn, t = pairs(set)
    local key: Archetype = nil
    return function(): Archetype
        local k, _ = nextFn(t, key)
        key = k
        return k
    end
end

local function hasKeyBatch(componentTypes: {Component}): boolean
    local Key <const> = builtins.Key
    for i = 1, #componentTypes do
        if componentTypes[i] == Key then
            return true
        end
    end
    return false
end

local function assertNoKeyBatch(componentTypes: {Component}, op: string)
    if hasKeyBatch(componentTypes) then
        error(op .. " does not support Key because keys must be claimed per entity. " ..
            "Use world:spawn/world:spawnAt or add Key with world:set per entity.")
    end
end

-- Batch ops share the staging-queue machinery used by regular deferred
-- mutations. Outside a scope we self-drain; inside a scope we stage and
-- let the outer boundary drain.
function WorldImpl:batchSpawn(
    count: integer,
    componentTypes: {Component},
    callback: function(Archetype, integer, integer, integer)
): integer | nil, {integer} | nil
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
    ids: {integer},
    componentTypes: {Component},
    callback: function(Archetype, integer, integer, integer)
)
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
    ids: any,
    count: integer,
    componentTypes: {Component},
    callback: function(Archetype, integer, integer, integer)
)
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

function WorldImpl:despawn(id: integer)
    if self._scopeDepth > 0 then
        self:_deferDespawn(id)
    elseif not self:_instantDespawn(id) then
        self._scopeDepth = 1
        self:_deferDespawn(id)
        self:_drain()
        self._scopeDepth = 0
    end
end

-- Snapshot matching archetypes from a Query object.
-- Snapshotting avoids iterating a live list that can be mutated by
-- onActivated/onDeactivated during batch drains.
local function archetypesOf(world: WorldImpl, query: Query): {Archetype}
    local items = (query as {string: any})._activeItems
    if not items then
        error("batch op requires a Query object (built via world:query(...)). " ..
            "Build the query once outside your hot loop and reuse it.")
    end
    local src = items as {Archetype}
    -- Pooled snapshot: released after commit (batch ops) or immediately
    -- after handoff (batchDespawn). Avoids one fresh-table allocation per
    -- batch call on the hot path.
    local snapshot = world._archetypeSnapshotPool:acquire() as {Archetype}
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

-- Queue despawn for all archetypes matched by query.
function WorldImpl:batchDespawn(query: Query)
    local targetArchetypes = archetypesOf(self, query)
    local inScope = self._scopeDepth > 0
    if not inScope then self._scopeDepth = 1 end
    self:_deferBatchDespawn(targetArchetypes)
    if not inScope then
        self:_drain()
        self._scopeDepth = 0
    end
    -- `_deferBatchDespawn` consumes this list immediately.
    self._archetypeSnapshotPool:release(targetArchetypes as {any})
end

-- Forms:
--   world:batchSet(query, instance)
--   world:batchSet(query, componentType, callback)
function WorldImpl:batchSet(query: Query, componentOrInstance: Component, callback?: function(Archetype, integer, integer, integer))
    local targetArchetypes = archetypesOf(self, query)

    -- Tecs components: the container (type) has `componentType == self`;
    -- an instance has `componentType` pointing AT the container (not
    -- itself) -- so `arg.componentType == arg` disambiguates. Using this
    -- test we validate the shape matches the call form: callback mode
    -- wants a container, const mode wants an instance (tags are
    -- containers and are accepted in const mode too, since the
    -- container IS its own tag value).
    local asAny = componentOrInstance as {string: any}
    local componentType = asAny.componentType as Component
    local isContainer = componentType == componentOrInstance
    if not componentType then
        error("batchSet: second argument must be a component (container or instance with " ..
            "a `componentType` field)")
    end

    local inScope = self._scopeDepth > 0
    if not inScope then self._scopeDepth = 1 end
    if callback then
        -- Callback form requires a component type.
        if not isContainer then
            error("batchSet callback form requires the component type (container), not an " ..
                "instance. Pass `MyComponent` rather than `MyComponent(...)`.")
        end
        self:_deferBatchSetCallback(targetArchetypes, componentOrInstance, callback)
    else
        -- Constant form accepts instance or tag container.
        self:_deferBatchSet(targetArchetypes, componentType, componentOrInstance)
    end
    if not inScope then
        self:_drain()
        self._scopeDepth = 0
    end
end

function WorldImpl:batchRemove(query: Query, componentType: Component)
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
                local entities = arch.entities as {integer}
                for row = 1, entities[0] do
                    observer.entity(entities[row], arch, nil)
                end
            end
        end
    end

    -- In-place reset: zero the arena slots, reset ring / nextFreshSlot.
    -- Keeps the arena object identity stable for captured references.
    IdAllocator.reset(self.allocator)
    self:_resetTxn()
    self._scopeDepth = 0

    local archetypeIndex = self.archetypeIndex
    -- `maxId` + nil-check tolerates holes left by compact().
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
    -- Release the pooled sparse-relationship arrays and reset the staging map,
    -- mirroring the drain cleanup. Without this, any sparse values still staged
    -- in `sparseSets` at clear time would survive into a later drain. Symmetric
    -- with the relationshipStores wipe above.
    local sparsePool = self._sparseArraysPool
    for slot, list in pairs(self.sparseSets) do
        self.sparseSets[slot] = nil
        sparsePool:release(list)
    end
    self.sparseSetCount = 0
    table_clear(self._dirtyArchetypes)
end

function WorldImpl:compact(): integer, integer
    assert(not self.isDirty, "compact requires a committed world")

    local index = self.archetypeIndex
    local pruned = 0
    local compacted = 0

    -- Phase 1: collect empty ephemeral archetypes that are unreachable
    -- because at least one relationship target is dead.
    local slots = self._slots
    local toDestroy: {Archetype} = {}
    local destroyedSet: {Archetype: boolean} = {}
    for i = 2, index.maxId do
        local arch = index[i]
        if arch and arch.isEphemeral and arch.entities[0] == 0 then
            -- Any dead relationship target makes the archetype unreachable.
            for j = 1, arch.columnsCount do
                local comp = arch.componentList[j]
                local target = comp.target
                if target ~= nil then
                    local targetSlot = IdAllocator.slotOf(target)
                    local s = slots[targetSlot]
                    -- Dead if slot is free or generation mismatches.
                    if s.archetypeId == 0
                            or IdAllocator.generationOfWithSlot(target, targetSlot) ~= s.generation then
                        toDestroy[#toDestroy + 1] = arch
                        destroyedSet[arch] = true
                        break
                    end
                end
            end
        end
    end

    -- Phase 2: destroy collected archetypes.
    if #toDestroy > 0 then
        for i = 1, #toDestroy do
            index:destroy(toDestroy[i])
        end
        pruned = #toDestroy

        -- Drop stale MovePlan cache entries targeting destroyed archetypes.
        for i = 1, index.maxId do
            local arch = index[i]
            if arch then
                local plans = (arch as {string: any}).movePlansOut
                    as {Archetype: internal.MovePlan}
                if plans then
                    for target in pairs(plans) do
                        if destroyedSet[target] then
                            plans[target] = nil
                        end
                    end
                end
            end
        end

        -- Clear stale last-arch column cache.
        if destroyedSet[self.lastArch] then
            self.lastArch = nil
            self.lastCompType = nil
            self.lastColumn = nil
        end
    end

    -- Phase 3: shrink over-allocated survivors.
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

function WorldImpl:isAlive(id: integer): boolean
    local slot = IdAllocator.slotOf(id)
    local s = self._slots[slot]
    if s.archetypeId == 0 then return false end
    -- Generation check detects ABA: id was captured when the slot held
    -- a prior (now-dead) entity, and the slot got recycled to a new one.
    -- id's generation part != current slot generation => id is stale.
    return IdAllocator.generationOfWithSlot(id, slot) == s.generation
end

-------------------------------------------------------------------------------
-- State Stack methods
-------------------------------------------------------------------------------

-- Snapshot the matching archetypes before mutating: staged set/remove/
-- despawn can create archetypes mid-walk (edge walks, cascade
-- removals), and adding keys to the live component-archetype set during
-- its next() traversal is undefined, so entries can be skipped.
local function snapshotStateArchetypes(
    self: WorldImpl,
    component: Component
): {Archetype}, {integer}
    local archs: {Archetype} = {}
    local lens: {integer} = {}
    for archetype, len in self:findArchetypes(component) do
        archs[#archs + 1] = archetype
        lens[#lens + 1] = len
    end
    return archs, lens
end

local ACTIONS <const>: {string: function(WorldImpl, Component)} = {
    pause = function(self: WorldImpl, stateComponent: Component)
        local Paused <const> = builtins.Paused
        local archs, lens = snapshotStateArchetypes(self, stateComponent)
        for k = 1, #archs do
            local archetype = archs[k]
            if not archetype.columns[Paused] then
                local entities = archetype.entities
                for i = 1, lens[k] do
                    self:set(entities[i] as integer, Paused)
                end
            end
        end
    end,
    resume = function(self: WorldImpl, stateComponent: Component)
        local Paused <const> = builtins.Paused
        local archs, lens = snapshotStateArchetypes(self, stateComponent)
        for k = 1, #archs do
            local archetype = archs[k]
            if archetype.columns[Paused] then
                local entities = archetype.entities
                for i = 1, lens[k] do
                    self:remove(entities[i] as integer, Paused)
                end
            end
        end
    end,
    despawn = function(self: WorldImpl, stateComponent: Component)
        local archs, lens = snapshotStateArchetypes(self, stateComponent)
        for k = 1, #archs do
            local entities = archs[k].entities
            for i = 1, lens[k] do
                self:despawn(entities[i] as integer)
            end
        end
    end,
    disable = function(self: WorldImpl, stateComponent: Component)
        local Disabled <const> = builtins.Disabled
        local archs, lens = snapshotStateArchetypes(self, stateComponent)
        for k = 1, #archs do
            local archetype = archs[k]
            if not archetype.columns[Disabled] then
                local entities = archetype.entities
                for i = 1, lens[k] do
                    self:set(entities[i] as integer, Disabled)
                end
            end
        end
    end
}

-- Execute a built-in state action on matching entities.
local function executeAction(self: WorldImpl, actionStr: string, stateComponent: Component)
    local actionFunc = ACTIONS[actionStr]
    if not actionFunc then
        error("Unknown state policy action: " .. actionStr)
    end
    actionFunc(self, stateComponent)
end

local function executePolicy(self: WorldImpl, action: string | StatePolicyAction | function(World), stateName: string)
    if not action then
        return
    end

    self:defer()
    local stateComponent = self._stateComponents[stateName]

    -- String shorthand: "pause", "resume", "despawn", "disable"
    if action is string then
        if stateComponent then
            executeAction(self, action, stateComponent)
        end
    elseif action is function then
        action(self)
    else
        -- StatePolicyAction table: apply action + call function
        local policyAction = action as StatePolicyAction
        if policyAction.apply and stateComponent then
            executeAction(self, policyAction.apply, stateComponent)
        end
        if policyAction.call then
            policyAction.call(self)
        end
    end

    self:commit()
end

function WorldImpl:createState(name: string, policy?: StatePolicy): Component
    if self._stateComponents[name] then
        error("State '" .. name .. "' already exists")
    end

    -- Reuse globally-registered component if it exists (e.g., across multiple worlds in tests)
    local componentName = name .. "State"
    local stateComponent = components.registeredComponents[componentName]
    if not stateComponent then
        stateComponent = components.newTagComponent({name = componentName})
    end
    self._stateComponents[name] = stateComponent

    policy = policy or {}
    if not policy.onExit then
        policy.onExit = "despawn"
    end

    self._statePolicies[name] = policy
    return stateComponent
end

function WorldImpl:pushState(name: string)
    local stateComponent = self._stateComponents[name]
    if not stateComponent then
        error("State '" .. name .. "' not found. Call createState('" .. name .. "') first.")
    end

    local stack = self._stateStack
    local before = stack[#stack]

    -- Fire onBlur for the current top state
    if #stack > 0 then
        local currentTop = stack[#stack]
        local currentPolicy = self._statePolicies[currentTop]
        if currentPolicy and currentPolicy.onBlur then
            executePolicy(self, currentPolicy.onBlur, currentTop)
        end
        self:emit(0, builtins.StateBlur(currentTop, name))
    end

    -- Push the new state
    stack[#stack + 1] = name
    self.autoStateComponent = stateComponent

    -- Fire onEnter for the new state
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

    -- Fire onExit for the state being popped
    local policy = self._statePolicies[poppedName]
    if policy and policy.onExit then
        executePolicy(self, policy.onExit, poppedName)
    end
    self:emit(0, builtins.StateExit(poppedName))

    -- Pop from stack
    stack[#stack] = nil

    -- Fire onFocus for the new top state
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

function WorldImpl:peekState(): string
    local stack = self._stateStack
    return stack[#stack]
end

-------------------------------------------------------------------------------
-- Sparse resource methods
-------------------------------------------------------------------------------

function WorldImpl:targets<T>(id: integer, relationship: Relationship, callback: function(integer, T), context: T)
    local store = self.relationshipStores[relationship as Component]
    if not store then
        error("targets() requires a relationship with reverseIndex = true, but given " .. relationship.componentName)
    end
    store:forEachSource(id, callback, context)
end

function WorldImpl:walkUp<T>(
    id: integer,
    relationship: Relationship,
    callback: function(integer, integer, T): boolean,
    context: T,
    maxDepth?: number
)
    local cap = (maxDepth or 100) as integer
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
        cap, id, tostring(relationship.componentName)
    ))
end

function WorldImpl:traverse(root: integer, relationship: Relationship): function(): (integer, integer)
    local store = self.relationshipStores[relationship as Component]
    if not store then
        error("traverse() requires a relationship with reverseIndex = true, but given " .. relationship.componentName)
    end

    -- DFS using an explicit stack: {entityId, depth} pairs
    local dfsStack: {{integer}} = {}

    -- Hoisted collectors for forEachSource. Using the context arg means
    -- we don't allocate a fresh closure on every push.
    local function seedCollector(child: integer, stack: any)
        local s = stack as {{integer}}
        s[#s + 1] = {child, 0}
    end
    local pendingChildren: {integer} = {}
    local function childCollector(child: integer, buf: any)
        local b = buf as {integer}
        b[#b + 1] = child
    end

    store:forEachSource(root, seedCollector, dfsStack)

    return function(): (integer, integer)
        while #dfsStack > 0 do
            local top = dfsStack[#dfsStack]
            dfsStack[#dfsStack] = nil
            local entityId = top[1]
            local depth = top[2]
            -- Push this entity's children (reverse order so first child is visited first)
            for i = #pendingChildren, 1, -1 do pendingChildren[i] = nil end
            store:forEachSource(entityId, childCollector, pendingChildren)
            for i = #pendingChildren, 1, -1 do
                dfsStack[#dfsStack + 1] = {pendingChildren[i], depth + 1}
            end
            return depth, entityId
        end
        return nil as integer, nil as integer
    end
end

-------------------------------------------------------------------------------
-- System methods
-------------------------------------------------------------------------------

function WorldImpl:addSystem(config: types.SystemConfig)
    self.pipeline:addSystem(assert(config, "Missing system config"))
end

function WorldImpl:removeSystem(systemName: string)
    self.pipeline:removeSystem(systemName)
end

-------------------------------------------------------------------------------
-- Query methods
-------------------------------------------------------------------------------

local function hasComponentInList(componentList: {Component}, target: Component): boolean
    if componentList then
        for i = 1, #componentList do
            if componentList[i] == target then
                return true
            end
        end
    end
    return false
end

local function autoExcludeComponent(descriptor: QueryDescriptor, component: Component)
    if hasComponentInList(descriptor.include, component) then
        -- Component is explicitly included, don't exclude it
    elseif not descriptor.exclude then
        descriptor.exclude = {component}
    elseif not hasComponentInList(descriptor.exclude, component) then
        descriptor.exclude[#descriptor.exclude + 1] = component
    end
end

function WorldImpl:query(descriptor: QueryDescriptor): Query
    -- Auto-exclude Disabled entities from all queries (unless explicitly included)
    autoExcludeComponent(descriptor, builtins.Disabled)

    -- Logic queries skip paused entities; render queries keep drawing them.
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

local NO_ENTITY_FUNCTION <const> = function(): Archetype, integer, DoubleArray
    return nil, 0, nil
end

function WorldImpl:findArchetypes(component: Component): function(): (Archetype, integer, DoubleArray)
    local archetypes = self.archetypeIndex:getArchetypesWithComponent(component)
    if archetypes then
        local key = next(archetypes)
        if key then
            return function(): (Archetype, integer, DoubleArray)
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

-------------------------------------------------------------------------------
-- Observer methods
-------------------------------------------------------------------------------

-- Observer addresses: 0 for global, or an entity handle/slot. Normalize
-- to slot via modulo; 0 stays 0, (slot, gen) handles collapse to slot,
-- raw slots pass through unchanged. Internal emits already pass slots.
function WorldImpl:observe<E is Event>(address: integer, eventType: E, observer: function(E), id?: string)
    local slot = IdAllocator.slotOf(address)
    self.messages:observe(slot, eventType, observer, id)
end

function WorldImpl:stopObserving<E is Event>(address: integer, eventType: E, observer: function(E) | string)
    self.messages:stopObserving(IdAllocator.slotOf(address), eventType, observer)
end

function WorldImpl:hasObservers<E is Event>(address: integer, eventType: E): boolean
    return self.messages:hasObservers(IdAllocator.slotOf(address), eventType)
end

function WorldImpl:emit<E is Event>(address: integer, eventOrType: E, ...: any)
    local slot = IdAllocator.slotOf(address)
    local messages = self.messages

    -- Create the event using arguments if the given value is a container.
    if eventOrType is table and rawget(eventOrType as table, "init") ~= nil then
        -- Only emit if there are actually listeners.
        if not messages:hasObservers(slot, eventOrType as E) then
            return
        end

        if eventOrType.__tecs_ffi then
            local ffiEvent = GLOBAL_FFI_EVENTS:vendEvent(self._ffiSliceId, eventOrType) as {string: any}
            ffiEvent.eventId = eventOrType.eventId
            ffiEvent.typeId = eventOrType.__tecs_ffi_typeId
            (eventOrType.init as function(E, ...: any))(ffiEvent as E, ...)
            messages:emit(slot, ffiEvent as E)
        else
            local eventId = eventOrType.eventId as integer
            local pooled = self._eventPool:acquire()
            local eventTable = pooled as {string: any}
            eventTable.eventId = eventId
            setmetatable(eventTable as {any: any}, eventOrType.__tecs_mt as metatable<{any: any}>)
            (eventOrType.init as function(E, ...: any))(eventTable as E, ...)
            messages:emit(slot, eventTable as E)
            self._eventPool:release(eventTable)
        end
    else
        messages:emit(slot, eventOrType)
    end
end

function WorldImpl:clearObservers(address: integer)
    self.messages:clearAddress(IdAllocator.slotOf(address))
end

function WorldImpl:addSnapshotHandler(handler: types.World.SnapshotHandler)
    if handler.name == nil or handler.name == "" then
        error("snapshot handler requires a non-empty name", 2)
    end

    local key <const> = handler.name
    local save <const> = handler.save
    if save then
        self:observe(0, builtins.OnSnapshotSave, function(ev: builtins.OnSnapshotSave)
            local value = save(self)
            if value ~= nil then
                ev:addData(key, value)
            end
        end)
    end

    local loadHandler <const> = handler.load
    if loadHandler then
        local loadFn <const> = loadHandler as function(types.World, any)
        self:observe(0, builtins.StartSnapshotLoad, function(ev: builtins.StartSnapshotLoad)
            ev:onData(key, function(value: any)
                loadFn(self, value)
            end)
        end)
    end

    local finish <const> = handler.finish
    if finish then
        local finishFn <const> = finish as function(types.World, types.World.SnapshotPrelude)
        self:observe(0, builtins.FinishSnapshotLoad, function(ev: builtins.FinishSnapshotLoad)
            finishFn(self, ev.prelude as types.World.SnapshotPrelude)
        end)
    end
end

-------------------------------------------------------------------------------
-- Phase methods
-------------------------------------------------------------------------------

-- Enter query iteration scope.
function WorldImpl:_pushQueryScope()
    self._scopeDepth = self._scopeDepth + 1
end

-- Leave query iteration scope; drain when the outer scope closes.
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

function WorldImpl:update(dt: number)
    self:commit()
    if self._ffiSliceId ~= 0 then
        GLOBAL_FFI_EVENTS:clearSlice(self._ffiSliceId)
    end
    self.pipeline:update(dt, self)

    -- Clear component-dirty bits after the pipeline finishes; systems
    -- drained their own scopes, and the next update's leading commit
    -- picks up anything still staged.
    for archetype in pairs(self._dirtyArchetypes) do
        archetype:clearDirtyComponents()
    end
    table_clear(self._dirtyArchetypes)
end

function WorldImpl:getFixedTiming(): number, number, number
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

function WorldImpl:enablePhase(phase: Phase)
    self.pipeline:enablePhase(phase)
end

function WorldImpl:disablePhase(phase: Phase)
    self.pipeline:disablePhase(phase)
end

function WorldImpl:registerPhase(phase: Phase)
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

function WorldImpl:runPhase(phase: Phase, dt?: number)
    self.pipeline:run(phase, dt or 0, self)
end

-------------------------------------------------------------------------------
-- Bundle methods
-------------------------------------------------------------------------------

function WorldImpl:newBundle(name: string, def?: types.Bundle.Definition): types.Bundle
    return bundleModule.create(self, name, def)
end

function WorldImpl:spawnBundle(name: string, ...: Component): integer
    local bndl = self._bundles[name]
    if not bndl then
        error("Unknown bundle: " .. name)
    end
    return bndl:spawn(...)
end

function WorldImpl:getBundles(): {string: types.Bundle}
    local result: {string: types.Bundle} = {}
    for name, bndl in pairs(self._bundles) do
        result[name] = bndl
    end
    return result
end

function WorldImpl:getBundle(name: string): types.Bundle | nil
    return self._bundles[name]
end

-------------------------------------------------------------------------------
-- Debugging / Introspection
-------------------------------------------------------------------------------

function WorldImpl:getStats(fill?: types.World.Stats): types.World.Stats
    fill = fill or {}

    -- Count actual entities across all archetypes. `maxId` + nil-check
    -- tolerates holes left by compact() (freed archetype ids).
    local actualEntityCount = 0
    local archetypeCount = 0
    local componentTypes: {Component: boolean} = {}

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

function WorldImpl:saveSnapshot(opts?: types.World.SnapshotOptions): types.World.SnapshotOutput
    return snapshotModule.saveSnapshot(self, opts)
end

function WorldImpl:loadSnapshot(source: any): types.World.SnapshotPrelude
    local prelude = snapshotModule.loadSnapshot(self, source) as types.World.SnapshotPrelude
    self:_rebuildKeyIndex()
    return prelude
end

function WorldImpl:_rebuildKeyIndex()
    local nextIndex: {string: integer} = {}
    local Key <const> = builtins.Key
    self:forEachArchetype(function(arch: Archetype)
        local col = arch.columns[Key] as {string}
        if col then
            local entities = arch.entities as {integer}
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

-- Side-effect module loads attach implementations onto `WorldImpl`.
require("tecs.internal.world.shared")
require("tecs.internal.world.instant")
require("tecs.internal.world.deferred")
require("tecs.internal.world.batch")
require("tecs.internal.world.drain")
require("tecs.internal.world.sparse")
require("tecs.internal.world.validate")

return WorldImpl
