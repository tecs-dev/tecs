local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local controller <const> = require("tecs2d.controller")
local events <const> = require("tecs2d.events")
local gfx <const> = require("tecs2d.gfx")
local mcp <const> = require("tecs2d.mcp")

local lg <const> = love.graphics

local Transform <const> = tecs.builtins.Transform
local Rectangle <const> = gfx.Rectangle
local Color <const> = gfx.Color

local record GamepadDemoPlugin
    world: tecs.World
    controlManager: controller.ControlManager
    controller: controller.Controller
    bindingNames: {string}
    bindingStates: {string:boolean}
    font: love.graphics.Font
    smallFont: love.graphics.Font
    bigFont: love.graphics.Font
    gamepadName: string
    isGamepadConnected: boolean

    init: function(self, world: tecs.World)
    updateBindingDisplay: function(self)
end

function GamepadDemoPlugin.new(): GamepadDemoPlugin
    return setmetatable({
        bindingNames = {
            "up", "down", "left", "right",
            "a", "b", "x", "y", "start", "select",
            "rightx", "righty", "triggerleft", "triggerright"
        },
        bindingStates = {},
        gamepadName = "",
        isGamepadConnected = false
    }, {__index = GamepadDemoPlugin})
end

function GamepadDemoPlugin:init(world: tecs.World)
    self.world = world
    self.font = lg.newFont(16)
    self.smallFont = lg.newFont(12)
    self.bigFont = lg.newFont(24)
    self.controlManager = world.resources[controller]

    local screenW, screenH = lg.getWidth(), lg.getHeight()
    local centerX = screenW / 2
    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    pipeline:getCamera():setPosition(centerX, screenH / 2)

    -- Background
    world:spawn(
        Transform(centerX, screenH / 2, 0, 1),
        Rectangle(screenW, screenH),
        Color(0.1, 0.1, 0.1)
    )

    -- Header bar
    world:spawn(
        Transform(centerX, 50, 1, 2),
        Rectangle(screenW, 60),
        Color(0.15, 0.25, 0.35)
    )

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
    world:observe(0, events.JoystickAdded, function(event: events.JoystickAdded)
        print("Joystick added event received: " .. event.joystick:getName())
    end)

    world:observe(0, events.JoystickRemoved, function(event: events.JoystickRemoved)
        print("Joystick removed event received: " .. event.joystick:getName())
    end)

    local demo = self

    world:addSystem({
        name = "InputSystem",
        phase = tecs.phases.Update,
        run = function()
            -- Look for joystick button presses and update binding states
            for _, name in ipairs(demo.bindingNames) do
                demo.bindingStates[name] = demo.controller:isDown(name)
            end

            demo:updateBindingDisplay()
        end
    })

    -- All text rendering via PostRender
    world:addSystem({
        name = "TextHUD",
        phase = tecs.phases.PostRender,
        run = function()
            local sw = lg.getWidth()
            local sh = lg.getHeight()

            if not demo.isGamepadConnected then
                -- Show "Connect a gamepad" centered
                lg.setFont(demo.bigFont)
                lg.setColor(0.9, 0.9, 0.9, 1)
                local connectText = "Connect a gamepad"
                local textW = demo.bigFont:getWidth(connectText)
                lg.print(connectText, sw / 2 - textW / 2, sh / 2 - 12)
                return
            end

            -- Gamepad name in header
            lg.setFont(demo.bigFont)
            lg.setColor(0.9, 0.9, 0.9, 1)
            local nameW = demo.bigFont:getWidth(demo.gamepadName)
            lg.print(demo.gamepadName, sw / 2 - nameW / 2, 38)

            -- Instructions
            lg.setFont(demo.font)
            lg.setColor(0.7, 0.7, 0.7, 1)
            local instruction = "Press a gamepad button or escape to quit..."
            local instrW = demo.font:getWidth(instruction)
            lg.print(instruction, sw / 2 - instrW / 2, 88)

            -- Binding rows
            local bindingStartY = 140
            local bindingRowHeight = 30
            for i, name in ipairs(demo.bindingNames) do
                local y = bindingStartY + (i - 1) * bindingRowHeight
                local rawValue = demo.controller:getRaw(name)
                local isActive = rawValue ~= 0

                -- Background highlight for active bindings
                if isActive then
                    lg.setColor(0.1, 0.4, 0.1, 0.8)
                    lg.rectangle("fill", 40, y - 5, sw - 80, bindingRowHeight - 5)
                end

                -- Binding name
                lg.setFont(demo.font)
                if isActive then
                    lg.setColor(0.2, 0.9, 0.2, 1)
                else
                    lg.setColor(0.9, 0.9, 0.9, 1)
                end
                lg.print(name .. ":", 50, y)

                -- Draw binding sources
                lg.setFont(demo.smallFont)
                lg.setColor(0.6, 0.6, 0.6, 1)
                local bindingsText = ""
                local binds = demo.controller.bindings.controls[name]
                if binds then
                    bindingsText = table.concat(binds as {string}, ", ")
                end
                lg.print(bindingsText, 200, y + 2)

                -- Draw raw value
                lg.setColor(isActive and {0.9, 0.9, 0.2, 1} or {0.5, 0.5, 0.5, 1})
                local valueText = string.format("%.2f", rawValue)
                lg.print(valueText, sw - 120, y + 2)
            end

            -- Footer stats
            local joystick = demo.controller.joystick
            if joystick then
                lg.setFont(demo.font)
                lg.setColor(0.5, 0.5, 0.5, 1)

                local vibrationSupported = joystick:isVibrationSupported()
                local supportText = vibrationSupported and "Vibration: Supported" or "Vibration: Not supported"
                lg.print(supportText, sw / 2 - demo.font:getWidth(supportText) / 2, sh - 60)

                local statsText = string.format(
                    "Axes: %.0f, Buttons: %.0f, Hats: %.0f",
                    joystick:getAxisCount(),
                    joystick:getButtonCount(),
                    joystick:getHatCount()
                )
                lg.print(statsText, sw / 2 - demo.font:getWidth(statsText) / 2, sh - 40)
            end
        end
    })
end

function GamepadDemoPlugin:updateBindingDisplay()
    local joystick = self.controller.joystick

    if joystick then
        self.isGamepadConnected = true
        local joystickId = joystick:getID()
        self.gamepadName = string.format("Gamepad: %s (ID: %d)", joystick:getName(), joystickId as integer)
    else
        self.isGamepadConnected = false
        self.gamepadName = ""
    end
end

-- Set up Tecs so that it runs the game loop
love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = function(world: tecs.World)
        world:addPlugin(mcp.new())
        world:addPlugin(require("tecs2d.debug").new())

        local demo = GamepadDemoPlugin.new()
        demo:init(world)
    end,
    render = {
        virtualHeight = 600,
        pixelMode = false,
        layers = {
            [1] = { name = "background" },
            [2] = { name = "ui" },
        },
    },
})
