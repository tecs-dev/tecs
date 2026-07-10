local table_clear <const> = require("table.clear")

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
        isMouseDown: function(button: integer): boolean
        isMousePressed: function(button: integer): boolean
        isMouseReleased: function(button: integer): boolean
        getMouseWheelMovement: function(): number, number, love.mouse.WheelDirection
    end

    --- The game's own input view. The module-level input.isKey*/isMouse*
    --- delegate to this; it reports nothing while any UI layer is pushed on top.
    base: View

    --- The stack of pushed UI layers: a dense, 1-based array (never a hash). A
    --- modal UI reads its own input through stack[token], and while it is on top
    --- the game (base) and lower layers report nothing, so their hotkeys do not
    --- fire. Forwarding to lower layers is intentionally not supported yet.
    stack: {View}

    --- Push an input layer, suppressing every layer below it. Returns the token
    --- to read through (input.stack[token]) and to pass to popStack.
    pushStack: function(): integer

    --- Pop the top input layer. Only the top may be popped; token must be the
    --- value returned by the matching pushStack.
    popStack: function(token: integer)

    --- Number of layers currently pushed (0 = only the game). The top layer's
    --- token equals this value.
    stackDepth: function(): integer

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
}

-- The suppressed view: any layer that is not on top (and the game while a modal
-- is active) sees this and reports no input.
local emptyView: input.View = {
    isKeyDown = function(_key: string): boolean return false end,
    isKeyPressed = function(_key: string): boolean return false end,
    isKeyReleased = function(_key: string): boolean return false end,
    isMouseDown = function(_button: integer): boolean return false end,
    isMousePressed = function(_button: integer): boolean return false end,
    isMouseReleased = function(_button: integer): boolean return false end,
    getMouseWheelMovement = function(): number, number, love.mouse.WheelDirection
        return 0, 0, "standard"
    end,
}

-- Exactly one view points at realView: the top layer, or the game base when the
-- stack is empty. Everything else points at emptyView. push/pop just repoint,
-- no allocation. stack stays a dense 1-based array (top-only pop never holes it).
input.base = realView
input.stack = {}
local stackTop = 0

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

function input.pushStack(): integer
    if stackTop == 0 then
        input.base = emptyView
    else
        input.stack[stackTop] = emptyView
    end
    stackTop = stackTop + 1
    input.stack[stackTop] = realView
    clearEdges()
    return stackTop
end

function input.popStack(token: integer)
    if token ~= stackTop then
        error("input.popStack: only the top layer may be popped (top=" ..
            tostring(stackTop) .. ", got=" .. tostring(token) .. ")")
    end
    input.stack[stackTop] = nil
    stackTop = stackTop - 1
    if stackTop == 0 then
        input.base = realView
    else
        input.stack[stackTop] = realView
    end
    clearEdges()
end

function input.stackDepth(): integer
    return stackTop
end

function input.isKeyDown(key: string): boolean
    return input.base.isKeyDown(key)
end

function input.isKeyPressed(key: string): boolean
    return input.base.isKeyPressed(key)
end

function input.isKeyReleased(key: string): boolean
    return input.base.isKeyReleased(key)
end

function input.isMouseDown(button: integer): boolean
    return input.base.isMouseDown(button)
end

function input.isMousePressed(button: integer): boolean
    return input.base.isMousePressed(button)
end

function input.isMouseReleased(button: integer): boolean
    return input.base.isMouseReleased(button)
end

function input.getMouseWheelMovement(): number, number, love.mouse.WheelDirection
    return input.base.getMouseWheelMovement()
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

function input.getJoystick(joystick: love.joystick.Joystick): input.JoystickInput
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

function input.markLatchedDirty()
    latchedDirty = true
end

return input