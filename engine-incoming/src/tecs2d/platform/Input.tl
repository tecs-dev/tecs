--- Input state, in three tiers, behind a layer stack.
---
--- Live state answers "is it held". Frame events answer "did it change this
--- frame". Latched events answer the same question for fixed-step systems,
--- which is not the same question: a key pressed and released between two
--- fixed steps is invisible to frame events, and dropping it produces
--- input loss that is nondeterministic and so effectively unreproducible.
--- Latched sets accumulate across every frame since the last fixed step and
--- clear when it ends.
---
--- Queries are answered relative to a layer. A layer that blocks hides input
--- from everything beneath it, so a menu suppresses gameplay without gameplay
--- code knowing a menu exists. Code that names no layer reads the base layer,
--- which is the safe default: it goes quiet when anything is pushed over it.
---
--- The state is fed typed events and holds no globals, so a recorded session
--- replays by feeding the same events back. It never sees an `SDL_Event`: the
--- conversion happens once, in `events`, and everything downstream shares that
--- one vocabulary.

local sdl <const> = require("tecs2d.ffi.sdl3")
local eventStream <const> = require("tecs2d.platform.events")

local C <const> = sdl.C
local K <const> = sdl.K

local record Layer
    name: string
    --- Whether this layer hides input from the layers beneath it.
    blocking: boolean
    index: integer
end

local record ButtonState
    down: {integer: boolean}
    pressed: {integer: boolean}
    released: {integer: boolean}
    latchedPressed: {integer: boolean}
    latchedReleased: {integer: boolean}
end

local record Input
    Layer: Layer

    --- Mouse position in window coordinates.
    mouseX: number
    mouseY: number
    --- Mouse motion accumulated this frame.
    mouseDeltaX: number
    mouseDeltaY: number
    --- Wheel movement accumulated this frame.
    wheelX: number
    wheelY: number
    --- Text committed this frame, from the text input event.
    text: string

    _keys: ButtonState
    _mouse: ButtonState
    _pads: ButtonState
    _axes: {integer: number}
    _layers: {Layer}
    _base: Layer
    _fixed: boolean
    _scancodes: {string: integer}
end

local InputMT <const>: metatable<Input> = { __index = Input }

local function newButtonState(): ButtonState
    return {
        down = {}, pressed = {}, released = {},
        latchedPressed = {}, latchedReleased = {},
    }
end

local function clear(set: {integer: boolean})
    for key in pairs(set) do set[key] = nil end
end

--- Creates an input state with a single base layer.
function Input.create(): Input
    local self = setmetatable({} as Input, InputMT)
    self._keys = newButtonState()
    self._mouse = newButtonState()
    self._pads = newButtonState()
    self._axes = {}
    self._scancodes = {}
    self._base = { name = "base", blocking = true, index = 1 }
    self._layers = { self._base }
    self._fixed = false
    self.mouseX, self.mouseY = 0.0, 0.0
    self.mouseDeltaX, self.mouseDeltaY = 0.0, 0.0
    self.wheelX, self.wheelY = 0.0, 0.0
    self.text = ""
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
    local layer: Layer = {
        name = name,
        blocking = blocking ~= false,
        index = #self._layers + 1,
    }
    self._layers[layer.index] = layer
    return layer
end

