---
description: "One connected gamepad as an object: buttons, axes, sensors, touchpads, rumble, lights and battery"
outline: deep
---

# tecs.gamepad.Gamepad

A gamepad is not a set of globals the way a keyboard nearly is. It has identity, a lifetime shorter than the
process, metadata, capabilities that differ between devices, and outputs. Two pads sharing one button set is not
a simplification, it is a defect: pad A releasing a button would release pad B's. So each device owns its own
state and is reached through its own object.

A retained reference to a device that went away is safe by construction rather than by documented caution. The
platform handle lives in exactly one field, exactly one function reads it, and disconnection clears it before the
handle is closed. Every method takes its quiet branch from there: queries answer as if nothing is held, outputs
report failure, and nothing reaches a freed pointer. A pad is never revived either, so a reference held across a
reconnect stays disconnected and the reconnected device is a new object.

## Where a pad comes from

Pads are opened, fed the event stream and disconnected by [`Input`](/modules/input), which also owns the layer
stack every query here is answered against; that module is where a game gets hold of a `Gamepad` object in the
first place.

Nothing on this page polls the device for state. Buttons, axes, sensor readings and touchpad fingers are all
folded from the event stream as it arrives, which is what makes a recorded session replay. Only the questions
about the device itself, the ones under [capabilities](#capabilities-and-identity), read the hardware.

Held buttons are released when the window loses focus and when the device is removed, and each release is
reported as an edge, so [`buttonReleased`](#buttonreleased) fires for it. The platform delivers no release in
either case, and a button that stayed held forever is worse than one that never worked. Axes, sensor readings
and touchpad fingers are cleared on removal too, so a pad that has gone reads as neutral rather than as frozen
at its last value.

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
blocks every device or none. The stack itself lives in [`Input`](/modules/input).

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

The type is reachable as `tecs.gamepad.TouchpadFinger`.

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

<!-- @generated by docs/scripts/reference.py from src/tecs/platform/Gamepad.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/platform/Gamepad.tl`.

<a id="tecs.gamepad.Gamepad.TouchpadFinger"></a>

### tecs.gamepad.Gamepad.TouchpadFinger

<pre><code v-pre><a href="#tecs.gamepad.Gamepad.TouchpadFinger">tecs.gamepad.Gamepad.TouchpadFinger</a>: TouchpadFinger
</code></pre>

<a id="tecs.gamepad.Gamepad.axis"></a>

### tecs.gamepad.Gamepad.axis

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.axis">tecs.gamepad.Gamepad.axis</a>(self: Gamepad, axis: string | integer, deadzone: number, layer: Layer): number
</code></pre>

An axis in -1..1, or a trigger in 0..1, or zero if the layer cannot read.

Names are "leftX", "rightY", "leftTrigger" and so on. Sticks report Y
growing downward, matching the screen rather than a maths convention.

Values inside the deadzone read as zero and values outside it are not
rescaled, so a stick leaving the deadzone steps from zero to the deadzone
magnitude. A game that wants a continuous ramp rescales what it gets.

#### Parameters

| Type                                 | Name                        | Description                                                                                                                                                           |
| ------------------------------------ | --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>Gamepad</code>           | <code v-pre>self</code>     |                                                                                                                                                                       |
| <code v-pre>string \| integer</code> | <code v-pre>axis</code>     |                                                                                                                                                                       |
| <code v-pre>number</code>            | <code v-pre>deadzone</code> | Magnitude below which the axis reads as zero. Defaults to a value that suits the hardware, since stick drift is a property of the device rather than of any one game. |
| <code v-pre>Layer</code>             | <code v-pre>layer</code>    |                                                                                                                                                                       |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>number</code> |             |

<a id="tecs.gamepad.Gamepad.buttonDown"></a>

### tecs.gamepad.Gamepad.buttonDown

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.buttonDown">tecs.gamepad.Gamepad.buttonDown</a>(self: Gamepad, button: string | integer, layer: Layer): boolean
</code></pre>

Whether a button is held. Names are positional: "south", "leftShoulder",
"dpadUp".

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| <code v-pre>Gamepad</code>           | <code v-pre>self</code>   |             |
| <code v-pre>string \| integer</code> | <code v-pre>button</code> |             |
| <code v-pre>Layer</code>             | <code v-pre>layer</code>  |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.gamepad.Gamepad.buttonPressed"></a>

### tecs.gamepad.Gamepad.buttonPressed

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.buttonPressed">tecs.gamepad.Gamepad.buttonPressed</a>(self: Gamepad, button: string | integer, layer: Layer): boolean
</code></pre>

Whether a button went down. Reads the latched set inside a fixed step, so
a press that began and ended between two steps is not lost.

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| <code v-pre>Gamepad</code>           | <code v-pre>self</code>   |             |
| <code v-pre>string \| integer</code> | <code v-pre>button</code> |             |
| <code v-pre>Layer</code>             | <code v-pre>layer</code>  |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.gamepad.Gamepad.buttonReleased"></a>

### tecs.gamepad.Gamepad.buttonReleased

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.buttonReleased">tecs.gamepad.Gamepad.buttonReleased</a>(self: Gamepad, button: string | integer, layer: Layer): boolean
</code></pre>

Whether a button came up, on the same tiers as `buttonPressed`.

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| <code v-pre>Gamepad</code>           | <code v-pre>self</code>   |             |
| <code v-pre>string \| integer</code> | <code v-pre>button</code> |             |
| <code v-pre>Layer</code>             | <code v-pre>layer</code>  |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.gamepad.Gamepad.connected"></a>

### tecs.gamepad.Gamepad.connected

<pre><code v-pre><a href="#tecs.gamepad.Gamepad.connected">tecs.gamepad.Gamepad.connected</a>: boolean
</code></pre>

Whether the device is still attached. False for good once it is: a pad
is never revived, so this only ever goes one way.
<a id="tecs.gamepad.Gamepad.enableSensor"></a>

### tecs.gamepad.Gamepad.enableSensor

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.enableSensor">tecs.gamepad.Gamepad.enableSensor</a>(self: Gamepad, sensor: string | integer, enabled: boolean): boolean
</code></pre>

Turns a sensor on or off.

Off by default and opt-in on purpose: an enabled sensor delivers an event
every few milliseconds, and a game that does not read one should not pay
for the stream.

#### Parameters

| Type                                 | Name                       | Description |
| ------------------------------------ | -------------------------- | ----------- |
| <code v-pre>Gamepad</code>           | <code v-pre>self</code>    |             |
| <code v-pre>string \| integer</code> | <code v-pre>sensor</code>  |             |
| <code v-pre>boolean</code>           | <code v-pre>enabled</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.gamepad.Gamepad.guid"></a>

### tecs.gamepad.Gamepad.guid

<pre><code v-pre><a href="#tecs.gamepad.Gamepad.guid">tecs.gamepad.Gamepad.guid</a>: string
</code></pre>

Stable hardware identity, for matching saved bindings.
<a id="tecs.gamepad.Gamepad.hasAxis"></a>

### tecs.gamepad.Gamepad.hasAxis

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.hasAxis">tecs.gamepad.Gamepad.hasAxis</a>(self: Gamepad, axis: string | integer): boolean
</code></pre>

Whether the device carries an axis, on the same terms as `hasButton`.

Worth asking before binding: a pad with no right stick reads zero on it
forever, which is indistinguishable from one the player is not moving.

#### Parameters

| Type                                 | Name                    | Description |
| ------------------------------------ | ----------------------- | ----------- |
| <code v-pre>Gamepad</code>           | <code v-pre>self</code> |             |
| <code v-pre>string \| integer</code> | <code v-pre>axis</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.gamepad.Gamepad.hasButton"></a>

### tecs.gamepad.Gamepad.hasButton

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.hasButton">tecs.gamepad.Gamepad.hasButton</a>(self: Gamepad, button: string | integer): boolean
</code></pre>

Whether the device carries a button at all, so a prompt can be omitted
rather than shown for something the player does not have.

Asked of the device rather than of the layer stack, so this answers the
same way whatever is on top. A disconnected pad answers false, which is the
same answer a prompt wants.

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| <code v-pre>Gamepad</code>           | <code v-pre>self</code>   |             |
| <code v-pre>string \| integer</code> | <code v-pre>button</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.gamepad.Gamepad.hasSensor"></a>

### tecs.gamepad.Gamepad.hasSensor

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.hasSensor">tecs.gamepad.Gamepad.hasSensor</a>(self: Gamepad, sensor: string | integer): boolean
</code></pre>

Whether the device carries a sensor: "gyro" or "accelerometer".

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| <code v-pre>Gamepad</code>           | <code v-pre>self</code>   |             |
| <code v-pre>string \| integer</code> | <code v-pre>sensor</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.gamepad.Gamepad.id"></a>

### tecs.gamepad.Gamepad.id

<pre><code v-pre><a href="#tecs.gamepad.Gamepad.id">tecs.gamepad.Gamepad.id</a>: number
</code></pre>

Platform instance id. Unique among attached devices, and not reused by
this object once the device is gone.
<a id="tecs.gamepad.Gamepad.kind"></a>

### tecs.gamepad.Gamepad.kind

<pre><code v-pre><a href="#tecs.gamepad.Gamepad.kind">tecs.gamepad.Gamepad.kind</a>: string
</code></pre>

Device family: "xboxOne", "ps5", "switchPro", "standard", "unknown".
<a id="tecs.gamepad.Gamepad.label"></a>

### tecs.gamepad.Gamepad.label

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.label">tecs.gamepad.Gamepad.label</a>(self: Gamepad, button: string | integer): string
</code></pre>

What is printed on a button, for a prompt: "a", "cross", "square".

Cached, because a prompt asks every frame it is on screen and the answer
only changes when the device is remapped, which drops the cache.

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| <code v-pre>Gamepad</code>           | <code v-pre>self</code>   |             |
| <code v-pre>string \| integer</code> | <code v-pre>button</code> |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>string</code> |             |

<a id="tecs.gamepad.Gamepad.name"></a>

### tecs.gamepad.Gamepad.name

<pre><code v-pre><a href="#tecs.gamepad.Gamepad.name">tecs.gamepad.Gamepad.name</a>: string
</code></pre>

What the platform calls the device, for showing the player which pad is
which. Not stable across platforms or drivers; `guid` is what matches.
<a id="tecs.gamepad.Gamepad.open"></a>

### tecs.gamepad.Gamepad.open

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.open">tecs.gamepad.Gamepad.open</a>(backend: Backend, gate: Gate, id: number): Gamepad
</code></pre>

Opens a device and reads what it says about itself.

Returns nil when the platform will not open it, which happens for a device
unplugged between enumeration and here.

#### Parameters

| Type                       | Name                       | Description                                                                            |
| -------------------------- | -------------------------- | -------------------------------------------------------------------------------------- |
| <code v-pre>Backend</code> | <code v-pre>backend</code> |                                                                                        |
| <code v-pre>Gate</code>    | <code v-pre>gate</code>    | The shared layer stack, which every query on this pad is answered against.             |
| <code v-pre>number</code>  | <code v-pre>id</code>      | The platform's instance id, from `Backend.attachedGamepads` or a `gamepadAdded` event. |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>Gamepad</code> |             |

<a id="tecs.gamepad.Gamepad.path"></a>

### tecs.gamepad.Gamepad.path

<pre><code v-pre><a href="#tecs.gamepad.Gamepad.path">tecs.gamepad.Gamepad.path</a>: string
</code></pre>

Where the platform says the device is attached. Empty when it declines
to say.
<a id="tecs.gamepad.Gamepad.playerIndex"></a>

### tecs.gamepad.Gamepad.playerIndex

<pre><code v-pre><a href="#tecs.gamepad.Gamepad.playerIndex">tecs.gamepad.Gamepad.playerIndex</a>: integer
</code></pre>

Player slot the platform assigned, or -1 for none.
<a id="tecs.gamepad.Gamepad.power"></a>

### tecs.gamepad.Gamepad.power

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.power">tecs.gamepad.Gamepad.power</a>(self: Gamepad): string, integer
</code></pre>

Power state name and charge percentage.

States are "onBattery", "charging", "charged", "noBattery", "unknown" and
"error". The percentage is -1 wherever the device declines to report one,
which includes every state that is not about a battery.

#### Parameters

| Type                       | Name                    | Description |
| -------------------------- | ----------------------- | ----------- |
| <code v-pre>Gamepad</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description                                      |
| -------------------------- | ------------------------------------------------ |
| <code v-pre>string</code>  | The state name, then the charge in 0..100 or -1. |
| <code v-pre>integer</code> |                                                  |

<a id="tecs.gamepad.Gamepad.rumble"></a>

### tecs.gamepad.Gamepad.rumble

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.rumble">tecs.gamepad.Gamepad.rumble</a>(self: Gamepad, low: number, high: number, seconds: number): boolean
</code></pre>

Rumbles both motors, at 0..1 each, for `seconds`.

Returns false rather than raising when the device is gone or has no motor,
because rumble is a garnish and a game should not have to guard it.

A second call replaces the first rather than adding to it, so a long effect
is cancelled by a short one. Seconds are rounded to milliseconds, which is
the resolution the platform takes.

#### Parameters

| Type                       | Name                       | Description                         |
| -------------------------- | -------------------------- | ----------------------------------- |
| <code v-pre>Gamepad</code> | <code v-pre>self</code>    |                                     |
| <code v-pre>number</code>  | <code v-pre>low</code>     | The heavier, lower-frequency motor. |
| <code v-pre>number</code>  | <code v-pre>high</code>    | The lighter, higher-frequency one.  |
| <code v-pre>number</code>  | <code v-pre>seconds</code> |                                     |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.gamepad.Gamepad.rumbleTriggers"></a>

### tecs.gamepad.Gamepad.rumbleTriggers

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.rumbleTriggers">tecs.gamepad.Gamepad.rumbleTriggers</a>(self: Gamepad, left: number, right: number, seconds: number): boolean
</code></pre>

Rumbles the triggers, on the devices that have motors in them.

Separate from `rumble` because the motors are separate hardware: a device
with trigger motors has the body motors too, and asking for one does
nothing to the other. False on everything else.

#### Parameters

| Type                       | Name                       | Description |
| -------------------------- | -------------------------- | ----------- |
| <code v-pre>Gamepad</code> | <code v-pre>self</code>    |             |
| <code v-pre>number</code>  | <code v-pre>left</code>    |             |
| <code v-pre>number</code>  | <code v-pre>right</code>   |             |
| <code v-pre>number</code>  | <code v-pre>seconds</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.gamepad.Gamepad.sensor"></a>

### tecs.gamepad.Gamepad.sensor

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.sensor">tecs.gamepad.Gamepad.sensor</a>(self: Gamepad, sensor: string | integer, layer: Layer): number, number, number
</code></pre>

The most recent reading from a sensor, as three components.

Folded from the event stream rather than polled, so a replay reproduces it
and a blocked layer cannot read it.

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| <code v-pre>Gamepad</code>           | <code v-pre>self</code>   |             |
| <code v-pre>string \| integer</code> | <code v-pre>sensor</code> |             |
| <code v-pre>Layer</code>             | <code v-pre>layer</code>  |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>number</code> |             |
| <code v-pre>number</code> |             |
| <code v-pre>number</code> |             |

<a id="tecs.gamepad.Gamepad.sensorEnabled"></a>

### tecs.gamepad.Gamepad.sensorEnabled

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.sensorEnabled">tecs.gamepad.Gamepad.sensorEnabled</a>(self: Gamepad, sensor: string | integer): boolean
</code></pre>

Whether a sensor is currently delivering readings.

Asked of the device, so this reports what is actually streaming rather than
what `enableSensor` was last asked for: a request the device refused shows
up here as false.

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| <code v-pre>Gamepad</code>           | <code v-pre>self</code>   |             |
| <code v-pre>string \| integer</code> | <code v-pre>sensor</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.gamepad.Gamepad.setLED"></a>

### tecs.gamepad.Gamepad.setLED

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.setLED">tecs.gamepad.Gamepad.setLED</a>(self: Gamepad, red: number, green: number, blue: number): boolean
</code></pre>

Sets the device's light, in 0..1 per channel.

The bar or ring some pads carry, not the numbered player indicator, which
`setPlayerIndex` drives. False on a device with neither.

#### Parameters

| Type                       | Name                     | Description |
| -------------------------- | ------------------------ | ----------- |
| <code v-pre>Gamepad</code> | <code v-pre>self</code>  |             |
| <code v-pre>number</code>  | <code v-pre>red</code>   |             |
| <code v-pre>number</code>  | <code v-pre>green</code> |             |
| <code v-pre>number</code>  | <code v-pre>blue</code>  |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.gamepad.Gamepad.setPlayerIndex"></a>

### tecs.gamepad.Gamepad.setPlayerIndex

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.setPlayerIndex">tecs.gamepad.Gamepad.setPlayerIndex</a>(self: Gamepad, index: integer): boolean
</code></pre>

Assigns the player slot, which is what lights the numbered indicator.

`playerIndex` is updated only if the platform accepted the change, so the
field describes the device rather than the last request. Nothing here
prevents two pads holding the same slot; that is the caller's to arrange.

#### Parameters

| Type                       | Name                     | Description                           |
| -------------------------- | ------------------------ | ------------------------------------- |
| <code v-pre>Gamepad</code> | <code v-pre>self</code>  |                                       |
| <code v-pre>integer</code> | <code v-pre>index</code> | The slot, zero-based, or -1 for none. |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.gamepad.Gamepad.touchpadFingers"></a>

### tecs.gamepad.Gamepad.touchpadFingers

<pre><code v-pre>function <a href="#tecs.gamepad.Gamepad.touchpadFingers">tecs.gamepad.Gamepad.touchpadFingers</a>(self: Gamepad, touchpad: integer, layer: Layer): {<a href="#tecs.gamepad.Gamepad.TouchpadFinger">TouchpadFinger</a>}
</code></pre>

Fingers currently on a touchpad, in 0..1 across it.

The records are reused between calls, so anything retaining one has to copy
it. The list is not: a fresh one is built per call, which makes this a poor
thing to ask every frame from a hot path.

#### Parameters

| Type                       | Name                        | Description                                                                                            |
| -------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------ |
| <code v-pre>Gamepad</code> | <code v-pre>self</code>     |                                                                                                        |
| <code v-pre>integer</code> | <code v-pre>touchpad</code> | Which touchpad, zero-based. Defaults to the first, which is the only one on every device that has any. |
| <code v-pre>Layer</code>   | <code v-pre>layer</code>    |                                                                                                        |

#### Returns

| Type                                                                                   | Description |
| -------------------------------------------------------------------------------------- | ----------- |
| <code v-pre>{<a href="#tecs.gamepad.Gamepad.TouchpadFinger">TouchpadFinger</a>}</code> |             |

<a id="tecs.gamepad.Gamepad.touchpads"></a>

### tecs.gamepad.Gamepad.touchpads

<pre><code v-pre><a href="#tecs.gamepad.Gamepad.touchpads">tecs.gamepad.Gamepad.touchpads</a>: integer
</code></pre>

Touchpads the device carries. Zero on most.
