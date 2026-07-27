# tecs

A typed entity component system and the game engine built around it, in Teal
for LuaJIT, on SDL3, SDL_GPU and Box2D 3. The two were separate projects and
are now one: the ECS knows what the GPU reads. Entities are the interface,
so anything that renders or updates per frame is an entity in a world.

SDL owns the loop. An entry file returns an application and a C host drives it
from `SDL_AppInit`, `SDL_AppEvent`, `SDL_AppIterate`, and `SDL_AppQuit`:

```lua
return tecs.application({
    load = function(app) end,
    update = function(app, dt) end,
    event = function(app, event)
        if event.kind == "appWillEnterBackground" then end
    end,
    quit = function(app) end,
})
```

That shape is not a preference. iOS never hands control back for a blocking
loop to sit in, so a host that cannot be entered by callback cannot run there
at all. The same shape works on desktop, so there is one lifecycle rather than
one per platform. The callbacks are C reaching Lua through the Lua C API, not
FFI callbacks, which are a trace barrier and unsafe from a thread the VM did
not create.

Everything below Lua is reached through the FFI. There are no Lua C extensions:
the only native code is a host that owns `main`, and even that is never called
from Lua.

## Status

Working today:

- Generated FFI bindings for SDL3, Box2D 3, shaderc, and SPIRV-Cross, verified
  against the C ABI
- A window, a Metal/Vulkan/D3D12 GPU device, and a swapchain render loop
- GLSL compiled at runtime to SPIR-V and translated to MSL, with resource
  bindings reflected and remapped for the backend
- Immutable graphics pipelines, storage buffers, uniform buffers, and offscreen
  render targets with pixel readback
- Compute pipelines with reflected workgroup size, and GPU-driven drawing: a
  compute pass writes the draw arguments, one indirect draw consumes them
- A declarative pass graph, and a deferred pipeline built on it
- Sixteen layers, each a band of the depth range that never sorts against
  another, deciding how its contents sort within that band, where they are
  positioned (by the camera, in screen pixels, in a virtual resolution, at
  their own parallax, or at a fixed size under zoom) and whether they are lit
- An ECS binding: Transform2D, Tint, Sprite, Material, PointLight, Clip and
  Renderable components, with a sync that walks archetype columns straight into
  mapped GPU staging, and a depth-tested G-buffer
- Physics in the world: a RigidBody component holding a value-typed Box2D
  handle, stepped in the fixed phases, solved across a native thread pool, and
  written back from the movement Box2D reports rather than by asking per body
- Input in three tiers behind a layer stack, latched for fixed steps, with
  per-device gamepads, text input bound to a layer, touch and pen
- Worker threads with serialized channels, and asset loading that decodes on
  one and uploads on the main thread
- Frame pacing from the swapchain, with no sleep heuristic
- Shaders packaged as artifacts, so a release links no compiler
- A platform contract with seven seams, and an SDL implementation of all seven
- A debug server over HTTP that survives a crash in game code, with tools that
  read and write the world, capture the frame, and report what the mixer is
  doing
- Per-stage frame timing with percentiles, which is how any of the numbers in
  this file were arrived at, and event-to-photon latency reported through the
  same stages
- Text from a signed distance field, laid out into one entity per glyph so it
  goes through the same cull and the same draw as everything else
- Deterministic sequencing with tweening merged into it: programs compiled to
  instructions, playback position kept as data so it survives a snapshot, and
  three clocks (fixed, frame, presentation) for the three rates gameplay,
  scripted input and presentation run at
- Sprite sheets on Aseprite's model: frames with their own durations, named
  tags playing forward, in reverse or pingpong, and slices carrying pivots,
  built by a grid, an explicit rect list, a builder, or read from an Aseprite
  JSON export; with playback resolved in the vertex shader against a shared
  frame table, so a frame changing writes nothing and two hundred thousand
  animating sprites cost what two hundred thousand still ones do
- Layers: sixteen bands of the depth range, each choosing how its contents sort
  within it, and each able to sit in screen pixels, in virtual coordinates,
  outside the camera's zoom, at its own parallax, or unlit
- Sound: clips read on the asset worker through SDL_mixer's decoders, a voice
  per mixer track, groups by tag with a gain, a mute and a sticky pause each,
  keyed limits with cooldowns, fades, pitch, loop points that change mid-play,
  seek and tell, 3D position or a plain left-and-right pan, streaming for long
  clips, and a `Sound` component that names a group and follows what is
  written to it for as long as its entity is around and enabled
- The clipboard read and written, and the primary selection beside it, so the
  `clipboardUpdate` event is something a game can act on rather than only
  notice
- Child processes run to completion off the main thread, with their output,
  error output and exit status answered through a handle a frame polls, an
  environment and a working directory the caller chooses, and a teardown that
  ends a child rather than leaving it behind
- The window: size, position, limits and aspect, fullscreen and the mode lists
  behind it, visibility and minimisation, focus, opacity, borders, icon, safe
  area, taskbar attention and progress, pointer and keyboard confinement, and
  the displays underneath it all, every one of them also settable in the
  application's config

Not built yet: shadows, post-processing, UI, tiled maps and multi-camera.

Design notes live in `../tecs-plans`, kept outside this repository so plans and
code have separate histories.

## The surface is a global

`tecs` is a global, so a game writes it in any file with no require line:

```lua
local world = tecs.newWorld()
local Velocity = tecs.newComponent({
    name = "Velocity",
    container = {},
    fields = { "x", "y" },
    defaults = { 0, 0 },
})
world:spawn(tecs.builtins.Transform(0, 0), Velocity(1, 0))
```

`require("tecs")` is equally supported and returns exactly the same table, so a
file that prefers to name its dependency can:

```lua
local tecs = require("tecs")
```

The global is set by `src/tecs/init.tl` itself, as it returns, and that
placement is the whole design. A host that set it would leave the global
present for a game and absent under a plain interpreter, so a headless tool,
the spec suite and the benchmarks would each see a different surface and the
same line would work in one and fail in another with nothing to warn on.
Setting it where the module is defined means requiring tecs anywhere,
including transitively, is enough. Require stays the mechanism; the global is a
consequence of it.

It is the same table, metatable included, so nothing about the lazy engine half
changes: `tecs.Application` read off the global resolves on first use exactly as
it does read off the required value, and `require("tecs")` still loads no engine
module. `require` caches, so the assignment runs once. A game that assigns
`tecs` itself afterwards owns the name from then on, and the declaration below
no longer describes what is there.

Teal types it through `src/tecs/global.d.tl`, which reads the type off the
module rather than restating it, so the two cannot drift:

```teal
local type TecsModule = require("tecs")

global tecs: TecsModule
```

A game names that declaration to the type checker in its own `tlconfig.lua`,
alongside the installed Teal sources that carry the engine's types:

```lua
return {
    global_env_def = "tecs.global",
    include_dir = {
        "<luajit-tl-type>",          -- ffi, bit, jit, string.buffer
        "<prefix>/share/tecs/teal",  -- tecs
    },
}
```

`tl check` then reports `tecs.newWorldd()` as `invalid key 'newWorldd' in record
'tecs' of type TecsModule`, at the line that wrote it. `TecsModule` is the
declaration file's own name for what the module returns, kept distinct from
`tecs` so the file that has to hold both apart reads unambiguously. It is
never something to write: the surface is spelled `tecs` everywhere else.

`share/tecs/teal` is the Teal sources, installed beside the compiled Lua that
actually runs. A `.lua` carries no types, so the sources are how a game reaches
them, and there is no second description of the surface to keep in step. The
declarations for LuaJIT itself are not tecs's to ship: they are the
`luajit-tl-type` rock, which any Teal project on LuaJIT installs.

Code inside this repository keeps its explicit requires. `src`, `main.tl` and
`bench` all say what they depend on, which is worth more than the line it saves,
and the engine's modules require `tecs.ecs` rather than the whole surface for a
reason the global would quietly undo. So `make check` runs with no declaration
loaded, and a module that reached for `tecs` without requiring it is an error
here rather than a cycle later.

## Callbacks and systems

Because the host reaches into an object rather than being handed a loop,
something has to run after the device and the world exist, once per iteration,
once per event, and once at teardown. That much follows from the entry point.
What does not follow is that those four are named fields of a typed record.
`load`, `update`, `event` and `quit` sit on `Application.Config` beside the
window, the shader pack, the audio device, the frame cap and the rest of the
startup settings, and that part is a choice. It is made for what the type
checker can say about it.

A name the host looks up at call time is a name nothing checks: a game that
misspells one gets a function that is never called and no diagnostic anywhere.
Written as a field of a record, every one of them is checked where it is
written:

```
entry.tl:4:5: unknown field windwo
entry.tl:5:5: unknown field updat
entry.tl:6:17: in record field: maxFrames: got string "sixty", expected integer
entry.tl:7:52: in record field: update: argument 2: got string, expected number
entry.tl:9:20: in record field: quit: incompatible number of arguments: got 2, expected 1
```

The error lands on the key, not on the frame that fails to call it, and nesting
does not weaken it: `window = { widht = 640 }` fails the same way. The one thing
it does not object to is dropping trailing parameters, so
`update = function(app)` type-checks against `function(Application, number)`.
That is worth having rather than working around; the demo's `update` takes only
the application, because reading a key is all it does.

Each callback is placed rather than merely called, and the placement is most of
what the shape is worth. `load` runs at the end of initialisation: the log file
is open, the shader pack has already decided which format the device may claim
and so which backend SDL selects, the window, device, world and renderer exist,
audio and the sequencer are installed, touch is scaled to the window, the
latched-input systems are in the fixed phases, and any gamepad that was plugged
in before the process started has been enumerated, since the platform reports a
device arriving and not one that was there all along. It runs before the clock
resets, so startup cost never lands in the first frame's dt. `event` runs after
the engine has folded the event into its own state, so quit, resize, suspend and
resume are handled and the game still sees the event. `update` runs before the
world steps, timed as a stage of its own, because its cost belongs to the
simulation side of any split and leaving it outside every stage would flatter
anything that moves work to the other side. `quit` runs before anything is
destroyed, so the window, device, world and renderer are all still live in it,
and it runs only if `load` returned, so a game never gets a teardown for a
startup that did not finish.

Where the line falls between a callback and a system is the question worth
answering, since entities are the interface and most per-frame work belongs in a
system. A system's signature is `(dt, world)` and it never sees the application,
so anything that reaches for the window, the input, the device or
`quitRequested` is either a callback or a system that captured the application
when `load` registered it. Nothing forbids the second, and the demo does exactly
that. The distinction that decides it is position rather than access. A system
runs inside `world:update`, which is what gives it phase order, deferred
mutation, the fixed step, pause and state gating, and the crash guard. A
callback runs outside all of that.

So gameplay goes in systems, and a callback is for work that has no entity to
hang on. The latency bench is the clearest case: its `update` pushes a synthetic
key event into SDL's queue and resets the timing tables at a chosen frame,
neither of which is world state, while the reaction to that press is an ordinary
system in `Update`, where it sits inside the step the measurement brackets.

The crash guard is the sharpest edge on that line. The world's step and the frame
it produces are wrapped, so an error in a system stops simulating and rendering
and leaves the loop draining events and answering the debug server with the
traceback, which is the moment the tooling is most useful and the worst one to
lose. The callbacks are called outside that guard, so an error in `update`
unwinds to the host, which logs it and ends the run. The same line of gameplay is
inspectable after it fails in a system and is not inspectable after it fails in
`update`, which is a second reason to prefer the system.

The shape costs something, and the cost is singleton assumptions. An application
owns one world; a second is possible and can be stepped from `update`, but only
`app.world` is rendered, bound to the debug tools and given the engine's own
systems. Replacing a callback while running works, since `event`, `update` and
`quit` are read off the config at each call rather than captured, but the config
is not part of the public surface, so hot reload has no seam of its own.
Nesting one application inside another does not work at all, and not because of
the config: the host holds a single registry reference to one returned table,
`SDL_Init` and `SDL_Quit` bracket the process, and the debug server's bindings
are module-level.

What the shape buys below itself is that nothing needs it. `tecs.Application` is
not loaded by `require("tecs")`; the engine modules resolve on first use through
the surface's `__index`, which is what lets a tool build a world with no window,
no device and no SDL reachable at all. The spec suite never constructs an
application: it builds worlds directly, or assembles a window, a device and a
renderer by hand, because the config is the only thing that puts those together
and every piece it puts together is separately constructible. The debug server
is bound to the world and the renderer rather than to the application, so a tool
reads the same world whichever callbacks a game supplied, and none of it goes
through the config at all.

## Workers and assets

