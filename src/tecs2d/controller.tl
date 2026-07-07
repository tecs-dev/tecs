--[[
This module provides rebindable controllers for a game.

## Controllers and Controller

Controllers manages the Controller objects of a game. Each Controller object
represents a player, and can be bound to a keyboard, mouse, and joystick.

## Bindings

Bindings of this module are based on baton.lua: https://github.com/tesselode/baton, with the following differences:

- Raw axis support: Axes can be used without direction suffixes to get full -1 to 1 range
- No scancode support: scancodes are unnecessary since controls are rebindable
]]

local tecs <const> = require("tecs")
local input <const> = require("tecs2d.input")
local events <const> = require("tecs2d.events")

local sqrt <const> = math.sqrt

local LOGGER <const> = require("tecs.utils.logging").getLogger("tecs2d.controller")

--- Manages the controllers of a game, allowing for rebindable controls.
local record controller is tecs.Key<controller.ControlManager>

    --- Configuration for joystick assignment and behavior.
    record JoystickConfig
        --- Direct joystick assignment.
        joystick: love.joystick.Joystick

        --- Enable auto-assignment. Defaults to false.
        auto: boolean

        --- Axis deadzone threshold (0-1). Defaults to 0.5.
        deadzone: number
    end

    record ControlManager
        --- The controllers of the game.
        controllers: {Controller}

        --- Add a controller.
        --- @param bindings The bindings of the controller.
        --- @param config Optional joystick configuration.
        --- @return the controller.
        addController: function(
            self,
            bindings: Bindings,
            config?: JoystickConfig
        ): Controller

        --- Remove a controller.
        --- @param controller The controller to remove.
        removeController: function(self, controller: Controller)

        --- Get a controller by index.
        --- @param index The index of the controller.
        --- @return The controller or nil.
        get: function(self, index: integer): Controller

        --- Handle joystick connection events (called internally).
        --- @param joystick The newly connected joystick.
        onJoystickAdded: function(self, joystick: love.joystick.Joystick)

        --- Handle joystick disconnection events (called internally).
        --- @param joystick The disconnected joystick.
        onJoystickRemoved: function(self, joystick: love.joystick.Joystick)

        -- Internal state.
        _world: tecs.World
        _tryAutoAssign: function(self, controller: Controller): boolean
        _hasJoystickActivity: function(self, joystick: love.joystick.Joystick): boolean
    end

    --- Input source types, based on baton.lua.
    enum Source
        --- A Love2D key constant.
        --- See http://love2d.org/wiki/KeyConstant
        "key"

        --- A Love2D mouse button (1=primary, 2=secondary, 3=middle, etc).
        --- See https://love2d.org/wiki/love.mouse.isDown
        "mouse"

        --- A joystick or gamepad axis.
        --- Either a number representing a joystick axis or a Love2D GamepadAxis.
        --- Optionally add a '+' or '-' on the end to denote the direction to detect.
        --- Without a suffix, returns the raw axis value (-1 to 1).
        "axis"

        --- A joystick or gamepad button.
        --- Either a number representing a joystick button or a Love2D GamepadButton.
        "button"

        --- A joystick hat.
        --- A number representing a joystick hat and a JoystickHat.
        --- For example '1r' corresponds to the 1st hat pushed right.
        --- See https://love2d.org/wiki/JoystickHat
        "hat"
    end

    --- Binding configuration.
    ---
    --- ## Binding Format
    ---
    --- Each binding is a string in the format "source:value" where:
    ---
    --- - `key:name` - Keyboard key (e.g., "key:space", "key:w")
    --- - `mouse:button` - Mouse button number (e.g., "mouse:1" for left click)
    --- - `button:name` - Gamepad button (e.g., "button:a", "button:start")
    --- - `axis:name` - Raw gamepad axis value from -1 to 1 (e.g., "axis:rightx", "axis:righty")
    --- - `axis:name+` or `axis:name-` - Gamepad axis with direction (e.g., "axis:leftx+", "axis:triggerleft+")
    --- - `hat:indexdirection` - Joystick hat (e.g., "hat:1u" for hat 1 up, "hat:1r" for right)
    ---
    --- ## Axis Bindings
    ---
    --- Axes can be bound in two ways:
    --- - Directional: Add `+` or `-` suffix to detect only positive or negative values
    ---   - `axis:leftx+` detects right movement (positive values)
    ---   - `axis:leftx-` detects left movement (negative values)
    ---   - Values are normalized to 0-1 range with deadzone applied
    --- - Raw: No suffix returns the full axis range from -1 to 1
    ---   - `axis:rightx` returns -1 (left) to 1 (right)
    ---   - `axis:righty` returns -1 (up) to 1 (down)
    ---   - Deadzone is applied to the absolute value
    ---
    --- ## Example
    --- ```lua
    --- local bindings: tecs2d.controller.Bindings = {
    ---     controls = {
    ---         -- Digital inputs
    ---         jump = {"key:space", "button:a"},
    ---         attack = {"key:z", "mouse:1", "button:x"},
    ---
    ---         -- Directional axis inputs (for movement)
    ---         left = {"key:a", "button:dpleft", "axis:leftx-"},
    ---         right = {"key:d", "button:dpright", "axis:leftx+"},
    ---
    ---         -- Raw analog inputs (for aiming, camera control)
    ---         aimX = {"axis:rightx"},  -- Returns -1 to 1
    ---         aimY = {"axis:righty"},  -- Returns -1 to 1
    ---
    ---         -- Triggers (usually only positive values)
    ---         shoot = {"axis:triggerright+"},
    ---         brake = {"axis:triggerleft+"}
    ---     },
    ---     pairs = {
    ---         move = {"left", "right", "up", "down"}
    ---     }
    --- }
    --- ```
    record Bindings
        --- An immutable map of button names to their bindings.
        controls: {string:{string}}

        --- An immutable map of button names to the pairs for the button.
        pairs: {string:{string}}
    end

    record Controller
        --- The bindings of the controller.
        bindings: Bindings

        --- A Love2D joystick. The joystick argument is optional; if it's not specified, or if the joystick becomes
        --- unavailable later, the player object will just ignore controller inputs.
        joystick: love.joystick.Joystick

        --- A number from 0-1 representing the minimum value axes have to cross to be detected.
        deadzone: number

        --- Whether gamepad auto-assignment is enabled for this controller.
        auto: boolean

        --- Optional callback when joystick changes.
        onJoystickChanged: function(
            controller: Controller, newJoystick: love.joystick.Joystick, oldJoystick: love.joystick.Joystick
        )

        --- Check if a button has just been pressed.
        --- @param button The button to check.
        --- @return Whether the button is just pressed.
        isPressed: function(self, button: string): boolean

        --- Check if a button is down (pressed or being held down).
        --- @param button The button to check.
        --- @return Whether the button is down.
        isDown: function(self, button: string): boolean

        --- Check if a button was just released.
        --- @param button The button to check.
        --- @return Whether the button was just released.
        isReleased: function(self, button: string): boolean

        --- Get the pair coordinates of a button.
        --- @param button The button to get the pair coordinates of.
        --- @return The pair X and Y coordinates.
        getPair: function(self, button: string): number, number

        --- Get the normalized pair coordinates of a button.
        --- @param button The button to get the pair coordinates of.
        --- @return The normalized pair X and Y coordinates.
        getPairNormalized: function(self, button: string): number, number

        --- Get the raw value of a control.
        --- - For buttons, keys, and hats: returns 0 (not pressed) or 1 (pressed)
        --- - For directional axes (with + or -): returns 0 to 1
        --- - For raw axes (without suffix): returns -1 to 1
        --- @param button The control name to get the raw value of.
        --- @return The raw numeric value of the control.
        getRaw: function(self, button: string): number

        --- Set the joystick for this controller and optionally trigger rumble.
        --- @param joystick The joystick to assign, or nil to clear.
        setJoystick: function(self, joystick: love.joystick.Joystick)

        --- Reset the joystick assignment.
        --- @param config New joystick configuration, or nil to disconnect.
        resetJoystick: function(self, config?: JoystickConfig)

        --- Rebind the controller with new bindings at runtime.
        --- @param bindings The new bindings for the controller.
        rebind: function(self, bindings: Bindings)

        --- Trigger a rumble notification on the controller.
        --- @param strength The rumble strength (0-1), defaults to 0.5.
        --- @param duration The rumble duration in seconds, defaults to 0.2.
        notifyWithRumble: function(self, strength?: number, duration?: number)

        -- Internal state.
        _isPressedGetters: {string: {function(Controller): boolean}}
        _isDownGetters: {string: {function(Controller): number}}
        _isReleasedGetters: {string: {function(Controller): boolean}}
        _manager: ControlManager
    end

    --- Create a new Controller manager.
    --- @return The new Controller manager.
    newManager: function(): ControlManager

    --- Create a Tecs plugin that integrates tecs2d.controller with joystick events.
    --- @return The plugin function.
    plugin: function(): tecs.Plugin
