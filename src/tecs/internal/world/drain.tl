--[[
Commit drain: despawn -> spawn -> move -> batch -> sparse -> reset.
]]

local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")
local IdAllocator <const> = require("tecs.internal.IdAllocator")
local BundleCodegen <const> = require("tecs.internal.BundleCodegen")
local pool <const> = require("tecs.utils.pool")
local table_clear <const> = require("table.clear")
local shared <const> = require("tecs.internal.world.shared")

local type Component = types.components.Component
local type Archetype = internal.ArchetypeInternal
local type EntitySlot = IdAllocator.EntitySlot
local type BatchMutation = shared.BatchMutation

local WorldImpl = internal.WorldImpl

local STATE_DESPAWN <const> = shared.STATE_DESPAWN

local copyPlanRow <const> = shared.copyPlanRow
local applyPendingVals <const> = shared.applyPendingVals
local applyPendingScalars <const> = shared.applyPendingScalars
local bumpTransactionEpoch <const> = shared.bumpTransactionEpoch

local pairs <const> = pairs

function WorldImpl:_truncateArchetype(arch: Archetype)
    local entities = arch.entities as {integer}
    local archCount = entities[0]
    if archCount == 0 then return end

    local arena = self.allocator

    -- notifyRemoved itself is gated on `hasRemoveObservers` internally
    -- -- no need to repeat the check at the call site.
    arch:notifyRemoved(0, archCount, nil)
    for r = 1, archCount do
        IdAllocator.freeSlot(arena, IdAllocator.slotOf(entities[r]))
    end
    entities[0] = 0
    if arch.observerCount > 0 then
        arch:notifyDeactivatedExternal()
    end
end

function WorldImpl:_drainPendingSpawns(arch: Archetype)
    local slots = self.allocator.slots as {integer: EntitySlot}
    local pendingArchArr = self._pendingArchArr as {integer:integer}
    local stateArr = self._stateArr as {integer:integer}
    local slotStamp = self._slotStamp as {integer:integer}
    local epoch = self._transactionEpoch
    local archId = arch.id

    local ids = arch.pendingSpawnIds as {integer}
    local count = arch.pendingSpawnCount
    local hasScalarPending = arch.hasScalarPending
    local archPendingScalarTypes = arch.pendingScalarTypes
    local archPendingScalarValues = arch.pendingScalarValues
    if count > 0 then
        arch:reserveCapacity((arch.entities[0] as integer) + count)
        local entities = arch.entities as {integer}
        local startRow = entities[0]
        local cols = arch.columns

        local placed = 0
        for k = 1, count do
            -- `pendingSpawnIds` stores packed ids; decode slot once per entity.
            local packedId = ids[k]
            local slot = IdAllocator.slotOf(packedId)
            if slotStamp[slot] ~= epoch
                    or pendingArchArr[slot] ~= archId
                    or stateArr[slot] == STATE_DESPAWN then
                goto nextSpawn
            end

            local row = startRow + placed
            local es = slots[slot]
            es.archetypeId = archId
            es.row = row
            entities[row + 1] = packedId

            local vals = arch:getPendingValues(slot)
            if vals then
                applyPendingVals(vals, cols, row + 1)
            end
            if hasScalarPending then
                local scalarTypes = archPendingScalarTypes[slot]
                if scalarTypes then
                    applyPendingScalars(scalarTypes, archPendingScalarValues[slot], cols, row + 1)
                end
            end

            -- Transition to committed before notifyAdded (observer correctness).
            -- Clear stamp so post-placement observer-fired ops see committed.
            slotStamp[slot] = 0
            self.entityStateCount = self.entityStateCount - 1

            placed = placed + 1
            ::nextSpawn::
        end

        entities[0] = startRow + placed

        arch:onRowsAdded(startRow, placed, nil)
    end
end