Workers are the only sanctioned way to run work off the main thread. Raw
thread creation stays unexposed: a LuaJIT FFI callback invoked from a thread
the VM did not create is unsafe, and a thread entry written in Lua is exactly
that mistake. The native side starts a thread with a fresh `lua_State` and
moves opaque byte blocks between queues; it never learns what a message
contains, because serialization stays in Lua.

That boundary is not a style choice. LuaJIT has no shared mutable heap across
threads, so a worker cannot see the spawning state's objects at all. What
crosses is numbers, strings, booleans, and tables of those.

Sends are checked before encoding rather than left to fail inside the encoder.
That is partly for the message, which names the offending path instead of
saying a function turned up somewhere. It is mostly because the failing path
proved unsafe: an encode error raised while worker threads are running
intermittently terminated the process instead of surfacing, at roughly one run
in ten under a coroutine-based test runner and never standalone. The mechanism
is below this code and unresolved. Not calling the encoder with something it
will reject keeps that path unreached.

A worker's state has to be given somewhere to compile into, and that is the
host's job rather than the worker's. A LuaJIT trace reaches the interpreter
with one immediate branch, so its machine code has to sit within that branch's
reach: 128MB on arm64, which LuaJIT halves to 62MB either side of the
interpreter's own code so mcode can reach mcode too. There is no way to hand
LuaJIT memory. It asks the kernel for an area near that anchor and rejects
whatever lands outside, and there is nowhere else a trace can go.

This process fills those 124MB. Below the anchor is `__PAGEZERO`, four
gigabytes the kernel refuses to shrink. Above it is where the loader stacks
every dylib and where the graphics driver maps. Sweeping the window with one
mmap per 64KB slot, all 1984 land before the engine boots and none do once a
window and a device exist, so a state created after that point never gets an
area and runs entirely interpreted. Measured on one hot numeric loop, a worker
took 27.8 seconds against the main state's 20.3 milliseconds, and
`jit.status()` answered true throughout.

So `native/mcodearena.c` holds 24MB of that window from the host's first
instruction and gives it back once initialisation returns. Everything mapped in
between goes elsewhere, because the block is already there, and what is
released is free address space in reach that nothing else has taken. The same
loop then runs in 23 milliseconds on a worker, within noise of the main state,
with LuaJIT's own defaults and no tuning. Reserving costs no memory: the block
is mapped unreadable and never touched.

Twenty-four megabytes is what fits, measured: a block that size places on every
launch and thirty-two on none. It also has to be that large to be enough, since
the driver's first-frame mappings take most of what is released before any
worker compiles; eight megabytes places just as reliably and left the worker
interpreted in three launches out of four. About six megabytes survives to
steady state, which is a dozen states compiling the 512KB LuaJIT allows each of
them, and many more compiling a few loops apiece: 48 workers running one loop
at once were measured with none of them interpreted. Past that bound a worker
competes for whatever the loader left, and the symptom is only that it runs
slowly. `TECS_TRACEPROF=1` makes each worker report its trace aborts when it
stops, which is how that is told apart from a worker that is merely busy: the
failure reads as tens of thousands of `failed to allocate mcode memory`.

Asset loading rides on that. Decoding a PNG is milliseconds of pure CPU work
with no GPU involvement, so it happens on a worker and the main thread only
uploads. The worker returns the _address_ of a decoded surface rather than its
pixels: surfaces live in process memory, so the pointer is valid in either
state, and passing it avoids copying an image through a serialized message
only to copy it again into staging. Ownership transfers with the address.

Sound takes the same route. A clip is read and decoded on the worker by
SDL_mixer and handed back as the address of a `MIX_Audio`, so a file that turns
out to be a minute of Vorbis costs the frame nothing. A clip long enough to
stream is measured on the worker and then thrown away rather than decoded, and
the voices that play it read the file for themselves.

The application owns the pump. `assets.update` runs once per iteration and
`assets.shutdown` runs at teardown, so a game that loads an image and does
nothing else still sees its handle resolve and the decoding thread still stops.
Subsystems that load assets of their own drain the same queue when they look at
their own waiting lists, and that is an optimisation rather than the mechanism.

A handle is a one-shot future, not a cache. Two loads of one path that overlap
share the decode and the surface, because decoding the same file twice at once
produces nothing the first decode does not already have; the last of them to
release is the one that frees. A load that starts after the first has resolved
decodes again, since handing back a handle whose pixels may already have been
uploaded and released would be a cache with none of a cache's guarantees.
Release is terminal and says so: a released handle reports `"released"` rather
than reporting `"ready"` over pixels that are gone, which is the difference
between a clear error at the upload and a null dereference inside it.

Files a game interprets itself go through `assets.read`, which is the only
sanctioned way to get bytes out of the content root: on Android content lives
inside the package and `io.open` does not reach it. It answers bytes rather
than text, so an image, an archive or a binary sidecar comes back whole and
being text is a decoder's opinion. Reading a document is that call and a
decoder over it, with nothing in between:

```lua
local bytes = tecs.assets.read(tecs.paths.asset("levels/1.json"))
local level = tecs.json.decode(bytes)
```

`read` answers nil for a path with no file, so an absent document is
distinguishable from a malformed one, which the decoder raises on.

Waiting on several handles at once is `assets.batch`. Sound holds a clip per
handle and text holds an atlas per handle; each of them had grown the same list
separately, and each wanted the same three things, which are how many are still
in flight, one callback per load that finished with the caller's own value
beside it, and a blocking form for startup and tests. A batch resolves by
compacting in place, so a frame with loads outstanding allocates nothing, and it
drains the worker itself, so a subsystem polling only its own batch still sees
its loads finish. The one rule it imposes is that a callback must not add to the
batch it is being called from, because the compaction is walking it.

All three entry points record what they touched. `assets.loaded` answers every
path this process has read or decoded and the kind it was read as, which is what
the file watcher polls instead of walking the content tree.

## Sound

`app.audio` is the whole surface: load a clip, play it, set a gain, fade it,
loop it, pitch it, seek it, pan it, put it in a group, cap how often it may
start, stop it. It is built on SDL_mixer 3 and on five decisions.

**The mixer decodes.** A clip is whatever the linked decoders can read. What
this build has is a question with a runtime answer rather than a configure-time
one, because a decoder whose dependency was missing is dropped without
complaint, so `Audio.decoders()` reports the list the library itself gives.
`cmake/Pinned.cmake` names every decoder option rather than accepting defaults:
several of them are LGPL and on by default, and a statically linked game must
not import those. dr_mp3 stands in for mpg123, dr_flac for libFLAC, stb_vorbis
for vorbisfile, and `SDLMIXER_STRICT` turns a dependency that could not be
found into a configure failure instead of a silently missing format.

**A voice is a track, and the mixer mixes.** Playing a sound points a track at
a clip and starts it; playing the same clip three times over is three tracks
reading one clip. Thirty-two voices by default, and a thirty-third play
declines rather than stealing one, because a sound that stops halfway through
because something else started is harder to explain than one that never
started.

**No callback runs on an audio thread.** SDL_mixer can call back when a track
stops, and that callback fires on a thread the Lua VM did not create; a Lua
function invoked from such a thread is the same unsafe case that keeps raw
thread creation unexposed. So none is installed, and `update` asks each
sounding voice whether the mixer is still taking samples from it. A voice is
reaped on the frame after it ended rather than the instant it did, which is the
whole cost, and it is the same frame the pass over `Sound` components already
runs in.

**A clip is resident or streamed, and its length decides.** Under ten seconds a
clip is decoded once, up front, and every voice reads the same PCM: that is
what a sound effect played forty times a second wants. At or over it the clip
holds nothing and each voice opens the file and decodes as it plays. A file
that will not say how long it is streams too, because a file that will not say
may be very long. `load` takes `stream` to override the threshold either way,
and `streamSeconds` moves it.

**Exactly one thing writes each gain.** The master is the mixer's own number
and goes straight to it, so setting it costs one call however many voices are
sounding. A voice's gain and its group's are multiplied together in Lua and
pushed to the track as one product, because SDL_mixer's per-tag gain is not a
separate multiplier: it writes each tagged track's own gain, and using it for a
group would overwrite what the voice asked for.

Groups are the mixer's tags. A voice names one on `play`, and the group's gain,
mute, pause, resume and stop reach every voice carrying it. Keyed limits are
not: `setLimit` caps how many voices a key may hold at once and how soon after
one starts another may, which is what keeps forty enemies dying together from
playing forty identical sounds, and SDL_mixer has no notion of it. The two
compose without either knowing the other, because a group says where a gain
comes from and a key says how many the mix will carry.

**A group's settings outlive the voices in it.** A gain, a mute and a pause are
recorded against the name and consulted when a voice starts, so a sound that
begins after "hold every effect for the menu" is held rather than heard.
`MIX_PauseTag` cannot answer that alone: it reaches the tracks sounding at the
moment it is called and explicitly ignores the rest. A mute is bookkeeping over
the gains that already exist and the mixer is never told about it, because
setting a group's gain to zero would lose the level an unmute has to put back.
The master mute is the exception that proves it: it goes to the mixer's own
number, the same place the master gain goes, and does not fan out to the groups,
whose mutes are the answers a later unmute needs.

None of that is in the world, so `Audio:install` adds a snapshot handler that
carries the master gain, the master mute and every group's gain, mute and
pause. Keyed limits stay out of it. A limit is a rule the build states at
startup beside the clip it governs, so restoring one from a file would let an
old save override a rule the build has since changed, and what a limit's bucket
holds is derived from voices a snapshot does not restore.

The output is the platform's default rather than a device chosen by name, so
SDL migrates the logical device when the system default changes and plugged-in
headphones need no handling.

A `Sound` component is how a sound belongs to an entity. Presence is the
instruction: an entity carrying one with a loaded clip starts sounding on the
next audio pass and stops when the component or the entity goes away. One walk
per frame starts what has not started, follows what is sounding, marks what has
finished, and releases any voice no component referred to, which is what makes
despawning something mid-sound do the obvious thing without an observer on
every archetype.

`Sound.playing` is the instruction rather than a report. Clearing it ends the
voice and puts the row back to zero, so setting it again starts the sound,
including on a one-shot that had already run out. Disabling an entity has the
same effect for the same reason and comes back the same way: `Disabled` is
excluded from every query that does not name it, so a disabled row is not
followed and its voice is taken, and the pass clears the handle in the same
frame so re-enabling starts rather than reading a voice that has gone as one
that finished. A second query naming `Disabled` is what sees those rows, and
because a disabled entity sits in an archetype of its own, a world with
nothing disabled matches nothing and walks nothing.

A `Sound` names its group the way it names its clip. The component is FFI and
holds numbers, so `Sound.group` carries an interned index from `Audio.groupId`
rather than the tag itself, and zero is no group. The index is one run's
numbering and nothing else, which is why the component serializes the name: an
integer in a save file would name whatever the next run happened to intern in
its place. `playing`, `gain`, `loop`, `pitch` and the position are followed for
as long as the voice sounds, each of them a read and a compare per sounding row
per frame and a call only on the frame the value moved. `clip` and `group` are
read when a voice starts and not afterwards, because changing either takes an
untag, a retag and a fresh input whatever else happens, and following a field
that cannot be applied without a restart would put that cost on every row that
never changes it. So moving a sound to another group means setting `group` and
clearing `voice`.

Position is passed to the mixer and nothing more. `Sound.spatial` switches it
on and `x`, `y` and `z` are read as SDL_mixer reads them: a right-handed system
whose listener sits at the origin and cannot be moved. The mixer attenuates
with distance and spatialises across the speakers on its own, so what is left
undecided is what a game has to do by hand. There is no listener component and
no rule that the camera is one, so whatever a game decides is listening is what
it subtracts before writing those fields; the scale between world units and the
mixer's is the game's to pick; and a sound on a layer that does not move with
the camera has no world position to convert, so it leaves `spatial` at zero.
Each of those is a design decision about a game rather than about audio, and
answering any of them here would fix the others by accident.

`Audio:setStereo` is the other way to place a voice: a plain left and right
gain, with no listener to subtract and no distance model to argue with, which
is usually what a game laid out on a plane wants. It and `setPosition` are
exclusive rather than layered. SDL_mixer keeps one spatialization mode per
track, so `MIX_SetTrack3DPosition` folds the input to mono and derives the
speaker gains from the coordinates while `MIX_SetTrackStereo` writes those same
gains directly and resets the recorded position, and whichever was called last
is what is heard. A null to either leaves both, which is why one
`clearSpatial` answers for them.

