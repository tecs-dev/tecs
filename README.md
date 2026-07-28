# tecs

A typed entity component system and the game engine built around it, in Teal
for LuaJIT, on SDL3, SDL_GPU and Box2D 3. The two were separate projects and
are now one: the ECS knows what the GPU reads. Entities are the interface,
so anything that renders or updates per frame is an entity in a world.

SDL owns the loop. An entry file returns an application and a C host drives it
from `SDL_AppInit`, `SDL_AppEvent`, `SDL_AppIterate`, and `SDL_AppQuit`:

```lua
return tecs.application.create({
    window = {title = "game", width = 1280, height = 720},

    plugin = function(world, app)
        world:addSystem({
            name = "game.Tick",
            phase = tecs.ecs.phases.Update,
            run = function(dt) end,
        })
        world:observe(0, tecs.events.on.appWillEnterBackground, function() end)
    end,
})
```

That shape is not a preference. iOS never hands control back for a blocking
loop to sit in, so a host that cannot be entered by callback cannot run there
at all. The same shape works on desktop, so there is one lifecycle rather than
one per platform. The host's calls into Lua are C reaching Lua through the Lua
C API, not FFI callbacks, which are a trace barrier and unsafe from a thread
the VM did not create.

Everything below Lua is reached through the FFI. What C there is under
`native/` is mostly there because something below Lua needs an address a Lua
function cannot safely be: a host that owns `main`, a worker thread runner, a
log sink, the thread pool Box2D solves across, the file dialogs, the HTTP
response buffers, the machine-code arena, a shared-object stub for SPIRV-Cross,
and the table of function pointers a target without `dlopen` reaches its
libraries through. The host itself is never called from Lua. The one Lua C
module is lua-cjson, compiled in and announced through `package.preload` rather
than found on a search path, for the reason that table of pointers exists.

## Status

Working today:

- Generated FFI bindings for SDL3, SDL3_image, SDL3_mixer, SDL3_net, Box2D 3,
  shaderc, SPIRV-Cross, libcurl and zlib, verified against the C ABI
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
- An ECS binding: the builtin `Transform` plus Tint, Sprite, Material,
  PointLight, Clip, Occluder, DropShadow and Renderable components, with a sync
  that walks archetype columns straight into mapped GPU staging, and a
  depth-tested G-buffer
- Physics in the world: a RigidBody component holding a value-typed Box2D
  handle, stepped in the fixed phases, solved across a native thread pool, and
  written back from the movement Box2D reports rather than by asking per body.
  A despawn destroys the body; a snapshot carries the `Body`, `Collider` and
  `Motion` columns instead of the handle, and the fixed-step reconcile rebuilds
  the body from them on load
- Input in three tiers behind a layer stack, latched for fixed steps, with
  per-device gamepads, text input bound to a layer, touch and pen
- Worker threads with serialized channels, and asset loading that decodes on
  one and uploads on the main thread
- Frame pacing from the swapchain, with no sleep heuristic
- Shaders packaged as artifacts, so a release links no compiler
- A platform contract with seven seams, and an SDL implementation of all seven
- A debug server over HTTP that survives a crash in game code, with tools that
  read and write the world, capture the frame, report what the mixer is doing,
  and pick the loop back up once the fault is fixed. The log file it reads
  through `get_logs` is written when the server or `debug` is asked for and not
  otherwise, so a shipped game writes no file nobody asked for; SDL already
  dispatches to a destination a human can read on every platform
- The platform lifecycle answered where it arrives, including a checkpoint the
  game prepares during ordinary frames and the engine flushes on being
  backgrounded or terminated
- Per-stage frame timing with percentiles, which is how any of the numbers in
  this file were arrived at, and event-to-photon latency reported through the
  same stages
- Text from a signed distance field, laid out into one entity per glyph so it
  goes through the same cull and the same draw as everything else
- Deterministic sequencing with tweening merged into it: programs compiled to
  instructions, playback position kept as data so it survives a snapshot, and
  three clocks (fixed, frame, presentation) for the three rates gameplay,
  scripted input and presentation run at
- Seeded generation in named, independent streams, whose state a snapshot
  carries and whose sequence is the same on every machine, with Perlin noise
  seeded the same way ([`src/tecs/random.tl`](src/tecs/random.tl))
- Sprite sheets on Aseprite's model: frames with their own durations, named
  tags playing forward, in reverse or pingpong, and slices carrying pivots,
  built by a grid, an explicit rect list, a builder, or read from an Aseprite
  JSON export; with playback resolved in the vertex shader against a shared
  frame table, so a frame changing writes nothing and two hundred thousand
  animating sprites cost what two hundred thousand still ones do
- Two shadows: an `Occluder` puts its silhouette into one mask that every light
  marches, so blocking a light costs one drawing of the caster rather than one
  per light, and a `DropShadow` throws a stretched copy along the ground, which
  is the half that reaches ambient. Both arrive through the renderer's
  `shadows` option and cost nothing without it
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
- Particles simulated on the GPU: an entity is an emitter and its particles are
  not entities, their state living in a buffer the CPU never reads, drawn
  through the instance stream and the cull that were already there. Opaque
  only: the forward blended lane exists, and nothing particle-shaped routes
  into it yet

Not built yet: post-processing, UI, tiled maps and multi-camera.

Design notes live in `../tecs-plans`, kept outside this repository so plans and
code have separate histories.

## The surface is a global

`tecs` is a global, so a game writes it in any file with no require line:

```lua
local world = tecs.ecs.newWorld()
local Velocity = tecs.ecs.newComponent({
    name = "Velocity",
    container = {},
    fields = { "x", "y" },
    defaults = { 0, 0 },
})
world:spawn(tecs.ecs.builtins.Transform(0, 0), Velocity(1, 0))
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
changes: `tecs.application.Application` read off the global resolves on first use exactly as
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

## One way in

Because the host reaches into an object rather than being handed a loop,
something has to run after the device and the world exist, once per iteration,
once per event, and once at teardown. That much follows from the entry point.
What does not follow is that a game should be handed four callbacks for it, and
it no longer is. `Application.Config` carries `plugin`, one
`function(world, app)`, and nothing else a game supplies is called by the loop.

The reason is that the ECS already answers all four questions, and answers them
better than a callback can. A system's order is declared by the phase it is
registered in rather than being implicit in where the loop happens to call it. A
system and an observer are both registered on the world, so the world can count
them and the debug server reports the count; a field of a config table is
reachable from nowhere. And both run inside the crash guard, so the line that
fails leaves a traceback and a live process rather than unwinding to the host.
That last one used to cut the other way: the same line of gameplay was
inspectable after it failed in a system and fatal after it failed in `update`,
which was reason enough on its own.

So the four map onto machinery that was already there:

```
 Was          Is now                        Run by
 ───────────  ────────────────────────────  ────────────────
 load         PreStartup, Startup,          world:startup
              PostStartup
 update       First … Last, fixed or not    world:update
 event        world:observe(0, on.<kind>)   the drain
 quit         PreShutdown, Shutdown,        world:shutdown
              PostShutdown
