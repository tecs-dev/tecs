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
    x: number
    y: number
    normalX: number
    normalY: number
    pressure: number
end

--- Where the text being edited sits, so the platform can place its candidate
--- window and its on-screen keyboard clear of it.
local record TextArea
    x: integer
    y: integer
    width: integer
    height: integer
    --- Caret offset from the left of the rectangle. Zero when omitted.
    cursor: integer
end

local record TextOptions
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
    Layer: Layer
    Touch: Touch
    TextArea: TextArea
    TextOptions: TextOptions
    Options: InputOptions

    --- Mouse position in window coordinates.
    mouseX: number
    mouseY: number
    --- Mouse motion accumulated this frame.
    mouseDeltaX: number
    mouseDeltaY: number
    --- Wheel movement accumulated this frame.
    wheelX: number
    wheelY: number
    --- Device that produced the most recent mouse event.
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
    --- Caret and selection within `composition`.
    compositionStart: integer
    compositionLength: integer

    --- Pen position in window coordinates, and what the pen is doing.
    penX: number
    penY: number
    penPressure: number
    --- Whether the pen is touching the surface.
    penTouching: boolean
    --- Whether the end in use is the eraser.
    penEraser: boolean
    --- Pen the state describes, or nil when no pen has been seen.
    penWhich: number

    _gate: Gate
    _keys: Buttons
    _mouse: Buttons
    _modifiers: integer
    _touches: {string: Touch}
    _touchList: {Touch}
    _pads: {number: Gamepad}
    _padList: {Gamepad}
    _scancodes: {string: integer}
    _backend: Backend
    _window: loader.CPtr
    --- Layer the text-input session belongs to, or nil when none is running.
    --- Popping that layer stops the session, so a menu takes its IME and its
    --- on-screen keyboard with it.
    _textLayer: Layer
    _textStarted: boolean

    --- Declared here because the layer stack and the shutdown path both stop a
    --- session, and both read better above where text input is defined.
    stopTextInput: function(self: Input): boolean
    setTextInputArea: function(self: Input, area: TextArea): boolean
end

local InputMT <const>: metatable<Input> = { __index = Input }

--- Creates an input state with a single base layer.
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
    self._window = given.window
    self._textStarted = false
    self.mouseX, self.mouseY = 0.0, 0.0
    self.mouseDeltaX, self.mouseDeltaY = 0.0, 0.0
    self.wheelX, self.wheelY = 0.0, 0.0
    self.mouseWhich = 0
    self.mouseSynthetic = false
    self.text = ""
    self.composition = ""
    self.compositionStart = 0
    self.compositionLength = 0
    self.penX, self.penY, self.penPressure = 0.0, 0.0, 0.0
    self.penTouching = false
    self.penEraser = false
    return self
end

-------------------------------------------------------------------------------
-- Layers
-------------------------------------------------------------------------------

--- Pushes a layer and returns it.
---
--- A blocking layer hides input from everything beneath. Pass
--- `blocking = false` for an overlay that observes without consuming.
function Input:pushLayer(name: string, blocking?: boolean): Layer
    return self._gate:push(name, blocking)
end

--- Removes the topmost layer. The base layer is never removed.
---
--- A text-input session started by that layer stops with it, because a menu
--- that closed and left the on-screen keyboard up is a bug the game would have
--- to remember to avoid.
function Input:popLayer(): Layer
    local layer = self._gate:pop()
    if layer ~= nil and layer == self._textLayer then
        self:stopTextInput()
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
function Input:beginFrame()
    self._keys:beginFrame()
    self._mouse:beginFrame()
    for index = 1, #self._padList do
        self._padList[index]:_beginFrame()
    end
    self.mouseDeltaX, self.mouseDeltaY = 0.0, 0.0
    self.wheelX, self.wheelY = 0.0, 0.0
    self.text = ""
end

--- Switches queries to the latched sets for the duration of a fixed step.
function Input:enterFixedPhase()
    self._gate.fixed = true
end

