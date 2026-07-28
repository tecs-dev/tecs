---
description: "One connected gamepad as an object: buttons, axes, sensors, touchpads, rumble, lights and battery"
outline: deep
---

# Gamepad

A gamepad is not a set of globals the way a keyboard nearly is. It has identity, a lifetime shorter than the
process, metadata, capabilities that differ between devices, and outputs. Two pads sharing one button set is not
a simplification, it is a defect: pad A releasing a button would release pad B's. So each device owns its own
state and is reached through its own object.

A retained reference to a device that went away is safe by construction rather than by documented caution. The
platform handle lives in exactly one field, exactly one function reads it, and disconnection clears it before the
handle is closed. Every method takes its quiet branch from there: queries answer as if nothing is held, outputs
report failure, and nothing reaches a freed pointer. A pad is never revived either, so a reference held across a
reconnect stays disconnected and the reconnected device is a new object.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

The whole surface is `require("tecs")` and every module is a field on it, so this module is `tecs.Gamepad`.
`tecs` is also set as a global, which makes the require line optional, and engine modules are resolved lazily on
first field access.

## Where a pad comes from

Pads are opened, fed the event stream and disconnected by [`Input`](/modules/Input), which also owns the layer
stack every query here is answered against; that module is where a game gets hold of a `Gamepad` object in the
first place.

