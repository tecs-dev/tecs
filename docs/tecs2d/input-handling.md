---
outline: deep
---

# Input handling

Tecs2D provides a global input state module that efficiently captures and manages all Love2D input events,
including keyboard, mouse, joysticks, and gamepads.

## Getting started

The input module is globally available and automatically managed by Tecs2D:

```lua
local tecs = require("tecs")
local tecs2d = require("tecs2d")
local input = tecs2d.input

-- In love.run
return tecs2d.run(1/60, function(world)
    -- Use input directly in your systems
    if input.isKeyPressed("space") then
        -- Handle input
    end
end)
```

## Keyboard input

Check keyboard state using the input module:

```lua
local tecs2d = require("tecs2d")
local input = tecs2d.input

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

*See [love.keypressed](https://love2d.org/wiki/love.keypressed) and [love.keyreleased](https://love2d.org/wiki/love.keyreleased) for keyboard events*

### Text input

For text entry (chat boxes, name fields, etc.), use the `textInput` field which captures actual typed characters with proper keyboard layout handling:

```lua
local tecs2d = require("tecs2d")
local input = tecs2d.input

-- Get text typed this frame
local text = input.textInput
if text ~= "" then
    chatBox:appendText(text)
end

-- Example text input field system
world:addSystem({
    phase = tecs.phases.Update,
    run = function()
        local tecs2d = require("tecs2d")
local input = tecs2d.input

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

Access mouse position and button states:

```lua
local tecs2d = require("tecs2d")
local input = tecs2d.input

-- Get current mouse position
local mouseX = input.mouseX
local mouseY = input.mouseY

-- Check mouse button states
if input.isMousePressed(1) then  -- Left button pressed
    fireWeapon()
end

if input.isMouseDown(2) then     -- Right button held
    aimDownSights()
end

if input.isMouseReleased(3) then -- Middle button released
    cancelAction()
end

-- Get mouse wheel movement
local wheelX = input.mouseWheelMoved[1]
local wheelY = input.mouseWheelMoved[2]
if wheelY ~= 0 then
    changeWeapon(wheelY)
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

```lua
local tecs2d = require("tecs2d")
local input = tecs2d.input

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

*See [love.gamepadpressed](https://love2d.org/wiki/love.gamepadpressed) for gamepad buttons and [love.joystickpressed](https://love2d.org/wiki/love.joystickpressed) for joystick buttons*

### Reacting to joystick events

You can also react to joystick connection/disconnection events:

```lua
local tecs2d = require("tecs2d")
local events = tecs2d.events

-- Set up joystick event observers in a startup system
world:addSystem({
    phase = tecs.phases.Startup,
    run = function()
        -- Handle new joystick connections
        world:observe(events.JoystickAdded, function(e: events.JoystickAdded)
            local name = e.joystick:getName()
            print("Controller connected: " .. name)

            -- Assign to next available player slot
            if not player1Controller then
                player1Controller = e.joystick
            elseif not player2Controller then
                player2Controller = e.joystick
            end
        end)

        -- Handle joystick disconnections
        world:observe(events.JoystickRemoved, function(e: events.JoystickRemoved)
            print("Controller disconnected")

            -- Clear player controller assignment
            if player1Controller == e.joystick then
                player1Controller = nil
                -- Switch player 1 to keyboard
            elseif player2Controller == e.joystick then
                player2Controller = nil
            end
        end)
    end
})
```

## Input philosophy in Tecs2D

Tecs2D takes a different approach to input than most Love2D libraries. The goal is to make input reliable, fair, and
simple in both variable-rate Update and fixed-rate FixedUpdate phases.

### How Love2D usually does it

- Love2D polls input once per render frame
- Libraries like Baton give you helpers like `pressed`, `released`, `down`, but these values are _frame-scoped_
- That works fine if your gameplay only runs once per frame in `love.update`

::: warning Problem: Fixed phases
If you run multiple fixed steps per frame, or sometimes zero (at very high FPS), quick taps can get lost
or duplicated.
:::

### Tecs2D's model

Tecs2D separates how input is captured from how it's consumed:

* Events are polled once per frame in the main loop before world:update()
* In **FixedUpdate**, input "edges" like `isKeyPressed` and `isKeyReleased`, etc.) are _latched_:
  - They report their value since the last FixedUpdate tick
  - If a key was pressed and released between FixedUpdate ticks, the key is both pressed and released
  - Queries like `isKeyDown` always reflect the most up to date state from Love2D.
  - Latches are cleared after each FixedUpdate tick. So only the first FixedUpdate tick sees the latched state.

So no matter what phase you handle input in, whether it's Update or FixedUpdate, "down", "released", and "pressed"
states will return fresh values you'd expect.

## Input events

While Tecs2D provides events for all input types, the Input resource abstraction means you typically don't need to observe events directly. Instead of reacting to events asynchronously, you can query input state synchronously and efficiently in your update systems.

For a complete list of available events and how to use them, see the [Love2D events documentation](./events.md).

Use the Input resource for:
- Continuous input (movement, aiming)
- Game controls that need state checking
- Any input that affects gameplay frame-by-frame

Use events when you need:
- One-time reactions (window resize, file drops)
- System-level events (focus, quit)
- Decoupled notifications between systems

```lua
local tecs2d = require("tecs2d")
local events = tecs2d.events

-- Events are best for one-time reactions
world:observe(events.Focus, function(e: events.Focus)
    if not e.visible then
        pauseGame()  -- One-time action
    end
end)

-- Input resource is best for continuous game input
world:addSystem({
    phase = tecs.phases.Update,
    run = function()
        local tecs2d = require("tecs2d")
local input = tecs2d.input

        -- Direct state queries, no event overhead
        if input.isKeyDown("w") then
            player:moveForward()  -- Every frame while held
        end
    end
})
```


## System integration

Use input in your systems, preferably in FixedUpdate for gameplay-critical input:

```lua
world:addSystem({
    phase = tecs.phases.FixedUpdate,
    run = function(dt)
        local tecs2d = require("tecs2d")
local input = tecs2d.input

        -- Query for player entities
        local players = world:query({ Player, Position, Velocity })

        for _, entity in ipairs(players) do
            local velocity = entity[Velocity]

            -- Update velocity based on input
            velocity.x = 0
            velocity.y = 0

            if input.isKeyDown("w") then velocity.y = -200 end
            if input.isKeyDown("s") then velocity.y = 200 end
            if input.isKeyDown("a") then velocity.x = -200 end
            if input.isKeyDown("d") then velocity.x = 200 end

            -- Handle jump on press (won't be missed even at low FPS)
            if input.isKeyPressed("space") then
                velocity.y = -500  -- Jump impulse
            end
        end
    end
})
```

*See [Systems documentation](../reference/systems.md) for more about systems*