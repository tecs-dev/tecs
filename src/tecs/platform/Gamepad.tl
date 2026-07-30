--[[
# Gamepads

Each [`Gamepad`](tealdoc:tecs.platform.input.Gamepad) owns one device's identity, event
state, capabilities, and outputs. A retained reference remains safe after
disconnection: queries return neutral values, outputs return false, and
`connected` stays false. A reconnect creates a new object rather than reviving
the old one.

Buttons use positional names. `"south"` names the button nearest the player on
every pad. `label("south")` returns the hardware label, such as `"a"` or
`"cross"`, for a prompt.

```teal
local pad <const> = app.input:gamepad(1)
if pad ~= nil and pad.connected then
    local moveX <const> = pad:axis("leftX")
    if pad:buttonPressed("south") then
        jump()
    end
end
```

Axes use a 0.15 deadzone by default. Output methods return false when the
device disconnects or lacks the requested hardware, so optional rumble and
lights need no capability branch.

Gamepad sensors remain off until `enableSensor` starts their event stream.
Their readings pass through the same layer stack as buttons and replay from
recorded events.
]]

local inputstate <const> = require("tecs.platform.inputstate")
local inputbackend <const> = require("tecs.platform.inputbackend")
local loader <const> = require("tecs.ffi.loader")

local type Layer = inputstate.Layer
local type Buttons = inputstate.Buttons
local type Gate = inputstate.Gate
local type Backend = inputbackend.Backend

--- `TouchpadFinger` reports one finger from the latest touchpad event.
---
--- Gamepad owns and reuses the record. Callers treat every field as read-only.
local record TouchpadFinger
    --- Read-only. Gamepad sets `touchpad` to the zero-based touchpad index when
    --- it creates the record.
    touchpad: integer
    --- Read-only. Gamepad sets `finger` to the zero-based slot on that
    --- touchpad. The value identifies a position, not a persistent finger.
    finger: integer
    --- Read-only. Gamepad updates `x` from 0 to 1 across the touchpad.
    x: number
    --- Read-only. Gamepad updates `y` from 0 to 1 down the touchpad.
    y: number
    --- Read-only. Gamepad updates `pressure` from 0 to 1 when the device
    --- reports it.
    pressure: number
    --- Read-only. Gamepad updates `down` when the finger enters or leaves the
    --- pad and keeps the record for reuse.
    down: boolean
end

