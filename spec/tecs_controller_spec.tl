require("busted")

-- Skip this entire test suite if FFI is disabled since tecs_controller requires FFI
local libffi = require("tecs.internal.ffi.libffi")
if not libffi.isFFIAvailable() then
    pending("This test suite requires FFI support")
    return
end

local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

-- Load mocks from love2d directory
local love2d_mock <const> = require("spec.love2d.love2d_mock")
local InputMock <const> = require("spec.love2d.tecs2d_input_mock")

-- Complete type definitions for tecs_controller module to avoid dynamic loading issues
local record ReinsModule
    record JoystickConfig
        joystick: any
        auto: boolean
        deadzone: number
    end

    record Bindings
        controls: {string:{string}}
        pairs: {string:{string}}
    end

    record Controller
        bindings: Bindings
        joystick: any
        deadzone: number
        auto: boolean

        isPressed: function(self: Controller, button: string): boolean
        isDown: function(self: Controller, button: string): boolean
        isReleased: function(self: Controller, button: string): boolean
        getPair: function(self: Controller, button: string): number, number
        getRaw: function(self: Controller, button: string): number
        setJoystick: function(self: Controller, joystick: any, skipRumble?: boolean)
        resetJoystick: function(self: Controller, config?: JoystickConfig)
        rebind: function(self: Controller, bindings: Bindings)
        notifyWithRumble: function(self: Controller, strength?: number, duration?: number)
    end

    record ControlManager
        controllers: {Controller}

        addController: function(self: ControlManager, bindings: Bindings, config?: JoystickConfig): Controller
        removeController: function(self: ControlManager, controller: Controller)
        get: function(self: ControlManager, index: integer): Controller
        onJoystickAdded: function(self: ControlManager, joystick: any)
        onJoystickRemoved: function(self: ControlManager, joystick: any)

        -- Internal fields for testing
        _world: tecs.World
    end


    newManager: function(): ControlManager

    -- Plugin and constants
    plugin: function(config?: any): tecs.Plugin
    CONTROLLER: tecs.Key<ControlManager>
end

local tecs_controller: ReinsModule

local record MockTecs2d
    events: {string: tecs.Event}
end


-- Type definitions for mock objects
local record MockInput
    simulateKeyPress: function(self: MockInput, key: string)
    simulateKeyRelease: function(self: MockInput, key: string)
    simulateKeyDown: function(self: MockInput, key: string)
    simulateMousePress: function(self: MockInput, button: integer)
    simulateMouseRelease: function(self: MockInput, button: integer)
    simulateMouseDown: function(self: MockInput, button: integer)
    simulateGamepadButton: function(self: MockInput, joystick: any, button: string, pressed: boolean)
    simulateGamepadAxis: function(self: MockInput, joystick: any, axis: string, value: number)
    simulateJoystickHat: function(self: MockInput, joystick: any, hat: integer, direction: string)
    clearFrameEvents: function(self: MockInput)
    clearAll: function(self: MockInput)
    -- Module-level functions (no self)
    isKeyPressed: function(key: string): boolean
    isKeyReleased: function(key: string): boolean
    isKeyDown: function(key: string): boolean
    isMousePressed: function(button: integer): boolean
    isMouseReleased: function(button: integer): boolean
    isMouseDown: function(button: integer): boolean
    getJoystick: function(joystick: any): any
    update: function()
    enterFixedPhase: function()
    exitFixedPhase: function()
    markLatchedDirty: function()
end

-- We'll mock the required modules since we're testing without Love2D
local mockInput: MockInput
local mockTecs2d: MockTecs2d