--- Ends the fixed phase and clears what it consumed.
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
    if self._pads[id] ~= nil then return end
    local pad = Gamepad.open(self._backend, self._gate, id)
    if pad == nil then return end
    self._pads[id] = pad
    self._padList[#self._padList + 1] = pad
end

local function disconnect(self: Input, id: number)
    local pad = self._pads[id]
    if pad == nil then return end
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
        if not present[known[index]] then disconnect(self, known[index]) end
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
function Input:gamepad(index: integer): Gamepad
    return self._padList[index or 1]
end

--- A gamepad by platform instance id, or nil when it is not connected.
function Input:gamepadById(id: number): Gamepad
    return self._pads[id]
end

--- Closes every open device. Called when the application shuts down.
function Input:destroy()
    local pads = self._padList
    self._padList = {}
    self._pads = {}
    for index = 1, #pads do pads[index]:_disconnect() end
    if self._textStarted then self:stopTextInput() end
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
    for key in pairs(self._touches) do self._touches[key] = nil end
    self.penTouching = false
end

local function touchKey(event: eventStream.Event): string
    return (event.touchDevice or "") .. ":" .. (event.finger or "")
end

--- Folds one typed event into the state.
---
--- Unrecognised kinds are ignored, so this can be handed the whole stream.
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
        self.wheelX = self.wheelX + event.wheelX
        self.wheelY = self.wheelY + event.wheelY
    elseif kind == "fingerDown" or kind == "fingerMotion" then
        local key = touchKey(event)
        local touch = self._touches[key]
        if touch == nil then
            touch = { device = event.touchDevice, finger = event.finger } as Touch
            self._touches[key] = touch
        end
        touch.x, touch.y = event.x, event.y
        touch.normalX, touch.normalY = event.normalX, event.normalY
        touch.pressure = event.pressure
    elseif kind == "fingerUp" or kind == "fingerCanceled" then
        self._touches[touchKey(event)] = nil
    elseif kind == "penMotion" or kind == "penAxis" then
        self.penWhich = event.which
        self.penX, self.penY = event.x, event.y
    elseif kind == "penDown" or kind == "penUp" then
        self.penWhich = event.which
        self.penX, self.penY = event.x, event.y
        self.penTouching = kind == "penDown"
        self.penEraser = event.eraser == true
    elseif kind == "penProximityOut" then
        self.penTouching = false
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
        if pad ~= nil then pad:_readInfo() end
    elseif kind == "gamepadButtonDown" then
        local pad = self._pads[event.which]
        if pad ~= nil then pad:_press(event.button) end
    elseif kind == "gamepadButtonUp" then
        local pad = self._pads[event.which]
        if pad ~= nil then pad:_release(event.button) end
    elseif kind == "gamepadAxis" then
        local pad = self._pads[event.which]
        if pad ~= nil then pad:_setAxis(event.axis, event.value) end
    elseif kind == "gamepadSensor" then
        local pad = self._pads[event.which]
        if pad ~= nil then
            pad:_setSensor(event.sensor, event.sensorX, event.sensorY,
                event.sensorZ)
        end
    elseif kind == "gamepadTouchpadDown" or kind == "gamepadTouchpadUp"
        or kind == "gamepadTouchpadMotion" then
        local pad = self._pads[event.which]
        if pad ~= nil then
            pad:_setFinger(event.touchpad, event.fingerIndex, event.normalX,
                event.normalY, event.pressure, event.down == true)
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
    if cached ~= nil then return cached end

    local code = self._backend.scancodeFromName(name)
    if code == 0 then
        local titled = name:gsub("(%a)([%w']*)", function(head: string, tail: string): string
            return head:upper() .. tail:lower()
        end)
        code = self._backend.scancodeFromName(titled)
    end
    if code == 0 then
        error(("tecs: no key named '%s'"):format(name), 2)
    end
    self._scancodes[name] = code
    return code
end

--- The name of a physical key, for showing a binding back to the player.
function Input:keyName(scancode: integer): string
    return self._backend.scancodeName(scancode)
end

local function resolveKey(self: Input, key: string | integer): integer
    if key is string then return self:scancode(key) end
    return key
end

--- Whether a key is held. Keys are identified by physical position, so a
--- movement binding stays where it is on every layout.
function Input:keyDown(key: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then return false end
    return self._keys.down[resolveKey(self, key)] == true
end

--- Whether a key went down. Reads the latched set inside a fixed step.
function Input:keyPressed(key: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then return false end
    return self._keys:edges(self._gate.fixed, false)[resolveKey(self, key)] == true
end

--- Whether a key came up, on the same tiers as `keyPressed`.
function Input:keyReleased(key: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then return false end
    return self._keys:edges(self._gate.fixed, true)[resolveKey(self, key)] == true
end

--- The modifier mask reported with the most recent key event.
function Input:modifiers(): integer
    return self._modifiers
end

--- Whether a modifier is held: "shift", "ctrl", "alt", "gui", "capsLock".
---
--- Either side counts for the unsided names, and "leftShift" asks for one.
function Input:modifierDown(name: string, layer?: Layer): boolean
    if not self._gate:canRead(layer) then return false end
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
    if not self._gate:canRead(layer) then return false end
    return self._mouse.down[resolveMouse(self, button)] == true
end

function Input:mousePressed(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then return false end
    return self._mouse:edges(self._gate.fixed, false)[resolveMouse(self, button)] == true
end

function Input:mouseReleased(button: string | integer, layer?: Layer): boolean
    if not self._gate:canRead(layer) then return false end
    return self._mouse:edges(self._gate.fixed, true)[resolveMouse(self, button)] == true
end

--- Hides the cursor and delivers motion as deltas only, for a game that turns
--- the view with the mouse.
function Input:setRelativeMouseMode(enabled: boolean): boolean
    return self._backend.setRelativeMouseMode(self._window, enabled ~= false)
end

function Input:relativeMouseMode(): boolean
    return self._backend.relativeMouseMode(self._window)
end

--- Moves the cursor within the window, in window coordinates.
function Input:warpMouse(x: number, y: number)
    self._backend.warpMouse(self._window, x, y)
end

--- Keeps delivering mouse events while a button is held outside the window,
--- which is what a drag that leaves the window needs.
function Input:captureMouse(enabled: boolean): boolean
    return self._backend.captureMouse(enabled ~= false)
end

function Input:showCursor(visible: boolean): boolean
    return self._backend.showCursor(visible ~= false)
end

function Input:cursorVisible(): boolean
    return self._backend.cursorVisible()
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
    for index = #out, 1, -1 do out[index] = nil end
    if not self._gate:canRead(layer) then return out end
    for _, touch in pairs(self._touches) do out[#out + 1] = touch end
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
    if not self._backend.startTextInput(self._window) then return false end
    self._textStarted = true
    self._textLayer = layer
    local area = options ~= nil and options.area or nil
    if area ~= nil then
        self:setTextInputArea(area)
    end
    return true
end

--- Stops text input and clears whatever was being composed.
function Input:stopTextInput(): boolean
    self._textLayer = nil
    self.composition = ""
    self.compositionStart = 0
    self.compositionLength = 0
    if not self._textStarted then return false end
    self._textStarted = false
    return self._backend.stopTextInput(self._window)
end

--- Whether a text-input session is running.
function Input:textInputActive(): boolean
    return self._textStarted
end

--- The layer the running session belongs to, or nil.
function Input:textInputLayer(): Layer
    return self._textLayer
end

--- Tells the platform where the edited text sits, in window coordinates.
function Input:setTextInputArea(area: TextArea): boolean
    return self._backend.setTextInputArea(self._window, area.x, area.y,
        area.width, area.height, area.cursor or 0)
end

--- Whether the platform puts a keyboard on the screen for text input.
function Input:screenKeyboardSupported(): boolean
    return self._backend.screenKeyboardSupported()
end

return Input