function WorldImpl:_drainPendingMoves(srcArch: Archetype)
    local srcEntities = srcArch.entities as {integer}
    local srcCount = srcEntities[0]
    if srcCount == 0 then return end

    local slots = self.allocator.slots as {integer: EntitySlot}
    local pendingArchArr = self._pendingArchArr as {integer:integer}
    local stateArr = self._stateArr as {integer:integer}
    local slotStamp = self._slotStamp as {integer:integer}
    local epoch = self._transactionEpoch
    local archIndex = self.archetypeIndex
    local toRemove = self._swapRemoveQueue
    local srcHasScalarPending = srcArch.hasScalarPending
    local srcPendingScalarTypes = srcArch.pendingScalarTypes
    local srcPendingScalarValues = srcArch.pendingScalarValues
    local getMovePlanTo = srcArch.getMovePlanTo
    local removeCount = 0
    local lastPlanDst: Archetype = nil
    local plan: internal.MovePlan = nil
    local planCount = 0
    local planSrcCols: {integer: {any}} = nil
    local planDstCols: {integer: {any}} = nil
    local dstCols: {Component: {any}} = nil
    local dstArchId = 0

    for r = srcCount, 1, -1 do
        local entId = srcEntities[r]
        local entSlot = IdAllocator.slotOf(entId)
        local dstArch: Archetype = nil
        -- Despawned entities keep their staged pending arch; the despawn
        -- drain owns their row, so the move must not relocate it.
        if slotStamp[entSlot] == epoch and stateArr[entSlot] ~= STATE_DESPAWN then
            local archId = pendingArchArr[entSlot]
            if archId ~= 0 then dstArch = archIndex[archId] end
        end

        if dstArch ~= nil then
            -- reserveCapacity may reallocate entities array.
            if dstArch.pendingWrites > 0 then
                dstArch:reserveCapacity(dstArch.entities[0] + dstArch.pendingWrites)
                dstArch.pendingWrites = 0
            end
            local dstEntities = dstArch.entities as {integer}

            if dstArch ~= lastPlanDst then
                plan = getMovePlanTo(srcArch, dstArch) as internal.MovePlan
                lastPlanDst = dstArch
                planCount = plan.count
                planSrcCols = plan.srcCols as {integer: {any}}
                planDstCols = plan.dstCols as {integer: {any}}
                dstCols = dstArch.columns
                dstArchId = dstArch.id
            end

            local newRow = dstEntities[0]
            local dLuaRow = newRow + 1

            copyPlanRow(planDstCols, planSrcCols, dLuaRow, r, planCount)

            local vals = srcArch:getPendingValues(entSlot)
            if vals then
                applyPendingVals(vals, dstCols, dLuaRow)
            end
            if srcHasScalarPending then
                local scalarTypes = srcPendingScalarTypes[entSlot]
                if scalarTypes then
                    applyPendingScalars(scalarTypes, srcPendingScalarValues[entSlot], dstCols, dLuaRow)
                end
            end

            -- Propagate the packed id directly (same slot + gen).
            dstEntities[dLuaRow] = entId
            dstEntities[0] = newRow + 1
            local es = slots[entSlot]
            es.archetypeId = dstArchId
            es.row = newRow

            -- onRowsAdded marks dirty unconditionally and gates
            -- notification on observer presence internally.
            dstArch:onRowsAdded(newRow, 1, srcArch)

            removeCount = removeCount + 1
            toRemove[removeCount] = r
        end
    end

    if removeCount == 0 then return end

    if removeCount >= srcCount then
        if srcArch.observerCount > 0 then
            for r = 1, srcCount do
                local entSlot = IdAllocator.slotOf(srcEntities[r])
                local dst: Archetype = nil
                if slotStamp[entSlot] == epoch then
                    local archId = pendingArchArr[entSlot]
                    if archId ~= 0 then dst = archIndex[archId] end
                end
                srcArch:notifyRemoved(r - 1, 1, dst)
            end
            srcArch:notifyDeactivatedExternal()
        end
        srcEntities[0] = 0
    else
        for k = 1, removeCount do
            local row = toRemove[k]
            local srcEntSlot = IdAllocator.slotOf(srcEntities[row])
            local entDst: Archetype = nil
            if slotStamp[srcEntSlot] == epoch then
                local archId = pendingArchArr[srcEntSlot]
                if archId ~= 0 then entDst = archIndex[archId] end
            end
            local movedEntId = srcArch:removeEntity(row - 1, entDst)
            if movedEntId ~= 0 then
                -- removeEntity returns swapped-in packed id.
                local movedSlot = IdAllocator.slotOf(movedEntId)
                slots[movedSlot].row = row - 1
            end
        end
    end
