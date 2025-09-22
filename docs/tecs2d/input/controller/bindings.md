# Bindings

Bindings are defined as strings in the format `source:value`. Each control can have multiple bindings, allowing
the same action to be triggered by different inputs.

::: info Based on baton
The binding system is based on [baton.lua](https://github.com/tesselode/baton) by Andrew Minnich, with the following
differences:

- Scancode inputs are not supported: scancodes exist for layout-independent physical key positions, but since controls
are rebindable, users can simply rebind to the desired key
- Raw axis support (axes without + or - suffix return full -1 to 1 range)
:::

## Keyboard Bindings

Use Love2D [KeyConstants](https://love2d.org/wiki/KeyConstant). For example:

| Binding          | Description        |
| ---------------- | ------------------ |
| `"key:space"`    | Spacebar           |
| `"key:w"`        | W key              |
| `"key:escape"`   | Escape key         |
| `"key:lshift"`   | Left shift key     |
| `"key:return"`   | Enter/Return key   |

## Mouse Bindings

Use mouse button numbers. For example:

| Binding       | Description            |
| ------------- | ---------------------- |
| `"mouse:1"`   | Left mouse button      |
| `"mouse:2"`   | Right mouse button     |
| `"mouse:3"`   | Middle mouse button    |
| `"mouse:4"`   | Extra mouse button 1   |
| `"mouse:5"`   | Extra mouse button 2   |

## Gamepad Button Bindings

Use Love2D [GamepadButton](https://love2d.org/wiki/GamepadButton) constants. For example:

| Binding                     | Description                            |
| --------------------------- | -------------------------------------- |
| `"button:a"`                | A button (Cross on PlayStation)        |
| `"button:b"`                | B button (Circle on PlayStation)       |
| `"button:x"`                | X button (Square on PlayStation)       |
| `"button:y"`                | Y button (Triangle on PlayStation)     |
| `"button:start"`            | Start button                           |
| `"button:back"`             | Back/Select button                     |
| `"button:guide"`            | Guide/Home button                      |
| `"button:leftshoulder"`     | Left shoulder button (L1/LB)           |
| `"button:rightshoulder"`    | Right shoulder button (R1/RB)          |
| `"button:leftstick"`        | Left stick click (L3)                  |
| `"button:rightstick"`       | Right stick click (R3)                 |
| `"button:dpup"`             | D-pad up                               |
| `"button:dpdown"`           | D-pad down                             |
| `"button:dpleft"`           | D-pad left                             |
| `"button:dpright"`          | D-pad right                            |

## Gamepad Axis Bindings

Use Love2D [GamepadAxis](https://love2d.org/wiki/GamepadAxis) constants. Axes can be used in two ways:

### Directional Axes (with + or - suffix)
For digital-style input from analog axes (returns 0 to 1):

| Binding                   | Description              |
| ------------------------- | ------------------------ |
| `"axis:leftx+"`           | Left stick right         |
| `"axis:leftx-"`           | Left stick left          |
| `"axis:lefty+"`           | Left stick down          |
| `"axis:lefty-"`           | Left stick up            |
| `"axis:rightx+"`          | Right stick right        |
| `"axis:rightx-"`          | Right stick left         |
| `"axis:righty+"`          | Right stick down         |
| `"axis:righty-"`          | Right stick up           |
| `"axis:triggerleft+"`     | Left trigger (L2/LT)     |
| `"axis:triggerright+"`    | Right trigger (R2/RT)    |

### Raw Axes (no suffix)
For full analog range (returns -1 to 1):

| Binding                  | Description                                        |
| ------------------------ | -------------------------------------------------- |
| `"axis:leftx"`           | Left stick horizontal (-1 = left, 1 = right)       |
| `"axis:lefty"`           | Left stick vertical (-1 = up, 1 = down)            |
| `"axis:rightx"`          | Right stick horizontal (-1 = left, 1 = right)      |
| `"axis:righty"`          | Right stick vertical (-1 = up, 1 = down)           |
| `"axis:triggerleft"`     | Left trigger (0 to 1 typically)                    |
| `"axis:triggerright"`    | Right trigger (0 to 1 typically)                   |

## Joystick Hat Bindings

For joystick hats, use the hat index followed by direction:

| Binding       | Description                  |
| ------------- | ---------------------------- |
| `"hat:1u"`    | Hat 1 up                     |
| `"hat:1d"`    | Hat 1 down                   |
| `"hat:1l"`    | Hat 1 left                   |
| `"hat:1r"`    | Hat 1 right                  |
| `"hat:1c"`    | Hat 1 center (released)      |

## Button Pairs for Movement

Button pairs convert digital inputs (like keyboard keys or d-pad buttons) into analog-style movement values.
They make it easier to implement directional movement.

A movement pair combines four directional controls into X/Y coordinates:

```lua
local bindings = {
    controls = {
        left = {"key:a", "key:left"},
        right = {"key:d", "key:right"},
        up = {"key:w", "key:up"},
        down = {"key:s", "key:down"}
    },
    pairs = {
        move = {"left", "right", "up", "down"}
    }
}

-- Get normalized movement direction
local moveX, moveY = controller:getPair("move")
-- moveX: -1 (left), 0 (none), or 1 (right)
-- moveY: -1 (up), 0 (none), or 1 (down)
```

### Pair Format

Button pairs must be defined with exactly 4 controls in a specific order:

```lua
pairs = {
    pairName = {
        "left",   -- Negative X direction
        "right",  -- Positive X direction
        "up",     -- Negative Y direction
        "down"    -- Positive Y direction
    }
}
```

When you call `getPair()`, it returns:
- **X value**: -1 if left is pressed, +1 if right is pressed, 0 if neither/both
- **Y value**: -1 if up is pressed, +1 if down is pressed, 0 if neither/both

### Using Pairs for Player Movement

```lua
local playerQuery = world:query({include = {Player, Velocity}})

world:addSystem({
    phase = tecs.phases.FixedUpdate,
    run = function(dt: number)
        for arch, len in playerQuery:iter() do
            local players = arch:get(Player)
            local velocities = arch:getMut(Velocity)
            for row = 1, len do
                local player = players[row]
                local velocity = velocities[row]
                -- Get movement from button pair, normalized for diagonal movement.
                local moveX, moveY = player.controller:getPairNormalized("move")
                velocity.x = moveX * player.speed
                velocity.y = moveY * player.speed
            end
        end
    end
})
```

::: info Diagonal movement
`getPair` returns raw axis values, which means diagonal input (e.g. W+D) will
produce a magnitude of ~1.41 instead of 1.0, causing faster diagonal movement.
Use `getPairNormalized` when applying input to velocity or any speed-sensitive
calculation.
:::

### Multiple Pairs for Different Actions

You can define multiple pairs for different types of movement:

```lua
local bindings = {
    controls = {
        -- Movement controls
        left = {"key:a"},
        right = {"key:d"},
        up = {"key:w"},
        down = {"key:s"},

        -- Camera controls
        camLeft = {"key:left"},
        camRight = {"key:right"},
        camUp = {"key:up"},
        camDown = {"key:down"},
    },
    pairs = {
        move = {"left", "right", "up", "down"},
        camera = {"camLeft", "camRight", "camUp", "camDown"},
    }
}

-- In game
local moveX, moveY = controller:getPair("move")
local camX, camY = controller:getPair("camera")
```

## Raw Values

Get the raw analog value of a control (useful for triggers and sticks):

```lua
-- For buttons and keys: returns 0 or 1
local jumpValue = controller:getRaw("jump")

-- For directional axes (with + or -): returns 0 to 1
local throttle = controller:getRaw("accelerate")  -- axis:triggerright+

-- For raw axes (no suffix): returns -1 to 1
local aimX = controller:getRaw("aimHorizontal")   -- axis:rightx
```

## Analog Stick Movement

For smooth analog movement without button pairs, you can directly bind analog axes:

```lua
local bindings = {
    controls = {
        -- Raw analog stick bindings (full -1 to 1 range)
        moveX = {"axis:leftx"},   -- Full horizontal axis
        moveY = {"axis:lefty"},   -- Full vertical axis
        aimX = {"axis:rightx"},   -- Right stick horizontal
        aimY = {"axis:righty"},   -- Right stick vertical

        -- Or use directional bindings (0 to 1 range)
        moveLeft = {"axis:leftx-"},
        moveRight = {"axis:leftx+"},
        moveUp = {"axis:lefty-"},
        moveDown = {"axis:lefty+"}
    }
}

-- Get smooth analog movement with raw axes
local moveX = controller:getRaw("moveX")  -- -1 to 1
local moveY = controller:getRaw("moveY")  -- -1 to 1

-- Get aim direction for twin-stick shooter
local aimX = controller:getRaw("aimX")  -- -1 to 1
local aimY = controller:getRaw("aimY")  -- -1 to 1
if math.abs(aimX) > 0.1 or math.abs(aimY) > 0.1 then
    player.aimAngle = math.atan2(aimY, aimX)
end
```

You can also combine analog sticks with keyboard fallback:

```lua
local bindings = {
    controls = {
        -- Keyboard and analog stick support
        left  = {"key:a", "axis:leftx-"},
        right = {"key:d", "axis:leftx+"},
        up    = {"key:w", "axis:lefty-"},
        down  = {"key:s", "axis:lefty+"}
    },
    pairs = {
        move  = {"left", "right", "up", "down"}
    }
}

-- Works with both keyboard (digital) and gamepad (analog)
local moveX, moveY = controller:getPair("move")
```
