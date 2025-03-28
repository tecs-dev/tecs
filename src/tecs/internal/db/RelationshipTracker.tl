--[[
    RelationshipTracker.tl - Entity relationship dependency tracking

    This module manages the complex web of relationships between entities in the ECS.
    It tracks both forward and reverse relationship edges, enabling efficient cleanup
    when entities are despawned and ensuring referential integrity throughout the
    system.

    WARNING: This is an internal module and should not be required directly.
]]

local types <const> = require("tecs.types")
local compat <const> = require("tecs.internal.utils.compat")
local table_clear <const> = compat.clear

local type Relationship = types.Relationship

local record RelationshipTracker
    --- An index of entity IDs to reverse edges that reference it.
    ---
    --- {
    ---     [Targetinteger] = {
    ---         [Relationship(target)] = {
    ---             [Source] = true
    ---         }
    ---     }
    --- }
    ---
    --- This index is used to clean up references to entities that are being despawned.
    reverseIndex: {integer: {Relationship: {integer: boolean}}}

    --- Creates a new RelationshipTracker.
    new: function(): RelationshipTracker

    --- Adds a relationship from source to target.
    add: function(self, source: integer, rel: Relationship)

    --- Removes a relationship from source to target.
    remove: function(self, source: integer, rel: Relationship)

    --- Gets all reverse dependencies for an entity (relationships that target it).
    getReverseDependencies: function(self, id: integer): {Relationship: {integer: boolean}}

    --- Cleans up all relationship data for an entity being despawned.
    --- Returns a map of entities to relationships that need to be removed.
    cleanupEntity: function(self, id: integer): {integer: Relationship}
end

local RELATIONSHIP_TRACKER_MT <const>: metatable<RelationshipTracker> = {
    __index = RelationshipTracker
}

function RelationshipTracker.new(): RelationshipTracker
    return setmetatable({
        reverseIndex = {}
    }, RELATIONSHIP_TRACKER_MT)
end

function RelationshipTracker:add(source: integer, rel: Relationship)
    -- Update the reverse index.
    local target <const> = rel.target
    local reverseIndex = self.reverseIndex[target]
    if not reverseIndex then
        reverseIndex = {}
        self.reverseIndex[target] = reverseIndex
    end
    local relIndex = reverseIndex[rel]
    if not relIndex then
        relIndex = {}
        reverseIndex[rel] = relIndex
    end
    relIndex[source] = true
end

function RelationshipTracker:remove(source: integer, rel: Relationship)
    -- Update the reverse index.
    local target <const> = rel.target
    local reverseIndex = self.reverseIndex[target]
    if reverseIndex then
        local relIndex = reverseIndex[rel]
        if relIndex then
            relIndex[source] = nil
            if not next(relIndex) then
                reverseIndex[rel] = nil
                if not next(reverseIndex) then
                    self.reverseIndex[target] = nil
                end
            end
        end
    end
end

function RelationshipTracker:getReverseDependencies(id: integer): {Relationship: {integer: boolean}}
    return self.reverseIndex[id]
end

function RelationshipTracker:cleanupEntity(id: integer): {integer: Relationship}
    local toRemove: {integer: Relationship} = {}
    local reverseEdges = self.reverseIndex[id]
    if reverseEdges then
        -- Collect all relationships that need to be removed
        for rel, sources in pairs(reverseEdges) do
            for source in pairs(sources) do
                -- Record that we need to remove this relationship from the source entity
                toRemove[source] = rel
            end
        end
        table_clear(reverseEdges as {any})
    end
    return toRemove
end

return RelationshipTracker