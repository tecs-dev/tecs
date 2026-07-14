---
description: "Gamepad support: auto-assignment, hot-plugging, switching joysticks, rumble vibration, and analog triggers on controllers"
---

# Gamepad Support

Controller provides comprehensive gamepad support with automatic input mapping and hot-plugging capabilities.

## Creating Controllers with Gamepads

Controllers can be created with different auto-assignment modes:

```teal
local bindings = {
    controls = {
        jump = {"key:space", "button:a"},
        attack = {"key:x", "button:x"},
        -- Raw axes for full analog control
        moveX = {"axis:leftx"},  -- Returns -1 to 1
        moveY = {"axis:lefty"},  -- Returns -1 to 1
        aimX = {"axis:rightx"},  -- Returns -1 to 1
        aimY = {"axis:righty"}   -- Returns -1 to 1
    }
}

-- Add a controller with no gamepad
local controller1 = controlManager:addController(bindings)

-- Add a controller that auto-assigns a gamepad
local controller2 = controlManager:addController(bindings, {
    auto = true,
    deadzone = 0.25
})
```

Manually assigning a specific gamepad:

```teal
local controller4 = controlManager:addController(bindings, {
    -- Assign the first connected gamepad
    joystick = love.joystick.getJoysticks()[1],
    deadzone = 0.25
})
```

## Auto-Assignment

Controller provides automatic gamepad assignment to simplify setup:

### When auto=false (default)

- No automatic gamepad assignment
- Must manually assign gamepads

### When auto=true

- Automatically assigns first available gamepad
- Prioritizes controllers with activity
- Reassigns to any available gamepad when disconnected

```teal
-- Player 1 gets first available gamepad (or active one if detected)
local player1 = controlManager:addController(bindings, {auto = true})

-- Player 2 gets next available gamepad
local player2 = controlManager:addController(bindings, {auto = true})
```

## Switching Controllers

The `resetJoystick()` method allows changing controller assignments at runtime:

```teal
-- Enable auto-assignment
controller:resetJoystick({auto = true})

-- Disable auto-assignment
controller:resetJoystick({auto = false})

-- Switch to a specific gamepad
controller:resetJoystick({
    joystick = joysticks[2],
    deadzone = 0.3
})

-- Disconnect gamepad (keyboard-only mode)
controller:resetJoystick(nil)
```

## Programmatic Joystick Assignment

You can directly set a controller's joystick using the `setJoystick` method:

```teal
-- Assign a specific joystick
local joystick = love.joystick.getJoysticks()[1]
controller:setJoystick(joystick)

-- Clear the joystick
controller:setJoystick(nil)
```

The `setJoystick` method automatically triggers rumble feedback when a joystick is connected to help players identify
their controller.

## Controller Joystick Changes

You can monitor when a controller's joystick changes by setting an `onJoystickChanged` callback:

```teal
-- Set a callback to be notified of joystick changes
controller.onJoystickChanged = function(
    ctrl: controller.Controller,
    newJoystick: love.joystick.Joystick,
    oldJoystick: love.joystick.Joystick
)
    if newJoystick then
        print(string.format("Controller connected: %s", newJoystick:getName()))
    else
        print("Controller disconnected")
    end

    -- Update UI to show controller status
    updateControllerIcon(ctrl, newJoystick)
end
```

This callback is triggered whenever:
- A joystick is assigned (manually or automatically)
- A joystick is disconnected
- The controller switches to a different joystick

## Vibration/Rumble

```teal
-- Add rumble feedback on hit
if controller:isPressed("attack") and enemy:wasHit() then
    local joystick = controller.joystick
    if joystick then
        -- Vibrate for 0.2 seconds at 50% strength
        joystick:setVibration(0.5, 0.5, 0.2)
    end
end
```

## Analog Triggers

```teal
local bindings = {
    controls = {
        accelerate = {"key:up", "axis:triggerright+"},
        brake = {"key:down", "axis:triggerleft+"}
    }
}

-- Get analog trigger values (0 to 1)
local acceleration = controller:getRaw("accelerate")
local braking = controller:getRaw("brake")

-- Apply to vehicle
vehicle.throttle = acceleration
vehicle.brakeForce = braking * vehicle.maxBrakeForce
```