Nothing on this page polls the device for state. Buttons, axes, sensor readings and touchpad fingers are all
folded from the event stream as it arrives, which is what makes a recorded session replay. Only the questions
about the device itself, the ones under [capabilities](#capabilities-and-identity), read the hardware.

## Fields

| Field         | Type      | Description                                                                                                              |
| ------------- | --------- | ------------------------------------------------------------------------------------------------------------------------ |
| `id`          | `number`  | Platform instance id. Unique among attached devices, and not reused by this object once the device is gone.              |
| `connected`   | `boolean` | Whether the device is still attached. False for good once it is: a pad is never revived, so this only ever goes one way. |
| `name`        | `string`  | What the platform calls the device, for showing the player which pad is which. Not stable across platforms or drivers.   |
| `kind`        | `string`  | Device family. See [device families](#device-families).                                                                  |
| `guid`        | `string`  | Stable hardware identity, for matching saved bindings. This is what matches, not `name`.                                 |
| `path`        | `string`  | Where the platform says the device is attached. Empty when it declines to say.                                           |
| `playerIndex` | `integer` | Player slot the platform assigned, or `-1` for none. See [`setPlayerIndex`](#setplayerindex).                            |
| `touchpads`   | `integer` | Touchpads the device carries. Zero on most.                                                                              |

### Device families

`kind` is one of `"standard"`, `"xbox360"`, `"xboxOne"`, `"ps3"`, `"ps4"`, `"ps5"`, `"switchPro"`,
`"joyconLeft"`, `"joyconRight"`, `"joyconPair"` and `"gamecube"`, or `"unknown"` when the platform does not
recognise the device.

## Names

Buttons are named positionally. `south` is the button nearest the player on every pad, where `a` is that button
on some pads and the one to its right on others. What is printed on the hardware is a separate question, and
[`label`](#label) answers it, because a prompt has to show the player their own pad.

Every method that takes a button, an axis or a sensor takes either the name or the platform's own integer code.
A name that is not in the table below raises.

| Kind    | Names                                                                                                                                                                                                                                                               |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Buttons | `south`, `east`, `west`, `north`, `back`, `guide`, `start`, `leftStick`, `rightStick`, `leftShoulder`, `rightShoulder`, `dpadUp`, `dpadDown`, `dpadLeft`, `dpadRight`, `misc1` to `misc6`, `leftPaddle1`, `leftPaddle2`, `rightPaddle1`, `rightPaddle2`, `touchpad` |
| Axes    | `leftX`, `leftY`, `rightX`, `rightY`, `leftTrigger`, `rightTrigger`                                                                                                                                                                                                 |
| Sensors | `gyro`, `accelerometer`, and the per-side `leftGyro`, `rightGyro`, `leftAccelerometer`, `rightAccelerometer` a split device carries                                                                                                                                 |

## Layers

Every query that reads folded state takes an optional `layer`, and answers as if nothing were held when that
layer cannot read. Omitting it means the base layer, which is the safe default: it goes quiet when anything is
pushed over it. The stack is shared across every device rather than being one of this pad's own, so a layer
blocks every device or none. The stack itself lives in [`Input`](/modules/Input).

The questions about the device rather than about its state, `hasButton`, `hasAxis`, `hasSensor`,
`sensorEnabled`, `label` and `power`, take no layer and answer the same way whatever is on top.

## Buttons

### buttonDown

Whether a button is held.

```teal
function Gamepad:buttonDown(button: string | integer, layer?: Layer): boolean
```

**Parameters:**

- `button`: a positional name or a platform code.
- `layer`: the layer to answer for. Omitted, the base layer.

**Returns:** whether the button is held right now, and `false` when the layer cannot read.

### buttonPressed

Whether a button went down.

```teal
function Gamepad:buttonPressed(button: string | integer, layer?: Layer): boolean
```

Inside a fixed step this reads the latched set, so a press that began and ended between two steps is not lost.

**Returns:** whether the button went down, and `false` when the layer cannot read.

### buttonReleased

Whether a button came up, on the same tiers as `buttonPressed`.

```teal
function Gamepad:buttonReleased(button: string | integer, layer?: Layer): boolean
```

**Example:**

```teal
if pad:buttonPressed("south") then
    jump()
end
if pad:buttonDown("rightShoulder") then
    aim()
end
```

## Axes

### axis

An axis in -1..1, or a trigger in 0..1.

```teal
function Gamepad:axis(axis: string | integer, deadzone?: number, layer?: Layer): number
```

**Parameters:**

- `axis`: a name or a platform code.
- `deadzone`: magnitude below which the axis reads as zero. Defaults to `0.15`, because stick drift is a property
  of the hardware rather than of any one game.
- `layer`: the layer to answer for. Omitted, the base layer.

**Returns:** the axis value, or zero inside the deadzone and zero when the layer cannot read.

Sticks report Y growing downward, matching the screen rather than a maths convention. Values inside the deadzone
read as zero and values outside it are not rescaled, so a stick leaving the deadzone steps from zero to the
deadzone magnitude. A game that wants a continuous ramp rescales what it gets.

**Example:**

```teal
local moveX <const> = pad:axis("leftX")
local moveY <const> = pad:axis("leftY")
local throttle <const> = pad:axis("rightTrigger", 0.05)
```

## Capabilities and identity

### hasButton

Whether the device carries a button at all, so a prompt can be omitted rather than shown for something the player
does not have.

```teal
function Gamepad:hasButton(button: string | integer): boolean
```

**Returns:** whether the device has it. A disconnected pad answers `false`, which is the same answer a prompt
wants.

### hasAxis

Whether the device carries an axis, on the same terms as `hasButton`.

```teal
function Gamepad:hasAxis(axis: string | integer): boolean
```

Worth asking before binding: a pad with no right stick reads zero on it forever, which is indistinguishable from
one the player is not moving.

### label

What is printed on a button, for a prompt.

```teal
function Gamepad:label(button: string | integer): string
```

**Returns:** one of `"a"`, `"b"`, `"x"`, `"y"`, `"cross"`, `"circle"`, `"square"`, `"triangle"`, or `"unknown"`
for a button the platform has no label for and for a pad that has gone.

Cached, because a prompt asks every frame it is on screen and the answer only changes when the device is
remapped, which drops the cache.

**Example:**

```teal
if pad:hasButton("south") then
    local hint <const> = ("Press %s to jump"):format(pad:label("south"))
    drawPrompt(hint)
end
```

### power

Power state name and charge percentage.

```teal
function Gamepad:power(): string, integer
```

**Returns:** the state name, then the charge in 0..100 or `-1`.

States are `"onBattery"`, `"charging"`, `"charged"`, `"noBattery"`, `"unknown"` and `"error"`. The percentage is
`-1` wherever the device declines to report one, which includes every state that is not about a battery. A pad
that has gone answers `"unknown", -1`.

## Sensors

A pad's gyro and accelerometer are off until asked for, and that is opt-in on purpose: an enabled sensor delivers
an event every few milliseconds, and a game that does not read one should not pay for the stream.

### hasSensor

Whether the device carries a sensor.

```teal
function Gamepad:hasSensor(sensor: string | integer): boolean
```

### enableSensor

Turns a sensor on or off.

```teal
function Gamepad:enableSensor(sensor: string | integer, enabled?: boolean): boolean
```

**Parameters:**

- `sensor`: a name or a platform code.
- `enabled`: whether to turn it on. Defaults to `true`.

**Returns:** whether the platform accepted the request. `false` for a pad that has gone.

### sensorEnabled

Whether a sensor is currently delivering readings.

```teal
function Gamepad:sensorEnabled(sensor: string | integer): boolean
```

Asked of the device, so this reports what is actually streaming rather than what `enableSensor` was last asked
for: a request the device refused shows up here as `false`.

### sensor

The most recent reading from a sensor, as three components.

```teal
function Gamepad:sensor(sensor: string | integer, layer?: Layer): number, number, number
```

**Returns:** the three components, or three zeros when nothing has been read yet and when the layer cannot read.

Folded from the event stream rather than polled, so a replay reproduces it and a blocked layer cannot read it.

**Example:**

```teal
if pad:hasSensor("gyro") then
    pad:enableSensor("gyro")
end

local pitch, yaw, roll = pad:sensor("gyro")
```

## Touchpads

### TouchpadFinger

One finger on one of the device's touchpads, in 0..1 across the pad.

| Field      | Type      | Description                                                                                                                                                                                          |
| ---------- | --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `touchpad` | `integer` | Which touchpad, zero-based, below `touchpads`.                                                                                                                                                       |
| `finger`   | `integer` | The finger's slot on that touchpad, zero-based. A position on the device rather than an identity: unlike a touch-surface finger this is not a 64-bit id, so it fits a number and is compared as one. |
| `x`        | `number`  | Position across the pad from its left edge, in 0..1.                                                                                                                                                 |
| `y`        | `number`  | Position across the pad from its top edge, in 0..1.                                                                                                                                                  |
| `pressure` | `number`  | How hard, in 0..1, on a device that measures it. Devices that do not report a constant while the finger is down.                                                                                     |
| `down`     | `boolean` | Whether the finger is on the pad.                                                                                                                                                                    |

The type is reachable as `tecs.Gamepad.TouchpadFinger`.

### touchpadFingers

Fingers currently on a touchpad.

```teal
function Gamepad:touchpadFingers(touchpad?: integer, layer?: Layer): {TouchpadFinger}
```

**Parameters:**

- `touchpad`: which touchpad, zero-based. Defaults to the first, which is the only one on every device that has
  any.
- `layer`: the layer to answer for. Omitted, the base layer.

**Returns:** the fingers that are down, and an empty list when the layer cannot read.

::: warning The records are reused
A returned record is reused between calls, so anything retaining one has to copy it. The list is not reused: a
fresh one is built per call, which makes this a poor thing to ask every frame from a hot path.
:::

## Outputs

Every output returns `false` rather than raising when the device is gone or has no such hardware, because rumble
and lights are garnish and a game should not have to guard them.

### rumble

Rumbles both motors, at 0..1 each, for `seconds`.

```teal
function Gamepad:rumble(low: number, high: number, seconds: number): boolean
```

**Parameters:**

- `low`: the heavier, lower-frequency motor.
- `high`: the lighter, higher-frequency one.
- `seconds`: how long, rounded to milliseconds, which is the resolution the platform takes.

**Returns:** whether the platform accepted it.

A second call replaces the first rather than adding to it, so a long effect is cancelled by a short one.

### rumbleTriggers

Rumbles the triggers, on the devices that have motors in them.

```teal
function Gamepad:rumbleTriggers(left: number, right: number, seconds: number): boolean
```

Separate from `rumble` because the motors are separate hardware: a device with trigger motors has the body motors
too, and asking for one does nothing to the other. `false` on everything else.

### setLED

Sets the device's light, in 0..1 per channel.

```teal
function Gamepad:setLED(red: number, green: number, blue: number): boolean
```

The bar or ring some pads carry, not the numbered player indicator, which `setPlayerIndex` drives. `false` on a
device with neither.

### setPlayerIndex

Assigns the player slot, which is what lights the numbered indicator.

```teal
function Gamepad:setPlayerIndex(index: integer): boolean
```

**Parameters:**

- `index`: the slot, zero-based, or `-1` for none.

**Returns:** whether the platform accepted the change.

The `playerIndex` field is updated only if the platform accepted it, so the field describes the device rather
than the last request. Nothing here prevents two pads holding the same slot; that is the caller's to arrange.

**Example:**

```teal
if pad:setPlayerIndex(0) then
    pad:setLED(0.0, 0.4, 1.0)
end
pad:rumble(0.8, 0.3, 0.2)
```

## Design record

- [Input](https://github.com/tecs-dev/tecs/blob/main/README.md#input)