Fades are the mixer's to run, on a play and on a stop. `play` takes a
`fadeIn`, and `stop`, `stopGroup` and `stopAll` all take a fade-out and leave
the voice sounding until the mixer finishes it, so a faded stop costs nothing
per frame and cannot drift. `pause` and `resume` take no duration, and that is
the same decision rather than a gap in it: the mixer ramps nowhere else, so a
faded pause means a gain ramp run from Lua on frame boundaries, its length
following the frame rate rather than the clock, with the pause itself deferred
until the ramp lands. What the mixer does offer instead is `tell` to read a
voice's position and `seek` to put one back, so fading out and taking a sound
back where it left off is something a game can build without either cost.

## Physics threads

Box2D 3 solves across threads when a world is given a task system, and solves
on one when it is not. Handing it one is worth the whole of the difference: a
step is most of a frame in a scene where the bodies stay awake, and no amount
of work moved off the main thread elsewhere touches it.

The executor is native for the same reason worker threads are. Box2D calls the
task function from whichever thread picks the work up, so an `enqueueTask`
written in Lua would be an FFI callback invoked from a thread the VM did not
create. `native/taskpool.c` is a fixed set of threads over one queue of chunks,
and Lua's part is to install two function pointers and a context into
`b2WorldDef` before the world is created.

Worker slot zero is the thread that called `b2World_Step`, which drains the
queue while it waits instead of idling; every other slot belongs to one thread
for that thread's lifetime, which is what Box2D means when it says a worker
exists on one thread at a time. So a pool of one worker starts no threads and
runs every task inline, which is exactly a world with no executor.

Claiming is oldest chunk first, and that is a correctness property rather than
a fairness preference. Box2D puts one task per worker in flight and the first
of them drives the rest through the solver's stages while they wait on it, so
an order that could leave that one queued while the others occupied every
thread would hang. FIFO puts it on a running thread before any of them starts.
Enqueuing never blocks and never waits for a free slot: more tasks outstanding
than the pool has room for means the task runs in the calling thread, which
Box2D accounts for through a null result.

The count defaults to the machine's performance cores where the platform will
say which those are, because the workers wait on each other between stages and
the slowest core sets the pace of the step. Adding workers does not change the
answer: the solver colours its constraint graph so no colour holds two
constraints sharing a body, and a 1,600-body pile lands bit-exactly where one
worker left it whether it was solved by 2 or by 64.

## Events

One typed stream, derived from SDL, shared by desktop, mobile, replay, and
tests. Game code never sees an `SDL_Event`: the union is a poor thing to
program against, and its pointer is only valid inside the callback that
produced it, so the host copies each event into a queue and the conversion
happens once.

`Event` is one wide record discriminated by `kind` rather than a union of
per-kind records. Teal can express the union but not a union that pools, and an
event stream that allocates per event is not one this engine can use. Records
handed to a handler are reused, so `events.copy` exists for anything that
retains one.

Unrecognised SDL events arrive as `unknown` carrying their numeric type instead
of being dropped, so upgrading SDL surfaces new input rather than silently
losing it.

A touch finger's identity is 64 bits and does not fit a double, so it is
carried as an opaque string, and so is the touch device it belongs to.
Reporting either as a number would round, and two distinct fingers could
collapse into one.

A recognised kind means usable fields. An event whose kind is named and whose
payload was left unread is worse than an unknown one, because the caller has
every reason to trust it, so text, composition, candidates, drops, the
clipboard, sensors, gamepad touchpads, displays, windows, pinches and user
events all convert their payloads. Several of those carry pointers into memory
SDL recycles as soon as the callback returns, so the C host copies those bytes
into the queue it owns and frees them when the queue drains. Retaining the
pointer is a use-after-free that reads as an occasional garbled string.

The vocabulary covers what a game can act on and stops there. Displays report
being added, removed, moved, reoriented, rescaled and remoded, each naming the
display it happened to. Windows report occlusion, entering and leaving
fullscreen, a display scale change and a safe area change, beside the states
they already reported. Keyboards, mice and audio devices report arriving,
leaving and being reformatted. A trackpad pinch arrives as `pinchBegin`,
`pinchUpdate` and `pinchEnd` carrying the factor it zoomed by, and counts as
player input for latency. What stays out is what this engine cannot act on: the
joystick family, because every pad is opened as a gamepad and forwarding both
would report one device twice; camera devices and the 2D renderer's device-loss
events, because neither subsystem is used; hit tests, because none is installed;
and ICC profile and HDR state, because there is no colour-managed path for a
game to respond through.

Every kind is drivable by name. `events.push` takes the engine's vocabulary
rather than an SDL union and fills the payload for the key, mouse, wheel, pen,
gamepad, device, pinch, window and display kinds, so the debug server's
`send_event` tool can occlude a window, move a display, zoom a pinch, scroll a
wheel or draw with a pen and have the game see what a real one carries. A kind
whose payload nobody injects is pushed carrying its type alone, which is honest
about the difference.

A mouse event the platform synthesised from a touch or a pen is marked as such.
Those arrive beside the finger events they were made from, and a game handling
both would otherwise act on one gesture twice.

Natural scrolling is normalised where the conversion happens, not left for each
reader to discover. SDL reports a flipped wheel by negating both axes and
setting a flag, so a game that read the pair without the flag scrolls backwards
on every machine with the setting on and nowhere else, which is the kind of
defect that reaches a player before it reaches a test. `wheelX` and `wheelY`
therefore mean one thing everywhere: positive is away from the player and to
the right. Beside them, `wheelTicksX` and `wheelTicksY` carry the whole notches
SDL accumulated against the platform's own threshold, so a menu stepping one
item per notch does not re-derive them from the fractional pair and disagree
with the rest of the machine about where a step begins.

That normalisation is drivable rather than only unit-tested. A pushed wheel
carries its axes the way the platform sends them, and `flipped` sets the flag
beside them, so a session or a test can scroll as a machine with the setting on
does and watch the signs arrive undone. The round trip is the conversion, not
the identity: what goes in flipped comes back negated, which is the whole point
of pushing it.

Where the platform has already done a piece of bookkeeping, the event carries
its answer rather than inviting a worse one above. A mouse button carries how
many clicks ran together, counted against the interval the player set. Every
pen event that reports one carries the full input mask, which is the only field
that says which barrel button is held rather than which end drew the current
stroke. A sensor reading carries the time the hardware took it, on the sensor's
own clock, since the interval between the events that delivered two readings is
the platform's scheduling and not the interval an integration wants.

The engine acts on lifecycle and input events and then hands every event to the
game anyway. An engine that consumed events would leave a game unable to tell
an event it never received from one it mishandled.

Every event carries an `arrival`: the performance counter as the host received
it from SDL, in the units `clock.now` reports. SDL's own `timestamp` is
nanoseconds on the `SDL_GetTicksNS` epoch, which orders events against each
other and against nothing else, so the host takes its own reading instead of
converting that one across an offset SDL does not promise. It is stamped where
SDL hands the event over rather than where a step picks it up, because the
interval between those two is the thing worth measuring.

## The clipboard

`clipboardUpdate` says the clipboard changed and lists the mime types now on
offer. `tecs.clipboard` is the other half: what those bytes are, and how to put
text there. Being told and having no way to look is the worse of the two
halves to ship alone.

Reads are not cached. The clipboard belongs to the desktop rather than to this
process, so a value read a frame ago may already be wrong, and the event is the
only invalidation there is.

Every read hands back an allocation the caller frees, and a failed read hands
back an empty string rather than nothing, so the free is owed on that case too.
`loader.toString` copies and does not free, which makes it the right converter
and half the job; the pairing lives in one place in `platform/clipboard.tl`
rather than at each call site, because a read that forgot would leak once per
paste and nothing about a process that grows while a text field is pasted into
points back at the clipboard.

Text goes out through `setText`, which SDL copies, so nothing is retained here
and the value's lifetime is SDL's from the moment the call returns. Offering an
arbitrary mime type is the one clipboard entry point that works the other way
round: `SDL_SetClipboardData` takes no copy, retaining a callback it calls when
some other application asks for the bytes, which may be long after the call
returned and is a moment this process does not choose. In Lua that is an FFI
callback pinned for the lifetime of the offer and entered from wherever SDL
fulfils the request, and [`physics/TaskPool.tl`](src/tecs/physics/TaskPool.tl)
already records why this engine keeps its callbacks native rather than take
that bet. Reading an arbitrary mime type carries none of it, so `mimeTypes`,
`hasData` and `data` are here and the offer side is not.

The primary selection is a second, independent clipboard rather than a flavour
of the first: X11 and Wayland fill it with whatever was last selected and paste
it on a middle click, with no copy step at all. Elsewhere there is no such
concept, and SDL does not fail there but keeps the value in the video device,
so `setPrimary` succeeds, `primary` reads back what this process wrote, and
nothing outside the process ever sees it.

The clipboard is part of SDL's video subsystem, so a headless tool has none.
`available` reports that, which is the only answer that separates no clipboard
from an empty one; the rest short-circuit to empty and false without calling
SDL, so a question that was never going to be answered does not overwrite the
SDL error a caller is about to read for some other reason.

Text is UTF-8 and passes through byte for byte. Line endings are not
normalised, so text copied on Windows arrives as CRLF and stays CRLF, and
nothing is trimmed from either end. Text stops at the first NUL, because that
is what terminates the C string SDL returns and what every producer of
clipboard text intends; `data` uses the length SDL reports instead, so a blob
keeps its NULs.

## Shelling out

A command line tool, a resource pipeline or an asset build wants to run another
program, and a game wants to do it between two frames rather than instead of
them. `tecs.proc` is that, and it is one of the few subsystems that is more
useful without a window than with one, so it initialises no SDL subsystem and
works under a plain interpreter.

```lua
local run = tecs.proc.run({ args = { "git", "rev-parse", "HEAD" } })
-- ... frames pass, the loop pumps ...
if not run:isRunning() and run:succeeded() then
    print(run.output)
end
```

**One shape, and it is run-to-completion.** The result arrives whole, once,
with the exit status beside it. The long-running child whose output you want as
it appears is a different API rather than a flag on this one: it has to answer
what a chunk is, what happens when a chatty child outruns its reader, and how
two streams interleave once they are delivered separately over time, and every
one of those is a guess here and a requirement there. The worker already reads
incrementally, so a streaming variant grows from that seam; until it exists,
output is accumulated whole and `timeoutMs` is what bounds a child that prints
forever.

**The child never leaves the worker.** `SDL_ReadProcess` reads to end of file
and a blocking `SDL_WaitProcess` waits for the child to exit, so on the main
thread either one is a stalled frame for as long as the program runs. A run
therefore goes out to a worker exactly as a decode does, and what comes back is
bytes, an exit code and a pid.

An `SDL_Process` could cross the way a decoded surface does, as an address with
ownership attached, and it must not. SDL documents `SDL_WaitProcess`,
`SDL_KillProcess`, `SDL_ReadProcess` and `SDL_DestroyProcess` as not thread
safe, and unlike a surface a process is not a block of memory whose ownership
can simply move: it is a pid that may be reaped exactly once, plus a set of
pipe descriptors. Two states holding it is two states able to reap it, and the
second reap lands on whatever pid the kernel has handed out since. The only
reason to move it would be to call something from the main thread, and every
call worth making there is one of those four. So the address stays on the
worker and the caller gets a copy of the output, which is the right trade at
this size: a decoded 4K texture is sixty-four megabytes and copying it twice is
the frame, while `git rev-parse` answers forty-one bytes.

**The worker polls, and that is what makes it interruptible.** Instead of
calling `SDL_ReadProcess` and disappearing for the child's lifetime, it asks
`SDL_WaitProcess` with `block` false and reads the child's pipes through the
non-blocking streams SDL hands out. Three things follow. A kill is a message
the worker picks up on its next pass, so the main thread can end a child it is
not allowed to touch. One worker holds any number of children at once, so a
second run does not queue behind the first. And a child that writes past the
pipe buffer keeps going, because something is draining it, rather than stopping
until someone reads.

**Teardown kills.** Reaping alone has no bound and a child that never exits
parks it; detaching leaves a worker running inside a library the process is
about to unmap, which is the failure
[`ffi/loader.tl`](src/tecs/ffi/loader.tl)'s `RTLD_NODELETE` already exists for.
So `proc.shutdown`, which the application runs at teardown, asks every live
child to stop, gives it a quarter second, and then forces it. A forced kill is
not refusable, so the join that follows is bounded by the kernel reaping the
child, and a handle whose child was still running ends at `"killed"` rather
than at a status that implies it finished.

**A failed spawn is a status.** A program that cannot be started resolves at
`"failed"` with `error` set, the way a failed decode resolves rather than
raising. A caller that shells out is already branching on the exit code, and a
spawn that did not happen is one more branch on the same value.

