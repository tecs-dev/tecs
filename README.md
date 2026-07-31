# tecs

A typed entity component system and game engine in Teal for LuaJIT, built on
SDL3, SDL_GPU and Rapier. The ECS knows what the GPU reads. Entities are the interface,
so anything that renders or updates per frame is an entity in a world.

SDL owns the loop. An entry file returns an application and a Rust host drives it
from `SDL_AppInit`, `SDL_AppEvent`, `SDL_AppIterate`, and `SDL_AppQuit`:

```lua
return tecs.newApplication({
    window = {title = "game", width = 1280, height = 720},

    plugin = function(world, app)
        world:addSystem({
            name = "game.Tick",
            phase = tecs.ecs.phases.Update,
            run = function(dt) end,
        })
        world:observe(0, tecs.platform.events.on.appWillEnterBackground, function() end)
    end,
})
```

That shape is not a preference. iOS never hands control back for a blocking
loop to sit in, so a host that cannot be entered by callback cannot run there
at all. The same shape works on desktop, so there is one lifecycle rather than
one per platform. The host's calls into Lua use the Lua C API, not FFI
callbacks, which are a trace barrier and unsafe from a thread
the VM did not create.

Everything below Lua is reached through the FFI. Rust owns the host, worker
runner, log sink, dialogs, HTTP client, physics, image codec, machine-code
arena, payload loader, and registry installation. The remaining first-party C
is generated linker glue and the small shared-object wrapper over SPIRV-Cross.
The host itself is never called from Lua. lua-cjson remains compiled in and
announced through `package.preload` rather than found on a search path.

## Status

Working today:

- Generated FFI bindings for SDL3, SDL3_mixer, shaderc, SPIRV-Cross and zlib,
  plus a checked Rust ABI for engine services
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
- Physics in the world through Rapier: a RigidBody component holding a
  generational handle, fixed-phase stepping with parallel solving, collision
  events, and full native snapshot/restore
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
- Per-stage frame timing with percentiles, which supplies the measurements in
  this file, and event-to-photon latency reported through the same stages
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
  behind it, visibility and minimization, focus, opacity, borders, icon, safe
  area, taskbar attention and progress, pointer and keyboard confinement, and
  the displays underneath it all, every one of them also settable in the
  application's config
- Particles simulated on the GPU: an entity is an emitter and its particles are
  not entities, their state living in a buffer the CPU never reads, drawn
  through the instance stream and the cull that were already there, blending
  over the composited image or adding to it as the effect asks

Not built yet: post-processing, tiled maps and multi-camera.

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
world:spawn(tecs.Transform(0, 0), Velocity(1, 0))
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
reason the global would quietly undo. So `cargo xtask check` runs with no declaration
loaded, and a module that reached for `tecs` without requiring it is an error
here rather than a cycle later.

### A module may sit inside a module, one level and no deeper

`tecs.gfx.layers` is a module reached through a name that is only a namespace.
A flat surface where every module is one segment fails on the count rather
than on any one name: a root holding several dozen unrelated names is looked up by
scrolling, and grouping the ones that share a subject is what makes a name
guessable from what a game is doing.

Two levels and no more. `tecs.gfx.layers.configure` is a namespace, a module
and a function, read left to right, and there is nothing to work out about
where one stops and the next begins. A third level would put that back:
`tecs.io.http.client.Response` reads as four guesses.

The constraint that shaped the mechanism is laziness, not depth. A plain
`require("tecs")` must not demand a graphics stack, because that is what lets a
resource pipeline, a simulation server and a spec use the same table a game
does, and the obvious way to build `tecs.gfx` defeats it: a `gfx/init.tl` that
requires its members loads all of them the moment anything reads one, and every
one of them reaches SDL through the FFI. So a namespace is a table whose
members arrive one at a time, and a name inside one is described exactly as a
name at the root is, by the same table and resolved by the same function.
`spec/headless_spec.lua` holds that: naming `tecs.gfx` loads nothing, and
reading `tecs.gfx.layers` loads layers and no sibling.

A name that resolves to a module resolves to the module itself rather than a
copy of it, so `tecs.gfx.layers` and `require("tecs.gfx.layers")` are one
table. That is not a detail: `layers.maxY` and `layers.maxZ` are assigned by a
game, and two tables would mean a write through one that nothing reads.

**A namespace with one principal module is that module.** `tecs.io` is the
table `require("tecs.io")` answers with, and `files`, `http`, `mcp`, and
`watcher` are hung off it when each name is first read. A separate proxy table
would need a second record that restates every member's type and documentation,
and writes would need routing to the module that owns each name. Using the
principal module avoids both copies, while
`tecs.io.files.setPreferenceIdentity` still lands directly on the files module
that `preferencePath` reads.

What that costs is a direction in the module graph. The parent has to name the
type of every name below it, and Teal refuses a require cycle even when one
side of it is erased at codegen, so a subordinate module cannot require its
parent. `Reader` and `Writer` therefore live in `io/types.tl`, below the parent
and every constructor that uses them. The watcher polls what the process has
opened, and the shader and material loaders read content through the same
roots the filesystem resolves, so those shared names live in
`platform/content.tl`, below both sibling modules. A namespace assembled from
several modules with no principal one keeps the table built for the name, and
keeps the record with it. `tecs.gfx` and `tecs.platform` are the two left:
graphics joins modules that answer one scene vocabulary, while platform groups
four independent host facilities without choosing one as the parent.

`tecs.audio`, `tecs.input` and `tecs.platform.window` are principal modules
that each contain one class. Their files are `src/tecs/audio.tl`,
`src/tecs/input.tl` and `src/tecs/platform/window.tl`, and each returns a
module record with its class nested inside it. Input sits at the root because
games reach it continually; window remains under platform because it is a host
facility.

Nesting the class inside the module record rather than hanging it off as a
field is not a style choice. tealdoc documents a module's returned record and
one level below it, so a class held as a field renders as a single line and its
methods vanish from the generated reference. Nested, the class's methods and
its option records are the module's own members and all of them render. What it
costs is that `Audio` is then a type name rather than a field,
so `record audio` cannot also declare `Audio: Audio`. The same one-namespace
rule gives the builtin component `EntityKey` a name distinct from
`tecs.data.Key`.

`tecs.gfx` deliberately has no principal module because laziness matters more
there than the shape. It answers four things a scene reaches for directly, the
camera, the components, the renderer and text, and four modules below it. A
principal loads when its name is read, and every suitable candidate reaches
SDL through the FFI. Making one principal would require a graphics stack merely
to read `tecs.gfx.layers`. A separate lazy `gfx/init.tl` would duplicate the
resolver one directory down, so the namespace record stays with the resolver.

What `tecs.gfx` does not carry is `Transform`. Grouping by the task a game is
doing puts a name where it is used, and a transform is used by the hierarchy,
by physics, by the sequencer and by the extractor, so filing it under drawing
would tell three of those four that they were moving a graphics component. It
is written `tecs.Transform`, at the root, because it is the one component
every subsystem moves and so belongs to none of them.

The root carries what crosses subsystems, and nothing else. `Transform` is one
of them; the others are `Application` and its `ApplicationConfig`, `Future`,
`newApplication`, `version`, and the four ECS types every subsystem writes into
its own signatures: `World`, `Query`, `System` and `Plugin`. An application is
not a subsystem, since it owns one of each of them, and a future is what every
subsystem that answers later hands back, so neither has an owner to be filed
under. The rest of the ECS vocabulary is `tecs.ecs`: `Component`, `Archetype`,
`Bundle`, `SystemConfig` and the snapshot records are named while configuring
the ECS rather than while reaching across it.

The line between them is what a name is written next to. A game annotating a
plugin writes `function(world: tecs.World, app: tecs.Application)`, and the
same `World` appears in the public signature of physics, drawing, audio and the
sequencer. A game declaring a component writes `is tecs.ecs.Component`, which
it is doing because it is talking to the ECS. Engine code that needs only the
type reaches for `tecs.types`, which sits below both halves and is what makes
`tecs.ecs.World` unnecessary rather than merely duplicated.

`spec/surface_spec.lua` walks the whole of it. The record in `init.tl` is what
a game is type-checked against and the descriptor table beneath it is what a
name resolves through, nothing in Teal connects the two, and a descriptor
pointing at the wrong module resolves to a table full of functions that are not
the ones promised. So the spec reads the record, resolves every name it
declares, and holds each to the module whose path ends in the name it was
reached by, along with every name the descriptor puts one level down.

## One way in

Because the host reaches into an object rather than being handed a loop,
something has to run after the device and the world exist, once per iteration,
once per event, and once at teardown. That much follows from the entry point.
`Application.Config` carries `plugin`, one
`function(world, app)`, and nothing else a game supplies is called by the loop.

The reason is that the ECS already answers all four questions, and answers them
better than a callback can. A system's order is declared by the phase it is
registered in rather than being implicit in where the loop happens to call it. A
system and an observer are both registered on the world, so the world can count
them and the debug server reports the count; a field of a config table is
reachable from nowhere. And both run inside the crash guard, so the line that
fails leaves a traceback and a live process rather than unwinding to the host.

The lifecycle maps directly onto ECS machinery:

```
 Concern      Representation                  Run by
 ───────────  ──────────────────────────────  ────────────────
 startup      PreStartup, Startup,            world:startup
              PostStartup
 iteration    First … Last, fixed or not      world:update
 event        world:observe(0, on.<kind>)     the drain
 shutdown     PreShutdown, Shutdown,          world:shutdown
              PostShutdown
```

`spec/phases_spec.lua` takes
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

### Timer callbacks stay out of Lua

`tecs.platform.time` exposes SDL's realtime and monotonic clocks, calendar
conversion, unit conversion, and blocking delays, but not `SDL_AddTimer`.
SDL runs a timer callback on a separate thread, so entering the main LuaJIT
state from it is undefined. Moving the callback through Rust and a queue would
make it safe, but it would duplicate scheduling that a system already expresses
in Lua.

A real-time deadline compares `time.now()` in a system. Work tied to simulated
time belongs in the sequence clock or the fixed-step pipeline. Both keep
execution on the main state and retain phase order, pause behavior, and the
application's crash guard, which an SDL timer callback would bypass.

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
simulated time resynchronize immediately and the simulation is now behind by
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
fix made right. Normalization has to happen somewhere, and a metatype computing
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

### Costs

