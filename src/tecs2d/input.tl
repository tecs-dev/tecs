local table_clear <const> = require("table.clear")
local tecs <const> = require("tecs")
local events <const> = require("tecs2d.events")

--- Global input state module for Love2D.
--- Captures input events from Love2D in an easy to use format.
local record input
    --- A container for input from a joystick.
    record JoystickInput
        --- Updated when a gamepad axis is moved.
        --- The key is the axis index, and the value is the new value of the axis.
        gamepadAxis: {love.joystick.GamepadAxis: number}

        --- Updated when a joystick hat is moved.
        --- The key is the hat number, and the value is the new direction of the hat (e.g., "c").
        joystickHat: {number: love.joystick.JoystickHat}

        --- LIVE state: Current gamepad button states (true = down, nil = up).
        gamepadButtons: {love.joystick.GamepadButton: boolean}

        --- Frame events: Gamepad buttons pressed this frame.
        gamepadPressed: {love.joystick.GamepadButton: boolean}

        --- Frame events: Gamepad buttons released this frame.
        gamepadReleased: {love.joystick.GamepadButton: boolean}

        --- Latched events: Gamepad buttons pressed.
        gamepadLatchedPressed: {love.joystick.GamepadButton: boolean}

        --- Latched events: Gamepad buttons released.
        gamepadLatchedReleased: {love.joystick.GamepadButton: boolean}

        --- LIVE state: Current joystick button states (true = down, nil = up).
        joystickButtons: {number: boolean}

        --- Frame events: Joystick buttons pressed this frame.
        joystickPressed: {number: boolean}

        --- Frame events: Joystick buttons released this frame.
        joystickReleased: {number: boolean}

        --- Latched events: Joystick buttons pressed.
        joystickLatchedPressed: {number: boolean}

        --- Latched events: Joystick buttons released.
        joystickLatchedReleased: {number: boolean}

        --- Check if a gamepad button is down.
        ---
        --- @param button The button to check.
        --- @return `true` if the button is down, `false` otherwise.
        isGamepadButtonDown: function(self: JoystickInput, button: love.joystick.GamepadButton): boolean

        --- Check if a gamepad button was just pressed.
        --- Automatically uses frame events or latched events based on current phase.
        ---
        --- @param button The button to check.
        --- @return `true` if the button is pressed, `false` otherwise.
        isGamepadButtonPressed: function(self: JoystickInput, button: love.joystick.GamepadButton): boolean

        --- Check if a gamepad button was just released.
        --- Automatically uses frame events or latched events based on current phase.
        ---
        --- @param button The button to check.
        --- @return `true` if the button is released, `false` otherwise.
        isGamepadButtonReleased: function(self: JoystickInput, button: love.joystick.GamepadButton): boolean

        --- Check if a joystick button is down.
        ---
        --- @param button The button to check.
        --- @return `true` if the button is down, `false` otherwise.
        isJoystickButtonDown: function(self: JoystickInput, button: number): boolean

        --- Check if a joystick button was just pressed.
        --- Automatically uses frame events or latched events based on current phase.
        ---
        --- @param button The button to check.
        --- @return `true` if the button is pressed, `false` otherwise.
        isJoystickButtonPressed: function(self: JoystickInput, button: number): boolean

        --- Check if a joystick button was just released.
        --- Automatically uses frame events or latched events based on current phase.
        ---
        --- @param button The button to check.
        --- @return `true` if the button is released, `false` otherwise.
        isJoystickButtonReleased: function(self: JoystickInput, button: number): boolean
    end

    --- Text input returned from `textinput`.
    textInput: string

    --- The current mouse x position.
    mouseX: number

    --- The current mouse y position.
    mouseY: number

    --- The amount moved along the mouse wheel x-axis and y-axis since the last frame.
    mouseWheelMoved: {number, number}

    --- The wheel movement direction from the last event ("flick" or "standard").
    mouseWheelDirection: love.mouse.WheelDirection

    --- Latched wheel movement (cleared after first FixedUpdate).
    mouseWheelLatchedMoved: {number, number}

    --- Latched wheel direction (cleared after first FixedUpdate).
    mouseWheelLatchedDirection: love.mouse.WheelDirection

    --- Current mouse button states (true = down, nil = up).
    mouseButtons: {integer: boolean}

    --- Frame events: Mouse buttons pressed this frame (cleared each frame).
    mousePressed: {integer: boolean}

    --- Frame events: Mouse buttons released this frame (cleared each frame).
    mouseReleased: {integer: boolean}

    --- Latched events: Mouse buttons pressed (cleared after first FixedUpdate).
    mouseLatchedPressed: {integer: boolean}

    --- Latched events: Mouse buttons released (cleared after first FixedUpdate).
    mouseLatchedReleased: {integer: boolean}

    --- Current key states (true = down, nil = up).
    keys: {string: boolean}

    --- Frame events: Keys pressed this frame (cleared each frame).
    keysPressed: {string: boolean}

    --- Frame events: Keys released this frame (cleared each frame).
    keysReleased: {string: boolean}

    --- Latched events: Keys pressed (cleared after first FixedUpdate).
    keysLatchedPressed: {string: boolean}

    --- Latched events: Keys released (cleared after first FixedUpdate).
    keysLatchedReleased: {string: boolean}

    --- A map of active joysticks to their input states.
    joysticks: {love.joystick.Joystick: JoystickInput}

    --- Check if a key is down.
    ---
    --- @param key The key to check.
    --- @return `true` if the key is down, `false` otherwise.
    isKeyDown: function(key: string): boolean

    --- Check if a key was just pressed.
    --- Automatically uses frame events or latched events based on current phase.
    ---
    --- @param key The key to check.
    --- @return `true` if the key is pressed, `false` otherwise.
    isKeyPressed: function(key: string): boolean

    --- Check if a key was just released.
    --- Automatically uses frame events or latched events based on current phase.
    ---
    --- @param key The key to check.
    --- @return `true` if the key is released, `false` otherwise.
    isKeyReleased: function(key: string): boolean

    --- A view of input for one layer of the input stack. It exposes the same
    --- query surface as the module. The layer on top of the stack sees real
    --- input; every layer below it (including the game at index 0) sees nothing.
    record View
        isKeyDown: function(key: string): boolean
        isKeyPressed: function(key: string): boolean
        isKeyReleased: function(key: string): boolean
        getTextInput: function(): string
        getMousePosition: function(): number, number
        isMouseDown: function(button: integer): boolean
        isMousePressed: function(button: integer): boolean
        isMouseReleased: function(button: integer): boolean
        getMouseWheelMovement: function(): number, number, love.mouse.WheelDirection
        getJoystick: function(joystick: love.joystick.Joystick): JoystickInput
    end

    --- One stable target in the intrusive input stack. Physical events reach
    --- only the top target. An observer explicitly forwards an unconsumed event
    --- with `layer.parent:emit(event)`.
    record Layer
        name: string
        view: View
        parent: Layer
        _child: Layer
        _bus: tecs.MessageBus
        _active: boolean
        _kind: string
        _lastDispatchId: integer

        observe: function<E is tecs.Event>(self, event: E, callback: function(E), id?: string)
        stopObserving: function<E is tecs.Event>(self, event: E, callback: function(E) | string)
        hasObservers: function<E is tecs.Event>(self, event: E): boolean
        emit: function<E is tecs.Event>(self, event: E)
        isActive: function(self): boolean
        isTop: function(self): boolean
    end

    --- The game's implicit bottom target. Existing world observers at address
    --- zero receive routed input when delivery reaches this target.
    base: Layer

    --- An always-live target for tooling, recording, and diagnostics. Raw
    --- observers run before the routed top target and cannot be intercepted.
    raw: Layer

    --- Create an inactive reusable input layer.
    newLayer: function(name: string): Layer

    --- Push a layer above the current top target.
    pushLayer: function(layer: Layer)

    --- Pop a specific active layer, including one below the current top.
    popLayer: function(layer: Layer): boolean

    --- Return the current routed target (base when no layer is pushed).
    topLayer: function(): Layer

    --- Number of pushed layers, excluding the implicit base target.
    layerCount: function(): integer

    --- Check if a mouse button is down.
    ---
    --- @param button The button to check.
    --- @return `true` if the button is down, `false` otherwise.
    isMouseDown: function(button: integer): boolean

    --- Check if a mouse button was just pressed.
    --- Automatically uses frame events or latched events based on current phase.
    ---
    --- @param button The button to check.
    --- @return `true` if the button is pressed, `false` otherwise.
    isMousePressed: function(button: integer): boolean

    --- Check if a mouse button was just released.
    --- Automatically uses frame events or latched events based on current phase.
    ---
    --- @param button The button to check.
    --- @return `true` if the button is released, `false` otherwise.
    isMouseReleased: function(button: integer): boolean

    --- Get the mouse wheel movement for the current frame.
    ---
    --- @return dx The horizontal wheel movement.
    --- @return dy The vertical wheel movement.
    --- @return direction The wheel direction ("flick" or "standard").
    getMouseWheelMovement: function(): number, number, love.mouse.WheelDirection

    --- Text entered this frame through the base input target.
    getTextInput: function(): string

    --- Mouse position through the base input target.
    getMousePosition: function(): number, number

    --- Update input states between frames (clears frame events).
    update: function()

    --- Called when entering the fixed update phase.
    --- Marks the input system as being in fixed phase for proper event handling.
    enterFixedPhase: function()

    --- Called when exiting the fixed update phase.
    --- Clears latched events and marks the input system as outside fixed phase.
    exitFixedPhase: function()

    --- Get the input state for a joystick.
    ---
    --- @param joystick The joystick to get the input state for.
    --- @return The input state for the joystick.
    getJoystick: function(joystick: love.joystick.Joystick): JoystickInput

    --- Internal raw joystick state used by LÖVE handlers and device management.
    getRawJoystick: function(joystick: love.joystick.Joystick): JoystickInput

    --- Bind the world used by the base event target.
    bindWorld: function(world: tecs.World)

    --- Route one LÖVE interaction to raw observers and the current top target.
    route: function<E is tecs.Event>(world: tecs.World, event: E, ...: any)

    --- Mark latched events as dirty so they'll be cleared after the next fixed update.
    markLatchedDirty: function()
