--- Gameplay input, in three tiers, behind a layer stack.
---
--- SDL owns device mechanics; this owns gameplay semantics. That split is why
--- there is no `tecs.keyboard` beside it and no supported way to reach raw
--- SDL: a query answered by polling the device would bypass replay, layers,
--- edge detection and latching, all of which live here.
---
--- Live state answers "is it held". Frame events answer "did it change this
--- frame". Latched events answer the same question for fixed-step systems,
--- which is not the same question: a key pressed and released between two
--- fixed steps is invisible to frame events, and dropping it produces input
--- loss that is nondeterministic and so effectively unreproducible. Latched
--- sets accumulate across every frame since the last fixed step and clear when
--- it ends.
---
--- Queries are answered relative to a layer. A layer that blocks hides input
--- from everything beneath it, so a menu suppresses gameplay without gameplay
--- code knowing a menu exists. Code that names no layer reads the base layer,
--- which is the safe default: it goes quiet when anything is pushed over it.
---
--- A gamepad is not part of this object. It has identity, a lifetime, metadata
--- and outputs, so it is reached through `gamepads()` and answers for itself.
--- What is here is what the machine has one of: a keyboard, an aggregate
--- mouse, the touch surface, the pen, and the registry the pads live in.
---
--- The state is fed typed events and holds no globals, so a recorded session
--- replays by feeding the same events back. It never sees an `SDL_Event`: the
--- conversion happens once, in `events`, and everything downstream shares that
--- one vocabulary. Every outbound command goes through a backend for the same
--- reason, so a platform that is not SDL substitutes one object.

local bit <const> = require("bit")
local eventStream <const> = require("tecs.platform.events")
local inputstate <const> = require("tecs.platform.inputstate")
local inputbackend <const> = require("tecs.platform.inputbackend")
local adapter <const> = require("tecs.platform.adapter")
local Gamepad <const> = require("tecs.platform.Gamepad")
local loader <const> = require("tecs.ffi.loader")

local type Layer = inputstate.Layer
local type Buttons = inputstate.Buttons
local type Gate = inputstate.Gate
local type Backend = inputbackend.Backend

--- One finger on the touch surface. Positions are the platform's own 0..1
--- across the window, plus the window coordinates they convert to.
local record Touch
    --- Touch device the finger belongs to, as an opaque identity.
    device: string
    --- Finger identity, as an opaque identity. A finger id is 64 bits and does
    --- not fit a double.
    finger: string
    --- Position in window coordinates, converted from the normalised pair by
    --- the window size `events.setTouchScale` was last told about. Stale by
    --- one frame if the window resized without that being updated.
    x: number
    y: number
    --- Position as the platform reported it, in 0..1 across the window. This
    --- is the pair that survives a resize.
    normalX: number
    normalY: number
    --- How hard, in 0..1, on a surface that measures it.
    pressure: number
end

--- Where the text being edited sits, so the platform can place its candidate
--- window and its on-screen keyboard clear of it.
local record TextArea
    --- The rectangle's top-left, in window coordinates.
    x: integer
    y: integer
    --- Its extent, which the platform reads as the run of text to keep clear
    --- of rather than as the whole field.
    width: integer
    height: integer
    --- Caret offset from the left of the rectangle. Zero when omitted.
    cursor: integer
end

local record TextOptions
    --- Where the edited text sits. Optional, and worth giving whenever there
    --- is one: without it the platform places its candidate window and its own
    --- keyboard wherever it likes, which is often over what is being typed.
    area: TextArea
end

local record InputOptions
    --- Platform window handle, which text input and the cursor modes act on.
    --- Omitting it leaves those commands reporting failure, which is what a
    --- headless test wants.
    window: loader.CPtr
    --- Backend to issue commands through. Defaults to the installed platform's.
    backend: Backend
end

