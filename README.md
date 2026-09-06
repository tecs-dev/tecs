# tecs

Tecs is a typed entity component system and 2D game engine, written in Nupp
against Rust services. Entities are the interface: anything that updates or
renders belongs to a world.

A game is a component. It exports a session constructor, and the Rust host
selects that export by name and drives it one frame at a time:

```nupp
module mygame

local application = require("tecs.application")
local ecs = require("tecs.ecs")
local gfx = require("tecs.gfx")
local host = require("tecs.host")

local function install(exclusive app: application.Application): nil
    app.world:addSystem({
        name = "game.Tick",
        phase = ecs.phases.Update,
        run = function(dt: number): nil
            -- Update game state.
        end,
    })
end

--- Creates the game's host session through its statically linked plugin.
export function create(
    title: string?,
    width: integer?,
    height: integer?,
    debug: boolean?,
    maxFrames: integer?
): host.Session
    return host.createWithPlugin(install, title or "My game", width, height, debug, maxFrames)
end
```

The ECS runs with no host at all, so simulation code, a headless tool and a
test suite reach the same world without starting a graphics stack.

## Features

- Typed ECS with archetype queries, plugins, state stacks, relationships,
  bundles, durable entity keys and snapshots.
- GPU-driven 2D rendering with a declared pass and target graph, compiled
  material dispatch, ordered GPU culling, deferred lighting, occluder masks,
  drop shadows and optional bloom.
- Camera, layers with positioning modes, images, clips, sprite sheets with
  animation, and distance-field text.
- Input across keyboard, pointer, gamepad and touch; audio playback, recording
  and device enumeration; physics over Rapier; sequencing with tweening; asset
  orchestration; file watching; and an MCP debug server.

General post-processing, tiled maps and multi-camera rendering are
intentionally absent rather than pending.

## Ownership boundaries

| Concern                                                | Owner                               |
| ------------------------------------------------------ | ----------------------------------- |
| Game code, ECS semantics, extraction, engine policy    | Nupp, in `src/tecs`                 |
| Window and event loop                                  | Rust, with `winit`                  |
| GPU resources, pipelines, submission, presentation     | Rust, with `wgpu`                   |
| Audio, gamepads, physics                               | Rust services behind Tecs contracts |
| Tasks, suspension, files, bytes, JSON, networking, log | The Nupp standard runtime           |

Two rules follow from that table and are worth stating separately.

**Where Nupp provides a facility, Tecs uses it directly and wraps nothing.** A
wrapper costs a file, a name and a second place to look, and it earns that back
only by adding behavior Nupp does not have. The logging module is the worked
example: it existed to add a per-name threshold, seven modules then reached past
it to `nupp.log` anyway, and the threshold it existed for stopped reaching them.
It is gone, and every module names its logger to `nupp.log.named`.

**Maintained Rust crates own published formats and coarse CPU algorithms, and
no crate is called per entity or per draw during a frame.** `symphonia`
decodes audio, `cpal` owns the device, `gilrs` owns gamepad enumeration and its
mapping database, and Rapier owns rigid-body storage and stepping. What crosses
into game code is a flat typed value, not a library handle.

## Structural mutation

Tecs uses one deferred structural model. Systems in a phase stage spawns,
despawns, additions, removals, bundles, and batches together; the scheduler
publishes them at the phase boundary. A system can declare `commitBefore` or
`commitAfter` when it unconditionally needs an extra boundary. A conditional
`enqueueCommit` request made during a system is honored only after that system
returns, before the next one runs; outside system dispatch it settles
synchronously for tests and debug tooling. Mutation itself never switches to
an eager path.

Value access stays direct. `getMut` marks and returns a live component because
changing its fields cannot move the entity between archetypes. Replacing an
existing component value through `set` takes the same immediate path. This
keeps the common simulation loop cheap without maintaining a second structural
mutation implementation.

### Builtin systems and the hierarchy gate

