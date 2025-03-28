local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local controller <const> = require("tecs_controller")

local lg <const> = love.graphics

local record GamepadDemoPlugin
    world: tecs.World
    controlManager: controller.ControlManager
    controller: controller.Controller
    bindingNames: {string}
    bindingStates: {string:boolean}
    font: love.graphics.Font
    smallFont: love.graphics.Font
    bigFont: love.graphics.Font

    render: function(self)
    renderNoGamepad: function(self, centerX: number, centerY: number)
    renderGamepadInfo: function(self, joystick: love.joystick.Joystick, centerX: number)
    init: function(self, world: tecs.World)
end

function GamepadDemoPlugin.new(): GamepadDemoPlugin
    return setmetatable({
        bindingNames = {
            "up", "down", "left", "right",
            "a", "b", "x", "y", "start", "select",
            "rightx", "righty", "triggerleft", "triggerright"
        },
        bindingStates = {}
    }, {__index = GamepadDemoPlugin})
end

function GamepadDemoPlugin:init(world: tecs.World)
    self.world = world
    self.font = lg.newFont(16)
    self.smallFont = lg.newFont(12)
    self.bigFont = lg.newFont(24)
    self.controlManager = world.resources[controller.CONTROLLER]

    local bindings: controller.Bindings = {
        controls = {
            up = {"key:up", "button:dpup", "axis:lefty-", "hat:1u"},
            down = {"key:down", "button:dpdown", "axis:lefty+", "hat:1d"},
            left = {"key:left", "button:dpleft", "axis:leftx-", "hat:1l"},
            right = {"key:right", "button:dpright", "axis:leftx+", "hat:1r"},
            a = {"key:space", "button:a"},
            b = {"key:t", "button:b"},
            x = {"key:lshift", "button:x"},
            y = {"key:e", "button:y"},
            start = {"key:return", "button:start"},
            select = {"key:tab", "button:back"},
            rightx = {"axis:rightx"},
            righty = {"axis:righty"},
            triggerleft = {"axis:triggerleft+"},
            triggerright = {"axis:triggerright+"}
        }
    }

    -- Create a controller with the above bindings that automatically connects to a joystick if possible.
    self.controller = self.controlManager:addController(bindings, {
        auto = true,
        deadzone = 0.25
    })

    -- Monitor for joystick changes on the controller itself.
    self.controller.onJoystickChanged = function(
        _ctrl: controller.Controller,
        newJoystick: love.joystick.Joystick,
        oldJoystick: love.joystick.Joystick
    )
        if newJoystick then
            print(string.format("Gamepad connected: %s", newJoystick:getName()))
        elseif oldJoystick then
            print(string.format("Gamepad disconnected: %s", oldJoystick:getName()))
        end
    end

    -- You can also monitor for joystick connection events across all controllers
    world:observe(tecs2d.events.JoystickAdded, function(event: tecs2d.events.JoystickAdded)
        print("Joystick added event received: " .. event.joystick:getName())
    end)

    world:observe(tecs2d.events.JoystickRemoved, function(event: tecs2d.events.JoystickRemoved)
        print("Joystick removed event received: " .. event.joystick:getName())
    end)

    local input = tecs2d.input
    world:addSystem({
        name = "InputSystem",
        phase = tecs.phases.Update,
        run = function()
            -- Quit the application when the escape key is released
            if input.isKeyReleased("escape") then
                tecs2d.quit(0)
                return
            end

            -- Look for joystick button presses and update bindin states
            for _, name in ipairs(self.bindingNames) do
                self.bindingStates[name] = self.controller:isDown(name)
            end
        end
    })

    world:addSystem({
        name = "GamepadRenderSystem",
        phase = tecs.phases.Render,
        run = function()
            self:render()
        end
    })
end

function GamepadDemoPlugin:render()
    local width, height = lg.getWidth(), lg.getHeight()

    lg.setColor(0.1, 0.1, 0.1, 1)
    lg.rectangle("fill", 0, 0, width, height)

    local joystick = self.controller.joystick
    local centerX = width / 2
    local centerY = height / 2

    if joystick then
        self:renderGamepadInfo(joystick, centerX)
    else
        self:renderNoGamepad(centerX, centerY)
    end
end

