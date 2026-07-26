# Tecs Project Guide

## Project Overview

Tecs is a high-performance Entity Component System framework written in Teal, designed for LuaJIT. The core `tecs`
module is renderer-agnostic. The `tecs2d` module layers on Love2D integration, GPU-driven rendering, input, audio,
UI, tiled maps, and MCP tooling.

Primary entry points:

- `src/tecs/init.tl`: supported public API for the ECS framework
- `src/tecs2d/init.tl`: supported public API for the Love2D/game-engine layer

Documentation entry points:

- `docs/tecs/index.md`: ECS getting started and core concepts
- `docs/tecs2d/index.md`: Tecs2D getting started and project setup
- `docs/index.md`: docs site homepage

## Key Commands

```bash
make build           # Compile src/ into build/ and compile test deps
make test            # Build, then run the Busted suite from build/test_deps
make test-love       # Love2D integration tests: real Love apps driven over the MCP HTTP server
make bench-love      # Love2D perf benches: steady-state frame time + alloc per scenario (SCENARIO=, RUNS=)
make all             # Build + test
make check           # Type-check all source files
make typecheck       # Type-check source files only
make rebuild         # Clean and rebuild from scratch
make clean           # Remove build artifacts
make dev             # Install LuaRocks dev deps, docs deps, then run an initial build
make docs-dev        # Run the VitePress docs dev server
make cli-check       # Lint, test, and build the bundled tecs command
make cli-package     # Build the CLI and package-manager archives
make check-examples  # Type-check the example projects
make build-examples  # Build the example projects
make help            # List all targets, including every example
```

Examples run via `make example-<name>` (e.g. `make example-lighting`, `make example-tiled`). Run `make help` for
the full, current list. If a target needs GPU features, the Makefile auto-downloads the configured Love 12 nightly
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
│   └── tecs2d/            # Love2D/game-engine layer
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
│       ├── sequence/
│       ├── tiled/
│       └── ui/
├── docs/                  # VitePress docs site
├── cli/                   # Self-contained tecs command, launchers, templates, and release payload
│   ├── tecs/
│   └── tecs2d/
├── examples/              # Runnable example projects
├── benches/               # Benchmarks
├── spec/                  # Test sources in Teal
├── scripts/               # Build/test helper scripts
├── vendor/                # Project-local LuaRocks dependencies and type definitions
└── build/                 # Generated Lua output
```

## Core Architecture Notes

### Public API boundaries

- The supported ECS surface is exposed from `require("tecs")`.
- The supported 2D engine surface is exposed from `require("tecs")`.
- `tecs.internal.*` and deep `tecs2d.*.internal.*` modules are implementation details with no stability guarantee.

### ECS model

- Worlds own entities, components, systems, plugins, resources, queries, and the state stack.
- Queries iterate through archetypes with `query:iter()`.
- Builtins are registered automatically and include components/events such as `ChildOf`, `Transform`, `TTL`,
  `Paused`, `Disabled`, and state transition events.
- The state model is a stack, using `world:createState`, `world:pushState`, `world:popState`, and `world:peekState`.

### Tecs2D integration

- `tecs.run` creates the `love.run` loop.
- `tecs.run` auto-installs the asset manager, audio plugin, sequencer, controller plugin, render pipeline,
  tiled plugin, and UI plugin before the user game plugin runs.
- Rendering is GPU-oriented and depends on Love 12 features for the modern pipeline.

### MCP debugging

- MCP tools may be exposed lazily by the agent environment. If a useful tool is not initially visible, search for
  the specific capability before falling back to `run_lua`.
- The surface is two layers: six kernel tools (`ping`, `screenshot`, `sample_pixels`,
  `send_love_event`, `run_lua`, `get_logs`) plus every debugger registry command projected as a
  `cmd_*` tool. `docs/tecs2d/mcp/tools.md` and `docs/tecs2d/debug-reference.md` are generated
  from those definitions by `make docs-debug`.
- Screenshots: with filesystem access to the game host, prefer `cmd_screenshot` and read the
  artifact file (cheaper than inline base64, and it persists in the session for the user); the
  capture lands at end of frame, so poll `cmd_screenshot_info` before reading. The kernel
  `screenshot` returns the image inline in one call; use it for a quick look or from a remote
  client.
- Prefer the structured `cmd_*` tools over `run_lua` for live game edits. In particular, use
  `cmd_set`, `cmd_modify`, and `cmd_remove` to add, update, or remove components on existing
  entities.
- Useful live-debug tools include `cmd_context`, `cmd_info`, `cmd_query`, and
  `cmd_components_info`.
- The debugger's commands share the operator's selection, marks, and notes (`cmd_select`,
  `cmd_mark`, `cmd_goto`, `cmd_note`, `cmd_query`, `cmd_spawn`, `cmd_systems_*`,
  `cmd_camera_*`, `cmd_snapshot_save`, `cmd_record_start`, ...). For durable tool-owned visuals,
  read `debugWorldId` from `cmd_context`, then use `cmd_spawn`, `cmd_modify`, and `cmd_despawn`
  with that `worldId`; the entities render in the isolated debugger world. Use commands to
  highlight entities the user can see in-game (`cmd_select` takes `replace = true` to swap the
  selection instead of adding). Open the debugger to suspend gameplay and advance frame by
  frame with `cmd_step`.
- Use the standard MCP `tools/list` request to learn the exact live tool surface and each
  command's contract. Tool results carry the payload as MCP `structuredContent`, and every
  tool declares safety annotations (read-only, destructive, idempotent).
- Time-travel debugging: `cmd_rewind_start` keeps a rolling snapshot ring while the game runs;
  after something goes wrong, `cmd_diff {from = "rewind:10s", ignore = "Transform", limit = 0}`
  shows a per-component summary of what changed and writes the full result as an artifact;
  `cmd_rewind_load` restores an entry, and `cmd_step` replays frame by frame.
  `cmd_map_info` reads tiles at a world point. `cmd_set` and `cmd_modify` take the
  component value as a JSON object: `cmd_set` replaces the whole component (adds it when missing,
  omitted fields reset to defaults) while `cmd_modify` changes only the named fields and skips
  targets that lack the component, so prefer `cmd_modify` for tweaking live values.
- `get_logs` returns captured engine log lines with a seq cursor (`after`); the operator-action
  feed (selection, marks, notes, edits, artifacts) logs under `tecs.debug.events`, so poll it
  with `get_logs {after = <seq>, contains = "debug.events"}`. `cmd_components_info` gives field
  names, C types, and defaults for building component payloads.
- Games can register custom debugger commands via `require("tecs.debug.commands").register`;
  registered commands appear as `cmd_<name>` tools too.

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
- Keep `query:iter()` for loops that run to exhaustion. If an archetype-level query loop may `break` or return
  early, use `query:cursor()` and call `cursor:close()` after the loop or immediately before returning.

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
    → `local Camera = require("tecs.gfx.Camera")`.
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