**Error output is separate by default.** `SDL_CreateProcess` inherits the
child's standard error, and interleaving diagnostics into standard output
corrupts anything parsing that output, so a run pipes both and answers them as
`output` and `errorOutput`. `mergeStderr` folds them for the caller who wants a
transcript. Creation always goes through `SDL_CreateProcessWithProperties`,
which is a strict superset: piping error output, a working directory and an
environment are reachable only there, and two creation paths would be two
places where what the child inherits is written down.

**Environment and working directory are exposed rather than hidden.** Both
default to inheriting, which is what a tool almost always wants; `cwd` sets the
directory, `env` sets variables over the inherited environment, and `clearEnv`
starts from an empty one so `env` is the whole of what the child sees. `input`
writes bytes to the child's standard input and closes it, which is what a child
reading to end of input is waiting for.

## The window

[`platform/Window.tl`](src/tecs/platform/Window.tl) is what SDL's window and
display API looks like in this engine's idiom, and the whole of it is reachable
from `Application.Config.window`, which is passed through rather than copied
field by field so a setting cannot exist in one place and not the other.

`getSize` is screen coordinates and `getPixelSize` is the drawable, and there
is no converter between them: one would have to pick one system as the real one
and silently reinterpret the other, where the pair says which is which at every
call site. `pixelDensity` is the ratio and `displayScale` is the desktop's own
scaling preference, which are different questions.

Events report a _change_; nothing reports the state a window started in. A
window created hidden fires no `windowHidden` and a window that has always had
focus fires no `windowFocusLost`, so `hasFocus`, `isVisible`, `isMinimized` and
the rest are how the first frame learns where it stands. They agree with the
events by construction, since each asks SDL rather than caching, and `id` is
what ties a window to the `which` an event carries.

Size, position, fullscreen, borders, opacity and visibility are all safe to
change while the device holds the window: the pass graph sizes its targets from
the swapchain texture it acquires each frame, so a change is picked up on the
next frame with no reconfiguration, and a hidden window acquires no texture and
the frame is skipped whole. Where a compositor answers a request later,
`sync` waits for it. Presentation pacing is not here: SDL's window vsync paces
the software surface, which cannot coexist with a claimed window, so a game
that wants it calls `Device:setPresentMode`. Message boxes are not here either,
being a blocking modal dialog whose one real use is a failure before or after a
window exists.

## Measuring latency

Frame time cannot see how long a player waits for a press to reach the screen,
and the two move independently: pipelining a frame buys throughput and pays for
it in latency. So the interval from arrival to submission is reported as stages
beside the frame stages, in one table, and it divides into three parts that sum
to the whole: `latencyWait` from arrival to the step that took the batch,
`latencyStep` for that step, and `latencyDraw` for drawing what it produced. A
regression is then attributable rather than merely visible.

Only frames that consumed an event are sampled, and a batch is charged to the
frame from its oldest event. A frame nobody was waiting on has no latency, and
averaging it in only makes the number smaller.

`make bench-latency` produces the number without a human at the keyboard. It
pushes synthetic events through SDL's own queue rather than through
`events.source`, so they are delivered to the host and stamped exactly as a
real press is: a replay source would skip the arrival stamp and leave the
harness measuring its own call. Presentation is submission, since the engine
knows when it handed a frame over and cannot see the display.
`BENCH_PRESENT=vsync` puts the display's own wait back into `latencyDraw`,
where it lands as a block in acquire.

## Input

Live state answers "is it held". Frame events answer "did it change this
frame". Latched events answer that for fixed-step systems, which is not the
same question: a key pressed and released between two fixed steps is invisible
to frame events, and losing it produces input loss that varies with frame
timing and so cannot be reproduced on demand. Latched sets accumulate across
every frame since the last fixed step and clear when it ends. The run loop
brackets the fixed phases itself, because that bracketing is the entire
mechanism.

Queries are answered relative to a layer. A blocking layer hides input from
everything beneath it, so a menu suppresses gameplay without gameplay code
knowing a menu exists. Code that names no layer reads the base layer, which is
the safe default: it goes quiet when anything is pushed over it.

A gamepad is not part of that state. It has identity, a lifetime shorter than
the process, metadata, capabilities that differ between devices, and outputs, so
it is an object reached through `input:gamepads()` and it answers for itself.
Two pads sharing one button set is not a simplification but a defect: pad A
releasing a button releases pad B's. Devices already attached are opened before
a game's `load` runs, because the platform reports additions and not devices
that were there all along.

A reference to a pad that went away is safe by construction rather than by
documented caution. The platform handle lives in one field, one function reads
it, and disconnection clears it before the handle is closed, so every method
takes its quiet branch: buttons read as released, outputs report failure, and
nothing reaches a freed pointer. A reconnect produces a new object, so an old
reference never comes back to life.

Buttons are named positionally: `south`, `east`, `leftShoulder`, `dpadUp`, and
axes `leftX`, `leftTrigger`. `south` is the button nearest the player on every
pad, where `a` is that button on some and the one to its right on others. What
is printed on the hardware is a separate question and `pad:label(button)`
answers it, because a prompt has to show the player their own controller.

Text input is off until asked for and is bound to a layer, so popping the menu
that started it stops the input method and takes the on-screen keyboard with
it. That is the case nobody remembers to handle. Composition is reported
separately from committed text, so a field draws what is being typed before it
commits, and an area is passed so the platform places its candidate window
clear of what the player is looking at.

A pen reports pressure, tilt and barrel rotation the way a pad reports a stick:
one axis event per reading, numbered by the platform. Those four are folded into
`penPressure`, `penTiltX`, `penTiltY` and `penRotation`; hover distance, the
barrel slider and tangential pressure are named by the backend and read by
nothing, so they are a line each to fold in when something wants them.

Held state clears on focus loss and on device removal. The platform delivers no
release for a key held as the window loses focus, and a button left held on a
device that is gone is worse than one that never worked. A pen carried out of
range clears its pressure for the same reason: nothing reports the lift.

Queries are never answered by polling the device. `SDL_GetKeyboardState` and
its relatives are read when a device is opened or resynchronised and never
after, because a poll bypasses replay, layers, edge detection and latching, all
of which are the point. The state is fed typed events and holds no globals, so
a recorded session replays by feeding the same events back through
`events.source`, and every outbound command goes through a backend for the same
reason.

## The Tecs binding

Tecs itself is unchanged and consumed as a dependency. What lives here is
tecs's own surface on top of it: components, a renderer that syncs from a
world, and a physics plugin.

`Renderer` is the bridge, and the only module that knows about both archetypes
and GPU buffers. Everything below it is renderer; above it is Tecs.

It is two halves and the seam between them, divided along the line the
simulation and render threads will fall either side of. `Extractor` is
world-facing: queries, archetype runs, relayout detection, dirty gating,
producers and the interpolation alpha, writing instances straight into mapped
staging and never touching a device. `Backend` is device-facing: the buffers,
the flush, the mark/scan/compact cull, the deferred pass graph and the image
array, and it names no world, query, archetype or component.

`FramePacket` is everything that crosses. It carries the staging slot that was
written, the byte ranges within it, the counts, a copy of the camera and the
frame's lights, and it carries no instance bytes at all: those are already in
the staging the backend owns, and copying them into a packet would be the
intermediate copy the design exists to avoid. Nothing in it refers to a Lua
object, so it becomes a native slot struct rather than being rewritten when the
two halves stop sharing a heap.

`Renderer` is what still sees both. It owns the packet, rotates the staging
slot, hands the backend's mapped addresses to the extractor, and centres the
camera on the first frame that draws, which is the one thing needing a target
size on the side that has no device.

Images live in one array texture, so the texture is a per-instance layer index
and the whole scene is one draw. That is also what frees the instance layout:
with nothing to sort by, each archetype keeps a contiguous run, and a run whose
components did not change is not rewritten.

That gating is the point. Walking every entity every frame is the cost that
decides whether a large world is affordable, and most frames change very
little. A still scene resyncs nothing at any size:

```
 4,000,000 entities, static      frame
 ──────────────────────────────  ────────
 world the size of the view      80.1 ms
 world 4x the view               21.1 ms
 world 8x the view               11.7 ms
 world 16x the view               7.0 ms
```

Four million is the ECS's ceiling: an entity id packs its slot into 22 bits.

### Runs pack, or reserve

Packed runs are laid end to end, so the extent is the rows and nothing else,
and so a run cannot grow without shifting every run after it. One spawn
anywhere therefore lays the whole scene out again and rewrites every instance
in it. `reserveRuns` on the renderer is the other layout: each archetype's
run is given room to grow into, a run that outgrows its room is moved to the
end rather than shifting its neighbours, and the slots nothing occupies are
written once as hidden. Hidden is what `gfx.text` already does with a glyph
slot it holds and is not drawing: the instance zeroed, the depth parked at the
back of its band, and a cull bound out where no finite view overlaps it, which
the mark pass rejects before the compaction that feeds the draw. A spawn then
rewrites the archetype it spawned into, and leaves every other archetype
resident.

A world of 200,000 still sprites with a spawner touching 64 of them a frame,
which is the shape of most games:

```
 layout    extract p50  extract p95  instances rewritten per frame
 ────────  ───────────  ───────────  ─────────────────────────────
 packed        1.420 ms     1.829 ms  200,032 mean, 200,064 peak
 reserved      0.092 ms     0.270 ms       32 mean,      64 peak
```

What it costs is the slack. The cull is dispatched over the extent rather than
over the rows, so that scene dispatches 217,000 threads where the packed one
dispatches 200,000, and a hidden slot costs a bounds read and a lane in the
mark pass and never reaches the draw. A run is given sixteen slots when it is
first laid out and a quarter of itself once it has outgrown a reservation, so a
still scene occupies what it occupies and a growing one is reallocated on a
geometric schedule. The extent is compacted when it has drifted half a layout
above what a fresh one would need; the trigger is measured against that fresh
layout rather than against the rows, so a compaction cannot ask for another
one. Slack is only ever what is left over after the rows: a compaction lays out
with the widest reservation the capacity affords and packs exactly when it
affords none, so `dropped` trips at the same population it trips at packed.

What still bounds it is the ECS, not the layout. Moving a row into an
archetype marks every one of that archetype's columns dirty, so a spawn
rewrites the destination archetype's whole run whatever the runs are laid out
like. Where a scene keeps everything in one archetype, that is the whole scene
again and reserving buys nothing.

What is drawn is decided on the GPU. A compute pass tests each instance against
the view, compacts the survivors into an index list, and writes the draw
arguments, so the draw touches only what is visible and the CPU never learns
how many that was. The first row above is the case the cull cannot help with,
where the whole world is on screen; there it costs about a sixth of a frame
for nothing. Every other row is what a world larger than its window looks
like.

Populate with `world:batchSpawn`, not a spawn per entity. A single spawn
resolves an archetype, allocates an id, and moves a row every time it is
called; in bulk that is the difference between fifteen milliseconds and nine
seconds. The callback writes columns in place, so no component values are
constructed at all. Note that `batchSpawn` skips FFI defaults, so every field
has to be written in the callback.

Every image lives in one 2D array texture, bound once, with the layer as a
per-instance float. That is not a workaround for the absence of bindless: it is
the only thing SDL_GPU offers, and it will stay so. SDL lists bindless among the
features it has chosen not to support, on the grounds that it would need large
changes to every backend and to the shader tooling, that the only technique
strictly requiring it is hardware raytracing, which the GPU API is also unlikely
to gain, and that debugging tooling for bindless renderers is immature. They
would rather design a future API around it than graft it onto this one. So the
constraint is architectural rather than a gap waiting to close. It is also worth
keeping in proportion: resource binding was the only way to write a renderer for
over twenty years, and only a minority of shipped games use bindless today.

Layer zero is a white pixel, so an entity with no `Sprite` samples it and
textured and untextured geometry share one shader and one pipeline. An image
smaller than a cell does not reach the cell's edge, so `registerImage` returns
a ready `Sprite` rather than a bare index: a caller guessing the UV range
would sample the undefined remainder.

What a caller sees is a sub-rect of a layer rather than a layer, which is what
makes packing possible. One image a layer costs a whole cell for a sixteen-
pixel icon and caps the process at one distinct image per layer;
`packImages = true` turns on a shelf allocator that fits many into each, and
the ceiling becomes the array's area rather than its layer count. An image
takes the shortest open shelf that is tall enough and has room, so a tall shelf
is not spent on a short image; failing that a shelf opens below the last, and
failing that a new layer starts. Shelves suit sprite work because frames of one
sheet are the same size and arrive together, and the waste is the difference
between an image's height and its shelf's.