An application owns one world. A second is possible and can be stepped from a
system, but only `app.world` is rendered, bound to the debug tools and given
the engine's own systems. Nesting one application inside another does not work
at all: the host holds a single registry reference to one returned table,
`SDL_Init` and `SDL_Quit` bracket the process, and the debug server's bindings
are module-level.

What the shape buys below itself is that nothing needs it. `tecs.Application` is
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
registration step a game has to find. A second name-to-component map assembled
from engine module tables would omit game-defined components, which are exactly
the components a debugging session is about.

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

The staging slot rotates before the frame is recorded. Recovery submits
whatever copy passes recording encoded before a throw, so rotating later could
make the next extraction write into the slot the GPU is copying out of. Which
slot a frame uploads from is
carried on the packet rather than read from the renderer, so moving the
rotation earlier changes nothing about what is drawn.

A begun pass registers itself against its command buffer in `gpu.passscope` and
takes itself off there when it finishes. That is the one thing a call site
cannot do for itself, and registering by command buffer rather than by frame is
what makes it cover every caller, including a compute stage a game installs and
records its own passes from.

How a broken frame is resolved is SDL's decision, not a preference.
`SDL_CancelGPUCommandBuffer` is documented as an error once a swapchain texture
has been acquired, and `Device:beginFrame` returns only after acquiring one.
`Frame:cancel` therefore refuses in that state. `Frame:abandon` is the recovery
path: it ends the open pass and then submits when a texture was acquired and
cancels when none was. What reaches the screen is what the frame drew before it
threw, which for a
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

`app:clearCrash()` resumes a development application after a guarded failure.
It provides another frame to inspect and a chance to reload; the world may be
inconsistent, so reload before trusting it. `spec/exceptions_spec.lua` verifies
that the world, device and renderer remain usable after recovery.

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
a tool. The second gate is severity, and it is narrow rather than a judgment
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

So the Rust machine-code arena holds 24MB of that window from the host's first
instruction and gives it back once initialization returns. Everything mapped in
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

Asset loading rides on that. Decoding a PNG or JPEG, or rasterizing a static
SVG, is pure CPU work, so it happens on a worker and the main thread only
uploads. Rust's `image` crate decodes raster bytes supplied through the storage
seam and `resvg` rasterizes SVG into the same tightly packed RGBA8 allocation.
The worker returns the allocation's address rather than serializing its pixels;
ownership transfers with that address and Rust frees it after upload.

An SVG renders at its intrinsic dimensions. The path is already an image's
identity in sprites, snapshots, deduplication and hot reload, so a second API
that accepts a target size would let one path mean several incompatible pixel
allocations where the renderer can name only one. The renderer can grow a
sized image identity if that use case arrives; the loader does not pretend it
has one now. SVG text always uses the bundled JetBrains Mono and the parser
does not scan system fonts. External image references are ignored instead of
reading around the storage seam and creating dependencies file watching cannot
see. The raster decoder compiles only PNG and JPEG, and `resvg` compiles no
embedded raster-image codecs, so accepted top-level formats and SVG output are
identical on every target and carry no platform image framework.

Sound takes the same route. A clip is read and decoded on the worker by
SDL_mixer and handed back as the address of a `MIX_Audio`, so a file that turns
out to be a minute of Vorbis costs the frame nothing. A clip long enough to
stream is measured on the worker and then thrown away rather than decoded, and
the voices that play it read the file for themselves.

The application owns the pump. `assets.update` runs once per iteration and
`assets.shutdown` runs at teardown, so a game that loads an image and does
nothing else still sees its load settle and the decoding thread still stops.
One subsystem drains the same queue itself, and it is `Audio:update`, which is
not a world system because reaping voices has to continue through a world pause;
an `Audio` outside an application would otherwise never see its clips arrive.

Nothing else drains the queue. Atlas registration is the load's own transform,
so it happens from the application drain. A subsystem with no state machine of
its own has nothing to pump.

A load is not a cache. Two image loads of one path that overlap share the decode
and the surface, because decoding the same file twice at once produces nothing
the first decode does not already have; the last of them to release is the one
that frees. A load that starts after the first has settled decodes again, since
handing back pixels that may already have been uploaded and released would be a
cache with none of a cache's guarantees. Sharing is the image path only: two
overlapping sound loads of one path each get their own clip. And a payload that
has been given back must not read as available: an `Image` whose last holder
released it reports nil pixels rather than pointing at a freed allocation, which
is the difference between a clear error at the upload and a null dereference
inside it. Availability therefore follows the pixels themselves.

A load answers with a `Future`, while its settled payload owns its own
lifetime. Before the load lands, cancel the future. After it lands, release the
payload. This keeps interest in pending work separate from ownership of decoded
memory.

`Audio:load` returns a `Future<Clip>` for the same reason an asset load returns
a future: the answer does not exist until the worker has read it. `Audio.Clip`
still keeps the state words, and they earn their place for a different reason.
A clip outlives its load, holds the `Sound` behind it, and remains inspectable
through `Audio:clip` while its load is pending or after it failed. Its first
three states are therefore spelled the way `Future` spells them, `"pending"`,
`"ready"` and `"failed"`, and the fourth is a state only a clip can be in. It is
not `"canceled"` either: nothing gives up the cache's load but `destroy`, which
has written `"released"` by the time the cancel reaches it. Those four words go
out over JSON-RPC in the `audio` debug tool's clip list, so the declaration says
so. They are an externally typed compatibility surface.

Audio owns the cache's interest in that load. Concurrent callers receive
distinct derived futures whose ready values are the same `Clip`, so one caller
can cancel without changing another caller or the clip the audio object still
needs. This deliberately differs from the image loader, where callers are the
only interests and the last cancellation abandons the decode. `Audio:destroy`
cancels every caller link before canceling its root, so a future retained past
the audio object cannot keep a decode alive underneath a mixer that has gone.

The shared decode is what decides the shape. A path already in flight does not
hand its future to the second caller; it keeps one root future to itself and
hands each caller a link derived from it. That buys three things out of
machinery that already shipped. The pending-side count is the root's watchers,
which a link increments and a cancel decrements, so the last caller to give up
is the one that abandons the decode. The settled-side count is incremented once
per caller _whose link actually ran_, so a caller that canceled first is not
counted and the number of holders is exact rather than optimistic. And every
caller holds a distinct object, so a future stays usable as a map key, which
three subsystems here already rely on.

Files a game interprets itself go through `files.read` or
`assets.loadString`, which are the two sanctioned ways to get bytes out of the
content root: on Android content lives inside the package and `io.open` does not
reach it. Both answer bytes rather than text, so an image, an archive or a
binary sidecar comes back whole and being text is a decoder's opinion. The
first is synchronous and suits a small document. The second runs the same
whole-file read on the asset worker and answers a `Future<string>` when the main
thread should not stop for it.

```lua
local files = tecs.io.files
local bytes = files.read(files.assetPath("levels/1.json"))
local level = tecs.data.decodeJSON(bytes)
```

`read` answers nil for a path with no file, so an absent document is
distinguishable from a malformed one, which the decoder raises on.
`loadString` reports the same absence as a failed future. It is not a stream:
the worker sends one binary Lua string back, complete, and overlapping callers
share that read while retaining futures of their own.

Font metrics take that asynchronous path. A `Future<Font>` settles after the
metrics have been read and parsed, which is the point the renderer-independent
font exists. Its atlas residency is still a renderer's answer: the first text
to use the font on each renderer starts that image decode and upload, so one
process-wide font can remain useful to headless measurement and to several
renderers.

Waiting on a fixed collection of loads is `Future.all`. It fails on the first
failed input and takes one hold on every input until the join settles or is
canceled. A caller that needs every outcome can recover each input before
joining it.

Waiting for a subsystem to become idle is a different operation. A fixed join
does not include work started by settlement listeners, while an idle barrier
asks whether anything remains outstanding after those listeners run. That is a
count and a drain rather than a collection combinator.

So `assets.waitAll` is the barrier, and it is the one wait here that is not a
join: its body is a `Future:wait` on a future the loader settles when its own
count of loads in flight reaches zero, rather than a third copy of the wall-clock
loop. Two properties make it right rather than merely available. The loader
settles that future after a result has run its listeners rather than inside the
settlement, so a load chained onto one is counted before the barrier is asked
whether anything is left and holds it pending instead of slipping past it. And
its scope is every load in the process, which can lengthen a wait and cannot
shorten one, so a subsystem waiting on it cannot proceed with work of its own
outstanding. That is what makes a wider scope safe to borrow. `Audio:waitForLoads`
and `Audio:destroy` borrow it and read their own count first, so an instance with
nothing in flight waits on nobody, and `destroy` gives up whatever the drain ran
out of time on rather than freeing the mixer under it.

All three entry points record what they touched in the internal content
registry. The file watcher polls that registry instead of walking the content
tree. Asset loads use the same registry rather than keeping a list of their
own, because the decode they are recording happens on a worker and a second
list is a second answer to the same question.

## Vector math stays in Lua

`tecs.math.vec2` takes vectors as separate numbers and returns them as multiple
values. A table or cdata vector would make every temporary choose an owner and
an allocation strategy even though the engine's components already store x and
y as separate fields. With numbers, a result can go straight into locals or an
archetype column, and LuaJIT can compile the helper's arithmetic into the
caller's trace:

```teal
local directionX, directionY =
    tecs.math.vec2.normalize(targetX - x, targetY - y)
x, y = tecs.math.vec2.moveTowards(x, y, targetX, targetY, speed * dt)
rotation = tecs.math.wrapAngle(rotation + turn * dt)
```

The vector and point operations sit under `vec2`; `wrapAngle` and `deltaAngle`
stay directly on `tecs.math` because neither takes a vector. Keeping all twenty
functions flat made an angle-to-angle operation look like part of the vector
vocabulary and left no place for another geometric subject without adding more
unqualified names. The subordinate module pays one segment only where a caller
is actually doing two-dimensional geometry.

That is also why these operations are Teal rather than Rust. A dot product,
normalization or rotation does too little work to repay an FFI call, and the
call would be opaque to the trace around it. Native vector math starts making
sense when one call walks a contiguous array; this API is for one vector in the
game code already touching it.

UUIDs, hashes and checksums remain under `tecs.data`. They are persisted
identities or operate on byte strings, and none is numeric geometry merely
because its implementation contains arithmetic or randomness.

