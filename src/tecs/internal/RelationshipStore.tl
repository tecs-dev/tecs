--- RelationshipStore: per-world storage for relationship inverse indexes (and
--- optionally forward data for sparse relationships).
---
--- Two implementations behind one interface:
---
---   Sparse -- owns BOTH a forward map (entityId → value) and an inverse index.
---     Used for relationships declared with `sparse = true`. The forward map
---     is the primary storage for the relationship value.
---
---   Dense  -- owns ONLY an inverse index. Forward data lives in archetype
---     columns (one column per (container, target) pair). Used for dense
---     relationships with `reverseIndex = true`. Forward storage methods
---     (get/set/has/etc) are no-ops on this implementation.
---
--- Both implementations satisfy the same `RelationshipStore` record so call
--- sites can dispatch polymorphically. Each implementation uses a single
--- shared metatable so LuaJIT sees a bimorphic call site rather than
--- per-instance metatables.
---
--- Lifecycle: relationship stores live on the World (`world.relationshipStores`)
--- and are created lazily on first use via `world:getRelationshipStore(container)`.
--- This prevents the cross-world state leak that would occur if stores lived on
--- the relationship container itself.

local InverseIndex <const> = require("tecs.internal.InverseIndex")

local record RelationshipStoreConfig
    sparse: boolean
    reverseIndex: boolean
    exclusive: boolean
    onTargetAdded: function(integer)
    onTargetRemoved: function(integer)
end

--- Unified record type for both Sparse and Dense relationship stores. Both
--- implementations satisfy this signature; instances dispatch via shared
--- metatables (`SPARSE_MT` / `DENSE_MT`).
local record RelationshipStore
    --- Create a new RelationshipStore. Returns a Sparse implementation if
    --- config.sparse is true, otherwise a Dense implementation. Returns nil
    --- if neither sparse nor reverseIndex is set (no store needed).
    create: function(config: RelationshipStoreConfig): RelationshipStore

    --- Inverse index operations - both implementations support these.
    --- For dense relationships, link/unlink are called by component-specific
    --- callbacks when entities are added/removed from archetypes containing
    --- the relationship.
    --- For sparse relationships, link/unlink are called internally by set/remove.
    link: function(self, sourceId: integer, targetId: integer)
    unlink: function(self, sourceId: integer, targetId: integer)
    forEachSource: function<T>(self, targetId: integer, callback: function(integer, T), context: T)

    --- Remove all entries that target a given entity. Returns a {[sourceId] = true}
    --- map of source entity IDs that were fully cleared (used for cascade-delete).
    --- Iterate with `for sourceId in pairs(...) do`.
    --- For dense relationships only the inverse index is cleared - despawn
    --- cleanup is responsible for removing the relationship instance
    --- components from each source's archetype.
    removeTarget: function(self, targetId: integer): {integer: boolean}

    --- Forward storage operations - only meaningful on the Sparse implementation.
    --- Dense returns nil/false from these (forward data lives in archetype columns).
    get: function(self, entityId: integer): any
    --- One relationship instance for the entity, or nil. For exclusive
    --- stores this is the value; for non-exclusive stores an arbitrary
    --- entry from the target map (never the map itself).
    getFirst: function(self, entityId: integer): any
    getTarget: function(self, entityId: integer, targetId: integer): any
    set: function(self, entityId: integer, value: any): any
    remove: function(self, entityId: integer): any
    removeOne: function(self, entityId: integer, targetId: integer): any, boolean
    has: function(self, entityId: integer): boolean

    --- Iterate all forward entries. Sparse yields its forward map; Dense yields nothing.
    pairs: function(self): (function(): (integer, any))
end

local EMPTY <const>: {integer: boolean} = {}

-------------------------------------------------------------------------------
-- Sparse implementation: forward map + inverse index
-------------------------------------------------------------------------------

local record SparseImpl
    _forward: {integer: any}
    _inverse: InverseIndex
    _exclusive: boolean
end

function SparseImpl:get(entityId: integer): any
    return self._forward[entityId]
end

function SparseImpl:getFirst(entityId: integer): any
    local val = self._forward[entityId]
    if val == nil or self._exclusive then
        return val
    end
    local _, first = next(val as {integer: any})
    return first
end

function SparseImpl:getTarget(entityId: integer, targetId: integer): any
    if self._exclusive then
        local val = self._forward[entityId]
        if val and (val as {string: integer}).target == targetId then
            return val
        end
        return nil
    else
        local map = self._forward[entityId] as {integer: any}
        return map and map[targetId] or nil
    end
end

function SparseImpl:set(entityId: integer, value: any): any
    local target = (value as {string: integer}).target
    local inverse = self._inverse

    if self._exclusive then
        local oldValue = self._forward[entityId]

        if inverse and oldValue ~= nil then
            local oldTarget = (oldValue as {string: integer}).target
            if oldTarget then
                inverse:unlink(entityId, oldTarget)
            end
        end

        self._forward[entityId] = value

        if inverse and target then
            inverse:link(entityId, target)
        end

        return oldValue
    else
        -- Non-exclusive: {[targetId] = value, ...}
        local map = self._forward[entityId] as {integer: any}
        if not map then
            map = {}
            self._forward[entityId] = map
        end

        local oldValue = map[target]

        -- Only link inverse for new targets (replacing an existing target keeps the same edge)
        if inverse and oldValue == nil and target then
            inverse:link(entityId, target)
        end

        map[target] = value
        return oldValue
    end
end