end

function WorldImpl:_drainPendingDespawns(arch: Archetype)
    local arena = self.allocator
    local slots = arena.slots as {integer: EntitySlot}

    if arch.pendingClear then
        self:_truncateArchetype(arch)
        arch.pendingClear = false
        arch.pendingDespawnCount = 0
    elseif arch.pendingDespawnCount > 0 then
        repeat
            local list = arch.pendingDespawn
            local removeCount = arch.pendingDespawnCount
            local entities = arch.entities as {integer}
            local archCount = entities[0]

            if removeCount >= archCount then
                self:_truncateArchetype(arch)
                -- Truncation removed every row; entries staged by its
                -- observers refer to freed rows of this archetype.
                arch.pendingDespawnCount = 0
            else
                -- Entries are slots; resolve each row at removal time so
                -- earlier swap-removals cannot stale the queue.
                for i = 1, removeCount do
                    local slotOfRow = list[i]
                    local row = slots[slotOfRow].row + 1
                    local movedEntId = arch:removeEntity(row - 1, nil)
                    IdAllocator.freeSlot(arena, slotOfRow)
                    if movedEntId ~= 0 then
                        slots[IdAllocator.slotOf(movedEntId)].row = row - 1
                    end
                    list[i] = nil
                end
                -- removeEntity observers may stage more despawns on this
                -- archetype; compact them down and loop again.
                local staged = arch.pendingDespawnCount - removeCount
                if staged > 0 then
                    for i = 1, staged do
                        list[i] = list[removeCount + i]
                        list[removeCount + i] = nil
                    end
                end
                arch.pendingDespawnCount = staged
            end
        until arch.pendingDespawnCount == 0
    end
end

function WorldImpl:_codegenBundleSpawn(
    typeArray: {Component},
    factoryArray: {function(): Component},
    requiredCount: integer
): function(any, ...: Component): integer
    return BundleCodegen.codegenBundleSpawn(self, typeArray, factoryArray, requiredCount)
end

local function resetTransaction(self: WorldImpl)
    -- Epoch bump: O(1) reset for entityState + entityPendingArch. All
    -- slot-indexed writes during the last transaction stamped the
    -- current epoch; bumping invalidates them without touching the
    -- underlying FFI arrays. Wrap every ~4B transactions clears the
    -- stamps -- negligible amortised cost.
    bumpTransactionEpoch(self)
    self.entityStateCount = 0

    local sparsePool = self._sparseArraysPool
    for id, list in pairs(self.sparseSets) do
        self.sparseSets[id] = nil
        sparsePool:release(list)
    end
    self.sparseSetCount = 0

    self._valsPoolNext = 1
    self.lastArch = nil

    if self.batchMutationCount > 0 then
        local q = self.batchMutations as {BatchMutation}
        -- Release pooled archetype snapshots acquired in `world.archetypesOf`.
        local snapshotPool = self._archetypeSnapshotPool as pool.TablePool
        for i = 1, self.batchMutationCount do
            local mut = q[i]
            snapshotPool:release(mut.archetypes as {any})
            mut.archetypes = nil  -- drop ref to released array
        end
        self.batchMutationCount = 0
    end

    local dirtyList = self.dirtyArchetypeList
    local dirtyCount = self.dirtyArchetypeCount
    for i = 1, dirtyCount do
        local arch = dirtyList[i]
        arch:resetPending()
        -- Nil out the list slot so `compact()`-destroyed archetypes can
        -- be GC'd. Bumping `_dirtyEpoch` alone invalidates dedupe
        -- markers but leaves stale Archetype references pinning memory.
        dirtyList[i] = nil
    end
    self.dirtyArchetypeCount = 0

    -- Bump dedupe epoch. On 32-bit wrap, walk all archetypes and clear
    -- their `dirtyQueuedEpoch` so the new epoch (=1) compares unequal
    -- to the reset marker (=0). Wrap is rare (every 2^32 commits);
    -- under a 60Hz game loop that's two years per world.
    local e = self._dirtyEpoch + 1
    if e > 0xFFFFFFFF then
        local archetypeIndex = self.archetypeIndex
        for i = 1, archetypeIndex.maxId do
            local a = archetypeIndex[i]
            if a then a.dirtyQueuedEpoch = 0 end
        end
        e = 1
    end
    self._dirtyEpoch = e

    self.isDirty = false