## Data transforms and typed stores

Encoding, hashing and decompression share the public `tecs.data` module because
a save is encoded, compressed and stamped as one task. Their implementations
remain in three files, and the surface resolves them lazily, so asking for a
hash loads neither encoder nor decompressor.

UUID generation shares that module because its result is an identifier stored
in data, not a mathematical operation. `uuid4` uses operating-system randomness
for independent allocation, while `uuid7` combines that randomness with time
and process-local ordering for database and protocol identifiers. Both cross
the existing Rust ABI because the runtime already depends on the implementation
and entropy provider.

Sharing the module qualifies the verbs. `encode` on a module that also
compresses would name two things at once, so JSON is `encodeJSON` and `decodeJSON`
while the compressors keep `deflate` and `inflate`, which already say their
format. lua-cjson's own names come through unchanged, sentinels and settings
alike, for the reason `STYLE.md` gives: renaming them would leave that
library's documentation describing names that do not exist here.

Typed stores live under `tecs.data` too, rather than under `tecs.ecs`.
`tecs.data.Store` is an independent in-memory value bag, and a world merely
owns one instance as `world.resources`. The key registry is process-wide so
hot reload and tools recover the same identity, while values remain scoped to
their store. No durability follows from the name: snapshots omit resources
unless a handler saves them.

`data.fnv1a64` is what identifies content: the shader pack carries one per
source so a pack built before an edit is detected rather than trusted. It is
not an integrity primitive and is not offered as one. Sixty-four bits puts an
accidental collision out of reach and a deliberate one within it, and
establishing that an asset is the asset that was published is a different
question with a different answer. The algorithm is in the name because the
values are written into files that outlive the process, so changing it has to
be a rename that every caller is rechecked against rather than a silent change
of meaning. `data.sha256` answers the separate integrity question when the
expected digest comes from a trusted channel or signed manifest. It crosses
the Rust ABI because the runtime's pinned `sha2` implementation is shared with
the build that stamps embedded payloads. `data.adler32` is there for the format
that specifies it.

`data.inflate` reads zlib streams and `data.inflateRaw` reads the
DEFLATE inside them. zlib decodes both: it is pinned, bound, and carried
through the ABI check, so a decoder written in Lua beside it would be a second
implementation of the format to keep correct, and the slower one. Both entry
points go through `inflate` over a `z_stream` rather than `uncompress`, because
`uncompress` wants the decompressed size up front and treats a wrong one as a
failure while `sizeHint` is a hint whose whole contract is that being wrong
costs a copy, and because `inflateInit2_` takes the window size, so negating it
selects the raw form and one loop answers both.

Writing uses the same whole-buffer shape. `data.deflate` produces a zlib
stream and `data.deflateRaw` the RFC 1951 bytes inside one, both from a
single output allocation sized by `deflateBound`. The optional level is zlib's
own `-1` through 9 rather than a second vocabulary the engine would have to
translate and document. CRC-32 joins Adler-32 there, for the formats such as
PNG, gzip and ZIP that specify it; neither checksum is presented as content
identity or integrity.

A malformed stream raises rather than returning: an over-subscribed code table,
a copy reaching before the start of the output, a stored block whose length
disagrees with its complement, a truncated stream, and a trailer that does not
match what came out. zlib decides all of those but the truncation, which
the engine decides by handing over the whole input at once and reading a call
that stopped with output room to spare as a stream that ended early. The
messages are zlib's own, so `spec/compress_spec.lua` asserts that each of those
raises and never which sentence it raised; pinning a suite to one
implementation's strings is what makes the next swap expensive.

## Compiled regular expressions

Regular expressions are `tecs.regex`, their own public module rather than a
section of `tecs.data`. The distinction is lifetime: a data transform consumes
one whole byte string and answers another, while a regex is compiled state a
caller deliberately keeps and applies many times. Filing it under data would
make a stateful text matcher read like another encoder.

Rust's `regex::bytes::Regex` is the implementation because a Lua string is a
byte string, not a promise of UTF-8. Patterns are still UTF-8 Rust regex syntax,
with flags written inline, while a subject may contain any bytes and every
returned position is a Lua-style 1-based inclusive byte index. The surface
stops at compilation, testing, finding and captures. Mirroring `RegexBuilder`
would create two configuration languages for flags the pattern already carries;
replacement and iteration wait until a use settles the ownership and allocation
shape they should promise.

## Sound

`app.audio` is the whole surface: load a clip, play it, set a gain, fade it,
loop it, pitch it, seek it, pan it, put it in a group, cap how often it may
start, stop it. It is built on SDL_mixer 3 and on six decisions.

**The mixer decodes.** A clip is whatever the linked decoders can read. What
this build has is a question with a runtime answer rather than a configure-time
one, because a decoder whose dependency was missing is dropped without
complaint, so `Audio.decoders()` reports the list the library itself gives.
The Cargo dependency builder names every decoder option rather than accepting defaults:
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

Rapier is compiled with its parallel solver and enhanced determinism features.
It uses Rayon's process-global executor and never calls Lua from a solver
thread. The first physics world sizes Rayon's executor from `workerCount`;
later worlds share that pool and reject a different size rather than silently
ignoring it.

## A body's lifetime

A `RigidBody` is a generational handle naming a body Rapier owns, so the
component and native body have separate lifetimes.

**A despawn destroys the body.** Nothing else knows the entity is gone, so
without this the body keeps being solved for the rest of the session: the
entity's collider stays in the pile, pushing bodies that are still on screen,
and the memory it holds is never returned. The physics plugin observes the
built-in `OnDespawn`, which fires while the row is still readable, and destroys
whatever handle it finds. It reaches the world named in the handle rather than
whichever world the plugin was last given, and it asks Rapier whether the handle
is live first, so a row that never had a body and a row whose world has already
been destroyed both pass through it safely.

**A snapshot carries the native physics world.** Rapier's serializable state
includes bodies, colliders, islands, broad and narrow phases, joints, CCD,
integration parameters and contact state. Restore then reconnects transient
entity handles by entity id. The persisted handler key is `"tecs.physics"`.

**`Paused` holds a body rather than hiding it.** Rapier steps a world rather than
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

Unrecognized SDL events arrive as `unknown` carrying their numeric type instead
of being dropped, so upgrading SDL surfaces new input rather than silently
losing it.

A touch finger's identity is 64 bits and does not fit a double, so it is
carried as an opaque string, and so is the touch device it belongs to.
Reporting either as a number would round, and two distinct fingers could
collapse into one.

A recognized kind means usable fields. An event whose kind is named and whose
payload was left unread is worse than an unknown one, because the caller has
every reason to trust it, so text, composition, candidates, drops, the
clipboard, sensors, gamepad touchpads, displays, windows, pinches and user
events all convert their payloads. Several of those carry pointers into memory
SDL recycles as soon as the callback returns, so the Rust host copies those bytes
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
is no color-managed path for a game to respond through.

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

Natural scrolling is normalized where the conversion happens, not left for each
reader to discover. SDL reports a flipped wheel by negating both axes and
setting a flag, so a game that read the pair without the flag scrolls backwards
on every machine with the setting on and nowhere else, which is the kind of
defect that reaches a player before it reaches a test. `wheelX` and `wheelY`
therefore mean one thing everywhere: positive is away from the player and to
the right. Beside them, `wheelTicksX` and `wheelTicksY` carry the whole notches
SDL accumulated against the platform's own threshold, so a menu stepping one
item per notch does not re-derive them from the fractional pair and disagree
with the rest of the machine about where a step begins.

That normalization is drivable rather than only unit-tested. A pushed wheel
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
units `time.now` reports: SDL's own nanosecond stamp for the event, converted
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
they were delivered, which nothing reads: the converter's input-kind set
excludes them, since
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
one: at this engine's entity counts, serializing a world inside a platform
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
events. On Android the process blocks as soon as backgrounding is dispatched,
so the drain runs after resume: acting on the event would be a whole suspension
too late.

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

At this engine's entity counts a world is not serializable inside a platform
callback. iOS allows roughly five seconds from the hook being entered and
Android rather less, so the clock is running while the callback runs and a
callback that walked four million entities would be killed part way through and
leave nothing behind. The host complains past 250 ms for that reason. So
`_willEnterBackground` writes a buffer the game already had.

`app:stageCheckpoint(bytes)` is how it gets one, called from an ordinary system
on an ordinary frame whenever the state worth keeping has changed. It takes
bytes rather than a function that produces them, and that is the whole design.
A function would let a game postpone the serializing into exactly the callback
that cannot afford it while looking like it had prepared something; a string
cannot, because by the time one exists the expensive half has already happened
on a frame that could pay for it. The host times the hook and says so past
250 ms, which is the check on the rest.

Staging again replaces what was staged: there is one checkpoint, not a queue.
Staging once and backgrounding twice writes once, on the argument the host
deduplicates backgroundings with, which is that the second write is the one that
gets interrupted and it had nothing new to say. The write goes through a
neighboring file and a rename, so what is on disk is either the previous
checkpoint or this one and never half of either. `app:readCheckpoint()` is the
other half, read while building the world; nil covers a first run, a game that
staged nothing and a file the player deleted, and none of those is an error.
`config.checkpoint` names the file, and staging without one raises rather than
holding bytes that will never be written.

## The clipboard

`clipboardUpdate` says the clipboard changed and lists the mime types now on
offer. The clipboard half of `tecs.platform.os` is the other half: what those bytes
are, and how to put
text there. Being told and having no way to look is the worse of the two
halves to ship alone.

Reads are not cached. The clipboard belongs to the desktop rather than to this
process, so a value read a frame ago may already be wrong, and the event is the
only invalidation there is.

Every read hands back an allocation the caller frees, and a failed read hands
back an empty string rather than nothing, so the free is owed on that case too.
`loader.toString` copies and does not free, which makes it the right converter
and half the job; the pairing lives in one place in `platform/os.tl`
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
so `setPrimarySelection` succeeds, `primarySelection` reads back what this
process wrote, and
nothing outside the process ever sees it.

The clipboard is part of SDL's video subsystem, so a headless tool has none.
`clipboardAvailable` reports that, which is the only answer that separates no
clipboard
from an empty one; the rest short-circuit to empty and false without calling
SDL, so a question that was never going to be answered does not overwrite the
SDL error a caller is about to read for some other reason.