end

-- Initialize the module fields
input.textInput = ""
input.mouseX = 0
input.mouseY = 0
input.mouseWheelMoved = {0, 0}
input.mouseWheelDirection = "standard"
input.mouseWheelLatchedMoved = {0, 0}
input.mouseWheelLatchedDirection = "standard"
input.mouseButtons = {}
input.mousePressed = {}
input.mouseReleased = {}
input.mouseLatchedPressed = {}
input.mouseLatchedReleased = {}
input.keys = {}
input.keysPressed = {}
input.keysReleased = {}
input.keysLatchedPressed = {}
input.keysLatchedReleased = {}
input.joysticks = {}

--- Track if latched states need clearing.
local latchedDirty = false

--- Track if we're currently in a fixed update phase.
local inFixedPhase = false

-------------------------------------------------------------------------------
-- Module functions
-------------------------------------------------------------------------------

local emptyJoystickInput: input.JoystickInput

-- The real input, read by whichever layer is on top of the stack.
local realView: input.View = {
    isKeyDown = function(key: string): boolean
        return input.keys[key] == true
    end,
    isKeyPressed = function(key: string): boolean
        if inFixedPhase then return input.keysLatchedPressed[key] == true end
        return input.keysPressed[key] == true
    end,
    isKeyReleased = function(key: string): boolean
        if inFixedPhase then return input.keysLatchedReleased[key] == true end
        return input.keysReleased[key] == true
    end,
    getTextInput = function(): string
        return input.textInput
    end,
    getMousePosition = function(): number, number
        return input.mouseX, input.mouseY
    end,
    isMouseDown = function(button: integer): boolean
        return input.mouseButtons[button] == true
    end,
    isMousePressed = function(button: integer): boolean
        if inFixedPhase then return input.mouseLatchedPressed[button] == true end
        return input.mousePressed[button] == true
    end,
    isMouseReleased = function(button: integer): boolean
        if inFixedPhase then return input.mouseLatchedReleased[button] == true end
        return input.mouseReleased[button] == true
    end,
    getMouseWheelMovement = function(): number, number, love.mouse.WheelDirection
        if inFixedPhase then
            return input.mouseWheelLatchedMoved[1], input.mouseWheelLatchedMoved[2], input.mouseWheelLatchedDirection
        end
        return input.mouseWheelMoved[1], input.mouseWheelMoved[2], input.mouseWheelDirection
    end,
    getJoystick = function(joystick: love.joystick.Joystick): input.JoystickInput
        return input.getRawJoystick(joystick)
    end,
}

