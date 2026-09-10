# tecs

Tecs is a typed entity component system and 2D game engine, written in Nupp
against Rust services. Entities are the interface: anything that updates or
renders belongs to a world.

A game is a component. It exports a session constructor, and the Rust host
selects that export by name and drives it one frame at a time:

```nupp
module mygame

local function install(exclusive app: tecs.application.Application): nil
    app.world:addSystem({
        name = "game.Tick",
        phase = tecs.ecs.phases.Update,
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
): tecs.host.Session
    return tecs.host.createWithPlugin(install, title or "My game", width, height, debug, maxFrames)
end
```

`tecs` is available as a typed namespace whenever Tecs is in the Nupp project.
Use `tecs.ecs.newWorld()`, `tecs.gfx.Tint(...)`, and nested modules directly;
no `require` or initialization call is needed. Nupp resolves these paths at
compile time and loads each referenced module once when the caller loads.

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

- [Tiled TMX maps and TSX tilesets](docs/tiled/index.md), animated tile and image
  layers, object factories, runtime tile edits and authored collision outlines.
- [Retained UI backed by Taffy](docs/ui/index.md), intrinsic text and images,
  scrolling, clipping, pointer capture, keyboard focus and controller activation.

The 2D shape materials include rectangles, circles, rings, rounded rectangles,
triangles and stars. 3D rendering, custom post-processing and multi-camera
rendering are not available in the current engine.

Run `nupp task ex-tiled` for a map with animation and collision, or `nupp task ex-ui`
for the Compose, Flex, Overlay and Scroll showcase over the animated gradient
field. `nupp task ex-uistandalone --width 960 --height 640` runs the centered panel.

## Ownership boundaries

| Concern                                                | Owner                               |
| ------------------------------------------------------ | ----------------------------------- |
| Game code, ECS semantics, extraction, engine policy    | Nupp, in `src/tecs`                 |
| Window and event loop                                  | Rust, with `winit`                  |
| GPU resources, pipelines, submission, presentation     | Rust, with `wgpu`                   |
| Audio, gamepads, physics                               | Rust services behind Tecs contracts |
| Tasks, suspension, files, bytes, JSON, networking, log | The Nupp standard runtime           |

Three rules follow from that table and are worth stating separately.

**Where Nupp provides a facility, Tecs uses it directly and wraps nothing.** A
wrapper costs a file, a name and a second place to look, and it earns that back
only by adding behavior Nupp does not have. The logging module is the worked
example: it existed to add a per-name threshold, seven modules then reached past
it to `nupp.log` anyway, and the threshold it existed for stopped reaching them.
It is gone, and every module names its logger to `nupp.log.named`.

**`exclusive` is a call-scoped borrow, so a function that keeps its receiver
does not take one.** Almost every engine function declares `exclusive world:
World` or `exclusive self`, which is what stops a caller holding a second view
across a mutation. A few build a record that outlives the call and holds the
receiver inside it: the world's bundles, `Input`'s gamepads, the asset loader's
entries, a model's instances, the frame extractors, the frame pump's parked
task and the debug server's suspension handler. A borrow may not be stored, so
those receivers are plain, and the record and the receiver are aliased and
collected together the way any two Lua tables are. The sequencer's action
context is the case where no mode worked: an action needs the world exclusively
while its context is live, so the context holds no world at all and
`ActionContext.entity` takes the one its action already received.

**Maintained Rust crates own published formats and coarse CPU algorithms, and
no crate is called per entity or per draw during a frame.** `symphonia`
decodes audio, `cpal` owns the device, `gilrs` owns gamepad enumeration and its
mapping database, and Rapier owns rigid-body storage and stepping. What crosses
into game code is a flat typed value, not a library handle.

## Component declarations

A component is a value declaration with an ECS derive, not a parallel schema.
Nupp supplies construction, reflection and derived methods; Tecs assigns the
component identity and specializes its storage. Structs use native columns and
records use managed columns without separate public factory families. Query
column types are selected at compile time, so this common declaration surface
adds no per-row dispatch.

Module-qualified declaration names remove registration boilerplate. An explicit
annotation name pins identities that must survive a module or declaration rename.
Factories remain useful for custom policies and for distinct component identities
that share one value layout, not for choosing its physical representation.

## System ordering

Phase boundaries carry the engine's frame dependencies. Named `before` and
`after` constraints express the dependencies left inside one phase without
making plugin installation order the only way to order systems. Missing or
cross-phase names add no edge, so an optional plugin stays optional. The
schedule uses registration order to break ties, rejects cycles before dispatch,
and caches its phase-local arrays until registration changes.

One external world dispatch captures one schedule. Rebuilding it in the middle
of a phase could repeat or skip systems, so additions wait for the next dispatch;
removals mark their existing entries inactive immediately. A disabled system
retains its dependency edges. Ordering alone is not a publication barrier.

