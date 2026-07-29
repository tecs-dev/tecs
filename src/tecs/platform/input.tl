--[[
# Gameplay input

`tecs.input` folds typed platform events into gameplay input. The application
creates one [`Input`](tealdoc:tecs.input.Input) as `app.input`; ordinary game
code does not construct or feed it. The module owns replay, layers, edge
detection and fixed-step latching.

## Three input tiers

Live state answers whether a key or button remains held. Frame edges answer
whether it changed this frame. Latched edges answer that question for the next
fixed step. The same `keyPressed`, `mousePressed` and
`Gamepad:buttonPressed` methods select frame or latched edges from the phase.
The engine consumes a latched edge in the first fixed step after it arrived.

## Layer capture

A blocking layer hides every device from lower layers. Calls that omit a layer
read the base layer, so gameplay becomes quiet while a menu owns capture.
Moving capture clears pending edges, text, wheel movement and mouse deltas.

```teal
local pause <const> = app.input:pushLayer("pause")

if app.input:keyPressed("Escape", pause) then
    app.input:popLayer()
end

-- The base layer cannot read while pause owns capture.
if app.input:keyDown("W") then
    movePlayer()
end
```

Pass false to `pushLayer` for an observing overlay. Because capture does not
move, the overlay does not clear edges.

## Focus and text input

Focus loss releases held keys, mouse buttons, gamepad buttons, fingers,
modifiers and pen pressure. The resulting release edges let a game finish the
active action.

Bind text input to the layer that owns the field. Popping the layer stops the
input method and clears composition.

```teal
local field <const> = app.input:pushLayer("playerName")
app.input:startTextInput(field, {
    area = {x = 40, y = 200, width = 320, height = 24, cursor = 80},
})
```

Append `input.text` once per frame. Draw `input.composition` until the input
method commits it. Update the text area when the field scrolls or its caret
moves.

## Gamepads and sensors

`Input:gamepads` returns a live connection-order list. Hold a
[`Gamepad`](tealdoc:tecs.input.Gamepad) object or match its `guid` to follow
hardware because list positions move and instance ids do not survive a
reconnect. Gamepad queries use the same layers and fixed-step tiers as keyboard
and mouse queries.

Standalone sensors do not belong to a gamepad. Enumerate them with
`tecs.input.sensors`, open one by instance id, poll it, and close it explicitly.
]]

-- Implementation details: SDL owns device mechanics. Input folds its events
-- into replay state, layer gates and fixed-step latches.

local bit <const> = require("bit")
local eventStream <const> = require("tecs.platform.events")
local inputstate <const> = require("tecs.platform.inputstate")
local inputbackend <const> = require("tecs.platform.inputbackend")
local adapter <const> = require("tecs.platform.adapter")
local Gamepad <const> = require("tecs.platform.Gamepad")
local sensors <const> = require("tecs.platform.sensors")
local loader <const> = require("tecs.ffi.loader")

local type Layer = inputstate.Layer
local type Buttons = inputstate.Buttons
local type Gate = inputstate.Gate
local type Backend = inputbackend.Backend

--- `Touch` reports one finger from the most recent touch event.
---
--- Input owns and reuses every field. Callers treat the record as read-only
--- and copy values they need to retain.
local record Touch
    --- Read-only. Input sets `device` to the touch device's opaque identity
    --- when the finger first appears.
    device: string
    --- Read-only. Input sets `finger` to the finger's opaque 64-bit identity
    --- when the finger first appears.
    finger: string
    --- Read-only. Input updates `x` in window coordinates on every touch event.
    --- It may lag a resize until `events.setTouchScale` receives the new size.
    x: number
    --- Read-only. Input updates `y` in window coordinates with `x`.
    y: number
    --- Read-only. Input updates `normalX` from the platform's 0 to 1 position
    --- on every touch event.
    normalX: number
    --- Read-only. Input updates `normalY` with `normalX`.
    normalY: number
    --- Read-only. Input updates `pressure` from 0 to 1 when the surface reports
    --- pressure.
    pressure: number
end

--- Callers write `TextArea` before passing it to a text-input method.
---
--- Input reads the record immediately and does not retain it.
local record TextArea
    --- Caller-writable. The caller sets `x` to the rectangle's left edge in
    --- window coordinates.
    x: integer
    --- Caller-writable. The caller sets `y` to the rectangle's top edge.
    y: integer
    --- Caller-writable. The caller sets `width` to the text run the platform
    --- should keep clear.
    width: integer
    --- Caller-writable. The caller sets `height` with `width`.
    height: integer
    --- Caller-writable. The caller sets `cursor` to the caret offset from the
    --- left edge. It defaults to zero.
    cursor: integer
end

local record TextOptions
    --- Caller-writable. The caller sets `area` so the platform can keep its
    --- candidate window and on-screen keyboard clear of the edited text.
    area: TextArea
end

local record InputOptions
    --- Engine-owned. The application supplies `window` for text input and
    --- cursor modes. Ordinary game code ignores this field; omitting it makes
    --- window commands report failure for a headless test.
    window: loader.CPtr
    --- Engine-owned. The application or a platform test supplies `backend`.
    --- Ordinary game code ignores it. Input uses the installed backend when
    --- the field is nil.
    backend: Backend
