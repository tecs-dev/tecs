---
description: "Gameplay input in three tiers, behind a layer stack: live state, frame events, and latched events"
outline: [2, 3]
---

# tecs.input.Input

`tecs.input.Input` is gameplay input, in three tiers, behind a layer stack. A game does not construct one: the
[application](/modules/application) does, and hands it over as `app.input`.

SDL owns device mechanics; this owns gameplay semantics. That split is why there is no `tecs.keyboard` beside it
and no supported way to reach raw SDL: a query answered by polling the device would bypass replay, layers, edge
detection and latching, all of which live here.

The state is fed typed events and holds no globals, so a recorded session replays by feeding the same events
back. It never sees an `SDL_Event`: the conversion happens once, in [`tecs.events`](/modules/events), and
everything downstream shares that one vocabulary. Every outbound command goes through a backend for the same
reason, so a platform that is not SDL substitutes one object.

## Three tiers

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

## Layers

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

## Focus loss

Everything held is released when the window loses focus: keys, mouse buttons, gamepad buttons, the modifier
mask, the fingers on the touch surface and the pen's pressure. The platform delivers no release for a key held
as focus goes, so without this a key reads as held until the player presses it again somewhere the application
can see. Each release is reported as an edge, so `keyReleased` and its relatives fire for it.

A device that is removed releases its held buttons on the same terms; see [`Gamepad`](/modules/gamepad). A pen
carried out of range clears `penTouching` and `penPressure`, since nothing reports the lift.

## Keyboard

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

## Mouse

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

## Touch and pen

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

## Text input

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

## Gamepads are not part of it

A gamepad has identity, a lifetime, metadata and outputs, so it is not a field on the input state. It is reached
through the registry and answers for itself.

| Method                   | What it answers                          |
| ------------------------ | ---------------------------------------- |
| `input:gamepads()`       | Every open pad, in connection order      |
| `input:gamepad(index)`   | The pad at that position                 |
| `input:gamepadById(id)`  | The pad with that platform instance id   |
| `input:refreshDevices()` | Opens the pads that are already attached |

`refreshDevices` runs before the game's plugin, because the platform reports an addition rather than a device
that was there all along, and waiting for an event would leave every already-plugged-in pad invisible. See
[`tecs.gamepad.Gamepad`](/modules/gamepad).

