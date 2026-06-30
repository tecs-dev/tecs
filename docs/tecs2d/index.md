---
outline: deep
---

# Getting Started

Tecs2D is a 2D game engine built on top of [Tecs](/tecs/) and [Love2D 12](https://love2d.org).
It wires the ECS into the Love2D event loop and adds rendering, audio, input, physics, tiled maps,
tweens, and dev tooling.

The fastest way to start is the [starter template](https://github.com/tecs-dev/tecs-starter).

## Prerequisites

You will need to install these tools to use Tecs2D:

* **LuaRocks**: Lua package manager - [Installation](https://github.com/luarocks/luarocks/blob/main/docs/download.md)
* **Teal**: Typed Lua compiler - [Download](https://teal-language.org/#download)
* **[LÖVE 12](https://love2d.org)**: Game runtime. LÖVE 12 is not yet a stable release, so Tecs2D targets [nightly builds](https://nightly.link/love2d/love/workflows/main/main)

Next, install Tecs2D (and Tecs) into your project using a single command:

```bash
luarocks install --dev --tree=src/vendor --lua-version=5.1 tecs2d
```

*While Tecs2D is in preview, `--dev` is required. There are no tagged release yet.*

## Starter template

::: code-group

```bash [Git Clone]
git clone https://github.com/tecs-dev/tecs-starter.git my-game
cd my-game
make run
```

```bash [GitHub CLI]
gh repo create my-game --template tecs-dev/tecs-starter --clone
cd my-game
make run
```

:::

You should see a demo with a movable player.

### What's included

The starter template comes pre-configured with:

- **Makefile** - Incremental builds, asset copying, dependency management
- **tlconfig.lua** - Teal compiler configuration
- **Type definitions** - Downloaded automatically for Love2D, LuaJIT FFI, etc.
- **Demo game** - Simple player movement with camera follow

### Project structure

```
my-game/
├── Makefile              # Build orchestration
├── tlconfig.lua          # Teal configuration
├── src/
│   ├── main.tl           # Game entry point
│   ├── conf.tl           # Love2D configuration
│   └── plugins/
│       └── game.tl       # Game logic
├── assets/               # Images, sounds, fonts
├── types/                # Type definitions (generated)
├── build/                # Compiled output (generated)
└── src/vendor/           # Dependencies (generated)
```

### Wiring up Tecs2D

`tecs2d.run` configures the world, render pipeline, and game plugin, then takes over Love2D's main loop:

```teal
local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")

local function game(world: tecs.World)
    -- register components, spawn entities, add systems
end

love.run = tecs2d.run({
    fps = 60,
    game = game,
    render = {
        virtualWidth = 800,
        virtualHeight = 600,
    },
})
```

The pure-ECS pieces (`World`, components, queries, systems) come from [Tecs](/tecs/). Tecs2D
adds the engine layer: rendering, audio, input, etc. Install `tecs2d` when you want the full
engine layer; it depends on `tecs` automatically.

### Make targets

| Command               | Description                                            |
| --------------------- | ------------------------------------------------------ |
| `make run`            | Build and run the game (runs setup automatically)      |
| `make build`          | Compile without running                                |
| `make clean`          | Remove build artifacts                                 |
| `make reset`          | Clean everything, including dependencies and Love2D    |
| `make love12`         | Re-download Love2D 12                                  |

### Managing dependencies

```bash
# Add a package
luarocks install --tree=src/vendor --lua-version=5.1 penlight

# Add a specific version
luarocks install --tree=src/vendor --lua-version=5.1 penlight 1.14.0
```

## Next steps

- [Tecs Quickstart](/tecs/) - Learn ECS concepts and build your first system
- [Love2D Integration](/tecs2d/love2d) - Game loop, events, and Love2D phase mapping
- [Rendering](/tecs2d/rendering/) - Camera, sprites, shapes, lighting
- [Input & Controls](/tecs2d/input/) - Keyboard, mouse, gamepad
