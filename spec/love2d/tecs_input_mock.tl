-- Mock Tecs2D Input module for testing
local love2d_mock <const> = require("spec.love2d.love2d_mock")

local record InputMock
    -- Constants matching tecs2d.input
    PRESS: integer
    RELEASE: integer
    REPEAT: integer

    -- Public state matching tecs2d.input module
    textInput: string
    mouseX: number
    mouseY: number
    mouseWheelMoved: {number, number}
    mouseButtons: {integer: boolean}
    mousePressed: {integer: boolean}
    mouseReleased: {integer: boolean}
    mouseLatchedPressed: {integer: boolean}
    mouseLatchedReleased: {integer: boolean}
    keys: {string: boolean}
    keysPressed: {string: boolean}
    keysReleased: {string: boolean}
    keysLatchedPressed: {string: boolean}
    keysLatchedReleased: {string: boolean}

    -- Joystick inputs
    record JoystickInput
        joystick: love2d_mock.JoystickModule.Joystick
        gamepadButtonPressed: {love2d_mock.JoystickModule.GamepadButton: boolean}
        gamepadButtonReleased: {love2d_mock.JoystickModule.GamepadButton: boolean}
        gamepadButtonDown: {love2d_mock.JoystickModule.GamepadButton: boolean}
        gamepadButtons: {love2d_mock.JoystickModule.GamepadButton: boolean}  -- State for activity detection
        joystickButtons: {integer: boolean}  -- State for activity detection
        gamepadAxis: {love2d_mock.JoystickModule.GamepadAxis: number}
        joystickHat: {integer: love2d_mock.JoystickModule.JoystickHat}
        gamepadPressed: {love2d_mock.JoystickModule.GamepadButton: boolean}
        gamepadReleased: {love2d_mock.JoystickModule.GamepadButton: boolean}
        gamepadLatchedPressed: {love2d_mock.JoystickModule.GamepadButton: boolean}
        gamepadLatchedReleased: {love2d_mock.JoystickModule.GamepadButton: boolean}
        joystickPressed: {integer: boolean}
        joystickReleased: {integer: boolean}
        joystickLatchedPressed: {integer: boolean}
        joystickLatchedReleased: {integer: boolean}

        isGamepadButtonPressed: function(self: JoystickInput, button: love2d_mock.JoystickModule.GamepadButton): boolean
        isGamepadButtonReleased: function(self: JoystickInput, button: love2d_mock.JoystickModule.GamepadButton): boolean
        isGamepadButtonDown: function(self: JoystickInput, button: love2d_mock.JoystickModule.GamepadButton): boolean
        isJoystickButtonPressed: function(self: JoystickInput, button: integer): boolean
        isJoystickButtonReleased: function(self: JoystickInput, button: integer): boolean
        isJoystickButtonDown: function(self: JoystickInput, button: integer): boolean
    end

    joysticks: {love2d_mock.JoystickModule.Joystick: JoystickInput}

    -- Public interface matching Tecs2D Input module (no self!)
    isKeyPressed: function(key: string): boolean
    isKeyReleased: function(key: string): boolean
    isKeyDown: function(key: string): boolean
    isMousePressed: function(button: integer): boolean
    isMouseReleased: function(button: integer): boolean
    isMouseDown: function(button: integer): boolean
    getJoystick: function(joystick: love2d_mock.JoystickModule.Joystick): JoystickInput
    update: function()
    enterFixedPhase: function()
    exitFixedPhase: function()
    markLatchedDirty: function()

    -- Test utilities (these still use self for the mock instance)
    simulateKeyPress: function(self: InputMock, key: string)
    simulateKeyRelease: function(self: InputMock, key: string)
    simulateKeyDown: function(self: InputMock, key: string)
    simulateMousePress: function(self: InputMock, button: integer)
    simulateMouseRelease: function(self: InputMock, button: integer)
    simulateMouseDown: function(self: InputMock, button: integer)
    simulateGamepadButton: function(self: InputMock, joystick: love2d_mock.JoystickModule.Joystick, button: love2d_mock.JoystickModule.GamepadButton, pressed: boolean)
    simulateGamepadAxis: function(self: InputMock, joystick: love2d_mock.JoystickModule.Joystick, axis: love2d_mock.JoystickModule.GamepadAxis, value: number)
    simulateJoystickHat: function(self: InputMock, joystick: love2d_mock.JoystickModule.Joystick, hat: integer, direction: love2d_mock.JoystickModule.JoystickHat)

    -- Clear all input state
    clearAll: function(self: InputMock)
    clearFrameEvents: function(self: InputMock)

    -- Create a new mock input
    new: function(): InputMock
