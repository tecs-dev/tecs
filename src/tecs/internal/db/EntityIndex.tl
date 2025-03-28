--[[
    EntityIndex.tl - Efficient entity index using packed values

    This module provides a hashtable-based entity index that maps entity IDs
    to packed archetype ID and row values. Uses Lua's safe integer range
    (up to 2^53) to avoid floating point precision issues.

    WARNING: This is an internal module and should not be required directly.
]]

local floor <const> = math.floor

local ROW_DIVISOR <const> = 0x4000000 -- 1 << 26 = 2^26

local record EntityIndex
    --- Get an archetype ID and row from the index.
    --- @param id The entity ID
    --- @return The archetype ID and row, or nil if not found
    get: function(self: EntityIndex, id: integer): integer, integer

    --- Set an archetype ID and row in the index.
    --- @param id The entity ID
    --- @param archetypeId The archetype ID to store (max 134M)
    --- @param row The row to store (max 67M)
    set: function(self: EntityIndex, id: integer, archetypeId: integer, row: integer)

    --- Delete an entity from the index.
    --- @param id The entity ID to delete
    delete: function(self: EntityIndex, id: integer)

    --- Clear all entries from the index.
    clear: function(self: EntityIndex)

    --- Creates a new entity index.
    --- @return A new empty entity index
    new: function(): EntityIndex

    _packed: {integer: number} -- id -> packed(archetype_id, row)
end

function EntityIndex:get(id: integer): integer, integer
    local packed = self._packed[id as integer]
    if not packed then
        return nil, nil
    end

    -- Extract row (lower 26 bits) and archetype ID (upper 27 bits)
    local row = packed % ROW_DIVISOR
    local archetypeinteger = floor(packed / ROW_DIVISOR)
    return archetypeinteger, row as integer
end

function EntityIndex:set(id: integer, archetypeinteger: integer, row: integer)
    -- Pack as: archetypeinteger * 2^26 + row
    self._packed[id as integer] = archetypeinteger * ROW_DIVISOR + row
end

function EntityIndex:delete(id: integer)
    self._packed[id as integer] = nil
end

function EntityIndex:clear()
    self._packed = {}
end

function EntityIndex.new(): EntityIndex
    return {
        _packed = {},
        get = EntityIndex.get,
        set = EntityIndex.set,
        delete = EntityIndex.delete,
        clear = EntityIndex.clear,
        new = EntityIndex.new,
    }
end

return EntityIndex