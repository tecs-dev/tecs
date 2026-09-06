# Tecs Project Guide

## Project Overview

Tecs is a typed entity component system and the game engine built around it, written in Nupp against Rust
services. The two were separate projects and are now one: the ECS knows what the GPU reads, and the engine is
not a layer bolted on top of a renderer-agnostic core.

The Rust host owns the loop. A game is a **component**: one compiled Nupp artifact exporting a session
constructor, which the host selects with `--entry` and drives one frame at a time. Nothing dynamically requires
game code, and no native window handle crosses into it. Window and events are `winit`, the GPU is `wgpu`, and
audio, physics and gamepads are Rust services behind Tecs-owned command and observation contracts.

Entities are the interface. Anything that renders or updates per frame is an entity in a world.

Primary entry points:

- `src/tecs/ecs.nupp`: the ECS a game writes and engine code requires
- `src/tecs/host.nupp`: the managed-call bridge the Rust host drives
- `nupp.lua`: the manifest naming every module, component target and the documentation site

## Key Commands

Nupp owns the project workflow. `nupp.lua` names builds, the native integration
test command and project tasks. Cargo compiles Rust artifacts inside those tasks.
Use the Nupp compiler on `PATH`; for sibling checkouts, add the absolute
`../nupp/bin` directory to `PATH` before starting.

```bash
nupp task deps                # Install the development formatters
nupp tasks                    # List the targets nupp.lua configures
nupp check --strict           # Type-check every Nupp source, strictly
nupp task format              # Format every supported source language in place
nupp task format-check        # Report sources that are not formatted
nupp test                     # Build and run the test suites
nupp build --target flatcolor
nupp task flatcolor --frames 120
nupp task bench shapes        # Run a benchmark from bench/nupp
nupp build --target docs      # Render the site into out/docs
nupp task docs-check          # Render it into a scratch directory and gate it
nupp task docs-dev            # Serve it, rebuilding on a change
nupp task verify              # Everything above, plus the Rust host
nupp task presets             # List the release matrix
nupp task package --preset macos-arm64
nupp task check-package       # Gate out/package
nupp task test-package --preset macos-arm64
nupp task clean
```

`nupp task test-tools` checks the separate `tools/nupp.lua` project and its
regression tests. Tooling dependencies must stay outside the game source set,
so they cannot add native process requirements to game components.

`nupp task deps` installs `stylua` and `prettier` on macOS. Other platforms
need both on `PATH`. Rust is pinned by `rust-toolchain.toml`; the compiler
revision is specified in `docs/getting-started.md` and CI.

`nupp task format` runs `cargo fmt`, `nupp fmt` and the suffix-dispatched formatters together. Naming paths
narrows it to those files, with Nupp and rustfmt handling their respective sources.

`nupp task package` installs a relocatable release into `out/package`. A release carries `bin/tecs-host`, the
prebuilt `bin/shaders.tecspack` and its manifest, `lib/` holding the Nupp runtime library beside `tecsaudio`,
`tecsgamepad` and `tecs_physics`, the compiled components under `share/tecs/components`, and the notices,
licenses and Cargo inventory under `share/tecs`. A Windows package puts every library in `bin/`, where that
loader looks.

`nupp task check-package` is the gate on the difference between a development preset and a release one. A
release records a loader-relative run path (`@executable_path/../lib`, or `$ORIGIN/../lib`) and ships compiled
shaders; a development preset links the staged SDK where it sits and ships none, and the check reports it
rather than passing it. `nupp task test-package` installs a clean release, checks it, copies it somewhere
unrelated, and runs the native smoke component and the showcase from there with every Tecs environment
override removed, which is the only way to find out whether an install is relocatable rather than merely tidy.

Packaging is native only. The Nupp toolchain stages an embedding library for the machine it runs on, so a
Windows release is built on Windows.