end

local ControlManager = controller.ControlManager
local Controller = controller.Controller
local Bindings = controller.Bindings
local JoystickConfig = controller.JoystickConfig

--------------------------------------------------------------------------------
-- Controller binding factories
--------------------------------------------------------------------------------

-- Factory functions for creating binding getters
local record BindingGetters
    isPressed: function(Controller): boolean
    isReleased: function(Controller): boolean
    isDown: function(Controller): number
end

local type BindingFactory = function(string, string): BindingGetters

local function createKeyBinding(key: string, _button: string): BindingGetters
    return {
        isPressed = function(): boolean
            return input.isKeyPressed(key)
        end,
        isReleased = function(): boolean
            return input.isKeyReleased(key)
        end,
        isDown = function(): number
            return input.isKeyDown(key) and 1 or 0
        end
    }
end

-- Mouse binding factory
local function createMouseBinding(value: string, _button: string): BindingGetters
    local buttonIndex = tonumber(value) as integer
    return {
        isPressed = function(): boolean
            return input.isMousePressed(buttonIndex)
        end,
        isReleased = function(): boolean
            return input.isMouseReleased(buttonIndex)
        end,
        isDown = function(): number
            return input.isMouseDown(buttonIndex) and 1 or 0
        end
    }
end

-- Gamepad button binding factory
local function createButtonBinding(value: string, _button: string): BindingGetters
    local gamepadButton = value as love.joystick.GamepadButton
    return {
        isPressed = function(self: Controller): boolean
            return self.joystick
                and input.getJoystick(self.joystick):isGamepadButtonPressed(gamepadButton)
                or false
        end,
        isReleased = function(self: Controller): boolean
            return self.joystick
                and input.getJoystick(self.joystick):isGamepadButtonReleased(gamepadButton)
                or false
        end,
        isDown = function(self: Controller): number
            return self.joystick
                and input.getJoystick(self.joystick):isGamepadButtonDown(gamepadButton)
                and 1 or 0
        end
    }