--- A `Gamepad` owns one attached gamepad and folds its event state.
---
--- Input owns the object. Callers use its methods and treat public fields as
--- read-only snapshots that change on connection and remap events.
local record Gamepad
    --- Read-only. Exposes
    --- [`TouchpadFinger`](tealdoc:tecs.platform.input.TouchpadFinger), whose records
    --- `touchpadFingers` returns. Ordinary game code does not replace this
    --- field.
    TouchpadFinger: TouchpadFinger

    --- Read-only. Input sets `id` to the platform instance id when it opens the
    --- device and never changes it.
    id: number
    --- Read-only. Input sets `connected` true at open and false permanently
    --- when the device disconnects.
    connected: boolean
    --- Read-only. Input refreshes `name` at open and on remap. The platform
    --- chooses it, so saved bindings use `guid` instead.
    name: string
    --- Read-only. Input refreshes `kind` at open and on remap. It contains a
    --- platform device family such as `"xboxOne"`, `"ps5"` or `"standard"`.
    kind: string
    --- Read-only. Input refreshes `guid` at open and on remap. Game code uses
    --- it to match saved bindings.
    guid: string
    --- Read-only. Input refreshes `path` at open and on remap. It contains an
    --- empty string when the platform declines to report one.
    path: string
    --- Read-only. Input refreshes `playerIndex` on open, remap and a successful
    --- `setPlayerIndex`. It contains -1 when the device has no slot.
    playerIndex: integer
    --- Read-only. Input refreshes `touchpads` at open and on remap.
    touchpads: integer

    --- The backend handles every outbound command and isolates SDL.
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

    --- Engine-owned. Opens a device for an Input object.
    ---
    --- Ordinary game code gets gamepads from `Input:gamepads` and must not call
    --- this function.
    ---
    --- @param backend Input supplies the platform backend.
    --- @param gate Input supplies its shared layer gate.
    --- @param id Input supplies the platform instance id.
    --- @return Returns the opened gamepad, or nil when the device disappeared.
    openGamepad: function(backend: Backend, gate: Gate, id: number): Gamepad

    --- Returns whether a button is held.
    ---
    --- @param button The caller supplies a positional name or platform number.
    ---     An unknown name raises.
    --- @param layer The caller omits this value to read the base layer.
    --- @return Returns false when the layer cannot read.
    buttonDown: function(self: Gamepad, button: string | integer, layer?: Layer): boolean

    --- Returns whether a button went down in the active tier.
    ---
    --- @param button The caller supplies a positional name or platform number.
    ---     An unknown name raises.
    --- @param layer The caller omits this value to read the base layer.
    --- @return Returns false when the layer cannot read.
    buttonPressed: function(self: Gamepad, button: string | integer, layer?: Layer): boolean

    --- Returns whether a button came up in the active tier.
    ---
    --- @param button The caller supplies a positional name or platform number.
    ---     An unknown name raises.
    --- @param layer The caller omits this value to read the base layer.
    --- @return Returns false when the layer cannot read.
    buttonReleased: function(self: Gamepad, button: string | integer, layer?: Layer): boolean

    --- Returns an axis value after applying a deadzone.
    ---
    --- Sticks return -1 to 1 and triggers return 0 to 1. Values outside the
    --- deadzone keep their original magnitude.
    ---
    --- @param axis The caller supplies a name or platform number. An unknown
    ---     name raises.
    --- @param deadzone The caller supplies the zero threshold or omits it for
    ---     the hardware-oriented default of 0.15.
    --- @param layer The caller omits this value to read the base layer.
    --- @return Returns zero when the layer cannot read or no event has set the
    ---     axis.
    axis: function(self: Gamepad, axis: string | integer, deadzone?: number, layer?: Layer): number

    --- Returns whether the device carries a button.
    ---
    --- @param button The caller supplies a name or platform number.
    --- @return Returns false after disconnection.
    hasButton: function(self: Gamepad, button: string | integer): boolean

    --- Returns whether the device carries an axis.
    ---
    --- @param axis The caller supplies a name or platform number.
    --- @return Returns false after disconnection.
    hasAxis: function(self: Gamepad, axis: string | integer): boolean

    --- Returns the hardware label printed on a button.
    ---
    --- @param button The caller supplies a positional name or platform number.
    --- @return Returns a label such as `"a"` or `"cross"`, or `"unknown"`
    ---     after disconnection.
    label: function(self: Gamepad, button: string | integer): string

    --- Returns the power state and charge.
    ---
    --- @return Returns `"onBattery"`, `"charging"`, `"charged"`,
    ---     `"noBattery"`, `"unknown"` or `"error"`.
    --- @return Returns the percentage from 0 to 100, or -1 when unavailable.
    power: function(self: Gamepad): string, integer

    --- Returns whether the device carries a sensor.
    ---
    --- @param sensor The caller supplies `"gyro"`, `"accelerometer"` or a
    ---     platform number.
    --- @return Returns false after disconnection.
    hasSensor: function(self: Gamepad, sensor: string | integer): boolean

    --- Enables or disables a gamepad sensor event stream.
    ---
    --- @param sensor The caller supplies a sensor name or platform number.
    --- @param enabled The caller passes false to disable the stream; nil and
    ---     true enable it.
    --- @return Returns whether the device accepted the change.
    enableSensor: function(self: Gamepad, sensor: string | integer, enabled?: boolean): boolean

    --- Returns whether a gamepad sensor is streaming.
    ---
    --- @param sensor The caller supplies a sensor name or platform number.
    --- @return Returns live device state and false after disconnection.
    sensorEnabled: function(self: Gamepad, sensor: string | integer): boolean

    --- Returns the latest event reading from a gamepad sensor.
    ---
    --- @param sensor The caller supplies a sensor name or platform number.
    --- @param layer The caller omits this value to read the base layer.
    --- @return Returns the x component, or zero when unreadable.
    --- @return Returns the y component, or zero when unreadable.
    --- @return Returns the z component, or zero when unreadable.
    sensor: function(self: Gamepad, sensor: string | integer, layer?: Layer): number, number, number

    --- Returns the fingers currently on a gamepad touchpad.
    ---
    --- @param touchpad The caller supplies a zero-based index or omits it for
    ---     the first touchpad.
    --- @param layer The caller omits this value to read the base layer.
    --- @return Returns a new list of Gamepad-owned records. Callers copy values
    ---     they need to retain.
    touchpadFingers: function(self: Gamepad, touchpad?: integer, layer?: Layer): {TouchpadFinger}

    --- Rumbles the low- and high-frequency motors.
    ---
    --- A new call replaces an active effect.
    ---
    --- @param low The caller supplies the low-frequency strength from 0 to 1.
    --- @param high The caller supplies the high-frequency strength from 0 to 1.
    --- @param seconds The caller supplies the duration in seconds.
    --- @return Returns false after disconnection or without rumble hardware.
    rumble: function(self: Gamepad, low: number, high: number, seconds: number): boolean

    --- Rumbles the left and right trigger motors.
    ---
    --- @param left The caller supplies the left strength from 0 to 1.
    --- @param right The caller supplies the right strength from 0 to 1.
    --- @param seconds The caller supplies the duration in seconds.
    --- @return Returns false after disconnection or without trigger motors.
    rumbleTriggers: function(self: Gamepad, left: number, right: number, seconds: number): boolean

    --- Sets the gamepad light color.
    ---
    --- @param red The caller supplies the red channel from 0 to 1.
    --- @param green The caller supplies the green channel from 0 to 1.
    --- @param blue The caller supplies the blue channel from 0 to 1.
    --- @return Returns false after disconnection or without a light.
    setLED: function(self: Gamepad, red: number, green: number, blue: number): boolean

    --- Assigns the platform player slot.
    ---
    --- A successful call updates the read-only `playerIndex` field.
    ---
    --- @param index The caller supplies a zero-based slot or -1 for none.
    --- @return Returns whether the device accepted the slot.
    setPlayerIndex: function(self: Gamepad, index: integer): boolean

    -- Declared here because opening a device calls it, and the definition
    -- reads more naturally beside the rest of the lifetime.

    --- Reloads the device's own description. Run at open and whenever the
    --- platform reports a remap, which is the only other moment the answers
    --- change.
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
    -- Labels belong to a device and button. A remap can change them, so drop
    -- the whole cache.
    self._labels = {}
