---
url: /modules/input.md
description: >-
  Gameplay input in three tiers behind a layer stack, the gamepads attached to
  it, and the standalone sensors a device carries
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
[application](/modules/application) does, and hands it over as `app.input`.

SDL owns device mechanics; this owns gameplay semantics. That split is why there is no `tecs.keyboard` beside it
and no supported way to reach raw SDL: a query answered by polling the device would bypass replay, layers, edge
detection and latching, all of which live here.

The state is fed typed events and holds no globals, so a recorded session replays by feeding the same events
back. It never sees an `SDL_Event`: the conversion happens once, in [`tecs.events`](/modules/events), and
everything downstream shares that one vocabulary. Every outbound command goes through a backend for the same
reason, so a platform that is not SDL substitutes one object.

### Three tiers

They answer three different questions, and the third is not a variant of the second.

* **Live state** answers "is it held" — `keyDown`, `mouseDown`, `modifierDown`.
* **Frame events** answer "did it change this frame" — `keyPressed`, `keyReleased`, `mousePressed`,
  `mouseReleased`.
* **Latched events** answer that same question for fixed-step systems. A key pressed and released between two
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
`scancode("Q")` names is labelled Q whatever a French keyboard prints on it. That is what to show a player when
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
normalised pair is the one that survives a resize; the window pair is converted using the size `events` was last
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
recognise the device.

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

* `button`: a positional name or a platform code.
* `layer`: the layer to answer for. Omitted, the base layer.

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

* `axis`: a name or a platform code.
* `deadzone`: magnitude below which the axis reads as zero. Defaults to `0.15`, because stick drift is a property
  of the hardware rather than of any one game.
* `layer`: the layer to answer for. Omitted, the base layer.

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

* `sensor`: a name or a platform code.
* `enabled`: whether to turn it on. Defaults to `true`.

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

* `touchpad`: which touchpad, zero-based. Defaults to the first, which is the only one on every device that has
  any.
* `layer`: the layer to answer for. Omitted, the base layer.

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

* `low`: the heavier, lower-frequency motor.
* `high`: the lighter, higher-frequency one.
* `seconds`: how long, rounded to milliseconds, which is the resolution the platform takes.

**Returns:** whether the platform accepted it.

A second call replaces the first rather than adding to it, so a long effect is cancelled by a short one.

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

* `index`: the slot, zero-based, or `-1` for none.

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

## Reference

Every function and type this module carries, rendered from `src/tecs/platform/Input.tl`, `src/tecs/platform/Gamepad.tl` and `src/tecs/platform/sensors.tl`.

### tecs.input.Input.Layer

A position in the layer stack, from `pushLayer`.


### tecs.input.Input.Options

What `create` takes.


### tecs.input.Input.TextArea

Where edited text sits, for `setTextInputArea`.


### tecs.input.Input.TextOptions

What `startTextInput` takes besides a layer.


### tecs.input.Input.Touch

One finger on the touch surface, as `touches` reports it.


### tecs.input.Input.beginFrame

Clears per-frame state. Call once before polling events for a frame.

Drops the frame edges, the accumulated motion and wheel, and the committed
text. Held keys and buttons, the pointer positions and the latched edges
all survive: holding is not an edge, and a latched edge belongs to the
fixed step rather than to the frame.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| Input | self |             |

### tecs.input.Input.canRead

Whether `layer` may read input. Omitting a layer means the base layer.

#### Parameters

| Type                                                           | Name                     | Description |
| -------------------------------------------------------------- | ------------------------ | ----------- |
| Input                                       | self  |             |
| Layer | layer |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.captureMouse

Keeps delivering mouse events while a button is held outside the window,
which is what a drag that leaves the window needs.

Applies to the application rather than to a window, so this is the one
cursor command that works without one.

#### Parameters

| Type                       | Name                       | Description |
| -------------------------- | -------------------------- | ----------- |
| Input   | self    |             |
| boolean | enabled |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.composition

Text an input method is composing and has not committed. Empty when
nothing is being composed. A field is drawn as its own content plus
this, so the player sees what they are typing before it commits.


### tecs.input.Input.compositionLength

