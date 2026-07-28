-- Archetype lookup, reverse indexing, and query matching.

local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")
local ArchetypeImpl <const> = require("tecs.internal.Archetype")
local Bitset <const> = require("tecs.utils.Bitset")

-- Store the concrete Archetype record directly so internal callers do not
-- need to cast through the public interface at every access site.
local type Archetype = internal.ArchetypeInternal
local type Component = types.components.Component
local type CompiledQueryMasks = internal.CompiledQueryMasks

local COMPARE_BY_ID <const> = function(a: Component, b: Component): boolean return a.componentId < b.componentId end

local record ArchetypeIndex is internal.ArchetypeIndexInternal
    componentIndex: {Component: {Archetype: boolean}}
    dirtySet: {Archetype: boolean}
    emptyArchetype: Archetype
    relationshipStoreGetter: function(Component): any
    onNewArchetype: function(Archetype)
    maxId: integer

    freeIds: {integer}
    freeIdCount: integer

    new: function(dirtySet?: {Archetype: boolean}): ArchetypeIndex
    getOrCreate: function(self, components: {Component}): Archetype
    findMatching: function(self, include: {Component}, masks: CompiledQueryMasks): {Archetype}
    getArchetypesWithComponent: function(self, component: Component): {Archetype: boolean} | nil
    destroy: function(self, archetype: Archetype)
end

local ARCHETYPE_INDEX_MT <const>: metatable<ArchetypeIndex> = {__index = ArchetypeIndex}

function ArchetypeIndex.new(dirtySet?: {Archetype: boolean}): ArchetypeIndex
    local self: ArchetypeIndex = setmetatable({
        componentIndex = {},
        dirtySet = dirtySet,
        relationshipStoreGetter = nil,
        onNewArchetype = nil,
        emptyArchetype = nil as Archetype,
        maxId = 0,
        freeIds = {},
        freeIdCount = 0,
    }, ARCHETYPE_INDEX_MT)

    -- Eagerly create the empty archetype.
    do
        local empty = ArchetypeImpl.new({}, self.dirtySet, self.relationshipStoreGetter)
        self.maxId = 1
        empty.id = 1
        self[1] = empty
        self.emptyArchetype = empty
    end

    return self
end

local function acquireId(self: ArchetypeIndex): integer
    local fc = self.freeIdCount
    if fc > 0 then
        local id = self.freeIds[fc]
        self.freeIds[fc] = nil
        self.freeIdCount = fc - 1
        return id
    end
    local id = self.maxId + 1
    self.maxId = id
    return id
end

local function setSize(set: {Archetype: boolean}): integer
    local n = 0
    for _ in pairs(set) do
        n = n + 1
    end
    return n
end

local function matchesQuerySignatures(
    archetype: Archetype,
    includeBits: Bitset,
    includeWordBits: Bitset,
    includeAnyBits: Bitset,
    includeAnyWordBits: Bitset,
    excludeBits: Bitset,
    excludeWordBits: Bitset
): boolean
    local signatureWordBits = archetype.signatureWordBits
    local signatureBits = archetype.signatureBits
    if not signatureWordBits:containsAll(includeWordBits) then
        return false
    end
    if not includeBits:isEmpty() and not signatureBits:containsAll(includeBits) then
        return false
    end
    if not includeAnyWordBits:isEmpty() and signatureWordBits:disjoint(includeAnyWordBits) then
        return false
    end
    if not includeAnyBits:isEmpty() and signatureBits:disjoint(includeAnyBits) then
        return false
    end
    if
        not excludeWordBits:isEmpty()
        and not signatureWordBits:disjoint(excludeWordBits)
        and not excludeBits:isEmpty()
        and signatureBits:overlaps(excludeBits)
    then
        return false
    end
    return true
end

local function filterMatchingBySignatures(
    result: {Archetype},
    count: integer,
    includeBits: Bitset,
    includeWordBits: Bitset,
    includeAnyBits: Bitset,
    includeAnyWordBits: Bitset,
    excludeBits: Bitset,
    excludeWordBits: Bitset
): integer
    local j = 1
    while j <= count do
        if not matchesQuerySignatures(
            result[j], includeBits, includeWordBits, includeAnyBits, includeAnyWordBits, excludeBits, excludeWordBits
        ) then
            result[j] = result[count]
            result[count] = nil
            count = count - 1
        else
            j = j + 1
        end
    end
    return count
end

