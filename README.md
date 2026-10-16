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
  and device enumeration; General MIDI from a SoundFont; emulated Yamaha FM
  chips, from the OPL2 and OPL3 to the YM2612 and the OPL4; MIDI, VGM, VGZ and
  DRO music played on them; physics over Rapier; sequencing with tweening;
  asset orchestration; file watching; and an MCP debug server.

- [Tiled TMX maps and TSX tilesets](docs/tiled/index.md), animated tile and image
  layers, object factories, runtime tile edits and authored collision outlines.
- [Retained UI backed by Taffy](docs/ui/index.md), intrinsic text and images,
  scrolling, clipping, pointer capture, keyboard focus and controller activation.
- Audio clips decoded from a file or from the bytes of a whole encoded file held
  in memory, for a game that unpacks its own archives.

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

`tecs.files` is the second worked example, and it went the same way once Nupp
grew application storage roots. It used to resolve the writable roots itself:
`APPDATA` and `LOCALAPPDATA` on Windows, `~/Library` on Apple platforms, the XDG
variables elsewhere, a sanitized publisher and game name under each, and the
executable's directory guessed from `arg[0]`. `nupp.io.files` now answers all of
it from one application identity, and it answers it better: configuration, data
and cache are three separate directories rather than two, a joined path refuses
a component that would escape the root, and the identity is encoded reversibly
rather than mapped onto underscores. What is left here is the asset root, which
Nupp cannot know, because where a build installed its content is a property of
the product. The module went from 431 lines to 164.

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

`nupp.host.pump` is what makes that work across the embedding boundary. The
call that starts or polls a host operation never yields: a wait parks the
operation's coroutine in the pump, and a later polling turn resumes it when
readiness is reported. Resuming during that notification releases the one-shot
source before MCP or another driver polls it again. Deferring that resumption
left completed network waits registered and fired them twice. So a parked
update is one the host observes as `parked` and asks again, rather than a yield
escaping into Rust. Tecs carried that scheduler privately until Nupp grew the
same one, and now uses Nupp's.

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

Synthetic input takes the same boundary. The debug server's `send_event` used
to fold its event into input state the moment the tool ran, which is between
frames: the next frame's `beginFrame` then cleared the edges, so an injected
key was down but never pressed, and a test harness had to queue events inside
the game instead. The application now queues them and delivers them after the
host's batch on the next frame that runs. Pausing is the application's rather
than the host's for the same reason: a held iteration keeps its events for the
frame that runs and a stepped frame takes a fixed delta, so a paused game
advances by exactly the frames granted, on any host, while the host keeps
serving screenshots of the held world.

A held turn is reported to the host as its own `held` state rather than as
`continue`. The offscreen host used to draw every turn, held or not, with no
pacing, so a paused test host spun a core and redrew an unchanged frame as fast
as the GPU would take it; several side by side then slowed each other down. It
now draws a held turn only when a screenshot, an image command or a model upload
is waiting, and otherwise sleeps a quarter of a millisecond, which keeps a
tool call's round trip faster than the old loop's. Comparing the frame counter in
`tecs.host` was chosen over a new application field because every frame that
runs advances it and a held turn is exactly one that does not.

Skipping held turns was not enough on its own. Nothing else held the offscreen
loop back either, so the frames that do run were submitted as fast as they were
extracted, and a GPU shared with other hosts accumulated them along with the
staging memory each holds: hosts grew to about 1 GB and side by side they still
slowed each other down. The loop now keeps at most two frames in flight, waiting
for the frame before last after each submit. One frame in flight bounds memory
as well but serializes extraction behind the GPU, which cost a lone host about
40 percent; two keeps that overlap.

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

### The windowed frame loop on macOS

The window host used to poll: `ControlFlow::Poll`, with the whole frame in
`about_to_wait`. Under FIFO presentation that frame spends most of its time in
`get_current_texture`, which on Metal is `nextDrawable` waiting for the next
vsync, on the main thread. Measured on a game, the main thread was blocked
there for 90 percent of the run, and it showed up somewhere nobody looks: with
Magnet running, every click and the start of every title-bar drag waited about
half a second, less on a 120 Hz display, while the host's own logs showed
frames every 16.7 ms and input delivered within a millisecond.

