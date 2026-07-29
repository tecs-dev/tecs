---
description: "The application object an entry file returns and the host drives: its config, what it owns, and the frame"
outline: [2, 3]
---

# tecs.Application

`tecs.Application` is the lifecycle the Rust host drives. An entry file ends with `return tecs.newApplication(config)`,
and the host calls into the returned object to initialize, for each event, for each iteration, and to shut down.

It is not a function that runs until done. A platform that never hands control back has no loop to block in, so
the loop lives below Lua and the application is what it calls.

```teal
local tecs <const> = require("tecs")

return tecs.newApplication({
    window = { title = "Hello", width = 1280, height = 960 },
    plugin = function(world: tecs.World, app: tecs.Application)
        -- everything the game registers goes here
    end,
})
```

## One way in

A game's own code runs in systems and observers, and `config.plugin` is the only entry point. It is handed the
world and the application, and registers what it wants to happen; the world runs it.

Nothing calls back into a game per frame or per event, because the world already does both and does them better.
A system's order is declared by its phase, both systems and observers are visible to the debug server, and both
run inside a guard that keeps the process alive and inspectable after the game throws. So the four lifecycle
points an engine usually hands a game map onto what the ECS already had:

- **Startup** — `PreStartup`, `Startup`, `PostStartup`, run once at the end of initialization.
- **Per frame** — the ordinary phases, run by `world:update`.
- **Per event** — `world:observe(0, tecs.events.on.<kind>, handler)`.
- **Teardown** — `PreShutdown`, `Shutdown`, `PostShutdown`, run once before anything is destroyed.

One entry point rather than a list, because composing plugins is something the world already does:
`world:addPlugin` takes an [`ecs.Plugin`](/ecs/plugins) and is how the engine installs its own, so a game with
several calls it from in here and needs no second mechanism.

The world comes first in the signature because every plugin the world takes is `function(world)`, so this reads
as that shape with one more thing, and code moves between here and a delegated plugin without a silent argument
swap.

The plugin runs at the end of initialization, after every engine subsystem is installed and before the startup
phases run, so a `Startup` system it registers runs on this initialization rather than the next one.

## The config

Every field is optional, including `plugin`. Nothing here is validated by the application: values are passed
through to the object that owns them, so a timestep of zero is refused by the world rather than in two places
that could disagree.

### The window and the device

| Field            | What it does                                                                     |
| ---------------- | -------------------------------------------------------------------------------- |
| `window`         | [`Window.Options`](/modules/window), passed through whole                        |
| `framesInFlight` | Frames the device may have outstanding. Omitted leaves the device's own default  |
| `presentMode`    | How the swapchain presents. Omitted leaves the device's own default              |
| `ambientLight`   | Light every surface receives before any light entity contributes. Defaults white |

`ambientLight` defaults to white rather than a dim gray because a scene that has placed no lights is the first
thing anyone builds, and it should look like what it is: sprites at their own color, with lights adding on top.
A game doing its own lighting turns this down to the level it wants unlit parts of the scene to sit at.

### The world and the renderer

| Field           | Default  | What it does                                                                |
| --------------- | -------- | --------------------------------------------------------------------------- |
| `maxEntities`   | `2^20`   | Entity slots the world is sized for. `tecs.ecs.MAX_ENTITIES` is the ceiling |
| `capacity`      | `65536`  | Instances the renderer's buffers are sized for                              |
| `timestep`      | `1/60`   | Seconds one fixed step covers                                               |
| `fixedMaxSteps` | `10`     | The most fixed steps one update runs before the overload policy applies     |
| `fixedOverload` | `"drop"` | What becomes of the catch-up that did not fit; `"accumulate"` keeps it      |
| `reserveRuns`   | `false`  | Give each archetype a run with room to grow rather than packing them        |

`maxEntities` counts concurrent slots rather than lifetime spawns: a slot is given back on despawn and reused.
The arena is preallocated for this many, so it is a memory decision as much as a limit.

`capacity` is a ceiling and not a hint. An instance is a row the GPU draws: every renderable entity is one, and
so is every glyph of every text, since a glyph is an entity like any other. Rows past the ceiling are dropped
rather than growing a buffer mid-frame, and `app.renderer.dropped` counts them. It is sized independently of
`maxEntities` because the two count different things: a world full of entities carrying no `Renderable` needs no
instances at all, and one text entity needs one per character.