Two things a packager learns the hard way. The three service libraries resolve in a release through the
_executable's_ run path, not through the ancestor walk in `tecs.internal.nativelibrary`: that walk starts at
the module's source directory, which a compiled component no longer has, so what actually finds them is a load
by bare name reaching the loader's search of `lib/`. And a guarded plugin failure is invisible to `--headless`,
because `run_headless` in the Rust host never calls `tecs.host.crashed`, so the smoke component prints a line
on success and the packaging test matches that line rather than trusting the exit status.

Both `nupp task run` and the host's own `cargo build` need a Nupp embedding SDK, which
`native/rust/winit-host/build.rs` stages through the Nupp compiler's `scripts/toolchain` in a checkout beside
this one. Set `NUPP_SDK` to a staged one to skip that.

Two things about that SDK are worth knowing before they cost an afternoon. It is staged for a named feature
set, and the runtime refuses to load a component whose declared features the library lacks, which reads as a
load failure in a host that built cleanly. Staging runs Nupp's own Cargo build, so it clears inherited
Cargo process overrides. Keep this tree's Rust pin aligned with the SDK's compiler: `libnupp.a` carries
Rust's standard library. Linux links the SDK's shared C API library because optimized linking can
pull duplicate standard-library objects from its static archive even with identical compiler versions.

Benchmarks are in `bench/nupp`, and `signature` rather than `bitset` is the archetype-signature one, because
this ECS has no bitset. `latency` has no counterpart: nothing in Nupp pushes an event into the host queue, and
no stage is marked inside a host turn.

## Project Structure

```text
tecs/
├── src/tecs/
│   ├── ecs.nupp            # The ECS, for a game and for engine code alike
│   ├── application.nupp    # The lifecycle a host drives
│   ├── host.nupp           # The managed-call bridge the Rust host drives
│   ├── internal/           # ECS, sequencer, MCP and frame-packet implementation
│   ├── gfx/                # Components, camera, layers, images, sheets, text, lighting
│   ├── gpu/                # Material dispatch and the declared pass graph
│   ├── platform/           # Window, events, audio and gamepad backends
│   ├── physics/            # Rapier contract and binding
│   ├── input.nupp          # Gameplay input over the platform event stream
│   ├── audio.nupp          # Clips, voices, groups, limits, the Sound component
│   ├── sequence.nupp       # Sequencer, with the tween runtime inside it
│   ├── assets.nupp         # Asset orchestration
│   ├── mcp.nupp            # Debug server: transport, tools, sandbox
│   └── events.nupp, data.nupp, files.nupp, watch.nupp
├── native/rust/
│   ├── winit-host/         # The application loop, the wgpu renderer, the host ABI
│   ├── tecs-audio/         # cpal output and capture behind a batched contract
│   ├── tecs-gamepad/       # gilrs enumeration and observations
│   ├── physics/            # Rapier storage and stepping
│   └── build-support/      # Native packaging and binary inspection
├── tools/                  # Isolated Nupp project for development commands and tests
├── assets/                 # shaders/ (WGSL) and materials/, read by the host
├── examples/nupp/          # Component entries: flatcolor, sprites, lighting, smoke
├── tests/                  # Suites; those reaching internals live in tests/tecs
├── bench/nupp/tecs/        # Benchmarks
├── docs/                   # Guides, plus the generated reference
├── nupp.lua                # The build manifest
└── out/                    # Build output
```

## Core Architecture Notes

### Tecs defers to Nupp

**Where Nupp provides a facility, Tecs uses it directly and wraps nothing.** Not a thin module
around it, not a constant table naming its arguments, not a re-export for convenience. A wrapper
costs a file, a name, and a second place to look, and it earns that back only by adding behavior
Nupp does not have.

The logging module is the worked example, and it is worked the wrong way twice. It existed to add a
per-name threshold Nupp does not offer, which is a real thing to add; then seven modules reached
past it to `nupp.log` anyway and the threshold it existed for stopped reaching them, so the wrapper
was costing a file and delivering nothing. It is gone, and every module names its logger to
`nupp.log.named`. Filtering is `nupp.log`'s process level until Nupp has more, and if per-name
filtering is worth having it is worth having in Nupp, where every program gets it.

