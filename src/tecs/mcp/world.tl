--- Tools that read and write the world.
---
--- These run on the game's own thread, inside the frame, before the world
--- updates. So they read a world that is not mid-update and write one that has
--- not yet been stepped, which is why none of them queue anything and none of
--- them lock.
---
--- Component values cross as plain tables through each component's own
--- `serialize` and the constructor beside it, rather than through a second
--- description of every component maintained here. A component the engine
--- gains is a component these tools gain.
---
--- Which components exist is read the same way, from the ECS's own registry
--- through `ecs.declaredComponents`. That registry is process-wide, so these
--- tools can name anything anybody registered, including a game's own, and
--- nothing has to be told about a component twice.

local cjson <const> = require("cjson")
local ecs <const> = require("tecs.ecs")
local mcp <const> = require("tecs.mcp")

--- Registers the world-facing tools, and names the world they act on.
---
--- Requiring this module registers its tools as a side effect; there is no
--- install step, and the only thing on the surface is `bind`. One world at a
--- time, held in a module-level slot rather than passed per call, because the
--- protocol has nowhere to carry it.
---
--- Every handler here runs on the game thread inside the frame, before the
--- world is stepped, so a write lands before the update that reads it. While
--- the application is suspended nothing is polled, so no tool answers at all.
local record world
    --- Makes `w` the world these tools act on.
    ---
    --- @param w Replaces whatever was bound before. Passing nil unbinds, after
    ---     which every tool that touches the world fails with a message saying
    ---     so; `components_info` still answers, reporting `bound` as false.
    bind: function(w: ecs.World)
end

local bound: ecs.World = nil

function world.bind(w: ecs.World)
    bound = w
end

--- The bound world, or an error naming why there is not one.
local function current(): ecs.World
    if bound == nil then
        error("no world is bound; the application has not started", 0)
    end
    return bound
end

--- The declared components, sorted by name.
local function sortedNames(declared: {string: ecs.Component}): {string}
    local names: {string} = {}
    for name in pairs(declared) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

--- Resolves a component by name, listing what exists when it cannot.
---
--- Registration rather than presence: a component nothing in this world
--- carries is still nameable, because `spawn` and `set` are how it comes to
--- be carried. Only a name nobody registered is refused.
local function component(name: string): ecs.Component
    local found = name ~= nil and ecs.componentByName(name) or nil
    if found == nil then
        local names = sortedNames(ecs.declaredComponents())
        error(("no component named '%s'; known: %s"):format(tostring(name), table.concat(names, ", ")), 0)
    end
    return found
end

--- Resolves a list of component names.
local function componentList(names: {any}): {ecs.Component}
    local list: {ecs.Component} = {}
    if names == nil then
        return list
    end
    for index = 1, #names do
        list[index] = component(names[index] as string)
    end
    return list
end

--- Interface members every component carries, which are not its data. A tag
--- component serializes to nothing but these, so without the filter its
--- storage class and signature index would read as fields it has.
local METADATA <const>: {string: boolean} = {
    componentType = true,
    componentName = true,
    componentId = true,
    relationshipType = true,
    wildcardContainer = true,
    target = true,
    transient = true,
    serialize = true,
    deserialize = true,
    storageType = true,
    signatureIndex = true,
    signatureWordIndex = true,
}

--- The data fields of a serialized component, without its interface members.
local function dataFields(values: {string: any}): {string: any}
    local out: {string: any} = {}
    for key, value in pairs(values) do
        if not METADATA[key] and key:sub(1, 1) ~= "_" then
            out[key] = value
        end
    end
    return out
end

--- Serializes an instance, or returns nil for a component that carries no
--- data. A tag is presence, so it has nothing to show.
local function valueOf(kind: ecs.Component, instance: any): {string: any}
    local ok, serialized = pcall(function(): {string: any}
        return (kind.serialize as function(any): {string: any})(instance)
    end)
    if not ok or serialized == nil then
        return nil
    end
    local fields = dataFields(serialized)
    if next(fields) == nil then
        return nil
    end
    return fields
end

--- An entity's `Name`, or nil for one that carries none.
---
--- Reported beside the id everywhere an entity is, because a bare number says
--- nothing about which entity it is and `Name` is what the ECS provides for
--- saying so.
local function nameOf(w: ecs.World, entity: integer): string
    local Name <const> = ecs.builtins.Name
    if not w:has(entity, Name as ecs.Component) then
        return nil
    end
    local ok, value = pcall(function(): any return w:get(entity, Name as ecs.Component) end)
    return ok and value ~= nil and tostring(value) or nil
end