end

local record input
    --- An `Input` folds platform events once a frame and exposes live state,
    --- frame edges and fixed-step latched edges.
    record Input
        --- Read-only. [`Layer`](tealdoc:tecs.input.Layer) names a position
        --- returned by `pushLayer`.
        Layer: Layer
        --- Read-only. [`Touch`](tealdoc:tecs.input.Touch) names a finger record
        --- returned by `touches`.
        Touch: Touch
        --- Read-only. Exposes [`TextArea`](tealdoc:tecs.input.TextArea), whose
        --- records callers pass to text-input methods.
        TextArea: TextArea
        --- Read-only. Exposes
        --- [`TextOptions`](tealdoc:tecs.input.TextOptions), whose records
        --- callers pass to `startTextInput`.
        TextOptions: TextOptions
        --- Engine-owned. Exposes the framework construction options. Ordinary
        --- game code uses the Input that the application creates and ignores
        --- this field.
        Options: InputOptions

        --- Read-only. Input updates `mouseX` from the most recent mouse event
        --- and retains it across frames without motion.
        mouseX: number
        --- Read-only. Input updates `mouseY` with `mouseX`.
        mouseY: number
        --- Read-only. Input accumulates `mouseDeltaX` during a frame and clears
        --- it in `beginFrame`.
        mouseDeltaX: number
        --- Read-only. Input accumulates `mouseDeltaY` and clears it with
        --- `mouseDeltaX`.
        mouseDeltaY: number
        --- Read-only. Input accumulates horizontal wheel motion during a frame
        --- and clears it in `beginFrame`. Positive `wheelX` scrolls right.
        wheelX: number
        --- Read-only. Input accumulates vertical wheel motion under the sign
        --- convention above and clears it in `beginFrame`.
        wheelY: number
        --- Read-only. Input accumulates horizontal whole-notch wheel motion
        --- during a frame and clears it in `beginFrame`.
        wheelTicksX: integer
        --- Read-only. Input accumulates vertical whole-notch wheel motion and
        --- clears it with `wheelTicksX`.
        wheelTicksY: integer
        --- Read-only. Input sets `mouseWhich` to the device from the most recent
        --- mouse button, motion or wheel event.
        mouseWhich: number
        --- Read-only. Input sets `mouseSynthetic` when that mouse event came
        --- from the platform's touch or pen translation.
        mouseSynthetic: boolean

        --- Read-only. Input appends committed text during a frame and clears it
        --- in `beginFrame`.
        text: string
        --- Read-only. Input replaces `composition` when the input method edits
        --- uncommitted text and clears it on commit or session stop.
        composition: string
        --- Read-only. Input sets `compositionStart` to the caret offset within
        --- `composition`.
        compositionStart: integer
        --- Read-only. Input sets `compositionLength` to the selected length
        --- within `composition`.
        compositionLength: integer

        --- Read-only. Input updates `penX` from the most recent pen event.
        penX: number
        --- Read-only. Input updates `penY` with `penX`.
        penY: number
        --- Read-only. Input updates `penPressure` from 0 to 1 and clears it when
        --- the pen leaves proximity.
        penPressure: number
        --- Read-only. Input updates `penTiltX` in degrees from upright.
        penTiltX: number
        --- Read-only. Input updates `penTiltY` with `penTiltX`.
        penTiltY: number
        --- Read-only. Input updates `penRotation` in clockwise degrees.
        penRotation: number
        --- Read-only. Input updates `penTouching` on contact and clears it when
        --- the pen leaves proximity.
        penTouching: boolean
        --- Read-only. Input sets `penEraser` when a stroke begins.
        penEraser: boolean
        --- Read-only. Input sets `penWhich` to the most recent pen identity. A
        --- second pen replaces the first pen's state.
        penWhich: number

        _gate: Gate
        _keys: Buttons
        _mouse: Buttons
        --- Modifier mask from the most recent key event, cleared on focus loss
        --- since the platform reports no key-up for a modifier released elsewhere.
        _modifiers: integer
        --- Fingers down, keyed by device and finger together, since a finger id is
        --- only unique within its device.
        _touches: {string: Touch}
        --- The list `touches` hands back, reused rather than rebuilt.
        _touchList: {Touch}
        --- Pads by platform instance id, for routing an event to one.
        _pads: {number: Gamepad}
        --- The same pads in connection order, for iterating and for `gamepads`.
        _padList: {Gamepad}
        --- Scancodes already resolved from a name, since a binding screen asks for
        --- the same names every frame.
        _scancodes: {string: integer}
        --- Platform numbers of the pen axes folded into fields above, resolved
        --- once so an axis event costs comparisons rather than lookups.
        _penPressureAxis: integer
        _penTiltXAxis: integer
        _penTiltYAxis: integer
        _penRotationAxis: integer
        _backend: Backend
        --- The window text input and the cursor modes act on. Nil in a headless
        --- test, where those commands report failure instead.
        _window: loader.CPtr
        --- System cursor this input state owns, or nil while using the platform
        --- default.
        _cursor: loader.CPtr
        --- Layer the text-input session belongs to, or nil when none is running.
        --- Popping that layer stops the session, so a menu takes its IME and its
        --- on-screen keyboard with it.
        _textLayer: Layer
        --- Whether this state started a session, which is separate from whether
        --- it named a layer. A caller must stop a session that names no layer.
        _textStarted: boolean

        --- Stops text input and clears the current composition.
        ---
        --- The layer stack and shutdown path both call this method, so its
        --- declaration sits beside the rest of the text-input contract.
        ---
        --- @return Returns false when no session was running. The method still
        ---     clears composition state, so a teardown may call it
        ---     unconditionally.
        stopTextInput: function(self: Input): boolean

        --- Moves the area a running text session reports after its field scrolls
        --- or its caret moves.
        ---
        --- @param area Input reads this record immediately and does not retain
        ---     it. A later edit has no effect until another call.
        --- @return Returns whether the platform accepted the hint. Text input
        ---     continues when it returns false.
        setTextInputArea: function(self: Input, area: TextArea): boolean

        --- Pushes a layer and returns it.
        ---
        --- A blocking layer moves capture and clears pending edges. A
        --- nonblocking layer observes input without hiding lower layers.
        ---
        --- @param name The caller supplies a diagnostic layer name.
        --- @param blocking The caller passes false for a nonblocking overlay;
        ---     nil and true create a blocking layer.
        --- @return Returns the new layer, which remains caller-owned until
        ---     `popLayer` removes it.
        pushLayer: function(self: Input, name: string, blocking?: boolean): Layer

        --- Removes and returns the top layer.
        ---
        --- The base layer remains in place. Popping the owner of a text-input
        --- session stops that session.
        ---
        --- @return Returns the removed layer, or nil at the base layer.
        popLayer: function(self: Input): Layer

        --- Returns the layer currently on top.
        ---
        --- @return Returns the live layer object. Callers treat its fields as
        ---     read-only.
        topLayer: function(self: Input): Layer

        --- Returns whether a layer may read input.
        ---
        --- @param layer The caller omits this value to test the base layer.
        --- @return Returns false when a blocking layer sits above it.
        canRead: function(self: Input, layer?: Layer): boolean

        --- Engine-owned. Starts a new frame and clears frame-local values.
        ---
        --- The application calls this before it folds events. Ordinary game
        --- code must not call it.
        beginFrame: function(self: Input)

        --- Engine-owned. Selects latched edges for a fixed step.
        ---
        --- The fixed-phase bracket calls this method. Ordinary game code must
        --- not call it.
        enterFixedPhase: function(self: Input)

        --- Engine-owned. Clears latched edges after a fixed step.
        ---
        --- The fixed-phase bracket calls this method. Ordinary game code must
        --- not call it.
        exitFixedPhase: function(self: Input)

        --- Engine-owned. Opens gamepads present at startup.
        ---
        --- The application calls this once before event intake. Ordinary game
        --- code observes the resulting `gamepads` list.
        refreshDevices: function(self: Input)

        --- Returns the live list of connected gamepads.
        ---
        --- @return Returns Input-owned storage. Callers may retain a
        ---     [`Gamepad`](tealdoc:tecs.input.Gamepad) from it but must not edit
        ---     the list.
        gamepads: function(self: Input): {Gamepad}

        --- Returns a connected gamepad by connection order.
        ---
        --- @param index The caller supplies a one-based position, or nil for
        ---     the first gamepad.
        --- @return Returns the gamepad, or nil when the position is empty.
        gamepad: function(self: Input, index: integer): Gamepad

        --- Returns a connected gamepad by platform instance id.
        ---
        --- @param id The caller supplies an id from a platform event.
        --- @return Returns the gamepad, or nil after it disconnects.
        gamepadById: function(self: Input, id: number): Gamepad

        --- Engine-owned. Closes devices and platform input resources.
        ---
        --- The application calls this during shutdown. Ordinary game code must
        --- not call it.
        destroy: function(self: Input)

        --- Engine-owned. Folds one typed platform event into input state.
        ---
        --- The application passes every event here. Input copies every value
        --- it retains. Ordinary game code must not call this method.
        ---
        --- @param event The engine supplies a borrowed event record.
        handleEvent: function(self: Input, event: eventStream.Event)

        --- Resolves and caches a physical key name.
        ---
        --- @param name The caller supplies the platform key name without
        ---     regard to case. An unknown name raises.
        --- @return Returns the platform scancode.
        scancode: function(self: Input, name: string): integer

        --- Returns the platform name for a physical key.
        ---
        --- @param scancode The caller supplies a platform scancode.
        --- @return Returns the display name for a binding prompt.
        keyName: function(self: Input, scancode: integer): string

        --- Returns whether a physical key is held.
        ---
        --- @param key The caller supplies a key name or scancode. An unknown
        ---     name raises.
        --- @param layer The caller omits this value to read the base layer.
        --- @return Returns false when the layer cannot read.
        keyDown: function(self: Input, key: string | integer, layer?: Layer): boolean

        --- Returns whether a physical key went down in the active tier.
        ---
        --- Fixed phases read latched edges; other phases read frame edges.
        ---
        --- @param key The caller supplies a key name or scancode. An unknown
        ---     name raises.
        --- @param layer The caller omits this value to read the base layer.
        --- @return Returns false when the layer cannot read.
        keyPressed: function(self: Input, key: string | integer, layer?: Layer): boolean

        --- Returns whether a physical key came up in the active tier.
        ---
        --- @param key The caller supplies a key name or scancode. An unknown
        ---     name raises.
        --- @param layer The caller omits this value to read the base layer.
        --- @return Returns false when the layer cannot read.
        keyReleased: function(self: Input, key: string | integer, layer?: Layer): boolean

        --- Returns the modifier mask from the most recent key event.
        ---
        --- The value ignores layers and resets on focus loss.
        ---
        --- @return Returns the platform modifier bits.
        modifiers: function(self: Input): integer

        --- Returns whether a named modifier is held.
        ---
        --- @param name The caller supplies `"shift"`, `"ctrl"`, `"alt"`,
        ---     `"gui"`, `"capsLock"` or a sided variant. An unknown name
        ---     raises.
        --- @param layer The caller omits this value to read the base layer.
        --- @return Returns false when the layer cannot read.
        modifierDown: function(self: Input, name: string, layer?: Layer): boolean

        --- Returns whether a mouse button is held.
        ---
        --- @param button The caller supplies a platform number or `"left"`,
        ---     `"middle"`, `"right"`, `"x1"` or `"x2"`.
        --- @param layer The caller omits this value to read the base layer.
        --- @return Returns false when the layer cannot read.
        mouseDown: function(self: Input, button: string | integer, layer?: Layer): boolean

        --- Returns whether a mouse button went down in the active tier.
        ---
        --- @param button The caller supplies a button name or number.
        --- @param layer The caller omits this value to read the base layer.
        --- @return Returns false when the layer cannot read.
        mousePressed: function(self: Input, button: string | integer, layer?: Layer): boolean

        --- Returns whether a mouse button came up in the active tier.
        ---
        --- @param button The caller supplies a button name or number.
        --- @param layer The caller omits this value to read the base layer.
        --- @return Returns false when the layer cannot read.
        mouseReleased: function(self: Input, button: string | integer, layer?: Layer): boolean

        --- Enables or disables relative mouse mode.
        ---
        --- Relative mode hides the cursor, freezes its position and reports
        --- movement through the delta fields.
        ---
        --- @param enabled The caller passes false to disable the mode; nil and
        ---     true enable it.
        --- @return Returns whether the platform accepted the change.
        setRelativeMouseMode: function(self: Input, enabled: boolean): boolean

        --- Returns whether relative mouse mode is active.
        ---
        --- @return Returns live platform state rather than the last request.
        relativeMouseMode: function(self: Input): boolean

        --- Moves the cursor within the window.
        ---
        --- The platform emits a motion event for the warp.
        ---
        --- @param x The caller supplies the window-coordinate x position.
        --- @param y The caller supplies the window-coordinate y position.
        warpMouse: function(self: Input, x: number, y: number)

        --- Enables or disables mouse capture outside the window.
        ---
        --- @param enabled The caller passes false to release capture; nil and
        ---     true enable it.
        --- @return Returns whether the platform accepted the change.
        captureMouse: function(self: Input, enabled: boolean): boolean

        --- Shows or hides the application cursor.
        ---
        --- @param visible The caller passes false to hide the cursor; nil and
        ---     true show it.
        --- @return Returns whether the platform accepted the change.
        showCursor: function(self: Input, visible: boolean): boolean

        --- Returns whether the platform shows the cursor.
        ---
        --- @return Returns live platform state.
        cursorVisible: function(self: Input): boolean

        --- Selects a standard platform cursor.
        ---
        --- Input owns the created cursor and releases it on replacement or
        --- `destroy`.
        ---
        --- @param name The caller omits this value or passes `"default"` to
        ---     restore the platform cursor. An unknown name raises.
        --- @return Returns whether the platform accepted the cursor.
        setCursor: function(self: Input, name?: string): boolean

        --- Returns the fingers currently on the touch surface.
        ---
        --- @param layer The caller omits this value to read the base layer.
        --- @return Returns Input-owned list and records that the next call may
        ---     reuse. Callers copy values they need to retain.
        touches: function(self: Input, layer?: Layer): {Touch}

        --- Starts text input and optionally binds it to a layer.
        ---
        --- Popping the owner layer stops the session.
        ---
        --- @param layer The caller omits this value for a session it will stop
        ---     explicitly.
        --- @param options The caller may supply the edited text area. Input
        ---     reads the record immediately and does not retain it.
        --- @return Returns whether the platform started the session.
        startTextInput: function(self: Input, layer?: Layer, options?: TextOptions): boolean

        --- Returns whether this Input started a text-input session.
        ---
        --- @return Returns false for sessions started outside this object.
        textInputActive: function(self: Input): boolean

        --- Returns the layer that owns the current text-input session.
        ---
        --- @return Returns nil when no layer owns the session.
        textInputLayer: function(self: Input): Layer

        --- Returns whether the platform supplies an on-screen keyboard.
        ---
        --- @return Returns live platform capability state.
        screenKeyboardSupported: function(self: Input): boolean
    end

    --- Read-only. [`Gamepad`](tealdoc:tecs.input.Gamepad) names one attached
    --- device. Ordinary game code gets objects from `Input:gamepads` and does
    --- not replace this module field.
    Gamepad: Gamepad

    --- Identifies a position from `pushLayer`.
    type Layer = Layer
    --- Describes a finger from `touches`.
    type Touch = Touch
    --- Describes a caller-writable text rectangle.
    type TextArea = TextArea
    --- Describes caller-writable text-input options.
    type TextOptions = TextOptions
    --- Describes framework construction options for `Input`.
    type Options = InputOptions
    --- Describes a gamepad touch.
    type TouchpadFinger = Gamepad.TouchpadFinger

    --- Describes an opened standalone sensor.
    type Sensor = sensors.Sensor

    --- Describes an enumerated standalone sensor before open.
    type SensorDevice = sensors.Device

    --- Builds the input state a game reads, with a single base layer.
    ---
    --- Holds no devices yet. `refreshDevices` opens the pads already attached,
    --- and everything after that arrives as events.
    ---
    --- @param options The engine omits this record for a headless state. Keys
    ---     and pads still fold while window commands report failure.
    --- @return Returns the state. The application owns one; a test may build
    ---     another.
    newInput: function(options?: InputOptions): Input

    --- Returns the standalone sensors attached now in platform order.
    ---
    --- A snapshot rather than a subscription: a sensor unplugged after this
    --- leaves an id `openSensor` refuses. Gamepad sensors are not here, since
    --- their identity and event routing live on the pad.
    ---
    --- @return Returns a fresh caller-owned list. It returns an empty list when
    ---     no sensors exist or the subsystem cannot start.
    --- @return Returns the platform's reason when enumeration fails.
    sensors: function(): {sensors.Device}, string

    --- Opens an attached standalone sensor by instance id.
    ---
    --- @param id The caller supplies an instance id from `sensors`. It stops
    ---     naming the device after unplug.
    --- @return Returns the open sensor, or nil on failure. The caller closes it
    ---     with `destroy`.
    --- @return Returns the reason when the first return is nil.
    openSensor: function(id: number): sensors.Sensor, string