Read this as the general rule the "not a line-for-line port" instruction implies: tasks,
suspension, workers, bytes, files, paths, JSON, networking, time, random and logging are Nupp's.
What survives the crossing is what is Tecs-specific, and a module that only forwards is not.

### The module graph

A game requires the module it needs: `tecs.ecs`, `tecs.gfx`, `tecs.application`. There is no aggregator, so
there is no cycle to design around and no lazy resolver to keep honest. Public names are
`tecs.<module>.<thing>`, and one level deeper where a module has children, so `tecs.gfx.layers.configure` is a
public name and nothing goes past it.

Engine modules require `tecs.ecs` rather than anything above it, and a module that needs only a type reaches
for the module that declares it. `tecs.ecs` is one table for both readers: the ECS a game writes and the module
engine code requires.

`tecs.internal.*` modules are implementation details with no stability guarantee, and the compiler enforces
that: a module may statically import `tecs.internal.*` only if its own first namespace segment is `tecs`. That
is why test suites reaching internals live in `tests/tecs/` with a one-line forwarder at `tests/<name>.nupp`,
which is where discovery looks.

A module with children lives in `name/init.nupp`. Prefer a flat `module.nupp` when there are none.

### ECS model

- Worlds own entities, components, systems, plugins, resources, queries and the state stack.
- Queries iterate through archetypes with `query:iter()`.
- Builtins are registered automatically and sit directly on `tecs.ecs`: `ChildOf`, `TTL`, `Name`, `Paused`,
  `Disabled`, `EntityKey`, `RelativeTransform2D` and the state transition events. `Transform2D` sits there too,
  because every 2D subsystem moves the same one.
- A component names what it cannot be meaningful without, the list flattens transitively, and a spawn or a set
  that adds the component adds them too.
- The state model is a stack: `world:createState`, `world:pushState`, `world:popState`, `world:peekState`.

### Rendering

Deferred and GPU-driven. A compute pass culls and compacts a visible list, one indirect draw consumes it, and
the material dispatch is compiled into a single fragment shader from `assets/materials/*.wgsl`. Shaders are
WGSL with no translation step; a release consumes a prebuilt pack.

Compaction is an ordered three-pass scan rather than an `atomicAdd`, because draw order has to be deterministic.

Nupp extracts one versioned, host-endian frame packet per completed frame. Rust owns adapters, surfaces,
resources, pipelines, submission and presentation, and validates the packet it is handed.

### What is here, and what is not

Working: windowing, events, keyboard, pointer, gamepad and touch input, durable entity keys, the GPU pipeline
with materials, camera, layers, images, clips, sprite sheets with animation, distance-field text, deferred
lighting with occluder masks, drop shadows and optional bloom, device loss, physics over Rapier, audio playback
and recording over `cpal`, sequencing with tweening merged into it, asset orchestration, file watching, and the
MCP debug server.

Deferred with a recorded contract: pen input, and audio device hotplug. `src/tecs/input.nupp` states what would
have to come back.

Intentionally removed: general post-processing, tiled maps, multi-camera, gamepad motion sensors and touchpads,
trigger rumble, LED, player index, and standalone sensors. Each is recorded at its declaration or in the
migration plan rather than silently absent.

## Development Guidelines

### Type Safety

- Prefer explicit typing for public APIs, plugin interfaces and shared resources.
- Ownership annotations (`exclusive`, `borrows`, `takes`) are checked, so write the one that is true rather
  than the one that compiles.
- Avoid `any` unless the boundary is genuinely dynamic, for example generic JSON payloads.
- Keep casts narrow and justified.

### Error reporting

Tecs distinguishes mistakes in a call from failures of valid work rather than
putting every outcome in one allocated result wrapper.

- An invalid caller argument raises at the call site. A missing required
  value, an invalid enum string, a value from the wrong constructor, and a
  range the signature forbids are programmer errors, not operational
  outcomes.
- A synchronous operation that could not produce its value returns
  `nil, reason`. A synchronous operation whose useful answer is whether it
  succeeded returns `false, reason`. The reason is a non-empty string suitable
  for context in a log or a raised error.