Every placement carries a one-texel gutter on all four sides, written as a copy
of the image's own edge rather than left undefined, so two images are two texels
apart and a filter that reaches past an edge finds the colour that was already
there. The rect a caller samples is the image's own texels and never the gutter,
so a neighbour packed beside it is unreachable however the sub-rect inside it is
narrowed. Nothing is reclaimed, which is the same bargain the unpacked path
makes.

If the layer count ever becomes the binding constraint again, SDL allows up to
sixteen texture samplers bound per stage, so binding several arrays and
branching on the slot index in the fragment shader would multiply the ceiling
without needing bindless. That composes with packing rather than competing with
it, since packing raises images per layer and this would raise layers. It costs
a divergent branch in the hot fragment path and more live bindings, and it is
not built: packing alone takes the ceiling well past any realistic scene, and a
second mechanism is worth it only if a measurement says so.

A `Sprite` names its image; which layer that name occupies is the renderer's
answer to it. Layers are handed out as images register, so a layer number
means whatever loaded in that position, and one written into a snapshot is a
different image the moment the assets load in a different order. So a snapshot
stores the name, `registerImage` keeps a registry from name to layer, and
registering a name twice answers with the layer it already holds instead of
consuming another. The name is the path rather than the spelling of it: a name
is normalised before it becomes an identity, so `a/b.png` and `a/./b.png` are
one image and not two layers holding the same pixels. Only what a spelling
cannot disagree about is dropped, which is repeated separators, `.` segments
and a trailing separator. Nothing there reads the filesystem, so a name
normalises the same before its file exists as after, and `..`, letter case and
the asset root are all left alone: resolving any of them lexically would merge
two names that are two different files, or make an identity depend on where the
process was looking when it was asked. The layer is cached in the `Sprite` when it is built, or on
the first frame that writes a restored one, because extraction reads it for
every row and a lookup per row is a lookup too many. A name nothing is
registered under fails rather than drawing whichever image holds that layer.

That failure is found deep inside a query cursor, so it is recorded and raised
after the cursor closes rather than thrown through it. An error thrown through
one leaves the world deferred, and every spawn made after that queues in
silence: the frame would take the world down with it instead of only itself.
Raised after, the world is whole, and a caller that registers the image draws
on the next frame. The lazy resolve is also why this cannot be moved to load
time: a snapshot legitimately restores before the images it names have
finished loading, so the first frame that tries to draw the row is the earliest
point anything can tell.

Its sync reads columns with `get`, never `getMut`. Taking a mutable column to
read would mark those components dirty on every archetype every frame, which
defeats every dirty-gated consumer downstream. That distinction is the single
easiest thing to get wrong here and the hardest to notice.

Syncing runs in `RenderFirst` inside the world's update; rendering happens
afterwards against a frame. The two stay separable because the sync needs no
command buffer and the render needs no world, which also means the swapchain
is held for as little of the frame as possible.

## Sprite sheets and playback

The model is Aseprite's, because that is what the art is authored in. A sheet
is a list of frames, each holding for its own duration; a set of named tags,
each an inclusive span of frames played forward, in reverse, or pingpong; and a
set of named slices carrying rectangles, nine-slice centres and pivots that
move from frame to frame. Tag zero is the whole sheet, forward.

Reading an Aseprite JSON export is one function in front of that model rather
than a second model: `sheet.fromAseprite` walks the export and writes what it
finds through the same builder everything else uses, so a reader for the binary
`.aseprite` format populates the same sheet without reshaping anything. Both of
Aseprite's frame layouts are read, the array and the object keyed by frame name,
the second in sorted name order because the names carry the frame number.
Trimmed exports are not: `spriteSourceSize` is ignored, so export with trimming
off.

`sheet.build` is the model's own front door, for an atlas from any other tool:
frames, tags and slices in any order, `finish` to register. `sheet.grid` cuts a
uniform grid (with an optional margin around it and spacing between the cells)
and `sheet.rects` takes an explicit list, and both are that builder with a loop
in front.

Timing is per frame rather than per entity, which is the thing a single frames-
per-second number cannot express: a hold frame is a frame with a long duration,
and that is how an artist writes one. Durations are authored in milliseconds
because Aseprite writes milliseconds, and converted to seconds once when the
sheet is built so playback never divides. What an `Animation` carries instead is
a `speed`, a multiplier on the sheet's own timing, so changing it leaves
playback on the frame it was showing rather than jumping.

A tag's direction is spent when the sheet is built rather than at every step of
playback. What comes out is the frames in the order they are shown and the
second each one ends on, so finding the current frame is a scan of numbers and
never a branch on direction, and pingpong is a longer list rather than a special
case. Pingpong repeats neither end, so a three-frame tag is 1, 2, 3, 2 and its
cycle is four frames long.

Slices are where pivots come from, rather than an origin API invented beside
them. A slice holds a key until the next one, so `Sheet:pivotOf` answers the
key in force on a frame, adds the slice's own origin, and divides by the frame:
what comes back is a fraction of the frame, so nothing downstream has to know
the sheet's pixel sizes. A slice with a nine-slice centre but no pivot answers
the middle of that centre, one with neither answers the middle of its own
rectangle, and no slice at all answers the middle of the frame, which is where
a quad sits with no pivot.

What reads that fraction is the `Pivot` component. It says where the quad hangs
off itself, and the entity's position is where that point lands: a character
pivoted at its feet stands at its position rather than hovering half a body
above it. `Sheet:pivot` resolves a named slice and stays bound to it, so
playback moves the pivot whenever the frame changes, which is what a slice with
several keys asks for; a pivot written directly is left where it was put. The
component lives with the sheet because a slice index is this run's answer and
naming it again for a snapshot needs the sheet registry, which is here.

The instance grows by nothing to carry it. A pivot is an affine shift of the
very basis the vertex shader applies, so moving the quad's middle by
`-basis * pivot` places every corner exactly where `corner - pivot` would;
extraction folds it into the origin and the shader is untouched. Sending it
instead would need a fifth `vec4`, which is sixteen more bytes streamed for
every instance in the world to say something almost none of them have anything
to say about. Two things follow the quad and one deliberately does not: the
cull bound is centred on the quad rather than on the entity, so it stays exactly
as big as it was instead of growing to cover a shift already known on the host;
and the depth sort still runs on the entity's position, which is the whole
reason a pivot at the feet is worth having, since two characters standing on
the same line then sort together however tall either drawing is.

The bound is exact for every pivot the host knows, which is every one written
directly and every slice with a single key. A slice that moves between frames is
resolved in the shader and the bound grows by the slice's own travel to cover it,
which is the one qualifier on the paragraph above and is worked out below.

A sheet is data, not a component: a hundred entities drawing one character
share one sheet and point at it. What the `Animation` component carries is the
sheet's registration index and the index of a tag within it, because a
component is plain C memory and a sheet is a table. Both indices depend on the
order sheets were built in, so a snapshot writes the pair of names instead and
resolves them again on the way back, for the reason a `Sprite` writes an image
name rather than a texture-array layer.

Two coordinate spaces meet in a sheet and only one of them is its business. A
frame is written in pixels, because that is how an image is cut up. What a
`Sprite` carries is a region of a texture-array layer, which is the frame's
fraction of the image scaled by the fraction of the layer the image occupies.
That second fraction is the renderer's answer, so `sheet:bind` takes what
`Renderer:sprite` returns for a whole image and rescales every frame once.
Before it, a frame's region is its plain fraction of the image, which is what a
sheet can say without a renderer and what makes one testable headless.

There are two paths from an `Animation` to a picture and `animation.useGPU`
chooses between them. The rest of this section is the host one, which walks every
playing animation on every fixed step and writes the frame's region into the
entity's `Sprite`; the section after it is the one that defaults on, which writes
what is playing and lets the shader work the frame out. They agree on the frame
and differ on what they write to reach it.

Playback advances in `FixedPostUpdate`, not per frame, because animation is
simulation: two machines fed the same recording have to show the same frame,
and a system driven by frame time shows a different one on the machine that
drew more frames. The system is handed the fixed step and never reads a clock.
`FixedPostUpdate` is late enough that gameplay logic in `FixedUpdate` has
already chosen what should be playing.

`Animation.frame` is the frame the `Sprite` was last written from, which is
what turns the write into a gate: a step that leaves an entity on the frame it
was already showing writes nothing, and an archetype where no frame changed
leaves its `Sprite` column clean for the sync to skip. So the column is taken
with `getMut` the first time a row is actually written and not before, and
`Animation` and `Sprite` are gated separately: time moves every step, regions
do not. Zero means nothing has been written yet, which is how a fresh or
restored animation gets its region on the first step rather than drawing
whatever its `Sprite` held.

That same field is what keeps a still sprite cheap. A row whose time did not
move shows the frame it already showed, so the step asks the sheet nothing:
only time advancing, a row that has never had a frame, and a sheet bound to
another image since the row was written send it down the long path, and all
three are comparisons where the long path is a scan of the tag's cycle and a
handful of writes. Without it a world where a hundredth of the sprites animate
costs nearly what one where all of them do costs. The gate above it is still per
archetype per component, so one playing animation marks the column every still
sprite beside it lives in: this cuts the walk, not the rewrite.

A frame is a region of an image, not a region on its own, so a step that
writes one writes the layer with it. Which layer is compared rather than
assumed to follow the frame index: a sheet swapped under an entity can land on
the index the last one left behind, and the quad would go on sampling the old
image with the new rect. A sheet with no image bound writes the region alone
and leaves the `Sprite` whatever it carried.

A tag that does not loop parks on its last frame, stops, and emits
`animation.Completed`; a looping one wraps and emits `animation.Looped`. Both
go to address zero with the entity in the payload, matching `OnSpawn` and
`OnDespawn`, which lets the system ask the bus once per step whether anyone is
listening rather than once per entity that finished.

Finding a parked one-shot playing means something set `playing` back to true,
which reads as asking for the animation again, so it starts over. Advancing
from the end instead would park it again on that step and on every step after
it, emitting `Completed` each time. `animation.restart` is the explicit form
and also rewinds one that has not finished; `animation.play` is for pointing an
entity at a different sheet or tag.

## Playback on the GPU

The gate above cuts the walk and not the rewrite, and the rewrite is what
decides whether a large animated scene is affordable. One animating sprite marks
the `Sprite` column of the archetype it lives in, and a dirty column has its
whole run rewritten and uploaded, so two thousand animating sprites in a field
of two hundred thousand cost two hundred thousand instances written. That is
measured rather than argued: `make bench-sprites` reports it as `rewritten`, and
the sparse regime exists to show it.

Playback therefore resolves in the shader, which is what `animation.useGPU`
selects and what it defaults to. The instance's region fields stop carrying a
region and start carrying enough to compute one: which animation is playing, the
fixed step it began on, and how many ticks of clip time it advances per step. A
frame changing then writes nothing at all, and what a step costs is what actually
changed rather than what is shaped like it. At two hundred thousand sprites all
animating, `rewritten` goes from a mean of eighty-five thousand per frame to
zero, and the frame time lands on what a scene of the same size that never
animates costs.

What makes it fit in the instance is that it needs no room. A region is four
floats and a playback is four floats, and no region is ever negative, so the
sign of the first says which is which for one comparison and no memory traffic.
The instance stays at sixteen floats, which at four million is 256 MB either
way: a fifth `vec4` would have been 64 MB a frame to say something most
instances have nothing to say about, which is the same argument the pivot fold
already makes.

What it resolves against is `src/tecs/gfx/frametable.tl`, one buffer holding a
directory, a tick table and the frame regions. A tick is a millisecond because
that is the unit the model is authored in, so every boundary an artist can write
lands on a tick and the table reproduces `Sheet:frameAt` exactly rather than
approximately. That makes a lookup constant time whatever the tag holds: one
directory read, one tick read, one region read, and no loop. A scan of
cumulative durations would cost the length of the tag, in the vertex shader,
once per vertex, for every pass that draws the sprite.

The clock is the world's count of fixed steps, from `world:fixedStepCount`,
carried in the frame packet and pushed in the spare component of the layer
uniform. Steps rather than seconds is what keeps playback on the simulation's
clock: two machines fed the same steps show the same frame however many frames
either drew, which is the property the host path has and the reason it runs in
`FixedPostUpdate`. It also costs no binding and no second push, because that
block is already sent every frame.

Resolution lives in `assets/shaders/include/playback.glsl` rather than in the
vertex shader, because it will have more than one caller. An occluder pass takes
a silhouette from the same texture at the same region, a drop-shadow pass draws
a stretched copy of that silhouette, and an animated light cookie needs a frame
too. All of them have to arrive at the same frame, so the include takes the
playback and the clock as parameters and declares its buffer behind a define
pair: a second caller needs no edit to it. The rule that goes with it is to
resolve at the point of use and never carry a resolved region from one pass to
another, because a buffer of regions written by one pass and read by the next is
what makes a shadow lag the sprite casting it.

