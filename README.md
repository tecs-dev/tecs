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
  read and write the world
- Per-stage frame timing with percentiles, which is how any of the numbers in
  this file were arrived at, and event-to-photon latency reported through the
  same stages
- Text from a signed distance field, laid out into one entity per glyph so it
  goes through the same cull and the same draw as everything else
- Deterministic sequencing with tweening merged into it: programs compiled to
  instructions, playback position kept as data so it survives a snapshot, and
  three clocks (fixed, frame, presentation) for the three rates gameplay,
  scripted input and presentation run at
- Sprite sheets and playback: an image cut into frames by a grid or by an
  explicit rect list, named ranges over those frames, and a fixed-phase system
  that writes the current frame's region into `Sprite` and reports a range
  completing or looping on the world's event bus
- Layers: sixteen bands of the depth range, each choosing how its contents sort
  within it, and each able to sit in screen pixels, in virtual coordinates,
  outside the camera's zoom, at its own parallax, or unlit
- Sound: WAV clips read on the asset worker, a voice per platform stream so the
  platform does the mixing, and a `Sound` component that plays for as long as
  its entity exists

Not built yet: shadows, post-processing, UI, tiled maps and multi-camera.

Design notes live in `../tecs-plans`, kept outside this repository so plans and
code have separate histories.

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

Asset loading rides on that. Decoding a PNG is milliseconds of pure CPU work
with no GPU involvement, so it happens on a worker and the main thread only
uploads. The worker returns the *address* of a decoded surface rather than its
pixels: surfaces live in process memory, so the pointer is valid in either
state, and passing it avoids copying an image through a serialized message
only to copy it again into staging. Ownership transfers with the address.

Sound takes the same route. A WAV is read and converted to the output's format
on the worker and handed back as the address of its PCM, so a clip that turns
out to be mono at 22050 costs the frame nothing and every voice that plays it
resamples nothing.

## Sound

`app.audio` is the whole surface: load a clip, play it, set a gain, stop it,
loop it. It is built on SDL's audio streams and on four decisions.

**WAV only.** Clips come through `SDL_LoadWAV`. There is no SDL_mixer here and
no decoder, so Ogg Vorbis, Opus, MP3, FLAC and tracker modules do not load, and
a compressed file fails rather than being resampled into something. Adding a
decoder adds a dependency and a licence to the build, which is a decision worth
making on its own rather than as a side effect of wanting background music.

**A voice is a stream, and the platform mixes.** Playing a sound binds a stream
to the output; playing the same clip three times over binds three streams
reading one buffer. Nothing in this engine sums samples, which is why
`SDL_MixAudio` goes unused: the only thing it could add is summing into a
buffer the engine owns, and there is no such buffer. Thirty-two voices by
default, and a thirty-third play declines rather than stealing one, because a
sound that stops halfway through because something else started is harder to
explain than one that never started.

**No callback runs on an audio thread.** SDL can pull audio from a callback,
and that callback fires on a thread the Lua VM did not create; a Lua function
invoked from such a thread is the same unsafe case that keeps raw thread
creation unexposed. The device is fed by queueing instead, from the iteration,
on the thread everything else runs on. A callback mixer would need a native
bridge and there is not one.

**Every voice is fed in pieces.** Each update tops a voice's stream up to a
quarter of a second of lead and no further, so a long piece of music holds a
bounded queue instead of being handed over whole, and looping is the cursor
wrapping rather than a second mechanism. What that is not is streaming from
disk: `SDL_LoadWAV` has no partial-read form, so the file is resident even
though the queue is not, and reading a WAV incrementally would mean parsing the
container here, which is the decoder that is deliberately absent.

The output is the platform's default rather than a device chosen by name, so
SDL migrates the logical device when the system default changes and plugged-in
headphones need no handling. That has one consequence worth writing down:
`SDL_OpenAudioDeviceStream` opens a device and one stream together and then
refuses every further binding on it, so the device is opened with
`SDL_OpenAudioDevice` and voices are bound to it, which is also the form that
starts unpaused.

A `Sound` component is how a sound belongs to an entity. Presence is the
instruction: an entity carrying one with a loaded clip starts sounding on the
next audio pass and stops when the component or the entity goes away. One walk
per frame starts what has not started, marks what has finished, and releases
any voice no component referred to, which is what makes despawning something
mid-sound do the obvious thing without an observer on every archetype.

There is no listener and no panning. SDL gives a stream one gain and a channel
map, and a channel map reorders channels rather than attenuating them, so
constant-power panning means either summing samples here or splitting every
mono clip across two streams. Both are real designs, and neither is worth
committing to before the questions under it are answered: what units distance
is in, what the falloff curve is, whether the listener follows the camera or an
entity, and what a sound on a screen-space layer does. Attenuating by distance
alone is the cheap half of that, and shipping the cheap half fixes the answers
to the rest by accident. `Sound.gain` is the seam it arrives through when it
does.

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
clipboard, sensors and gamepad touchpads all convert their payloads. Several of
those carry pointers into memory SDL recycles as soon as the callback returns,
so the C host copies those bytes into the queue it owns and frees them when the
queue drains. Retaining the pointer is a use-after-free that reads as an
occasional garbled string.

