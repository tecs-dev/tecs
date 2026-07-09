--[[
Batch staging + drain.

`_deferBatchSpawn` / `_deferBatchSpawnAt`: resolve the shared archetype,
enqueue a placement descriptor on its `batchSpawnQueue`. `_drainArchBatchSpawn`
/ `_drainArchBatchSpawnAt` drain those at commit time.

`_deferBatchSet` / `_deferBatchRemove` / `_deferBatchSetCallback`: enqueue
one `BatchMutation` per call on `world.batchMutations`. `_drainBatchMutations`
walks the list in enqueue order at commit time.

`_deferBatchDespawn`: walks archetypes eagerly with a per-entity path when
dense relationships or reverse-index targets need unlink/cascade work,
otherwise a bulk archetype-truncate path.
]]

local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")
local IdAllocator <const> = require("tecs.internal.IdAllocator")
local builtins <const> = require("tecs.internal.builtins")
local behavior <const> = require("tecs.internal.behavior")
local shared <const> = require("tecs.internal.world.shared")

local type Component = types.components.Component
local type Archetype = internal.ArchetypeInternal
local type ComponentInternal = internal.ComponentInternal
local type EntitySlot = IdAllocator.EntitySlot
local type BatchMutation = shared.BatchMutation
local type RequireEntry = internal.RequireEntry

local WorldImpl = internal.WorldImpl

local STATE_SPAWN <const> = shared.STATE_SPAWN
local STATE_MUTATE <const> = shared.STATE_MUTATE
local STATE_DESPAWN <const> = shared.STATE_DESPAWN
local BATCH_OP_SET_CONST <const> = shared.BATCH_OP_SET_CONST
local BATCH_OP_SET_CALLBACK <const> = shared.BATCH_OP_SET_CALLBACK
local BATCH_OP_REMOVE <const> = shared.BATCH_OP_REMOVE

local applyBatchSet <const> = shared.applyBatchSet
local applyBatchRemove <const> = shared.applyBatchRemove
local applyRequires <const> = shared.applyRequires
local writeRequiredRange <const> = shared.writeRequiredRange

local table_clear <const> = require("table.clear")
local floor <const> = math.floor

-- batchSpawnQueue layout: each entry is 5 slots -- {count, firstSlotOrIdsList,
-- callback, mode, requiredList}. RANGE uses a scalar `firstSlot` and strict
-- contiguous ids; LIST uses an `ids` array for best-effort / explicit id sets.
-- `requiredList` is the entries from `applyRequires` whose default values
-- must be written into each spawned row at drain time (or nil).
local BATCH_SPAWN_SLOTS <const> = 5
local BATCH_SPAWN_MODE_RANGE <const> = 1
local BATCH_SPAWN_MODE_LIST <const> = 2

-- `batchSpawnAt` queue layout: 4 slots per request (ids, count, callback,
-- requiredList). `ids` is either a Lua `{integer}` (1-based) or an FFI
-- `double[count]` (0-based); `_drainArchBatchSpawnAt` dispatches once per
-- entry by `type(ids)` so each loop stays monomorphic. `requiredList` is
-- the entries from `applyRequires` whose default values must be written
-- into each spawned row at drain time (or nil).
local BATCH_SPAWN_AT_SLOTS <const> = 4

local function validateBatchCount(name: string, count: integer)
    if count < 1 or count ~= floor(count) then
        error(name .. ": count must be a positive integer, got " .. tostring(count))
    end
end