--- Reads one entity's components as plain tables.
local function describe(w: ecs.World, entity: integer, declared: {string: ecs.Component}): {string: any}
    local values: {string: any} = {}
    local count = 0
    for name, kind in pairs(declared) do
        if w:has(entity, kind) then
            -- Through the component's own serializer, so an FFI component
            -- crosses as numbers rather than as cdata JSON cannot carry. A tag
            -- has no data, so it reports as present rather than as an empty
            -- object a client would have to special-case.
            local ok, instance = pcall(function(): any return w:get(entity, kind) end)
            local data = ok and valueOf(kind, instance) or nil
            values[name] = data ~= nil and data or true
            count = count + 1
        end
    end
    return {
        entity = entity,
        name = nameOf(w, entity) or cjson.null,
        components = values,
        count = count,
    }
end

--- Everything about one entity, with the registry read once for it.
local function describeOne(w: ecs.World, entity: integer): {string: any}
    return describe(w, entity, ecs.declaredComponents())
end

-------------------------------------------------------------------------------
-- Reading
-------------------------------------------------------------------------------

--- The components some live entity of `w` carries.
---
--- The registry is process-wide and a world is not: a component can be
--- declared and carried by nothing here, which is an ordinary state and not
--- the same answer as a name nobody registered. So `components_info` reports
--- both rather than conflating them.
local function presentIn(w: ecs.World): {ecs.Component: boolean}
    local present: {ecs.Component: boolean} = {}
    if w == nil then
        return present
    end
    w:forEachArchetype(function(archetype: ecs.Archetype)
        if archetype.entities[0] == 0 then
            return
        end
        local list = archetype.componentList
        for index = 1, #list do
            present[list[index]] = true
        end
    end)
    return present
end

