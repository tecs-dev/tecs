--- Engine-section debugger commands: systems, archetypes, components,
--- states, physics, controllers, assets, audio, fetch, resources, and
--- bundles, plus the subsystem lookups they share (the physics state, the
--- controller/audio/asset managers, and the asset manager's strong load log).
---
--- Everything shared with the core registry arrives through cmdtypes.Deps;
--- this module must not require tecs2d.debug.commands (a load cycle).

local tecs <const> = require("tecs")
local json <const> = require("tecs.utils.json")
local gfxtypes <const> = require("tecs2d.gfx.types")
local componentregistry <const> = require("tecs.internal.components")
local sanitize <const> = require("tecs2d.debug.internal.sanitize")
local entityinfo <const> = require("tecs2d.internal.entityinfo")
local systemcontrol <const> = require("tecs2d.internal.systemcontrol")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

local format <const> = string.format


local record engine
    --- The Engine-section commands, in display order.
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

local systemNameSchema <const>: cmdargs.Schema = {
    args = { name = {required = true, help = "system name (see `systems`)"} },
    positional = {"name"},
}

local fetchSchema <const>: cmdargs.Schema = {
    args = {
        expr = {rest = true, required = true,
            help = "component names separated by spaces; -Foo excludes"},
        limit = {default = 100, min = 0, help = "max entities returned"},
        count_only = {kind = "boolean",
            help = "return only the match count, no entity payloads"},
        x = {kind = "number", help = "bounds left world x (give all of x, y, w, h or none)"},
        y = {kind = "number", help = "bounds top world y"},
        w = {kind = "number", help = "bounds width in world units"},
        h = {kind = "number", help = "bounds height in world units"},
    },
    positional = {"expr"},
}
cmdargs.validate(fetchSchema)

local bundleSpawnSchema <const>: cmdargs.Schema = {
    args = {
        name = {required = true, help = "bundle name"},
        components = {kind = "table",
            help = "component overrides: {Name = {field = value}, ...} (a JSON object over MCP)"},
    },
    positional = {"name", "components"},
}
cmdargs.validate(bundleSpawnSchema)

local resourcesSchema <const>: cmdargs.Schema = {
    args = {
        name = {help = "named key (from tecs.newKey(\"name\")): return that resource's value"},
    },
    positional = {"name"},
}
cmdargs.validate(resourcesSchema)

-- Evaluate a Lua table expression from the command line. Same trust level
-- as the run_lua MCP tool: the debugger is a developer surface.
local function evalTable(expr: string): {string: any}, string
    local chunk, cerr = load("return " .. expr, "debug-expr", "t")
    if not chunk then return nil, "bad expression: " .. tostring(cerr) end
    local ok, result = pcall(chunk)
    if not ok then return nil, "expression failed: " .. tostring(result) end
    if type(result) ~= "table" then
        return nil, "expression must be a table, got " .. type(result)
    end
    return result as {string: any}, nil
end

-- A table-kind argument value: a table passes through (a JSON object over
-- MCP); a nonempty string evaluates as a Lua table expression. Returns nil
-- with no error when the value is absent.
local function parseTableArg(value: any): {string: any}, string
    if type(value) == "table" then
        return value as {string: any}, nil
    end
    if type(value) == "string" and (value as string) ~= "" then
        return evalTable(value as string)
    end
    return nil, nil
end

-- Archetype signature (sorted component names) as one display string.
local function archetypeSignature(arch: tecs.Archetype): string
    local names: {string} = {}
    for i = 1, #arch.componentList do
        local nm = arch.componentList[i].componentName
        if nm then names[#names + 1] = nm end
    end
    table.sort(names)
    return table.concat(names, ", ")
end

function engine.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    -- The shared context, aliased once so command bodies stay terse.
    local w <const> = d.world
    local ctx <const> = d.ctx
    local env <const> = d.env
    local pipeline <const> = d.pipeline
    local componentFor <const> = d.componentFor
    local resolveTargets <const> = d.resolveTargets
    local makeAnnotation <const> = d.makeAnnotation
    local onOffSchema <const> = d.onOffSchema
    local optionalTargetSchema <const> = d.optionalTargetSchema

    -- Pre-mute master volume for `audio mute off`.
    local preMuteVolume: number = nil

    -- Resolve the pipeline, or produce the standard failure Result. Call
    -- sites early-return the second value.
    local function needPipeline(message: string): gfxtypes.Pipeline, cmdtypes.Result
        local p = pipeline()
        if p then return p, nil end
        return nil, {ok = false, code = "no_pipeline", message = message}
    end

    -- Plugin modules (physics, controller, assets, audio) double as their
    -- resource keys. They are read from package.loaded, never required here:
    -- a require would register their components in every game the debugger
    -- runs in, plugin installed or not. A module that was never required
    -- cannot have been installed as a plugin, so a package.loaded miss means
    -- the plugin is absent.
    local function pluginResource(modname: string): any
        local key = package.loaded[modname]
        if key == nil then return nil end
        return w.resources[key as tecs.Key<any>]
    end

    local function physicsState(): {string: any}
        return pluginResource("tecs2d.physics") as {string: any}
    end

    -- Find an entity's Box2D body by scanning shape user data.
    local function bodyForEntity(st: {string: any}, eid: integer): love.physics.Body
        local world = st.world as love.physics.World
        local bodies = world:getBodies()
        for i = 1, #bodies do
            local body = bodies[i]
            local shapes = (body as {string: any}).getShapes as function(any): {any}
            local okShapes, list = pcall(shapes, body)
            if okShapes and list then
                for j = 1, #list do
                    local shapeAny = list[j] as {string: any}
                    local getUD = shapeAny.getUserData as function(any): any
                    local okUD, data = pcall(getUD, list[j])
                    if okUD and data and ((data as {string: any}).entity as integer) == eid then
                        return body
                    end
                end
            end
        end
        return nil
    end

    local function controllerManager(): {string: any}
        return pluginResource("tecs2d.controller") as {string: any}
    end

    local function audioManager(): any
        return pluginResource("tecs2d.audio")
    end

    local function assetManager(): {string: any}
        return pluginResource("tecs2d.assets") as {string: any}
    end

    -- Sorted asset keys, optionally filtered by a plain substring. Reads the
    -- manager's strong _assetLog (the cache is weak-valued, so cache entries
    -- vanish once the game drops its handles) unioned with the live cache.
    -- Returns nil + reason when the manager is missing.
    local function assetKeys(filter: string): {string}, string
        local mgr = assetManager()
        if not mgr then
            return nil, "manager not installed"
        end
        local seen: {string: boolean} = {}
        local keys: {string} = {}
        local function collect(t: {string: any})
            for k in pairs(t or {}) do
                if not seen[k] and (not filter or k:find(filter, 1, true)) then
                    seen[k] = true
                    keys[#keys + 1] = k
                end
            end
        end
        collect(mgr._assetLog as {string: any})
        collect(mgr._cache as {string: any})
        table.sort(keys)
        return keys, nil
    end

    -- One asset's action/path/status plus whether a live handle is still
    -- cached, from the log entry or the handle (whichever exists).
    local function assetEntry(key: string): {string: any}
        local mgr = assetManager()
        local logTable = mgr._assetLog as {string: any}
        local logged = logTable and logTable[key] as {string: any}
        local cache = mgr._cache as {string: any}
        local handle = cache and cache[key] as {string: any}
        local action = logged and logged.action or (handle and handle._action) or "(custom)"
        local path = logged and logged.path or (handle and handle._path) or key
        local status = logged and (logged.status as string) or nil
        if handle and (status == nil or status == "custom") then
            status = "loaded"
            if not handle.isComplete then
                status = "loading"
            elseif handle.err ~= nil then
                status = "failed: " .. tostring(handle.err)
            end
        end
        return {key = key, action = action, path = path,
            status = status or "unknown", cached = handle ~= nil}
    end

    -- Re-queue a cached handle's original worker request under its own id,
    -- so completion swaps the loaded value in place and re-fires
    -- HandleComplete. Handles from custom :load() loaders have no worker
    -- request to replay; those return false.
    local function reloadAssetHandle(mgrAny: {string: any}, handle: {string: any}): boolean
        if not handle then return false end
        local args = handle._args as {any}
        local id = handle.id as integer
        local push = mgrAny._pushChannel as love.thread.Channel
        if not args or not id or not push then return false end
        local tasks = mgrAny._runningTasks as {integer: any}
        if tasks[id] then return false end   -- already loading; nothing to do
        tasks[id] = handle
        mgrAny._runningCount = ((mgrAny._runningCount as integer) or 0) + 1
        handle.isComplete = false
        push:push(args)
        return true
    end

    -- Systems listing and control shared by the `systems` verbs.
    local function systemsList(): cmdtypes.Result
        local infos = systemcontrol.list(w)
        local popup: {string} = {"systems  (" .. tostring(#infos) .. "):"}
        for i = 1, #infos do
            local info = infos[i]
            popup[#popup + 1] = "  " .. info.name .. "\t" .. info.phase ..
                (info.enabled and "" or "\tstopped")
        end
        local data: {{string: any}} = {}
        for i = 1, #infos do
            data[i] = {name = infos[i].name, phase = infos[i].phase, enabled = infos[i].enabled}
        end
        return {ok = true, popup = popup, data = {count = #infos, systems = data}}
    end

    local function setSystemEnabled(nm: string, enabled: boolean): cmdtypes.Result
        local ok, err = systemcontrol.setEnabled(w, nm, enabled)
        if not ok then
            return {ok = false, code = "system_not_found", message = "systems: " .. err}
        end
        return {ok = true,
            message = (enabled and "started " or "stopped ") .. nm,
            data = {name = nm, enabled = enabled}}
    end

    return {
        {
            name = "systems",
            section = "Engine",
            shortHelp = "list systems and stop, start, or inspect them",
            examples = {"systems list", "systems stop PhysicsStep", "systems start PhysicsStep",
                "systems info debug.Overlay"},
            subcommands = {
                {
                    name = "list",
                    aliases = {"ls"},
                    shortHelp = "list every system with its phase and state",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        return systemsList()
                    end,
                },
                {
                    name = "stop",
                    complete = {[1] = "systems"},
                    shortHelp = "disable a system by name",
                    schema = systemNameSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        return setSystemEnabled(v.name as string, false)
                    end,
                },
                {
                    name = "start",
                    complete = {[1] = "systems"},
                    shortHelp = "re-enable a stopped system",
                    schema = systemNameSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        return setSystemEnabled(v.name as string, true)
                    end,
                },
                {
                    name = "toggle",
                    complete = {[1] = "systems"},
                    shortHelp = "flip a system between stopped and running",
                    schema = systemNameSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local nm = v.name as string
                        local info = systemcontrol.info(w, nm)
                        if not info then
                            return {ok = false, code = "system_not_found",
                                message = "systems: no system named '" .. nm .. "'"}
                        end
                        return setSystemEnabled(nm, not info.enabled)
                    end,
                },
                {
                    name = "info",
                    complete = {[1] = "systems"},
                    shortHelp = "show one system's phase, order, and state",
                    schema = systemNameSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local nm = v.name as string
                        local info = systemcontrol.info(w, nm)
                        if not info then
                            return {ok = false, code = "system_not_found",
                                message = "systems: no system named '" .. nm .. "'"}
                        end
                        return {ok = true, popup = {
                            "system: " .. info.name,
                            "  phase\t" .. info.phase,
                            "  order in phase\t#" .. tostring(info.position),
                            "  state\t" .. (info.enabled and "running" or "stopped"),
                            "  own runIf\t" .. (info.hasRunIf and "yes" or "no"),
                        }, data = {name = info.name, phase = info.phase, enabled = info.enabled,
                            position = info.position, hasRunIf = info.hasRunIf}}
                    end,
                },
            },
        },
        {
            name = "archetypes",
            section = "Engine",
            shortHelp = "list archetypes, show one, or select its entities",
            examples = {"archetypes list", "archetypes info 12", "archetypes select 12"},
            subcommands = {
                {
                    name = "list",
                    shortHelp = "list archetypes by entity count",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local rows: {{string: any}} = {}
                        w:forEachArchetype(function(arch: tecs.Archetype)
                            local n = arch.entities[0] as integer
                            local names: {string} = {}
                            for i = 1, #arch.componentList do
                                local nm = arch.componentList[i].componentName
                                if nm then names[#names + 1] = nm end
                            end
                            table.sort(names)
                            rows[#rows + 1] = {id = arch.id, entities = n,
                                components = table.concat(names, ", ")}
                        end)
                        table.sort(rows, function(a: {string: any}, b: {string: any}): boolean
                            return (a.entities as integer) > (b.entities as integer)
                        end)
                        local popup: {string} = {"archetypes  (" .. tostring(#rows) .. ", by entity count):"}
                        for i = 1, #rows do
                            popup[#popup + 1] = format("  #%d\t%d\t%s",
                                rows[i].id as integer, rows[i].entities as integer,
                                rows[i].components as string)
                        end
                        return {ok = true, popup = popup, data = {count = #rows, archetypes = rows}}
                    end,
                },
                {
                    name = "info",
                    shortHelp = "show one archetype's entity count and components",
                    schema = { args = { id = {required = true, kind = "number", help = "archetype id"} },
                        positional = {"id"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local wanted = math.floor(v.id as number)
                        local found: tecs.Archetype = nil
                        w:forEachArchetype(function(arch: tecs.Archetype)
                            if arch.id == wanted then found = arch end
                        end)
                        if not found then
                            return {ok = false, code = "no_match",
                                message = "archetypes info: no archetype " .. tostring(wanted)}
                        end
                        local names: {string} = {}
                        for i = 1, #found.componentList do
                            local nm = found.componentList[i].componentName
                            if nm then names[#names + 1] = nm end
                        end
                        table.sort(names)
                        local popup: {string} = {
                            "archetype #" .. tostring(wanted),
                            "  entities\t" .. tostring(found.entities[0]),
                            "Components:",
                        }
                        for i = 1, #names do popup[#popup + 1] = "  " .. names[i] end
                        return {ok = true, popup = popup,
                            data = {id = wanted, entities = found.entities[0], components = names}}
                    end,
                },
                {
                    name = "select",
                    shortHelp = "select every entity in an archetype",
                    schema = { args = { id = {required = true, kind = "number", help = "archetype id"} },
                        positional = {"id"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local wanted = math.floor(v.id as number)
                        local total = 0
                        local added = 0
                        local seen: {integer: boolean} = {}
                        for i = 1, #ctx.selected do seen[ctx.selected[i]] = true end
                        w:forEachArchetype(function(arch: tecs.Archetype)
                            if arch.id ~= wanted then return end
                            local n = arch.entities[0] as integer
                            total = total + n
                            for row = 1, n do
                                local eid = arch.entities[row] as integer
                                if not seen[eid] then
                                    seen[eid] = true
                                    added = added + 1
                                    ctx.selected[#ctx.selected + 1] = eid
                                end
                            end
                        end)
                        if total == 0 then
                            return {ok = false, code = "no_match",
                                message = "archetypes select: archetype " .. tostring(wanted) ..
                                    " is empty or unknown"}
                        end
                        debugcontext.pushEvent(ctx, "selection", {selected = #ctx.selected})
                        return {ok = true, message = "selected " .. tostring(added) ..
                            " of " .. tostring(total) .. " entities from archetype " .. tostring(wanted),
                            data = {selected = #ctx.selected, added = added,
                                total = total, archetype = wanted}}
                    end,
                },
            },
        },
        {
            name = "components",
            section = "Engine",
            shortHelp = "list component types or show one component's schema",
            examples = {"components list", "components info Transform"},
            subcommands = {
                {
                    name = "list",
                    shortHelp = "list registered component types",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local names: {string} = {}
                        for name in pairs(componentregistry.registeredComponents) do
                            names[#names + 1] = name
                        end
                        table.sort(names)
                        local popup: {string} = {"components  (" .. tostring(#names) .. "):"}
                        local line = "  "
                        for i = 1, #names do
                            local piece = names[i] .. ((i < #names) and ", " or "")
                            if #line + #piece > 64 and line ~= "  " then
                                popup[#popup + 1] = line
                                line = "  "
                            end
                            line = line .. piece
                        end
                        popup[#popup + 1] = line
                        return {ok = true, popup = popup, data = {count = #names, components = names}}
                    end,
                },
                {
                    name = "info",
                    complete = {[1] = "components"},
                    shortHelp = "show a component's schema by name or id",
                    schema = { args = { name = {required = true, help = "component name or id"} },
                        positional = {"name"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local nm = v.name as string
                        local comp, cerr = componentFor(nm)
                        if not comp then
                            -- A numeric argument looks up the component id instead.
                            local wanted = tonumber(nm)
                            if wanted then
                                for _, c in pairs(componentregistry.registeredComponents) do
                                    local candidate = c as tecs.Component
                                    if candidate.componentId == wanted then comp = candidate end
                                end
                            end
                        end
                        if not comp then
                            return {ok = false, code = "unknown_component", message = "components info: " .. cerr}
                        end
                        local schema = entityinfo.componentSchema(comp)
                        local popup: {string} = {
                            "component " .. tostring(schema.name),
                            "  id\t" .. tostring(schema.id),
                            "  storage\t" .. schema.kind,
                            "  serializable\t" .. (schema.serializable and "yes" or "no"),
                        }
                        if #schema.fields > 0 then
                            popup[#popup + 1] = "Fields:"
                            for i = 1, #schema.fields do
                                local f = schema.fields[i]
                                local def = schema.defaults and schema.defaults[f.name]
                                popup[#popup + 1] = "  " .. f.name .. "\t" .. f.type ..
                                    ((def ~= nil) and ("\t= " .. tostring(def)) or "")
                            end
                        end
                        return {ok = true, popup = popup,
                            data = {name = schema.name, id = schema.id, kind = schema.kind,
                                fields = schema.fields, defaults = schema.defaults,
                                serializable = schema.serializable}}
                    end,
                },
            },
        },
        {
            name = "states",
            section = "Engine",
            shortHelp = "show the state stack; `push <name>` / `pop` change it",
            examples = {"states info", "states push Paused", "states pop"},
            subcommands = {
                {
                    name = "info",
                    shortHelp = "show the state stack, top last",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local stack = (w as {string: any})._stateStack as {any}
                        local popup: {string} = {"state stack  (top last):"}
                        local names: {string} = {}
                        if stack and #stack > 0 then
                            for i = 1, #stack do
                                local entry = stack[i]
                                local nm = (type(entry) == "table")
                                    and tostring((entry as {string: any}).name) or tostring(entry)
                                names[#names + 1] = nm
                                popup[#popup + 1] = "  " .. tostring(i) .. "\t" .. nm ..
                                    ((i == #stack) and "\t<- top" or "")
                            end
                        else
                            popup[#popup + 1] = "  (empty)"
                        end
                        return {ok = true, popup = popup, data = {stack = names, top = w:peekState()}}
                    end,
                },
                {
                    name = "push",
                    shortHelp = "push a created state onto the stack",
                    schema = { args = { name = {required = true, help = "state name (created with createState)"} },
                        positional = {"name"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local nm = v.name as string
                        local ok, err = pcall(function(): boolean
                            w:pushState(nm)
                            return true
                        end)
                        if not ok then
                            return {ok = false, code = "push_failed",
                                message = "states push: " .. tostring(err)}
                        end
                        debugcontext.pushEvent(ctx, "edit", {state = nm, pushed = true})
                        return {ok = true, message = "pushed state " .. nm, data = {top = w:peekState()}}
                    end,
                },
                {
                    name = "pop",
                    shortHelp = "pop the top state off the stack",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local top = w:peekState()
                        if not top then
                            return {ok = false, code = "empty_stack", message = "states pop: the stack is empty"}
                        end
                        local ok, err = pcall(function(): boolean
                            w:popState()
                            return true
                        end)
                        if not ok then
                            return {ok = false, code = "pop_failed",
                                message = "states pop: " .. tostring(err)}
                        end
                        debugcontext.pushEvent(ctx, "edit", {state = top, popped = true})
                        return {ok = true, message = "popped " .. tostring(top),
                            data = {popped = top, top = w:peekState()}}
                    end,
                },
            },
        },
        {
            name = "physics",
            section = "Engine",
            shortHelp = "physics info; debug draw, body info, raycast, and area query",
            examples = {"physics info", "physics debug", "physics info 42",
                "physics raycast 0 0 100 100", "physics query 0 0 64 64"},
            subcommands = {
                {
                    name = "debug",
                    shortHelp = "toggle collision-shape debug drawing (installs the drawer if needed)",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        if not physicsState() then
                            return {ok = false, code = "no_physics", message = "physics: plugin not installed"}
                        end
                        -- Requiring the module here is safe: physicsState()
                        -- proves the game already loaded tecs2d.physics, so no
                        -- components get registered behind the game's back.
                        local physicsdebug = require("tecs2d.gfx.internal.physicsdebug")
                            as {string: any}
                        -- Install the debug drawer on demand.
                        if not systemcontrol.info(w, "tecs2d.gfx.physicsdebug") then
                            local p, perr = needPipeline("physics debug: the drawer needs a render pipeline")
                            if not p then return perr end
                            local newPlugin = physicsdebug.new as function(): tecs.Plugin
                            w:addPlugin(newPlugin())
                        end
                        local toggle = physicsdebug.PhysicsDebugToggle as function(): tecs.Event
                        w:emit(0, toggle())
                        return {ok = true, message = "physics debug toggled", data = {}}
                    end,
                },
                {
                    name = "info",
                    shortHelp = "physics state, or one entity's Box2D body properties",
                    schema = optionalTargetSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local st = physicsState()
                        if not st then
                            return {ok = false, code = "no_physics", message = "physics: plugin not installed"}
                        end
                        if v.target == nil then
                            local pworld = st.world as love.physics.World
                            local gx, gy = pworld:getGravity()
                            return {ok = true, popup = {
                                "physics",
                                "  bodies\t" .. tostring(pworld:getBodyCount()),
                                format("  gravity\t%.2f, %.2f", gx, gy),
                                "  smoothing\t" .. tostring(st.smoothing),
                                "  debug draw\t" .. (st.debug and "on" or "off"),
                            }, data = {bodies = pworld:getBodyCount(), gravityX = gx, gravityY = gy,
                                smoothing = st.smoothing}}
                        end
                        local ids = resolveTargets(v)
                        local target = ids[1]
                        if not target then
                            return {ok = false, code = "no_match",
                                message = "physics info: no match for '" .. tostring(v.target) .. "'"}
                        end
                        local body = bodyForEntity(st, target)
                        if not body then
                            return {ok = false, code = "no_body",
                                message = "physics info: entity #" .. tostring(target) .. " has no body"}
                        end
                        local bx, by = body:getPosition()
                        local vx, vy = body:getLinearVelocity()
                        return {ok = true, popup = {
                            "body #" .. tostring(target),
                            "  type\t" .. tostring(body:getType()),
                            format("  position\t%.2f, %.2f", bx, by),
                            format("  velocity\t%.2f, %.2f", vx, vy),
                            format("  angle\t%.3f", body:getAngle()),
                            format("  mass\t%.3f", body:getMass()),
                            "  awake\t" .. (body:isAwake() and "yes" or "no"),
                            "  bullet\t" .. (body:isBullet() and "yes" or "no"),
                        }, data = {entity = target, type = body:getType(), x = bx, y = by,
                            vx = vx, vy = vy, angle = body:getAngle(), mass = body:getMass(),
                            awake = body:isAwake()}}
                    end,
                },
                {
                    name = "raycast",
                    shortHelp = "cast a ray, draw it, and select the hits",
                    schema = { args = {
                        x1 = {required = true, kind = "number", help = "start world x"},
                        y1 = {required = true, kind = "number", help = "start world y"},
                        x2 = {required = true, kind = "number", help = "end world x"},
                        y2 = {required = true, kind = "number", help = "end world y"},
                    }, positional = {"x1", "y1", "x2", "y2"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local st = physicsState()
                        if not st then
                            return {ok = false, code = "no_physics", message = "physics: plugin not installed"}
                        end
                        local x1 = v.x1 as number
                        local y1 = v.y1 as number
                        local x2 = v.x2 as number
                        local y2 = v.y2 as number
                        local hits: {{string: number}} = {}
                        local raycaster = st.world as {string: any}
                        local rayFn = raycaster.rayCast as function(any, number, number, number, number,
                            function(any, number, number, number, number, number): number)
                        local castOk, castErr = pcall(rayFn, st.world, x1, y1, x2, y2,
                            function(shape: any, hx: number, hy: number,
                                    _nx: number, _ny: number, fraction: number): number
                                local shapeAny = shape as {string: any}
                                local getUD = shapeAny.getUserData as function(any): any
                                local data = getUD(shape) as {string: any}
                                local eid = data and (data.entity as integer) or 0
                                hits[#hits + 1] = {entity = eid, x = hx, y = hy, fraction = fraction}
                                return 1   -- keep going: collect every hit
                            end) as (boolean, any)
                        if not castOk then
                            return {ok = false, code = "raycast_failed",
                                message = "physics raycast: " .. tostring(castErr)}
                        end
                        table.sort(hits, function(a: {string: number}, b: {string: number}): boolean
                            return a.fraction < b.fraction
                        end)
                        env.annotations:add(makeAnnotation({x = x1, y = y1, x2 = x2, y2 = y2,
                            seconds = 5, tag = "physics", g = 0.4, b = 1}, "line"))
                        for i = 1, #hits do
                            env.annotations:add(makeAnnotation({x = hits[i].x, y = hits[i].y,
                                radius = 4, seconds = 5, tag = "physics", g = 0.2, b = 0.2}, "circle"))
                            if hits[i].entity ~= 0 then
                                debugcontext.addSelected(ctx, hits[i].entity as integer)
                            end
                        end
                        if #hits > 0 then
                            debugcontext.pushEvent(ctx, "selection", {selected = #ctx.selected})
                        end
                        return {ok = true,
                            message = "raycast hit " .. tostring(#hits) ..
                                " shape(s); drawn for 5s (`draw clear physics`)",
                            data = {hits = hits}}
                    end,
                },
                {
                    name = "query",
                    shortHelp = "select bodies inside a world-space box and draw it",
                    schema = { args = {
                        x = {required = true, kind = "number", help = "left world x"},
                        y = {required = true, kind = "number", help = "top world y"},
                        w = {required = true, kind = "number", help = "width"},
                        h = {required = true, kind = "number", help = "height"},
                    }, positional = {"x", "y", "w", "h"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local st = physicsState()
                        if not st then
                            return {ok = false, code = "no_physics", message = "physics: plugin not installed"}
                        end
                        local qx = v.x as number
                        local qy = v.y as number
                        local qw = v.w as number
                        local qh = v.h as number
                        local found: {integer} = {}
                        local seen: {integer: boolean} = {}
                        local pworld = st.world as love.physics.World
                        pworld:queryBoundingBox(qx, qy, qx + qw, qy + qh,
                            function(shape: any): boolean
                                local shapeAny = shape as {string: any}
                                local getUD = shapeAny.getUserData as function(any): any
                                local okUD, data = pcall(getUD, shape)
                                local eid = okUD and data and ((data as {string: any}).entity as integer) or 0
                                if eid ~= 0 and not seen[eid] then
                                    seen[eid] = true
                                    found[#found + 1] = eid
                                    debugcontext.addSelected(ctx, eid)
                                end
                                return true
                            end)
                        env.annotations:add(makeAnnotation({x = qx, y = qy, w = qw, h = qh,
                            seconds = 5, tag = "physics", g = 0.4, b = 1}, "rect"))
                        if #found > 0 then
                            debugcontext.pushEvent(ctx, "selection", {selected = #ctx.selected})
                        end
                        return {ok = true,
                            message = "query matched " .. tostring(#found) ..
                                " bodies; drawn for 5s (`draw clear physics`)",
                            data = {entities = found}}
                    end,
                },
            },
        },
        {
            name = "controllers",
            section = "Engine",
            shortHelp = "list controllers; `info <n>` shows bindings, `rumble` tests one",
            examples = {"controllers list", "controllers info 1", "controllers rumble 1"},
            subcommands = {
                {
                    name = "list",
                    shortHelp = "list controllers and their joysticks",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local mgr = controllerManager()
                        if not mgr then
                            return {ok = false, code = "no_controllers", message = "controllers: plugin not installed"}
                        end
                        local list = mgr.controllers as {any}
                        local popup: {string} = {"controllers  (" .. tostring(#list) .. "):"}
                        local rows: {{string: any}} = {}
                        for i = 1, #list do
                            local ctrl = list[i] as {string: any}
                            local js = ctrl.joystick as {string: any}
                            local jsName = "(no joystick)"
                            if js then
                                local getName = js.getName as function(any): string
                                local okName, nm = pcall(getName, js)
                                jsName = okName and nm or "(unknown)"
                            end
                            popup[#popup + 1] = "  " .. tostring(i) .. "\t" .. jsName
                            rows[#rows + 1] = {index = i, joystick = jsName}
                        end
                        return {ok = true, popup = popup,
                            data = {count = #list, controllers = rows}}
                    end,
                },
                {
                    name = "info",
                    shortHelp = "show a controller's joystick, deadzone, and bindings",
                    schema = { args = { id = {required = true, kind = "number", help = "controller index"} },
                        positional = {"id"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local mgr = controllerManager()
                        if not mgr then
                            return {ok = false, code = "no_controllers", message = "controllers: plugin not installed"}
                        end
                        local list = mgr.controllers as {any}
                        local idx = math.floor(v.id as number)
                        local ctrl = list[idx] as {string: any}
                        if not ctrl then
                            return {ok = false, code = "no_match",
                                message = "controllers info: no controller " .. tostring(idx)}
                        end
                        local js = ctrl.joystick as {string: any}
                        local jsName = "(none)"
                        if js then
                            local getName = js.getName as function(any): string
                            local okName, nm = pcall(getName, js)
                            jsName = okName and nm or "(unknown)"
                        end
                        local popup: {string} = {
                            "controller " .. tostring(idx),
                            "  joystick\t" .. jsName,
                            format("  deadzone\t%.2f", (ctrl.deadzone as number) or 0),
                            "  auto-assign\t" .. (ctrl.auto and "yes" or "no"),
                            "Bindings:",
                        }
                        local bindings = ctrl.bindings as {string: {string}}
                        local actions: {string} = {}
                        for action in pairs(bindings or {}) do actions[#actions + 1] = action end
                        table.sort(actions)
                        for i = 1, #actions do
                            popup[#popup + 1] = "  " .. actions[i] .. "\t" ..
                                table.concat(bindings[actions[i]], ", ")
                        end
                        return {ok = true, popup = popup,
                            data = {id = idx, joystick = jsName,
                                deadzone = ctrl.deadzone, auto = ctrl.auto, bindings = bindings}}
                    end,
                },
                {
                    name = "rumble",
                    shortHelp = "vibrate a controller's joystick to verify it",
                    schema = { args = {
                        id = {required = true, kind = "number", help = "controller index"},
                        seconds = {default = 0.5, help = "vibration duration"},
                    }, positional = {"id", "seconds"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local mgr = controllerManager()
                        if not mgr then
                            return {ok = false, code = "no_controllers", message = "controllers: plugin not installed"}
                        end
                        local ctrl = (mgr.controllers as {any})[math.floor(v.id as number)] as {string: any}
                        if not ctrl then
                            return {ok = false, code = "no_match",
                                message = "controllers rumble: no controller " .. tostring(v.id)}
                        end
                        local js = ctrl.joystick as {string: any}
                        if not js then
                            return {ok = false, code = "no_joystick",
                                message = "controllers rumble: controller " .. tostring(v.id) ..
                                    " has no joystick assigned"}
                        end
                        local vib = js.setVibration as function(any, number, number, number): boolean
                        local okVib = pcall(vib, js, 1, 1, v.seconds as number)
                        return {ok = true,
                            message = okVib and "rumbling controller " .. tostring(v.id)
                                or "controller " .. tostring(v.id) .. " does not support vibration",
                            data = {id = v.id, supported = okVib}}
                    end,
                },
            },
        },
        {
            name = "assets",
            section = "Engine",
            shortHelp = "list cached assets, show one, or reload one from disk",
            examples = {"assets list", "assets info player.png", "assets reload player.png"},
            subcommands = {
                {
                    name = "list",
                    shortHelp = "list cached asset keys, optionally filtered",
                    schema = { args = { filter = {help = "substring to filter keys"} },
                        positional = {"filter"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local keys, err = assetKeys(v.filter as string)
                        if not keys then
                            return {ok = false, code = "no_assets", message = "assets: " .. err}
                        end
                        local popup: {string} = {"assets  (" .. tostring(#keys) .. "):"}
                        local rows: {{string: any}} = {}
                        for i = 1, #keys do
                            local e = assetEntry(keys[i])
                            rows[#rows + 1] = e
                            popup[#popup + 1] = format("  %s\t%s%s", e.status as string,
                                e.path as string, (e.cached as boolean) and "" or "\t(handle dropped)")
                        end
                        if #keys == 0 then popup[#popup + 1] = "  (none)" end
                        return {ok = true, popup = popup, data = {count = #keys, assets = rows}}
                    end,
                },
                {
                    name = "info",
                    shortHelp = "show a cached asset's action, path, and load state",
                    schema = { args = { path = {required = true, help = "asset path or key substring"} },
                        positional = {"path"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local wanted = v.path as string
                        local keys, err = assetKeys(wanted)
                        if not keys then
                            return {ok = false, code = "no_assets", message = "assets: " .. err}
                        end
                        if #keys == 0 then
                            return {ok = false, code = "no_match",
                                message = "assets info: nothing loaded matching '" .. wanted .. "'"}
                        end
                        local e = assetEntry(keys[1])
                        return {ok = true, popup = {
                            "asset " .. keys[1],
                            "  action\t" .. tostring(e.action),
                            "  path\t" .. tostring(e.path),
                            "  status\t" .. tostring(e.status),
                            "  live handle\t" .. ((e.cached as boolean) and "yes" or "no (dropped)"),
                        }, data = e}
                    end,
                },
                {
                    name = "reload",
                    shortHelp = "re-read matching cached assets from disk in place",
                    schema = { args = { path = {required = true, help = "asset path or key substring"} },
                        positional = {"path"} },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local wanted = v.path as string
                        local keys, err = assetKeys(wanted)
                        if not keys then
                            return {ok = false, code = "no_assets", message = "assets: " .. err}
                        end
                        if #keys == 0 then
                            return {ok = false, code = "no_match",
                                message = "assets reload: nothing cached matching '" .. wanted .. "'"}
                        end
                        local mgr = assetManager()
                        local cache = mgr._cache as {string: any}
                        local assetLog = mgr._assetLog as {string: {string: any}}
                        local reloaded: {string} = {}
                        local skipped = 0
                        for i = 1, #keys do
                            local key = keys[i]
                            if reloadAssetHandle(mgr, cache[key] as {string: any}) then
                                reloaded[#reloaded + 1] = key
                                local logged = assetLog and assetLog[key]
                                if logged then logged.status = "loading" end
                            else
                                skipped = skipped + 1
                            end
                        end
                        if #reloaded == 0 then
                            return {ok = false, code = "not_reloadable",
                                message = "assets reload: no live handle to re-queue (the game" ..
                                    " dropped its handles, or the loader is custom)"}
                        end
                        debugcontext.pushEvent(ctx, "edit", {assetsReloaded = #reloaded})
                        return {ok = true,
                            message = "reloading " .. tostring(#reloaded) .. " asset(s)" ..
                                ((skipped > 0) and (", skipped " .. tostring(skipped)) or "") ..
                                "; handles refresh in place when the load settles",
                            data = {reloaded = reloaded, skipped = skipped}}
                    end,
                },
            },
        },
        {
            name = "audio",
            section = "Engine",
            shortHelp = "audio info; stop everything or mute the master group",
            examples = {"audio info", "audio stop", "audio mute", "audio mute off"},
            subcommands = {
                {
                    name = "info",
                    shortHelp = "show active sources per group and the master volume",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local mgr = audioManager()
                        if not mgr then
                            return {ok = false, code = "no_audio", message = "audio: manager not installed"}
                        end
                        local mgrAny = mgr as {string: any}
                        local active = mgrAny._activeSources as {any: any}
                        local byGroup: {string: integer} = {}
                        local total = 0
                        for _, info in pairs(active or {}) do
                            total = total + 1
                            local g = tostring((info as {string: any}).group or "?")
                            byGroup[g] = (byGroup[g] or 0) + 1
                        end
                        local getVol = mgrAny.getGroupVolume as function(any, string): number
                        local popup: {string} = {
                            "audio",
                            "  active sources\t" .. tostring(total),
                            format("  master volume\t%.2f", getVol(mgr, "master")),
                        }
                        local groups: {string} = {}
                        for g in pairs(byGroup) do groups[#groups + 1] = g end
                        table.sort(groups)
                        for i = 1, #groups do
                            popup[#popup + 1] = "  " .. groups[i] .. "\t" .. tostring(byGroup[groups[i]]) .. " playing"
                        end
                        return {ok = true, popup = popup,
                            data = {active = total, groups = byGroup, masterVolume = getVol(mgr, "master")}}
                    end,
                },
                {
                    name = "stop",
                    shortHelp = "stop every active source",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local mgr = audioManager()
                        if not mgr then
                            return {ok = false, code = "no_audio", message = "audio: manager not installed"}
                        end
                        local stopAll = (mgr as {string: any}).stopAll as function(any)
                        stopAll(mgr)
                        return {ok = true, message = "stopped all sources", data = {}}
                    end,
                },
                {
                    name = "mute",
                    shortHelp = "silence the master group; `audio mute off` restores",
                    schema = onOffSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local mgr = audioManager()
                        if not mgr then
                            return {ok = false, code = "no_audio", message = "audio: manager not installed"}
                        end
                        local mgrAny = mgr as {string: any}
                        local getVol = mgrAny.getGroupVolume as function(any, string): number
                        local setVol = mgrAny.setGroupVolume as function(any, string, number)
                        local want = v.on as boolean
                        if want == nil then want = getVol(mgr, "master") > 0 end
                        if want then
                            preMuteVolume = getVol(mgr, "master")
                            if preMuteVolume <= 0 then preMuteVolume = 1 end
                            setVol(mgr, "master", 0)
                        else
                            setVol(mgr, "master", preMuteVolume or 1)
                        end
                        return {ok = true, message = want and "audio muted" or "audio unmuted",
                            data = {muted = want}}
                    end,
                },
            },
        },
        {
            name = "fetch",
            section = "Engine",
            complete = {[0] = "components"},
            shortHelp = "fetch entities matching a component query, without selecting them",
            mcpHelp = "Fetch entities matching a component expression ('Enemy -Dead' means has Enemy, lacks Dead) with their serialized component data, without touching the operator's selection. count_only=true answers \"how many match\" with just the count -- the cheapest population check; prefer it whenever you don't need the component data. Give x, y, w, h to restrict to a world-space box (spatial filter via Position when registered, else Transform; the spatial component is always included). Returns up to limit entities plus a truncated flag. Use cmd_query when you want to select the matches instead.",
            schema = fetchSchema,
            examples = {"fetch Transform -Disabled", "fetch Enemy limit=10",
                "fetch Transform x=0 y=0 w=640 h=360"},
            annotations = {readOnlyHint = true, idempotentHint = true},
            outputSchema = {
                type = "object",
                properties = {
                    count = {type = "integer", description = "entities returned"},
                    entities = {type = "array", items = {type = "object", properties = {
                        id = {type = "integer"},
                        archetypeId = {type = "integer",
                            description = "absent in the bounds form"},
                        archetypeComponents = {type = "string",
                            description = "sorted archetype signature; absent in the bounds form"},
                        components = {type = "object",
                            description = "serialized data of the included components"},
                    }}},
                    truncated = {type = "boolean", description = "true when the limit cut the results"},
                    bounds = {type = "object", properties = {
                        x = {type = "number"},
                        y = {type = "number"},
                        width = {type = "number"},
                        height = {type = "number"},
                    }, description = "the spatial filter, when one was given"},
                },
                required = {"count", "entities", "truncated"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local given = 0
                if v.x ~= nil then given = given + 1 end
                if v.y ~= nil then given = given + 1 end
                if v.w ~= nil then given = given + 1 end
                if v.h ~= nil then given = given + 1 end
                if given ~= 0 and given ~= 4 then
                    return {ok = false, code = "invalid_arguments",
                        message = "fetch: bounds need all of x, y, w, h (or none)"}
                end

                local include: {tecs.Component} = {}
                local includeNames: {string} = {}
                local exclude: {tecs.Component} = {}
                for tok in (v.expr as string):gmatch("%S+") do
                    local nm = tok
                    local bucket = "include"
                    if tok:sub(1, 1) == "-" then
                        nm = tok:sub(2)
                        bucket = "exclude"
                    elseif tok:sub(1, 1) == "+" then
                        nm = tok:sub(2)
                    end
                    local comp, cerr = componentFor(nm)
                    if not comp then
                        return {ok = false, code = "unknown_component", message = "fetch: " .. cerr}
                    end
                    if bucket == "include" then
                        include[#include + 1] = comp
                        includeNames[#includeNames + 1] = nm
                    else
                        exclude[#exclude + 1] = comp
                    end
                end
                if #include == 0 then
                    return {ok = false, code = "invalid_arguments",
                        message = "fetch: needs at least one component to include"}
                end
                local limit = math.max(0, math.floor(v.limit as number))

                if given == 0 then
                    -- Component-only form. temp avoids registering a persistent
                    -- query for every call; the loop runs to exhaustion because
                    -- breaking out of query:iter() leaks the query scope.
                    local query = w:query({temp = true, include = include, exclude = exclude})
                    if v.count_only == true then
                        -- "How many match" is the most common verification
                        -- read; answer it without serializing anything.
                        local total = query:count()
                        return {ok = true, message = "fetch matched " .. tostring(total),
                            data = {count = total, entities = {}, truncated = false}}
                    end
                    local results: {{string: any}} = {}
                    local count = 0
                    for archetype, len, entityList in query:iter() do
                        if count < limit then
                            local sig = archetypeSignature(archetype)
                            local archetypeId = archetype.id
                            for row = 1, len do
                                if count >= limit then break end
                                results[#results + 1] = {
                                    id = entityList[row],
                                    archetypeId = archetypeId,
                                    archetypeComponents = sig,
                                    components = entityinfo.serializeRow(archetype, include, row),
                                }
                                count = count + 1
                            end
                        end
                    end
                    return {ok = true,
                        message = "fetch matched " .. tostring(count) ..
                            ((count >= limit) and " (truncated)" or ""),
                        data = {count = count, entities = results, truncated = count >= limit}}
                end

                -- Bounds form. Prefer a game-registered Position component;
                -- tecs's Transform is the ubiquitous fallback.
                local spatial = componentFor("Position")
                local spatialName = "Position"
                if not spatial then
                    spatial = componentFor("Transform")
                    spatialName = "Transform"
                end
                if not spatial then
                    return {ok = false, code = "spatial_component_not_found",
                        message = "fetch: neither Position nor Transform is registered;" ..
                            " bounds need one"}
                end
                local includeComponents: {tecs.Component} = {spatial}
                for i = 1, #include do
                    if includeNames[i] ~= spatialName then
                        includeComponents[#includeComponents + 1] = include[i]
                    end
                end
                local bx = v.x as number
                local by = v.y as number
                local bw = v.w as number
                local bh = v.h as number
                local bx2, by2 = bx + bw, by + bh
                local query = w:query({temp = true, include = includeComponents, exclude = exclude})
                local results: {{string: any}} = {}
                local countOnly = v.count_only == true
                local count = 0
                for archetype, len, entityList in query:iter() do
                    local posColumn = (countOnly or count < limit) and archetype:get(spatial) or nil
                    if posColumn then
                        for row = 1, len do
                            if not countOnly and count >= limit then break end
                            local pos = posColumn[row] as {string: number}
                            local px, py = pos.x, pos.y
                            if px >= bx and px <= bx2 and py >= by and py <= by2 then
                                if not countOnly then
                                    results[#results + 1] = {
                                        id = entityList[row],
                                        components = entityinfo.serializeRow(
                                            archetype, includeComponents, row),
                                    }
                                end
                                count = count + 1
                            end
                        end
                    end
                end
                local truncated = not countOnly and count >= limit
                return {ok = true,
                    message = "fetch matched " .. tostring(count) .. " in bounds" ..
                        (truncated and " (truncated)" or ""),
                    data = {count = count, entities = results, truncated = truncated,
                        bounds = {x = bx, y = by, width = bw, height = bh}}}
            end,
        },
        {
            name = "resources",
            section = "Engine",
            shortHelp = "list world resources; pass a name to read one value",
            mcpHelp = "Without arguments: every world resource as {key, type} -- keys created with "
                .. "tecs.newKey(\"name\") resolve to that name -- plus `unset`, the registered key "
                .. "names holding no value yet. With name=<key name>: that resource's current value, "
                .. "deep-copied to JSON-safe data (live objects render as their tostring). This is "
                .. "the way to read named game state (e.g. a GameState resource) without writing Lua.",
            examples = {"resources", "resources game.state"},
            annotations = {readOnlyHint = true, idempotentHint = true},
            schema = resourcesSchema,
            outputSchema = {
                type = "object",
                properties = {
                    count = {type = "integer"},
                    resources = {type = "array", items = {type = "object", properties = {
                        key = {type = "string", description = "resource key name"},
                        type = {type = "string", description = "value type name"},
                    }}},
                    unset = {type = "array", items = {type = "string"},
                        description = "registered key names with no value (list form)"},
                    key = {type = "string", description = "the requested key (value form)"},
                    set = {type = "boolean", description = "whether the resource holds a value (value form)"},
                    value = {description = "the resource value, JSON-safe (value form)"},
                },
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local named = tecs.listKeys()

                -- Value form: read one named resource.
                if v.name ~= nil then
                    local nm = v.name as string
                    local id = named[nm]
                    if not id then
                        local known: {string} = {}
                        for n in pairs(named) do known[#known + 1] = n end
                        table.sort(known)
                        return {ok = false, code = "unknown_key",
                            message = "resources: no key named '" .. nm .. "'; named keys: "
                                .. table.concat(known, ", ")}
                    end
                    local value = (w.resources as {any: any})[id]
                    return {ok = true,
                        popup = {"resource " .. nm .. " (" .. type(value) .. ")"},
                        data = {key = nm, set = value ~= nil,
                            value = sanitize.value(value)}}
                end

                local reverse: {integer: string} = {}
                for n, id in pairs(named) do reverse[id] = n end

                local resources = w.resources as {any: any}
                local rows: {{string: any}} = {}
                for key, value in pairs(resources) do
                    local keyStr: string
                    if type(key) == "table" and (key as {string: any}).name then
                        keyStr = (key as {string: any}).name as string
                    elseif type(key) == "number" and reverse[key as integer] then
                        keyStr = reverse[key as integer]
                    else
                        keyStr = tostring(key)
                    end
                    local valueType: string
                    if type(value) == "table" and getmetatable(value) then
                        local mt = getmetatable(value) as {string: any}
                        if mt.__name then
                            valueType = mt.__name as string
                        elseif mt.__index and type(mt.__index) == "table"
                            and (mt.__index as {string: any}).__name then
                            valueType = (mt.__index as {string: any}).__name as string
                        else
                            valueType = "table"
                        end
                    else
                        valueType = type(value)
                    end
                    rows[#rows + 1] = {key = keyStr, type = valueType}
                end
                table.sort(rows, function(a: {string: any}, b: {string: any}): boolean
                    return (a.key as string) < (b.key as string)
                end)

                -- Named keys with no value: still worth surfacing, so an agent
                -- learns the name exists before the game first sets it.
                local unset: {string} = {}
                for n, id in pairs(named) do
                    if resources[id] == nil then unset[#unset + 1] = n end
                end
                table.sort(unset)

                local popup: {string} = {"resources  (" .. tostring(#rows) .. "):"}
                for i = 1, #rows do
                    popup[#popup + 1] = "  " .. tostring(rows[i].key) .. "\t" ..
                        tostring(rows[i].type)
                end
                return {ok = true, popup = popup,
                    data = {count = #rows, resources = rows, unset = unset}}
            end,
        },
        {
            name = "bundles",
            section = "Engine",
            shortHelp = "list registered bundles or spawn an entity from one",
            examples = {"bundles list", "bundles spawn enemy",
                "bundles spawn enemy {Transform = {x = 10, y = 5}}"},
            subcommands = {
                {
                    name = "list",
                    aliases = {"ls"},
                    shortHelp = "list bundles with their required and defaulted components",
                    mcpHelp = "Registered bundles as a map of name to component requirements: required components must be provided at spawn, defaulted ones fill in automatically. Pair with cmd_bundles_spawn.",
                    outputSchema = {
                        type = "object",
                        properties = {
                            bundles = {type = "object",
                                additionalProperties = {type = "object", properties = {
                                    required = {type = "array", items = {type = "string"},
                                        description = "components that must be provided at spawn"},
                                    defaulted = {type = "array", items = {type = "string"},
                                        description = "components filled from defaults"},
                                }},
                                description = "bundle name to its component requirements"},
                        },
                        required = {"bundles"},
                    },
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local bundles = w:getBundles()
                        local result: {string: {string: any}} = {}
                        local names: {string} = {}
                        for name, bundle in pairs(bundles) do
                            local bndl = bundle as tecs.Bundle
                            result[name] = {required = bndl.required, defaulted = bndl.defaulted}
                            names[#names + 1] = name
                        end
                        if #names == 0 then
                            return {ok = true, message = "no bundles registered",
                                data = {bundles = json.EMPTY_OBJECT as {string: any}}}
                        end
                        table.sort(names)
                        local popup: {string} = {"bundles  (" .. tostring(#names) .. "):"}
                        for i = 1, #names do
                            local b = bundles[names[i]] as tecs.Bundle
                            local bits: {string} = {}
                            if #b.required > 0 then
                                bits[#bits + 1] = "required: " .. table.concat(b.required, ", ")
                            end
                            if #b.defaulted > 0 then
                                bits[#bits + 1] = "defaulted: " .. table.concat(b.defaulted, ", ")
                            end
                            popup[#popup + 1] = "  " .. names[i] .. "\t" .. table.concat(bits, "; ")
                        end
                        return {ok = true, popup = popup, data = {bundles = result}}
                    end,
                },
                {
                    name = "spawn",
                    complete = {[1] = "bundles"},
                    shortHelp = "spawn an entity from a bundle with optional component overrides",
                    mcpHelp = "Spawn one entity from a registered bundle. components is a map of component name to field data; the bundle's required components must be provided there. Returns the new entity id. Unlike cmd_spawn this does not select the entity.",
                    schema = bundleSpawnSchema,
                    examples = {"bundles spawn enemy",
                        "bundles spawn enemy {Transform = {x = 10, y = 5}}"},
                    outputSchema = {
                        type = "object",
                        properties = {
                            id = {type = "integer", description = "the new entity"},
                        },
                        required = {"id"},
                    },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local bundleName = v.name as string
                        local overrides, verr = parseTableArg(v.components)
                        if verr then
                            return {ok = false, code = "invalid_arguments",
                                message = "bundles spawn: " .. verr}
                        end
                        local instances: {tecs.Component} = {}
                        for compName, compData in pairs(overrides or {}) do
                            local comp, cerr = componentFor(compName)
                            if not comp then
                                return {ok = false, code = "unknown_component",
                                    message = "bundles spawn: " .. cerr}
                            end
                            local okD, res = pcall(function(): tecs.Component
                                return comp.deserialize(w, compData as {string: any})
                            end)
                            if not okD then
                                return {ok = false, code = "component_deserialize_failed",
                                    message = "bundles spawn: " .. compName .. ": " .. tostring(res)}
                            end
                            instances[#instances + 1] = res as tecs.Component
                        end
                        local okS, spawnedOrErr = pcall(function(): integer
                            return w:spawnBundle(bundleName, table.unpack(instances))
                        end)
                        if not okS then
                            return {ok = false, code = "spawn_bundle_failed",
                                message = "bundles spawn failed: " .. tostring(spawnedOrErr)}
                        end
                        local id = spawnedOrErr as integer
                        debugcontext.pushEvent(ctx, "spawn", {id = id, bundle = bundleName})
                        return {ok = true,
                            message = "spawned #" .. tostring(id) .. " from " .. bundleName,
                            data = {id = id}}
                    end,
                },
            },
        },
    }
end

return engine
