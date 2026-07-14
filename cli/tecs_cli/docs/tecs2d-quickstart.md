# Tecs2D quickstart

The minimal shape of a Tecs2D game — entry point, plugin, systems, and component-driven rendering.

## Entry point (`src/main.tl`)

```teal
local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")

local Transform <const> = tecs.builtins.Transform

local function gamePlugin(world: tecs.World)
    world:addSystem({
        name = "Spawn",
        phase = tecs.phases.Startup,
        run = function()
            world:spawn(
                Transform(160, 90, 0, 1),      -- x, y, z, layer
                gfx.Circle(20),
                gfx.Color(1, 0.5, 0, 1)
            )
        end,
    })
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = gamePlugin,
    render = {
        virtualHeight = 180,
        lightingMode = "none",
        layers = {
            [1] = {name = "background", space = "virtual"},
            [2] = {name = "content", space = "virtual"},
        },
    },
})
```

## Structure

- `tecs2d.run(config)` returns the `love.run` function. Assign it directly. It installs the render
  pipeline, input, audio, tween, tiled and UI plugins, then your `game` plugin last.
- A **plugin** is `function(world: tecs.World)`. It is where you register components, create
  queries (once), add systems, and install observers. Compose plugins with `world:addPlugin(p)`.
- **Startup** spawns run once; **Update** systems run every frame with `dt`.
- Enable in-editor tooling by adding the MCP + debug plugins in your game plugin:
  `world:addPlugin(require("tecs2d.mcp").new())` and
  `world:addPlugin(require("tecs2d.debug").new())`. Generated projects already wire `.mcp.json`
  to `tecs mcp`.

## Loop / commands

- `tecs check` — type-check `src/` (`--json` for machine-readable diagnostics).
- `tecs build` — compile to `build/`; a running game hot-reloads on success.
- `tecs run` — build then launch.
- `tecs integ` — run `spec/*_lovespec.tl` against the built game over MCP.

See also: `tecs docs tecs-ecs`, `tecs docs tecs2d-rendering`, `tecs docs tecs-input`.
