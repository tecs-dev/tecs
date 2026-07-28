--- One gamepad, as an object.
---
--- A gamepad is not a set of globals the way a keyboard nearly is. It has
--- identity, a lifetime shorter than the process, metadata, capabilities that
--- differ between devices, and outputs. Two pads sharing one button set is not
--- a simplification, it is a defect: pad A releasing a button releases pad B's.
--- So each device owns its own state and is reached through its own object.
---
--- A retained reference to a device that went away is safe by construction.
--- The platform handle lives in exactly one field, exactly one function reads
--- it, and `_disconnect` clears it before the handle is closed. Every method
--- takes its quiet branch from there: queries answer as if nothing is held,
--- outputs report failure, and nothing reaches a freed pointer. A pad is never
--- revived either, so a reference held across a reconnect stays disconnected
--- and the reconnected device is a new object.
---
--- Buttons are named positionally: `south` is the button nearest the player on
--- every pad, where `a` is that button on some and the one to its right on
--- others. What is printed on the hardware is a separate question, and
--- `label` answers it, because a prompt has to show the player their own pad.

local inputstate <const> = require("tecs.platform.inputstate")
local inputbackend <const> = require("tecs.platform.inputbackend")
local loader <const> = require("tecs.ffi.loader")

local type Layer = inputstate.Layer
local type Buttons = inputstate.Buttons
local type Gate = inputstate.Gate
local type Backend = inputbackend.Backend

--- One finger on one of the device's touchpads, in 0..1 across the pad.
local record TouchpadFinger
    --- Which touchpad, zero-based, below `touchpads`.
    touchpad: integer
    --- The finger's slot on that touchpad, zero-based. A position on the
    --- device rather than an identity: unlike a touch-surface finger this is
    --- not a 64-bit id, so it fits a number and is compared as one.
    finger: integer
    --- Position across the pad, from its top-left, in 0..1 on each axis.
    x: number
    y: number
    --- How hard, in 0..1, on a device that measures it. Devices that do not
    --- report a constant while the finger is down.
    pressure: number
    --- Whether the finger is on the pad. A record for a finger that has lifted
    --- is kept and marked down false rather than dropped, so the slot is there
    --- to write into when the finger returns.
    down: boolean
end

local record Gamepad
    TouchpadFinger: TouchpadFinger

    --- Platform instance id. Unique among attached devices, and not reused by
    --- this object once the device is gone.
    id: number
    --- Whether the device is still attached. False for good once it is: a pad
    --- is never revived, so this only ever goes one way.
    connected: boolean
    --- What the platform calls the device, for showing the player which pad is
    --- which. Not stable across platforms or drivers; `guid` is what matches.
    name: string
    --- Device family: "xboxOne", "ps5", "switchPro", "standard", "unknown".
    kind: string
    --- Stable hardware identity, for matching saved bindings.
    guid: string
    --- Where the platform says the device is attached. Empty when it declines
    --- to say.
    path: string
    --- Player slot the platform assigned, or -1 for none.
    playerIndex: integer
    --- Touchpads the device carries. Zero on most.
    touchpads: integer

    --- Where every outbound command goes, and the only thing here that knows
    --- about SDL.
    _backend: Backend
    --- The shared layer stack, not one of this pad's own: a layer blocks every
    --- device or none.
    _gate: Gate
    --- The platform handle, and the only field that holds one. Nil once the
    --- device is gone, which is what makes a stale reference harmless.
    _handle: loader.CPtr
    _buttons: Buttons
    --- Latest value per axis, folded from the event stream. An axis no event
    --- has mentioned is absent and reads as zero.
    _axes: {integer: number}
    --- Latest reading per sensor, as three components in a reused table.
    _sensors: {integer: {number}}
    --- Fingers by touchpad and then by slot, in records reused across events.
    _fingers: {integer: {integer: TouchpadFinger}}
    --- Button labels already asked for. Dropped whole on a remap, since that
    --- is the one thing that changes them.
    _labels: {integer: string}

    --- Declared here because opening a device calls it, and the definition
    --- reads more naturally beside the rest of the lifetime.
    _readInfo: function(self: Gamepad)
end

local GamepadMT <const>: metatable<Gamepad> = {__index = Gamepad}

