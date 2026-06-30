---
outline: deep
---

# Love2D Integration

The `tecs2d` module integrates Tecs with Love2D, providing the game loop and event handling.

## Getting started

```teal
-- main.tl
local tecs2d = require("tecs2d")

love.run = tecs2d.run({
    fps = 60,
    game = gamePlugin,
    render = { virtualHeight = 180 },
})
```

### run

Creates a `love.run` function integrated with Tecs's world and phase system. This function replaces the default
Love2D run loop with one that manages a Tecs world, handles fixed timestep updates, and integrates all Love2D events
with Tecs.

```teal
love.run = tecs2d.run({
    fps = 60,
    game = gamePlugin,
    render = {
        virtualHeight = 180,
        lightingMode = "deferred",
        layers = {
            [1] = { name = "background" },
            [2] = { name = "sprites" },
            [10] = { name = "hud", space = "virtual" },
        }
    }
})
```

#### Parameters

`tecs2d.run` takes a single `RunConfig` table:

| Field    | Type                                       | Default                        | Description                                                     |
| -------- | ------------------------------------------ | ------------------------------ | --------------------------------------------------------------- |
| `fps`    | `number`                                   | `60`                           | Target frames per second                                        |
| `game`   | `function(tecs.World)`                     | *(required)*                   | A plugin function that receives the world and sets up your game |
| `render` | [`RenderConfig`](/tecs2d/rendering/#renderconfig) | [defaults](/tecs2d/rendering/#fields) | Render pipeline configuration                                   |

See [`RenderConfig`](/tecs2d/rendering/#renderconfig) for all available fields and their defaults. The pipeline is accessible
in your game plugin via `world.resources[gfx.PIPELINE]`.

#### Returns

A function suitable for assigning to `love.run`.

### quit

Triggers a quit event to exit the application cleanly. This is the recommended way to exit a Tecs application.

```teal
local input = require("tecs2d.input")

-- Exit on escape key
if input.isKeyReleased("escape") then
    tecs2d.quit()
end

-- Exit with custom error code
if criticalError then
    tecs2d.quit(1)  -- Exit code 1 for error
end
```

::: danger `tecs2d.quit()` does not quit immediately
Calling `tecs2d.quit()` causes the game to exit at the end of the frame or start of the next frame. It does not
cause the function that called it to immediately exit.
:::

#### Parameters

| Name         | Type                  | Description                                           |
| ------------ | --------------------- | ----------------------------------------------------- |
| `exitCode`   | `number` (optional)   | The exit code to return (defaults to 0 for success)   |

#### Usage notes

- The default exit code is 0 (success)
- Non-zero exit codes typically indicate an error condition

## Integration features

### Automatic phase mapping

The game loop automatically integrates Love2D's rendering pipeline with Tecs phases:

| Tecs Phase                | Love2D Integration                                 |
| ------------------------- | -------------------------------------------------- |
| `tecs.phases.PostStartup` | Steps timer after initialization                   |
| `tecs.phases.Update`      | Calls `love.update()` if defined                   |
| `tecs.phases.FixedFirst`  | Marks entry to fixed timestep phases               |
| `tecs.phases.FixedLast`   | Clears latched input, marks exit from fixed phases |
| `tecs.phases.RenderFirst` | Clears screen, resets graphics state               |
| `tecs.phases.Render`      | Calls `love.draw()` if defined                     |
| `tecs.phases.RenderLast`  | Presents rendered frame                            |

### Input resource

Input is available through the [input module](/tecs2d/input/):

```teal
local input = require("tecs2d.input")

-- Check keyboard state
if input.isKeyDown("w") then
    -- Move forward
end

-- Check mouse position
local mouseX, mouseY = input.mouseX, input.mouseY

-- Check gamepad (iterate through connected joysticks)
for joystick, joystickInput in pairs(input.joysticks) do
    if joystickInput:isGamepadButtonDown("a") then
        -- Jump
    end
end
```

::: tip Why use this?
You can still use `love.keyboard.isDown()` and the like, but the input module efficiently buffers keyboard events and
tracks when keys are released or pressed in a way that _just works_ across fixed and non-fixed update phases. See
[input documentation](/tecs2d/input/#input-philosophy-in-tecs) for more information.
:::

### Event observation

Love2D events are translated into Tecs events and can be observed like any other Tecs event.
See [Love2D Events](/tecs2d/events) for all available event types.

```teal
local tecs2d = require("tecs2d")

world:observe(0, tecs2d.MousePressed, function(e: tecs2d.MousePressed)
    print("Mouse clicked at", e.x, e.y, "button", e.button)
end)

world:observe(0, tecs2d.Resize, function(e: tecs2d.Resize)
    print("Window resized to", e.width, "x", e.height)
end)
```

Standard Love2D callbacks continue to work alongside Tecs:

```teal
-- Both approaches work simultaneously
function love.keypressed(key)
    if key == "escape" then
        love.event.quit()
    end
end

world:addSystem({
    phase = tecs.phases.Update,
    run = function()
        if input.isKeyPressed("escape") then
            tecs2d.quit()
        end
    end
})
```

::: tip Why use Tecs events?
You can still use `love.*` events as usual, but using Tecs events allows for building decoupled and composable
plugins that don't have to hijack `love.*` callback methods. Any number of Tecs plugins can listen to these Love2D
events and react to them.
:::

## Basic game setup

In your `main.tl` Love 2D script:

```teal
local tecs2d = require("tecs2d")
local game = require("game")

love.run = tecs2d.run({
    fps = 60,
    game = game,
})
```

In `game.tl`, implement the game setup and systems:

```teal
local tecs = require("tecs")
local tecs2d = require("tecs2d")
local input = require("tecs2d.input")

return function(world: tecs.World)
    -- Register components
    local record PositionType is tecs.Component
        x: number
        y: number
    end

    local Position = tecs.newComponent({
        name = "Position",
        container = PositionType,
        fields = {"x", "y"},
        defaults = {0, 0},
        init = function(instance: PositionType)
            instance.x = instance.x or 0
            instance.y = instance.y or 0
        end
    })

    -- Add a system to quit
    world:addSystem({
        phase = tecs.phases.Update,
        run = function()
            if input.isKeyPressed("escape") then
                tecs2d.quit()
            end
        end
    })

    -- Create queries outside systems
    local positionQuery = world:query({include = {Position}})

    world:addSystem({
        phase = tecs.phases.Render,
        run = function()
            for archetype, len in positionQuery:iter() do
                local positions = archetype:get(Position)
                for row = 1, len do
                    local pos = positions[row]
                    love.graphics.circle("fill", pos.x, pos.y, 10)
                end
            end
        end
    })

    -- Spawn initial entities on startup
    world:addSystem({
        phase = tecs.phases.Startup,
        run = function()
            world:spawn(Position(400, 300))
        end
    })
end
```