end

local type Input = input.Input

local InputMT <const>: metatable<Input> = {__index = Input}

function input.newInput(options?: InputOptions): Input
    local given = options or {} as InputOptions
    local self = setmetatable({} as Input, InputMT)
    self._gate = inputstate.Gate.create()
    self._keys = inputstate.Buttons.create()
    self._mouse = inputstate.Buttons.create()
    self._modifiers = 0
    self._touches = {}
    self._touchList = {}
    self._pads = {}
    self._padList = {}
    self._scancodes = {}
    self._backend = given.backend or adapter.current().input or inputbackend.sdl
    self._penPressureAxis = self._backend.penAxisFromName("pressure")
    self._penTiltXAxis = self._backend.penAxisFromName("tiltX")
    self._penTiltYAxis = self._backend.penAxisFromName("tiltY")
    self._penRotationAxis = self._backend.penAxisFromName("rotation")
    self._window = given.window
    self._textStarted = false
    self.mouseX, self.mouseY = 0.0, 0.0
    self.mouseDeltaX, self.mouseDeltaY = 0.0, 0.0
    self.wheelX, self.wheelY = 0.0, 0.0
    self.wheelTicksX, self.wheelTicksY = 0, 0
    self.mouseWhich = 0
    self.mouseSynthetic = false
    self.text = ""
    self.composition = ""
    self.compositionStart = 0
    self.compositionLength = 0
    self.penX, self.penY, self.penPressure = 0.0, 0.0, 0.0
    self.penTiltX, self.penTiltY, self.penRotation = 0.0, 0.0, 0.0
    self.penTouching = false
    self.penEraser = false
    return self
