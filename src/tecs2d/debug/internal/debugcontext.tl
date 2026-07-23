--- Shared DebugContext resource and its world key.
--- Read by the cmd_context MCP tool and written by the overlay systems.

local tecs <const> = require("tecs")
local logging <const> = require("tecs.utils.logging")

-- Operator-action feed: pushEvent logs one line per action here; agents read
-- it back with get_logs (contains = "tecs2d.debug.events", after = <seq>).
local EVENTS <const> = logging.getLogger("tecs2d.debug.events")

local record debugcontext
    --- A saved snapshot: session number, file path, byte size, unix
    --- timestamp, and the entity count captured at save time.
    record SnapshotEntry
        number: integer
        path: string
        size: integer
        time: integer
        entities: integer
    end

    --- A profile capture: file path, byte size, unix timestamp.
    record ProfileEntry
        path: string
        size: integer
        time: integer
    end

    --- A captured screenshot: save-dir file path, byte size, unix timestamp.
    record ScreenshotEntry
        path: string
        size: integer
        time: integer
    end

    --- A completed host recording: save-dir file path, byte size, unix timestamp.
    record RecordingEntry
        path: string
        size: integer
        time: integer
        duration: number
        stopReason: string
    end

    --- A diff artifact written by the `diff` command: save-dir file path,
    --- byte size, unix timestamp, and total change count.
    record DiffEntry
        path: string
        size: integer
        time: integer
        changes: integer
    end

    --- Current host-recording state, controlled by debugger commands or MCP.
    record RecordingState
        status: string
        path: string
        logPath: string
        startedAt: number
        duration: number
        countdown: number
        stopOnDebugOpen: boolean
        stopReason: string
        error: string
        name: string
        backend: string
        ffmpegPath: string
        input: string
    end

    --- Live debugger state, published as a world resource and read over MCP.
    record Context
        open: boolean
        frozen: boolean
        --- Whether the stats HUD is visible (maintained by the stats module).
        statsShown: boolean
        --- Whether entity id labels are drawn over on-screen entities.
        showIds: boolean
        --- Whether size outlines are drawn around entities with known bounds.
        showBounds: boolean
        --- Right-click context menu: open flag and its target entity
        --- (0 = a world-position menu).
        menuOpen: boolean
        menuTarget: integer

        --- Diff artifacts written by the `diff` command, oldest first.
        diffs: {DiffEntry}

        record RewindEntry
            path: string
            size: integer
            -- os.time() at capture; ages are computed against os.time().
            time: integer
            entities: integer
            -- Replay anchor: the recorder's gameplay frame at capture, and
            -- synthesized press rows for inputs held at that moment. Absent
            -- on entries captured before the recorder existed.
            frame: integer
            held: {{string: any}}
        end

        --- Time-travel snapshot ring (the `rewind` command). Captures are
        --- driven by the overlay's input system on wall-clock time and skip
        --- while the freeze controller is held.
        record RewindState
            --- "idle" | "running" | "paused" | "stopped"
            status: string
            --- "" | "manual" | "loaded" | "error"
            pauseReason: string
            interval: number
            cap: integer
            --- love.timer clock (monotonic), unrelated to entry times.
            nextDueAt: number
            entries: {RewindEntry}
            --- Monotonic capture number for filenames.
            counter: integer
            --- Total bytes currently held by the ring.
            bytes: integer
            lastCaptureMs: number
            lastError: string
        end

        rewind: RewindState
        --- World-space debug grid. Enabled draws lines every gridW x gridH
        --- world units, anchored at (gridOX, gridOY).
        gridEnabled: boolean
        gridW: number
        gridH: number
        gridOX: number
        gridOY: number
        mode: string
        command: string
        message: string
        selected: {integer}
        marks: {integer: string}
        notes: {integer: string}
        profileTop: {string}
        snapshots: {SnapshotEntry}
        profiles: {ProfileEntry}
        screenshots: {ScreenshotEntry}
        recording: RecordingState
        recordings: {RecordingEntry}
        entityCount: integer
        hasArea: boolean
        areaX1: number
        areaY1: number
        areaX2: number
        areaY2: number
        mouseScreenX: number
        mouseScreenY: number
        mouseWorldX: number
        mouseWorldY: number
        cameraX: number
        cameraY: number
        cameraZoom: number
        cameraRotation: number
        cameraW: number
        cameraH: number
    end

    --- Resource key for reading the DebugContext from world.resources.
    KEY: tecs.Key<Context>

    --- Create a DebugContext with default values.
    new: function(): Context

    --- Set the status line shown in the context bar. Subsystems call this to
    --- report an outcome, e.g. "screenshot saved at /full/path", which stays
    --- until the next command or message replaces it.
    setStatus: function(ctx: Context, text: string)

    --- Absolute path of a save-directory-relative file, for status messages.
    savePath: function(rel: string): string

    --- Selection-set helpers shared by the overlay's mouse handling and the
    --- command registry. The selection is an ordered set of entity ids.
    isSelected: function(ctx: Context, id: integer): boolean
    addSelected: function(ctx: Context, id: integer)
    removeSelected: function(ctx: Context, id: integer)

    --- Log one operator action ("open", "close", "selection", "mark",
    --- "note", "edit", "spawn", "snapshot", "screenshot", "profile",
    --- "recording") with key=value details to the tecs2d.debug.events
    --- logger. Agents poll it with get_logs (contains = "debug.events",
    --- after = <last seq>) instead of diffing the context.
    pushEvent: function(ctx: Context, kind: string, data?: {string: any})

    --- Invert an entity->value map to value->compact id-range string, e.g.
    --- {5="a", 6="a", 9="b"} -> {a="5-6", b="9"}. Keeps marks and notes cheap to
    --- ship to the agent for lists and contiguous ranges of entities.
    encodeGroups: function({integer: string}): {string: string}

    --- Emitted (to address 0) when the debugger writes a snapshot or profile.
    --- kind is "snapshot" or "profile"; path is the file; number is the save
    --- number for snapshots (0 otherwise).
    record OnDebugContext is tecs.Event
        kind: string
        path: string
        number: integer
        metamethod __call: function(self, kind: string, path: string, number: integer): OnDebugContext
    end