```

Two of those four rows were built and never invoked. `world:startup` and
`world:shutdown` existed, all twenty-one phases existed, and `Application`
called neither, so a game registering a `Startup` system got one that was
accepted, counted, and silently never run. That is presumably why the callbacks
existed at all: they filled a gap that was only ever a missing pair of calls.
`spec/phases_spec.lua` is the guard against it happening again, and it is
deliberately not a list of the six phases that were dead. It takes
`phases.index` from the phases module, registers a marker in every phase in it,
drives a real application through the whole lifecycle and names the ones that
never fired, so a phase added later is covered the day it is added.

### One plugin, and what it is handed

There is one entry point rather than a list of them, because the world already
composes plugins. `world:addPlugin` takes an `ecs.Plugin`, which is a plain
`function(world)`, and it is how `main.tl` installs the text plugin. Anything
the entry plugin delegates to has that same shape and goes through the world, so
a game with several modules calls it from inside its entry plugin and a list
here would be a second mechanism for something that already has one.

The entry plugin is handed the world and the application, in that order. The
world comes first because every plugin the world takes is `function(world)`:
the entry reads as that shape with one more thing, and a body moved between it
and a delegated plugin cannot silently swap its arguments. Reversed, this would
be the only plugin in the tree whose parameters run the other way.

The application is passed rather than looked up, and that closes a hole by
construction instead of by type. An accessor keyed on the world has to answer
nil for a world nothing drives, so its result is a value every caller
dereferences at once and none of them checks. A plugin runs only for a world
that has an application, so passing it in leaves no nil case to express and
there is no `Application.of` to write. The renderer is `app.renderer` for the
same reason, and there is no `Renderer.of` either, nor the weak table behind
it. `Audio.of` is the one that stays, because the debug tools reach the mixer
holding only a world and have no application to have been handed.

Being handed the application is not a fifth lifecycle mechanism, and the
difference is worth stating: what made a callback worse than a system was
_when_ it ran, not what it could see. A system that captured the application
when the plugin registered it gets phase order, the fixed step, pause and state
gating, and the guard, and reaches everything a callback did.

### When the fixed step cannot keep up

A frame hands the pipeline however long the last one took, and the fixed step
runs whole timesteps out of it. A stall, an asset load or a breakpoint hands it
seconds, and running every step that implies would take longer than the frame
it is inside, so the next frame owes more than this one did and the process
spirals. `fixedMaxSteps` bounds that: ten steps by default, a sixth of a second
at 60Hz, long enough to absorb an ordinary hitch and short enough that the
frame recovering from one still draws.

What happens to the rest is `fixedOverload`, and both answers are wrong in
different ways. `drop` abandons the steps that did not fit, so wall time and
simulated time resynchronise immediately and the simulation is now behind by
however much was abandoned. `accumulate` abandons nothing, so the simulation
stays exact and a replay of the same steps reproduces, and on a machine that is
genuinely too slow the accumulator grows every frame and the spiral is back.

`drop` is the default because it is the one with a bound on it, and a process
that cannot draw cannot report what went wrong either. It is still a lie about
how much time passed, so it is counted rather than swallowed:
`world:getStats()` carries `fixedTimeDropped` and `fixedStepsDropped`, the MCP
`context` tool reports both, and the first drop and every doubling of the total
after it are logged at error priority, which is where SDL leaves a category a
game has not turned up. Whole steps only: the sub-step remainder is what the
interpolation alpha is computed from, and taking that as well would jolt every
interpolated transform on a frame that was already late.

A simulation that would rather stall than lie asks for `accumulate`, on the
world or through whatever configures it, and reads the same counters to confirm
they stay at zero.

### Events are a type per kind

Platform events reach a game through the world's message bus, at address zero,
with one ECS event type per kind: `world:observe(0, events.on.dropFile, h)` is
called for dropped files and for nothing else. The alternative shape, one type
carrying a `kind` field, is the callback with a subscription table in front of
it, since every subscriber would be handed every kind and would filter it back
out. Precise subscription is the entire difference, so it is the one worth
having.

The vocabulary is checked where it is written. `events.on` is a record with a
field per kind, so `events.on.dropFil` is an error on the key rather than an
observer that is never called. `events.typeOf` is the same table for code
holding a kind as a string, which is the conversion itself and the debug tools.

Delivery copies nothing. `events.tl` already converts into one reused record,
so what a "copy" would have cost is field stores into a warm table rather than
an allocation, and the emit avoids even those: the bus routes on `eventId` and
reads nothing else, so stamping that one field on the record already in hand is
the whole cost of delivery. Nothing is emitted for a kind nobody observes, so a
stream of motion at device rate costs a table lookup and a gate. The borrow
rule that follows is the one this vocabulary always had, now stated for
observers too: read the record or copy it with `events.copy`, but do not keep
it, because the next event overwrites it.

A raw cdata view onto SDL's own storage would save the conversion's stores as
well, and it is the wrong trade. Wheel axes are negated when the platform
reports natural scrolling and pen axes are folded the same way, so a plain cast
to the SDL struct hands back values that are wrong in exactly the way a recent
fix made right. Normalisation has to happen somewhere, and a metatype computing
it per access moves the cost rather than removing it.

Where an observer sits in the frame is worth being plain about, because an
observer is not a system. The drain runs before `world:update`, so an observer
fires ahead of every system in the frame the event belongs to, outside every
phase: no fixed step, no pause or state gating, and its mutations apply at once
rather than at a phase boundary. `Input` is folded first and is unaffected by
any of this: it consumes the whole stream into state that systems read in
phase, and remains the way to react to input. A game wanting a reaction in
phase does what `Input` does, which is fold the event into something a system
looks at.

### What the shape costs

An application owns one world. A second is possible and can be stepped from a
system, but only `app.world` is rendered, bound to the debug tools and given
the engine's own systems. Nesting one application inside another does not work
at all: the host holds a single registry reference to one returned table,
`SDL_Init` and `SDL_Quit` bracket the process, and the debug server's bindings
are module-level.

What the shape buys below itself is that nothing needs it. `tecs.application.Application` is
not loaded by `require("tecs")`; the engine modules resolve on first use through
the surface's `__index`, which is what lets a tool build a world with no window,
no device and no SDL reachable at all. Most of the spec suite never constructs
an application: it builds worlds directly, or assembles a window, a device and a
renderer by hand, because the config is the only thing that puts those together
and every piece it puts together is separately constructible. The debug server
is bound to the world and the renderer rather than to the application, so a tool
reads the same world whatever a game registered.

The world is all it is bound to. Which components exist is not something the
application tells it, because the ECS already knows: every component enters
`components.registeredComponents` when it is registered, whoever declared it,
and `ecs.declaredComponents` is the read-only view of that. So the eight world
tools name a game's own components on the same terms as the engine's, with no
registration step a game has to find. The alternative the tools used to have was
a second name-to-component map filled by scanning the engine's own module tables
for anything that looked like a component, which meant the tools were wrong by
default for every game: `query`, `set` and the rest answered "no component named
X" for exactly the components a debugging session is about.

That registry is process-wide and a world is not, which is a distinction the
tools report rather than hide. A component's id is allocated once at
registration and every world that carries one agrees on it, so registration is
what makes a name resolvable and `spawn` and `set` are how it comes to be
carried here. A component declared and carried by nothing in the bound world is
an ordinary state, so `components_info` marks it absent rather than unnameable,
and `context` reports `world.components` from `world:getStats` beside
`world.declaredComponents` from the registry. An agent that cannot find a
component can tell which of the two it is looking at.

### A frame that throws puts back what it was holding

The guard keeps the process alive, and that is only half of what a crash needs.
The other half is that a frame holds things across calls that can fail. A render
or compute pass is open between its begin and its end; a command buffer holds a
slot in a finite pool and, once a swapchain texture has been acquired on it, the
texture the display is waiting for; and a query loop holds the world in deferred
mutation for as long as it is iterating. Lua has no finally, so a throw between
two of those lines releases none of it.

So the guard is the finally. It records the traceback first and puts back
afterwards, in that order, because recovery has failures of its own to report
and none of them may replace the one that explains the crash. What it puts back
is reachable from the application while it is held: the frame is recorded on
`app._frame` the moment it is acquired, so recovery can resolve one that the
throw skipped past.

The first traceback is the one kept, and every later one is logged instead. Two
paths produce a later one. Teardown runs `world:shutdown` on a crashed world
deliberately, because a game that acquired something before it threw still has
to be given the chance to give it back, and a `Shutdown` system reaching for
what the crash left half built throws in its turn. And an event delivered to a
game that has stopped can be handled by an observer that throws. The second is
closed outright: while the application is crashed, events are folded into engine
state and not emitted on the bus, so quit still closes the window and `Input`
still tracks what is held while nothing reaches the game. A game whose systems
are not running is not in a state to handle an event either.

The staging slot rotates before the frame is recorded rather than after. A
throw inside the recording used to skip the rotation, and recovery submits
whatever copy passes were already encoded, so the next extraction would write
into the slot the GPU was copying out of. Which slot a frame uploads from is
carried on the packet rather than read from the renderer, so moving the
rotation earlier changes nothing about what is drawn.

A begun pass registers itself against its command buffer in `gpu.passscope` and
takes itself off there when it finishes. That is the one thing a call site
cannot do for itself, and registering by command buffer rather than by frame is
what makes it cover every caller, including a compute stage a game installs and
records its own passes from.

How a broken frame is resolved is SDL's decision, not a preference.
`SDL_CancelGPUCommandBuffer` is documented as an error once a swapchain texture
has been acquired, and `Device:beginFrame` returns only after acquiring one, so
cancelling was invalid on essentially every frame that existed. `Frame:cancel`
now refuses in that state and `Frame:abandon` is the recovery path: it ends the
open pass and then submits when a texture was acquired and cancels when none
was. What reaches the screen is what the frame drew before it threw, which for a
throw ahead of present is whatever the swapchain texture last held.
Clearing it would be a decision about what the game looks like, and recovery is
not the place that makes those.

Acquiring the swapchain later than `beginFrame` does would make cancellation
legal again and would shorten the block that dominates a 60 Hz budget, which is
the better shape and is not this change: the frame's size comes back from that
acquire and is read by the cull, the pass graph and every target it sizes, so
moving it needs a second source for the size and a benchmark on both ends.

`world:unwind` closes every open scope and drains. `world:update` calls it
instead of committing one level, so a system that threw two loops deep cannot
leave the world staging mutations through every update after it, and popping a
query scope is clamped at zero so a cursor closed after an unwind cannot push
the depth negative. Nothing in the ECS catches to do this: catching there would
build the traceback at the rethrow rather than at the line that failed, and the
traceback is the point.

### Picking the loop back up

A crash used to latch for the life of the process, so one nil index in a
gameplay system stopped simulation permanently even though the world, the device
and the renderer are demonstrably healthy afterwards, which is what
`spec/exceptions_spec.lua` exists to show. `app:clearCrash()` lifts it, and its
own documentation is the contract: another frame to look at and a chance to
reload; the world may be inconsistent, reload before trusting it.

The name is chosen against being mistaken for fault tolerance. What the guard
restored are the engine's invariants, which are the ones it can name. A game's
are not restored and cannot be, because a system that threw halfway through its
query left some entities updated and some not, and nothing here knows which half
or what either half meant.

Two gates, and they are different kinds of thing. The first is whether this is a
development build at all, which is `debug`, `mcpPort` or `watch` in the config:
a shipped build sets none of them, latches on the first crash and stays latched,
because there is nobody there to read the frame and carrying on with a world
that is provably inconsistent is how one bug becomes a corrupted save. `watch`
is in that list because the file watcher is the other caller below, and a
watcher that could not pick the loop back up would be a notification rather than
a tool. The second gate is severity, and it is narrow rather than a judgement
about how bad the throw looked: recovery reports whether it had to force-end a
pass or cancel a frame instead of submitting it, and neither resumes at any
setting, because the device is then not in the state the engine intended and the
next frame would be recorded against something nobody can describe.

The callers are the debug server's `clear_crash` tool and the file watcher's
reloads, and both mean the same thing: something about the run has changed, try
it again. That is what gives the watcher its purpose back. Simulated time stops
with the simulation, so `app.elapsed` does not accumulate the length of the fix.
`Input`'s fixed-phase gate would otherwise survive a resume latched on if the
throw landed between `FixedFirst` and `FixedLast`, so recovery leaves that phase
the ordinary way, late: the engine enters and leaves it twice a frame through
the same call, and taking it once more is cheaper than a second way out. Physics
resumability is open.

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

An image is a PNG or a JPEG, and nothing else. SDL_image offers eighteen
formats and `cmake/Pinned.cmake` turns off every one of the other sixteen,
because each is a codec that a statically linked game carries whether or not it
loads one: WebP, AVIF, TIFF and JPEG XL between them cost several megabytes,
and libavif reaches dav1d and aom behind it for about five more. Two backend
options go with them. `SDLIMAGE_BACKEND_IMAGEIO` is off because with it on
`IMG_Load` is not SDL_image's function at all on Apple platforms: CoreGraphics
answers it and reads WebP, AVIF, TIFF, BMP and GIF whatever the format options
say, which would mean a game shipping an atlas that works on macOS and fails
everywhere else. `SDLIMAGE_BACKEND_WIC` is off for the same reason in the
small. What is left decodes identically on every target: libpng for PNG, and
the bundled stb_image for JPEG, which is why keeping JPEG costs no libjpeg. An
asset in any other format is converted when it is built, not enabled when the
engine is configured.

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

A handle is a one-shot future, not a cache. Two image loads of one path that
overlap share the decode and the surface, because decoding the same file twice
at once produces nothing the first decode does not already have; the last of
them to release is the one that frees. A load that starts after the first has
resolved decodes again, since handing back a handle whose pixels may already
have been uploaded and released would be a cache with none of a cache's
guarantees. Sharing is the image path only: two overlapping sound loads of one
path each get their own clip. Release is terminal and says so: a released handle
reports `"released"` rather than reporting `"ready"` over pixels that are gone,
which is the difference between a clear error at the upload and a null
dereference inside it.

Files a game interprets itself go through `filesystem.read`, which is the only
sanctioned way to get bytes out of the content root: on Android content lives
inside the package and `io.open` does not reach it. It answers bytes rather than
text, so an image, an archive or a binary sidecar comes back whole and being
text is a decoder's opinion. Reading a document is that call and a decoder over
it, with nothing in between:

```lua
local bytes = tecs.filesystem.read(tecs.paths.asset("levels/1.json"))
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

All three entry points record what they touched, and they record it in one
place: `filesystem.loaded` answers every path this process has read or decoded
and the kind it was read as, which is what the file watcher polls instead of
walking the content tree. The two loads call `filesystem.note` rather than
keeping a list of their own, because the decode they are recording happens on a
worker and a second list is a second answer to the same question.

## Hashing and decompression

`tecs.hash` and `tecs.compress` are two modules rather than one, because
"operations over bytes" is a category and not a concern: a tool that wants a
shader's identity has no reason to load a decompressor. They share no code, no
state and, since zlib checks a stream's trailer itself, no dependency on each
other either. Both resolve lazily off the surface, the way `json` and `log` do.

`hash.fnv1a64` is what identifies content: the shader pack carries one per
source so a pack built before an edit is detected rather than trusted. It is
not an integrity primitive and is not offered as one. Sixty-four bits puts an
accidental collision out of reach and a deliberate one within it, and
establishing that an asset is the asset that was published is a different
question with a different answer. The algorithm is in the name because the
values are written into files that outlive the process, so changing it has to
be a rename that every caller is rechecked against rather than a silent change
of meaning. `hash.adler32` is there for the format that specifies it.

`compress.inflate` reads zlib streams and `compress.inflateRaw` reads the
DEFLATE inside them. zlib decodes both: it is pinned, bound, carried through the
ABI check and already in the process because libcurl needs it to answer a
`Content-Encoding`, so a decoder written in Lua beside it would be a second
implementation of the format to keep correct, and the slower one. Both entry
points go through `inflate` over a `z_stream` rather than `uncompress`, because
`uncompress` wants the decompressed size up front and treats a wrong one as a
failure while `sizeHint` is a hint whose whole contract is that being wrong
costs a copy, and because `inflateInit2_` takes the window size, so negating it
selects the raw form and one loop answers both.