-- The suppressed view: any layer that is not on top (and the game while a modal
-- is active) sees this and reports no input.
local emptyView: input.View = {
    isKeyDown = function(_key: string): boolean return false end,
    isKeyPressed = function(_key: string): boolean return false end,
    isKeyReleased = function(_key: string): boolean return false end,
    getTextInput = function(): string return "" end,
    getMousePosition = function(): number, number return 0, 0 end,
    isMouseDown = function(_button: integer): boolean return false end,
    isMousePressed = function(_button: integer): boolean return false end,
    isMouseReleased = function(_button: integer): boolean return false end,
    getMouseWheelMovement = function(): number, number, love.mouse.WheelDirection
        return 0, 0, "standard"
    end,
    getJoystick = function(_joystick: love.joystick.Joystick): input.JoystickInput
        return emptyJoystickInput
    end,
}

local LAYER_MT <const>: metatable<input.Layer> = { __index = input.Layer }
local boundWorld: tecs.World = nil
local top: input.Layer
local pushedCount = 0
local nextDispatchId = 0
local dispatchDepth = 0
local dispatchEvents: {tecs.Event} = {}
local dispatchWorlds: {tecs.World} = {}
local dispatchIds: {integer} = {}

local function makeLayer(name: string, kind: string, view: input.View): input.Layer
    return setmetatable({
        name = name,
        view = view,
        parent = nil,
        _child = nil,
        _bus = tecs.newMessageBus(),
        _active = kind ~= "layer",
        _kind = kind,
        _lastDispatchId = 0,
    }, LAYER_MT)
