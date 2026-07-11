--- Shared record types for the debugger command registry. This is a leaf
--- module: tecs2d.debug.commands re-exports these types for its public API,
--- and the command-group modules (internal/cmd/*) depend on it instead of
--- commands, which keeps the require graph acyclic.

local tecs <const> = require("tecs")
local profile <const> = require("tecs.utils.profile")
local gfxtypes <const> = require("tecs2d.gfx.types")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local recording <const> = require("tecs2d.debug.internal.recording")
local freeze <const> = require("tecs2d.debug.internal.freeze")
local annotations <const> = require("tecs2d.debug.internal.annotations")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")

local record cmdtypes
    --- Sentinel popup line drawn as a horizontal rule rather than text.
    HRULE: string

    --- Prefix marking a section separator entry in completion candidates.
    SECTION_MARK: string

    --- The toggle keys, used by the help command's key listing.
    record Keys
        leader: string
        debugToggle: string
        statsToggle: string
    end

    --- Everything an action may touch. Built by the overlay at install time.
    record Env
        world: tecs.World
        ctx: debugcontext.Context
        recorder: recording.Controller
        freeze: freeze.Controller
        annotations: annotations.Store
        keys: Keys
    end

    --- What an action asks its surface to do. `data` is the canonical
    --- structured payload (the MCP tool result); `popup` is overlay-only
    --- presentation; ok=false marks a failure (code is machine-readable).
    --- popupImagePath names a save-dir image the overlay shows as a thumbnail
    --- for the popup's lifetime (screenshot info); MCP ignores it.
    record Result
        ok: boolean
        code: string
        message: string
        data: {string: any}
        popup: {string}
        popupImagePath: string
    end

    --- Surface-directed side effects an action may raise instead of poking
    --- overlay state: `action` is "exit" (close the panel) or "quit";
    --- hideOverlay hides the chrome for one frame (screenshots).
    record Signals
        action: string
        hideOverlay: boolean
    end

    --- One verb under a command (git/docker style), e.g. `snapshot save`.
    record Subcommand
        name: string
        aliases: {string}
        shortHelp: string
        schema: cmdargs.Schema
        examples: {string}
        -- When false the verb is not projected as an MCP tool.
        mcp: boolean
        -- Overrides for the derived MCP safety hints (partial; unset keys
        -- keep the derived value).
        annotations: ToolAnnotations
        -- Agent-facing tool description: when to use it, what it changes,
        -- what it returns, and what to call next. Falls back to shortHelp,
        -- which is written for the overlay's one-line hint.
        mcpHelp: string
        -- Optional Tab-completion sources by argument position (1 = the word
        -- after the verb; 0 = any later position). Comma-separated source
        -- names: "components", "marks", "targets", "edittargets", "bundles",
        -- "systems", "cameras", "commands".
        complete: {integer: string}
        -- JSON Schema for the Result.data payload. Projected over MCP as the
        -- tool's outputSchema (wrapped in the {ok, result} envelope) and
        -- rendered in the generated command reference.
        outputSchema: {string: any}
        -- Application-specific metadata; the engine never interprets it
        -- beyond documented keys. `screenshots` is a list of
        -- {file, alt, docs} entries; those with docs = true render as images
        -- in the generated command reference.
        metadata: {string: any}
        run: function(v: {string: any}, parts: {string}): Result
    end

    record Command
        name: string
        aliases: {string}
        shortHelp: string
        examples: {string}
        schema: cmdargs.Schema
        subcommands: {Subcommand}
        -- When false the command's default action is not projected to MCP.
        mcp: boolean
        -- When false the command is not typeable in the overlay (no name in
        -- help or completion): an MCP-only command.
        overlay: boolean
        -- Overrides for the derived MCP safety hints (partial; unset keys
        -- keep the derived value).
        annotations: ToolAnnotations
        -- Agent-facing tool description; see Subcommand.mcpHelp.
        mcpHelp: string
        -- Optional Tab-completion sources by argument position (1 = the word
        -- after the command name; 0 = any later position). Subcommand names
        -- complete implicitly at position 1. Same sources as Subcommand.
        complete: {integer: string}
        -- Help/completion grouping: "Select", "Edit", "Render", "Engine",
        -- "Capture", or "Session". Unset (custom commands) groups as "Custom".
        section: string
        -- JSON Schema for the Result.data payload; see Subcommand.outputSchema.
        outputSchema: {string: any}
        -- Application-specific metadata; see Subcommand.metadata.
        metadata: {string: any}
        run: function(v: {string: any}, parts: {string}): Result
    end

    --- MCP tool safety hints. The protocol's defaults are pessimistic
    --- (destructive and open-world default to true), so every projected tool
    --- declares all four explicitly.
    record ToolAnnotations
        readOnlyHint: boolean
        destructiveHint: boolean
        idempotentHint: boolean
        openWorldHint: boolean
    end

    --- A registry-derived MCP tool: name, description, JSON input schema,
    --- and safety annotations.
    record McpTool
        name: string
        description: string
        inputSchema: {string: any}
        outputSchema: {string: any}
        annotations: ToolAnnotations
    end

    --- Profiler session state shared between the profile command and the
    --- overlay (which finishes a session on reopen or deadline).
    record ProfilerState
        session: profile.SampleSession
        deadline: number
        counter: integer
    end

    --- A screenshot scheduled with `delay=`; the overlay's input system
    --- counts these down each frame and fires them when due.
    record PendingShot
        dueIn: number
        fire: function()
    end

    --- The slice of registry state the command groups touch. The full
    --- Registry lives in tecs2d.debug.commands; build() passes itself here
    --- through a cast (same table, narrower type).
    record RegSlice
        signals: Signals
        profiler: ProfilerState
        saveCounter: integer
        saves: {integer: string}
        shotCounter: integer
        history: {string}
        lastWorldLoadAt: number
        diffCounter: integer
        lastDiff: {string: any}
        lastOutput: {string}
        pendingShots: {PendingShot}
        despawnSelected: function(RegSlice): integer
        finishProfile: function(RegSlice): {string}
    end

    --- Everything a command group receives from the core: the world, the
    --- shared context, the registry slice, and the helpers that live in
    --- tecs2d.debug.commands. Group modules must not require commands (that
    --- would be a cycle); anything shared arrives through this record.
    record Deps
        world: tecs.World
        ctx: debugcontext.Context
        env: Env
        reg: RegSlice

        --- The render pipeline resource, or nil before gfx installs.
        pipeline: function(): gfxtypes.Pipeline

        --- A registered component by name, or nil + reason.
        componentFor: function(string): tecs.Component, string

        --- Resolve a parsed `<id|name>` target to entity ids.
        resolveTargets: function({string: any}): {integer}

        --- Build a validated annotation from draw-style arguments.
        makeAnnotation: function({string: any}, annotations.Kind): annotations.Annotation

        --- commands.tileAt, passed through so groups avoid the cycle.
        tileAt: function(tecs.World, debugcontext.Context, number, number): integer, integer, number, number, number, number

        --- Profile helpers shared with Registry:finishProfile.
        summarizeProfile: function(text: string, name: string, systemsById: {string: string}): {string}, {string}
        systemZoneIds: function(tecs.World): {string: string}

        -- Shared schemas and constants.
        onOffSchema: cmdargs.Schema
        nameSchema: cmdargs.Schema
        refSchema: cmdargs.Schema
        targetSchema: cmdargs.Schema
        optionalTargetSchema: cmdargs.Schema
        --- The literal "@selection" edit target.
        selectionTarget: string
    end
end

cmdtypes.HRULE = "\1"
cmdtypes.SECTION_MARK = "\2"

return cmdtypes
