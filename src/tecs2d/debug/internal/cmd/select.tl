--- Select-section debugger commands: select, clear, mark, goto, note, info,
--- despawn, query, and ids, plus the selection helpers they share (query
--- expression matching, entity inspection, and mark grouping).
---
--- Everything shared with the core registry arrives through cmdtypes.Deps;
--- this module must not require tecs2d.debug.commands (a load cycle).

local tecs <const> = require("tecs")
local json <const> = require("tecs.utils.json")
local entityinfo <const> = require("tecs2d.internal.entityinfo")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

local Transform <const> = tecs.builtins.Transform

local record selectcmds
    --- The Select-section commands, in display order.
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

local querySchema <const>: cmdargs.Schema = {
    args = {
        expr = {rest = true, required = true,
            help = "component names separated by spaces; -Foo excludes"},
        invert = {default = false,
            help = "de-select the selected entities that match, instead of adding"},
    },
    positional = {"expr"},
}
cmdargs.validate(querySchema)

local noteSchema <const>: cmdargs.Schema = {
    args = {
        msg = {rest = true, help = "note text; omit to clear notes on the selection"},
    },
    positional = {"msg"},
}
cmdargs.validate(noteSchema)

local idsSchema <const>: cmdargs.Schema = {
    args = { on = {kind = "boolean", help = "show or hide; omit to toggle"} },
    positional = {"on"},
}
cmdargs.validate(idsSchema)

