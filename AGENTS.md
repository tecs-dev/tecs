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
make format         # Format sources in place
make format-check   # Report unformatted sources, writing nothing
make run            # Run the demo
make bench          # Shapes benchmark
make bench-physics  # Physics benchmark
make bench-sprites  # Sprite extraction, in four regimes
make bench-latency  # Event-to-photon latency, with synthetic input
make abi-check      # Verify generated cdefs against the C ABI
make shaders        # Build the shader pack a target without a compiler consumes
make package        # Install a tree into out/package
make check-package  # Verify a package carries its own dependencies
make test-package   # Run the spec suite against out/package
make presets        # List the platform matrix
make deps           # Install development dependencies (Homebrew)
```

`PRESET=` selects the target and defaults to `macos-arm64-dev`. A development preset resolves dependencies from
the system, which is convenient and not shippable. A packaged preset builds pinned revisions from source, and
`make check-package` is the gate on the difference, and only a packaged install can pass it. A packaged preset also
needs a Python with `jinja2` and `jsonschema` on the build host, which Mbed TLS generates sources with.

`macos-arm64-sanitize` and `linux-x64-sanitize` are development presets with AddressSanitizer and
UndefinedBehaviorSanitizer under the C. Run the host through them, which is `make run` or any of the
benchmarks; `make test` cannot use them, and CONTRIBUTING.md says why and what to do instead.

## Project Structure

```text
tecs/
├── src/tecs/
│   ├── init.tl            # The public API: one module per name, ECS and engine
│   ├── ecs.tl             # tecs.ecs, for a game and for engine code alike
│   ├── types.tl
│   ├── internal/          # ECS implementation
│   ├── utils/
│   ├── ffi/               # Generated bindings: SDL3, SDL3_mixer, Box2D, shaderc, SPIRV-Cross
│   ├── gpu/               # Device, pipelines, buffers, pass graph, shaders
│   ├── gfx/               # Camera, layers, distance-field text
│   ├── platform/          # Window, input, audio, events, time, files, the OS
│   ├── box2d/             # Box2D 3
│   ├── sequence/          # Sequencer, with the tween runtime inside it
│   ├── mcp/               # Debug server: transport, tools, sandbox
│   ├── Application.tl     # The lifecycle the host drives
│   ├── Renderer.tl        # World to GPU, owning the two halves below
│   ├── Extractor.tl       # World-facing: a world to a frame packet
│   ├── Backend.tl         # Device-facing: a frame packet to a frame
│   ├── FramePacket.tl     # What crosses between them
│   ├── audio.tl           # Clips, voices, groups, limits, the Sound component
│   ├── components.tl      # Engine components
│   ├── assets.tl
│   ├── workers.tl
│   ├── log.tl             # SDL's logging, per platform
│   └── json.tl            # lua-cjson, with the build's own copy found
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

`tecs` is what a game reaches, and every public name on it is `tecs.<module>.<thing>`: `tecs.ecs.newWorld`,
`tecs.gfx.Camera`, `tecs.newApplication`. A module may sit inside another module, one level and no
deeper, so `tecs.gfx.layers.configure` is also a public name and nothing goes past it. The host loads `tecs`
before a game's first line, so a game writes no require; a headless tool or a spec writes `require("tecs")`
and gets the same table.

`SURFACE` in `src/tecs/init.tl` is what a name resolves through, one descriptor per name at either level.
A descriptor with one principal module answers with that module's own table, so the record that types the
public name is the module's own and the names one level down are hung off it on first read. A namespace
assembled from several modules at one level cannot be typed by any of them, so `init.tl` declares a record
for it, and that record is a second copy of signatures and docblocks the modules already carry: prefer
one module per public name. `spec/surface_spec.lua` walks the declaration and holds the resolver to it,
and `spec/headless_spec.lua` holds the laziness that makes the resolver worth having: naming a namespace
loads nothing, and reading one module under it loads no sibling.

A subordinate module cannot require its parent. The parent names the subordinate's type, and Teal refuses
a require cycle even through a type-only require, so anything both of them need lives below both.