end

input.base = makeLayer("base", "base", realView)
input.raw = makeLayer("raw", "raw", realView)
top = input.base

-- Drop pending edge (pressed/released) and latched state at a capture boundary,
-- so key/button/wheel/text that happened for one layer never leaks to the layer
-- that gains input on the other side. Held state (input.keys, mouseButtons) is
-- left alone: a key still physically down stays down. Without this, input taken
-- while a layer was up (or the game frozen behind it) fires the instant the
-- layer pops, e.g. an "f" typed into the debugger toggling the game's fullscreen.
local function clearEdges()
    input.textInput = ""
    table_clear(input.keysPressed)
    table_clear(input.keysReleased)
    table_clear(input.keysLatchedPressed)
    table_clear(input.keysLatchedReleased)
    table_clear(input.mousePressed)
    table_clear(input.mouseReleased)
    table_clear(input.mouseLatchedPressed)
    table_clear(input.mouseLatchedReleased)
    input.mouseWheelMoved[1], input.mouseWheelMoved[2] = 0, 0
    input.mouseWheelDirection = "standard"
    input.mouseWheelLatchedMoved[1], input.mouseWheelLatchedMoved[2] = 0, 0
    input.mouseWheelLatchedDirection = "standard"
    for _, joystickInput in pairs(input.joysticks) do
        table_clear(joystickInput.gamepadPressed)
        table_clear(joystickInput.gamepadReleased)
        table_clear(joystickInput.gamepadLatchedPressed)
        table_clear(joystickInput.gamepadLatchedReleased)
        table_clear(joystickInput.joystickPressed)
        table_clear(joystickInput.joystickReleased)
        table_clear(joystickInput.joystickLatchedPressed)
        table_clear(joystickInput.joystickLatchedReleased)
    end
    latchedDirty = false
end

function input.Layer:observe<E is tecs.Event>(eventType: E, callback: function(E), id?: string)
    if self._kind == "base" then
        if not boundWorld then error("input.base is not bound to a world yet", 2) end
        boundWorld:observe(0, eventType, callback, id)
    else
        self._bus:observe(0, eventType, callback, id)
    end
end

function input.Layer:stopObserving<E is tecs.Event>(eventType: E, callback: function(E) | string)
    if self._kind == "base" then
        if not boundWorld then error("input.base is not bound to a world yet", 2) end
        boundWorld:stopObserving(0, eventType, callback)
    else
        self._bus:stopObserving(0, eventType, callback)
    end
end

function input.Layer:hasObservers<E is tecs.Event>(eventType: E): boolean
    if self._kind == "base" then
        return boundWorld ~= nil and boundWorld:hasObservers(0, eventType)
    end
    return self._bus:hasObservers(0, eventType)
end

function input.Layer:emit<E is tecs.Event>(event: E)
    local depth <const> = dispatchDepth
    if depth == 0 or dispatchEvents[depth] ~= event then
        error("input layer targets may only emit the input event currently being routed", 2)
    end

    local dispatchId <const> = dispatchIds[depth]
    if self._lastDispatchId == dispatchId then return end
    self._lastDispatchId = dispatchId

    if self._kind == "base" then
        dispatchWorlds[depth]:emit(0, event)
    elseif self._bus:hasObservers(0, event) then
        self._bus:emit(0, event)
    end
