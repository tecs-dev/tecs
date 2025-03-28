-- Mock Love2D module for testing
local record love2d_mock
    record TimerModule
        getTime: function(): number
        getFPS: function(): number
        currentTime: number  -- Mock time for testing
    end
    record JoystickModule
        enum GamepadButton
            "a"
            "b"
            "x"
            "y"
            "back"
            "guide"
            "start"
            "leftstick"
            "rightstick"
            "leftshoulder"
            "rightshoulder"
            "dpup"
            "dpdown"
            "dpleft"
            "dpright"
        end

        enum GamepadAxis
            "leftx"
            "lefty"
            "rightx"
            "righty"
            "triggerleft"
            "triggerright"
        end

        enum JoystickHat
            "c"  -- centered
            "u"  -- up
            "d"  -- down
            "l"  -- left
            "r"  -- right
            "lu" -- left-up
            "ld" -- left-down
            "ru" -- right-up
            "rd" -- right-down
        end

        record Joystick
            getGUID: function(self: Joystick): string
            getName: function(self: Joystick): string
            getID: function(self: Joystick): number, number
            isGamepad: function(self: Joystick): boolean
            isVibrationSupported: function(self: Joystick): boolean
            setVibration: function(self: Joystick, left: number, right: number, duration: number): boolean

            -- Internal mock state
            _guid: string
            _name: string
            _id: number
            _instanceId: number
            _isGamepad: boolean
            _buttons: {integer: boolean}
            _axes: {string: number}
            _hats: {integer: JoystickHat}
        end

        getJoysticks: function(): {Joystick}
    end

    joystick: JoystickModule
    timer: TimerModule

    -- Mock joystick registry for testing
    _mockJoysticks: {JoystickModule.Joystick}

    -- Create a mock joystick for testing
    createMockJoystick: function(guid: string, name?: string, isGamepad?: boolean): JoystickModule.Joystick

    -- Clear all mock joysticks
    clearMockJoysticks: function()

    -- Add a mock joystick to the registry
    addMockJoystick: function(joystick: JoystickModule.Joystick)

    -- Remove a mock joystick from the registry
    removeMockJoystick: function(joystick: JoystickModule.Joystick)

    -- Event module for Love2D event handling
    record EventModule
        poll: function(): string, any, any, any, any, any
        pump: function()
    end
    event: EventModule

    -- Graphics module for Love2D graphics functions
    record GraphicsModule
        getStats: function(): table
    end
    graphics: GraphicsModule

    -- Love2D event handlers
    handlers: {string: function}

    -- Timer module functions
    quit: function(): boolean
end

local love: love2d_mock = {
    joystick = {},
    timer = {} as love2d_mock.TimerModule,
    _mockJoysticks = {}
}

local JoystickMT: metatable<love2d_mock.JoystickModule.Joystick> = {
    __index = {
        getGUID = function(self: love2d_mock.JoystickModule.Joystick): string
            return self._guid
        end,
        getName = function(self: love2d_mock.JoystickModule.Joystick): string
            return self._name
        end,
        getID = function(self: love2d_mock.JoystickModule.Joystick): number, number
            return self._id, self._instanceId
        end,
        isGamepad = function(self: love2d_mock.JoystickModule.Joystick): boolean
            return self._isGamepad
        end,
        isVibrationSupported = function(self: love2d_mock.JoystickModule.Joystick): boolean
            return self._isGamepad -- Assume gamepads support vibration
        end,
        setVibration = function(self: love2d_mock.JoystickModule.Joystick, _left: number, _right: number, _duration: number): boolean
            -- Mock vibration, just return success
            return self._isGamepad
        end
    }
}

function love.joystick.getJoysticks(): {love2d_mock.JoystickModule.Joystick}
    return love._mockJoysticks
end

local nextId = 1
local nextInstanceId = 1

function love.createMockJoystick(guid: string, name?: string, isGamepad?: boolean): love2d_mock.JoystickModule.Joystick
    local joystick = {
        _guid = guid,
        _name = name or "Mock Controller",
        _id = nextId,
        _instanceId = nextInstanceId,
        _isGamepad = isGamepad ~= false, -- Default to true
        _buttons = {},
        _axes = {},
        _hats = {}
    } as love2d_mock.JoystickModule.Joystick

    setmetatable(joystick, JoystickMT)

    nextId = nextId + 1
    nextInstanceId = nextInstanceId + 1

    return joystick
end

function love.clearMockJoysticks()
    love._mockJoysticks = {}
end

function love.addMockJoystick(joystick: love2d_mock.JoystickModule.Joystick)
    table.insert(love._mockJoysticks, joystick)
end

function love.removeMockJoystick(joystick: love2d_mock.JoystickModule.Joystick)
    for i = #love._mockJoysticks, 1, -1 do
        if love._mockJoysticks[i] == joystick then
            table.remove(love._mockJoysticks, i)
            break
        end
    end
end

-- Initialize timer module
love.timer.currentTime = 0
love.timer.getTime = function(): number
    return love.timer.currentTime
end
love.timer.getFPS = function(): number
    return 60  -- Mock 60 FPS
end

-- Initialize event module for tecs2d
love.event = {
    poll = function(): string, any, any, any, any, any
        -- Return nil to indicate no events
        return nil
    end,
    pump = function()
        -- Do nothing for tests
    end
}

-- Initialize handlers for tecs2d
love.handlers = {}

-- Initialize quit function
love.quit = function(): boolean
    return true  -- Allow quit for tests
end

-- Initialize graphics module
love.graphics = {
    getStats = function(): table
        return {
            texturememory = 1024,
            images = 0,
            canvases = 0,
            fonts = 0,
            drawcalls = 0,
            drawcallsbatched = 0
        }
    end
}

return love