--- Shared entity introspection for the MCP server and the debugger's inspect
--- command: locate a live entity's archetype row through the allocator, and
--- serialize component rows. Reads only; never mutates world state.

local tecs <const> = require("tecs")
local IdAllocator <const> = require("tecs.internal.IdAllocator")

local record entityinfo
    --- Locate a live entity's archetype and 1-based row.
    --- Returns nil, 0, and "not_alive" or "not_committed" on failure.
    locate: function(w: tecs.World, eid: integer): tecs.Archetype, integer, string

    --- Serialize the serializable components of one archetype row (1-based)
    --- from the given component list. Non-serializable components (tag
    --- components, or components without a serialize callback) are skipped so
    --- they never raise.
    serializeRow: function(archetype: tecs.Archetype, compList: {tecs.Component}, row: integer): {string: any}

    record ComponentSchema
        name: string
        id: integer
        kind: string
        fields: {{string: string}}
        defaults: {string: any}
        serializable: boolean
    end

    --- A component's field names and types (exact C types for FFI components
    --- via the storage fingerprint; Lua types from a default-constructed
    --- instance otherwise), plus default values.
    componentSchema: function(comp: tecs.Component): ComponentSchema
end

function entityinfo.locate(w: tecs.World, eid: integer): tecs.Archetype, integer, string
    if not w:isAlive(eid) then
        return nil, 0, "not_alive"
    end
    local worldAny = w as {string: any}
    local allocator = worldAny.allocator as {string: any}
    local archetypeIndex = worldAny.archetypeIndex as {tecs.Archetype}
    local slot = IdAllocator.slotOf(eid)
    local s = (allocator.slots as {integer: {string: integer}})[slot]
    local archetype = s and archetypeIndex[s.archetypeId]
    if not archetype then
        return nil, 0, "not_committed"
    end
    -- The allocator's row is 0-based; callers index columns 1-based.
    return archetype, s.row + 1, nil
end

function entityinfo.serializeRow(archetype: tecs.Archetype, compList: {tecs.Component}, row: integer): {string: any}
    local components: {string: any} = {}
    for i = 1, #compList do
        local comp = compList[i]
        local compAny = comp as {string: any}
        if comp.componentName and compAny.storageType == "tag" then
            components[comp.componentName] = true
        elseif comp.componentName and comp.serialize then
            local column = archetype:get(comp) as {any}
            local instance = column and column[row]
            if instance ~= nil then
                local serialize = comp.serialize as function(any): {string: any}
                local ok, serialized = pcall(serialize, instance)
                if ok and serialized then
                    components[comp.componentName] = serialized
                end
            end
        end
    end
    return components
end


function entityinfo.componentSchema(comp: tecs.Component): entityinfo.ComponentSchema
    local compAny = comp as {string: any}
    local storage = compAny.storage as {string: any}
    local kind = (compAny.storageType as string)
        or (storage and storage.storageType as string) or "table"

    -- FFI components carry an exact C-typed field list in the storage
    -- fingerprint ("x:float,y:float,...|size").
    local fields: {{string: string}} = {}
    local fingerprint = storage and storage._fingerprint as string
    if fingerprint then
        local list = fingerprint:match("^([^|]*)") or ""
        for pair in list:gmatch("[^,]+") do
            local fname, ftype = pair:match("^(.-):(.*)$")
            if fname then
                fields[#fields + 1] = {name = fname, type = ftype}
            end
        end
    end

    -- Defaults (and Lua-typed fields when no fingerprint exists) come from
    -- serializing a default-constructed instance.
    local defaults: {string: any} = nil
    if comp.serialize then
        local ok, serialized = pcall(function(): {string: any}
            local ctor = comp as function(): any
            local serialize = comp.serialize as function(any): {string: any}
            return serialize(ctor())
        end)
        if ok and serialized then
            defaults = serialized
            if #fields == 0 then
                local names: {string} = {}
                for k in pairs(serialized) do names[#names + 1] = k end
                table.sort(names)
                for i = 1, #names do
                    fields[#fields + 1] = {name = names[i], type = type(serialized[names[i]])}
                end
            end
        end
    end

    return {
        name = comp.componentName,
        id = comp.componentId,
        kind = kind,
        fields = fields,
        defaults = defaults,
        serializable = comp.serialize ~= nil,
    }
end

return entityinfo
