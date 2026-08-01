# tecs

Tecs is a typed entity component system and 2D/3D game engine for LuaJIT,
written in Teal and built on SDL3, SDL_GPU, and Rapier. Entities are the
interface: anything that updates or renders belongs to a world.

The Rust host owns the SDL lifecycle. A game entry returns an application:

```lua
return tecs.newApplication({
    window = { title = "game", width = 1280, height = 720 },

    plugin = function(world)
        world:addSystem({
            name = "game.Tick",
            phase = tecs.ecs.phases.Update,
            run = function(dt)
                -- Update game state.
            end,
        })
    end,
})
```

Games can use the global `tecs` table, or `require("tecs")` in headless tools
and specs. The engine is loaded lazily, so simulation code does not need to
start a graphics stack.

## Features

- Typed ECS with archetype queries, plugins, state stacks, snapshots, and
  deterministic random streams.
- GPU-driven 2D rendering with materials, lights, shadows, layers, text,
  sprite animation, and particles.
- Optional 3D rendering with indexed mesh residency, ordered GPU frustum
  culling, texture and PBR material residency, static glTF/GLB loading, and an
  independently allocated transparent forward lane.
- Input, audio, physics, assets, workers, async I/O, HTTP, file watching, and
  a debug server.

Skinned and animated 3D rendering, mesh shadows, post-processing, tiled maps,
and multi-camera are not yet built.

## Build

Cargo and `xtask` own the build, generated bindings, tests, and packaging.
Run `cargo xtask deps` once to install and stage development dependencies, then:

```bash
cargo xtask build              # Build the host development preset
cargo xtask example ui-demo    # Run the 2D showcase
cargo xtask example gltf3d     # Run the textured 3D example
cargo xtask test               # Run the spec suite
cargo xtask check              # Type-check Teal sources
cargo xtask format             # Format sources
cargo xtask docs-check         # Validate the documentation site
cargo xtask package --preset macos-arm64
cargo xtask check-package out/package
```

`--preset` selects a platform and defaults to the host development preset.
Use `cargo xtask presets` to list available targets. Packaged presets build
pinned dependencies for distributable releases; development presets use the
system libraries.

## Documentation

The API reference and guides live in [`docs/`](docs/). Serve them locally with
`cargo xtask docs-dev`. Public API documentation lives beside its Teal
declarations under [`src/tecs/`](src/tecs/).

The source layout and project conventions are documented in
[`AGENTS.md`](AGENTS.md). Design notes live in the adjacent `../tecs-plans`
repository.

## Requirements

Rust/Cargo, LuaJIT, SDL3, SDL3_mixer, shaderc, SPIRV-Cross, zlib, and Teal.
`rust-toolchain.toml` selects the Rust version; `cargo xtask deps` installs the
development dependencies managed by the project.

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for dependency notices.
