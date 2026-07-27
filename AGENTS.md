# Tecs Project Guide

## Project Overview

Tecs is a typed entity component system and the game engine built around it, written in Teal for LuaJIT. The two
were separate projects and are now one: the ECS knows what the GPU reads, and the engine is not a layer bolted on
top of a renderer-agnostic core.

SDL owns the loop. An entry file returns an application and a C host drives it through `SDL_AppInit`,
`SDL_AppEvent`, `SDL_AppIterate` and `SDL_AppQuit`. Everything below Lua is reached through the FFI against
generated bindings; the only native code is that host, plus a worker thread runner, a log sink, and the thread
pool Box2D solves across.

Entities are the interface. Anything that renders or updates per frame is an entity in a world.

Primary entry point:

- `src/tecs/init.tl`: the supported public API, ECS and engine together

## Key Commands

CMake is canonical and Make wraps it, so there is one description of how the tree is assembled.

```bash
make build          # Build the selected preset
make test           # Run the spec suite (both suites, one Busted run)
make check          # Type-check Teal sources
make run            # Run the demo
make bench          # Shapes benchmark
make bench-physics  # Physics benchmark
make bench-latency  # Event-to-photon latency, with synthetic input
make abi-check      # Verify generated cdefs against the C ABI
make shaders        # Build the shader pack a target without a compiler consumes
make package        # Install a tree into out/package
make check-package  # Verify a package carries its own dependencies
make presets        # List the platform matrix
make deps           # Install development dependencies (Homebrew)
```

`PRESET=` selects the target and defaults to `macos-arm64-dev`. A development preset resolves dependencies from
the system, which is convenient and not shippable. A packaged preset builds pinned revisions from source, and
`make check-package` is the gate on the difference.

## Project Structure

```text
tecs/
├── src/tecs/
│   ├── init.tl            # The public surface, ECS and engine
│   ├── ecs.tl             # The ECS half, for engine code
│   ├── types.tl
│   ├── internal/          # ECS implementation
│   ├── utils/
│   ├── ffi/               # Generated bindings: SDL3, Box2D, shaderc, SPIRV-Cross
│   ├── gpu/               # Device, pipelines, buffers, pass graph, shaders
│   ├── gfx/               # Camera
│   ├── platform/          # Window, input, events, clock, paths, capabilities
│   ├── physics/           # Box2D 3
│   ├── sequence/          # Sequencer, with the tween runtime inside it
│   ├── mcp/               # Debug server: transport, tools, sandbox
│   ├── Application.tl     # The lifecycle the host drives
│   ├── Renderer.tl        # World to GPU
│   ├── components.tl      # Engine components
│   ├── assets.tl
│   ├── workers.tl
│   └── log.tl
├── native/                # Host, worker runner, log sink, solver pool, registry
├── assets/                # shaders/ and materials/, globbed at build time
├── cmake/                 # Pinned dependency revisions
├── scripts/               # cdef generation, ABI check, shader pack, package check
├── spec/                  # Engine specs in Lua, ECS specs in Teal under spec/tecs
├── bench/
└── out/<preset>/          # Build output
```

## Core Architecture Notes

### The dependency rule

`require("tecs")` is the whole surface and is what a game requires. Engine modules require `tecs.ecs` instead,
because the surface exports those modules and a module that also depended on the surface would be a cycle, which
Teal rejects even through a type-only require.

So the graph runs one way: internal code depends on a half, only a game depends on the whole. `tecs.ecs` carries
what the engine actually uses rather than the whole ECS API, so the dependency stays legible.

`tecs.internal.*` modules are implementation details with no stability guarantee.

### ECS model

- Worlds own entities, components, systems, plugins, resources, queries and the state stack.
- Queries iterate through archetypes with `query:iter()`.
- Builtins are registered automatically: `ChildOf`, `Transform`, `TTL`, `Paused`, `Disabled`, and the state
  transition events.
- The state model is a stack: `world:createState`, `world:pushState`, `world:popState`, `world:peekState`.

### Rendering

