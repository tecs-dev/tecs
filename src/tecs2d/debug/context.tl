--- The debug plugin's integration surface for other plugins (the MCP server):
--- the shared DebugContext resource, the freeze controller, and the command
--- registry's MCP projection. Everything under tecs2d.debug.internal is
--- private; cross-plugin consumers go through this module.

local tecs <const> = require("tecs")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local commands <const> = require("tecs2d.debug.commands")
local freeze <const> = require("tecs2d.debug.internal.freeze")

local record context
    --- Resource key for the live DebugContext published by the debug plugin
    --- (selection, marks, notes, camera, artifact histories, recording state).
    KEY: tecs.Key<debugcontext.Context>

    --- Invert an entity->value map to value->compact id-range string, e.g.
    --- {5="a", 6="a", 9="b"} -> {a="5-6", b="9"}.
    encodeGroups: function({integer: string}): {string: string}

    --- Get or create the world's freeze/step controller. Works with or
    --- without the debug plugin installed.
    ensureFreeze: function(w: tecs.World): freeze.Controller

    --- The command registry projected as MCP tool definitions (debug_*
    --- names), or nil when the debug plugin is not installed.
    commandTools: function(w: tecs.World): {commands.McpTool}

    --- Dispatch a debug_* tool call with JSON args. Returns nil plus
    --- "disabled" when the debug plugin is not installed, or nil plus an
    --- error message for an unknown tool name.
    invokeCommand: function(w: tecs.World, name: string, args: {string: any}): commands.Result, string
end

context.KEY = debugcontext.KEY
context.encodeGroups = debugcontext.encodeGroups
context.ensureFreeze = freeze.ensure

function context.commandTools(w: tecs.World): {commands.McpTool}
    local registry = w.resources[commands.KEY]
    if not registry then return nil end
    return registry:mcpTools()
end

function context.invokeCommand(w: tecs.World, name: string, args: {string: any}): commands.Result, string
    local registry = w.resources[commands.KEY]
    if not registry then return nil, "disabled" end
    return registry:invokeMcp(name, args)
end

return context