end

local function commitSparseChanges(self: WorldImpl)
    local stores = self.relationshipStores
    local stateArr = self._stateArr as {integer:integer}
    local slotStamp = self._slotStamp as {integer:integer}
    local epoch = self._transactionEpoch
    local slots = self.allocator.slots as {integer: EntitySlot}
    for slot, sets in pairs(self.sparseSets) do
        if not (slotStamp[slot] == epoch and stateArr[slot] == STATE_DESPAWN) then
            local packedId = IdAllocator.encodeId(slot, slots[slot].generation)
            for si = 1, #sets do
                local value = sets[si]
                local rel = value as types.components.Relationship
                local container = rel.relationshipType as Component
                local store = stores[container]
                if store then
                    store:set(packedId, value)
                end
            end
        end
    end
end

-- Safety valve for observer-cascade loops.
local MAX_DRAIN_ITERATIONS <const> = 64

function WorldImpl:_drain()
    if not self.isDirty then
        return
    end

    -- Hold `_scopeDepth >= 1` so observer-triggered mutations stage.
    local outerDepth = self._scopeDepth
    self._scopeDepth = outerDepth + 1

    local dirtyList = self.dirtyArchetypeList
    local processed = 0
    local iterations = 0
    local oneShotDone = false

    -- Fixed-point loop over dirty archetype waves + one-shot phases.
    while processed < self.dirtyArchetypeCount or not oneShotDone do
        iterations = iterations + 1
        if iterations > MAX_DRAIN_ITERATIONS then
            error("_drain exceeded MAX_DRAIN_ITERATIONS — likely an observer cascade with no fixed point")
        end

        local count = self.dirtyArchetypeCount
        if processed < count then
            -- Clear this wave's dedupe markers so observer-fired re-marks
            -- during drain can re-queue the same archetypes for the
            -- next wave.
            for i = processed + 1, count do
                dirtyList[i].dirtyQueuedEpoch = 0
            end

            -- Despawns first so spawns can reuse rows.
            for i = processed + 1, count do
                local arch = dirtyList[i]
                if arch.hasPendingDespawns then
                    self:_drainPendingDespawns(arch)
                end
            end

            -- Spawns (bundle, batch, batchAt, per-entity).
            for i = processed + 1, count do
                local arch = dirtyList[i]
                local pendingBundleDrainCount = arch.pendingBundleDrainCount
                if pendingBundleDrainCount > 0 then
                    local drains = arch.pendingBundleDrains
                    for j = 1, pendingBundleDrainCount do
                        (drains[j] as function())()
                    end
                    table_clear(drains)
                    arch.pendingBundleDrainCount = 0
                end
                if arch.batchSpawnQueueCount > 0 then
                    self:_drainArchBatchSpawn(arch)
                end
                if arch.batchSpawnAtQueueCount > 0 then
                    self:_drainArchBatchSpawnAt(arch)
                end
                if arch.hasPendingSpawns then
                    self:_drainPendingSpawns(arch)
                end
            end

            -- Moves.
            for i = processed + 1, count do
                local arch = dirtyList[i]
                if arch.hasPendingMoveOut then
                    self:_drainPendingMoves(arch)
                end
            end

            processed = count
        else
            -- Fire one-shot phases; they may enqueue new dirty arches.
            if self.batchMutationCount > 0 then
                self:_drainBatchMutations()
            end
            if self.sparseSetCount > 0 then
                commitSparseChanges(self)
            end
            oneShotDone = true
        end
    end

    resetTransaction(self)
    self._scopeDepth = outerDepth
end

function WorldImpl:_resetTxn()
    if self.isDirty then
        resetTransaction(self)
    end
end


return {}