end

--- Detaches the object from the device and closes it.
---
--- Releases held buttons first because the platform sends no release after
--- the device disappears.
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

function Gamepad:buttonDown(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    return self._buttons.down[resolveButton(self, button)] == true
end

function Gamepad:buttonPressed(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    local edges = self._buttons:edges(self._gate.fixed, false)
    return edges[resolveButton(self, button)] == true
end

function Gamepad:buttonReleased(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    local edges = self._buttons:edges(self._gate.fixed, true)
    return edges[resolveButton(self, button)] == true
end

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

function Gamepad:hasButton(button: string | integer): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.gamepadHasButton(handle, resolveButton(self, button))
end

function Gamepad:hasAxis(axis: string | integer): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.gamepadHasAxis(handle, resolveAxis(self, axis))
end

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

function Gamepad:hasSensor(sensor: string | integer): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.gamepadHasSensor(handle, resolveSensor(self, sensor))
end

function Gamepad:enableSensor(sensor: string | integer, enabled?: boolean): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.setGamepadSensor(handle, resolveSensor(self, sensor), enabled ~= false)
end

function Gamepad:sensorEnabled(sensor: string | integer): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.gamepadSensorEnabled(handle, resolveSensor(self, sensor))
end

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

function Gamepad:rumble(low: number, high: number, seconds: number): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.rumble(handle, low, high, math.floor((seconds or 0.0) * 1000.0 + 0.5))
end

function Gamepad:rumbleTriggers(left: number, right: number, seconds: number): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.rumbleTriggers(handle, left, right, math.floor((seconds or 0.0) * 1000.0 + 0.5))
end

function Gamepad:setLED(red: number, green: number, blue: number): boolean
    local handle = live(self)
    if handle == nil then
        return false
    end
    return self._backend.setLED(handle, red, green, blue)
end

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
