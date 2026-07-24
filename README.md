# Tecs

A fast, type-safe ECS framework for LuaJIT and LÖVE2D. Uses a GPU-driven rendering pipeline made available in LÖVE 12
to handle millions of draws at 60+ FPS.

Full documentation is available at https://tecs.dev.

## Features

* **Strongly typed**: Catch errors at compile time, not runtime. Designed from the ground-up for typing with
  [Teal](https://github.com/teal-language/tl).
* **Lightning fast ECS**: Archetype-based ECS with FFI components that can handle millions of entities at 60 FPS.
* **GPU rendering**: Sprites, geometry, text (BMFont, MSDF), meshes, and particles, all GPU-instanced with compute
  shader culling.
* **Lighting engine**: Deferred G-buffer pipeline with 2.5D raymarched shadows and PBR-style material maps.
* **Tiled integration**: Load Tiled maps with animated tiles, object spawning, and collision layers.
* **Sprite animation**: Frame-based animation with tags, loops, and Aseprite slice support.
* **UI system**: Layout boxes with clipping, scrolling, and auto-sizing containers.
* **Entity hierarchy**: Parent-child relationships with relative transforms and referential integrity.
* **State machines**: State management with enter, exit, and transition events.
* **Plugin system**: Share and reuse game mechanics across projects.
* **Events**: Decouple systems with type-safe events. React to spawn, despawn, state changes, and custom events.
* **Build with AI**: A runtime debugger and built-in MCP server let humans and agents inspect, freeze, rewind, diff,
  edit, replay, and verify a running game through one shared command surface.
* **LÖVE2D integration**: Integrates with LÖVE2D game loop, input handling, physics, audio, and events.
* **Batteries included**: Pixel-perfect camera, rebindable controllers, async asset loading, component bundles,
  and more.

## Installation

Install the Tecs CLI with Homebrew (macOS and Linux), then create a project:

```bash
brew install tecs-dev/tap/tecs-cli
tecs new my-game
cd my-game
tecs run
```

On Windows, install with Scoop:

```powershell
scoop bucket add tecs https://github.com/tecs-dev/scoop-bucket
scoop install tecs
```

Standalone installers are also available if you prefer not to use a package
manager:

```bash
curl -fsSL https://github.com/tecs-dev/tecs/releases/latest/download/install.sh | sh
```

```powershell
irm https://github.com/tecs-dev/tecs/releases/latest/download/install.ps1 | iex
```

The CLI supplies Teal, Tecs/Tecs2D, type definitions, project setup, builds,
and a cached LÖVE 12 runtime. See the
[Tecs2D Getting Started guide](https://tecs.dev/tecs2d/) for the full workflow.

To hack on Tecs itself, run `make dev` to install LuaRocks and docs dev dependencies.

## Basic Example

```lua
local tecs = require("tecs")

-- Create a new World (Tecs supports multi-world)
local world = tecs.newWorld()

-- Define typed component records with Teal
local record Position is tecs.Component
    x: number
    y: number
    metamethod __call: function(self, x?: number, y?: number): Position
end

-- Easily register FFI components for C-like speed and memory
tecs.newFFIComponent({
    name = "Position",
    container = Position,
    fields = {
        {"x", "float"},
        {"y", "float"},
    },
})

local record Velocity is tecs.Component
    x: number
    y: number
    metamethod __call: function(self, x?: number, y?: number): Velocity
end

tecs.newFFIComponent({
    name = "Velocity",
    container = Velocity,
    fields = {
        {"x", "float"},
        {"y", "float"},
    },
})

-- Queries find entities with specific components
local query = world:query({
    include = {Position, Velocity}
})

-- Systems can update entities
world:addSystem({
    phase = tecs.phases.Update,
    run = function(dt: number)
        for archetype, len in query:iter() do
            local positions = archetype:getMut(Position) -- get and mark dirty
            local velocities = archetype:get(Velocity)
            for row = 1, len do
                local pos = positions[row]
                local vel = velocities[row]
                pos.x = pos.x + vel.x * dt
                pos.y = pos.y + vel.y * dt
            end
        end
    end
})

world:spawn(
    Position(100, 100),
    Velocity(10, 0),
    tecs.builtins.Name("player")
)
```

## License

Licensed under either of

 * Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
 * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)

at your option.

Third-party assets retain their original licenses. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

### Contribution

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in the work by you, 
as defined in the Apache-2.0 license, shall be dual licensed as above, without any additional terms or conditions.