-- Pre-stake pending spawn-at ids: marks each slot as pending spawn onto
-- `archetype` (without row placement) so mid-frame mutations against
-- any of the ids see them as valid. Actual placement runs at commit in
-- `_drainArchBatchSpawnAt`.
local function stakePendingSpawnAt(
    self: WorldImpl,
    archetype: Archetype,
    count: integer,
    readId: function(integer): integer
)
    local arena = self.allocator
    local slots = arena.slots as {integer: EntitySlot}
    -- Cache FFI arrays + epoch. Hot-loop inline reads/writes trace
    -- better than per-iter helper dispatch.
    local pendingArr = self._pendingArchArr as {integer:integer}
    local stateArr = self._stateArr as {integer:integer}
    local slotStamp = self._slotStamp as {integer:integer}
    local epoch = self._transactionEpoch
    local archId = archetype.id
    local stateCount = self.entityStateCount
    for i = 0, count - 1 do
        local id = readId(i)
        local slot = IdAllocator.slotOf(id)
        if slot >= arena.nextFreshSlot then
            arena.nextFreshSlot = slot + 1
        elseif arena.freeCount > 0 then
            -- A previously despawned slot may sit on the free stack; a
            -- later allocSlot would alias the revived entity.
            IdAllocator.unfree(arena, slot)
        end
        slots[slot].generation = IdAllocator.generationOfWithSlot(id, slot)
        if slotStamp[slot] ~= epoch then
            slotStamp[slot] = epoch
            pendingArr[slot] = archId
            stateArr[slot] = STATE_SPAWN
            stateCount = stateCount + 1
        else
            pendingArr[slot] = archId
            if stateArr[slot] == 0 then
                stateArr[slot] = STATE_SPAWN
                stateCount = stateCount + 1
            end
        end
    end
    self.entityStateCount = stateCount
end

local pairs <const> = pairs

local macro ensureDirty!(archExpr: Expression)
    return ```
        if $archExpr.dirtyQueuedEpoch ~= self._dirtyEpoch then
            $archExpr.dirtyQueuedEpoch = self._dirtyEpoch
            local __c = self.dirtyArchetypeCount + 1
            self.dirtyArchetypeList[__c] = $archExpr
            self.dirtyArchetypeCount = __c
        end
    ```
end

local macro markDirty!(archExpr: Expression, flagField: Expression)
    return ```
        $archExpr.$flagField = true
        if $archExpr.dirtyQueuedEpoch ~= self._dirtyEpoch then
            $archExpr.dirtyQueuedEpoch = self._dirtyEpoch
            local __c = self.dirtyArchetypeCount + 1
            self.dirtyArchetypeList[__c] = $archExpr
            self.dirtyArchetypeCount = __c
        end
    ```
end

-- Shared placement body for every batch spawn drain loop. Reads/writes
-- the caller's locals (slots, stateArr, slotStamp, epoch, archId,
-- entitiesArr, currentCount, placed, archetype, self); `$slotExpr` may
-- reference the freshly-bound `entityId`. Resolves the slot's
-- transaction state: despawned slots skip placement, mutated slots keep
-- their stamp so the move drain relocates them, everything else commits
-- in place. The `do ... end` scopes temporaries so repeated expansions
-- don't collide, and each expansion stays a single monomorphic loop
-- body.
local macro placeStakedRow!(idExpr: Expression, slotExpr: Expression)
    return ```
        do
            local entityId = $idExpr
            local entSlot = $slotExpr
            local st = (slotStamp[entSlot] == epoch and stateArr[entSlot] or 0)
            if st == STATE_DESPAWN then
                slotStamp[entSlot] = 0
            else
                local row = currentCount + placed
                entitiesArr[row + 1] = entityId
                local es = slots[entSlot]
                es.archetypeId = archId
                es.row = row
                placed = placed + 1
                if st == STATE_MUTATE then
                    -- Inlined markDirty! body (macros don't compose).
                    archetype.hasPendingMoveOut = true
                    if archetype.dirtyQueuedEpoch ~= self._dirtyEpoch then
                        archetype.dirtyQueuedEpoch = self._dirtyEpoch
                        local __c = self.dirtyArchetypeCount + 1
                        self.dirtyArchetypeList[__c] = archetype
                        self.dirtyArchetypeCount = __c
                    end
                else
                    slotStamp[entSlot] = 0
                end
            end
        end
    ```
end

-- Fast placement when the transaction holds no per-slot state at all:
-- no state checks, every id places.
local macro placeFreshRow!(idExpr: Expression, slotExpr: Expression)
    return ```
        do
            local entityId = $idExpr
            local entSlot = $slotExpr
            local row = currentCount + placed
            entitiesArr[row + 1] = entityId
            local es = slots[entSlot]
            es.archetypeId = archId
            es.row = row
            placed = placed + 1
            slotStamp[entSlot] = 0
        end
    ```
end

