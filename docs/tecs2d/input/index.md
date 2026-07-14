---
description: "Low-level tecs2d.input queries for keyboard, mouse, and gamepad state plus the latch-based input model"
outline: deep
---

# Input Handling

The input module provides low-level access to keyboard, mouse, and gamepad state. Use this for direct device queries
like "is spacebar down?" or "where is the mouse?".

For rebindable game controls (jump, attack, move), see [Controller](/tecs2d/input/controller/).

## Getting Started

The input module is globally available and automatically managed by Tecs:

```teal
local tecs = require("tecs")
local tecs2d = require("tecs2d")
local input = require("tecs2d.input")

love.run = tecs2d.run({
    fps = 60,
    game = function(world)
        -- Use input directly in your systems
        if input.isKeyPressed("space") then
            -- Handle input
        end
    end
})
```

## Keyboard input

Check keyboard state using the input module:

```teal
local tecs2d = require("tecs2d")
local input = require("tecs2d.input")

-- Check if a key is currently down (pressed or held)
if input.isKeyDown("space") then
    player:jump()
end

-- Check if a key was just pressed this frame
if input.isKeyPressed("escape") then
    pauseGame()
end

-- Check if a key was just released this frame
if input.isKeyReleased("e") then
    interact()
end
```

*See [love.keypressed](https://love2d.org/wiki/love.keypressed) and
[love.keyreleased](https://love2d.org/wiki/love.keyreleased) for keyboard events*

### Text input

For text entry (chat boxes, name fields, etc.), use the `textInput` field which captures actual typed characters with
proper keyboard layout handling:

```teal
local tecs2d = require("tecs2d")
local input = require("tecs2d.input")

-- Get text typed this frame
local text = input.textInput
if text ~= "" then
    chatBox:appendText(text)
end

-- Example text input field system
world:addSystem({
    phase = tecs.phases.Update,
    run = function()
        if activeTextField then
            -- Append typed text
            activeTextField.text = activeTextField.text .. input.textInput

            -- Handle backspace
            if input.isKeyPressed("backspace") then
                activeTextField.text = activeTextField.text:sub(1, -2)
            end
        end
    end
})
```

*See [love.textinput](https://love2d.org/wiki/love.textinput) for more about text input handling*

## Mouse input

You can get the current mouse X and Y position using `input`:

```teal
local tecs2d = require("tecs2d")
local input = require("tecs2d.input")

local x, y = input.mouseX, input.mouseY
```

You can check if the mouse wheel was moved using `getMouseWheelMovement()`:

```teal
local dx, dy = input.getMouseWheelMovement()
if dy ~= 0 then
    zoom = zoom + dy * 0.1
end
```

Or access the wheel movement array directly:

```teal
local wheelX = input.mouseWheelMoved[1]
local wheelY = input.mouseWheelMoved[2]
```

You can check mouse button states:

```teal
if input.isMouseDown(1) then
    -- Button held
end

if input.isMousePressed(1) then
    -- Just pressed
end

if input.isMouseReleased(1) then
    -- Just released
end
```

### Mouse button reference
* **1**: Primary button (usually left)
* **2**: Secondary button (usually right)
* **3**: Middle button (wheel click)
* **4+**: Additional buttons (mouse-dependent)

*See [love.mousepressed](https://love2d.org/wiki/love.mousepressed) for more about mouse buttons*

## Gamepad and joystick input

Handle gamepad and joystick input for each connected device:

```teal
local tecs2d = require("tecs2d")
local input = require("tecs2d.input")

-- Iterate through connected joysticks
for joystick, joystickInput in pairs(input.joysticks) do
    -- Check gamepad buttons (using standard names)
    if joystickInput:isGamepadButtonPressed("a") then
        player:jump()
    end

    if joystickInput:isGamepadButtonDown("x") then
        player:attack()
    end

    -- Read analog stick values
    local leftStickX = joystickInput.gamepadAxis["leftx"] or 0
    local leftStickY = joystickInput.gamepadAxis["lefty"] or 0
    player:move(leftStickX, leftStickY)

    -- Check joystick buttons by number
    if joystickInput:isJoystickButtonPressed(1) then
        handleButtonPress(1)
    end

    -- Read joystick hat positions
    local hatDirection = joystickInput.joystickHat[1]
    if hatDirection == "u" then
        navigateMenu("up")
    end
end
```

*See [love.gamepadpressed](https://love2d.org/wiki/love.gamepadpressed) for gamepad buttons and
[love.joystickpressed](https://love2d.org/wiki/love.joystickpressed) for joystick buttons*

### Reacting to joystick events

You can also react to joystick connection/disconnection events:

```teal
local tecs2d = require("tecs2d")

world:addSystem({
    phase = tecs.phases.Startup,
    run = function()
        world:observe(0, tecs2d.JoystickAdded, function(e: tecs2d.JoystickAdded)
            local name = e.joystick:getName()
            print("Controller connected: " .. name)
        end)

        world:observe(0, tecs2d.JoystickRemoved, function(e: tecs2d.JoystickRemoved)
            print("Controller disconnected")
        end)
    end
})
```

## Latch-based input

Tecs takes a different approach to input than most Love2D libraries. The goal is to make input reliable and
simple in both variable-rate Update and fixed-rate FixedUpdate phases.

### How Love2D usually does it

- Love2D polls input once per render frame
- Libraries like Baton give you helpers like `pressed`, `released`, `down`, but these values are _frame-scoped_
- That works fine if your gameplay only runs once per frame in `love.update`

::: warning Problem: Fixed phases
If you run multiple fixed steps per frame, or sometimes zero (at very high FPS), quick taps can get lost
or duplicated.
:::

### Tecs's model

Tecs separates how input is captured from how it's consumed:

* Events are polled once per frame in the main loop before world:update()
* In **FixedUpdate**, input "edges" (like `isKeyPressed` and `isKeyReleased`) are _latched_:
  - They report their value since the last FixedUpdate tick
  - If a key was pressed and released between FixedUpdate ticks, the key is both pressed and released
  - Queries like `isKeyDown` always reflect the most up to date state from Love2D.
  - Latches are cleared after each FixedUpdate tick. So only the first FixedUpdate tick sees the latched state.

So no matter what phase you handle input in, whether it's Update or FixedUpdate, "down", "released", and "pressed"
states will return fresh values you'd expect.

## Input events

While `isKeyPressed` and `isKeyReleased` use a latching model to ensure inputs are never dropped, they do not preserve
the exact sequence or timing of multiple inputs within a single render frame. If your game requires frame-perfect
combos or input sequences (e.g., a fighting game), you should implement a custom input buffer by consuming the raw
event stream provided by the [Tecs event system](/tecs2d/events).

```teal
local tecs2d = require("tecs2d")

world:observe(0, tecs2d.KeyPressed, function(e: tecs2d.KeyPressed)
    addToComboBuffer(e.key, love.timer.getTime())
end)
```