--- Removes the topmost layer. The base layer is never removed.
function Input:popLayer(): Layer
    if #self._layers <= 1 then return nil end
    local layer = self._layers[#self._layers]
    self._layers[#self._layers] = nil
    return layer
end

--- The layer currently on top.
function Input:topLayer(): Layer
    return self._layers[#self._layers]
end

--- The lowest layer index still allowed to read.
local function readableFrom(self: Input): integer
    for index = #self._layers, 1, -1 do
        if self._layers[index].blocking then return index end
    end
    return 1
end

--- Whether `layer` may read input. Omitting a layer means the base layer.
function Input:canRead(layer?: Layer): boolean
    local index = layer ~= nil and layer.index or 1
    return index >= readableFrom(self)
end

-------------------------------------------------------------------------------
-- Frame lifecycle
-------------------------------------------------------------------------------

--- Clears per-frame state. Call once before polling events for a frame.
function Input:beginFrame()
    clear(self._keys.pressed)
    clear(self._keys.released)
    clear(self._mouse.pressed)
    clear(self._mouse.released)
    clear(self._pads.pressed)
    clear(self._pads.released)
    self.mouseDeltaX, self.mouseDeltaY = 0.0, 0.0
    self.wheelX, self.wheelY = 0.0, 0.0
    self.text = ""
end

--- Switches queries to the latched sets for the duration of a fixed step.
function Input:enterFixedPhase()
    self._fixed = true
end

--- Ends the fixed phase and clears what it consumed.
function Input:exitFixedPhase()
    self._fixed = false
    clear(self._keys.latchedPressed)
    clear(self._keys.latchedReleased)
    clear(self._mouse.latchedPressed)
    clear(self._mouse.latchedReleased)
    clear(self._pads.latchedPressed)
    clear(self._pads.latchedReleased)
end

-------------------------------------------------------------------------------
-- Event intake
-------------------------------------------------------------------------------

local function press(state: ButtonState, code: integer)
    state.down[code] = true
    state.pressed[code] = true
    state.latchedPressed[code] = true
end

local function release(state: ButtonState, code: integer)
    state.down[code] = nil
    state.released[code] = true
    state.latchedReleased[code] = true
end

--- Folds one typed event into the state.
---
--- Unrecognised kinds are ignored, so this can be handed the whole stream.
function Input:handleEvent(event: eventStream.Event)
    local kind = event.kind

    if kind == "keyDown" then
        -- A repeat is not a press: holding a key must not read as pressing it
        -- many times.
        if not event.repeated then
            press(self._keys, event.scancode)
        end
    elseif kind == "keyUp" then
        release(self._keys, event.scancode)
    elseif kind == "mouseDown" then
        press(self._mouse, event.button)
    elseif kind == "mouseUp" then
        release(self._mouse, event.button)
    elseif kind == "mouseMotion" then
        self.mouseX = event.x
        self.mouseY = event.y
        self.mouseDeltaX = self.mouseDeltaX + event.dx
        self.mouseDeltaY = self.mouseDeltaY + event.dy
    elseif kind == "mouseWheel" then
        self.wheelX = self.wheelX + event.wheelX
        self.wheelY = self.wheelY + event.wheelY
    elseif kind == "controllerButtonDown" then
        press(self._pads, event.button)
    elseif kind == "controllerButtonUp" then
        release(self._pads, event.button)
    elseif kind == "controllerAxis" then
        self._axes[event.axis] = event.value
    end
end

-------------------------------------------------------------------------------
-- Queries
-------------------------------------------------------------------------------

--- Resolves a key name to a scancode, caching the lookup.
---
--- Names are SDL's ("Space", "Left Shift"), matched case-insensitively so
--- "space" and "left shift" work too.
function Input:scancode(name: string): integer
    local cached = self._scancodes[name]
    if cached ~= nil then return cached end

    local code = tonumber(C.SDL_GetScancodeFromName(name)) as integer
    if code == 0 then
        local titled = name:gsub("(%a)([%w']*)", function(head: string, tail: string): string
            return head:upper() .. tail:lower()
        end)
        code = tonumber(C.SDL_GetScancodeFromName(titled)) as integer
    end
    if code == 0 then
        error(("tecs2d: no key named '%s'"):format(name), 2)
    end
    self._scancodes[name] = code
    return code
end

local function resolve(self: Input, key: string | integer): integer
    if key is string then return self:scancode(key) end
    return key
end

--- The set a query should read, given the current phase.
local function eventSet(self: Input, state: ButtonState, released: boolean): {integer: boolean}
    if self._fixed then
        return released and state.latchedReleased or state.latchedPressed
    end
    return released and state.released or state.pressed
end

function Input:isKeyDown(key: string | integer, layer?: Layer): boolean
    if not self:canRead(layer) then return false end
    return self._keys.down[resolve(self, key)] == true
end

function Input:isKeyPressed(key: string | integer, layer?: Layer): boolean
    if not self:canRead(layer) then return false end
    return eventSet(self, self._keys, false)[resolve(self, key)] == true
end

function Input:isKeyReleased(key: string | integer, layer?: Layer): boolean
    if not self:canRead(layer) then return false end
    return eventSet(self, self._keys, true)[resolve(self, key)] == true
end

function Input:isMouseDown(button: integer, layer?: Layer): boolean
    if not self:canRead(layer) then return false end
    return self._mouse.down[button] == true
end

function Input:isMousePressed(button: integer, layer?: Layer): boolean
    if not self:canRead(layer) then return false end
    return eventSet(self, self._mouse, false)[button] == true
end

function Input:isMouseReleased(button: integer, layer?: Layer): boolean
    if not self:canRead(layer) then return false end
    return eventSet(self, self._mouse, true)[button] == true
end

function Input:isPadDown(button: integer, layer?: Layer): boolean
    if not self:canRead(layer) then return false end
    return self._pads.down[button] == true
end

function Input:isPadPressed(button: integer, layer?: Layer): boolean
    if not self:canRead(layer) then return false end
    return eventSet(self, self._pads, false)[button] == true
end

function Input:isPadReleased(button: integer, layer?: Layer): boolean
    if not self:canRead(layer) then return false end
    return eventSet(self, self._pads, true)[button] == true
end

--- A gamepad axis in -1..1, or zero if the layer cannot read.
---
--- `deadzone` suppresses stick drift, which is a property of the hardware
--- rather than of any one game, so it is applied here.
function Input:axis(axis: integer, deadzone?: number, layer?: Layer): number
    if not self:canRead(layer) then return 0.0 end
    local value = self._axes[axis] or 0.0
    local limit = deadzone or 0.15
    if math.abs(value) < limit then return 0.0 end
    return value
end

--- Mouse button constants, from SDL.
function Input.buttons(): {string: integer}
    return {
        left = K.SDL_BUTTON_LEFT,
        middle = K.SDL_BUTTON_MIDDLE,
        right = K.SDL_BUTTON_RIGHT,
    }
end

return Input
