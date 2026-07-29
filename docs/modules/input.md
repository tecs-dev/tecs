---
description: "Gameplay input in three tiers behind a layer stack, the gamepads attached to it, and the standalone sensors a device carries"
outline: deep
---

# tecs.input

`tecs.input` is what a player does and the devices they do it with. `Input` folds the platform event stream
into per-frame state a system can read; `Gamepad` is one pad, as an object; `sensors` and `openSensor` reach
the accelerometers and gyroscopes a device carries on its own.

They are one module because they are one question asked of three sources, and because the layer stack answers
all three. A pad's buttons are gated by the same stack a keyboard's keys are, so reaching `Input` and
`Gamepad` from different places would make the gate look like a property of one of them.

Platform events stay separate, under [`events`](/modules/events), because that stream also carries lifecycle,
window, display, clipboard and device-arrival events, none of which is gameplay input.

## Input

`tecs.input.Input` is gameplay input, in three tiers, behind a layer stack. A game does not construct one: the
[application](/modules/Application) does, and hands it over as `app.input`.

SDL owns device mechanics; this owns gameplay semantics. That split is why there is no `tecs.keyboard` beside it
and no supported way to reach raw SDL: a query answered by polling the device would bypass replay, layers, edge
detection and latching, all of which live here.

The state is fed typed events and holds no globals, so a recorded session replays by feeding the same events
back. It never sees an `SDL_Event`: the conversion happens once, in [`tecs.events`](/modules/events), and
everything downstream shares that one vocabulary. Every outbound command goes through a backend for the same
reason, so a platform that is not SDL substitutes one object.

### Three tiers

They answer three different questions, and the third is not a variant of the second.

- **Live state** answers "is it held" — `keyDown`, `mouseDown`, `modifierDown`.
- **Frame events** answer "did it change this frame" — `keyPressed`, `keyReleased`, `mousePressed`,
  `mouseReleased`.
- **Latched events** answer that same question for fixed-step systems. A key pressed and released between two
  fixed steps is invisible to frame events, and dropping it produces input loss that is nondeterministic and so
  effectively unreproducible. Latched sets accumulate across every frame since the last fixed step and clear when
  it ends.

There is no third set of method names. The same `keyPressed` reads the latched set inside a fixed phase and the
frame set outside it, because a system does not choose which it wants: its phase already did. The engine brackets
the fixed phases itself, with systems in `FixedFirst` and `FixedLast`, so a game never enters or leaves the
latched tier by hand.

Latching brackets one step, not one frame. The latched edges clear at the end of each step, so a press is
delivered to the first step that runs after it and to that one only, whether the frame ran one step or four.

### Layers

Queries are answered relative to a layer.

```teal
local menu = app.input:pushLayer("menu")
-- gameplay code reading the base layer now sees nothing
app.input:popLayer()
```

A layer that blocks hides input from everything beneath it, so a menu suppresses gameplay without gameplay code
knowing a menu exists. Code that names no layer reads the base layer, which is the safe default: it goes quiet
when anything is pushed over it. Pass `blocking = false` for an overlay that observes without consuming.

| Method                             | What it does                                               |
| ---------------------------------- | ---------------------------------------------------------- |
| `input:pushLayer(name, blocking?)` | Pushes a layer and returns it                              |
| `input:popLayer()`                 | Removes the topmost layer. The base layer is never removed |
| `input:topLayer()`                 | The layer currently on top                                 |
| `input:canRead(layer?)`            | Whether that layer may read input                          |

**Moving capture drops the pending edges.** An edge belongs to whoever could read input at the moment it
happened, and a layer on the far side of a boundary has no claim on it: an `f` typed into a debug overlay must
not toggle the game's fullscreen the instant the overlay closes, and a menu opening mid-frame must not act on a
key pressed before it existed. An overlay that consumes nothing moves no capture and drops nothing.

The accumulated quantities go with the edges, because a frame's text, wheel and mouse motion are edges measured
over an interval rather than states: a camera handed the motion made inside a menu jumps the frame the menu
closes. Held buttons, pointer positions, the modifier mask, fingers down and the pen all survive, because those
are states and the platform is still reporting them.

Popping a layer also stops a text-input session that layer started, so a menu takes its IME and its on-screen
keyboard with it.