### tecs.input.Input.compositionStart

Caret offset and selection length within `composition`, in the units
the platform counts it in. Both zero when nothing is being composed.


### tecs.input.Input.cursorVisible

Whether the cursor is being shown, asked of the platform.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| Input | self |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.destroy

Closes every open device. Called when the application shuts down.

Stops a running text-input session too, since the platform would otherwise
be left composing for a window that is about to go away.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| Input | self |             |

### tecs.input.Input.enterFixedPhase

Switches queries to the latched sets for the duration of a fixed step.

Every device answers from the latched sets while this is on, since the gate
is shared. Nested steps are not tracked: the flag is set, not counted.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| Input | self |             |

### tecs.input.Input.exitFixedPhase

Ends the fixed phase and clears what it consumed.

Brackets one step, not one frame. The latched edges are cleared here, so a
press is delivered to the first step that runs after it and to that one
only, whether the frame ran one step or four.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| Input | self |             |

### tecs.input.Input.gamepad

The nth connected gamepad, or nil.

Position in the list, not a player slot: a pad's index moves when one
before it disconnects. Match on `guid` or hold the object to follow a
particular device.

#### Parameters

| Type                       | Name                     | Description |
| -------------------------- | ------------------------ | ----------- |
| Input   | self  |             |
| integer | index |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| Gamepad |             |

### tecs.input.Input.gamepadById

A gamepad by platform instance id, or nil when it is not connected.

Ids are not reused while a device is attached and say nothing once it is
gone, so this is for routing an event that carries one rather than for
remembering a pad across a reconnect.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| Input  | self |             |
| number | id   |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| Gamepad |             |

### tecs.input.Input.gamepads

Every connected gamepad, in the order the platform reported them.

The list is the live one, so a pad that disconnects leaves it. A reference
taken out of it stays valid and answers as disconnected.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| Input | self |             |

#### Returns

| Type                         | Description |
| ---------------------------- | ----------- |
| {Gamepad} |             |

### tecs.input.Input.handleEvent

Folds one typed event into the state.

Unrecognised kinds are ignored, so this can be handed the whole stream.

Nothing is retained: every field the state keeps is copied out here, so the
caller is free to reuse the record, which the converter does.

#### Parameters

| Type                                 | Name                     | Description |
| ------------------------------------ | ------------------------ | ----------- |
| Input             | self  |             |
| eventStream.Event | event |             |

### tecs.input.Input.keyDown

Whether a key is held. Keys are identified by physical position, so a
movement binding stays where it is on every layout.

#### Parameters

| Type                                                           | Name                     | Description |
| -------------------------------------------------------------- | ------------------------ | ----------- |
| Input                                       | self  |             |
| string | integer                           | key   |             |
| Layer | layer |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.keyName

The name of a physical key, for showing a binding back to the player.

The platform's own name for the position, which is not the character the
player's layout produces there: the key `scancode("Q")` names is labelled Q
whatever a French keyboard prints on it.

#### Parameters

| Type                       | Name                        | Description |
| -------------------------- | --------------------------- | ----------- |
| Input   | self     |             |
| integer | scancode |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| string |             |

### tecs.input.Input.keyPressed

Whether a key went down. Reads the latched set inside a fixed step.

#### Parameters

| Type                                                           | Name                     | Description |
| -------------------------------------------------------------- | ------------------------ | ----------- |
| Input                                       | self  |             |
| string | integer                           | key   |             |
| Layer | layer |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.keyReleased

Whether a key came up, on the same tiers as `keyPressed`.

#### Parameters

| Type                                                           | Name                     | Description |
| -------------------------------------------------------------- | ------------------------ | ----------- |
| Input                                       | self  |             |
| string | integer                           | key   |             |
| Layer | layer |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.modifierDown

Whether a modifier is held: "shift", "ctrl", "alt", "gui", "capsLock".

Either side counts for the unsided names, and "leftShift" asks for one.

#### Parameters

| Type                                                           | Name                     | Description |
| -------------------------------------------------------------- | ------------------------ | ----------- |
| Input                                       | self  |             |
| string                                      | name  |             |
| Layer | layer |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.modifiers