Text is UTF-8 and passes through byte for byte. Line endings are not
normalized, so text copied on Windows arrives as CRLF and stays CRLF, and
nothing is trimmed from either end. Text stops at the first NUL, because that
is what terminates the C string SDL returns and what every producer of
clipboard text intends; `clipboardData` copies the length SDL reports directly
into an owned `tecs.io.Buffer`, so a blob keeps its NULs without passing
through an intermediate Lua string. The caller releases that buffer.

## Native platform utilities

The smaller operating-system services are one module rather than an
`Application` grab bag, and rather than one name each. `tecs.platform.os` holds what
this build can do here, the clipboard, running another program, URLs, locale
preference, power, the simple blocking message box and asynchronous file and
folder selection. The `os` name distinguishes these host facilities from
`tecs.System`, which remains the ECS system type. None of them is a subsystem a
game builds on. Each is a handful of calls made when a player asks for
something, and four names for that
would make a game copying a path and then opening its folder reach three modules
to do one thing. Names are qualified by what they act on, because a bare `text`,
`data`, `clear`, `run` or `update` means nothing on a module that does all of
it.

The process sandbox is reported separately from the target. The same Linux or
macOS build can run without one or inside Flatpak, Snap, an unknown container,
or the macOS app sandbox, and those environments change filesystem and child
process expectations without changing what executable was built.

Standalone sensor handles sit under `tecs.input` instead, beside the pads and
the keyboard, because a game asking what a device can sense is asking one
question. Standard cursor shapes stay on `Input`, because cursor choice is an
outbound input command on the same seam as visibility and relative mode.

Device enumeration and microphone capture live inside `tecs.audio`, beside the
mixer. The mixer and the device it opens are one subject at two levels: a game
that wants a particular output names a
device from `tecs.audio.playbackDevices` and passes its id to
`tecs.audio.newAudio`. `src/tecs/platform/audio.tl` remains the SDL-only seam,
and `tecs.audio` publishes its operations under the game-facing names, the way
`tecs.io.files` publishes `platform/content.tl`.

File and folder dialogs are the exception to "one SDL call and return". SDL
retains a callback and may enter it from a thread the VM did not create, so
the Rust dialog bridge owns that callback, copies its answer behind a mutex, and
`tecs.platform.os` polls it into a `Future` on the main thread. A Lua `ffi.cast`
callback would be shorter and would make the program undefined on exactly the
platform path the dialog exists to use.

Microphone capture avoids the callback family for the same reason. SDL opens
an audio stream with no callback, its audio thread fills the stream, and Lua
pulls complete float32 frames with `Microphone:read`. That also gives capture
an explicit lifetime and a natural nonblocking `availableFrames` query instead
of making game code run at device-thread cadence.

## Moving binary data

`tecs.io.Stream` describes where bytes live without retaining a cursor.
Strings, owned buffers, borrowed FFI memory, paths and handles all use that
one storage vocabulary. Direction remains in the type:
`ReadableStream:newReader` and `WritableStream:newWriter` create caller-owned
endpoints, while source-only strings and borrowed bytes do not pretend to have
a writer. Cursor state belongs to each endpoint, so two readers over replayable
memory or a path do not move one another. A borrowed handle reports that it is
not replayable and lets only its first endpoint claim the handle's cursor.

`Buffer` is the reusable native-memory boundary beneath those interfaces. It
separates logical length from capacity, grows geometrically through
`ensureCapacity`, and exposes a borrowed FFI pointer whose lifetime ends at
growth or release. `resize` changes the logical length instead, zero-filling
bytes it exposes. `Reader:readInto` and `Writer:writeFrom` let SDL fill and
drain that allocation directly. A generic `write(any)` lost both the cdata
length and the right to check a range, so the explicit buffer and offset
contract won.

Whole-source operations return `Future` values. On streaming backends, such as
the direct SDL filesystem backend, one application poll shares sixteen 64 KiB
read or write steps round-robin across every pending transfer. That caps
aggregate streaming I/O work at about one MiB; a generic read-and-write copy
advances about 512 KiB of payload when it is the only transfer. A platform
backend without `openWrite` uses the whole-file fallback instead: it
accumulates chunks, then `close` concatenates and writes the complete payload
in one operation. That compatibility path is not covered by the per-poll byte
bound. A blocking wait drains streaming transfers against its actual time
budget. Stable buffer sources bypass the scratch copy, strings retain their
immutable Lua storage, and `hasBuffer` says exactly when `transferToBuffer`
returns the retained object instead of materializing a new one.

The descriptor owns no cursor and does not take policy away from its backing:
paths still open through `tecs.io.files`, TCP and UDP handles are constructed
by `tecs.io`, and media type and length are lazy metadata methods.
`contentLength() ~= nil` is the one known-length test; a mirrored
`hasKnownLength` method lost because it could only repeat that answer and add
another operation every structural implementation had to keep consistent.
`withMetadata` wraps those methods without eagerly opening or reading the
source.

`tecs.Closeable` is the root structural lifetime contract because cursors,
network handles, streams, and clients cross subsystem boundaries. It contains
only `close`; a concrete close may still return a status that generic cleanup
ignores. A worker `Channel` does not implement it because its `close` signals
end-of-input while `destroy` releases the queue, and a `Buffer` uses `release`.
Calling either through a generic ownership contract would promise the wrong
lifetime.

Sockets, files, protocol transfers and external tool traffic are all I/O, so
transport, HTTP and MCP live under `tecs.io`. The operation carries the useful
distinction without adding another organizational root or a third module level.

## Touching the filesystem

`tecs.io.files` answers both halves: where a path is, and what to do once
you have one. They are one module because they are one task. Every path a game
touches is resolved and then acted on in the same breath.
`platform/content.tl` sits below it and its watcher sibling. It holds the roots
the shader and material loaders read and the loaded-path set the watcher polls,
so neither public child has to require the other. It is one backend call per
function and nothing composed out of several, and on SDL each of those is the
obvious call: `SDL_GetPathInfo` behind `info`, `exists`, `isFile` and
`isDirectory`, `SDL_GlobDirectory` behind `list` and `glob`, `SDL_LoadFile`
behind `read`, then `createDirectory`, `remove`, `rename`, `copy`, `write`,
`currentDirectory` and `userFolder`. No virtual filesystem and no invented
path scheme, so a failure is the platform's failure and the name says which
call to read about. Like the process half it initializes no subsystem and is
more useful with no window than with one.

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
this process has opened that `tecs.io.watcher` polls, and the decodes in
`assets` write into that same record through `note` instead of keeping one of
their own. Bytes are bytes, so nothing at this layer can tell a font's metrics
from a level: whatever asked for them names the kind, and an unnamed read is a
document.

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
syscall rather than another program's lifetime, which is what put the process
runner on a
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
process, a request. [`Future.tl`](src/tecs/Future.tl) gives all of them one
settle-once state, failure, cancellation, listener and wait vocabulary.

```lua
local Future = require("tecs.Future")

tecs.platform.os.runProcess({ args = { "git", "rev-parse", "HEAD" } })
    :map(function(result) return result.output end)
    :recover(function() return "unknown" end)
    :onSettle(function(future) print(future.value) end)
```

**`status` is a plain field.** `"pending"`, `"ready"`, `"failed"` or
`"canceled"`, read directly rather than through a method, because several call
sites read it once a frame and a field read plus a string compare is what that
should cost. `"canceled"` is a state of its own rather than a kind of failure,
because `recover` must not run for it: a caller who canceled a load did not ask
for a fallback value.

**`value` is the blocking dereference.** Reading it advances a pending future
for the source's default wait budget, returns the result when ready, and raises
on failure or cancellation. An expired budget raises without changing the
future, because running out of time to wait is not the work's outcome and it may
still settle later. A successful non-nil result is already a field on the
future, so the common read after settlement does not call through a method or a
metamethod. The convenience is for startup, tools and tests; a frame reads
`status`, and a listener does not re-enter the source that is settling it.

**A `Source` is the whole driver interface.** Two functions carry it: `poll`,
which takes whatever is ready, and `advance(ms)`, which blocks for up to that
long and takes whatever arrives. That is all a worker channel is and all an HTTP
multi handle is, so the same hook covers a decode, a subprocess and a transfer.
`poll` is what the loop calls once a frame, and `wait` spends its budget inside
`advance` rather than spinning. A third, `cancel`, is optional and is the honest
answer to work that cannot be stopped: a source with no hook leaves it running
and stops caring, rather than the interface pretending every source can be told
to stop.

**The budget is wall clock.** A wait measures the time its source actually
spends pumping rather than counting messages or nominal slices. The default and
the slice size live on the source, which lets a subprocess keep a longer default
than a decode without a second convention.

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
advances and nothing else. Canceling a `flatMap` before its outer settles stops
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

**A game never pumps.** Reqwest runs transfers on a bounded Tokio runtime, but
their results still have to enter Lua on the SDL thread. That is engine work,
and it is the same work
`assets.update` and `proc.update` already do in the loop for the same reason: a
decode that finished has finished, a child that exited has exited, a transfer
that completed has completed, and nothing else in a frame is obliged to ask.
`assets` and `proc` are module singletons, while a game may construct several
HTTP clients. The clients therefore register with the loop: building one puts it on the
private application registry turns, `close` takes it off, and the
application turns whatever is on the list. Native workers send bounded chunk,
completion and error messages to a queue; the frame pump drains it without any
Rust callback entering Lua. The list holds its clients strongly, so a request whose
future is the only thing a game kept still lands; the price is that `close` is
what ends a client rather than losing the last reference to it, and the
alternative -- a weak list -- is a fire-and-forget request that stops moving
whenever a collection happens to run.

**A body uses the same `tecs.io.Stream` as every other binary source and
destination.** A request takes a string or `ReadableStream`, `into` takes a path
or `WritableStream`, and a response always returns a `Stream`. Metadata stays on
methods because a file can change between calls, and readers and writers are
endpoints with their own cursors rather than state hidden on the descriptor.

The two directions are bounded. A file or custom request source is read into
one reusable 64 KiB `Buffer` on the SDL thread and offered to a bounded Rust
channel. A full channel refuses the piece before copying it, so backpressure
holds the upload near one MiB rather than materializing it. In-memory strings,
buffers and borrowed byte regions take a synchronous direct-pointer path;
native code makes the one ownership copy before `send` returns.