Deferred and GPU-driven. A compute pass culls and compacts a visible list, one indirect draw consumes it, and the
material dispatch is compiled into a single fragment shader from `assets/materials/*.glsl`. Shaders are GLSL
compiled to SPIR-V and translated for the backend; a release consumes a prebuilt pack and links no compiler.

Compaction is an ordered three-pass scan rather than an `atomicAdd`, because draw order has to be deterministic.

### Ported, and not yet

Working: windowing, input in three tiers behind a layer stack, events, the GPU pipeline, materials, camera,
physics, workers and asset loading, logging, the debug server, and sequencing with tweening merged into it.

Not ported: shadows, post-processing, audio, text, UI, tiled maps, sprite animation, layers and multi-camera.

## Development Guidelines

### Type Safety

- Prefer explicit Teal typing for public APIs, plugin interfaces and shared resources.
- Avoid `any` unless the boundary is genuinely dynamic, for example generic JSON payloads.
- Keep casts narrow and justified.

### Testing

- Add or update tests when changing behavior, fixing bugs or extending public APIs.
- Engine specs are Lua under `spec/`; ECS specs are Teal under `spec/tecs/`. Both run in one `make test`.
- Teal specs are compiled by `scripts/compile_specs.lua`, which emits code even when a file does not type-check.
  That is deliberate: their type errors are in the test code, and refusing to build them would take real coverage
  away over that. `make check` therefore covers `src`, `main.tl` and `bench`.

### Documentation

- `README.md` is the design record. Update it when public behavior or a design decision changes.
- Prefer linking to entry points that exist in this repo, not guessed future paths.

### Mutation and Dirty Model

The rules that prevent the most common defect class:

- Reads use `archetype:get` / `world:get`; writes go through `getMut`, which marks the component's column dirty on
  the archetype. Never `getMut` in a loop that might not write, it defeats every dirty-gated consumer.
- Direct cdata writes through `world:get` on FFI components need an explicit `world:markComponentDirty(id,
  Component)` or the GPU never re-syncs.
- Dirty bits clear at the end of each `world:update`.
- `world:batchSpawn` skips FFI defaults; set every field in the callback.
- Keep `query:iter()` for loops that run to exhaustion. If an archetype-level query loop may `break` or return
  early, use `query:cursor()` and call `cursor:close()` after the loop or immediately before returning. Leaving
  one early through `iter` leaves the world deferred, which silently queues every later spawn.

### Code Style

`STYLE.md` is the long form. In brief: 4-space indentation, reasonable line length, `local` and `<const>` where
appropriate, early returns over deep nesting, comments sparse and informational.

### Naming

- **Identifiers** (functions, methods, record fields, option keys, non-import locals): `camelCase`. No
  `snake_case`.
- **Filenames and their import bindings** follow a class/module split:
  - The file *is* a class (one dominant type you construct and call methods on, including component records):
    **PascalCase**, e.g. `Camera.tl` → `local Camera = require("tecs.gfx.Camera")`.
  - The file is a *module* containing a class or a namespace of functions: **luacase** (all lowercase, no
    separators), e.g. `shaderpack.tl` → `local shaderpack = require("tecs.gpu.shaderpack")`. Multi-word module
    files drop their underscores.
- Prefer single-word module names where a clear one exists.
- Prefer a flat `module.tl` over `module/init.tl` when the module is a single file.
- The `require` path mirrors the filename; the local binding mirrors it too.

### Performance

- Avoid allocations in hot paths.
- Prefer archetype/query iteration patterns that work with contiguous columns.
- Be careful when changing rendering, storage and snapshot code paths; they are performance-sensitive.
- Benchmarks are the argument. `make bench` is a uniform loop over transforms, `make bench-physics` is lumpy and
  CPU-bound, and a frame-structure change has to be judged against both, p50 and p95 together.
- `make bench-latency` measures what neither of those can see: the wait from an event arriving to the frame that
  reacted to it being submitted. Anything that pipelines the frame buys throughput and pays for it there.

## History

`main` holds the previous engine, which this branch replaces rather than migrates. Use a git worktree to read from
it or to A/B a measurement; do not carry a second copy of it here.

Design notes live in `../tecs-plans`, outside this repository, so plans and code have separate histories.