What writes the encoding is `tecs.EncodeAnimation`, in `PostUpdate`, gated on
the `Animation` column's own dirty bit. That bit is set by exactly the things
that change what is playing: a spawn, an archetype move, `play`, `restart`, and
any direct write. So a step where nothing changed visits no archetype, and a
`batchSpawn` or a snapshot load is encoded on the first update after it without
either knowing this exists. The phase is `PostUpdate` rather than a render one
so it lands before extraction whatever order the plugins were installed in.

The encoder anchors on the step count the update began on rather than the one it
reached, because `Animation.time` is the phase before that update's steps ran: an
entity spawned between two updates, and a snapshot loaded between them, were both
written before the fixed loop. Anchoring on the count after it would make a
playback's phase depend on how many fixed steps happened to fall inside the
update it was first seen in, and two machines fed the same steps in differently
sized updates would show different frames.

What it reads for the phase is the encoding the row already carries, not
`Animation.time`. Nothing advances `time` on this path, so it is the phase the
entity was last started from and it stays there; reading it would send an entity
back to that phase every time anything re-encoded it, and an archetype move
re-encodes everything it moved because a move marks every component on the
destination dirty. Adding an unrelated component to a walking character would
rewind its walk. Reading the encoding instead makes a freeze, a thaw and a speed
change hold their position too, since all three are that same re-encode: pausing
holds the tick the entity was on, resuming rebases from it, and a new rate is
applied from where the cycle is rather than from where it began.

`Animation.frame` is what says a row was reset rather than merely re-encoded.
`play`, `restart`, `of` and `deserialize` all write zero and nothing else does,
which is the job the field already had; the encoder writes a value no sheet
numbers a frame, so the field keeps its zero and stops pretending to be an index.
Which frame is showing is `animation.frameOf` on either path.

The one thing a re-encode cannot hold is a one-shot nothing is listening to.
`playing` is what parks it, `Completed` is what clears `playing`, and with no
subscriber it stays true, so past its end and playing reads as asked-again either
way and the entity starts over. Carrying `AnimationEvents` parks it and a
re-encode then holds it on the last frame.

Pausing has to be said rather than assumed, because the world's clock does not
stop for one entity. A rate of zero means held, and the second field then
carries the tick to hold instead of the step playback began on. `Paused` moves
an entity to another archetype and a move marks every component on the
destination dirty, so the freeze and the thaw both arrive at the encoder without
anything having to notice them.

### The pivot that follows a moving slice

A pivot bound to a slice moves as the frame does, and the host cannot fold it
once when it is the shader that knows the frame. What it folds instead is the
middle of where the slice goes over the cycle, and the frame table carries each
step's offset from that middle; the shader subtracts the offset from the corner,
which is two multiply-adds on a basis it has already built.

The middle rather than the pivot is what keeps the cull bound honest. A pivot
written directly and a slice with a single key both offset nothing on every
frame, which is `Builder:slice` and every Aseprite slice that does not move, so
their fold and their bound are bit for bit what they were. Only a slice that
genuinely moves pays, and it pays exactly its own travel: `Pivot` carries `halfX`
and `halfY` beside the point, extraction grows the half extents by them, and the
bound stays conservative in the direction that can only keep an instance the cull
might have dropped.

The slice is therefore part of a playback's key alongside the sheet and the tag,
because two playbacks of one tag bound to two slices want different offsets for
the same frame. The `Pivot` column joins the encoder's gate for the same reason:
pointing an entity at another slice changes which playback it is on and nothing
about its `Animation` moved to say so.

### Events, derived rather than observed

Whether an entity crossed its cycle during a window of steps is a function of the
start and the rate its `Sprite` already carries against the step count, so
`tecs.ReportAnimation` reads two columns and writes nothing: no `getMut`, no
dirty column, and no run rewritten because a crowd of animations wrapped. The one
write is the flag a finished one-shot parks behind, on the step it finishes and
never again.

Which entities it walks is an opt-in, `animation.AnimationEvents`. That is what
keeps the walk small: the handful a game listens to sit in an archetype of their
own and the crowd is visited by no query at all. Keeping full host playback for
the subscribers instead would be worse, and for a specific reason: those entities
share archetypes with everything else of their shape, so writing their `Sprite`
column rewrites those runs, which is the same cliff at a smaller scale and lands
on the archetypes a game cares most about.

### Asking what an entity is showing

`animation.frameOf` and `animation.timeOf` recompute on the call, against the
same tick tables the shader reads, through the `Sheet:frameAt` that already
exists. No walk, no column and no readback. A few hundred calls a step is free;
it stops being free somewhere in the tens of thousands, which is a game asking a
question this is the wrong shape for. Both answer from wherever the path they are
on keeps the answer, so a case that asks which frame is showing reads the same on
either side of the flag.

The two paths anchor a fresh entity's cycle to the same step and agree frame for
frame, except within a millisecond of a boundary: one reaches the boundary by
accumulating a step at a time and the other by multiplying a step count, and
which side of it they land on is then a last-place difference. That is a display
difference of well under a fixed step and it cannot reach simulation, because
gameplay reads `frameOf` rather than the GPU's answer.

`animation.useGPU(false)` puts playback back on the host, for a world that wants
events and frame queries without opting in or recomputing and is small enough to
pay a walk of every animation on every step.
`../tecs-plans/gpu-animation.md` is the design.

## Buffer writes

SDL_GPU has no mappable device buffer. Data reaches one by being written into
a mapped transfer buffer and copied across in a copy pass, and the transfer
buffer must be unmapped before that copy is encoded. That staged copy is
unavoidable.

What is avoidable is a second one. `Buffer:map` returns the driver's own
address, so a producer walking archetype columns copies straight into it
rather than filling a staging array that then has to be copied again.
`mapAs` gives the same memory as a typed array, for writing struct fields in
place.

Writes are tracked as ranges rather than replacing the whole buffer, because
most frames change very little of what is resident. Adjacent writes merge;
past a fixed number of distinct spans the dirty region collapses to one,
trading bandwidth for bounded bookkeeping but never dropping a range.

The destination is never cycled. Cycling discards a buffer's contents, which
would erase every range a frame did not rewrite, and that failure looks
exactly like a bug in whatever reads the buffer later rather than like an
upload problem. `flush` takes the caller's command buffer so the copy is
ordered against the frame that consumes it instead of racing a separate
submission.

## The pass graph

Passes name the targets they read and write. The graph owns those targets,
resizes them with the frame, begins and ends each pass, and binds each pass's
inputs as fragment samplers, so a pass body only draws.

Execution follows declaration order rather than a topological sort. The order
of a deferred pipeline is a design decision, not something worth rediscovering
every frame, and a graph that silently reorders is harder to reason about than
one that refuses to run. Declared inputs are validated against what earlier
passes produce, so a missing dependency is an error when the graph is built
instead of a black screen later.

The graph knows nothing about entities, archetypes, or dirtiness. A pass that
should be skipped says so through `enabled`, which is where an ECS-side dirty
gate plugs in without the graph learning what dirty means.

One depth attachment is shared by whichever passes ask for it, sized and resized
with the frame like every other target. Its format is discovered rather than
assumed: Metal has no `D24_UNORM` and a Vulkan driver may have that one and not
`D32_FLOAT`, so the device is asked which of the three it supports as a depth
target and the best answer is taken. What is taken is then checked against what
the sort needs, because the fallback is otherwise the quietest defect in the
engine: `D16_UNORM` steps by 1.5e-5 and the layer bands resolve to 9.3e-7, so a
device that offers only the floor keeps the bands and loses the sort inside
them, and everything within about sixteen world units of anything else draws in
the order it was written. That is reported rather than raised. A layer sorted by
z alone resolves in `D16_UNORM` with room to spare, and so does a game whose
world is smaller than the default extents; refusing the depth target would take
a device those scenes are correct on and leave it with no picture at all. Depth
state is declared per pass, because a
pass that must not have an attachment is as ordinary as a pass that must, and a
pipeline bakes its target info, so the graph answers both cases through
`depthOf` rather than leaving the call site to assume one.

`Deferred` assembles the standard pipeline on it: geometry fills a G-buffer,
lighting resolves it against a storage buffer of lights, and composite puts the
result on screen. Geometry is a callback because what to draw is the caller's
problem. Deferred is what makes light count independent of object count:
geometry rasterises once regardless of how many lights touch it, and lighting
runs once per pixel regardless of how many objects overlap it.

Geometry is the pass that owns depth, testing and writing, so wherever two
instances overlap the nearer one is what the G-buffer keeps. An instance's depth
is the fourth float of its transform vector, and the comparison is
`lessOrEqual` rather than `less`: equal depths let the later fragment through,
so draw order still decides ties and depth only decides between instances that
differ. Lighting and composite have no attachment. Each covers every pixel
exactly once and has nothing to be occluded by.

## Layers

A `Transform` carries a layer, and a layer is a band of that depth range.
Everything on a layer sorts within its band and never against another one, so a
HUD on layer 8 covers a world on layer 1 whatever the world contains.
`layers.configure` says what a layer does with its contents: how they sort
within the band (lower on the screen, by z alone, or by both axes for a diamond
grid), where they are positioned, and whether they are lit.

Positioning is four cases and one multiplier. Screen-space contents are placed
in pixels and ignore the camera; virtual-coordinate contents are placed in a
fixed design resolution scaled to fill the target; ignore-zoom contents follow
the camera's position but not its scale, so they hold their size on screen;
parallax multiplies how far the camera's position carries them. Unlit contents
bypass the lighting pass, which the material can also ask for, and a fragment is
lit only where the material and the layer agree.

The vertex shader recovers an entity's layer from the depth already in its
instance rather than being told it: `depthOf` writes `(MAX - layer) / MAX` plus
a within-band offset strictly narrower than a band, so multiplying by `MAX`
leaves `MAX - layer` as the integer part exactly. That keeps the instance at
four vec4s. What the shader is told is a uniform of sixteen entries and the
camera's parameters, rather than a matrix per case: parallax multiplies the
camera's position, so a precomputed matrix would have to exist per layer and be
rebuilt every frame the camera moved, while the camera's position, its
reciprocal zoom and two clip scales compose all four cases in a handful of
instructions and leave the table itself constant between the frames that
configure it.

The cull tests a world bound against the world rectangle the camera sees, which
only means something on a layer the camera places where that bound says. A layer
that asks for screen space, virtual coordinates, parallax or ignore-zoom is
given a bound no view can be outside of, so it draws whatever the camera is
looking at. That gives up culling on those layers and keeps it exactly on every
layer that does not ask, which is where the entities are.

## Clip regions

A `Clip` names a rectangle an instance's fragments are kept inside, and
`Renderer:setClipRegion` says what that rectangle is. The rectangle is in
target pixels, tested against `gl_FragCoord`, which is what a scrollable list
inside a panel means and what is right for world contents and screen-space
layers alike. Regions do not nest: a region is one rectangle, so a panel within
a panel is set up as the intersection of the two and the fragment tests once.
`clearClipRegion` puts a region back to clipping nothing, so an index handed
out and taken back leaves instances still pointing at it drawing whole rather
than silently gone.

The index rides in `origin.z` beside the texture-array layer, as
`clip * 64 + layer`. A layer is a small integer bounded by the array's 64
slots, and a float32 represents integers exactly to 16,777,216, so the largest
value the pair packs is 16,383 and both halves come back out exactly: the
shader takes the layer with a modulo and the region with a division. That keeps
the instance at four vec4s, which is the point. `instancelayout` owns the
packing so the renderer's sync and the text producer state it once between
them.

Not clipping costs nothing. An archetype with no `Clip` column is written by a
loop that never mentions a region, and the float it writes is the layer as it
always was. In the fragment shader the index is a flat varying, so an unclipped
instance takes a branch its whole primitive agrees on and never reads the
region table; and the test lands on the coverage the material already returned,
leaving through the `discard` that was there for distance fields rather than
adding one.

The cull knows nothing about regions. An instance entirely outside its region is
drawn and thrown away a fragment at a time, which is correct and wasteful;
rejecting it belongs in `instance.mark.comp.glsl` beside the view test, and is
not built.

## Shapes are materials

A shape is not geometry. Every entity is the same quad, and a `Material` names
the fragment function that decides which part of it exists: `circle`, `ellipse`,
`ring`, `rounded`, `frame`, `capsule`, `line`, `pie`, `triangle` and `star`,
alongside `textured`, which is the image's own silhouette, and `glyph`. They
are compiled into one fragment shader with a generated dispatch, so a scene of
shapes is still one batch, one cull and one draw, and a shape is one entity
rather than the several a fan of triangles would need.

