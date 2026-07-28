---
description: "Gameplay input in three tiers, behind a layer stack: live state, frame events, and latched events"
outline: [2, 3]
---

# tecs.Input

`tecs.Input` is gameplay input, in three tiers, behind a layer stack. A game does not construct one: the
[application](/modules/Application) does, and hands it over as `app.input`.

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
[`tecs.Gamepad`](/modules/Gamepad).

What `Input` holds is what the machine has one of: a keyboard, an aggregate mouse, the touch surface, the pen,
and the registry the pads live in.

## Design record

- [Input](https://github.com/tecs-dev/tecs/blob/main/README.md#input)
- [Events](https://github.com/tecs-dev/tecs/blob/main/README.md#events)
- [Measuring latency](https://github.com/tecs-dev/tecs/blob/main/README.md#measuring-latency)
