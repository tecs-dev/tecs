# Plan

This engine started as a separate project because it replaced Love2D while the
ECS stayed renderer-agnostic. That boundary has stopped paying for itself. The
renderer's whole job is to read archetype columns, and the ECS's storage layout
is the thing that decides whether that is fast. Keeping them apart means neither
can know what the other needs.

So they become one project, named `tecs`, and the plan below is what follows
from that.

## 0. The merge

**Direction.** `tecs2d` merges into `tecs`. The ECS repository has the longer
history, the changelog, the docs site, the CLI, the examples, and the benches,
and it already has the name. Preserve both histories with a remote and
`--allow-unrelated-histories` rather than copying files in.

**Namespace.** One, `tecs.*`. `require("tecs2d")` goes away. The public surface
stays small, which was already decided:

```
 tecs.application(config)   the object the host drives
 tecs.components            the component set
 tecs.phases                the schedule, including render passes
 tecs.assets                handle-based content
 world:*                    spawn, query, getMut, phases, state stack
```

`gpu/`, `platform/`, and `ffi/` move under `internal/`. Nothing named `Device`,
`Frame`, `RenderPass`, `Buffer`, or `PassGraph` appears in the public surface.

**Headless still works.** GPU-backed storage is opt-in per component, so a world
with no GPU components needs no device. Tests, servers, and the debugger keep
working without a window. This is a rule, not an accident, and it needs a spec.

**The Love engine stays in-tree, out of the build,** under `legacy/`. It is both
the port source for roughly 55k lines and the performance baseline every
comparison is measured against. It gets deleted subsystem by subsystem as each
one lands. The recorded benches under `benches/love2d/results/` outlive it.

## 1. What the merge is actually for

Today the renderer walks archetype columns every frame and writes a packed
64-byte instance into mapped GPU staging. Measured cost is about 11 ns per
instance, and at 200k to 1M instances that walk is the single largest scaling
term in the frame.

The walk exists only because the ECS does not know its columns are destined for
a GPU. If a component column can be allocated inside a persistently mapped
transfer buffer, `getMut` marks a dirty byte range instead of a dirty flag, and
the frame copies only changed ranges. The per-entity walk disappears.

There is a real problem to solve first, and it is the reason this is a research
step rather than a task. The current instance is **derived** data: a 2x2 basis
computed from rotation and scale, a UV rect resolved from a sprite frame. It is
a projection of several components, not any one column. So there are two shapes:

```
 A  GPU gathers from columns    cull reads Transform, Tint, Sprite from
                                separate SSBOs and derives the instance
                                itself. Deletes the CPU walk entirely.
                                Needs an archetype descriptor table on the
                                GPU: (archetype, component) -> buffer offset.

 B  CPU keeps a packed instance  what exists now. One coherent 64-byte read
                                in the cull, but the walk stays.
```

A is the better architecture and the reason to merge at all: adding a component
to the render set becomes binding another SSBO rather than editing a packing
function, and derivation happens where it is free. Its cost is a gather instead
of one coherent read, plus that archetype descriptor table, which is genuinely
new machinery.

**Prototype A against B before locking the instance layout.** The cull shader
already exists, so this is a measurable experiment rather than a judgement call,
and it is the one item in section 2 that depends on the answer.

Two known hazards carry over. Buffer growth needs the previous allocation pinned
for a frame or the GPU reads freed memory. And archetype moves become copies
between mapped regions, so dirty range tracking has to survive a row changing
archetype mid-frame.

## 2. Lock the render contract

These are expensive or impossible to change once content and user code depend on
them. Everything else in this plan is downstream of them.

**Delete `Transform2D`, adopt the core `Transform`.** It already carries `x`,
`y`, `z`, and `layer`. This also makes tween move what the renderer draws, which
it currently does not.

**Port `computeDepth` verbatim** from `legacy/gfx/internal/gpu/shaders/depth_common.glsl`,
with `MAX_LAYERS = 16` and the per-layer configuration block: screen-space,
ignore-zoom, virtual-coords and unlit masks, per-layer sort mode, parallax
offsets. `MAX_LAYERS` is load-bearing because the masks and the sort-mode
packing are sized to 16. Once content is authored against the formula, changing
it changes how everything looks.

**Add a depth attachment to the G-buffer,** with per-pass test and write state.
`GraphicsPipeline.tl` currently hardcodes `has_depth_stencil_target = false`.
Retrofitting depth later touches every pass, every pipeline, and the pass
graph's format validation.

