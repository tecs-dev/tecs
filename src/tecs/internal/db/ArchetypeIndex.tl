--[[
    ArchetypeIndex.tl - Archetype storage and lookup management

    This module provides efficient storage and retrieval of archetypes within the ECS.
    - archetype lookup by component combination using hash-based indexing
    - query matching for finding archetypes with specific components
    - Component-to-archetype reverse indexing for relationship tracking
    - Automatic archetype creation when new component combinations are encountered
    - Support for include/exclude component queries

    WARNING: This is an internal module and should not be required directly.
]]

local Archetype <const> = require("tecs.internal.Archetype")
local types <const> = require("tecs.types")
local pool <const> = require("tecs.internal.utils.pool")
local compat <const> = require("tecs.internal.utils.compat")

local bxor, band <const> = compat.bxor, compat.band

local type Component = types.Component

local record ArchetypeIndex is {Archetype}
    --- An index of components to a set of archetypes that have the component.
    componentIndex: {Component: {Archetype: boolean}}

    --- Hashed components to archetypes that match the hash.
    componentHashMap: {integer: {Archetype}}

    --- Creates a new ArchetypeIndex.
    new: function(): ArchetypeIndex

    --- Gets or creates an archetype with the given components.
    getOrCreate: function(self, components: {Component}, onCreate?: function(Archetype)): Archetype

    --- Finds all archetypes that match the given include and exclude components.
    findMatching: function(self, include: {Component}, exclude: {Component}): {Archetype}

    --- Gets all archetypes that contain a specific component.
    getArchetypesWithComponent: function(self, component: Component): {Archetype: boolean}

    --- Finds an archetype that exactly matches the given components.
    findExact: function(self, components: {Component}): Archetype

    --- Gets the next archetype ID for a new archetype.
    _getNextId: function(self): integer

    --- Registers an archetype in the index.
    _registerArchetype: function(self, archetype: Archetype, components: {Component})
end

local ARCHETYPE_INDEX_MT <const>: metatable<ArchetypeIndex> = {
    __index = ArchetypeIndex
}

function ArchetypeIndex.new(): ArchetypeIndex
    return setmetatable({
        componentIndex = {},
        componentHashMap = {},
    }, ARCHETYPE_INDEX_MT)
end

--- Order-independent hash for a set of components.
---
--- Uses two very cheap accumulators:
--- - `h1` is a Zobrist-style XOR of all component hashes (order-independent).
--- - `h2` is the 32-bit sum of all component hashes (also order-independent).
---
--- Combining them (`bxor(h1, h2)`) reduces collisions compared to plain XOR.
local function hashComponents(components: {Component}): integer
    local h1, h2 = 0, 0
    for i = 1, #components do
        local k = components[i].componentHash
        h1 = bxor(h1, k)
        -- 32-bit additive accumulator
        h2 = (h2 + k) % 0x100000000
    end
    -- fold to a single 32-bit hash
    return band(bxor(h1, h2), 0xFFFFFFFF)
end

function ArchetypeIndex:getOrCreate(components: {Component}, onCreate?: function(Archetype)): Archetype
    local hash = hashComponents(components)
    local bucket = self.componentHashMap[hash]

    if bucket then
        for i = 1, #bucket do
            local archetype = bucket[i]
            if archetype:isExactMatch(components) then
                return archetype
            end
        end
    else
        bucket = {}
        self.componentHashMap[hash] = bucket
    end

    -- Create a new archetype if one doesn't exist and add it to the bucket.
    local archetype = Archetype.new(components, hash)
    archetype.id = #self + 1  -- ID equals the next array index
    self[#self + 1] = archetype  -- Append to maintain dense array
    bucket[#bucket + 1] = archetype

    -- Add this archetype to the component index.
    for i = 1, #components do
        local component = components[i]
        local archetypesWithComponent = self.componentIndex[component]
        if not archetypesWithComponent then
            archetypesWithComponent = {}
            self.componentIndex[component] = archetypesWithComponent
        end
        archetypesWithComponent[archetype] = true
    end

    -- Notify callback if provided
    if onCreate then
        onCreate(archetype)
    end

    return archetype
end

function ArchetypeIndex:findMatching(include: {Component}, exclude: {Component}): {Archetype}
    local result: {Archetype} = {}
    include = include or pool.EMPTY as {Component}
    exclude = exclude or pool.EMPTY as {Component}

    if #include == 0 then
        for i = 1, #self do
            result[i] = self[i]
        end
    else
        local firstComponent = include[1]
        local archetypesWithFirst = self.componentIndex[firstComponent]
        if not archetypesWithFirst then
            return result
        end

        -- Initialize candidates with these archetypes.
        for archetype, _ in pairs(archetypesWithFirst) do
            result[#result + 1] = archetype
        end

        -- Remove archetypes that lack a required component.
        for i = 2, #include do
            local component = include[i]
            local j = 1
            while j <= #result do
                local archetype = result[j]
                if not archetype.columns[component] then
                    -- Move the last element to this position and remove the last element
                    result[j] = result[#result]
                    result[#result] = nil
                    -- Don't increment j so we check the newly swapped element
                else
                    -- Only increment if we didn't remove
                    j = j + 1
                end
            end
            -- Early termination if no candidates left
            if #result == 0 then
                return result
            end
        end
    end

    -- Remove archetypes that have an excluded component.
    if #exclude > 0 then
        local j = 1
        while j <= #result do
            local archetype = result[j]
            if archetype:hasAnyOf(exclude) then
                -- Move the last element to this position and remove the last element
                result[j] = result[#result]
                result[#result] = nil
                -- Don't increment j so we check the newly swapped element
            else
                -- Only increment if we didn't remove
                j = j + 1
            end
        end
    end

    return result
end

function ArchetypeIndex:getArchetypesWithComponent(component: Component): {Archetype: boolean}
    return self.componentIndex[component]
end

-- Find an archetype that exactly matches the given components
function ArchetypeIndex:findExact(components: {Component}): Archetype
    local hash = hashComponents(components)
    local bucket = self.componentHashMap[hash]

    if bucket then
        for i = 1, #bucket do
            local archetype = bucket[i]
            if archetype:isExactMatch(components) then
                return archetype
            end
        end
    end

    return nil as Archetype  -- Not found
end

-- Get the next archetype ID
function ArchetypeIndex:_getNextId(): integer
    return #self + 1
end

-- Register a new archetype in the index
function ArchetypeIndex:_registerArchetype(archetype: Archetype, components: {Component})
    -- Add to main array
    self[#self + 1] = archetype

    -- Add to hash bucket
    local hash = archetype.componentHash
    local bucket = self.componentHashMap[hash]
    if not bucket then
        bucket = {}
        self.componentHashMap[hash] = bucket
    end
    bucket[#bucket + 1] = archetype

    -- Add to component index
    for i = 1, #components do
        local component = components[i]
        local archetypesWithComponent = self.componentIndex[component]
        if not archetypesWithComponent then
            archetypesWithComponent = {}
            self.componentIndex[component] = archetypesWithComponent
        end
        archetypesWithComponent[archetype] = true
    end
end

return ArchetypeIndex