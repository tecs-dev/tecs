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
    touchpad: integer
    finger: integer
    x: number
    y: number
    pressure: number
    down: boolean
end

local record Gamepad
    TouchpadFinger: TouchpadFinger

    --- Platform instance id. Unique among attached devices, and not reused by
    --- this object once the device is gone.
    id: number
    --- Whether the device is still attached.
    connected: boolean
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
    --- Touchpads the device carries.
    touchpads: integer

    _backend: Backend
    _gate: Gate
    --- The platform handle, and the only field that holds one. Nil once the
    --- device is gone, which is what makes a stale reference harmless.
    _handle: loader.CPtr
    _buttons: Buttons
    _axes: {integer: number}
    _sensors: {integer: {number}}
    _fingers: {integer: {integer: TouchpadFinger}}
    _labels: {integer: string}

    --- Declared here because opening a device calls it, and the definition
    --- reads more naturally beside the rest of the lifetime.
    _readInfo: function(self: Gamepad)
end

local GamepadMT <const>: metatable<Gamepad> = { __index = Gamepad }

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
function Gamepad.open(backend: Backend, gate: Gate, id: number): Gamepad
    local handle = backend.openGamepad(id)
    if handle == nil then return nil end

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
    if handle == nil then return end
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
    if handle ~= nil then self._backend.closeGamepad(handle) end
end

--- Clears every tier. For focus loss, where the device is still there but the
--- application is not the one receiving from it.
function Gamepad:_releaseHeld()
    self._buttons:releaseAll()
end

-------------------------------------------------------------------------------
-- Event intake
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
        reading = { 0.0, 0.0, 0.0 }
        self._sensors[sensor] = reading
    end
    reading[1], reading[2], reading[3] = x, y, z
end

function Gamepad:_setFinger(touchpad: integer, finger: integer, x: number,
                            y: number, pressure: number, down: boolean)
    local pad = self._fingers[touchpad]
    if pad == nil then
        pad = {}
        self._fingers[touchpad] = pad
    end
    local held = pad[finger]
    if held == nil then
        held = { touchpad = touchpad, finger = finger } as TouchpadFinger
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
    if not self._gate:canRead(layer) then return false end
    return self._buttons.down[resolveButton(self, button)] == true
end