Writing uses the same whole-buffer shape. `compress.deflate` produces a zlib
stream and `compress.deflateRaw` the RFC 1951 bytes inside one, both from a
single output allocation sized by `deflateBound`. The optional level is zlib's
own `-1` through 9 rather than a second vocabulary the engine would have to
translate and document. CRC-32 joins Adler-32 in `hash`, for the formats such as
PNG, gzip and ZIP that specify it; neither checksum is presented as content
identity or integrity.

A malformed stream raises rather than returning: an over-subscribed code table,
a copy reaching before the start of the output, a stored block whose length
disagrees with its complement, a truncated stream, and a trailer that does not
match what came out. zlib decides all of those but the truncation, which
`compress` decides by handing over the whole input at once and reading a call
that stopped with output room to spare as a stream that ended early. The
messages are zlib's own, so `spec/compress_spec.lua` asserts that each of those
raises and never which sentence it raised; pinning a suite to one
implementation's strings is what makes the next swap expensive.

## Sound

`app.audio` is the whole surface: load a clip, play it, set a gain, fade it,
loop it, pitch it, seek it, pan it, put it in a group, cap how often it may
start, stop it. It is built on SDL_mixer 3 and on six decisions.

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

The output defaults to the platform's default rather than to a device chosen by
name, so SDL migrates the logical device when the system default changes and
plugged-in headphones need no handling. Naming one is available and is the
exception: `config.device` takes an id from `tecs.audio.playbackDevices`, and a
build that pins an output has said it would rather not follow the system.

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
and Lua's part is to install two function pointers, a context and the worker
count into `b2WorldDef` before the world is created. The count is there for the
same reason the pointers are: Box2D indexes per-worker state by it, so a
definition naming more workers than the pool started would have the solver
address state that does not exist.

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
say which those are, falling back to its logical cores, because the workers wait
on each other between stages and the slowest core sets the pace of the step. It
is capped at eight whatever the machine has, since the solver's stages are short
enough that past a handful of workers the coordination costs more than the work,
and a spinning worker on a core the stepping thread needs takes more than it
contributes. Adding workers does not change the answer either way: the solver
colours its constraint graph so no colour holds two constraints sharing a body,
and `spec/taskpool_spec.lua` steps a 256-body pile for 120 steps and asserts it
lands bit-exactly where one worker left it whether two, three, four or eight
solved it.

## A body's lifetime

A `RigidBody` is three integers naming a body Box2D owns, so the component and
the thing it names have separate lifetimes and every place they can come apart
is a place where nothing announces the difference. There are three, and each is
answered here rather than left to a game.

**A despawn destroys the body.** Nothing else knows the entity is gone, so
without this the body keeps being solved for the rest of the session: the
entity's collider stays in the pile, pushing bodies that are still on screen,
and the memory it holds is never returned. The physics plugin observes the
built-in `OnDespawn`, which fires while the row is still readable, and destroys
whatever handle it finds. It reaches the world named in the handle rather than
whichever world the plugin was last given, and it asks Box2D whether the handle
is live first, so a row that never had a body and a row whose world has already
been destroyed both pass through it safely.

**A snapshot does not carry the handle.** Box2D keeps `index1` dense and hands
a slot to the next body the moment the one holding it is destroyed, so a saved
handle names whichever body the loading run happens to have put there. Restoring
one verbatim writes that body's pose into this entity's `Transform`, every step,
with no error and nothing out of place to notice. So `RigidBody` is transient.
The stable declaration lives in `Body` and `Collider`, while `Motion` stores the
live velocity immediately before a save. After load the ordinary fixed-step
reconcile path rebuilds the body from those columns and restores its motion. A
loaded body therefore takes the same path as one created by `spawn`,
`batchSpawn`, or the world tools.

**`Paused` holds a body rather than hiding it.** Box2D steps a world rather than
a body, and disabling one removes its support from the broad phase. Physics
instead stores its linear and angular velocity in `Motion`, changes it to
static, and leaves it solid and immovable. Removing `Paused` restores the
declared kind and the stored motion. This is why `Body`, `Motion`, and the live
handle are separate components: declaration, resumable state, and native
identity have different owners and lifetimes.

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