local record Input
    --- A position in the layer stack, from `pushLayer`.
    Layer: Layer
    --- One finger on the touch surface, as `touches` reports it.
    Touch: Touch
    --- Where edited text sits, for `setTextInputArea`.
    TextArea: TextArea
    --- What `startTextInput` takes besides a layer.
    TextOptions: TextOptions
    --- What `create` takes.
    Options: InputOptions

    --- Mouse position in window coordinates, from the top-left. The last
    --- position reported, so it persists across frames that saw no motion.
    mouseX: number
    mouseY: number
    --- Mouse motion accumulated this frame, summed over every motion event and
    --- cleared by `beginFrame`. Under relative mouse mode this is the whole of
    --- what the mouse said, since the position stops moving.
    mouseDeltaX: number
    mouseDeltaY: number
    --- Wheel movement accumulated this frame, in the platform's own notches
    --- rather than pixels. Cleared by `beginFrame`.
    ---
    --- One sign whatever the machine is set to: positive `wheelY` is a scroll
    --- away from the player, positive `wheelX` a scroll to the right. A
    --- platform with natural scrolling on reports the opposite pair and says
    --- so, and the conversion in `events` puts it back, so a binding written
    --- against these fields does not invert on somebody else's desk.
    wheelX: number
    wheelY: number
    --- The same movement accumulated to whole notches by the platform, on the
    --- same sign convention and cleared by `beginFrame` alongside the pair
    --- above. What a menu stepping one item per notch reads, rather than
    --- picking its own threshold on the fractional pair.
    wheelTicksX: integer
    wheelTicksY: integer
    --- Device that produced the most recent mouse button, motion or wheel
    --- event.
    mouseWhich: number
    --- Whether that event was the platform's own translation of a touch or a
    --- pen. A game that handles touch itself reads this and ignores the
    --- duplicate rather than acting on one gesture twice.
    mouseSynthetic: boolean

    --- Text committed this frame, from the text input events. Empty when
    --- nothing was typed, so it can be appended without a nil check.
    text: string
    --- Text an input method is composing and has not committed. Empty when
    --- nothing is being composed. A field is drawn as its own content plus
    --- this, so the player sees what they are typing before it commits.
    composition: string
    --- Caret offset and selection length within `composition`, in the units
    --- the platform counts it in. Both zero when nothing is being composed.
    compositionStart: integer
    compositionLength: integer

    --- Pen position in window coordinates, from the top-left.
    penX: number
    penY: number
    --- How hard the pen is pressed, in 0..1. Zero until the pen reports it,
    --- and on a pen that measures no pressure it stays there.
    penPressure: number
    --- How far the pen leans from upright, in degrees, negative towards the
    --- left and towards the top of the surface. Both zero on a pen that does
    --- not report tilt.
    penTiltX: number
    penTiltY: number
    --- Barrel rotation in degrees clockwise, for a pen with a chisel nib. Zero
    --- on a pen that does not report it.
    penRotation: number
    --- Whether the pen is touching the surface. Cleared when the pen leaves
    --- proximity, since a pen carried away never reports lifting.
    penTouching: boolean
    --- Whether the end in use is the eraser. Read at the moment the pen went
    --- down, so it describes the current stroke.
    penEraser: boolean
    --- Pen the state describes, or nil when no pen has been seen. One pen's
    --- state is kept, not one per device: a second pen overwrites the first.
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
    --- Whether this state started a session, which is separate from whether it
    --- named a layer: a session started without one runs until it is stopped
    --- by hand.
    _textStarted: boolean

    --- Stops text input and clears whatever was being composed.
    ---
    --- Declared here because the layer stack and the shutdown path both stop a
    --- session, and both read better above where text input is defined.
    ---
    --- @return False when no session was running, in which case the composition
    ---     state is cleared anyway, so this is safe to call unconditionally on
    ---     a teardown path.
    stopTextInput: function(self: Input): boolean

    --- Moves the area a running text session reports, for a field that scrolls
    --- or a caret that moved since `startTextInput` was given one.
    ---
    --- @param area Read here and not retained, so a later edit to the same
    ---     table has no effect until this is called again.
    --- @return Whatever the platform answered. False is not worth acting on:
    ---     the area is a hint, and text input keeps working without it.
    setTextInputArea: function(self: Input, area: TextArea): boolean
end

local InputMT <const>: metatable<Input> = {__index = Input}

--- Creates an input state with a single base layer.
---
--- Holds no devices yet. `refreshDevices` opens the pads that are already
--- attached, and everything after that arrives as events.
function Input.create(options?: InputOptions): Input
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
--- What a capture boundary needs. An edge belongs to whoever could read input
--- at the moment it happened, and a layer on the far side of a boundary has no
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

--- Pushes a layer and returns it.
---
--- A blocking layer hides input from everything beneath. Pass
--- `blocking = false` for an overlay that observes without consuming.
---
--- A layer that blocks moves capture, so the pending edges are dropped: what
--- was pressed before the layer existed is not the layer's to act on. An
--- overlay that consumes nothing moves no capture and drops nothing.
function Input:pushLayer(name: string, blocking?: boolean): Layer
    local layer, captureMoved = self._gate:push(name, blocking)
    if captureMoved then
        clearEdges(self)
    end
    return layer
end

--- Removes the topmost layer. The base layer is never removed.
---
--- A text-input session started by that layer stops with it, because a menu
--- that closed and left the on-screen keyboard up is a bug the game would have
--- to remember to avoid. The pending edges go the same way when the layer was
--- blocking, so what was typed into it stays in it.
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

--- The layer currently on top.
function Input:topLayer(): Layer
    return self._gate:top()
end

--- Whether `layer` may read input. Omitting a layer means the base layer.
function Input:canRead(layer?: Layer): boolean
    return self._gate:canRead(layer)
end

