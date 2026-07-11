--- World-facing MCP tool handlers: entity, component, archetype, system, and
--- resource introspection plus the spawn/despawn/patch/run_lua mutation
--- tools. Mutations that must run inside the frame's update go through the
--- shared queued-op drain.

local tecs <const> = require("tecs")
local logging <const> = require("tecs.utils.logging")
local entityinfo <const> = require("tecs2d.internal.entityinfo")
local systemcontrol <const> = require("tecs2d.internal.systemcontrol")
local rpc <const> = require("tecs2d.mcp.internal.rpc")
local state <const> = require("tecs2d.mcp.internal.state")

local log <const> = logging.getLogger("tecs-mcp")

local record worldtools
    install: function(ctx: state.Context)
end

local ctx: state.Context = nil

local sendToolOK <const> = rpc.sendToolOK
local sendToolError <const> = rpc.sendToolError
local requireWorld <const> = rpc.requireWorld
local requireArg <const> = rpc.requireArg
local serializeRow <const> = entityinfo.serializeRow

local handlers: {string: rpc.Handler} = {}

--- Collect entity IDs from the 'id' or 'ids' args, validating types at the
--- boundary. Reports a tool error and returns nil on invalid input.
local function collectEntityIds(args: {string:any}, id: number): {integer}
    local entityIds: {integer} = {}
    if args.ids then
        if type(args.ids) ~= "table" then
            sendToolError(id, "invalid_parameter", "'ids' must be an array of numbers")
            return nil
        end
        local ids = args.ids as {any}
        for i = 1, #ids do
            if type(ids[i]) ~= "number" then
                sendToolError(id, "invalid_parameter", "Entity ids must be numbers",
                    {index = i, value = tostring(ids[i])})
                return nil
            end
            table.insert(entityIds, ids[i] as integer)
        end
    elseif args.id then
        if type(args.id) ~= "number" then
            sendToolError(id, "invalid_parameter", "'id' must be a number",
                {value = tostring(args.id)})
            return nil
        end
        table.insert(entityIds, args.id as integer)
    else
        sendToolError(id, "missing_parameter", "Missing entity ID(s) - provide 'id' or 'ids'")
        return nil
    end
    return entityIds
end

-- Helper: Build component name → object lookup from global registry
local function getComponentMap(): {string: tecs.Component}
    local map: {string: tecs.Component} = {}
    local id = 1
    while true do
        local comp = tecs.getComponentById(id)
        if not comp then
            break
        end
        if comp.componentName then
            map[comp.componentName] = comp
        end
        id = id + 1
    end
    return map
end

--- Look up a component by name, reporting unknown_component and returning
--- nil when it is not registered.
local function resolveComponent(map: {string: tecs.Component}, name: string, id: number): tecs.Component
    local comp = map[name]
    if not comp then
        sendToolError(id, "unknown_component", "Unknown component", {component = name})
        return nil
    end
    return comp
end

-- Helper: Get archetype signature (sorted component names)
local function getArchetypeSignature(archetype: tecs.Archetype): string
    local names: {string} = {}
    local compList = archetype.componentList
    for i = 1, #compList do
        local comp = compList[i]
        if comp.componentName then
            table.insert(names, comp.componentName)
        end
    end
    table.sort(names)
    return table.concat(names, ", ")
end

--- Deserialize a component-name to component-data map into instances.
--- Reports a tool error and returns nil when a component is unknown or
--- fails to deserialize.
local function deserializeComponents(
    world: tecs.World,
    id: number,
    componentsData: {string: {string: any}},
    componentMap: {string: tecs.Component}
): {tecs.Component}
    local instances: {tecs.Component} = {}
    for compName, compData in pairs(componentsData) do
        local comp = resolveComponent(componentMap, compName, id)
        if not comp then return nil end

        -- Use component's deserialize method to create instance from data
        local ok, instance = pcall(function(): tecs.Component
            return comp.deserialize(world, compData)
        end)
        if not ok then
            sendToolError(id, "component_deserialize_failed", "Failed to create component", {
                component = compName,
                error = tostring(instance)
            })
            return nil
        end
        table.insert(instances, instance)
    end
    return instances
end