Timer predicates consume simulation deltas, not wall clocks, and short-circuit
composition controls whether a timer advances. Jitter takes a Nupp random
generator explicitly: restoring Tecs-specific scheduling does not restore a
second random API or silently make runtime closures part of entity snapshots.

World-managed randomness adds ownership and persistence to Nupp's generator,
not another generator implementation. A stream's seed is derived from the world
seed and its name, so adding a consumer cannot move another consumer's sequence.
Reseeding and snapshot restore mutate existing generators in place because
systems capture them during setup. The persisted `tecs.random` key and seed
derivation remain compatible with the old architecture. Restore recognizes that
key even before a world first requests a stream, removing the old initialization
ordering trap. Worlds that never use randomness allocate no stream registry and
write no random snapshot entry.

## Structural mutation

Component requirements are addition rules, not continuously enforced invariants.
They expand only when a component enters the staged signature, preserving
existing values and intentional removals. Definitions request per-entity
defaults; constructed instances explicitly request shared values. Every mutation
path uses the same closure, so a bulk operation or a relationship cannot silently
bypass the dependencies a component declares.

Tecs uses one deferred structural model. Systems in a phase stage spawns,
despawns, additions, removals, and bundle spawns together; the scheduler
publishes them at the phase boundary. A system can declare `commitBefore` or
`commitAfter` when it needs an extra boundary. Explicit `world:commit()` settles
staged work synchronously for setup, tests and debug tooling. A query iterator
owns no mutation scope, so callers leave the loop before explicitly committing.

`world:enqueueCommit()` is the conditional boundary: a system requests it only
when its work needs to be visible to the next system. The dispatcher coalesces
requests until the body returns, even when the body suspends, preserving the
current iterator's view. Predicate requests follow the same rule even when the
predicate skips the body. Outside a system the request is synchronous, and
requests during publication join its drain instead of recursing. A failed
system cancels its request without publishing during error unwinding.

Value access stays direct. `getMut` marks and returns a live component because
changing its fields cannot move the entity between archetypes. Replacing a
component through `set` is staged, including when the component already exists.
Relationship targets must be changed through `set`, because the reverse index
and, for dense relationships, the archetype signature depend on that target.

### Bulk operations and compaction

Bulk mutation uses the same staged transaction as scalar mutation. A batch
resolves its shared shape once, captures query members at the call, and leaves
publication to the barrier. Deferred column writers introduce ordered transaction
segments so a later scalar write cannot be overwritten by an earlier initializer.
Relationship edits retain the ordinary reverse-index and cascade paths.

Maintenance is explicit because rebuilding row tables invalidates captured
column views. Archetype identity is separate from the dense registry that
enumerates it: pruning a dead relationship target must not renumber survivors.
The Nupp stores expose no native capacity, so compaction reports stores rebuilt
after occupancy shrinks rather than inventing a byte count.

### Query membership and relationship storage

State exclusion belongs to query construction: all game queries exclude
`Disabled`, and logic queries also exclude `Paused`, unless explicitly included.
Native resource reconciliation and retained UI layout need an internal unfiltered
query because they must clean up disabled entities and restore hidden ones.
Putting that exception at those ownership boundaries keeps ordinary simulation
queries from accidentally processing disabled entities.

Query observers follow set membership. Moving between two matching archetypes
does not report removal and addition, because the entity never left the query.
Departing callbacks read the old row; entering callbacks read the published row.
Callbacks may stage another mutation, which the active commit drains afterwards.
Only queries with callbacks join the notification list, so ordinary queries add
no observer dispatch work to each entity move.

Dense relationships place each target in the archetype signature and keep edge
payloads in target-specific columns. This lets a query select a target without
scanning entity values. Sparse relationships keep entity-indexed edge sets and
put only the relationship's presence in the signature. Frequent retargeting then
does not fragment archetypes. `ChildOf` and the physics ownership relationships
use sparse storage for that reason. Both modes support cardinality, traversal,
reverse indexes and snapshots. Indexed dense edges clean up a deleted target;
non-cascading sparse edges retain their identifiers until explicitly removed,
preserving the original relationship contract.

Typed table data relationships require explicit snapshot hooks. The constructor alone
cannot reconstruct a record from saved fields when it takes additional arguments
or establishes invariants. Leaving that decision with its declaration preserves
the edge's record identity and methods after load.

### Native columns and publication

Native component layout belongs to Nupp's struct declaration. Recreating a C
schema and installing a second metatype would duplicate that authority and could
steal another component's instance identity. Tecs instead binds the declaration
to its component, reads field metadata once, and keeps contiguous columns with
the original one-based rows, geometric growth and bulk memory copies. Two
components can use the same struct layout without sharing component identity.

The built-in numeric components use that path too, including shape material,
transforms, tint, camera, lights, animation, sound, physics and numeric UI state.
Their Debug and Serde derives belong to Nupp, not a Tecs-generated metatype.
Managed strings and collections stay in record components. Renderer caches own
reusable native copies instead of retaining one allocated row reference per
entity; this also keeps interpolation separate from simulation memory.