end

local JoystickInputMT: metatable<InputMock.JoystickInput> = {
    __index = InputMock.JoystickInput
}

function InputMock.JoystickInput:isGamepadButtonPressed(button: love2d_mock.JoystickModule.GamepadButton): boolean
    return self.gamepadPressed[button] or false
end

function InputMock.JoystickInput:isGamepadButtonReleased(button: love2d_mock.JoystickModule.GamepadButton): boolean
    return self.gamepadReleased[button] or false
end

function InputMock.JoystickInput:isGamepadButtonDown(button: love2d_mock.JoystickModule.GamepadButton): boolean
    return self.gamepadButtons[button] == true
end

function InputMock.JoystickInput:isJoystickButtonPressed(button: integer): boolean
    return self.joystickPressed[button] or false
end

function InputMock.JoystickInput:isJoystickButtonReleased(button: integer): boolean
    return self.joystickReleased[button] or false
end

function InputMock.JoystickInput:isJoystickButtonDown(button: integer): boolean
    return self.joystickButtons[button] or false
end

local InputMockMT: metatable<InputMock> = {
    __index = InputMock
}

-- Create the singleton mock instance
local mockInstance: InputMock

function InputMock.isKeyPressed(key: string): boolean
    return mockInstance.keysPressed[key] or false
end

function InputMock.isKeyReleased(key: string): boolean
    return mockInstance.keysReleased[key] or false
end

function InputMock.isKeyDown(key: string): boolean
    return mockInstance.keys[key] or false
end

function InputMock.isMousePressed(button: integer): boolean
    return mockInstance.mousePressed[button] or false
end

function InputMock.isMouseReleased(button: integer): boolean
    return mockInstance.mouseReleased[button] or false
end

function InputMock.isMouseDown(button: integer): boolean
    return mockInstance.mouseButtons[button] or false
end

function InputMock.getJoystick(joystick: love2d_mock.JoystickModule.Joystick): InputMock.JoystickInput
    local js = mockInstance.joysticks[joystick]
    if not js then
        js = setmetatable({
            joystick = joystick,
            gamepadButtonPressed = {},
            gamepadButtonReleased = {},
            gamepadButtonDown = {},
            gamepadButtons = {},
            joystickButtons = {},
            gamepadAxis = {},
            joystickHat = {},
            gamepadPressed = {},
            gamepadReleased = {},
            gamepadLatchedPressed = {},
            gamepadLatchedReleased = {},
            joystickPressed = {},
            joystickReleased = {},
            joystickLatchedPressed = {},
            joystickLatchedReleased = {}
        }, JoystickInputMT)
        mockInstance.joysticks[joystick] = js as InputMock.JoystickInput
    end
    return js
end

function InputMock.update()
    mockInstance:clearFrameEvents()
end

function InputMock.enterFixedPhase()
    -- No-op for mock
end

function InputMock.exitFixedPhase()
    -- No-op for mock
end

function InputMock.markLatchedDirty()
    -- No-op for mock
end

-- Test utility methods (still instance methods)
function InputMock:simulateKeyPress(key: string)
    self.keysPressed[key] = true
    self.keys[key] = true
end

function InputMock:simulateKeyRelease(key: string)
    self.keysReleased[key] = true
    self.keys[key] = nil
end

function InputMock:simulateKeyDown(key: string)
    self.keys[key] = true
end

function InputMock:simulateMousePress(button: integer)
    self.mousePressed[button] = true
    self.mouseButtons[button] = true
end

function InputMock:simulateMouseRelease(button: integer)
    self.mouseReleased[button] = true
    self.mouseButtons[button] = nil
end

function InputMock:simulateMouseDown(button: integer)
    self.mouseButtons[button] = true