end

local function createAxisBinding(value: string, _button: string): BindingGetters
    local direction = value:sub(-1)
    local axis: love.joystick.GamepadAxis
    local multiplier: integer

    -- Check if this has a direction suffix (+ or -)
    if direction == "+" or direction == "-" then
        axis = value:sub(1, -2) as love.joystick.GamepadAxis
        multiplier = direction == "+" and 1 or -1
    else
        -- No direction suffix, treat as raw axis
        axis = value as love.joystick.GamepadAxis
        multiplier = 0
    end

    -- Pick the right getter based on the optionally present directional suffix
    local getAxisValue: function(Controller): number = nil
    if multiplier == 0 then
        getAxisValue = function(ctrl: Controller): number
            if not ctrl.joystick then
                return 0
            end
            local axisValue = input.getJoystick(ctrl.joystick).gamepadAxis[axis] or 0
            -- Raw axis value, apply deadzone to absolute value
            if math.abs(axisValue) >= ctrl.deadzone then
                return axisValue
            else
                return 0
            end
        end
    elseif multiplier == 1 then
        getAxisValue = function(ctrl: Controller): number
            if not ctrl.joystick then
                return 0
            end
            local axisValue = input.getJoystick(ctrl.joystick).gamepadAxis[axis] or 0
            -- Positive direction: only return positive values
            local positiveValue = math.max(0, axisValue)
            return positiveValue >= ctrl.deadzone and positiveValue or 0
        end
    else
        getAxisValue = function(ctrl: Controller): number
            if not ctrl.joystick then
                return 0
            end

            local axisValue = input.getJoystick(ctrl.joystick).gamepadAxis[axis] or 0
            -- Negative direction: convert negative to positive
            local negativeValue = math.max(0, -axisValue)
            return negativeValue >= ctrl.deadzone and negativeValue or 0
        end
    end

    -- Axes don't have pressed/released states, only continuous values
    return {
        isPressed = function(_self: Controller): boolean return false end,
        isReleased = function(_self: Controller): boolean return false end,
        isDown = getAxisValue
    }