function ArchetypeIndex:getOrCreate(components: {Component}): Archetype
    local n = #components
    if n == 0 then
        return self.emptyArchetype
    end

    table.sort(components, COMPARE_BY_ID)

    local compIndex = self.componentIndex
    local notify = self.onNewArchetype
    local dirtySet = self.dirtySet
    local relationshipStoreGetter = self.relationshipStoreGetter

    local target = self.emptyArchetype
    local prefix: {Component} = {}

    for i = 1, n do
        local c = components[i]
        prefix[i] = c

        local edgeTarget = target.addEdges[c] as Archetype
        if not edgeTarget then
            edgeTarget = ArchetypeImpl.new(prefix, dirtySet, relationshipStoreGetter)
            local nextId = acquireId(self)
            edgeTarget.id = nextId
            self[nextId] = edgeTarget

            for k = 1, i do
                local comp = prefix[k]
                local set = compIndex[comp]
                if not set then
                    set = {}
                    compIndex[comp] = set
                end
                set[edgeTarget] = true
            end

            target.addEdges[c] = edgeTarget
            edgeTarget.removeEdges[c] = target

            if notify then
                notify(edgeTarget)
            end
        end
        target = edgeTarget
    end

    return target
end

function ArchetypeIndex:findMatching(include: {Component}, masks: CompiledQueryMasks): {Archetype}
    local result: {Archetype} = {}
    local includeBits = masks.includeBits
    local includeWordBits = masks.includeWordBits
    local includeAnyBits = masks.includeAnyBits
    local includeAnyWordBits = masks.includeAnyWordBits
    local excludeBits = masks.excludeBits
    local excludeWordBits = masks.excludeWordBits
    local includeCount = include == nil and 0 or #include

    if includeCount == 0 then
        local n = 0
        for i = 1, self.maxId do
            local arch = self[i]
            if arch then
                n = n + 1
                result[n] = arch
            end
        end
    else
        local seedComponent = include[1]
        local seedArchetypes = self.componentIndex[seedComponent]
        if not seedArchetypes then
            return result
        end
        local seedCount = setSize(seedArchetypes)

        for i = 2, includeCount do
            local component = include[i]
            local archetypes = self.componentIndex[component]
            if not archetypes then
                return result
            end
            local arcSize = setSize(archetypes)
            if arcSize < seedCount then
                seedComponent = component
                seedArchetypes = archetypes
                seedCount = arcSize
            end
        end

        local n = 0
        for archetype in pairs(seedArchetypes) do
            n = n + 1
            result[n] = archetype
        end

        n = filterMatchingBySignatures(
            result, n, includeBits, includeWordBits, includeAnyBits, includeAnyWordBits, excludeBits, excludeWordBits
        )
        if n == 0 then
            return result
        end
    end

    local n = #result
    n = filterMatchingBySignatures(
        result, n, includeBits, includeWordBits, includeAnyBits, includeAnyWordBits, excludeBits, excludeWordBits
    )

    return result
end

function ArchetypeIndex:getArchetypesWithComponent(component: Component): {Archetype: boolean} | nil
    return self.componentIndex[component]
end

--- Destroy an empty archetype, remove it from all indexes, and recycle its id.
function ArchetypeIndex:destroy(archetype: Archetype)
    archetype:notifyArchetypeDestroyed()

    for c, neighbor in pairs(archetype.addEdges) do
        neighbor.removeEdges[c] = nil
    end
    for c, neighbor in pairs(archetype.removeEdges) do
        neighbor.addEdges[c] = nil
    end

    local compIndex = self.componentIndex
    for i = 1, archetype.columnsCount do
        local comp = archetype.componentList[i]
        local set = compIndex[comp]
        if set then
            set[archetype] = nil
            if next(set) == nil then
                compIndex[comp] = nil
            end
        end
    end

    local destroyedId = archetype.id
    self[destroyedId] = nil
    local fc = self.freeIdCount + 1
    self.freeIds[fc] = destroyedId
    self.freeIdCount = fc

    local dirtySet = self.dirtySet
    if dirtySet then
        dirtySet[archetype] = nil
    end

    -- Raw table access bypasses Teal's strict nil-field checks.
    local t = archetype as {string: any}
    t.columns = nil
    t.columnArray = nil
    t.componentList = nil
    t.signatureBits = nil
    t.signatureWordBits = nil
    t.movePlansOut = nil
    t.addEdges = nil
    t.removeEdges = nil
    t._observers = nil
    t.pendingSpawnIds = nil
    t.pendingValues = nil
    t.pendingScalarTypes = nil
    t.pendingScalarValues = nil
    t.pendingDespawn = nil
    t.pendingBundleDrains = nil
    t.batchSpawnQueue = nil
    t.batchSpawnAtQueue = nil
    t._componentDirty = nil
    t.entities = nil
    archetype.id = 0
end

return ArchetypeIndex