- A cooperative operation preserves the failure shape on its declaration.
  An operation declared as `value, reason` returns that pair after resuming.
  An operation declared with only a value raises its operational reason from
  that direct call. The pump that discovers a failure never raises later and
  out of context; it resumes the suspended call that owns the outcome.
- Cancellation remains separate from operational failure in private producer
  state. World shutdown uses it to unwind a suspended system and its lexical
  resource scopes rather than presenting a failed operation to later code.
- `close`, `flush`, and similar final operations report failures discovered
  only after buffered work reaches its destination. An earlier successful
  write does not suppress that delayed error. Finalizers remain a leak safety
  net and cannot report such failures, so callers explicitly close resources
  whose completion matters.

Do not introduce a `Result` record, tuple wrapper, or per-call allocation only
to make these shapes look uniform. Their uniformity is semantic: programmer
errors raise before valid work starts, returned reasons report failures where
the signature exposes a reason, and a direct value-only operation raises its
operational failure at the call that requested the value. Document an
intentional exception on its declaration.

### Binding a Rust library that would call back

A native library that takes a function pointer is the one binding shape with a rule, and it is not
obvious, so it is written here rather than learned twice.

**A managed function reached through a cast cannot be entered from a compiled trace, and cannot be
entered from a thread the virtual machine never created.** The first raises; the second is
undefined. Both are hazards of the callee, not the caller: calling _into_ a cast function pointer is
fine and compiles fine. What breaks is native code calling back while a trace is running, which is
exactly what happens when the call sits in a loop hot enough to compile.

So, in order of preference:

1. **Let the library write into memory instead.** Many callback APIs have a buffer or a queue form,
   and it is worth looking for one before writing a callback at all.
2. **Put the callback in Rust**, and hand results across a queue the Nupp side drains.
3. **If a managed callback is genuinely unavoidable**, keep the native call that triggers it off any
   path that compiles, and say in a comment why it cannot compile. This is fragile: a loop that was
   cold yesterday is hot after somebody calls it more often.

The three Rust services take the second path. `tecs-audio` fills a preallocated command buffer that
Nupp flushes once per update and drains observations from on the frame thread, so the `cpal`
callback thread can never enter Nupp. `tecs-gamepad` runs a `CFRunLoop` thread on macOS and nothing
in it takes a function pointer. The physics service is one call per fixed step, with the managed
side owning every buffer Rust borrows for exactly that call.

There are no cast callbacks anywhere in `src/`. Adding the first one is a decision worth making
deliberately.

Load a native library through `src/tecs/internal/nativelibrary.nupp`, which searches for `lib/` and then a
Cargo target directory. Do not put a `from` clause on a `cdef function`: it binds eagerly to one platform's
file name and only resolves where the system loader already looks. Declare bare symbols after calling
`nativelibrary.open`. `src/tecs/physics/rapier.nupp` is the worked example.

### Testing

- Add or update tests when changing behavior, fixing bugs or extending public APIs.
- Suites are Nupp under `tests/`, and discovery reads `tests/*test.nupp` without recursing. A suite that
  imports `tecs.internal.*` lives at `tests/tecs/<name>test.nupp` with a one-line forwarder where discovery
  looks, because the checker restricts internal imports to the `tecs` namespace.
- `tests/tecs/compatibilitytest.nupp` pins every externally typed string the tree declares. A rename fails
  there rather than changing what a save file means. Read it as the specification of that surface.
- `nupp check --strict` covers `src`, `examples/nupp`, `tests` and `bench/nupp`, so a test calling a function
  that does not exist fails the gate rather than slipping through.
- Rust tests run with `cargo test --workspace`. `nupp task verify` runs both halves plus the host.
- A `src/tecs/**.nupp` module absent from the `headless` target's `entries` in `nupp.lua` is neither built nor
  checked. A new module goes there.

### Documentation

**A user-facing change is not done until its documentation is.** Landing one without the other is
the same defect as landing one without a test: the tree says something that is not true, and the
next person believes it. This is not a nicety, and reviews should treat a missing page edit the way
they treat a missing spec.