The modifier mask reported with the most recent key event.

Not gated by a layer, and only as fresh as the last key event: a modifier
pressed on its own does produce one, but a modifier state that changed
while the window was not focused is not seen. Focus loss zeroes it for that
reason. `modifierDown` is the gated form and reads the same mask.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| Input | self |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| integer |             |

### tecs.input.Input.mouseDeltaX

Mouse motion accumulated this frame, summed over every motion event and
cleared by `beginFrame`. Under relative mouse mode this is the whole of
what the mouse said, since the position stops moving.


### tecs.input.Input.mouseDeltaY

### tecs.input.Input.mouseDown

Whether a mouse button is held. Names are "left", "middle", "right", "x1",
"x2".

#### Parameters

| Type                                                           | Name                      | Description |
| -------------------------------------------------------------- | ------------------------- | ----------- |
| Input                                       | self   |             |
| string | integer                           | button |             |
| Layer | layer  |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.mousePressed

Whether a mouse button went down. Reads the latched set inside a fixed
step, on the same tiers as `keyPressed`.

#### Parameters

| Type                                                           | Name                      | Description |
| -------------------------------------------------------------- | ------------------------- | ----------- |
| Input                                       | self   |             |
| string | integer                           | button |             |
| Layer | layer  |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.mouseReleased

Whether a mouse button came up, on the same tiers as `mousePressed`.

#### Parameters

| Type                                                           | Name                      | Description |
| -------------------------------------------------------------- | ------------------------- | ----------- |
| Input                                       | self   |             |
| string | integer                           | button |             |
| Layer | layer  |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.mouseSynthetic

Whether that event was the platform's own translation of a touch or a
pen. A game that handles touch itself reads this and ignores the
duplicate rather than acting on one gesture twice.


### tecs.input.Input.mouseWhich

Device that produced the most recent mouse button, motion or wheel
event.


### tecs.input.Input.mouseX

Mouse position in window coordinates, from the top-left. The last
position reported, so it persists across frames that saw no motion.


### tecs.input.Input.mouseY

### tecs.input.Input.newInput

Creates an input state with a single base layer.

Holds no devices yet. `refreshDevices` opens the pads that are already
attached, and everything after that arrives as events.

#### Parameters

| Type                            | Name                       | Description |
| ------------------------------- | -------------------------- | ----------- |
| InputOptions | options |             |

#### Returns

| Type                     | Description |
| ------------------------ | ----------- |
| Input |             |

### tecs.input.Input.penEraser

Whether the end in use is the eraser. Read at the moment the pen went
down, so it describes the current stroke.


### tecs.input.Input.penPressure

How hard the pen is pressed, in 0..1. Zero until the pen reports it,
and on a pen that measures no pressure it stays there.


### tecs.input.Input.penRotation

Barrel rotation in degrees clockwise, for a pen with a chisel nib. Zero
on a pen that does not report it.


### tecs.input.Input.penTiltX

How far the pen leans from upright, in degrees, negative towards the
left and towards the top of the surface. Both zero on a pen that does
not report tilt.


### tecs.input.Input.penTiltY

### tecs.input.Input.penTouching

Whether the pen is touching the surface. Cleared when the pen leaves
proximity, since a pen carried away never reports lifting.


### tecs.input.Input.penWhich

Pen the state describes, or nil when no pen has been seen. One pen's
state is kept, not one per device: a second pen overwrites the first.


### tecs.input.Input.penX

Pen position in window coordinates, from the top-left.


### tecs.input.Input.penY

### tecs.input.Input.popLayer

Removes the topmost layer. The base layer is never removed.

A text-input session started by that layer stops with it, because a menu
that closed and left the on-screen keyboard up is a bug the game would have
to remember to avoid. The pending edges go the same way when the layer was
blocking, so what was typed into it stays in it.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| Input | self |             |

#### Returns

| Type                                                           | Description |
| -------------------------------------------------------------- | ----------- |
| Layer |             |

### tecs.input.Input.pushLayer

Pushes a layer and returns it.

A blocking layer hides input from everything beneath. Pass
`blocking = false` for an overlay that observes without consuming.