The builtins a game reaches without registering anything are split across three
modules rather than one. `tecs.internal.components` holds the definitions that
depend on nothing, `tecs.internal.rendercomponents` holds `Transform2D`, and
`tecs.internal.builtins` holds the two that a world has to run a system for,
`TTL` and `RelativeTransform2D`. The split is forced: naming the world type is
what registering a system needs, and `tecs.internal.world` requires the
component registry, so putting the systems beside the registrations would be a
cycle. `tecs.ecs.newWorld` calls `install` instead, which is why a world built
through the internal module directly runs none of them.

Relative transforms recompose behind a dirty gate, and the gate is sampled
once, from a system in `Last`, which is the final phase before dirty marks
clear at the end of the update. The SDL implementation sampled in `RenderLast`
and then again from a private world hook that ran after the pipeline, because a
write from `Last` would otherwise be lost. Keeping the hook bought nothing
here: there is no phase after `Last`, so the extra sampling point had nothing
left to catch.

The composed result lands in a scratch transform first and reaches the entity's
column only when it differs from what is already there. Writing unconditionally
would mark `Transform2D` dirty on every child every frame, which reopens the
gate the next frame and turns the whole optimization into a constant cost. The
old implementation depended on `float32` storage rounding the comparison; this
one stores doubles, and composition of unchanged inputs is deterministic, so
exact equality converges the same way.

The hierarchy resolver detects a `ChildOf` cycle and raises rather than
overflowing the stack.

## Async design

Asynchronous operations return their values directly. A system does not choose
between a callback, a future, and a coroutine API. During `world:update`, the
logical update runs inside one structured `nupp.tasks` scope. An operation that
must wait parks that coroutine at the call site through the surrounding
suspension handler; an operation that is ready returns inline. The host keeps
turning and may present the last completed frame until the update resumes in
the same system and schedule position.

The coroutine belongs to the world update, not to an entity or an I/O call.
This keeps entity loops from creating a task per spawn and amortizes the
scheduler state across frames. Startup, shutdown, and calls made outside
`world:update` use the same direct-value API.

`tecs.internal.framepump` is what makes that work across the embedding
boundary. The call that starts or polls a host operation never yields: a wait
parks the operation's coroutine in the pump, and a later polling turn resumes
it when readiness is reported. Resuming during that notification releases the
one-shot source before MCP or another driver polls it again. Deferring that
resumption left completed network waits registered and fired them twice. So a
parked update is one the host observes as `parked` and asks again, rather than
a yield escaping into Rust.

Failure reporting follows the shape on the declaration rather than a wrapper
type. An operation declared as `value, reason` returns that pair after
resuming; an operation declared with only a value raises its operational reason
from the direct call that requested it. The pump never raises later and out of
context, it resumes the call that owns the outcome. Cancellation stays a
separate outcome from failure, which is what lets host shutdown unwind a
suspended system and its lexical resource scopes without presenting a failed
operation to later code.

External input is retained at update boundaries. The host queues translated
events, a new update seals one immutable batch, folds input once, and
dispatches observers from the scheduler-owned `Ingress` phase. If an observer
suspends, later events wait for the next update. Watcher changes use the same
boundary. The scheduler therefore commits a phase once and extraction never
observes half of an external batch.

### Application lifecycle and presentation timing

The application owns asset orchestration and optional debugging because both
must survive individual world updates and still stop after a guarded failure.
The host pumps MCP outside the world's task scope; nesting the debugger there
can deadlock. Parked operations permit diagnostics, while tools that touch the
world wait for an operation boundary. Listener and connection owners live in
exact lexical scopes so cancellation closes them, including on exceptional exit.

Nominal presentation duration belongs to the world. A process-global value
lets one game change another game's sequence waits, and a measured frame delta
makes an authored duration depend on whichever frame happened to schedule it.
World configuration controls future conversions; existing tick deadlines stay
fixed. Physics history stores the creation pose before the first solver result,
then snapshots before later fixed steps, keeping rendering between two real
simulation poses without changing either.

## Platform services this tree does not carry

Three services the SDL implementation shipped are settled differently here, and
the reasoning is here because the absence is what a reader will notice.

