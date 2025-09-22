--[[
Instant mutation paths (spawn/set/remove/despawn) used when `_scopeDepth == 0`.
Complex or nested cases route through deferred paths under a synthetic scope.
]]

local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")
local events <const> = require("tecs.internal.events")
local IdAllocator <const> = require("tecs.internal.IdAllocator")
local builtins <const> = require("tecs.internal.builtins")
local shared <const> = require("tecs.internal.world.shared")

local type Component = types.components.Component
local type Archetype = internal.ArchetypeInternal
local type ComponentInternal = internal.ComponentInternal
local type EntitySlot = IdAllocator.EntitySlot

local WorldImpl = internal.WorldImpl
local moveSingleEntity <const> = shared.moveSingleEntity
local applyRequires <const> = shared.applyRequires
local writeRequired <const> = shared.writeRequired
local getEntityState <const> = shared.getEntityState
local OnDespawn <const> = builtins.OnDespawn

local select <const> = select

-- `_instantSpawn` runs when `_scopeDepth == 0` and the args don't
-- require deferred semantics. It writes directly into the target
-- archetype's committed row, skipping the pending-write queue.
-- Relationship components aren't supported here (no sparse/exclusive
-- logic) — the first one encountered bubbles up `false` so the caller
-- falls back to the deferred path. The body is split into per-phase
-- macros so instantSpawn1..4 unroll cleanly (no variable-index
-- `select(i, ...)` on the hot path) while N>=5 loops.

-- Common setup: target starts at empty archetype; requires closure
-- entries collect across args and are applied at end.
local macro instantBegin!()
    return ```
        local target = self.emptyArchetype as Archetype
        local requiredList: {internal.RequireEntry}
    ```
end

-- Per-component Phase A: bail out if relationship (caller falls back
-- to deferred), extend arch, merge requires closure.
local macro instantResolveOne!(compExpr: Expression)
    return ```
        do
            local comp = $compExpr
            local ct = comp.componentType as ComponentInternal
            if ct.relationshipType ~= nil then
                return false, 0
            end
            target = target:withComponent(ct, self.archetypeIndex)
            if ct._hasRequires then
                local extension: {internal.RequireEntry}
                target, extension = applyRequires(target, ct, self.archetypeIndex)
                if extension then
                    if requiredList == nil then
                        requiredList = extension
                    else
                        for k = 1, #extension do
                            requiredList[#requiredList + 1] = extension[k]
                        end
                    end
                end
            end
        end
    ```
end

-- Between resolve and write: apply autoState, alloc slot, encode id,
-- reserve capacity, write id into entities, set slot metadata. Leaves
-- `target`, `slot`, `sSlot`, `id`, `newRow`, `dstLuaRow`, `dstEntities`
-- in scope for instantWriteOne! and instantFinish!.
local macro instantMiddle!()
    return ```
        local autoState = self.autoStateComponent
        if autoState then
            target = target:withComponent(autoState, self.archetypeIndex)
        end

        local slot = IdAllocator.allocSlot(self.allocator)
        local slots = self.allocator.slots as {integer: EntitySlot}
        local sSlot = slots[slot]
        local id = IdAllocator.encodeId(slot, sSlot.generation)

        local newRow = (target.entities as {integer})[0] as integer
        if newRow + 1 > target.capacity then
            target:reserveCapacity(newRow + 1)
        end
        local dstEntities = target.entities as {integer}
        local dstLuaRow = newRow + 1
        dstEntities[dstLuaRow] = id
        dstEntities[0] = newRow + 1

        sSlot.archetypeId = target.id
        sSlot.row = newRow
    ```
end

-- Per-component Phase B: write comp into its column at the placed row.
-- Scalar wrappers (`Name("Frank")`) carry a raw value alongside the type;
-- unwrap at this boundary so columns hold raw scalars.
local macro instantWriteOne!(compExpr: Expression)
    return ```
        do
            local comp = $compExpr
            local ct = comp.componentType as Component
            local col = target.columns[ct] as {any}
            if col then
                if (ct as ComponentInternal).storageType == "scalar" then
                    col[dstLuaRow] = (comp as {string:any}).value
                else
                    col[dstLuaRow] = comp
                end
            end
        end
    ```
end

-- Common finalization: write required-closure values, fire observers,
-- return (true, id).
local macro instantFinish!()
    return ```
        writeRequired(requiredList, target, dstLuaRow)

        target:onRowsAdded(newRow, 1, nil)

        return true, id
    ```
end

-- Dispatcher: hook-bearing components either must defer (synthetic scope
-- routes to deferred dispatcher) or run the hook eagerly on the instant
-- path. Flag-free components fall through to the Raw body.
function WorldImpl:_instantSet(id: integer, componentType: Component, value: any)
    local ci = componentType as ComponentInternal
    if ci._mustDeferSet then
        self._scopeDepth = self._scopeDepth + 1
        self:_deferSet(id, componentType, value)
        self._scopeDepth = self._scopeDepth - 1
        if self._scopeDepth == 0 and self.isDirty then self:_drain() end
        return
    end
    if ci._hasDeferSet then
        return ci.deferSet(self, id, componentType, value)
    end
    return self:instantSetRaw(id, componentType, value)
