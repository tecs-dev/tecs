---
description: "The engine's typed platform event stream: one wide record per event, one ECS event type per kind, and how to observe, copy and inject them"
outline: deep
---

# tecs.events

`tecs.events` is the engine's platform event stream: keys, pointers, fingers, pens, gamepads, windows, displays,
drops, the clipboard, audio devices and the application lifecycle, all as one typed vocabulary. Game code never
sees an `SDL_Event`, both because the union is a poor thing to program against and because its pointer is only
valid inside the callback that produced it.

Every platform delivers the same vocabulary: desktop, mobile, replay and tests. Unrecognized SDL events arrive as
`unknown` carrying their numeric type rather than being dropped, so upgrading SDL surfaces new input instead of
silently losing it.

::: info This is not the ECS message bus
[`world:emit`](/ecs/events) and `world:observe` are the ECS's own message bus, which carries whatever event
types a game declares. This module is the platform layer that produces one particular family of them. The two
meet at exactly one point: each platform kind is registered as an ECS event type, so a platform event is
delivered through the same bus a game's own events are. Everything else about the bus, including addresses,
ordering and how a listener is registered, is the ECS's; see [Events](/ecs/events).
:::

## Observing a kind

Events reach a game through the world's message bus, one ECS event type per kind, at address zero.

```teal
world:observe(0, tecs.events.on.dropFile, function(event: tecs.events.Event)
    load(event.text)
end)
```

That handler is called for dropped files and for nothing else. A type per kind is what buys that over one type
carrying the kind, where every subscriber is handed every kind and filters it back out again.

`events.on` is a record with a field per kind, so a misspelled kind is a compile error on the key rather than an
observer that is never called.

Nothing is emitted for a kind nobody observes, so a stream of motion at device rate costs a table lookup and a
gate rather than a dispatch.

### Where an observer runs

An observer is not a system, and the difference matters for anything it touches. The drain runs before
`world:update`, so an observer fires ahead of every system in the frame the event belongs to and outside every
phase: no fixed step, no pause and no state gating apply to it, and its mutations land at once rather than at a
phase boundary.

A reaction that wants to be in phase does what [`Input`](/modules/input) does, which is fold the event into
something a system reads. `Input` is folded before any observer runs and is unaffected by all of this.

### typeOf

The event type for a kind held as a string.

```teal
function events.typeOf(kind: string): Event
```

**Parameters:**

