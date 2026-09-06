---
description: "Tecs is a typed entity component system and the GPU-driven 2D game engine built around it, written in Nupp against Rust services"
order: 10
---

# Tecs

Tecs is a typed entity component system and the game engine built around it.
Game code is Nupp. The window, the GPU, audio, physics and gamepads are Rust
services behind Tecs-owned contracts. The two were separate projects and are
now one: the ECS knows what the GPU reads, and the engine is not a layer bolted
on top of a renderer-agnostic core.

Entities are the interface. Anything that renders or updates per frame is an
entity in a world.

```nupp
local ecs = require("tecs.ecs")
local gfx = require("tecs.gfx")

const world = ecs.newWorld()
world:spawn(ecs.Transform2D(120, 90, 0, 1, 0, 64, 64), gfx.Tint(1, 0.4, 0.2, 1), gfx.Renderable2D)
world:update(1 / 60)
```

## The shape of the tree

A game is a **component**: one compiled Nupp artifact exporting a session
constructor. The Rust host loads it, selects that export with `--entry`, and
drives it one frame at a time. Nothing dynamically requires game code, and no
native window handle crosses into it.

| Concern                                        | Owner                               |
| ---------------------------------------------- | ----------------------------------- |
| Game code, ECS semantics, extraction           | Nupp, in `src/tecs`                 |
| Window and event loop                          | Rust, with `winit`                  |
| GPU                                            | Rust, with `wgpu`                   |
| Audio, physics, gamepads                       | Rust services behind Tecs contracts |
| Tasks, files, bytes, JSON, networking, logging | The Nupp standard runtime           |

Tecs defers to Nupp. Anything the standard runtime already supplies is reached
directly rather than wrapped, so what is left in Tecs is Tecs-specific.

## Commands

Every command runs from the repository root and needs a
[Nupp compiler](https://github.com/nupp-lang/nupp) plus the Rust toolchain
`rust-toolchain.toml` pins.

```bash
cargo xtask check          # Type-check every Nupp source, strictly
cargo xtask test           # Build and run the test suites
cargo xtask run flatcolor  # Build a component and run it through the Rust host
cargo xtask verify         # Every gate above, plus the Rust host
cargo xtask docs           # Render this site into out/docs
```

[Getting started](getting-started.md) walks through building the tree, running
an example, and writing a component of your own.

## The reference

Every module's contracts live on its declarations, and the reference below is
rendered from them, so a signature has no second copy to drift from. Start at
[](tecs.ecs) for worlds, entities, components, queries, systems and states,
[](tecs.gfx) for what a frame draws, and [](tecs.application) for the lifecycle
a host drives.

The [MCP migration contracts](mcp-migration.md) record tool compatibility and
the host contracts for deferred debugging features.
