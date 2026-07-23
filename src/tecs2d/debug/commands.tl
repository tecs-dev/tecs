--- The debugger command registry: one declaration per command (schema, help,
--- subcommands, action) shared by both surfaces. The overlay tokenizes a typed
--- line and dispatches through execute(); the MCP server projects the same
--- registry to cmd_* tools (mcpTools) and dispatches JSON args through
--- invokeMcp(). Actions receive parsed, typed values and return a Result whose
--- `data` is the canonical structured payload; `popup` is overlay presentation.
---
--- Games can add their own commands with commands.register(world, cmd) after
--- installing the debug plugin. A registered command gets the same treatment
--- as the builtins: schema-parsed arguments, generated help and completion in
--- the overlay, and a cmd_<name> MCP tool. The `overlay` and `mcp` flags
--- scope a command to one surface. Read the live debugger state (selection,
--- marks, notes) through world.resources[require("tecs2d.debug.context").KEY].
---
--- Commands adapt values to services (recorder, freeze controller, world);
--- heavy machinery does not live here.

local tecs <const> = require("tecs")
local componentregistry <const> = require("tecs.internal.components")
local json <const> = require("tecs.utils.json")
local systemcontrol <const> = require("tecs2d.internal.systemcontrol")
local logtap <const> = require("tecs2d.internal.logtap")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")
local worldregistry <const> = require("tecs2d.gfx.internal.worldregistry")
local gfxtypes <const> = require("tecs2d.gfx.types")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local cmdtypes <const> = require("tecs2d.debug.internal.cmdtypes")
local markup <const> = require("tecs2d.debug.internal.markup")
local breakpoints <const> = require("tecs2d.debug.internal.breakpoints")
local breakpointcmds <const> = require("tecs2d.debug.internal.cmd.breakpoint")
local capturecmds <const> = require("tecs2d.debug.internal.cmd.capture")
local editcmds <const> = require("tecs2d.debug.internal.cmd.edit")
local enginecmds <const> = require("tecs2d.debug.internal.cmd.engine")
local rendercmds <const> = require("tecs2d.debug.internal.cmd.render")
local selectcmds <const> = require("tecs2d.debug.internal.cmd.select")
local sessioncmds <const> = require("tecs2d.debug.internal.cmd.session")

local format <const> = string.format

local Transform <const> = tecs.builtins.Transform

--- The action a projected cmd_* tool name dispatches to: the argument
--- schema (nil when the action takes none) and the run function.
local record ToolEntry
    schema: cmdargs.Schema
    run: function(v: {string: any}, parts: {string}): cmdtypes.Result
end

local record commands
    --- Sentinel popup line drawn as a horizontal rule rather than text.
    HRULE: string

    --- Flatten popup lines into clipboard text: tabs become spaces and
    --- rules become dashes. Used by the overlay's leader+Y yank.
    flattenOutput: function(lines: {string}): string

    --- Tile grid at a world point: the first TileChunk's size and origin,
    --- else the enabled debug grid. Returns tile x, tile y, tile width and
    --- height, and grid origin x and y, or nil when no grid source exists.
    --- Shared by the `tile` command and the overlay's context menu.
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
        --- Overlay dispatch by name; excludes MCP-only commands
        --- (overlay = false).
        byName: {string: Command}
        --- Every registered command regardless of surface; backs the
        --- duplicate-registration check and MCP dispatch.
        allByName: {string: Command}
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

        --- Monotonic diff artifact number.
        diffCounter: integer

        --- The last executed result's popup (or message) for the overlay's
        --- leader+Y yank. Stored at execute time so contextual command help
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

        --- The results popup of a timed profile's auto-finish, stored by
        --- debug.CoreTick when the deadline passes so timed profiles finish
        --- headless. The overlay's input system consumes it: reopen the
        --- debugger if closed, show the popup, clear the field.
        profileResult: {string}

        --- A breakpoint hit waiting for the overlay to reopen and present it.
        breakpointResult: Result

        --- cmd_* tool name to its dispatch entry; built lazily on the
        --- first invokeMcp and appended by add().
        byToolName: {string: ToolEntry}

        --- The registry projected as MCP tool definitions (cmd_* names).
        mcpTools: function(self: Registry): {McpTool}

        --- Dispatch an MCP tool call by its cmd_* name with JSON args.
        --- Returns nil + error when the name is unknown.
        invokeMcp: function(self: Registry, name: string, args: {string: any}): Result, string

        --- Add a command to the registry. Raises on a duplicate name or
        --- an invalid schema, since a bad registration is a programming error.
        add: function(self: Registry, cmd: Command)

        --- Append an executed command line to the history (skipping immediate
        --- repeats) and persist the tail to the save directory.
        appendHistory: function(self: Registry, text: string)

        --- Schema-driven completion for a partial command line: returns the
        --- text up to the word being completed and candidate replacements for
        --- command names, verbs, argument keys, and argument values.
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
    --- generated help and Tab completion in the overlay, and a cmd_<name>
    --- MCP tool (set mcp = false for overlay-only, overlay = false for
    --- MCP-only). Raises when the debug plugin is missing or the command is
    --- invalid.
    register: function(w: tecs.World, cmd: Command)

    --- Wrap a command's data schema in the {ok, result, error} envelope the
    --- MCP server sends, so projected structuredContent validates against it.
    wrapOutputSchema: function(dataSchema: {string: any}): {string: any}

    --- The command's name plus its generated signature, e.g. "goto <id|name>".
    commandSignature: function(c: Command): string

    subSignature: function(c: Command, sub: Subcommand): string

    --- Popup lines describing a command: signature, help, arguments,
    --- subcommands, and examples. Used by `help <name>` and overlay F1 help.
    usagePopup: function(c: Command): {string}

    --- Typed popup help consumed by F1 and `help <command>`.
    usageDocument: function(c: Command): markup.Document

    SECTIONS: {string}
    SECTION_COLORS: {string: {number}}
    SECTION_COLORS_BAR: {string: {number}}
