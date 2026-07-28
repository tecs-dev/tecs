--[[
Shared helpers/constants for world/*.tl mutation paths.
]]

local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")
local IdAllocator <const> = require("tecs.internal.IdAllocator")
local C <const> = require("ffi")

local type Component = types.components.Component
local type ComponentInternal = internal.ComponentInternal
local type Archetype = internal.ArchetypeInternal
local type ArchetypeIndex = internal.ArchetypeIndexInternal
local type WorldImpl = internal.WorldImpl
local type EntitySlot = IdAllocator.EntitySlot
local table_move <const> = table.move

local ffi_copy <const> = C.copy
local SIZEOF_DOUBLE <const> = C.sizeof("double") as integer

-- Typed cdata pointer arithmetic helper (offset in rows/elements).
local ffi_add_rows: function(ptr: C.CData, rows: integer): C.CData
do
    local loadfn = rawget(_G as table, "load") or rawget(_G as table, "loadstring")
    local fn = (loadfn as function(string): function(): any)("return function(p, r) return p + r end")()
    ffi_add_rows = fn as function(C.CData, integer): C.CData
end

local STATE_SPAWN <const> = 1
local STATE_MUTATE <const> = 2
local STATE_DESPAWN <const> = 3

-- Epoch-stamped entityState / entityPendingArch accessors. A single
-- `_slotStamp[slot]` governs BOTH `_stateArr[slot]` and
-- `_pendingArchArr[slot]`: when `stamp != epoch`, both are treated as
-- unset (0). First write this epoch stamps the slot and zeros the
-- companion field (since its stored bytes are stale from a prior epoch
-- and are about to become "live" under the new stamp). Subsequent
-- writes skip the zero. Reads check the stamp; mismatch returns 0.
-- `resetTransaction` bumps the epoch in O(1); wrap (every ~4B txns)
-- clears the stamp array.

-- Returns state value (1/2/3) or 0 if unset for this transaction.
local function getEntityState(world: WorldImpl, slot: integer): integer
    if (world._slotStamp as {integer: integer})[slot] == world._transactionEpoch then
        return (world._stateArr as {integer: integer})[slot]
    end
    return 0
end

-- Write state for slot. Zeros pending-arch companion on first claim.
local function setEntityState(world: WorldImpl, slot: integer, state: integer)
    local stamp = world._slotStamp as {integer: integer}
    local epoch = world._transactionEpoch
    local stateArr = world._stateArr as {integer: integer}
    if stamp[slot] ~= epoch then
        stamp[slot] = epoch
        (world._pendingArchArr as {integer: integer})[slot] = 0
    end
    stateArr[slot] = state
end

-- Read pending archetype. Returns nil when unset; resolves stamp →
-- archetype id → live Archetype via the world's archetype index.
local function getPendingArch(world: WorldImpl, slot: integer): Archetype
    if (world._slotStamp as {integer: integer})[slot] == world._transactionEpoch then
        local id = (world._pendingArchArr as {integer: integer})[slot]
        if id ~= 0 then
            return world.archetypeIndex[id]
        end
    end
    return nil
end

-- Write pending archetype. Zeros state companion on first claim.
local function setPendingArch(world: WorldImpl, slot: integer, arch: Archetype)
    local stamp = world._slotStamp as {integer: integer}
    local epoch = world._transactionEpoch
    local pendingArchArr = world._pendingArchArr as {integer: integer}
    if stamp[slot] ~= epoch then
        stamp[slot] = epoch
        (world._stateArr as {integer: integer})[slot] = 0
    end
    pendingArchArr[slot] = arch.id
end

-- Bump transaction epoch. On wrap, clears the stamp array and resets
-- to 1. Wrap is rare (every 2^32 transactions ≈ 4 billion); under the
-- default game-loop cadence that's centuries.
local function bumpTransactionEpoch(world: WorldImpl)
    local e = world._transactionEpoch + 1
    if e == 0 or e > 0xFFFFFFFF then
        C.fill(world._slotStamp as C.CData, (world._maxSlotCount + 1) * 4, 0)
        e = 1
    end
    world._transactionEpoch = e
end

-- batchMutations op tags.
local BATCH_OP_SET_CONST <const> = 1 -- write constant value to column (move if arch lacks component)
local BATCH_OP_SET_CALLBACK <const> = 2 -- invoke user callback per (arch, range) after ensuring component present
local BATCH_OP_REMOVE <const> = 3 -- remove component, moving entities to arch:withoutComponent

--- A single deferred batch mutation operation.
local record BatchMutation
    op: integer
    archetypes: {Archetype}
    componentType: Component
    value: any -- BATCH_OP_SET_CONST only
    callback: function(Archetype, integer, integer, integer) -- BATCH_OP_SET_CALLBACK only
    -- Hoisted component invariants, computed once at enqueue.
    isTag: boolean
    canBulk: boolean
end

local function moveSingleEntity(
    self: WorldImpl,
    slot: integer,
    srcArch: Archetype,
    srcRow: integer,
    dstArch: Archetype,
    newColumn: {any}, -- may be nil (remove path)
    newValue: Component -- may be nil (remove path / tag)
)
    local newRow = (dstArch.entities as {integer})[0] as integer
    if newRow + 1 > dstArch.capacity then
        dstArch:reserveCapacity(newRow + 1)
    end
    local dstEntities = dstArch.entities as {integer}
    local dstLuaRow = newRow + 1
    local srcLuaRow = srcRow + 1

    local plan = srcArch:getMovePlanTo(dstArch) as internal.MovePlan
    local planSrcCols = plan.srcCols as {integer: {any}}
    local planDstCols = plan.dstCols as {integer: {any}}
    for c = 1, plan.count do
        planDstCols[c][dstLuaRow] = planSrcCols[c][srcLuaRow]
    end

    if newColumn then
        newColumn[dstLuaRow] = newValue
    end

    local packedId = (srcArch.entities as {integer})[srcLuaRow]
    dstEntities[dstLuaRow] = packedId
    dstEntities[0] = newRow + 1

    local slots = self.allocator.slots as {integer: EntitySlot}
    local s = slots[slot]
    s.archetypeId = dstArch.id
    s.row = newRow

    dstArch:onRowsAdded(newRow, 1, srcArch)

    local movedEntId = srcArch:removeEntity(srcRow, dstArch)
    if movedEntId ~= 0 then
        local movedSlot = IdAllocator.slotOf(movedEntId)
        slots[movedSlot].row = srcRow
    end
    local observer = self._transitionObserver
    if observer then
        observer.entity(packedId, srcArch, dstArch)
    end
end

local function bulkMoveEntireArchetype(self: WorldImpl, srcArch: Archetype, dstArch: Archetype): integer, integer
    local srcEntities = srcArch.entities as {integer}
    local count = srcEntities[0]
    if count == 0 then
        return 0, 0
    end
    local observer = self._transitionObserver
    if observer then
        for i = 1, count do
            observer.entity(srcEntities[i], srcArch, dstArch)
        end
    end

    local plan = srcArch:getMovePlanTo(dstArch) as internal.MovePlan
    local planCount = plan.count
    local dstEntities = dstArch.entities as {integer}
    local dstBase = dstEntities[0] as integer -- rows 0..dstBase-1 are existing
    local dstArchId = dstArch.id

    -- O(1) swap fast path when destination is empty.
    if dstBase == 0 then
        dstArch:reserveCapacity(count)
        dstEntities = dstArch.entities as {integer}

        local planComps = plan.comps as {integer: Component}
        local planSrcIdx = plan.srcColIndices as {integer: integer}
        local planDstIdx = plan.dstColIndices as {integer: integer}
        local planSrcCols = plan.srcCols as {integer: {any}}
        local planDstCols = plan.dstCols as {integer: {any}}
        local srcColumns = srcArch.columns as {Component: {any}}
        local dstColumns = dstArch.columns as {Component: {any}}
        local srcColArr = srcArch.columnArray as {integer: {any}}
        local dstColArr = dstArch.columnArray as {integer: {any}}

        local srcArchTable = srcArch as {Component: {any}}
        local dstArchTable = dstArch as {Component: {any}}
        for c = 1, planCount do
            local comp = planComps[c]
            local srcCol = srcColumns[comp]
            local dstCol = dstColumns[comp]
            srcColumns[comp] = dstCol
            dstColumns[comp] = srcCol
            srcColArr[planSrcIdx[c]] = dstCol
            dstColArr[planDstIdx[c]] = srcCol
            local compI = comp as ComponentInternal
            if not (compI.isSparse and compI.relationshipType == comp) then
                srcArchTable[comp] = dstCol
                dstArchTable[comp] = srcCol
            end
            planSrcCols[c] = dstCol
            planDstCols[c] = srcCol
        end

        local srcEntitiesArr = srcArch.entities
        local dstEntitiesArr = dstArch.entities
        srcArch.entities = dstEntitiesArr
        dstArch.entities = srcEntitiesArr
        srcEntities[0] = count -- now dst's length pad
        dstEntities[0] = 0 -- now src's length pad

        -- Only plan (shared) columns swapped sides; a column present on one
        -- side only keeps its pre-swap size. Clamp both capacities to the
        -- smaller side so neither claims rows its shortest column lacks;
        -- per-column storage metadata lets a later reserveCapacity regrow
        -- only the short columns.
        local srcCap = srcArch.capacity
        local dstCap = dstArch.capacity
        local minCap = srcCap < dstCap and srcCap or dstCap
        srcArch.capacity = minCap
        dstArch.capacity = minCap

        local slots = self.allocator.slots as {integer: EntitySlot}
        -- Per-entity update; contiguous slot ranges are not row-ordered.
        for i = 1, count do
            local s = slots[IdAllocator.slotOf(srcEntities[i])]
            s.archetypeId = dstArchId
            s.row = i - 1
        end

        local srcGen = srcArch.generation + 1
        local dstGen = dstArch.generation + 1
        srcArch.generation = srcGen
        dstArch.generation = dstGen
        plan.srcGen = srcGen
        plan.dstGen = dstGen

        dstArch:onRowsAdded(0, count, srcArch)
        if srcArch.observerCount > 0 then
            srcArch:notifyRemoved(0, count, dstArch)
            srcArch:notifyDeactivatedExternal()
        end

        return count, 1
    end

    dstArch:reserveCapacity(dstBase + count)
    dstEntities = dstArch.entities as {integer}
    local dstColumnsNow = dstArch.columns as {Component: {any}}

    local planSrcCols = plan.srcCols as {integer: {any}}
    local planComps = plan.comps as {integer: Component}
    local planStructSizes = plan.structSizes as {integer: integer}
    for c = 1, planCount do
        local srcCol = planSrcCols[c]
        local dstCol = dstColumnsNow[planComps[c]]
        local structSize = planStructSizes[c]
        if structSize > 0 then
            ffi_copy(
                ffi_add_rows(dstCol as C.CData, dstBase + 1), ffi_add_rows(srcCol as C.CData, 1), count * structSize
            )
        else
            table_move(srcCol, 1, count, dstBase + 1, dstCol)
        end
    end

    ffi_copy(
        ffi_add_rows(dstEntities as C.CData, dstBase + 1),
        ffi_add_rows(srcEntities as C.CData, 1),
        count * SIZEOF_DOUBLE
    )
    dstEntities[0] = dstBase + count

    local slots = self.allocator.slots as {integer: EntitySlot}
    -- Per-entity update; contiguous slot ranges are not row-ordered.
    for i = 1, count do
        local s = slots[IdAllocator.slotOf(srcEntities[i])]
        s.archetypeId = dstArchId
        s.row = dstBase + i - 1
    end

    dstArch:onRowsAdded(dstBase, count, srcArch)
    if srcArch.observerCount > 0 then
        srcArch:notifyRemoved(0, count, dstArch)
    end

    srcEntities[0] = 0
    if srcArch.observerCount > 0 then
        srcArch:notifyDeactivatedExternal()
    end

    return count, dstBase + 1
end

local function copyPlanRow(
    planDstCols: {integer: {any}}, planSrcCols: {integer: {any}}, dLuaRow: integer, srcRow: integer, count: integer
)
    for c = 1, count do
        planDstCols[c][dLuaRow] = planSrcCols[c][srcRow]
    end
end

local function applyPendingVals(vals: {any}, dstCols: {Component: {any}}, dLuaRow: integer)
    for v = 1, #vals do
        local inst = vals[v]
        local ct = (inst as {string: any}).componentType as ComponentInternal
        local col = dstCols[ct] as {any}
        if col and ct.storageType ~= "tag" then
            col[dLuaRow] = inst
        end
    end
end

local function applyPendingScalars(ctList: {Component}, values: {any}, dstCols: {Component: {any}}, dLuaRow: integer)
    for i = 1, #ctList do
        local col = dstCols[ctList[i]] as {any}
        if col then
            col[dLuaRow] = values[i]
        end
    end
end

-- A pre-resolved entry in a component's transitive `requires` closure.
local type RequireEntry = internal.RequireEntry

-- Build transitive `requires` closure for `comp`, flattened and deduped.
local function buildRequiresClosure(comp: ComponentInternal): {RequireEntry}
    local entries: {RequireEntry} = {}
    local visited: {Component: boolean} = {[comp] = true}
    local stack: {ComponentInternal} = {comp}
    local top = 1

    while top > 0 do
        local cur = stack[top]
        top = top - 1
        local reqs = cur.requires
        if reqs then
            for i = 1, #reqs do
                local r = reqs[i] as ComponentInternal
                local rType: ComponentInternal
                local sharedValue: Component
                local factory: Component
                if (r.componentType as Component) == r then
                    -- Container entry: shared tag value or per-entity factory.
                    rType = r
                    if r.storageType == "tag" then
                        sharedValue = r
                    else
                        factory = r
                    end
                else
                    -- Instance entry.
                    rType = r.componentType as ComponentInternal
                    sharedValue = r
                end
                if not visited[rType] then
                    visited[rType] = true
                    local entry: RequireEntry = {
                        type = rType,
                        sharedValue = sharedValue,
                        factory = factory,
                        writeColumn = rType.storageType ~= "tag",
                    }
                    entries[#entries + 1] = entry
                    top = top + 1
                    stack[top] = rType
                end
            end
        end
    end

    return entries
end

-- Fetch/build cached transitive requires closure.
local function getRequiresClosure(comp: ComponentInternal): {RequireEntry}
    local closure = comp._requiresClosure
    if closure == nil then
        closure = buildRequiresClosure(comp)
        comp._requiresClosure = closure
    end
    return closure
end

-- Extend `dstArch` with missing required components and collect row writes.
local function applyRequires(
    dstArch: Archetype, comp: ComponentInternal, archetypeIndex: ArchetypeIndex
): Archetype, {RequireEntry}
    if not comp._hasRequires then
        return dstArch, nil
    end
    local closure = getRequiresClosure(comp)
    local missing: {RequireEntry} = nil
    for i = 1, #closure do
        local entry = closure[i]
        if dstArch.columns[entry.type] == nil then
            dstArch = dstArch:withComponent(entry.type, archetypeIndex)
            if entry.writeColumn then
                missing = missing or {}
                missing[#missing + 1] = entry
            end
        end
    end
    return dstArch, missing
end

-- Write row values for missing required entries. Scalar required
-- components produce wrapper instances from their factory; unwrap to
-- the raw value here so columns stay raw.
local function writeRequired(missing: {RequireEntry}, dstArch: Archetype, dLuaRow: integer)
    if missing == nil then
        return
    end
    local cols = dstArch.columns
    for i = 1, #missing do
        local entry = missing[i]
        local col = cols[entry.type] as {any}
        if col then
            local v = entry.sharedValue
            if v == nil then
                v = (entry.factory as function(...: any): Component)()
            end
            if (entry.type as ComponentInternal).storageType == "scalar" then
                col[dLuaRow] = (v as {string: any}).value
            else
                col[dLuaRow] = v
            end
        end
    end
end

-- Write `requires`-supplied defaults across a row range. Table storage
-- gets a fresh factory value per row so rows never share one table;
-- other storages resolve one value and fan it (scalars unwrapped).
local function writeRequiredRange(arch: Archetype, requiredList: {RequireEntry}, rStart: integer, rEnd: integer)
    local cols = arch.columns
    for k = 1, #requiredList do
        local entry = requiredList[k]
        local col = cols[entry.type] as {any}
        if col then
            local storage = (entry.type as ComponentInternal).storageType
            if storage == "table" then
                for r = rStart, rEnd do
                    col[r] = (entry.factory as function(...: any): Component)()
                end
            else
                local v: any = entry.sharedValue
                if v == nil then
                    v = (entry.factory as function(...: any): Component)()
                end
                if storage == "scalar" then
                    v = (v as {string: any}).value
                end
                for r = rStart, rEnd do
                    col[r] = v
                end
            end
        end
    end
end

local function applyBatchSet(self: WorldImpl, mut: BatchMutation, srcArch: Archetype)
    local componentType = mut.componentType
    local archetypeIndex = self.archetypeIndex

    local entities = srcArch.entities as {integer}
    local count = entities[0] as integer
    if count == 0 then
        return
    end

    local hasComponent = srcArch.columns[componentType] ~= nil
    local fast = mut.canBulk
    local isTag = mut.isTag

    if not fast then
        -- Slow path: per-entity `_instantSet` for non-bulk behavior.
        local value = mut.value
        for i = count, 1, -1 do
            self:_instantSet(entities[i], componentType, value)
        end
        return
    end

    if hasComponent then
        if not isTag then
            local col = srcArch.columns[componentType] as {any}
            if mut.op == BATCH_OP_SET_CONST then
                local value = mut.value
                for row = 1, count do
                    col[row] = value
                end
            else
                mut.callback(srcArch, 1, count, count)
            end
        end
        -- The whole column just changed. Observer notification
        -- (notifyAdded) doesn't fire here because no entities were added.
        srcArch:markComponentDirty(componentType)
        return
    end

    local dstArch = srcArch:withComponent(componentType, archetypeIndex)
    local ci = componentType as ComponentInternal
    local requiredList: {RequireEntry} = nil
    if ci._hasRequires then
        dstArch, requiredList = applyRequires(dstArch, ci, archetypeIndex)
    end
    if dstArch == srcArch then
        return
    end
    local moved, firstRow = bulkMoveEntireArchetype(self, srcArch, dstArch)
    if moved == 0 then
        return
    end
    local lastRow = firstRow + moved - 1
    -- Required defaults first; the user's value or callback wins on
    -- any overlap.
    if requiredList then
        writeRequiredRange(dstArch, requiredList, firstRow, lastRow)
    end
    if isTag then
        return
    end

    local newCol = dstArch.columns[componentType] as {any}
    if mut.op == BATCH_OP_SET_CONST then
        local value = mut.value
        for row = firstRow, lastRow do
            newCol[row] = value
        end
    else
        mut.callback(dstArch, firstRow, lastRow, moved)
    end
end

local function applyBatchRemove(self: WorldImpl, mut: BatchMutation, srcArch: Archetype)
    local componentType = mut.componentType
    if srcArch.columns[componentType] == nil then
        return
    end

    local entities = srcArch.entities as {integer}
    local count = entities[0] as integer
    if count == 0 then
        return
    end

    if not mut.canBulk then
        -- Slow path: per-entity `_instantRemove`.
        for i = count, 1, -1 do
            self:_instantRemove(entities[i], componentType)
        end
        return
    end

    local archetypeIndex = self.archetypeIndex
    local dstArch = srcArch:withoutComponent(componentType, archetypeIndex)
    if dstArch == srcArch then
        return
    end
    bulkMoveEntireArchetype(self, srcArch, dstArch)
end

local record shared
    type BatchMutation = BatchMutation

    STATE_SPAWN: integer
    STATE_MUTATE: integer
    STATE_DESPAWN: integer
    BATCH_OP_SET_CONST: integer
    BATCH_OP_SET_CALLBACK: integer
    BATCH_OP_REMOVE: integer

    SIZEOF_DOUBLE: integer
    ffi_add_rows: function(ptr: C.CData, rows: integer): C.CData

    moveSingleEntity: function(
        self: WorldImpl,
        slot: integer,
        srcArch: Archetype,
        srcRow: integer,
        dstArch: Archetype,
        newColumn: {any},
        newValue: Component
    )
    bulkMoveEntireArchetype: function(self: WorldImpl, srcArch: Archetype, dstArch: Archetype): integer, integer
    applyBatchSet: function(self: WorldImpl, mut: BatchMutation, srcArch: Archetype)
    applyBatchRemove: function(self: WorldImpl, mut: BatchMutation, srcArch: Archetype)
    copyPlanRow: function(
        planDstCols: {integer: {any}}, planSrcCols: {integer: {any}}, dLuaRow: integer, srcRow: integer, count: integer
    )
    applyPendingVals: function(vals: {any}, dstCols: {Component: {any}}, dLuaRow: integer)
    applyPendingScalars: function(ctList: {Component}, values: {any}, dstCols: {Component: {any}}, dLuaRow: integer)
    getRequiresClosure: function(comp: ComponentInternal): {RequireEntry}
    applyRequires: function(
        dstArch: Archetype, comp: ComponentInternal, archetypeIndex: ArchetypeIndex
    ): Archetype, {RequireEntry}
    writeRequired: function(missing: {RequireEntry}, dstArch: Archetype, dLuaRow: integer)
    writeRequiredRange: function(arch: Archetype, requiredList: {RequireEntry}, rStart: integer, rEnd: integer)

    getEntityState: function(world: WorldImpl, slot: integer): integer
    setEntityState: function(world: WorldImpl, slot: integer, state: integer)
    getPendingArch: function(world: WorldImpl, slot: integer): Archetype
    setPendingArch: function(world: WorldImpl, slot: integer, arch: Archetype)
    bumpTransactionEpoch: function(world: WorldImpl)
end

shared.STATE_SPAWN = STATE_SPAWN
shared.STATE_MUTATE = STATE_MUTATE
shared.STATE_DESPAWN = STATE_DESPAWN
shared.BATCH_OP_SET_CONST = BATCH_OP_SET_CONST
shared.BATCH_OP_SET_CALLBACK = BATCH_OP_SET_CALLBACK
shared.BATCH_OP_REMOVE = BATCH_OP_REMOVE
shared.SIZEOF_DOUBLE = SIZEOF_DOUBLE
shared.ffi_add_rows = ffi_add_rows
shared.moveSingleEntity = moveSingleEntity
shared.bulkMoveEntireArchetype = bulkMoveEntireArchetype
shared.applyBatchSet = applyBatchSet
shared.applyBatchRemove = applyBatchRemove
shared.copyPlanRow = copyPlanRow
shared.applyPendingVals = applyPendingVals
shared.applyPendingScalars = applyPendingScalars
shared.getRequiresClosure = getRequiresClosure
shared.applyRequires = applyRequires
shared.writeRequired = writeRequired
shared.writeRequiredRange = writeRequiredRange
shared.getEntityState = getEntityState
shared.setEntityState = setEntityState
shared.getPendingArch = getPendingArch
shared.setPendingArch = setPendingArch
shared.bumpTransactionEpoch = bumpTransactionEpoch

return shared
