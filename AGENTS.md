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
make test-love       # Love2D integration tests: real LÖVE apps driven over the MCP HTTP server
make bench-love      # Love2D perf benches: steady-state frame time + alloc per scenario (SCENARIO=, RUNS=)
make all             # Build + test
make check           # Type-check all source files
make typecheck       # Type-check source files only
make rebuild         # Clean and rebuild from scratch
make clean           # Remove build artifacts
make dev             # Install LuaRocks dev deps, docs deps, then run an initial build
make docs-dev        # Run the VitePress docs dev server
make check-examples  # Type-check the example projects
make build-examples  # Build the example projects
make help            # List all targets, including every example
```

Examples run via `make example-<name>` (e.g. `make example-lighting`, `make example-tiled`). Run `make help` for
the full, current list. If a target needs GPU features, the Makefile auto-downloads the configured LÖVE 12 nightly
into `bin/love2d/`.

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
│       ├── assets/
│       ├── audio/
│       ├── controller.tl
│       ├── debug/
│       ├── events.tl
│       ├── gfx/
│       ├── input.tl
│       ├── internal/
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

### MCP debugging

- MCP tools may be exposed lazily by the agent environment. If a useful tool is not initially visible, search for
  the specific capability before falling back to `run_lua`.
- Prefer high-level MCP world-operation tools over `run_lua` for live game edits. In particular, use
  `patch_entities` to add, update, or remove components on existing entities.
- Useful live-debug tools include `get_debug_context`, `get_entity`, `query`, `query_in_bounds`,
  and `patch_entities`.
- When the debug plugin is installed, the in-game debugger's commands are also projected as
  `debug_*` MCP tools (`debug_select`, `debug_mark`, `debug_goto`, `debug_note`, `debug_query`,
  `debug_set`, `debug_spawn`, `debug_draw_*`, `debug_systems_*`, `debug_camera_*`,
  `debug_snapshot_save`, `debug_record_start`, ...). They share the operator's selection, marks,
  and notes, so use them to annotate or highlight entities the user can see in-game
  (`debug_select` takes `replace = true` to swap the selection instead of adding).
- Call `debug_capabilities` once after connecting to learn which plugins and tool families the
  session supports, and `debug_describe {command = "<name>"}` for a command's full contract.
  Tool results carry the payload as MCP `structuredContent`, and every tool declares safety
  annotations (read-only, destructive, idempotent).
- Time-travel debugging: `debug_rewind_start` keeps a rolling snapshot ring while the game runs;
  after something goes wrong, `debug_diff {from = "rewind:10s", ignore = "Transform", limit = 0}`
  shows a per-component summary of what changed, `debug_diff_get` dereferences a JSON Pointer
  into the result, `debug_rewind_load` restores an entry, and the `step` tool replays frame by
  frame. `debug_map_info` reads tiles at a world point; `debug_set` takes the component value as
  a JSON object.
- `get_logs` returns captured engine log lines with a seq cursor (`after`); the operator-action
  feed (selection, marks, notes, edits, artifacts) logs under `tecs2d.debug.events`, so poll it
  with `get_logs {after = <seq>, contains = "debug.events"}`. `get_component_schema` gives field
  names, C types, and defaults for building component payloads.
- Games can register custom debugger commands via `require("tecs2d.debug.commands").register`;
  registered commands appear as `debug_<name>` tools too.

## Development Guidelines

### Type Safety

- Prefer explicit Teal typing for public APIs, plugin interfaces, and shared resources.
- Avoid `any` unless the boundary is genuinely dynamic, for example generic JSON payloads.
- Keep casts narrow and justified.

### Testing

- Add or update tests when changing behavior, fixing bugs, or extending public APIs.
- Tests live under `spec/` and are written in Teal.
- `make test` compiles sources and test dependencies before running Busted.
- Love2D integration tests live under `spec/integration/` and use the `*_lovespec.tl` suffix so the fast
  suite's default `_spec` pattern never collects them; run them with `make test-love` (needs a display).
- Before writing a new integration spec, load the `love2d-integration-test` skill (`.claude/skills/`);
  it carries the harness conventions and the accumulated gotchas. For performance work, load `love2d-bench`;
  to diagnose live rendering problems, load `love2d-debug-rendering`.

### Documentation

- Update `docs/`, `README.md`, and agent guidance files when public behavior or workflows change.
- Prefer linking to current docs entry points that exist in this repo, not guessed future paths.

### Mutation and Dirty Model

`docs/tecs/mutation-model.md` is normative. The rules that prevent the most common defect class:

- Reads use `archetype:get` / `world:get`; writes go through `getMut`, which marks the component's
  column dirty on the archetype. Never `getMut` in a loop that might not write - it defeats every
  dirty-gated consumer (GPU uploads, cached masks, layout gates).
- Direct cdata writes through `world:get` on FFI components need an explicit
  `world:markComponentDirty(id, Component)` or the GPU never re-syncs.
- Dirty bits clear at the end of each `world:update`. Systems gated on dirty state that run before
  a mutation's phase need a frame-end carryover sampler (see `ui/internal/layout_dirty.tl`).
- `world:batchSpawn` skips FFI defaults; set every field in the callback.
- Never `break` or return early inside `query:iter()` - it leaks the deferred scope and spawns
  silently queue. Loop to completion with a flag.

### Code Style

- Use 4-space indentation.
- Keep line length reasonable.
- Prefer `local` bindings and `<const>` where appropriate.
- Prefer early returns over deep nesting.
- Keep comments sparse and informational.

### Naming

Naming mirrors Love2D, which uses camelCase functions, PascalCase types, and
lowercase modules (never snake_case).

- **Identifiers** (functions, methods, record fields, option keys, non-import
  locals): `camelCase`. No `snake_case`.
- **Filenames and their import bindings** follow a class/module split:
  - The whole file *is* a class (one dominant type you construct and call
    methods on, including component records): **PascalCase**, e.g. `Camera.tl`
    → `local Camera = require("tecs2d.gfx.Camera")`.
  - The file is a *module* that contains a class or is a namespace of
    functions/data: **luacase** (all lowercase, no separators, no camelCase),
    e.g. `bucketmanager.tl` → `local bucketmanager = require("...bucketmanager")`.
    Multi-word module files drop their underscores (`bucket_manager` → `bucketmanager`).
- **Prefer single-word module names** where a clear one exists: `behavior`, not
  `frameworkbehavior`; `dirty`, not `layoutdirty`. Only keep a compound when no
  single word is unambiguous (`bucketmanager`, `componentids`).
- Prefer a flat `module.tl` over a `module/init.tl` directory when the module is
  a single file (`bmfont.tl`, not `bmfont/init.tl`).
- The `require` path mirrors the filename; the local binding mirrors it too.

### Performance

- Avoid allocations in hot paths when possible.
- Prefer archetype/query iteration patterns that work with contiguous columns.
- Be careful when changing rendering, storage, and snapshot code paths, they are performance-sensitive.
