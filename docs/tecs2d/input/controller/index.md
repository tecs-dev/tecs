---
description: "The tecs2d.controller layer for rebindable logical controls, mapping physical inputs to actions with bindings and pairs"
---

# Tecs Controller

Tecs Controller provides rebindable controls for Tecs games. It builds on top of Tecs's event-based
[input handling system](/tecs2d/input/) to add a layer of configurable controller mappings.

::: tip Controller == logical input
Tecs Input handles the *physical* inputs efficiently, while Controller manages the *logical* mapping of those inputs
to game actions like "jump" and "attack".
:::

## Quick Start

```teal
local tecs = require("tecs")
local tecs2d = require("tecs2d")
local controller = require("tecs2d.controller")

-- In your game plugin (passed to tecs2d.run)
local function gamePlugin(world: tecs.World)
    -- Get the control manager from world resources (auto-added by tecs2d)
    local controlManager = world.resources[controller]

    -- Define control bindings
    local bindings = {
        controls = {
            jump = {"key:space", "button:a"},
            attack = {"key:z", "mouse:1", "button:x"},
            menu = {"key:escape", "button:start"},
            -- Direction controls for the movement pair
            left = {"key:a", "key:left", "axis:leftx-"},
            right = {"key:d", "key:right", "axis:leftx+"},
            up = {"key:w", "key:up", "axis:lefty-"},
            down = {"key:s", "key:down", "axis:lefty+"}
        },
        pairs = {
            move = {"left", "right", "up", "down"}
        }
    }

    -- Add a controller with auto-assignment enabled
    local player1 = controlManager:addController(bindings, {auto = true})

    -- Use controller state in a system
    world:addSystem({
        name = "PlayerInput",
        phase = tecs.phases.FixedUpdate,
        run = function()
            if player1:isPressed("jump") then
                -- Player just pressed jump
            end

            if player1:isDown("attack") then
                -- Player is holding attack
            end

            local moveX, moveY = player1:getPair("move")
            -- moveX is -1 (left), 0 (none), or 1 (right)
            -- moveY is -1 (up), 0 (none), or 1 (down)
        end
    })
end
```

## Multiple Players

```teal
-- Define different bindings for each player
local player1Bindings = {
    controls = {
        jump = {"key:w", "button:a"},
        attack = {"key:space", "button:x"}
    }
}

local player2Bindings = {
    controls = {
        jump = {"key:up", "button:a"},
        attack = {"key:rctrl", "button:x"}
    }
}

-- Add controllers with auto mode for multiplayer
local player1 = controlManager:addController(player1Bindings, {
    auto = true,
    deadzone = 0.25
})

local player2 = controlManager:addController(player2Bindings, {
    auto = true,
    deadzone = 0.25
})
```

## Custom Dead Zones

Dead zones prevent analog stick drift from registering as input:

```teal
-- Create controller with custom dead zone (0.0 to 1.0)
local player = controlManager:addController(bindings, {
    auto = true,
    deadzone = 0.3  -- 30% dead zone
})
```

## Custom Control Manager

If you need a custom control manager, you can override the auto-created one by
setting the resource key directly:

```teal
-- Create custom control manager
local customManager = controller.newManager()

-- Configure the manager as needed
customManager:addController(player1Bindings, {auto = true})
customManager:addController(player2Bindings, {auto = true})

-- Override the auto-created manager
world.resources[controller] = customManager
```
