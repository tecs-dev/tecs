--- The debugger command registry: one declaration per command (schema, help,
--- subcommands, action) shared by both surfaces. The overlay tokenizes a typed
--- line and dispatches through execute(); the MCP server projects the same
--- registry to debug_* tools (mcpTools) and dispatches JSON args through
--- invokeMcp(). Actions receive parsed, typed values and return a Result whose
--- `data` is the canonical structured payload; `popup` is overlay presentation.
---
--- Games can add their own commands with commands.register(world, cmd) after
--- installing the debug plugin. A registered command gets the same treatment
--- as the builtins: schema-parsed arguments, generated help and completion in
--- the overlay, and a debug_<name> MCP tool. The `overlay` and `mcp` flags
--- scope a command to one surface. Read the live debugger state (selection,
--- marks, notes) through world.resources[require("tecs2d.debug.context").KEY].
---
--- Commands adapt values to services (recorder, freeze controller, world);
--- heavy machinery does not live here.

local tecs <const> = require("tecs")
local componentregistry <const> = require("tecs.internal.components")
local json <const> = require("tecs.utils.json")
local entityinfo <const> = require("tecs2d.internal.entityinfo")
local systemcontrol <const> = require("tecs2d.internal.systemcontrol")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")
local gfxtypes <const> = require("tecs2d.gfx.types")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local annotations <const> = require("tecs2d.debug.internal.annotations")
local mcpinfo <const> = require("tecs2d.internal.mcpinfo")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")
local capturecmds <const> = require("tecs2d.debug.internal.cmd.capture")
local enginecmds <const> = require("tecs2d.debug.internal.cmd.engine")
local rendercmds <const> = require("tecs2d.debug.internal.cmd.render")

local format <const> = string.format
local getTime <const> = love.timer.getTime

local Transform <const> = tecs.builtins.Transform

local record commands
    --- Sentinel popup line drawn as a horizontal rule rather than text.
    HRULE: string

    --- Flatten popup lines into clipboard text: tabs become spaces and
    --- rules become dashes. Used by the overlay's leader+Y yank.
    flattenOutput: function(lines: {string}): string

    --- Tile grid at a world point: the first TileChunk's size and origin,
    --- else the enabled debug grid. Returns tile x, tile y, tile size, and
    --- grid origin, or nil when no grid source exists. Shared by the `tile`
    --- command and the overlay's context menu.
    tileAt: function(w: tecs.World, ctx: debugcontext.Context, wx: number, wy: number): integer, integer, number, number, number, number

    --- Prefix marking a section separator entry in completion candidates.
    SECTION_MARK: string

    -- The shared record types live in internal/cmdtypes (a leaf module) so
    -- the command groups can use them without requiring this module back.
    -- Re-exported so commands.Result etc. work as type annotations.
    type Keys = cmdtypes.Keys
    type Env = cmdtypes.Env
    type Result = cmdtypes.Result
    type Signals = cmdtypes.Signals
    type Subcommand = cmdtypes.Subcommand
    type Command = cmdtypes.Command
    type McpTool = cmdtypes.McpTool
    type ProfilerState = cmdtypes.ProfilerState

    record Registry
        env: Env
        list: {Command}
        byName: {string: Command}
        names: {string}
        signals: Signals
        profiler: ProfilerState
        saveCounter: integer
        saves: {integer: string}
        shotCounter: integer
        --- Command history, oldest first. Loaded from the save dir at build,
        --- appended by the overlay on Enter, read by the history command.
        history: {string}

        --- Wall clock of the last snapshot/rewind world load. Loads within
        --- LOAD_COOLDOWN of each other are refused so mashed or queued Enter
        --- presses cannot stack full-world loads back to back.
        lastWorldLoadAt: number

        --- Monotonic diff artifact number and the last diff result held in
        --- memory for `diff get`.
        diffCounter: integer
        lastDiff: {string: any}

        --- The last executed result's popup (or message) for the overlay's
        --- leader+Y yank. Stored at execute time so the live usage previews
        --- can never clobber it.
        lastOutput: {string}

        --- Screenshots scheduled with `delay=`; the overlay's input system
        --- counts them down each frame and fires them when due.
        pendingShots: {cmdtypes.PendingShot}

        --- Overlay dispatch: tokenize, route (subcommands), parse the schema,
        --- run. Returns nil for an empty line.
        execute: function(self: Registry, text: string): Result

        --- Despawn every selected entity and clear the set; returns the count.
        --- Shared by the despawn command and the overlay's Delete key.
        despawnSelected: function(self: Registry): integer

        --- Stop the active profiler session, write the collapsed stacks, and
        --- return the results popup (nil when no session is active).
        finishProfile: function(self: Registry): {string}

        --- The registry projected as MCP tool definitions (debug_* names).
        mcpTools: function(self: Registry): {McpTool}

        --- Dispatch an MCP tool call by its debug_* name with JSON args.
        --- Returns nil + error when the name is unknown.
        invokeMcp: function(self: Registry, name: string, args: {string: any}): Result, string

        --- Add a command to the registry. Raises on a duplicate name/alias or
        --- an invalid schema, since a bad registration is a programming error.
        add: function(self: Registry, cmd: Command)

        --- Append an executed command line to the history (skipping immediate
        --- repeats) and persist the tail to the save directory.
        appendHistory: function(self: Registry, text: string)

        --- Tab completion for a partial command line: returns the text up to
        --- the word being completed and the candidate replacements for it
        --- (command names, subcommand verbs, and per-command sources such as
        --- component and mark names).
        complete: function(self: Registry, text: string): string, {string}

        --- Resolve one completion source name to its current candidates.
        --- Assigned by build() (sources read live world state).
        candidatesFor: function(self: Registry, source: string): {string}
    end

    KEY: tecs.Key<Registry>

    --- Build the registry for a world. The overlay installs it as a resource
    --- under commands.KEY so the MCP plugin can project it.
    build: function(env: Env): Registry

    --- Register a custom debugger command on a world that has the debug
    --- plugin installed. The command joins the builtins: schema-parsed args,
    --- generated help and Tab completion in the overlay, and a debug_<name>
    --- MCP tool (set mcp = false for overlay-only, overlay = false for
    --- MCP-only). Raises when the debug plugin is missing or the command is
    --- invalid.
    register: function(w: tecs.World, cmd: Command)

    --- The command's name plus its generated signature, e.g. "goto <id|name>".
    commandSignature: function(c: Command): string

    --- Popup lines describing a command: signature, help, arguments,
    --- subcommands, and examples. Used by `help <name>` and the live preview.
    usagePopup: function(c: Command): {string}
end

commands.HRULE = cmdtypes.HRULE
commands.KEY = tecs.newKey()

--- Sentinel prefix marking a section separator in a completion list; the
--- overlay renders it as " | Name | " and skips it while cycling.
commands.SECTION_MARK = cmdtypes.SECTION_MARK

-- Display order of command sections in help and completion.
local SECTION_ORDER <const>: {string} = {
    "Select", "Edit", "Render", "Engine", "Capture", "Custom", "Session",
}

local HISTORY_FILE <const> = "debug-history.txt"
local HISTORY_CAP <const> = 100