end

-- Raw default-behavior entry. Hooks call this to invoke default semantics.
function WorldImpl:instantSetRaw(id: integer, componentType: Component, value: any)
    local slot = IdAllocator.slotOf(id)

    -- Entity mid-transaction (bundle spawn / batch spawn pre-commit,
    -- etc.) routes through the staging path — it knows how to walk
    -- the pending-arch state. Unknown entities error there too.
    if getEntityState(self, slot) ~= 0 then
        self._scopeDepth = self._scopeDepth + 1
        self:_deferSet(id, componentType as Component, value)
        self._scopeDepth = self._scopeDepth - 1
        if self._scopeDepth == 0 and self.isDirty then self:_drain() end
        return
    end

    local slots = self.allocator.slots as {integer: EntitySlot}
    local s = slots[slot]
    local srcArch = self.archetypeIndex[s.archetypeId]
    -- Unknown archetype (entity state out of sync): fall back to staged.
    -- Exclusive-relationship handling migrated to `deferSet` hook — the
    -- dispatcher fires the hook before reaching this Raw path.
    if not srcArch then
        self._scopeDepth = self._scopeDepth + 1
        self:_deferSet(id, componentType as Component, value)
        self._scopeDepth = self._scopeDepth - 1
        if self._scopeDepth == 0 and self.isDirty then self:_drain() end
        return
    end

    local srcRow = s.row
    local srcLuaRow = srcRow + 1

    local existingCol = srcArch.columns[componentType as Component] as {any}
    if existingCol then
        -- Same-archetype value write. The component-dirty bit signals
        -- to shadow buffers / incremental sync that this column changed; no
        -- notifyAdded because no entities were added.
        existingCol[srcLuaRow] = value
        srcArch:markComponentDirty(componentType as Component)
        return
    end

    local dstArch = srcArch:withComponent(componentType as Component, self.archetypeIndex)

    local ci = componentType as ComponentInternal
    local requiredList: {internal.RequireEntry}
    if ci._hasRequires then
        dstArch, requiredList = applyRequires(dstArch, ci, self.archetypeIndex)
    end

    if dstArch == srcArch then return end

    -- `withComponent` handles wildcard container insertion for dense rel instances.

    local newRow = (dstArch.entities as {integer})[0] as integer
    if newRow + 1 > dstArch.capacity then
        dstArch:reserveCapacity(newRow + 1)
    end
    local dstEntities = dstArch.entities as {integer}
    local dstLuaRow = newRow + 1

    local plan = srcArch:getMovePlanTo(dstArch) as internal.MovePlan
    local planSrcCols = plan.srcCols as {integer: {any}}
    local planDstCols = plan.dstCols as {integer: {any}}
    for c = 1, plan.count do
        planDstCols[c][dstLuaRow] = planSrcCols[c][srcLuaRow]
    end

    local newCol = dstArch.columns[componentType as Component] as {any}
    if newCol then
        newCol[dstLuaRow] = value
    end
    writeRequired(requiredList, dstArch, dstLuaRow)

    local packedId = (srcArch.entities as {integer})[srcLuaRow]
    dstEntities[dstLuaRow] = packedId
    dstEntities[0] = newRow + 1

    s.archetypeId = dstArch.id
    s.row = newRow

    -- Reverse-index link migrated to `deferSet` hook (Phase 3). Reached
    -- via the dispatcher above when `_hasDeferSet` is set on the dense
    -- relationship container. Instant path lands here only when no hook.

    dstArch:onRowsAdded(newRow, 1, srcArch)

    local movedEntId = srcArch:removeEntity(srcRow, dstArch)
    if movedEntId ~= 0 then
        local movedSlot = IdAllocator.slotOf(movedEntId)
        slots[movedSlot].row = srcRow
    end
end

-- Dispatcher: hook-bearing components either must defer (synthetic scope
-- routes to deferred dispatcher) or run the hook eagerly on the instant
-- path. Flag-free components fall through to the Raw body.
function WorldImpl:_instantRemove(id: integer, component: Component)
    local ci = component as ComponentInternal
    if ci._mustDeferRemove then
        self._scopeDepth = self._scopeDepth + 1
        self:_deferRemove(id, component)
        self._scopeDepth = self._scopeDepth - 1
        if self._scopeDepth == 0 and self.isDirty then self:_drain() end
        return
    end
    if ci._hasDeferRemove then
        return ci.deferRemove(self, id, component)
    end
    return self:instantRemoveRaw(id, component)
end