Response chunks remain Reqwest `Bytes` until Lua drains the event. The default
destination copies them directly into one growable `Buffer`, with no
intermediate Lua strings. A caller-supplied writer receives the same chunks
through one reusable scratch `Buffer`, and partial writes are retried. A file
writer therefore adds no body-sized allocation in Lua or Rust. Native response
pieces are capped at 64 KiB before entering a 64-slot queue, so queued response
storage is bounded near four MiB. The running total is checked before queueing
each chunk, which keeps `maxBytes` identical for memory and streaming
destinations.

The response future settles only after the destination writer closes, so the
body handed to game code is complete even though its transfer was streamed.
The descriptor remains useful afterwards when it is replayable, as files and
owned buffers are. A one-shot handle correctly reports itself unavailable
after its endpoint consumed it.

`cargo xtask bench http` compares string, buffer, file and structural-reader
uploads with default-buffer and structural-writer downloads over loopback. It
reports p50 and p95 request latency and payload throughput, validates CRC-32
for every body, and states both queue bounds beside the results.

## Shelling out

A command line tool, a resource pipeline or an asset build wants to run another
program, and a game wants to do it between two frames rather than instead of
them. `tecs.platform.os` is that, and it is one of the few subsystems that is more
useful without a window than with one, so it initializes no SDL subsystem and
works under a plain interpreter.

