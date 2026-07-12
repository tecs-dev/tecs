--- Edit-section debugger commands: remove, set, modify, spawn, and draw,
--- plus the mutation helpers they share (edit-target resolution, Lua table
--- expression evaluation, field merging, and the draw-verb schemas).
---
--- Everything shared with the core registry arrives through cmdtypes.Deps;
--- this module must not require tecs2d.debug.commands (a load cycle).

local tecs <const> = require("tecs")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local annotations <const> = require("tecs2d.debug.internal.annotations")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

local record edit
    --- The Edit-section commands, in display order.
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

-- Shared arguments of every draw verb, plus the verb's own positionals.
local function makeDrawSchema(extra: {string: cmdargs.ArgSpec}, positional: {string}): cmdargs.Schema
    local args: {string: cmdargs.ArgSpec} = {
        x = {default = 0, help = "world x (an offset when entity is set)"},
        y = {default = 0, help = "world y (an offset when entity is set)"},
        r = {kind = "number", help = "red 0-1 (default 1)"},
        g = {kind = "number", help = "green 0-1 (default 1)"},
        b = {kind = "number", help = "blue 0-1 (default 0)"},
        a = {kind = "number", help = "alpha 0-1 (default 0.8)"},
        tag = {help = "tag for grouped clearing"},
        seconds = {kind = "number", help = "auto-remove after N wall-clock seconds; 0 = one frame"},
        entity = {kind = "number", help = "pin to this entity: positions become offsets; removed when it dies"},
        -- Named stroke, not width: rect already has a `w` size argument.
        stroke = {default = 4, help = "outline width in pixels"},
    }
    for k, v in pairs(extra) do args[k] = v end
    local schema: cmdargs.Schema = {args = args, positional = positional}
    cmdargs.validate(schema)
    return schema
end

local drawRectSchema <const> = makeDrawSchema({
    w = {required = true, kind = "number", help = "width in world units"},
    h = {required = true, kind = "number", help = "height in world units"},
}, {"x", "y", "w", "h"})

local drawCircleSchema <const> = makeDrawSchema({
    radius = {required = true, kind = "number", help = "radius in world units"},
}, {"x", "y", "radius"})

local drawLineSchema <const> = makeDrawSchema({
    x2 = {required = true, kind = "number", help = "end world x (an offset when entity is set)"},
    y2 = {required = true, kind = "number", help = "end world y (an offset when entity is set)"},
}, {"x", "y", "x2", "y2"})

local drawTextSchema <const> = makeDrawSchema({
    msg = {rest = true, required = true, help = "text to display"},
    fontSize = {default = 14, help = "font size in pixels"},
}, {"x", "y", "msg"})

-- Clear by tag or id, or everything when omitted.
local drawClearSchema <const>: cmdargs.Schema = {
    args = {
        id = {kind = "number", forward = "which", help = "annotation id"},
        tag = {forward = "which", help = "annotation tag"},
        which = {synthetic = {"id", "tag"}, help = "an annotation id or tag; omit to clear all"},
    },
    positional = {"which"},
}
cmdargs.validate(drawClearSchema)

local drawOutputSchema <const>: {string: any} = {
    type = "object",
    properties = {
        id = {type = "integer", description = "annotation id for draw clear"},
        tag = {type = "string"},
    },
    required = {"id"},
}

local spawnSchema <const>: cmdargs.Schema = {
    args = {
        spec = {rest = true, required = true,
            help = "[bundle] Component {lua table} ..., e.g. enemy Transform {x = 10}"},
    },
    positional = {"spec"},
}
cmdargs.validate(spawnSchema)

-- Evaluate a Lua table expression from the command line. Same trust level
-- as the run_lua MCP tool: the debugger is a developer surface.
local function evalTable(expr: string): {string: any}, string
    local chunk, err = load("return " .. expr, "debug-expr", "t")
    if not chunk then return nil, "bad expression: " .. tostring(err) end
    local ok, result = pcall(chunk)
    if not ok then return nil, "expression failed: " .. tostring(result) end
    if type(result) ~= "table" then
        return nil, "expression must be a table, got " .. type(result)
    end
    return result as {string: any}, nil
end