**Replace the `vec4 viewport` uniform with a camera matrix** carrying a
projection mode. One `Camera` type, not a 2D and 3D split. Pin the Y-flip
convention in exactly one place; it has bitten before, where `toWorld`,
`toScreen`, and the occluder mask UV signs disagreed with compose.

**Render passes become phases.** `Cull`, `Geometry`, `Lighting`, `Post`,
`Screen` are phases inside `RenderGroup`, not objects. A pass graph and a phase
schedule are the same structure, and having both is the duplication that makes
this feel like an SDL wrapper. This needs the one core change: phases are a
fixed tree built at load time with no registration API, so `RenderGroup` gains
children.

**The instance layout, after the section 1 experiment resolves.** Depth lands in
the spare `origin.w`. Clip travels as a `u16` index into a clip-rect table, not
as four inline floats: the cull pass is memory-bound at about 11 ns per
instance, and inline clip is a 25% instance growth on exactly the number that
matters, for data that is nearly always absent outside UI.

## 3. 2D does not get slower

Measured, on the static scene with immediate present:

```
 instances   full size   quads at 1/10 size   fill share
 ─────────   ─────────   ──────────────────   ──────────
 4k            1.76 ms              1.74 ms          1%
 200k          4.95 ms              3.95 ms         20%
 1M           19.99 ms             12.57 ms         37%
```

The engine is per-instance bound, not fill bound. `computeDepth` and the layer
mask tests are a dozen ALU ops on a pass already waiting on memory, so they
hide. Depth goes in a field that is already spare, so the instance does not
grow. Depth write costs fragment bandwidth and early-Z rejection returns some;
that one is a prediction, not a measurement, and cannot be measured until depth
exists.

The cost that is real and bounded: translucent content needs a back-to-front
sort each frame, scaling with the translucent count only. The benefit that
matters more: depth is what lets opaque content stay unsorted and
archetype-contiguous, which is what keeps the dirty gate working at 4M.

## 4. Clay for UI layout

Verified against `clay.h` 0.14. Components own retained UI state, Clay solves
layout, tecs renders. Clay's own transitions are **not** used: their state lives
in Clay's arena, which means it is invisible to `world:saveSnapshot`, and the
debugger does time travel over a snapshot ring. Anything animated lives in
components, on the fixed step.

What makes it fit better than expected:

- `Clay_ElementDeclaration.userData` passes through to the render command, so
  the entity handle round-trips with no ID lookup. `Clay_RenderCommand` also
  carries `id` and `zIndex`, and the command array is pre-sorted.
- `Clay__ConfigureOpenElementPtr` takes a pointer, so the FFI path avoids
  passing a large aggregate by value. The `Clay__` internals are all
  `CLAY_DLL_EXPORT` under a documented "required by macros" heading, which is
  the sanctioned binding path.
- `SCISSOR_START`/`SCISSOR_END` flatten into per-entity `ClipBounds`, which is
  already a component in the legacy engine.
- Clay caches measurement per whitespace-separated word, so the measure callback
  fires on cache misses rather than per element per frame.

Rules for the integration:

- **Update entities, never respawn them.** Structural change only spawns and
  despawns. Writing entities from the command list every frame would churn
  archetypes and destroy the contiguity everything else depends on.
- **Gate the whole `BeginLayout`/`EndLayout` on the UI dirty bit.** Clay is
  deterministic given the same declarations, so caching the command array is
  sound.
- **The measure callback is C, never Lua.** An FFI callback from C aborts JIT
  traces, and this one fires during layout solving.

Clay replaces the layout half of the legacy `ui/`: `Flow`, `FlowOrder`,
`LayoutBox`, `FitContent`, `Anchor`. `Viewport` and the dirty machinery stay.

## 5. Fonts

Verified against SDL_ttf `main`. `TTF_SetFontSDF` generates distance values "in
the alpha channel", and `TTF_IMAGE_SDF` says the same: single-channel SDF, not
multi-channel. It cannot replace MSDF, and its GPU text engine returns a linked
list of vertex and index arrays, which is not instanced, does not write the
G-buffer, and is regenerated per text object.

Runtime font loading is a requirement, so an MSDF generator has to be linked.
There is no well-maintained pure-C one:

```
 library                  lang   stars   last push
 ───────────────────────  ────   ─────   ──────────
 Chlumsky/msdfgen         C++     4884   2026-05-17
 Chlumsky/msdf-atlas-gen  C++     1297   2026-05-16
 pjako/msdf_c             C         78   2023-01-31
 solenum/msdf-c           C         10   2021-07-19
```