The delay sits in front of the process. Window managers such as Magnet and
BetterTouchTool (its snap areas) install an event tap that filters mouse-down
events, and before letting a click through they ask the clicked application
about its window over Accessibility. That request is a message on the main run
loop, which a polled loop serves one per turn, and every turn is a frame
blocked until vsync, so a few dozen requests cost a few dozen frames. The
press and release then reach the window together, a few milliseconds apart.
winit#1737 is the same report from other engines and apps, and Godot ships a
workaround that detects Magnet by its bundle identifier.

The host now paces the windowed frame on macOS instead (`pacing` in the
winit host). The event loop sleeps in `WaitUntil` until a frame is due, one
monitor refresh after the last; the frame is requested with `request_redraw`
and runs in `RedrawRequested`; and a worker thread acquires each drawable as
soon as the previous frame is presented, so a due frame whose drawable is not
in hand yet is put off and checked again every millisecond rather than waited
for. Between frames the run loop is asleep in the kernel, where an
Accessibility request wakes it at once. Pacing alone was not enough: a timer
deadline does not stay in phase with vsync, so with every drawable queued the
acquire still blocked for the phase difference, up to a whole frame, and clicks
were still held for up to a hundred milliseconds. With the frame gated on a
free drawable, measured with a diagnostic build that counted presented
drawables, the share of the run spent blocked fell to nothing and the oldest
click on arrival to about 16 ms, the tap's own cost.

The alternatives that lost: a `CADisplayLink` driving the frame paced well but
still blocked in acquire without the gate, and with it was no better than the
timer while adding a macOS 14 dependency; one frame of latency instead of two
halved the frame rate, because a single queued drawable is not released before
the next frame wants it; and counting presented drawables needs a handler on
the `CAMetalDrawable`, which wgpu does not expose, so it meant patching
wgpu-hal. Acquiring on a worker uses only wgpu's public API (`Surface` and
`SurfaceTexture` are `Send` and `Sync`) and answers exactly the question the
gate asks. One consequence to know: wgpu-hal's Metal acquire reads the hosting
`NSWindow`'s `occlusionState` to skip occluded windows, and that read now
happens on the worker. A reconfigure first waits for the acquisition in flight
and drops what it acquired, since a surface is not configured with a texture
outstanding. A frame put off for 100 ms runs anyway and waits for its drawable
as before, so a surface that stops answering cannot stop the game. Other
platforms keep the polled loop: nothing there has shown the failure, and the
render benchmark's interactive view keeps it too, since it measures uncapped
presentation.

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

A clip from memory is the bytes of a whole encoded file, container and all,
rather than raw samples. `loadBytes` hands them to the same `symphonia` probe a
file goes through, so every format `load` reads from disk reads from memory too,
and there is one decode path rather than two. The alternative was a
`loadSamples` taking floats with a rate and a channel count, and it lost on
three counts: it needs a sample-format vocabulary (width, signedness, endianness,
interleaving) that a WAV header already is, it copies a Nupp table across the
seam one float at a time where a string crosses as one pointer and a length,
and a game format that is not raw PCM would still need the decoders anyway. A
game holding raw samples writes the 44-byte header itself, which is the cost
this pushes onto it. The clip is always resident, because streaming would mean
Rust keeping the bytes alive for every voice; the bytes are copied once for the
decode and dropped. Its name shares the clip namespace with paths, because a
`Sound` row and a snapshot carry a clip as a string, and so `reload` reports
false for it rather than having a file to re-read.

The capture buffer is bounded rather than growing without limit as the SDL
stream did. It holds one second by default, drops the oldest, and reports the
loss through `Microphone.overruns`. An unbounded allocation driven by a
realtime callback was not worth carrying across.

## General MIDI is synthesized in-process

`tecs.audio.synth` renders General MIDI from a SoundFont with `rustysynth`
(MIT, pure Rust, no dependencies) as one voice of the mixer, rather than
sending MIDI to whatever synthesizer the operating system offers. On a desktop
the system synthesizer is software too: Apple's DLS synth on macOS, the
Microsoft GS Wavetable synth on Windows, and on Linux nothing at all unless the
player installed and started FluidSynth or TiMidity. Sending to it buys no
quality and gives up three things a game needs. The music sounds the same on
every machine, because the SoundFont ships with the game instead of being
whatever bank the platform has. It goes through the mixer, so group gain, mute,
pause and master gain apply to it like any other sound, and a system synth
offers none of them. And it is deterministic: events carry a time on the
synthesizer's own clock, the callback splits its render at those times, and the
same schedule renders the same samples on every run, which a test can pin and
a recording can reproduce. An external synth answers on its own clock and its
own latency, and the mix of the two cannot be captured offline.