A layer that blocks moves capture, so the pending edges are dropped: what
was pressed before the layer existed is not the layer's to act on. An
overlay that consumes nothing moves no capture and drops nothing.

#### Parameters

| Type                       | Name                        | Description |
| -------------------------- | --------------------------- | ----------- |
| Input   | self     |             |
| string  | name     |             |
| boolean | blocking |             |

#### Returns

| Type                                                           | Description |
| -------------------------------------------------------------- | ----------- |
| Layer |             |

### tecs.input.Input.refreshDevices

Opens every gamepad already attached.

Run before a game's own load, so a pad that was plugged in when the process
started is there when the game asks. Safe to call again: a device already
open is left alone, and one that went away without an event is closed.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| Input | self |             |

### tecs.input.Input.relativeMouseMode

Whether relative mouse mode is on, asked of the platform rather than
remembered, so a mode the window lost reports honestly.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| Input | self |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.scancode

Resolves a key name to a scancode, caching the lookup.

Names are the platform's ("Space", "Left Shift"), matched case-insensitively
so "space" and "left shift" work too.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| Input  | self |             |
| string | name |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| integer |             |

### tecs.input.Input.screenKeyboardSupported

Whether the platform puts a keyboard on the screen for text input.

What a layout has to know: where this is true, starting text input covers
part of the window, and the area given to `startTextInput` is what keeps
the field out from under it.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| Input | self |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.setCursor

Selects one of the platform's standard cursor shapes.

Pass nil or `"default"` to restore the platform default. The other names
are `"text"`, `"wait"`, `"crosshair"`, `"progress"`, `"pointer"`,
`"move"`, `"notAllowed"` and the eight compass resize cursors such as
`"ewResize"` and `"nwseResize"`.

The cursor is owned by this input state and released when it is replaced or
when `destroy` runs.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| Input  | self |             |
| string | name |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.setRelativeMouseMode

Hides the cursor and delivers motion as deltas only, for a game that turns
the view with the mouse.

`mouseX` and `mouseY` stop moving while this is on, since there is no
cursor to report a position for; `mouseDeltaX` and `mouseDeltaY` carry the
whole of what the mouse said. False without a window, which is what a
headless test gets.

#### Parameters

| Type                       | Name                       | Description                                                                |
| -------------------------- | -------------------------- | -------------------------------------------------------------------------- |
| Input   | self    |                                                                            |
| boolean | enabled | Anything but false turns it on, so calling with nothing on is enabling it. |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.setTextInputArea

Tells the platform where the edited text sits, in window coordinates.

Worth calling as the caret moves, not only at the start: the platform
places its candidate window against the most recent rectangle it was given.

#### Parameters

| Type                                                                 | Name                    | Description |
| -------------------------------------------------------------------- | ----------------------- | ----------- |
| Input                                             | self |             |
| TextArea | area |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.showCursor

Shows or hides the cursor, for the application rather than one window.

Independent of relative mouse mode, which hides the cursor for the duration
on its own: leaving this alone is the usual thing.

#### Parameters

| Type                       | Name                       | Description |
| -------------------------- | -------------------------- | ----------- |
| Input   | self    |             |
| boolean | visible |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.startTextInput

Starts text input, bound to a layer.

Off until asked for, because a platform that is composing text is one whose
key events a game must not also read as bindings, and because on a phone it
puts a keyboard over half the screen. Binding the session to a layer is
what makes stopping it reliable: popping the layer stops the session, so
the case nobody remembers to handle is handled.

Pass an area whenever there is one. The platform places its candidate
window and its own keyboard clear of the rectangle, and without one they
land over what the player is typing.

#### Parameters

| Type                                                                       | Name                       | Description |
| -------------------------------------------------------------------------- | -------------------------- | ----------- |
| Input                                                   | self    |             |
| Layer             | layer   |             |
| TextOptions | options |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.stopTextInput

Stops text input and clears whatever was being composed.

Declared here because the layer stack and the shutdown path both stop a
session, and both read better above where text input is defined.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| Input | self |             |

#### Returns

| Type                       | Description                                                                                                                                           |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| boolean | False when no session was running, in which case the composition state is cleared anyway, so this is safe to call unconditionally on a teardown path. |