end

commands.HRULE = cmdtypes.HRULE
commands.KEY = tecs.newKey("tecs2d.debug.commands")

--- Sentinel prefix marking a section separator in a completion list; the
--- overlay renders it as " | Name | " and skips it while cycling.
commands.SECTION_MARK = cmdtypes.SECTION_MARK

--- Canonical section order and accent colors, shared with the overlay and
--- the docs generator.
commands.SECTIONS = cmdtypes.SECTIONS
commands.SECTION_COLORS = cmdtypes.SECTION_COLORS
commands.SECTION_COLORS_BAR = cmdtypes.SECTION_COLORS_BAR

local HISTORY_FILE <const> = "debug-history.txt"
local HISTORY_CAP <const> = 100

-------------------------------------------------------------------------------
-- Schemas
-------------------------------------------------------------------------------

-- A target given as an entity id or a mark name, sharing one positional
-- slot. Entries of `extra` (may be nil) merge into the argument specs.
local function makeTargetSchema(required: boolean, extra: {string: cmdargs.ArgSpec}): cmdargs.Schema
    local args: {string: cmdargs.ArgSpec} = {
        id = {kind = "number", forward = "target", help = "entity id"},
        name = {forward = "target", completion = "targets", help = "mark name"},
        target = {synthetic = {"id", "name"}, required = required,
            completion = "targets", help = "entity id or mark name"},
    }
    if extra then
        for k, v in pairs(extra) do args[k] = v end
    end
    local schema: cmdargs.Schema = {args = args, positional = {"target"}}
    cmdargs.validate(schema)
    return schema
end

local targetSchema <const> = makeTargetSchema(true, nil)
local optionalTargetSchema <const> = makeTargetSchema(false, nil)

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

local onOffSchema <const>: cmdargs.Schema = {
    args = { on = {kind = "boolean", help = "enable or disable; omit to toggle"} },
    positional = {"on"},
}
cmdargs.validate(onOffSchema)

--- The literal target meaning "the current selection" in entity-edit
--- commands and their Tab completion.
local EDIT_SELECTION_TARGET <const> = "@selection"

-------------------------------------------------------------------------------
-- Presentation helpers
-------------------------------------------------------------------------------

-- Signature lines cap at 120 characters so a wide argument list cannot
-- flood the help popup or the generated reference headings.
local SIGNATURE_CAP <const> = 120

local function capSignature(sig: string): string
    if #sig > SIGNATURE_CAP then
        return sig:sub(1, SIGNATURE_CAP - 3) .. "..."
    end
    return sig
end

function commands.commandSignature(c: commands.Command): string
    local sig = c.name
    if c.schema then
        local s = cmdargs.signature(c.schema)
        if s ~= "" then sig = c.name .. " " .. s end
    end
    return capSignature(sig)