end

function input.Layer:isActive(): boolean
    return self._active
end

function input.Layer:isTop(): boolean
    return self == top
end

function input.newLayer(name: string): input.Layer
    if name == "" then error("input.newLayer requires a non-empty name", 2) end
    return makeLayer(name, "layer", emptyView)
end

local function emitCapture(target: input.Layer, eventType: tecs.Event, from: string, to: string)
    if target._kind == "base" then
        if boundWorld then boundWorld:emit(0, eventType, from, to) end
    elseif target._bus:hasObservers(0, eventType) then
        local constructor = eventType as any as function(...: any): tecs.Event
        target._bus:emit(0, constructor(from, to))
    end
end

function input.pushLayer(layer: input.Layer)
    if layer._kind ~= "layer" then error("input.pushLayer expects a user input layer", 2) end
    if layer._active then error("input.pushLayer: layer is already active: " .. layer.name, 2) end

    local outgoing <const> = top
    emitCapture(outgoing, events.InputCaptureLost, outgoing.name, layer.name)
    outgoing.view = emptyView

    layer.parent = outgoing
    layer._child = nil
    outgoing._child = layer
    layer._active = true
    layer.view = realView
    top = layer
    pushedCount = pushedCount + 1
    clearEdges()
    emitCapture(layer, events.InputCaptureGained, outgoing.name, layer.name)
end

function input.popLayer(layer: input.Layer): boolean
    if layer._kind ~= "layer" or not layer._active then return false end

    local wasTop <const> = layer == top
    local parent <const> = layer.parent
    local child <const> = layer._child
    if wasTop then
        emitCapture(layer, events.InputCaptureLost, layer.name, parent.name)
    end

    parent._child = child
    if child then child.parent = parent end
    layer._child = nil
    layer._active = false
    layer.view = emptyView
    pushedCount = pushedCount - 1

    if wasTop then
        top = parent
        parent.view = realView
        clearEdges()
        emitCapture(parent, events.InputCaptureGained, layer.name, parent.name)
    end
    return true
end

function input.topLayer(): input.Layer
    return top
end

function input.layerCount(): integer
    return pushedCount
end

function input.bindWorld(world: tecs.World)
    boundWorld = world
end

function input.route<E is tecs.Event>(world: tecs.World, eventType: E, ...: any)
    boundWorld = world
    local rawListening <const> = input.raw._bus:hasObservers(0, eventType)
    local routedListening <const> = top:hasObservers(eventType)
    if not rawListening and not routedListening then return end

    -- Preserve World's lazy pooled constructor path for the overwhelmingly
    -- common case: gameplay is top and no always-on raw observer needs the
    -- same instance. This adds no event allocation beyond the pre-layer API.
    if top == input.base and not rawListening then
        world:emit(0, eventType, ...)
        return
    end

    local constructor = eventType as any as function(...: any): E
    local event <const> = constructor(...) as E
    nextDispatchId = nextDispatchId + 1
    dispatchDepth = dispatchDepth + 1
    local depth <const> = dispatchDepth
    dispatchEvents[depth] = event
    dispatchWorlds[depth] = world
    dispatchIds[depth] = nextDispatchId

    if rawListening then input.raw:emit(event) end
    if routedListening then top:emit(event) end

    dispatchEvents[depth] = nil
    dispatchWorlds[depth] = nil
    dispatchIds[depth] = nil
    dispatchDepth = depth - 1
end

function input.isKeyDown(key: string): boolean
    return input.base.view.isKeyDown(key)
end

function input.isKeyPressed(key: string): boolean
    return input.base.view.isKeyPressed(key)
end

function input.isKeyReleased(key: string): boolean
    return input.base.view.isKeyReleased(key)
end

function input.isMouseDown(button: integer): boolean
    return input.base.view.isMouseDown(button)
end

function input.isMousePressed(button: integer): boolean
    return input.base.view.isMousePressed(button)
end

function input.isMouseReleased(button: integer): boolean
    return input.base.view.isMouseReleased(button)
end

function input.getMouseWheelMovement(): number, number, love.mouse.WheelDirection
    return input.base.view.getMouseWheelMovement()
end

function input.getTextInput(): string
    return input.base.view.getTextInput()
end

function input.getMousePosition(): number, number
    return input.base.view.getMousePosition()
end