function selectcmds.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    -- The shared context, aliased once so command bodies stay terse.
    local w <const> = d.world
    local ctx <const> = d.ctx
    local reg <const> = d.reg
    local pipeline <const> = d.pipeline
    local resolveTargets <const> = d.resolveTargets
    local targetSchema <const> = d.targetSchema
    local optionalTargetSchema <const> = d.optionalTargetSchema

    -- select's target plus a replace flag (replace the selection instead of adding).
    local selectSchema <const> = d.makeTargetSchema(true, {
        replace = {default = false, help = "replace the selection instead of adding to it"},
    })

    -- Archetype signature membership by component identity. Column access
    -- (arch:get) returns nil for tag components, so scan componentList.
    local function archHas(arch: tecs.Archetype, comp: tecs.Component): boolean
        local list = arch.componentList
        for i = 1, #list do
            if list[i] == comp then return true end
        end
        return false
    end

    -- query expr: bare names must be present, -Name must be absent. With
    -- invert, refine instead of add: de-select the currently selected
    -- entities that match the expression.
    local function runQuery(expr: string, invert: boolean): cmdtypes.Result
        local include: {tecs.Component} = {}
        local exclude: {tecs.Component} = {}
        for tok in expr:gmatch("%S+") do
            local name = tok
            local bucket = "include"
            if tok:sub(1, 1) == "-" then
                name = tok:sub(2)
                bucket = "exclude"
            elseif tok:sub(1, 1) == "+" then
                name = tok:sub(2)
            end
            local ok, resolved = pcall(tecs.componentByName, name)
            local comp = (ok and resolved) as tecs.Component
            if not comp then
                return {ok = false, code = "unknown_component",
                    message = "query: unknown component '" .. name .. "'"}
            end
            if bucket == "include" then
                include[#include + 1] = comp
            else
                exclude[#exclude + 1] = comp
            end
        end
        if #include == 0 then
            return {ok = false, code = "invalid_arguments",
                message = "query: needs at least one component to include"}
        end

        local function archMatches(arch: tecs.Archetype): boolean
            for i = 1, #include do
                if not archHas(arch, include[i]) then return false end
            end
            for i = 1, #exclude do
                if archHas(arch, exclude[i]) then return false end
            end
            return true
        end

        if invert then
            -- Refinement: drop selected entities whose archetype matches.
            local kept: {integer} = {}
            local removed = 0
            for i = 1, #ctx.selected do
                local eid = ctx.selected[i]
                local arch = entityinfo.locate(w, eid)
                if arch and archMatches(arch) then
                    removed = removed + 1
                else
                    kept[#kept + 1] = eid
                end
            end
            ctx.selected = kept
            debugcontext.pushEvent(ctx, "selection",
                {selected = #kept, deselected = removed})
            return {ok = true, message = "deselected " .. tostring(removed),
                data = {deselected = removed, selected = #kept}}
        end

        local seen: {integer: boolean} = {}
        for i = 1, #ctx.selected do seen[ctx.selected[i]] = true end
        local count = 0
        w:forEachArchetype(function(arch: tecs.Archetype)
            local n = arch.entities[0] as integer
            if n == 0 or not archMatches(arch) then return end
            for row = 1, n do
                local eid = arch.entities[row] as integer
                if not seen[eid] then
                    seen[eid] = true
                    ctx.selected[#ctx.selected + 1] = eid
                end
                count = count + 1
            end
        end)
        debugcontext.pushEvent(ctx, "selection", {selected = #ctx.selected, matched = count})
        return {ok = true, message = "query matched " .. tostring(count),
            data = {matched = count, selected = #ctx.selected}}
    end

    -- Build display lines for an entity: a header plus one line per component
    -- with its serialized field values.
    local function inspectEntity(eid: integer): {string}
        local archetype, row, why = entityinfo.locate(w, eid)
        if not archetype then
            return {"#" .. tostring(eid) ..
                (why == "not_alive" and " is not alive" or " is not committed")}
        end
        local lines: {string} = {"entity #" .. tostring(eid)}
        local compList = archetype.componentList
        for i = 1, #compList do
            local comp = compList[i]
            local cname = comp.componentName
            if cname then
                local rendered = false
                if comp.serialize then
                    local column = archetype:get(comp) as {any}
                    local instance = column and column[row]
                    if instance ~= nil then
                        local serfn = comp.serialize as function(any): {string: any}
                        local ok, serialized = pcall(serfn, instance)
                        if ok and serialized then
                            lines[#lines + 1] = cname .. ":"
                            local pretty = json.serializePretty(serialized, true)
                            for jline in (pretty .. "\n"):gmatch("(.-)\n") do
                                lines[#lines + 1] = "  " .. jline
                            end
                            rendered = true
                        end
                    end
                end
                if not rendered then
                    lines[#lines + 1] = cname
                end
            end
        end
        return lines
    end

    -- Marks grouped for display and data: name -> {count, first id}.
    local function markGroups(): {string: {string: integer}}
        local groups: {string: {string: integer}} = {}
        for eid, mn in pairs(ctx.marks) do
            if w:isAlive(eid) then
                local g = groups[mn]
                if not g then
                    g = {count = 0, first = eid}
                    groups[mn] = g
                end
                g.count = g.count + 1
                if eid < g.first then g.first = eid end
            end
        end
        return groups
    end

    local function markLines(groups: {string: {string: integer}}): {string}
        local lines: {string} = {}
        for mn, g in pairs(groups) do
            lines[#lines + 1] = "  " .. mn .. "\t(" .. tostring(g.count) .. ")\t#" .. tostring(g.first)
        end
        table.sort(lines)
        return lines
    end

    return {
        {
            name = "select",
            section = "Select",
            complete = {[1] = "targets"},
            examples = {"select 5", "select boss", "select 5 replace", "select name=\"big boss\""},
            shortHelp = "select an entity by id, or all entities with a mark name",
            mcpHelp = "Add an entity (by id) or a marked group (by name) to the operator-visible selection; replace=true swaps the selection instead. Selected entities are highlighted in-game. Returns the selection size. Follow with debug_info for component data or debug_note to annotate.",
            schema = selectSchema,
            metadata = {screenshots = {
                {file = "./assets/debug/select.png", docs = true,
                    alt = "The debugger with a select command typed: the usage popup shows the signature and arguments, and the selected entity is ringed by gold markers"},
            }},
            outputSchema = {
                type = "object",
                properties = {
                    selected = {type = "integer", description = "selection size after the call"},
                    added = {type = "array", items = {type = "integer"},
                        description = "entity ids added to the selection"},
                },
                required = {"added", "selected"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local ids = resolveTargets(v)
                local live: {integer} = {}
                for i = 1, #ids do
                    if w:isAlive(ids[i]) then live[#live + 1] = ids[i] end
                end
                if #live == 0 then
                    return {ok = false, code = "no_match",
                        message = "select: no live match for '" .. tostring(v.target) .. "'. Use `mark list`."}
                end
                if v.replace as boolean then
                    ctx.selected = {}
                end
                for i = 1, #live do
                    debugcontext.addSelected(ctx, live[i])
                end
                debugcontext.pushEvent(ctx, "selection", {selected = #ctx.selected})
                return {ok = true, message = "selected " .. tostring(#live),
                    data = {selected = #ctx.selected, added = live}}
            end,
        },
        {
            name = "clear",
            section = "Select",
            shortHelp = "clear the selection, message, and drag area",
            outputSchema = {
                type = "object",
                properties = {
                    selected = {type = "integer", description = "always 0"},
                },
                required = {"selected"},
            },
            run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                ctx.selected = {}
                ctx.hasArea = false
                debugcontext.pushEvent(ctx, "selection", {selected = 0})
                return {ok = true, message = "", data = {selected = 0}}
            end,
        },
        {
            name = "mark",
            section = "Select",
            shortHelp = "name the selected entities so select, goto, and despawn can recall them by name",
            mcpHelp = "Name the currently selected entities so later commands (select, goto, despawn, diff entity=) can address the group by that name. Marks survive until cleared. Returns the marked count.",
            schema = { args = { name = {help = "mark name; omit to unmark the selection"} }, positional = {"name"} },
            examples = {"mark boss", "mark \"big boss\"", "mark  (unmark selection)", "mark ls"},
            outputSchema = {
                type = "object",
                properties = {
                    marked = {type = "integer", description = "entities marked"},
                    name = {type = "string"},
                    unmarked = {type = "integer", description = "entities unmarked when no name given"},
                },
            },
            subcommands = {
                {
                    name = "list",
                    aliases = {"ls"},
                    shortHelp = "show every mark with its count and first id",
                    outputSchema = {
                        type = "object",
                        properties = {
                            marks = {type = "object",
                                additionalProperties = {type = "object", properties = {
                                    count = {type = "integer", description = "live entities with the mark"},
                                    first = {type = "integer", description = "lowest live entity id"},
                                }},
                                description = "mark name to its live count and first entity id"},
                        },
                        required = {"marks"},
                    },
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        local groups = markGroups()
                        local lines = markLines(groups)
                        if #lines == 0 then
                            return {ok = true, message = "no marks yet", data = {marks = json.EMPTY_OBJECT as {string: any}}}
                        end
                        local popup: {string} = {"marks  (type to dismiss):"}
                        for i = 1, #lines do popup[#popup + 1] = lines[i] end
                        return {ok = true, popup = popup, data = {marks = groups}}
                    end,
                },
                {
                    name = "clear",
                    aliases = {"rm"},
                    shortHelp = "remove all marks",
                    run = function(_v: {string: any}, _parts: {string}): cmdtypes.Result
                        ctx.marks = {}
                        debugcontext.pushEvent(ctx, "mark", {cleared = true})
                        return {ok = true, message = "cleared all marks", data = {}}
                    end,
                },
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                if #ctx.selected == 0 then
                    return {ok = false, code = "nothing_selected", message = "mark: nothing selected"}
                end
                local name = v.name as string
                if not name then
                    for i = 1, #ctx.selected do ctx.marks[ctx.selected[i]] = nil end
                    debugcontext.pushEvent(ctx, "mark", {unmarked = #ctx.selected})
                    return {ok = true, message = "unmarked " .. tostring(#ctx.selected),
                        data = {unmarked = #ctx.selected}}
                end
                -- Numeric names are unreachable later: target resolution binds
                -- numbers to entity ids before mark names.
                if tonumber(name) then
                    return {ok = false, code = "invalid_name",
                        message = "mark: numeric names collide with entity ids; pick a word"}
                end
                for i = 1, #ctx.selected do ctx.marks[ctx.selected[i]] = name end
                debugcontext.pushEvent(ctx, "mark", {name = name, marked = #ctx.selected})
                return {ok = true, message = "marked " .. tostring(#ctx.selected) .. " as " .. name,
                    data = {marked = #ctx.selected, name = name}}
            end,
        },
        {
            name = "goto",
            section = "Select",
            complete = {[1] = "targets"},
            examples = {"goto 5", "goto boss"},
            shortHelp = "move the camera to an entity by id, or the first with a mark name",
            schema = targetSchema,
            outputSchema = {
                type = "object",
                properties = {
                    id = {type = "integer", description = "the entity moved to"},
                    x = {type = "number"},
                    y = {type = "number"},
                },
                required = {"id", "x", "y"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local ids = resolveTargets(v)
                local firstId = 0
                for i = 1, #ids do
                    local eid = ids[i]
                    if w:isAlive(eid) and (firstId == 0 or eid < firstId) then firstId = eid end
                end
                if firstId == 0 then
                    return {ok = false, code = "no_match",
                        message = "goto: no live entity for '" .. tostring(v.target) .. "'. Use `mark list`."}
                end
                local t = w:get(firstId, Transform)
                if not t then
                    return {ok = false, code = "no_transform",
                        message = "goto: #" .. tostring(firstId) .. " has no Transform to move to"}
                end
                local p = pipeline()
                if not p then
                    return {ok = false, code = "no_pipeline",
                        message = "goto: no render pipeline, camera not moved"}
                end
                p:getCamera():setPosition(t.x, t.y)
                return {ok = true, message = "goto -> #" .. tostring(firstId),
                    data = {id = firstId, x = t.x, y = t.y}}
            end,
        },
        {
            name = "note",
            section = "Select",
            shortHelp = "annotate the selected entities for the agent; empty message clears",
            mcpHelp = "Attach a note to the selected entities, visible in-game above them and in get_debug_context. Use it to flag findings for the operator. An empty message clears notes on the selection.",
            schema = noteSchema,
            examples = {"note flickers when hit", "note  (clear notes)"},
            outputSchema = {
                type = "object",
                properties = {
                    noted = {type = "integer", description = "entities annotated"},
                    msg = {type = "string"},
                    cleared = {type = "integer", description = "entities whose notes were cleared"},
                },
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local msg = (v.msg as string) or ""
                if #ctx.selected == 0 then
                    return {ok = false, code = "nothing_selected", message = "note: nothing selected"}
                elseif msg == "" then
                    for i = 1, #ctx.selected do ctx.notes[ctx.selected[i]] = nil end
                    debugcontext.pushEvent(ctx, "note", {cleared = #ctx.selected})
                    return {ok = true, message = "cleared notes on " .. tostring(#ctx.selected),
                        data = {cleared = #ctx.selected}}
                end
                for i = 1, #ctx.selected do ctx.notes[ctx.selected[i]] = msg end
                debugcontext.pushEvent(ctx, "note", {noted = #ctx.selected, msg = msg})
                return {ok = true, message = "noted " .. tostring(#ctx.selected),
                    data = {noted = #ctx.selected, msg = msg}}
            end,
        },
        {
            name = "info",
            section = "Select",
            mcp = false,   -- agents use the get_entity MCP tool instead
            complete = {[1] = "targets"},
            shortHelp = "show an entity's components; defaults to the first selected",
            schema = optionalTargetSchema,
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local target = 0
                if v.target == nil then
                    target = ctx.selected[1] or 0
                else
                    local ids = resolveTargets(v)
                    for i = 1, #ids do
                        local eid = ids[i]
                        if w:isAlive(eid) and (target == 0 or eid < target) then target = eid end
                    end
                end
                if target == 0 then
                    return {ok = false, code = "no_match",
                        message = (v.target ~= nil) and ("info: no match for '" .. tostring(v.target) .. "'")
                            or "info: nothing selected"}
                end
                return {ok = true, popup = inspectEntity(target)}
            end,
        },
        {
            name = "despawn",
            section = "Select",
            complete = {[1] = "targets"},
            shortHelp = "despawn an entity by id or mark name, or the whole selection",
            mcpHelp = "Despawn the target entities (an id, a mark name, or the current selection when no target is given). Destructive and immediate. Take debug_snapshot_save first if the state matters.",
            schema = optionalTargetSchema,
            outputSchema = {
                type = "object",
                properties = {
                    despawned = {type = "integer"},
                    ids = {type = "array", items = {type = "integer"},
                        description = "despawned entity ids (absent for selection despawns)"},
                },
                required = {"despawned"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                if v.target == nil then
                    local n = reg:despawnSelected()
                    return {ok = true, message = "despawned " .. tostring(n) .. " selected",
                        data = {despawned = n}}
                end
                local ids = resolveTargets(v)
                local killed: {integer} = {}
                for i = 1, #ids do
                    local eid = ids[i]
                    if w:isAlive(eid) then
                        debugcontext.removeSelected(ctx, eid)
                        w:despawn(eid)
                        ctx.marks[eid] = nil
                        ctx.notes[eid] = nil
                        killed[#killed + 1] = eid
                    end
                end
                if #killed == 0 then
                    return {ok = false, code = "no_match",
                        message = "despawn: no live match for '" .. tostring(v.target) .. "'"}
                end
                debugcontext.pushEvent(ctx, "selection", {selected = #ctx.selected, despawned = #killed})
                return {ok = true, message = "despawned " .. tostring(#killed),
                    data = {despawned = #killed, ids = killed}}
            end,
        },
        {
            name = "query",
            section = "Select",
            aliases = {"q"},
            complete = {[0] = "components"},
            shortHelp = "select entities matching a component query: Foo has it, -Foo lacks it",
            mcpHelp = "Select every entity matching a component expression ('Enemy -Dead' means has Enemy, lacks Dead); invert=true instead de-selects matching entities from the current selection. Returns the match count. Follow with debug_info or debug_set on @selection.",
            schema = querySchema,
            examples = {"query Position Velocity -Dead",
                "query Dead invert=true  (de-select dead entities)"},
            outputSchema = {
                type = "object",
                properties = {
                    matched = {type = "integer", description = "entities matching the expression"},
                    deselected = {type = "integer", description = "matches removed when invert=true"},
                    selected = {type = "integer", description = "selection size after the call"},
                },
                required = {"selected"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                return runQuery(v.expr as string, v.invert as boolean)
            end,
        },
        {
            name = "ids",
            section = "Select",
            shortHelp = "toggle entity id labels over on-screen entities",
            schema = idsSchema,
            examples = {"ids", "ids on", "ids off"},
            outputSchema = {
                type = "object",
                properties = {
                    shown = {type = "boolean", description = "label state after the call"},
                },
                required = {"shown"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local want = v.on as boolean
                if want == nil then want = not ctx.showIds end
                ctx.showIds = want
                return {ok = true,
                    message = want and "entity ids on (up to 200 labels)" or "entity ids off",
                    data = {shown = want}}
            end,
        },
    }
end

return selectcmds