`textured` takes its coverage from the texel's alpha, at a threshold of a
half. That is what makes a cut-out sprite a cut-out: the geometry pass writes
depth and does not blend, so a fragment that survives claims the pixel, and a
quad that covered its whole rectangle would hide whatever stood behind the
transparent part of the image as well as painting over it. The test is on the
texture's alpha rather than on the product with the tint, so an entity with no
`Sprite` samples the opaque white layer and draws at whatever tint alpha it
carries. The threshold is a half rather than any nonzero alpha because
coverage here is a yes or no: a texel kept at low alpha would land at full
strength as a dark fringe rather than as a soft edge. Smooth edges want either
multisampling or a forward-blended path, both of which follow depth.

Each answers with a signed distance rather than a yes or a no. Positive inside
and negative outside, in the quad's own coordinates, which run -0.5 to 0.5
across it however large the entity is drawn: nothing is measured in pixels and
nothing is sampled, so an edge is as exact at five hundred pixels as at five. It
is also what an antialiased edge is computed from, since the rate a distance
changes across a pixel is what a boolean throws away.

A material gets one parameter, a ratio from zero to one, because the instance
packs the material's id and its parameter into a single float: the integer part
selects and the fraction carries. So each shape spends it on the one thing the
transform cannot say. Scale already gives a shape its width and height and
rotation aims it, which is why `triangle` takes no parameter at all; `ring`
spends it on the hole's radius, `frame` on the border's thickness, `capsule` and
`line` on thickness, `pie` on the swept fraction of a turn, `star` on how deep
the valleys between its points cut, and `ellipse` on its height as a fraction of
the quad's, so an entity scaled evenly can still be an ellipse. A shape that
genuinely needed two would need the instance to grow, which is a decision about
every entity in the scene rather than about that shape.

`line` is the one whose parameterisation is worth stating: it runs along the
quad's diagonal, so placing it at the midpoint of two points and scaling it by
their signed difference draws the segment joining them. A negative scale mirrors
the quad and takes the diagonal with it, so either direction works without the
material knowing which.

## Text is a producer's run

A `Text` names a font and a string, and a system in `PostUpdate` lays it out
into instances. The glyphs are not entities: the text plugin registers an
`InstanceProducer` with the renderer, which lays a producer out as its own run
after the archetypes and asks it which sub-ranges changed. A glyph is still a
quad with a UV rect addressing its cell of the font atlas and a material
selecting the distance-field shader, so extraction, culling, the indirect draw,
layers and depth all apply to it exactly as they apply to an entity, and a text
on a screen-space layer or moved by a parent works without any of the text code
knowing about either.

An entity per glyph is what a producer is here to avoid, and the reason is the
dirty model rather than the entity. Dirty is per archetype per component, so
every glyph in the world would share one archetype and editing one string would
rewrite all of them; and spawning or despawning a glyph moves an archetype's
length, which relays the whole scene out. Measured at four thousand short texts,
editing a single string rewrote sixty-four thousand instances that frame.

The glyph is a multi-channel signed distance field. The median of the three
channels is the signed distance to the outline, and scaling it by how many
screen pixels the field's range covers is what keeps the outline exact at any
size: the quad grows and the threshold stays on the curve. The material
reconstructs the field bilinearly itself, because the shared image sampler
reads nearest and the median has to be taken after interpolation; taking it
first collapses three channels into one and loses the corners they encode,
which is exactly where a glyph has its sharp features.

Each text owns a span of the producer's run, and spans come from a size-bucketed
free list: allocating takes an exact-size span off the free list when one is
there and extends the high-water mark otherwise, and freeing hands the span back
to its size's list. That is chosen for damage numbers, where short strings of
the same length appear and disappear constantly and reuse each other's spans
exactly, so the run's length settles and nothing relays out. Fragmentation is
the tradeoff, since a span freed at one length is only reclaimed at that length;
compaction is the answer if a measurement ever shows it mattering, and there is
none until one does.

A span outlives its text unless something hands it back. Despawning is observed
and `world:remove` is not, so the plugin records which entity holds each span
and sweeps the ones whose entity no longer carries the same `Text`. The sweep is
gated on there being more spans held than there are texts to hold them, and on
those two counts having moved since it last ran, so a scene keeping texts out of
the query by disabling them is walked once rather than every frame. A removal
hook in the ECS is the deeper answer and a much larger change; a walk of the
spans in hand costs nothing while nothing is being removed.

The producer keeps its own copy of the instances, so a layout writes into
ordinary memory and the renderer's sync is a bulk copy of the ranges that moved.
A glyph carries an absolute position, so a text composes its own transform onto
the glyph offsets and a text whose `Transform` moved is as stale as one whose
string changed. Layout runs every frame and almost no text changes, so it is
gated twice: an archetype whose `Text`, `Tint` and `Transform` columns are all
clean is skipped whole, and within a dirty archetype a row whose authored fields
and transform match what its glyphs were built from is skipped too.

## GPU-driven by default

`make run` animates 512 instances and issues exactly one dispatch and one
indirect draw per frame. Per-instance data lives in a storage buffer that a
compute pass updates, and the instance count is written by that same pass into
an `SDL_GPUIndirectDrawCommand`, so the CPU never learns it.

That is the whole reason for the deferred-only decision. There are no vertex
buffers anywhere: shaders index storage buffers by vertex and instance ID.

## The shader pipeline

GLSL goes to SPIR-V through shaderc, then to MSL through SPIRV-Cross. Runtime
compilation is a requirement rather than a convenience: material variants are
assembled from preprocessor defines at load time, so an offline-only bake would
not serve them.

SDL abstracts the whole API across Metal, Vulkan, and D3D12 identically, but
it deliberately does not abstract shaders: `SDL_CreateGPUShader` takes
precompiled bytecode in a backend-specific format and never compiles or
translates. That is the one platform-specific seam, and this is the code that
sits on it. Only MSL and SPIR-V are produced today, so Windows resolves to the
Vulkan backend; D3D12 would need DXC for DXIL.

A release compiles nothing. On iOS there is no writable executable memory to
hand a compiler, on a console there is no compiler to link, and everywhere else
it is tens of megabytes baked into a build that already knows every shader it
will ever use. So every shader the engine can ask for is registered by name in
`tecs.gpu.shaders`, and `make shaders` walks that registry and writes a pack:
code, entry point, reflected counts, workgroup size, and a hash of the source it
came from. Because the builder calls the same compiler a development build
calls, the packaged reflection cannot drift from what would have happened at run
time.

Nothing about that path degrades quietly. `shadercompiler.plan` decides where a
shader comes from and takes "can this build compile" as an argument, since a
running process cannot unlink its own compiler to test the rule that matters
most. A shader missing from the pack, or present but built from source that has
since changed, is a recompile where one is possible and an error where it is
not. The device claims the pack's format for the same reason: claiming a format
the build cannot supply selects a backend that fails at shader creation rather
than at startup.

Shaders and materials are re-readable while the process runs, through the
debug server's `reload_shaders` tool. The interesting part of a reload is not
noticing the edit; it is the refusals. A build that
links no compiler cannot reload at all: a pack decides the shader format the
device claimed when it was created, so there is nothing to put in a pipeline's
place. And a material file appearing or disappearing renumbers every material
after it alphabetically, while `Material` components in the live world already
hold numbers, so editing a body reloads and adding one is a restart. Both are
refused by name rather than attempted.

What makes the swap cheap is that the pipeline objects a frame binds are read
through the backend every frame, so replacing them is picked up by the next
frame with no pass graph rebuilt and nothing in the world touched.
`Backend:rebuildPipelines` is that half. It waits for the device to go idle,
builds the geometry pipeline, the three cull pipelines and the deferred pass's
own two against the formats the G-buffer was created with, and installs them
only once every one of them has compiled, so a source that no longer compiles
raises and leaves the process drawing exactly what it drew.

Images re-read on the same principle, through `reload_image`. A file is decoded
again and written over the texels its name already occupies, so the layer and
the UV rect that every `Sprite`, `Sheet` and glyph is holding stay true and
there is nothing to invalidate. That is what makes it identity rather than a
second upload, and it is also why the size has to match: a resize is a different
rect, packed or not, and the instances already carrying the old one have no way
to be told. Packed or not, only the image's own rectangle and the gutter around
it are written, so the neighbours sharing its layer are untouched.

Sound re-reads through `reload_sound`, and identity is kept the same way: a
clip's index is its path's, so an edited file comes back under the index every
`Sound` row already carries. What differs is that there is a case with nothing
to do. A streamed clip holds nothing, because each voice opens the file for
itself, so the next voice reads the new file and the reload only says so. A
resident clip is decoded again and swapped, and the samples it replaces are
destroyed while voices may still be reading them: `MIX_DestroyAudio` drops a
reference rather than freeing, and a track holds one, so a sound playing across
the swap finishes on what it started with and the last track to let go is what
frees. A resident clip stays resident whatever the new file's length would have
chosen on a first load, because rows pointing at it were started against held
samples and turning it into a stream under them would change what a voice is.

A sheet re-reads through `sheet.replace`, which exists because building a sheet
under a name that is already taken does the opposite of what a reload wants: it
answers new entities with the new sheet and leaves every entity already playing
on the old one, which is right for two sheets that share a name and wrong for
one file that was exported twice. `replace` folds a freshly built sheet into the
one the name already held, keeping its id, so an `Animation` goes on playing and
shows the new frames on its next step. Frames, durations and image size are free
to change, since what an entity carries is a tag and a time and the frame is
resolved from the cycle at every step. Tags and slices are not: their ids follow
their names in sorted order, an `Animation` holds a tag index and a `Pivot`
holds a slice index, so a re-export that adds, removes or renames either is
refused by name, exactly as a material file appearing is.

A font re-reads through `reload_font`, and it is the one reload with something
in the world to put right afterwards. An image, a clip and a pipeline are each
read through every frame, so replacing one is picked up by the next frame and
nothing has to be told. A glyph is not: it is an instance laid out once from the
metrics and left alone until something about its text changes, and re-reading
the metrics changes nothing about its text.

So identity is kept the same way and then has to be worked around. The metrics
are read back into the `Font` table itself rather than into a new one, because a
`Text` names its font by holding it and a replacement would strand every live
text on the font that was. Which means nothing can infer from identity that
anything happened, since a text is laid out again when what its glyphs were
built from differs from what it holds and after a read in place none of it
differs. The texts naming that font are therefore told, by forgetting the font
in each one's build record: that makes the comparison fail, and it goes on
failing until a build succeeds, which is what carries them across the frames the
atlas is decoding in. Exactly those texts, and no others: one naming a different
font is not laid out again however much of an archetype it shares with one that
is.

The refusal is the atlas's size, on the terms `reload_image` refuses an image
whose size moved. Every glyph carries UV extents computed against the size the
atlas had, and a page of another size makes each of them address something else.
A font is two files, and only the metrics reload as a font: the atlas is an
image, was loaded as one, and reloads as one under the rect it already occupies,
so no glyph has to be told about it. What the metrics reload does give up is
what the renderer resolved for the font, since the field's range arrives as a
fraction of a cell computed from the metrics, and a page that would not decode
is remembered so a broken path is reported once rather than every frame. Both
are answers to a question the re-read just changed, and the second is the more
useful one: a font regenerated over a page that was missing can come back.

### The file watcher

Those five are driven by an agent that knows it edited something, and also by a
watcher that notices. SDL has no change notification: not in 3.4 and not behind
a hint, and `SDL_AddEventWatch` watches the event queue rather than the
filesystem. What `SDL_filesystem.h` offers is `SDL_GetPathInfo`, which answers a
type, a size and three timestamps. So `tecs.platform.watch` polls, and going
native to avoid polling would mean inotify, FSEvents and
`ReadDirectoryChangesW`, plus one more for every platform whose SDK is licensed,
to save work measured below in microseconds.

It polls what was loaded rather than the content tree. `assets` records every
path this process has read or decoded, which is both a much smaller set and the
only set where a change has anything to act on, since a file nothing opened has
no reloader to route to. That is also why `SDL_EnumerateDirectory` is never
called: there is nothing to enumerate.

The poll is synchronous, on the main thread, between frames. Async IO is not an
option rather than a rejected one: SDL's asynchronous IO opens, reads, writes
and closes files, and there is no asynchronous `SDL_GetPathInfo`, so asking a
file's size and modification time is a blocking `stat` however it is reached. A
thread is a rejected one. A poll costs one call per watched path, measured at
0.86 microseconds a path, so a hundred files at two polls a second is 172
microseconds a second, and a frame the interval has not elapsed on costs a clock
read and a compare. A worker would have to be told the watched set every time
something loaded, every reload it could trigger has to happen on the main thread
anyway, and what it would move off the frame is already free.