function GamepadDemoPlugin:renderNoGamepad(centerX: number, centerY: number)
    local text = "Connect a gamepad"
    local textWidth = self.bigFont:getWidth(text)
    local textHeight = self.bigFont:getHeight()
    local padding = 20
    local boxWidth = textWidth + padding * 2
    local boxHeight = textHeight + padding * 2

    lg.setFont(self.bigFont)
    lg.setColor(0.9, 0.9, 0.9, 1)

    lg.setColor(0.2, 0.2, 0.2, 1)
    lg.rectangle("fill", centerX - boxWidth / 2, centerY - boxHeight / 2, boxWidth, boxHeight)

    lg.setColor(0.5, 0.5, 0.5, 1)
    lg.setLineWidth(2)
    lg.rectangle("line", centerX - boxWidth / 2, centerY - boxHeight / 2, boxWidth, boxHeight)

    lg.setColor(0.9, 0.9, 0.9, 1)
    lg.print(text, centerX - textWidth / 2, centerY - textHeight / 2)
end

function GamepadDemoPlugin:renderGamepadInfo(joystick: love.joystick.Joystick, centerX: number)
    local gamepadName = joystick:getName()
    local gamepadId = joystick:getID()
    local text = string.format("Gamepad: %s (ID: %s)", gamepadName, tostring(gamepadId))
    local textWidth = self.bigFont:getWidth(text)
    local textHeight = self.bigFont:getHeight()

    local padding = 20
    local screenWidth = lg.getWidth()
    local screenHeight = lg.getHeight()
    local boxHeight = textHeight + padding * 2
    local infoBoxY = 50

    lg.setFont(self.bigFont)
    lg.setColor(0.9, 0.9, 0.9, 1)

    -- Matte blue box background
    lg.setColor(0.15, 0.25, 0.35, 1)
    lg.rectangle("fill", 0, infoBoxY - boxHeight / 2, screenWidth, boxHeight)

    -- Box border (darker blue)
    lg.setColor(0.1, 0.15, 0.25, 1)
    lg.setLineWidth(2)
    lg.rectangle("line", 0, infoBoxY - boxHeight / 2, screenWidth, boxHeight)

    lg.setColor(0.9, 0.9, 0.9, 1)
    lg.print(text, centerX - textWidth / 2, infoBoxY - textHeight / 2)

    lg.setFont(self.font)
    lg.setColor(0.7, 0.7, 0.7, 1)
    local instructionText = "Press a gamepad button or escape to quit..."
    local instructionWidth = self.font:getWidth(instructionText)
    lg.print(instructionText, centerX - instructionWidth / 2, 100)

    -- Single column vertical bindings display
    local columnX = 50
    local startY = 140
    local rowHeight = 30

    for i, name in ipairs(self.bindingNames) do
        local y = startY + (i - 1) * rowHeight

        -- Draw background if binding is active
        local rawValue = self.controller:getRaw(name)
        local isActive = rawValue ~= 0
        if isActive then
            lg.setColor(0.1, 0.4, 0.1, 0.8)
            lg.rectangle("fill", columnX - 10, y - 5, screenWidth - 80, rowHeight - 5)
        end

        -- Draw binding name
        lg.setFont(self.font)
        lg.setColor(isActive and {0.2, 0.9, 0.2, 1} or {0.9, 0.9, 0.9, 1})
        lg.print(name .. ":", columnX, y)

        -- Get and display actual binding values
        local bindingValues = {}
        local bindings = self.controller.bindings.controls[name]
        if bindings then
            for _, binding in ipairs(bindings) do
                table.insert(bindingValues, binding)
            end
        end

        lg.setFont(self.smallFont)
        lg.setColor(0.6, 0.6, 0.6, 1)
        local bindingsText = table.concat(bindingValues, ", ")
        lg.print(bindingsText, columnX + 160, y + 2)

        -- Display raw value
        lg.setColor(isActive and {0.9, 0.9, 0.2, 1} or {0.5, 0.5, 0.5, 1})
        local valueText = string.format("%.2f", rawValue)
        lg.print(valueText, screenWidth - 120, y + 2)
    end

    -- Footer info
    lg.setFont(self.font)
    lg.setColor(0.5, 0.5, 0.5, 1)
    local vibrationSupported = joystick:isVibrationSupported()
    local supportText = vibrationSupported and "Vibration: Supported" or "Vibration: Not supported"
    lg.print(supportText, centerX - self.font:getWidth(supportText) / 2, screenHeight - 60)

    local statsText = string.format(
        "Axes: %.0f, Buttons: %.0f, Hats: %.0f",
        joystick:getAxisCount(),
        joystick:getButtonCount(),
        joystick:getHatCount()
    )
    lg.print(statsText, centerX - self.font:getWidth(statsText) / 2, screenHeight - 40)
end

-- Set Tecs2D up so that it runs the game loop
function love.run(): function(): string | number
    return tecs2d.run(1 / 60, function(world: tecs.World)
        world:addPlugin(controller.plugin())
        local demo = GamepadDemoPlugin.new()
        demo:init(world)
    end)
end