Engine modules require `tecs.ecs` rather than `tecs`, because `tecs` is the aggregator that pulls every engine
module in and a module `tecs` exports cannot also depend on `tecs` without making a cycle, which Teal rejects
even through a type-only require.

`tecs.ecs` is one table for both readers: the ECS a game writes, and the module engine code requires. So the
graph runs one way, and nothing under `tecs.ecs` may require the whole. A module that needs only a type reaches
for `tecs.types`, which sits below both.

`tecs.internal.*` modules are implementation details with no stability guarantee.

### ECS model

- Worlds own entities, components, systems, plugins, resources, queries and the state stack.
- Queries iterate through archetypes with `query:iter()`.
- Builtins are registered automatically and sit directly on `tecs.ecs`: `ChildOf`, `TTL`, `Paused`, `Disabled`,
  `EntityKey` and the state transition events. `Transform` is the exception and sits at the root, as
  `tecs.Transform`, because every subsystem moves the same one.
- The state model is a stack: `world:createState`, `world:pushState`, `world:popState`, `world:peekState`.

### Rendering

Deferred and GPU-driven. A compute pass culls and compacts a visible list, one indirect draw consumes it, and the
material dispatch is compiled into a single fragment shader from `assets/materials/*.glsl`. Shaders are GLSL
compiled to SPIR-V and translated for the backend; a release consumes a prebuilt pack and links no compiler.

Compaction is an ordered three-pass scan rather than an `atomicAdd`, because draw order has to be deterministic.

### Ported, and not yet

Working: windowing, input in three tiers behind a layer stack, events, the GPU pipeline, materials, camera,
layers, physics, workers and asset loading, logging, the debug server, sprite sheets with animation,
sequencing with tweening merged into it, distance-field text drawn through an instance producer, audio
on SDL3_mixer (a voice per track, groups by tag, keyed limits, fades, pitch, loop points, and streaming),
and shadows: an occluder mask every light marches against, and a drop shadow that reaches ambient.

Not ported: post-processing, UI, tiled maps and multi-camera.

## Development Guidelines

### Type Safety

- Prefer explicit Teal typing for public APIs, plugin interfaces and shared resources.
- Avoid `any` unless the boundary is genuinely dynamic, for example generic JSON payloads.
- Keep casts narrow and justified.

### Binding a C library that calls back

A C library that takes a function pointer is the one binding shape with a rule, and it is not
obvious, so it is written here rather than learned twice.

**A Lua function reached through `ffi.cast` cannot be entered from a compiled trace, and cannot be
entered from a thread the VM never created.** The first raises; the second is undefined. Both are
hazards of the callee, not the caller: calling _into_ a cast function pointer from Lua is fine and
compiles fine. What breaks is C calling back while a trace is running, which is exactly what
happens when the C call sits in a loop hot enough to compile.

That is why the two places this tree already needs a callback are C rather than Lua, and each says
so at the top of its file. `native/logsink.c` takes SDL's log output function because SDL logs from
threads it created, the audio device thread and the async IO pool among them. `native/worker.c`
owns the thread entry point for the same reason, and `src/tecs/workers.tl` states the rule from the
other side: raw thread creation is deliberately not exposed, because a thread entry written in Lua
is precisely that mistake. `box2d/TaskPool.tl` takes its two callbacks from C through
`tecsTaskPoolEnqueueCallback` rather than casting Lua ones.

So, in order of preference:

1. **Let the library write into memory instead.** Many callback APIs have a buffer or a queue form,
   and it is worth looking for one before writing a callback at all.
2. **Put the callback in C**, in `native/`, and hand results across a queue the Lua side drains.
   This is what the three cases above do.
3. **If a Lua callback is genuinely unavoidable**, keep the C call that triggers it off any path
   that compiles, and say in a comment why it cannot compile. This is fragile: a loop that was cold
   yesterday is hot after somebody calls it more often.

There are currently no `ffi.cast` callbacks in Lua anywhere in `src/`. Adding the first one is a
decision worth making deliberately.