What "user-facing" means here: anything a game can call, configure, spawn or observe. A new module,
a new function, a renamed or removed field, a changed default, a changed error, a behavior a game
could depend on. Internals under `internal/` are not, unless the change is visible through something
that is.

Three places, and they hold different things:

- **Docblocks** hold the API documentation, and the generated reference is rendered from them, so a signature
  has no second copy to drift from. This is where almost every documentation change belongs.
- **`docs/`** holds what a declaration cannot: a workflow that crosses modules, an architecture decision, a
  comparison. It does not restate a signature, and it carries no handwritten module catalog, because the
  reference already has one. `nupp task docs-check` requires a one-line `description:` on every page and
  refuses an em dash; `nupp task docs-dev` serves the site while you write.
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

`nupp task docs-check` is the gate, and it holds two things: the handwritten pages carry a description and
no em dash, and the render resolves every link and anchor over the site it just wrote. A docblock the generator
cannot read fails there too.

### Docblocks

Every public module starts with a long `--[[ ... ]]` doc comment holding its introduction, cross-symbol
constraints and primary examples. Write `--[==[` when the prose itself contains `]]`. Every public function,
record and field carries a `---` docblock, and every public function carries `@param` for each parameter and
`@return` for each return. `@raises` says what makes a function raise, one line per condition, because there is
no signature to find that out from.

Write every summary and tag as a complete sentence with an actor and a verb. A function says what it does:
`Returns the number of queued messages.` A field says who controls it and what it means:
`Read-only. Reports the number of queued messages after the last send.` Begin every public field with
`Caller-writable`, `Read-only` or `Engine-owned`. An engine-owned field also says why it is public and
whether ordinary game code should ignore it.

Use active voice. Never use an em dash. Name sections for their subject, not as generic questions such as
`What this means`, `How it works` or `Why this exists`. Prefer one complete example to several paragraphs
that narrate the same calls.

An example that calls a Tecs module inside a frame or other hot loop binds that module to a local outside the
loop, and calls through the local rather than resolving the module again on every iteration.

A tag earns its place by saying what the signature cannot: units, the coordinate space, what nil
means, what happens at a boundary, whether a returned table is the caller's to keep or a view
onto something live, which errors are raised rather than returned. A tag that restates the
parameter's own name is worse than no tag, because it costs a line and answers nothing.

Link the first mention of a public type in each docblock with the generator's cross-reference form, which is a
Markdown link whose target is the name: ``[`Sound`](tecs.audio.Sound)``. Empty link text renders the name
itself, so `[](tecs.ecs)` is the whole cost of a reference in passing. Do not write a path: a path resolves to
the emitted Markdown file rather than the site route, and does so silently. Use backticks without a link for
functions, fields, constants, enum values and literal strings. Do not link internal types.

Documentation lives on the declaration, which is the record field, and the implementing function
below does not repeat it. Two copies drift, and the generator reads the declaration.

### Mutation and Dirty Model

The rules that prevent the most common defect class:

- Reads use `archetype:get` / `world:get`; writes go through `getMut`, which marks the component's column dirty
  on the archetype. Never `getMut` in a loop that might not write, it defeats every dirty-gated consumer.
- An out-of-band write to a committed value needs an explicit `world:markComponentDirty(id, Component)` or the
  GPU never re-syncs.
- Dirty bits clear at the end of each `world:update`, after every phase has run. A consumer that has to see
  them samples from `Last`, which is the final phase before that clear.
- Query iteration owns no mutation scope or resource. A loop may `break`, return, raise or suspend without
  cleanup; structural mutations remain staged until the pipeline's next declared barrier.

### Code Style

`STYLE.md` is the long form, and it separates what `nupp task format` decides from what it cannot. Layout is
the formatter's: indentation, columns, wrapping, alignment. What is left to a person is `const` where the
binding is strong, early returns over deep nesting, require grouping (the formatter deliberately does not sort
them, because import order is meaningful), comments sparse and informational, and the naming rules below.

### Naming

- **Identifiers** (functions, methods, record fields, option keys, non-import locals): `camelCase`. No
  `snake_case`.
