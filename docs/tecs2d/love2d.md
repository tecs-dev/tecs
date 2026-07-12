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
    quitOnEscape = true,
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
| `quitOnEscape` | `boolean`                           | `false`                        | When true, pressing Escape requests a clean quit with exit code 0 |
| `hotReload` | `HotReloadConfig`                       | disabled                       | Optional development hot reload using one build stamp file and snapshots |

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

### Hot Reload

`hotReload` is a development workflow for preserving ECS state across a Love2D
restart. Tecs2D polls a single stamp file; your build tool updates that stamp
only after a successful rebuild.

```teal
love.run = tecs2d.run({
    fps = 60,
    game = gamePlugin,
    hotReload = {
        enabled = true,
        snapshotPath = ".tecs-hot-reload.snapshot",
        stampPath = ".tecs-reload-stamp",
    },
})
```

When the stamp changes, Tecs2D saves a binary world snapshot, shuts down the
world, and returns Love2D's `"restart"` signal. On the next startup it restores
the snapshot after `Startup` and before `PostStartup`.

Use startup phases with that order in mind:

- `PreStartup` / `Startup`: register systems, observers, plugins, and runtime resources.
- Snapshot restore: replaces entity data while preserving systems, resources, queries, and global observers.
- `PostStartup`: rebuild transient or derived entities that are intentionally not snapshotted, and rebind runtime
  entity handles from [`Key`](/tecs/builtins#key-component) or saved components.

Snapshots do not capture `world.resources`, so persist your own resource state with a [snapshot
handler](/tecs/save-games#world-resources). The built-in plugins already handle theirs (audio, cameras, sprites, text,
physics, tweens, and tiled maps); see [Handled by built-in
plugins](/tecs/save-games#handled-by-built-in-plugins) for exactly what round-trips.

For example, refresh keyed handles in `PostStartup`:

```teal
local playerId = 0

world:addSystem({
    phase = tecs.phases.PostStartup,
    run = function()
        playerId = world:requireKey("player")
    end,
})
```

For a project launched from its `build/` directory, the host stamp file is often `build/.tecs-reload-stamp`, while
the in-game `stampPath` is `.tecs-reload-stamp`.

The following example watches game assets for changes and then triggers a hot reload:

```bash
watchexec -w src -w assets 'tecs build && touch build/.tecs-reload-stamp'
```

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
