local types <const> = require("tecs.types")
local compat <const> = require("tecs.internal.utils.compat")
local pool <const> = require("tecs.internal.utils.pool")
local ffi <const> = require("tecs.internal.ffi")

local table_new <const> = compat.new

local table_insert, table_concat <const> = table.insert, table.concat
local rawget, next, pairs <const> = rawget, next, pairs

local type Component = types.Component
local type Relationship = types.Relationship

-- The auto-incrementing ID for archetypes.
local AUTO_ID = 0

local record Archetype is types.Archetype end

local ARCHETYPE_MT <const>: metatable<Archetype> = {
    __index = Archetype as (function<C is Component>(self: Archetype, component: C): {C}),
    __tostring = function(self: Archetype): string
        local buf: {string} = pool.acquireArray()
        table_insert(buf, "Archetype([")
        local i = 0
        for c, _ in pairs(self.columns) do
            if i > 0 then
                table_insert(buf, ", ")
            end
            table_insert(buf, tostring(c))
            i = i + 1
        end
        table_insert(buf, "])")
        local result = table_concat(buf)
        pool.releaseArray(buf)
        return result
    end
}

function Archetype:get<T is Component>(component: T, row: integer): T
    local column = rawget(self.columns, component)
    return column and column[row] as T
end

function Archetype:isExactMatch(components: {Component}): boolean
    local columnsCount = self.columnsCount
    if columnsCount ~= #components then
        return false
    end

    local columns = self.columns
    for i = 1, columnsCount do
        if not columns[components[i]] then
            return false
        end
    end

    return true
end

function Archetype:hasAnyOf(components: {Component}): boolean
    local columns = self.columns
    for i = 1, #components do
        if columns[components[i]] then
            return true
        end
    end
    return false
end

local EMPTY_ITERATOR <const> = function(): nil
    return nil
end

function Archetype:getRelationships<T is Relationship>(relationshipContainer: T, row: integer): function(): T
    if not self.columns[relationshipContainer] then
        return EMPTY_ITERATOR
    end

    -- Return an iterator over the matching relationships
    local columnKey: Component = nil
    local columnValue: {Component} = nil
    local columns = self.columns
    return function(): T
        while true do
            columnKey, columnValue = next(columns, columnKey)
            if columnKey == nil then
                return nil -- no more columns
            end

            -- Check if this component is a relationship of the same type as the container
            if columnKey is Relationship and columnKey.relationshipType == relationshipContainer then
                -- Don't yield the relationship container itself.
                if columnKey.componentType ~= relationshipContainer then
                    return columnValue[row] as T
                end
            end
        end
    end
end

function Archetype:getFirstRelationship<T is Relationship>(relationshipContainer: T, row: integer): T
    return self:getRelationships(relationshipContainer, row)()
end

--- Creates a new archetype.
---
--- @param components An array of component types that define this archetype.
--- @param componentHash A hash of the components in this archetype.
--- @return A new Archetype instance.
function Archetype.new(components: {Component}, componentHash: integer): Archetype
    AUTO_ID = AUTO_ID + 1
    local columnsCount = #components
    local columns = table_new(0, columnsCount) as {Component:{Component}}

    local self: Archetype = {
        id = AUTO_ID,
        entities = ffi.newInt32(16),
        columns = columns,
        columnsCount = columnsCount,
        componentHash = componentHash
    }

    for i = 1, columnsCount do
        local comp = components[i]
        -- Create a new storage column for this component
        local store = comp:getStorage():new(0)
        -- Store the column in columns, and available directly as a property of the archetype
        columns[comp] = store
        (self as table)[comp] = store
    end

    return setmetatable(self, ARCHETYPE_MT)
end

return Archetype