```lua
local run = tecs.platform.os.runProcess({ args = { "git", "rev-parse", "HEAD" } })
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
child, and a run whose child was still going ends at `"canceled"` rather than
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

[`io.tl`](src/tecs/io.tl) exposes Rust's TCP and UDP transport shapes without
inventing a protocol above either. TCP is an ordered byte stream, so a write is
not a message boundary and reads are allowed to be short. UDP preserves a
packet boundary and promises neither delivery nor order. Length prefixes,
serialization, reliability and replication all need requirements of their own;
putting one guess here would make a game work around the engine to choose
another.

Resolution and client connection are `Future` sources because both settle once,
can fail before producing a usable object. Rust workers perform those two
operations and the SDL thread polls ordinary results through the checked native
boundary. The owned TCP object is a `TCPSocket`: `connect` and `accept`
produce a connection, while byte stream describes TCP's ordering rather than
the resource's identity. TCP listeners, TCP sockets, addresses, and UDP sockets
are not futures: they remain useful across many frames and own a native
lifetime, so each is closed explicitly. A received UDP packet takes ownership
of its source address and copies the native packet into an owned `Buffer`;
closing the packet releases both.

The application polls `tecs.io` once per iteration, beside the other services
whose finite asynchronous work has to settle without a system remembering to
drive it. The empty path is one list-length check. Keeping that check out of a
game with no pending work was not worth the failure mode where a resolution,
connection or transfer stays pending forever because the game forgot a pump.
The poll remains public because a headless server using the ECS drives the same
module without an `Application`, and `Future:wait` drives the same source when
blocking outside a frame is the honest operation.

## The window

[`platform/window.tl`](src/tecs/platform/window.tl) is what SDL's window and
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

`cargo xtask bench latency` produces the number without a human at the keyboard. It
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
allocation is measured on its own, by `cargo xtask bench alloc`, and held by
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
machine-code arena the Rust host reserves at startup, so LuaJIT cannot
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
slot, hands the backend's mapped addresses to the extractor, and centers the
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
end rather than shifting its neighbors, and the slots nothing occupies are
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

That shape is what the `spawner` regime of `cargo xtask bench sprites` builds:
a still field spread over archetypes a spawner cannot reach, and a wave of
sprites rising and falling in one of its own. The regimes that hold every
sprite in a single archetype cannot tell the two layouts apart, which is not a
gap in them but the same fact stated from the other side.

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

### Structural dirt is a set of rows, not a set of columns

Reserving stops a spawn moving the archetypes around it and does nothing about
the one it landed in. Moving a row into an archetype marks every one of that
archetype's columns dirty, while the structural residue lets extraction narrow
that broad signal to the rows whose storage changed.

The broad component mark is necessary. A
placement's row is storage no consumer has seen: capacity grows without
initializing and a removal shrinks the run by decrementing a count, so the slot
at `length + 1` holds whatever its last tenant left there. And a swap-pop
genuinely moves a row: the surviving row at the removed index now belongs to a
different entity, in every column. So the **component set** the mark names is
exact. What is an over-approximation is the **row set**, and the rows are a
contiguous suffix plus a bounded set of swap-pop destinations already known to
the structural path.

`partialRewrites` keeps them. `markAllComponentsDirty` sets one flag rather than
every bit, and `isComponentDirty` composes the flag in, so every consumer reads
the same answer it always read; alongside it the archetype records a monotonic
count of structural changes and, per frame, the lowest row appended and up to 64
swap-pop rows. Extraction records the count each run was last written at and
writes the rows the residue names. One spawn into a 200,000-row archetype then
costs one row.

The residue belongs only to the structural path. Value writes declare intent
through `getMut`; a dirtied column still rewrites the whole run because naming
a column says nothing about which rows changed.

Writing and marking are separated, and only writing has to be exact. A byte
range list tracks 64 spans and then collapses to one covering everything in it,
gaps between runs included, so a frame of scattered rows marked one span apiece
could upload more than one covering span. Extraction therefore
names spans individually while the frame's lists are under half their ceiling
and names the run's covering span past it, which is exactly what a whole-run
rewrite marks. The upload is therefore bounded by the covering span and shrinks
when the changed rows are few or clustered.

Two regimes get nothing from it, both because something wider is genuinely
dirty. An archetype carrying `PreviousTransform` is interpolated, so its drawn
positions move on every frame landing at a new point in the fixed step. And a
`batchSpawn` fill callback takes `getMut` on the columns it initializes, which
declares the whole column: correct, and the reason a bulk load resyncs whole.

The hazard worth naming is what this stops masking. A spawn anywhere in an
archetype rewriting its whole run accidentally repaired any row whose cdata was
written through `world:get` without the `world:markComponentDirty` that goes
with it. That repair is gone, so a defect of that class becomes a visible stale
instance rather than a latent one. It is why the option defaults to off, and why
the guard on it is a differential spec rather than a set of expected numbers:
one seeded churn stream is applied to two extractors, one partial and one not,
and every float of both buffers is compared after every frame.

One thing a frame derives from the rows it wrote is not bytes, and it does not
compose with a partial write for free: the count of instances routed to the
forward pass. A whole-run rewrite counts a run's blended rows as it writes them,
which is the run's own total. A partial rewrite sees a subset, and the count it
takes from that subset is smaller than the run's. Storing it under-reports, and
the backend skips the entire forward lane at zero, so under-reporting is every
blended instance in the scene going missing. It is the one direction that cannot
be tolerated, so the count is either exact or wrong the other way.

It is exact, and free in the case that matters. The partial path only runs while
no value write has landed on those columns since the run was last written, in any
phase of any frame, so a row it did not write carries the tint it carried before
and cannot have changed lane. A run whose last write found nothing
blended therefore has the residue's own count as its whole answer, which is what
an opaque scene is and what this option exists for. A run that did hold a blended
row is recounted, one float per row, because a swap-pop may have written over
that row or the run may have given it up off its end and neither is anything the
residue names. That is a row walk on structural-change frames for archetypes that
blend, against twenty floats per row for a whole-run rewrite, and
nothing at all for the archetypes the option was built for. The differential
compares the count beside the bytes, and a third of the churn stream's spawns are
translucent so that there is a count to disagree about.

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
apart and a filter that reaches past an edge finds the color that was already
there. The rect a caller samples is the image's own texels and never the gutter,
so a neighbor packed beside it is unreachable however the sub-rect inside it is
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
is normalized before it becomes an identity, so `a/b.png` and `a/./b.png` are
one image and not two layers holding the same pixels. Only what a spelling
cannot disagree about is dropped, which is repeated separators, `.` segments
and a trailing separator. Nothing there reads the filesystem, so a name
normalizes the same before its file exists as after, and `..`, letter case and
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

That phase is also what the dirty bits cannot be read against. They clear at the
end of the update, and the sync runs inside it, so a spawn, a despawn or a value
write from any later phase sets a bit that is wiped before the next sync looks:
not one frame late, but never. So the archetype keeps two monotonic counts
instead, one for structural changes and one for value writes to the columns a row
is drawn from, and each run records the count it was last written at. A count
survives the clear, so the change is still a difference a frame later.

Two cheaper shapes lose. Carrying the bits forward into the next frame answers
the same question and breaks the property the counts keep: a change has to stop
being dirty the frame after it happened, or a scene that moved once rewrites for
ever. And bumping the value count where a column's bit goes from clean to dirty,
which would cost one add per column per frame rather than one per write, is wrong
for the reason it is cheap: the bit's window is the frame. Two writes to one
column in one frame, one on each side of the sync, find the bit already set the
second time, and the second write is exactly the one the sync has not seen. A
spec pins it, and it fails under that version.

The read is cheaper than the bits it replaces either way. Asking eight columns
whether their value bits are set is eight lookups into the archetype's
column index and eight bitset reads per archetype per frame; asking the count is
an integer compare. Which columns count is the component's own opt-in, so
extraction pays for the eight it draws from and a game's own components cost it
nothing.

## Sprite sheets and playback

The model is Aseprite's, because that is what the art is authored in. A sheet
is a list of frames, each holding for its own duration; a set of named tags,
each an inclusive span of frames played forward, in reverse, or pingpong; and a
set of named slices carrying rectangles, nine-slice centers and pivots that
move from frame to frame. Tag zero is the whole sheet, forward.

Reading an Aseprite JSON export is one function in front of that model rather
than a second model: `animation.newSheetFromAseprite` walks the export and writes what it
finds through the same builder everything else uses, so a reader for the binary
`.aseprite` format populates the same sheet without reshaping anything. Both of
Aseprite's frame layouts are read, the array and the object keyed by frame name,
the second in sorted name order because the names carry the frame number.
Trimmed exports are not: `spriteSourceSize` is ignored, so export with trimming
off.

`animation.newSheetBuilder` is the model's own front door, for an atlas from any other tool:
frames, tags and slices in any order, `finish` to register. `animation.newGridSheet` cuts a
uniform grid (with an optional margin around it and spacing between the cells)
and `animation.newRectSheet` takes an explicit list, and both are that builder with a loop
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

Tag zero being the whole sheet is also what makes a misspelled tag name
dangerous. `Sheet:tagId` has no index to answer with, and zero is a plausible
animation rather than a visible failure, so a typo plays every frame of the
sheet and nothing else goes wrong. It is reported at error level, with the tags
the sheet does carry, and the fallback stays, because the paths that arrive with
a name do not all want the same answer. `animation.of` and `animation.play`
raise: an author naming a tag there has one in mind, and the sheet is already in
hand to check it against. A particle effect's `render.tag` and a restored
snapshot's tag name cannot raise, since the first would fail an effect
definition over a diagnostic and the second would make a re-exported sheet
unloadable. The report lives in the lookup rather than at each of those call
sites, so a path added later cannot miss it, and it is memoized per sheet and
name, which is what makes putting it there safe: a caller resolving a tag every
frame reports on its first frame and stays quiet afterwards. Nil and the empty
string are the whole sheet on purpose, and the empty string is what a snapshot
stores for tag zero, so neither is reported.

Slices are where pivots come from, rather than an origin API invented beside
them. A slice holds a key until the next one, so `Sheet:pivotOf` answers the
key in force on a frame, adds the slice's own origin, and divides by the frame:
what comes back is a fraction of the frame, so nothing downstream has to know
the sheet's pixel sizes. A slice with a nine-slice center but no pivot answers
the middle of that center, one with neither answers the middle of its own
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
cull bound is centerd on the quad rather than on the entity, so it stays exactly
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

Playback is quantized to the fixed step and never to frame time, because
animation is simulation: two machines fed the same recording have to show the
same frame, and anything driven by frame time shows a different one on the
machine that drew more frames. So the clock playback reads is the world's count
of completed fixed steps rather than a sum of seconds, and every frame drawn
inside one step shows the same animation frame.

A frame is a region of an image and not a region on its own, so the layer it
lives on belongs to the frame as much as the rect does. Both are the frame
table's rather than the entity's, which is what makes a sheet rebound to another
image cost one table and no instances at all: an entity carrying a resolved
region would go on sampling the layer the image left with the rect it landed on.
A sheet with no image bound says so, and the quad keeps whatever layer it had.

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

## Playback resolves in the shader

The arrangement this one is measured against is a system that walks every playing
animation on every fixed step and writes the frame's region into the entity's
`Sprite`. It cannot reach a large animated scene, and the reason is the dirty
gate rather than the walk: one animating sprite marks the `Sprite` column of the
archetype it lives in, a dirty column has its whole run rewritten and uploaded,
and two thousand animating sprites in a field of two hundred thousand therefore
cost two hundred thousand instances written. That is measured rather than argued:
`cargo xtask bench sprites` reports it as `rewritten`, and the sparse regime
exists to show it.

Playback therefore resolves in the shader. The instance's region fields stop
carrying a region and start carrying enough to compute one: which animation is
playing, the fixed step it began on, and how many ticks of clip time it advances
per step. A frame changing then writes nothing at all, and what a step costs is
what actually changed rather than what is shaped like it. At two hundred thousand
sprites all animating, `rewritten` is zero against a mean of eighty-five thousand
a frame for writing the regions on the host, and the frame time lands on what a
scene of the same size that never animates costs.

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

The clock is a count of fixed steps, carried in the frame packet and pushed in
the spare component of the layer uniform. Steps rather than seconds is what keeps
playback on the simulation's clock: two machines fed the same steps show the same
frame however many frames either drew, and every frame drawn inside one step
resolves the same one. It also costs no binding and no second push, because that
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

### The clock comes round

Both quantities the shader multiplies have a ceiling, because both are floats. A
float32 names every integer up to 2^24, which is 77 hours of steps at sixty
hertz, so a clock that only ever grew would eventually stop naming every step.
And the ticks a row is into its cycle are the difference between the clock and
the row's start step times a rate, which a float32 resolves to a whole
millisecond only while the product stays under the same 2^24, about four and a
half hours of one animation playing. Past that a boundary lands a tick late, then
two, then a whole step. A game left running all day drifts and then stutters.

So `tecs.RebaseAnimation` moves the clock's origin up to the step the world has
reached, every `frametable.REBASE_STEPS`, and rewrites every animated row's start
step against the new origin. That is two and a half hours of uptime at sixty
hertz, one rewrite of the animated rows on the update it happens, and nothing on
any update either side of it.

Subtracting a constant from the clock and from every start step is the version
that suggests itself, and it moves the growth rather than removing it: the start
steps go as far below zero as the clock was above it and lose exactly the
resolution the rebase was for. What makes it work is that a cycle repeats. The
rebase folds each row's phase into its own cycle before re-anchoring it, which is
invisible because whole cycles are what the shader's own wrap takes off anyway,
and the elapse a row carries is then bounded by the period instead of by the
world's age. That is also what sets the period: `REBASE_STEPS` times a rate has
to stay inside the exact range, which holds to about twice the authored speed at
sixty hertz and quantises in proportion to the rate above that rather than in
proportion to how long the game has been on.

The origin lives with the encoding, in `frametable`, because a start step and the
clock it is subtracted from have to share one, and it is per world since a start
step is written into a row of one world. Extraction publishes `frametable.clockOf`
rather than `world:fixedStepCount`, so the world's own count stays what it claims
to be, a number of steps that only increases, and the only clock that comes round
is the one playback measures against.

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
question this is the wrong shape for.

That these two answer the same thing is the one agreement worth a spec, and one
walks every tick of every tag holding the tick table to `Sheet:frameAt`. Two GPUs
can still disagree by a last place on the multiply that turns a step count into
ticks, which moves a boundary by at most a tick and only for an entity sitting on
one. That is a display difference of well under a fixed step and it cannot reach
simulation, because gameplay reads `frameOf` rather than the shader's answer.

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

A color clear comes from the target rather than from the pass, which is right
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
the packet says how many instances the frame may blend, and the whole lane is
skipped at zero. That number is exact for the rows extraction wrote and an upper
bound for a producer's, because a producer whose instances are written by compute
cannot count what a frame actually has. Over-reporting runs a lane that finds
less than it expected; under-reporting drops it, so the bound is the safe way
round and the particle pool answers with the slots its blended effects reserve.

The forward pipeline blends premultiplied rather than straight alpha, which is
what lets one pipeline and one draw serve two looks. The fragment shader scales
its color by its own alpha either way; what it writes into alpha is what chooses
the mode, so an alpha of zero beside that scaled color adds to the target instead
of covering it. Two pipelines would mean two draws over one list, and every
additive instance in the frame would then land after every alpha-blended one
whatever their depths said. Which mode an instance is in rides in `origin.z`
beside its array layer, clip region and cast height, since a blended instance
casts nothing and a caster blends nothing.

What it gives up is resolution. There are 256 buckets, so two blended instances
whose depths differ by less than one part in 256 draw in the
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
again at the first of them. The view arrives as a center and a rotation divided
by the zoom, because an orthographic projection inverts to a 2x2 and an offset
and a fragment should pay two multiply-adds rather than a 4x4 by a vec4. A
pipeline nothing sets a view on centers one on its own target, which makes
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
already being written, with a constant.

### Emission has an attachment of its own

A surface that gives off light is not a surface a light reaches, so emission
needed somewhere to live that lighting reads rather than writes. Nothing was
spare: the albedo's alpha is carried through to the composite and the normal's
alpha is the lit flag, so both existing attachments are spent. It has a color
target of its own. The cost is one more full frame-sized RGBA8 target, about
8 MB at 1080p, four more bytes written per covered fragment and one more texture
fetch per pixel in the resolve.

An attachment rather than a scalar packed into the spare bits of the normal's
alpha, because a glow's color is not its albedo. A lamp's glass is grey and
glows warm, and reconstructing emission from the albedo would make every
emissive surface glow in its own diffuse color.

The attachment holds a color and a strength rather than one premultiplied
color, and that is not the redundancy it looks like at eight bits a channel:
premultiplying a dim warm glow quantises its hue away, while a color plus a
strength keeps eight bits of each.

Emission is added to the resolved pixel rather than multiplied into it, past
the ambient, past every light and past the drop shadow, on both sides of the
unlit branch. That is what separates it from a material asking not to be lit,
which replaces the lighting with the albedo instead of adding to it. A lamp can
therefore be lit and glowing at once, and a glowing sign is as bright in the
dark as under a light, which is the whole of what makes it a sign.

What says a thing emits is its material, not a component. The instance record
is four vec4s with no spare lane, and a component would widen it for every
entity in the world to carry something almost none of them have anything to say
about. A material reads `frag.param` and `frag.color` for per-entity strength
and color, and `materials.addRoot` and `materials.define` are how a game brings
its own. Per-texel emission is a sidecar image, which is the same piece of work
a normal map is.

The forward blended lane adds its own emission to its own color and writes no
attachment. It cannot write one: it runs after the G-buffer has been resolved,
which is the price of the lane. So a translucent emitter glows, scaled by its
alpha along with everything else, and it will not reach a later pass that reads
the attachment.

### ORM fills the fourth attachment

Surface properties occupy the last color target a render pass allows. Red is
ambient occlusion, green is roughness, blue is metallic and alpha is reserved.
The neutral value is `(1.0, 0.5, 0.0, 1.0)`: fully unoccluded, medium roughness
and non-metallic. It is both the material default and the attachment clear, so
every built-in keeps the image it had before the target existed.

Ambient occlusion multiplies ambient light and no point-light contribution. It
is an authored approximation of indirect light the surface cannot receive,
while a point light has a known direction and the shadow mask says whether it
reaches the fragment. Roughness and metallic are written now and deliberately
do nothing under Lambert. The Cook-Torrance term consumes them together, so
giving either an unrelated approximation here would be a second lighting model
to remove when that term lands.

Packing the values into the other attachments lost. Albedo alpha is still the
coverage composite carries, normal alpha is the lit flag, and emission needs
its color plus strength. Taking any of those channels either removes an
existing answer or makes a surface property reconstruct from albedo, which is
false for a painted metal and an occluded white surface alike.

The target costs another frame-sized RGBA8 allocation, about 8 MB at 1080p,
four bytes written per covered fragment and one fetch per lit pixel. Deferring
it until the physically based term would save that fetch temporarily and make
the material contract, geometry pipeline and resolve bindings change again in
the same work that changes the BRDF.

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
covered it and not of their order; on an unsigned normalized target that is bit
exact. Nothing in the subsystem uses an atomic, for the same reason nothing else
here does. The one cap that binds, four lights per caster, is applied by
descending weight in a fixed comparison network rather than by buffer order: a
cap that binds by buffer order drops whichever shadow sits later in the buffer,
which can be the brightest, and makes shadows move when an unrelated light is
spawned and the slots shift.

Off, which is the default, the whole of it costs one more count in a scan that
was already running. On, it costs three targets, four passes, four pipelines,
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
the text producer and the particle pool share one definition.

Not clipping costs nothing. An archetype with no `Clip` column is written by a
loop that never mentions a region, and the float it writes is the layer. In the
fragment shader the index is a flat varying, so an unclipped
instance takes a branch its whole primitive agrees on and never reads the
region table; and the test lands on the coverage the material already returned,
using the same `discard` path as distance fields.

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

## UI is layout over entities

Taffy owns UI layout and nothing else. A retained Taffy tree in Rust is keyed
by the same entity IDs the world already owns, and `ChildOf` is its hierarchy.
Styles cross the FFI only when their component column is dirty; computed boxes
come back into `UiLayout`, and only changed boxes mark that column dirty. Taffy
therefore replaces neither the ECS nor the renderer and introduces no DOM
beside them.

A rectangle, circle, image and text remain their existing components, material
and instance producer. `UiPaint` can copy a box into the transform scale, but
the entity still reaches the GPU through the same archetype run or text
producer as one positioned without UI. Layout does not create a second drawing
path, which keeps shape instancing and text residency intact.

`UiScroll` moves descendants after layout and treats its own box as a viewport.
Nested viewports are intersected on the CPU and receive one of the existing
clip indices, because an instance has room for one index and the fragment
shader already tests one rectangle. The plugin owns a caller-selected range of
the renderer's 255 indices and fails when that range is exhausted. Scroll and
clip precede event routing so a later hit test can reject the same off-viewport
content the GPU rejects.

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
quad with a UV rect addressing its packed texture-array region and a material
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

The glyph is SDL_ttf's single-channel signed distance field. Scaling it changes
the quad while the threshold stays on the outline, and screen-space derivatives
keep the transition one pixel wide. The material reconstructs the field
bilinearly itself because the shared image sampler reads nearest. SDF trades
some corner fidelity for a smaller texture footprint and, unlike MSDF, is
available from SDL_ttf without a second rasterizer and cache.

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
particles spawn and evolve, built by `particles.newEffect`, registered once under a
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
state. Two consequences follow. Adding a randomized property does not shift
every other random choice, so an effect edited to randomize its rotation keeps
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
end, so a randomized lifetime randomizes the playback speed. Per-frame
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

**Particles blend by default.**
Routing into the forward lane is negating the first half extent of a cull bound,
and a particle's bound is written by the simulate pass rather than by extraction,
so the pass reads one float off the effect record and negates or does not. That
is the whole of the mechanism, which is the point: nothing downstream of the
bound had to learn what a particle is.

`render.blend` names `"alpha"`, `"additive"` or `"opaque"` and defaults to
`"alpha"`. The G-buffer writes with replace and has nowhere to put partial
coverage, so an opaque gradient ending at transparent black would cover what is
behind it with black. Alpha over at an alpha of one is the same image the
G-buffer produces. A blended particle is not in the occluder mask, is not
shadowed by one, and carries no normal into the resolve. An effect that needs
any of those asks for `"opaque"` and gives up alpha in exchange, which is the
trade the two names make explicit.

Additive is not a second pipeline. The forward pipeline blends premultiplied, so
the fragment shader chooses between covering and adding by what it writes into
alpha, and the mode rides in the same `origin.z` that already carries the array
layer, the clip region and a caster's height. One pipeline, one draw and one sort
therefore serve both, and an additive spark interleaves with the alpha-blended
smoke around it rather than being drawn as a second pass after all of it.

What is still not sorted is a pool against itself. An effect names one layer and
its particles take one depth within it, so they land in one bucket of the forward
sort and composite in pool-slot order: deterministic, correct for additive, and
arbitrary for alpha among particles that are all at the same depth anyway.
Per-particle depth is what would change that, and it is the feature the plan
defers rather than a consequence of this one.

## GPU-driven by default

`cargo xtask run` animates 4000 instances and never tells the GPU how many of them to
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
`tecs.gpu.shaders`, and `cargo xtask shaders` walks that registry and writes a pack:
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
it are written, so the neighbors sharing its layer are untouched.

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

Fonts follow SDL_ttf's ownership model. `newTTF` asynchronously reads source
bytes, opens one immutable
`TTF_Font`, enables SDF rasterization, and returns it only after those steps
succeed. SDL_ttf and HarfBuzz own shaping and line layout. Tecs deliberately
does not use SDL_ttf's GPU text engine: that engine emits four vertices and six
indices per glyph, while this renderer's throughput comes from one fixed quad
and one instance per glyph.

SDL_ttf's copy operations are therefore an interchange format, not a rendering
backend. A dirty string updates one reusable `TTF_Text`; a transform, tint,
clip, alignment, or display-size change reads its existing operations and
rewrites only that entity's producer span. The first operation needing a glyph
asks SDL_ttf for its SDF surface and uploads it into the renderer's packed
texture array. The cache is keyed by native font and glyph index, so later
texts reuse both the rasterization and the residency. `Text.size` scales those
instances and never changes the native font generation.

SDF is the sole field format for now. It costs one texture channel, works with
SDL_ttf's public raster API, and preserves the instanced renderer. MSDF would
require a separate generator and cache policy without changing the public text
model, so it is deferred until its sharper corners justify that second
backend. Source fonts are immutable after loading; editing one creates a new
font through `newTTF` instead of mutating live layout and cache identity.

### The file watcher

Four of those five are driven by an agent that knows it edited something, and
also by a watcher that notices. The sheet is the exception, and by omission
rather than by decision: no kind is registered for one, so `animation.replace` is
reachable from game code alone.

SDL has no change notification: not in 3.4 and not behind a hint, and
`SDL_AddEventWatch` watches the event queue rather than the filesystem. What
`SDL_filesystem.h` offers is `SDL_GetPathInfo`, which answers a type, a size and
three timestamps. So `tecs.io.watcher` polls through the installed storage
backend, and going native to avoid polling would mean inotify, FSEvents and
`ReadDirectoryChangesW`, plus one more for every platform whose SDK is licensed,
to save work measured below in microseconds.

It polls what was loaded rather than the content tree. `files` records
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
`read` takes the kind from whoever asked for the bytes and the call that loads
a font is the one that names it a font. Which reloader owns a kind is
registered by the application, not by the watcher, so the I/O modules do not
have to know what an image or a clip is.

It is development only. `Application.Config.watch` starts it, the `watch` tool
turns it on, off and a poll at a time, and `install` asks the explicit
`hotReload` capability rather than inferring itself from the shader kind. The
current development presets enable both hot reload and runtime shader
compilation, while a release enables neither and polls nothing.

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

### Runtime Teal

The host also accepts a `.tl` entry. It loads the pinned Teal compiler carried
beside the engine, compiles that entry in memory, and installs Teal's module
searcher for the state. A required `.lua` still wins over a `.tl` file with the
same module name, so an ordinary precompiled release changes neither its load
order nor its startup work.

Set `TECS_TL_PATH` to one or more semicolon-separated source roots when an
entry is below the root that its module names are relative to:

```sh
TECS_TL_PATH=src tecs --entry src/main.tl
```

The entry's own directory is always searched. Runtime compilation parses and
generates Lua but does not reject Teal type errors, so `tecs check` and a
precompiled release remain the normal gates. This is deliberately available in
production for source-distributed games and mod loaders; it does not make that
the default release path.

## Porting to a platform SDL does not cover

SDL covers every platform this engine can be built for openly. It does not
cover the ones whose SDKs are licensed, and those cannot live in this repository
even for someone who holds a license, because their headers may not be
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
 static FFI  Function pointers taken at build time      Rust registry installer
 storage     Content, persistent and cache roots, and   adapter.basePath/prefPath/
             how a file under one is reached            cachePath and adapter.storage
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
two: a platform names its content, persistent-state and disposable-cache roots,
and also supplies the operations that reach a file under them. A platform that
invents a root is not served by the engine then reading that root with the
host's own file calls. The pack layout does not change for a platform with
private bytecode; only the declared format does.

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

These shape the seam and constrain everything built on it.

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

**The ECS and the engine are one project.** The renderer reads archetype
columns, and the ECS's storage layout decides whether that is fast. Keeping both
in one project makes GPU-readable storage a property of the component model
rather than an integration boundary.
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

So the build emits, for each native namespace, a struct of typed function
pointers and generated linker glue that takes each address. Rust installs
those tables into every Lua state, including every worker state, before any
Lua runs. The registry covers SDL, SDL_mixer, shaderc, SPIRV-Cross, zlib, and
the Rust services for TCP and UDP, HTTP, the official RMCP debug server,
images, physics, workers, dialogs, logging, CLI parsing, and payloads.

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

The Cargo binding generator runs the system preprocessor over the installed headers,
keeps the declarations that came from the library, and rewrites them into the
subset of C that LuaJIT's parser accepts. Integer `#define` constants are
recovered separately by compiling a program that prints them, because the
preprocessor expands them away before a cdef could see them, and because many
of them (`SDL_WINDOW_RESIZABLE`) hide behind helper macros that pattern
matching misses.