-------------------------------------------------------------------------------
-- Frame lifecycle
-------------------------------------------------------------------------------

--- Clears per-frame state. Call once before polling events for a frame.
---
--- Drops the frame edges, the accumulated motion and wheel, and the committed
--- text. Held keys and buttons, the pointer positions and the latched edges
--- all survive: holding is not an edge, and a latched edge belongs to the
--- fixed step rather than to the frame.
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

--- Switches queries to the latched sets for the duration of a fixed step.
---
--- Every device answers from the latched sets while this is on, since the gate
--- is shared. Nested steps are not tracked: the flag is set, not counted.
function Input:enterFixedPhase()
    self._gate.fixed = true
end

--- Ends the fixed phase and clears what it consumed.
---
--- Brackets one step, not one frame. The latched edges are cleared here, so a
--- press is delivered to the first step that runs after it and to that one
--- only, whether the frame ran one step or four.
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
    local pad = Gamepad.open(self._backend, self._gate, id)
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

--- Opens every gamepad already attached.
---
--- Run before a game's own load, so a pad that was plugged in when the process
--- started is there when the game asks. Safe to call again: a device already
--- open is left alone, and one that went away without an event is closed.
function Input:refreshDevices()
    local attached = self._backend.attachedGamepads()
    local present: {number: boolean} = {}
    for index = 1, #attached do
        present[attached[index]] = true
        connect(self, attached[index])
    end

    -- Copied first, since disconnecting rewrites the list being walked.
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

--- Every connected gamepad, in the order the platform reported them.
---
--- The list is the live one, so a pad that disconnects leaves it. A reference
--- taken out of it stays valid and answers as disconnected.
function Input:gamepads(): {Gamepad}
    return self._padList
end

--- The nth connected gamepad, or nil.
---
--- Position in the list, not a player slot: a pad's index moves when one
--- before it disconnects. Match on `guid` or hold the object to follow a
--- particular device.
function Input:gamepad(index: integer): Gamepad
    return self._padList[index or 1]
end

--- A gamepad by platform instance id, or nil when it is not connected.
---
--- Ids are not reused while a device is attached and say nothing once it is
--- gone, so this is for routing an event that carries one rather than for
--- remembering a pad across a reconnect.
function Input:gamepadById(id: number): Gamepad
    return self._pads[id]
end

--- Closes every open device. Called when the application shuts down.
---
--- Stops a running text-input session too, since the platform would otherwise
--- be left composing for a window that is about to go away.
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
--- What focus loss needs. The platform delivers no release for a key held as
--- the window loses focus, so without this the key reads as held until the
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

--- Folds one typed event into the state.
---
--- Unrecognised kinds are ignored, so this can be handed the whole stream.
---
--- Nothing is retained: every field the state keeps is copied out here, so the
--- caller is free to reuse the record, which the converter does.
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
        -- these two fields exist to let a game recognise.
        self.mouseWhich = event.which
        self.mouseSynthetic = event.synthetic == true
        self.wheelX = self.wheelX + event.wheelX
        self.wheelY = self.wheelY + event.wheelY
        -- A replayed event carries only what was recorded, so a stream from
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
        -- Committing ends whatever was being composed, so a field does not
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

--- Resolves a key name to a scancode, caching the lookup.
---
--- Names are the platform's ("Space", "Left Shift"), matched case-insensitively
--- so "space" and "left shift" work too.
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

--- The name of a physical key, for showing a binding back to the player.
---
--- The platform's own name for the position, which is not the character the
--- player's layout produces there: the key `scancode("Q")` names is labelled Q
--- whatever a French keyboard prints on it.
function Input:keyName(scancode: integer): string
    return self._backend.scancodeName(scancode)
end

local function resolveKey(self: Input, key: string | integer): integer
    if key is string then
        return self:scancode(key)
    end
    return key
end