What `Input` holds is what the machine has one of: a keyboard, an aggregate mouse, the touch surface, the pen,
and the registry the pads live in.
<!-- @generated by docs/scripts/reference.py from src/tecs/platform/Input.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/platform/Input.tl`.

<a id="tecs.input.Input.Layer"></a>

### tecs.input.Input.Layer

<pre><code v-pre><a href="#tecs.input.Input.Layer">tecs.input.Input.Layer</a>: Layer
</code></pre>

A position in the layer stack, from `pushLayer`.
<a id="tecs.input.Input.Options"></a>

### tecs.input.Input.Options

<pre><code v-pre><a href="#tecs.input.Input.Options">tecs.input.Input.Options</a>: InputOptions
</code></pre>

What `create` takes.
<a id="tecs.input.Input.TextArea"></a>

### tecs.input.Input.TextArea

<pre><code v-pre><a href="#tecs.input.Input.TextArea">tecs.input.Input.TextArea</a>: TextArea
</code></pre>

Where edited text sits, for `setTextInputArea`.
<a id="tecs.input.Input.TextOptions"></a>

### tecs.input.Input.TextOptions

<pre><code v-pre><a href="#tecs.input.Input.TextOptions">tecs.input.Input.TextOptions</a>: TextOptions
</code></pre>

What `startTextInput` takes besides a layer.
<a id="tecs.input.Input.Touch"></a>

### tecs.input.Input.Touch

<pre><code v-pre><a href="#tecs.input.Input.Touch">tecs.input.Input.Touch</a>: Touch
</code></pre>

One finger on the touch surface, as `touches` reports it.
<a id="tecs.input.Input.beginFrame"></a>

### tecs.input.Input.beginFrame

<pre><code v-pre>function <a href="#tecs.input.Input.beginFrame">tecs.input.Input.beginFrame</a>(self: Input)
</code></pre>

Clears per-frame state. Call once before polling events for a frame.

Drops the frame edges, the accumulated motion and wheel, and the committed
text. Held keys and buttons, the pointer positions and the latched edges
all survive: holding is not an edge, and a latched edge belongs to the
fixed step rather than to the frame.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| <code v-pre>Input</code> | <code v-pre>self</code> |             |

<a id="tecs.input.Input.canRead"></a>

### tecs.input.Input.canRead

<pre><code v-pre>function <a href="#tecs.input.Input.canRead">tecs.input.Input.canRead</a>(self: Input, layer: <a href="#tecs.input.Input.Layer">Layer</a>): boolean
</code></pre>

Whether `layer` may read input. Omitting a layer means the base layer.

#### Parameters

| Type                                                           | Name                     | Description |
| -------------------------------------------------------------- | ------------------------ | ----------- |
| <code v-pre>Input</code>                                       | <code v-pre>self</code>  |             |
| <code v-pre><a href="#tecs.input.Input.Layer">Layer</a></code> | <code v-pre>layer</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.captureMouse"></a>

### tecs.input.Input.captureMouse

<pre><code v-pre>function <a href="#tecs.input.Input.captureMouse">tecs.input.Input.captureMouse</a>(self: Input, enabled: boolean): boolean
</code></pre>

Keeps delivering mouse events while a button is held outside the window,
which is what a drag that leaves the window needs.

Applies to the application rather than to a window, so this is the one
cursor command that works without one.

#### Parameters

| Type                       | Name                       | Description |
| -------------------------- | -------------------------- | ----------- |
| <code v-pre>Input</code>   | <code v-pre>self</code>    |             |
| <code v-pre>boolean</code> | <code v-pre>enabled</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.composition"></a>

### tecs.input.Input.composition

<pre><code v-pre><a href="#tecs.input.Input.composition">tecs.input.Input.composition</a>: string
</code></pre>

Text an input method is composing and has not committed. Empty when
nothing is being composed. A field is drawn as its own content plus
this, so the player sees what they are typing before it commits.
<a id="tecs.input.Input.compositionLength"></a>

### tecs.input.Input.compositionLength

<pre><code v-pre><a href="#tecs.input.Input.compositionLength">tecs.input.Input.compositionLength</a>: integer
</code></pre>

<a id="tecs.input.Input.compositionStart"></a>

### tecs.input.Input.compositionStart

<pre><code v-pre><a href="#tecs.input.Input.compositionStart">tecs.input.Input.compositionStart</a>: integer
</code></pre>

Caret offset and selection length within `composition`, in the units
the platform counts it in. Both zero when nothing is being composed.
<a id="tecs.input.Input.create"></a>

### tecs.input.Input.create

<pre><code v-pre>function <a href="#tecs.input.Input.create">tecs.input.Input.create</a>(options: InputOptions): Input
</code></pre>

Creates an input state with a single base layer.

Holds no devices yet. `refreshDevices` opens the pads that are already
attached, and everything after that arrives as events.

#### Parameters

| Type                            | Name                       | Description |
| ------------------------------- | -------------------------- | ----------- |
| <code v-pre>InputOptions</code> | <code v-pre>options</code> |             |

#### Returns

| Type                     | Description |
| ------------------------ | ----------- |
| <code v-pre>Input</code> |             |

<a id="tecs.input.Input.cursorVisible"></a>

### tecs.input.Input.cursorVisible

<pre><code v-pre>function <a href="#tecs.input.Input.cursorVisible">tecs.input.Input.cursorVisible</a>(self: Input): boolean
</code></pre>

Whether the cursor is being shown, asked of the platform.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| <code v-pre>Input</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.destroy"></a>

### tecs.input.Input.destroy

<pre><code v-pre>function <a href="#tecs.input.Input.destroy">tecs.input.Input.destroy</a>(self: Input)
</code></pre>

Closes every open device. Called when the application shuts down.

Stops a running text-input session too, since the platform would otherwise
be left composing for a window that is about to go away.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| <code v-pre>Input</code> | <code v-pre>self</code> |             |

<a id="tecs.input.Input.enterFixedPhase"></a>

### tecs.input.Input.enterFixedPhase

<pre><code v-pre>function <a href="#tecs.input.Input.enterFixedPhase">tecs.input.Input.enterFixedPhase</a>(self: Input)
</code></pre>

Switches queries to the latched sets for the duration of a fixed step.

Every device answers from the latched sets while this is on, since the gate
is shared. Nested steps are not tracked: the flag is set, not counted.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| <code v-pre>Input</code> | <code v-pre>self</code> |             |

<a id="tecs.input.Input.exitFixedPhase"></a>

### tecs.input.Input.exitFixedPhase

<pre><code v-pre>function <a href="#tecs.input.Input.exitFixedPhase">tecs.input.Input.exitFixedPhase</a>(self: Input)
</code></pre>

Ends the fixed phase and clears what it consumed.

Brackets one step, not one frame. The latched edges are cleared here, so a
press is delivered to the first step that runs after it and to that one
only, whether the frame ran one step or four.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| <code v-pre>Input</code> | <code v-pre>self</code> |             |

<a id="tecs.input.Input.gamepad"></a>

### tecs.input.Input.gamepad

<pre><code v-pre>function <a href="#tecs.input.Input.gamepad">tecs.input.Input.gamepad</a>(self: Input, index: integer): Gamepad
</code></pre>

The nth connected gamepad, or nil.

Position in the list, not a player slot: a pad's index moves when one
before it disconnects. Match on `guid` or hold the object to follow a
particular device.

#### Parameters

| Type                       | Name                     | Description |
| -------------------------- | ------------------------ | ----------- |
| <code v-pre>Input</code>   | <code v-pre>self</code>  |             |
| <code v-pre>integer</code> | <code v-pre>index</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>Gamepad</code> |             |

<a id="tecs.input.Input.gamepadById"></a>

### tecs.input.Input.gamepadById

<pre><code v-pre>function <a href="#tecs.input.Input.gamepadById">tecs.input.Input.gamepadById</a>(self: Input, id: number): Gamepad
</code></pre>

A gamepad by platform instance id, or nil when it is not connected.

Ids are not reused while a device is attached and say nothing once it is
gone, so this is for routing an event that carries one rather than for
remembering a pad across a reconnect.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Input</code>  | <code v-pre>self</code> |             |
| <code v-pre>number</code> | <code v-pre>id</code>   |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>Gamepad</code> |             |

<a id="tecs.input.Input.gamepads"></a>

### tecs.input.Input.gamepads

<pre><code v-pre>function <a href="#tecs.input.Input.gamepads">tecs.input.Input.gamepads</a>(self: Input): {Gamepad}
</code></pre>

Every connected gamepad, in the order the platform reported them.

The list is the live one, so a pad that disconnects leaves it. A reference
taken out of it stays valid and answers as disconnected.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| <code v-pre>Input</code> | <code v-pre>self</code> |             |

#### Returns

| Type                         | Description |
| ---------------------------- | ----------- |
| <code v-pre>{Gamepad}</code> |             |

<a id="tecs.input.Input.handleEvent"></a>

### tecs.input.Input.handleEvent

<pre><code v-pre>function <a href="#tecs.input.Input.handleEvent">tecs.input.Input.handleEvent</a>(self: Input, event: eventStream.Event)
</code></pre>

Folds one typed event into the state.

Unrecognised kinds are ignored, so this can be handed the whole stream.

Nothing is retained: every field the state keeps is copied out here, so the
caller is free to reuse the record, which the converter does.

#### Parameters

| Type                                 | Name                     | Description |
| ------------------------------------ | ------------------------ | ----------- |
| <code v-pre>Input</code>             | <code v-pre>self</code>  |             |
| <code v-pre>eventStream.Event</code> | <code v-pre>event</code> |             |

<a id="tecs.input.Input.keyDown"></a>

### tecs.input.Input.keyDown

<pre><code v-pre>function <a href="#tecs.input.Input.keyDown">tecs.input.Input.keyDown</a>(self: Input, key: string | integer, layer: <a href="#tecs.input.Input.Layer">Layer</a>): boolean
</code></pre>

Whether a key is held. Keys are identified by physical position, so a
movement binding stays where it is on every layout.

#### Parameters

| Type                                                           | Name                     | Description |
| -------------------------------------------------------------- | ------------------------ | ----------- |
| <code v-pre>Input</code>                                       | <code v-pre>self</code>  |             |
| <code v-pre>string \| integer</code>                           | <code v-pre>key</code>   |             |
| <code v-pre><a href="#tecs.input.Input.Layer">Layer</a></code> | <code v-pre>layer</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.keyName"></a>

### tecs.input.Input.keyName

<pre><code v-pre>function <a href="#tecs.input.Input.keyName">tecs.input.Input.keyName</a>(self: Input, scancode: integer): string
</code></pre>

The name of a physical key, for showing a binding back to the player.

The platform's own name for the position, which is not the character the
player's layout produces there: the key `scancode("Q")` names is labelled Q
whatever a French keyboard prints on it.

#### Parameters

| Type                       | Name                        | Description |
| -------------------------- | --------------------------- | ----------- |
| <code v-pre>Input</code>   | <code v-pre>self</code>     |             |
| <code v-pre>integer</code> | <code v-pre>scancode</code> |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>string</code> |             |

<a id="tecs.input.Input.keyPressed"></a>

### tecs.input.Input.keyPressed

<pre><code v-pre>function <a href="#tecs.input.Input.keyPressed">tecs.input.Input.keyPressed</a>(self: Input, key: string | integer, layer: <a href="#tecs.input.Input.Layer">Layer</a>): boolean
</code></pre>

Whether a key went down. Reads the latched set inside a fixed step.

#### Parameters

| Type                                                           | Name                     | Description |
| -------------------------------------------------------------- | ------------------------ | ----------- |
| <code v-pre>Input</code>                                       | <code v-pre>self</code>  |             |
| <code v-pre>string \| integer</code>                           | <code v-pre>key</code>   |             |
| <code v-pre><a href="#tecs.input.Input.Layer">Layer</a></code> | <code v-pre>layer</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.keyReleased"></a>

### tecs.input.Input.keyReleased

<pre><code v-pre>function <a href="#tecs.input.Input.keyReleased">tecs.input.Input.keyReleased</a>(self: Input, key: string | integer, layer: <a href="#tecs.input.Input.Layer">Layer</a>): boolean
</code></pre>

Whether a key came up, on the same tiers as `keyPressed`.

#### Parameters

| Type                                                           | Name                     | Description |
| -------------------------------------------------------------- | ------------------------ | ----------- |
| <code v-pre>Input</code>                                       | <code v-pre>self</code>  |             |
| <code v-pre>string \| integer</code>                           | <code v-pre>key</code>   |             |
| <code v-pre><a href="#tecs.input.Input.Layer">Layer</a></code> | <code v-pre>layer</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.modifierDown"></a>

### tecs.input.Input.modifierDown

<pre><code v-pre>function <a href="#tecs.input.Input.modifierDown">tecs.input.Input.modifierDown</a>(self: Input, name: string, layer: <a href="#tecs.input.Input.Layer">Layer</a>): boolean
</code></pre>

Whether a modifier is held: "shift", "ctrl", "alt", "gui", "capsLock".

Either side counts for the unsided names, and "leftShift" asks for one.

#### Parameters

| Type                                                           | Name                     | Description |
| -------------------------------------------------------------- | ------------------------ | ----------- |
| <code v-pre>Input</code>                                       | <code v-pre>self</code>  |             |
| <code v-pre>string</code>                                      | <code v-pre>name</code>  |             |
| <code v-pre><a href="#tecs.input.Input.Layer">Layer</a></code> | <code v-pre>layer</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.modifiers"></a>

### tecs.input.Input.modifiers

<pre><code v-pre>function <a href="#tecs.input.Input.modifiers">tecs.input.Input.modifiers</a>(self: Input): integer
</code></pre>

The modifier mask reported with the most recent key event.

Not gated by a layer, and only as fresh as the last key event: a modifier
pressed on its own does produce one, but a modifier state that changed
while the window was not focused is not seen. Focus loss zeroes it for that
reason. `modifierDown` is the gated form and reads the same mask.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| <code v-pre>Input</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>integer</code> |             |

<a id="tecs.input.Input.mouseDeltaX"></a>

### tecs.input.Input.mouseDeltaX

<pre><code v-pre><a href="#tecs.input.Input.mouseDeltaX">tecs.input.Input.mouseDeltaX</a>: number
</code></pre>

Mouse motion accumulated this frame, summed over every motion event and
cleared by `beginFrame`. Under relative mouse mode this is the whole of
what the mouse said, since the position stops moving.
<a id="tecs.input.Input.mouseDeltaY"></a>

### tecs.input.Input.mouseDeltaY

<pre><code v-pre><a href="#tecs.input.Input.mouseDeltaY">tecs.input.Input.mouseDeltaY</a>: number
</code></pre>

<a id="tecs.input.Input.mouseDown"></a>

### tecs.input.Input.mouseDown

<pre><code v-pre>function <a href="#tecs.input.Input.mouseDown">tecs.input.Input.mouseDown</a>(self: Input, button: string | integer, layer: <a href="#tecs.input.Input.Layer">Layer</a>): boolean
</code></pre>

Whether a mouse button is held. Names are "left", "middle", "right", "x1",
"x2".

#### Parameters

| Type                                                           | Name                      | Description |
| -------------------------------------------------------------- | ------------------------- | ----------- |
| <code v-pre>Input</code>                                       | <code v-pre>self</code>   |             |
| <code v-pre>string \| integer</code>                           | <code v-pre>button</code> |             |
| <code v-pre><a href="#tecs.input.Input.Layer">Layer</a></code> | <code v-pre>layer</code>  |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.mousePressed"></a>

### tecs.input.Input.mousePressed

<pre><code v-pre>function <a href="#tecs.input.Input.mousePressed">tecs.input.Input.mousePressed</a>(self: Input, button: string | integer, layer: <a href="#tecs.input.Input.Layer">Layer</a>): boolean
</code></pre>

Whether a mouse button went down. Reads the latched set inside a fixed
step, on the same tiers as `keyPressed`.

#### Parameters

| Type                                                           | Name                      | Description |
| -------------------------------------------------------------- | ------------------------- | ----------- |
| <code v-pre>Input</code>                                       | <code v-pre>self</code>   |             |
| <code v-pre>string \| integer</code>                           | <code v-pre>button</code> |             |
| <code v-pre><a href="#tecs.input.Input.Layer">Layer</a></code> | <code v-pre>layer</code>  |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.mouseReleased"></a>

### tecs.input.Input.mouseReleased

<pre><code v-pre>function <a href="#tecs.input.Input.mouseReleased">tecs.input.Input.mouseReleased</a>(self: Input, button: string | integer, layer: <a href="#tecs.input.Input.Layer">Layer</a>): boolean
</code></pre>

Whether a mouse button came up, on the same tiers as `mousePressed`.

#### Parameters

| Type                                                           | Name                      | Description |
| -------------------------------------------------------------- | ------------------------- | ----------- |
| <code v-pre>Input</code>                                       | <code v-pre>self</code>   |             |
| <code v-pre>string \| integer</code>                           | <code v-pre>button</code> |             |
| <code v-pre><a href="#tecs.input.Input.Layer">Layer</a></code> | <code v-pre>layer</code>  |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.mouseSynthetic"></a>

### tecs.input.Input.mouseSynthetic

<pre><code v-pre><a href="#tecs.input.Input.mouseSynthetic">tecs.input.Input.mouseSynthetic</a>: boolean
</code></pre>

Whether that event was the platform's own translation of a touch or a
pen. A game that handles touch itself reads this and ignores the
duplicate rather than acting on one gesture twice.
<a id="tecs.input.Input.mouseWhich"></a>

### tecs.input.Input.mouseWhich

<pre><code v-pre><a href="#tecs.input.Input.mouseWhich">tecs.input.Input.mouseWhich</a>: number
</code></pre>

Device that produced the most recent mouse button, motion or wheel
event.
<a id="tecs.input.Input.mouseX"></a>

### tecs.input.Input.mouseX

<pre><code v-pre><a href="#tecs.input.Input.mouseX">tecs.input.Input.mouseX</a>: number
</code></pre>

Mouse position in window coordinates, from the top-left. The last
position reported, so it persists across frames that saw no motion.
<a id="tecs.input.Input.mouseY"></a>

### tecs.input.Input.mouseY

<pre><code v-pre><a href="#tecs.input.Input.mouseY">tecs.input.Input.mouseY</a>: number
</code></pre>

<a id="tecs.input.Input.penEraser"></a>

### tecs.input.Input.penEraser

<pre><code v-pre><a href="#tecs.input.Input.penEraser">tecs.input.Input.penEraser</a>: boolean
</code></pre>

Whether the end in use is the eraser. Read at the moment the pen went
down, so it describes the current stroke.
<a id="tecs.input.Input.penPressure"></a>

### tecs.input.Input.penPressure

<pre><code v-pre><a href="#tecs.input.Input.penPressure">tecs.input.Input.penPressure</a>: number
</code></pre>

How hard the pen is pressed, in 0..1. Zero until the pen reports it,
and on a pen that measures no pressure it stays there.
<a id="tecs.input.Input.penRotation"></a>

### tecs.input.Input.penRotation

<pre><code v-pre><a href="#tecs.input.Input.penRotation">tecs.input.Input.penRotation</a>: number
</code></pre>

Barrel rotation in degrees clockwise, for a pen with a chisel nib. Zero
on a pen that does not report it.
<a id="tecs.input.Input.penTiltX"></a>

### tecs.input.Input.penTiltX

<pre><code v-pre><a href="#tecs.input.Input.penTiltX">tecs.input.Input.penTiltX</a>: number
</code></pre>

How far the pen leans from upright, in degrees, negative towards the
left and towards the top of the surface. Both zero on a pen that does
not report tilt.
<a id="tecs.input.Input.penTiltY"></a>

### tecs.input.Input.penTiltY

<pre><code v-pre><a href="#tecs.input.Input.penTiltY">tecs.input.Input.penTiltY</a>: number
</code></pre>

<a id="tecs.input.Input.penTouching"></a>

### tecs.input.Input.penTouching

<pre><code v-pre><a href="#tecs.input.Input.penTouching">tecs.input.Input.penTouching</a>: boolean
</code></pre>

Whether the pen is touching the surface. Cleared when the pen leaves
proximity, since a pen carried away never reports lifting.
<a id="tecs.input.Input.penWhich"></a>

### tecs.input.Input.penWhich

<pre><code v-pre><a href="#tecs.input.Input.penWhich">tecs.input.Input.penWhich</a>: number
</code></pre>

Pen the state describes, or nil when no pen has been seen. One pen's
state is kept, not one per device: a second pen overwrites the first.
<a id="tecs.input.Input.penX"></a>

### tecs.input.Input.penX

<pre><code v-pre><a href="#tecs.input.Input.penX">tecs.input.Input.penX</a>: number
</code></pre>

Pen position in window coordinates, from the top-left.
<a id="tecs.input.Input.penY"></a>

### tecs.input.Input.penY

<pre><code v-pre><a href="#tecs.input.Input.penY">tecs.input.Input.penY</a>: number
</code></pre>

<a id="tecs.input.Input.popLayer"></a>

### tecs.input.Input.popLayer

<pre><code v-pre>function <a href="#tecs.input.Input.popLayer">tecs.input.Input.popLayer</a>(self: Input): <a href="#tecs.input.Input.Layer">Layer</a>
</code></pre>

Removes the topmost layer. The base layer is never removed.

A text-input session started by that layer stops with it, because a menu
that closed and left the on-screen keyboard up is a bug the game would have
to remember to avoid. The pending edges go the same way when the layer was
blocking, so what was typed into it stays in it.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| <code v-pre>Input</code> | <code v-pre>self</code> |             |

#### Returns

| Type                                                           | Description |
| -------------------------------------------------------------- | ----------- |
| <code v-pre><a href="#tecs.input.Input.Layer">Layer</a></code> |             |

<a id="tecs.input.Input.pushLayer"></a>

### tecs.input.Input.pushLayer

<pre><code v-pre>function <a href="#tecs.input.Input.pushLayer">tecs.input.Input.pushLayer</a>(self: Input, name: string, blocking: boolean): <a href="#tecs.input.Input.Layer">Layer</a>
</code></pre>

Pushes a layer and returns it.

A blocking layer hides input from everything beneath. Pass
`blocking = false` for an overlay that observes without consuming.

A layer that blocks moves capture, so the pending edges are dropped: what
was pressed before the layer existed is not the layer's to act on. An
overlay that consumes nothing moves no capture and drops nothing.

#### Parameters

| Type                       | Name                        | Description |
| -------------------------- | --------------------------- | ----------- |
| <code v-pre>Input</code>   | <code v-pre>self</code>     |             |
| <code v-pre>string</code>  | <code v-pre>name</code>     |             |
| <code v-pre>boolean</code> | <code v-pre>blocking</code> |             |

#### Returns

| Type                                                           | Description |
| -------------------------------------------------------------- | ----------- |
| <code v-pre><a href="#tecs.input.Input.Layer">Layer</a></code> |             |

<a id="tecs.input.Input.refreshDevices"></a>

### tecs.input.Input.refreshDevices

<pre><code v-pre>function <a href="#tecs.input.Input.refreshDevices">tecs.input.Input.refreshDevices</a>(self: Input)
</code></pre>

Opens every gamepad already attached.

Run before a game's own load, so a pad that was plugged in when the process
started is there when the game asks. Safe to call again: a device already
open is left alone, and one that went away without an event is closed.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| <code v-pre>Input</code> | <code v-pre>self</code> |             |

<a id="tecs.input.Input.relativeMouseMode"></a>

### tecs.input.Input.relativeMouseMode

<pre><code v-pre>function <a href="#tecs.input.Input.relativeMouseMode">tecs.input.Input.relativeMouseMode</a>(self: Input): boolean
</code></pre>

Whether relative mouse mode is on, asked of the platform rather than
remembered, so a mode the window lost reports honestly.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| <code v-pre>Input</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.scancode"></a>

### tecs.input.Input.scancode

<pre><code v-pre>function <a href="#tecs.input.Input.scancode">tecs.input.Input.scancode</a>(self: Input, name: string): integer
</code></pre>

Resolves a key name to a scancode, caching the lookup.

Names are the platform's ("Space", "Left Shift"), matched case-insensitively
so "space" and "left shift" work too.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Input</code>  | <code v-pre>self</code> |             |
| <code v-pre>string</code> | <code v-pre>name</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>integer</code> |             |

<a id="tecs.input.Input.screenKeyboardSupported"></a>

### tecs.input.Input.screenKeyboardSupported

<pre><code v-pre>function <a href="#tecs.input.Input.screenKeyboardSupported">tecs.input.Input.screenKeyboardSupported</a>(self: Input): boolean
</code></pre>

Whether the platform puts a keyboard on the screen for text input.

What a layout has to know: where this is true, starting text input covers
part of the window, and the area given to `startTextInput` is what keeps
the field out from under it.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| <code v-pre>Input</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.setCursor"></a>

### tecs.input.Input.setCursor

<pre><code v-pre>function <a href="#tecs.input.Input.setCursor">tecs.input.Input.setCursor</a>(self: Input, name: string): boolean
</code></pre>

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
| <code v-pre>Input</code>  | <code v-pre>self</code> |             |
| <code v-pre>string</code> | <code v-pre>name</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.setRelativeMouseMode"></a>

### tecs.input.Input.setRelativeMouseMode

<pre><code v-pre>function <a href="#tecs.input.Input.setRelativeMouseMode">tecs.input.Input.setRelativeMouseMode</a>(self: Input, enabled: boolean): boolean
</code></pre>

Hides the cursor and delivers motion as deltas only, for a game that turns
the view with the mouse.

`mouseX` and `mouseY` stop moving while this is on, since there is no
cursor to report a position for; `mouseDeltaX` and `mouseDeltaY` carry the
whole of what the mouse said. False without a window, which is what a
headless test gets.

#### Parameters

| Type                       | Name                       | Description                                                                |
| -------------------------- | -------------------------- | -------------------------------------------------------------------------- |
| <code v-pre>Input</code>   | <code v-pre>self</code>    |                                                                            |
| <code v-pre>boolean</code> | <code v-pre>enabled</code> | Anything but false turns it on, so calling with nothing on is enabling it. |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.setTextInputArea"></a>

### tecs.input.Input.setTextInputArea

<pre><code v-pre>function <a href="#tecs.input.Input.setTextInputArea">tecs.input.Input.setTextInputArea</a>(self: Input, area: <a href="#tecs.input.Input.TextArea">TextArea</a>): boolean
</code></pre>

Tells the platform where the edited text sits, in window coordinates.

Worth calling as the caret moves, not only at the start: the platform
places its candidate window against the most recent rectangle it was given.

#### Parameters

| Type                                                                 | Name                    | Description |
| -------------------------------------------------------------------- | ----------------------- | ----------- |
| <code v-pre>Input</code>                                             | <code v-pre>self</code> |             |
| <code v-pre><a href="#tecs.input.Input.TextArea">TextArea</a></code> | <code v-pre>area</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.showCursor"></a>

### tecs.input.Input.showCursor

<pre><code v-pre>function <a href="#tecs.input.Input.showCursor">tecs.input.Input.showCursor</a>(self: Input, visible: boolean): boolean
</code></pre>

Shows or hides the cursor, for the application rather than one window.

Independent of relative mouse mode, which hides the cursor for the duration
on its own: leaving this alone is the usual thing.

#### Parameters

| Type                       | Name                       | Description |
| -------------------------- | -------------------------- | ----------- |
| <code v-pre>Input</code>   | <code v-pre>self</code>    |             |
| <code v-pre>boolean</code> | <code v-pre>visible</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.startTextInput"></a>

### tecs.input.Input.startTextInput

<pre><code v-pre>function <a href="#tecs.input.Input.startTextInput">tecs.input.Input.startTextInput</a>(self: Input, layer: <a href="#tecs.input.Input.Layer">Layer</a>, options: <a href="#tecs.input.Input.TextOptions">TextOptions</a>): boolean
</code></pre>

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
| <code v-pre>Input</code>                                                   | <code v-pre>self</code>    |             |
| <code v-pre><a href="#tecs.input.Input.Layer">Layer</a></code>             | <code v-pre>layer</code>   |             |
| <code v-pre><a href="#tecs.input.Input.TextOptions">TextOptions</a></code> | <code v-pre>options</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.stopTextInput"></a>

### tecs.input.Input.stopTextInput

<pre><code v-pre>function <a href="#tecs.input.Input.stopTextInput">tecs.input.Input.stopTextInput</a>(self: Input): boolean
</code></pre>

Stops text input and clears whatever was being composed.

Declared here because the layer stack and the shutdown path both stop a
session, and both read better above where text input is defined.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| <code v-pre>Input</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description                                                                                                                                           |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | False when no session was running, in which case the composition state is cleared anyway, so this is safe to call unconditionally on a teardown path. |

<a id="tecs.input.Input.text"></a>

### tecs.input.Input.text

<pre><code v-pre><a href="#tecs.input.Input.text">tecs.input.Input.text</a>: string
</code></pre>

Text committed this frame, from the text input events. Empty when
nothing was typed, so it can be appended without a nil check.
<a id="tecs.input.Input.textInputActive"></a>

### tecs.input.Input.textInputActive

<pre><code v-pre>function <a href="#tecs.input.Input.textInputActive">tecs.input.Input.textInputActive</a>(self: Input): boolean
</code></pre>

Whether a text-input session is running.

What this state started, not what the platform is doing: a session started
outside the engine is not visible here.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| <code v-pre>Input</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description |
| -------------------------- | ----------- |
| <code v-pre>boolean</code> |             |

<a id="tecs.input.Input.textInputLayer"></a>

### tecs.input.Input.textInputLayer

<pre><code v-pre>function <a href="#tecs.input.Input.textInputLayer">tecs.input.Input.textInputLayer</a>(self: Input): <a href="#tecs.input.Input.Layer">Layer</a>
</code></pre>

The layer the running session belongs to, or nil.

Nil both when no session is running and when one was started without naming
a layer, which is a session nothing will stop on its own.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| <code v-pre>Input</code> | <code v-pre>self</code> |             |

#### Returns

| Type                                                           | Description |
| -------------------------------------------------------------- | ----------- |
| <code v-pre><a href="#tecs.input.Input.Layer">Layer</a></code> |             |

<a id="tecs.input.Input.topLayer"></a>

### tecs.input.Input.topLayer

<pre><code v-pre>function <a href="#tecs.input.Input.topLayer">tecs.input.Input.topLayer</a>(self: Input): <a href="#tecs.input.Input.Layer">Layer</a>
</code></pre>

The layer currently on top.

#### Parameters

| Type                     | Name                    | Description |
| ------------------------ | ----------------------- | ----------- |
| <code v-pre>Input</code> | <code v-pre>self</code> |             |

#### Returns

| Type                                                           | Description |
| -------------------------------------------------------------- | ----------- |
| <code v-pre><a href="#tecs.input.Input.Layer">Layer</a></code> |             |

<a id="tecs.input.Input.touches"></a>

### tecs.input.Input.touches

<pre><code v-pre>function <a href="#tecs.input.Input.touches">tecs.input.Input.touches</a>(self: Input, layer: <a href="#tecs.input.Input.Layer">Layer</a>): {<a href="#tecs.input.Input.Touch">Touch</a>}
</code></pre>

Fingers currently on the touch surface.

The list and the records in it are reused between calls, so anything
retaining one has to copy it.

#### Parameters

| Type                                                           | Name                     | Description |
| -------------------------------------------------------------- | ------------------------ | ----------- |
| <code v-pre>Input</code>                                       | <code v-pre>self</code>  |             |
| <code v-pre><a href="#tecs.input.Input.Layer">Layer</a></code> | <code v-pre>layer</code> |             |

#### Returns

| Type                                                             | Description |
| ---------------------------------------------------------------- | ----------- |
| <code v-pre>{<a href="#tecs.input.Input.Touch">Touch</a>}</code> |             |

<a id="tecs.input.Input.warpMouse"></a>

### tecs.input.Input.warpMouse

<pre><code v-pre>function <a href="#tecs.input.Input.warpMouse">tecs.input.Input.warpMouse</a>(self: Input, x: number, y: number)
</code></pre>

Moves the cursor within the window, in window coordinates.

Produces a motion event like any other, so `mouseDeltaX` and `mouseDeltaY`
pick the jump up. A game recentring the cursor every frame reads its own
warp as input unless it accounts for it.

#### Parameters

| Type                      | Name                    | Description |
| ------------------------- | ----------------------- | ----------- |
| <code v-pre>Input</code>  | <code v-pre>self</code> |             |
| <code v-pre>number</code> | <code v-pre>x</code>    |             |
| <code v-pre>number</code> | <code v-pre>y</code>    |             |

<a id="tecs.input.Input.wheelTicksX"></a>

### tecs.input.Input.wheelTicksX

<pre><code v-pre><a href="#tecs.input.Input.wheelTicksX">tecs.input.Input.wheelTicksX</a>: integer
</code></pre>

The same movement accumulated to whole notches by the platform, on the
same sign convention and cleared by `beginFrame` alongside the pair
above. What a menu stepping one item per notch reads, rather than
picking its own threshold on the fractional pair.
<a id="tecs.input.Input.wheelTicksY"></a>

### tecs.input.Input.wheelTicksY

<pre><code v-pre><a href="#tecs.input.Input.wheelTicksY">tecs.input.Input.wheelTicksY</a>: integer
</code></pre>

<a id="tecs.input.Input.wheelX"></a>

### tecs.input.Input.wheelX

<pre><code v-pre><a href="#tecs.input.Input.wheelX">tecs.input.Input.wheelX</a>: number
</code></pre>

Wheel movement accumulated this frame, in the platform's own notches
rather than pixels. Cleared by `beginFrame`.

One sign whatever the machine is set to: positive `wheelY` is a scroll
away from the player, positive `wheelX` a scroll to the right. A
platform with natural scrolling on reports the opposite pair and says
so, and the conversion in `events` puts it back, so a binding written
against these fields does not invert on somebody else's desk.
<a id="tecs.input.Input.wheelY"></a>

### tecs.input.Input.wheelY

<pre><code v-pre><a href="#tecs.input.Input.wheelY">tecs.input.Input.wheelY</a>: number
</code></pre>