- **Module files and their import bindings** are **luacase**: all lowercase, no separators, so
  `rendercomponents.nupp` binds as `local rendercomponents = require("tecs.internal.rendercomponents")`.
  Multi-word module files drop their underscores.
- Prefer single-word module names where a clear one exists.
- Prefer a flat `module.nupp` over `module/init.nupp` when the module has no children.
- The `require` path mirrors the filename; the local binding mirrors it too.
- **Component and type names are PascalCase** and live inside a module rather than in a file of their own:
  `tecs.gfx.Camera2D` is a name `src/tecs/gfx/init.nupp` exports.

### Externally typed strings are a separate compatibility surface

**Reorganizing module namespaces must not rename persisted keys, logger categories, component names,
event kinds, MCP tool names, or other externally typed strings.**

A module name is reached by code this tree can see, so moving one is a rename in a single commit. These
are reached by a save file written last year, a filter a developer typed into a shell, a JSON payload
an agent sends, or a snapshot another build wrote. Nothing here can see those call sites, so nothing
here may move them.

What the rule covers:

- **Snapshot handler keys** (`"tecs.random"`, `"tecs.physics"`, `"tecs.audio"`, `"tecs.sequence"`),
  and **component, event and relationship names**, since a snapshot names components by string. The
  failure mode is what makes this absolute rather than a preference: a restore that falls through to
  a default when it finds no state loads successfully and diverges rather than erroring.
- **Logger names**, which are the unit a log threshold filters on, so they are configuration a
  developer types rather than an identifier.
- **System names**, which the debug server reports and an agent selects on.
- **MCP tool names**, and the argument keys of their schemas.
- **Pass and target names** in the deferred graph, which a game names to add a pass of its own.

So a module that moves keeps its strings, and they will look like oversights afterwards. Say so at
the declaration: a comment naming the string a compatibility surface is what stops the next reader
tidying it. `tests/tecs/compatibilitytest.nupp` holds the tree to the whole set.

Renaming one of these is a migration, not a rename. It needs an explicit path from the old value and
validation that finds state written under it, and neither is in scope for a namespace change.

**A device vocabulary is the exception, and follows the library that reports it.** Key names,
mouse button names and gamepad button and axis names came from SDL and now come from `winit` and
`gilrs`, so `x1` is `back`, `A` is `KeyA` and `Left` is `ArrowLeft`. A binding saved by an SDL build
does not survive that, and no migration is provided: the alternative is a translation table that
exists only to preserve the vocabulary of a library the engine no longer links, maintained forever
against two upstreams. The numeric codes never moved, so what changed is the spelling.

Two consequences worth stating. A name that no current library can report is not published, however
long SDL published it, because a button nothing can press is the same empty promise as a logger
nothing writes through. And a vocabulary that comes from a dependency's `Debug` implementation is
pinned by a test, because a bump can otherwise rename a key with nothing here failing to build.

### Performance

- Avoid allocations in hot paths. Rendering and extraction are hot.
- Prefer archetype/query iteration patterns that work with contiguous columns.
- Be careful when changing rendering, storage and snapshot code paths; they are performance-sensitive.
- Benchmarks are the argument. `nupp task bench shapes` is a uniform loop over transforms and
  `nupp task bench physics` is lumpy and CPU-bound, and a frame-structure change has to be judged against
  both, p50 and p95 together.
- `nupp task bench signature` and `nupp task bench snapshot` isolate the two core paths those scene
  benchmarks cannot: archetype signature and query matching, and binary save/load throughput.
- A benchmark is compiled at `-O2`, because a measurement taken at a different optimization level than the one
  that ships answers a question nobody asked.

### A note on checker cost

A module once cost 2093 seconds of checker CPU with a type parameter appearing in none of its record's fields.
That is believed fixed upstream, but if a check suddenly takes minutes rather than seconds, an unused type
parameter is still the first thing to look at.

## Related repositories

The Nupp compiler, its standard library and its documentation are the reference for the language. Read
`nupp/docs/` and `nupp/src/nupp/` in the sibling checkout; the signatures there are the contract.

Design notes live in the separate `../tecs-plans` repository.