`reserveRuns` is a tuning setting, not a debugging one. Packed, a run cannot grow without shifting every run
after it, so a spawn anywhere rewrites every instance in the scene. Reserved, a run grows into its own slack and
the archetypes around it are left alone. What it costs is that the cull is dispatched over the slack as well as
over the rows, and that reserving needs headroom: a `capacity` sized to exactly the population leaves nothing to
reserve out of and the setting does nothing. Worth it for a scene that spawns into one archetype while most of
the world sits in others; worth nothing for a scene held in a single archetype.

### Sound, logging and diagnostics

| Field            | What it does                                                                                 |
| ---------------- | -------------------------------------------------------------------------------------------- |
| `audio`          | [`Audio.Config`](/modules/audio). Omitted opens the platform's default device                |
| `logFile`        | Log file under the writable root, as JSON Lines, beside the platform's destination           |
| `logLevel`       | Lowest priority that reaches the log at all, from [`tecs.log`](/modules/log)                 |
| `checkpoint`     | File the staged checkpoint is written to when the platform backgrounds us                    |
| `mcpPort`        | Port for the [debug server](/modules/mcp). Omitted means no server                           |
| `watch`          | [`watch.Config`](/modules/filesystem/watch) for content hot reload. Omitted means no watcher |
| `debug`          | Marks this a development run                                                                 |
| `debugMaxFrames` | Stops after this many iterations                                                             |

`mcpPort` and `watch` are omitted by default because a game should no more open a socket nobody asked for than
poll a filesystem nobody asked for. A release refuses the watcher outright.

`logFile` follows the thing that reads it. Omitted, one is written when `mcpPort` or `debug` is set and not
otherwise: the file exists for the debug server, which is what makes its `get_logs` a seek and a read rather than
a ring buffer kept in the process. Nothing is lost by the default, because SDL already dispatches to a
destination a human can read on every platform. A shipped game that wants a crash log in the field names one,
since where a game writes user data is the game's decision.

`logLevel` is separate from `logFile` beside it: one decides volume, the other durability. A game wanting
everything kept and little of it shown sets both.

