---
outline: deep
---

# Tecs2D Reference

Tecs2D integrates Tecs with Love2D.

## Installation

You can install Tecs2D using LuaRocks:

```bash
luarocks install --tree=src/vendor tecs2d.tl
```

::: info Installation help
See the [install](/guide/install) guide for more info
:::

## Module Structure

Tecs2D is organized as a single top-level module that re-exports all submodules:

```lua
local tecs2d = require("tecs2d")

-- Access submodules through the main module
local input = tecs2d.input
local events = tecs2d.events
local stats = tecs2d.stats
```

## Getting Started

```lua
-- main.tl
local tecs = require("tecs")
local tecs2d = require("tecs2d")

-- Give love2d a custom `run` function to run tecs2d
function love.run(): function(): string | number
    return tecs2d.run(1 / 60, gamePlugin)
end
```

### tecs2d.run

Creates a complete Love2D game loop integrated with Tecs's world and phase system. This function replaces the default
Love2D run loop with one that manages a Tecs world, handles fixed timestep updates, and integrates all Love2D events
with the ECS architecture.

```lua
-- main.tl
function love.run(): function(): string | number
    return tecs2d.run(1 / 60, gamePlugin)
end
```

#### Parameters

| Name | Type | Description |
|------|------|-------------|
| `timestep` | `number` | The fixed timestep in seconds between each update (e.g., `1/60` for 60 FPS) |
| `gamePlugin` | `function(world: tecs.World)` | A plugin function that receives the world and sets up your game |

#### Returns

```lua
function(): integer | string
```

A function that should be assigned to `love.run` to drive the game loop

### tecs2d.quit

Triggers a quit event to exit the application cleanly. This is the recommended way to exit a Tecs2D application.

```lua
-- Exit on escape key
if tecs2d.input.isKeyReleased("escape") then
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

| Name       | Type                | Description                                         |
|------------|---------------------|-----------------------------------------------------|
| `exitCode` | `number` (optional) | The exit code to return (defaults to 0 for success) |

#### Usage Notes

- The default exit code is 0 (success)
- Non-zero exit codes typically indicate an error condition

## Core Modules

These modules provide Love2D-specific functionality and are accessed through `tecs2d.moduleName`:

### [tecs2d.input](/tecs2d/input-handling)

Global input state module that captures and manages all Love2D input events:

```lua
local tecs2d = require("tecs2d")
if tecs2d.input.isKeyPressed("space") then
    -- Handle space key press
end
```

### [tecs2d.events](/tecs2d/events)

Type-safe wrappers for all Love2D callbacks as Tecs events:

- `tecs2d.events.MousePressed` - Mouse button press events
- `tecs2d.events.MouseReleased` - Mouse button release events
- `tecs2d.events.MouseFocus` - Mouse focus change events
- `tecs2d.events.KeyPressed` - Keyboard press events (via Input module)
- `tecs2d.events.Focus` - Window focus events
- `tecs2d.events.Resize` - Window resize events
- `tecs2d.events.Quit` - Application quit events
- `tecs2d.events.JoystickAdded` - Controller connection events
- `tecs2d.events.JoystickRemoved` - Controller disconnection events
- `tecs2d.events.FileDropped` - File drag-and-drop events
- `tecs2d.events.DirectoryDropped` - Directory drag-and-drop events
- `tecs2d.events.Visible` - Window visibility changes

### [tecs2d.stats](/tecs2d/stats)

Performance monitoring and debug display system, showing FPS, memory usage, entity count, system performance, and more.

```lua
world:addPlugin(tecs2d.stats.plugin({
    enabled = true,
    drawMode = "fps"
}))
```

## Integration Features

### Automatic Phase Mapping

Tecs2D automatically integrates Love2D's rendering pipeline with Tecs phases:

| Tecs Phase | Love2D Integration |
|------------|-------------------|
| `tecs.phases.RenderFirst` | Clears screen, resets graphics state |
| `tecs.phases.Render` | Calls `love.draw()` if defined |
| `tecs.phases.RenderLast` | Presents rendered frame |
| `tecs.phases.Update` | Calls `love.update()` if defined |
| `tecs.phases.FixedFirst` | Marks entry to fixed timestep phases |
| `tecs.phases.FixedLast` | Clears latched input, marks exit from fixed phases |
| `tecs.phases.PostStartup` | Steps timer after initialization |

### Input Resource

Input is available through the tecs2d module:

```lua
local tecs2d = require("tecs2d")

-- Check keyboard state
if tecs2d.input.isKeyDown("w") then
    -- Move forward
end

-- Check mouse position
local mouseX, mouseY = input:getMousePosition()

-- Check gamepad
local gamepad = input:getJoystick(1)
if gamepad and gamepad:isGamepadDown("a") then
    -- Jump
end
```

::: tip Why use this?
You can still use `love.keyboard.isDown()` and the like, but Tecs2D efficiently buffers keyboard events and tracks
when keys are released or pressed in a way that _just works_ across fixed and non-fixed update phases.
:::

### Event Observation

Love2D events are translated into Tecs2D events. These events can be observed like any other Tecs event:

```lua
world:observe(tecs2d.events.MousePressed, function(e: tecs2d.events.MousePressed)
    print("Mouse clicked at", e.x, e.y, "button", e.button)
end)

world:observe(tecs2d.events.Resize, function(e: tecs2d.events.Resize)
    print("Window resized to", e.width, "x", e.height)
end)
```

Traditional Love2D callbacks continue to work alongside Tecs2D:

```lua
-- Both approaches work simultaneously
function love.draw()
    -- Called during tecs.phases.Render
end

world:addSystem({
    phase = tecs.phases.Render,
    run = function()
        -- Also runs during render phase
    end
})
```

::: tip Why use Tecs2D events?
You can still use `love.*` events as usual, but using Tecs2D events allows for building decoupled and composable
plugins that don't have to hijack `love.*` callback methods. Any number of Tecs plugins can listen to these Love2D
events and react to them. The events are also nearly zero cost in that they are only emitted if something is listening
and use FFI events when the runtime allows it.
:::

## Basic Game Setup

In your `main.tl` Love 2D script:

```lua
local tecs2d = require("tecs2d")

function love.run(): function(): string | number
    return tecs2d.run(1 / 60, gamePlugin)
end
```

In `game.tl`, implement the game setup and systems:

```lua
local tecs = require("tecs")
local tecs2d = require("tecs2d")

return function(world: tecs.World)
    -- Register components
    local Position = tecs.newComponent({
        name = "Position",
        constructor = function(x, y)
            return {x = x, y = y}
        end
    })

    -- Add a system to quit
    world:addSystem({
        phase = tecs.phases.Update,
        run = function()
            if tecs2d.input.isKeyPressed("escape") then
                love.event.quit()
            end
        end
    })

    -- Create queries outside systems
    local positionQuery = world:query({include = {Position}})

    world:addSystem({
        phase = tecs.phases.Render,
        run = function()
            for _, entity in positionQuery do
                local pos = entity[Position]
                love.graphics.circle("fill", pos.x, pos.y, 10)
            end
        end
    })

    -- Spawn initial entities on startup
    world:addSystem({
        phase = tecs.phases.Startup,
        run = function()
            world:spawn(
                Position.new(400, 300)
            )
        end
    })
end
```