### Focus loss

Everything held is released when the window loses focus: keys, mouse buttons, gamepad buttons, the modifier
mask, the fingers on the touch surface and the pen's pressure. The platform delivers no release for a key held
as focus goes, so without this a key reads as held until the player presses it again somewhere the application
can see. Each release is reported as an edge, so `keyReleased` and its relatives fire for it.

A device that is removed releases its held buttons on the same terms; see [`Gamepad`](#gamepad). A pen
carried out of range clears `penTouching` and `penPressure`, since nothing reports the lift.

### Keyboard

Keys are identified by **physical position**, so a movement binding stays where it is on every layout.

```teal
if app.input:keyDown("space") then ... end
```

| Method                             | What it answers                                     |
| ---------------------------------- | --------------------------------------------------- |
| `input:keyDown(key, layer?)`       | Whether a key is held                               |
| `input:keyPressed(key, layer?)`    | Whether it went down this frame, or this fixed step |
| `input:keyReleased(key, layer?)`   | Whether it came up, on the same tiers               |
| `input:scancode(name)`             | Resolves a key name to a scancode, cached           |
| `input:keyName(scancode)`          | The platform's name for a physical key              |
| `input:modifiers()`                | The modifier mask from the most recent key event    |
| `input:modifierDown(name, layer?)` | Whether a modifier is held                          |

`key` is a name or a scancode. Names are the platform's — `"Space"`, `"Left Shift"` — matched
case-insensitively, so `"space"` and `"left shift"` work too. A name nothing matches raises rather than silently
never firing.

`keyName` gives the name of the position, which is not the character the player's layout produces there: the key
`scancode("Q")` names is labeled Q whatever a French keyboard prints on it. That is what to show a player when
displaying a binding.

Modifier names are `"shift"`, `"ctrl"`, `"alt"`, `"gui"` and `"capsLock"`. Either side counts for the unsided
names, and `"leftShift"` asks for one. `modifiers()` is not gated by a layer and is only as fresh as the last key
event: a modifier state that changed while the window was not focused is not seen, which is why focus loss zeroes
it.

### Mouse

Positions and accumulated motion are plain fields, read directly:

| Field                        | What it is                                                          |
| ---------------------------- | ------------------------------------------------------------------- |
| `mouseX`, `mouseY`           | Position in window coordinates, from the top-left                   |
| `mouseDeltaX`, `mouseDeltaY` | Motion accumulated this frame                                       |
| `wheelX`, `wheelY`           | Wheel movement this frame, in the platform's notches                |
| `wheelTicksX`, `wheelTicksY` | The same movement accumulated to whole notches by the platform      |
| `mouseWhich`                 | Device that produced the most recent mouse event                    |
| `mouseSynthetic`             | Whether that event was the platform's translation of a touch or pen |

The position persists across frames that saw no motion; the deltas and the wheel are cleared each frame.

The wheel has **one sign whatever the machine is set to**: positive `wheelY` is a scroll away from the player,
positive `wheelX` a scroll to the right. A platform with natural scrolling on reports the opposite pair and says
so, and the conversion in `events` puts it back, so a binding written against these fields does not invert on
somebody else's desk. `wheelTicks*` is what a menu stepping one item per notch reads, rather than picking its own
threshold on the fractional pair.

`mouseSynthetic` is what a game handling touch itself reads, so it can ignore the duplicate rather than acting on
one gesture twice.

| Method                                | What it does                                                      |
| ------------------------------------- | ----------------------------------------------------------------- |
| `input:mouseDown(button, layer?)`     | Whether a button is held                                          |
| `input:mousePressed(button, layer?)`  | Whether it went down, on the three tiers                          |
| `input:mouseReleased(button, layer?)` | Whether it came up                                                |
| `input:setRelativeMouseMode(enabled)` | Hides the cursor and delivers motion as deltas only               |
| `input:relativeMouseMode()`           | Whether it is on, asked of the platform                           |
| `input:warpMouse(x, y)`               | Moves the cursor within the window                                |
| `input:captureMouse(enabled)`         | Keeps delivering events while a button is held outside the window |
| `input:showCursor(visible)`           | Shows or hides the cursor, for the application                    |
| `input:cursorVisible()`               | Whether it is being shown, asked of the platform                  |
| `input:setCursor(name?)`              | Selects and owns a standard system cursor                         |

Button names are `"left"`, `"middle"`, `"right"`, `"x1"` and `"x2"`, or a platform button number.

Under relative mouse mode `mouseX` and `mouseY` stop moving, since there is no cursor to report a position for,
and the delta pair carries the whole of what the mouse said.

`warpMouse` produces a motion event like any other, so the deltas pick the jump up. A game recentring the cursor
every frame reads its own warp as input unless it accounts for it.

The mode queries ask the platform rather than remembering, so a mode the window lost reports honestly. Without a
window — which is what a headless test gets — the commands report failure rather than raising.

`setCursor` accepts `"default"`, `"text"`, `"wait"`, `"crosshair"`, `"progress"`, `"pointer"`, `"move"`,
`"notAllowed"` and the compass resize names (`"nResize"`, `"neResize"`, `"ewResize"`, `"nwseResize"` and the
rest). Omitting the name restores the default. `Input` releases the prior cursor when it replaces it and releases
the final one on `destroy`, so callers never own a platform cursor handle.

### Touch and pen

`input:touches(layer?)` answers the fingers currently on the surface. The list and the records in it are reused
between calls, so anything retaining one has to copy it.

Each `Touch` carries `device` and `finger` as opaque identities, `x` and `y` in window coordinates, `normalX` and
`normalY` as the platform's own 0..1 across the window, and `pressure` on a surface that measures it. The
normalized pair is the one that survives a resize; the window pair is converted using the size `events` was last
told about, so it is stale by one frame if the window resized without that being updated.

The pen is a set of fields rather than a list, because one pen's state is kept and a second pen overwrites the
first: `penX`, `penY`, `penPressure`, `penTiltX`, `penTiltY`, `penRotation`, `penTouching`, `penEraser` and
`penWhich`. `penTouching` clears when the pen leaves proximity, since a pen carried away never reports lifting.
`penEraser` is read at the moment the pen went down, so it describes the current stroke.

Pressure, the two tilts and rotation are the axes folded here. A tablet may report more, hover distance and a
barrel slider among them, and those arrive on the raw `penAxis` event carrying the platform's own axis number;
see [`events`](/modules/events#pen).

### Text input

Off until asked for, because a platform that is composing text is one whose key events a game must not also read
as bindings, and because on a phone it puts a keyboard over half the screen.

```teal
local field = app.input:pushLayer("field")
app.input:startTextInput(field, { area = { x = 40, y = 200, width = 320, height = 24 } })
```

Binding the session to a layer is what makes stopping it reliable: popping the layer stops the session, so the
case nobody remembers to handle is handled. A session started without a layer runs until it is stopped by hand.

| Method                                | What it does                                       |
| ------------------------------------- | -------------------------------------------------- |
| `input:startTextInput(layer?, opts?)` | Starts a session, bound to a layer                 |
| `input:stopTextInput()`               | Stops it and clears whatever was being composed    |
| `input:textInputActive()`             | Whether a session this state started is running    |
| `input:textInputLayer()`              | The layer it belongs to, or nil                    |
| `input:setTextInputArea(area)`        | Tells the platform where the edited text sits      |
| `input:screenKeyboardSupported()`     | Whether the platform puts a keyboard on the screen |

What arrives comes back as fields: `text` is what committed this frame, empty when nothing was typed so it can be
appended without a nil check; `composition` is what an input method is composing and has not committed, with
`compositionStart` and `compositionLength` giving the caret and selection inside it. Draw a field as its own
content plus `composition`, so the player sees what they are typing before it commits.

Pass an area whenever there is one, and update it as the caret moves. The platform places its candidate window
and its own keyboard against the most recent rectangle it was given, and without one they land over what the
player is typing. `screenKeyboardSupported` is what a layout has to know: where it is true, starting text input
covers part of the window.

## Gamepad

A gamepad is not a set of globals the way a keyboard nearly is. It has identity, a lifetime shorter than the
process, metadata, capabilities that differ between devices, and outputs. Two pads sharing one button set is
not a simplification, it is a defect: pad A releasing a button releases pad B's. So each device owns its own
state and is reached through its own object.

A pad is never constructed by a game. `Input` opens one when the platform reports a device and hands it over
through `input:gamepads()` and `input:gamepad(index)`; `tecs.input.Gamepad` is the type those answer with, and
the page below is what one does.

A gamepad is not a set of globals the way a keyboard nearly is. It has identity, a lifetime shorter than the
process, metadata, capabilities that differ between devices, and outputs. Two pads sharing one button set is not
a simplification, it is a defect: pad A releasing a button would release pad B's. So each device owns its own
state and is reached through its own object.

A retained reference to a device that went away is safe by construction rather than by documented caution. The
platform handle lives in exactly one field, exactly one function reads it, and disconnection clears it before the
handle is closed. Every method takes its quiet branch from there: queries answer as if nothing is held, outputs
report failure, and nothing reaches a freed pointer. A pad is never revived either, so a reference held across a
reconnect stays disconnected and the reconnected device is a new object.

### Where a pad comes from

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

### What a pad says about itself

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

#### Device families

`kind` is one of `"standard"`, `"xbox360"`, `"xboxOne"`, `"ps3"`, `"ps4"`, `"ps5"`, `"switchPro"`,
`"joyconLeft"`, `"joyconRight"`, `"joyconPair"` and `"gamecube"`, or `"unknown"` when the platform does not
recognize the device.

### Button and axis names

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

### Layers and pads

Every query that reads folded state takes an optional `layer`, and answers as if nothing were held when that
layer cannot read. Omitting it means the base layer, which is the safe default: it goes quiet when anything is
pushed over it. The stack is shared across every device rather than being one of this pad's own, so a layer
blocks every device or none. The stack itself lives in [`Input`](/modules/input).

The questions about the device rather than about its state, `hasButton`, `hasAxis`, `hasSensor`,
`sensorEnabled`, `label` and `power`, take no layer and answer the same way whatever is on top.

### Buttons

#### buttonDown

Whether a button is held.

```teal
function Gamepad:buttonDown(button: string | integer, layer?: Layer): boolean
```

**Parameters:**

- `button`: a positional name or a platform code.
- `layer`: the layer to answer for. Omitted, the base layer.

**Returns:** whether the button is held right now, and `false` when the layer cannot read.

#### buttonPressed

Whether a button went down.

```teal
function Gamepad:buttonPressed(button: string | integer, layer?: Layer): boolean
```

Inside a fixed step this reads the latched set, so a press that began and ended between two steps is not lost.

**Returns:** whether the button went down, and `false` when the layer cannot read.

#### buttonReleased

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

### Axes

#### axis

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

### Capabilities and identity

#### hasButton

Whether the device carries a button at all, so a prompt can be omitted rather than shown for something the player
does not have.

```teal
function Gamepad:hasButton(button: string | integer): boolean
```

**Returns:** whether the device has it. A disconnected pad answers `false`, which is the same answer a prompt
wants.

#### hasAxis

Whether the device carries an axis, on the same terms as `hasButton`.

```teal
function Gamepad:hasAxis(axis: string | integer): boolean
```

Worth asking before binding: a pad with no right stick reads zero on it forever, which is indistinguishable from
one the player is not moving.

#### label

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

#### power

Power state name and charge percentage.

```teal
function Gamepad:power(): string, integer
```

**Returns:** the state name, then the charge in 0..100 or `-1`.

States are `"onBattery"`, `"charging"`, `"charged"`, `"noBattery"`, `"unknown"` and `"error"`. The percentage is
`-1` wherever the device declines to report one, which includes every state that is not about a battery. A pad
that has gone answers `"unknown", -1`.

### Sensors on a pad

A pad's gyro and accelerometer are off until asked for, and that is opt-in on purpose: an enabled sensor delivers
an event every few milliseconds, and a game that does not read one should not pay for the stream.

#### hasSensor

Whether the device carries a sensor.

```teal
function Gamepad:hasSensor(sensor: string | integer): boolean
```

#### enableSensor

Turns a sensor on or off.

```teal
function Gamepad:enableSensor(sensor: string | integer, enabled?: boolean): boolean
```

**Parameters:**

- `sensor`: a name or a platform code.
- `enabled`: whether to turn it on. Defaults to `true`.

**Returns:** whether the platform accepted the request. `false` for a pad that has gone.

#### sensorEnabled

Whether a sensor is currently delivering readings.

```teal
function Gamepad:sensorEnabled(sensor: string | integer): boolean
```

Asked of the device, so this reports what is actually streaming rather than what `enableSensor` was last asked
for: a request the device refused shows up here as `false`.

#### sensor

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

### Touchpads

#### TouchpadFinger

One finger on one of the device's touchpads, in 0..1 across the pad.

| Field      | Type      | Description                                                                                                                                                                                          |
| ---------- | --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `touchpad` | `integer` | Which touchpad, zero-based, below `touchpads`.                                                                                                                                                       |
| `finger`   | `integer` | The finger's slot on that touchpad, zero-based. A position on the device rather than an identity: unlike a touch-surface finger this is not a 64-bit id, so it fits a number and is compared as one. |
| `x`        | `number`  | Position across the pad from its left edge, in 0..1.                                                                                                                                                 |
| `y`        | `number`  | Position across the pad from its top edge, in 0..1.                                                                                                                                                  |
| `pressure` | `number`  | How hard, in 0..1, on a device that measures it. Devices that do not report a constant while the finger is down.                                                                                     |
| `down`     | `boolean` | Whether the finger is on the pad.                                                                                                                                                                    |

The type is reachable as `tecs.input.TouchpadFinger`.

#### touchpadFingers

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

### Outputs

Every output returns `false` rather than raising when the device is gone or has no such hardware, because rumble
and lights are garnish and a game should not have to guard them.

#### rumble

Rumbles both motors, at 0..1 each, for `seconds`.

```teal
function Gamepad:rumble(low: number, high: number, seconds: number): boolean
```

**Parameters:**

- `low`: the heavier, lower-frequency motor.
- `high`: the lighter, higher-frequency one.
- `seconds`: how long, rounded to milliseconds, which is the resolution the platform takes.

**Returns:** whether the platform accepted it.

A second call replaces the first rather than adding to it, so a long effect is canceled by a short one.

#### rumbleTriggers

Rumbles the triggers, on the devices that have motors in them.

```teal
function Gamepad:rumbleTriggers(left: number, right: number, seconds: number): boolean
```

Separate from `rumble` because the motors are separate hardware: a device with trigger motors has the body motors
too, and asking for one does nothing to the other. `false` on everything else.

#### setLED

Sets the device's light, in 0..1 per channel.

```teal
function Gamepad:setLED(red: number, green: number, blue: number): boolean
```

The bar or ring some pads carry, not the numbered player indicator, which `setPlayerIndex` drives. `false` on a
device with neither.

#### setPlayerIndex

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

## Standalone sensors

`tecs.input.sensors` lists the sensors the platform reports independently. Sensors built into a gamepad stay
methods and events on [`Gamepad`](#gamepad), where their controller identity belongs.

### sensors

```teal
function tecs.input.sensors(): {sensors.Device}, string
```

Returns the sensors attached now, in platform order, plus an error only when the sensor subsystem could not
start. Each device has:

| Field          | Type      | Meaning                                                                         |
| -------------- | --------- | ------------------------------------------------------------------------------- |
| `id`           | `number`  | Instance id, valid while attached                                               |
| `name`         | `string`  | Platform display name                                                           |
| `kind`         | `string`  | `accelerometer`, `gyroscope`, a left/right variant, or `unknown`                |
| `platformType` | `integer` | Platform-specific type number, for hardware the portable vocabulary cannot name |

### openSensor

```teal
function tecs.input.openSensor(id: number): sensors.Sensor, string
```

Opens a device from `devices`, returning `(sensor, nil)` or `(nil, error)`. A `Sensor` copies the same metadata
onto `id`, `name`, `kind`, and `platformType`.

### Sensor:read

```teal
function Sensor:read(count?: integer): {number}, string
```

Reads the newest values after updating SDL's sensor state. The default is three values, which is the natural
vector size for acceleration and angular velocity. A platform-specific sensor may request 1 through 16.

### Sensor:destroy

```teal
function Sensor:destroy()
```

Closes the native sensor and is safe to call more than once. Reading afterwards returns an error.