The part with a real decision in it is the half-written file. An editor saving
commonly truncates and rewrites, so a poll can land on a file of zero length or
of half its eventual size, and handing either to a reloader is how a watcher
takes a process down. Two rules cover it. A file must report the same size and
modification time on consecutive polls before it is dispatched, so a rewrite in
progress is seen changing and is not acted on until it stops changing; and a
file of zero length is never dispatched, since that is a truncation whatever
else it is. Under both, a handler runs guarded and a raise is logged rather than
propagated, and the reloads themselves already refuse safely: a truncated PNG
does not decode, a broken shader does not compile, and neither replaces what the
process is drawing.

Dispatch is by kind, and the kind comes from how the file was loaded rather than
from its name: something asked for a path as an image, which is what makes it
one. A suffix decides in one place only, because `read` answers bytes and cannot
know what wanted them, so a `.glsl` document is a shader and every other
unnamed document is a document. A font's metrics are the case that pins the
rule: they are JSON, a level is JSON, and the suffix cannot tell them apart, so
`read` takes the kind from whoever asked for the bytes and the call that loads a
font is the one that names it a font. Which reloader owns a kind is registered
by the application, not by the watcher, so nothing in `tecs.platform` has to
know what an image or a clip is.

It is development only. `Application.Config.watch` starts it, the `watch` tool
turns it on, off and a poll at a time, and `install` refuses on a build that
links no shader compiler, which is the same bit `reload_shaders` refuses on and
the same thing it means: a release polls nothing.

Content is never resolved against the working directory. That happens to work
when a build is launched from a project root and is meaningless the moment
anything else launches it, and on a device there is no useful working directory
at all. The build states where content sits relative to the executable, the C
host resolves both its entry chunk and the asset root against that, and an
installed tree runs from an unrelated directory with nothing in the environment.

## Porting to a platform SDL does not cover

SDL covers every platform this engine can be built for openly. It does not
cover the ones whose SDKs are licensed, and those cannot live in this repository
even for someone who holds a licence, because their headers may not be
redistributed. So the engine names its platform seams instead. There are seven,
and a port supplies these and touches nothing above them:

```
 Seam        What a port supplies                       Where it plugs in
 ──────────  ─────────────────────────────────────────  ───────────────────────
 lifecycle   A host that calls _init, _receive,         its own entry point
             _iterate, _shutdown
 events      Typed events, produced directly            adapter.events
 input       Devices, rumble, cursor modes, text input  adapter.input
 audio       A mixer, tracks, gain, tags                adapter.audio
 static FFI  Function pointers taken at build time      native/registry.c
 storage     Content and writable roots                 adapter.basePath/prefPath
 shaders     A pack in the platform's own format        adapter.shaderFormat
```

Each is a seam rather than a fork because everything above it is already
indifferent to the answer. The application is an object a host drives rather
than a function that runs until done, which is why iOS and a console SDK can
both call the same four methods. Events are one typed stream discriminated by
`kind`, so a platform with no `SDL_Event` produces those values directly.
Input needs a second face because rumble, an LED, a cursor mode and a text
input session are commands going the other way, and no event vocabulary can
express one. Audio is almost that direction alone: a mixer opens, a voice is
pointed at a clip, a gain is set, a voice stops, and the one thing that comes
back is whether a voice is still sounding, which is asked rather than
delivered. A target that forbids `dlopen` reaches its libraries through a
table of pointers
taken at build time, and nothing calls `ffi.load` when one is present. The pack
layout does not change for a platform with private bytecode; only the declared
format does.

`tecs.platform.adapter` holds the SDL implementation of all five, which
doubles as the worked example. `spec/adapter_spec.lua` installs a platform that
is not SDL and drives real work through it, because a seam nobody has ever
substituted is a guess about what a port would need rather than a contract.
That spec is not a console port and cannot be one; it is the evidence that a
port has five things to supply.

The fiddly part is bindings. SDL_GPU consumes compiled shaders and is told
separately how many resources of each class they bind, and it fixes the
descriptor sets shaders must be authored against. Those sets differ by stage:

```
 Stage     Textures and storage buffers   Uniform buffers
 ────────  ─────────────────────────────  ───────────────
 vertex    set 0                          set 1
 fragment  set 2                          set 3
 compute   set 0 read-only, 1 read-write  set 2
```

Metal has no descriptor sets, so those bindings are flattened into `[[buffer]]`
and `[[texture]]` indices in the order SDL_GPU's Metal backend expects. Both
the counts and the remapping come from reflecting the SPIR-V, because a wrong
count is not a compile error. It is a silent binding mismatch.

That is also why `spec/render_spec.lua` renders offscreen and asserts on real
pixels. A draw that produces nothing still runs at full frame rate, so "it did
not error" is not evidence that it drew.

## Locked decisions

These shape the seam and are effectively impossible to retrofit, so they were
settled before anything was written.

**Deferred only, no immediate mode.** SDL_GPU bakes blend, depth, and cull into
immutable pipeline objects and has no global state to set. An immediate-mode API
would have to be built in order to then be worked around, so there isn't one.
Every draw goes through a render pass on an explicit frame.

**The command buffer is a value, never a global.** `Device:beginFrame` returns a
`Frame` that carries its own command buffer, and anything recording work takes
that frame explicitly. SDL_GPU permits a command buffer per thread; a module
global would make threaded recording impossible to add later without touching
every drawing site.

**Nondeterminism is injectable.** `platform.clock` and `platform.events` both
read through a provider that defaults to the real source. A replay driver
substitutes recorded dt and recorded input without either subsystem knowing.
Events are delivered as a reused `SDL_Event`, so recording is a 128 byte copy
and replay is the same copy back, with no second representation to keep in sync.

**Resource handles are owned by the platform, not by Lua's collector.** Windows
and devices are released by an explicit `destroy`. Tying GPU-adjacent lifetimes
to finalizers makes hot reload either leak or double-free depending on
collection order.

**The ECS and the engine are one project.** They were separate while this
replaced the previous rendering layer and the ECS stayed renderer-agnostic.
The renderer's whole job
is reading archetype columns, and the ECS's storage layout decides whether that
is fast, so the boundary stopped paying for itself. Storage that a GPU can read
directly is the reason to merge, and it is not expressible with the two apart.
Headless worlds keep working: GPU-backed storage is opt-in per component.

**Workers will be the only threading path.** LuaJIT FFI callbacks invoked from
threads the VM did not create are unsafe, so raw thread creation will not be
exposed even though the symbols are bound.

## Reaching native code

A library is reached through a registry the host installed if there is one, and
through `ffi.load` otherwise.

`ffi.load` needs a shared object and a working `dlopen`. iOS has neither: every
library is linked into the executable and loading one by name at run time is
not permitted. A target like that can still call C, but the addresses have to
be taken at build time.

So the build emits, for each library, a struct of typed function pointers and
one C file that fills it by taking the address of each function. The host
installs those tables into every Lua state, including every worker state, before
any Lua runs. A worker resolving its own libraries would reintroduce the
dependency on dynamic loading in the place it is hardest to notice, since a
worker that fails to start looks like a worker that had nothing to do.

```
 sdl3        1231 functions
 box2d        421
 spvc         169
 sdl3image    102
 sdl3mixer     92
 shaderc       45
 worker        10
 taskpool       7
 logsink        3
```

Signatures come from the generated cdef rather than being parsed again, so the
pointer table cannot disagree with the bindings. Both are generated with the
same preprocessor defines the C is compiled with: a header that declares
different things under `NDEBUG` would otherwise produce a binding for a
function the build does not have.

The tables hold functions only. Enum constants are compile-time values that
need no library loaded, so they resolve through the FFI's own namespace and the
engine finds both through one handle. Resolved names are memoised, so a name
costs a lookup once rather than on every call.

Taking the address of a shader compiler's functions means linking it, which is
the coupling `TECS_RUNTIME_SHADERS=OFF` removes: a release generates no table
for shaderc or SPIRV-Cross and links neither.

## Bindings are generated, never hand-written

`scripts/gencdef.py` runs the system preprocessor over the installed headers,
keeps the declarations that came from the library, and rewrites them into the
subset of C that LuaJIT's parser accepts. Integer `#define` constants are
recovered separately by compiling a program that prints them, because the
preprocessor expands them away before a cdef could see them, and because many
of them (`SDL_WINDOW_RESIZABLE`) hide behind helper macros that pattern
matching misses.

A hand-maintained cdef does not fail to link when it drifts. It reinterprets
memory and surfaces later as corruption far from the cause. `make abi-check`
compares LuaJIT's view of every generated record against the C compiler's:
size, alignment, and the offset of every field. It currently verifies 194
records. A binding whose header is written against another library's types
names that one as a prerequisite, which is how SDL_mixer's records are
declared against SDL's.

Header-only `static inline` helpers have no symbol to bind and are
reimplemented in Lua. That is usually faster anyway, since the JIT can inline
Lua where it cannot inline across an FFI call. `World.getAngle` converting a
`b2Rot` cosine/sine pair is the current example.

## Layout

```
host/main.c                 process entry: a Lua state and argv, nothing else
scripts/gencdef.py          header -> cdef + constants generator
scripts/abicheck.py         cdef vs C compiler layout verification
src/tecs/global.d.tl      declares the `tecs` global, typed off init.tl
src/tecs/ffi/             library loading and generated binding wrappers
src/tecs/platform/        window, clock, events, clipboard, proc, input, audio
src/tecs/gpu/             device, frame, passes, shaders, pipelines, buffers
src/tecs/components.tl    components the engine renders and simulates
src/tecs/gfx/             camera, layers, sprite sheets and their playback
src/tecs/Renderer.tl      the world-to-GPU bridge, owning both halves below
src/tecs/Extractor.tl     the world-facing half: a world to a frame packet
src/tecs/Backend.tl       the device-facing half: a frame packet to a frame
src/tecs/FramePacket.tl   what crosses between the two
src/tecs/Audio.tl         clips, voices, groups, and the Sound component
src/tecs/physics/         Box2D binding and its world plugin
src/tecs/sequence/        the sequencer, and the tween runtime inside it
spec/                       busted suite
```

## Build

CMake is canonical. Make is a wrapper that forwards to it, so there is one
description of how the engine is assembled rather than one per platform to keep
in step.

```
make presets        list the platform matrix
make build          build the selected preset
make run            run the demo
make test           run the spec suite
make check          type-check Teal sources
make abi-check      verify generated cdefs against the C ABI
make package        install a tree into out/package
make check-package  verify a package carries its own dependencies
make deps           install development dependencies (Homebrew)
```

`PRESET=` selects the target; it defaults to `macos-arm64-dev`. Presets come in
two kinds. A development preset resolves dependencies from the system, which is
convenient and not shippable: it links the build machine's libraries by
absolute path. A packaged preset builds pinned revisions from source, so a
release is reproducible and carries no path from the machine that made it.

`make check-package` is the gate on that distinction. It inspects the installed
binaries for search paths and absolute references that leave the package, and
for a shader compiler a release is not meant to ship. On a development install
it reports what it found and passes, because those references are expected
there; on a packaged one it fails. A package that resolved a library from the
build machine works there and nowhere else, and the failure only appears once
someone else unpacks it.

It holds the installed types to the same standard, for the same reason: it
type-checks a file that uses the `tecs` global against `share/tecs/teal` and
nothing else of the engine's, so a package whose type information is missing or
incomplete fails here rather than for whoever unpacks it. That one fails on
both kinds of install, since types are not something a development build is
allowed to borrow from its machine.

`TECS_FRAMES=N make run` exits after N frames, so an automated run can drive
a real window to completion.

## Requirements

CMake 3.24+, LuaJIT, SDL3 (3.4+, for SDL_GPU), SDL3_image, SDL3_mixer,
SDL3_net, Box2D 3.x, shaderc, SPIRV-Cross, and Teal (`tl`). `make deps`
installs them on macOS.

A development build takes SDL_mixer from the system, and a system build is
whatever the packager configured: Homebrew's loads its optional decoders by
name at `MIX_Init`, so a developer's machine may well have the LGPL ones
available where a package built from `cmake/Pinned.cmake` does not.
`Audio.decoders()` is how to tell which build is running.

Dependencies are found through pkg-config rather than a package manager's
paths, which is what lets the same build description cross-compile. Box2D ships
no pkg-config file and is located directly.

SPIRV-Cross is distributed as static archives only, and the FFI needs a shared
object, so the build links one. Whole-archive linking is deliberate there: the C
API's symbols are not referenced from the stub, so the linker would otherwise
discard every one of them.