end

function commands.subSignature(c: commands.Command, sub: commands.Subcommand): string
    local sig = c.name .. " " .. sub.name
    if sub.schema then
        local s = cmdargs.signature(sub.schema)
        if s ~= "" then sig = sig .. " " .. s end
    end
    return capSignature(sig)
end

function commands.usageDocument(c: commands.Command): markup.Document
    local document = markup.new(commands.commandSignature(c))
    markup.text(document, c.shortHelp)
    if c.schema or c.subcommands then
        markup.rule(document)
    end
    if c.schema then
        markup.section(document, "Arguments")
        for _, definition in ipairs(cmdargs.argDefinitions(c.schema)) do
            markup.definition(document, definition.term, definition.description)
        end
    end
    if c.subcommands then
        markup.section(document, "Subcommands")
        for _, sub in ipairs(c.subcommands) do
            markup.definition(document, commands.subSignature(c, sub), sub.shortHelp)
        end
    end
    if c.examples and #c.examples > 0 then
        markup.section(document, "Examples")
        if #c.examples >= 4 then
            local half = math.ceil(#c.examples / 2) as integer
            local columns: {{markup.Line}} = {{}, {}}
            for i = 1, #c.examples do
                local ci = i <= half and 1 or 2
                columns[ci][#columns[ci] + 1] = markup.line(c.examples[i],
                    "code", "console")
            end
            markup.columns(document, columns, "auto")
        else
            for i = 1, #c.examples do
                markup.add(document, markup.line(c.examples[i], "code", "console"))
            end
        end
    end
    return document
end

function commands.usagePopup(c: commands.Command): {string}
    return markup.plainLines(commands.usageDocument(c))
end

local function titledUsage(c: commands.Command): commands.Result
    local document = commands.usageDocument(c)
    return {
        ok = true,
        popupDocument = document,
        popupModal = true,
        popupClosable = true,
    }
end

-------------------------------------------------------------------------------
-- Registry
-------------------------------------------------------------------------------

local function findSubcommand(cmd: commands.Command, subName: string): commands.Subcommand
    if not cmd.subcommands or not subName then return nil end
    for _, sub in ipairs(cmd.subcommands) do
        if sub.name == subName then return sub end
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
        if result.popupDocument then
            self.lastOutput = markup.plainLines(result.popupDocument)
        elseif result.popupMarkup then
            local document = markup.parse(result.popupMarkup)
            if document then self.lastOutput = markup.plainLines(document) end
        elseif result.popup then
            if result.popupTitle then
                local output: {string} = {result.popupTitle}
                for i = 1, #result.popup do output[#output + 1] = result.popup[i] end
                self.lastOutput = output
            else
                self.lastOutput = result.popup
            end
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

-- The server spreads Result.data into `result` next to `message` and sends
-- {ok = true, result = ...}; failures arrive as {ok = false, error}. A
-- command declares the schema of its data payload; the projected MCP
-- outputSchema wraps it in that envelope so structuredContent validates.
function commands.wrapOutputSchema(dataSchema: {string: any}): {string: any}
    if not dataSchema then return nil end
    local props: {string: any} = {}
    for k, v in pairs((dataSchema.properties as {string: any}) or {}) do props[k] = v end
    props.message = {type = "string", description = "human-readable summary"}
    local result: {string: any} = {}
    for k, v in pairs(dataSchema) do result[k] = v end
    result.properties = props
    return {
        type = "object",
        properties = {
            ok = {type = "boolean"},
            result = result,
            error = {type = "object", properties = {
                code = {type = "string"},
                message = {type = "string"},
            }},
        },
        required = {"ok"},
    }
end

-- The projected input schema of an action that takes no arguments.
local EMPTY_SCHEMA <const>: {string: any} = {
    type = "object",
    properties = json.EMPTY_OBJECT,
    additionalProperties = false,
}

-- Appended to every projected tool description.
local TOOL_SUFFIX <const> = " In-game debugger command; requires the debug plugin." ..
    " Returns compact JSON text envelope."

-- One command, or one of its subcommand verbs when `sub` is set, projected
-- as an MCP tool definition.
local function projectTool(cmd: commands.Command, sub: commands.Subcommand): commands.McpTool
    if sub then
        return {
            name = "cmd_" .. cmd.name .. "_" .. sub.name,
            description = (sub.mcpHelp or (cmd.name .. " " .. sub.name .. ": " ..
                sub.shortHelp .. ".")) .. TOOL_SUFFIX,
            inputSchema = sub.schema and cmdargs.toolSchema(sub.schema) or EMPTY_SCHEMA,
            outputSchema = commands.wrapOutputSchema(sub.outputSchema),
            annotations = toolAnnotations(cmd.name, sub.name, sub.annotations),
        }
    end
    return {
        name = "cmd_" .. cmd.name,
        description = (cmd.mcpHelp or (cmd.shortHelp .. ".")) .. TOOL_SUFFIX,
        inputSchema = cmd.schema and cmdargs.toolSchema(cmd.schema) or EMPTY_SCHEMA,
        outputSchema = commands.wrapOutputSchema(cmd.outputSchema),
        annotations = toolAnnotations(cmd.name, nil, cmd.annotations),
    }
end

-- Register one command's MCP-dispatchable actions in the tool-name index.
local function indexTools(index: {string: ToolEntry}, cmd: commands.Command)
    if cmd.mcp ~= false and cmd.run then
        index["cmd_" .. cmd.name] = {schema = cmd.schema, run = cmd.run}
    end
    if cmd.subcommands then
        for _, sub in ipairs(cmd.subcommands) do
            if sub.mcp ~= false then
                index["cmd_" .. cmd.name .. "_" .. sub.name] = {schema = sub.schema, run = sub.run}
            end
        end
    end
end

function commands.Registry:mcpTools(): {commands.McpTool}
    local out: {commands.McpTool} = {}
    for _, cmd in ipairs(self.list) do
        if cmd.mcp ~= false and cmd.run then
            out[#out + 1] = projectTool(cmd, nil)
        end
        if cmd.subcommands then
            for _, sub in ipairs(cmd.subcommands) do
                if sub.mcp ~= false then
                    out[#out + 1] = projectTool(cmd, sub)
                end
            end
        end
    end
    return out
end

function commands.Registry:invokeMcp(name: string, args: {string: any}): commands.Result, string
    local index = self.byToolName
    if not index then
        index = {}
        for _, cmd in ipairs(self.list) do
            indexTools(index, cmd)
        end
        self.byToolName = index
    end
    local entry = index[name]
    if not entry then
        return nil, "unknown debugger tool: " .. name
    end
    local values: {string: any} = {}
    if entry.schema then
        local v, err = cmdargs.parseValues(entry.schema, args)
        if not v then
            return {ok = false, code = "invalid_arguments", message = err}
        end
        values = v
    elseif next(args) ~= nil then
        return {ok = false, code = "invalid_arguments", message = "takes no arguments"}
    end
    return entry.run(values, {})
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
    if not w.resources[breakpoints.KEY] then
        w.resources[breakpoints.KEY] = breakpoints.new(w, env.suspension)
    end

    local reg: commands.Registry = {
        env = env,
        list = {},
        byName = {},
        allByName = {},
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
            return {math.floor(v.id as number)}
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

    local function worldFor(v: {string: any}): tecs.World, integer, string
        local requested = v.worldId as number
        if requested == nil then
            return w, w.resources[worldregistry.WORLD_ID] or 0, nil
        end
        local worldId = math.floor(requested) as integer
        if worldId == 0 and not w.resources[worldregistry.WORLD_ID] then
            return w, 0, nil
        end
        local target = worldregistry.resolve(worldId)
        if not target then
            return nil, worldId, "unknown or stale render worldId " .. tostring(worldId)
        end
        return target, worldId, nil
    end

    local function componentFor(nm: string): tecs.Component, string
        local ok, resolved = pcall(tecs.componentByName, nm)
        local comp = (ok and resolved) as tecs.Component
        if not comp then return nil, "unknown component '" .. nm .. "'" end
        return comp, nil
    end

    -- Live candidates for Tab-completion sources. Sources read current world
    -- or process state (marks, bundles, systems, cameras, loggers) at
    -- completion time.
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
        elseif source == "breakpointselectors" then
            return breakpoints.completionCandidates(w)
        elseif source == "breakpointids" then
            local manager = w.resources[breakpoints.KEY]
            if manager then
                for i = 1, #manager.entries do
                    out[#out + 1] = tostring(manager.entries[i].id)
                end
            end
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
        elseif source == "loggers" then
            return logtap.loggers()
        end
        return out
    end

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
        worldFor = worldFor,
        tileAt = commands.tileAt,
        summarizeProfile = summarizeProfile,
        systemZoneIds = systemZoneIds,
        onOffSchema = onOffSchema,
        nameSchema = nameSchema,
        refSchema = refSchema,
        targetSchema = targetSchema,
        optionalTargetSchema = optionalTargetSchema,
        makeTargetSchema = makeTargetSchema,
        selectionTarget = EDIT_SELECTION_TARGET,
        historyFile = HISTORY_FILE,
    }

    -- The Select, Edit, and Session groups own these builtin definitions;
    -- the cmds list below owns the registration order, which drives help
    -- listing, completion cycling, the MCP tool listing, and the generated
    -- reference.
    local groupCmds: {string: commands.Command} = {}
    for _, group in ipairs({selectcmds.commands(d), editcmds.commands(d),
            sessioncmds.commands(d)}) do
        for _, c in ipairs(group) do
            groupCmds[c.name] = c
        end
    end
    local function grouped(nm: string): commands.Command
        local c = groupCmds[nm]
        if not c then
            error("commands: builtin '" .. nm .. "' is missing from its command group")
        end
        return c
    end

    local cmds: {commands.Command} = {
        {
            name = "help",
            section = "Session",
            mcp = false,
            shortHelp = "list all commands, or show one command's arguments",
            schema = { args = { command = {completion = "commands",
                help = "command name"} }, positional = {"command"} },
            examples = {"help", "help record", "help select"},
            run = function(v: {string: any}, _parts: {string}): commands.Result
                local q = v.command as string
                if q then
                    local c = reg.byName[q]
                    if not c then
                        return {ok = false, code = "unknown_command",
                            message = "help: no such command '" .. q .. "'"}
                    end
                    return titledUsage(c)
                end
                local keys = env.keys
                local document = markup.new("debugger help")
                markup.text(document,
                    "Type [code]help <command>[/code] for command details.")
                markup.section(document, "Mouse")
                markup.definition(document, "click",
                    "replace the selection with the entity under the cursor")
                markup.definition(document, "shift+click",
                    "add the entity under the cursor to the selection")
                markup.definition(document, "drag",
                    "replace the selection with entities inside the rectangle")
                markup.definition(document, "shift+drag",
                    "add entities inside the rectangle to the selection")
                markup.definition(document, "ctrl+drag",
                    "move the selection; right-click cancels and restores")
                markup.definition(document, "right-click",
                    "open the context menu for an entity or world position")
                markup.definition(document, "middle-drag", "pan the camera")
                markup.definition(document, "wheel", "zoom toward the cursor")
                markup.section(document, "Keys")
                markup.definition(document, keys.leader .. "+" .. keys.debugToggle,
                    "open or close the debugger (freezes the game)")
                markup.definition(document, keys.leader .. "+" .. keys.statsToggle,
                    "toggle the stats HUD")
                markup.definition(document, keys.leader .. "+c",
                    "clear the command or popup")
                markup.definition(document, keys.leader .. "+y",
                    "yank the last command output to the clipboard")
                markup.definition(document, "escape",
                    "clear the command or popup, or close when empty")
                markup.definition(document, "tab / shift+tab",
                    "cycle completions (hold to repeat)")
                markup.definition(document, "f1",
                    "toggle command help (general help when empty)")
                markup.definition(document, "up / down", "walk command history")
                markup.definition(document, "page up / page down",
                    "scroll this popup by a page")
                markup.definition(document, "home / end",
                    "jump to the start or end of this popup")
                markup.definition(document, "enter", "run the command")
                markup.definition(document, "delete", "despawn the selection")
                markup.section(document, "Arguments")
                markup.text(document,
                    "Give arguments positionally or as [code]name=value[/code], in any order.")
                markup.text(document, "Positional arguments precede named arguments.")
                markup.text(document,
                    "Quote spaces: [code]mark \"big boss\"[/code] or [code]record name=\"my clip\"[/code].")
                markup.text(document,
                    "Flags are bare or boolean: [code]debug[/code], [code]debug=true[/code], [code]debug=off[/code].")
                markup.section(document, "Commands")
                for _, section in ipairs(cmdtypes.SECTIONS) do
                    local names: {string} = {}
                    for i = 1, #reg.names do
                        local c = reg.byName[reg.names[i]]
                        if c and (c.section or "Custom") == section then
                            names[#names + 1] = reg.names[i]
                        end
                    end
                    if #names > 0 then
                        markup.definition(document, section,
                            table.concat(names, ", "))
                    end
                end
                local hasSubcommands = false
                for i = 1, #reg.names do
                    local c = reg.byName[reg.names[i]]
                    if c and c.subcommands then
                        if not hasSubcommands then
                            markup.section(document, "Subcommands")
                            hasSubcommands = true
                        end
                        local verbs: {string} = {}
                        for _, sub in ipairs(c.subcommands) do
                            verbs[#verbs + 1] = sub.name
                        end
                        markup.definition(document, c.name,
                            table.concat(verbs, ", "))
                    end
                end
                return {
                    ok = true,
                    popupDocument = document,
                    popupModal = true,
                    popupClosable = true,
                }
            end,
        },
        grouped("select"),
        grouped("clear"),
        grouped("mark"),
        grouped("goto"),
        grouped("note"),
        grouped("info"),
        grouped("despawn"),
        grouped("remove"),
        grouped("set"),
        grouped("modify"),
        grouped("spawn"),
        grouped("query"),
        grouped("ids"),
        grouped("history"),
        grouped("agent"),
        grouped("step"),
        grouped("input_tape"),
        grouped("context"),
        grouped("restart"),
        grouped("quit"),
    }

    for _, group in ipairs({rendercmds.commands(d), enginecmds.commands(d),
            breakpointcmds.commands(d), capturecmds.commands(d)}) do
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
    if self.allByName[cmd.name] then
        error("commands: '" .. cmd.name .. "' is already registered")
    end
    if cmd.schema then cmdargs.validate(cmd.schema) end
    if cmd.metadata ~= nil and type(cmd.metadata) ~= "table" then
        error("commands: '" .. cmd.name .. "' metadata must be a table")
    end
    if cmd.outputSchema ~= nil and type(cmd.outputSchema) ~= "table" then
        error("commands: '" .. cmd.name .. "' outputSchema must be a table")
    end
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
            if sub.metadata ~= nil and type(sub.metadata) ~= "table" then
                error("commands: '" .. cmd.name .. " " .. sub.name .. "' metadata must be a table")
            end
            if sub.outputSchema ~= nil and type(sub.outputSchema) ~= "table" then
                error("commands: '" .. cmd.name .. " " .. sub.name .. "' outputSchema must be a table")
            end
        end
    end
    self.list[#self.list + 1] = cmd
    self.allByName[cmd.name] = cmd
    -- Keep the lazy MCP dispatch index current once it exists.
    if self.byToolName then
        indexTools(self.byToolName, cmd)
    end
    -- overlay = false keeps the command out of the typed surface entirely
    -- (no dispatch, no help listing, no completion): an MCP-only command.
    if cmd.overlay ~= false then
        self.byName[cmd.name] = cmd
        self.names[#self.names + 1] = cmd.name
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

local function completionKind(spec: cmdargs.ArgSpec): string
    if spec.kind then return spec.kind end
    if type(spec.default) == "boolean" then return "boolean" end
    if type(spec.default) == "number" then return "number" end
    return "string"
end

local function markCompletionArg(schema: cmdargs.Schema,
        used: {string: boolean}, name: string)
    if not name then return end
    used[name] = true
    local spec = schema.args[name]
    if not spec then return end
    if spec.forward then
        used[spec.forward] = true
        local target = schema.args[spec.forward]
        for _, member in ipairs((target and target.synthetic) or {}) do
            used[member] = true
        end
    end
    for _, member in ipairs(spec.synthetic or {}) do used[member] = true end
end

local function completionPosition(schema: cmdargs.Schema, tokens: {string}): integer,
        {string: boolean}
    local used: {string: boolean} = {}
    local position = 1
    for _, token in ipairs(tokens) do
        local name = token:match("^([%a_][%w_]*)=")
        if name and schema.args[name] then
            markCompletionArg(schema, used, name)
        else
            local positional = schema.positional or {}
            local slot = positional[position]
            if slot then
                markCompletionArg(schema, used, slot)
                local spec = schema.args[slot]
                if not spec.rest then position = position + 1 end
            end
        end
    end
    return position, used
end

local function quotedCompletion(value: string): string
    if not value:find("[%s\"\\]") then return value end
    return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
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
            for _, section in ipairs(cmdtypes.SECTIONS) do
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

    local routedSub: commands.Subcommand = nil
    if cmd.subcommands and toks[2] then
        routedSub = findSubcommand(cmd, toks[2])
    end

    if cmd.subcommands and not routedSub then
        for _, sub in ipairs(cmd.subcommands) do
            if sub.name:sub(1, #prefix) == prefix then
                out[#out + 1] = sub.name
            end
        end
        -- A command may have both a default action and named subcommands.
        -- Keep the matching verbs, then also complete the default schema.
        -- Subcommand-only parents stop here because they have no default
        -- argument surface to merge.
        if not cmd.run then return head, out end
    end

    local schema = routedSub and routedSub.schema or cmd.schema
    if not schema then return head, out end
    local firstArg = routedSub and 3 or 2
    local previous: {string} = {}
    for i = firstArg, #toks do previous[#previous + 1] = toks[i] end
    local position, used = completionPosition(schema, previous)

    local named, valuePrefix = prefix:match("^([%a_][%w_]*)=(.*)$")
    local spec: cmdargs.ArgSpec = nil
    local activeSlot: string = nil
    local outputPrefix = ""
    if named and schema.args[named] and not schema.args[named].synthetic then
        spec = schema.args[named]
        outputPrefix = named .. "="
    else
        local positional = schema.positional or {}
        local slot = positional[position]
        if slot and (not named or schema.args[slot].rest) then
            activeSlot = slot
            spec = schema.args[slot]
        end
        valuePrefix = prefix
    end

    local seen: {string: boolean} = {}
    local function add(value: string, rawPrefix: string, prefixOut: string)
        local negative = rawPrefix:sub(1, 1) == "-"
        local openedQuote = rawPrefix:sub(1, 1) == '"'
        local matchPrefix = rawPrefix
        if negative or openedQuote then matchPrefix = rawPrefix:sub(2) end
        if value:sub(1, #matchPrefix) ~= matchPrefix then return end
        local rendered = quotedCompletion(value)
        if negative then rendered = "-" .. rendered end
        local candidate = prefixOut .. rendered
        if not seen[candidate] then
            seen[candidate] = true
            out[#out + 1] = candidate
        end
    end

    local function addSpecValues(valueSpec: cmdargs.ArgSpec)
        local values: {string} = {}
        for _, value in ipairs(valueSpec.enum or {}) do values[#values + 1] = value end
        if completionKind(valueSpec) == "boolean" then
            values[#values + 1] = "on"
            values[#values + 1] = "off"
        end
        if valueSpec.completion then
            for source in valueSpec.completion:gmatch("[^,]+") do
                local live = self:candidatesFor(source)
                for i = 1, #live do values[#values + 1] = live[i] end
            end
        end
        for _, member in ipairs(valueSpec.synthetic or {}) do
            local memberSpec = schema.args[member]
            if memberSpec then
                for _, value in ipairs(memberSpec.enum or {}) do
                    values[#values + 1] = value
                end
                if completionKind(memberSpec) == "boolean" then
                    values[#values + 1] = "on"
                    values[#values + 1] = "off"
                end
                if memberSpec.completion then
                    for source in memberSpec.completion:gmatch("[^,]+") do
                        local live = self:candidatesFor(source)
                        for i = 1, #live do values[#values + 1] = live[i] end
                    end
                end
            end
        end
        for i = 1, #values do add(values[i], valuePrefix or "", outputPrefix) end
    end
    if spec then addSpecValues(spec) end

    if not named then
        local keys: {string} = {}
        for name, argSpec in pairs(schema.args) do
            if not argSpec.synthetic and not used[name] and name ~= activeSlot then
                keys[#keys + 1] = name .. "="
            end
        end
        table.sort(keys)
        for i = 1, #keys do
            if keys[i]:sub(1, #prefix) == prefix and not seen[keys[i]] then
                seen[keys[i]] = true
                out[#out + 1] = keys[i]
            end
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
    -- io.open writes to the process working directory, not the LÖVE save dir.
    debugcontext.setStatus(ctx, "profile saved at " ..
        love.filesystem.getWorkingDirectory() .. "/" .. name)
    debugcontext.pushEvent(ctx, "profile", {path = name})
    self.env.world:emit(0, debugcontext.OnDebugContext("profile", name, 0))
    return popup
end

return commands
