--- Frame-scheduled Love event injection: the input tape. Rows of
--- {at, event, args} -- literal love event shapes -- dispatch through the
--- exact path real events take (tecs2d.internal.handlers.dispatch).
---
--- A queued batch is a sequencer program on the frame clock: waits between
--- rows, a call per row. That clock advances in phases.First, which the
--- suspension controller disables while held and enables during cmd_step, so
--- queueing input before a step is deterministic; unfrozen, the same clock
--- advances on live frames.
---
--- What the tape still owns is the input bookkeeping the sequencer has no
--- business knowing: which presses are outstanding, and what fired recently.
---
--- `at` counts gameplay frames from queue time: at=1 fires on the next
--- gameplay frame. Taped input updates the tecs2d.input snapshot, emits Tecs
--- events, and invokes user love.* callbacks identically to a human press;
--- raw love.* polls (love.keyboard.isDown) still report physical hardware.

local tecs <const> = require("tecs")
local inputHandlers <const> = require("tecs2d.internal.handlers")
local inputidentity <const> = require("tecs2d.debug.internal.inputidentity")
local sequence <const> = require("tecs2d.sequence")
local logging <const> = require("tecs.utils.logging")

local LOGGER <const> = logging.getLogger("tecs2d.debug.inputtape")
local FIRED_CAP <const> = 64

-- One program name, re-versioned per queued batch. A version is dropped when
-- its playback finishes, so a long session does not accumulate them.
local PROGRAM_NAME <const> = "tecs2d.debug.inputTape"
local DISPATCH_ACTION <const> = "tecs2d.debug.inputTape.dispatch"

local record inputtape
    record Row
        at: integer      -- gameplay frames from queue time
        event: string
        args: {any}
    end

    record Held
        event: string    -- the paired release event name
        args: {any}      -- args to release with (copied from the press)
    end

    record Fired
        frame: integer
        event: string
        args: {any}
    end

    record Tape
        world: tecs.World
        fired: {Fired}           -- newest last, capped at FIRED_CAP
        held: {string: Held}     -- press-without-release, by identity
        playbacks: {integer}     -- queued batches still to finish

        --- Gameplay frames the tape has seen, from the frame clock.
        frame: function(self: Tape): integer

        --- Queue rows (each {at, event, args}). Returns the count queued, or
        --- nil and a message when any row is invalid (nothing is queued).
        queue: function(self: Tape, rows: {{string: any}}, force: boolean): integer, string

        --- Drop pending rows and synthesize releases for anything the tape
        --- still holds down. Returns rows dropped and releases fired.
        clear: function(self: Tape): integer, integer

        --- Rows due within the next `n` gameplay frames, as {in, event}.
        upcoming: function(self: Tape, n: integer): {{string: any}}

        --- Held identities, sorted.
        heldIds: function(self: Tape): {string}
    end

    KEY: tecs.Key<Tape>

    --- Get or create the world's tape (installs its consumer system once).
    ensure: function(w: tecs.World): Tape

    tapeable: function(event: string): boolean
end

inputtape.KEY = tecs.newKey("tecs2d.debug.inputTape")

-- Events whose real arguments include userdata (Joystick, DroppedFile): a
-- JSON row cannot express them, and faking the objects is the not-yet-built
-- virtual-gamepad feature. Refused with a clear message.
local UNTAPEABLE <const>: {string: boolean} = {
    gamepadaxis = true, gamepadpressed = true, gamepadreleased = true,
    joystickadded = true, joystickremoved = true, joystickpressed = true,
    joystickreleased = true, joystickhat = true, filedropped = true,
}

--- Whether the tape can carry this event (send_love_event routes tapeable
--- events through the tape so they land frame-aligned with defaulted args).
function inputtape.tapeable(event: string): boolean
    return not UNTAPEABLE[event]
end

