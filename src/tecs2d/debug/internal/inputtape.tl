--- Frame-scheduled LÖVE event injection: the input tape. Rows of
--- {at, event, args} -- literal love event shapes -- dispatch through the
--- exact path real events take (tecs2d.internal.handlers.dispatch), on
--- GAMEPLAY frames: the tape's consumer system runs in phases.First, which
--- the freeze controller disables while frozen and enables during cmd_step,
--- so `freeze -> queue -> step N -> assert state` is fully deterministic.
--- Unfrozen, the same system consumes the tape on live frames.
---
--- `at` counts gameplay frames from queue time: at=1 fires on the next
--- gameplay frame. Taped input updates the tecs2d.input snapshot, emits Tecs
--- events, and invokes user love.* callbacks identically to a human press;
--- raw love.* polls (love.keyboard.isDown) still report physical hardware.

local tecs <const> = require("tecs")
local inputHandlers <const> = require("tecs2d.internal.handlers")
local logging <const> = require("tecs.utils.logging")

local LOGGER <const> = logging.getLogger("tecs2d.debug.inputtape")
local FIRED_CAP <const> = 64

local record inputtape
    record Row
        at: integer      -- absolute gameplay frame this fires on
        seq: integer     -- insertion order, to keep same-frame rows stable
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
        frame: integer           -- gameplay frames observed by the tape
        seq: integer
        rows: {Row}              -- pending, sorted by (at, seq)
        fired: {Fired}           -- newest last, capped at FIRED_CAP
        held: {string: Held}     -- press-without-release, by identity

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

        --- Per-gameplay-frame consumer; installed as the debug.InputTape
        --- system in phases.First.
        tick: function(self: Tape)
    end

    KEY: tecs.Key<Tape>

    --- Get or create the world's tape (installs its consumer system once).
    ensure: function(w: tecs.World): Tape
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

-- Press events the tape tracks so `clear` (and the status report) can see
-- what it left logically held down. Returns identity and the paired release.
local function pressIdentity(event: string, args: {any}): string, string
    if event == "keypressed" then
        return "key:" .. tostring(args[1]), "keyreleased"
    elseif event == "mousepressed" then
        return "mouse:" .. tostring(args[3]), "mousereleased"
    elseif event == "touchpressed" then
        return "touch:" .. tostring(args[1]), "touchreleased"
    end
    return nil, nil
end

local function releaseIdentity(event: string, args: {any}): string
    if event == "keyreleased" then
        return "key:" .. tostring(args[1])
    elseif event == "mousereleased" then
        return "mouse:" .. tostring(args[3])
    elseif event == "touchreleased" then
        return "touch:" .. tostring(args[1])
    end
    return nil
end

local TapeImpl <const> = {}

local function dispatchRow(self: inputtape.Tape, event: string, args: {any})
    inputHandlers.dispatch(self.world, event, table.unpack(args))

    self.fired[#self.fired + 1] = {frame = self.frame, event = event, args = args}
    if #self.fired > FIRED_CAP then
        table.remove(self.fired, 1)
    end

    local id <const>, releaseEvent <const> = pressIdentity(event, args)
    if id then
        self.held[id] = {event = releaseEvent, args = args}
    else
        local released <const> = releaseIdentity(event, args)
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
                .. "' (any LÖVE event name the game handles, e.g. keypressed)"
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
        self.seq = self.seq + 1
        prepared[#prepared + 1] = {
            at = self.frame + (at as integer),
            seq = self.seq,
            event = event,
            args = args,
        }
    end

    for i = 1, #prepared do
        self.rows[#self.rows + 1] = prepared[i]
    end
    table.sort(self.rows, function(a: inputtape.Row, b: inputtape.Row): boolean
        if a.at ~= b.at then return a.at < b.at end
        return a.seq < b.seq
    end)
    return #prepared, nil
end

function TapeImpl.clear(self: inputtape.Tape): integer, integer
    local dropped <const> = #self.rows
    self.rows = {}

    local released = 0
    for _, holdInfo in pairs(self.held) do
        dispatchRow(self, holdInfo.event, holdInfo.args)
        released = released + 1
    end
    self.held = {}
    return dropped, released
end

function TapeImpl.upcoming(self: inputtape.Tape, n: integer): {{string: any}}
    local out: {{string: any}} = {}
    for i = 1, #self.rows do
        local row <const> = self.rows[i]
        local rel <const> = row.at - self.frame
        if rel <= n then
            out[#out + 1] = {["in"] = rel, event = row.event}
        end
    end
    return out
end

function TapeImpl.heldIds(self: inputtape.Tape): {string}
    local ids: {string} = {}
    for id in pairs(self.held) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

function TapeImpl.tick(self: inputtape.Tape)
    self.frame = self.frame + 1
    while self.rows[1] and self.rows[1].at <= self.frame do
        local row <const> = table.remove(self.rows, 1)
        dispatchRow(self, row.event, row.args)
    end
end

function inputtape.ensure(w: tecs.World): inputtape.Tape
    local existing = w.resources[inputtape.KEY]
    if existing then return existing end

    local tape: inputtape.Tape = setmetatable({
        world = w,
        frame = 0,
        seq = 0,
        rows = {},
        fired = {},
        held = {},
    } as inputtape.Tape, {__index = TapeImpl} as metatable<inputtape.Tape>)

    w.resources[inputtape.KEY] = tape

    -- phases.First is the earliest gameplay phase: disabled while frozen,
    -- enabled during steps, and ahead of Update either way -- so a row fires
    -- into the same frame's input snapshot its consumers read.
    w:addSystem({
        name = "debug.InputTape",
        phase = tecs.phases.First,
        run = function()
            tape:tick()
        end,
    })
    LOGGER:debug("input tape installed")
    return tape
end

return inputtape