### The C the tree is written in

**C99, and that is settled.** The only things a later standard offers this code are
`_Static_assert` and `_Atomic`; atomics already arrive from SDL as `SDL_AtomicInt`, and MSVC drives
the Windows preset with comparatively recent support for later C. `CMAKE_C_STANDARD_REQUIRED` is
`ON`, so a compiler that cannot give C99 fails to configure rather than quietly giving something
else.

`CMAKE_C_EXTENSIONS` is left at its default, which is `gnu99` rather than `c99`, and that is load
bearing on Linux. `-std=c99` defines `__STRICT_ANSI__`, glibc's `features.h` then leaves
`_DEFAULT_SOURCE` and `_GNU_SOURCE` undefined, and `native/mcodearena.c` reaches for `MAP_ANONYMOUS`
and `dladdr`, both of which those macros gate. Moving to `c99` means writing feature-test macros
into every file that touches a POSIX header, which buys nothing the standard pin does not already
buy.

**A header the FFI binds must stay a C subset LuaJIT can parse.** `scripts/gencdef.py` runs the
preprocessor over `native/*.h` and hands the result to `ffi.cdef`, which accepts less than a
compiler does. An anonymous union, a bit-field of an unusual width, a `_Static_assert`, an attribute
in a declaration: each of those compiles and then breaks binding generation, which fails as a module
that will not load rather than as a header that will not compile. So the headers under `native/`
are declarations and nothing else, and anything a binding does not need stays in the `.c`.

Do not write `_Static_assert` layout checks. `make abi-check` already does the stronger version: it
generates a C program comparing LuaJIT's view of every record against the compiler's, checking size,
alignment and every field offset across 219 records. A static assert only checks a header against
itself.

### Testing

- Add or update tests when changing behavior, fixing bugs or extending public APIs.
- Engine specs are Lua under `spec/`; ECS specs are Teal under `spec/tecs/`. Both run in one `make test`.
- Teal specs are compiled by `scripts/compile_specs.lua`, which emits code even when a file does not type-check.
  That is deliberate: their type errors are in the test code, and refusing to build them would take real coverage
  away over that. `make check` therefore covers `src`, `main.tl` and `bench`.

### Documentation

**A user-facing change is not done until its documentation is.** Landing one without the other is
the same defect as landing one without a test: the tree says something that is not true, and the
next person believes it. This is not a nicety, and reviews should treat a missing page edit the way
they treat a missing spec.

What "user-facing" means here: anything a game can call, configure, spawn or observe. A new module,
a new function, a renamed or removed field, a changed default, a changed error, a behavior a game
could depend on. Internals under `internal/` are not, unless the change is visible through something
that is.

Two places, and they hold different things:

- **`docs/`** is the reference. A module's page says what it is, what it takes and what it answers.
  `make docs-check` requires every page to carry a one-line `description:`, and `make docs-dev`
  serves the site with hot reload while you write.
- **`README.md`** is the design record. It holds why, not what: the decision, the alternative that
  lost, and the constraint that forced it. A change that only adds a function needs no entry; a
  change that settles a question does.

The failure this exists to prevent has already happened here. Pages ported from an earlier tree
claimed writing `Transform` needed no dirty tracking and that `archetype:get` on a tag returns nil.
Both read as authoritative and both were false, and neither was caught by a test, because nothing
tests prose. The only defense is the person making the change, at the time they make it.

- Prefer linking to entry points that exist in this repo, not guessed future paths.
- A page that cannot be verified against the code should not be written. A gap is honest; a
  confident wrong answer is not.

`make docs-check` is the gate, and it holds four things: every page carries a one-line
`description:`; the module list matches `src/tecs/init.tl` in three listings at once
(`docs/index.md`, `docs/modules/index.md` and the sidebar in `docs/.vitepress/config.mts`), in
one order, with one page per public name and no page outliving its module; every link and anchor
resolves; and each page's generated reference section matches a fresh render. That last one is
why a page is never hand-edited below its `@generated` marker: run `python3 docs/scripts/reference.py`.