mcp.register({
    name = "components_info",
    description = "Lists the components these tools can name, with the fields "
        .. "each carries and whether the bound world carries any.",
    readOnly = true,
    inputSchema = {type = "object", properties = cjson.empty_array},
    handler = function(_: {string: any}): {string: any}
        local declared = ecs.declaredComponents()
        local names = sortedNames(declared)
        local present = presentIn(bound)

        local described: {any} = {}
        for index, name in ipairs(names) do
            local kind = declared[name]
            -- Fields are read from a default instance rather than declared
            -- again here, so this cannot describe a component incorrectly.
            local fields: {string} = {}
            local built, sample = pcall(function(): any return (kind as function(): any)() end)
            local data = built and valueOf(kind, sample) or nil
            if data ~= nil then
                for field in pairs(data) do
                    fields[#fields + 1] = field
                end
                table.sort(fields)
            end
            described[index] = {
                name = name,
                id = kind.componentId,
                -- A component with no fields is a tag: presence is its whole
                -- meaning, which is worth saying rather than leaving inferred
                -- from an empty list.
                tag = #fields == 0,
                fields = #fields > 0 and fields or cjson.empty_array,
                -- Declared here and carried by nothing is a real state, so it
                -- reads as absent rather than as a name that does not exist.
                present = present[kind] == true,
            }
        end
        return {components = described, bound = bound ~= nil}
    end,
})

mcp.register({
    name = "query",
    description = "Finds entities carrying every named component. Returns "
        .. "their ids and, unless values is false, their component values.",
    readOnly = true,
    inputSchema = {
        type = "object",
        properties = {
            include = {
                type = "array",
                items = {type = "string"},
                description = "Component names an entity must have.",
            },
            limit = {type = "integer", description = "Default 50."},
            values = {
                type = "boolean",
                description = "Include component values. Default true.",
            },
        },
        required = {"include"},
    },
    handler = function(args: {string: any}): {string: any}
        local w = current()
        local include = componentList(args.include as {any})
        if #include == 0 then
            error("include must name at least one component", 0)
        end

        local limit = math.floor(tonumber(args.limit) or 50) as integer
        local wantValues = args.values ~= false
        -- Read once for the page rather than per row, since a describe walks
        -- it whole and the registry cannot change while this runs.
        local declared = ecs.declaredComponents()

        local query = w:query({include = include})
        local rows: {any} = {}
        local total = 0

        -- A cursor rather than iter, because this stops at the limit and
        -- leaving an archetype loop early through iter leaves the world
        -- deferred, which silently queues every later spawn.
        local cursor = query:cursor()
        for archetype, length in cursor:iter() do
            total = total + length
            for row = 1, length do
                if #rows < limit then
                    local entity = archetype.entities[row] as integer
                    if wantValues then
                        rows[#rows + 1] = describe(w, entity, declared)
                    else
                        rows[#rows + 1] = {
                            entity = entity,
                            name = nameOf(w, entity) or cjson.null,
                        }
                    end
                end
            end
        end
        cursor:close()

        return {
            matched = total,
            returned = #rows,
            entities = #rows > 0 and rows or cjson.empty_array,
        }
    end,
})

mcp.register({
    name = "info",
    description = "Everything known about one entity.",
    readOnly = true,
    inputSchema = {
        type = "object",
        properties = {entity = {type = "integer"}},
        required = {"entity"},
    },
    handler = function(args: {string: any}): {string: any}
        local w = current()
        local entity = math.floor(tonumber(args.entity) or 0) as integer
        if not w:isAlive(entity) then
            return {entity = entity, alive = false}
        end
        local described = describeOne(w, entity)
        described.alive = true
        return described
    end,
})

-------------------------------------------------------------------------------
-- Writing
-------------------------------------------------------------------------------

--- Builds a component instance from a plain table.
---
--- Through the component's own constructor, so defaults come from where they
--- are declared rather than from a copy of them here. A field the payload
--- omits therefore takes the component's default, which is what makes `set` a
--- replacement rather than a merge.
local function construct(kind: ecs.Component, values: {string: any}): any
    local instance = (kind as function(): any)()
    if values == nil then
        return instance
    end
    local fields = instance as {string: any}
    for field, value in pairs(values) do
        fields[field] = value
    end
    return instance
end

mcp.register({
    name = "spawn",
    description = "Creates an entity carrying the given components.",
    destructive = true,
    inputSchema = {
        type = "object",
        properties = {
            components = {
                type = "object",
                description = "Component name to its field values.",
            },
        },
        required = {"components"},
    },
    handler = function(args: {string: any}): {string: any}
        local w = current()
        local requested = args.components as {string: any}
        if requested == nil or next(requested) == nil then
            error("components must name at least one component", 0)
        end

        local instances: {any} = {}
        for name, values in pairs(requested) do
            instances[#instances + 1] = construct(component(name), values as {string: any})
        end

        -- LuaJIT is 5.1, where unpack is a global rather than table.unpack.
        local unpackAll = (_G as {string: any})["unpack"] as function({any}): any...
        local entity = (w.spawn as function(ecs.World, ...: any): integer)(w, unpackAll(instances))
        return describeOne(w, entity)
    end,
})

mcp.register({
    name = "set",
    description = "Replaces a component in full, adding it if absent. Fields "
        .. "the payload omits take the component's defaults, so prefer modify "
        .. "for changing a value without disturbing the rest.",
    destructive = true,
    inputSchema = {
        type = "object",
        properties = {
            entity = {type = "integer"},
            component = {type = "string"},
            values = {type = "object"},
        },
        required = {"entity", "component"},
    },
    handler = function(args: {string: any}): {string: any}
        local w = current()
        local entity = math.floor(tonumber(args.entity) or 0) as integer
        if not w:isAlive(entity) then
            error(("entity %d is not alive"):format(entity), 0)
        end

        local kind = component(args.component as string)
        local added = not w:has(entity, kind)
        w:set(entity, kind, construct(kind, args.values as {string: any}))

        local described = describeOne(w, entity)
        described.added = added
        return described
    end,
})

mcp.register({
    name = "modify",
    description = "Changes only the named fields, leaving the rest alone. "
        .. "An entity without the component is skipped rather than gaining "
        .. "one, so a typo cannot silently add a component.",
    destructive = true,
    inputSchema = {
        type = "object",
        properties = {
            entity = {type = "integer"},
            component = {type = "string"},
            values = {type = "object"},
        },
        required = {"entity", "component", "values"},
    },
    handler = function(args: {string: any}): {string: any}
        local w = current()
        local entity = math.floor(tonumber(args.entity) or 0) as integer
        local kind = component(args.component as string)
        if not w:isAlive(entity) or not w:has(entity, kind) then
            return {entity = entity, skipped = true}
        end

        local values = args.values as {string: any}
        if values == nil or next(values) == nil then
            error("values must name at least one field", 0)
        end

        -- getMut rather than get, so the column is marked dirty and whatever
        -- consumes it re-uploads. Writing through get would change the memory
        -- and leave the GPU showing the old value.
        local instance = w:getMut(entity, kind) as {string: any}
        for field, value in pairs(values) do
            instance[field] = value
        end

        local described = describeOne(w, entity)
        described.skipped = false
        return described
    end,
})

mcp.register({
    name = "remove",
    description = "Removes a component from an entity.",
    destructive = true,
    inputSchema = {
        type = "object",
        properties = {
            entity = {type = "integer"},
            component = {type = "string"},
        },
        required = {"entity", "component"},
    },
    handler = function(args: {string: any}): {string: any}
        local w = current()
        local entity = math.floor(tonumber(args.entity) or 0) as integer
        local kind = component(args.component as string)
        if not w:isAlive(entity) or not w:has(entity, kind) then
            return {entity = entity, skipped = true}
        end
        w:remove(entity, kind)
        local described = describeOne(w, entity)
        described.skipped = false
        return described
    end,
})

mcp.register({
    name = "despawn",
    description = "Destroys an entity.",
    destructive = true,
    inputSchema = {
        type = "object",
        properties = {entity = {type = "integer"}},
        required = {"entity"},
    },
    handler = function(args: {string: any}): {string: any}
        local w = current()
        local entity = math.floor(tonumber(args.entity) or 0) as integer
        if not w:isAlive(entity) then
            return {entity = entity, skipped = true}
        end
        w:despawn(entity)
        return {entity = entity, skipped = false}
    end,
})

return world