end

local function createHatBinding(value: string, button: string): BindingGetters
    if (not value) or #value < 2 then
        error(string.format(
            "Invalid hat binding for button '%s': 'hat:%s' (expected format 'hat:indexdirection', e.g., 'hat:1u')",
            button, tostring(value)))
    end

    local hatStr, directionStr = value:match("^(%d+)(%a+)$")
    if not hatStr then
        error(string.format(
            "Invalid hat binding for button '%s': 'hat:%s' (expected format 'hat:indexdirection', e.g., 'hat:1u')",
            button, value))
    end
    local hat = tonumber(hatStr) as integer
    local direction = directionStr as love.joystick.JoystickHat

    -- Hats only support isDown
    return {
        isPressed = function(_self: Controller): boolean
            return false
        end,
        isReleased = function(_self: Controller): boolean
            return false
        end,
        isDown = function(self: Controller): number
            return self.joystick
                and input.getJoystick(self.joystick).joystickHat[hat] == direction
                and 1 or 0
        end
    }
end

-- Map of binding types to their factory functions
local BINDING_FACTORIES <const>: {string: BindingFactory} = {
    key = createKeyBinding,
    mouse = createMouseBinding,
    button = createButtonBinding,
    axis = createAxisBinding,
    hat = createHatBinding
}

local function buildBindings(self: Controller, bindings: Bindings)
    -- Clear any existing bindings
    self._isPressedGetters = {}
    self._isDownGetters = {}
    self._isReleasedGetters = {}

    -- Parse sources and add bindings.
    for button, sources in pairs(bindings.controls) do
        -- Initialize getter arrays for this button if needed
        self._isPressedGetters[button] = self._isPressedGetters[button] or {}
        self._isReleasedGetters[button] = self._isReleasedGetters[button] or {}
        self._isDownGetters[button] = self._isDownGetters[button] or {}

        for si = 1, #sources do
            local source = sources[si]
            local bindingType, bindingValue = source:match("([^:]+):([^:]+)")
            if not bindingType or not bindingValue then
                error(string.format(
                    "Invalid binding format for button '%s': '%s' (expected 'source:value')",
                    button, source))
            end

            local factory = BINDING_FACTORIES[bindingType]
            if not factory then
                error(string.format(
                    "Unknown binding source '%s' for button '%s' (valid sources: key, mouse, button, axis, hat)",
                    bindingType, button))
            end

            LOGGER:debug("Binding %s %s to %s", bindingType, bindingValue, button)

            local getters = factory(bindingValue, button)
            table.insert(self._isPressedGetters[button], getters.isPressed)
            table.insert(self._isReleasedGetters[button], getters.isReleased)
            table.insert(self._isDownGetters[button], getters.isDown)
        end
    end
end

--------------------------------------------------------------------------------
-- Controller
--------------------------------------------------------------------------------

local CONTROLLER_MT <const>: metatable<Controller> = {
    __index = Controller
}

function Controller.new(
    bindings: Bindings,
    manager: ControlManager,
    config?: JoystickConfig
): Controller
    config = config or {}

    local self: Controller = {
        bindings = assert(bindings, "Controller bindings are required"),
        joystick = nil,
        deadzone = config.deadzone or 0.5,
        auto = config.auto or false,
        onJoystickChanged = nil,
        _isPressedGetters = {},
        _isDownGetters = {},
        _isReleasedGetters = {},
        _manager = manager,
    }
    setmetatable(self, CONTROLLER_MT)

    buildBindings(self, bindings)

    -- Handle joystick assignment
    if config.joystick then
        self.auto = false
        self:setJoystick(config.joystick)
    elseif self.auto then
        manager:_tryAutoAssign(self)
    end

    return self