-- Fill what MUST be filled so a row can use the natural short form
-- (e.g. keypressed with just the key), mirroring how send_love_event
-- forgives optional args. Returns an error string for unusable rows.
local function defaultArgs(event: string, args: {any}): string
    if event == "keypressed" or event == "keyreleased" then
        if type(args[1]) ~= "string" then return "needs args[1] = key" end
        if args[2] == nil then args[2] = args[1] end       -- scancode
        if event == "keypressed" and args[3] == nil then args[3] = false end
    elseif event == "mousepressed" or event == "mousereleased" then
        if type(args[1]) ~= "number" or type(args[2]) ~= "number"
            or type(args[3]) ~= "number" then
            return "needs args = {x, y, button}"
        end
        if args[4] == nil then args[4] = false end          -- istouch
        if args[5] == nil then args[5] = 1 end              -- presses
    elseif event == "mousemoved" then
        if type(args[1]) ~= "number" or type(args[2]) ~= "number" then
            return "needs args = {x, y}"
        end
        if args[3] == nil then args[3] = 0 end              -- dx
        if args[4] == nil then args[4] = 0 end              -- dy
        if args[5] == nil then args[5] = false end          -- istouch
    elseif event == "touchpressed" or event == "touchmoved"
        or event == "touchreleased" then
        if args[1] == nil or type(args[2]) ~= "number"
            or type(args[3]) ~= "number" then
            return "needs args = {id, x, y}"
        end
        if args[4] == nil then args[4] = 0 end              -- dx
        if args[5] == nil then args[5] = 0 end              -- dy
        if args[6] == nil then args[6] = 1 end              -- pressure
        if args[8] == nil then args[8] = false end          -- isMouse
    end
    return nil
end

local TapeImpl <const> = {}