A game reads the stream by observing the kinds it wants, one ECS event type per
kind, which is described under [One way in](#one-way-in) along with why
delivery copies nothing.

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
into a batch it owns and frees them with that batch. Retaining the pointer is a
use-after-free that reads as an occasional garbled string.

There are two such batches and they swap at the top of an iteration: one is
handed to Lua and is immutable while it is being drained, and the other receives
whatever SDL delivers meanwhile. A single shared array with a drained count
subtracted from it cannot do the job. `SDL_AppEvent` can run during an
iteration, and from another thread, so growing the array for a new event would
reallocate the one Lua is reading, and freeing the payloads of the events Lua
consumed would free strings out of a list a later event is still recorded in.
Ownership per batch makes both impossible, and an event that arrives mid-drain
simply belongs to the next iteration.

The vocabulary covers what a game can act on and stops there. Displays report
being added, removed, moved, reoriented, rescaled and remoded, each naming the
display it happened to. Windows report occlusion, entering and leaving
fullscreen, a display scale change and a safe area change, beside the states
they already reported. Keyboards, mice and audio devices report arriving and
leaving, and an audio device reports being reformatted as well. A trackpad pinch
arrives as `pinchBegin`, `pinchUpdate` and `pinchEnd` carrying the factor it
zoomed by, and counts as player input for latency. What stays out is what this
engine cannot act on: the joystick family, because every pad is opened as a
gamepad and forwarding both would report one device twice; camera devices and
the 2D renderer's device-loss events, because neither subsystem is used; hit
tests, because none is installed; and ICC profile and HDR state, because there
is no colour-managed path for a game to respond through.

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

Every event that came through the host's queue carries an `arrival`, in the
units `clock.now` reports: SDL's own nanosecond stamp for the event, converted
onto the performance counter. An event that did not, a replayed one above all,
has none rather than a made-up one, because a synthesised arrival would be a
latency measurement of the replay driver. The two clocks are the same clock in
SDL's implementation and not by its contract, so the host measures the offset
between them once at startup rather than assuming one, and both are monotonic,
so the one measurement holds.

Taking a reading where SDL hands the event over instead would be simpler and
would be a floor rather than a measurement. SDL only hands events over while
the main thread is pumping, and most of what a player waits through is time the
thread is doing something else: a frame blocked in
`SDL_WaitAndAcquireGPUSwapchainTexture` cannot pump, and everything that
arrived during that block would be dated to the end of it. The measurement
would be least trustworthy in exactly the frames it exists to catch. Reading
the stamp SDL already put on the event has no such gap, and SDL translates a
driver's own timestamp onto that clock rather than passing it through, clamped
so it can never be in the future.

The six lifecycle events carry no stamp, because SDL hands them to its event
watchers without queueing them and never fills one in. Those are dated where
they were delivered, which nothing reads: `events.isInput` excludes them, since
nobody is waiting on a backgrounding.

### The lifecycle events, and the moment they arrive

SDL treats six events specially and dispatches them from its event watcher
rather than queueing them for the next iteration: `terminating`, `lowMemory`,
and the four background and foreground transitions. Under
`SDL_MAIN_USE_CALLBACKS` that watcher is `SDL_AppEvent`. The reason is on
Android, where the app blocks as soon as backgrounding has been sent, and SDL's
own comment says what that means for an application: it should do its lifecycle
handling in the event filter, while the event is being sent.

So that instant is the only one a game gets, and copying the event into a queue
for the next iteration misses it. On Android the next iteration is after resume;
on iOS SDL has stopped the display link by then. The host therefore answers
these where they arrive, calling one hook per event on the application:
`_lowMemory`, `_willEnterBackground`, `_didEnterBackground`,
`_willEnterForeground`, `_didEnterForeground` and `_terminating`. One per event
rather than one for the group, because giving memory back, saving state,
releasing a graphics device, recovering one and resetting a clock are different
jobs with different deadlines. A hook a game did not write is not an error.

Two things stop a hook from running, and the host checks both. `SDL_AppEvent`
is called from whichever thread produced the event, and a Lua state may only be
entered from the thread that owns it. And an event dispatched into a frame that
is already running would re-enter the state from inside `world:update`. Either
way the hook is recorded and replayed at the top of the next iteration, which is
correct rather than useful: it exists so nothing is dropped silently, not as a
second way of meeting the deadline. Past `terminating` there is no next
iteration at all, so a refusal there is reported instead.

A backgrounding hook is dispatched once per backgrounding rather than once per
event that mentions one, and the foreground rearms it. What it is for is
flushing a checkpoint the game already prepared during a frame, not building
one: at this engine's entity counts, serialising a world inside a platform
callback cannot meet any deadline, and the host says so if the hook overruns.

The event is queued as well as dispatched. The hook is where a game meets the
platform's deadline; the stream is where it observes the change like any other,
and those answer different questions.

The engine answers five of the six. `_lowMemory` collects, a full cycle rather
than a step, because what is being asked for is the low-water mark and the pause
it costs is cheaper than being killed. `_willEnterBackground` suspends and
flushes the checkpoint below. `_didEnterBackground` waits for the device to go
idle, so nothing is in flight across a suspension whose length is not ours.
`_didEnterForeground` unsuspends and restarts the clock, because whatever the
platform did while we were away is not elapsed game time and a dt of it would
put every fixed step of the interval through in one frame. `_terminating`
offers the checkpoint one last time, since a termination out of the foreground
never went through a backgrounding.

Suspension is set and cleared in the hooks rather than folded out of the queued
events, which is where it used to be. On Android the process blocks as soon as
the backgrounding has been dispatched, so the drain that would have folded it is
after the resume: acting on the event is acting a whole suspension too late.

`_willEnterForeground` is deliberately unanswered. It says the application is
about to be visible again and the engine has nothing to do before the platform
is actually drawing, which is what `_didEnterForeground` beside it is for. A
game that wants the earlier moment observes `events.on.appWillEnterForeground`.

Releasing the graphics device on backgrounding, and recreating it on the way
back, is where an engine that has shipped to Android ends up, and it is a stated
gap rather than a half-written path. Three things have to be true first. Every
GPU handle in the process would have to be reachable from one place to be
released and recreated, and they are not: they belong to the backend, the
deferred pipeline, the image array and every buffer, and a recreation that
missed one is a use-after-free rather than a black frame. The image array would
have to be refillable, and the pixels behind it are released at
`Renderer:registerImage` because the array holds them, so there is nothing on
the CPU to upload again. And it would have to be testable, and none of these
events fires on a platform the suite runs on, so a recovery path written now is
one whose first execution is on a player's phone.

### The checkpoint, which is bytes and not a callback

A game could not save state on being backgrounded at all, and the plumbing is
the easy half. The contract is the part that decides whether it works.

At this engine's entity counts a world is not serialisable inside a platform
callback. iOS allows roughly five seconds from the hook being entered and
Android rather less, so the clock is running while the callback runs and a
callback that walked four million entities would be killed part way through and
leave nothing behind. The host complains past 250 ms for that reason. So
`_willEnterBackground` writes a buffer the game already had.

`app:stageCheckpoint(bytes)` is how it gets one, called from an ordinary system
on an ordinary frame whenever the state worth keeping has changed. It takes
bytes rather than a function that produces them, and that is the whole design.
A function would let a game postpone the serialising into exactly the callback
that cannot afford it while looking like it had prepared something; a string
cannot, because by the time one exists the expensive half has already happened
on a frame that could pay for it. The host times the hook and says so past
250 ms, which is the check on the rest.

Staging again replaces what was staged: there is one checkpoint, not a queue.
Staging once and backgrounding twice writes once, on the argument the host
deduplicates backgroundings with, which is that the second write is the one that
gets interrupted and it had nothing new to say. The write goes through a
neighbouring file and a rename, so what is on disk is either the previous
checkpoint or this one and never half of either. `app:readCheckpoint()` is the
other half, read while building the world; nil covers a first run, a game that
staged nothing and a file the player deleted, and none of those is an error.
`config.checkpoint` names the file, and staging without one raises rather than
holding bytes that will never be written.

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

## Native platform utilities

The smaller operating-system services stay small modules rather than becoming
an `Application` grab bag. `tecs.system` holds URLs, locale preference, power,
the simple blocking message box and asynchronous file and folder selection;
`tecs.sensors` owns standalone sensor handles.
Standard cursor shapes stay on `Input`, because cursor choice is an outbound
input command on the same seam as visibility and relative mode.

Device enumeration and microphone capture went the other way and are inside
`tecs.audio`, beside the mixer, rather than being a module of their own. They
were briefly two modules that differed only in the case of one letter, which is
the worst spelling a distinction can have. The mixer and the device it opens
are one subject at two levels: a game that wants a particular output names a
device from `tecs.audio.playbackDevices` and passes its id to
`tecs.audio.Audio.create`, and having to know which of two modules each half
came from bought nothing. `src/tecs/platform/audio.tl` is still its own file
and still only reaches SDL, so it is what the namespace searches first and a
game listing devices never loads a mixer.

File and folder dialogs are the exception to "one SDL call and return". SDL
retains a callback and may enter it from a thread the VM did not create, so
`native/dialogs.c` owns that callback, copies its answer behind a mutex, and
`tecs.system` polls it into a `Future` on the main thread. A Lua `ffi.cast`
callback would be shorter and would make the program undefined on exactly the
platform path the dialog exists to use.

Microphone capture avoids the callback family for the same reason. SDL opens
an audio stream with no callback, its audio thread fills the stream, and Lua
pulls complete float32 frames with `Microphone:read`. That also gives capture
an explicit lifetime and a natural nonblocking `availableFrames` query instead
of making game code run at device-thread cadence.

## Touching the filesystem

`tecs.paths` answers where a path is; `tecs.filesystem` is what to do once you
have one. It is one backend call per function and nothing composed out of
several, and on SDL each of those is the obvious call: `SDL_GetPathInfo` behind
`info`, `exists`, `isFile` and `isDirectory`, `SDL_GlobDirectory` behind `list`
and `glob`, `SDL_LoadFile` behind `read`, then `createDirectory`, `remove`,
`rename`, `copy`, `write`, `currentDirectory` and `userFolder`. No virtual
filesystem and no invented path scheme, so a failure is the platform's failure
and the name says which call to read about. Like `proc` it initialises no
subsystem and is more useful with no window than with one.

`openWrite` and `openRead` are the pair that is not one call, and they are the
exception the streaming body needed: a backend that can open a file is asked
to, and one that cannot is buffered over, so a download that ends in a file and
an upload read out of one both work whatever a port supplied.

Nothing here reaches the operating system, because `adapter` names storage as a
seam and a seam that covered only _where_ content is would leave every read of a
path under that root going to the host's own file API anyway. So the calls are
`storagebackend`'s and what stays in this module is what a port should not have
to write twice: the argument checks, the record of what has been opened, and the
four questions that are one backend call answered differently.

Reading is one of those calls rather than something `assets` owns, and there is
exactly one reader in the tree, because a second one would mean a file opened
through the wrong one never reloads. `read` is the load plus the record of what
this process has opened that `watch` polls, and the decodes in `assets` write
into that same record through `note` instead of keeping one of their own. Bytes
are bytes, so nothing at this layer can tell a font's metrics from a level:
whatever asked for them names the kind, and an unnamed read is a document.

Enumeration is glob rather than `SDL_EnumerateDirectory`, so no FFI callback is
installed for a walk; the list comes back as one allocation holding the array
and its strings, freed in one place the way the clipboard's mime list is.
**`SDL_GlobDirectory` recurses when nothing stops it**: with no pattern it
walks the whole tree and returns `/`-joined relative paths, and `"*"` is one
level only because a wildcard never matches a separator, which is what `list`
is. The other surprises are documented rather than smoothed over:
`createDirectory` makes parents and leaves an SDL error set even when it
succeeds, `remove` reports success when there was nothing there, `rename` and
`copy` overwrite silently, and `userFolder` is legitimately nil on a platform
with no such folder.

Everything blocks, and that is the whole of stage one. A path call is one
syscall rather than another program's lifetime, which is what put `proc` on a
worker, and `SDL_LoadFileAsync` reads a file rather than a directory, so it
would leave the one unbounded case, a recursive glob over a large tree, exactly
where it was. That case runs on a worker instead: every function takes a path
and returns a value, so nothing crosses a thread that must not.

`SDL_Storage` is deliberately not what the SDL backend is written against. Its
readiness model has no equivalent in a path call and, on a desktop, no test:
every backing it can have here is the plain filesystem, so a spec would only
ever exercise the ready-immediately path and would prove nothing about the model
that is the reason to have it. So it belongs to whichever port needs it, which
is exactly what the seam is for: a target whose content is a title storage
writes `SDL_OpenTitleStorage`, its readiness wait and its `SDL_ReadStorageFile`
into a backend of its own, in a module the engine never sees. Its paths being a
different space costs nothing either, because every path that reaches a backend
was built by resolving against a root the same platform minted, so a port that
answers `""` for its base receives back exactly the storage-relative paths it
handed out. The engine concatenates and never interprets, which is why nothing
above resolves a path.

## A value that settles once

Several things in this tree are work in flight: an asset decode, a child
process, a request. Each of them used to own a private cell with four states, a
failure string, a registry keyed by a worker correlation id, and a blocking wait
that pumped, and each of them had a different word for the same four states.
[`Future.tl`](src/tecs/Future.tl) is the shape they share, written once.

```lua
local Future = require("tecs.Future")

tecs.proc.run({ args = { "git", "rev-parse", "HEAD" } })
    :map(function(result) return result.output end)
    :recover(function() return "unknown" end)
    :onSettle(function(future) print(future.value) end)
```

**`status` is a plain field.** `"pending"`, `"ready"`, `"failed"` or
`"cancelled"`, read directly rather than through a method, because several call
sites read it once a frame and a field read plus a string compare is what that
should cost. `"cancelled"` is a state of its own rather than a kind of failure,
because `recover` must not run for it: a caller who cancelled a load did not ask
for a fallback value.

**A `Source` is the whole driver interface.** Two functions carry it: `poll`,
which takes whatever is ready, and `advance(ms)`, which blocks for up to that
long and takes whatever arrives. That is all a worker channel is and all a curl
multi handle is, so the same hook covers a decode, a subprocess and a transfer.
`poll` is what the loop calls once a frame, and `wait` spends its budget inside
`advance` rather than spinning. A third, `cancel`, is optional and is the honest
answer to work that cannot be stopped: a source with no hook leaves it running
and stops caring, rather than the interface pretending every source can be told
to stop.

**The budget is wall clock.** Every wait this replaces subtracted the nominal
slice size whatever the slice actually cost, and a source returns as soon as one
message arrives, so a "5000 ms" wait was really "at most 312 messages". The
default and the slice size live on the source, which is what lets a subprocess
keep a longer default than a decode without a second convention.

**Settling drains iteratively.** A dependent that settles another future extends
a loop instead of the stack. `flatMap` is what makes that necessary rather than
tidy: it builds link N inside the settlement of link N-1, so a paginated fetch
written as a recursion is a chain as long as there are pages, bounded by nothing
in the source text and failing inside the frame pump. A thousand-link chain runs
at 38 frames of Lua stack; recursing runs at 7031. It also makes re-entrancy
legal by construction, so a listener may settle, cancel or register on anything,
including the future it is being called from.

**Order is registration order,** at both levels: the drain is first-in-first-out
across futures, and a future's listeners run from the first registered. Java
runs dependents backwards because a Treiber stack is what one compare-and-swap
buys, and dropping the concurrency drops the reason -- every source here settles
on the thread that pumps it, so the dependent list is a plain array. Order is
observable rather than academic: a listener that registers an image allocates
through a shelf packer whose coordinates depend on arrival order and end up in a
`Sprite`, which a snapshot stores. That removes order as a source of
nondeterminism; it does not make the system deterministic, since two decodes
still race on the worker and arrive in whatever order they finish.

**Cancellation is reference counted,** because a shared root is real: two loads
of one path that overlap get the same future, and one consumer giving up must
not break the other. So `cancel` decrements, and only the last holder settles
the future and asks the source to stop the work -- and only for a future the
source made, since a derived link inherits the source to know what a wait
advances and nothing else. Cancelling a `flatMap` before its outer settles stops
the inner from ever being created, which is the one place the rule needs a
second sentence: there is no inner to cancel after the fact.

**A future is never in a snapshot.** It holds listeners, a source and, through
it, a native handle. What a snapshot does carry is a sequence cursor parked on
one, as a provider name, an entity and a key. `Future.track` is the engine's one
registrant in the sequencer's awaitable registry, so a program can park on a
decode or a request, and it is keyed by entity and key rather than by identity
so the wait survives a round trip the future cannot. After a load nothing is
tracked, `isPending` answers false, and the parked cursor resumes on the next
fixed step; a game that wants the wait to mean something re-issues the work and
re-tracks it under the same key.

## Asking the network for something

Every HTTP request is a future, which is the easy half. The two questions worth
recording are who drives the transfer and what a body is.

**A game never pumps.** libcurl's multi interface has to be turned for a
transfer to move, and the first shape of this made a game call `client:pump()`
once a frame. That is engine work in a game's hands, and it is the same work
`assets.update` and `proc.update` already do in the loop for the same reason: a
decode that finished has finished, a child that exited has exited, a transfer
that completed has completed, and nothing else in a frame is obliged to ask.
The reason it was not simply a third line in `Application` is that `assets` and
`proc` are module singletons and a client is an object a game constructs, maybe
several of. So the clients come to the loop: building one registers it in
`tecs.http.clients`, `close` takes it off, and the application turns whatever is
on the list. That list is a module with no FFI in it, because
`tecs.http.client` loads libcurl the moment it is required and a game with no
HTTP in it must not link one. It holds its clients strongly, so a request whose
future is the only thing a game kept still lands; the price is that `close` is
what ends a client rather than losing the last reference to it, and the
alternative -- a weak list -- is a fire-and-forget request that stops moving
whenever a collection happens to run.

**A body is one value.** The first shape had five: `body`, `bodyBytes` with
`bodyLength` beside it, `into`, and a response whose `body` was nil exactly when
its `path` was not. All of them answer one question, so they became one type. A
`DataStream` is a string, a buffer, a path or a handle, and it reports a length
when something can know one.

What the type is for is `into`, which existed so a 500 MB download would not be
a 500 MB Lua string and was exactly that. Now the native response buffer holds
what has arrived, the pump hands it to the destination and consumes it, and the
next pump starts from empty, so a body bound for a file is held for a frame.
That needed the storage seam to be able to open a file rather than only take
one whole, and it needed the C buffer to be able to give bytes back; the
running total the ceiling is measured against is what keeps `maxBytes` meaning
the same thing whether or not something is draining.

**A request body is not streamed, and the asymmetry is the callback rule.** A
destination is written _between_ calls into libcurl, where Lua may do anything.
Feeding a body happens _inside_ one, through a read callback libcurl calls, and
a Lua callback anywhere in a pump makes the loop around it uncompilable, which
is the whole reason the response callbacks are in C. So a file or a handle given
as a body is read at `send` and libcurl copies it, and an upload costs twice its
size while it runs. Streaming one is a request buffer in `native/http.c` beside
the response one, with a C read callback serving bytes Lua tops up each pump and
returning `CURL_READFUNC_PAUSE` rather than 0 when it runs dry, since 0 is how a
read callback says the body ended. That is a pause protocol across two
languages, and it is not worth writing before something needs to upload
something large. The bound in the meantime is stated rather than implied.

A body is deliberately not a stream in the other sense either. It is only ever
handed over settled, over a string that is complete or a file that is closed,
because a stream the caller must close is a connection held until it does, which
is the one shape a frame-driven client cannot take.

## Shelling out

A command line tool, a resource pipeline or an asset build wants to run another
program, and a game wants to do it between two frames rather than instead of
them. `tecs.proc` is that, and it is one of the few subsystems that is more
useful without a window than with one, so it initialises no SDL subsystem and
works under a plain interpreter.

```lua
local run = tecs.proc.run({ args = { "git", "rev-parse", "HEAD" } })
-- ... frames pass, the loop pumps ...
if run.status == "ready" and run.value:succeeded() then
    print(run.value.output)
end
```

A run is a [`Future`](#a-value-that-settles-once), so the words for how it
ended are the ones every asynchronous thing in the tree uses, and a caller who
wants the answer rather than the polling writes
`proc.run(...):map(function(result) return result.output end)`.

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
child, and a run whose child was still going ends at `"cancelled"` rather than
at a status that implies it finished. That includes a child the kernel never
reaped: its future is settled on the way out rather than dropped, because the
runner is about to stop and nothing would ever answer for it.

**A failed spawn is a status, and an exit code is not one.** A program that
cannot be started settles at `"failed"` with `error` set, the way a failed
decode settles rather than raising. A child that ran and exited 3 settles
`"ready"` carrying a result that says 3, because the code is the answer rather
than an error, and `Result:succeeded` is the separate question about it. Reading
that the other way would make every non-zero exit propagate as a failure through
`map`, which is wrong for everything that shells out to a tool whose exit code
is data.

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

## Networking is a transport, and the loop drives it

[`net.tl`](src/tecs/net.tl) exposes SDL3_net's two transport shapes without
inventing a protocol above either. TCP is an ordered byte stream, so a write is
not a message boundary and reads are allowed to be short. UDP preserves a
packet boundary and promises neither delivery nor order. Length prefixes,
serialization, reliability and replication all need requirements of their own;
putting one guess here would make a game work around the engine to choose
another.

Resolution and client connection are `Future` sources because both settle once,
can fail before producing a usable object, and SDL3_net already supplies the
bounded poll and wait operations a source needs. Servers, streams, addresses
and datagram sockets are not futures: they remain useful across many frames and
own a native lifetime, so each is closed explicitly. A received packet refs its
source address before SDL's packet is destroyed, which makes the ownership
visible rather than leaving a borrowed pointer in a Lua record.

The application does not poll networking unconditionally. `net.poll` is one
nonblocking call a game makes while resolutions or connections are pending,
and `Future:wait` drives the same source when blocking outside a frame is the
honest operation. That leaves a game with no network work off the path and lets
a headless server using the ECS drive exactly the same module without an
`Application`.

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

## Measuring allocation

A frame that allocates has bought a collection it will pay for later, in some
other frame. Frame time cannot see that either: the cost lands away from where
it was incurred and arrives as a tail nobody can attribute. So steady-state
allocation is measured on its own, by `make bench-alloc`, and held by
`spec/allocation_spec.lua`.

Measuring it is mostly a matter of not being fooled three times.
`collectgarbage("count")` reports the heap rather than what was allocated, so a
collection inside the window eats the delta and more work can measure as less:
the collector is stopped for every window. `collectgarbage` is not compiled by
LuaJIT, so a probe inside the frame aborts every trace that would have covered
the frame and the compiler then spends the run recording and recompiling, which
is heap traffic charged to the frame; four probes a frame are enough to double
a reading and to make two runs of one binary differ by 40%. And the compiler
removes allocations that do not escape a trace, so the
same source measures differently depending on what happens to be compiled.

The bench answers all three. Each regime is measured twice: once with no probe
in the frame at all, which gives the total, and once with probes at phase
boundaries, which gives the breakdown into `sim`, `extract`, `render` and
`submit`. Both count only the frames `jit.attach` reports the compiler did not
touch, and the report prints how many of those there were, so the two columns
can be read against each other rather than taken on trust.

The spec cannot be that precise, and the reason is worth writing down. Under
Busted the engine runs on a plain `luajit`, which does not reserve the
machine-code arena `native/mcodearena.c` reserves at startup, so LuaJIT cannot
place mcode near the interpreter, flushes its whole trace cache every few dozen
frames, and starts again: three flushes in a hundred and twenty frames, and a
frame the engine's own binary reads in hundreds of bytes reading thousands
there. Turning the compiler off would make the reading exact and is worse than
the imprecision, because `jit.off()` followed by `jit.flush()` on a process
that has already run a device leaves LuaJIT reporting `jit.status()` true and
unable to compile anything afterwards, which costs a later spec a 780x slowdown
and fails the two specs that watch the process size.

So the spec holds what can be held without touching the compiler: a ceiling on
the frame well above the true figure; that the figure does not grow with the
size of the world, which is what a per-row allocation cannot hide from; and then
each piece of the frame path measured on its own, where the compiler's
contribution to a window is roughly fixed and divides away while a per-call
allocation does not. Extraction, the hierarchy dirty sampler, a two-pass render
graph and a compute pass are each read that way, and the staging buffer's two
properties are read exactly, since a single call can be. Three of the assertions
are not measurements at all: a cursor does not escape the loop that opens it, so
LuaJIT removes the allocation once it has compiled the traversal and no reading
can see it, and the frame object and the closure the event drain is handed are
one object each per iteration, which is too small to see past the compiler's
noise and just as real. All three are counted rather than weighed.

What a steady-state frame costs today is a little over 300 bytes for a still
scene and exactly 144 more for a moving one, and nearly all of it is not the
engine's to give back: SDL hands nine pointers a frame back into Lua, and
LuaJIT boxes each into 24 bytes of cdata that has to be held for the rest of
the frame. The 144 is the two staging flushes. Everything above that has been
taken
out: the pass graph builds each pass's attachments, sampler bindings and
context when the pass is declared and rewrites them per frame; `RenderPass` and
`ComputePass` stage their SDL argument arrays in module-level scratch, on the
same one-call-at-a-time terms `begin` already had; the pass objects, the frame
object and the buffer lists the call sites hand them are held and filled in
again; and the world's dirty set is walked directly rather than through the
iterator closure `world:dirtyArchetypes` builds per call.

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

Pushing or popping a blocking layer drops every pending edge, on every device,
in both tiers. An edge belongs to whoever could read input at the moment it
happened, and a layer on the far side of that boundary has no claim on it: an
`f` typed into a debug overlay must not toggle the game's fullscreen the
instant the overlay closes, and a menu opening mid-frame must not act on a key
pressed before it existed. The frame's accumulated text, wheel and mouse motion
go with them, because those are measured over an interval rather than held, and
a camera handed the motion made inside a menu jumps the frame it closes. Held
buttons, pointer positions, the modifier mask, fingers and the pen all survive,
because the platform is still reporting them and a key still down is still
down. A non-blocking overlay is not a boundary: it consumes nothing, so the
layers beneath keep reading the stream they were already reading, and clearing
there would be the same defect pointing the other way.

A gamepad is not part of that state. It has identity, a lifetime shorter than
the process, metadata, capabilities that differ between devices, and outputs, so
it is an object reached through `input:gamepads()` and it answers for itself.
Two pads sharing one button set is not a simplification but a defect: pad A
releasing a button releases pad B's. Devices already attached are opened before
a game's entry plugin runs, because the platform reports additions and not
devices that were there all along.

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

Queries are never answered by polling the device. SDL's own state-reading calls
are not used at all, not even once at startup, because a poll bypasses replay,
layers, edge detection and latching, all of which are the point. The state is
fed typed events and holds no globals, so a recorded session replays by feeding
the same events back through `events.source`, and every outbound command goes
through a backend for the same reason.

## The Tecs binding

The ECS and the engine are one tree, and the boundary between them is a
dependency rule rather than a repository. A game requires `tecs`, the whole
surface; engine code requires `tecs.ecs`, which carries what the engine actually
uses. That runs one way on purpose, because the surface exports the engine
modules and a module that also depended on the surface would be a cycle, which
Teal rejects even through a type-only require.

`Renderer` is where the two meet, and the only module that knows about both
archetypes and GPU buffers.

It is two halves and the seam between them. `Extractor` is world-facing:
queries, archetype runs, relayout detection, dirty gating, producers and the
interpolation alpha, writing instances straight into mapped staging and never
touching a device. `Backend` is device-facing: the buffers, the flush, the
mark/scan/compact cull, the deferred pass graph and the image array, and it
names no world, query, archetype or component.

Both halves run on the main thread, one after the other, and the seam is not a
thread boundary. It earns its place without being one: a world extracts with no
device behind it, which is what a headless run is; the backend is exercised
against a device with no world behind it; the dirty bits a frame consumes are
consumed in one place rather than wherever a draw happened to read them; and no
GPU handle ever lands in ECS storage.

`FramePacket` is everything that crosses. It carries the staging slot that was
written, the byte ranges within it, the counts, a copy of the camera and the
frame's lights, and it carries no instance bytes at all: those are already in
the staging the backend owns, and copying them into a packet would be the
intermediate copy the design exists to avoid.

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
than a second model: `animation.fromAseprite` walks the export and writes what it
finds through the same builder everything else uses, so a reader for the binary
`.aseprite` format populates the same sheet without reshaping anything. Both of
Aseprite's frame layouts are read, the array and the object keyed by frame name,
the second in sorted name order because the names carry the frame number.
Trimmed exports are not: `spriteSourceSize` is ignored, so export with trimming
off.

`animation.build` is the model's own front door, for an atlas from any other tool:
frames, tags and slices in any order, `finish` to register. `animation.grid` cuts a
uniform grid (with an optional margin around it and spacing between the cells)
and `animation.rects` takes an explicit list, and both are that builder with a loop
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

Reporting settles what the engine does and leaves open what a game does, which
is why the same number is also a question: `Renderer:depthSortCollapse` answers
the world units that collapse onto one depth value, and zero when none do.
Dividing `layers.maxY` and `layers.maxZ` by it raises the sort's resolution by
the same factor, so a game trades world size for a sort that works and can ask
again to see that the trade took. The number is derived on the call rather than
stored when the target is made, because it is a comparison against extents a
game moves and a stored one would go on answering for extents it no longer has.
A log line on its own leaves the shortfall observable and unanswerable, and
being answerable is the whole reason it is reported rather than raised.

A colour clear comes from the target rather than from the pass, which is right
while one pass writes a target and wrong as soon as two do: the second clears
the first one's result away. A pass may name its own clear, which wins, and
`PassGraph.LOAD` is how it says "load, whatever the target asks for". That is
what a pass accumulating into a target an earlier pass filled needs, and what a
second view's lighting pass will need to leave the first view's pixels alone.

`Deferred` assembles the standard pipeline on it: geometry fills a G-buffer,
lighting resolves it against a storage buffer of lights, composite turns that
into the frame's image in the `scene` target, and present copies `scene` to the
swapchain. Geometry is a callback because what to draw is the caller's problem.
Deferred is what makes light count independent of object count: geometry
rasterises once regardless of how many lights touch it, and lighting runs once
per pixel regardless of how many objects overlap it.

Geometry is the pass that owns depth, testing and writing, so wherever two
instances overlap the nearer one is what the G-buffer keeps. An instance's depth
is the fourth float of its transform vector, and the comparison is
`lessOrEqual` rather than `less`: equal depths let the later fragment through,
so draw order still decides ties and depth only decides between instances that
differ. The three fullscreen passes have no attachment. Each covers every pixel
exactly once and has nothing to be occluded by.

### The seam between composite and present

Composite and present are two passes rather than one because a pass writing the
swapchain is the end of the frame. The swapchain texture belongs to the
presenter once the frame is submitted, is not created with the sampled usage
bit, and is not a target the graph owns, so nothing can read it and nothing can
follow it. `scene` is what buys the gap: a graph target like any other, frame
sized, sampled, and readable between frames.

Everything declared between the two sees it. The forward pass below is the first
and drew the shape the rest take. A post-process reading `scene` and writing it
back, or reading it and writing a target of its own that a later pass folds in.
A second view compositing into a rectangle of the same `scene`. Those two do not
exist yet and all three were going to need the same thing, so it is one target
and one pass rather than several arrangements that unpick each other.

`scene` declares no clear, so every pass that writes it loads what is already
there and each adds to the last. Composite is what makes that defined: it covers
every pixel and runs first, so nothing downstream reads memory no frame has
written. Present is declared last, because the graph runs passes in declaration
order and present is the one that writes the swapchain; anything added to the
seam is declared above it.

`Backend:captureTexture` returns `scene` rather than `lit`, so a screenshot is
the image that was presented rather than the image before whatever the seam
holds. What the seam costs is one RGBA8 target at frame size, about 8 MB at
1080p, one more render pass, and one more fullscreen triangle sampling a texture
the size of the screen.

### Alpha is what says a thing is blended

A deferred G-buffer has nowhere to put partial coverage. It is written with
replace, so a fragment at half alpha would overwrite what is behind it rather
than let any of it through, and a `Tint` alpha below one therefore did nothing
at all. That is a broken value rather than a missing feature, and the forward
pass is what fixes it: an entity whose alpha is below one skips the G-buffer and
is drawn over the composited image with straight alpha instead.

The alpha itself is the mark, rather than a `Blend` component or a per-layer
flag. A component would make a fade into a structural change per entity per
frame, which is the most expensive thing this ECS does, and it would let two
answers to "how transparent is this" disagree. A layer flag would make the
decision per layer when it is plainly per entity. The alpha is a float already
being written into the instance, and reading it is free.

Free at the instance, and not at the cull. The mark pass reads a sixteen byte
cull bound for every instance in the world every frame, drawn or not, and
reaching into the instance for one float would be a sixty-four byte gather
against exactly the traffic that split is there to avoid. So the lane travels in
the bound: a half extent is a length, its sign carries nothing, and extraction
negates the first of the two for a blended row. The cull takes the magnitude for
the view test and the sign for the lane.

The forward pass lights itself, which is what makes the alpha a pure coverage
knob. An unlit overlay would have been smaller, and would have meant an entity
fading from one to a half popping from lit to unlit on the frame it crossed. It
runs the same material dispatch and the same light loop the resolve runs, out of
the same scene block, so the only thing that changes as alpha crosses one is how
much of the fragment lands. What it gives up is the G-buffer: blended content
writes no depth, hides nothing behind it, and is invisible to anything that
reads a normal or an emission later.

### Blending is ordered, and ordering is a second lane

Blending does not commute, so a forward pass has to draw back to front, and the
compaction that produces its list is ordered by instance index, which is where
extraction put a row rather than where the scene put it. Depth resolves blended
geometry against the G-buffer and cannot resolve it against itself, because
nothing here writes depth.

So the order is established by a counting sort on the depth the extractor
already computed, for the same reason the compaction is a scan rather than an
atomic append: a counting sort is stable, so the same scene comes out in the
same order every frame. It runs in two stages. The mark pass scans two lanes in
one dispatch over the one bound read it already pays for, packing a rank per
lane into the word it already writes; the opaque lane compacts as it always did
and the forward lane compacts beside it. Then the forward list, and only the
forward list, is bucketed by depth, its buckets scanned, and its entries placed.

Two stages rather than one because the counts a bucketed scan needs are a uint
per bucket per block, and a block per 256 instances of a four million instance
world would be a table larger than the world. Over a list that has already been
compacted the same table is a quarter of a megabyte. That is what fixes the
forward list's ceiling at 65,536 instances: past it the entries earliest in the
buffer are drawn and the rest are dropped, which is the same answer
`setLightData` gives a light beyond the light buffer.

What it costs is five compute passes and a draw on a frame that blends
something, and one branch and one empty render pass on a frame that does not:
the packet says how many rows extraction routed forward, and the whole lane is
skipped at zero. What it gives up is resolution. There are 256 buckets, so two
blended instances whose depths differ by less than one part in 256 draw in the
order the compaction gave them, which is the order the depth test already
resolves opaque geometry in. Raising the count is a constant and a larger counts
table, not a design change.

### Lights are in the world

A light is placed in world units, like everything else, and the lighting pass
is handed the view through `Deferred:setView` so it can take each fragment back
out to the world rather than bringing the lights in. Moving the camera
therefore moves what is lit, and zoom scales what a radius covers on screen
rather than what it covers in the world.

The direction is chosen rather than incidental. Projecting lights on the host
would be the same arithmetic once, but everything that comes after wants a
world-space ray: an occluder mask is built with a world projection and a shadow
march is a march through the world, so the projection would have to be undone
again at the first of them. The view arrives as a centre and a rotation divided
by the zoom, because an orthographic projection inverts to a 2x2 and an offset
and a fragment should pay two multiply-adds rather than a 4x4 by a vec4. A
pipeline nothing sets a view on centres one on its own target, which makes
world units target pixels and is the same default the renderer's camera takes.

### Materials say which way they face

The G-buffer's normal attachment carries a real per-fragment normal, and what
writes it is the material. A `MaterialOutput` starts from `materialDefaults`
and the default is flat, facing the viewer, because a 2D sprite genuinely has
no normal: it is a picture of a surface rather than a surface, and inventing a
curve would light every sprite as though it bulged. So the answer is per
material rather than per texture, and a material claims a shape only where its
own silhouette is one. `circle` and `ellipse` return a dome, `capsule` returns
a cylinder with hemispherical caps, and everything else is flat. A sprite that
really wants a normal per texel wants a normal map, which is a sidecar image
and a separate piece of work.

The vertex shader hands the fragment shader the instance's rotation and the
axes its scale mirrored, and not the scale itself. A normal usually transforms
by the inverse transpose of the basis, which divides the in-plane components
through by the scale and would leave every shape larger than a unit quad
reading as flat. That is right when the third axis has a scale of its own to
stay in proportion with, and here it does not: a 2D transform says how wide and
how tall a shape is drawn and nothing about how far it stands out of the plane.
A shape is taken to swell with itself, which makes the scale drop out.

No attachment was added for this. The normal target already existed and was
already being written, with a constant; four colour attachments is what a
render pass allows and the G-buffer is using two of them.

### Lights are binned into tiles

A fragment consults the lights whose tile it is in rather than every light in
the scene. Without that the loop runs its whole body for every light however
far away it is, because falloff clamps to zero rather than rejecting, so a
scene's light count is a per-pixel cost: at 1280x720 with 256 lights each
reaching a small part of the view, the lighting pass measured 9.8 ms a frame
against 0.8 with binning.

The grid is in world space. It covers the world rectangle the camera can see,
so a light's position and its radius are already in the space the tiles are
measured in and the zoom enters once, as the half extent of that rectangle.
Binning in device coordinates would mean projecting a radius, which is not a
length under a projection. The rectangle is resolved once per frame and read by
both the pass that fills the grid and the pass that reads it, because a grid the
two disagree about puts a light in a tile nothing looks in.

It is a fixed count of tiles rather than a fixed tile size in pixels, so its two
buffers are allocated once and never replaced while a frame in flight is still
reading them, and a tile holds a bounded number of lights.

The fill is a thread per tile walking the light buffer, rather than a thread per
light scattering into the tiles it covers. The scatter does less arithmetic and
needs an atomic to claim a slot and a pass to zero the counts first. Gathering
needs neither: a tile is written by the one thread that owns it, so a count is a
local variable until it is stored and the list comes out in light-buffer order
every time. That order is worth having rather than merely free. Summing a tile's
lights is floating-point addition, which is not associative, so a list in a
different order sums to a different last bit; the rule here is that a result
nothing can observe an order in may use an atomic, and this one would have
needed the argument made. Gathering means the question does not arise. The cost
is tiles times lights, which is a few hundred comparisons per thread against the
millions of pixels it saves.

It runs every frame, including a frame with no lights at all, because it is the
only thing that writes the counts and a frame that skipped it would leave the
last frame's lists standing.

### Two shadows, because one of them cannot reach ambient

An occluder puts its silhouette into a mask, and every light marches that same
mask, so blocking light costs one drawing of a caster rather than one per light.
A drop shadow throws a stretched copy of a caster along the ground and darkens
what it lands on. They look like one feature at two strengths and they are not:
the mask is read inside the light loop, so the most it can take away is a
light's own contribution, while the drop shadow multiplies the sum the loop
produced and so reaches the ambient term, which the mask has no output at all
against. A black light over full ambient is the case that separates them, and it
is a pixel test in `spec/shadow_spec.lua`.

They are exclusive per entity, which is also a decision rather than a
limitation. A crowd of light-blocking silhouettes merges under the mask's max
blend into one flat mat of darkness, so the thing that wants a contact shadow is
exactly the thing that must not be an occluder.

That exclusivity is what let the role fit in the bound. A half extent is a
length, so neither of its two signs carried anything, and two signs name exactly
four states: opaque, blended, occluder, drop-shadow caster. A row therefore says
what it casts in bytes the cull already reads, and the mark pass scans a third
lane as a `uvec3` add under the barriers it was already taking, over the one
bound read it already paid for. It never touches the 64-byte instance to find
out. The caster's height rides above the clip region in the float that carries
its texture-array layer, which had room for a third field and no more.

The lane's predicate is its own rather than the view's: a rectangle wider than
the view by a shadow margin, so a wall just off the left edge still casts across
the pixels that can see it. A fan-out living inside the ordinary cull inherits
that cull's viewport and cannot express this.

Overlap resolves by `min` and `max` rather than by an accumulate, and both
commute, so what a pixel holds is a function of the set of fragments that
covered it and not of their order; on an unsigned normalised target that is bit
exact. Nothing in the subsystem uses an atomic, for the same reason nothing else
here does. The one cap that binds, four lights per caster, is applied by
descending weight in a fixed comparison network rather than by buffer order: a
cap that binds by buffer order drops whichever shadow sits later in the buffer,
which can be the brightest, and makes shadows move when an unrelated light is
spawned and the slots shift.

Off, which is the default, the whole of it costs one more count in a scan that
was already running. On, it costs three targets, four passes, three pipelines,
two dispatches and a list, on every frame whether or not anything casts. That is
a setting rather than a count taken off the frame because the alternative is a
pass graph whose shape depends on what a world happens to hold this frame and a
lighting pipeline rebuilt the first time something casts. The per-pixel cost is
bounded the other way instead: the march's step count is adaptive, clamped down
by the light's own attenuation to four, and skipped entirely below a twentieth.

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

The index rides in `origin.z` beside the texture-array layer and the caster
height, as `height * 16384 + clip * 64 + layer`. Each is a small integer
bounded by what it counts, which is the array's 64 slots, 256 regions and 256
height steps, and a float32 represents integers exactly to 16,777,216, so the
largest value the three pack is 4,194,303 and every one of them comes back out
exactly: the shader takes the layer with a modulo, the region with a division
and a modulo, and the height with a division. That keeps the instance at four
vec4s, which is the point. `instancelayout.packSlot` owns the packing and
`assets/shaders/include/slot.glsl` owns the recovery, so the renderer's sync,
the text producer and the particle pool state it once between them.

Not clipping costs nothing. An archetype with no `Clip` column is written by a
loop that never mentions a region, and the float it writes is the layer as it
always was. In the fragment shader the index is a flat varying, so an unclipped
instance takes a branch its whole primitive agrees on and never reads the
region table; and the test lands on the coverage the material already returned,
leaving through the `discard` that was there for distance fields rather than
adding one.

The cull knows nothing about regions. An instance entirely outside its region is
drawn and thrown away a fragment at a time, which is correct and wasteful, and
rejecting it in the mark pass beside the view test costs more than it saves.

Two things stop it. The pass reads a sixteen byte bound for every instance in
the world every frame, drawn or not, and never touches the sixty-four byte
instance, which is the whole reason the bound is a separate buffer; the clip
index is in the instance, packed into `origin.z`, and there is nowhere in the
bound to move it to, because both half extents' signs are already the role and a
region index is eight bits rather than one. A parallel buffer of indices would
avoid the gather and still add a quarter to the traffic of the one pass that
reads every entity, to serve the few that clip.

The second is that the case which would pay for it is the case the test cannot
reject. Clipping is what a panel with a scrollable list inside it uses, and a
panel sits on a screen-space or virtual-coordinate layer, which writes an
`UNBOUNDED` extent precisely so that a world rectangle cannot cull what is on
screen. An unbounded box overlaps every rectangle there is, so a region test in
world units keeps every one of those instances. What is left over is world
content that is inside the view and outside its region, bought at a per-entity
cost across a four million entity scale bar.

What would change the answer is a pass dispatched over the clipped runs alone,
which extraction already knows the extents of, rewriting each of their bounds
from the instance it is entitled to read because that row clips. It charges
nothing to a row that does not, and what it costs instead is a second copy of
extraction's bound and placement arithmetic living on the GPU, where it can
drift from the one that produced the rows. That is a larger change than the one
it replaces, and it is not built either.

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

## Particles are emitters, not entities

An entity carrying `ParticleEmitter` is an emitter. Its particles are not
entities, are not components, and never cross back to the host at all: their
position, velocity, age and lifetime live in a storage buffer that the CPU
never reads and the vertex shader never sees, and a slot in it is handed out
once, at spawn, and held until the particle expires. Four thousand particles
cost three dispatches and no per-frame host writes; what that buys is paid for
by not being able to inspect, move, kill or count one of them.

Three things divide the work. An `Effect` is immutable data describing how
particles spawn and evolve, built by `particles.effect`, registered once under a
name and shared by every emitter naming it. The emitter component names an
effect and carries playback state, a seed and a few per-instance scales, and
deliberately nothing else: if an instance could override every effect field then
effects would stop being reusable GPU data. A pool owns one run of the instance
buffer, sub-allocates a contiguous slot range of the effect's capacity to each
emitter, and records the passes that fill it.

Drawing is not new work. A particle written into the instance buffer is an
instance: the same sixteen floats, the same four bound floats, the same mark,
scan and compact, and the same indirect draw. The pool is an `InstanceProducer`
whose `takeDirty` is always empty, which is what gives it a region of the
instance and bounds buffers the host flush never covers, and a
`Backend.ComputeStage`, which is what lets it write that region between the
staging flush and the cull. Nothing downstream was taught about particles.

Three compute passes, in order. **Emit** is one thread per emitter: it advances
the schedule, carries the fractional accumulator, fires the bursts whose time
has passed and reserves a block of the emitter's own range. **Spawn** is one
thread per pool slot: a slot works out arithmetically whether it falls in its
emitter's reserved block, and if it does it draws its lifetime, speed,
direction, size and rotation and writes them. **Simulate** is one thread per
pool slot too: it integrates whole fixed steps and writes the instance and the
bound beside it. Emit and spawn are separate because the schedule is per
emitter and the work it decides on is per particle, so a burst of four thousand
is four thousand threads rather than one thread going round four thousand
times.

Slot allocation is an `atomicAdd`, and the ordered scan the compaction uses is
not the right mechanism here. The rule that scan exists for is that a
_permutation the image can see_ must not depend on thread scheduling; a
particle's slot is assigned once and held for its whole life, so two particles'
relative draw order is fixed from the moment both exist and the scene cannot
shimmer. Emitters also do not share an arena: each has its own range and its
own cursor, so the only contention possible is within one emitter.

The emitter presents no bound to the cull, because the emitter is not in the
instance stream. Its particles are, one bound each, written by the simulate
pass from each particle's own position and size by the same formula
`instancelayout.extentOf` uses. Culling is therefore exact and per particle,
which a conservative bound around an emitter could never be, and it costs
nothing extra because the pass is already writing the instance beside it. A
slot with no live particle writes `instancelayout.HIDDEN`, which is what a
reserved run has always written, so a dead particle costs a bounds read and a
scan lane and never reaches the draw.

Randomness is a counter-based hash of the seed, the emitter's generation, the
particle's serial and a lane per property, rather than a generator carrying
state. Two consequences follow. Adding a randomised property does not shift
every other random choice, so an effect edited to randomise its rotation keeps
the sizes it had. And a particle's constants are recomputed each frame rather
than stored, which is what keeps its state at eight floats: seven hash draws
are cheaper than seven floats of memory traffic per particle per frame.

Integration is whole fixed steps against the emitter's own clock, so two
machines fed the same steps hold the same field however many frames either
drew, and an emitter that is paused, stopped or held by the `Paused` tag stands
still while the world goes on drawing. Smoothness is bought presentationally:
the instance position carries one extrapolation term along the particle's own
velocity, applied to the output and never to the state, so it cannot feed back.

Animated particles are the frame table's second caller and build nothing new.
Writing `rate = tickCount / (lifetime * stepsPerSecond)` with looping off makes
a particle traverse its cycle exactly once over its own life and clamp at the
end, so a randomised lifetime randomises the playback speed. Per-frame
durations, reverse and pingpong all arrive already spent at build time, and
there is no second registry, no second table and no second answer to which
frame a thing is showing.

An emitter dirties nothing, ever, while its whole field moves every frame, and
unlike an animated sprite there is no archetype bit that could be read instead.
Any gate of the shape "nothing is dirty" concludes wrongly here, so the pool
publishes the answer itself through `ComputeStage:active`, counting its own
live emitters and holding the gate open one frame past the last of them so the
pass that hides their slots is the one that runs. For the same reason the host
walks every emitter every frame rather than gating on a dirty bit that will
never be set; emitters are counted in tens, so the walk is cheaper than any
arrangement that tried to avoid it would be to get right.

A snapshot carries the emitter and not the field, which is the shape audio is
already in: the configuration, the seed and the playback state cross, and not
one particle does. What crosses for the effect is its name. An effect's index
is `#registry + 1` at the moment it was registered, so it records where in one
process's registration order the effect landed and means nothing outside it: a
plugin installed earlier, or a registration behind a condition that was true
last run, moves every index after it, and a saved one then names whichever
effect the loading process put in that place. Unlike a material's number that
is not even a rebuild away, since nothing but call order decides it. So a name
is required at registration, a name already taken is refused, and a snapshot
naming an effect this build does not have raises and says which one. Resolving
it to something else or dropping the component would both load without a word
and play an effect nobody asked for, which is the failure the name exists to
prevent.

`finished` answers exactly from the schedule and the longest lifetime, which is
what almost every "has the explosion ended" question is actually asking;
`estimatedCount` integrates the schedule and subtracts expirations, and its
name carries the caveat. Neither reads anything back, because a readback here
is a pipeline stall.

**Particles are opaque.** The forward blended lane exists and nothing
particle-shaped reaches it: routing into it is extraction negating the first
half extent of a cull bound, and the simulate pass writes every particle's bound
with both extents positive. So a particle goes to the G-buffer, which is written
with replace and has nowhere to put partial coverage, and a colour's alpha
reaches the swapchain having blended against nothing. A gradient ending at
transparent black writes opaque black over what was behind it, which is worse
than not fading. Alpha is carried and it is inert, `render.blend` is accepted
and logged and ignored so an effect authored today draws as written once the
simulate pass can pick the lane, and the only fade that works is the size curve
going to zero. What that leaves working is debris, chunks, gibs, snow, rain,
confetti and hard-edged sparks. Fire, smoke, glow and soft dust want the blended
lane and do not yet reach it.

## GPU-driven by default

`make run` animates 4000 instances and never tells the GPU how many of them to
draw. Per-instance data lives in a storage buffer the host writes the deltas of,
and what decides the draw is a chain of compute passes: mark, scan and compact
for the opaque lane, five more for the blended one, light binning beside them.
The instance count each draw consumes is written by that chain into an
`SDL_GPUIndexedIndirectDrawCommand`, so the CPU never learns what survived the
cull.

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

The same renumbering is why a `Material` crosses a snapshot as the material's
name and not as its id, the way a `Sprite` carries its image's name and an
`Animation` its sheet's. A reload is refused because a live world's numbers
cannot be moved under it, but a save outlives the process and there is nothing
left to refuse by the time it is read: a build with one more material file
would load an id that means a different shader, render the scene wrong and say
nothing about it. So `materials.name` writes the name and `materials.find`
resolves it again, and a name this build does not have raises and says which
one, since falling back to the default or dropping the component are the same
silent wrong shader by another route. The set of materials is not written
alongside it. A snapshot naming only materials the build has is safe whether or
not the set matches, so a set-level check would refuse loads that are correct,
and one narrow enough not to would be asking exactly what the names already
answer.

What makes the swap cheap is that the pipeline objects a frame binds are read
through the backend every frame, so replacing them is picked up by the next
frame with no pass graph rebuilt and nothing in the world touched.
`Backend:rebuildPipelines` is that half. It waits for the device to go idle,
builds the geometry and forward pipelines, the five cull and sort pipelines and
the deferred pass's own four against the formats the G-buffer was created with,
and installs them only once every one of them has compiled, so a source that no
longer compiles raises and leaves the process drawing exactly what it drew.

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

A sheet re-reads through `animation.replace`, which exists because building a sheet
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

Four of those five are driven by an agent that knows it edited something, and
also by a watcher that notices. The sheet is the exception, and by omission
rather than by decision: no kind is registered for one, so `animation.replace` is
reachable from game code alone.

SDL has no change notification: not in 3.4 and not behind a hint, and
`SDL_AddEventWatch` watches the event queue rather than the filesystem. What
`SDL_filesystem.h` offers is `SDL_GetPathInfo`, which answers a type, a size and
three timestamps. So `tecs.platform.watch` polls, and going native to avoid
polling would mean inotify, FSEvents and `ReadDirectoryChangesW`, plus one more
for every platform whose SDK is licensed, to save work measured below in
microseconds.

It polls what was loaded rather than the content tree. `filesystem` records
every path this process has read or decoded, which is both a much smaller set
and the only set where a change has anything to act on, since a file nothing
opened has no reloader to route to. That is also why `SDL_EnumerateDirectory` is
never called: there is nothing to enumerate.

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

Each reload ends by asking `clearCrash` to pick the loop back up, which is what
the watcher is for. A file that broke the game is a file someone is about to
fix, and a loop that stays stopped after the fix has landed makes the watcher a
notification rather than a tool. A handler that raised never gets there: the
reload refused, so nothing has changed.

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
 storage     Content and writable roots, and how a      adapter.basePath/prefPath
             file under one is reached                  and adapter.storage
 shaders     A pack in the platform's own format        adapter.shaderFormat
```

Each is a seam rather than a fork because everything above it is already
indifferent to the answer. The application is an object a host drives rather
than a function that runs until done, which is why iOS and a console SDK can
both call the same four methods. Events are one typed stream discriminated by
`kind`, so a platform with no `SDL_Event` produces those values directly. Input
needs a second face because rumble, an LED, a cursor mode and a text input
session are commands going the other way, and no event vocabulary can express
one. Audio is almost that direction alone: a mixer opens, a voice is pointed at
a clip, a gain is set, a voice stops, and the one thing that comes back is
whether a voice is still sounding, which is asked rather than delivered. A
target that forbids `dlopen` reaches its libraries through a table of pointers
taken at build time, and nothing calls `ffi.load` when one is present. Storage
is two halves and neither is useful alone, which is why it is one seam and not
two: a platform that says its content lives at a root it invented is not served
by the engine then reading that root with the host's own file calls, so the seam
carries operations and not just paths. The pack layout does not change for a
platform with private bytecode; only the declared format does.

`tecs.platform.adapter` holds the SDL implementation of all seven, which doubles
as the worked example. `spec/adapter_spec.lua` installs a platform that is not
SDL and drives real work through it, because a seam nobody has ever substituted
is a guess about what a port would need rather than a contract. That spec is not
a console port and cannot be one; it is the evidence that a port has seven
things to supply.

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
What a source hands over is the engine's own `Event` record rather than an
`SDL_Event`, which is what makes a platform that has no `SDL_Event` able to
supply one; the record is reused, so anything a recorder retains it takes
through `events.copy`. A replayed event carries no `arrival`, because a
synthesised one would be a latency measurement of the replay driver.

**Randomness is seeded, and split by name rather than by order.** `tecs.ecs.random`
gives a world a generator per name, each seeded by hashing the name against the
world's seed, so a stream that did not exist before takes a seed of its own
without moving any other stream's. One generator shared between consumers has
the opposite property: whichever ran first decides what the rest get, which is
exactly the case a replay needs to survive. The state is four 32-bit words a
snapshot carries, and the arithmetic is integer, so a sequence is the same on
every machine rather than the same on most of them.

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

**Workers are the only threading path.** LuaJIT FFI callbacks invoked from
threads the VM did not create are unsafe, so raw thread creation is not exposed
even though the symbols are bound. The frame itself is not split across
threads: simulation, extraction and submission are one sequence on the main
thread.

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
 sdl3       1231 functions
 box2d       421
 spvc        169
 sdl3image   102
 sdl3mixer    94
 curl         81
 zlib         81
 shaderc      45
 sdl3net      34
 worker       10
 dialogs      10
 http          8
 taskpool      7
 logsink       3
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
size, alignment, and the offset of every field. It currently verifies 219
records. A binding whose header is written against another library's types
names that one as a prerequisite, which is how SDL_mixer's records are
declared against SDL's.

Header-only `static inline` helpers have no symbol to bind and are
reimplemented in Lua. That is usually faster anyway, since the JIT can inline
Lua where it cannot inline across an FFI call. `World.getAngle` converting a
`b2Rot` cosine/sine pair is the current example.

## Layout

```
native/host.c             process entry, the event batches, the lifecycle hooks
native/registry.c         function pointers, for a target without `dlopen`
native/                   worker runner, log sink, task pool, dialogs, HTTP
scripts/gencdef.py        header -> cdef + constants generator
scripts/abicheck.py       cdef vs C compiler layout verification
src/tecs/init.tl          the public API: one module per name, ECS and engine
src/tecs/ecs.tl           what a game writes, and what engine modules require
src/tecs/global.d.tl      declares the `tecs` global, typed off init.tl
src/tecs/Application.tl   the lifecycle the host drives
src/tecs/ffi/             library loading and generated binding wrappers
src/tecs/platform/        window, input, audio, sensors, files, OS services
src/tecs/gpu/             device, frame, passes, shaders, pipelines, buffers
src/tecs/components.tl    components the engine renders and simulates
src/tecs/gfx/             camera, layers, sheets and playback, text, particles
src/tecs/Renderer.tl      the world-to-GPU bridge, owning both halves below
src/tecs/Extractor.tl     the world-facing half: a world to a frame packet
src/tecs/Backend.tl       the device-facing half: a frame packet to a frame
src/tecs/FramePacket.tl   what crosses between the two
src/tecs/Audio.tl         clips, voices, groups, and the Sound component
src/tecs/physics/         Box2D binding and its world plugin
src/tecs/sequence/        the sequencer, and the tween runtime inside it
src/tecs/mcp/             the debug server: transport, tools, sandbox
src/tecs/assets.tl        images and clips, decoded on a worker
src/tecs/workers.tl       threads with serialized channels
src/tecs/Future.tl        the value everything asynchronous settles into
src/tecs/http/            requests, and the clients the loop turns
src/tecs/net.tl           nonblocking TCP and UDP transport
src/tecs/random.tl        seeded streams and Perlin noise
src/tecs/hash.tl          FNV-1a, Adler-32 and CRC-32 over byte strings
src/tecs/compress.tl      zlib and raw DEFLATE in both directions
assets/                   shaders, materials and fonts, globbed at build time
spec/                     busted suite
bench/                    where the numbers in this file come from
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
make test-package   run the spec suite against out/package
make deps           install development dependencies (Homebrew)
```

`PRESET=` selects the target; it defaults to `macos-arm64-dev`. Presets come in
two kinds. A development preset resolves dependencies from the system, which is
convenient and not shippable: it links the build machine's libraries by
absolute path. A packaged preset builds pinned revisions from source, so a
release is reproducible and carries no path from the machine that made it.

A packaged preset asks two things of the build host that a development one does
not. Mbed TLS generates part of its own source when it is built from a git
revision rather than a release archive, so the Python the configure finds needs
`jinja2` and `jsonschema`; the configure says so rather than letting the build
fail inside a dependency a quarter of an hour later. And LuaJIT's Makefile
refuses to guess a deployment target on Apple, so the macOS presets name one.

`make check-package` is the gate on that distinction. It inspects the installed
binaries for search paths and absolute references that leave the package, and it
checks that a pack is there, since a release ships no compiler and must
therefore ship its shaders. The script also refuses a shader compiler outright,
and that is the one check the make target turns off: it passes
`--allow-compiler`, because `check-package` packages whatever `PRESET=` names
and that defaults to a development preset, which links one on purpose. Only a
packaged install can pass the rest: a development one keeps its link paths on
purpose, so what runs against one is the half that is about the tree rather than
the preset, the licence position and the packaged types, and the rest is
reported as not run. A package that resolved a library from the build machine
works there and nowhere else, and the failure only appears once someone else
unpacks it.

`make test-package` is the other half of the same idea. `make test` runs the
suite against a build tree, which on a development preset means against the
machine's own SDL, Box2D and libcurl; against an installed packaged tree it is
the only thing that exercises the revisions a release actually ships. It sets a
path per library, because `loader.library` tries a library's plain soname
before any directory it was told about, so `ffi.load("SDL3")` otherwise reaches
whatever the machine has installed from inside a package carrying its own, and
two SDL3 images end up in one process.

It holds the installed types to the same standard, for the same reason: it
type-checks a file that uses the `tecs` global against `share/tecs/teal` and
nothing else of the engine's, so a package whose type information is missing or
incomplete fails here rather than for whoever unpacks it. That one fails on
both kinds of install, since types are not something a development build is
allowed to borrow from its machine.

`TECS_FRAMES=N make run` exits after N frames, so an automated run can drive
a real window to completion.

## Requirements

CMake 3.24+, LuaJIT, SDL3 (3.4, for SDL_GPU), SDL3_image, SDL3_mixer, SDL3_net,
Box2D 3.x, shaderc, SPIRV-Cross, libcurl, zlib, and Teal (`tl`). The configure
requires every one of them. `make deps` installs the ones Homebrew supplies;
libcurl and zlib are not among them, because a development preset finds the
host's.

A version is a requirement rather than a floor. The spec suite runs against
whatever a development preset resolved, so a suite run against a different SDL,
SDL_image, SDL_mixer, SDL_net, LuaJIT or shaderc than `cmake/Revisions.cmake`
names is not testing what a release ships, and the configure fails on the
difference rather than leaving it to be found as a spec that passes on one
machine and not another. `-DTECS_ALLOW_VERSION_DRIFT=ON` proceeds anyway, which
is for working on a dependency before its revision is raised. Box2D,
SPIRV-Cross, libcurl and zlib are unchecked, and `cmake/SystemVersions.cmake`
says why each is.

A development build takes SDL_mixer from the system, and a system build is
whatever the packager configured: Homebrew's loads its optional decoders by
name at `MIX_Init`, so a developer's machine may well have the LGPL ones
available where a package built from `cmake/Pinned.cmake` does not.
`Audio.decoders()` is how to tell which build is running.

The same gap runs the other way for images, and it is the sharper one because
there is no runtime call that reports it. A development build takes SDL_image
from the system, and a packager's build reads everything: a WebP that loads on
a developer's machine is refused by a package built from `cmake/Pinned.cmake`,
where PNG and JPEG are the whole list. Test an unfamiliar format against a
packaged preset before shipping an asset in it.

### Licences

Everything this engine links is permissive, and it stays that way. LGPL is the
one rule with no exceptions, because a statically linked game cannot satisfy
the relinking obligation and a shipped binary is what this is for. It is not
left to a document: `cmake/Pinned.cmake` names every decoder option that would
fetch one, `spec/licenses_spec.lua` holds those options to their values and
fails on a name it does not recognise, and `scripts/checkpackage.py` holds the
libraries an installed tree actually links against a list carrying a licence
and a reason for each. Neither of those two checks reads a licence out of a
binary, because that is not something a binary carries; what they prove is that
nothing gets linked without somebody having written down what it is.

`THIRD_PARTY_NOTICES.md` is the list, and it installs to `share/tecs` with the
binaries it describes. A package that carried the code and not the notice would
be the one compliance failure this engine could commit on its own, so
`make check-package` fails an install that is missing it.

Dependencies are found through pkg-config rather than a package manager's paths,
which is what lets the same build description cross-compile. Two are found by
hand and each for its own reason: Box2D ships no pkg-config file at all, and
SDL3_net ships one whose `includedir` and `libdir` are `/include` and `/lib`,
which CMake rejects when it builds an imported target out of them. Its `.pc`
file is still consulted for the version, which is the one thing that answer is
good for.

SPIRV-Cross is distributed as static archives only, and the FFI needs a shared
object, so the build links one. Whole-archive linking is deliberate there: the C
API's symbols are not referenced from the stub, so the linker would otherwise
discard every one of them.