### tecs.input.Input.text

Text committed this frame, from the text input events. Empty when
nothing was typed, so it can be appended without a nil check.


### tecs.input.Input.textInputActive

Whether a text-input session is running.

What this state started, not what the platform is doing: a session started
outside the engine is not visible here.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| Input | self |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Input.textInputLayer

The layer the running session belongs to, or nil.

Nil both when no session is running and when one was started without naming
a layer, which is a session nothing will stop on its own.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| Input | self |             |

#### Returns

| Type                                                           | Description |
| -------------------------------------------------------------- | ----------- |
| Layer |             |

### tecs.input.Input.topLayer

The layer currently on top.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| Input | self |             |

#### Returns

| Type                                                           | Description |
| -------------------------------------------------------------- | ----------- |
| Layer |             |

### tecs.input.Input.touches

Fingers currently on the touch surface.

The list and the records in it are reused between calls, so anything
retaining one has to copy it.

#### Parameters

| Type                                                           | Name                     | Description |
| -------------------------------------------------------------- | ------------------------ | ----------- |
| Input                                       | self  |             |
| Layer | layer |             |

#### Returns

| Type                                                             | Description |
| ---------------------------------------------------------------- | ----------- |
| {Touch} |             |

### tecs.input.Input.warpMouse

Moves the cursor within the window, in window coordinates.

Produces a motion event like any other, so `mouseDeltaX` and `mouseDeltaY`
pick the jump up. A game recentring the cursor every frame reads its own
warp as input unless it accounts for it.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| Input  | self |             |
| number | x    |             |
| number | y    |             |

### tecs.input.Input.wheelTicksX

The same movement accumulated to whole notches by the platform, on the
same sign convention and cleared by `beginFrame` alongside the pair
above. What a menu stepping one item per notch reads, rather than
picking its own threshold on the fractional pair.


### tecs.input.Input.wheelTicksY

### tecs.input.Input.wheelX

Wheel movement accumulated this frame, in the platform's own notches
rather than pixels. Cleared by `beginFrame`.

One sign whatever the machine is set to: positive `wheelY` is a scroll
away from the player, positive `wheelX` a scroll to the right. A
platform with natural scrolling on reports the opposite pair and says
so, and the conversion in `events` puts it back, so a binding written
against these fields does not invert on somebody else's desk.


### tecs.input.Input.wheelY

### tecs.input.Gamepad.TouchpadFinger

### tecs.input.Gamepad.axis

An axis in -1..1, or a trigger in 0..1, or zero if the layer cannot read.

Names are "leftX", "rightY", "leftTrigger" and so on. Sticks report Y
growing downward, matching the screen rather than a maths convention.

Values inside the deadzone read as zero and values outside it are not
rescaled, so a stick leaving the deadzone steps from zero to the deadzone
magnitude. A game that wants a continuous ramp rescales what it gets.

#### Parameters

| Type                                 | Name                        | Description                                                                                                                                                           |
| ------------------------------------ | --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Gamepad           | self     |                                                                                                                                                                       |
| string | integer | axis     |                                                                                                                                                                       |
| number            | deadzone | Magnitude below which the axis reads as zero. Defaults to a value that suits the hardware, since stick drift is a property of the device rather than of any one game. |
| Layer             | layer    |                                                                                                                                                                       |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| number |             |

### tecs.input.Gamepad.buttonDown

Whether a button is held. Names are positional: "south", "leftShoulder",
"dpadUp".

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| Gamepad           | self   |             |
| string | integer | button |             |
| Layer             | layer  |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Gamepad.buttonPressed

Whether a button went down. Reads the latched set inside a fixed step, so
a press that began and ended between two steps is not lost.

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| Gamepad           | self   |             |
| string | integer | button |             |
| Layer             | layer  |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Gamepad.buttonReleased

Whether a button came up, on the same tiers as `buttonPressed`.

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| Gamepad           | self   |             |
| string | integer | button |             |
| Layer             | layer  |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Gamepad.connected

Whether the device is still attached. False for good once it is: a pad
is never revived, so this only ever goes one way.


### tecs.input.Gamepad.enableSensor