end

local function callGetters(self: Controller, getters: {function(Controller): boolean}): boolean
    if not getters then
        return false
    end
    for i = 1, #getters do
        if getters[i](self) then
            return true
        end
    end
    return false
end

function Controller:isPressed(button: string): boolean
    return callGetters(self, self._isPressedGetters[button])
end

function Controller:isReleased(button: string): boolean
    return callGetters(self, self._isReleasedGetters[button])
end

function Controller:getRaw(button: string): number
    local getters = self._isDownGetters[button]
    if not getters then
        return 0
    end
    for i = 1, #getters do
        local value = getters[i](self)
        if value ~= 0 then
            return value
        end
    end
    return 0
end

function Controller:isDown(button: string): boolean
    return self:getRaw(button) ~= 0
end

function Controller:getPair(name: string): number, number
    local pairButtons = self.bindings.pairs[name]
    local x, y = 0.0, 0.0
    if pairButtons then
        -- Analog magnitudes preserved: an axis binding at half deflection
        -- contributes 0.5, digital bindings contribute 0 or 1. Opposites
        -- cancel by subtraction; clamp so combined bindings can't exceed
        -- a unit deflection per axis.
        x = self:getRaw(pairButtons[2]) - self:getRaw(pairButtons[1])
        y = self:getRaw(pairButtons[4]) - self:getRaw(pairButtons[3])
        if x > 1 then x = 1 elseif x < -1 then x = -1 end
        if y > 1 then y = 1 elseif y < -1 then y = -1 end
    end
    return x, y
end

function Controller:getPairNormalized(name: string): number, number
    local x, y = self:getPair(name)
    local mag2 = x * x + y * y
    if mag2 > 0 then
        local inv = 1.0 / sqrt(mag2)
        x, y = x * inv, y * inv
    end
    return x, y
end

function Controller:rebind(bindings: Bindings)
    self.bindings = assert(bindings, "Controller bindings are required")
    buildBindings(self, bindings)
end

function Controller:notifyWithRumble(strength?: number, duration?: number)
    if self.joystick and self.joystick:isVibrationSupported() then
        strength = strength or 0.5
        duration = duration or 0.2
        self.joystick:setVibration(strength, strength, duration)
    end
end

function Controller:setJoystick(joystick: love.joystick.Joystick)
    local oldJoystick = self.joystick
    self.joystick = joystick

    -- Call callback if joystick changed
    if oldJoystick ~= joystick and self.onJoystickChanged then
        self.onJoystickChanged(self, joystick, oldJoystick)
    end

    if joystick then
        self:notifyWithRumble()
    end
end

function Controller:resetJoystick(config?: JoystickConfig)
    self:setJoystick(nil)

    if not config then
        self.auto = false
        return
    end

    if config.deadzone then
        self.deadzone = config.deadzone
    end

    if config.auto ~= nil then
        self.auto = config.auto
    end

    -- Handle joystick assignment
    if config.joystick then
        self.auto = false
        self:setJoystick(config.joystick)
    elseif self.auto then
        self._manager:_tryAutoAssign(self)
    end
end

--------------------------------------------------------------------------------
-- ControlManager
--------------------------------------------------------------------------------

local CONTROLLER_MANAGER_MT <const>: metatable<ControlManager> = {
    __index = ControlManager
}

function ControlManager.new(): ControlManager
    local self = {
        controllers = {},
        _world = nil
    }
    return setmetatable(self, CONTROLLER_MANAGER_MT)
end

function ControlManager:addController(
    bindings: Bindings,
    config?: JoystickConfig
): Controller
    local ctrl = Controller.new(bindings, self, config)
    table.insert(self.controllers, ctrl)
    return ctrl
end

