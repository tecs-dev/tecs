require("busted")

local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

-- Load mocks from love2d directory
local love2d_mock <const> = require("spec.love2d.love2d_mock")
local InputMock <const> = require("spec.love2d.tecs_input_mock")

-- Complete type definitions for tecs2d.controller module to avoid dynamic loading issues
local record ReinsModule is tecs.Key<tecs2d.controller.ControlManager>
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
        onJoystickChanged: function(controller: Controller, newJoystick: any, oldJoystick: any)

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
end

local controller: ReinsModule

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

describe("tecs2d.controller", function()
    before_each(function()
        -- Clear mock joysticks
        love2d_mock.clearMockJoysticks()

        -- Clear package cache to force reload with new love mock
        package.loaded["tecs2d.controller"] = nil
        package.loaded["tecs2d"] = nil
        package.loaded["tecs2d.input"] = nil
        package.loaded["tecs2d.internal.handlers"] = nil
        package.loaded["tecs2d.events"] = nil
        package.loaded["tecs2d.debug"] = nil

        -- Set up Love2D mock
        local globalEnv = _G as {string:any}
        globalEnv["love"] = love2d_mock

        -- Use real tecs2d and its input module (no mocking needed)
        controller = require("tecs2d.controller") as ReinsModule

        -- Get access to input module for direct state manipulation
        local tecs2d_input = require("tecs2d.input")
        local inputAny = tecs2d_input as {string:any}

        -- Create a mock wrapper instead of mutating the input module
        mockInput = {} as MockInput

        -- Copy module-level functions
        mockInput.isKeyPressed = inputAny.isKeyPressed as function(string):boolean
        mockInput.isKeyReleased = inputAny.isKeyReleased as function(string):boolean
        mockInput.isKeyDown = inputAny.isKeyDown as function(string):boolean
        mockInput.isMousePressed = inputAny.isMousePressed as function(integer):boolean
        mockInput.isMouseReleased = inputAny.isMouseReleased as function(integer):boolean
        mockInput.isMouseDown = inputAny.isMouseDown as function(integer):boolean
        mockInput.update = inputAny.update as function()
        mockInput.enterFixedPhase = inputAny.enterFixedPhase as function()
        mockInput.exitFixedPhase = inputAny.exitFixedPhase as function()
        mockInput.markLatchedDirty = inputAny.markLatchedDirty as function()
        mockInput.getJoystick = inputAny.getJoystick as function(any):any

        -- Add simulation methods by directly manipulating input state
        mockInput.simulateKeyPress = function(_self, key: string)
            local keysTable = inputAny.keys as {string:any}
            local keysPressedTable = inputAny.keysPressed as {string:any}
            local keysLatchedPressedTable = inputAny.keysLatchedPressed as {string:any}
            keysTable[key] = true
            keysPressedTable[key] = true
            keysLatchedPressedTable[key] = true
            local markLatchedDirtyFn = inputAny.markLatchedDirty as function()
            markLatchedDirtyFn()
        end
        mockInput.simulateKeyDown = function(_self, key: string)
            local keysTable = inputAny.keys as {string:any}
            keysTable[key] = true
        end
        mockInput.simulateKeyRelease = function(_self, key: string)
            local keysTable = inputAny.keys as {string:any}
            local keysReleasedTable = inputAny.keysReleased as {string:any}
            local keysLatchedReleasedTable = inputAny.keysLatchedReleased as {string:any}
            keysTable[key] = nil
            keysReleasedTable[key] = true
            keysLatchedReleasedTable[key] = true
            local markLatchedDirtyFn = inputAny.markLatchedDirty as function()
            markLatchedDirtyFn()
        end
        mockInput.simulateMousePress = function(_self, button: integer)
            local mouseButtonsTable = inputAny.mouseButtons as {integer:any}
            local mousePressedTable = inputAny.mousePressed as {integer:any}
            local mouseLatchedPressedTable = inputAny.mouseLatchedPressed as {integer:any}
            mouseButtonsTable[button] = true
            mousePressedTable[button] = true
            mouseLatchedPressedTable[button] = true
            local markLatchedDirtyFn = inputAny.markLatchedDirty as function()
            markLatchedDirtyFn()
        end
        mockInput.clearFrameEvents = function(_self)
            local updateFn = inputAny.update as function()
            updateFn()
        end
        mockInput.simulateGamepadButton = function(_self, joystick: any, button: string, pressed: boolean)
            local getJoystickFn = inputAny.getJoystick as function(any):any
            local js = getJoystickFn(joystick) as {string:any}
            if pressed then
                local pressedTable = js.gamepadPressed as {string:any}
                local buttonsTable = js.gamepadButtons as {string:any}
                local latchedPressedTable = js.gamepadLatchedPressed as {string:any}
                buttonsTable[button] = true
                pressedTable[button] = true
                latchedPressedTable[button] = true
            else
                local releasedTable = js.gamepadReleased as {string:any}
                local buttonsTable = js.gamepadButtons as {string:any}
                local latchedReleasedTable = js.gamepadLatchedReleased as {string:any}
                buttonsTable[button] = nil
                releasedTable[button] = true
                latchedReleasedTable[button] = true
            end
            local markLatchedDirtyFn = inputAny.markLatchedDirty as function()
            markLatchedDirtyFn()
        end
        mockInput.simulateGamepadAxis = function(_self, joystick: any, axis: string, value: number)
            local getJoystickFn = inputAny.getJoystick as function(any):any
            local js = getJoystickFn(joystick) as {string:any}
            local axisTable = js.gamepadAxis as {string:any}
            axisTable[axis] = value
        end
        mockInput.simulateJoystickHat = function(_self, joystick: any, hat: integer, direction: string)
            local getJoystickFn = inputAny.getJoystick as function(any):any
            local js = getJoystickFn(joystick) as {string:any}
            local hatTable = js.joystickHat as {integer:any}
            hatTable[hat] = direction
        end
        mockInput.clearAll = function(_self)
            -- Clear all input state
            local updateFn = inputAny.update as function()
            updateFn()
        end
        mockInput.getJoystick = function(joystick: any): any
            local getJoystickFn = inputAny.getJoystick as function(any):any
            return getJoystickFn(joystick)
        end
    end)

    after_each(function()
        -- Clean up global Love2D mock
        local globalEnv = _G as {string:any}
        globalEnv["love"] = nil
    end)

    describe("ControlManager", function()
        it("should create a new control manager", function()
            local manager = controller.newManager()
            luassert.is_not_nil(manager)
            luassert.is_table(manager.controllers)
            luassert.equals(0, #manager.controllers)
        end)

        it("should add a controller with bindings", function()
            local manager = controller.newManager()
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
            local manager = controller.newManager()
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
        local ctrl: ReinsModule.Controller

        before_each(function()
            manager = controller.newManager()
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
            ctrl = manager:addController(bindings)
        end)

        it("should detect key presses", function()
            mockInput:simulateKeyPress("space")
            luassert.is_true(ctrl:isPressed("jump"))
            luassert.is_true(ctrl:isDown("jump"))

            mockInput:clearFrameEvents()
            luassert.is_false(ctrl:isPressed("jump"))
            luassert.is_true(ctrl:isDown("jump"))
        end)

        it("should detect key releases", function()
            mockInput:simulateKeyDown("space")
            luassert.is_false(ctrl:isReleased("jump"))

            mockInput:simulateKeyRelease("space")
            luassert.is_true(ctrl:isReleased("jump"))
            luassert.is_false(ctrl:isDown("jump"))
        end)

        it("should detect mouse button presses", function()
            mockInput:simulateMousePress(1)
            luassert.is_true(ctrl:isPressed("attack"))
            luassert.is_true(ctrl:isDown("attack"))
            luassert.equals(1, ctrl:getRaw("attack"))
        end)

        it("should support multiple bindings for same action", function()
            -- Test keyboard binding
            mockInput:simulateKeyPress("z")
            luassert.is_true(ctrl:isPressed("attack"))
            mockInput:clearAll()

            -- Test mouse binding
            mockInput:simulateMousePress(1)
            luassert.is_true(ctrl:isPressed("attack"))
        end)

        it("should handle button pairs correctly", function()
            -- No input
            local x, y = ctrl:getPair("move") as (number, number)
            luassert.equals(0, x)
            luassert.equals(0, y)

            -- Left pressed
            mockInput:simulateKeyDown("a")
            x, y = ctrl:getPair("move") as (number, number)
            luassert.equals(-1, x)
            luassert.equals(0, y)

            -- Right also pressed (cancels out)
            mockInput:simulateKeyDown("d")
            x, y = ctrl:getPair("move") as (number, number)
            luassert.equals(0, x)
            luassert.equals(0, y)

            -- Clear and test vertical
            mockInput:clearAll()
            mockInput:simulateKeyDown("w")
            x, y = ctrl:getPair("move") as (number, number)
            luassert.equals(0, x)
            luassert.equals(-1, y)

            mockInput:simulateKeyDown("s")
            x, y = ctrl:getPair("move") as (number, number)
            luassert.equals(0, x)
            luassert.equals(0, y)
        end)
    end)

    describe("Gamepad Support", function()
        local manager: ReinsModule.ControlManager
        local joystick: any  -- Mock joystick, type varies

        before_each(function()
            manager = controller.newManager()
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

        it("preserves analog magnitude in pairs", function()
            local bindings = {
                controls = {
                    left = {"axis:leftx-"},
                    right = {"axis:leftx+"},
                    up = {"axis:lefty-"},
                    down = {"axis:lefty+"},
                },
                pairs = {
                    move = {"left", "right", "up", "down"},
                },
            }
            local controller = manager:addController(bindings, {joystick = joystick, deadzone = 0.25})

            mockInput:simulateGamepadAxis(joystick, "leftx", 0.6)
            mockInput:simulateGamepadAxis(joystick, "lefty", -0.4)
            local x, y = controller:getPair("move") as (number, number)
            luassert.is_near(0.6, x, 0.001)
            luassert.is_near(-0.4, y, 0.001)
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

        it("should handle diagonal hat directions", function()
            local bindings = {
                controls = {
                    upLeft = {"hat:1lu"},
                    downRight = {"hat:1rd"}
                },
                pairs = {}
            }

            local controller = manager:addController(bindings, {joystick = joystick})

            mockInput:simulateJoystickHat(joystick, 1, "lu")
            luassert.is_true(controller:isDown("upLeft"))
            luassert.is_false(controller:isDown("downRight"))

            mockInput:simulateJoystickHat(joystick, 1, "rd")
            luassert.is_false(controller:isDown("upLeft"))
            luassert.is_true(controller:isDown("downRight"))
        end)

        it("should reject malformed hat bindings", function()
            local bindings = {
                controls = { bad = {"hat:xu"} },
                pairs = {}
            }
            luassert.has_error(function()
                manager:addController(bindings, {joystick = joystick})
            end)
        end)
    end)

    describe("Auto-Assignment Modes", function()
        local manager: ReinsModule.ControlManager

        before_each(function()
            manager = controller.newManager()
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
            manager = controller.newManager()
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
            manager = controller.newManager()
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
            manager = controller.newManager()
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
        local ctrl: ReinsModule.Controller

        before_each(function()
            manager = controller.newManager()
            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }
            ctrl = manager:addController(bindings)
        end)

        it("should switch to auto-assignment mode", function()
            ctrl:resetJoystick({auto = true})
            luassert.is_true(ctrl.auto)

            -- Should pick up next available joystick
            local joystick = love2d_mock.createMockJoystick("guid-auto", "Auto Controller")
            love2d_mock.addMockJoystick(joystick)
            manager:onJoystickAdded(joystick)

            luassert.equals(joystick, ctrl.joystick)
        end)

        it("should disable auto-assignment mode", function()
            ctrl:resetJoystick({auto = false})
            luassert.is_false(ctrl.auto)

            -- Shouldn't pick up a joystick
            local joystick = love2d_mock.createMockJoystick("guid-different", "Different Controller")
            love2d_mock.addMockJoystick(joystick)
            manager:onJoystickAdded(joystick)

            luassert.is_nil(ctrl.joystick)
        end)

        it("should switch to specific joystick", function()
            local joystick1 = love2d_mock.createMockJoystick("guid-1", "Controller 1")
            local joystick2 = love2d_mock.createMockJoystick("guid-2", "Controller 2")
            love2d_mock.addMockJoystick(joystick1)
            love2d_mock.addMockJoystick(joystick2)

            ctrl:resetJoystick({joystick = joystick1})
            luassert.equals(joystick1, ctrl.joystick)
            luassert.is_false(ctrl.auto)

            ctrl:resetJoystick({joystick = joystick2})
            luassert.equals(joystick2, ctrl.joystick)
        end)

        it("should disconnect joystick when nil", function()
            local joystick = love2d_mock.createMockJoystick("guid-disc", "Controller")
            ctrl:resetJoystick({joystick = joystick})
            luassert.equals(joystick, ctrl.joystick)

            ctrl:resetJoystick(nil)
            luassert.is_nil(ctrl.joystick)
            luassert.is_false(ctrl.auto)
        end)


        it("should update partial config without changing joystick", function()
            local joystick = love2d_mock.createMockJoystick("guid-test", "Test Controller")
            love2d_mock.addMockJoystick(joystick)

            -- Start with specific settings
            ctrl:resetJoystick({
                joystick = joystick,
                deadzone = 0.2
            })
            luassert.equals(joystick, ctrl.joystick)
            luassert.equals(0.2, ctrl.deadzone)
            luassert.is_false(ctrl.auto)

            -- Update just deadzone
            ctrl:resetJoystick({
                joystick = joystick,
                deadzone = 0.4
            })
            luassert.equals(joystick, ctrl.joystick)  -- Still same joystick
            luassert.equals(0.4, ctrl.deadzone)  -- Updated deadzone

            -- Switch to auto mode - should try to auto-assign
            ctrl:resetJoystick({
                auto = true
            })
            luassert.equals(joystick, ctrl.joystick)  -- Should auto-assign the available joystick
            luassert.is_true(ctrl.auto)
            luassert.equals(0.4, ctrl.deadzone)  -- Preserved from before
        end)
    end)

    describe("Runtime Rebinding", function()
        it("should change bindings at runtime", function()
            local manager = controller.newManager()
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
            local manager = controller.newManager()
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

    describe("Joystick Callbacks", function()
        it("should trigger onJoystickChanged when joystick is assigned", function()
            local manager = controller.newManager()
            local joystick = love2d_mock.createMockJoystick("test-guid", "Test Controller")
            love2d_mock.addMockJoystick(joystick)

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            local controller = manager:addController(bindings)
            local callbackCalled = false
            local receivedNew: any = nil
            local receivedOld: any = nil

            controller.onJoystickChanged = function(
                _ctrl: ReinsModule.Controller,
                newJoystick: any,
                oldJoystick: any
            )
                callbackCalled = true
                receivedNew = newJoystick
                receivedOld = oldJoystick
            end

            controller:setJoystick(joystick)
            luassert.is_true(callbackCalled)
            luassert.equals(joystick, receivedNew)
            luassert.is_nil(receivedOld)
        end)

        it("should trigger onJoystickChanged when joystick is removed", function()
            local manager = controller.newManager()
            local joystick = love2d_mock.createMockJoystick("test-guid", "Test Controller")
            love2d_mock.addMockJoystick(joystick)

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            local controller = manager:addController(bindings, {joystick = joystick})

            local callbackCalled = false
            local receivedNew: any = nil
            local receivedOld: any = nil

            controller.onJoystickChanged = function(
                _ctrl: ReinsModule.Controller,
                newJoystick: any,
                oldJoystick: any
            )
                callbackCalled = true
                receivedNew = newJoystick
                receivedOld = oldJoystick
            end

            controller:setJoystick(nil)
            luassert.is_true(callbackCalled)
            luassert.is_nil(receivedNew)
            luassert.equals(joystick, receivedOld)
        end)

        it("should not trigger onJoystickChanged when set to same joystick", function()
            local manager = controller.newManager()
            local joystick = love2d_mock.createMockJoystick("test-guid", "Test Controller")
            love2d_mock.addMockJoystick(joystick)

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            local controller = manager:addController(bindings, {joystick = joystick})

            local callbackCalled = false
            controller.onJoystickChanged = function()
                callbackCalled = true
            end

            -- Set to the same joystick
            controller:setJoystick(joystick)
            luassert.is_false(callbackCalled)
        end)
    end)

    describe("Rumble", function()
        it("should call notifyWithRumble without error when joystick supports vibration", function()
            local manager = controller.newManager()
            local joystick = love2d_mock.createMockJoystick("test-guid", "Test Controller")
            love2d_mock.addMockJoystick(joystick)

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            local controller = manager:addController(bindings, {joystick = joystick})

            luassert.has_no_errors(function()
                controller:notifyWithRumble(0.5, 0.3)
            end, "notifyWithRumble should not error", nil)
        end)

        it("should not error when notifyWithRumble is called without joystick", function()
            local manager = controller.newManager()

            local bindings = {
                controls = { jump = {"button:a"} },
                pairs = {}
            }

            local controller = manager:addController(bindings)

            luassert.has_no_errors(function()
                controller:notifyWithRumble()
            end, "notifyWithRumble should not error without joystick", nil)
        end)
    end)

    describe("Button Pairs", function()
        it("should return 0,0 for undefined pair", function()
            local manager = controller.newManager()
            local bindings = {
                controls = {
                    left = {"key:a"},
                    right = {"key:d"}
                },
                pairs = {}  -- No pairs defined
            }

            local controller = manager:addController(bindings)
            local x, y = controller:getPair("undefined_pair") as (number, number)
            luassert.equals(0, x)
            luassert.equals(0, y)
        end)
    end)

    describe("Bindings Validation", function()
        it("should reject invalid binding formats", function()
            local manager = controller.newManager()
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
            local manager = controller.newManager()
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
            local manager = controller.newManager()
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
            local manager = controller.newManager()
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

        it("should reject invalid hat binding format", function()
            local manager = controller.newManager()
            local invalidBindings = {
                controls = {
                    test = {"hat:x"}  -- Invalid: missing hat number
                },
                pairs = {}
            }

            luassert.has_error(function()
                manager:addController(invalidBindings)
            end, "Invalid hat binding for button 'test': 'hat:x' (expected format 'hat:indexdirection', e.g., 'hat:1u')")
        end)

        it("should reject empty hat binding", function()
            local manager = controller.newManager()
            local invalidBindings = {
                controls = {
                    test = {"hat:"}  -- Invalid: empty value
                },
                pairs = {}
            }

            luassert.has_error(function()
                manager:addController(invalidBindings)
            end, "Invalid binding format for button 'test': 'hat:' (expected 'source:value')")
        end)
    end)

    describe("Plugin", function()
        it("should create a plugin function", function()
            local plugin = controller.plugin()
            luassert.is_function(plugin)
        end)

        it("should set up world resources when applied", function()
            local world = tecs.newWorld()
            local plugin = controller.plugin()
            plugin(world)

            local manager = world.resources[controller]
            luassert.is_not_nil(manager)
            luassert.is_table(manager.controllers)
        end)

        it("should store world reference in manager", function()
            local world = tecs.newWorld()
            local plugin = controller.plugin()
            plugin(world)

            -- Check that manager has reference to world
            local manager = world.resources[controller]
            luassert.is_not_nil(manager._world)
            luassert.equals(world, manager._world)
        end)
    end)

    describe("getRaw edge cases", function()
        it("should return 0 for undefined button", function()
            local manager = controller.newManager()
            local bindings = {
                controls = { jump = {"key:space"} },
                pairs = {}
            }

            local controller = manager:addController(bindings)
            luassert.equals(0, controller:getRaw("undefined_button"))
        end)

        it("should return 0 for isDown on undefined button", function()
            local manager = controller.newManager()
            local bindings = {
                controls = { jump = {"key:space"} },
                pairs = {}
            }

            local controller = manager:addController(bindings)
            luassert.is_false(controller:isDown("undefined_button"))
        end)

        it("should return false for isPressed on undefined button", function()
            local manager = controller.newManager()
            local bindings = {
                controls = { jump = {"key:space"} },
                pairs = {}
            }

            local controller = manager:addController(bindings)
            luassert.is_false(controller:isPressed("undefined_button"))
        end)

        it("should return false for isReleased on undefined button", function()
            local manager = controller.newManager()
            local bindings = {
                controls = { jump = {"key:space"} },
                pairs = {}
            }

            local controller = manager:addController(bindings)
            luassert.is_false(controller:isReleased("undefined_button"))
        end)
    end)
end)