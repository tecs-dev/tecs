--- Core ECS debugger commands: systems, archetypes, components, and states.

local tecs <const> = require("tecs")
local componentregistry <const> = require("tecs.internal.components")
local entityinfo <const> = require("tecs2d.internal.entityinfo")
local systemcontrol <const> = require("tecs2d.internal.systemcontrol")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")
local markup <const> = require("tecs2d.debug.internal.markup")

local format <const> = string.format

local record engineecs
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

local systemNameSchema <const>: cmdargs.Schema = {
    args = { name = {required = true, completion = "systems",
        help = "system name (see `systems`)"} },
    positional = {"name"},
}

function engineecs.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    local w <const> = d.world
    local ctx <const> = d.ctx
    local componentFor <const> = d.componentFor

    local function systemsList(): cmdtypes.Result
        local infos = systemcontrol.list(w)
        local popup: {string} = {"systems  (" .. tostring(#infos) .. "):"}
        for i = 1, #infos do
            local info = infos[i]
            popup[#popup + 1] = "  " .. info.name .. "\\t" .. info.phase ..
                (info.enabled and "" or "\\tstopped")
        end
        local data: {{string: any}} = {}
        for i = 1, #infos do
            data[i] = {name = infos[i].name, phase = infos[i].phase,
                enabled = infos[i].enabled}
        end
        return {ok = true, popup = popup,
            data = {count = #infos, systems = data}}
    end

    local function setSystemEnabled(name: string, enabled: boolean): cmdtypes.Result
        local ok, err = systemcontrol.setEnabled(w, name, enabled)
        if not ok then
            return {ok = false, code = "system_not_found",
                message = "systems: " .. err}
        end
        return {
            ok = true,
            message = (enabled and "started " or "stopped ") .. name,
            data = {name = name, enabled = enabled},
        }
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
                    shortHelp = "list every system with its phase and state",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        return systemsList()
                    end,
                },
                {
                    name = "stop",
                    shortHelp = "disable a system by name",
                    schema = systemNameSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        return setSystemEnabled(v.name as string, false)
                    end,
                },
                {
                    name = "start",
                    shortHelp = "re-enable a stopped system",
                    schema = systemNameSchema,
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        return setSystemEnabled(v.name as string, true)
                    end,
                },
                {
                    name = "toggle",
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
                    shortHelp = "show a component's schema by name or id",
                    schema = { args = { name = {required = true,
                        completion = "components", help = "component name or id"} },
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
                        local document = markup.new("component " .. tostring(schema.name))
                        markup.text(document, "id  " .. tostring(schema.id))
                        markup.text(document, "storage  " .. schema.kind)
                        markup.text(document, "serializable  " ..
                            (schema.serializable and "yes" or "no"))
                        if #schema.fields > 0 then
                            markup.section(document, "Fields")
                            for i = 1, #schema.fields do
                                local f = schema.fields[i]
                                local def = schema.defaults and schema.defaults[f.name]
                                markup.definition(document, f.name, f.type ..
                                    ((def ~= nil) and (" = " .. tostring(def)) or ""))
                            end
                        end
                        return {ok = true, popupDocument = document,
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
            shortHelp = "show the state stack",
            examples = {"states info"},
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
            },
        },
    }
end

return engineecs