Turns a sensor on or off.

Off by default and opt-in on purpose: an enabled sensor delivers an event
every few milliseconds, and a game that does not read one should not pay
for the stream.

#### Parameters

| Type                                 | Name                       | Description |
| ------------------------------------ | -------------------------- | ----------- |
| Gamepad           | self    |             |
| string | integer | sensor  |             |
| boolean           | enabled |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Gamepad.guid

Stable hardware identity, for matching saved bindings.


### tecs.input.Gamepad.hasAxis

Whether the device carries an axis, on the same terms as `hasButton`.

Worth asking before binding: a pad with no right stick reads zero on it
forever, which is indistinguishable from one the player is not moving.

#### Parameters

| Type                                 | Name                    | Description |
| ------------------------------------ | ----------------------- | ----------- |
| Gamepad           | self |             |
| string | integer | axis |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Gamepad.hasButton

Whether the device carries a button at all, so a prompt can be omitted
rather than shown for something the player does not have.

Asked of the device rather than of the layer stack, so this answers the
same way whatever is on top. A disconnected pad answers false, which is the
same answer a prompt wants.

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| Gamepad           | self   |             |
| string | integer | button |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Gamepad.hasSensor

Whether the device carries a sensor: "gyro" or "accelerometer".

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| Gamepad           | self   |             |
| string | integer | sensor |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Gamepad.id

Platform instance id. Unique among attached devices, and not reused by
this object once the device is gone.


### tecs.input.Gamepad.kind

Device family: "xboxOne", "ps5", "switchPro", "standard", "unknown".


### tecs.input.Gamepad.label

What is printed on a button, for a prompt: "a", "cross", "square".

Cached, because a prompt asks every frame it is on screen and the answer
only changes when the device is remapped, which drops the cache.

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| Gamepad           | self   |             |
| string | integer | button |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| string |             |

### tecs.input.Gamepad.name

What the platform calls the device, for showing the player which pad is
which. Not stable across platforms or drivers; `guid` is what matches.


### tecs.input.Gamepad.openGamepad

Opens a device and reads what it says about itself.

Returns nil when the platform will not open it, which happens for a device
unplugged between enumeration and here.

#### Parameters

| Type                       | Name                       | Description                                                                            |
| -------------------------- | -------------------------- | -------------------------------------------------------------------------------------- |
| Backend | backend |                                                                                        |
| Gate    | gate    | The shared layer stack, which every query on this pad is answered against.             |
| number  | id      | The platform's instance id, from `Backend.attachedGamepads` or a `gamepadAdded` event. |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| Gamepad |             |

### tecs.input.Gamepad.path

Where the platform says the device is attached. Empty when it declines
to say.


### tecs.input.Gamepad.playerIndex

Player slot the platform assigned, or -1 for none.


### tecs.input.Gamepad.power

Power state name and charge percentage.

States are "onBattery", "charging", "charged", "noBattery", "unknown" and
"error". The percentage is -1 wherever the device declines to report one,
which includes every state that is not about a battery.

#### Parameters

| Type                       | Name                    | Description |
| -------------------------- | ----------------------- | ----------- |
| Gamepad | self |             |

#### Returns

| Type                       | Description                                      |
| -------------------------- | ------------------------------------------------ |
| string  | The state name, then the charge in 0..100 or -1. |
| integer |                                                  |

### tecs.input.Gamepad.rumble

Rumbles both motors, at 0..1 each, for `seconds`.

Returns false rather than raising when the device is gone or has no motor,
because rumble is a garnish and a game should not have to guard it.

A second call replaces the first rather than adding to it, so a long effect
is cancelled by a short one. Seconds are rounded to milliseconds, which is
the resolution the platform takes.

#### Parameters

| Type                       | Name                       | Description                         |
| -------------------------- | -------------------------- | ----------------------------------- |
| Gamepad | self    |                                     |
| number  | low     | The heavier, lower-frequency motor. |
| number  | high    | The lighter, higher-frequency one.  |
| number  | seconds |                                     |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Gamepad.rumbleTriggers

Rumbles the triggers, on the devices that have motors in them.