end

function InputMock:simulateGamepadButton(joystick: love2d_mock.JoystickModule.Joystick, button: love2d_mock.JoystickModule.GamepadButton, pressed: boolean)
    local js = self.joysticks[joystick] or InputMock.getJoystick(joystick)
    if pressed then
        js.gamepadPressed[button] = true
        js.gamepadButtons[button] = true
    else
        js.gamepadReleased[button] = true
        js.gamepadButtons[button] = nil
    end
end

function InputMock:simulateGamepadAxis(joystick: love2d_mock.JoystickModule.Joystick, axis: love2d_mock.JoystickModule.GamepadAxis, value: number)
    local js = self.joysticks[joystick] or InputMock.getJoystick(joystick)
    js.gamepadAxis[axis] = value
end

function InputMock:simulateJoystickHat(joystick: love2d_mock.JoystickModule.Joystick, hat: integer, direction: love2d_mock.JoystickModule.JoystickHat)
    local js = self.joysticks[joystick] or InputMock.getJoystick(joystick)
    js.joystickHat[hat] = direction
end

function InputMock:clearFrameEvents()
    -- Clear keyboard frame events
    for k in pairs(self.keysPressed) do
        self.keysPressed[k] = nil
    end
    for k in pairs(self.keysReleased) do
        self.keysReleased[k] = nil
    end

    -- Clear mouse frame events
    for k in pairs(self.mousePressed) do
        self.mousePressed[k] = nil
    end
    for k in pairs(self.mouseReleased) do
        self.mouseReleased[k] = nil
    end

    -- Clear joystick frame events
    for _, js in pairs(self.joysticks) do
        for k in pairs(js.gamepadPressed) do
            js.gamepadPressed[k] = nil
        end
        for k in pairs(js.gamepadReleased) do
            js.gamepadReleased[k] = nil
        end
        for k in pairs(js.joystickPressed) do
            js.joystickPressed[k] = nil
        end
        for k in pairs(js.joystickReleased) do
            js.joystickReleased[k] = nil
        end
    end
end

function InputMock:clearAll()
    -- Clear all state
    for k in pairs(self.keys) do
        self.keys[k] = nil
    end
    for k in pairs(self.keysPressed) do
        self.keysPressed[k] = nil
    end
    for k in pairs(self.keysReleased) do
        self.keysReleased[k] = nil
    end

    for k in pairs(self.mouseButtons) do
        self.mouseButtons[k] = nil
    end
    for k in pairs(self.mousePressed) do
        self.mousePressed[k] = nil
    end
    for k in pairs(self.mouseReleased) do
        self.mouseReleased[k] = nil
    end

    for k in pairs(self.joysticks) do
        self.joysticks[k] = nil
    end
end

function InputMock.new(): InputMock
    local mock: InputMock = {
        PRESS = 1,
        RELEASE = 2,
        REPEAT = 3,
        textInput = "",
        mouseX = 0,
        mouseY = 0,
        mouseWheelMoved = {0, 0},
        mouseButtons = {},
        mousePressed = {},
        mouseReleased = {},
        mouseLatchedPressed = {},
        mouseLatchedReleased = {},
        keys = {},
        keysPressed = {},
        keysReleased = {},
        keysLatchedPressed = {},
        keysLatchedReleased = {},
        joysticks = {}
    }
    setmetatable(mock, InputMockMT)

    -- Set the singleton instance
    mockInstance = mock

    -- Copy module-level functions to the instance for module-like behavior
    mock.isKeyPressed = InputMock.isKeyPressed
    mock.isKeyReleased = InputMock.isKeyReleased
    mock.isKeyDown = InputMock.isKeyDown
    mock.isMousePressed = InputMock.isMousePressed
    mock.isMouseReleased = InputMock.isMouseReleased
    mock.isMouseDown = InputMock.isMouseDown
    mock.getJoystick = InputMock.getJoystick
    mock.update = InputMock.update
    mock.enterFixedPhase = InputMock.enterFixedPhase
    mock.exitFixedPhase = InputMock.exitFixedPhase
    mock.markLatchedDirty = InputMock.markLatchedDirty

    return mock
end

return InputMock