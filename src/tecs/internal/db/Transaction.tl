--[[
    Transaction.tl - Deferred mutation system for bulk ECS operations

    Stages all entity changes during a frame and commits them in bulk for
    maximum performance. Replaces ChangeBatch with zero-allocation staging
    using arenas for FFI components and simple maps for Lua values.
]]

local types <const> = require("tecs.types")
local compat <const> = require("tecs.internal.utils.compat")
local table_clear <const> = compat.clear
local logging <const> = require("tecs.internal.utils.logging")
local pool <const> = require("tecs.internal.utils.pool")
local ArchetypeClass = require("tecs.internal.Archetype")
local ffi <const> = require("tecs.internal.ffi")
local ChangeViewClass = require("tecs.internal.db.ChangeView")
local WeakArray <const> = require("tecs.internal.utils.WeakArray")
local LOGGER <const> = logging.getLogger("tecs.Transaction")

local type Int32Array = types.Int32Array
local setIntArraySize <const> = ffi.setIntArraySize

local bxor = compat.bxor
local band = compat.band

local type Component = types.Component
local type Archetype = types.Archetype
local type ArchetypeChangeObserver = types.ArchetypeChangeObserver
local type EntityIndex = require("tecs.internal.db.EntityIndex")
local type ArchetypeIndex = require("tecs.internal.db.ArchetypeIndex")
local type RelationshipTracker = require("tecs.internal.db.RelationshipTracker")

-- Record for accessing archetype implementation fields
local record ArchetypeImpl
    id: integer
    entities: Int32Array
    columns: {Component: any}
end

-- Removed TableValues as it's no longer needed in staging archetype design

-- Staging archetype for spawn batches - IS a real archetype, just not "registered" yet
local record StagingArchetype
    -- Core archetype structure (mirrors Archetype exactly)
    id: integer                 -- Temporary ID during staging
    entities: Int32Array  -- Entity IDs in spawn order (FFI array)
    columns: {Component: any}   -- Component columns with real typed arrays
    columnsCount: integer       -- Number of components
    componentHash: integer      -- Hash of component set

    -- Staging-specific fields
    components: {Component}     -- The component set (for promotion/merging)
    isPromoted: boolean         -- Whether this staging was promoted to real archetype

    -- Methods for promotion/merging
    promoteToReal: function(self: StagingArchetype, archetypeIndex: ArchetypeIndex): Archetype
    mergeIntoExisting: function(self: StagingArchetype, target: Archetype)
end

local record Transaction
    -- Entity ID allocation
    firstEntityId: integer
    nextEntityId: integer

    -- Spawn staging (immutable once created)
    stagingArchetypes: {StagingArchetype}  -- Staging archetypes for spawns
    stagingArchetypePool: {integer: {StagingArchetype}}  -- Pool by component hash for reuse
    spawnedEntities: {integer: boolean}    -- Track which entities were spawned this frame

    -- Accumulate spawn components per entity before creating staging archetype
    spawnComponents: {integer: {Component}}      -- Components being added to spawned entities
    spawnValues: {integer: {Component: any}}     -- Component values for spawned entities

    -- Mutation operations (for existing entities only)
    despawns: {integer: boolean}
    pendingAdd: {integer: {Component: boolean}}
    pendingRemove: {integer: {Component: boolean}}
    mutatedValues: {integer: {Component: any}}  -- Component values for mutations
    mutatedEntities: {integer: boolean}        -- Track which entities have mutations

    -- References to DB components
    entityIndex: EntityIndex
    archetypeIndex: ArchetypeIndex
    relationshipTracker: RelationshipTracker
    world: types.World
    changeObservers: WeakArray<ArchetypeChangeObserver>

    -- Temporary state during despawn processing
    currentlyDespawning: {integer: boolean}
    despawnsDuringHooks: {integer: boolean}

    -- Computed during commit
    newArchetypes: {Archetype}

    -- Performance optimization: track if any mutations occurred
    isDirty: boolean

    -- Methods
    setWorld: function(self: Transaction, world: types.World)
    setChangeObservers: function(self: Transaction, observers: WeakArray<ArchetypeChangeObserver>)
    reset: function(self: Transaction, nextEntityId: integer)
    allocateEntityId: function(self: Transaction): integer
    spawn: function(self: Transaction, id: integer)
    despawn: function(self: Transaction, id: integer)
    addComponent: function(self: Transaction, id: integer, component: Component, value: any)
    removeComponent: function(self: Transaction, id: integer, component: Component)
    mutateComponent: function(self: Transaction, id: integer, component: Component, value: any)
    isSpawn: function(self: Transaction, id: integer): boolean
    isBeingDespawned: function(self: Transaction, id: integer): boolean
    hasChanges: function(self: Transaction): boolean
    commit: function(self: Transaction)
    clearStagingData: function(self: Transaction)
    getNewArchetypes: function(self: Transaction): {Archetype}
    getPendingComponent: function<C is Component>(self: Transaction, id: integer, component: C): C
    _getSpawnComponents: function(self: Transaction, id: integer): {Component}
    _finalizeSpawns: function(self: Transaction)
    _findOrCreateStagingArchetype: function(self: Transaction, components: {Component}): StagingArchetype
    _processStagingArchetype: function(self: Transaction, staging: StagingArchetype)
    _getFinalComponentsForMutation: function(self: Transaction, id: integer): {Component}
    _countSpawns: function(self: Transaction): integer
    _countMutations: function(self: Transaction): integer
    _countDespawns: function(self: Transaction): integer
    _processDespawns: function(self: Transaction)
    _processMutations: function(self: Transaction)
    _removeEntitiesFromArchetype: function(self: Transaction, archetype: Archetype, removals: {integer: boolean})
    _moveEntityToArchetype: function(self: Transaction, entityId: integer, newArchetype: Archetype)
    _removeEntityFromArchetype: function(self: Transaction, archetype: Archetype, entityId: integer, row: integer)
    _processOnAddHooks: function(self: Transaction, entityId: integer, components: {Component})
    _processOnRemoveHooks: function(self: Transaction, entityId: integer, components: {Component})
