--[[
Deferred mutation paths for `_scopeDepth > 0` and eager fallbacks.
Writes stage into archetype queues; drain performs placement/moves.
]]

local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")
local IdAllocator <const> = require("tecs.internal.IdAllocator")
local builtins <const> = require("tecs.internal.builtins")
local table_clear <const> = require("table.clear")
local shared <const> = require("tecs.internal.world.shared")

local type Component = types.components.Component
local type Archetype = internal.ArchetypeInternal
local type ComponentInternal = internal.ComponentInternal
local type EntitySlot = IdAllocator.EntitySlot

local WorldImpl = internal.WorldImpl

local STATE_SPAWN <const> = shared.STATE_SPAWN
local STATE_MUTATE <const> = shared.STATE_MUTATE
local STATE_DESPAWN <const> = shared.STATE_DESPAWN

local getRequiresClosure <const> = shared.getRequiresClosure
local getEntityState <const> = shared.getEntityState
local setEntityState <const> = shared.setEntityState
local getPendingArch <const> = shared.getPendingArch
local setPendingArch <const> = shared.setPendingArch

local OnSpawn <const> = builtins.OnSpawn
local OnDespawn <const> = builtins.OnDespawn

local pairs <const> = pairs
local select <const> = select

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

-- Per-component body of the stage-arg loop, inlined for deferSpawn1..4
-- so each specialization is a single trace with no variable-index
-- `select(i, ...)` (trace-hostile) and no per-component function call.
--
-- Each expansion reads/writes the outer locals:
--   self, world, archetypeIndex, id  — stable per call
--   arch, vals, valCount             — accumulator state
--   exclusiveByContainer             — lazily-acquired pool table
--
-- The `do ... end` block scopes the per-component temporaries so that
-- repeated expansions in the same function don't collide.
local macro deferOne!(compExpr: Expression)
    return ```
        do
            local comp = $compExpr
            local ct = comp.componentType as ComponentInternal

            -- Sparse relationships stash the value on the per-world
            -- store; the archetype only records the container type.
            local relType = ct.relationshipType as ComponentInternal
            if relType and relType.isSparse then
                -- Bare wildcard containers stay dense-only (archetype
                -- presence). Only real sparse instances with a target
                -- belong in the sparse staging/store path.
                if (comp as {string:any}).target ~= nil then
                    self:setSparseRaw(id, comp as any)
                end
                ct = relType
                comp = relType
            end

            -- Non-nil only for dense relationship instances.
            local container = ct.wildcardContainer

            -- Exclusive dense relationships: later sibling replaces earlier sibling.
            if container and (ct as types.components.Relationship).exclusiveRelationship then
                exclusiveByContainer = exclusiveByContainer or (self._exclusivePool:acquire() as {Component: integer})
                local priorIdx = exclusiveByContainer[container]
                if priorIdx then
                    local priorComp = vals[priorIdx] as Component
                    local priorCt = priorComp.componentType as Component
                    if priorCt ~= ct then
                        if priorIdx ~= valCount then
                            vals[priorIdx] = vals[valCount]
                            local movedCt = (vals[priorIdx] as Component).componentType as ComponentInternal
                            local movedContainer = movedCt.wildcardContainer
                            if movedContainer
                                    and (movedCt as types.components.Relationship).exclusiveRelationship
                                    and exclusiveByContainer[movedContainer] == valCount then
                                exclusiveByContainer[movedContainer] = priorIdx
                            end
                        end
                        vals[valCount] = nil
                        valCount = valCount - 1
                        arch = arch:withoutComponent(priorCt, archetypeIndex)
                        if (container as ComponentInternal).reverseIndex then
                            local store = world.relationshipStores[container]
                            if store then
                                store:unlink(id, (priorComp as {string: integer}).target)
                            end
                        end
                    end
                end
            end

            arch = arch:withComponent(ct, archetypeIndex)
            -- Scalar wrappers (`Name("Frank")`) carry both componentType
            -- and a raw value; unwrap into the per-arch scalar staging
            -- pair so `vals[]` never holds wrapper tables. Internals
            -- read raw scalars from `pendingScalarValues` directly.
            -- Scalars can't be relationships so the wildcard / exclusive
            -- bookkeeping below is unreachable for this branch.
            if ct.storageType == "scalar" then
                stageScalar(self, arch, slot, ct as Component, (comp as {string:any}).value)
            else
                valCount = valCount + 1
                vals[valCount] = comp
            end

            if container and (ct as types.components.Relationship).exclusiveRelationship then
                exclusiveByContainer[container] = valCount
            end

            if container then
                if arch.columns[container] == nil then
                    arch = arch:withComponent(container, archetypeIndex)
                    valCount = valCount + 1
                    vals[valCount] = container
                end
                if (container as ComponentInternal).reverseIndex then
                    local store = world.relationshipStores[container]
                    if store then
                        store:link(id, comp.target)
                    end
                end
            end

            -- Declarative `requires`: expand ct's cached transitive
            -- closure inline. arch growth is monotonic (except the
            -- exclusive swap above, which only drops the prior sibling's
            -- own type), so expanding here is order-equivalent to a
            -- trailing second pass: if a later user-provided arg supplies
            -- a required component, its `withComponent` is a no-op and
            -- the drain's last-write-wins applies its value.
            local cti = ct as ComponentInternal
            if cti._hasRequires then
                local closure = getRequiresClosure(cti)
                for j = 1, #closure do
                    local entry = closure[j]
                    local rType = entry.type
                    if arch.columns[rType] == nil then
                        arch = arch:withComponent(rType, archetypeIndex)
                        local v = entry.sharedValue
                        if v == nil then
                            v = (entry.factory as function(...: any): Component)()
                        end
                        if (rType as ComponentInternal).storageType == "scalar" then
                            stageScalar(self, arch, slot, rType, (v as {string:any}).value)
                        else
                            valCount = valCount + 1
                            vals[valCount] = v
                        end
                    end
                end
            end
        end
    ```
