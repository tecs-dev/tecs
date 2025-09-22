# Tecs Project Guide

## Project Overview

Tecs is a high-performance Entity Component System framework written in Teal, designed for LuaJIT. The core `tecs`
module is renderer-agnostic. The `tecs2d` module layers on LÖVE2D integration, GPU-driven rendering, input, audio,
UI, tiled maps, and MCP tooling.

Primary entry points:

- `src/tecs/init.tl`: supported public API for the ECS framework
- `src/tecs2d/init.tl`: supported public API for the LÖVE2D/game-engine layer

Documentation entry points:

- `docs/tecs/index.md`: ECS getting started and core concepts
- `docs/tecs2d/index.md`: Tecs2D getting started and project setup
- `docs/index.md`: docs site homepage

## Key Commands

```bash
make build           # Compile src/ into build/ and compile test deps
make test            # Build, then run the Busted suite from build/test_deps
make all             # Build + test
make check           # Type-check all source files
make typecheck       # Type-check source files only
make rebuild         # Clean and rebuild from scratch
make clean           # Remove build artifacts
make dev             # Install LuaRocks dev deps, docs deps, then run an initial build
make docs-dev        # Run the VitePress docs dev server
make check-examples  # Type-check the example projects
make build-examples  # Build the example projects
```

Examples are usually run via `make example-<name>`. The current Makefile includes targets such as:

- `make example-audio`
- `make example-ball-bench`
- `make example-camera-multi`
- `make example-camera-target`
- `make example-circles`
- `make example-layer-fx`
- `make example-lighting`
- `make example-material-demo`
- `make example-mesh-demo`
- `make example-msdf-text`
- `make example-orbiting-shapes`
- `make example-physics`
- `make example-save-game`
- `make example-shape-bench`
- `make example-sprite-collision`
- `make example-sprite-onloop`
- `make example-text-bench`
- `make example-tiled`
- `make example-transform-demo`
- `make example-tween-demo`
- `make example-ui`

If a target needs GPU features, the Makefile auto-downloads the configured LÖVE 12 nightly into `bin/love2d/`.

## Project Structure

```text
tecs/
├── src/
│   ├── tecs/              # Core ECS public API and internals
│   │   ├── init.tl
│   │   ├── types.tl
│   │   ├── internal/
│   │   └── utils/
│   └── tecs2d/            # LÖVE2D/game-engine layer
│       ├── init.tl
│       ├── gfx/
│       ├── audio/
│       ├── controller.tl
│       ├── input.tl
│       ├── mcp/
│       ├── physics.tl
│       ├── tiled/
│       ├── tween.tl
│       └── ui/
├── docs/                  # VitePress docs site
│   ├── tecs/
│   └── tecs2d/
├── examples/              # Runnable example projects
├── benches/               # Benchmarks
├── spec/                  # Test sources in Teal
├── scripts/               # Build/test helper scripts
├── types/                 # Ambient type definitions for external libs
└── build/                 # Generated Lua output
```

## Core Architecture Notes

### Public API boundaries

- The supported ECS surface is exposed from `require("tecs")`.
- The supported 2D engine surface is exposed from `require("tecs2d")`.
- `tecs.internal.*` and deep `tecs2d.*.internal.*` modules are implementation details with no stability guarantee.

### ECS model

- Worlds own entities, components, systems, plugins, resources, queries, and the state stack.
- Queries iterate through archetypes with `query:iter()`.
- Builtins are registered automatically and include components/events such as `ChildOf`, `Transform`, `TTL`,
  `Paused`, `Disabled`, and state transition events.
- The state model is a stack, using `world:createState`, `world:pushState`, `world:popState`, and `world:peekState`.

### Tecs2D integration

- `tecs2d.run` creates the `love.run` loop.
- `tecs2d.run` auto-installs the asset manager, audio plugin, tween plugin, controller plugin, render pipeline,
  tiled plugin, and UI plugin before the user game plugin runs.
- Rendering is GPU-oriented and depends on LÖVE 12 features for the modern pipeline.

## Development Guidelines

### Type Safety

- Prefer explicit Teal typing for public APIs, plugin interfaces, and shared resources.
- Avoid `any` unless the boundary is genuinely dynamic, for example generic JSON payloads.
- Keep casts narrow and justified.

### Testing

- Add or update tests when changing behavior, fixing bugs, or extending public APIs.
- Tests live under `spec/` and are written in Teal.
- `make test` compiles sources and test dependencies before running Busted.

### Documentation

- Update `docs/`, `README.md`, and agent guidance files when public behavior or workflows change.
- Prefer linking to current docs entry points that exist in this repo, not guessed future paths.

### Code Style

- Use 4-space indentation.
- Keep line length reasonable.
- Prefer `local` bindings and `<const>` where appropriate.
- Prefer early returns over deep nesting.
- Keep comments sparse and informational.

### Performance

- Avoid allocations in hot paths when possible.
- Prefer archetype/query iteration patterns that work with contiguous columns.
- Be careful when changing rendering, storage, and snapshot code paths, they are performance-sensitive.