end

local STAGING_ARCHETYPE_MT <const>: metatable<StagingArchetype> = { __index = StagingArchetype }

-- Promote staging archetype to a real archetype (zero-copy for new archetypes)
function StagingArchetype:promoteToReal(archetypeIndex: ArchetypeIndex): Archetype
    -- Create real archetype using existing staging data (zero copy!)
    local realArchetype = ArchetypeClass.new(self.components, self.componentHash)

    -- Replace the empty columns with our populated staging columns
    local realImpl = realArchetype as ArchetypeImpl
    realImpl.entities = self.entities
    setIntArraySize(realImpl.entities, self.entities[0])
    realArchetype.columns = self.columns as {Component: {Component}}
    for comp, column in pairs(self.columns) do
        (realArchetype as table)[comp] = column  -- Update direct reference
    end

    -- Set the proper archetype ID
    realArchetype.id = archetypeIndex:_getNextId()

    -- Register in archetype index
    archetypeIndex:_registerArchetype(realArchetype, self.components)

    -- Mark as promoted
    self.isPromoted = true

    return realArchetype as types.Archetype
end

-- Merge staging archetype into existing archetype (single memcpy per column)
function StagingArchetype:mergeIntoExisting(target: Archetype)
    local entityCount = self.entities[0]
    if entityCount == 0 then
        return
    end

    -- Cast target to access implementation fields
    local targetImpl = target as ArchetypeImpl

    -- Start position in target archetype
    local startRow = targetImpl.entities[0]

    -- Ensure capacity and extend target entities array
    targetImpl.entities = ffi.ensureCapacityInt32(targetImpl.entities, startRow + entityCount)
    for i = 1, entityCount do
        (targetImpl.entities as {integer})[startRow + i] = (self.entities as {integer})[i]
    end
    setIntArraySize(targetImpl.entities, startRow + entityCount)

    -- Merge each component column using single memcpy
    for component, stagingColumn in pairs(self.columns) do
        local targetColumn = target.columns[component]
        local storage = component:getStorage()

        -- Ensure target has capacity
        if storage.ensureCapacity then
            local newColumn = storage:ensureCapacity(targetColumn, startRow + entityCount)
            if newColumn ~= targetColumn then
                target.columns[component] = newColumn
                targetColumn = newColumn
                -- Update direct reference in target archetype table
                (target as table)[component] = newColumn
            end
        end

        -- Single memcpy operation per column (check if storage has bulk copy)
        local storageAny = storage as {string: any}
        if storageAny.bulkCopy then
            -- FFI storage with optimized bulk copy
            local bulkCopyFn = storageAny.bulkCopy as function(any, any, integer, any, integer, integer)
            bulkCopyFn(storage, targetColumn, startRow, stagingColumn, 0, entityCount)
        else
            -- Fallback: element-by-element copy
            for i = 1, entityCount do
                (targetColumn as {any})[startRow + i] = (stagingColumn as {any})[i]
            end
        end
    end
end

local TRANSACTION_MT <const>: metatable<Transaction> = { __index = Transaction }

function Transaction:setWorld(world: types.World)
    self.world = world
end

function Transaction:setChangeObservers(observers: WeakArray<ArchetypeChangeObserver>)
    self.changeObservers = observers
end

function Transaction.new(
    entityIndex: EntityIndex,
    archetypeIndex: ArchetypeIndex,
    relationshipTracker: RelationshipTracker,
    nextEntityId: integer
): Transaction
    local self: Transaction = {
        firstEntityId = nextEntityId,
        nextEntityId = nextEntityId,
        stagingArchetypes = {},
        stagingArchetypePool = {},  -- Initialize the pool
        spawnedEntities = {},
        spawnComponents = {},
        spawnValues = {},
        despawns = {},
        pendingAdd = {},
        pendingRemove = {},
        mutatedValues = {},
        mutatedEntities = {},
        entityIndex = entityIndex,
        archetypeIndex = archetypeIndex,
        relationshipTracker = relationshipTracker,
        world = nil as types.World,
        newArchetypes = {},
        isDirty = false
    }
    return setmetatable(self, TRANSACTION_MT)
end

function Transaction:reset(nextEntityId: integer)
    self.firstEntityId = nextEntityId
    self.nextEntityId = nextEntityId
    if self.isDirty then
        table_clear(self.stagingArchetypes)
        table_clear(self.spawnedEntities)
        table_clear(self.spawnComponents)
        table_clear(self.spawnValues)
        table_clear(self.despawns)
        table_clear(self.pendingAdd)
        table_clear(self.pendingRemove)
        table_clear(self.mutatedValues)
        table_clear(self.mutatedEntities)
        table_clear(self.newArchetypes)
        self.isDirty = false
    end
end

-- Allocate a new entity ID
function Transaction:allocateEntityId(): integer
    local id = self.nextEntityId
    self.nextEntityId = id + 1
    return id
end

-- Stage a spawn (entity will be put in staging archetype)
function Transaction:spawn(id: integer)
    self.spawnedEntities[id] = true
    self.isDirty = true
end

-- Stage a despawn
function Transaction:despawn(id: integer)
    -- Special case: if entity was spawned in same transaction, cancel the spawn
    if self:isSpawn(id) then
        -- Remove from spawn tracking
        self.spawnedEntities[id] = nil
        self.spawnComponents[id] = nil
        self.spawnValues[id] = nil
        -- Don't mark as despawn since it never existed
        return
    end

    self.despawns[id] = true
    self.isDirty = true
end