Separate from `rumble` because the motors are separate hardware: a device
with trigger motors has the body motors too, and asking for one does
nothing to the other. False on everything else.

#### Parameters

| Type                       | Name                       | Description |
| -------------------------- | -------------------------- | ----------- |
| Gamepad | self    |             |
| number  | left    |             |
| number  | right   |             |
| number  | seconds |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Gamepad.sensor

The most recent reading from a sensor, as three components.

Folded from the event stream rather than polled, so a replay reproduces it
and a blocked layer cannot read it.

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| Gamepad           | self   |             |
| string | integer | sensor |             |
| Layer             | layer  |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| number |             |
| number |             |
| number |             |

### tecs.input.Gamepad.sensorEnabled

Whether a sensor is currently delivering readings.

Asked of the device, so this reports what is actually streaming rather than
what `enableSensor` was last asked for: a request the device refused shows
up here as false.

#### Parameters

| Type                                 | Name                      | Description |
| ------------------------------------ | ------------------------- | ----------- |
| Gamepad           | self   |             |
| string | integer | sensor |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Gamepad.setLED

Sets the device's light, in 0..1 per channel.

The bar or ring some pads carry, not the numbered player indicator, which
`setPlayerIndex` drives. False on a device with neither.

#### Parameters

| Type                       | Name                     | Description |
| -------------------------- | ------------------------ | ----------- |
| Gamepad | self  |             |
| number  | red   |             |
| number  | green |             |
| number  | blue  |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Gamepad.setPlayerIndex

Assigns the player slot, which is what lights the numbered indicator.

`playerIndex` is updated only if the platform accepted the change, so the
field describes the device rather than the last request. Nothing here
prevents two pads holding the same slot; that is the caller's to arrange.

#### Parameters

| Type                       | Name                     | Description                           |
| -------------------------- | ------------------------ | ------------------------------------- |
| Gamepad | self  |                                       |
| integer | index | The slot, zero-based, or -1 for none. |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| boolean |             |

### tecs.input.Gamepad.touchpadFingers

Fingers currently on a touchpad, in 0..1 across it.

The records are reused between calls, so anything retaining one has to copy
it. The list is not: a fresh one is built per call, which makes this a poor
thing to ask every frame from a hot path.

#### Parameters

| Type                       | Name                        | Description                                                                                            |
| -------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------ |
| Gamepad | self     |                                                                                                        |
| integer | touchpad | Which touchpad, zero-based. Defaults to the first, which is the only one on every device that has any. |
| Layer   | layer    |                                                                                                        |

#### Returns

| Type                                                                                 | Description |
| ------------------------------------------------------------------------------------ | ----------- |
| {TouchpadFinger} |             |

### tecs.input.Gamepad.touchpads

Touchpads the device carries. Zero on most.

### tecs.input.Device

One sensor the platform reports, before it is opened.


### tecs.input.Sensor

An opened sensor.


### tecs.input.openSensor

Opens an attached sensor by instance id.

#### Parameters

| Type                      | Name                  | Description                                                                                                                                                      |
| ------------------------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| number | id | An instance id from `sensors`. Ids name a device while it stays attached rather than a slot, so one kept across an unplug does not come back to the same sensor. |

#### Returns

| Type                                                       | Description                                                                                                                                                                                                                                 |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Sensor | The open sensor, whose `name` and `kind` are read from the device itself rather than copied from the listing. Nil on failure, with the reason beside it, and nothing is left open in that case. Closing is the caller's, through `destroy`. |
| string                                  | The reason, when the first return is nil.                                                                                                                                                                                                   |

### tecs.input.sensors

Sensors attached now, in platform order.

A snapshot, not a subscription: a sensor unplugged after this leaves an id
that `openSensor` refuses.

#### Returns

| Type                                                         | Description                                                                                                                                                                                                                                                          |
| ------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| {Device} | The devices, listed afresh each call and the caller's to keep. Empty rather than nil when the sensor subsystem cannot start, so a caller that only iterates needs no nil check. Most desktop machines genuinely have none, which is an empty list and not a failure. |
| string                                    | SDL's reason, when something went wrong.                                                                                                                                                                                                                             |