function SparseImpl:remove(entityId: integer): any
    local oldValue = self._forward[entityId]
    if oldValue == nil then
        return nil
    end
    local inverse = self._inverse

    if inverse then
        if self._exclusive then
            local oldTarget = (oldValue as {string: integer}).target
            if oldTarget then
                inverse:unlink(entityId, oldTarget)
            end
        else
            local map = oldValue as {integer: any}
            for targetId in pairs(map) do
                inverse:unlink(entityId, targetId)
            end
        end
    end

    self._forward[entityId] = nil
    return oldValue
end

function SparseImpl:removeOne(entityId: integer, targetId: integer): any, boolean
    local inverse = self._inverse
    if self._exclusive then
        local val = self._forward[entityId]
        if val and (val as {string: integer}).target == targetId then
            self._forward[entityId] = nil
            if inverse then
                inverse:unlink(entityId, targetId)
            end
            return val, false
        end
        return nil, self._forward[entityId] ~= nil
    else
        local map = self._forward[entityId] as {integer: any}
        if not map then return nil, false end

        local val = map[targetId]
        if val == nil then
            return nil, next(map) ~= nil
        end

        map[targetId] = nil
        if inverse then
            inverse:unlink(entityId, targetId)
        end

        local hasRemaining = next(map) ~= nil
        if not hasRemaining then
            self._forward[entityId] = nil
        end
        return val, hasRemaining
    end
end

function SparseImpl:has(entityId: integer): boolean
    return self._forward[entityId] ~= nil
end

function SparseImpl:pairs(): (function(): (integer, any))
    local k: integer = nil
    local forward = self._forward
    return function(): (integer, any)
        local nextK, nextV = next(forward, k)
        k = nextK
        return nextK, nextV
    end
end

function SparseImpl:link(sourceId: integer, targetId: integer)
    if self._inverse then
        self._inverse:link(sourceId, targetId)
    end
end

function SparseImpl:unlink(sourceId: integer, targetId: integer)
    if self._inverse then
        self._inverse:unlink(sourceId, targetId)
    end
end

function SparseImpl:forEachSource(targetId: integer, callback: function(integer, any), context: any)
    if not self._inverse then return end
    self._inverse:forEachSource(targetId, callback, context)
end

function SparseImpl:removeTarget(targetId: integer): {integer: boolean}
    local inverse = self._inverse
    if not inverse then
        return EMPTY
    end

    local sources = inverse:removeTarget(targetId)
    if next(sources) == nil then
        return EMPTY
    end

    -- Remove this target from each source's forward entries.
    -- Collect sources that are now fully empty (for cascade delete).
    local fullyCleared: {integer: boolean} = {}
    for sourceId in pairs(sources) do
        if self._exclusive then
            self._forward[sourceId] = nil
            fullyCleared[sourceId] = true
        else
            local map = self._forward[sourceId] as {integer: any}
            if map then
                map[targetId] = nil
                if next(map) == nil then
                    self._forward[sourceId] = nil
                    fullyCleared[sourceId] = true
                end
            end
        end
    end

    return fullyCleared
end

local SPARSE_MT <const> = {__index = SparseImpl}

-------------------------------------------------------------------------------
-- Dense implementation: inverse index only (no forward storage)
-------------------------------------------------------------------------------

local record DenseImpl
    _inverse: InverseIndex
end

-- Forward storage methods are no-ops for dense -- forward data lives in archetype columns.
function DenseImpl:get(_entityId: integer): any return nil end
function DenseImpl:getFirst(_entityId: integer): any return nil end
function DenseImpl:getTarget(_entityId: integer, _targetId: integer): any return nil end
function DenseImpl:set(_entityId: integer, _value: any): any return nil end
function DenseImpl:remove(_entityId: integer): any return nil end
function DenseImpl:removeOne(_entityId: integer, _targetId: integer): any, boolean
    return nil, false
end
function DenseImpl:has(_entityId: integer): boolean return false end
function DenseImpl:pairs(): (function(): (integer, any))
    return function(): (integer, any) return nil, nil end
end

-- Inverse index ops delegate directly.
function DenseImpl:link(sourceId: integer, targetId: integer)
    self._inverse:link(sourceId, targetId)
end

function DenseImpl:unlink(sourceId: integer, targetId: integer)
    self._inverse:unlink(sourceId, targetId)
end

function DenseImpl:forEachSource(targetId: integer, callback: function(integer, any), context: any)
    self._inverse:forEachSource(targetId, callback, context)
end

function DenseImpl:removeTarget(targetId: integer): {integer: boolean}
    return self._inverse:removeTarget(targetId)
end

local DENSE_MT <const> = {__index = DenseImpl}

-------------------------------------------------------------------------------
-- Factory
-------------------------------------------------------------------------------

-- Returns a RelationshipStore for the given config, OR nil if no store is
-- needed (a regular dense relationship without reverseIndex stores everything
-- in archetype columns, so there's nothing for a per-world store to track).
-- Named `create` rather than `new` to make the nullable return obvious at the
-- call site.
function RelationshipStore.create(config: RelationshipStoreConfig): RelationshipStore
    if config.sparse then
        local inverse: InverseIndex = nil
        if config.reverseIndex then
            inverse = InverseIndex.new()
            (inverse as {string: any})._onTargetAdded = config.onTargetAdded
            (inverse as {string: any})._onTargetRemoved = config.onTargetRemoved
        end
        local store = {
            _forward = {} as {integer: any},
            _inverse = inverse,
            _exclusive = config.exclusive or false,
        }
        return setmetatable(store as RelationshipStore, SPARSE_MT)
    elseif config.reverseIndex then
        local inverse = InverseIndex.new()
        (inverse as {string: any})._onTargetAdded = config.onTargetAdded
        (inverse as {string: any})._onTargetRemoved = config.onTargetRemoved
        local store = {
            _inverse = inverse,
        }
        return setmetatable(store as RelationshipStore, DENSE_MT)
    end
    return nil
end

return RelationshipStore