local function resolveBatchSpawnArchetype(
    self: WorldImpl,
    componentTypes: {Component}
): Archetype, {RequireEntry}
    local archetypeIndex = self.archetypeIndex
    local archetype = archetypeIndex.emptyArchetype
    local requiredList: {RequireEntry} = nil
    for i = 1, #componentTypes do
        local comp = componentTypes[i]
        local ci = comp as ComponentInternal
        archetype = archetype:withComponent(comp, archetypeIndex)
        if ci._hasRequires then
            local extension: {RequireEntry}
            archetype, extension = applyRequires(archetype, ci, archetypeIndex)
            if extension then
                if requiredList == nil then
                    requiredList = extension
                else
                    local rl = requiredList as {RequireEntry}
                    for k = 1, #extension do
                        rl[#rl + 1] = extension[k]
                    end
                end
            end
        end
        -- Relationship targets always add the container, so ensure we place correctly.
        local wildcard = ci.wildcardContainer
        if wildcard then
            archetype = archetype:withComponent(wildcard, archetypeIndex)
        end
    end

    local autoState = self.autoStateComponent
    if autoState then
        archetype = archetype:withComponent(autoState, archetypeIndex)
    end
    return archetype, requiredList
end

function WorldImpl:_deferBatchSpawn(
    count: integer,
    componentTypes: {Component},
    callback: function(Archetype, integer, integer, integer)
): integer | nil, {integer} | nil
    validateBatchCount("World:batchSpawn", count)

    if self.allocator.nextFreshSlot + count > self.allocator.maxSlotCount then
        return nil, self:_deferBatchSpawnList(count, componentTypes, callback)
    end

    -- Contiguous `firstId + i` handles need one generation across the
    -- whole range. After clearEntities the fresh range restarts inside the
    -- recycled (nonzero-generation) prefix; a range straddling the prefix
    -- boundary spans two generations, so it falls back to per-id handles.
    local genSlots = self.allocator.slots as {integer: EntitySlot}
    local nextFresh = self.allocator.nextFreshSlot
    local rangeGen = genSlots[nextFresh].generation as integer
    if genSlots[nextFresh + count - 1].generation ~= rangeGen then
        return nil, self:_deferBatchSpawnList(count, componentTypes, callback)
    end

    local archetype, requiredList = resolveBatchSpawnArchetype(self, componentTypes)

    -- Strict contiguous: draw exclusively from the fresh range. Callers
    -- rely on `firstId + i` for handle reconstruction, so a non-contiguous
    -- fallback would silently hand back wrong ids. Errors on overflow.
    local firstSlot = IdAllocator.allocContiguousSlots(self.allocator, count)
    local pendingArr = self._pendingArchArr as {integer:integer}
    local stateArr = self._stateArr as {integer:integer}
    local slotStamp = self._slotStamp as {integer:integer}
    local epoch = self._transactionEpoch
    local archId = archetype.id
    for i = 0, count - 1 do
        local s = firstSlot + i
        if slotStamp[s] ~= epoch then
            slotStamp[s] = epoch
            stateArr[s] = 0
        end
        pendingArr[s] = archId
    end

    -- Handles carry the range's generation; `firstId + i` stays contiguous
    -- because the generation bits are constant across the range.
    local firstId = IdAllocator.encodeId(firstSlot, rangeGen)

    local c = archetype.batchSpawnQueueCount
    local q = archetype.batchSpawnQueue
    q[c + 1] = count
    q[c + 2] = firstId
    q[c + 3] = callback
    q[c + 4] = BATCH_SPAWN_MODE_RANGE
    q[c + 5] = requiredList
    archetype.batchSpawnQueueCount = c + BATCH_SPAWN_SLOTS
    ensureDirty!(archetype)
    self.isDirty = true

    return firstId, nil
end

function WorldImpl:_deferBatchSpawnList(
    count: integer,
    componentTypes: {Component},
    callback: function(Archetype, integer, integer, integer)
): {integer}
    local archetype, requiredList = resolveBatchSpawnArchetype(self, componentTypes)

    local allocator = self.allocator
    local pendingArr = self._pendingArchArr as {integer:integer}
    local stateArr = self._stateArr as {integer:integer}
    local slotStamp = self._slotStamp as {integer:integer}
    local epoch = self._transactionEpoch
    local archId = archetype.id
    local freshAvail = allocator.maxSlotCount - allocator.nextFreshSlot
    local totalAvail = freshAvail + allocator.freeCount
    if count > totalAvail then
        error("entity slot exhaustion: maxSlotCount (" .. allocator.maxSlotCount .. ") reached")
    end

    local idsList: {integer} = {}
    local n = 0

    if freshAvail > 0 then
        local takeFresh = freshAvail < count and freshAvail or count
        local firstFresh = IdAllocator.allocContiguousSlots(allocator, takeFresh)
        for i = 0, takeFresh - 1 do
            local slot = firstFresh + i
            -- Fresh slots carry a nonzero generation after clearEntities.
            local id = IdAllocator.encodeId(slot, allocator.slots[slot].generation)
            n = n + 1
            idsList[n] = id
            if slotStamp[slot] ~= epoch then
                slotStamp[slot] = epoch
                stateArr[slot] = 0
            end
            pendingArr[slot] = archId
        end
    end

    while n < count do
        local slot = IdAllocator.allocSlot(allocator)
        local id = IdAllocator.encodeId(slot, allocator.slots[slot].generation)
        n = n + 1
        idsList[n] = id
        if slotStamp[slot] ~= epoch then
            slotStamp[slot] = epoch
            stateArr[slot] = 0
        end
        pendingArr[slot] = archId
    end

    local c = archetype.batchSpawnQueueCount
    local q = archetype.batchSpawnQueue
    q[c + 1] = count
    q[c + 2] = idsList
    q[c + 3] = callback
    q[c + 4] = BATCH_SPAWN_MODE_LIST
    q[c + 5] = requiredList
    archetype.batchSpawnQueueCount = c + BATCH_SPAWN_SLOTS
    ensureDirty!(archetype)
    self.isDirty = true

    return idsList
end

function WorldImpl:_drainArchBatchSpawn(archetype: Archetype)
    local slots = self.allocator.slots as {integer: EntitySlot}
    local stateArr = self._stateArr as {integer:integer}
    local slotStamp = self._slotStamp as {integer:integer}
    local epoch = self._transactionEpoch
    local archId = archetype.id
    local q = archetype.batchSpawnQueue

    local i = 1
    while i <= archetype.batchSpawnQueueCount do
        local count = q[i] as integer
        local idsOrFirst = q[i + 1]
        local callback = q[i + 2] as function(Archetype, integer, integer, integer)
        local mode = q[i + 3] as integer
        local requiredList = q[i + 4] as {RequireEntry}

        archetype:reserveCapacity((archetype.entities[0] as integer) + count)
        local entities = archetype.entities
        local currentCount = entities[0] as integer
        local entitiesArr = entities as {integer}

        local placed = 0
        local stateCount = self.entityStateCount
        if mode == BATCH_SPAWN_MODE_RANGE then
            -- `firstId` carries the range's generation; slot arithmetic
            -- runs on the decoded base.
            local firstId = idsOrFirst as integer
            local firstSlot = IdAllocator.slotOf(firstId)
            if stateCount == 0 then
                for j = 0, count - 1 do
                    placeFreshRow!(firstId + j, firstSlot + j)
                end
            else
                for j = 0, count - 1 do
                    placeStakedRow!(firstId + j, firstSlot + j)
                end
            end
        else
            local ids = idsOrFirst as {integer}
            if stateCount == 0 then
                for j = 1, count do
                    placeFreshRow!(ids[j], IdAllocator.slotOf(entityId))
                end
            else
                for j = 1, count do
                    placeStakedRow!(ids[j], IdAllocator.slotOf(entityId))
                end
            end
        end
        entitiesArr[0] = currentCount + placed

        if placed > 0 then
            -- `requires`-supplied defaults go in before the user callback
            -- so callback writes win on overlap. Skipped when nil (no
            -- `requires` declared on any of the caller's component types).
            if requiredList then
                writeRequiredRange(archetype, requiredList, currentCount + 1, currentCount + placed)
            end
            callback(archetype, currentCount + 1, currentCount + placed, placed)
        end

        archetype:onRowsAdded(currentCount, placed, nil)

        i = i + BATCH_SPAWN_SLOTS
    end

    -- Clear the queue so observer-triggered dirty-marks (which may
    -- re-queue this archetype for move-phase work) don't cause the
    -- drain loop to re-process stale entries on subsequent waves.
    table_clear(archetype.batchSpawnQueue)
    archetype.batchSpawnQueueCount = 0
end

local function resolveBatchArchetype(
    self: WorldImpl,
    componentTypes: {Component}
): Archetype, {RequireEntry}
    local archetypeIndex = self.archetypeIndex
    local archetype = archetypeIndex.emptyArchetype
    local requiredList: {RequireEntry} = nil
    for i = 1, #componentTypes do
        local comp = componentTypes[i]
        local ci = comp as ComponentInternal
        archetype = archetype:withComponent(comp, archetypeIndex)
        if ci._hasRequires then
            local extension: {RequireEntry}
            archetype, extension = applyRequires(archetype, ci, archetypeIndex)
            if extension then
                if requiredList == nil then
                    requiredList = extension
                else
                    local rl = requiredList as {RequireEntry}
                    for k = 1, #extension do
                        rl[#rl + 1] = extension[k]
                    end
                end
            end
        end
        local wildcard = ci.wildcardContainer
        if wildcard then
            archetype = archetype:withComponent(wildcard, archetypeIndex)
        end
    end
    local autoState = self.autoStateComponent
    if autoState then
        archetype = archetype:withComponent(autoState, archetypeIndex)
    end
    return archetype, requiredList
end

function WorldImpl:_deferBatchSpawnAt(
    ids: {integer},
    componentTypes: {Component},
    callback: function(Archetype, integer, integer, integer)
)
    local n = #ids
    if n == 0 then return end

    local archetype, requiredList = resolveBatchArchetype(self, componentTypes)
    stakePendingSpawnAt(self, archetype, n, function(i: integer): integer
        return ids[i + 1]
    end)

    local c = archetype.batchSpawnAtQueueCount
    local q = archetype.batchSpawnAtQueue
    q[c + 1] = ids
    q[c + 2] = n
    q[c + 3] = callback
    q[c + 4] = requiredList
    archetype.batchSpawnAtQueueCount = c + BATCH_SPAWN_AT_SLOTS
    ensureDirty!(archetype)
    self.isDirty = true
end

function WorldImpl:_deferBatchSpawnAtRaw(
    ids: any,
    count: integer,
    componentTypes: {Component},
    callback: function(Archetype, integer, integer, integer)
)
    if count == 0 then return end

    local archetype, requiredList = resolveBatchArchetype(self, componentTypes)
    local idsArr = ids as {integer: integer}
    stakePendingSpawnAt(self, archetype, count, function(i: integer): integer
        return idsArr[i]
    end)

    local c = archetype.batchSpawnAtQueueCount
    local q = archetype.batchSpawnAtQueue
    q[c + 1] = ids
    q[c + 2] = count
    q[c + 3] = callback
    q[c + 4] = requiredList
    archetype.batchSpawnAtQueueCount = c + BATCH_SPAWN_AT_SLOTS
    ensureDirty!(archetype)
    self.isDirty = true
end

function WorldImpl:_drainArchBatchSpawnAt(archetype: Archetype)
    local slots = self.allocator.slots as {integer: EntitySlot}
    local stateArr = self._stateArr as {integer:integer}
    local slotStamp = self._slotStamp as {integer:integer}
    local epoch = self._transactionEpoch
    local archId = archetype.id
    local q = archetype.batchSpawnAtQueue

    local i = 1
    while i <= archetype.batchSpawnAtQueueCount do
        local ids = q[i]
        local n = q[i + 1] as integer
        local callback = q[i + 2] as function(Archetype, integer, integer, integer)
        local requiredList = q[i + 3] as {RequireEntry}

        archetype:reserveCapacity((archetype.entities[0] as integer) + n)
        local entitiesArr = archetype.entities as {integer}
        local currentCount = entitiesArr[0] as integer

        -- `ids` is either a Lua array (1-based) or an FFI int32_t* (0-based).
        -- Branch once per queue entry so each placement loop is monomorphic.
        local placed = 0
        local idsRaw = ids as {integer: integer}
        local isCdata = type(ids) == "cdata"
        if isCdata then
            for j = 0, n - 1 do
                placeStakedRow!(idsRaw[j], IdAllocator.slotOf(entityId))
            end
        else
            for j = 1, n do
                placeStakedRow!(idsRaw[j], IdAllocator.slotOf(entityId))
            end
        end
        entitiesArr[0] = currentCount + placed

        if placed > 0 then
            if requiredList then
                writeRequiredRange(archetype, requiredList, currentCount + 1, currentCount + placed)
            end
            callback(archetype, currentCount + 1, currentCount + placed, placed)
        end

        archetype:onRowsAdded(currentCount, placed, nil)

        i = i + BATCH_SPAWN_AT_SLOTS
    end

    -- Same queue-clear as `_drainArchBatchSpawn`: prevent re-processing
    -- across drain waves when observer-staged mutations re-queue this
    -- archetype for later phases.
    table_clear(archetype.batchSpawnAtQueue)
    archetype.batchSpawnAtQueueCount = 0
end

function WorldImpl:_deferBatchDespawn(archetypes: {Archetype})
    local world = self
    local refCounts = (world as {string:any})._targetRefCounts as {integer:integer}

    -- OnDespawn fan-out: cached once for the whole call.
    local OnDespawnBuiltin <const> = builtins.OnDespawn
    local despawnEventId <const> = OnDespawnBuiltin.eventId
    local hasGlobalObs <const> = world:hasObservers(0, OnDespawnBuiltin)
    local messagesAny = (world as {string:any}).messages as {string:any}
    local entityObsCount <const> = messagesAny._entityObserverCount as integer
    local busObservers = messagesAny._observers as {integer: {integer: {any}}}
    local anyPerEntityObs = false
    if entityObsCount > 0 then
        for addr, byEvent in pairs(busObservers) do
            if addr ~= 0 and byEvent[despawnEventId] then
                anyPerEntityObs = true
                break
            end
        end
    end
    -- Archetypes bulk-cleared below; their observer addresses are swept in
    -- one pass at the end of the call.
    local clearedArchIds: {integer: boolean} = nil

    for a = 1, #archetypes do
        local arch = archetypes[a]
        local entities = arch.entities as {integer}
        local count = entities[0]
        if count > 0 then
            -- "Complex" despawn: dense relationships or entities targeted by
            -- reverse-index relationships need per-entity dispatch so unlink
            -- and cascade cleanup run. Otherwise bulk-truncate.
            local complex = arch.onDespawnCount > 0
            if not complex then
                for i = 1, count do
                    if refCounts[entities[i]] then
                        complex = true
                        break
                    end
                end
            end

            if complex then
                for i = count, 1, -1 do
                    self:_deferDespawn(entities[i])
                end
            else
                -- Sparse relationship sources: drop their store entries
                -- and reverse-index links before the bulk clear frees the
                -- rows, mirroring `_deferDespawn`'s store cleanup. Marks
                -- imply the container column, so archetypes without one
                -- skip this entirely.
                if world._hasRelationshipStores then
                    local list = arch.componentList
                    for j = 1, arch.columnsCount do
                        local c = list[j] as ComponentInternal
                        if c.isSparse and c.isContainer then
                            local store = world.relationshipStores[c as Component]
                            if store then
                                for i = 1, count do
                                    store:remove(entities[i])
                                end
                            end
                        end
                    end
                end
                -- Fire events at write time, then mark for clear.
                if hasGlobalObs or anyPerEntityObs then
                    for i = 1, count do
                        local id = entities[i]
                        if anyPerEntityObs and world:hasObservers(id, OnDespawnBuiltin) then
                            world:emit(id, OnDespawnBuiltin, id)
                        end
                        if hasGlobalObs then world:emit(0, OnDespawnBuiltin, id) end
                    end
                end
                if entityObsCount > 0 then
                    if not clearedArchIds then clearedArchIds = {} end
                    clearedArchIds[arch.id] = true
                end
                arch.pendingClear = true
                markDirty!(arch, hasPendingDespawns)
            end
        end
    end

    -- One pass over the bus's non-zero addresses clears observers owned by
    -- the bulk-cleared archetypes: addresses are slots, so membership is
    -- one sidecar read. Runs only when per-entity observers exist.
    if clearedArchIds then
        local slots = self.allocator.slots as {integer: EntitySlot}
        for addr in pairs(busObservers) do
            if addr ~= 0 and clearedArchIds[slots[addr].archetypeId] then
                world:clearObservers(addr)
            end
        end
    end

    self.isDirty = true
end

local function canBulkBatchComponent(componentType: Component): boolean
    return not behavior.hasBits(componentType, behavior.NoBulkBatch)
end

local function batchMutationSlot(self: WorldImpl, c: integer): BatchMutation
    local q = self.batchMutations as {BatchMutation}
    local mut = q[c]
    if not mut then
        mut = {} as BatchMutation
        q[c] = mut
    end
    return mut
end

function WorldImpl:_deferBatchSet(
    archetypes: {Archetype},
    componentType: Component,
    value: Component
)
    if #archetypes == 0 then return end
    local ci = componentType as ComponentInternal
    local storedValue: any = value
    if ci.storageType == "scalar" then
        if value == componentType then
            storedValue = (componentType as types.components.ScalarComponent<any>).scalarDefault
        else
            storedValue = (value as {string:any}).value
        end
    end
    local c = self.batchMutationCount + 1
    local mut = batchMutationSlot(self, c)
    mut.op = BATCH_OP_SET_CONST
    mut.archetypes = archetypes
    mut.componentType = componentType
    mut.value = storedValue
    mut.callback = nil  -- clear inactive union slot
    mut.isTag = ci.storageType == "tag"
    mut.canBulk = canBulkBatchComponent(componentType)
    self.batchMutationCount = c
    self.isDirty = true
end

function WorldImpl:_deferBatchSetCallback(
    archetypes: {Archetype},
    componentType: Component,
    callback: function(Archetype, integer, integer, integer)
)
    if #archetypes == 0 then return end
    if not canBulkBatchComponent(componentType) then
        error("batchSet callback form requires a bulk-safe component. Use the constant-value form " ..
            "`world:batchSet(query, instance)` for relationship components.")
    end
    local c = self.batchMutationCount + 1
    local mut = batchMutationSlot(self, c)
    mut.op = BATCH_OP_SET_CALLBACK
    mut.archetypes = archetypes
    mut.componentType = componentType
    mut.callback = callback
    mut.value = nil  -- clear inactive union slot
    mut.isTag = (componentType as ComponentInternal).storageType == "tag"
    mut.canBulk = true  -- `canBulkBatchComponent` asserted above
    self.batchMutationCount = c
    self.isDirty = true
end

function WorldImpl:_deferBatchRemove(
    archetypes: {Archetype},
    componentType: Component
)
    if #archetypes == 0 then return end
    local c = self.batchMutationCount + 1
    local mut = batchMutationSlot(self, c)
    mut.op = BATCH_OP_REMOVE
    mut.archetypes = archetypes
    mut.componentType = componentType
    mut.value = nil       -- not used by REMOVE
    mut.callback = nil    -- not used by REMOVE
    mut.isTag = (componentType as ComponentInternal).storageType == "tag"
    mut.canBulk = canBulkBatchComponent(componentType)
    self.batchMutationCount = c
    self.isDirty = true
end

-- Shared spawn-archetype resolution for codegen'd bundle spawns: applies
-- `requires`, wildcard containers, and the active auto-state component,
-- matching every other spawn path.
function WorldImpl:_resolveSpawnArchetype(componentTypes: {Component}): Archetype, {RequireEntry}
    return resolveBatchSpawnArchetype(self, componentTypes)
end

function WorldImpl:_drainBatchMutations()
    local count = self.batchMutationCount
    if count == 0 then return end
    local queue = self.batchMutations as {BatchMutation}
    for i = 1, count do
        local mut = queue[i]
        local archetypes = mut.archetypes
        local op = mut.op
        if op == BATCH_OP_REMOVE then
            for a = 1, #archetypes do
                applyBatchRemove(self, mut, archetypes[a])
            end
        else
            for a = 1, #archetypes do
                applyBatchSet(self, mut, archetypes[a])
            end
        end
    end

    -- Drain moves staged by slow-path add/remove during batch.
    local dirtyList = self.dirtyArchetypeList
    for i = 1, self.dirtyArchetypeCount do
        local arch = dirtyList[i]
        if arch.hasPendingMoveOut then
            self:_drainPendingMoves(arch)
        end
    end

    -- Consume the processed entries: `_drain` re-enters this phase for
    -- mutations staged by observers, which append past `count`.
    local snapshotPool = self._archetypeSnapshotPool
    for i = 1, count do
        local mut = queue[i]
        snapshotPool:release(mut.archetypes as {any})
        mut.archetypes = nil
    end
    local total = self.batchMutationCount
    if total > count then
        for i = 1, total - count do
            queue[i], queue[count + i] = queue[count + i], nil
        end
        self.batchMutationCount = total - count
    else
        self.batchMutationCount = 0
    end
end


return {}