`tecs.io.filters` is dropped rather than ported. Its deflate, inflate, hex and
iconv transforms had one named consumer, HTTP response compression, and
`nupp.io.http` decompresses natively; every format Tecs owns is uncompressed,
and what those formats do need is already `nupp.data`: base64, CRC-32, SHA-256,
FNV-1a and UTF-8 validation. The two alternatives lose on cost. A Rust service
would be a native library with an ABI, a packaging entry and a per-platform
build for a facility nothing calls. A Nupp implementation would put a DEFLATE
codec in a game engine's repository, maintained here, competing with the one
every language runtime already ships. A general facility Nupp supplies does not
get a Tecs copy, and a general facility Nupp lacks is a request to Nupp.

`tecs.watch` polls `nupp.io.files.info` rather than binding a platform
change-notification service such as `notify`. A notification says a write
happened, not that the writer finished, so the settle policy has to stat the
file anyway; the watched set is what a game loaded, and one stat measures at
1.0 microseconds, so a hundred paths at two polls a second costs 0.02 percent
of one core; and a notification arrives on a thread the virtual machine never
created, so it would cross the same drain-a-buffer seam the gamepad and audio
services cross for an answer that still needs the stat.

`tecs.workers` has no counterpart. `nupp.workers` supplies the isolated states,
the channels, the request and reply correlation and the cooperative wait that
module existed to provide, and no engine subsystem is left that needs one:
whole-file I/O already settles on `nupp.io.files`' own worker lane, and image
decoding belongs to the Rust host. Worker support is also a property of the
build rather than of the engine, since Nupp runs workers only in a binary
target with the compiler-owned stub, which neither the module target nor a game
component is. A game that needs isolated parallel work reaches `nupp.workers`
directly once its target can carry one.

## Native callbacks stay in Rust

A managed function reached through a cast cannot be entered from a compiled
trace, and cannot be entered from a thread the virtual machine never created.
Both are hazards of the callee, and the second is exactly what a device
callback is.

So every native service here is pull-only. `tecs-audio` takes a preallocated
command buffer Nupp flushes once per update and returns observations through a
drain call on the frame thread, so the `cpal` callback thread can never enter
Nupp. Its capture ring is written under `try_lock` and drops a block rather
than blocking a realtime thread. `tecs-gamepad` runs a `CFRunLoop` thread on
macOS and nothing in it takes a function pointer. The physics service is one
call per fixed step, with the managed side owning every buffer Rust borrows for
exactly that call. There is no function pointer anywhere in the three bindings.

The audio mixer is the tree's own rather than a crate. `kira` has no arbitrary
left/right gain pair, only an equal-power panning law, so `setStereo` cannot be
expressed, and its gain is in decibels rather than linear amplitude. `rodio`'s
looped decoder exposes no public methods, so looping cannot be cleared
mid-playback, and its seek blocks the caller. Both own their own device and
decode graph, so adapting either meant writing custom sources anyway and taking
the dependency. What remained was roughly 450 lines: resampling, a gain
envelope, a speaker pair, and a loop wrap.

The capture buffer is bounded rather than growing without limit as the SDL
stream did. It holds one second by default, drops the oldest, and reports the
loss through `Microphone.overruns`. An unbounded allocation driven by a
realtime callback was not worth carrying across.

## Device vocabularies follow the library that reports them

Key names, mouse button names and gamepad button and axis names came from SDL
and now come from `winit` and `gilrs`, so `x1` is `back`, `A` is `KeyA` and
`Left` is `ArrowLeft`. A binding saved by an SDL build does not survive that,
and no migration is provided: the alternative is a translation table that
exists only to preserve the vocabulary of a library the engine no longer links,
maintained forever against two upstreams. The numeric codes never moved, so
what changed is the spelling.

Every other externally typed string does move unchanged. Snapshot handler keys,
component and event names, logger names, system names, MCP tool names, and pass
and target names are reached by save files, shell filters and JSON payloads
this tree cannot see. `tests/tecs/compatibilitytest.nupp` pins the whole set
against literals, so a rename fails there rather than changing what a save file
means.

## Build