Publication copies a moving native row before swap-removing its source. Managed
records tolerate the opposite order because a reference keeps the record, but a
native row reference names a location whose bytes swap removal overwrites. Dense
relationship wildcard columns likewise alias their first target column instead
of keeping a second payload copy. Growth, compaction and swap removal repair
those aliases while no query loop is running.

Automatic native snapshot codecs cover the supported inline fields. Explicit
codec pairs disable raw serialization in both directions; a fast path that
bypasses an image registry or runtime-state reconstruction is incorrect. Native
storage exposes buffer-direct column copies and retained custom backing for the
snapshot and renderer boundaries. These are storage capabilities, not a claim
that binary world snapshot framing has already been restored.

`nupp task bench storage` compares the native ECS query loop with the original
direct FFI-array loop and managed records, and compares the two buffer-direct
copy paths. It also reports allocation over warmed full-query loops. It is not
a substitute for the shapes, physics and snapshot benchmarks.

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

## Retained rendering

Rendering keeps the original `SpriteExtractor` / `SpriteBackend` design:
packed archetype runs, persistent instance buffers, monotonic write counters
and bounded dirty byte ranges. Frame-local dirty bits alone cannot serve the
host, which extracts after `world:update` has cleared them. Unchanged runs
therefore compare write counters and preserve their packed bytes; camera-only
movement changes the view without repacking world-space geometry.

The managed Nupp/Rust boundary carries only changed ranges once both sides
agree on the resident generation. A new receiver requests a complete scene,
and layout changes replace it. This preserves validation at the host boundary
without rescanning or copying every resident instance each frame. The GPU
still culls and draws the current view. See the [rendering benchmark](docs/gfx/benchmarks.md)
for measured frame times and workload limits.

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
and what those formats do need the Nupp standard library already has: base64,
CRC-32, SHA-256, FNV-1a and UTF-8 validation. The two alternatives lose on
cost. A Rust service would be a native library with an ABI, a packaging entry
and a per-platform build for a facility nothing calls. A Nupp implementation
would put a DEFLATE codec in a game engine's repository, maintained here,
competing with the one every language runtime already ships. A general facility
Nupp supplies does not get a Tecs copy, and a general facility Nupp lacks is a
request to Nupp.

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

Nupp owns the development workflow through `nupp.lua`: build targets,
project tasks and the test command share one entry point. Cargo compiles the
Rust host and services underneath those tasks; the Rust packaging helper owns
binary inspection, relocation and native release assembly.

A checkout needs the Rust toolchain `rust-toolchain.toml` pins and a current
[Nupp compiler](https://github.com/nupp-lang/nupp) on `PATH`.
`nupp task deps` installs the two formatters on macOS.

```bash
nupp check --strict           # Type-check every Nupp source, strictly
nupp test                     # Build native services; require every test to pass
nupp task ex-flatcolor           # Open a window and render the example
nupp task ex-lighting --frames 120
nupp task bench shapes        # Run a benchmark from bench/nupp
nupp task bench acceptance    # Three repetitions of fixed CPU workloads
nupp task format              # Format every supported source language
nupp task docs-check          # Validate the documentation site
nupp task verify              # Checks, tests, docs, Rust and headless smokes
nupp task package --preset macos-arm64
nupp task check-package
```

`nupp task presets` lists the release matrix: macOS arm64, Linux x64 and
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
the part that must be complete. MPL-2.0 remains accepted for Symphonia. A package
also carries version-specific covered-source URLs and checksums in
`license-sources.json`; packaging compares covered sources with the locked crate
archives before recording them as unmodified. Patched covered sources need an
actual source package and modification record before they can ship.

A package ships a prebuilt `shaders.tecspack` and no material directory, so a
run that loses the pack cannot fall back, and packaging holds the packed
material names to the builtin list: a mismatch there would draw the wrong
material silently, because a frame packet selects by id.

Packaging is native only. The Nupp toolchain stages an embedding library for
the machine it runs on, so there is nothing to cross-link a Windows release
against on a Mac, and each platform builds its own.

## Documentation

The guides and the generated API reference live in [`docs/`](docs/). Serve them
locally with `nupp task docs-dev`. API contracts live on their declarations
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

## Static tile storage

Static Tiled tiles use 16×16 native TileChunk grids, preserving the original
engine's distinction between chunked scenery and individually animated sprites.
One entity per static tile imposed ECS allocation and update costs for scenery
that changes only on edits. Chunks retain compact tile-ID grids on the GPU;
compute culls chunks and shaders place their tiles through indirect draws.
Edits upload changed chunks, and unchanged frames upload no instance or tile data.
Tileset normal, emission and ORM companion maps are loaded automatically.
See [TileChunks](docs/tiled/tile-chunks.md) and [Screenshots](docs/gfx/screenshots.md).