-------------------------------------------------------------------------------
-- Schemas
-------------------------------------------------------------------------------

-- A target given as an entity id or a mark name, sharing one positional slot.
local function makeTargetSchema(required: boolean): cmdargs.Schema
    local schema: cmdargs.Schema = {
        args = {
            id = {default = 0, forward = "target", help = "entity id"},
            name = {forward = "target", help = "mark name"},
            target = {synthetic = {"id", "name"}, required = required, help = "entity id or mark name"},
        },
        positional = {"target"},
    }
    cmdargs.validate(schema)
    return schema
end

local targetSchema <const> = makeTargetSchema(true)
local optionalTargetSchema <const> = makeTargetSchema(false)

-- select's target plus a replace flag (replace the selection instead of adding).
local selectSchema <const>: cmdargs.Schema = {
    args = {
        id = {default = 0, forward = "target", help = "entity id"},
        name = {forward = "target", help = "mark name"},
        target = {synthetic = {"id", "name"}, required = true, help = "entity id or mark name"},
        replace = {default = false, help = "replace the selection instead of adding to it"},
    },
    positional = {"target"},
}
cmdargs.validate(selectSchema)


local stepSchema <const>: cmdargs.Schema = {
    args = { n = {default = 1, help = "number of frames to tick"} },
    positional = {"n"},
}
cmdargs.validate(stepSchema)



-- r/g/b default to nil: an omitted channel keeps its current value.

local nameSchema <const>: cmdargs.Schema = {
    args = { name = {help = "output filename"} },
    positional = {"name"},
}
cmdargs.validate(nameSchema)

local refSchema <const>: cmdargs.Schema = {
    args = { ref = {help = "save name or number"} },
    positional = {"ref"},
}
cmdargs.validate(refSchema)

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
        id = {default = 0, forward = "which", help = "annotation id"},
        tag = {forward = "which", help = "annotation tag"},
        which = {synthetic = {"id", "tag"}, help = "an annotation id or tag; omit to clear all"},
    },
    positional = {"which"},
}
cmdargs.validate(drawClearSchema)

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

local onOffSchema <const>: cmdargs.Schema = {
    args = { on = {kind = "boolean", help = "enable or disable; omit to toggle"} },
    positional = {"on"},
}
cmdargs.validate(onOffSchema)

local EDIT_SELECTION_TARGET <const> = "@selection"