function input.update()
    input.textInput = ""
    local mouseWheelMoved = input.mouseWheelMoved
    mouseWheelMoved[1], mouseWheelMoved[2] = 0, 0
    input.mouseWheelDirection = "standard"

    table_clear(input.keysPressed as {any})
    table_clear(input.keysReleased as {any})
    table_clear(input.mousePressed as {any})
    table_clear(input.mouseReleased as {any})

    local joysticks = input.joysticks
    for _, joystickInput in pairs(joysticks) do
        table_clear(joystickInput.gamepadPressed as {any})
        table_clear(joystickInput.gamepadReleased as {any})
        table_clear(joystickInput.joystickPressed as {any})
        table_clear(joystickInput.joystickReleased as {any})
    end
end

function input.enterFixedPhase()
    inFixedPhase = true
end

function input.exitFixedPhase()
    if latchedDirty then
        table_clear(input.keysLatchedPressed as {any})
        table_clear(input.keysLatchedReleased as {any})
        table_clear(input.mouseLatchedPressed as {any})
        table_clear(input.mouseLatchedReleased as {any})
        input.mouseWheelLatchedMoved[1], input.mouseWheelLatchedMoved[2] = 0, 0
        input.mouseWheelLatchedDirection = "standard"
        for _, joystickInput in pairs(input.joysticks) do
            table_clear(joystickInput.gamepadLatchedPressed as {any})
            table_clear(joystickInput.gamepadLatchedReleased as {any})
            table_clear(joystickInput.joystickLatchedPressed as {any})
            table_clear(joystickInput.joystickLatchedReleased as {any})
        end
        latchedDirty = false
    end

    inFixedPhase = false
end

-------------------------------------------------------------------------------
-- Joystick Input implementation
-------------------------------------------------------------------------------

local JOYSTICK_INPUT_MT <const>: metatable<input.JoystickInput> = { __index = input.JoystickInput }

emptyJoystickInput = setmetatable({
    gamepadAxis = {},
    joystickHat = {},
    gamepadButtons = {},
    gamepadPressed = {},
    gamepadReleased = {},
    gamepadLatchedPressed = {},
    gamepadLatchedReleased = {},
    joystickButtons = {},
    joystickPressed = {},
    joystickReleased = {},
    joystickLatchedPressed = {},
    joystickLatchedReleased = {},
}, JOYSTICK_INPUT_MT)

function input.JoystickInput:isGamepadButtonDown(button: love.joystick.GamepadButton): boolean
    return self.gamepadButtons[button] == true
end

function input.JoystickInput:isGamepadButtonPressed(button: love.joystick.GamepadButton): boolean
    if inFixedPhase then
        return self.gamepadLatchedPressed[button] == true
    else
        return self.gamepadPressed[button] == true
    end
end

function input.JoystickInput:isGamepadButtonReleased(button: love.joystick.GamepadButton): boolean
    if inFixedPhase then
        return self.gamepadLatchedReleased[button] == true
    else
        return self.gamepadReleased[button] == true
    end
end

function input.JoystickInput:isJoystickButtonDown(button: number): boolean
    return self.joystickButtons[button] == true
end

function input.JoystickInput:isJoystickButtonPressed(button: number): boolean
    if inFixedPhase then
        return self.joystickLatchedPressed[button] == true
    else
        return self.joystickPressed[button] == true
    end
end

function input.JoystickInput:isJoystickButtonReleased(button: number): boolean
    if inFixedPhase then
        return self.joystickLatchedReleased[button] == true
    else
        return self.joystickReleased[button] == true
    end
end

function input.getRawJoystick(joystick: love.joystick.Joystick): input.JoystickInput
    local result = input.joysticks[joystick]
    if not result then
        result = {
            gamepadAxis = {},
            joystickHat = {},
            gamepadButtons = {},
            gamepadPressed = {},
            gamepadReleased = {},
            gamepadLatchedPressed = {},
            gamepadLatchedReleased = {},
            joystickButtons = {},
            joystickPressed = {},
            joystickReleased = {},
            joystickLatchedPressed = {},
            joystickLatchedReleased = {},
        }
        setmetatable(result, JOYSTICK_INPUT_MT)
        input.joysticks[joystick] = result
    end
    return result
end

function input.getJoystick(joystick: love.joystick.Joystick): input.JoystickInput
    return input.base.view.getJoystick(joystick)
end

function input.markLatchedDirty()
    latchedDirty = true
end

return input
