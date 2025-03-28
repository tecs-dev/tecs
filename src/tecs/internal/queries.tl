local types <const> = require("tecs.types")

local table_insert, table_concat <const> = table.insert, table.concat

local type ArchetypeChangeObserver = types.ArchetypeChangeObserver
local type QueryDescriptor = types.QueryDescriptor
local type Query = types.Query
local type Archetype = types.Archetype

local record queries
    --- Create a new query from a query descriptor and matching archetypes.
    ---
    --- @param descriptor The query descriptor used to create the query.
    --- @param matchingArchetype The archetypes that match the query.
    --- @return the created query.
    new: function(descriptor: QueryDescriptor, matchingArchetypes: {Archetype}): Query
end

-------------------------------------------------------------------------------
-- Query Implementation
-------------------------------------------------------------------------------

local record QueryImpl is Query, ArchetypeChangeObserver
    --- The query descriptor used to create the query.
    descriptor: QueryDescriptor

    --- The archetypes that match the query (internal storage).
    _archetypes: {Archetype}

    --- Private method to check if an archetype is in this query.
    _hasArchetype: function(self, archetype: Archetype): boolean
end

local QUERY_MT <const>: metatable<QueryImpl> = {
    __index = QueryImpl,
}

--- Makes the toString of a query
local function formatQuery(query: QueryImpl): string
    local result = query.descriptor.name or "Query"

    local includeNames = {}
    for i = 1, #query.descriptor.include do
        table_insert(includeNames, tostring(query.descriptor.include[i]))
    end

    local excludeNames = {}
    local exclude = query.descriptor.exclude
    if exclude then
        for i = 1, #exclude do
            table_insert(excludeNames, tostring(exclude[i]))
        end
    end

    local parts = {}
    if #includeNames > 0 then
        table_insert(parts, "include: " .. table_concat(includeNames, ", "))
    end
    if #excludeNames > 0 then
        table_insert(parts, "exclude: " .. table_concat(excludeNames, ", "))
    end

    if #parts > 0 then
        result = result .. " {" .. table_concat(parts, ", ") .. "}"
    end

    result = result .. " [" .. #query._archetypes .. " archetypes]"

    return result
end

QUERY_MT.__tostring = formatQuery

QUERY_MT.__call = function(self: QueryImpl): function(): (Archetype, integer, any)
    local archetypes = self._archetypes
    local index = 0
    local count = #archetypes

    return function(): (Archetype, integer, any)
        while index < count do
            index = index + 1
            local archetype = archetypes[index]
            local entities = archetype.entities
            local len = archetype.entities[0]
            if len > 0 then
                return archetype, len, entities
            end
        end
    end
end

function queries.new(descriptor: QueryDescriptor, matchingArchetypes: {Archetype}): Query
    local newQuery: QueryImpl = setmetatable({
        descriptor = descriptor,
        _archetypes = matchingArchetypes,
    }, QUERY_MT)

    -- Call onMatch for all existing entities in matching archetypes
    if descriptor.onMatch then
        for i = 1, #matchingArchetypes do
            local archetype = matchingArchetypes[i]
            local entities = archetype.entities as {integer}
            for j = 1, archetype.entities[0] do
                descriptor.onMatch(entities[j], archetype, j)
            end
        end
    end

    return newQuery
end

function QueryImpl:onNewArchetype(archetype: Archetype)
    -- Check if archetype matches this query
    local include = self.descriptor.include
    local exclude = self.descriptor.exclude

    if include then
        for i = 1, #include do
            local comp = include[i]
            if not archetype.columns[comp] then
                return
            end
        end
    end

    if exclude then
        for i = 1, #exclude do
            if archetype.columns[exclude[i]] then
                return
            end
        end
    end

    table_insert(self._archetypes, archetype)

    -- Call onMatch for all existing entities in this archetype
    local onMatch = self.descriptor.onMatch
    if onMatch and archetype.entities[0] > 0 then
        local entities = archetype.entities as {integer}
        for i = 1, archetype.entities[0] do
            onMatch(entities[i], archetype, i)
        end
    end
end

-- Legacy method names for backward compatibility (if needed)
function QueryImpl:onArchetypeAdded(archetype: Archetype)
    self:onNewArchetype(archetype)
end

function QueryImpl:onEntityChange(
    entityinteger: integer,
    fromArchetype: Archetype,
    toArchetype: Archetype,
    entityPosition: integer
)
    local hadEntity = fromArchetype and self:_hasArchetype(fromArchetype)
    local hasEntity = toArchetype and self:_hasArchetype(toArchetype)

    if not hadEntity and hasEntity then
        -- Entity now matches query
        if self.descriptor.onMatch then
            self.descriptor.onMatch(entityinteger, toArchetype, entityPosition)
        end
    elseif hadEntity and not hasEntity then
        -- Entity no longer matches query (despawned or components changed)
        if self.descriptor.onRemove then
            -- For onRemove we need the old position, but we only have the new position
            -- This is a limitation of the current API
            self.descriptor.onRemove(entityinteger, fromArchetype, entityPosition)
        end
    end
end

function QueryImpl:onEntityMoved(
    entityinteger: integer,
    fromArchetype: Archetype,
    fromRow: integer,
    toArchetype: Archetype,
    toRow: integer
)
    if self.descriptor.onMatch and not self:_hasArchetype(fromArchetype) and self:_hasArchetype(toArchetype) then
        self.descriptor.onMatch(entityinteger, toArchetype, toRow)
    elseif self.descriptor.onRemove and self:_hasArchetype(fromArchetype) and not self:_hasArchetype(toArchetype) then
        self.descriptor.onRemove(entityinteger, fromArchetype, fromRow)
    end
end

function QueryImpl:onEntityRemoved(entityinteger: integer, archetype: Archetype, row: integer)
    if self.descriptor.onRemove and self:_hasArchetype(archetype) then
        self.descriptor.onRemove(entityinteger, archetype, row)
    end
end

function QueryImpl:_hasArchetype(archetype: Archetype): boolean
    for i = 1, #self._archetypes do
        if self._archetypes[i] == archetype then
            return true
        end
    end
    return false
end

return queries