- `kind`: one of the names in the [kind reference](#kind-reference).

**Returns:** the ECS event type to observe, or nil for a name this build does not know. This is what `events.on`
is for code that cannot spell the kind in source, which is the conversion itself and the debug tools.

### kinds

Every kind this build recognizes, sorted.

```teal
function events.kinds(): {string}
```

For tooling that enumerates them. A kind whose SDL constant this build does not have is not in the list, and
`unknown` is not either, since nothing maps to it.

## Borrow rule

`Event` is one wide record discriminated by `kind` rather than a union of per-kind records. Teal can express the
union, but not a union that pools, and an event stream that allocates per event is not one this engine can use.

One record is reused for the whole process, so the record an observer receives is the record the next event
overwrites. Read it inside the handler, or copy it, but do not keep it.

The kind determines which fields are meaningful and the rest are stale. Fields that answer a question by
existing, a string, a list or a flag, are cleared on every event, so `event.text ~= nil` and `event.eraser`
cannot read as the previous event's payload; a stale number is only read by code that ignored the kind.

### copy

Returns an independent copy.

```teal
function events.copy(event: Event): Event
```

Shallow, which is enough because every field is a number, a string or a boolean except the three lists, and
those are freshly built per event rather than reused. It allocates, so it is for the events a recorder or a tool
keeps and not for the stream.

## Event fields

Every event carries `kind`, `timestamp` and `sdlType`. The rest are filled per kind.

### Identity and time

| Field       | Type      | Description                                                                                                                                                                                                           |
| ----------- | --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kind`      | `string`  | What happened. Determines which other fields mean anything.                                                                                                                                                           |
| `timestamp` | `number`  | Nanoseconds since SDL started, as SDL reported it. That epoch is not the clock [`time.now`](/modules/time#now) reads, so it orders events against each other and against nothing else.                                |
| `arrival`   | `number`  | Monotonic seconds on the clock `clock.now` reads, converted by the host from the stamp SDL put on the event when it produced it. Nil for an event that did not come through the host's queue, such as a replayed one. |
| `sdlType`   | `integer` | Numeric SDL type, set on every event and the only useful field on `unknown`.                                                                                                                                          |
| `which`     | `number`  | The device the event came from: a gamepad, keyboard, mouse, pen, sensor, display or window. These identifiers are 32 bits and fit a Lua number exactly.                                                               |

`arrival` is not where the host was handed the event, which is a different and much kinder number: SDL only
hands events over while the main thread is pumping, and most of what a player waits through is time the thread
was doing something else. Dating an event from delivery would leave the measurement least trustworthy in exactly
the frames worth catching.

### Keyboard and text

| Field        | Type       | Description                                                                                                                                  |
| ------------ | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `scancode`   | `integer`  | Physical key position, which is what a movement binding wants: WASD stays in the same place on every layout.                                 |
| `keycode`    | `integer`  | The key the layout produces, which is what a text binding and a prompt want. Both are carried, because neither answers the other's question. |
| `modifiers`  | `integer`  | Modifier keys held when the key event was produced, as a mask.                                                                               |
| `repeated`   | `boolean`  | True when the platform is repeating a held key rather than reporting a new press.                                                            |
| `down`       | `boolean`  | Whether the button or key this event describes went down.                                                                                    |
| `text`       | `string`   | Text committed by an input method, being composed by one, or dropped onto the window.                                                        |
| `start`      | `integer`  | Cursor position within composing text.                                                                                                       |
| `length`     | `integer`  | Selection length within composing text.                                                                                                      |
| `candidates` | `{string}` | Candidates an input method is offering. Nil when the platform offers none.                                                                   |
| `selected`   | `integer`  | Which candidate is selected.                                                                                                                 |
| `horizontal` | `boolean`  | Whether the platform lays its candidates out horizontally.                                                                                   |

### Pointers, wheels and gestures

| Field                        | Type      | Description                                                                                                                                                                     |
| ---------------------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `x`, `y`                     | `number`  | Pointer position, in window coordinates.                                                                                                                                        |
| `dx`, `dy`                   | `number`  | Movement since the previous event of this kind.                                                                                                                                 |
| `normalX`, `normalY`         | `number`  | Position as the platform reported it, in 0..1 across the window. Touch is normalized at source, and a normalized position survives a resize where a window coordinate does not. |
| `button`                     | `integer` | Mouse, gamepad or pen button.                                                                                                                                                   |
| `clicks`                     | `integer` | How many times this button was pressed in quick succession, as the platform counts it against its own double-click interval. One for a single click, two for a double.          |
| `wheelX`, `wheelY`           | `number`  | Wheel movement. Positive `wheelY` is a scroll away from the player and positive `wheelX` is a scroll to the right.                                                              |
| `wheelTicksX`, `wheelTicksY` | `integer` | The same movement accumulated to whole notches by the platform, on the same sign convention. What a menu stepping one item per notch reads.                                     |
| `flipped`                    | `boolean` | Whether a wheel event handed to `push` is one a platform with natural scrolling would send. Read only there; see below.                                                         |
| `scale`                      | `number`  | Zoom factor a pinch reports since the previous event in it. Below one is a pinch closed, above one is a pinch opened.                                                           |
| `synthetic`                  | `boolean` | True when the platform produced this mouse event from a touch or a pen rather than from a mouse. A game that also handles touch would otherwise act on the same gesture twice.  |

Natural scrolling is undone by the conversion rather than left for each reader to discover: SDL reports a
flipped wheel by negating both axes and setting a flag, so `wheelX` and `wheelY` mean one thing everywhere and
nothing above binds a sign twice.

Touch positions are converted into window coordinates using the size
[`setTouchScale`](#settouchscale) was last told about, so touch and mouse arrive in the same units.

### Touch, pens and gamepad touchpads

| Field         | Type      | Description                                                                                                                                                                                                                                 |
| ------------- | --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `finger`      | `string`  | Touch finger identity. 64 bits, carried as an opaque string rather than a number that might silently round.                                                                                                                                 |
| `touchDevice` | `string`  | The touch device the finger belongs to, on the same terms.                                                                                                                                                                                  |
| `touchpad`    | `integer` | Gamepad touchpad index.                                                                                                                                                                                                                     |
| `fingerIndex` | `integer` | The finger's slot on that touchpad. A touchpad finger is identified by position on the device, not by a 64-bit id.                                                                                                                          |
| `pressure`    | `number`  | How hard a finger is pressing, in 0..1, on a touch surface or a gamepad touchpad. A pen reports pressure as an axis instead, so a pen event leaves this holding whatever the last touch put there.                                          |
| `eraser`      | `boolean` | Whether the pen's eraser end is in use.                                                                                                                                                                                                     |
| `penState`    | `integer` | Everything the pen was doing at the instant of the event, as a mask of the platform's `SDL_PEN_INPUT_*` values: tip down, eraser end in use, proximity, and each barrel button. Not carried on the proximity events, which report no state. |
| `axis`        | `integer` | Gamepad or pen axis.                                                                                                                                                                                                                        |
| `value`       | `number`  | That axis's value, in -1..1.                                                                                                                                                                                                                |

### Sensors

| Field                           | Type       | Description                                                                                                                                                                                                          |
| ------------------------------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sensor`                        | `integer`  | Sensor identity on a gamepad sensor event.                                                                                                                                                                           |
| `sensorX`, `sensorY`, `sensorZ` | `number`   | The reading's first three components.                                                                                                                                                                                |
| `sensorData`                    | `{number}` | The whole reading. A standalone sensor reports up to six components where a gamepad reports three.                                                                                                                   |
| `sensorTimestamp`               | `number`   | When the hardware took the reading, in nanoseconds on the sensor's own clock. Like `timestamp` it orders readings against each other and against nothing else, which is what integrating a rotation over them needs. |

### Drops, the clipboard, audio devices and payloads

| Field            | Type       | Description                                                                                                                                                                                            |
| ---------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `text`           | `string`   | The dropped file's path, or the dropped text.                                                                                                                                                          |
| `source`         | `string`   | Where a dropped file or text came from, when the platform says.                                                                                                                                        |
| `mimeTypes`      | `{string}` | Clipboard formats on offer. The same list [`clipboard.mimeTypes`](/modules/system#clipboardmimetypes) answers.                                                                                         |
| `owner`          | `boolean`  | Whether the clipboard's new contents are this application's own.                                                                                                                                       |
| `recording`      | `boolean`  | Whether an audio device is a recording device.                                                                                                                                                         |
| `data1`, `data2` | `integer`  | Window, display and user payloads as SDL reports them. A user event's code arrives in `data1`; the two data pointers beside it do not cross, since a pointer is not a value this vocabulary can carry. |

## Kind reference

### Application lifecycle

`quit`, `terminating`, `lowMemory`, `appWillEnterBackground`, `appDidEnterBackground`, `appWillEnterForeground`,
`appDidEnterForeground`, `localeChanged`, `themeChanged`.

SDL dispatches six of these from its event watcher rather than queueing them, and the instant they arrive is the
only one a game gets on some platforms. The host therefore answers them where they arrive, by calling a hook on
the [application](/modules/Application), and queues the event as well, so a game can observe the change like any
other. The hook is where a game meets the platform's deadline; the stream is where it observes the change. These
six carry no stamp from SDL, so `arrival` on them is where they were delivered, and
[`isInput`](#isinput) excludes them.

### Displays

`displayOrientation`, `displayAdded`, `displayRemoved`, `displayMoved`, `displayScaleChanged`,
`displayDesktopModeChanged`, `displayCurrentModeChanged`, `displayUsableBoundsChanged`.

`which` is the display the event is about, which is its whole subject: a display event that did not carry one
would name a change on a machine with two monitors without saying which of them changed.
[`Window`](/modules/window#displays) is where the new state is read from.

### Windows

`windowShown`, `windowHidden`, `windowExposed`, `windowMoved`, `windowResized`, `windowPixelSizeChanged`,
`windowMinimized`, `windowMaximized`, `windowRestored`, `windowMouseEnter`, `windowMouseLeave`,
`windowFocusGained`, `windowFocusLost`, `windowCloseRequested`, `windowDisplayChanged`,
`windowDisplayScaleChanged`, `windowSafeAreaChanged`, `windowOccluded`, `windowEnterFullscreen`,
`windowLeaveFullscreen`.

`which` is the window id, which is what [`Window:id`](/modules/window#id) answers. An event reports a change and
nothing reports the state a window started in, so [`Window`](/modules/window) has a getter for every one of these
facts.

### Keyboard and text

`keyDown`, `keyUp`, `textEditing`, `textCandidates`, `textInput`, `keymapChanged`, `keyboardAdded`,
`keyboardRemoved`, `screenKeyboardShown`, `screenKeyboardHidden`.

### Mouse

`mouseMotion`, `mouseDown`, `mouseUp`, `mouseWheel`, `mouseAdded`, `mouseRemoved`.

### Touch and gestures

`fingerDown`, `fingerUp`, `fingerMotion`, `fingerCanceled`, `pinchBegin`, `pinchUpdate`, `pinchEnd`.

### Pen

`penProximityIn`, `penProximityOut`, `penDown`, `penUp`, `penMotion`, `penButtonDown`, `penButtonUp`, `penAxis`.

### Gamepad

`gamepadAdded`, `gamepadRemoved`, `gamepadRemapped`, `gamepadButtonDown`, `gamepadButtonUp`, `gamepadAxis`,
`gamepadSensor`, `gamepadTouchpadDown`, `gamepadTouchpadUp`, `gamepadTouchpadMotion`.

Gamepad axis values arrive as signed 16-bit and are reported as -1..1.

### Drag and drop

`dropFile`, `dropText`, `dropBegin`, `dropComplete`, `dropPosition`.

### Everything else

`clipboardUpdate`, `audioDeviceAdded`, `audioDeviceRemoved`, `audioDeviceFormatChanged`, `sensorUpdate`, `user`,
and `unknown` for an SDL event this build has no name for, which carries `sdlType` and nothing else worth
reading.

## isInput

Whether a kind carries player input rather than describing the platform.

```teal
function events.isInput(kind: string): boolean
```

True for the key, text, mouse, finger, pinch, pen and gamepad kinds a player produces, and false for everything
the platform reports about itself. Latency is only meaningful for these: nobody is waiting on a window expose.

## Injecting an event

### push

Pushes a synthetic event onto SDL's own queue.

```teal
function events.push(kind: string, fields: Event)
```

**Parameters:**

- `kind`: one of [`events.kinds()`](#kinds). An unrecognized name raises.
- `fields`: a partial `Event`. Only the fields a kind uses are read.

Takes the engine's vocabulary rather than an SDL union, so a test or a tool can inject input without knowing
SDL's layout. Payloads are filled for the key, mouse, wheel, pen, gamepad, device, pinch, window and display
kinds; any other recognized kind is pushed carrying its type and nothing else, which is what a kind whose payload
nobody injects needs and is not what a caller expecting a full event would assume.

SDL stamps the timestamp, so a pushed event arrives ordered against real ones rather than ahead of them.

**Example:**

```teal
tecs.events.push("mouseDown", { button = 1, x = 120, y = 64 })
tecs.events.push("gamepadAxis", { which = 0, axis = 0, value = -1.0 })
```

::: tip A flipped wheel round-trips as a normalization
A wheel payload is written the way the platform writes one, so `flipped` sets the direction and the axes beside
it are left as given. The conversion then negates them, which is what a caller asking for a flipped scroll is
asking to see: the round trip is the normalization, not the identity.
:::

## Wiring the stream

These three are how the loop and a replay driver reach the module. [`Application`](/modules/Application) calls
the first two for you.

### setTouchScale

Tells the converter how large the window is.

```teal
function events.setTouchScale(width: number, height: number)
```

Touch arrives normalized, so this is what lets touch positions be reported in the same units mouse positions
arrive in as well as in the platform's own 0..1. Logical window size, not pixels: scaling touch by the pixel size
would put the two pointers in different units on every high-density display.

### drain

Converts and dispatches a queue of SDL events, in arrival order.

```teal
function events.drain(queue: loader.CValue, count: integer,
                      handler: function(Event), arrivals?: loader.CValue)
```

The host owns the queue and clears it; this only reads. `arrivals` is the host's parallel array of performance
counter readings, one per event, converted there from the stamp SDL put on each event as it was produced. Given
it, every converted event carries `arrival` in the units `clock.now` reports.

When a replay `source` is installed, it is called instead and the queue is not read at all.

### Replaying a stream

`events.source` is `function(handler: function(Event))`. Installed by a replay driver, it is called instead of
draining the host queue and is expected to invoke the handler for each recorded event. It is also the seam a
platform that is not SDL supplies, producing the engine's typed values directly rather than translating an
`SDL_Event`.

Pair it with [`time.provider`](/modules/time#driving-a-replay), which replaces the frame delta on the same
terms.