Timing is exact to `rustysynth`'s internal block, which is where it applies
MIDI and runs its envelopes. Tecs sets that block to eight frames, the smallest
the library takes: every event lands on the first eight-frame boundary at or
after its time, 0.17 milliseconds at worst at 48 kHz. Measured on FluidR3 GM
with 48 notes held and the effects on, that costs 3.3 percent of one core
against 1.9 at the library's default of 64 frames.

Events cross to the output callback through a bounded single-producer,
single-consumer ring, 4096 events, with as many again held in a preallocated
schedule for events sent ahead of their time. The callback never waits and
never allocates; a send that finds no room returns false and the event is
dropped, because the alternatives are blocking the frame thread or growing a
buffer the callback reads. A game streaming a song with a lookahead of a frame
or two never comes near it.

A hardware MIDI output is the extension this leaves room for and does not
build. The seam is `tecs.platform.audiobackend.SynthPort`: `send` with a time,
`notesOff`, `reset` and a clock. A second implementation over `midir`
(CoreMIDI, WinMM, ALSA) would put a sender thread in Rust that holds the
schedule and writes each message when its time comes, with `now` on the host's
monotonic clock instead of rendered frames, chosen when the synth is made.
Nothing above the port changes. It is deferred because nothing needs it yet,
and what it costs is the determinism above: a hardware synth cannot be rendered
offline.

## FM synthesis is a register-level chip, emulated by a Rust crate

`tecs.audio.fm` is a Yamaha OPL2 (YM3812) or OPL3 (YMF262) a game drives by
writing its registers, played as one voice of the mixer on the same scheduler
as the General MIDI synth. It is for the music and effects of the DOS era,
which were written as streams of register writes to an AdLib or a Sound
Blaster, and a port of such a game wants to replay what its driver wrote, not
an approximation of it.

The interface is registers only: `write`, `writes` for a tick's batch, `reset`
and a clock. A note-and-instrument layer was the alternative, and it lost
because it is the part that differs between games. Every driver had its own
instrument format, its own channel allocation and its own idea of a note, and
an engine layer would have had to pick one or grow into a superset of all of
them. The chip is the one contract they all shared. A game that wants notes
writes a driver for its own format above this, in Nupp, and gets exactly the
sound that format made. Status and timer reads are left out for the same
reason they are left out of the scheduler: a driver that paced itself on the
chip's timers paces itself on `now` instead, and a read would need an answer
from the audio thread inside the call.

Writes land on the first chip sample at or after their time, a grid of one
rather than the synth's eight, because a register write takes effect on the
next sample the chip computes and a driver's timing is part of its sound: a
key-off and key-on a sample apart is a retrigger, and moving it eight samples
changes the attack. The scheduler names its grid per target to allow that,
eight frames for the synth and one for the chip, and the ring, the schedule
and the source are otherwise the synth's, so the queue bound and the clock
behave the same way. Writes due on one sample all apply before that sample is
generated, in sending order, so a key-off and a key-on there count as no
change: a driver that re-strikes a note spaces the two writes one sample apart,
which is what the hardware's write timing did anyway. `writes` is all or
nothing, because a tick applied in part plays a note with half its instrument.

A reset carries a time like a write. Writes sent before it and due before it
still apply; those due at or after it are discarded, so nothing scheduled
earlier plays over the silence it makes, and writes sent after it apply as
usual, at its own sample included. The synth's reset, which lands at its next
block, keeps its old meaning; the chip's needed a time because a driver
restarting a song schedules the restart rather than taking it whenever the
next buffer begins.

The chip renders at its own rate and the mixer voice resamples it as it would
a clip, so the clock counts chip samples and the output rate does not leak
into a driver's timing. The rate is the input clock over 72 on the OPL2,
3.579545 MHz, and over 288 on the OPL3, four times that: 49 715.9 Hz, which
the emulator truncates to 49715. Rounding it to 49716 instead, as an earlier
draft did, would be closer by under twenty parts per million, which is a
thirtieth of a cent of pitch and under a tenth of a second an hour of tempo,
below anything heard; the clock simply has to agree with the emulator, and a test
holds `rate` to what the emulator reports for both chips.