end

debugcontext.KEY = tecs.newKey("tecs2d.debug.context")

function debugcontext.new(): debugcontext.Context
    return {
        open = false,
        frozen = false,
        statsShown = false,
        showIds = false,
        showBounds = false,
        menuOpen = false,
        menuTarget = 0,
        diffs = {},
        rewind = {
            status = "idle",
            pauseReason = "",
            interval = 5,
            cap = 10,
            nextDueAt = 0,
            entries = {},
            counter = 0,
            bytes = 0,
            lastCaptureMs = 0,
            lastError = "",
        },
        gridEnabled = false,
        gridW = 0,
        gridH = 0,
        gridOX = 0,
        gridOY = 0,
        mode = "",
        command = "",
        message = "",
        selected = {},
        marks = {},
        notes = {},
        profileTop = {},
        snapshots = {},
        profiles = {},
        screenshots = {},
        recording = {
            status = "idle",
            path = "",
            logPath = "",
            startedAt = 0,
            duration = 0,
            countdown = 0,
            stopOnDebugOpen = false,
            stopReason = "",
            error = "",
            name = "",
            backend = "",
            ffmpegPath = "",
            input = "",
        },
        recordings = {},
        entityCount = 0,
        hasArea = false,
        areaX1 = 0,
        areaY1 = 0,
        areaX2 = 0,
        areaY2 = 0,
        mouseScreenX = 0,
        mouseScreenY = 0,
        mouseWorldX = 0,
        mouseWorldY = 0,
        cameraX = 0,
        cameraY = 0,
        cameraZoom = 1,
        cameraRotation = 0,
        cameraW = 0,
        cameraH = 0,
    }
end

-- Coalesce a sorted id list into "A-B,C,D-E".
local function encodeRanges(ids: {integer}): string
    table.sort(ids)
    local parts: {string} = {}
    local i = 1
    local n = #ids
    while i <= n do
        local start = ids[i]
        local last = start
        while i < n and ids[i + 1] == last + 1 do
            i = i + 1
            last = ids[i]
        end
        if start == last then
            parts[#parts + 1] = tostring(start)
        else
            parts[#parts + 1] = tostring(start) .. "-" .. tostring(last)
        end
        i = i + 1
    end
    return table.concat(parts, ",")
end

function debugcontext.setStatus(ctx: debugcontext.Context, text: string)
    ctx.message = text
end

function debugcontext.isSelected(ctx: debugcontext.Context, id: integer): boolean
    for i = 1, #ctx.selected do
        if ctx.selected[i] == id then return true end
    end
    return false
end

function debugcontext.addSelected(ctx: debugcontext.Context, id: integer)
    if id ~= 0 and not debugcontext.isSelected(ctx, id) then
        ctx.selected[#ctx.selected + 1] = id
    end
end

function debugcontext.removeSelected(ctx: debugcontext.Context, id: integer)
    for i = 1, #ctx.selected do
        if ctx.selected[i] == id then
            table.remove(ctx.selected, i)
            return
        end
    end
end

-- The Context parameter is unused today; it keeps the call shape stable for a
-- future per-context event feed (every caller already has one in hand).
function debugcontext.pushEvent(_ctx: debugcontext.Context, kind: string, data?: {string: any})
    if not data or next(data) == nil then
        EVENTS:info("%s", kind)
        return
    end
    -- Deterministic key=value detail, e.g. "selection selected=3 clicked=42".
    local keys: {string} = {}
    for k in pairs(data) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts: {string} = {kind}
    for i = 1, #keys do
        parts[#parts + 1] = keys[i] .. "=" .. tostring(data[keys[i]])
    end
    EVENTS:info("%s", table.concat(parts, " "))
end

function debugcontext.savePath(rel: string): string
    return love.filesystem.getSaveDirectory() .. "/" .. rel
end

function debugcontext.encodeGroups(map: {integer: string}): {string: string}
    local byValue: {string: {integer}} = {}
    for eid, v in pairs(map) do
        local list = byValue[v]
        if not list then
            list = {}
            byValue[v] = list
        end
        list[#list + 1] = eid
    end
    local out: {string: string} = {}
    for v, ids in pairs(byValue) do
        out[v] = encodeRanges(ids)
    end
    return out
end

debugcontext.OnDebugContext.init = function(
    e: debugcontext.OnDebugContext, kind: string, path: string, number: integer
)
    e.kind, e.path, e.number = kind or "", path or "", number or 0
end
tecs.newEvent(debugcontext.OnDebugContext)

return debugcontext