`debug` is read by two things. The device is created with its validation layers on, and the log file above is
written without being asked for. It is also one of the settings [`clearCrash`](#crashes) looks at.

`debugMaxFrames` lets an automated run drive a real window to completion without a human closing it.

## What it owns

These are fields on the application a plugin is handed, so nothing has to be looked up:

- `app.window` — [`Window`](/modules/window)
- `app.device` — the GPU device
- `app.world` — the [world](/ecs/world)
- `app.renderer` — [`Renderer`](/modules/gfx/)
- `app.input` — [`Input`](/modules/input)
- `app.audio` — [`Audio`](/modules/audio)
- `app.mcp` — the debug server, when `mcpPort` asked for one

The application is handed to the plugin rather than looked up, so there is no `Application.of` and no
`Renderer.of` to call: a system that needs either captures it from here when the plugin registers the
system, and what it captures cannot be nil. [`tecs.audio.Audio.of`](/modules/audio#of) is the one accessor
of that kind that exists, because the debug tools reach the mixer holding only a world.

And four values it keeps about the run:

- `app.quitRequested` — set it to `true` to leave the loop at the end of the current iteration
- `app.suspended` — true while the platform has the application backgrounded. The loop still runs; simulation and
  rendering do not
- `app.elapsed` — seconds of **simulated** time, advanced by the frame dt, so a replay reproduces it exactly and a
  crashed run does not fold the length of the fix into it
- `app.frame` — iterations completed

## What one iteration does

In order, and the order is the contract:

1. Read the clock for `dt`, then `input:beginFrame()`.
2. Drain every event SDL delivered since the previous iteration. Each is folded into engine state and then
   emitted on the world's bus, so an observer reading `app.input` inside its handler sees the press it is being
   told about rather than the state before it. Observers see every event, including ones the engine acted on: an
   engine that consumed events would leave a game unable to tell an event it never received from one it
   mishandled.
3. Return early if `quitRequested` was set.
4. `assets.update()`, `proc.update()`, `watch.poll()` — these run outside the suspension and crash guards,
   because a decode that finished while backgrounded is finished, a child that exited has exited, and a shader
   edited to fix the crash is exactly what a stopped process is waiting for.
5. If not suspended: poll the debug server, then, if the game has not crashed, advance `elapsed` and run the
   guarded frame — `world:update(dt)`, acquire a frame, `renderer:render(frame)`, `frame:submit()`.
6. `audio:update(dt)`, also outside both guards: a sound that sticks because the game crashed or the window went
   to the background is a second failure on top of the first.

An observer is not a system, and the difference matters. The drain in step 2 runs before `world:update`, so an
observer fires ahead of every system in the frame the event belongs to and outside every phase: no fixed step, no
pause or state gating, and mutations apply at once rather than deferring to a phase boundary. A game wanting a
reaction in phase does what `Input` does, which is fold the event into something a system reads.

## Checkpoints

Mobile platforms give an application a few seconds' notice before backgrounding it, and rather less on Android.
A world is not serializable inside any of that at this project's scale, so this takes bytes rather than a
callback that produces them.

```teal
app:stageCheckpoint(save)   -- from an ordinary system, on an ordinary frame
```

Nothing is written there. The bytes are held, and the engine writes them at the one moment the platform gives. By
the time they exist the expensive half has already happened on a frame that could afford it, which a callback
would let a game postpone into exactly the moment it cannot. The host times the hook and says so past 250 ms.

Staging again replaces what was staged; there is one checkpoint, not a queue. Staging and then backgrounding
twice writes once, because a write nothing has changed since is a second chance to be interrupted for nothing.

`stageCheckpoint` raises when no `checkpoint` file was configured, because silently holding bytes that will never
be written is the one failure a game would not notice.

| Method                   | What it answers                                                      |
| ------------------------ | -------------------------------------------------------------------- |
| `app:stageCheckpoint(b)` | Hands the engine the bytes to write when the platform backgrounds us |
| `app:readCheckpoint()`   | The bytes the last run left, or nil when there are none              |
| `app:checkpointPath()`   | Where the checkpoint is written, or nil when none was configured     |

Read the checkpoint while building the world, which is what the plugin and the startup phases are for. Nil covers
every reason there is nothing to resume from — a first run, a game that never staged anything, a file the player
deleted — and none of those is an error, so none of them raises.

## Crashes

Every entry into a game's own code is guarded. When a system, an observer, the plugin or a startup phase throws,
the traceback is recorded rather than propagated: the loop keeps draining events so the window still closes, and
keeps answering the debug server so an agent that was watching gets the traceback rather than a refused
connection. Engine code is deliberately not guarded, because an engine that throws is a bug here and swallowing
it would hide it.

The first traceback wins. A throw after it is usually the consequence rather than the explanation. One of
the later ones is expected: teardown still runs `world:shutdown` on a crashed world, because a game that
acquired something before it threw still has to be given the chance to give it back, and a `Shutdown`
system reaching for what the crash left half built throws in its turn.

While the game is crashed, events are still folded into engine state and no longer emitted on the world's
bus. Quit still closes the window, `Input` still tracks what is held and the debug server's `send_event`
still reaches both, but no observer runs until `clearCrash` does, because a game whose systems have
stopped is not in a state to handle an event either and an observer that throws produces the one traceback
nobody needed.

- `app:crashed()` — the gameplay traceback, or nil while the game is healthy.
- `app:clearCrash()` — returns whether the loop resumed, and why it did not.

`clearCrash` is a debugging affordance, not fault tolerance, and its whole contract is one sentence: **another
frame to look at and a chance to reload; the world may be inconsistent, reload before trusting it.** What the
guard put back are the engine's invariants, which are the ones it can name — the command buffer is resolved, the
passes are ended, the world is applying mutations again. A game's invariants are not restored and cannot be,
because a system that threw halfway through its query left some entities updated and some not, and nothing here
knows which half or what either half meant.

What stays on screen is whatever the frame had drawn before it threw, which for a throw ahead of present is
whatever the swapchain texture last held. Recovery does not clear it, because what the game looks like is
not a decision recovery gets to make.

It refuses on two gates:

- **This build is not a development one.** With none of `debug`, `mcpPort` or `watch` set, the first crash
  latches and stays latched. That is the right shipped behavior: there is nobody there to read the frame, and
  carrying on with a world that is provably inconsistent is how one bug becomes a corrupted save.
- **Recovery was not clean.** If a pass had to be force-ended or a frame canceled rather than submitted, the
  device is not in the state the engine intended, and the next frame would be recorded against a device nobody
  can describe. That refuses at any setting.

Its callers are the debug server's `clear_crash` tool and the file watcher's reloads. Both mean the same thing:
something about the run has changed, try it again.

Physics resumability is a separate and open question: a solver stepped out of is not obviously a solver that can
be stepped again.

## The platform lifecycle

SDL dispatches the platform lifecycle from its event watcher rather than queueing it, and the host calls one
method per event at the instant it arrives, because on Android the process blocks as soon as backgrounding has
been sent and the next iteration is after the resume.

The engine answers five of those: low memory triggers a full collection, backgrounding sets `suspended` and
flushes the checkpoint, entering the background waits for the device to go idle, returning to the foreground
lifts the suspension, and termination writes the checkpoint one last time.

Every one of them is also queued on the bus, so a game reads the transitions as ordinary events —
`tecs.events.on.lowMemory`, `tecs.events.on.appWillEnterForeground` and the rest. The hook is where the engine
meets a deadline the event stream cannot; a game reads the event. The one thing a game cannot do that way is save
state on being backgrounded, because there may be no later drain to do it in, and `stageCheckpoint` exists for
exactly that.

Releasing the graphics device on suspension is **not** done, and the gap is stated rather than half closed. Three
things would have to be true first: every GPU handle in the process would have to be reachable from one place to
be released and recreated, the image array would have to be refillable when the pixels behind it are released at
`Renderer:registerImage`, and it would have to be testable, which it is not while none of these events fires on
the platforms the suite runs on.
<!-- @generated by `cargo xtask docs-reference` from src/tecs/Application.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/Application.tl`.

<a id="tecs.Application.Config"></a>

### tecs.Application.Config

<pre><code v-pre>record <a href="#tecs.Application.Config">tecs.Application.Config</a>
</code></pre>

<a id="tecs.Application.Config.window"></a>

### tecs.Application.Config.window

<pre><code v-pre><a href="#tecs.Application.Config.window">tecs.Application.Config.window</a>: Window.Options
</code></pre>

The window to open, as `Window.Options` describes it. Passed
through whole rather than copied field by field, so everything a
window can be created with is reachable from here and a field
added there needs nothing added here.

<a id="tecs.Application.Config.debug"></a>

### tecs.Application.Config.debug

<pre><code v-pre><a href="#tecs.Application.Config.debug">tecs.Application.Config.debug</a>: boolean
</code></pre>

Marks this run as a development one, which two things read.

The device is created with its validation layers on, and the log
file below is written without being asked for. It is also one of
the three settings `clearCrash` looks at, beside `mcpPort` and
`watch`, to decide whether resuming after a gameplay crash is
something this build does at all.

<a id="tecs.Application.Config.framesInFlight"></a>

### tecs.Application.Config.framesInFlight

<pre><code v-pre><a href="#tecs.Application.Config.framesInFlight">tecs.Application.Config.framesInFlight</a>: integer
</code></pre>

<a id="tecs.Application.Config.presentMode"></a>

### tecs.Application.Config.presentMode

<pre><code v-pre><a href="#tecs.Application.Config.presentMode">tecs.Application.Config.presentMode</a>: string
</code></pre>

<a id="tecs.Application.Config.ambientLight"></a>

### tecs.Application.Config.ambientLight

<pre><code v-pre><a href="#tecs.Application.Config.ambientLight">tecs.Application.Config.ambientLight</a>: {number}
</code></pre>

Light every surface receives before any light entity contributes,
as red, green and blue. Defaults to white.

White rather than a dim gray, because a scene that has placed no
lights is the first thing anyone builds and it should look like
what it is: sprites at their own color, with lights adding on top
of them. A game doing its own lighting turns this down to the
level it wants the unlit parts of the scene to sit at.

<a id="tecs.Application.Config.audio"></a>

### tecs.Application.Config.audio

<pre><code v-pre><a href="#tecs.Application.Config.audio">tecs.Application.Config.audio</a>: Audio.Config
</code></pre>

Sound output. Omitted takes the defaults, which open the
platform's default device.

<a id="tecs.Application.Config.logFile"></a>

### tecs.Application.Config.logFile

<pre><code v-pre><a href="#tecs.Application.Config.logFile">tecs.Application.Config.logFile</a>: string
</code></pre>

Log file name, under the writable root, written as JSON Lines
beside the platform's own destination rather than instead of it.

Omitted, one is written when `mcpPort` or `debug` is set and not
otherwise. The file exists for the debug server, which is what
makes `get_logs` a seek and a read rather than a ring buffer kept
in the process, so it follows the thing that reads it: a game
should no more write a file nobody asked for than open a socket
nobody asked for. Nothing is lost by that, because SDL already
dispatches to a destination a human can read on every platform;
see `log`. A shipped game that wants a crash log in the field
names one here, since where a game writes user data is the game's
decision and not the engine's.

<a id="tecs.Application.Config.logLevel"></a>

### tecs.Application.Config.logLevel

<pre><code v-pre><a href="#tecs.Application.Config.logLevel">tecs.Application.Config.logLevel</a>: integer
</code></pre>

Lowest priority that reaches the log at all, as one of
`log.TRACE`, `log.VERBOSE`, `log.DEBUG`, `log.INFO`, `log.WARN`,
`log.ERROR` or `log.CRITICAL`. Omitted leaves SDL's own default.

Applies to every category, ours and SDL's, and it is set before
anything here has had a chance to say something. Separate from
`logFile` above, which decides durability rather than volume: a
game wanting everything kept and little of it shown sets both.

<a id="tecs.Application.Config.checkpoint"></a>

### tecs.Application.Config.checkpoint

<pre><code v-pre><a href="#tecs.Application.Config.checkpoint">tecs.Application.Config.checkpoint</a>: string
</code></pre>

File name, under the writable root, that a checkpoint is written
to when the platform backgrounds or terminates the application.
Omitted means no checkpoint, and `stageCheckpoint` says so.

See `Application:stageCheckpoint` for what a game has to do, which
is the part that matters.

<a id="tecs.Application.Config.mcpPort"></a>

### tecs.Application.Config.mcpPort

<pre><code v-pre><a href="#tecs.Application.Config.mcpPort">tecs.Application.Config.mcpPort</a>: integer
</code></pre>

Port for the MCP server. Omitted means no server, since a game
should not open a socket nobody asked for.

<a id="tecs.Application.Config.watch"></a>

### tecs.Application.Config.watch

<pre><code v-pre><a href="#tecs.Application.Config.watch">tecs.Application.Config.watch</a>: watch.Config
</code></pre>

Watches the content files this run has loaded and reloads them when
they change. Omitted means no watcher, on the same footing as the
server above: a poll of the filesystem is not something to start
because a build happened to be able to. A release refuses it.

<a id="tecs.Application.Config.capacity"></a>

### tecs.Application.Config.capacity

<pre><code v-pre><a href="#tecs.Application.Config.capacity">tecs.Application.Config.capacity</a>: integer
</code></pre>

Instances the renderer's buffers are sized for. Defaults to 65536.

An instance is a row the GPU draws: every renderable entity is one,
and so is every glyph of every text, since a glyph is an entity
like any other. This is a ceiling rather than a hint. Rows past it
are dropped rather than growing a buffer mid-frame, and
`renderer.dropped` counts them.

Sized independently of `maxEntities` beside it, because the two
count different things: a world full of entities that carry no
`Renderable` needs no instances at all, and one text entity needs
one instance per character.

<a id="tecs.Application.Config.timestep"></a>

### tecs.Application.Config.timestep

<pre><code v-pre><a href="#tecs.Application.Config.timestep">tecs.Application.Config.timestep</a>: number
</code></pre>

Seconds one fixed step covers. Must be greater than zero. Defaults
to 1/60.

<a id="tecs.Application.Config.fixedMaxSteps"></a>

### tecs.Application.Config.fixedMaxSteps

<pre><code v-pre><a href="#tecs.Application.Config.fixedMaxSteps">tecs.Application.Config.fixedMaxSteps</a>: integer
</code></pre>

The most fixed steps one update runs before the overload policy
applies. Must be a positive integer. Defaults to 10.

<a id="tecs.Application.Config.fixedOverload"></a>

### tecs.Application.Config.fixedOverload

<pre><code v-pre><a href="#tecs.Application.Config.fixedOverload">tecs.Application.Config.fixedOverload</a>: ecs.FixedOverload
</code></pre>

What becomes of the catch-up that did not fit. Defaults to "drop",
which bounds a frame's work and reports the loss through
`world:getStats`. "accumulate" keeps every second instead.

<a id="tecs.Application.Config.maxEntities"></a>

### tecs.Application.Config.maxEntities

<pre><code v-pre><a href="#tecs.Application.Config.maxEntities">tecs.Application.Config.maxEntities</a>: integer
</code></pre>

Entity slots the world is sized for. Defaults to 2^20, and 2^22 - 1
is the ceiling the packed id format allows.

Concurrent slots rather than lifetime spawns: a slot is given back
when the entity is despawned and reused by the next one. The arena
is preallocated for this many, so it is a memory decision as much
as a limit, and a game that knows its population sets it rather
than paying for a million slots it will not use.

<a id="tecs.Application.Config.reserveRuns"></a>

### tecs.Application.Config.reserveRuns

<pre><code v-pre><a href="#tecs.Application.Config.reserveRuns">tecs.Application.Config.reserveRuns</a>: boolean
</code></pre>

Give each archetype a run with room to grow rather than packing the
runs end to end. Defaults to false, which packs.

Packed, a run cannot grow without shifting every run after it, so a
spawn anywhere rewrites every instance in the scene. Reserved, it
grows into its own slack and the archetypes around it are left
alone. What it costs is that the cull is dispatched over the slack
as well as over the rows, and that reserving needs headroom: a
`capacity` sized to exactly the population leaves nothing to
reserve out of and the setting does nothing.

Worth it for a scene that spawns into one archetype while most of
the world sits in others, which is what a game with a level and
projectiles in it looks like. Worth nothing for a scene held in a
single archetype, where there is no other run to leave alone.

Not named for debugging, unlike `debugMaxFrames` below, because it
is not a debugging setting: it is a tuning one, measured at 15.4x
on a mixed-archetype spawner scene. A name with `debug` in it would
warn off exactly the shipped games that should turn it on.

<a id="tecs.Application.Config.packImages"></a>

### tecs.Application.Config.packImages

<pre><code v-pre><a href="#tecs.Application.Config.packImages">tecs.Application.Config.packImages</a>: boolean
</code></pre>

Fit many images into each layer of the renderer's image array
rather than one. Defaults to false, where the ceiling on distinct
images is the array's layer count and a small image costs a whole
cell. On, the ceiling is the array's area instead.

<a id="tecs.Application.Config.shadows"></a>

### tecs.Application.Config.shadows

<pre><code v-pre><a href="#tecs.Application.Config.shadows">tecs.Application.Config.shadows</a>: Deferred.ShadowOptions
</code></pre>

Let entities cast shadows, and tune what they cost. Nil, the
default, means an `Occluder` or a `DropShadow` on an entity draws
the entity and casts nothing, because the targets that would hold a
shadow are never built. An empty table turns them on with every
default; see `Deferred.ShadowOptions` for the seven numbers.

<a id="tecs.Application.Config.debugMaxFrames"></a>

### tecs.Application.Config.debugMaxFrames

<pre><code v-pre><a href="#tecs.Application.Config.debugMaxFrames">tecs.Application.Config.debugMaxFrames</a>: integer
</code></pre>

Stops after this many iterations. Lets an automated run drive a
real window to completion without a human closing it.

<a id="tecs.Application.Config.plugin"></a>

### tecs.Application.Config.plugin

<pre><code v-pre>function <a href="#tecs.Application.Config.plugin">tecs.Application.Config.plugin</a>(types.World, Application)
</code></pre>

The game, as one function handed the world and this application.

Called at the end of initialization, after every engine subsystem is
installed and before the startup phases run, so it can register a
`Startup` system and have it run this initialization rather than the
next one.

One entry point rather than a list, because composing plugins is
something the world already does: `world:addPlugin` takes an
`tecs.Plugin` and is how the engine installs its own, so a game with
several calls it from in here and needs no second mechanism.

The world comes first because every plugin the world takes is
`function(world)`, so this reads as that shape with one more thing
and code moves between here and a delegated plugin without a silent
argument swap.

#### Parameters

| Type                           | Name | Description |
| ------------------------------ | ---- | ----------- |
| <code v-pre>types.World</code> |      |             |
| <code v-pre>Application</code> |      |             |

<a id="tecs.Application.audio"></a>

### tecs.Application.audio

<pre><code v-pre><a href="#tecs.Application.audio">tecs.Application.audio</a>: Audio
</code></pre>

<a id="tecs.Application.checkpointPath"></a>

### tecs.Application.checkpointPath

<pre><code v-pre>function <a href="#tecs.Application.checkpointPath">tecs.Application.checkpointPath</a>(self: Application): string
</code></pre>

Where the checkpoint is written, or nil when none was configured.

#### Parameters

| Type                           | Name                    | Description |
| ------------------------------ | ----------------------- | ----------- |
| <code v-pre>Application</code> | <code v-pre>self</code> |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>string</code> |             |

<a id="tecs.Application.clearCrash"></a>

### tecs.Application.clearCrash

<pre><code v-pre>function <a href="#tecs.Application.clearCrash">tecs.Application.clearCrash</a>(self: Application): boolean, string
</code></pre>

Another frame to look at and a chance to reload; the world may be
inconsistent, reload before trusting it.

That sentence is the whole contract, and the name is deliberately not
`recover` or `retry`: this is a debugging affordance, not fault tolerance.
What the guard put back are the engine's invariants, which are the ones it
can name: the command buffer is resolved, the passes are ended, the world
is applying mutations again. A game's invariants are not restored and
cannot be, because a system that threw halfway through its query left some
entities updated and some not, and nothing here knows which half or what
either half meant. So the frame after this is a frame to read, and the way
to get back to a world worth trusting is to reload the scene.

Two gates, and they are different kinds of thing.

The first is whether this build is a development one at all, which is
`debug`, `mcpPort` or `watch` in the config. A watcher counts because it is
the configuration that most wants this: a game running one is being edited,
and reloading the file that threw is exactly the way back. A shipped build
has none of the three, latches on the first crash and stays latched, which
is the right shipped behavior:
there is nobody there to read the frame, and carrying on with a world that
is provably inconsistent is how one bug becomes a corrupted save.

The second is severity, and it is narrower rather than a judgment about
how bad the throw looked. Recovery reports whether it had to force-end a
pass or cancel a frame instead of submitting it, and in either case the
device is not in the state the engine intended; see `_recover`. Those do
not resume, at any setting, because the next frame would be recorded
against a device nobody can describe.

The callers are the debug server's `clear_crash` tool and the file
watcher's reloads. Both mean the same thing: something about the run has
changed, try it again.

Physics resumability is a separate and open question: a solver stepped out
of is not obviously a solver that can be stepped again.

#### Parameters

| Type                           | Name                    | Description |
| ------------------------------ | ----------------------- | ----------- |
| <code v-pre>Application</code> | <code v-pre>self</code> |             |

#### Returns

| Type                       | Description                                   |
| -------------------------- | --------------------------------------------- |
| <code v-pre>boolean</code> | Whether the loop resumed, and why it did not. |
| <code v-pre>string</code>  |                                               |

<a id="tecs.Application.crashed"></a>

### tecs.Application.crashed

<pre><code v-pre>function <a href="#tecs.Application.crashed">tecs.Application.crashed</a>(self: Application): string
</code></pre>

The gameplay traceback, or nil while the game is healthy.

#### Parameters

| Type                           | Name                    | Description |
| ------------------------------ | ----------------------- | ----------- |
| <code v-pre>Application</code> | <code v-pre>self</code> |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>string</code> |             |

<a id="tecs.Application.device"></a>

### tecs.Application.device

<pre><code v-pre><a href="#tecs.Application.device">tecs.Application.device</a>: Device
</code></pre>

<a id="tecs.Application.elapsed"></a>

### tecs.Application.elapsed

<pre><code v-pre><a href="#tecs.Application.elapsed">tecs.Application.elapsed</a>: number
</code></pre>

Seconds of simulated time, advanced by the frame dt so a replay
reproduces it exactly.

<a id="tecs.Application.frame"></a>

### tecs.Application.frame

<pre><code v-pre><a href="#tecs.Application.frame">tecs.Application.frame</a>: integer
</code></pre>

Iterations completed.

<a id="tecs.Application.input"></a>

### tecs.Application.input

<pre><code v-pre><a href="#tecs.Application.input">tecs.Application.input</a>: Input
</code></pre>

<a id="tecs.Application.mcp"></a>

### tecs.Application.mcp

<pre><code v-pre><a href="#tecs.Application.mcp">tecs.Application.mcp</a>: mcp.Server
</code></pre>

The debug server, when one was asked for.

<a id="tecs.Application.newApplication"></a>

### tecs.Application.newApplication

<pre><code v-pre>function <a href="#tecs.Application.newApplication">tecs.Application.newApplication</a>(config: Application.Config): Application
</code></pre>

Builds an application. Return the result from the entry chunk.

Reached as `tecs.newApplication`, at the root rather than under a module,
because an application is not a subsystem: it owns the window, the device,
the input, the renderer and the audio, and is handed to the entry plugin
beside the world.

#### Parameters

| Type                                  | Name                      | Description                                                                               |
| ------------------------------------- | ------------------------- | ----------------------------------------------------------------------------------------- |
| <code v-pre>Application.Config</code> | <code v-pre>config</code> | Read here, so a field changed on the table afterwards is not seen. Nothing is opened yet. |

#### Returns

| Type                           | Description                                               |
| ------------------------------ | --------------------------------------------------------- |
| <code v-pre>Application</code> | The application, at rest until the host's first callback. |

<a id="tecs.Application.quitRequested"></a>

### tecs.Application.quitRequested

<pre><code v-pre><a href="#tecs.Application.quitRequested">tecs.Application.quitRequested</a>: boolean
</code></pre>

Set to true to leave the loop at the end of the current iteration.

<a id="tecs.Application.readCheckpoint"></a>

### tecs.Application.readCheckpoint

<pre><code v-pre>function <a href="#tecs.Application.readCheckpoint">tecs.Application.readCheckpoint</a>(self: Application): string
</code></pre>

The bytes the last run left, or nil when there are none.

Read it while building the world, which is what the plugin and the startup
phases are for. Nil covers every reason there is nothing to resume from: a
first run, a game that never staged anything, a file the player deleted.
None of those is an error, so none of them raises.

#### Parameters

| Type                           | Name                    | Description |
| ------------------------------ | ----------------------- | ----------- |
| <code v-pre>Application</code> | <code v-pre>self</code> |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| <code v-pre>string</code> |             |

<a id="tecs.Application.renderer"></a>

### tecs.Application.renderer

<pre><code v-pre><a href="#tecs.Application.renderer">tecs.Application.renderer</a>: Renderer
</code></pre>

<a id="tecs.Application.stageCheckpoint"></a>

### tecs.Application.stageCheckpoint

<pre><code v-pre>function <a href="#tecs.Application.stageCheckpoint">tecs.Application.stageCheckpoint</a>(self: Application, bytes: string)
</code></pre>

Hands the engine the bytes to write when the platform backgrounds us.

Call this from an ordinary system, on an ordinary frame, whenever the state
worth keeping has changed. Nothing is written here; the bytes are held, and
`_willEnterBackground` writes them at the one moment the platform gives.

What this takes is bytes rather than a function that produces them, and
that is the whole design rather than an inconvenience. iOS allows roughly
five seconds from the backgrounding callback returning and Android rather
less, and at this project's scale a world is not serializable inside any of
it: a callback that walked four million entities would be killed part way
through and leave nothing behind. A function would let a game postpone the
serializing into exactly that callback while looking like it had prepared
something. A string cannot: by the time it exists, the expensive half has
already happened on a frame that could afford it. The host times the hook
and says so past 250 ms, which is the check on the rest.

Staging again replaces what was staged; there is one checkpoint, not a
queue. Staging and then backgrounding twice writes once, because a write
nothing has changed since is a second chance to be interrupted for nothing.

The counterpart is `readCheckpoint`, which is how the next run gets it back.
Raises when no `checkpoint` was configured, because silently holding bytes
that will never be written is the one failure a game would not notice.

#### Parameters

| Type                           | Name                     | Description |
| ------------------------------ | ------------------------ | ----------- |
| <code v-pre>Application</code> | <code v-pre>self</code>  |             |
| <code v-pre>string</code>      | <code v-pre>bytes</code> |             |

<a id="tecs.Application.suspended"></a>

### tecs.Application.suspended

<pre><code v-pre><a href="#tecs.Application.suspended">tecs.Application.suspended</a>: boolean
</code></pre>

True while the platform has the application in the background. The
loop still runs, but simulation and rendering do not.

<a id="tecs.Application.window"></a>

### tecs.Application.window

<pre><code v-pre><a href="#tecs.Application.window">tecs.Application.window</a>: Window
</code></pre>

<a id="tecs.Application.world"></a>

### tecs.Application.world

<pre><code v-pre><a href="#tecs.Application.world">tecs.Application.world</a>: types.World
</code></pre>
