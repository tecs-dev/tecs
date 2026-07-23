--- Shared record types for the debugger command registry. This is a leaf
--- module: tecs2d.debug.commands re-exports these types for its public API,
--- and the command-group modules (internal/cmd/*) depend on it instead of
--- commands, which keeps the require graph acyclic.

local tecs <const> = require("tecs")
local profile <const> = require("tecs.utils.profile")
local gfxtypes <const> = require("tecs2d.gfx.types")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local recording <const> = require("tecs2d.debug.internal.recording")
local suspension <const> = require("tecs2d.internal.suspension")
local cmdargs <const> = require("tecs2d.debug.internal.cmdargs")
local markup <const> = require("tecs2d.debug.internal.markup")

local record cmdtypes
    --- Sentinel popup line drawn as a horizontal rule rather than text.
    HRULE: string

    --- Prefix marking a section separator entry in completion candidates.
    SECTION_MARK: string

    --- Display order of command sections in help, completion, and the
    --- generated reference. Unset sections group as "Custom".
    SECTIONS: {string}

    --- Section accent colors ({r, g, b}, 0-1), tuned for dark surfaces
    --- (popup section headings). One entry per SECTIONS name.
    SECTION_COLORS: {string: {number}}

    --- The same hues as muted pastel fills: the completion strip draws
    --- each section marker as a pill in this shade with a white label.
    SECTION_COLORS_BAR: {string: {number}}

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
        suspension: suspension.Controller
        keys: Keys
    end

    --- What an action asks its surface to do. `data` is the canonical
    --- structured payload (the MCP tool result); popup fields are overlay-only
    --- presentation; ok=false marks a failure (code is machine-readable).
    --- popupImagePath names a save-dir image the overlay shows as a thumbnail
    --- for the popup's lifetime (screenshot info); MCP ignores it.
    record Result
        ok: boolean
        code: string
        message: string
        data: {string: any}
        popup: {string}
        --- Optional heading rendered in a dedicated popup title band. When
        --- omitted, existing popups continue to use their first line.
        popupTitle: string
        --- Optional lightweight syntax mode for popup body lines.
        popupLanguage: string
        --- Optional semantic body blocks. The overlay packs these into as
        --- many vertical columns as fit; `popup` remains the copy/yank form.
        popupBlocks: {{string}}
        --- Typed popup document, used by built-in help and reusable surfaces.
        popupDocument: markup.Document
        --- Authored popup markup parsed into popupDocument by the overlay.
        popupMarkup: string
        --- Presentation controls consumed only by debugger UI surfaces.
        popupModal: boolean
        popupClosable: boolean
        popupMaxColumns: integer
        popupScrollToEnd: boolean
        popupImagePath: string
    end

    --- Surface-directed side effects an action may raise instead of poking
    --- overlay state: `action` is "exit" (close the panel);
    --- hideOverlay hides the chrome for one frame (screenshots).
    record Signals
        action: string
        hideOverlay: boolean
    end

    --- One verb under a command (git/docker style), e.g. `snapshot save`.
    record Subcommand
        name: string
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
        --- Registered commands in registration order. Groups read it for
        --- counts and section summaries; only the core registry appends.
        list: {Command}
        signals: Signals
        profiler: ProfilerState
        saveCounter: integer
        saves: {integer: string}
        shotCounter: integer
        history: {string}
        lastWorldLoadAt: number
        diffCounter: integer
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

        --- Resolve an optional worldId argument. Omitted means the game world.
        worldFor: function({string: any}): tecs.World, integer, string

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

        --- Build a validated `<id|name>` target schema; entries of `extra`
        --- (may be nil) merge into its argument specs.
        makeTargetSchema: function(required: boolean, extra: {string: cmdargs.ArgSpec}): cmdargs.Schema

        --- The literal "@selection" edit target.
        selectionTarget: string

        --- The command-history file in the save directory, shared with the
        --- registry's history persistence.
        historyFile: string
    end
end

cmdtypes.HRULE = "\1"
cmdtypes.SECTION_MARK = "\2"

cmdtypes.SECTIONS = {
    "Select", "Edit", "Render", "Engine", "Capture", "Custom", "Session",
}

-- One hue per section, in two shades: Everforest-style pastels for dark
-- surfaces and muted pastel fills for the strip's section pills.
-- Adjacent sections must stay distinguishable in both palettes.
cmdtypes.SECTION_COLORS = {
    Select = {0.498, 0.733, 0.702},    -- blue
    Edit = {0.902, 0.494, 0.502},      -- red
    Render = {0.839, 0.600, 0.714},    -- purple
    Engine = {0.902, 0.596, 0.459},    -- orange
    Capture = {0.514, 0.753, 0.573},   -- teal
    Custom = {0.859, 0.737, 0.498},    -- gold
    Session = {0.616, 0.663, 0.627},   -- grey
}

cmdtypes.SECTION_COLORS_BAR = {
    Select = {0.36, 0.53, 0.51},       -- blue
    Edit = {0.65, 0.36, 0.37},         -- red
    Render = {0.60, 0.43, 0.51},       -- purple
    Engine = {0.65, 0.43, 0.33},       -- orange
    Capture = {0.37, 0.54, 0.41},      -- teal
    Custom = {0.62, 0.53, 0.35},       -- gold
    Session = {0.44, 0.48, 0.45},      -- grey
}

return cmdtypes