A mouse event the platform synthesised from a touch or a pen is marked as such.
Those arrive beside the finger events they were made from, and a game handling
both would otherwise act on one gesture twice.

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

Layer zero is a white pixel, so an entity with no `Sprite` samples it and
textured and untextured geometry share one shader and one pipeline. An image
smaller than a cell does not reach the cell's edge, so `registerImage` returns
a ready `Sprite` rather than a bare index: a caller guessing the UV range
would sample the undefined remainder.

A `Sprite` names its image; which layer that name occupies is the renderer's
answer to it. Layers are handed out as images register, so a layer number
means whatever loaded in that position, and one written into a snapshot is a
different image the moment the assets load in a different order. So a snapshot
stores the name, `registerImage` keeps a registry from name to layer, and
registering a name twice answers with the layer it already holds instead of
consuming another. The layer is cached in the `Sprite` when it is built, or on
the first frame that writes a restored one, because extraction reads it for
every row and a lookup per row is a lookup too many. A name nothing is
registered under fails rather than drawing whichever image holds that layer.

Its sync reads columns with `get`, never `getMut`. Taking a mutable column to
read would mark those components dirty on every archetype every frame, which
defeats every dirty-gated consumer downstream. That distinction is the single
easiest thing to get wrong here and the hardest to notice.

Syncing runs in `RenderFirst` inside the world's update; rendering happens
afterwards against a frame. The two stay separable because the sync needs no
command buffer and the render needs no world, which also means the swapchain
is held for as little of the frame as possible.

## Sprite sheets and playback

A sheet is an image divided into frames, cut either by a uniform grid
(`sheet.grid`, with an optional margin around the grid and spacing between the
cells) or by an explicit list of rects (`sheet.rects`). Frames are addressed by
index, and named ranges are inclusive spans over those indices. A range is what
an animation plays.

A sheet is data, not a component: a hundred entities drawing one character
share one sheet and point at it. What the `Animation` component carries is the
sheet's registration index and the index of a range within it, because a
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

A range that does not loop parks on its last frame, stops, and emits
`animation.Completed`; a looping one wraps and emits `animation.Looped`. Both
go to address zero with the entity in the payload, matching `OnSpawn` and
`OnDespawn`, which lets the system ask the bus once per step whether anyone is
listening rather than once per entity that finished.

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
target and the best answer is taken. Depth state is declared per pass, because a
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
alongside `textured`, which is the whole quad, and `glyph`. They are compiled
into one fragment shader with a generated dispatch, so a scene of shapes is
still one batch, one cull and one draw, and a shape is one entity rather than
the several a fan of triangles would need.

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
 audio       An output, streams, PCM, gain              adapter.audio
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
express one. Audio is that direction and only that direction: an output opens,
PCM goes in, a gain is set, a voice stops, and nothing about sound comes back
as an event. A target that forbids `dlopen` reaches its libraries through a
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
size, alignment, and the offset of every field. It currently verifies 192
records across the four libraries.

Header-only `static inline` helpers have no symbol to bind and are
reimplemented in Lua. That is usually faster anyway, since the JIT can inline
Lua where it cannot inline across an FFI call. `World.getAngle` converting a
`b2Rot` cosine/sine pair is the current example.

## Layout

```
host/main.c                 process entry: a Lua state and argv, nothing else
scripts/gencdef.py          header -> cdef + constants generator
scripts/abicheck.py         cdef vs C compiler layout verification
src/tecs/ffi/             library loading and generated binding wrappers
src/tecs/platform/        window, clock, events, input and audio backends
src/tecs/gpu/             device, frame, passes, shaders, pipelines, buffers
src/tecs/components.tl    components the engine renders and simulates
src/tecs/gfx/             camera, layers, sprite sheets and their playback
src/tecs/Renderer.tl      the world-to-GPU bridge, owning both halves below
src/tecs/Extractor.tl     the world-facing half: a world to a frame packet
src/tecs/Backend.tl       the device-facing half: a frame packet to a frame
src/tecs/FramePacket.tl   what crosses between the two
src/tecs/Audio.tl         clips, voices, and the Sound component
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

`TECS_FRAMES=N make run` exits after N frames, so an automated run can drive
a real window to completion.

## Requirements

CMake 3.24+, LuaJIT, SDL3 (3.4+, for SDL_GPU), SDL3_image, Box2D 3.x, shaderc,
SPIRV-Cross, and Teal (`tl`). `make deps` installs them on macOS.

Dependencies are found through pkg-config rather than a package manager's
paths, which is what lets the same build description cross-compile. Box2D ships
no pkg-config file and is located directly.

SPIRV-Cross is distributed as static archives only, and the FFI needs a shared
object, so the build links one. Whole-archive linking is deliberate there: the C
API's symbols are not referenced from the stub, so the linker would otherwise
discard every one of them.
