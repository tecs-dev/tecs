--[[
This module provides rebindable controllers for a game.

## Controllers and Controller

Controllers manages the Controller objects of a game. Each Controller object
represents a player, and can be bound to a keyboard, mouse, and joystick.

## Bindings

Bindings of this module are based on baton.lua: https://github.com/tesselode/baton, with the following differences:

- Raw axis support: Axes can be used without direction suffixes to get full -1 to 1 range
- No scancode support: The "sc" (scancode) binding type is not supported
]]--

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local input <const> = tecs2d.input

local LOGGER <const> = tecs.logging.getLogger("tecs2d.Controllers")

--- Manages the controllers of a game, allowing for rebindable controls.
local record tecs_controller

    CONTROLLER: tecs.Key<ControlManager>

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
    --- local bindings: reins.Bindings = {
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
        onJoystickChanged: function(controller: Controller, newJoystick: love.joystick.Joystick, oldJoystick: love.joystick.Joystick)

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

    --- Plugin configuration for Reins.
    record PluginConfig
        --- The control manager to use. If not provided, one will be created.
        manager: ControlManager
    end

    --- Create a Tecs plugin that integrates Reins with joystick events.
    --- @param config The plugin configuration.
    --- @return The plugin function.
    plugin: function(config?: PluginConfig): tecs.Plugin
end

tecs_controller.CONTROLLER = tecs.newKey()
local ControlManager = tecs_controller.ControlManager
local Controller = tecs_controller.Controller
local Bindings = tecs_controller.Bindings
local JoystickConfig = tecs_controller.JoystickConfig

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
        getAxisValue = function(controller: Controller): number
            if not controller.joystick then
                return 0
            end
            local axisValue = input.getJoystick(controller.joystick).gamepadAxis[axis] or 0
            -- Raw axis value, apply deadzone to absolute value
            if math.abs(axisValue) >= controller.deadzone then
                return axisValue
            else
                return 0
            end
        end
    elseif multiplier == 1 then
        getAxisValue = function(controller: Controller): number
            if not controller.joystick then
                return 0
            end
            local axisValue = input.getJoystick(controller.joystick).gamepadAxis[axis] or 0
            -- Positive direction: only return positive values
            local positiveValue = math.max(0, axisValue)
            return positiveValue >= controller.deadzone and positiveValue or 0
        end
    else
        getAxisValue = function(controller: Controller): number
            if not controller.joystick then
                return 0
            end

            local axisValue = input.getJoystick(controller.joystick).gamepadAxis[axis] or 0
            -- Negative direction: convert negative to positive
            local negativeValue = math.max(0, -axisValue)
            return negativeValue >= controller.deadzone and negativeValue or 0
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

    local hat = tonumber(value:sub(1, -2)) as integer
    local direction = value:sub(-1) as love.joystick.JoystickHat

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

        for _, source in ipairs(sources) do
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
    for _, getter in ipairs(getters) do
        if getter(self) then
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
    local x, y = 0, 0
    if pairButtons then
        local left = self:isDown(pairButtons[1])
        local right = self:isDown(pairButtons[2])
        local up = self:isDown(pairButtons[3])
        local down = self:isDown(pairButtons[4])

        -- Opposites cancel out
        if left and not right then
            x = -1
        elseif right and not left then
            x = 1
        end

        if up and not down then
            y = -1
        elseif down and not up then
            y = 1
        end
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
    local controller = Controller.new(bindings, self, config)
    table.insert(self.controllers, controller)
    return controller
end

function ControlManager:_hasJoystickActivity(joystick: love.joystick.Joystick): boolean
    local js = input.getJoystick(joystick)
    if not js then
        return false
    end

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

function ControlManager:_tryAutoAssign(controller: Controller): boolean
    if not controller.auto then
        return false
    end

    -- Find available joysticks
    local candidates = {}
    local activeCandidate: love.joystick.Joystick = nil

    for _, js in ipairs(love.joystick.getJoysticks()) do
        -- Check if this joystick is already assigned to another controller
        local alreadyAssigned = false
        for _, otherController in ipairs(self.controllers) do
            if otherController.joystick == js and otherController ~= controller then
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
    controller:setJoystick(chosen)
    LOGGER:debug("Auto-assigned joystick %s to controller", chosen:getName())

    return true
end

function ControlManager:onJoystickAdded(joystick: love.joystick.Joystick)
    local hasActivity = self:_hasJoystickActivity(joystick)

    -- Find the best controller to assign this joystick to
    local bestMatch: Controller = nil

    -- If there's activity, prefer the first auto controller without a joystick
    if hasActivity then
        for _, controller in ipairs(self.controllers) do
            if controller.auto and not controller.joystick then
                bestMatch = controller
                break
            end
        end
    end

    -- Otherwise, just find any auto controller without a joystick
    if not bestMatch then
        for _, controller in ipairs(self.controllers) do
            if controller.auto and not controller.joystick then
                bestMatch = controller
                break
            end
        end
    end

    if bestMatch then
        bestMatch:setJoystick(joystick)
        LOGGER:debug(
            "Assigned joystick %s to controller%s",
            joystick:getName(), hasActivity and " - detected activity" or ""
        )
    end
end

function ControlManager:onJoystickRemoved(joystick: love.joystick.Joystick)
    -- Find controller using this joystick and clear it
    for _, controller in ipairs(self.controllers) do
        if controller.joystick == joystick then
            controller:setJoystick(nil)
            LOGGER:debug("Disconnected joystick %s from controller", joystick:getName())
            return
        end
    end
end

function ControlManager:removeController(controller: Controller)
    for i = #self.controllers, 1, -1 do
        if self.controllers[i] == controller then
            table.remove(self.controllers, i)
            break
        end
    end
end

function ControlManager:get(index: integer): Controller
    return index and self.controllers[index]
end

function tecs_controller.newManager(): ControlManager
    return ControlManager.new()
end

--------------------------------------------------------------------------------
-- Plugin
--------------------------------------------------------------------------------

function tecs_controller.plugin(config?: tecs_controller.PluginConfig): tecs.Plugin
    config = config or {}

    return function(w: tecs.World)

        -- Get or create the control manager
        local manager: ControlManager
        if config.manager then
            manager = config.manager
        else
            manager = tecs_controller.newManager()
        end

        -- Store the manager in world resources
        w.resources[tecs_controller.CONTROLLER] = manager

        -- Store world reference for event emission
        manager._world = w

        -- Set up joystick event handling
        w:addSystem({
            name = "tecs_controller.joystickEventSetup",
            phase = tecs.phases.Startup,
            run = function()
                -- Observe joystick connection events
                w:observe(tecs2d.events.JoystickAdded, function(event: tecs2d.events.JoystickAdded)
                    manager:onJoystickAdded(event.joystick)
                end)

                -- Observe joystick disconnection events
                w:observe(tecs2d.events.JoystickRemoved, function(event: tecs2d.events.JoystickRemoved)
                    manager:onJoystickRemoved(event.joystick)
                end)
            end
        })
    end
end

return tecs_controller