handlers["get_stats"] = function(_: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end
    local stats = world:getStats()
    local memoryKB = collectgarbage("count")
    sendToolOK(id, {
        entities = stats.entities,
        archetypes = stats.archetypes,
        components = stats.components,
        systems = stats.systems,
        memoryKB = memoryKB,
        memoryMB = memoryKB / 1024
    })
end

handlers["get_components"] = function(_: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end
    local componentIds: {string: integer} = {}
    local componentCounts: {string: integer} = {}
    world:forEachArchetype(function(archetype: tecs.Archetype)
        local entityCount = archetype.entities[0] as integer
        local compList = archetype.componentList
        for j = 1, #compList do
            local comp = compList[j]
            local name = comp.componentName
            if name then
                if not componentIds[name] then
                    componentIds[name] = comp.componentId
                    componentCounts[name] = 0
                end
                componentCounts[name] = componentCounts[name] + entityCount
            end
        end
    end)
    local names: {string} = {}
    for name in pairs(componentIds) do
        table.insert(names, name)
    end
    table.sort(names)
    local components: {{string: any}} = {}
    for i = 1, #names do
        local name = names[i]
        table.insert(components, {
            name = name,
            id = componentIds[name],
            entities = componentCounts[name]
        })
    end
    sendToolOK(id, {count = #components, components = components})
end

handlers["get_systems"] = function(_: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end
    local infos = systemcontrol.list(world)
    local systems: {{string: any}} = {}
    for i = 1, #infos do
        systems[i] = {name = infos[i].name, phase = infos[i].phase, enabled = infos[i].enabled}
    end
    sendToolOK(id, {count = #systems, systems = systems})
end

handlers["get_resources"] = function(_: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end

    local resources = world.resources as {any: any}
    local result: {{string: any}} = {}

    for key, value in pairs(resources) do
        local keyStr: string
        local valueType: string

        -- Try to get a meaningful name for the key
        if type(key) == "table" and (key as {string:any}).name then
            keyStr = (key as {string:any}).name as string
        else
            keyStr = tostring(key)
        end

        -- Get the type of the value
        if type(value) == "table" and getmetatable(value) then
            local mt = getmetatable(value)
            if mt.__name then
                valueType = mt.__name as string
            elseif mt.__index and type(mt.__index) == "table" and (mt.__index as {string:any}).__name then
                valueType = (mt.__index as {string:any}).__name as string
            else
                valueType = "table"
            end
        else
            valueType = type(value)
        end

        table.insert(result, {key = keyStr, type = valueType})
    end

    table.sort(result, function(a: {string: any}, b: {string: any}): boolean
        return (a.key as string) < (b.key as string)
    end)

    sendToolOK(id, {count = #result, resources = result})
end

handlers["despawn"] = function(args: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end

    -- Build list of entity IDs to despawn
    local entityIds = collectEntityIds(args, id)
    if not entityIds then return end

    -- Despawn all entities
    local succeeded: {integer} = {}
    local failed: {{string: any}} = {}
    for i = 1, #entityIds do
        local entityId = entityIds[i]
        local ok, err = pcall(world.despawn, world, entityId) as (boolean, any)
        if ok then
            table.insert(succeeded, entityId)
        else
            table.insert(failed, {id = entityId, error = tostring(err)})
        end
    end

    sendToolOK(id, {
        despawned = #succeeded,
        failed = #failed,
        ids = succeeded,
        errors = failed
    })
end

handlers["get_entity"] = function(args: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end

    local entityId = requireArg(args, "id", id) as integer
    if not entityId then return end

    local archetype, row, why = entityinfo.locate(world, entityId)
    if not archetype then
        if why == "not_alive" then
            sendToolError(id, "entity_not_found", "Entity not found", {id = entityId})
        else
            sendToolError(id, "entity_not_committed", "Entity not committed yet", {id = entityId})
        end
        return
    end
    local components = serializeRow(archetype, archetype.componentList, row)

    local result = {
        id = entityId,
        archetypeId = archetype.id,
        archetypeComponents = getArchetypeSignature(archetype),
        components = components
    }
    sendToolOK(id, result)
end

handlers["query"] = function(args: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end

    local includeNames = args.include as {string}
    if not includeNames or #includeNames == 0 then
        sendToolError(id, "missing_parameter", "Missing 'include' parameter")
        return
    end

    local excludeNames = (args.exclude as {string}) or {}
    local limit = (args.limit as integer) or 100

    -- Resolve component names to objects
    local componentMap = getComponentMap()
    local includeComponents: {tecs.Component} = {}
    local excludeComponents: {tecs.Component} = {}

    for i = 1, #includeNames do
        local comp = resolveComponent(componentMap, includeNames[i], id)
        if not comp then return end
        table.insert(includeComponents, comp)
    end

    for i = 1, #excludeNames do
        local comp = resolveComponent(componentMap, excludeNames[i], id)
        if not comp then return end
        table.insert(excludeComponents, comp)
    end

    -- Create and execute query. temp avoids registering a persistent query
    -- (and its archetype observers) for every MCP call.
    local query = world:query({
        temp = true,
        include = includeComponents,
        exclude = excludeComponents
    })

    -- Iterate and collect results. Iterate to exhaustion even after hitting
    -- the limit: breaking out of query:iter() leaks the query scope and
    -- leaves the world deferred for the rest of the frame.
    local results: {{string: any}} = {}
    local count = 0

    for archetype, len, entityList in query:iter() do
        if count < limit then
            local archetypeSig = getArchetypeSignature(archetype)
            local archetypeId = archetype.id
            for row = 1, len do
                if count >= limit then break end
                local entityId = entityList[row]
                local entityData: {string: any} = {
                    id = entityId,
                    archetypeId = archetypeId,
                    archetypeComponents = archetypeSig,
                    components = serializeRow(archetype, includeComponents, row)
                }
                table.insert(results, entityData)
                count = count + 1
            end
        end
    end

    local response = {count = count, entities = results}
    sendToolOK(id, response, {limit = limit, truncated = count >= limit})
end

handlers["get_archetypes"] = function(_: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end

    local archetypes: {{string: any}} = {}
    world:forEachArchetype(function(archetype: tecs.Archetype)
        local entityCount = archetype.entities[0] as integer

        local componentNames: {string} = {}
        local compList = archetype.componentList
        for j = 1, #compList do
            local comp = compList[j]
            if comp.componentName then
                table.insert(componentNames, comp.componentName)
            end
        end
        table.sort(componentNames)

        table.insert(archetypes, {
            id = archetype.id,
            entities = entityCount,
            components = componentNames
        })
    end)

    sendToolOK(id, {count = #archetypes, archetypes = archetypes})
end

handlers["spawn"] = function(args: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end

    local componentsData = requireArg(args, "components", id) as {string: {string: any}}
    if not componentsData then return end

    local instances = deserializeComponents(world, id, componentsData, getComponentMap())
    if not instances then return end

    -- Spawn entity
    local ok, result = pcall(function(): integer
        return world:spawn(table.unpack(instances))
    end)
    if ok then
        sendToolOK(id, {id = result})
    else
        sendToolError(id, "spawn_failed", "Spawn failed", {error = tostring(result)})
    end
end

handlers["get_bundles"] = function(_: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end

    local bundles = world:getBundles()
    local result: {string: {string: any}} = {}

    for name, bundle in pairs(bundles) do
        local bndl = bundle as tecs.Bundle
        result[name] = {
            required = bndl.required,
            defaulted = bndl.defaulted
        }
    end

    sendToolOK(id, {bundles = result})
end

handlers["spawn_bundle"] = function(args: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end

    local bundleName = requireArg(args, "bundle", id) as string
    if not bundleName then return end

    local componentsData = (args.components as {string: {string: any}}) or {}
    local instances = deserializeComponents(world, id, componentsData, getComponentMap())
    if not instances then return end

    local ok, result = pcall(function(): integer
        return world:spawnBundle(bundleName, table.unpack(instances))
    end)
    if ok then
        sendToolOK(id, {id = result})
    else
        sendToolError(id, "spawn_bundle_failed", "Spawn bundle failed", {error = tostring(result)})
    end
end

handlers["run_lua"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    local code = requireArg(args, "code", id) as string
    if not code then return end

    -- Wrap user code in a function(world) body so they don't need boilerplate
    -- Newline before "end" so code ending in a line comment still parses.
    local wrapped <const> = "return function(world) " .. code .. "\nend"

    -- Load the code
    local loadOk, loadResult = pcall(function(): function(tecs.World)
        local chunk, loadErr = load(wrapped, "mcp_lua", "t")
        if not chunk then
            error("Failed to load code: " .. tostring(loadErr))
        end
        local fn = chunk()
        if type(fn) ~= "function" then
            error("Code must return a function, got " .. type(fn))
        end
        return fn as function(tecs.World)
    end)

    if not loadOk then
        local errMsg = tostring(loadResult)
        log:error("run_lua load failed: %s", errMsg)
        sendToolError(id, "lua_load_failed", "Lua load failed", {error = errMsg})
        return
    end

    local fn = loadResult as function(tecs.World)

    -- Run in the queued-op drain and return the chunk's results. Keep the client
    -- socket open until this deferred response is sent (the request handler returns
    -- before the queued op runs).
    ctx.pendingWorldOpResponse = true
    state.enqueue(ctx, function(w: tecs.World)
        local pcallAny = pcall as function(any, ...: any): boolean, any
        local results = {pcallAny(fn, w)} as {any}
        if not results[1] then
            local errMsg = tostring(results[2])
            log:error("run_lua execution failed: %s", errMsg)
            sendToolError(id, "lua_execution_failed", "Lua execution failed", {error = errMsg})
            ctx.pendingWorldOpResponse = false
            return
        end
        local n = #results
        local values: {string} = {}
        for i = 2, n do values[i - 1] = tostring(results[i]) end
        sendToolOK(id, {
            returned = n - 1,
            values = values
        })
        ctx.pendingWorldOpResponse = false
    end)
end

handlers["patch_entities"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end

    -- Build list of entity IDs. Validation matters here: the queued op runs
    -- in the drain outside any pcall, one frame after this tool already
    -- replied, so a bad id there would crash the frame.
    local entityIds = collectEntityIds(args, id)
    if not entityIds then return end

    local setData = (args.set as {string: {string: any}}) or {}
    local removeNames = (args.remove as {string}) or {}
    local componentMap = getComponentMap()

    -- Validate components exist before making changes
    for compName in pairs(setData) do
        if not resolveComponent(componentMap, compName, id) then return end
    end
    for i = 1, #removeNames do
        if not resolveComponent(componentMap, removeNames[i], id) then return end
    end

    -- Apply patches in the MCP queued-op drain (RenderFirst phase).
    state.enqueue(ctx, function(w: tecs.World)
        local patched = 0
        local errors: {string} = {}

        for i = 1, #entityIds do
            local entityId = entityIds[i]
            -- The drain runs outside any pcall; nothing per-entity may
            -- raise or the whole frame dies after the client already got
            -- a queued=true reply.
            local aliveOk, alive = pcall(w.isAlive, w, entityId)
            if not aliveOk or not alive then
                table.insert(errors, "Entity " .. entityId .. " not found")
            else
                local okOps = 0

                -- Set/update components
                for compName, compData in pairs(setData) do
                    local comp = componentMap[compName]
                    local setErr: string = nil
                    local ok = xpcall(function()
                        w:set(entityId, comp.deserialize(w, compData))
                    end, function(e: any): string
                        setErr = tostring(e)
                        return setErr
                    end)
                    if ok then
                        okOps = okOps + 1
                    else
                        local err = "Failed to set " .. compName .. " on " .. entityId ..
                            ": " .. setErr
                        table.insert(errors, err)
                    end
                end

                -- Remove components
                for j = 1, #removeNames do
                    local comp = componentMap[removeNames[j]]
                    local removeOk, removeErr = pcall(w.remove, w, entityId, comp) as (boolean, any)
                    if removeOk then
                        okOps = okOps + 1
                    else
                        local err = "Failed to remove " .. removeNames[j] .. " from " ..
                            entityId .. ": " .. tostring(removeErr)
                        table.insert(errors, err)
                    end
                end

                -- An entity counts as patched only when at least one of its
                -- ops landed; the log would otherwise overstate success.
                if okOps > 0 then
                    patched = patched + 1
                end
            end
        end

        local msg = "Patched " .. patched .. " entities"
        if #errors > 0 then
            msg = msg .. " with " .. #errors .. " errors: " .. table.concat(errors, "; ")
        end
        log:info(msg)
    end)

    sendToolOK(id, {queued = true, entities = #entityIds, ids = entityIds})
end

handlers["query_in_bounds"] = function(args: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end

    local boundsX = args.x as number
    local boundsY = args.y as number
    local boundsW = args.width as number
    local boundsH = args.height as number
    if not boundsX or not boundsY or not boundsW or not boundsH then
        sendToolError(id, "missing_parameter", "Missing bounds parameters (x, y, width, height)")
        return
    end

    local limit = (args.limit as integer) or 100
    local includeNames = (args.include as {string}) or {}
    local componentMap = getComponentMap()

    -- Spatial component: accept either "Position" or the built-in Transform.
    -- Many tecs games don't define their own Position component; tecs's
    -- Transform is the ubiquitous one. Prefer Position for backwards
    -- compatibility with games that do register it.
    local positionComp = componentMap["Position"]
    local positionName = "Position"
    if not positionComp then
        positionComp = componentMap["Transform"]
        positionName = "Transform"
    end
    if not positionComp then
        sendToolError(id, "spatial_component_not_found",
            "Neither Position nor Transform component is registered; cannot run query_in_bounds.")
        return
    end

    -- Build include list with the spatial component first
    local includeComponents: {tecs.Component} = {positionComp}
    for i = 1, #includeNames do
        local name = includeNames[i]
        if name ~= positionName then
            local comp = resolveComponent(componentMap, name, id)
            if not comp then return end
            table.insert(includeComponents, comp)
        end
    end

    -- Query and filter by bounds. temp avoids registering a persistent query,
    -- and the loop runs to exhaustion because breaking out of query:iter()
    -- leaks the query scope and leaves the world deferred.
    local query = world:query({temp = true, include = includeComponents})
    local results: {{string: any}} = {}
    local count = 0
    local boundsX2 = boundsX + boundsW
    local boundsY2 = boundsY + boundsH

    for archetype, len, entityList in query:iter() do
        local posColumn = count < limit and archetype:get(positionComp)
        if posColumn then
            for row = 1, len do
                if count >= limit then break end
                local pos = posColumn[row]
                local posAny = pos as {string: number}
                local px, py = posAny.x, posAny.y

                -- Check bounds
                if px >= boundsX and px <= boundsX2 and py >= boundsY and py <= boundsY2 then
                    local entityId = entityList[row]
                    local entityData: {string: any} = {
                        id = entityId,
                        components = serializeRow(archetype, includeComponents, row)
                    }
                    table.insert(results, entityData)
                    count = count + 1
                end
            end
        end
    end

    local response = {
        count = count, entities = results,
        bounds = {x = boundsX, y = boundsY, width = boundsW, height = boundsH}
    }
    sendToolOK(id, response, {limit = limit, truncated = count >= limit})
end

handlers["toggle_system"] = function(args: {string:any}, id: number)
    local world = requireWorld(id)
    if not world then return end

    local systemName = requireArg(args, "name", id) as string
    if not systemName then return end
    local isEnabled = requireArg(args, "enabled", id) as boolean
    if isEnabled == nil then return end

    local ok, err = systemcontrol.setEnabled(world, systemName, isEnabled)
    if not ok then
        sendToolError(id, "system_not_found", err, {system = systemName})
        return
    end
    sendToolOK(id, {system = systemName, enabled = isEnabled})
end

handlers["get_component_schema"] = function(args: {string:any}, id: number)
    if not requireWorld(id) then return end
    local name = requireArg(args, "name", id) as string
    if not name then return end
    local comp = resolveComponent(getComponentMap(), name, id)
    if not comp then return end
    local schema = entityinfo.componentSchema(comp)
    sendToolOK(id, {
        name = schema.name,
        id = schema.id,
        kind = schema.kind,
        fields = schema.fields,
        defaults = schema.defaults,
        serializable = schema.serializable,
    })
end

function worldtools.install(c: state.Context)
    ctx = c
    for name, fn in pairs(handlers) do
        rpc.handlers[name] = fn
    end
end

return worldtools