The emulator is ymfm-oxide (<https://github.com/albanmgicquel/ymfm-oxide>), a
pure-Rust, `no_std`, dependency-free port of ymfm, Aaron Giles's BSD-3-Clause
emulator of the Yamaha FM family, used for its YM3812 and YMF262: OPL3
4-operator pairs, all eight waveforms, the NEW bit, stereo and rhythm mode.
Linking ymfm's C++ was the alternative, and it lost to the build: every other
native service here is Cargo only, and a C++ toolchain on every platform,
Windows included, for one module was not a cost worth carrying. ymfm was the
source because it is permissively licensed and written to be read, which is
what makes a port checkable. The candidates under the LGPL or the GPL,
Nuked-OPL3 and DOSBox's among them, are excluded by the licence rule in
`THIRD_PARTY_NOTICES.md`, and so is anything developed from them.

The port lives in its own crate rather than in this tree, and it was first
written here. Kept here, Tecs carried a few thousand lines of BSD-3-Clause
source with its own notices, its golden renders and a C++ oracle, none of it
about the engine; as a crate it is one dependency with one notice, its check
lives with its code, and the other chips ymfm models come with it for whoever
wants them. The crate holds itself to ymfm sample for sample with golden
renders of synthetic register logs, made by ymfm through an oracle program,
and a randomized differential test against it. It is a git dependency pinned
to a full commit, and `Cargo.lock` records that commit, so a build cannot pick
up a different emulator without a change here. `tecs-audio` drives it through
the chips' own ports: a register below 0x100 through the address port at
offset 0 and the data port at 1, one from 0x100 up through the OPL3's
second-bank address port at 2 and the data port at 3, which is how the chip
itself folds a second-bank write back to the first until the NEW bit is set.
The OPL3's left and right are its outputs A and B; the OPL2 is mono and plays
its one output on both sides.

## Every chip the emulator models is one voice, named by its part number

`tecs.audio.fm` began as the OPL2 and OPL3 and now makes any of the 24 chips
ymfm-oxide models, because the register logs a game ships or a player loads
are not all DOS ones: a Mega Drive log is a YM2612, an arcade one a YM2151 or
a YM2610, an MSX one a YM2413 beside a Y8950. The alternative was a module per
family, and it lost because the families differ only in data a table holds:
where the registers sit among the ports, what the input clock usually was, how
the outputs reach two speakers and what memory the chip reads. The contract a
game writes against, registers, a clock and `at`, is the same for all of them,
so the chip is a name and a clock and nothing else changes. Names are Yamaha
part numbers in lower case rather than family names, because a family name
does not say which chip: an OPN is any of eight. `"opl2"` and `"opl3"` stay as
aliases, so the first callers never notice.

The register convenience stays the primary interface, since every log and every
driver's source names registers, and it maps a register's high byte to the
bank's address and data ports: one bank at offsets 0 and 1, the second at 2 and
3, the OPL4's PCM registers as a third at 4 and 5, and the YM2149's data port
at 2. The OPQ has no address port and is written by register. Port writes are
offered beside it for the driver that wrote the bus itself, and a test holds the
two to the same render.

The chip renders at the emulator's own rate for its clock, which the voice
resamples. Two consequences needed decisions. The OPN chips with an SSG default
in ymfm to their highest fidelity, a megahertz for the YM2203, and run here at
their lowest, which keeps every FM sample and averages the SSG's; and where the
emulator still renders faster than 64 kHz, as the YM2203, the YM2608 and the
YMF288 do, consecutive samples are averaged into one frame of the chip's clock.
That keeps the mixer's linear resampler away from ratios where it aliases, and
it puts a ceiling on `rate`, the unit of `at`. Outputs fold to stereo by a
fixed table: a mono chip on both sides, the OPL3's A and B, the OPL4's mixed
pair, the SSG at two thirds of its channels' sum, which is ymfm's own mix.
The SSG's square waves swing between zero and a positive level, which a real
board's output capacitor took out, so a chip with one has a 5 Hz high-pass
filter on its output; without it a song would start and end with a click and
carry an offset into the mix.

External memory is images a game hands over, whole: `setMemory` replaces the
ADPCM-A, ADPCM-B or PCM image from the next frame, and a reset keeps it. The
images belong to the audio thread's half of the chip. ymfm reaches memory
through the chip's interface, which the chip owns and not every chip lends
back, so the interface holds a pointer to images the target owns, read and
swapped only between samples on the one thread that renders; a lock around
them was the alternative and lost, being a lock on the audio thread taken on
every ADPCM fetch to protect nothing a second thread touches. An image crosses
on a bounded channel of its own, paired with an event in the write queue that
says when to take it, and the image it displaces goes back to the game thread
to be freed there. Timers, busy time and the IRQ line are not offered: a log is
already timed and a driver paces on `now`, and an answer from the emulator
inside a call would need the audio thread to reply. What that leaves out is
the OPN's CSM key-on and the ADPCM end-of-sample flags, which only a timer or a
status read can drive.

An idle chip at its usual clock costs between a fifth of a percent and one
percent of a core in a release build, measured over a second of rendering; the
YMF288 is the dearest and the YM2149 the cheapest.

## Music is two asset kinds and a player that owns its voices

`tecs.audio.music` plays songs on the synthesizer voices: Standard MIDI Files on
the General MIDI synth, and VGM, VGZ and DRO register logs on emulated FM chips.
Each format is a `tecs.assets.Kind`, `"music.midi"` and `"music.fm"`,
which are content kind names and so a compatibility surface, and a
`tecs.audio.music.Player` plays what one loaded.

The files are parsed in Nupp, on the loader's readiness pump, up to 65 536
commands a pass, so a large log loads across frames instead of stalling one.
A worker lane was the alternative and lost: it needs the `workers` host
feature and a sendable parser, and its result, tens of thousands of events,
would be copied back across the lane only to be read on the frame thread
anyway. Parsing in Rust lost for the same reason, with a structured payload to
carry over the C ABI besides. A log is kept as two integer arrays, a tick and
a packed chip, register and value a write, rather than a record per write,
because a long VGM holds hundreds of thousands of them. VGZ inflates through
`nupp.compression`, which is Nupp's and so is what Tecs uses: the host now
stages the `native-compression` feature beside `native-files` and
`native-net`, in the three places that list them. `flate2`, already in the
Cargo graph through `tecs-assets`, would have worked too, and is exactly the
wrapper around a Nupp facility the project does not keep.

A player owns its voices, a synth for a MIDI song and one chip for each chip a
log names, and the handle it plays, which it retains and watches for a reload.
The mixer's `update` advances every player made on it, because a game already
calls that every frame and keeps calling it while its world is paused; a
`Music` component was the alternative, and it lost because a song is a handle
and a set of voices, neither of which is data a snapshot could carry or a row
could own. The player schedules ahead on the voices' own clock, `lookahead`
seconds at a time, so timing follows the audio rather than the frame rate. When
a stall makes an event late, that event plays at once and the rest keep their
distance from it: the song slips by the stall instead of rushing what it
missed, and a stall over a rest changes nothing. A loop ends before the
events at its end, which belong to the next pass, and held notes are released
there; the song's own end takes everything, so its closing note offs are sent.
A song loops forever when it has a loop point and plays once when it has none.

Seeking resets the voices and rebuilds their state rather than replaying the
song up to the point: a MIDI song sends the programs, controllers and bends in
force there, and a log writes the last value of every register. The second is
exact for everything a register holds and approximate for what a chip holds
besides, envelopes in flight and the OPN's shared key-on register among them,
so a note held across the point comes back at its next key-on. System
exclusive messages are kept in a song but not sent, because the synth takes
short messages; the resets they carry are what a fresh synth already is.

A VGM file is a log of every chip in a machine, and a Mega Drive's has an
SN76489 beside its YM2612. Refusing such a file because one of its chips is
not a Yamaha one would make the YM2612 useless, so each chip Tecs cannot
emulate is skipped with a reason in `skipped`, and only a file left with
nothing is refused. The YM2612's DAC writes from a data bank, the `0x8n`
commands and the DAC streams, are turned into ordinary register writes at
their times when the file is read, so the player knows nothing of them, and a
format 2 MIDI file's patterns play one after another.

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