A hand-maintained cdef does not fail to link when it drifts. It reinterprets
memory and surfaces later as corruption far from the cause. `cargo xtask abi-check`
compares LuaJIT's view of every generated record against the C compiler's:
size, alignment, and the offset of every field. It currently verifies 219
records. A binding whose header is written against another library's types
names that one as a prerequisite, which is how SDL_mixer's records are
declared against SDL's.

Header-only `static inline` helpers have no symbol to bind and are
reimplemented in Lua. That is usually faster anyway, since the JIT can inline
Lua where it cannot inline across an FFI call.

## Layout

```
Cargo.toml                project workspace and canonical build entry
xtask/                    project assembly, generation, checks, and packaging
native/rust/runtime/      host, services, image, HTTP, physics, and CLI parsing
native/rust/build-support reusable build and generator implementation
native/rust.h             the C-compatible ABI LuaJIT reaches
native/                   headers, generated linker glue, SPIRV-Cross wrapper
src/tecs/init.tl          the public API: one module per name, ECS and engine
src/tecs/ecs.tl           what a game writes, and what engine modules require
src/tecs/global.d.tl      declares the `tecs` global, typed off init.tl
src/tecs/Application.tl   the lifecycle the host drives
src/tecs/ffi/             library loading and generated binding wrappers
src/tecs/platform/        window, events, input backends, sensors, OS services
src/tecs/gpu/             device, frame, passes, shaders, pipelines, buffers
src/tecs/components.tl    components the engine renders and simulates
src/tecs/gfx/             camera, layers, sheets and playback, text, particles
src/tecs/Renderer.tl      the world-to-GPU bridge, owning both halves below
src/tecs/Extractor.tl     the world-facing half: a world to a frame packet
src/tecs/Backend.tl       the device-facing half: a frame packet to a frame
src/tecs/FramePacket.tl   what crosses between the two
src/tecs/audio.tl         clips, voices, groups, and the Sound component
src/tecs/physics/         Rapier binding and its world plugin
src/tecs/sequence/        the sequencer, and the tween runtime inside it
src/tecs/io/              files, HTTP, MCP, and loaded-file watching
src/tecs/io/mcp/          the debug server: transport, tools, sandbox
src/tecs/assets.tl        images and clips, decoded on a worker
src/tecs/workers.tl       threads with serialized channels
src/tecs/Future.tl        the value everything asynchronous settles into
src/tecs/io.tl            binary contracts plus nonblocking TCP and UDP
src/tecs/io/http/         requests, and the clients the loop turns
src/tecs/random.tl        seeded streams and Perlin noise
src/tecs/data.tl          stores, JSON, DEFLATE, UUIDs, hashes and checksums
src/tecs/regex.tl         compiled Rust regular expressions over byte strings
assets/                   shaders, materials and fonts, globbed at build time
spec/                     busted suite
bench/                    where the numbers in this file come from
```

