---
description: "Controller API reference: ControlManager, Controller methods (isPressed, getPair, rebind, rumble), JoystickConfig, and Bindings types"
---

# API Reference

::: tip Routed gameplay input
All `Controller` query methods read [`input.base`](/tecs2d/input/#targets). While another input layer owns capture,
digital queries return false and analog queries return zero. See [Input ownership](/tecs2d/input/controller/#input-ownership).
:::

## JoystickConfig

The `JoystickConfig` type defines joystick assignment options:

```teal
type JoystickConfig = {
    joystick?: love.joystick.Joystick,  -- Specific gamepad to use
    auto?: boolean,  -- Enable auto-assignment (default: false)
    deadzone?: number  -- Axis deadzone threshold 0-1 (default: 0.5)
}
```

**Fields:**

- `joystick`: A specific Love2D joystick/gamepad to assign to the controller
- `auto`: Enable automatic gamepad assignment (default: false)
  - When `true`: Auto-assigns available gamepads, prioritizes controllers with activity
  - When `false`: Manual assignment only
- `deadzone`: Minimum axis value to register as input (prevents stick drift)

## Bindings

The `Bindings` type defines the structure for control mappings:

```teal
type Bindings = {
    controls: {string: {string}},  -- Map of control names to binding arrays
    pairs?: {string: {string}}     -- Optional map of pair names to 4 control names
}
```

**Fields:**

- `controls`: A table mapping control names (strings) to arrays of binding strings
  - Keys are control names like "jump", "attack", "moveLeft"
  - Values are arrays of binding strings like `{"key:space", "button:a"}`
- `pairs` (optional): A table mapping pair names to exactly 4 control names
  - Keys are pair names like "move", "aim"
  - Values must be arrays with exactly 4 control names: `{left, right, up, down}`

**Example:**

```teal
local bindings: Bindings = {
    controls = {
        jump = {"key:space", "button:a"},
        attack = {"key:z", "mouse:1"},
        left = {"key:a"},
        right = {"key:d"},
        up = {"key:w"},
        down = {"key:s"}
    },
    pairs = {
        move = {"left", "right", "up", "down"}
    }
}
```

## ControlManager

The `ControlManager` manages multiple controllers for different players in your game.

### newManager

Creates a new control manager.

```teal
function controller.newManager(): ControlManager
```

**Returns:**

- A new `ControlManager` instance.

::: tip A ControlManager is created automatically
You typically don't need to call this. A ControlManager is created and registered automatically
when Tecs registers with Love2D.
:::

### addController

Adds a new controller with the specified bindings.

```teal
function ControlManager:addController(
    bindings: Bindings,
    config?: JoystickConfig
): Controller
```

- `bindings`: Table containing control mappings and button pairs.
- `config`: Optional joystick configuration:
  - `joystick`: Specific gamepad to use
  - `auto`: Enable auto-assignment (true/false, default: false)
  - `deadzone`: Dead zone threshold from 0 to 1 (default: 0.5)

**Returns:**

- The newly created `Controller` instance.

**Example:**

```teal
local bindings = {
    controls = {
        jump = {"key:space", "button:a"},
        attack = {"key:z", "button:x"},
        left = {"key:a", "axis:leftx-"},
        right = {"key:d", "axis:leftx+"},
        up = {"key:w", "axis:lefty-"},
        down = {"key:s", "axis:lefty+"}
    },
    pairs = {
        move = {"left", "right", "up", "down"}
    }
}

-- Manual mode (default)
local controller1 = controlManager:addController(bindings)

-- Auto-assignment enabled
local controller2 = controlManager:addController(bindings, {
    auto = true,
    deadzone = 0.25
})

-- Specific joystick assignment
local joystick = love.joystick.getJoysticks()[1]
local controller3 = controlManager:addController(bindings, {
    joystick = joystick,
    deadzone = 0.25
})
```

### removeController

Removes a controller from the manager.

```teal
function ControlManager:removeController(controller: Controller)
```

- `controller`: The controller instance to remove.

**Example:**

```teal
controlManager:removeController(player2Controller)
```

### get

Gets a controller by its index.

```teal
function ControlManager:get(index: integer): Controller
```

- `index`: The 1-based index of the controller.

**Returns:**

- The controller at the specified index, or nil if not found.

**Example:**

```teal
local player1 = controlManager:get(1)
local player2 = controlManager:get(2)
```

## Controller

The `Controller` represents a single player's input device with their control bindings.

### isPressed

Checks if a button was just pressed this frame.

```teal
function Controller:isPressed(button: string): boolean
```

- `button`: The name of the button to check.

**Returns:**

- `true` if the button was just pressed, `false` otherwise.

**Notes:**

- Only returns true on the frame the button is first pressed.
- Will not return true while the button is held down.

**Example:**

```teal
if controller:isPressed("jump") then
    player:startJump()
end
```

### isDown

Checks if a button is currently being held down.

```teal
function Controller:isDown(button: string): boolean
```

- `button`: The name of the button to check.

**Returns:**

- `true` if the button is currently down, `false` otherwise.

**Notes:**

- Returns true for every frame the button is held.
- Includes the initial press frame.

**Example:**

```teal
if controller:isDown("sprint") then
    player.speed = player.runSpeed
end
```

### isReleased

Checks if a button was just released this frame.

```teal
function Controller:isReleased(button: string): boolean
```

- `button`: The name of the button to check.

**Returns:**

- `true` if the button was just released, `false` otherwise.

**Notes:**

- Only returns true on the frame the button is released.

**Example:**

```teal
if controller:isReleased("charge") then
    player:releaseChargedAttack()
end
```

### getPair

Gets the directional input from a button pair.

```teal
function Controller:getPair(name: string): number, number
```

- `name`: The name of the button pair.

**Returns:**

- `x`: Horizontal direction (-1 for left, 0 for neutral, 1 for right).
- `y`: Vertical direction (-1 for up, 0 for neutral, 1 for down).

**Notes:**

- Button pairs must be defined in the bindings with exactly 4 buttons: left, right, up, down.
- Opposite directions cancel out (e.g., pressing both left and right returns 0).

**Example:**

```teal
local moveX, moveY = controller:getPair("move")
velocity.x = moveX * player.speed
velocity.y = moveY * player.speed
```

### getPairNormalized

Gets the directional input from a button pair, normalized to work correctly with diagonal movement.

```teal
function Controller:getPairNormalized(name: string): number, number
```

- `name`: The name of the button pair.

**Returns:**

- `x`: Horizontal direction (-1 for left, 0 for neutral, 1 for right).
- `y`: Vertical direction (-1 for up, 0 for neutral, 1 for down).

### getRaw

Gets the raw numeric value of a control.

```teal
function Controller:getRaw(button: string): number
```

- `button`: The name of the control to check.

**Returns:**

- For buttons, keys, and hats: 0 when not pressed, 1 when pressed
- For directional axes (with + or -): 0 to 1 based on axis position
- For raw axes (without suffix): -1 to 1 for the full axis range

**Notes:**

- Useful for analog controls like triggers or thumbsticks.
- Values within the dead zone return 0.

**Example:**

```teal
local throttle = controller:getRaw("accelerate")
car.acceleration = throttle * car.maxAcceleration
```

### rebind

Changes the controller's bindings at runtime.

```teal
function Controller:rebind(bindings: Bindings)
```

- `bindings`: The new binding configuration to apply.

**Notes:**

- Useful for implementing control remapping in settings menus.
- Preserves the controller's joystick and deadzone settings.
- Clears all previous bindings before applying new ones.

**Example:**

```teal
-- In a settings menu: create new bindings with the changed control
local function remapJumpKey(newKey: string)
    local newBindings = {
        controls = {
            jump = {"key:" .. newKey, "button:a"},
            attack = player1Controller.bindings.controls.attack
        },
        pairs = player1Controller.bindings.pairs
    }
    player1Controller:rebind(newBindings)
end

-- Complete rebinding
local newBindings = {
    controls = {
        jump = {"key:w", "button:a"},
        attack = {"key:q", "button:x"}
    }
}
player1Controller:rebind(newBindings)
```

### notifyWithRumble

Triggers rumble feedback on the controller's joystick.

```teal
function Controller:notifyWithRumble(strength?: number, duration?: number)
```

- `strength`: Vibration strength from 0 to 1 (default: 0.5)
- `duration`: Duration in seconds (default: 0.2)

**Notes:**

- No-op if no joystick is assigned or if vibration is not supported.

**Example:**

```teal
if controller:isPressed("attack") and enemy:wasHit() then
    controller:notifyWithRumble(0.7, 0.3)
end
```

### setJoystick

Directly sets the joystick for this controller.

```teal
function Controller:setJoystick(joystick?: love.joystick.Joystick)
```

- `joystick`: The joystick to assign, or `nil` to clear.

**Notes:**

- Automatically triggers rumble feedback when a joystick is assigned
- Calls the `onJoystickChanged` callback if set
- Does not change the auto-assignment setting

**Example:**

```teal
-- Assign a specific joystick
local joystick = love.joystick.getJoysticks()[1]
controller:setJoystick(joystick)

-- Clear the joystick
controller:setJoystick(nil)
```

### resetJoystick

Resets or changes the joystick assignment for the controller.

```teal
function Controller:resetJoystick(config?: JoystickConfig)
```

- `config`: Optional joystick configuration:
  - `joystick`: Specific gamepad to use
  - `auto`: Enable auto-assignment (true/false)
  - `deadzone`: Dead zone threshold from 0 to 1
  - `nil`: Disconnect gamepad and disable auto mode

**Notes:**

- Useful for switching controllers or changing modes at runtime
- Can update deadzone without changing joystick

**Example:**

```teal
-- Enable auto-assignment
controller:resetJoystick({auto = true})

-- Disable auto-assignment
controller:resetJoystick({auto = false})

-- Switch to specific gamepad
local joysticks = love.joystick.getJoysticks()
controller:resetJoystick({
    joystick = joysticks[2],
    deadzone = 0.3
})

-- Disconnect gamepad (keyboard only)
controller:resetJoystick(nil)
```

## Controller Properties

### bindings

The current binding configuration. Can be read to inspect bindings or passed to `rebind()`.

```teal
controller.bindings: Bindings
```

### joystick

The currently assigned joystick, or `nil` if no joystick is connected.

```teal
controller.joystick: love.joystick.Joystick
```

### deadzone

The axis deadzone threshold (0 to 1). Values below this threshold are treated as 0.

```teal
controller.deadzone: number  -- default: 0.5
```

### auto

Whether automatic gamepad assignment is enabled.

```teal
controller.auto: boolean  -- default: false
```

### onJoystickChanged

Optional callback function that's called when the controller's joystick changes.

```teal
controller.onJoystickChanged: function(
    controller: Controller,
    newJoystick: love.joystick.Joystick,
    oldJoystick: love.joystick.Joystick
)
```

**Parameters:**

- `controller`: The controller whose joystick changed
- `newJoystick`: The new joystick (nil if disconnected)
- `oldJoystick`: The previous joystick (nil if was disconnected)

**Example:**

```teal
controller.onJoystickChanged = function(
    ctrl: controller.Controller,
    newJoy: love.joystick.Joystick,
    oldJoy: love.joystick.Joystick
)
    if newJoy then
        print("Controller connected: " .. newJoy:getName())
        updateControllerUI(ctrl, newJoy)
    else
        print("Controller disconnected")
        showKeyboardControlsUI(ctrl)
    end
end
```