--- Stick drift is a property of the hardware rather than of any one game, so
--- a default lives here.
local DEFAULT_DEADZONE <const> = 0.15

--- The platform handle, or nil once the device is gone.
---
--- Every call into the backend goes through this. Disconnection nils the
--- handle in one place, so there is no second copy to go stale and no method
--- that can reach a closed device by holding one.
local function live(self: Gamepad): loader.CPtr
    return self._handle
end

--- Opens a device and reads what it says about itself.
---
--- Returns nil when the platform will not open it, which happens for a device
--- unplugged between enumeration and here.
--- @param gate The shared layer stack, which every query on this pad is
---     answered against.
--- @param id The platform's instance id, from `Backend.attachedGamepads` or a
---     `gamepadAdded` event.
function Gamepad.openGamepad(backend: Backend, gate: Gate, id: number): Gamepad
    local handle = backend.openGamepad(id)
    if handle == nil then
        return nil
    end

    local self = setmetatable({} as Gamepad, GamepadMT)
    self._backend = backend
    self._gate = gate
    self._handle = handle
    self._buttons = inputstate.Buttons.create()
    self._axes = {}
    self._sensors = {}
    self._fingers = {}
    self._labels = {}
    self.id = id
    self.connected = true
    self:_readInfo()
    return self
end

--- Reloads the device's own description. Run at open and whenever the platform
--- reports a remap, which is the only other moment the answers change.
function Gamepad:_readInfo()
    local handle = live(self)
    if handle == nil then
        return
    end
    local info = self._backend.gamepadInfo(handle, self.id)
    self.name = info.name
    self.kind = info.kind
    self.guid = info.guid
    self.path = info.path
    self.playerIndex = info.playerIndex
    self.touchpads = info.touchpads
    -- Labels are per device and per button, and a remap can change them, so
    -- the cache is dropped rather than refreshed field by field.
    self._labels = {}
end

--- Detaches the object from the device and closes it.
---
--- Held buttons are released first, because the platform will never deliver
--- the release for a device that is gone and a button held forever is worse
--- than one that never worked.
function Gamepad:_disconnect()
    local handle = self._handle
    self.connected = false
    self._handle = nil
    self._buttons:releaseAll()
    self._axes = {}
    self._sensors = {}
    self._fingers = {}
    if handle ~= nil then
        self._backend.closeGamepad(handle)
    end
end

--- Clears every tier. For focus loss, where the device is still there but the
--- application is not the one receiving from it.
function Gamepad:_releaseHeld()
    self._buttons:releaseAll()
end

-------------------------------------------------------------------------------
-- Event intake
--
-- Called by `Input` as it folds the event stream, never by a game. Everything
-- here is state a query later reads, which is what makes a recorded session
-- replay: nothing below polls the device.
-------------------------------------------------------------------------------

function Gamepad:_press(button: integer)
    self._buttons:press(button)
end

function Gamepad:_release(button: integer)
    self._buttons:release(button)
end

function Gamepad:_setAxis(axis: integer, value: number)
    self._axes[axis] = value
end

function Gamepad:_setSensor(sensor: integer, x: number, y: number, z: number)
    local reading = self._sensors[sensor]
    if reading == nil then
        reading = {0.0, 0.0, 0.0}
        self._sensors[sensor] = reading
    end
    reading[1], reading[2], reading[3] = x, y, z
end

function Gamepad:_setFinger(touchpad: integer, finger: integer, x: number, y: number, pressure: number, down: boolean)
    local pad = self._fingers[touchpad]
    if pad == nil then
        pad = {}
        self._fingers[touchpad] = pad
    end
    local held = pad[finger]
    if held == nil then
        held = {touchpad = touchpad, finger = finger} as TouchpadFinger
        pad[finger] = held
    end
    held.x, held.y, held.pressure, held.down = x, y, pressure, down
end

function Gamepad:_beginFrame()
    self._buttons:beginFrame()
end

function Gamepad:_exitFixedPhase()
    self._buttons:exitFixed()
end

--- Drops the pending edges when capture moves to another layer. Held buttons
--- and axis positions survive, because those are states the pad is still
--- reporting rather than things that happened on one side of a boundary.
function Gamepad:_clearEdges()
    self._buttons:clearEdges()
end

-------------------------------------------------------------------------------
-- Queries
-------------------------------------------------------------------------------