end

local function borrowVals(self: WorldImpl): {any}
    local n = self._valsPoolNext
    self._valsPoolNext = n + 1
    local t: {any}
    if n <= self._valsPoolSize then
        t = self._valsPool[n]
        table_clear(t)
    else
        t = {}
        self._valsPool[n] = t
        self._valsPoolSize = n
    end
    return t
end

local function appendPendingValue(self: WorldImpl, arch: Archetype, slot: integer, value: any)
    local vals = arch:getPendingValues(slot)
    if vals then
        vals[#vals + 1] = value
    else
        arch:appendPendingValue(slot, value, borrowVals(self))
    end
end

-- Append a scalar staging pair to the archetype's parallel arrays.
-- Scalars stay separate so drain can skip wrapper checks.
local function stageScalar(
    self: WorldImpl,
    arch: Archetype,
    slot: integer,
    componentType: Component,
    value: any
)
    local ctList = arch.pendingScalarTypes[slot]
    local values: {any}
    if ctList then
        values = arch.pendingScalarValues[slot]
    else
        ctList = borrowVals(self) as {Component}
        values = borrowVals(self)
        arch.pendingScalarTypes[slot] = ctList
        arch.pendingScalarValues[slot] = values
        arch.hasScalarPending = true
    end
    local n = #ctList + 1
    ctList[n] = componentType
    values[n] = value
end

-- Move both the instance-list AND the scalar pair from one archetype to
-- another when an entity's pending archetype shifts under it. The scalar
-- branch is gated on `src.hasScalarPending` so archetypes that never
-- touched scalars this transaction pay nothing.
local function migratePending(src: Archetype, dst: Archetype, slot: integer)
    src:movePendingValuesTo(dst, slot)
    if not src.hasScalarPending then return end
    local ctList = src.pendingScalarTypes[slot]
    if ctList then
        local values = src.pendingScalarValues[slot]
        src.pendingScalarTypes[slot] = nil
        src.pendingScalarValues[slot] = nil
        dst.pendingScalarTypes[slot] = ctList
        dst.pendingScalarValues[slot] = values
        dst.hasScalarPending = true
    end
end

-- Common setup: mark the slot as a spawn claim, emit OnSpawn, and
-- return freshly-borrowed accumulator state. Called from every
-- deferSpawnN; shared by the macro expansions in those functions.
local macro deferBegin!()
    return ```
        local world = self
        local archetypeIndex = self.archetypeIndex

        setEntityState(self, slot, STATE_SPAWN)
        self.entityStateCount = self.entityStateCount + 1
        self.isDirty = true

        world:emit(0, OnSpawn, id)

        local arch = self.emptyArchetype as Archetype
        local vals: {any} = borrowVals(self)
        local valCount = 0
        -- Lazily acquired on the first exclusive-relationship hit.
        local exclusiveByContainer: {Component: integer} = nil
    ```
end

-- Common finalization: tack on autoState, stash the spawn on the target
-- archetype's pending-write queues, mark the arch dirty for drain, and
-- release the exclusivity map back to its pool. Mirrors the trailing
-- block of the original single `deferSpawn`.
local macro deferFinish!()
    return ```
        local autoState = self.autoStateComponent
        if autoState then
            arch = arch:withComponent(autoState, archetypeIndex)
            valCount = valCount + 1
            vals[valCount] = autoState
        end

        setPendingArch(self, slot, arch)
        arch.pendingWrites = arch.pendingWrites + 1
        for i = 1, valCount do
            appendPendingValue(self, arch, slot, vals[i])
        end

        local c = arch.pendingSpawnCount + 1
        arch.pendingSpawnCount = c
        (arch.pendingSpawnIds as {integer})[c] = id

        -- Inlined markDirty! body (macros don't compose).
        arch.hasPendingSpawns = true
        if arch.dirtyQueuedEpoch ~= self._dirtyEpoch then
            arch.dirtyQueuedEpoch = self._dirtyEpoch
            local __c = self.dirtyArchetypeCount + 1
            self.dirtyArchetypeList[__c] = arch
            self.dirtyArchetypeCount = __c
        end

        if exclusiveByContainer then
            self._exclusivePool:release(exclusiveByContainer)
        end
    ```
end

local function deferSpawn1(self: WorldImpl, slot: integer, id: integer, c1: Component)
    deferBegin!()
    deferOne!(c1)
    deferFinish!()
end

local function deferSpawn2(self: WorldImpl, slot: integer, id: integer, c1: Component, c2: Component)
    deferBegin!()
    deferOne!(c1)
    deferOne!(c2)
    deferFinish!()
end

local function deferSpawn3(self: WorldImpl, slot: integer, id: integer, c1: Component, c2: Component, c3: Component)
    deferBegin!()
    deferOne!(c1)
    deferOne!(c2)
    deferOne!(c3)
    deferFinish!()
end

local function deferSpawn4(self: WorldImpl, slot: integer, id: integer,
                           c1: Component, c2: Component, c3: Component, c4: Component)
    deferBegin!()
    deferOne!(c1)
    deferOne!(c2)
    deferOne!(c3)
    deferOne!(c4)
    deferFinish!()
end

-- Fallback for N > 4. Falls back to variable-index `select(i, ...)`
-- (trace-hostile on LuaJIT) — the unrolled deferSpawn1..4 are the
-- fast paths that cover the overwhelming majority of real spawns.
local function deferSpawnN(self: WorldImpl, slot: integer, id: integer, ...: Component)
    local n = select("#", ...)
    deferBegin!()
    for i = 1, n do
        deferOne!(select(i, ...))
    end
    deferFinish!()
end

local function deferSpawn(self: WorldImpl, slot: integer, id: integer, ...: Component)
    local n = select("#", ...)
    if n == 1 then
        deferSpawn1(self, slot, id, select(1, ...))
    elseif n == 2 then
        deferSpawn2(self, slot, id, select(1, ...), select(2, ...))
    elseif n == 3 then
        deferSpawn3(self, slot, id, select(1, ...), select(2, ...), select(3, ...))
    elseif n == 4 then
        deferSpawn4(self, slot, id, select(1, ...), select(2, ...), select(3, ...), select(4, ...))
    else
        deferSpawnN(self, slot, id, ...)
    end
end

function WorldImpl:_deferSpawn(...: Component): integer
    local allocator = self.allocator
    local slot = IdAllocator.allocSlot(allocator)
    local generation = (allocator.slots as {integer: EntitySlot})[slot].generation
    local id = IdAllocator.encodeId(slot, generation)
    deferSpawn(self, slot, id, ...)
    return id
end

function WorldImpl:_deferSpawnAt(id: integer, ...: Component)
    local slot = IdAllocator.slotOf(id)
    local generation = IdAllocator.generationOfWithSlot(id, slot)
    local allocator = self.allocator
    -- Guard against out-of-range decoded slots before touching arena cdata.
    if slot < 1 or slot >= allocator.maxSlotCount then
        error("spawnAt: id " .. tostring(id) .. " decodes to slot " .. tostring(slot) ..
            " which is outside the configured slot range [1, " ..
            tostring(allocator.maxSlotCount) .. "). Check the encoding " ..
            "(IdAllocator.encodeId: slot + generation * 2^22).")
    end
    if slot >= allocator.nextFreshSlot then
        allocator.nextFreshSlot = slot + 1
    end
    (allocator.slots as {integer: EntitySlot})[slot].generation = generation
    deferSpawn(self, slot, id, ...)
end

function WorldImpl:findOldValue(
    slot: integer,
    componentType: Component,
    sourceArch: Archetype,
    sourceRow: integer
): any
    -- Check pending staging first.
    local pendingArch = getPendingArch(self, slot)
    if pendingArch then
        local st = getEntityState(self, slot)
        local stageArch: Archetype
        if st == STATE_SPAWN then
            stageArch = pendingArch
        else
            stageArch = sourceArch
        end
        if stageArch then
            if (componentType as ComponentInternal).storageType == "scalar" then
                local ctList = stageArch.pendingScalarTypes[slot]
                if ctList then
                    local values = stageArch.pendingScalarValues[slot]
                    for i = #ctList, 1, -1 do
                        if ctList[i] == componentType then
                            return values[i]
                        end
                    end
                end
            else
                return stageArch:findPendingValue(slot, componentType)
            end
        end
    end
    if sourceArch then
        local sourceCol = sourceArch.columns[componentType]
        if sourceCol then
            return (sourceCol as {any})[sourceRow + 1]
        end
    end
    return nil
end

-- Dispatcher: flag-gate hook check, fall through to Raw for default.
-- Underscored — users call `world:set`, not this directly.
function WorldImpl:_deferSet(id: integer, componentType: Component, value: any)
    local ci = componentType as ComponentInternal
    if ci._hasDeferSet then
        return ci.deferSet(self, id, componentType, value)
    end
    return self:deferSetRaw(id, componentType, value)
end

-- Raw default-behavior entry. Hooks call this to invoke default semantics
-- without re-dispatching (which would recurse into themselves).
function WorldImpl:deferSetRaw(id: integer, componentType: Component, value: any)
    local slot = IdAllocator.slotOf(id)

    -- Fast path: committed entity, plain component, no staged state.
    if getEntityState(self, slot) == 0 then
        local s = (self.allocator.slots as {integer: EntitySlot})[slot]
        local archetype = self.archetypeIndex[s.archetypeId]
        if archetype then
            local row = s.row
            -- Reuse last archetype+component column cache.
            local column: {any}
            if archetype == self.lastArch and componentType == self.lastCompType then
                column = self.lastColumn as {any}
            else
                column = archetype.columns[componentType as Component] as {any}
                self.lastCompType = componentType as Component
                self.lastArch = archetype
                self.lastColumn = column
            end
            if column then
                -- Same-archetype value update.
                local luaRow = row + 1
                column[luaRow] = value
                archetype:markComponentDirty(componentType as Component)
                return
            elseif componentType.relationshipType == nil then
                -- Plain structural add: stage move out of source archetype.
                local newArch = archetype:withComponent(componentType as Component, self.archetypeIndex)
                if newArch ~= archetype then
                    if (componentType as ComponentInternal).storageType == "scalar" then
                        stageScalar(self, archetype, slot, componentType as Component, value)
                    else
                        appendPendingValue(self, archetype, slot, value)
                    end
                    newArch.pendingWrites = newArch.pendingWrites + 1
                    markDirty!(archetype, hasPendingMoveOut)
                    setPendingArch(self, slot, newArch)
                end
                setEntityState(self, slot, STATE_MUTATE)
                self.entityStateCount = self.entityStateCount + 1
                self.isDirty = true
                return
            end
        end
    end

    self:_deferSetSlow(id, componentType as Component, value)
end

function WorldImpl:_deferSetSlow(
    id: integer,
    componentType: Component,
    value: any
)
    local slot = IdAllocator.slotOf(id)
    local st = getEntityState(self, slot)
    if st == STATE_DESPAWN then return end

    -- Tags carry no per-row payload; avoid appending/allocating tag values.
    local ctI = componentType as ComponentInternal
    local isTag = ctI.storageType == "tag"
    local isScalar = ctI.storageType == "scalar"

    do
        local pendingArch = getPendingArch(self, slot)
        if pendingArch and (st == STATE_SPAWN or st == STATE_MUTATE) then
            local newArch = pendingArch:withComponent(componentType, self.archetypeIndex)

            if st == STATE_SPAWN then
                if newArch ~= pendingArch then
                    local c = newArch.pendingSpawnCount + 1
                    newArch.pendingSpawnCount = c
                    (newArch.pendingSpawnIds as {integer})[c] = id
                    markDirty!(newArch, hasPendingSpawns)
                    migratePending(pendingArch, newArch, slot)
                    if isScalar then
                        stageScalar(self, newArch, slot, componentType, value)
                    elseif not isTag then
                        appendPendingValue(self, newArch, slot, value)
                    end
                elseif isScalar then
                    stageScalar(self, pendingArch, slot, componentType, value)
                elseif not isTag then
                    appendPendingValue(self, pendingArch, slot, value)
                end
            else
                -- For committed entities, pending values stay on source archetype.
                local srcSlot = (self.allocator.slots as {integer: EntitySlot})[slot]
                local srcArch = self.archetypeIndex[srcSlot.archetypeId]
                if newArch ~= pendingArch then
                    pendingArch.pendingWrites = pendingArch.pendingWrites - 1
                    newArch.pendingWrites = newArch.pendingWrites + 1
                    -- Ensure moves pass sees this source archetype.
                    if srcArch then
                        markDirty!(srcArch, hasPendingMoveOut)
                    end
                end
                if isScalar then
                    if srcArch then
                        stageScalar(self, srcArch, slot, componentType, value)
                    end
                elseif not isTag then
                    appendPendingValue(self, srcArch as Archetype, slot, value)
                end
            end

            setPendingArch(self, slot, newArch)
            self.isDirty = true
            return
        end

        -- No pending arch yet: derive start archetype from state.
        local srcSlot = (self.allocator.slots as {integer: EntitySlot})[slot]
        local startArch: Archetype
        if st == STATE_SPAWN then
            startArch = self.archetypeIndex[srcSlot.archetypeId] or self.emptyArchetype
        else
            startArch = getPendingArch(self, slot)
            if not startArch then
                startArch = self.archetypeIndex[srcSlot.archetypeId]
                if not startArch then
                    error("Entity ID not found: " .. id)
                end
            end
        end

        local newArch = startArch:withComponent(componentType, self.archetypeIndex)
        newArch.pendingWrites = newArch.pendingWrites + 1
        setPendingArch(self, slot, newArch)
        if st == 0 then
            setEntityState(self, slot, STATE_MUTATE)
            self.entityStateCount = self.entityStateCount + 1
        end
        if st == STATE_SPAWN then
            local sc = newArch.pendingSpawnCount + 1
            newArch.pendingSpawnCount = sc
            (newArch.pendingSpawnIds as {integer})[sc] = id
            markDirty!(newArch, hasPendingSpawns)
            if isScalar then
                stageScalar(self, newArch, slot, componentType, value)
            elseif not isTag then
                appendPendingValue(self, newArch, slot, value)
            end
        else
            markDirty!(startArch, hasPendingMoveOut)
            if isScalar then
                stageScalar(self, startArch, slot, componentType, value)
            elseif not isTag then
                appendPendingValue(self, startArch, slot, value)
            end
        end
        self.isDirty = true
    end

    local hadComponent = false
    if st ~= STATE_SPAWN then
        local srcSlot = (self.allocator.slots as {integer: EntitySlot})[slot]
        local sourceArch = self.archetypeIndex[srcSlot.archetypeId]
        if sourceArch and sourceArch.columns[componentType] ~= nil then
            hadComponent = true
        end
    end

    if hadComponent then
        -- Value-only update; drain applies pending value.
        return
    end

    -- New component path: dense-relationship structural bookkeeping.
    -- Reverse-index link (Phase 3) and exclusive sibling eviction (Phase 4)
    -- both migrated out to `deferSet` hooks. The deferSpawn macro keeps
    -- both inline because it can't reach into hooks without giving up
    -- in-place accumulator compaction (Phase 4 Option A).
    --
    -- What remains here: wildcard container auto-add for dense relationship
    -- instances, which is structural (touches archetype membership) rather
    -- than behavioral, so it stays in the Raw path.
    local container = (componentType as ComponentInternal).wildcardContainer
    if container then
        local curArch = getPendingArch(self, slot)
        if curArch.columns[container] == nil then
            self:_deferSetSlow(id, container, container)
        end
    end
end

-- Dispatcher: flag-gate hook check, fall through to Raw for default.
function WorldImpl:_deferRemove(id: integer, component: Component)
    local ci = component as ComponentInternal
    if ci._hasDeferRemove then
        return ci.deferRemove(self, id, component)
    end
    return self:deferRemoveRaw(id, component)
end

-- Raw default-behavior entry. Hooks call this to invoke default semantics.
function WorldImpl:deferRemoveRaw(id: integer, component: Component)
    local slot = IdAllocator.slotOf(id)
    local st = getEntityState(self, slot)

    -- Fast path: plain component.
    if component.relationshipType == nil then
        if st == 0 then
            local s = (self.allocator.slots as {integer: EntitySlot})[slot]
            local archetype = self.archetypeIndex[s.archetypeId]
            if archetype then
                if archetype ~= self.lastArch then
                    self.lastArch = archetype
                end

                if archetype.columns[component] == nil then
                    return  -- component not present
                end

                local newArch = (archetype.removeEdges as {Component: Archetype})[component]
                if newArch == nil then
                    newArch = archetype:withoutComponent(component, self.archetypeIndex)
                end
                if newArch == archetype then
                    return
                end

                newArch.pendingWrites = newArch.pendingWrites + 1
                markDirty!(archetype, hasPendingMoveOut)
                setEntityState(self, slot, STATE_MUTATE)
                self.entityStateCount = self.entityStateCount + 1
                setPendingArch(self, slot, newArch)
                self.isDirty = true
                return
            end
        elseif st ~= STATE_DESPAWN then
            local pendingArch = getPendingArch(self, slot)
            if pendingArch then
                if pendingArch.columns[component] == nil then
                    return
                end
                local newArch = (pendingArch.removeEdges as {Component: Archetype})[component]
                if newArch == nil then
                    newArch = pendingArch:withoutComponent(component, self.archetypeIndex)
                end
                if newArch ~= pendingArch then
                    if st == STATE_SPAWN then
                        local c = newArch.pendingSpawnCount + 1
                        newArch.pendingSpawnCount = c
                        (newArch.pendingSpawnIds as {integer})[c] = id
                        markDirty!(newArch, hasPendingSpawns)
                        migratePending(pendingArch, newArch, slot)
                    end
                    pendingArch.pendingWrites = pendingArch.pendingWrites - 1
                    newArch.pendingWrites = newArch.pendingWrites + 1
                end
                setPendingArch(self, slot, newArch)
                self.isDirty = true
                return
            end
        end
    end

    if st == STATE_DESPAWN then return end

    -- Sparse routing migrated to `deferRemove` hook (Phase 1). Path is
    -- reached only for components without the hook — no sparse work here.

    local hadPendingArch = getPendingArch(self, slot) ~= nil
    local prevArch: Archetype = getPendingArch(self, slot)
    if not prevArch then
        local s = (self.allocator.slots as {integer: EntitySlot})[slot]
        if st == STATE_SPAWN then
            prevArch = self.emptyArchetype
        else
            prevArch = self.archetypeIndex[s.archetypeId]
        end
    end

    if prevArch.columns[component] == nil then
        return
    end

    -- Reverse-index unlink migrated to `deferRemove` hook (Phase 3).
    -- Hook reads old value BEFORE invoking deferRemoveRaw so the unlink
    -- sees the correct target.

    local newArch = prevArch:withoutComponent(component, self.archetypeIndex)
    if newArch ~= prevArch then
        if st == STATE_SPAWN then
            local c = newArch.pendingSpawnCount + 1
            newArch.pendingSpawnCount = c
            (newArch.pendingSpawnIds as {integer})[c] = id
            markDirty!(newArch, hasPendingSpawns)
            migratePending(prevArch, newArch, slot)
        else
            local s = (self.allocator.slots as {integer: EntitySlot})[slot]
            local srcArch = self.archetypeIndex[s.archetypeId]
            markDirty!(srcArch, hasPendingMoveOut)
        end
        if hadPendingArch then
            prevArch.pendingWrites = prevArch.pendingWrites - 1
        end
        newArch.pendingWrites = newArch.pendingWrites + 1
    end
    setPendingArch(self, slot, newArch)
    if st == 0 then
        setEntityState(self, slot, STATE_MUTATE)
        self.entityStateCount = self.entityStateCount + 1
    end
    self.isDirty = true
end

function WorldImpl:_deferDespawn(id: integer)
    local slot = IdAllocator.slotOf(id)
    local st <const> = getEntityState(self, slot)
    if st == STATE_DESPAWN then
        return -- don't double-despawn
    end

    local world = self
    local s = (self.allocator.slots as {integer: EntitySlot})[slot]
    local sourceArch = self.archetypeIndex[s.archetypeId]
    local pendingArch = getPendingArch(self, slot)

    -- Emit OnDespawn only when observers exist.
    local hasGlobalObs <const> = world:hasObservers(0, OnDespawn)
    local hasObs <const> = world:hasObservers(id, OnDespawn)

    local sourceRow = sourceArch and s.row or 0

    local logicalArch: Archetype = nil
    if pendingArch then
        logicalArch = pendingArch
    elseif sourceArch then
        logicalArch = sourceArch
    end

    local relationshipStores = world.relationshipStores

    -- Fire per-component `onDespawn` hooks. Precomputed fanout list is
    -- empty for archetypes whose components have no hooks — zero cost
    -- in the common case. INVARIANT: row is still readable here, before
    -- any teardown below. Hooks read old column values for side effects
    -- (e.g. dense relationship reverse-index unlink).
    if logicalArch and logicalArch.onDespawnCount > 0 then
        local list = logicalArch.onDespawnComponents
        for i = 1, logicalArch.onDespawnCount do
            local comp = list[i] as ComponentInternal
            comp.onDespawn(world, id, comp, logicalArch, sourceRow)
        end
    end

    -- Cascade delete + cleanup of relationships targeting this entity.
    for container, store in pairs(relationshipStores) do
        local contRel = container as ComponentInternal
        if contRel.cascadeDelete then
            local sources = store:removeTarget(id)
            for sourceId in pairs(sources) do
                local sourceSlot = IdAllocator.slotOf(sourceId)
                if getEntityState(self, sourceSlot) ~= STATE_DESPAWN then
                    self:_deferDespawn(sourceId)
                end
            end
        elseif not contRel.isSparse then
            local sources = store:removeTarget(id)
            local instance = (container as function(integer): any)(id) as Component
            for sourceId in pairs(sources) do
                local sourceSlot = IdAllocator.slotOf(sourceId)
                if getEntityState(self, sourceSlot) ~= STATE_DESPAWN then
                    self:_deferRemove(sourceId, instance)
                end
            end
        end
        store:remove(id)
    end

    -- Emit OnDespawn and clear per-entity observers.
    if hasGlobalObs or hasObs then
        if hasObs then world:emit(id, OnDespawn, id) end
        if hasGlobalObs then world:emit(0, OnDespawn, id) end
        world:clearObservers(id)
    end

    -- Physical row removal is deferred to `drainPendingDespawns`.
    if pendingArch then
        pendingArch.pendingWrites = pendingArch.pendingWrites - 1
    end
    if sourceArch then
        local c = sourceArch.pendingDespawnCount + 1
        sourceArch.pendingDespawnCount = c
        sourceArch.pendingDespawn[c] = sourceRow + 1
        markDirty!(sourceArch, hasPendingDespawns)
    end

    if st == 0 then self.entityStateCount = self.entityStateCount + 1 end
    setEntityState(self, slot, STATE_DESPAWN)
    self.isDirty = true
end

return {}