--- Whether a button went down. Reads the latched set inside a fixed step, so
--- a press that began and ended between two steps is not lost.
function Gamepad:buttonPressed(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then return false end
    local edges = self._buttons:edges(self._gate.fixed, false)
    return edges[resolveButton(self, button)] == true
end

--- Whether a button came up, on the same tiers as `buttonPressed`.
function Gamepad:buttonReleased(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then return false end
    local edges = self._buttons:edges(self._gate.fixed, true)
    return edges[resolveButton(self, button)] == true
end

--- An axis in -1..1, or a trigger in 0..1, or zero if the layer cannot read.
---
--- `deadzone` suppresses stick drift and defaults to a value that suits the
--- hardware rather than any one game.
function Gamepad:axis(axis: string | integer, deadzone?: number,
                      layer?: Layer): number
    if not self._gate:canRead(layer) then return 0.0 end
    local value = self._axes[resolveAxis(self, axis)] or 0.0
    local limit = deadzone or DEFAULT_DEADZONE
    if value < limit and value > -limit then return 0.0 end
    return value
end

--- Whether the device carries a button at all, so a prompt can be omitted
--- rather than shown for something the player does not have.
function Gamepad:hasButton(button: string | integer): boolean
    local handle = live(self)
    if handle == nil then return false end
    return self._backend.gamepadHasButton(handle, resolveButton(self, button))
end

function Gamepad:hasAxis(axis: string | integer): boolean
    local handle = live(self)
    if handle == nil then return false end
    return self._backend.gamepadHasAxis(handle, resolveAxis(self, axis))
end

--- What is printed on a button, for a prompt: "a", "cross", "square".
---
--- Cached, because a prompt asks every frame it is on screen and the answer
--- only changes when the device is remapped, which drops the cache.
function Gamepad:label(button: string | integer): string
    local handle = live(self)
    if handle == nil then return "unknown" end
    local code = resolveButton(self, button)
    local cached = self._labels[code]
    if cached ~= nil then return cached end
    local found = self._backend.gamepadButtonLabel(handle, code)
    self._labels[code] = found
    return found
end

--- Power state name and charge percentage, or "unknown" and -1.
function Gamepad:power(): string, integer
    local handle = live(self)
    if handle == nil then return "unknown", -1 end
    return self._backend.gamepadPower(handle)
end

-------------------------------------------------------------------------------
-- Sensors
-------------------------------------------------------------------------------

--- Whether the device carries a sensor: "gyro" or "accelerometer".
function Gamepad:hasSensor(sensor: string | integer): boolean
    local handle = live(self)
    if handle == nil then return false end
    return self._backend.gamepadHasSensor(handle, resolveSensor(self, sensor))
end

--- Turns a sensor on or off.
---
--- Off by default and opt-in on purpose: an enabled sensor delivers an event
--- every few milliseconds, and a game that does not read one should not pay
--- for the stream.
function Gamepad:enableSensor(sensor: string | integer, enabled?: boolean): boolean
    local handle = live(self)
    if handle == nil then return false end
    return self._backend.setGamepadSensor(handle, resolveSensor(self, sensor),
        enabled ~= false)
end

function Gamepad:sensorEnabled(sensor: string | integer): boolean
    local handle = live(self)
    if handle == nil then return false end
    return self._backend.gamepadSensorEnabled(handle, resolveSensor(self, sensor))
end

--- The most recent reading from a sensor, as three components.
---
--- Folded from the event stream rather than polled, so a replay reproduces it
--- and a blocked layer cannot read it.
function Gamepad:sensor(sensor: string | integer, layer?: Layer): number, number, number
    if not self._gate:canRead(layer) then return 0.0, 0.0, 0.0 end
    local reading = self._sensors[resolveSensor(self, sensor)]
    if reading == nil then return 0.0, 0.0, 0.0 end
    return reading[1], reading[2], reading[3]
end

-------------------------------------------------------------------------------
-- Touchpads
-------------------------------------------------------------------------------

--- Fingers currently on a touchpad, in 0..1 across it.
---
--- The returned records are reused between calls, so anything retaining one
--- has to copy it.
function Gamepad:touchpadFingers(touchpad?: integer, layer?: Layer): {TouchpadFinger}
    local out: {TouchpadFinger} = {}
    if not self._gate:canRead(layer) then return out end
    local pad = self._fingers[touchpad or 0]
    if pad == nil then return out end
    for _, finger in pairs(pad) do
        if finger.down then out[#out + 1] = finger end
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
function Gamepad:rumble(low: number, high: number, seconds: number): boolean
    local handle = live(self)
    if handle == nil then return false end
    return self._backend.rumble(handle, low, high,
        math.floor((seconds or 0.0) * 1000.0 + 0.5))
end

--- Rumbles the triggers, on the devices that have motors in them.
function Gamepad:rumbleTriggers(left: number, right: number, seconds: number): boolean
    local handle = live(self)
    if handle == nil then return false end
    return self._backend.rumbleTriggers(handle, left, right,
        math.floor((seconds or 0.0) * 1000.0 + 0.5))
end

--- Sets the device's light, in 0..1 per channel.
function Gamepad:setLED(red: number, green: number, blue: number): boolean
    local handle = live(self)
    if handle == nil then return false end
    return self._backend.setLED(handle, red, green, blue)
end

--- Assigns the player slot, which is what lights the numbered indicator.
function Gamepad:setPlayerIndex(index: integer): boolean
    local handle = live(self)
    if handle == nil then return false end
    if not self._backend.setPlayerIndex(handle, index) then return false end
    self.playerIndex = index
    return true
end

return Gamepad