## Build

Cargo is canonical. The root workspace owns the Rust runtime and a dedicated
`xtask` binary owns final assembly, native dependency builds, generated files,
tests, packaging, and repository maintenance. Native dependencies may use
their own upstream build systems internally; they do not add a second project
build graph.

That keeps a single-file build single: Cargo, the crate graph, and native
archives are build inputs, not files a game needs at run time. Every product
build first runs `rustfmt --check` and Clippy with warnings denied. The runtime
owns image decoding, networking, HTTP, the RMCP Streamable HTTP server,
physics, regular expressions, and Clap parsing while Teal retains the public
API and command implementations.

```
cargo xtask presets       list the platform matrix
cargo xtask build         build the host development preset
cargo xtask run           run the demo
cargo xtask test          run the spec suite
cargo xtask check         type-check Teal sources
cargo xtask abi-check     verify generated cdefs against the C ABI
cargo xtask package --preset macos-arm64
cargo xtask check-package out/package
cargo xtask test-package --preset macos-arm64
cargo xtask single        build out/single/bin/tecs
cargo xtask deps          install development dependencies (Homebrew)
```

The single executable also carries the documentation site's pages. `tecs docs`
lists them, and a query such as `physics` finds one without a project or a
network connection. It carries the prose and not the reference: a page's
signatures are rendered from `src` when the site is built rather than written
into the tree, so a name like `tecs.physics.attach` is not something a copy of
the pages can be asked about. Staging the rendered site instead of its sources
is what would put those back, and it costs the product build a site render.

`--preset` selects the target; when omitted it selects the host development
preset. Presets come in two kinds. A development preset resolves dependencies
from the system, which is convenient and not shippable: it links the build
machine's libraries by absolute path. A packaged preset builds pinned revisions
from source, so a release is reproducible and carries no path from the machine
that made it.

A packaged preset also builds the pinned LuaJIT and SDL family. LuaJIT's
Makefile refuses to guess a deployment target on Apple, so the macOS presets
name one.

`cargo xtask check-package` is the gate on that distinction. It inspects the installed
binaries for search paths and absolute references that leave the package, and it
checks that a pack is there, since a release ships no compiler and must
therefore ship its shaders. The checker also refuses a shader compiler
outright unless `--allow-compiler` is passed for a development install. Only a
packaged install can pass the containment checks: a development one keeps its
link paths on purpose, so the license position and packaged types are checked
and containment is reported as not run. A package that resolved a library from
the build machine works there and nowhere else, and the failure only appears
once someone else unpacks it.

`cargo xtask test-package` is the other half of the same idea. It runs the
package checker and the headless specs against a freshly installed tree. The
rest of the spec suite belongs to the development build: shader-reload specs
require the compiler a release deliberately omits, and rendering specs require
a display. Native loading prefers the package's discovered `lib` directory
before the machine's plain soname, so a packaged SDL cannot be mixed with a
system SDL in one process.

It holds the installed types to the same standard, for the same reason: it
type-checks a file that uses the `tecs` global against `share/tecs/teal` and
nothing else of the engine's, so a package whose type information is missing or
incomplete fails here rather than for whoever unpacks it. That one fails on
both kinds of install, since types are not something a development build is
allowed to borrow from its machine.

`TECS_FRAMES=N cargo xtask run` exits after N frames, so an automated run can drive
a real window to completion.

## One program owns both halves of a documentation page

Tealdoc renders the site from `tealdoc.site` in `tlconfig.lua`. A module page
contains frontmatter and its title, then Tealdoc appends the reference rendered
from the modules that page names. The module's leading long doc comment carries
its introduction and examples, and declaration docblocks carry symbol
contracts. Guides under `docs/` remain Markdown because they span modules. A
signature cannot drift from its page because no second copy exists.

A `before_build` hook in the same file requires every public name in
`src/tecs/init.tl` to have a page, rejects a page with no module, keeps both
module listings aligned with the declaration, and gives the sidebar one row per
page. The pages are derived from `SURFACE` rather than transcribed beside it, so
a renamed module fails at its declaration instead of leaving an orphaned page.

A page's reference comes from a list of modules rather than one, because a
public name is a namespace and a module is a file and the two do not have to
agree. `tecs.gfx` is assembled from four files, `tecs.input` from
three and `tecs.gfx.animation` from two. `tecs.platform` itself has no
principal module or combined reference; its children each keep their own page.
Every entry in that list goes away the day its namespace is one module, which
is what `AGENTS.md` already asks for.

`tecs docs` carries the composed pages. Product builds stage that Markdown from
the rendered site and rebuild it only when a Markdown or Teal input is newer
than the last render, so an unchanged build does not pay the render cost.

Type is sized in `rem`, and the root size is one value at every width. Browser
zoom therefore scales the same layout rather than changing spacing at viewport
breakpoints. The hero and root size are pinned because base text size belongs
to the site rather than the generator.

The sidebar opens the section holding the page being read, and nothing else.
Open at once it is a hundred and fifty rows, and a reader scrolls past the
whole surface to reach the part they are in. A group's name is the prefix of
every name under it, so a closed `tecs.gfx` still tells a reader looking for
`tecs.gfx.layers` whether to open it.

## Requirements

Rust/Cargo 1.97.1, LuaJIT, SDL3 (3.4, for SDL_GPU),
SDL3_mixer, shaderc, SPIRV-Cross, zlib, and Teal
(`tl`). `rust-toolchain.toml` selects the Rust toolchain. A development build
requires every one of them. `cargo xtask deps` installs the ones Homebrew supplies; zlib is not
among them, because a development preset finds the host's.

A version is a requirement rather than a floor. The spec suite runs against
whatever a development preset resolved, so a suite run against a different SDL,
SDL_mixer, LuaJIT or shaderc than the pinned revisions in the build-support crate
names is not testing what a release ships, and the build fails on the
difference rather than leaving it to be found as a spec that passes on one
machine and not another. `TECS_ALLOW_VERSION_DRIFT=1` permits a deliberate
dependency update. SPIRV-Cross and zlib are unchecked because neither exposes
the release identity needed for that comparison.

`cargo xtask deps` runs that check itself, at the end, on the machine it just
installed to. It has to, because it is the one command here capable of breaking
the gate: Homebrew carries one version of a formula and it is the current one, so
four of the packages `deps` installs are pinned by this tree and unpinnable
through `brew`, and installing them is a way out of the pin. The alternative
would be for `deps` to skip them, which trades a command that reports what it did
for a command that cannot set a machine up at all. So it installs and then says
so, where whoever ran it is still reading the output, rather than leaving the
next build to fail on a version nobody chose.

A development build takes SDL_mixer from the system, and a system build is
whatever the packager configured: Homebrew's loads its optional decoders by
name at `MIX_Init`, so a developer's machine may well have the LGPL ones
available where the pinned package does not.
`Audio.decoders()` is how to tell which build is running.

Image decoding does not have that development/package split: every build links
the same pinned Rust `image` crate with only PNG and JPEG enabled and the same
`resvg` SVG rasterizer.

### Licenses

Everything this engine links is permissive, and it stays that way. LGPL is the
one rule with no exceptions, because a statically linked game cannot satisfy
the relinking obligation and a shipped binary is what this is for. It is not
left to a document: the Cargo dependency builder names every decoder option
that would fetch one, `spec/licenses_spec.lua` holds those options to their
values and fails on a name it does not recognize, and the package checker holds the
libraries an installed tree actually links against a list carrying a license
and a reason for each. Neither of those two checks reads a license out of a
binary, because that is not something a binary carries; what they prove is that
nothing gets linked without somebody having written down what it is.

The spec asks both directions. Reading the pins and asking the notices about
each catches a dependency without a notice. Reading the notices back against
the pins catches stale notices, and holding Cargo exceptions to the lockfile
prevents an obsolete exception from suppressing a check for a live package.

`THIRD_PARTY_NOTICES.md` is the list, and it installs to `share/tecs` with the
binaries it describes. A package that carried the code and not the notice would
be the one compliance failure this engine could commit on its own, so
`cargo xtask check-package` fails an install that is missing it.

System dependencies are found through pkg-config rather than a package manager's
paths, which is what lets the same build description cross-compile. TCP, UDP,
DNS, and client connection are part of the pinned Rust runtime, so there is no
separate native networking library for a build host or package to supply.

SPIRV-Cross is distributed as static archives only, and the FFI needs a shared
object, so the build links one. Whole-archive linking is deliberate there: the C
API's symbols are not referenced from the stub, so the linker would otherwise
discard every one of them.
