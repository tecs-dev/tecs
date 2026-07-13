---
outline: deep
---

# Tecs2D

Tecs2D is a 2D game engine built on top of [Tecs](/tecs/) and [Love2D 12](https://love2d.org).
It wires the ECS into the Love2D event loop and adds rendering, audio, input, physics, tiled maps,
tweens, and dev tooling.

## Install Tecs CLI

The Tecs CLI is the supported installation path. It includes Teal,
Tecs/Tecs2D, type definitions, project generation, and build tooling. On first
use it downloads a cached LÖVE 12 nightly. You do not need to install Lua,
LuaRocks, Teal, LÖVE, or a C compiler separately.

::: code-group

```bash [macOS]
brew install tecs-dev/tap/tecs-cli
```

```powershell [Windows]
scoop bucket add tecs https://github.com/tecs-dev/scoop-bucket
scoop install tecs
```

```bash [Linux]
brew install tecs-dev/tap/tecs-cli
```

:::

Prefer a standalone installer? Use the scripts from
[tecs-cli releases](https://github.com/tecs-dev/tecs-cli/releases/latest):
`install.sh` (macOS/Linux) or `install.ps1` (Windows).

Open a new terminal after installing on Windows.

## Create a game

```bash
tecs new my-game
cd my-game
tecs run
```

You should see the generated hello game. It includes the runtime debugger and
MCP server so a developer or coding agent can inspect the running world.

### What's included

`tecs new` creates:

- **`src/main.tl`** - A small Tecs2D game with startup spawning, render layers, MCP, and debugging
- **`src/conf.tl`** - LÖVE application configuration
- **`tlconfig.lua`** - Teal compiler configuration
- **`assets/`** - Project-owned game assets
- **`.github/workflows/ci.yml`** - CI that type-checks and builds the game on Linux, macOS, and Windows
- **Agent tooling** - `AGENTS.md`/`CLAUDE.md` guidance plus MCP client config for Claude Code (`.mcp.json`) and Codex (`.codex/config.toml`)
- **Prepared dependencies** - Tecs/Tecs2D sources and type declarations are copied automatically on first check or build

### Project structure

```
my-game/
├── tlconfig.lua          # Teal configuration
├── src/
│   ├── main.tl           # Game entry point
│   ├── conf.tl           # Love2D configuration
│   └── vendor/           # Framework sources, declarations, and rocks added with `tecs add`
├── assets/               # Images, sounds, fonts
└── build/                # Self-contained compiled game (generated)
```

### Larger reference project

The [tecs-space-example repository](https://github.com/tecs-dev/tecs-space-example)
is a larger game example with multiple plugins and states. Use it as reference
material; install the CLI and use `tecs new` when creating a project.

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
adds the engine layer: rendering, audio, input, and more. Projects created by
`tecs new` include both layers automatically.

### CLI commands

The full reference lives in the [Tecs CLI section](/cli/).

| Command          | Description                                      |
| ------------------- | ------------------------------------------------ |
| `tecs run`          | Build and run the game                           |
| `tecs build`        | Compile a self-contained game without running it |
| `tecs check`        | Type-check all project Teal sources (`--json` for tooling) |
| `tecs integ`        | Run project specs; `*_lovespec.tl` files drive the built game over MCP |
| `tecs dist`         | Package the game: `.love`, macOS app bundle, fused Windows executable |
| `tecs add <rock>`   | Vendor a pure-Lua rock and its Teal types from luarocks.org |
| `tecs remove <rock>` | Remove a vendored rock                          |
| `tecs update`       | Update vendored rocks to their newest versions   |
| `tecs clean`        | Remove generated build output                    |
| `tecs info`         | Show CLI/runtime versions and project status (`--json` for tooling) |
| `tecs agent`        | List bundled agent guides or print one's installed path |
| `tecs completions`  | Print a bash, zsh, or fish completion script     |

## Next steps

- [Tecs Quickstart](/tecs/) - Learn ECS concepts and build your first system
- [Love2D Integration](/tecs2d/love2d) - Game loop, events, and Love2D phase mapping
- [Rendering](/tecs2d/rendering/) - Camera, sprites, shapes, lighting
- [Input & Controls](/tecs2d/input/) - Keyboard, mouse, gamepad