end

-------------------------------------------------------------------------------
-- Layers
-------------------------------------------------------------------------------

--- Drops every pending edge, on every device, in both tiers.
---
--- An edge belongs to whoever could read input at the moment it happened. A
--- layer on the far side of a capture boundary has no
--- claim on it: an `f` typed into a debug overlay must not toggle the game's
--- fullscreen the instant the overlay closes, and a menu opening mid-frame
--- must not act on a key pressed before it existed.
---
--- The accumulated quantities go with them, because a frame's text, wheel and
--- mouse motion are edges measured over an interval rather than states: a
--- camera handed the motion made inside a menu jumps the frame the menu
--- closes. Held buttons, pointer positions, the modifier mask, fingers down
--- and the pen all survive, because those are states and the platform is still
--- reporting them.
local function clearEdges(self: Input)
    self._keys:clearEdges()
    self._mouse:clearEdges()
    for index = 1, #self._padList do
        self._padList[index]:_clearEdges()
    end
    self.text = ""
    self.mouseDeltaX, self.mouseDeltaY = 0.0, 0.0
    self.wheelX, self.wheelY = 0.0, 0.0
    self.wheelTicksX, self.wheelTicksY = 0, 0
end

function Input:pushLayer(name: string, blocking?: boolean): Layer
    local layer, captureMoved = self._gate:push(name, blocking)
    if captureMoved then
        clearEdges(self)
    end
    return layer