-- Raw default-behavior entry. Hooks call this to invoke default semantics.
function WorldImpl:instantRemoveRaw(id: integer, component: Component)
    local slot = IdAllocator.slotOf(id)

    -- Entity mid-transaction routes through staging for the same
    -- reasons as `_instantSet` (bundle/batch spawn pre-commit, etc.).
    if getEntityState(self, slot) ~= 0 then
        self._scopeDepth = self._scopeDepth + 1
        self:_deferRemove(id, component)
        self._scopeDepth = self._scopeDepth - 1
        if self._scopeDepth == 0 and self.isDirty then self:_drain() end
        return
    end

    local slots = self.allocator.slots as {integer: EntitySlot}
    local s = slots[slot]
    local srcArch = self.archetypeIndex[s.archetypeId]
    if not srcArch then return end

    -- Reverse-index unlink migrated to `deferRemove` hook (Phase 3).
    -- Instant path lands here only when no hook is attached; plain
    -- components fall straight through the archetype transition.
    if not srcArch.columns[component] then return end

    local dstArch = srcArch:withoutComponent(component, self.archetypeIndex)
    if dstArch == srcArch then return end

    moveSingleEntity(self, slot, srcArch, s.row, dstArch, nil, nil)
end

local function instantSpawn1(self: WorldImpl, c1: Component): boolean, integer
    instantBegin!()
    instantResolveOne!(c1)
    instantMiddle!()
    instantWriteOne!(c1)
    instantFinish!()
end

local function instantSpawn2(self: WorldImpl, c1: Component, c2: Component): boolean, integer
    instantBegin!()
    instantResolveOne!(c1)
    instantResolveOne!(c2)
    instantMiddle!()
    instantWriteOne!(c1)
    instantWriteOne!(c2)
    instantFinish!()
end

local function instantSpawn3(self: WorldImpl, c1: Component, c2: Component, c3: Component): boolean, integer
    instantBegin!()
    instantResolveOne!(c1)
    instantResolveOne!(c2)
    instantResolveOne!(c3)
    instantMiddle!()
    instantWriteOne!(c1)
    instantWriteOne!(c2)
    instantWriteOne!(c3)
    instantFinish!()
end

local function instantSpawn4(self: WorldImpl,
        c1: Component, c2: Component, c3: Component, c4: Component): boolean, integer
    instantBegin!()
    instantResolveOne!(c1)
    instantResolveOne!(c2)
    instantResolveOne!(c3)
    instantResolveOne!(c4)
    instantMiddle!()
    instantWriteOne!(c1)
    instantWriteOne!(c2)
    instantWriteOne!(c3)
    instantWriteOne!(c4)
    instantFinish!()
end

-- Fallback for N > 4: variable-index `select(i, ...)` (trace-hostile
-- on LuaJIT). The unrolled 1..4 cases above are the fast paths.
local function instantSpawnN(self: WorldImpl, ...: Component): boolean, integer
    local n = select('#', ...)
    instantBegin!()
    for i = 1, n do
        instantResolveOne!(select(i, ...))
    end
    instantMiddle!()
    for i = 1, n do
        instantWriteOne!(select(i, ...))
    end
    instantFinish!()
end

function WorldImpl:_instantSpawn(...: Component): boolean, integer
    local n = select('#', ...)
    if n == 1 then
        return instantSpawn1(self, select(1, ...))
    elseif n == 2 then
        return instantSpawn2(self, select(1, ...), select(2, ...))
    elseif n == 3 then
        return instantSpawn3(self, select(1, ...), select(2, ...), select(3, ...))
    elseif n == 4 then
        return instantSpawn4(self, select(1, ...), select(2, ...), select(3, ...), select(4, ...))
    else
        return instantSpawnN(self, ...)
    end
end

function WorldImpl:_instantDespawn(id: integer): boolean
    local slot = IdAllocator.slotOf(id)
    local slots = self.allocator.slots
    local s = slots[slot]
    local srcArch = self.archetypeIndex[s.archetypeId]

    -- Archetypes with any onDespawn hook need per-entity dispatch so the
    -- drain path fires the hooks (reverse-index unlink, etc.). Fall back
    -- to the deferred despawn path here.
    if not srcArch or srcArch.onDespawnCount > 0 then
        return false
    end

    if self._hasRelationshipStores then
        if self._targetRefCounts[id] then
            return false
        end
    end

    local messages = self.messages as events.MessageBus
    if (messages._totalObservers as integer) > 0 then
        local hasGlobalObs = self:hasObservers(0, OnDespawn)
        local hasObs = self:hasObservers(id, OnDespawn)
        if hasGlobalObs or hasObs then
            if hasObs then self:emit(id, OnDespawn, id) end
            if hasGlobalObs then self:emit(0, OnDespawn, id) end
            self:clearObservers(id)
        end
    end

    local movedEntId = srcArch:removeEntity(s.row, nil)
    if movedEntId ~= 0 then
        local movedSlot = IdAllocator.slotOf(movedEntId)
        slots[movedSlot].row = s.row
    end

    IdAllocator.freeSlot(self.allocator, slot)
    return true
end

return {}