function ControlManager:_hasJoystickActivity(joystick: love.joystick.Joystick): boolean
    local js = input.getJoystick(joystick)

    -- Check for any button activity (we don't care about press vs release)
    if next(js.gamepadButtons) then
        LOGGER:debug("Detected gamepad button activity on joystick %s", joystick:getGUID())
        return true
    end

    if next(js.joystickButtons) then
        LOGGER:debug("Detected joystick button activity on joystick %s", joystick:getGUID())
        return true
    end

    -- Check for significant axis movement
    local axisThreshold = 0.5
    for axis, value in pairs(js.gamepadAxis) do
        if math.abs(value) > axisThreshold then
            LOGGER:debug("Detected axis activity on joystick %s: axis %s at %f", joystick:getGUID(), axis, value)
            return true
        end
    end

    return false
end

function ControlManager:_tryAutoAssign(ctrl: Controller): boolean
    if not ctrl.auto then
        return false
    end

    -- Find available joysticks
    local candidates = {}
    local activeCandidate: love.joystick.Joystick = nil

    local joysticks <const> = love.joystick.getJoysticks()
    local controllers <const> = self.controllers
    for i = 1, #joysticks do
        local js = joysticks[i]
        -- Check if this joystick is already assigned to another controller
        local alreadyAssigned = false
        for j = 1, #controllers do
            local otherController = controllers[j]
            if otherController.joystick == js and otherController ~= ctrl then
                alreadyAssigned = true
                break
            end
        end

        if not alreadyAssigned then
            table.insert(candidates, js)

            -- Check for activity on this joystick
            if not activeCandidate and self:_hasJoystickActivity(js) then
                activeCandidate = js
                LOGGER:debug("Found active joystick %s for auto-assignment", js:getName())
            end
        end
    end

    if #candidates == 0 then
        return false
    end

    -- Prefer joystick with activity, otherwise take first available
    local chosen = activeCandidate or candidates[1]

    -- Assign the joystick
    ctrl:setJoystick(chosen)
    LOGGER:debug("Auto-assigned joystick %s to controller", chosen:getName())

    return true
end

function ControlManager:onJoystickAdded(joystick: love.joystick.Joystick)
    -- Find the first auto controller without a joystick
    local ctrls <const> = self.controllers
    for i = 1, #ctrls do
        local ctrl = ctrls[i]
        if ctrl.auto and not ctrl.joystick then
            ctrl:setJoystick(joystick)
            LOGGER:debug("Assigned joystick %s to controller", joystick:getName())
            return
        end
    end
end

function ControlManager:onJoystickRemoved(joystick: love.joystick.Joystick)
    -- Clear every controller using this joystick (manual setJoystick can share one)
    local ctrls <const> = self.controllers
    for i = 1, #ctrls do
        local ctrl = ctrls[i]
        if ctrl.joystick == joystick then
            ctrl:setJoystick(nil)
            LOGGER:debug("Disconnected joystick %s from controller", joystick:getName())
        end
    end
end

function ControlManager:removeController(ctrl: Controller)
    for i = #self.controllers, 1, -1 do
        if self.controllers[i] == ctrl then
            table.remove(self.controllers, i)
            break
        end
    end
end

function ControlManager:get(index: integer): Controller
    return index and self.controllers[index]
end

function controller.newManager(): ControlManager
    return ControlManager.new()
end

--------------------------------------------------------------------------------
-- Plugin
--------------------------------------------------------------------------------

function controller.plugin(): tecs.Plugin
    return function(w: tecs.World)
        local manager = controller.newManager()

        -- Store the manager in world resources
        w.resources[controller] = manager

        -- Store world reference for event emission
        manager._world = w

        -- Set up joystick event handling
        w:addSystem({
            name = "tecs2d.controller.joystickEventSetup",
            phase = tecs.phases.Startup,
            run = function()
                -- Observe joystick connection events
                w:observe(0, events.JoystickAdded, function(event: events.JoystickAdded)
                    manager:onJoystickAdded(event.joystick)
                end)

                -- Observe joystick disconnection events
                w:observe(0, events.JoystickRemoved, function(event: events.JoystickRemoved)
                    manager:onJoystickRemoved(event.joystick)
                end)
            end
        })
    end
end

return controller