-- Entity-edit commands take an explicit target: an id, a mark name, or the
-- literal @selection (explicit, because component names follow it).
local function editTargetArgs(): {string: cmdargs.ArgSpec}
    return {
        id = {default = 0, forward = "target", help = "entity id"},
        name = {forward = "target", help = "mark name, or " .. EDIT_SELECTION_TARGET},
        target = {synthetic = {"id", "name"}, required = true,
            help = "entity id, mark name, or " .. EDIT_SELECTION_TARGET},
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

local spawnSchema <const>: cmdargs.Schema = {
    args = {
        spec = {rest = true, required = true,
            help = "[bundle] Component {lua table} ..., e.g. enemy Transform {x = 10}"},
    },
    positional = {"spec"},
}
cmdargs.validate(spawnSchema)

-------------------------------------------------------------------------------
-- Presentation helpers
-------------------------------------------------------------------------------

function commands.commandSignature(c: commands.Command): string
    if c.schema then
        local sig = cmdargs.signature(c.schema)
        if sig ~= "" then return c.name .. " " .. sig end
    end
    return c.name
end

function commands.usagePopup(c: commands.Command): {string}
    local popup: {string} = {commands.commandSignature(c), "  " .. c.shortHelp}
    if c.aliases and #c.aliases > 0 then
        popup[#popup + 1] = "  aliases: " .. table.concat(c.aliases, ", ")
    end
    if c.schema or c.subcommands then
        popup[#popup + 1] = commands.HRULE
    end
    if c.schema then
        for _, l in ipairs(cmdargs.argHelp(c.schema)) do popup[#popup + 1] = l end
    end
    if c.subcommands then
        popup[#popup + 1] = "Subcommands:"
        for _, sub in ipairs(c.subcommands) do
            local sig = sub.schema and (" " .. cmdargs.signature(sub.schema)) or ""
            popup[#popup + 1] = "  " .. c.name .. " " .. sub.name .. sig .. "\t" .. sub.shortHelp
        end
    end
    if c.examples and #c.examples > 0 then
        popup[#popup + 1] = "Examples:"
        for i = 1, #c.examples do popup[#popup + 1] = "  " .. c.examples[i] end
    end
    return popup
end

-------------------------------------------------------------------------------
-- Registry
-------------------------------------------------------------------------------

local function findSubcommand(cmd: commands.Command, subName: string): commands.Subcommand
    if not cmd.subcommands or not subName then return nil end
    for _, sub in ipairs(cmd.subcommands) do
        if sub.name == subName then return sub end
        if sub.aliases then
            for _, a in ipairs(sub.aliases) do
                if a == subName then return sub end
            end
        end
    end
    return nil
end

function commands.Registry:execute(text: string): commands.Result
    local parts, tokErr = cmdargs.tokenize(text)
    if tokErr then
        return {ok = false, code = "parse_error", message = "parse error: " .. tokErr}
    end
    local name = parts[1]
    if not name then return nil end
    local cmd = self.byName[name]
    if not cmd then
        return {ok = false, code = "unknown_command",
            message = "unknown command: " .. name .. ". Type help."}
    end
    -- Route to a subcommand if one matches; otherwise fall back to the
    -- command's own run (its no-subcommand / value-argument default).
    local runFn = cmd.run
    local schema = cmd.schema
    local argStart = 2
    if cmd.subcommands and parts[2] then
        local sub = findSubcommand(cmd, parts[2])
        if sub then
            runFn, schema, argStart = sub.run, sub.schema, 3
        end
    end
    if not runFn then
        return {ok = false, code = "unknown_subcommand",
            message = cmd.name .. ": expected a subcommand. See `help " .. cmd.name .. "`."}
    end
    local values: {string: any} = {}
    if schema then
        local toks: {string} = {}
        for i = argStart, #parts do toks[#toks + 1] = parts[i] end
        local v, err = cmdargs.parse(schema, toks)
        if not v then
            return {ok = false, code = "invalid_arguments", message = cmd.name .. ": " .. err}
        end
        values = v
    end
    local result = runFn(values, parts)
    if result then
        if result.popup then
            self.lastOutput = result.popup
        elseif result.message and result.message ~= "" then
            self.lastOutput = {result.message}
        end
    end
    return result
end

-- Verbs that only read state: safe, repeatable, world untouched.
local READ_VERBS <const>: {string: boolean} = {
    list = true, ls = true, info = true, status = true, get = true,
}
-- Commands whose action removes data outright.
local DESTRUCTIVE_CMDS <const>: {string: boolean} = {
    despawn = true, remove = true, quit = true,
}
-- Parents whose `clear` verb deletes files, not just UI state.
local ARTIFACT_PARENTS <const>: {string: boolean} = {
    snapshot = true, screenshot = true, record = true, profile = true,
    diff = true, rewind = true, history = true,
}

-- Safety hints for one projected tool: derived from the command and verb,
-- then overridden key by key with any explicit annotations.
local function toolAnnotations(cmdName: string, verb: string,
        explicit: cmdtypes.ToolAnnotations): cmdtypes.ToolAnnotations
    local readOnly = (verb ~= nil and READ_VERBS[verb] == true)
    local destructive = DESTRUCTIVE_CMDS[cmdName] == true
        or verb == "load"
        or (verb == "clear" and ARTIFACT_PARENTS[cmdName] == true)
    local a: cmdtypes.ToolAnnotations = {
        readOnlyHint = readOnly,
        destructiveHint = destructive,
        idempotentHint = readOnly,
        openWorldHint = false,
    }
    if explicit then
        if explicit.readOnlyHint ~= nil then a.readOnlyHint = explicit.readOnlyHint end
        if explicit.destructiveHint ~= nil then a.destructiveHint = explicit.destructiveHint end
        if explicit.idempotentHint ~= nil then a.idempotentHint = explicit.idempotentHint end
        if explicit.openWorldHint ~= nil then a.openWorldHint = explicit.openWorldHint end
    end
    return a
end

function commands.Registry:mcpTools(): {commands.McpTool}
    local out: {commands.McpTool} = {}
    local emptySchema: {string: any} = {
        type = "object",
        properties = json.EMPTY_OBJECT,
        additionalProperties = false,
    }
    local suffix <const> = " In-game debugger command; requires the debug plugin." ..
        " Returns compact JSON text envelope."
    for _, cmd in ipairs(self.list) do
        if cmd.mcp ~= false and cmd.run then
            out[#out + 1] = {
                name = "debug_" .. cmd.name,
                description = (cmd.mcpHelp or (cmd.shortHelp .. ".")) .. suffix,
                inputSchema = cmd.schema and cmdargs.toolSchema(cmd.schema) or emptySchema,
                annotations = toolAnnotations(cmd.name, nil, cmd.annotations),
            }
        end
        if cmd.subcommands then
            for _, sub in ipairs(cmd.subcommands) do
                if sub.mcp ~= false then
                    out[#out + 1] = {
                        name = "debug_" .. cmd.name .. "_" .. sub.name,
                        description = (sub.mcpHelp or (cmd.name .. " " .. sub.name .. ": " ..
                            sub.shortHelp .. ".")) .. suffix,
                        inputSchema = sub.schema and cmdargs.toolSchema(sub.schema) or emptySchema,
                        annotations = toolAnnotations(cmd.name, sub.name, sub.annotations),
                    }
                end
            end
        end
    end
    return out
end

function commands.Registry:invokeMcp(name: string, args: {string: any}): commands.Result, string
    for _, cmd in ipairs(self.list) do
        local schema: cmdargs.Schema = nil
        local runFn: function({string: any}, {string}): commands.Result = nil
        if cmd.mcp ~= false and name == "debug_" .. cmd.name then
            schema, runFn = cmd.schema, cmd.run
        elseif cmd.subcommands then
            for _, sub in ipairs(cmd.subcommands) do
                if sub.mcp ~= false and name == "debug_" .. cmd.name .. "_" .. sub.name then
                    schema, runFn = sub.schema, sub.run
                end
            end
        end
        if runFn then
            local values: {string: any} = {}
            if schema then
                local v, err = cmdargs.parseValues(schema, args)
                if not v then
                    return {ok = false, code = "invalid_arguments", message = err}
                end
                values = v
            elseif next(args) ~= nil then
                return {ok = false, code = "invalid_arguments", message = "takes no arguments"}
            end
            return runFn(values, {})
        end
    end
    return nil, "unknown debugger tool: " .. name
end

-------------------------------------------------------------------------------
-- Build
-------------------------------------------------------------------------------

local function sortedCounts(m: {string: integer}): {{string, integer}}
    local out: {{string, integer}} = {}
    for k, v in pairs(m) do out[#out + 1] = {k, v} end
    table.sort(out, function(a: {string, integer}, b: {string, integer}): boolean
        return a[2] > b[2]
    end)
    return out
end

-- Summarize collapsed-stack text: the top self-sample hot spots (with the
-- zone each ran in) and the top systems by inclusive samples (every system
-- runs in its own "Phase:SystemName" jit.zone, the second stack segment).
-- Returns the popup body and the compact profileTop lines.
local function summarizeProfile(text: string, name: string,
        systemsById: {string: string}): {string}, {string}
    local byHot: {string: integer} = {}
    local bySystem: {string: integer} = {}
    local total = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local stack, cnt = line:match("^(.-)%s+(%d+)$")
        if stack and cnt then
            local n = tonumber(cnt) as integer
            total = total + n
            local leaf = stack:match("([^;]+)$") or stack
            local zone = stack:match("^([^;]+)") or ""
            if zone:lower() == "root" then zone = "" end
            byHot[leaf .. "\1" .. zone] = (byHot[leaf .. "\1" .. zone] or 0) + n
            local seg2 = stack:match("^[^;]+;([^;]+)")
            local sysName = seg2 and systemsById[seg2]
            if sysName then
                bySystem[sysName] = (bySystem[sysName] or 0) + n
            end
        end
    end
    local hot = sortedCounts(byHot)
    local systems = sortedCounts(bySystem)

    local top: {string} = {}
    local popup: {string} = {"profile  (type to dismiss)", "saved: " .. name,
        "samples: " .. tostring(total), "Hot spots (self, zone):"}
    for i = 1, math.min(10, #hot) do
        local leaf, zone = hot[i][1]:match("^(.-)\1(.*)$")
        local zoneStr = (zone ~= "") and ("<" .. zone .. ">") or ""
        local pct = (total > 0) and (hot[i][2] * 100.0 / total) or 0.0
        popup[#popup + 1] = format("  %d\t%.1f%%\t%s\t%s", hot[i][2], pct, leaf, zoneStr)
        top[#top + 1] = format("%d %.1f%% %s %s", hot[i][2], pct, leaf, zoneStr)
    end
    if #systems > 0 then
        popup[#popup + 1] = commands.HRULE
        popup[#popup + 1] = "Systems (inclusive samples):"
        for i = 1, math.min(10, #systems) do
            local pct = (total > 0) and (systems[i][2] * 100.0 / total) or 0.0
            popup[#popup + 1] = format("  %d\t%.1f%%\t%s", systems[i][2], pct, systems[i][1])
            top[#top + 1] = format("system %d %.1f%% %s", systems[i][2], pct, systems[i][1])
        end
    end
    return popup, top
end

--- The system-id to name map for profile summaries.
local function systemZoneIds(w: tecs.World): {string: string}
    local out: {string: string} = {}
    local infos = systemcontrol.list(w)
    for i = 1, #infos do
        out[infos[i].phase .. ":" .. infos[i].name] = infos[i].name
    end
    return out
end

function commands.build(env: commands.Env): commands.Registry
    local w = env.world
    local ctx = env.ctx

    local reg: commands.Registry = {
        env = env,
        list = {},
        byName = {},
        names = {},
        signals = {action = "", hideOverlay = false},
        pendingShots = {},
        profiler = {session = nil, deadline = 0.0, counter = 0},
        saveCounter = 0,
        saves = {},
        shotCounter = 0,
        history = {},
        lastWorldLoadAt = -math.huge,
        diffCounter = 0,
    } as commands.Registry
    setmetatable(reg as {string: any}, {__index = commands.Registry})

    -- Persisted command history: newest HISTORY_CAP lines from the save dir.
    local histData = love.filesystem.read(HISTORY_FILE)
    if histData then
        for line in (histData .. "\n"):gmatch("(.-)\n") do
            if line ~= "" then reg.history[#reg.history + 1] = line end
        end
        while #reg.history > HISTORY_CAP do table.remove(reg.history, 1) end
    end

    local function pipeline(): gfxtypes.Pipeline
        return w.resources[pipelinekey.PIPELINE]
    end

    -- Resolve a parsed `<id|name>` target to entity ids: an id yields that
    -- entity; a name yields every live entity marked with it.
    local function resolveTargets(v: {string: any}): {integer}
        if v.id ~= nil then
            return {v.id as integer}
        end
        local nm = v.name as string
        local ids: {integer} = {}
        for eid, mn in pairs(ctx.marks) do
            if mn == nm and w:isAlive(eid) then
                ids[#ids + 1] = eid
            end
        end
        return ids
    end

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
    local function runQuery(expr: string, invert: boolean): commands.Result
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

    -- Build an annotation from parsed draw args (default color: yellow).
    local function makeAnnotation(v: {string: any}, kind: annotations.Kind): annotations.Annotation
        local expiresAt: number = nil
        local secs = v.seconds as number
        if secs then
            -- 0 means one frame: expire right after the next render.
            expiresAt = getTime() + ((secs > 0) and secs or 0.001)
        end
        return {
            kind = kind,
            x = v.x as number,
            y = v.y as number,
            w = (v.w as number) or 0,
            h = (v.h as number) or 0,
            radius = (v.radius as number) or 0,
            x2 = (v.x2 as number) or 0,
            y2 = (v.y2 as number) or 0,
            text = (v.msg as string) or "",
            r = (v.r as number) or 1,
            g = (v.g as number) or 1,
            b = (v.b as number) or 0,
            a = (v.a as number) or 0.8,
            tag = v.tag as string,
            expiresAt = expiresAt,
            lineWidth = (v.stroke as number) or 4,
            fontSize = (v.fontSize as number) or 14,
            entity = math.floor((v.entity as number) or 0) as integer,
        }
    end

    -- Resolve an edit target; the literal @selection means the current
    -- selection. Returns nil plus a reason when nothing matches.
    local function resolveEditTargets(v: {string: any}): {integer}, string
        if v.name == EDIT_SELECTION_TARGET then
            if #ctx.selected == 0 then return nil, "nothing selected" end
            local ids: {integer} = {}
            for i = 1, #ctx.selected do ids[i] = ctx.selected[i] end
            return ids, nil
        end
        local ids = resolveTargets(v)
        if #ids == 0 then
            return nil, "no live match for '" .. tostring(v.target) .. "'"
        end
        return ids, nil
    end

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

    local function componentFor(nm: string): tecs.Component, string
        local ok, resolved = pcall(tecs.componentByName, nm)
        local comp = (ok and resolved) as tecs.Component
        if not comp then return nil, "unknown component '" .. nm .. "'" end
        return comp, nil
    end

    -- Live candidates for Tab-completion sources. Sources read current world
    -- state (marks, bundles, systems, cameras) at completion time.
    reg.candidatesFor = function(_self: commands.Registry, source: string): {string}
        local out: {string} = {}
        if source == "commands" then
            return reg.names
        elseif source == "components" then
            -- Iterate the name-keyed registry: id-walking breaks at the first
            -- gap in component ids.
            for name in pairs(componentregistry.registeredComponents) do
                out[#out + 1] = name
            end
            table.sort(out)
            return out
        elseif source == "marks" or source == "targets" or source == "edittargets" then
            if source == "edittargets" then out[#out + 1] = EDIT_SELECTION_TARGET end
            local names: {string} = {}
            for _, mn in pairs(ctx.marks) do
                names[#names + 1] = mn
            end
            table.sort(names)
            local last: string = nil
            for i = 1, #names do
                if names[i] ~= last then
                    out[#out + 1] = names[i]
                    last = names[i]
                end
            end
            return out
        elseif source == "bundles" then
            for name in pairs(w:getBundles()) do
                out[#out + 1] = name
            end
            table.sort(out)
            return out
        elseif source == "systems" then
            local infos = systemcontrol.list(w)
            for i = 1, #infos do out[#out + 1] = infos[i].name end
            table.sort(out)
            return out
        elseif source == "cameras" then
            local p = pipeline()
            local registered = p and (p as {string: any})._cameras as {gfxtypes.Camera}
            if registered then
                for i = 1, #registered do
                    local nm = registered[i]:getName()
                    if nm ~= "" then out[#out + 1] = nm end
                end
            end
            table.sort(out)
            return out
        end
        return out
    end


    local cmds: {commands.Command} = {
        {
            name = "help",
            section = "Session",
            mcp = false,
            complete = {[1] = "commands"},
            shortHelp = "list all commands, or show one command's arguments",
            schema = { args = { command = {help = "a command to describe"} }, positional = {"command"} },
            examples = {"help", "help record", "help select"},
            run = function(v: {string: any}, _parts: {string}): commands.Result
                local q = v.command as string
                if q then
                    local c = reg.byName[q]
                    if not c then
                        return {ok = false, code = "unknown_command",
                            message = "help: no such command '" .. q .. "'"}
                    end
                    return {ok = true, popup = commands.usagePopup(c)}
                end
                local keys = env.keys
                local lines: {string} = {
                    "help  (type `help <command>` for details)",
                    "Mouse:",
                    "  click = toggle the entity under the cursor in the selection",
                    "  drag = box-select the entities inside the rectangle",
                    "  shift+drag = move the selection; right-click cancels and restores",
                    "  right-click = context menu for the entity or world position",
                    "  middle-drag = pan the camera",
                    "  wheel = zoom toward the cursor",
                    "Keys:",
                    "  " .. keys.leader .. "+" .. keys.debugToggle .. " = open or close the debugger (freezes the game)",
                    "  " .. keys.leader .. "+" .. keys.statsToggle .. " = toggle the stats HUD",
                    "  " .. keys.leader .. "+c = clear the command / popup",
                    "  " .. keys.leader .. "+y = yank the last command's output to the clipboard",
                    "  escape = clear the command / popup, or close when empty",
                    "  tab / shift+tab = cycle completions (hold to repeat)",
                    "  bare tab starts the cycle at the last used command",
                    "  up / down = walk the command history",
                    "  left / right = page this popup",
                    "  enter = run the command",
                    "  delete = despawn the selection",
                    "Arguments (`help <command>` lists each command's):",
                    "  give them positionally or as name=value, in any order;",
                    "  positional args come before any named arg",
                    "  quote values with spaces: mark \"big boss\", record name=\"my clip\"",
                    "  flags are bare or =bool: debug, debug=true, debug=off",
                    "Commands (`help <name>` for details):",
                }
                -- Group by section, wrapping each section's names (one long
                -- line overflows the popup).
                for _, section in ipairs(SECTION_ORDER) do
                    local names: {string} = {}
                    for i = 1, #reg.names do
                        local c = reg.byName[reg.names[i]]
                        if c and (c.section or "Custom") == section then
                            names[#names + 1] = reg.names[i]
                        end
                    end
                    if #names > 0 then
                        lines[#lines + 1] = section .. ":"
                        local line = "  "
                        for i = 1, #names do
                            local piece = names[i] .. ((i < #names) and ", " or "")
                            if #line + #piece > 64 and line ~= "  " then
                                lines[#lines + 1] = line
                                line = "  "
                            end
                            line = line .. piece
                        end
                        lines[#lines + 1] = line
                    end
                end
                -- Commands with verbs, so subcommands are discoverable here
                -- and not only from `help <name>`.
                local withSubs: {string} = {}
                for i = 1, #reg.names do
                    local c = reg.byName[reg.names[i]]
                    if c and c.subcommands then
                        local verbs: {string} = {}
                        for _, sub in ipairs(c.subcommands) do
                            verbs[#verbs + 1] = sub.name
                        end
                        withSubs[#withSubs + 1] = "  " .. c.name .. "\t" .. table.concat(verbs, ", ")
                    end
                end
                if #withSubs > 0 then
                    lines[#lines + 1] = "Subcommands:"
                    for i = 1, #withSubs do lines[#lines + 1] = withSubs[i] end
                end
                return {ok = true, popup = lines}
            end,
        },
        {
            name = "select",
            section = "Select",
            complete = {[1] = "targets"},
            examples = {"select 5", "select boss", "select 5 replace", "select name=\"big boss\""},
            shortHelp = "select an entity by id, or all entities with a mark name",
            mcpHelp = "Add an entity (by id) or a marked group (by name) to the operator-visible selection; replace=true swaps the selection instead. Selected entities are highlighted in-game. Returns the selection size. Follow with debug_info for component data or debug_note to annotate.",
            schema = selectSchema,
            run = function(v: {string: any}, _parts: {string}): commands.Result
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
            run = function(_v: {string: any}, _parts: {string}): commands.Result
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
            subcommands = {
                {
                    name = "list",
                    aliases = {"ls"},
                    shortHelp = "show every mark with its count and first id",
                    run = function(_v: {string: any}, _parts: {string}): commands.Result
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
                    run = function(_v: {string: any}, _parts: {string}): commands.Result
                        ctx.marks = {}
                        debugcontext.pushEvent(ctx, "mark", {cleared = true})
                        return {ok = true, message = "cleared all marks", data = {}}
                    end,
                },
            },
            run = function(v: {string: any}, _parts: {string}): commands.Result
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
            run = function(v: {string: any}, _parts: {string}): commands.Result
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
                local p = pipeline()
                if t and p then
                    p:getCamera():setPosition(t.x, t.y)
                end
                return {ok = true, message = "goto -> #" .. tostring(firstId),
                    data = {id = firstId, x = t and t.x or 0, y = t and t.y or 0}}
            end,
        },
        {
            name = "note",
            section = "Select",
            shortHelp = "annotate the selected entities for the agent; empty message clears",
            mcpHelp = "Attach a note to the selected entities, visible in-game above them and in get_debug_context. Use it to flag findings for the operator. An empty message clears notes on the selection.",
            schema = noteSchema,
            examples = {"note flickers when hit", "note  (clear notes)"},
            run = function(v: {string: any}, _parts: {string}): commands.Result
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
            run = function(v: {string: any}, _parts: {string}): commands.Result
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
            run = function(v: {string: any}, _parts: {string}): commands.Result
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
            name = "remove",
            section = "Edit",
            complete = {[1] = "edittargets", [0] = "components"},
            shortHelp = "remove components from an entity, marked group, or " .. EDIT_SELECTION_TARGET,
            mcpHelp = "Strip the named components from the target entities (an id, a mark name, or @selection). Destructive to component data; the entities survive. Returns how many entities were changed.",
            schema = removeSchema,
            examples = {"remove 5 Velocity", "remove @selection Burning Stunned", "remove boss Shield"},
            run = function(v: {string: any}, _parts: {string}): commands.Result
                local ids, terr = resolveEditTargets(v)
                if not ids then
                    return {ok = false, code = "no_match", message = "remove: " .. terr}
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
                EDIT_SELECTION_TARGET .. " (Lua table value)",
            mcpHelp = "Write one component on the target entities (an id, a mark name, or the literal @selection). The value is a Lua table expression, e.g. {x = 10, y = {n = 2}}; omitted fields keep their values. Mutates the live world immediately. Returns how many entities were written.",
            schema = setSchema,
            examples = {"set 5 Transform {x = 10, y = 20}", "set @selection Color {r = 1, g = 0, b = 0}",
                "set boss Shield"},
            run = function(v: {string: any}, _parts: {string}): commands.Result
                local ids, terr = resolveEditTargets(v)
                if not ids then
                    return {ok = false, code = "no_match", message = "set: " .. terr}
                end
                local compName = v.comp as string
                local comp, cerr = componentFor(compName)
                if not comp then
                    return {ok = false, code = "unknown_component", message = "set: " .. cerr}
                end
                -- The value arrives as a JSON object over MCP or as a Lua
                -- table expression from the command line.
                local dataTbl: {string: any} = {}
                if type(v.value) == "table" then
                    dataTbl = v.value as {string: any}
                elseif type(v.value) == "string" and (v.value as string) ~= "" then
                    local parsed, verr = evalTable(v.value as string)
                    if not parsed then
                        return {ok = false, code = "invalid_arguments", message = "set: " .. verr}
                    end
                    dataTbl = parsed
                end
                local count = 0
                local firstError: string = nil
                for i = 1, #ids do
                    local eid = ids[i]
                    if w:isAlive(eid) then
                        -- A fresh instance per entity: FFI cdata must never be
                        -- shared across rows.
                        local results = {pcall(function()
                            w:set(eid, comp.deserialize(w, dataTbl))
                        end)}
                        local ok2 = results[1]
                        local err2 = results[2]
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
            name = "spawn",
            section = "Edit",
            complete = {[1] = "bundles,components", [0] = "components"},
            shortHelp = "spawn an entity from a bundle and/or components with Lua table values",
            mcpHelp = "Spawn one entity from a bundle name and/or component list with Lua table values, e.g. 'Transform {x = 10, y = 20}'. The new entity becomes selected. Returns its id.",
            schema = spawnSchema,
            examples = {"spawn Transform {x = 100, y = 50}", "spawn enemy Transform {x = 0, y = 0}",
                "spawn ball"},
            run = function(v: {string: any}, _parts: {string}): commands.Result
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
            name = "query",
            section = "Select",
            aliases = {"q"},
            complete = {[0] = "components"},
            shortHelp = "select entities matching a component query: Foo has it, -Foo lacks it",
            mcpHelp = "Select every entity matching a component expression ('Enemy -Dead' means has Enemy, lacks Dead); invert=true instead de-selects matching entities from the current selection. Returns the match count. Follow with debug_info or debug_set on @selection.",
            schema = querySchema,
            examples = {"query Position Velocity -Dead",
                "query Dead invert=true  (de-select dead entities)"},
            run = function(v: {string: any}, _parts: {string}): commands.Result
                return runQuery(v.expr as string, v.invert as boolean)
            end,
        },
        {
            name = "draw",
            section = "Edit",
            shortHelp = "draw a world-space annotation over the game",
            examples = {"draw rect 10 10 64 48", "draw circle 0 0 20 entity=42 r=0 b=1",
                "draw text 5 -30 spawn point here", "draw clear paths"},
            subcommands = {
                {
                    name = "rect",
                    shortHelp = "outline a rectangle (x y w h in world units)",
                    schema = drawRectSchema,
                    run = function(v: {string: any}, _parts: {string}): commands.Result
                        local id = env.annotations:add(makeAnnotation(v, "rect"))
                        return {ok = true, message = "drew rect #" .. tostring(id),
                            data = {id = id, tag = v.tag}}
                    end,
                },
                {
                    name = "circle",
                    shortHelp = "outline a circle (x y radius in world units)",
                    schema = drawCircleSchema,
                    run = function(v: {string: any}, _parts: {string}): commands.Result
                        local id = env.annotations:add(makeAnnotation(v, "circle"))
                        return {ok = true, message = "drew circle #" .. tostring(id),
                            data = {id = id, tag = v.tag}}
                    end,
                },
                {
                    name = "line",
                    shortHelp = "draw a line (x y x2 y2 in world units)",
                    schema = drawLineSchema,
                    run = function(v: {string: any}, _parts: {string}): commands.Result
                        local id = env.annotations:add(makeAnnotation(v, "line"))
                        return {ok = true, message = "drew line #" .. tostring(id),
                            data = {id = id, tag = v.tag}}
                    end,
                },
                {
                    name = "text",
                    shortHelp = "print text at a world position",
                    schema = drawTextSchema,
                    run = function(v: {string: any}, _parts: {string}): commands.Result
                        local id = env.annotations:add(makeAnnotation(v, "text"))
                        return {ok = true, message = "drew text #" .. tostring(id),
                            data = {id = id, tag = v.tag}}
                    end,
                },
                {
                    name = "clear",
                    aliases = {"rm"},
                    shortHelp = "remove annotations by id or tag; everything when omitted",
                    schema = drawClearSchema,
                    run = function(v: {string: any}, _parts: {string}): commands.Result
                        local id: integer = nil
                        if v.id ~= nil then id = math.floor(v.id as number) as integer end
                        local n = env.annotations:clear(v.tag as string, id)
                        return {ok = true, message = "cleared " .. tostring(n) .. " annotation(s)",
                            data = {cleared = n}}
                    end,
                },
            },
        },
        {
            name = "ids",
            section = "Select",
            shortHelp = "toggle entity id labels over on-screen entities",
            schema = idsSchema,
            examples = {"ids", "ids on", "ids off"},
            run = function(v: {string: any}, _parts: {string}): commands.Result
                local want = v.on as boolean
                if want == nil then want = not ctx.showIds end
                ctx.showIds = want
                return {ok = true,
                    message = want and "entity ids on (up to 200 labels)" or "entity ids off",
                    data = {shown = want}}
            end,
        },
        {
            name = "history",
            section = "Session",
            shortHelp = "show the command history (persisted across sessions)",
            examples = {"history", "history clear"},
            subcommands = {
                {
                    name = "clear",
                    aliases = {"rm"},
                    shortHelp = "forget the history and delete its file",
                    run = function(_v: {string: any}, _parts: {string}): commands.Result
                        local n = #reg.history
                        reg.history = {}
                        love.filesystem.remove(HISTORY_FILE)
                        return {ok = true, message = "cleared " .. tostring(n) .. " history entries",
                            data = {cleared = n}}
                    end,
                },
            },
            run = function(_v: {string: any}, _parts: {string}): commands.Result
                if #reg.history == 0 then
                    return {ok = true, message = "no history yet", data = {history = reg.history}}
                end
                local popup: {string} = {"history  (newest last; up/down to walk):"}
                local first = math.max(1, #reg.history - 30 + 1)
                for i = first, #reg.history do
                    popup[#popup + 1] = "  " .. reg.history[i]
                end
                return {ok = true, popup = popup, data = {history = reg.history}}
            end,
        },
        {
            name = "agent",
            section = "Session",
            shortHelp = "MCP session info and client config",
            examples = {"agent info", "agent connect"},
            subcommands = {
                {
                    name = "info",
                    shortHelp = "show the MCP URL, tool count, and save directory",
                    run = function(_v: {string: any}, _parts: {string}): commands.Result
                        local info = w.resources[mcpinfo.KEY]
                        if not info then
                            return {ok = false, code = "no_mcp", message = "agent: MCP plugin not installed"}
                        end
                        local port = info.port()
                        local url = (port ~= 0) and ("http://localhost:" .. tostring(port) .. "/mcp") or "(binding...)"
                        return {ok = true, popup = {
                            "agent session",
                            "  mcp url\t" .. url,
                            "  tools\t" .. tostring(info.toolCount()),
                            "  save dir\t" .. love.filesystem.getSaveDirectory(),
                            "  identity\t" .. tostring(love.filesystem.getIdentity()),
                        }, data = {url = url, port = port, tools = info.toolCount(),
                            saveDir = love.filesystem.getSaveDirectory()}}
                    end,
                },
                {
                    name = "connect",
                    shortHelp = "copy the MCP client config JSON to the clipboard",
                    run = function(_v: {string: any}, _parts: {string}): commands.Result
                        local info = w.resources[mcpinfo.KEY]
                        if not info then
                            return {ok = false, code = "no_mcp", message = "agent: MCP plugin not installed"}
                        end
                        local port = info.port()
                        if port == 0 then
                            return {ok = false, code = "not_bound", message = "agent: MCP port not bound yet"}
                        end
                        local cfg = '{"type":"http","url":"http://localhost:' .. tostring(port) .. '/mcp"}'
                        love.system.setClipboardText(cfg)
                        return {ok = true, message = "MCP client config copied to clipboard: " .. cfg,
                            data = {config = cfg, port = port}}
                    end,
                },
            },
        },
        {
            name = "capabilities",
            section = "Session",
            shortHelp = "installed plugins, command families, and host features",
            mcpHelp = "What this game session supports: installed plugins (render pipeline, physics, tilemaps, controllers, audio, assets, recorder), command sections with counts, capture facilities, host OS, and the MCP port. Call once after connecting to learn which tool families apply.",
            examples = {"capabilities"},
            run = function(_v: {string: any}, _parts: {string}): commands.Result
                -- Plugin presence by resource probe, never by requiring the
                -- plugin modules (that would register their components).
                local function hasPhysics(): boolean
                    for _, value in pairs(w.resources as {any: any}) do
                        if type(value) == "table" then
                            local t = value as {string: any}
                            if t.world ~= nil and t.smoothing ~= nil then
                                return true
                            end
                        end
                    end
                    return false
                end
                local tilemapComp = componentFor("Tilemap")
                local tilemapCount = 0
                if tilemapComp then
                    w:forEachArchetype(function(arch: tecs.Archetype)
                        local col = arch:get(tilemapComp)
                        if col then
                            tilemapCount = tilemapCount + (arch.entities[0] as integer)
                        end
                    end)
                end
                local controllerkey = require("tecs2d.controller")
                local assetsmod = require("tecs2d.assets")
                local audiomod = require("tecs2d.audio")
                local plugins: {string: any} = {
                    pipeline = pipeline() ~= nil,
                    physics = hasPhysics(),
                    tilemaps = tilemapCount,
                    controllers = w.resources[controllerkey as tecs.Key<any>] ~= nil,
                    assets = w.resources[assetsmod] ~= nil,
                    audio = w.resources[audiomod] ~= nil,
                    recorder = env.recorder ~= nil,
                }
                local sections: {string: integer} = {}
                for _, c in ipairs(reg.list) do
                    local section = c.section or "Custom"
                    sections[section] = (sections[section] or 0) + 1
                end
                local osName = love.system.getOS()
                local info = w.resources[mcpinfo.KEY]
                local popup: {string} = {"capabilities:"}
                local names: {string} = {}
                for nm in pairs(plugins) do names[#names + 1] = nm end
                table.sort(names)
                for _, nm in ipairs(names) do
                    popup[#popup + 1] = "  " .. nm .. "\t" .. tostring(plugins[nm])
                end
                popup[#popup + 1] = "  commands\t" .. tostring(#reg.list)
                popup[#popup + 1] = "  host\t" .. tostring(osName)
                return {ok = true, popup = popup, data = {
                    plugins = plugins,
                    commands = {count = #reg.list, sections = sections},
                    capture = {snapshots = true, diff = true, rewind = ctx.rewind.status},
                    host = {os = osName,
                        posix = osName == "OS X" or osName == "Linux"},
                    mcp = info and {port = info.port(), tools = info.toolCount()} or nil,
                }}
            end,
        },
        {
            name = "describe",
            section = "Session",
            overlay = false,   -- the typed surface has `help <command>`
            complete = {[1] = "commands"},
            shortHelp = "one command's full contract as structured data",
            mcpHelp = "The complete contract of one debugger command: signature, help, argument schema, subcommand verbs with their schemas and safety annotations, and examples. Use it before calling an unfamiliar debug_* tool, or to discover verbs of a family.",
            schema = { args = { command = {required = true, help = "command name"} },
                positional = {"command"} },
            run = function(v: {string: any}, _parts: {string}): commands.Result
                local q = v.command as string
                local c = reg.byName[q]
                if not c then
                    return {ok = false, code = "unknown_command",
                        message = "describe: no such command '" .. q .. "'"}
                end
                local emptySchema: {string: any} = {
                    type = "object",
                    properties = json.EMPTY_OBJECT,
                    additionalProperties = false,
                }
                local subs: {{string: any}} = {}
                for _, sub in ipairs(c.subcommands or {}) do
                    subs[#subs + 1] = {
                        name = sub.name,
                        shortHelp = sub.shortHelp,
                        mcpHelp = sub.mcpHelp,
                        tool = (sub.mcp ~= false) and ("debug_" .. c.name .. "_" .. sub.name) or nil,
                        inputSchema = sub.schema and cmdargs.toolSchema(sub.schema) or emptySchema,
                        annotations = toolAnnotations(c.name, sub.name, sub.annotations),
                    }
                end
                return {ok = true, popup = commands.usagePopup(c), data = {
                    name = c.name,
                    signature = commands.commandSignature(c),
                    section = c.section or "Custom",
                    shortHelp = c.shortHelp,
                    mcpHelp = c.mcpHelp,
                    tool = (c.mcp ~= false and c.run ~= nil) and ("debug_" .. c.name) or nil,
                    inputSchema = c.schema and cmdargs.toolSchema(c.schema) or emptySchema,
                    annotations = toolAnnotations(c.name, nil, c.annotations),
                    subcommands = subs,
                    examples = c.examples,
                }}
            end,
        },
        {
            name = "step",
            section = "Session",
            mcp = false,   -- agents use the step MCP tool (same freeze controller)
            shortHelp = "tick the game forward N frames while otherwise frozen",
            schema = stepSchema,
            run = function(v: {string: any}, _parts: {string}): commands.Result
                local n = math.max(1, math.floor(v.n as number)) as integer
                local ok, err = env.freeze:step(n)
                if not ok then
                    return {ok = false, code = "not_frozen", message = "step: " .. err}
                end
                return {ok = true, message = "stepping " .. tostring(n) .. " frame(s)",
                    data = {frames = n}}
            end,
        },
        {
            name = "exit",
            section = "Session",
            mcp = false,
            shortHelp = "close the debugger (same as the toggle key)",
            run = function(_v: {string: any}, _parts: {string}): commands.Result
                reg.signals.action = "exit"
                return {ok = true, message = ""}
            end,
        },
        {
            name = "quit",
            section = "Session",
            mcp = false,   -- the quit MCP tool exists
            shortHelp = "quit the game",
            run = function(_v: {string: any}, _parts: {string}): commands.Result
                reg.signals.action = "quit"
                return {ok = true}
            end,
        },
    }

    -- Shared context for the command groups (internal/cmd/*). The registry
    -- itself is passed as the narrower RegSlice view.
    local d: cmdtypes.Deps = {
        world = w,
        ctx = ctx,
        env = env,
        reg = (reg as any) as cmdtypes.RegSlice,
        pipeline = pipeline,
        componentFor = componentFor,
        resolveTargets = resolveTargets,
        makeAnnotation = makeAnnotation,
        tileAt = commands.tileAt,
        summarizeProfile = summarizeProfile,
        systemZoneIds = systemZoneIds,
        onOffSchema = onOffSchema,
        nameSchema = nameSchema,
        refSchema = refSchema,
        targetSchema = targetSchema,
        optionalTargetSchema = optionalTargetSchema,
        selectionTarget = EDIT_SELECTION_TARGET,
    }
    for _, group in ipairs({rendercmds.commands(d), enginecmds.commands(d),
            capturecmds.commands(d)}) do
        for _, c in ipairs(group) do
            cmds[#cmds + 1] = c
        end
    end

    for i = 1, #cmds do
        reg:add(cmds[i])
    end
    return reg
end

function commands.tileAt(w: tecs.World, ctx: debugcontext.Context, wx: number, wy: number): integer, integer, number, number, number, number
    local tw, th, ox, oy = 0.0, 0.0, 0.0, 0.0
    local okC, chunkComp = pcall(tecs.componentByName, "TileChunk")
    if okC and chunkComp then
        w:forEachArchetype(function(arch: tecs.Archetype)
            if tw > 0 then return end
            local col = arch:get(chunkComp) as {any}
            local n = arch.entities[0] as integer
            if col and n > 0 then
                local c = col[1] as {string: number}
                tw, th = c.tileWidth, c.tileHeight
                local tcol = arch:get(Transform)
                local t = tcol and tcol[1]
                if t then ox, oy = t.x, t.y end
            end
        end)
    end
    if tw <= 0 and ctx.gridEnabled and ctx.gridW > 0 then
        tw, th = ctx.gridW, ctx.gridH
        ox, oy = ctx.gridOX, ctx.gridOY
    end
    if tw <= 0 or th <= 0 then return nil, nil, 0, 0, 0, 0 end
    return math.floor((wx - ox) / tw) as integer, math.floor((wy - oy) / th) as integer,
        tw, th, ox, oy
end

function commands.flattenOutput(lines: {string}): string
    local out: {string} = {}
    for i = 1, #lines do
        local line = lines[i]
        if line == commands.HRULE then
            out[#out + 1] = "----"
        else
            out[#out + 1] = (line:gsub("\t", "  "))
        end
    end
    return table.concat(out, "\n")
end

function commands.Registry:add(cmd: commands.Command)
    if type(cmd.name) ~= "string" or cmd.name == "" or cmd.name:find("%s") then
        error("commands: a command needs a name without spaces")
    end
    if type(cmd.shortHelp) ~= "string" or cmd.shortHelp == "" then
        error("commands: '" .. cmd.name .. "' needs a shortHelp")
    end
    if not cmd.run and not cmd.subcommands then
        error("commands: '" .. cmd.name .. "' needs a run action or subcommands")
    end
    if self.byName[cmd.name] then
        error("commands: '" .. cmd.name .. "' is already registered")
    end
    if cmd.schema then cmdargs.validate(cmd.schema) end
    if cmd.subcommands then
        local seen: {string: boolean} = {}
        for _, sub in ipairs(cmd.subcommands) do
            if type(sub.name) ~= "string" or sub.name == "" or sub.name:find("%s") then
                error("commands: '" .. cmd.name .. "' has a subcommand without a valid name")
            end
            if seen[sub.name] then
                error("commands: '" .. cmd.name .. " " .. sub.name .. "' is declared twice")
            end
            seen[sub.name] = true
            if sub.schema then cmdargs.validate(sub.schema) end
        end
    end
    if cmd.aliases then
        for _, a in ipairs(cmd.aliases) do
            if self.byName[a] then
                error("commands: alias '" .. a .. "' of '" .. cmd.name .. "' is already registered")
            end
        end
    end
    self.list[#self.list + 1] = cmd
    -- overlay = false keeps the command out of the typed surface entirely
    -- (no dispatch, no help listing, no completion): an MCP-only command.
    if cmd.overlay ~= false then
        self.byName[cmd.name] = cmd
        self.names[#self.names + 1] = cmd.name
        if cmd.aliases then
            for _, a in ipairs(cmd.aliases) do
                self.byName[a] = cmd
            end
        end
    end
end

function commands.register(w: tecs.World, cmd: commands.Command)
    local registry = w.resources[commands.KEY]
    if not registry then
        error("commands.register: the debug plugin is not installed on this world " ..
            "(world:addPlugin(require(\"tecs2d.debug\").new()) first)")
    end
    registry:add(cmd)
end

function commands.Registry:despawnSelected(): integer
    local env = self.env
    local ctx = env.ctx
    local c = 0
    for i = 1, #ctx.selected do
        local eid = ctx.selected[i]
        if env.world:isAlive(eid) then
            env.world:despawn(eid)
            ctx.marks[eid] = nil
            ctx.notes[eid] = nil
            c = c + 1
        end
    end
    ctx.selected = {}
    debugcontext.pushEvent(ctx, "selection", {selected = 0, despawned = c})
    return c
end

function commands.Registry:appendHistory(text: string)
    if text == "" or self.history[#self.history] == text then return end
    self.history[#self.history + 1] = text
    if #self.history > HISTORY_CAP then
        table.remove(self.history, 1)
    end
    love.filesystem.write(HISTORY_FILE, table.concat(self.history, "\n") .. "\n")
end

function commands.Registry:complete(text: string): string, {string}
    local out: {string} = {}
    local head, prefix = text:match("^(.*%s)(%S*)$")
    if not head then
        -- Completing the command name itself; keep registry order within each
        -- section so cycling is stable (help first, quit last). The full
        -- listing (empty prefix) is grouped with section separators; a typed
        -- prefix returns plain matches.
        prefix = text
        if prefix == "" then
            for _, section in ipairs(SECTION_ORDER) do
                local start = #out
                for i = 1, #self.names do
                    local c = self.byName[self.names[i]]
                    if c and (c.section or "Custom") == section then
                        out[#out + 1] = self.names[i]
                    end
                end
                if #out > start then
                    table.insert(out, start + 1, commands.SECTION_MARK .. section)
                end
            end
            return "", out
        end
        for i = 1, #self.names do
            if self.names[i]:sub(1, #prefix) == prefix then
                out[#out + 1] = self.names[i]
            end
        end
        return "", out
    end

    local toks = cmdargs.tokenize(head)
    if not toks or #toks == 0 then return head, out end
    local cmd = self.byName[toks[1]]
    if not cmd then return head, out end

    -- The word being completed sits at argument position #toks relative to
    -- the command, shifting by one once a subcommand verb is routed.
    local argIndex = #toks
    local completeMap = cmd.complete
    local routedSub: commands.Subcommand = nil
    if cmd.subcommands and toks[2] then
        routedSub = findSubcommand(cmd, toks[2])
        if routedSub then
            completeMap = routedSub.complete
            argIndex = #toks - 1
        end
    end

    local candidates: {string} = {}
    if argIndex == 1 and cmd.subcommands and not routedSub then
        for _, sub in ipairs(cmd.subcommands) do
            candidates[#candidates + 1] = sub.name
        end
    end
    if completeMap then
        local src = completeMap[argIndex] or completeMap[0]
        if src then
            for name in src:gmatch("[^,]+") do
                local list = self:candidatesFor(name)
                for i = 1, #list do candidates[#candidates + 1] = list[i] end
            end
        end
    end

    local seen: {string: boolean} = {}
    for i = 1, #candidates do
        local c = candidates[i]
        if c:sub(1, #prefix) == prefix and not seen[c] then
            seen[c] = true
            out[#out + 1] = c
        end
    end
    return head, out
end


-- Stop the active sampler, write the collapsed stacks, summarize the top
-- self-sample frames (and derived zones), and publish the path to the context.
-- Returns the results popup for the overlay to show, or nil with no session.
function commands.Registry:finishProfile(): {string}
    local prof = self.profiler
    if not prof.session then return nil end
    local ctx = self.env.ctx
    local text = prof.session:stop()
    prof.session = nil
    prof.deadline = 0.0
    prof.counter = prof.counter + 1
    local name = "debug-profile-" .. tostring(prof.counter) .. ".collapsed"
    local f = io.open(name, "w")
    if f then
        f:write(text)
        f:close()
    end
    ctx.profiles[#ctx.profiles + 1] = {path = name, size = #text, time = os.time()}

    local popup, top = summarizeProfile(text, name, systemZoneIds(self.env.world))
    ctx.profileTop = top
    debugcontext.setStatus(ctx, "profile saved at " .. debugcontext.savePath(name))
    debugcontext.pushEvent(ctx, "profile", {path = name})
    self.env.world:emit(0, debugcontext.OnDebugContext("profile", name, 0))
    return popup
end

return commands