local function resolveButton(self: Gamepad, button: string | integer): integer
    if button is string then
        local code = self._backend.gamepadButtonFromName(button)
        if code == nil then
            error(("tecs: no gamepad button named '%s'"):format(button), 3)
        end
        return code
    end
    return button
end

local function resolveAxis(self: Gamepad, axis: string | integer): integer
    if axis is string then
        local code = self._backend.gamepadAxisFromName(axis)
        if code == nil then
            error(("tecs: no gamepad axis named '%s'"):format(axis), 3)
        end
        return code
    end
    return axis
end

local function resolveSensor(self: Gamepad, sensor: string | integer): integer
    if sensor is string then
        local code = self._backend.sensorFromName(sensor)
        if code == nil then
            error(("tecs: no sensor named '%s'"):format(sensor), 3)
        end
        return code
    end
    return sensor
end

--- Whether a button is held. Names are positional: "south", "leftShoulder",
--- "dpadUp".
function Gamepad:buttonDown(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    return self._buttons.down[resolveButton(self, button)] == true
end

--- Whether a button went down. Reads the latched set inside a fixed step, so
--- a press that began and ended between two steps is not lost.
function Gamepad:buttonPressed(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    local edges = self._buttons:edges(self._gate.fixed, false)
    return edges[resolveButton(self, button)] == true
end

--- Whether a button came up, on the same tiers as `buttonPressed`.
function Gamepad:buttonReleased(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    local edges = self._buttons:edges(self._gate.fixed, true)
    return edges[resolveButton(self, button)] == true
end

--- An axis in -1..1, or a trigger in 0..1, or zero if the layer cannot read.
---
--- Names are "leftX", "rightY", "leftTrigger" and so on. Sticks report Y
--- growing downward, matching the screen rather than a maths convention.
---
--- Values inside the deadzone read as zero and values outside it are not
--- rescaled, so a stick leaving the deadzone steps from zero to the deadzone
--- magnitude. A game that wants a continuous ramp rescales what it gets.
--- @param deadzone Magnitude below which the axis reads as zero. Defaults to a
---     value that suits the hardware, since stick drift is a property of the
---     device rather than of any one game.
function Gamepad:axis(axis: string | integer, deadzone?: number, layer?: Layer): number
    if not self._gate:canRead(layer) then
        return 0.0
    end
    local value = self._axes[resolveAxis(self, axis)] or 0.0
    local limit = deadzone or DEFAULT_DEADZONE
    if value < limit and value > -limit then
        return 0.0
    end
    return value
end

--- Whether the device carries a button at all, so a prompt can be omitted
--- rather than shown for something the player does not have.
---
--- Asked of the device rather than of the layer stack, so this answers the
--- same way whatever is on top. A disconnected pad answers false, which is the
--- same answer a prompt wants.
function Gamepad:hasButton(button: string | integer): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.gamepadHasButton(handle, resolveButton(self, button))
end

--- Whether the device carries an axis, on the same terms as `hasButton`.
---
--- Worth asking before binding: a pad with no right stick reads zero on it
--- forever, which is indistinguishable from one the player is not moving.
function Gamepad:hasAxis(axis: string | integer): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.gamepadHasAxis(handle, resolveAxis(self, axis))
end

--- What is printed on a button, for a prompt: "a", "cross", "square".
---
--- Cached, because a prompt asks every frame it is on screen and the answer
--- only changes when the device is remapped, which drops the cache.
function Gamepad:label(button: string | integer): string
    local handle = live(self)
    if handle == nil then
        return "unknown"
    end
    local code = resolveButton(self, button)
    local cached = self._labels[code]
    if cached ~= nil then
        return cached
    end
    local found = self._backend.gamepadButtonLabel(handle, code)
    self._labels[code] = found
    return found
end

--- Power state name and charge percentage.
---
--- States are "onBattery", "charging", "charged", "noBattery", "unknown" and
--- "error". The percentage is -1 wherever the device declines to report one,
--- which includes every state that is not about a battery.
--- @return The state name, then the charge in 0..100 or -1.
function Gamepad:power(): string, integer
    local handle = live(self)
    if handle == nil then
        return "unknown", -1
    end
    return self._backend.gamepadPower(handle)
end

-------------------------------------------------------------------------------
-- Sensors
-------------------------------------------------------------------------------

--- Whether the device carries a sensor: "gyro" or "accelerometer".
function Gamepad:hasSensor(sensor: string | integer): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.gamepadHasSensor(handle, resolveSensor(self, sensor))
end

--- Turns a sensor on or off.
---
--- Off by default and opt-in on purpose: an enabled sensor delivers an event
--- every few milliseconds, and a game that does not read one should not pay
--- for the stream.
function Gamepad:enableSensor(sensor: string | integer, enabled?: boolean): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.setGamepadSensor(handle, resolveSensor(self, sensor), enabled ~= false)
end

--- Whether a sensor is currently delivering readings.
---
--- Asked of the device, so this reports what is actually streaming rather than
--- what `enableSensor` was last asked for: a request the device refused shows
--- up here as false.
function Gamepad:sensorEnabled(sensor: string | integer): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.gamepadSensorEnabled(handle, resolveSensor(self, sensor))
end

--- The most recent reading from a sensor, as three components.
---
--- Folded from the event stream rather than polled, so a replay reproduces it
--- and a blocked layer cannot read it.
function Gamepad:sensor(sensor: string | integer, layer?: Layer): number, number, number
    if not self._gate:canRead(layer) then
        return 0.0, 0.0, 0.0
    end
    local reading = self._sensors[resolveSensor(self, sensor)]
    if reading == nil then
        return 0.0, 0.0, 0.0
    end
    return reading[1], reading[2], reading[3]
end

-------------------------------------------------------------------------------
-- Touchpads
-------------------------------------------------------------------------------

--- Fingers currently on a touchpad, in 0..1 across it.
---
--- The records are reused between calls, so anything retaining one has to copy
--- it. The list is not: a fresh one is built per call, which makes this a poor
--- thing to ask every frame from a hot path.
--- @param touchpad Which touchpad, zero-based. Defaults to the first, which is
---     the only one on every device that has any.
function Gamepad:touchpadFingers(touchpad?: integer, layer?: Layer): {TouchpadFinger}
    local out: {TouchpadFinger} = {}
    if not self._gate:canRead(layer) then
        return out
    end
    local pad = self._fingers[touchpad or 0]
    if pad == nil then
        return out
    end
    for _, finger in pairs(pad) do
        if finger.down then
            out[#out + 1] = finger
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- Outputs
-------------------------------------------------------------------------------

--- Rumbles both motors, at 0..1 each, for `seconds`.
---
--- Returns false rather than raising when the device is gone or has no motor,
--- because rumble is a garnish and a game should not have to guard it.
---
--- A second call replaces the first rather than adding to it, so a long effect
--- is cancelled by a short one. Seconds are rounded to milliseconds, which is
--- the resolution the platform takes.
--- @param low The heavier, lower-frequency motor.
--- @param high The lighter, higher-frequency one.
function Gamepad:rumble(low: number, high: number, seconds: number): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.rumble(handle, low, high, math.floor((seconds or 0.0) * 1000.0 + 0.5))
end

--- Rumbles the triggers, on the devices that have motors in them.
---
--- Separate from `rumble` because the motors are separate hardware: a device
--- with trigger motors has the body motors too, and asking for one does
--- nothing to the other. False on everything else.
function Gamepad:rumbleTriggers(left: number, right: number, seconds: number): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.rumbleTriggers(handle, left, right, math.floor((seconds or 0.0) * 1000.0 + 0.5))
end

--- Sets the device's light, in 0..1 per channel.
---
--- The bar or ring some pads carry, not the numbered player indicator, which
--- `setPlayerIndex` drives. False on a device with neither.
function Gamepad:setLED(red: number, green: number, blue: number): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.setLED(handle, red, green, blue)
end

--- Assigns the player slot, which is what lights the numbered indicator.
---
--- `playerIndex` is updated only if the platform accepted the change, so the
--- field describes the device rather than the last request. Nothing here
--- prevents two pads holding the same slot; that is the caller's to arrange.
--- @param index The slot, zero-based, or -1 for none.
function Gamepad:setPlayerIndex(index: integer): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    if not self._backend.setPlayerIndex(handle, index) then
        return false
    end
    self.playerIndex = index
    return true
end

return Gamepad
