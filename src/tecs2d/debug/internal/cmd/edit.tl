--- Edit-section debugger commands: remove, set, modify, and spawn,
--- plus the mutation helpers they share (edit-target resolution, Lua table
--- expression evaluation, and field merging).
---
--- Everything shared with the core registry arrives through cmdtypes.Deps;
--- this module must not require tecs2d.debug.commands (a load cycle).

local tecs <const> = require("tecs")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")
local setfenv <const> = ((_G as any) as {string: any})["setfenv"]
    as function(any, {string: any})

local record edit
    --- The Edit-section commands, in display order.
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

local spawnSchema <const>: cmdargs.Schema = {
    args = {
        worldId = {kind = "number",
            help = "render world id; omit for the game world (see context)"},
        spec = {rest = true, required = true, completion = "bundles,components",
            help = "[bundle] Component {lua table} ..., e.g. enemy Transform {x = 10}"},
    },
    positional = {"spec"},
}
cmdargs.validate(spawnSchema)

-- Evaluate a data-only Lua table expression from the command line. The empty
-- environment admits literals and arithmetic but no globals, so cmd_spawn
-- cannot become an unsandboxed process/filesystem escape over MCP.
local function evalTable(expr: string): {string: any}, string
    local chunk, err = load("return " .. expr, "debug-expr", "t")
    if not chunk then return nil, "bad expression: " .. tostring(err) end
    setfenv(chunk, {})
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
    local componentFor <const> = d.componentFor
    local resolveTargets <const> = d.resolveTargets
    local worldFor <const> = d.worldFor
    local selectionTarget <const> = d.selectionTarget

    -- Entity-edit commands take an explicit target: an id, a mark name, or
    -- the literal @selection (explicit, because component names follow it).
    -- ids= is the batch alternative and overrides the positional target.
    local function editTargetArgs(): {string: cmdargs.ArgSpec}
        return {
            id = {kind = "number", forward = "target", help = "entity id"},
            name = {forward = "target", completion = "edittargets",
                help = "mark name, or " .. selectionTarget},
            target = {synthetic = {"id", "name"},
                completion = "edittargets",
                help = "entity id, mark name, or " .. selectionTarget .. " (or give ids=)"},
            ids = {kind = "list", help = "entity ids to target instead (overrides target)"},
            worldId = {kind = "number",
                help = "render world id; omit for the game world (see context)"},
        }
    end

    local removeSchema <const>: cmdargs.Schema = (function(): cmdargs.Schema
        local args = editTargetArgs()
        args.comps = {rest = true, required = true, completion = "components",
            help = "component names to remove"}
        local schema: cmdargs.Schema = {args = args, positional = {"target", "comps"}}
        cmdargs.validate(schema)
        return schema
    end)()

    local setSchema <const>: cmdargs.Schema = (function(): cmdargs.Schema
        local args = editTargetArgs()
        args.comp = {required = true, completion = "components", help = "component name"}
        args.value = {rest = true, kind = "table",
            help = "component fields: a Lua table expression, e.g. {x = 10, y = 20}, or a JSON object over MCP; omit for defaults"}
        local schema: cmdargs.Schema = {args = args, positional = {"target", "comp", "value"}}
        cmdargs.validate(schema)
        return schema
    end)()

    local modifySchema <const>: cmdargs.Schema = (function(): cmdargs.Schema
        local args = editTargetArgs()
        args.comp = {required = true, completion = "components", help = "component name"}
        args.value = {rest = true, required = true, kind = "table",
            help = "fields to change: a Lua table expression, e.g. {x = 10}, or a JSON object over MCP"}
        local schema: cmdargs.Schema = {args = args, positional = {"target", "comp", "value"}}
        cmdargs.validate(schema)
        return schema
    end)()

    -- Resolve an edit target: an explicit ids= list wins, and the literal
    -- @selection means the current selection. Returns nil plus a reason and
    -- a machine-readable code when nothing matches.
    local function resolveEditTargets(v: {string: any}, targetWorld: tecs.World):
            {integer}, string, string
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
        if targetWorld ~= w and v.name ~= nil then
            return nil, "marks and @selection belong to the game world; use id= or ids= with worldId",
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

    return {
        {
            name = "remove",
            section = "Edit",
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
                    worldId = {type = "integer", description = "target render world"},
                },
                required = {"components", "entities", "errors", "worldId"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local targetWorld, worldId, werr = worldFor(v)
                if not targetWorld then
                    return {ok = false, code = "unknown_world", message = "remove: " .. werr}
                end
                local ids, terr, tcode = resolveEditTargets(v, targetWorld)
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
                    if targetWorld:isAlive(eid) then
                        for j = 1, #comps do
                            if not pcall(targetWorld.remove, targetWorld, eid, comps[j]) then
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
                    data = {entities = touched, components = names,
                        errors = errors, worldId = worldId}}
            end,
        },
        {
            name = "set",
            section = "Edit",
            shortHelp = "set one component on an entity, marked group, or " .. selectionTarget .. " (Lua table value)",
            mcpHelp = "Write one component on the target entities (an id, a mark name, the literal @selection, or an ids list). The value is a JSON object; omitted fields reset to the component's defaults (use cmd_modify to change fields in place). Adds the component when missing. Mutates the live world immediately. Returns how many entities were written.",
            schema = setSchema,
            examples = {"set 5 Transform {x = 10, y = 20}", "set @selection Color {r = 1, g = 0, b = 0}",
                "set boss Shield", "set ids=5,6 comp=Transform value={x = 0}"},
            outputSchema = {
                type = "object",
                properties = {
                    set = {type = "integer", description = "entities written"},
                    component = {type = "string"},
                    worldId = {type = "integer", description = "target render world"},
                },
                required = {"component", "set", "worldId"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local targetWorld, worldId, werr = worldFor(v)
                if not targetWorld then
                    return {ok = false, code = "unknown_world", message = "set: " .. werr}
                end
                local ids, terr, tcode = resolveEditTargets(v, targetWorld)
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
                    if targetWorld:isAlive(eid) then
                        -- A fresh instance per entity: FFI cdata must never be
                        -- shared across rows.
                        local ok2, err2 = pcall(function()
                            targetWorld:set(eid, comp.deserialize(targetWorld, dataTbl))
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
                    data = {set = count, component = compName, worldId = worldId}}
            end,
        },
        {
            name = "modify",
            section = "Edit",
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
                    worldId = {type = "integer", description = "target render world"},
                },
                required = {"component", "modified", "skipped", "worldId"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local targetWorld, worldId, werr = worldFor(v)
                if not targetWorld then
                    return {ok = false, code = "unknown_world", message = "modify: " .. werr}
                end
                local ids, terr, tcode = resolveEditTargets(v, targetWorld)
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
                    if targetWorld:isAlive(eid) then
                        if not targetWorld:has(eid, comp) then
                            skipped = skipped + 1
                        else
                            -- getMut marks the component dirty so GPU syncs
                            -- and other dirty-gated consumers see the write.
                            local ok2, err2 = pcall(function()
                                applyFields(targetWorld:getMut(eid, comp), dataTbl)
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
                    data = {modified = count, skipped = skipped,
                        component = compName, worldId = worldId}}
            end,
        },
        {
            name = "spawn",
            section = "Edit",
            shortHelp = "spawn an entity from a bundle and/or components with Lua table values",
            mcpHelp = "Spawn one entity in the game world or an explicit render worldId from a bundle name and/or component list with data-only Lua table literals, e.g. 'Transform {x = 10, y = 20}'. Game-world entities become selected; entities in another world remain independent. Returns its id and worldId.",
            schema = spawnSchema,
            examples = {"spawn Transform {x = 100, y = 50}", "spawn enemy Transform {x = 0, y = 0}",
                "spawn ball"},
            outputSchema = {
                type = "object",
                properties = {
                    id = {type = "integer", description = "the new entity, now selected"},
                    bundle = {type = "string", description = "bundle used, when one matched"},
                    worldId = {type = "integer", description = "target render world"},
                },
                required = {"id", "worldId"},
            },
            run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                local targetWorld, worldId, werr = worldFor(v)
                if not targetWorld then
                    return {ok = false, code = "unknown_world", message = "spawn: " .. werr}
                end
                local toks, terr = cmdargs.tokenize(v.spec as string)
                if not toks then
                    return {ok = false, code = "parse_error", message = "spawn: " .. terr}
                end
                local bundles = targetWorld:getBundles()
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
                        return comp.deserialize(targetWorld, dataTbl)
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
                        return targetWorld:spawnBundle(bundleName, table.unpack(instances))
                    end
                    return targetWorld:spawn(table.unpack(instances))
                end)
                if not okS then
                    return {ok = false, code = "spawn_failed",
                        message = "spawn failed: " .. tostring(spawnedOrErr)}
                end
                local id = spawnedOrErr as integer
                if targetWorld == w then debugcontext.addSelected(ctx, id) end
                debugcontext.pushEvent(ctx, "spawn",
                    {id = id, worldId = worldId, bundle = bundleName})
                return {ok = true,
                    message = "spawned #" .. tostring(id) ..
                        (bundleName and (" from " .. bundleName) or ""),
                    data = {id = id, worldId = worldId, bundle = bundleName}}
            end,
        },
    }
end

return edit