Use msdfgen behind an `extern "C"` shim in `native/`. The build already compiles
C++ for SPIRV-Cross, and `native/spirvcross.c` is the same pattern for the same
reason. msdf-atlas-gen is the same library, so a font baked into the content
pack and one loaded at run time produce identical atlases: one appearance, one
code path, and the offline path stays available where a generator should not
ship.

The resulting stack:

```
 SDL_ttf / FreeType    face loading, shaping, outlines
 msdfgen + C shim      outlines to MSDF atlas, runtime or baked
 generated metrics     owned in memory, never parsed from a .fnt
 the existing pipeline unchanged, all ~2950 lines
```

Because generation owns the metrics, nothing parses a `.fnt` or MSDF JSON at run
time. That removes the parsing half of `bmfont.tl`, roughly 300 of 475 lines,
and keeps the metric types. Clay's measurement cache does not delete existing
code; `glyphslab.tl` caches GPU glyph data keyed by text, font, and scale, which
is a different problem. What Clay saves is a measurement cache that would
otherwise have to be written.

## 6. Assets are handles

No filesystem in game code. Content is a manifest built at package time and a
handle at run time, with the handle being the texture-array slot the GPU already
indexes. Paths exist only inside the packaging step. The shader pack built in
step 5 of the portability work is the working precedent to copy.

## 7. Batteries

A game on a console or on iOS cannot load a library, because there is no
`dlopen`. So anything a shipped game needs at run time is either in the engine's
build or it does not exist, and that is the whole case for shipping batteries.
The same rule splits the list:

```
 runtime, ships in the game    in-engine, static, console-capable
 tooling only                  may be dev-only, dynamic, host-only
```

### SDL3 already covers most of it

All of these are bound and generated today. Nothing new gets added for them:

```
 filesystem   SDL_EnumerateDirectory, SDL_GlobDirectory, SDL_CreateDirectory,
              SDL_CopyFile, SDL_RemovePath, SDL_RenamePath, SDL_GetPathInfo
 storage      SDL_OpenTitleStorage, SDL_OpenUserStorage, SDL_OpenFileStorage,
              SDL_ReadStorageFile, SDL_WriteStorageFile, SDL_StorageReady
 async io     SDL_AsyncIOFromFile, SDL_LoadFileAsync, SDL_CreateAsyncIOQueue,
              SDL_GetAsyncIOResult, SDL_AsyncIOOutcome
 process      SDL_CreateProcess, SDL_GetProcessInput, SDL_ReadProcess
 time         SDL_GetCurrentTime, SDL_TimeToDateTime, locale preferences
 misc         SDL_rand with explicit state, SDL_murmur3_32, SDL_OpenURL,
              clipboard, power, preferred locales
```

`SDL_Storage` replaces the base-path and pref-path pair currently in `paths.tl`.
It splits read-only title content from per-user save data and has an explicit
ready state, because on a console storage is not available synchronously at
boot. That is the shape the platform seam should expose.

### Asynchronous IO is SDL's, not ours

`SDL_GetAsyncIOResult` is non-blocking and fills an outcome, so the whole
mechanism is a drain in a phase. `SDL_LoadFileAsync` reads a whole file in one
call, and the `userdata` pointer round-trips, so an asset handle travels with
the request and comes back with the result.

This splits asset loading three ways, and only one part needs a thread:

```
 read      SDL_AsyncIO           native async, no worker
 decode    worker                CPU-bound, genuinely needs a thread
 upload    copy pass             main thread
```

What that buys depends on the platform, and it is worth being exact. SDL has
three backends: `io_uring` on Linux, IoRing on Windows, and a generic one
everywhere else that is a thread pool blocking on synchronous reads, sized at
twice the core count plus one. macOS and iOS get the generic one.

So on Apple platforms this is not faster than the worker that does it today. It
is one API instead of two, a thread pool SDL maintains rather than one we do,
and a free upgrade to kernel async on Linux and Windows. Take it for those
reasons, not for throughput.

liburing is loaded through `SDL_LoadObject`, so a statically linked target
silently falls back to the thread pool. Report which backend is live through
capabilities rather than leaving it to be discovered in a profile.

### Storage and async IO are not alternatives

They answer different questions. AsyncIO answers when the bytes arrive. Storage
answers which namespace is being read and whether it is available yet.

The friction is that Storage is closed: `SDL_ReadStorageFile` never yields a
path, so nothing can be handed to AsyncIO. That is a real fork, so split it by
use case rather than by platform:

```
 assets     read, hot, streaming    AsyncIO
 save data  write, cold, once       Storage
```