Cargo and `xtask` own the build, tests, documentation and packaging. A checkout
needs the Rust toolchain `rust-toolchain.toml` pins and a
[Nupp compiler](https://github.com/nupp-lang/nupp); `cargo xtask deps` installs
the two formatters and reports where the compiler resolved.

```bash
cargo xtask check              # Type-check every Nupp source, strictly
cargo xtask test               # Build native services; require every test to pass
cargo xtask run flatcolor      # Open a window and render the example
cargo xtask run lighting -- --frames 120
cargo xtask bench shapes       # Run a benchmark from bench/nupp
cargo xtask bench acceptance   # Three repetitions of fixed CPU workloads
cargo xtask format             # Format every supported source language
cargo xtask docs-check         # Validate the documentation site
cargo xtask verify             # Checks, tests, docs, Rust and headless smokes
cargo xtask package --preset macos-arm64
cargo xtask check-package
```

`cargo xtask presets` lists the release matrix: macOS arm64, Linux x64 and
Windows x64, each with a development preset and a release preset. Windows is
experimental until its Nupp, host and relocated-package gates execute.

### Packaging

A release records its loader-relative run path when it links, rather than being
relocated after. The alternative was to link against the staged Nupp SDK as a
checkout does and then rewrite the result, and it lost on its tools:
`install_name_tool` ships with the Xcode command-line tools that a macOS build
already needs, but the Linux equivalent is `patchelf`, which is a dependency
this tree does not otherwise have and would have to install on every builder.
Passing the packager's run path to the host's build script costs one
environment variable and no tool at all.

One post-link edit survives on macOS, and only there. Cargo gives a `cdylib`
the absolute path it wrote it to as its install name, so a copied service
library still names the Cargo target directory it came from. The obvious fix,
a per-crate `-install_name` link argument, loses because Cargo applies
`RUSTFLAGS` to a whole invocation: three different install names would mean
three builds that each invalidate the last one's cache. Rewriting three
finished files is cheaper than rebuilding the graph three times.

Release licensing is generated rather than curated. The host's resolved graph
is around 150 Cargo packages, and roughly half are named nowhere in
`THIRD_PARTY_NOTICES.md`. Instead of hand-writing entries for them, a package
installs `cargo-licenses.txt` beside `cargo-dependencies.txt`, carrying the
SPDX expression Cargo metadata records for every package in the inventory, and
`check-package` refuses an install where an entry has no answer. Curated prose
says why a dependency is there; this says what it is licensed under, which is
the part that must be complete.

A package ships a prebuilt `shaders.tecspack` and no material directory, so a
run that loses the pack cannot fall back, and packaging holds the packed
material names to the builtin list: a mismatch there would draw the wrong
material silently, because a frame packet selects by id.

Packaging is native only. The Nupp toolchain stages an embedding library for
the machine it runs on, so there is nothing to cross-link a Windows release
against on a Mac, and each platform builds its own.

## Documentation

The guides and the generated API reference live in [`docs/`](docs/). Serve them
locally with `cargo xtask docs-dev`. API contracts live on their declarations
under [`src/tecs/`](src/tecs/), and the reference is rendered from those, so a
signature has no second copy to drift from.

The source layout and project conventions are documented in
[`AGENTS.md`](AGENTS.md). Design notes live in the adjacent `../tecs-plans`
repository.

## Requirements

Rust and Cargo, and a Nupp compiler. `rust-toolchain.toml` selects the Rust
version. Linux additionally needs the development packages `winit`, `wgpu`,
`cpal` and `gilrs` link against: `libasound2-dev`, `libudev-dev`,
`libwayland-dev`, `libxkbcommon-dev`, `libx11-dev`, `libxcursor-dev`,
`libxi-dev` and `libxrandr-dev`.

A Linux release carries the Nupp and Tecs runtime libraries. The distribution
supplies ALSA (`libasound.so.2`) and udev (`libudev.so.1`), plus the C/C++ system
runtime and the window-system/graphics-driver libraries for windowed execution.
Compiler and shader-compiler tools are not needed to run a release.
The Linux host uses a relative `DT_RPATH` so service loads originating in the
shared Nupp runtime also find the packaged `lib/` directory.

See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for dependency notices.