end

function Input:popLayer(): Layer
    local layer, captureMoved = self._gate:pop()
    if layer ~= nil and layer == self._textLayer then
        self:stopTextInput()
    end
    if captureMoved then
        clearEdges(self)
    end
    return layer
end

function Input:topLayer(): Layer
    return self._gate:top()
end

function Input:canRead(layer?: Layer): boolean
    return self._gate:canRead(layer)
end

-------------------------------------------------------------------------------
-- Frame lifecycle
-------------------------------------------------------------------------------

function Input:beginFrame()
    self._keys:beginFrame()
    self._mouse:beginFrame()
    for index = 1, #self._padList do
        self._padList[index]:_beginFrame()
    end
    self.mouseDeltaX, self.mouseDeltaY = 0.0, 0.0
    self.wheelX, self.wheelY = 0.0, 0.0
    self.wheelTicksX, self.wheelTicksY = 0, 0
    self.text = ""
end

function Input:enterFixedPhase()
    self._gate.fixed = true
end

function Input:exitFixedPhase()
    self._gate.fixed = false
    self._keys:exitFixed()
    self._mouse:exitFixed()
    for index = 1, #self._padList do
        self._padList[index]:_exitFixedPhase()
    end
end

-------------------------------------------------------------------------------
-- Devices
-------------------------------------------------------------------------------

