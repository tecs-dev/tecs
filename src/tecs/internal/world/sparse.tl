--[[
Sparse relationship staging + apply.

`setSparseRaw` buffers per-entity values in `sparseSets`; they're flushed
to `relationshipStores` by `commitSparseChanges` at the end of `_drain`.
`removeSparseRaw` / `removeSparseOneRaw` apply directly so store:has is
accurate, and route the wildcard-container cleanup back through
`deferRemoveRaw` on the staging path.

Contract: these are called from sparse relationship defer handlers, so they
carry no `_` prefix.
]]

local table_clear <const> = require("table.clear")
local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")
local IdAllocator <const> = require("tecs.internal.IdAllocator")

local type Component = types.components.Component

local WorldImpl = internal.WorldImpl

function WorldImpl:setSparseRaw(id: integer, value: any)
    local slot = IdAllocator.slotOf(id)
    local sets = self.sparseSets[slot]
    if not sets then
        sets = self._sparseArraysPool:acquire() as {Component}
        self.sparseSets[slot] = sets
        self.sparseSetCount = self.sparseSetCount + 1
    elseif (sets as {any: any}).id ~= id then
        -- The slot was recycled mid-transaction; the previous entity's
        -- staged values die with it.
        table_clear(sets as {any: any})
    end
    -- Stash the packed handle so `commitSparseChanges` can reject entries
    -- whose entity died (generation mismatch) before applying them.
    (sets as {any: any}).id = id
    sets[#sets + 1] = value as Component
    self.isDirty = true
end

function WorldImpl:removeSparseRaw(id: integer, container: Component)
    local slot = IdAllocator.slotOf(id)
    local sets = self.sparseSets[slot]
    if sets then
        local n = #sets
        local w = 0
        for i = 1, n do
            local v = sets[i]
            local rel = v as types.components.Relationship
            if rel.relationshipType ~= container then
                w = w + 1
                if w ~= i then sets[w] = v end
            end
        end
        for i = w + 1, n do
            sets[i] = nil
        end
    end

    local store = self.relationshipStores[container]
    if store then
        store:remove(id)
        -- Use deferRemoveRaw to skip dispatcher recursion; we're already
        -- inside the sparse defer handler.
        self:deferRemoveRaw(id, container)
    end
    self.isDirty = true
end

function WorldImpl:removeSparseOneRaw(id: integer, container: Component, targetId: integer)
    -- Purge matching staged values first: `store:removeOne` cannot see
    -- them, and `commitSparseChanges` would re-apply exactly what this
    -- call removes.
    local slot = IdAllocator.slotOf(id)
    local sets = self.sparseSets[slot]
    local stagedForContainer = false
    if sets then
        local n = #sets
        local w = 0
        for i = 1, n do
            local v = sets[i]
            local rel = v as types.components.Relationship
            if rel.relationshipType ~= container or rel.target ~= targetId then
                if rel.relationshipType == container then
                    stagedForContainer = true
                end
                w = w + 1
                if w ~= i then sets[w] = v end
            end
        end
        for i = w + 1, n do
            sets[i] = nil
        end
    end

    local store = self.relationshipStores[container]
    if store then
        store:removeOne(id, targetId)
        -- Keep the container marker while either the store or the staging
        -- buffer still holds values for this entity.
        if not stagedForContainer and not store:has(id) then
            -- Use deferRemoveRaw to skip dispatcher recursion.
            self:deferRemoveRaw(id, container)
        end
    end
    self.isDirty = true
end

return {}