### Docblocks

Every public function, record and field carries a `---` docblock, and every public function
carries `@param` for each parameter and `@return` for each return.

A tag earns its place by saying what the signature cannot: units, the coordinate space, what nil
means, what happens at a boundary, whether a returned table is the caller's to keep or a view
onto something live, which errors are raised rather than returned. A tag that restates the
parameter's own name is worse than no tag, because it costs a line and answers nothing.

Documentation lives on the declaration, which is the record field, and the implementing function
below does not repeat it. Two copies drift, and tealdoc reads the declaration.

### Mutation and Dirty Model

The rules that prevent the most common defect class:

- Reads use `archetype:get` / `world:get`; writes go through `getMut`, which marks the component's column dirty on
  the archetype. Never `getMut` in a loop that might not write, it defeats every dirty-gated consumer.
- Direct cdata writes through `world:get` on FFI components need an explicit
  `world:markComponentDirty(id, Component)` or the GPU never re-syncs.
- Dirty bits clear at the end of each `world:update`.
- `world:batchSpawn` skips FFI defaults; set every field in the callback.
- Keep `query:iter()` for loops that run to exhaustion. If an archetype-level query loop may `break` or return
  early, use `query:cursor()` and call `cursor:close()` after the loop or immediately before returning. Leaving
  one early through `iter` leaves the world deferred, which silently queues every later spawn.

### Code Style

`STYLE.md` is the long form, and it separates what `make format` decides from what it cannot. Layout is the
formatter's: indentation, columns, wrapping, alignment. What is left to a person is `local` and `<const>` where
appropriate, early returns over deep nesting, require grouping (the formatter deliberately does not sort them,
because import order is meaningful), comments sparse and informational, and the naming rules above.

### Naming

- **Identifiers** (functions, methods, record fields, option keys, non-import locals): `camelCase`. No
  `snake_case`.
- **Filenames and their import bindings** follow a class/module split:
  - The file _is_ a class (one dominant type you construct and call methods on, including component records):
    **PascalCase**, e.g. `Camera.tl` → `local Camera = require("tecs.gfx.Camera")`.
  - The file is a _module_ containing a class or a namespace of functions: **luacase** (all lowercase, no
    separators), e.g. `shaderpack.tl` → `local shaderpack = require("tecs.gpu.shaderpack")`. Multi-word module
    files drop their underscores.
- Prefer single-word module names where a clear one exists.
- Prefer a flat `module.tl` over `module/init.tl` when the module is a single file.
- The `require` path mirrors the filename; the local binding mirrors it too.

### Externally typed strings are a separate compatibility surface

**Reorganizing Lua namespaces must not rename persisted keys, logger categories, component names,
event kinds, MCP tool names, or other externally typed strings.**

A Lua name is reached by code this tree can see, so moving one is a rename in a single commit. These
are reached by a save file written last year, a filter a developer typed into a shell, a JSON payload
an agent sends, or a snapshot another build wrote. Nothing here can see those call sites, so nothing
here may move them.

What the rule covers:

- **Snapshot handler keys** (`"tecs.random"`, `"tecs.physics"`, `"tecs.audio"`, `"tecs.sequence"`),
  and **component, event and relationship names**, since a snapshot names components by string. The
  failure mode is what makes this absolute rather than a preference: `random.tl`'s `restore` falls
  through to reseeding when it finds no state, so a renamed key loads successfully and diverges
  rather than erroring.
- **Logger names**, which are the unit `SDL_SetLogPriority` filters on, so they are configuration a
  developer types rather than an identifier.
- **System names**, which the debug server reports and an agent selects on.
- **MCP tool names**, and the argument keys of their schemas.
- **Pass and target names** in the deferred graph, which a game names to add a pass of its own.

So a module that moves keeps its strings, and they will look like oversights afterwards. Say so at
the declaration: a comment naming the string a compatibility surface is what stops the next reader
tidying it.

Renaming one of these is a migration, not a rename. It needs an explicit path from the old value and
validation that finds state written under it, and neither is in scope for a namespace change.

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