describe("Reins", function()
    before_each(function()
        -- Reset module cache to ensure clean state
        package.loaded["tecs_controller"] = nil
        package.loaded["tecs2d.input"] = nil
        package.loaded["tecs2d"] = nil
        package.loaded["love"] = nil

        -- Clear mock joysticks
        love2d_mock.clearMockJoysticks()

        -- Set up Love2D mock
        package.loaded["love"] = love2d_mock
        -- Cast _G to a table that can accept love
        local globalEnv = _G as {string:any}
        globalEnv["love"] = love2d_mock

        -- Create input mock
        mockInput = InputMock.new() as MockInput

        -- Mock tecs2d module with proper event types
        local JoystickAdded = {} as tecs.Event
        local JoystickRemoved = {} as tecs.Event

        mockTecs2d = {
            events = {
                JoystickAdded = JoystickAdded,
                JoystickRemoved = JoystickRemoved
            }
        } as MockTecs2d

        -- Add input to the tecs2d mock
        (mockTecs2d as {string:any})["input"] = mockInput

        -- Mock the tecs2d modules
        package.loaded["tecs2d.input"] = mockInput
        package.loaded["tecs2d"] = mockTecs2d

        -- Now we can safely require tecs_controller
        tecs_controller = require("tecs_controller") as ReinsModule
    end)

    after_each(function()
        -- Clean up global Love2D mock
        local globalEnv = _G as {string:any}
        globalEnv["love"] = nil
    end)

    describe("ControlManager", function()
        it("should create a new control manager", function()
            local manager = tecs_controller.newManager()
            luassert.is_not_nil(manager)
            luassert.is_table(manager.controllers)
            luassert.equals(0, #manager.controllers)
        end)

        it("should add a controller with bindings", function()
            local manager = tecs_controller.newManager()
            local bindings = {
                controls = {
                    jump = {"key:space"},
                    attack = {"key:z", "mouse:1"}
                },
                pairs = {}
            }

            local controller = manager:addController(bindings)
            luassert.is_not_nil(controller)
            luassert.equals(1, #manager.controllers)
            luassert.equals(controller, manager:get(1))
        end)

        it("should remove a controller", function()
            local manager = tecs_controller.newManager()
            local bindings = {
                controls = {
                    test = {"key:a"}
                },
                pairs = {}
            }

            local controller1 = manager:addController(bindings)
            local controller2 = manager:addController(bindings)
            luassert.equals(2, #manager.controllers)

            manager:removeController(controller1)
            luassert.equals(1, #manager.controllers)
            luassert.equals(controller2, manager:get(1))
        end)
    end)

    describe("Controller Input", function()
        local manager: ReinsModule.ControlManager
        local controller: ReinsModule.Controller

        before_each(function()
            manager = tecs_controller.newManager()
            local bindings = {
                controls = {
                    jump = {"key:space", "button:a"},
                    attack = {"key:z", "mouse:1", "button:x"},
                    moveLeft = {"key:a", "key:left"},
                    moveRight = {"key:d", "key:right"},
                    moveUp = {"key:w", "key:up"},
                    moveDown = {"key:s", "key:down"}
                },
                pairs = {
                    move = {"moveLeft", "moveRight", "moveUp", "moveDown"}
                }
            }
            controller = manager:addController(bindings)
        end)

        it("should detect key presses", function()
            mockInput:simulateKeyPress("space")
            luassert.is_true(controller:isPressed("jump"))
            luassert.is_true(controller:isDown("jump"))

            mockInput:clearFrameEvents()
            luassert.is_false(controller:isPressed("jump"))
            luassert.is_true(controller:isDown("jump"))
        end)

        it("should detect key releases", function()
            mockInput:simulateKeyDown("space")
            luassert.is_false(controller:isReleased("jump"))

            mockInput:simulateKeyRelease("space")
            luassert.is_true(controller:isReleased("jump"))
            luassert.is_false(controller:isDown("jump"))
        end)

        it("should detect mouse button presses", function()
            mockInput:simulateMousePress(1)
            luassert.is_true(controller:isPressed("attack"))
            luassert.is_true(controller:isDown("attack"))
            luassert.equals(1, controller:getRaw("attack"))
        end)

        it("should support multiple bindings for same action", function()
            -- Test keyboard binding
            mockInput:simulateKeyPress("z")
            luassert.is_true(controller:isPressed("attack"))
            mockInput:clearAll()

            -- Test mouse binding
            mockInput:simulateMousePress(1)
            luassert.is_true(controller:isPressed("attack"))
        end)

        it("should handle button pairs correctly", function()
            -- No input
            local x, y = controller:getPair("move") as (number, number)
            luassert.equals(0, x)
            luassert.equals(0, y)

            -- Left pressed
            mockInput:simulateKeyDown("a")
            x, y = controller:getPair("move") as (number, number)
            luassert.equals(-1, x)
            luassert.equals(0, y)

            -- Right also pressed (cancels out)
            mockInput:simulateKeyDown("d")
            x, y = controller:getPair("move") as (number, number)
            luassert.equals(0, x)
            luassert.equals(0, y)

            -- Clear and test vertical
            mockInput:clearAll()
            mockInput:simulateKeyDown("w")
            x, y = controller:getPair("move") as (number, number)
            luassert.equals(0, x)
            luassert.equals(-1, y)

            mockInput:simulateKeyDown("s")
            x, y = controller:getPair("move") as (number, number)
            luassert.equals(0, x)
            luassert.equals(0, y)
        end)
    end)

    describe("Gamepad Support", function()
        local manager: ReinsModule.ControlManager
        local joystick: any  -- Mock joystick, type varies

        before_each(function()
            manager = tecs_controller.newManager()
            local mockJoy = love2d_mock.createMockJoystick("test-guid-123", "Xbox Controller")
            joystick = mockJoy
            love2d_mock.addMockJoystick(mockJoy)
        end)

        it("should support manual joystick assignment", function()
            local bindings = {
                controls = {
                    jump = {"button:a"}
                },
                pairs = {}
            }

            local controller = manager:addController(bindings, {joystick = joystick})
            luassert.equals(joystick, controller.joystick)
        end)

        it("should handle setJoystick method correctly", function()
            local bindings = {
                controls = {
                    jump = {"button:a"}
                },
                pairs = {}
            }

            local controller = manager:addController(bindings)
            luassert.is_nil(controller.joystick)

            -- Set a joystick
            controller:setJoystick(joystick)
            luassert.equals(joystick, controller.joystick)

            -- Clear joystick
            controller:setJoystick(nil)
            luassert.is_nil(controller.joystick)

            -- Set joystick again with skipRumble
            controller:setJoystick(joystick, true)
            luassert.equals(joystick, controller.joystick)
        end)

        it("should detect gamepad button presses", function()
            local bindings = {
                controls = {
                    jump = {"button:a"},
                    attack = {"button:x"}
                },
                pairs = {}
            }

            local controller = manager:addController(bindings, {joystick = joystick})

            mockInput:simulateGamepadButton(joystick, "a", true)
            luassert.is_true(controller:isPressed("jump"))
            luassert.is_true(controller:isDown("jump"))

            mockInput:simulateGamepadButton(joystick, "a", false)
            luassert.is_true(controller:isReleased("jump"))
            luassert.is_false(controller:isDown("jump"))
        end)

        it("should handle gamepad axes with deadzone", function()
            local bindings = {
                controls = {
                    moveRight = {"axis:leftx+"},
                    moveLeft = {"axis:leftx-"},
                    accelerate = {"axis:triggerright+"}
                },
                pairs = {}
            }

            local controller = manager:addController(bindings, {joystick = joystick, deadzone = 0.25})

            -- Below deadzone
            mockInput:simulateGamepadAxis(joystick, "leftx", 0.1)
            luassert.equals(0, controller:getRaw("moveRight"))

            -- Above deadzone
            mockInput:simulateGamepadAxis(joystick, "leftx", 0.5)
            luassert.equals(0.5, controller:getRaw("moveRight"))

            -- Negative direction
            mockInput:simulateGamepadAxis(joystick, "leftx", -0.5)
            luassert.equals(0.5, controller:getRaw("moveLeft"))
            luassert.equals(0, controller:getRaw("moveRight"))
        end)

        it("should handle raw gamepad axes without direction", function()
            local bindings = {
                controls = {
                    moveStick = {"axis:leftx"},  -- Raw axis without direction
                    rightStick = {"axis:rightx"}
                },
                pairs = {}
            }

            local controller = manager:addController(bindings, {joystick = joystick, deadzone = 0.25})

            -- Positive value
            mockInput:simulateGamepadAxis(joystick, "leftx", 0.5)
            luassert.equals(0.5, controller:getRaw("moveStick"))

            -- Negative value
            mockInput:simulateGamepadAxis(joystick, "leftx", -0.7)
            luassert.equals(-0.7, controller:getRaw("moveStick"))

            -- Below deadzone (should return 0)
            mockInput:simulateGamepadAxis(joystick, "leftx", 0.1)
            luassert.equals(0, controller:getRaw("moveStick"))

            -- Negative below deadzone (should return 0)
            mockInput:simulateGamepadAxis(joystick, "leftx", -0.1)
            luassert.equals(0, controller:getRaw("moveStick"))
        end)

        it("should handle joystick hats", function()
            local bindings = {
                controls = {
                    up = {"hat:1u"},
                    down = {"hat:1d"},
                    left = {"hat:1l"},
                    right = {"hat:1r"}
                },
                pairs = {}
            }

            local controller = manager:addController(bindings, {joystick = joystick})

            mockInput:simulateJoystickHat(joystick, 1, "u")
            luassert.is_true(controller:isDown("up"))
            luassert.is_false(controller:isDown("down"))

            mockInput:simulateJoystickHat(joystick, 1, "c")
            luassert.is_false(controller:isDown("up"))
        end)
    end)

    describe("Auto-Assignment Modes", function()
        local manager: ReinsModule.ControlManager

        before_each(function()
            manager = tecs_controller.newManager()
        end)

        it("should not auto-assign in off mode (default)", function()
            local joystick1 = love2d_mock.createMockJoystick("guid-1", "Controller 1")
            love2d_mock.addMockJoystick(joystick1)

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            -- Default mode is off, so no auto-assignment
            local controller = manager:addController(bindings)
            luassert.is_nil(controller.joystick)
            luassert.is_false(controller.auto)
        end)

        it("should auto-assign when auto is true", function()
            local joystick1 = love2d_mock.createMockJoystick("guid-1", "Controller 1")
            local joystick2 = love2d_mock.createMockJoystick("guid-2", "Controller 2")
            love2d_mock.addMockJoystick(joystick1)
            love2d_mock.addMockJoystick(joystick2)

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            -- First controller gets first joystick
            local controller1 = manager:addController(bindings, {auto = true})
            luassert.equals(joystick1, controller1.joystick)
            luassert.is_true(controller1.auto)

            -- Second controller gets second joystick
            local controller2 = manager:addController(bindings, {auto = true})
            luassert.equals(joystick2, controller2.joystick)

            -- Third controller gets nothing (no more joysticks)
            local controller3 = manager:addController(bindings, {auto = true})
            luassert.is_nil(controller3.joystick)
            luassert.is_true(controller3.auto)
        end)

        it("should not auto-assign when auto is false", function()
            local joystick1 = love2d_mock.createMockJoystick("guid-1", "Controller 1")
            love2d_mock.addMockJoystick(joystick1)

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            local controller = manager:addController(bindings, {auto = false})
            luassert.is_nil(controller.joystick) -- Should not auto-assign
            luassert.is_false(controller.auto)
        end)

        it("should handle joystick connection for auto-enabled controllers", function()
            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            -- Create controller with auto enabled but no joysticks available
            local controller = manager:addController(bindings, {auto = true})
            luassert.is_nil(controller.joystick)
            luassert.is_true(controller.auto)

            -- Connect a joystick - should be assigned
            local joystick = love2d_mock.createMockJoystick("guid-new", "New Controller")
            love2d_mock.addMockJoystick(joystick)
            manager:onJoystickAdded(joystick)

            luassert.equals(joystick, controller.joystick)
        end)

        it("should not auto-assign when auto is disabled", function()
            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            -- Create controller with auto disabled
            local controller = manager:addController(bindings)
            luassert.is_nil(controller.joystick)
            luassert.is_false(controller.auto)

            -- Connect a joystick
            local joystick = love2d_mock.createMockJoystick("guid-new", "New Controller")
            love2d_mock.addMockJoystick(joystick)
            manager:onJoystickAdded(joystick)

            -- Should NOT be assigned
            luassert.is_nil(controller.joystick)
        end)

        it("should reassign when joystick reconnects", function()
            local joystick = love2d_mock.createMockJoystick("sticky-guid", "My Controller")
            love2d_mock.addMockJoystick(joystick)

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            local controller = manager:addController(bindings, {auto = true})
            luassert.equals(joystick, controller.joystick)

            -- Disconnect
            manager:onJoystickRemoved(joystick)
            luassert.is_nil(controller.joystick)

            -- Reconnect same joystick - should auto-assign again
            manager:onJoystickAdded(joystick)
            luassert.equals(joystick, controller.joystick)
        end)

        it("should not reassign already assigned joysticks", function()
            local joystick = love2d_mock.createMockJoystick("guid-taken", "Controller")
            love2d_mock.addMockJoystick(joystick)

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            -- First controller takes the joystick
            local controller1 = manager:addController(bindings, {auto = true})
            luassert.equals(joystick, controller1.joystick)

            -- Second controller with auto-assign should not get it
            local controller2 = manager:addController(bindings, {auto = true})
            luassert.is_nil(controller2.joystick)
        end)
    end)

    describe("Joystick Reassignment", function()
        local manager: ReinsModule.ControlManager
        local standardBindings: ReinsModule.Bindings

        before_each(function()
            manager = tecs_controller.newManager()
            -- Standard bindings for reuse
            standardBindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }
        end)

        it("should reassign to any available joystick", function()
            local xboxController = love2d_mock.createMockJoystick("xbox-guid", "Xbox Controller")
            love2d_mock.addMockJoystick(xboxController)

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            -- Create controller with auto enabled
            local controller = manager:addController(bindings, {auto = true})
            luassert.equals(xboxController, controller.joystick)

            -- Disconnect the Xbox controller
            manager:onJoystickRemoved(xboxController)
            luassert.is_nil(controller.joystick)

            -- Remove the old controller entirely
            love2d_mock.removeMockJoystick(xboxController)

            -- Add a PS4 controller
            local psController = love2d_mock.createMockJoystick("ps4-guid", "PS4 Controller")
            love2d_mock.addMockJoystick(psController)
            manager:onJoystickAdded(psController)

            -- Should now be reassigned to the PS4 controller
            luassert.equals(psController, controller.joystick)
        end)

        it("should handle multiple controllers reassignment", function()
            local xbox1 = love2d_mock.createMockJoystick("xbox-guid-1", "Xbox Controller")
            love2d_mock.addMockJoystick(xbox1)

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            local controller = manager:addController(bindings, {auto = true})
            luassert.equals(xbox1, controller.joystick)

            -- Disconnect and remove
            manager:onJoystickRemoved(xbox1)
            love2d_mock.removeMockJoystick(xbox1)

            -- Add multiple controllers
            local psController = love2d_mock.createMockJoystick("ps-guid", "PS4 Controller")
            local xbox2 = love2d_mock.createMockJoystick("xbox-guid-2", "Xbox Controller")
            love2d_mock.addMockJoystick(psController)
            love2d_mock.addMockJoystick(xbox2)

            -- First available controller should be reassigned
            manager:onJoystickAdded(psController)

            -- Should get reassigned to first available (PS4)
            luassert.equals(psController, controller.joystick)
        end)


        it("should handle multiple auto controllers competing for joysticks", function()
            -- Two auto controllers, one joystick
            local controller1 = manager:addController(standardBindings, {auto = true})
            local controller2 = manager:addController(standardBindings, {auto = true})

            -- Both start unassigned
            luassert.is_nil(controller1.joystick)
            luassert.is_nil(controller2.joystick)

            -- Add one joystick - first controller should get it
            local xbox = love2d_mock.createMockJoystick("xbox-guid", "Xbox Controller")
            love2d_mock.addMockJoystick(xbox)
            manager:onJoystickAdded(xbox)

            luassert.equals(xbox, controller1.joystick)
            luassert.is_nil(controller2.joystick)

            -- Add another joystick - second controller should get it
            local ps4 = love2d_mock.createMockJoystick("ps4-guid", "PS4 Controller")
            love2d_mock.addMockJoystick(ps4)
            manager:onJoystickAdded(ps4)

            luassert.equals(xbox, controller1.joystick)
            luassert.equals(ps4, controller2.joystick)
        end)
    end)


    describe("Activity Detection for Auto-Assignment", function()
        local manager: ReinsModule.ControlManager

        before_each(function()
            manager = tecs_controller.newManager()
            mockInput:clearAll()
        end)

        it("should prefer joystick with button activity when auto-assigning", function()
            local xbox = love2d_mock.createMockJoystick("xbox-guid", "Xbox Controller")
            local ps4 = love2d_mock.createMockJoystick("ps4-guid", "PS4 Controller")
            love2d_mock.addMockJoystick(xbox)
            love2d_mock.addMockJoystick(ps4)

            -- Simulate button press on PS4 controller
            mockInput:simulateGamepadButton(ps4, "a", true)

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            -- Create flexible controller - should pick PS4 due to activity
            local controller = manager:addController(bindings, {auto = true})

            -- Should have selected the PS4 controller with activity
            luassert.equals(ps4, controller.joystick)
        end)

        it("should prefer joystick with axis activity when auto-assigning", function()
            local xbox = love2d_mock.createMockJoystick("xbox-guid", "Xbox Controller")
            local ps4 = love2d_mock.createMockJoystick("ps4-guid", "PS4 Controller")
            love2d_mock.addMockJoystick(xbox)
            love2d_mock.addMockJoystick(ps4)

            -- Simulate significant axis movement on Xbox controller
            mockInput:simulateGamepadAxis(xbox, "leftx", 0.8)

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            -- Create flexible controller - should pick Xbox due to activity
            local controller = manager:addController(bindings, {auto = true})

            -- Should have selected the Xbox controller with activity
            luassert.equals(xbox, controller.joystick)
        end)

        it("should ignore small axis movements below threshold", function()
            local xbox = love2d_mock.createMockJoystick("xbox-guid", "Xbox Controller")
            local ps4 = love2d_mock.createMockJoystick("ps4-guid", "PS4 Controller")
            love2d_mock.addMockJoystick(xbox)
            love2d_mock.addMockJoystick(ps4)

            -- Small axis movement on PS4 - should be ignored
            mockInput:simulateGamepadAxis(ps4, "leftx", 0.3)

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            -- Create flexible controller - should pick first available (Xbox)
            local controller = manager:addController(bindings, {auto = true})

            -- Should have selected Xbox (first available, PS4 activity ignored)
            luassert.equals(xbox, controller.joystick)
        end)

        it("should prefer active joystick when one is added", function()
            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            -- Create controller without any joysticks
            local controller = manager:addController(bindings, {auto = true})
            luassert.is_nil(controller.joystick)

            -- Add first joystick without activity
            local xbox = love2d_mock.createMockJoystick("xbox-guid", "Xbox Controller")
            love2d_mock.addMockJoystick(xbox)

            -- Add second joystick with activity
            local ps4 = love2d_mock.createMockJoystick("ps4-guid", "PS4 Controller")
            love2d_mock.addMockJoystick(ps4)
            mockInput:simulateGamepadButton(ps4, "x", true)

            -- Notify manager about PS4 addition
            manager:onJoystickAdded(ps4)

            -- Should have assigned PS4 due to activity
            luassert.equals(ps4, controller.joystick)
        end)
    end)

    describe("Configuration Defaults and Validation", function()
        local manager: ReinsModule.ControlManager

        before_each(function()
            manager = tecs_controller.newManager()
        end)

        it("should use correct default values", function()
            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            -- No config = auto disabled by default
            local controller1 = manager:addController(bindings)
            luassert.is_false(controller1.auto)
            luassert.equals(0.5, controller1.deadzone)

            -- Empty config = defaults
            local controller2 = manager:addController(bindings, {})
            luassert.is_false(controller2.auto)
            luassert.equals(0.5, controller2.deadzone)

            -- Partial config preserves other defaults
            local controller3 = manager:addController(bindings, {auto = true})
            luassert.is_true(controller3.auto)
            luassert.equals(0.5, controller3.deadzone)
        end)

        it("should override auto mode when joystick is directly assigned", function()
            local joystick = love2d_mock.createMockJoystick("test-guid", "Test Controller")
            love2d_mock.addMockJoystick(joystick)

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            -- Even with auto enabled, direct joystick assignment overrides it
            local controller = manager:addController(bindings, {
                joystick = joystick,
                auto = true  -- This should be overridden
            })

            luassert.equals(joystick, controller.joystick)
            luassert.is_false(controller.auto)  -- Should be false when joystick is directly assigned
        end)
    end)


    describe("resetJoystick", function()
        local manager: ReinsModule.ControlManager
        local controller: ReinsModule.Controller

        before_each(function()
            manager = tecs_controller.newManager()
            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }
            controller = manager:addController(bindings)
        end)

        it("should switch to auto-assignment mode", function()
            controller:resetJoystick({auto = true})
            luassert.is_true(controller.auto)

            -- Should pick up next available joystick
            local joystick = love2d_mock.createMockJoystick("guid-auto", "Auto Controller")
            love2d_mock.addMockJoystick(joystick)
            manager:onJoystickAdded(joystick)

            luassert.equals(joystick, controller.joystick)
        end)

        it("should disable auto-assignment mode", function()
            controller:resetJoystick({auto = false})
            luassert.is_false(controller.auto)

            -- Shouldn't pick up a joystick
            local joystick = love2d_mock.createMockJoystick("guid-different", "Different Controller")
            love2d_mock.addMockJoystick(joystick)
            manager:onJoystickAdded(joystick)

            luassert.is_nil(controller.joystick)
        end)

        it("should switch to specific joystick", function()
            local joystick1 = love2d_mock.createMockJoystick("guid-1", "Controller 1")
            local joystick2 = love2d_mock.createMockJoystick("guid-2", "Controller 2")
            love2d_mock.addMockJoystick(joystick1)
            love2d_mock.addMockJoystick(joystick2)

            controller:resetJoystick({joystick = joystick1})
            luassert.equals(joystick1, controller.joystick)
            luassert.is_false(controller.auto)

            controller:resetJoystick({joystick = joystick2})
            luassert.equals(joystick2, controller.joystick)
        end)

        it("should disconnect joystick when nil", function()
            local joystick = love2d_mock.createMockJoystick("guid-disc", "Controller")
            controller:resetJoystick({joystick = joystick})
            luassert.equals(joystick, controller.joystick)

            controller:resetJoystick(nil)
            luassert.is_nil(controller.joystick)
            luassert.is_false(controller.auto)
        end)


        it("should update partial config without changing joystick", function()
            local joystick = love2d_mock.createMockJoystick("guid-test", "Test Controller")
            love2d_mock.addMockJoystick(joystick)

            -- Start with specific settings
            controller:resetJoystick({
                joystick = joystick,
                deadzone = 0.2
            })
            luassert.equals(joystick, controller.joystick)
            luassert.equals(0.2, controller.deadzone)
            luassert.is_false(controller.auto)

            -- Update just deadzone
            controller:resetJoystick({
                joystick = joystick,
                deadzone = 0.4
            })
            luassert.equals(joystick, controller.joystick)  -- Still same joystick
            luassert.equals(0.4, controller.deadzone)  -- Updated deadzone

            -- Switch to auto mode - should try to auto-assign
            controller:resetJoystick({
                auto = true
            })
            luassert.equals(joystick, controller.joystick)  -- Should auto-assign the available joystick
            luassert.is_true(controller.auto)
            luassert.equals(0.4, controller.deadzone)  -- Preserved from before
        end)
    end)

    describe("Runtime Rebinding", function()
        it("should change bindings at runtime", function()
            local manager = tecs_controller.newManager()
            local originalBindings = {
                controls = {
                    jump = {"key:space"},
                    attack = {"key:z"}
                },
                pairs = {}
            }

            local controller = manager:addController(originalBindings)

            -- Test original bindings
            mockInput:simulateKeyPress("space")
            luassert.is_true(controller:isPressed("jump"))
            mockInput:clearAll()

            -- Rebind
            local newBindings = {
                controls = {
                    jump = {"key:w"},
                    attack = {"key:q"},
                    newAction = {"key:e"}
                },
                pairs = {}
            }

            controller:rebind(newBindings)

            -- Old binding shouldn't work
            mockInput:simulateKeyPress("space")
            luassert.is_false(controller:isPressed("jump"))

            -- New binding should work
            mockInput:simulateKeyPress("w")
            luassert.is_true(controller:isPressed("jump"))

            -- New action should be available
            mockInput:simulateKeyPress("e")
            luassert.is_true(controller:isPressed("newAction"))
        end)

        it("should preserve joystick and deadzone on rebind", function()
            local manager = tecs_controller.newManager()
            local joystick = love2d_mock.createMockJoystick("guid-preserve", "Controller")
            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            local controller = manager:addController(bindings, {joystick = joystick, deadzone = 0.35})
            luassert.equals(joystick, controller.joystick)
            luassert.equals(0.35, controller.deadzone)

            controller:rebind({
                controls = { attack = {"button:x"} },
                pairs = {}
            })

            -- Joystick and deadzone preserved
            luassert.equals(joystick, controller.joystick)
            luassert.equals(0.35, controller.deadzone)
        end)
    end)

    describe("Bindings Validation", function()
        it("should reject invalid binding formats", function()
            local manager = tecs_controller.newManager()
            local invalidBindings = {
                controls = {
                    test = {"invalid_format"}  -- Missing colon separator
                },
                pairs = {}
            }

            luassert.has_error(function()
                manager:addController(invalidBindings)
            end, "Invalid binding format for button 'test': 'invalid_format' (expected 'source:value')")
        end)

        it("should accept raw axis values without direction", function()
            local manager = tecs_controller.newManager()
            local rawAxisBindings = {
                controls = {
                    test = {"axis:leftx"}  -- Raw axis without + or - direction
                },
                pairs = {}
            }

            -- Should not throw an error and should create a controller
            local controller: ReinsModule.Controller
            luassert.has_no_errors(function()
                controller = manager:addController(rawAxisBindings)
            end, "Should accept raw axis values without direction")

            -- Verify it was created successfully
            luassert.is_not_nil(controller)
        end)

        it("should reject unknown binding sources", function()
            local manager = tecs_controller.newManager()
            local invalidBindings = {
                controls = {
                    test = {"unknown:value"}
                },
                pairs = {}
            }

            luassert.has_error(function()
                manager:addController(invalidBindings)
            end, "Unknown binding source 'unknown' for button 'test' (valid sources: key, mouse, button, axis, hat)")
        end)

        it("should accept all valid binding types", function()
            local manager = tecs_controller.newManager()
            local validBindings = {
                controls = {
                    key_test = {"key:space"},
                    mouse_test = {"mouse:1"},
                    button_test = {"button:a"},
                    axis_plus = {"axis:leftx+"},
                    axis_minus = {"axis:leftx-"},
                    hat_test = {"hat:1u"}
                },
                pairs = {}
            }

            luassert.has_no_error(function()
                manager:addController(validBindings)
            end, "Valid bindings should work")
        end)
    end)

    describe("Plugin", function()
        it("should create a plugin function", function()
            local plugin = tecs_controller.plugin()
            luassert.is_function(plugin)
        end)

        it("should accept custom manager in config", function()
            local customManager = tecs_controller.newManager()
            local plugin = tecs_controller.plugin({
                manager = customManager
            })
            luassert.is_function(plugin)
        end)

        it("should set up world resources when applied", function()
            local world = tecs.newWorld()
            local plugin = tecs_controller.plugin()
            plugin(world)

            local manager = world.resources[tecs_controller.CONTROLLER]
            luassert.is_not_nil(manager)
            luassert.is_table(manager.controllers)
        end)

        it("should use provided manager if given", function()
            local world = tecs.newWorld()
            local customManager = tecs_controller.newManager()
            local plugin = tecs_controller.plugin({
                manager = customManager
            })
            plugin(world)

            luassert.equals(customManager, world.resources[tecs_controller.CONTROLLER])
        end)
    end)
end)