local function dispatchRow(self: inputtape.Tape, event: string, args: {any})
    inputHandlers.dispatch(self.world, event, table.unpack(args))

    self.fired[#self.fired + 1] = {frame = self:frame(), event = event, args = args}
    if #self.fired > FIRED_CAP then
        table.remove(self.fired, 1)
    end

    -- A press stays held until its release arrives, so `clear` and the
    -- status report can see what the tape left down.
    local id <const> = inputidentity.press(event, args)
    if id then
        self.held[id] = {event = inputidentity.pairedRelease(event), args = args}
    else
        local released <const> = inputidentity.release(event, args)
        if released then
            self.held[released] = nil
        end
    end
end

function TapeImpl.queue(self: inputtape.Tape, rows: {{string: any}}, force: boolean): integer, string
    if type(rows) ~= "table" or #rows == 0 then
        return nil, "events must be a non-empty array of {at, event, args}"
    end

    -- Validate every row before queueing any, so a bad batch is atomic.
    local prepared: {inputtape.Row} = {}
    for i = 1, #rows do
        local row <const> = rows[i]
        local at <const> = tonumber(row.at)
        local event <const> = row.event as string
        if not at or at < 1 or at % 1 ~= 0 then
            return nil, "row " .. i .. ": at must be an integer >= 1 (gameplay frames from now)"
        end
        if type(event) ~= "string" or inputHandlers.handlers[event] == nil then
            return nil, "row " .. i .. ": unknown event '" .. tostring(event)
                .. "' (any Love event name the game handles, e.g. keypressed)"
        end
        if UNTAPEABLE[event] then
            return nil, "row " .. i .. ": '" .. event .. "' needs a device object "
                .. "(virtual gamepads are not implemented yet)"
        end
        local args: {any} = (row.args as {any}) or {}
        if (event == "keypressed" or event == "keyreleased")
            and args[1] == "escape" and not force then
            return nil, "row " .. i .. ": refusing to tape 'escape' (quitOnEscape "
                .. "and debugger binds may fire); pass force=true to override"
        end
        local argErr <const> = defaultArgs(event, args)
        if argErr then
            return nil, "row " .. i .. ": " .. event .. " " .. argErr
        end
        prepared[#prepared + 1] = {
            at = at as integer,
            event = event,
            args = args,
        }
    end

    -- Rows due on one frame keep the order they were given, and a batch
    -- queued later keeps its place behind one queued earlier at the same
    -- frame, because playbacks scheduled for the same tick run in play order.
    table.sort(prepared, function(a: inputtape.Row, b: inputtape.Row): boolean
        return a.at < b.at
    end)

    local nodes: {sequence.Node} = {}
    local at = 0
    for i = 1, #prepared do
        local row <const> = prepared[i]
        -- The first instruction already runs one frame out, so the first
        -- wait is one short.
        local delta <const> = row.at - at - (i == 1 and 1 or 0)
        if delta > 0 then nodes[#nodes + 1] = sequence.waitSteps(delta) end
        nodes[#nodes + 1] = sequence.call(DISPATCH_ACTION, row.event, row.args)
        at = row.at
    end

    local program <const> = sequence.define(PROGRAM_NAME, nodes, {clock = "frame"})
    self.playbacks[#self.playbacks + 1] =
        sequence.play(self.world, program, {owner = 0})
    return #prepared, nil
end

-- Playbacks that have finished are dropped lazily: the tape only looks when
-- something asks what is pending.
local function livePlaybacks(self: inputtape.Tape): {integer}
    local live: {integer} = {}
    for i = 1, #self.playbacks do
        local handle <const> = self.playbacks[i]
        local status <const> = sequence.status(self.world, handle)
        if status and status.state == "running" then live[#live + 1] = handle end
    end
    self.playbacks = live
    return live
end

function TapeImpl.clear(self: inputtape.Tape): integer, integer
    local dropped = 0
    local live <const> = livePlaybacks(self)
    for i = 1, #live do
        dropped = dropped + #sequence.upcoming(self.world, live[i])
        sequence.cancel(self.world, live[i])
    end
    self.playbacks = {}

    local released = 0
    for _, holdInfo in pairs(self.held) do
        dispatchRow(self, holdInfo.event, holdInfo.args)
        released = released + 1
    end
    self.held = {}
    return dropped, released
end

function TapeImpl.upcoming(self: inputtape.Tape, n: integer): {{string: any}}
    local due: {{string: any}} = {}
    local live <const> = livePlaybacks(self)
    for i = 1, #live do
        local ahead <const> = sequence.upcoming(self.world, live[i], n)
        for j = 1, #ahead do
            due[#due + 1] = {["in"] = ahead[j].ticks, event = ahead[j].args[1]}
        end
    end
    -- Merged across batches, so the soonest row leads whichever batch it
    -- came from. Ties keep batch order, which is queue order.
    table.sort(due, function(a: {string: any}, b: {string: any}): boolean
        return (a["in"] as integer) < (b["in"] as integer)
    end)
    return due
end

function TapeImpl.heldIds(self: inputtape.Tape): {string}
    local ids: {string} = {}
    for id in pairs(self.held) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

function TapeImpl.frame(self: inputtape.Tape): integer
    return sequence.currentStep(self.world, "frame")
end

function inputtape.ensure(w: tecs.World): inputtape.Tape
    local existing = w.resources[inputtape.KEY]
    if existing then return existing end

    local tape: inputtape.Tape = setmetatable({
        world = w,
        fired = {},
        held = {},
        playbacks = {},
    } as inputtape.Tape, {__index = TapeImpl} as metatable<inputtape.Tape>)

    w.resources[inputtape.KEY] = tape

    -- The frame clock is what carries a queued batch, and a world that
    -- scripts input may not have installed the sequencer for any other
    -- reason.
    sequence.plugin(w)

    -- Dispatch is an action rather than an instruction so the sequencer stays
    -- a control-flow machine: it knows nothing about input, and the tape
    -- keeps the press bookkeeping that goes with dispatching.
    sequence.registerAction(w, DISPATCH_ACTION,
        function(_w: tecs.World, ctx: sequence.ActionContext)
            dispatchRow(tape, ctx.args[1] as string, ctx.args[2] as {any})
        end)

    LOGGER:debug("input tape installed")
    return tape
end

return inputtape