-- Add/set a component (spawns go to staging, mutations stage for later)
function Transaction:addComponent(id: integer, componentType: Component, value: any)
    -- Ignore changes to despawned entities
    if self.despawns[id] then
        return
    end

    if self:isSpawn(id) then
        -- For spawns: accumulate components, create staging archetype later
        local components = self.spawnComponents[id]
        if not components then
            components = {}
            self.spawnComponents[id] = components
        end
        components[#components + 1] = componentType

        local values = self.spawnValues[id]
        if not values then
            values = {}
            self.spawnValues[id] = values
        end
        values[componentType] = value
    else
        -- For mutations: verify entity exists
        local archetypeId = self.entityIndex:get(id)
        if not archetypeId then
            error(string.format("Entity ID %d not found in any archetype", id))
        end

        -- Stage the operation
        local adds = self.pendingAdd[id]
        if not adds then
            adds = {}
            self.pendingAdd[id] = adds
        end
        adds[componentType] = true

        -- Store the value
        local values = self.mutatedValues[id]
        if not values then
            values = {}
            self.mutatedValues[id] = values
        end
        values[componentType] = value

        self.mutatedEntities[id] = true
    end
    self.isDirty = true
end

-- Finalize spawns by creating staging archetypes from accumulated components
function Transaction:_finalizeSpawns()
    -- First, process hooks for all spawned entities BEFORE grouping them
    -- This allows hooks to modify the spawn components
    for entityId, components in pairs(self.spawnComponents) do
        if components and #components > 0 then
            self:_processOnAddHooks(entityId, components)
        end
    end

    -- Also process entities that were spawned but have no components yet
    for entityId in pairs(self.spawnedEntities) do
        if not self.spawnComponents[entityId] then
            -- Create empty component list for this entity
            self.spawnComponents[entityId] = {}
            self.spawnValues[entityId] = {}
        end
    end

    -- Now group spawned entities by their FINAL component signature (after hooks)
    local entityGroups: {string: {integer}} = {}  -- signature -> entity list
    local componentSignatures: {string: {Component}} = {}  -- signature -> components

    for entityId, components in pairs(self.spawnComponents) do
        -- Sort components for consistent signature
        local sortedComponents = {}
        for i = 1, #components do
            sortedComponents[i] = components[i]
        end
        table.sort(sortedComponents, function(a, b): boolean
            return tostring(a) < tostring(b)
        end)

        -- Create signature
        local signature = ""
        for i = 1, #sortedComponents do
            signature = signature .. tostring(sortedComponents[i]) .. "|"
        end

        -- Group entity by signature
        local entityList = entityGroups[signature]
        if not entityList then
            entityList = {}
            entityGroups[signature] = entityList
            componentSignatures[signature] = sortedComponents
        end
        entityList[#entityList + 1] = entityId
    end

    -- Create staging archetypes for each group
    for signature, entities in pairs(entityGroups) do
        local components = componentSignatures[signature]
        local staging = self:_findOrCreateStagingArchetype(components)

        -- Add all entities to this staging archetype
        for _, entityId in ipairs(entities) do
            local entityIndex = staging.entities[0] + 1
            staging.entities = ffi.ensureCapacityInt32(staging.entities, entityIndex)
            (staging.entities as {integer})[entityIndex] = entityId
            setIntArraySize(staging.entities, entityIndex)

            -- Ensure columns have capacity
            for comp, column in pairs(staging.columns) do
                local storage = comp:getStorage()
                if storage.ensureCapacity then
                    local newColumn = storage:ensureCapacity(column as {Component}, entityIndex)
                    if newColumn ~= column then
                        staging.columns[comp] = newColumn
                    end
                end
            end

            -- Store component values
            local values = self.spawnValues[entityId]
            if values then
                for comp, value in pairs(values) do
                    local column = staging.columns[comp]
                    (column as {any})[entityIndex] = value
                end
            end
        end
    end
end

-- Helper: get components for a spawned entity so far (for getPendingComponent)
function Transaction:_getSpawnComponents(id: integer): {Component}
    return self.spawnComponents[id] or {}
end

-- Check if an entity is a spawn
function Transaction:isSpawn(id: integer): boolean
    return self.spawnedEntities[id] == true
end

-- Check if an entity is currently being despawned
function Transaction:isBeingDespawned(id: integer): boolean
    return self.currentlyDespawning and self.currentlyDespawning[id] == true
end

-- Remove a component from an entity
function Transaction:removeComponent(id: integer, component: Component)
    -- Ignore changes to despawned entities
    if self.despawns[id] then
        return
    end

    -- Error if trying to remove component from entity spawned in same transaction (immutability rule)
    if self:isSpawn(id) then
        error(string.format("Cannot remove components from entity %d in the same transaction where it was spawned. Spawned entities are immutable within their spawn transaction.", id))
    end

    -- Stage the removal
    local removes = self.pendingRemove[id]
    if not removes then
        removes = {}
        self.pendingRemove[id] = removes
    end
    removes[component] = true
    self.mutatedEntities[id] = true
    self.isDirty = true
end

-- Mutate a component value (existing entity only)
function Transaction:mutateComponent(id: integer, component: Component, value: any)
    -- Ignore changes to despawned entities
    if self.despawns[id] then
        return
    end

    -- Error if trying to mutate component on entity spawned in same transaction (immutability rule)
    if self:isSpawn(id) then
        error(string.format("Cannot mutate components on entity %d in the same transaction where it was spawned. Spawned entities are immutable within their spawn transaction.", id))
    end

    -- Store the mutated value
    local values = self.mutatedValues[id]
    if not values then
        values = {}
        self.mutatedValues[id] = values
    end
    values[component] = value
    self.mutatedEntities[id] = true
    self.isDirty = true
end

-- Check if there are any changes
function Transaction:hasChanges(): boolean
    local hasSpawns = next(self.spawnedEntities) ~= nil
    local hasDespawns = next(self.despawns) ~= nil
    local hasMutations = next(self.mutatedEntities) ~= nil

    return hasSpawns or hasDespawns or hasMutations
end

-- Find or create a staging archetype for the given component set
function Transaction:_findOrCreateStagingArchetype(components: {Component}): StagingArchetype
    -- Sort components for consistent lookup
    local sortedComponents = {}
    for i = 1, #components do
        sortedComponents[i] = components[i]
    end
    table.sort(sortedComponents, function(a, b): boolean
        return tostring(a) < tostring(b)
    end)

    -- Calculate component hash for this component set using same algorithm as ArchetypeIndex
    local h1, h2 = 0, 0
    for i = 1, #sortedComponents do
        local comp = sortedComponents[i]
        local k = comp.componentHash or comp.componentId or i
        h1 = bxor(h1, k as integer)
        -- 32-bit additive accumulator
        h2 = (h2 + (k as integer)) % 0x100000000
    end
    -- fold to a single 32-bit hash (same as ArchetypeIndex)
    local componentHash = band(bxor(h1, h2), 0xFFFFFFFF)

    -- Try to find existing staging archetype with same component hash
    for _, staging in ipairs(self.stagingArchetypes) do
        if staging.componentHash == componentHash and #staging.components == #sortedComponents then
            -- Double-check exact match
            local matches = true
            for i = 1, #sortedComponents do
                if sortedComponents[i] ~= staging.components[i] then
                    matches = false
                    break
                end
            end
            if matches then
                return staging
            end
        end
    end

    -- Check the pool for a reusable staging archetype
    local pooled = self.stagingArchetypePool[componentHash]
    if pooled then
        for _, staging in ipairs(pooled) do
            if #staging.components == #sortedComponents then
                -- Double-check exact match
                local matches = true
                for i = 1, #sortedComponents do
                    if sortedComponents[i] ~= staging.components[i] then
                        matches = false
                        break
                    end
                end
                if matches then
                    -- Reuse this pooled staging archetype
                    -- Reset its state but keep allocated memory
                    setIntArraySize(staging.entities, 0)  -- Just reset count, keep FFI array allocated
                    staging.isPromoted = false

                    -- Clear column data but keep arrays allocated
                    for comp, column in pairs(staging.columns) do
                        local storage = comp:getStorage()
                        if storage.clear then
                            storage:clear(column as {Component})
                        end
                    end

                    -- Add to active staging archetypes
                    self.stagingArchetypes[#self.stagingArchetypes + 1] = staging
                    return staging
                end
            end
        end
    end

    -- Create new staging archetype with real archetype structure
    local staging: StagingArchetype = {
        id = -(#self.stagingArchetypes + 1),  -- Negative temporary ID
        entities = ffi.newInt32(16),  -- Start with small FFI array
        columns = {},
        columnsCount = #sortedComponents,
        componentHash = componentHash,
        components = sortedComponents,
        isPromoted = false,
        promoteToReal = StagingArchetype.promoteToReal,
        mergeIntoExisting = StagingArchetype.mergeIntoExisting
    }

    -- Create real typed columns for each component (like real archetype)
    for i = 1, #sortedComponents do
        local comp = sortedComponents[i]
        local storage = comp:getStorage()
        local column = storage:new(0)  -- Start with zero capacity, will grow
        staging.columns[comp] = column
    end

    setmetatable(staging, STAGING_ARCHETYPE_MT)
    self.stagingArchetypes[#self.stagingArchetypes + 1] = staging
    return staging
end

-- Process a staging archetype: either promote to new archetype or merge into existing
function Transaction:_processStagingArchetype(staging: StagingArchetype)
    local entityCount = staging.entities[0]
    if entityCount == 0 then
        return
    end

    -- Check if archetype with these components already exists
    local existingArchetype = self.archetypeIndex:findExact(staging.components)

    if existingArchetype then
        -- Merge into existing archetype (single memcpy per column)
        staging:mergeIntoExisting(existingArchetype)

        -- Update entity index for all spawned entities
        local existingImpl = existingArchetype as ArchetypeImpl
        local startRow = existingImpl.entities[0] - entityCount  -- New entities start here
        for i = 1, entityCount do
            local entityId = (staging.entities as {integer})[i]
            local row = startRow + i - 1
            self.entityIndex:set(entityId, existingArchetype.id, row)  -- 0-based for entity index

            -- Track relationships for spawned entities
            for component, column in pairs(existingArchetype.columns) do
                if component is types.Relationship then
                    local relInstance = (column as {any})[row + 1]  -- +1 for Lua indexing
                    if relInstance then
                        local rel = relInstance as types.Relationship
                        self.relationshipTracker:add(entityId, rel)
                    end
                end
            end

            -- Notify change observers about the entity being spawned (from nil to archetype)
            if self.changeObservers then
                for j = 1, #self.changeObservers do
                    local observer = self.changeObservers[j]
                    if observer and observer.onEntityChange then  -- Skip GC'd weak references
                        observer:onEntityChange(entityId, nil, existingArchetype, row)
                    end
                end
            end
        end

        LOGGER:debug("Merged %d entities into existing archetype %d", entityCount, existingArchetype.id)
    else
        -- Promote staging to real archetype (zero-copy!)
        local realArchetype = staging:promoteToReal(self.archetypeIndex)
        self.newArchetypes[#self.newArchetypes + 1] = realArchetype

        -- Update entity index for all spawned entities
        for i = 1, entityCount do
            local entityId = (staging.entities as {integer})[i]
            local row = i - 1
            self.entityIndex:set(entityId, realArchetype.id, row)  -- 0-based for entity index

            -- Track relationships for spawned entities
            for component, column in pairs(realArchetype.columns) do
                if component is types.Relationship then
                    local relInstance = (column as {any})[row + 1]  -- +1 for Lua indexing
                    if relInstance then
                        local rel = relInstance as types.Relationship
                        self.relationshipTracker:add(entityId, rel)
                    end
                end
            end

            -- Notify change observers about the entity being spawned (from nil to archetype)
            if self.changeObservers then
                for j = 1, #self.changeObservers do
                    local observer = self.changeObservers[j]
                    if observer and observer.onEntityChange then  -- Skip GC'd weak references
                        observer:onEntityChange(entityId, nil, realArchetype, row)
                    end
                end
            end
        end

        LOGGER:debug("Promoted staging archetype to new archetype %d with %d entities", realArchetype.id, entityCount)
    end
end

-- Get the final component set for a mutated entity
function Transaction:_getFinalComponentsForMutation(id: integer): {Component}
    local components: {Component} = {}

    -- Start with existing components
    local archetypeId, _ = self.entityIndex:get(id)
    if not archetypeId then
        return components  -- Entity doesn't exist
    end

    local archetype = self.archetypeIndex[archetypeId]
    if not archetype then
        return components
    end

    -- Use a set for O(1) duplicate checking
    local componentSet: {Component: boolean} = {}

    -- Start with existing components (minus removes)
    local removes = self.pendingRemove[id]
    for comp in pairs(archetype.columns) do
        if not removes or not removes[comp] then
            componentSet[comp] = true
        end
    end

    -- Add new components
    local adds = self.pendingAdd[id]
    if adds then
        for comp in pairs(adds) do
            componentSet[comp] = true
        end
    end

    -- Convert set back to array
    for comp in pairs(componentSet) do
        components[#components + 1] = comp
    end

    return components
end

-- Simplified commit: promote/merge staging archetypes and process mutations
function Transaction:commit()
    if not self:hasChanges() then
        LOGGER:debug("Transaction:commit - no changes to commit")
        return
    end

    -- Only count for debug logging when we actually have changes
    LOGGER:debug("Committing transaction with %d accumulated spawns, %d mutations, %d despawns",
        self:_countSpawns(),
        self:_countMutations(),
        self:_countDespawns())

    -- Step 1: Process despawns first
    self:_processDespawns()

    -- Step 2: Finalize spawns into staging archetypes
    self:_finalizeSpawns()

    -- Step 3: Process staging archetypes (promote to new or merge into existing)
    for _, staging in ipairs(self.stagingArchetypes) do
        self:_processStagingArchetype(staging)
    end

    -- Step 4: Process mutations (entities changing archetypes)
    self:_processMutations()

    LOGGER:debug("Transaction commit completed")
end

-- Count spawns for logging
function Transaction:_countSpawns(): integer
    local count = 0
    for _ in pairs(self.spawnedEntities) do
        count = count + 1
    end
    return count
end

-- Count mutations for logging
function Transaction:_countMutations(): integer
    local count = 0
    for _ in pairs(self.mutatedEntities) do
        count = count + 1
    end
    return count
end

-- Count despawns for logging
function Transaction:_countDespawns(): integer
    local count = 0
    for _ in pairs(self.despawns) do
        count = count + 1
    end
    return count
end

-- Process despawns by removing entities from their archetypes
function Transaction:_processDespawns()
    -- First, emit OnDespawn events for all entities being despawned
    -- This must happen BEFORE the entities are removed from archetypes
    if self.world then
        local builtins = require("tecs.internal.builtins")
        for entityId in pairs(self.despawns) do
            -- Mark entity as currently being despawned
            self.currentlyDespawning = self.currentlyDespawning or {}
            self.currentlyDespawning[entityId] = true

            -- Get the entity's emitter (if it has one)
            local world = self.world as types.World
            local getEntityEmitter = world.getEntityEmitter
            if getEntityEmitter then
                local emitter = getEntityEmitter(world, entityId)
                if emitter then
                    -- Emit OnDespawn event
                    emitter:emit(builtins.OnDespawn(entityId))
                end
            end
        end
    end

    -- Group despawns by archetype for efficient batch removal
    local removalsByArchetype: {integer: {integer: boolean}} = {}

    for entityId in pairs(self.despawns) do
        local archetypeId, _row = self.entityIndex:get(entityId)
        if archetypeId then
            local removals = removalsByArchetype[archetypeId]
            if not removals then
                removals = {}
                removalsByArchetype[archetypeId] = removals
            end
            removals[entityId] = true
        end
    end

    -- Remove entities from each archetype
    for archetypeId, removals in pairs(removalsByArchetype) do
        local archetype = self.archetypeIndex[archetypeId]
        if archetype then
            self:_removeEntitiesFromArchetype(archetype, removals)
        end
    end

    -- Clear the currently despawning flag
    self.currentlyDespawning = nil
end

-- Remove entities from an archetype using compaction
function Transaction:_removeEntitiesFromArchetype(archetype: Archetype, removals: {integer: boolean})
    local archImpl = archetype as ArchetypeImpl
    local entities = archImpl.entities as {integer}  -- Cast for indexing
    local currentLen = archImpl.entities[0]
    local writePos = 1

    -- Compact entities array and component columns
    for readPos = 1, currentLen do
        local entityId = entities[readPos]

        if not removals[entityId] then
            -- Keep this entity
            if readPos ~= writePos then
                entities[writePos] = entityId
                self.entityIndex:set(entityId, archetype.id, writePos - 1)  -- 0-based

                -- Move component data
                for component, column in pairs(archetype.columns) do
                    local storage = component:getStorage()
                    local storageAny = storage as {string:any}

                    if storageAny._ffiConstructor and storageAny.swap then
                        -- FFI storage with swap method
                        local swapFn = storageAny.swap as function(any, integer, integer)
                        swapFn(column, writePos - 1, readPos - 1)  -- 0-based
                    else
                        -- Table storage
                        (column as {any})[writePos] = (column as {any})[readPos]
                    end
                end
            end
            writePos = writePos + 1
        else
            -- Entity being removed - clean up
            self.entityIndex:delete(entityId)

            -- Get relationships that need to be removed from other entities
            local relationshipsToRemove = self.relationshipTracker:cleanupEntity(entityId)

            -- Process relationship removals immediately (trigger onRemove hooks)
            if self.world then
                for sourceEntity, relationship in pairs(relationshipsToRemove) do
                    -- Get the source entity's archetype and position
                    local sourceArchId, sourceRow = self.entityIndex:get(sourceEntity)
                    if sourceArchId then
                        local sourceArch = self.archetypeIndex[sourceArchId]
                        if sourceArch and sourceArch.columns[relationship] then
                            -- Get the relationship instance
                            local relColumn = sourceArch.columns[relationship]
                            local relInstance = (relColumn as {any})[sourceRow + 1]  -- +1 for Lua indexing

                            -- Call the onRemove hook if it exists
                            if relInstance and relationship.onRemove then
                                local changeView = ChangeViewClass.new(sourceEntity, self, self.entityIndex)
                                relationship.onRemove(relInstance as types.Component, self.world, sourceEntity, changeView)

                                -- Check if the entity was despawned during the hook (cascade delete)
                                -- This happens when the hook calls world:despawn(entityId)
                                if self.despawns[sourceEntity] then
                                    -- Add to current despawn processing
                                    self.despawnsDuringHooks = self.despawnsDuringHooks or {}
                                    self.despawnsDuringHooks[sourceEntity] = true
                                end
                            end

                            -- Actually remove the relationship from the source entity
                            -- This needs to be queued as a mutation for the next frame
                            self.pendingRemove[sourceEntity] = self.pendingRemove[sourceEntity] or {}
                            self.pendingRemove[sourceEntity][relationship] = true
                            self.mutatedEntities[sourceEntity] = true
                        end
                    end
                end
            end

            -- Notify change observers about the entity removal (from archetype to nil)
            if self.changeObservers then
                for j = 1, #self.changeObservers do
                    local observer = self.changeObservers[j]
                    if observer and observer.onEntityChange then  -- Skip GC'd weak references
                        observer:onEntityChange(entityId, archetype, nil, readPos - 1)  -- from archetype to nil (despawn)
                    end
                end
            end

            -- Call onRemove hooks if world is available
            if self.world then
                local componentsToRemove: {Component} = {}
                for component in pairs(archetype.columns) do
                    if component.onRemove then
                        componentsToRemove[#componentsToRemove + 1] = component
                    end
                end

                if #componentsToRemove > 0 then
                    -- Create a ChangeView for the entity being despawned
                    local changeView = ChangeViewClass.new(entityId, self, self.entityIndex)

                    for j = 1, #componentsToRemove do
                        local component = componentsToRemove[j]
                        local column = archetype.columns[component]
                        local value = (column as {any})[readPos]
                        if value ~= nil then
                            component.onRemove(value as types.Component, self.world, entityId, changeView)
                        end
                    end
                end
            end
        end
    end

    -- Update count (FFI arrays don't need explicit clearing)
    setIntArraySize(archImpl.entities, writePos - 1)

    -- Clear remaining slots in component columns
    for i = writePos, currentLen do
        for component, column in pairs(archetype.columns) do
            local storage = component:getStorage()
            local storageAny = storage as {string:any}
            if not storageAny or not storageAny._ffiConstructor then
                (column as {any})[i] = nil
            end
        end
    end

    -- Process cascade despawns that were triggered during hooks
    if self.despawnsDuringHooks then
        for cascadeEntity in pairs(self.despawnsDuringHooks) do
            if not self.despawns[cascadeEntity] then
                -- Add to despawns for next iteration
                self.despawns[cascadeEntity] = true
            end
        end
        -- Clear for next batch
        self.despawnsDuringHooks = nil

        -- Recursively process the new despawns
        self:_processDespawns()
    end
end

--[[
Process mutations and move entities between archetypes at most once, even as hooks add/remove components.

This method uses a two-phase approach to handle component hooks that may add new mutations:

Phase 1: Hook Processing (Multi-pass)
- Process component hooks in multiple passes without moving entities between archetypes
- Each pass processes entities that were mutated in previous passes
- Hooks can call world:set() to add mutations to other entities
- New mutations are queued for processing in subsequent passes
- Continues until no new mutations are added (convergence)
- Limited to MAX_MUTATION_PASSES (10) to prevent infinite loops

Phase 2: Bulk Archetype Moves
- After all hooks are processed, move all entities to their final archetypes
]]
function Transaction:_processMutations()
    -- Scratch are reused throughout
    local mutatedEntityIds: {integer} = pool.acquireArray(16)
    local componentScratchArray: {Component} = pool.acquireArray(8)
    local processedEntities: {integer: boolean} = pool.acquireMap()

    -- Process mutations in multiple passes to handle hooks adding new mutations
    local needsAnotherPass = true
    local passes = 0
    local MAX_MUTATION_PASSES <const> = 10

    while needsAnotherPass and passes < MAX_MUTATION_PASSES do
        table_clear(mutatedEntityIds)
        needsAnotherPass = false
        passes = passes + 1

        for entityId in pairs(self.mutatedEntities) do
            if not processedEntities[entityId] then
                mutatedEntityIds[#mutatedEntityIds + 1] = entityId
                processedEntities[entityId] = true
                needsAnotherPass = true
            end
        end

        -- Process hooks for entities in this pass (note that we aren't moving archetypes yet)
        for i = 1, #mutatedEntityIds do
            local entityId = mutatedEntityIds[i]
            if not self.despawns[entityId] then
                local archetypeId, _ = self.entityIndex:get(entityId)
                if archetypeId then
                    local oldArchetype = self.archetypeIndex[archetypeId]
                    if oldArchetype then
                        -- First, process onRemove hooks for components being removed
                        local removes = self.pendingRemove[entityId]
                        if removes then
                            table_clear(componentScratchArray)
                            for comp in pairs(removes) do
                                if oldArchetype.columns[comp] then
                                    componentScratchArray[#componentScratchArray + 1] = comp
                                end
                            end
                            if #componentScratchArray > 0 then
                                self:_processOnRemoveHooks(entityId, componentScratchArray)
                            end
                        end

                        -- Next process any onAdd hooks for components being added
                        local adds = self.pendingAdd[entityId]
                        if adds then
                            table_clear(componentScratchArray)
                            for comp in pairs(adds) do
                                if not oldArchetype.columns[comp] then
                                    componentScratchArray[#componentScratchArray + 1] = comp
                                end
                            end
                            if #componentScratchArray > 0 then
                                self:_processOnAddHooks(entityId, componentScratchArray)
                            end
                        end
                    end
                end
            end
        end
    end

    if passes >= MAX_MUTATION_PASSES then
        LOGGER:warn("Max mutation passes reached while processing mutations")
    end

    table_clear(mutatedEntityIds)
    for entityId in pairs(self.mutatedEntities) do
        if not self.despawns[entityId] then
            mutatedEntityIds[#mutatedEntityIds + 1] = entityId
        end
    end

    -- Process archetype moves
    for i = 1, #mutatedEntityIds do
        local entityId = mutatedEntityIds[i]
        local newComponents = self:_getFinalComponentsForMutation(entityId)
        local newArchetype = self.archetypeIndex:getOrCreate(newComponents, function(newArch: Archetype)
            self.newArchetypes[#self.newArchetypes + 1] = newArch
        end)
        self:_moveEntityToArchetype(entityId, newArchetype)
    end

    pool.releaseArray(mutatedEntityIds)
    pool.releaseArray(componentScratchArray)
    pool.releaseMap(processedEntities)
end

-- Move an entity to a different archetype
function Transaction:_moveEntityToArchetype(entityId: integer, newArchetype: Archetype)
    local oldArchetypeId, oldRow = self.entityIndex:get(entityId)
    if not oldArchetypeId then
        return  -- Entity doesn't exist
    end

    local oldArchetype = self.archetypeIndex[oldArchetypeId]
    if not oldArchetype then
        return
    end

    if newArchetype.id == oldArchetypeId then
        -- Same archetype, just update component values
        local mutatedValues = self.mutatedValues[entityId]
        if mutatedValues then
            for component, value in pairs(mutatedValues) do
                local column = newArchetype.columns[component]
                if column then
                    (column as {any})[oldRow + 1] = value  -- +1 for Lua indexing
                end
            end
        end
        return
    end

    -- Different archetype - move entity
    -- First, add to new archetype
    local newArchImpl = newArchetype as ArchetypeImpl
    local newRow = newArchImpl.entities[0]  -- 0-based
    newArchImpl.entities = ffi.ensureCapacityInt32(newArchImpl.entities, newRow + 1)
    (newArchImpl.entities as {integer})[newRow + 1] = entityId
    setIntArraySize(newArchImpl.entities, newRow + 1)

    -- Copy/set component values
    for component, newColumn in pairs(newArchetype.columns) do
        local storage = component:getStorage()

        -- Ensure capacity
        if storage.ensureCapacity then
            local expandedColumn = storage:ensureCapacity(newColumn, newRow + 1)
            if expandedColumn ~= newColumn then
                newArchetype.columns[component] = expandedColumn
                newColumn = expandedColumn
            end
        end

        -- Check if this component was mutated
        local mutatedValues = self.mutatedValues[entityId]
        local mutatedValue = mutatedValues and mutatedValues[component]

        if mutatedValue ~= nil then
            -- Use mutated value
            (newColumn as {any})[newRow + 1] = mutatedValue
        else
            -- Copy from old archetype if it exists there
            local oldColumn = oldArchetype.columns[component]
            if oldColumn then
                (newColumn as {any})[newRow + 1] = (oldColumn as {any})[oldRow + 1]
            end
            -- If not in old archetype, leave as default (already handled by ensureCapacity)
        end
    end

    -- Update entity index
    self.entityIndex:set(entityId, newArchetype.id, newRow)

    -- Track relationships (add new ones, remove old ones)
    -- Check for relationships being added
    for component, newColumn in pairs(newArchetype.columns) do
        if component is types.Relationship then
            -- This is a relationship component
            if not oldArchetype.columns[component] then
                -- This relationship was added
                local relInstance = (newColumn as {any})[newRow + 1]
                if relInstance then
                    local rel = relInstance as types.Relationship
                    self.relationshipTracker:add(entityId, rel)
                end
            end
        end
    end

    -- Check for relationships being removed
    for component, oldColumn in pairs(oldArchetype.columns) do
        if component is types.Relationship then
            -- This is a relationship component
            if not newArchetype.columns[component] then
                -- This relationship was removed
                local relInstance = (oldColumn as {any})[oldRow + 1]
                if relInstance then
                    local rel = relInstance as types.Relationship
                    self.relationshipTracker:remove(entityId, rel)
                end
            end
        end
    end

    -- Notify change observers about the entity movement
    if self.changeObservers then
        for i = 1, #self.changeObservers do
            local observer = self.changeObservers[i]
            if observer and observer.onEntityChange then  -- Skip GC'd weak references
                observer:onEntityChange(entityId, oldArchetype, newArchetype, newRow)
            end
        end
    end

    -- Remove from old archetype (compact)
    self:_removeEntityFromArchetype(oldArchetype, entityId, oldRow)
end

-- Remove a single entity from an archetype by swapping with the last
function Transaction:_removeEntityFromArchetype(archetype: Archetype, _entityId: integer, row: integer)
    local archImpl = archetype as ArchetypeImpl
    local entities = archImpl.entities as {integer}  -- Cast for indexing
    local lastIndex = archImpl.entities[0]

    if row + 1 == lastIndex then
        -- Removing the last entity, just truncate
        setIntArraySize(archImpl.entities, archImpl.entities[0] - 1)
        for component, column in pairs(archetype.columns) do
            local storage = component:getStorage()
            local componentInstance = (column as {any})[lastIndex]
            if componentInstance then
                -- Recycle the component instance back to storage pool
                storage:recycle(componentInstance as Component)
                -- Clear the column slot for non-FFI components
                local storageAny = storage as {string:any}
                if not storageAny._ffiConstructor then
                    (column as {any})[lastIndex] = nil
                end
            end
        end
    else
        -- Swap with last entity
        local lastEntityId = entities[lastIndex]
        entities[row + 1] = lastEntityId
        setIntArraySize(archImpl.entities, archImpl.entities[0] - 1)

        -- Update entity index for swapped entity
        self.entityIndex:set(lastEntityId, archetype.id, row)

        -- Swap component data
        for component, column in pairs(archetype.columns) do
            local storage = component:getStorage()

            -- Recycle the component being removed
            local componentToRemove = (column as {any})[row + 1]
            if componentToRemove then
                storage:recycle(componentToRemove as Component)
            end

            -- Use storage swap implementation (both use 1-based indexing)
            storage:swap(column, row + 1, lastIndex)

            -- Clear the last slot for table storage
            local storageAny = storage as {string:any}
            if not storageAny._ffiConstructor then
                (column as {any})[lastIndex] = nil
            end
        end
    end
end


-- Clear staging data after commit (but preserve entity ID tracking)
function Transaction:clearStagingData()
    -- Return staging archetypes to pool for reuse
    for _, staging in ipairs(self.stagingArchetypes) do
        -- Don't pool promoted archetypes
        if not staging.isPromoted then
            local hash = staging.componentHash
            if not self.stagingArchetypePool[hash] then
                self.stagingArchetypePool[hash] = {}
            end
            local pool = self.stagingArchetypePool[hash]

            -- Only keep a reasonable number in the pool (e.g., 3 per hash)
            if #pool < 3 then
                -- Clear entity count but keep FFI array allocated
                setIntArraySize(staging.entities, 0)

                -- Clear column data but keep arrays allocated
                for comp, column in pairs(staging.columns) do
                    local storage = comp:getStorage()
                    if storage.clear then
                        storage:clear(column as {Component})
                    end
                end

                pool[#pool + 1] = staging
            end
        end
    end

    -- Clear spawn staging
    table_clear(self.stagingArchetypes)
    table_clear(self.spawnedEntities)
    table_clear(self.spawnComponents)
    table_clear(self.spawnValues)

    -- Clear mutation staging
    table_clear(self.despawns)
    table_clear(self.pendingAdd)
    table_clear(self.pendingRemove)
    table_clear(self.mutatedValues)
    table_clear(self.mutatedEntities)

    -- Clear new archetypes
    table_clear(self.newArchetypes)

    -- Reset dirty flag since we've cleared everything
    self.isDirty = false

    -- DO NOT reset firstEntityId or nextEntityId - they must be preserved
end

function Transaction:getNewArchetypes(): {Archetype}
    return self.newArchetypes
end

-- Get a pending component value from the transaction
function Transaction:getPendingComponent<C is Component>(id: integer, component: C): C
    -- Check if entity is despawned
    if self.despawns[id] then
        return nil as C
    end

    -- Check if component is marked for removal
    local removes = self.pendingRemove[id]
    if removes and removes[component] then
        return nil as C
    end

    if self:isSpawn(id) then
        -- Check accumulated spawn values for spawned entities
        local values = self.spawnValues[id]
        if values then
            local value = values[component]
            if value ~= nil then
                return value as C
            end
        end
    else
        -- Check mutated values for existing entities
        local mutatedValues = self.mutatedValues[id]
        if mutatedValues then
            local value = mutatedValues[component]
            if value ~= nil then
                return value as C
            end
        end
    end

    return nil as C
end

-- Process onAdd hooks for a set of components being added to an entity
function Transaction:_processOnAddHooks(entityId: integer, components: {Component})
    if not self.world then
        return
    end

    -- Track which hooks we've already called to avoid infinite loops
    local calledHooks: {Component: boolean} = {}

    -- Build initial list of components to process hooks for
    local componentsToProcess: {Component: boolean} = {}
    for _, comp in ipairs(components) do
        componentsToProcess[comp] = true
    end

    local needsAnotherPass = true
    local passes = 0
    local MAX_PASSES <const> = 10

    while needsAnotherPass and passes < MAX_PASSES do
        needsAnotherPass = false
        passes = passes + 1

        -- Process hooks for components that haven't been processed yet
        for component in pairs(componentsToProcess) do
            if not calledHooks[component] and component.onAdd then
                calledHooks[component] = true

                -- Create change view for this entity
                local changeView = ChangeViewClass.new(entityId, self, self.entityIndex)

                -- Get the component value
                local value = changeView:get(component)
                if value then
                    -- Call the hook
                    component.onAdd(value, self.world, entityId, changeView)

                    -- Check if the hook added new components
                    for newComp in pairs(changeView.localAdds) do
                        if not componentsToProcess[newComp] then
                            componentsToProcess[newComp] = true
                            needsAnotherPass = true
                        end
                    end
                end
            end
        end
    end

    if passes >= MAX_PASSES then
        LOGGER:warn("Max passes reached while processing onAdd hooks for entity ", entityId)
    end
end

-- Process onRemove hooks for components being removed from an entity
function Transaction:_processOnRemoveHooks(entityId: integer, components: {Component})
    if not self.world then
        return
    end

    for _, component in ipairs(components) do
        if component.onRemove then
            -- Create change view for this entity
            local changeView = ChangeViewClass.new(entityId, self, self.entityIndex)

            -- Get the component value before removal
            local archetypeId, row = self.entityIndex:get(entityId)
            if archetypeId then
                local archetype = self.archetypeIndex[archetypeId]
                if archetype then
                    local column = archetype.columns[component]
                    if column then
                        local value = (column as {any})[row + 1]
                        if value then
                            -- Call the hook
                            component.onRemove(value, self.world, entityId, changeView)
                        end
                    end
                end
            end
        end
    end
end

return Transaction