--- Opens a device the platform has just reported, or reports it again.
local function connect(self: Input, id: number)
    if self._pads[id] ~= nil then
        return
    end
    local pad = Gamepad.openGamepad(self._backend, self._gate, id)
    if pad == nil then
        return
    end
    self._pads[id] = pad
    self._padList[#self._padList + 1] = pad
end

local function disconnect(self: Input, id: number)
    local pad = self._pads[id]
    if pad == nil then
        return
    end
    self._pads[id] = nil
    for index = 1, #self._padList do
        if self._padList[index] == pad then
            table.remove(self._padList, index)
            break
        end
    end
    pad:_disconnect()
end

function Input:refreshDevices()
    local attached = self._backend.attachedGamepads()
    local present: {number: boolean} = {}
    for index = 1, #attached do
        present[attached[index]] = true
        connect(self, attached[index])
    end

    -- Copy first because disconnecting rewrites the list under iteration.
    local known: {number} = {}
    for index = 1, #self._padList do
        known[index] = self._padList[index].id
    end
    for index = 1, #known do
        if not present[known[index]] then
            disconnect(self, known[index])
        end
    end
end

function Input:gamepads(): {Gamepad}
    return self._padList
end

function Input:gamepad(index: integer): Gamepad
    return self._padList[index or 1]
end

function Input:gamepadById(id: number): Gamepad
    return self._pads[id]
end

function Input:destroy()
    local pads = self._padList
    self._padList = {}
    self._pads = {}
    for index = 1, #pads do
        pads[index]:_disconnect()
    end
    if self._textStarted then
        self:stopTextInput()
    end
    if self._cursor ~= nil then
        self._backend.setCursor(self._backend.defaultCursor())
        self._backend.destroyCursor(self._cursor)
        self._cursor = nil
    end
end

-------------------------------------------------------------------------------
-- Event intake
-------------------------------------------------------------------------------

--- Releases everything held.
---
--- The platform sends no release for a key held as the window loses focus.
--- Release it here so it does not read as held until the
--- player presses it again somewhere the application can see.
local function releaseHeld(self: Input)
    self._keys:releaseAll()
    self._mouse:releaseAll()
    self._modifiers = 0
    for index = 1, #self._padList do
        self._padList[index]:_releaseHeld()
    end
    for key in pairs(self._touches) do
        self._touches[key] = nil
    end
    self.penTouching = false
    self.penPressure = 0.0
end

local function touchKey(event: eventStream.Event): string
    return (event.touchDevice or "") .. ":" .. (event.finger or "")
end

function Input:handleEvent(event: eventStream.Event)
    local kind = event.kind

    if kind == "keyDown" then
        self._modifiers = event.modifiers or self._modifiers
        -- A repeat is not a press: holding a key must not read as pressing it
        -- many times.
        if not event.repeated then
            self._keys:press(event.scancode)
        end
    elseif kind == "keyUp" then
        self._modifiers = event.modifiers or self._modifiers
        self._keys:release(event.scancode)
    elseif kind == "mouseDown" then
        self.mouseWhich = event.which
        self.mouseSynthetic = event.synthetic == true
        self._mouse:press(event.button)
    elseif kind == "mouseUp" then
        self.mouseWhich = event.which
        self.mouseSynthetic = event.synthetic == true
        self._mouse:release(event.button)
    elseif kind == "mouseMotion" then
        self.mouseWhich = event.which
        self.mouseSynthetic = event.synthetic == true
        self.mouseX = event.x
        self.mouseY = event.y
        self.mouseDeltaX = self.mouseDeltaX + event.dx
        self.mouseDeltaY = self.mouseDeltaY + event.dy
    elseif kind == "mouseWheel" then
        -- The wheel says which device it came from like every other mouse
        -- event, and a scroll the platform made out of a touch is exactly what
        -- these two fields exist to let a game recognize.
        self.mouseWhich = event.which
        self.mouseSynthetic = event.synthetic == true
        self.wheelX = self.wheelX + event.wheelX
        self.wheelY = self.wheelY + event.wheelY
        -- A replay event carries only the recorded values, so a stream from
        -- before the whole-notch pair existed adds nothing rather than
        -- failing.
        self.wheelTicksX = self.wheelTicksX + (event.wheelTicksX or 0)
        self.wheelTicksY = self.wheelTicksY + (event.wheelTicksY or 0)
    elseif kind == "fingerDown" or kind == "fingerMotion" then
        local key = touchKey(event)
        local touch = self._touches[key]
        if touch == nil then
            touch = {device = event.touchDevice, finger = event.finger} as Touch
            self._touches[key] = touch
        end
        touch.x, touch.y = event.x, event.y
        touch.normalX, touch.normalY = event.normalX, event.normalY
        touch.pressure = event.pressure
    elseif kind == "fingerUp" or kind == "fingerCanceled" then
        self._touches[touchKey(event)] = nil
    elseif kind == "penMotion" then
        self.penWhich = event.which
        self.penX, self.penY = event.x, event.y
    elseif kind == "penAxis" then
        self.penWhich = event.which
        self.penX, self.penY = event.x, event.y
        -- One axis per event, so the value belongs to whichever field this
        -- axis names. An axis with no field here is a reading nothing reads.
        local axis = event.axis
        if axis == self._penPressureAxis then
            self.penPressure = event.value
        elseif axis == self._penTiltXAxis then
            self.penTiltX = event.value
        elseif axis == self._penTiltYAxis then
            self.penTiltY = event.value
        elseif axis == self._penRotationAxis then
            self.penRotation = event.value
        end
    elseif kind == "penDown" or kind == "penUp" then
        self.penWhich = event.which
        self.penX, self.penY = event.x, event.y
        self.penTouching = kind == "penDown"
        self.penEraser = event.eraser == true
    elseif kind == "penProximityOut" then
        -- A pen out of range is pressing on nothing, and the pressure it
        -- reported last would otherwise read as a stroke still under way.
        self.penTouching = false
        self.penPressure = 0.0
    elseif kind == "textInput" then
        self.text = self.text .. (event.text or "")
        -- Committing ends the current composition, so a field does not
        -- draw the composition twice.
        self.composition = ""
        self.compositionStart = 0
        self.compositionLength = 0
    elseif kind == "textEditing" then
        self.composition = event.text or ""
        self.compositionStart = event.start or 0
        self.compositionLength = event.length or 0
    elseif kind == "gamepadAdded" then
        connect(self, event.which)
    elseif kind == "gamepadRemoved" then
        disconnect(self, event.which)
    elseif kind == "gamepadRemapped" then
        local pad = self._pads[event.which]
        if pad ~= nil then
            pad:_readInfo()
        end
    elseif kind == "gamepadButtonDown" then
        local pad = self._pads[event.which]
        if pad ~= nil then
            pad:_press(event.button)
        end
    elseif kind == "gamepadButtonUp" then
        local pad = self._pads[event.which]
        if pad ~= nil then
            pad:_release(event.button)
        end
    elseif kind == "gamepadAxis" then
        local pad = self._pads[event.which]
        if pad ~= nil then
            pad:_setAxis(event.axis, event.value)
        end
    elseif kind == "gamepadSensor" then
        local pad = self._pads[event.which]
        if pad ~= nil then
            pad:_setSensor(event.sensor, event.sensorX, event.sensorY, event.sensorZ)
        end
    elseif kind == "gamepadTouchpadDown" or kind == "gamepadTouchpadUp" or kind == "gamepadTouchpadMotion" then
        local pad = self._pads[event.which]
        if pad ~= nil then
            pad:_setFinger(
                event.touchpad, event.fingerIndex, event.normalX, event.normalY, event.pressure, event.down == true
            )
        end
    elseif kind == "windowFocusLost" then
        releaseHeld(self)
    end
end

-------------------------------------------------------------------------------
-- Keyboard
-------------------------------------------------------------------------------

function Input:scancode(name: string): integer
    local cached = self._scancodes[name]
    if cached ~= nil then
        return cached
    end

    local code = self._backend.scancodeFromName(name)
    if code == 0 then
        local titled = name:gsub(
            "(%a)([%w']*)", function(head: string, tail: string): string return head:upper() .. tail:lower() end
        )
        code = self._backend.scancodeFromName(titled)
    end
    if code == 0 then
        error(("tecs: no key named '%s'"):format(name), 2)
    end
    self._scancodes[name] = code
    return code
end

function Input:keyName(scancode: integer): string
    return self._backend.scancodeName(scancode)
end

local function resolveKey(self: Input, key: string | integer): integer
    if key is string then
        return self:scancode(key)
    end
    return key
end

function Input:keyDown(key: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    return self._keys.down[resolveKey(self, key)] == true
end

function Input:keyPressed(key: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    return self._keys:edges(self._gate.fixed, false)[resolveKey(self, key)] == true
end

function Input:keyReleased(key: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    return self._keys:edges(self._gate.fixed, true)[resolveKey(self, key)] == true
end

function Input:modifiers(): integer
    return self._modifiers
end

function Input:modifierDown(name: string, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    local mask = self._backend.modifierFromName(name)
    if mask == nil then
        error(("tecs: no modifier named '%s'"):format(name), 2)
    end
    return bit.band(self._modifiers, mask) ~= 0
end

-------------------------------------------------------------------------------
-- Mouse
-------------------------------------------------------------------------------

local function resolveMouse(self: Input, button: string | integer): integer
    if button is string then
        local code = self._backend.mouseButtonFromName(button)
        if code == nil then
            error(("tecs: no mouse button named '%s'"):format(button), 3)
        end
        return code
    end
    return button
end

function Input:mouseDown(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    return self._mouse.down[resolveMouse(self, button)] == true
end

function Input:mousePressed(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    return self._mouse:edges(self._gate.fixed, false)[resolveMouse(self, button)] == true
end

function Input:mouseReleased(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    return self._mouse:edges(self._gate.fixed, true)[resolveMouse(self, button)] == true
end

function Input:setRelativeMouseMode(enabled: boolean): boolean
    return self._backend.setRelativeMouseMode(self._window, enabled ~= false)
end

function Input:relativeMouseMode(): boolean
    return self._backend.relativeMouseMode(self._window)
end

function Input:warpMouse(x: number, y: number)
    self._backend.warpMouse(self._window, x, y)
end

function Input:captureMouse(enabled: boolean): boolean
    return self._backend.captureMouse(enabled ~= false)
end

function Input:showCursor(visible: boolean): boolean
    return self._backend.showCursor(visible ~= false)
end

function Input:cursorVisible(): boolean
    return self._backend.cursorVisible()
end

function Input:setCursor(name?: string): boolean
    local previous = self._cursor
    if name == nil or name == "default" then
        if not self._backend.setCursor(self._backend.defaultCursor()) then
            return false
        end
        self._cursor = nil
        if previous ~= nil then
            self._backend.destroyCursor(previous)
        end
        return true
    end

    local cursor = self._backend.createSystemCursor(name)
    if cursor == nil then
        error(("tecs: unknown or unavailable system cursor %q"):format(name), 2)
    end
    if not self._backend.setCursor(cursor) then
        self._backend.destroyCursor(cursor)
        return false
    end
    self._cursor = cursor
    if previous ~= nil then
        self._backend.destroyCursor(previous)
    end
    return true
end

-------------------------------------------------------------------------------
-- Touch
-------------------------------------------------------------------------------

function Input:touches(layer?: Layer): {Touch}
    local out = self._touchList
    for index = #out, 1, -1 do
        out[index] = nil
    end
    if not self._gate:canRead(layer) then
        return out
    end
    for _, touch in pairs(self._touches) do
        out[#out + 1] = touch
    end
    return out
end

-------------------------------------------------------------------------------
-- Text input
-------------------------------------------------------------------------------

function Input:startTextInput(layer?: Layer, options?: TextOptions): boolean
    if not self._backend.startTextInput(self._window) then
        return false
    end
    self._textStarted = true
    self._textLayer = layer
    local area = options ~= nil and options.area or nil
    if area ~= nil then
        self:setTextInputArea(area)
    end
    return true
end

function Input:stopTextInput(): boolean
    self._textLayer = nil
    self.composition = ""
    self.compositionStart = 0
    self.compositionLength = 0
    if not self._textStarted then
        return false
    end
    self._textStarted = false
    return self._backend.stopTextInput(self._window)
end

function Input:textInputActive(): boolean
    return self._textStarted
end

function Input:textInputLayer(): Layer
    return self._textLayer
end

function Input:setTextInputArea(area: TextArea): boolean
    return self._backend.setTextInputArea(self._window, area.x, area.y, area.width, area.height, area.cursor or 0)
end

function Input:screenKeyboardSupported(): boolean
    return self._backend.screenKeyboardSupported()
end

input.Gamepad = Gamepad

-- The standalone sensors, under this module's public names. `sensors.tl` is
-- the seam and reaches only SDL; `tecs.input` is the surface, the way
-- `tecs.filesystem` publishes what `platform/content.tl` holds.
input.sensors = sensors.sensors
input.openSensor = sensors.openSensor

return input