Assets take AsyncIO, for native async with no worker. Where a target has no
filesystem, a Storage-backed implementation does the read on a worker instead,
and the synchronous read stops mattering once it is off the main thread. That
substitution is only cheap because assets are handles and game code never sees a
path, which is the rule in section 6.

Save data takes Storage now, because saving is infrequent and two things there
have no AsyncIO equivalent. `SDL_StorageReady` models storage that is not
mounted at boot, which happens on a console before a profile is chosen, and is
polled in a phase rather than spun on as the header's example does.
`SDL_GetStorageSpaceRemaining` is what certification generally requires before a
write.

`SDL_OpenStorage` also takes an `SDL_StorageInterface`, twelve function pointers
covering read, write, enumerate, info, mkdir, remove, rename, copy, space and
ready. A licensed port implements those and nothing above changes, so Storage is
a better seam for content than anything hand-rolled here.

### JSON: take lua-cjson, delete ours

The recorded bench decides it. Parsing a small object:

```
 implementation   min_us   p50_us
 ──────────────   ──────   ──────
 lua-cjson        0.1658   0.2910
 tecs.json        0.2496   0.3329
 loadstring       0.6659   0.7921
 dkjson           2.0410   2.2091
```

lua-cjson is 1.5 to 2x faster and removes 1,229 lines. Two migration risks: it
cannot distinguish an empty array from an empty object without a sentinel, and
both the MCP protocol and the Tiled loader round-trip structures where that
matters; and the Teal types go, so it needs a declaration file.

### HTTP is a platform seam, not a linked dependency

SDL has no HTTP client and will not grow one. curl brings a TLS stack, and
consoles have their own networking stacks and certificate stores where it is
generally not permitted; Apple platforms have NSURLSession as the blessed
client. The seam therefore earns its keep well beyond console. So the engine exposes an
HTTP API and curl implements it for open platforms, as a sixth seam alongside
lifecycle, events, static FFI, storage, and shaders.

The integration shape matters more than the library. Requests are components, a
worker owns the multi handle, and completions arrive as typed events. curl never
touches the frame path, and an in-flight request is component state that
survives a snapshot.

### Sockets: SDL3_net

Same ecosystem, same static-link story, and it fits a poll-per-frame loop:
`NET_GetAddressStatus`, `NET_GetConnectionStatus` and `NET_ReadFromStreamSocket`
all return immediately, with the `NET_WaitUntil*` forms as opt-in. luasocket is
blocking-oriented and predates everything about how this loop works. For
reliable UDP gameplay traffic rather than raw sockets, ENet is the alternative
worth considering.

SDL3_net carries no TLS, which is why it is not a path to HTTP. Every real
endpoint is HTTPS, so building on it would mean sourcing a TLS stack and writing
a client, which is a worse trade than linking curl.

### Compression is two questions

zlib is interop: HTTP content encoding, `.gz`, anything produced elsewhere. It
arrives with curl, so it costs nothing extra.

Asset and snapshot compression is a different job, where decompression speed
matters more than ratio, so it is LZ4 or zstd and not gzip. Having zlib present
is not a reason to use it for content.

### base64 is not a dependency

curl does not export it publicly and SDL does not have it. Forty lines.

### Headless is the one worth prioritising

A world without a device makes the asset pipeline tecs programs rather than a
second language. MSDF baking, shader packing, texture array building, and
manifest generation currently live across `gencdef.py`, `genregistry.py`,
`abicheck.py`, `checkpackage.py`, and `buildshaders.lua`. One toolchain, and the
tooling exercises the engine it ships with.

It is nearly true already. The blockers are that the host always creates a
window and there is no non-application entry point.

### Logging: SDL_Log, and nothing else

`logging.tl` and `logtap.tl` both go, 318 lines, and nothing replaces them. No
timestamp cache, no sinks, no prefixes, no level options, no ring buffer.

The reason is not that SDL writes to stderr. It is that SDL's default output
function is a per-platform destination:

```
 Windows   OutputDebugString, plus console with attach handling
 Android   __android_log_write, so logcat with a tag
 Apple     SDL_NSLog
 other     fprintf to stderr
```

Writing to stderr from Lua on Android reaches nobody.

`SDL_LogMessageV` checks the priority before it formats, and renders into a
stack buffer that only mallocs on overflow, so a filtered message costs nothing
and an emitted one allocates nothing. `SDL_GetLogPriority` bypasses the mutex
for known categories and is a plain array read; the lock guards the output
dispatch, which happens after the filter. Formatting in Lua and passing `"%s"`
would throw all of that away and allocate a collectable string per call, so the
guard goes outside:

```lua
if C.SDL_GetLogPriority(category) <= INFO then
    C.SDL_LogMessage(category, INFO, "%s", fmt:format(...))
end
```

Disabled, that is a load and a compare after LuaJIT inlines the call. Enabled,
SDL formats and dispatches.

Logger names map onto `SDL_LOG_CATEGORY_CUSTOM + n`. `SDL_GetLogPriority` is
then the only source of truth, so `SDL_SetLogPriority` works without anything
mirroring it, and per-subsystem verbosity becomes a debugger command with no
state to keep in sync. SDL's own diagnostics, GPU errors and driver selection
and audio device problems, arrive in the same stream with no tee.

What is lost: timestamps on desktop stderr. logcat and os_log stamp for us.

A log file is the one thing SDL has no sink for, and MCP needs it. It is a small
C output function that writes the line and then delegates to
`SDL_GetDefaultLogOutputFunction()`, so the platform destination still gets the
usual human-readable text. It lives in C rather than Lua because SDL logs from
its own audio and async IO threads, and an FFI callback from a thread the VM did
not create is the unsafe pattern behind the unexplained worker crash in section
9.

The file is what lets `get_logs` drop its ring buffer. The cursor stops being a
synthetic sequence number and becomes a byte offset: seek, read to the end,
return the lines and the new offset. Co-located agents get the path and grep it
directly, mirroring how `cmd_screenshot` already prefers an artifact over inline
base64; remote ones get the tail over the wire.

Write it as JSON Lines. The output function receives category, priority and
message as separate arguments, already structured, so nothing ever re-parses
formatted text. That was logtap's mistake: it formatted a prefix and then
recovered the logger name back out of it with a pattern match.

On a target with no writable log file the output function keeps a small ring in
C instead. Not before something needs it.

### Not included

Crypto beyond hashing, an image codec beyond SDL_image, a regular expression
engine, and anything XML. Each is real surface, and none is something a game
cannot live without or a tool cannot reach through `SDL_CreateProcess`.

### The rule for all of them

Every integration is a tecs-shaped API, never a raw binding in the public
surface. HTTP requests are components with events, not a curl handle. Storage is
handles, not paths. Sockets are components, not descriptors. That is what lets a
console port substitute an implementation, lets the underlying library be
swapped, and keeps the whole surface explainable as a world, components, and
phases.

## 8. What is still to port

Roughly 55k lines of the legacy engine, in dependency order:

```
 subsystem   lines    notes
 ─────────   ──────   ─────────────────────────────────────────────
 ui           1,899   Love-free already; Clay replaces layout
 text         2,950   needs section 5
 debug       17,102   includes MCP, the stated moat
 mcp          1,722
 tiled        4,103
 audio        1,592   nothing exists on SDL3 yet
 assets       1,055   becomes section 6
 gfx         24,845   largely superseded rather than ported
```

Already across: tween and sequence, 4,292 lines with their 2,874-line suites,
paused pending upstream iteration.

## 9. Open problems

**A 1.74 ms fixed cost per frame.** It does not move with instance count from 4k
to 1M, with quad size across a 100x coverage change, or with light count. The
legacy engine renders its entire 200k `shapes` scene in 2.34 ms, so this burns
74% of a whole legacy frame before drawing anything. It is the largest number on
the board, it is independent of everything else here, and no performance claim
means much until it is explained. Candidates: the two full-screen passes and
their clears, or swapchain acquire blocking.

**Only one preset has ever been built.** `macos-arm64-dev`. The other eight are
declared and unexercised, and the SPIR-V path has never executed.

**A worker crash that is not root-caused.** Intermittent silent process death,
roughly one run in ten, when `string.buffer` is handed an unencodable value with
worker threads live. Made unreachable by validating first; the mechanism is
unknown.

**Two demo-level bugs found while benchmarking.** 256 lights fails at startup
while 32 works. And when `TECS2D_LUA` is unset, the development fallback in
`package.path` silently loads the legacy engine instead of this one, which needs
to go or become loud.

## 10. Sequence

```
 0  merge                    mechanical, unblocks the rest
 1  column experiment        A against B, decides the instance layout
 2  lock the contract        section 2, everything else depends on it
 3  headless + async IO      cheap, and makes the tooling one language
 4  Clay and UI
 5  fonts
 6  remaining port           debug and MCP first, they make the rest visible
```

Batteries land opportunistically rather than as a phase. lua-cjson and
SDL_AsyncIO are worth taking early because both delete code; HTTP and sockets
can wait until something needs them.

The 1.74 ms floor is independent and should be chased in parallel, before any
performance claim is made.
