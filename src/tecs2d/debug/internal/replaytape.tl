--- Rewind's flight recorder and replay driver. While a rewind session runs,
--- every dispatched input event and every gameplay frame's dt are recorded
--- against the gameplay-frame clock (frames are the coordinate system; time
--- is derived). Replaying from a rewind snapshot is then: restore the
--- snapshot (RNG state included), synthesize presses for inputs held at the
--- anchor, queue the recorded rows into the input tape, feed the recorded dt
--- per frame through tecs2d.internal.frameclock, and step. Live input is not
--- muted -- touching the keyboard during a replay simply makes a new
--- timeline, which the recorder keeps recording.
---
--- Everything is in-memory and bounded (HORIZON frames, ~10 min at 60fps);
--- serialization to disk is a deliberate future verb, not a side effect.

local tecs <const> = require("tecs")
local inputHandlers <const> = require("tecs2d.internal.handlers")
local frameclock <const> = require("tecs2d.internal.frameclock")
local inputidentity <const> = require("tecs2d.debug.internal.inputidentity")
local inputtape <const> = require("tecs2d.debug.internal.inputtape")
local logging <const> = require("tecs.utils.logging")

local LOGGER <const> = logging.getLogger("tecs2d.debug.replaytape")

-- Recording window in gameplay frames (~10 minutes at 60fps). The dt array
-- costs ~16 bytes per frame; the event list is bounded by the same horizon.
local HORIZON <const> = 36000

local record replaytape
    record Row
        frame: integer
        event: string
        args: {any}
    end

    record Recorder
        world: tecs.World
        frame: integer            -- gameplay frames observed
        rows: {Row}               -- recorded events, frame-stamped
        dts: {integer: number}    -- gameplay frame -> dt it ran with
        down: {string: Row}       -- held press-type inputs, by identity
        pendingEvents: {{any}}    -- dispatched since the last gameplay frame
        replayDts: {number}       -- active replay dt feed (nil when idle)
        replayCursor: integer

        --- Synthesized press rows recreating everything currently held, for
        --- storage on a rewind entry at capture time.
        heldRows: function(self: Recorder): {{string: any}}

        --- Recorded rows and dts for gameplay frames (from, from + frames].
        --- Returns tape-ready rows (relative `at`) and the dt list, or
        --- nil + reason when the window is no longer (or not yet) covered.
        slice: function(self: Recorder, from: integer, frames: integer): {{string: any}}, {number}, string

        --- Begin feeding `dts` to the frame clock: one value per stepped
        --- gameplay frame, uninstalling itself when exhausted.
        feedDts: function(self: Recorder, dts: {number}, stepping: function(): boolean)

        tick: function(self: Recorder, dt: number)
    end

    KEY: tecs.Key<Recorder>

    --- Get or create the world's recorder (installs the dispatch listener
    --- and its First-phase system once).
    ensure: function(w: tecs.World): Recorder
end

replaytape.KEY = tecs.newKey("tecs2d.debug.replayTape")

local RecorderImpl <const> = {}

function RecorderImpl.heldRows(self: replaytape.Recorder): {{string: any}}
    local ids: {string} = {}
    for id in pairs(self.down) do ids[#ids + 1] = id end
    table.sort(ids)
    local out: {{string: any}} = {}
    for i = 1, #ids do
        local press <const> = self.down[ids[i]]
        out[#out + 1] = {event = press.event, args = press.args}
    end
    return out
end

function RecorderImpl.slice(self: replaytape.Recorder, from: integer, frames: integer): {{string: any}}, {number}, string
    if frames < 1 then
        return nil, nil, "frames must be at least 1"
    end
    local last <const> = from + frames
    if last > self.frame then
        return nil, nil, "only " .. tostring(self.frame - from)
            .. " frame(s) recorded after that snapshot"
    end
    local dts: {number} = {}
    for f = from + 1, last do
        local dt <const> = self.dts[f]
        if dt == nil then
            return nil, nil, "the recording no longer covers that window "
                .. "(frame " .. tostring(f) .. " was pruned)"
        end
        dts[#dts + 1] = dt
    end
    local rows: {{string: any}} = {}
    for i = 1, #self.rows do
        local row <const> = self.rows[i]
        if row.frame > from and row.frame <= last then
            rows[#rows + 1] = {at = row.frame - from, event = row.event, args = row.args}
        end
    end
    return rows, dts, nil
end

function RecorderImpl.feedDts(self: replaytape.Recorder, dts: {number}, stepping: function(): boolean)
    self.replayDts = dts
    self.replayCursor = 0
    frameclock.provider = function(_realDt: number): number
        if not stepping() then return nil end
        if self.replayCursor >= #self.replayDts then
            frameclock.provider = nil
            self.replayDts = nil
            return nil
        end
        self.replayCursor = self.replayCursor + 1
        local dt <const> = self.replayDts[self.replayCursor]
        if self.replayCursor >= #self.replayDts then
            -- Uninstall after handing out the last value so a later live
            -- frame never consumes a stale provider.
            frameclock.provider = nil
            self.replayDts = nil
        end
        return dt
    end
end

function RecorderImpl.tick(self: replaytape.Recorder, dt: number)
    self.frame = self.frame + 1
    self.dts[self.frame] = dt
    self.dts[self.frame - HORIZON] = nil

    local pending <const> = self.pendingEvents
    if #pending > 0 then
        for i = 1, #pending do
            local ev <const> = pending[i]
            local name <const> = ev[1] as string
            local args: {any} = {}
            for j = 2, #ev do args[j - 1] = ev[j] end
            self.rows[#self.rows + 1] = {frame = self.frame, event = name, args = args}

            -- A press without its release leaves the input logically down,
            -- so the anchor can synthesize it when a replay starts.
            local id <const> = inputidentity.press(name, args)
            if id then
                self.down[id] = {frame = self.frame, event = name, args = args}
            else
                local released <const> = inputidentity.release(name, args)
                if released then self.down[released] = nil end
            end
        end
        self.pendingEvents = {}
    end

    -- Prune rows older than the horizon (they lead the list).
    local cutoff <const> = self.frame - HORIZON
    while self.rows[1] and self.rows[1].frame <= cutoff do
        table.remove(self.rows, 1)
    end
end

function replaytape.ensure(w: tecs.World): replaytape.Recorder
    local existing = w.resources[replaytape.KEY]
    if existing then return existing end

    -- The input tape must exist first: its First-phase system dispatches
    -- taped rows, and registering the recorder's system after it means those
    -- rows are already in the pending buffer when this frame is stamped.
    inputtape.ensure(w)

    local recorder: replaytape.Recorder = setmetatable({
        world = w,
        frame = 0,
        rows = {},
        dts = {},
        down = {},
        pendingEvents = {},
        replayCursor = 0,
    } as replaytape.Recorder, {__index = RecorderImpl} as metatable<replaytape.Recorder>)

    w.resources[replaytape.KEY] = recorder

    inputHandlers.onDispatch = function(name: string, ...: any)
        recorder.pendingEvents[#recorder.pendingEvents + 1] = {name, ...}
    end

    w:addSystem({
        name = "debug.ReplayRecorder",
        phase = tecs.phases.First,
        run = function(dt: number)
            recorder:tick(dt)
        end,
    })
    LOGGER:debug("replay recorder installed")
    return recorder
end

return replaytape
