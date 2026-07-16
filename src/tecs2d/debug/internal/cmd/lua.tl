--- Lua-introspection debugger commands: a deliberately curated, read-only
--- window into the Lua side of the running game -- loaded modules and their
--- exports. This group is the growth point for exposing more of Lua's debug
--- facilities as safe, structured commands over time; the raw `debug` and
--- `package` libraries stay out of the run_lua sandbox because they can
--- rebuild io/os/load from any closure, so anything they would answer gets
--- mediated here instead.
---
--- Everything shared with the core registry arrives through cmdtypes.Deps;
--- this module must not require tecs2d.debug.commands (a load cycle).

local sanitize <const> = require("tecs2d.debug.internal.sanitize")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")

local record luacmds
    --- The Lua-introspection commands, in display order.
    commands: function(d: cmdtypes.Deps): {cmdtypes.Command}
end

local exportsSchema <const>: cmdargs.Schema = {
    args = {
        module = {required = true, help = "loaded module name (see `lua modules`)"},
    },
    positional = {"module"},
}
cmdargs.validate(exportsSchema)

local modulesSchema <const>: cmdargs.Schema = {
    args = {
        contains = {help = "only names containing this substring"},
    },
    positional = {"contains"},
}
cmdargs.validate(modulesSchema)

function luacmds.commands(_d: cmdtypes.Deps): {cmdtypes.Command}
    local loaded <const> = package.loaded as {string: any}

    return {
        {
            name = "lua",
            section = "Engine",
            shortHelp = "inspect the Lua side: loaded modules and their exports",
            examples = {"lua modules", "lua modules snake", "lua exports components.food"},
            subcommands = {
                {
                    name = "modules",
                    shortHelp = "list loaded module names",
                    mcpHelp = "Every module name currently loaded (package.loaded), sorted; "
                        .. "pass contains=<text> to filter. The game's own modules appear "
                        .. "under the names they are required with (e.g. components.food). "
                        .. "Follow with cmd_lua_exports to read one module's exports.",
                    schema = modulesSchema,
                    annotations = {readOnlyHint = true, idempotentHint = true},
                    outputSchema = {
                        type = "object",
                        properties = {
                            count = {type = "integer"},
                            modules = {type = "array", items = {type = "string"}},
                        },
                        required = {"count", "modules"},
                    },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local contains = v.contains as string
                        local names: {string} = {}
                        for name in pairs(loaded) do
                            if not contains or name:find(contains, 1, true) then
                                names[#names + 1] = name
                            end
                        end
                        table.sort(names)
                        local popup: {string} = {"modules  (" .. tostring(#names) .. "):"}
                        for i = 1, math.min(#names, 40) do
                            popup[#popup + 1] = "  " .. names[i]
                        end
                        if #names > 40 then
                            popup[#popup + 1] = "  ... (" .. tostring(#names - 40) .. " more)"
                        end
                        return {ok = true, popup = popup,
                            data = {count = #names, modules = names}}
                    end,
                },
                {
                    name = "exports",
                    shortHelp = "dump a loaded module's exports as data",
                    mcpHelp = "A loaded module's exported table, deep-copied to JSON-safe data: "
                        .. "scalars and tables come through as values, functions and other live "
                        .. "objects as their tostring form (inert -- nothing returned here is "
                        .. "callable). Use it to read a game module's constants, keys, and "
                        .. "structure without writing Lua.",
                    schema = exportsSchema,
                    annotations = {readOnlyHint = true, idempotentHint = true},
                    outputSchema = {
                        type = "object",
                        properties = {
                            module = {type = "string"},
                            type = {type = "string",
                                description = "Lua type of the module's return value"},
                            exports = {description = "the module value, JSON-safe"},
                        },
                        required = {"module", "type"},
                    },
                    run = function(v: {string: any}, _parts: {string}): cmdtypes.Result
                        local name = v.module as string
                        local mod = loaded[name]
                        if mod == nil then
                            return {ok = false, code = "unknown_module",
                                message = "lua exports: no loaded module '" .. name
                                    .. "' (see `lua modules`)"}
                        end
                        return {ok = true,
                            popup = {"exports of " .. name .. " (" .. type(mod) .. ")"},
                            data = {module = name, type = type(mod),
                                exports = sanitize.value(mod)}}
                    end,
                },
            },
        },
    }
end

return luacmds