--- Whether a key is held. Keys are identified by physical position, so a
--- movement binding stays where it is on every layout.
function Input:keyDown(key: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    return self._keys.down[resolveKey(self, key)] == true
end

--- Whether a key went down. Reads the latched set inside a fixed step.
function Input:keyPressed(key: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    return self._keys:edges(self._gate.fixed, false)[resolveKey(self, key)] == true
end

--- Whether a key came up, on the same tiers as `keyPressed`.
function Input:keyReleased(key: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    return self._keys:edges(self._gate.fixed, true)[resolveKey(self, key)] == true
end

--- The modifier mask reported with the most recent key event.
---
--- Not gated by a layer, and only as fresh as the last key event: a modifier
--- pressed on its own does produce one, but a modifier state that changed
--- while the window was not focused is not seen. Focus loss zeroes it for that
--- reason. `modifierDown` is the gated form and reads the same mask.
function Input:modifiers(): integer
    return self._modifiers
end

--- Whether a modifier is held: "shift", "ctrl", "alt", "gui", "capsLock".
---
--- Either side counts for the unsided names, and "leftShift" asks for one.
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

--- Whether a mouse button is held. Names are "left", "middle", "right", "x1",
--- "x2".
function Input:mouseDown(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    return self._mouse.down[resolveMouse(self, button)] == true
end

--- Whether a mouse button went down. Reads the latched set inside a fixed
--- step, on the same tiers as `keyPressed`.
function Input:mousePressed(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    return self._mouse:edges(self._gate.fixed, false)[resolveMouse(self, button)] == true
end

--- Whether a mouse button came up, on the same tiers as `mousePressed`.
function Input:mouseReleased(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then
        return false
    end
    return self._mouse:edges(self._gate.fixed, true)[resolveMouse(self, button)] == true
end

--- Hides the cursor and delivers motion as deltas only, for a game that turns
--- the view with the mouse.
---
--- `mouseX` and `mouseY` stop moving while this is on, since there is no
--- cursor to report a position for; `mouseDeltaX` and `mouseDeltaY` carry the
--- whole of what the mouse said. False without a window, which is what a
--- headless test gets.
--- @param enabled Anything but false turns it on, so calling with nothing on
---     is enabling it.
function Input:setRelativeMouseMode(enabled: boolean): boolean
    return self._backend.setRelativeMouseMode(self._window, enabled ~= false)
end

--- Whether relative mouse mode is on, asked of the platform rather than
--- remembered, so a mode the window lost reports honestly.
function Input:relativeMouseMode(): boolean
    return self._backend.relativeMouseMode(self._window)
end

--- Moves the cursor within the window, in window coordinates.
---
--- Produces a motion event like any other, so `mouseDeltaX` and `mouseDeltaY`
--- pick the jump up. A game recentring the cursor every frame reads its own
--- warp as input unless it accounts for it.
function Input:warpMouse(x: number, y: number)
    self._backend.warpMouse(self._window, x, y)
end

--- Keeps delivering mouse events while a button is held outside the window,
--- which is what a drag that leaves the window needs.
---
--- Applies to the application rather than to a window, so this is the one
--- cursor command that works without one.
function Input:captureMouse(enabled: boolean): boolean
    return self._backend.captureMouse(enabled ~= false)
end

--- Shows or hides the cursor, for the application rather than one window.
---
--- Independent of relative mouse mode, which hides the cursor for the duration
--- on its own: leaving this alone is the usual thing.
function Input:showCursor(visible: boolean): boolean
    return self._backend.showCursor(visible ~= false)
end

--- Whether the cursor is being shown, asked of the platform.
function Input:cursorVisible(): boolean
    return self._backend.cursorVisible()
end

--- Selects one of the platform's standard cursor shapes.
---
--- Pass nil or `"default"` to restore the platform default. The other names
--- are `"text"`, `"wait"`, `"crosshair"`, `"progress"`, `"pointer"`,
--- `"move"`, `"notAllowed"` and the eight compass resize cursors such as
--- `"ewResize"` and `"nwseResize"`.
---
--- The cursor is owned by this input state and released when it is replaced or
--- when `destroy` runs.
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

--- Fingers currently on the touch surface.
---
--- The list and the records in it are reused between calls, so anything
--- retaining one has to copy it.
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

--- Starts text input, bound to a layer.
---
--- Off until asked for, because a platform that is composing text is one whose
--- key events a game must not also read as bindings, and because on a phone it
--- puts a keyboard over half the screen. Binding the session to a layer is
--- what makes stopping it reliable: popping the layer stops the session, so
--- the case nobody remembers to handle is handled.
---
--- Pass an area whenever there is one. The platform places its candidate
--- window and its own keyboard clear of the rectangle, and without one they
--- land over what the player is typing.
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

--- Whether a text-input session is running.
---
--- What this state started, not what the platform is doing: a session started
--- outside the engine is not visible here.
function Input:textInputActive(): boolean
    return self._textStarted
end

--- The layer the running session belongs to, or nil.
---
--- Nil both when no session is running and when one was started without naming
--- a layer, which is a session nothing will stop on its own.
function Input:textInputLayer(): Layer
    return self._textLayer
end

--- Tells the platform where the edited text sits, in window coordinates.
---
--- Worth calling as the caret moves, not only at the start: the platform
--- places its candidate window against the most recent rectangle it was given.
function Input:setTextInputArea(area: TextArea): boolean
    return self._backend.setTextInputArea(self._window, area.x, area.y, area.width, area.height, area.cursor or 0)
end

--- Whether the platform puts a keyboard on the screen for text input.
---
--- What a layout has to know: where this is true, starting text input covers
--- part of the window, and the area given to `startTextInput` is what keeps
--- the field out from under it.
function Input:screenKeyboardSupported(): boolean
    return self._backend.screenKeyboardSupported()
end

return Input
