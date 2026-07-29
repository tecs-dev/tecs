---
url: /modules/application.md
description: >-
  The application object an entry file returns and the host drives: its config,
  what it owns, and the frame
---

# tecs.application.Application

`tecs.application.Application` is the lifecycle the C host drives. An entry file ends with `return tecs.application.create(config)`,
and the host calls into the returned object to initialise, for each event, for each iteration, and to shut down.

It is not a function that runs until done. A platform that never hands control back has no loop to block in, so
the loop lives below Lua and the application is what it calls.

```teal
local tecs <const> = require("tecs")

return tecs.application.create({
    window = { title = "Hello", width = 1280, height = 960 },
    plugin = function(world: tecs.World, app: tecs.application.Application)
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

* **Startup** — `PreStartup`, `Startup`, `PostStartup`, run once at the end of initialisation.
* **Per frame** — the ordinary phases, run by `world:update`.
* **Per event** — `world:observe(0, tecs.events.on.<kind>, handler)`.
* **Teardown** — `PreShutdown`, `Shutdown`, `PostShutdown`, run once before anything is destroyed.

One entry point rather than a list, because composing plugins is something the world already does:
`world:addPlugin` takes an [`ecs.Plugin`](/ecs/plugins) and is how the engine installs its own, so a game with
several calls it from in here and needs no second mechanism.

The world comes first in the signature because every plugin the world takes is `function(world)`, so this reads
as that shape with one more thing, and code moves between here and a delegated plugin without a silent argument
swap.

The plugin runs at the end of initialisation, after every engine subsystem is installed and before the startup
phases run, so a `Startup` system it registers runs on this initialisation rather than the next one.

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

`ambientLight` defaults to white rather than a dim grey because a scene that has placed no lights is the first
thing anyone builds, and it should look like what it is: sprites at their own colour, with lights adding on top.
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

* `app.window` — [`Window`](/modules/window)
* `app.device` — the GPU device
* `app.world` — the [world](/ecs/world)
* `app.renderer` — [`Renderer`](/modules/gfx/)
* `app.input` — [`Input`](/modules/input)
* `app.audio` — [`Audio`](/modules/audio)
* `app.mcp` — the debug server, when `mcpPort` asked for one

The application is handed to the plugin rather than looked up, so there is no `Application.of` and no
`Renderer.of` to call: a system that needs either captures it from here when the plugin registers the
system, and what it captures cannot be nil. [`tecs.audio.Audio.of`](/modules/audio#of) is the one accessor
of that kind that exists, because the debug tools reach the mixer holding only a world.

And four values it keeps about the run:

* `app.quitRequested` — set it to `true` to leave the loop at the end of the current iteration
* `app.suspended` — true while the platform has the application backgrounded. The loop still runs; simulation and
  rendering do not
* `app.elapsed` — seconds of **simulated** time, advanced by the frame dt, so a replay reproduces it exactly and a
  crashed run does not fold the length of the fix into it
* `app.frame` — iterations completed

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
A world is not serialisable inside any of that at this project's scale, so this takes bytes rather than a
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

* `app:crashed()` — the gameplay traceback, or nil while the game is healthy.
* `app:clearCrash()` — returns whether the loop resumed, and why it did not.

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

* **This build is not a development one.** With none of `debug`, `mcpPort` or `watch` set, the first crash
  latches and stays latched. That is the right shipped behaviour: there is nobody there to read the frame, and
  carrying on with a world that is provably inconsistent is how one bug becomes a corrupted save.
* **Recovery was not clean.** If a pass had to be force-ended or a frame cancelled rather than submitted, the
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

## Reference

Every function and type this module carries, rendered from `src/tecs/Application.tl`.

### tecs.application.Application.Config

### tecs.application.Application.Config.window

The window to open, as `Window.Options` describes it. Passed
through whole rather than copied field by field, so everything a
window can be created with is reachable from here and a field
added there needs nothing added here.


### tecs.application.Application.Config.debug

Marks this run as a development one, which two things read.

The device is created with its validation layers on, and the log
file below is written without being asked for. It is also one of
the three settings `clearCrash` looks at, beside `mcpPort` and
`watch`, to decide whether resuming after a gameplay crash is
something this build does at all.


### tecs.application.Application.Config.framesInFlight

### tecs.application.Application.Config.presentMode

### tecs.application.Application.Config.ambientLight

Light every surface receives before any light entity contributes,
as red, green and blue. Defaults to white.

White rather than a dim grey, because a scene that has placed no
lights is the first thing anyone builds and it should look like
what it is: sprites at their own colour, with lights adding on top
of them. A game doing its own lighting turns this down to the
level it wants the unlit parts of the scene to sit at.


### tecs.application.Application.Config.audio

Sound output. Omitted takes the defaults, which open the
platform's default device.


### tecs.application.Application.Config.logFile

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


### tecs.application.Application.Config.logLevel

Lowest priority that reaches the log at all, as one of
`log.TRACE`, `log.VERBOSE`, `log.DEBUG`, `log.INFO`, `log.WARN`,
`log.ERROR` or `log.CRITICAL`. Omitted leaves SDL's own default.

Applies to every category, ours and SDL's, and it is set before
anything here has had a chance to say something. Separate from
`logFile` above, which decides durability rather than volume: a
game wanting everything kept and little of it shown sets both.


### tecs.application.Application.Config.checkpoint

File name, under the writable root, that a checkpoint is written
to when the platform backgrounds or terminates the application.
Omitted means no checkpoint, and `stageCheckpoint` says so.

See `Application:stageCheckpoint` for what a game has to do, which
is the part that matters.


### tecs.application.Application.Config.mcpPort

Port for the MCP server. Omitted means no server, since a game
should not open a socket nobody asked for.


### tecs.application.Application.Config.watch

Watches the content files this run has loaded and reloads them when
they change. Omitted means no watcher, on the same footing as the
server above: a poll of the filesystem is not something to start
because a build happened to be able to. A release refuses it.


### tecs.application.Application.Config.capacity

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


### tecs.application.Application.Config.timestep

Seconds one fixed step covers. Must be greater than zero. Defaults
to 1/60.


### tecs.application.Application.Config.fixedMaxSteps

The most fixed steps one update runs before the overload policy
applies. Must be a positive integer. Defaults to 10.


### tecs.application.Application.Config.fixedOverload

What becomes of the catch-up that did not fit. Defaults to "drop",
which bounds a frame's work and reports the loss through
`world:getStats`. "accumulate" keeps every second instead.


### tecs.application.Application.Config.maxEntities

Entity slots the world is sized for. Defaults to 2^20, and 2^22 - 1
is the ceiling the packed id format allows.

Concurrent slots rather than lifetime spawns: a slot is given back
when the entity is despawned and reused by the next one. The arena
is preallocated for this many, so it is a memory decision as much
as a limit, and a game that knows its population sets it rather
than paying for a million slots it will not use.


### tecs.application.Application.Config.reserveRuns

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


### tecs.application.Application.Config.packImages

Fit many images into each layer of the renderer's image array
rather than one. Defaults to false, where the ceiling on distinct
images is the array's layer count and a small image costs a whole
cell. On, the ceiling is the array's area instead.


### tecs.application.Application.Config.shadows

Let entities cast shadows, and tune what they cost. Nil, the
default, means an `Occluder` or a `DropShadow` on an entity draws
the entity and casts nothing, because the targets that would hold a
shadow are never built. An empty table turns them on with every
default; see `Deferred.ShadowOptions` for the seven numbers.


### tecs.application.Application.Config.debugMaxFrames

Stops after this many iterations. Lets an automated run drive a
real window to completion without a human closing it.


### tecs.application.Application.Config.plugin

The game, as one function handed the world and this application.

Called at the end of initialisation, after every engine subsystem is
installed and before the startup phases run, so it can register a
`Startup` system and have it run this initialisation rather than the
next one.

One entry point rather than a list, because composing plugins is
something the world already does: `world:addPlugin` takes an
`ecs.Plugin` and is how the engine installs its own, so a game with
several calls it from in here and needs no second mechanism.

The world comes first because every plugin the world takes is
`function(world)`, so this reads as that shape with one more thing
and code moves between here and a delegated plugin without a silent
argument swap.

#### Parameters

| Type                           | Name | Description |
| ------------------------------ | ---- | ----------- |
| ecs.World   |      |             |
| Application |      |             |

### tecs.application.Application.audio

### tecs.application.Application.checkpointPath

Where the checkpoint is written, or nil when none was configured.

#### Parameters

| Type                           | Name                    | Description |
| ------------------------------ | ----------------------- | ----------- |
| Application | self |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| string |             |

### tecs.application.Application.clearCrash

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
is the right shipped behaviour:
there is nobody there to read the frame, and carrying on with a world that
is provably inconsistent is how one bug becomes a corrupted save.

The second is severity, and it is narrower rather than a judgement about
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
| Application | self |             |

#### Returns

| Type                       | Description                                   |
| -------------------------- | --------------------------------------------- |
| boolean | Whether the loop resumed, and why it did not. |
| string  |                                               |

### tecs.application.Application.crashed

The gameplay traceback, or nil while the game is healthy.

#### Parameters

| Type                           | Name                    | Description |
| ------------------------------ | ----------------------- | ----------- |
| Application | self |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| string |             |

### tecs.application.Application.create

Builds an application. Return the result from the entry chunk.

#### Parameters

| Type                                  | Name                      | Description |
| ------------------------------------- | ------------------------- | ----------- |
| Application.Config | config |             |

#### Returns

| Type                           | Description |
| ------------------------------ | ----------- |
| Application |             |

### tecs.application.Application.device

### tecs.application.Application.elapsed

Seconds of simulated time, advanced by the frame dt so a replay
reproduces it exactly.


### tecs.application.Application.frame

Iterations completed.


### tecs.application.Application.input

### tecs.application.Application.mcp

The debug server, when one was asked for.


### tecs.application.Application.quitRequested

Set to true to leave the loop at the end of the current iteration.


### tecs.application.Application.readCheckpoint

The bytes the last run left, or nil when there are none.

Read it while building the world, which is what the plugin and the startup
phases are for. Nil covers every reason there is nothing to resume from: a
first run, a game that never staged anything, a file the player deleted.
None of those is an error, so none of them raises.

#### Parameters

| Type                           | Name                    | Description |
| ------------------------------ | ----------------------- | ----------- |
| Application | self |             |

#### Returns

| Type                      | Description |
| ------------------------- | ----------- |
| string |             |

### tecs.application.Application.renderer

### tecs.application.Application.stageCheckpoint

Hands the engine the bytes to write when the platform backgrounds us.

Call this from an ordinary system, on an ordinary frame, whenever the state
worth keeping has changed. Nothing is written here; the bytes are held, and
`_willEnterBackground` writes them at the one moment the platform gives.

What this takes is bytes rather than a function that produces them, and
that is the whole design rather than an inconvenience. iOS allows roughly
five seconds from the backgrounding callback returning and Android rather
less, and at this project's scale a world is not serialisable inside any of
it: a callback that walked four million entities would be killed part way
through and leave nothing behind. A function would let a game postpone the
serialising into exactly that callback while looking like it had prepared
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
| Application | self  |             |
| string      | bytes |             |

### tecs.application.Application.suspended

True while the platform has the application in the background. The
loop still runs, but simulation and rendering do not.


### tecs.application.Application.window

### tecs.application.Application.world