-- The set/modify value argument: a table passes through (a JSON object over
-- MCP); a nonempty string evaluates as a Lua table expression. Returns nil
-- with no error when the value is absent.
local function parseValueArg(value: any): {string: any}, string
    if type(value) == "table" then
        return value as {string: any}, nil
    end
    if type(value) == "string" and (value as string) ~= "" then
        return evalTable(value as string)
    end
    return nil, nil
end

-- Merge fields into a live component instance. Nested tables recurse into
-- the existing sub-value (a table or an FFI struct reference) so siblings
-- of the named fields survive; anything else assigns directly.
local function applyFields(target: any, fields: {string: any})
    local tgt = target as {string: any}
    for k, fv in pairs(fields) do
        if type(fv) == "table" and tgt[k] ~= nil then
            applyFields(tgt[k], fv as {string: any})
        else
            tgt[k] = fv
        end
    end
end

function edit.commands(d: cmdtypes.Deps): {cmdtypes.Command}
    -- The shared context, aliased once so command bodies stay terse.
    local w <const> = d.world
    local ctx <const> = d.ctx
    local env <const> = d.env
    local componentFor <const> = d.componentFor
    local resolveTargets <const> = d.resolveTargets
    local makeAnnotation <const> = d.makeAnnotation
    local selectionTarget <const> = d.selectionTarget

    -- Entity-edit commands take an explicit target: an id, a mark name, or
    -- the literal @selection (explicit, because component names follow it).
    -- ids= is the batch alternative and overrides the positional target.
    local function editTargetArgs(): {string: cmdargs.ArgSpec}
        return {
            id = {kind = "number", forward = "target", help = "entity id"},
            name = {forward = "target", help = "mark name, or " .. selectionTarget},
            target = {synthetic = {"id", "name"},
                help = "entity id, mark name, or " .. selectionTarget .. " (or give ids=)"},
            ids = {kind = "list", help = "entity ids to target instead (overrides target)"},
        }
    end

    local removeSchema <const>: cmdargs.Schema = (function(): cmdargs.Schema
        local args = editTargetArgs()
        args.comps = {rest = true, required = true, help = "component names to remove"}
        local schema: cmdargs.Schema = {args = args, positional = {"target", "comps"}}
        cmdargs.validate(schema)
        return schema
    end)()

    local setSchema <const>: cmdargs.Schema = (function(): cmdargs.Schema
        local args = editTargetArgs()
        args.comp = {required = true, help = "component name"}
        args.value = {rest = true, kind = "table",
            help = "component fields: a Lua table expression, e.g. {x = 10, y = 20}, or a JSON object over MCP; omit for defaults"}
        local schema: cmdargs.Schema = {args = args, positional = {"target", "comp", "value"}}
        cmdargs.validate(schema)
        return schema
    end)()

    local modifySchema <const>: cmdargs.Schema = (function(): cmdargs.Schema
        local args = editTargetArgs()
        args.comp = {required = true, help = "component name"}
        args.value = {rest = true, required = true, kind = "table",
            help = "fields to change: a Lua table expression, e.g. {x = 10}, or a JSON object over MCP"}
        local schema: cmdargs.Schema = {args = args, positional = {"target", "comp", "value"}}
        cmdargs.validate(schema)
        return schema
    end)()

    -- Resolve an edit target: an explicit ids= list wins, and the literal
    -- @selection means the current selection. Returns nil plus a reason and
    -- a machine-readable code when nothing matches.
    local function resolveEditTargets(v: {string: any}): {integer}, string, string
        if v.ids ~= nil then
            local ids: {integer} = {}
            for _, raw in ipairs(v.ids as {string}) do
                local n = tonumber(raw)
                if not n then
                    return nil, "ids must be numeric entity ids, got '" .. raw .. "'",
                        "invalid_arguments"
                end
                ids[#ids + 1] = math.floor(n)
            end
            if #ids == 0 then return nil, "ids is empty", "invalid_arguments" end
            return ids, nil, nil
        end
        if v.target == nil then
            return nil, "give an entity id, mark name, " .. selectionTarget .. ", or ids=",
                "invalid_arguments"
        end
        if v.name == selectionTarget then
            if #ctx.selected == 0 then return nil, "nothing selected", "no_match" end
            local ids: {integer} = {}
            for i = 1, #ctx.selected do ids[i] = ctx.selected[i] end
            return ids, nil, nil
        end
        local ids = resolveTargets(v)
        if #ids == 0 then
            return nil, "no live match for '" .. tostring(v.target) .. "'", "no_match"
        end
        return ids, nil, nil
    end

    -- One draw verb: the name doubles as the annotation kind.
    local function drawVerb(name: string, shortHelp: string, schema: cmdargs.Schema): cmdtypes.Subcommand
        return {
            name = name,
            shortHelp = shortHelp,
            schema = schema,
            outputSchema = drawOutputSchema,
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local id = env.annotations:add(makeAnnotation(v, name as annotations.Kind))
                return {ok = true, message = "drew " .. name .. " #" .. tostring(id),
                    data = {id = id, tag = v.tag}}
            end,
        }
    end

    return {
        {
            name = "remove",
            section = "Edit",
            complete = {[1] = "edittargets", [0] = "components"},
            shortHelp = "remove components from an entity, marked group, or " .. selectionTarget,
            mcpHelp = "Strip the named components from the target entities (an id, a mark name, @selection, or an ids list). Destructive to component data; the entities survive. Returns how many entities were changed.",
            schema = removeSchema,
            examples = {"remove 5 Velocity", "remove @selection Burning Stunned", "remove boss Shield",
                "remove ids=5,6 comps=Shield"},
            outputSchema = {
                type = "object",
                properties = {
                    entities = {type = "integer", description = "entities touched"},
                    components = {type = "array", items = {type = "string"}},
                    errors = {type = "integer", description = "failed removals"},
                },
                required = {"components", "entities", "errors"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local ids, terr, tcode = resolveEditTargets(v)
                if not ids then
                    return {ok = false, code = tcode, message = "remove: " .. terr}
                end
                local comps: {tecs.Component} = {}
                local names: {string} = {}
                for nm in (v.comps as string):gmatch("%S+") do
                    local comp, cerr = componentFor(nm)
                    if not comp then
                        return {ok = false, code = "unknown_component", message = "remove: " .. cerr}
                    end
                    comps[#comps + 1] = comp
                    names[#names + 1] = nm
                end
                if #comps == 0 then
                    return {ok = false, code = "invalid_arguments",
                        message = "remove: name at least one component"}
                end
                local touched = 0
                local errors = 0
                for i = 1, #ids do
                    local eid = ids[i]
                    if w:isAlive(eid) then
                        for j = 1, #comps do
                            if not pcall(w.remove, w, eid, comps[j]) then
                                errors = errors + 1
                            end
                        end
                        touched = touched + 1
                    end
                end
                debugcontext.pushEvent(ctx, "edit",
                    {removed = table.concat(names, ","), entities = touched})
                return {ok = true,
                    message = "removed " .. table.concat(names, ", ") .. " from " ..
                        tostring(touched) .. " entities" ..
                        ((errors > 0) and (" (" .. tostring(errors) .. " errors)") or ""),
                    data = {entities = touched, components = names, errors = errors}}
            end,
        },
        {
            name = "set",
            section = "Edit",
            complete = {[1] = "edittargets", [2] = "components"},
            shortHelp = "set one component on an entity, marked group, or " ..
                selectionTarget .. " (Lua table value)",
            mcpHelp = "Write one component on the target entities (an id, a mark name, the literal @selection, or an ids list). The value is a JSON object or a Lua table expression, e.g. {x = 10, y = {n = 2}}; omitted fields reset to the component's defaults (use cmd_modify to change fields in place). Adds the component when missing. Mutates the live world immediately. Returns how many entities were written.",
            schema = setSchema,
            examples = {"set 5 Transform {x = 10, y = 20}", "set @selection Color {r = 1, g = 0, b = 0}",
                "set boss Shield", "set ids=5,6 comp=Transform value={x = 0}"},
            outputSchema = {
                type = "object",
                properties = {
                    set = {type = "integer", description = "entities written"},
                    component = {type = "string"},
                },
                required = {"component", "set"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local ids, terr, tcode = resolveEditTargets(v)
                if not ids then
                    return {ok = false, code = tcode, message = "set: " .. terr}
                end
                local compName = v.comp as string
                local comp, cerr = componentFor(compName)
                if not comp then
                    return {ok = false, code = "unknown_component", message = "set: " .. cerr}
                end
                local dataTbl, verr = parseValueArg(v.value)
                if verr then
                    return {ok = false, code = "invalid_arguments", message = "set: " .. verr}
                end
                if not dataTbl then dataTbl = {} end
                local count = 0
                local firstError: string = nil
                for i = 1, #ids do
                    local eid = ids[i]
                    if w:isAlive(eid) then
                        -- A fresh instance per entity: FFI cdata must never be
                        -- shared across rows.
                        local ok2, err2 = pcall(function()
                            w:set(eid, comp.deserialize(w, dataTbl))
                        end) as (boolean, any)
                        if ok2 then
                            count = count + 1
                        elseif not firstError then
                            firstError = tostring(err2)
                        end
                    end
                end
                if count == 0 then
                    return {ok = false, code = "set_failed",
                        message = "set: " .. (firstError or "no live targets")}
                end
                debugcontext.pushEvent(ctx, "edit", {component = compName, set = count})
                return {ok = true,
                    message = "set " .. compName .. " on " .. tostring(count) .. " entities" ..
                        (firstError and (" (some failed: " .. firstError .. ")") or ""),
                    data = {set = count, component = compName}}
            end,
        },
        {
            name = "modify",
            section = "Edit",
            complete = {[1] = "edittargets", [2] = "components"},
            shortHelp = "change only the given fields of a component the target already has",
            mcpHelp = "Update only the provided fields of one component on the target entities (an id, a mark name, @selection, or an ids list). Unlike cmd_set it never adds the component and never resets omitted fields: targets missing the component are skipped and unnamed fields keep their current values. Returns modified and skipped counts.",
            schema = modifySchema,
            examples = {"modify 5 Transform {x = 10}", "modify @selection Color {a = 0.5}",
                "modify boss Health {hp = 1}", "modify ids=5,6 comp=Health value={hp = 1}"},
            outputSchema = {
                type = "object",
                properties = {
                    modified = {type = "integer", description = "entities changed"},
                    skipped = {type = "integer", description = "live targets lacking the component"},
                    component = {type = "string"},
                },
                required = {"component", "modified", "skipped"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local ids, terr, tcode = resolveEditTargets(v)
                if not ids then
                    return {ok = false, code = tcode, message = "modify: " .. terr}
                end
                local compName = v.comp as string
                local comp, cerr = componentFor(compName)
                if not comp then
                    return {ok = false, code = "unknown_component", message = "modify: " .. cerr}
                end
                local dataTbl, verr = parseValueArg(v.value)
                if verr then
                    return {ok = false, code = "invalid_arguments", message = "modify: " .. verr}
                end
                if not dataTbl or next(dataTbl) == nil then
                    return {ok = false, code = "invalid_arguments",
                        message = "modify: provide at least one field, e.g. {x = 10}"}
                end
                local count = 0
                local skipped = 0
                local firstError: string = nil
                for i = 1, #ids do
                    local eid = ids[i]
                    if w:isAlive(eid) then
                        if not w:has(eid, comp) then
                            skipped = skipped + 1
                        else
                            -- getMut marks the component dirty so GPU syncs
                            -- and other dirty-gated consumers see the write.
                            local ok2, err2 = pcall(function()
                                applyFields(w:getMut(eid, comp), dataTbl)
                            end) as (boolean, any)
                            if ok2 then
                                count = count + 1
                            elseif not firstError then
                                firstError = tostring(err2)
                            end
                        end
                    end
                end
                if count == 0 then
                    local why = firstError
                        or ((skipped > 0) and ("no target has " .. compName) or "no live targets")
                    return {ok = false, code = "modify_failed", message = "modify: " .. why}
                end
                debugcontext.pushEvent(ctx, "edit", {component = compName, modified = count})
                return {ok = true,
                    message = "modified " .. compName .. " on " .. tostring(count) .. " entities" ..
                        ((skipped > 0) and (" (" .. tostring(skipped) .. " lacked it)") or "") ..
                        (firstError and (" (some failed: " .. firstError .. ")") or ""),
                    data = {modified = count, skipped = skipped, component = compName}}
            end,
        },
        {
            name = "spawn",
            section = "Edit",
            complete = {[1] = "bundles,components", [0] = "components"},
            shortHelp = "spawn an entity from a bundle and/or components with Lua table values",
            mcpHelp = "Spawn one entity from a bundle name and/or component list with Lua table values, e.g. 'Transform {x = 10, y = 20}'. The new entity becomes selected. Returns its id.",
            schema = spawnSchema,
            examples = {"spawn Transform {x = 100, y = 50}", "spawn enemy Transform {x = 0, y = 0}",
                "spawn ball"},
            outputSchema = {
                type = "object",
                properties = {
                    id = {type = "integer", description = "the new entity, now selected"},
                    bundle = {type = "string", description = "bundle used, when one matched"},
                },
                required = {"id"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local toks, terr = cmdargs.tokenize(v.spec as string)
                if not toks then
                    return {ok = false, code = "parse_error", message = "spawn: " .. terr}
                end
                local bundles = w:getBundles()
                local idx = 1
                local bundleName: string = nil
                if toks[1] and bundles[toks[1]] ~= nil then
                    bundleName = toks[1]
                    idx = 2
                end
                local instances: {tecs.Component} = {}
                while idx <= #toks do
                    local nm = toks[idx]
                    if nm:sub(1, 1) == "{" then
                        return {ok = false, code = "invalid_arguments",
                            message = "spawn: a component name must precede '" .. nm .. "'"}
                    end
                    local comp, cerr = componentFor(nm)
                    if not comp then
                        local hint = (idx == 1 and not bundleName)
                            and " (and no bundle has that name)" or ""
                        return {ok = false, code = "unknown_component",
                            message = "spawn: " .. cerr .. hint}
                    end
                    local expr: string = nil
                    if toks[idx + 1] and toks[idx + 1]:sub(1, 1) == "{" then
                        expr = toks[idx + 1]
                        idx = idx + 1
                    end
                    local dataTbl: {string: any} = {}
                    if expr then
                        local parsed, verr = evalTable(expr)
                        if not parsed then
                            return {ok = false, code = "invalid_arguments",
                                message = "spawn: " .. nm .. ": " .. verr}
                        end
                        dataTbl = parsed
                    end
                    local okD, res = pcall(function(): tecs.Component
                        return comp.deserialize(w, dataTbl)
                    end)
                    if not okD then
                        return {ok = false, code = "component_deserialize_failed",
                            message = "spawn: " .. nm .. ": " .. tostring(res)}
                    end
                    instances[#instances + 1] = res as tecs.Component
                    idx = idx + 1
                end
                if not bundleName and #instances == 0 then
                    return {ok = false, code = "invalid_arguments",
                        message = "spawn: give a bundle name and/or components. See `help spawn`."}
                end
                local okS, spawnedOrErr = pcall(function(): integer
                    if bundleName then
                        return w:spawnBundle(bundleName, table.unpack(instances))
                    end
                    return w:spawn(table.unpack(instances))
                end)
                if not okS then
                    return {ok = false, code = "spawn_failed",
                        message = "spawn failed: " .. tostring(spawnedOrErr)}
                end
                local id = spawnedOrErr as integer
                debugcontext.addSelected(ctx, id)
                debugcontext.pushEvent(ctx, "spawn", {id = id, bundle = bundleName})
                return {ok = true,
                    message = "spawned #" .. tostring(id) ..
                        (bundleName and (" from " .. bundleName) or ""),
                    data = {id = id, bundle = bundleName}}
            end,
        },
        {
            name = "draw",
            section = "Edit",
            shortHelp = "draw a world-space annotation over the game",
            examples = {"draw rect 10 10 64 48", "draw circle 0 0 20 entity=42 r=0 b=1",
                "draw text 5 -30 spawn point here", "draw clear paths"},
            subcommands = {
                drawVerb("rect", "outline a rectangle (x y w h in world units)", drawRectSchema),
                drawVerb("circle", "outline a circle (x y radius in world units)", drawCircleSchema),
                drawVerb("line", "draw a line (x y x2 y2 in world units)", drawLineSchema),
                drawVerb("text", "print text at a world position", drawTextSchema),
                {
                    name = "clear",
                    aliases = {"rm"},
                    shortHelp = "remove annotations by id or tag; everything when omitted",
                    schema = drawClearSchema,
                    outputSchema = {
                        type = "object",
                        properties = {
                            cleared = {type = "integer", description = "annotations removed"},
                        },
                        required = {"cleared"},
                    },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local id: integer = nil
                        if v.id ~= nil then id = math.floor(v.id as number) as integer end
                        local n = env.annotations:clear(v.tag as string, id)
                        return {ok = true, message = "cleared " .. tostring(n) .. " annotation(s)",
                            data = {cleared = n}}
                    end,
                },
            },
        },
    }
end

return edit
