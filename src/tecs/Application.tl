--[=[
The application that an entry chunk returns.

The host owns the loop and calls the application to initialize, process
events, iterate, and shut down. Game code registers systems and observers
instead of calling a blocking `run` function:

```teal
return tecs.newApplication({
    window = {
        title = "Game",
        width = 1280,
        height = 720,
    },
    plugin = function(world: tecs.World, app: tecs.Application)
        local transforms <const> = world:newQuery({
            include = {tecs.Transform},
        })

        world:addSystem({
            name = "game.Move",
            phase = tecs.ecs.phases.Update,
            run = function(dt: number)
                for archetype, length in transforms:iter() do
                    local column <const> =
                        archetype:getMut(tecs.Transform)
                    for row = 1, length do
                        column[row].x = column[row].x + 120 * dt
                    end
                end
            end,
        })

        world:spawn(tecs.Transform(100, 100))
    end,
})
```

## Lifecycle

The entry plugin receives the world and application after engine subsystem
installation and before startup phases. It registers the game. The world then
owns the scheduled lifecycle:

| Stage | Game API |
| --- | --- |
| Startup | `PreStartup`, `Startup`, and `PostStartup` |
| Event | `world:observe(0, tecs.platform.events.on.<kind>, handler)` |
| Frame | The phases driven by `world:update(dt)` |
| Shutdown | `PreShutdown`, `Shutdown`, and `PostShutdown` |

Every iteration runs the same eight steps in the same order, and the order is
the contract: a system reads what the steps above it settled during this frame
rather than one frame later.

1. The application starts the input frame and drains every platform event SDL
   delivered since the previous iteration. A quit request ends the iteration
   here.
2. `tecs.assets.update` settles the loads the worker finished.
3. `tecs.platform.os.updateProcesses` and `tecs.platform.os.updateDialogs` settle the
   children that exited and the dialogs the user answered.
4. `tecs.io.poll` advances asynchronous I/O sources, including address
   resolution and client connection.
5. The application pumps every open `tecs.io.http` client, which settles the
   transfers that completed.
6. `tecs.io.watcher` polls, which reloads content whose file changed.
7. The debug server answers, `world:update(dt)` runs the phases, and the
   renderer records and submits one frame.
8. The audio mixer updates, which reaps the voices it has finished with.

Steps 2 through 6 and step 8 run whatever else is true of the process. A decode
that finished, a child that exited, a transfer that completed and a file that
changed have all already happened, and a voice the mixer is done with has to be
reaped either way, so a suspended run and a crashed one keep settling them.
Step 7 is the one the guards hold back. A suspended application skips all of
it, and a crashed one skips the world update and the rendering while still
answering the debug server, so an agent that was watching gets the traceback.

Event observers run inside step 1, before the world update and outside every
phase. They see input state after the application folds the event in. Store
event state in a component or a resource when a scheduled system has to react
to it.

## Checkpoints and crashes

Mobile platforms may suspend a process before another frame runs. Prepare a
snapshot during an ordinary frame and stage its bytes before that deadline:

```teal
local save <const> = world:saveSnapshot().buffer
app:stageCheckpoint(tostring(save))
```

The application writes the latest staged bytes when the platform backgrounds
or terminates it. The next entry plugin can call `readCheckpoint` and load the
result.

The application catches errors from game systems, observers, plugins, and
startup phases. It records the first traceback while the host continues to
serve platform events and the debug connection. The guard restores
engine-owned scopes, not partially changed game state. Use `clearCrash` only
as a development reload aid.

Methods whose names begin with an underscore belong to the host contract.
]=]

-- Implementation details:
-- SDL drives the host through SDL_AppInit, SDL_AppEvent, SDL_AppIterate, and
-- SDL_AppQuit. The Rust host forwards those callbacks to the underscore
-- methods on Application.

local data <const> = require("tecs.data")
local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local time <const> = require("tecs.platform.time")
local events <const> = require("tecs.platform.events")
local input <const> = require("tecs.platform.input")
local type Input = input.Input
local window <const> = require("tecs.platform.window")
local type Window = window.Window
local Device <const> = require("tecs.gpu.Device")
local Frame <const> = require("tecs.gpu.Frame")
local passscope <const> = require("tecs.gpu.passscope")
local Renderer <const> = require("tecs.Renderer")
local type Deferred = require("tecs.gpu.Deferred")
local audio <const> = require("tecs.audio")
local type Audio = audio.Audio
local assets <const> = require("tecs.assets")
local sequence <const> = require("tecs.sequence")
local tecsIO <const> = require("tecs.io")
local files <const> = require("tecs.io.files")
local platformOS <const> = require("tecs.platform.os")

-- Host-only event conversion operations. The public events record omits these
-- engine-facing helpers, while the implementation table retains them for the
-- application lifecycle.
local record EventHost
    drain: function(queue: loader.CValue, count: integer, handler: function(events.Event), arrivals?: loader.CValue)
    isInput: function(kind: string): boolean
    setTouchScale: function(width: number, height: number)
end

local eventHost <const> = events as EventHost
local httpClients <const> = require("tecs.io.http.clients")
local watcher <const> = require("tecs.io.watcher")
local log <const> = require("tecs.log")
local mcp <const> = require("tecs.io.mcp")
local timing <const> = require("tecs.timing")

local LOGGER <const> = log.get("tecs.app")
local shaderpack <const> = require("tecs.gpu.shaderpack")
local shadercompiler <const> = require("tecs.gpu.shadercompiler")

local C <const> = sdl.C
local K <const> = sdl.K

-- The stages of a frame, named once. Extraction is registered by the renderer,
-- since that is where it happens.
local FRAME <const> = timing.stage("frame")
local SIMULATE <const> = timing.stage("simulate")
local ACQUIRE <const> = timing.stage("acquire")
local RECORD <const> = timing.stage("record")
local SUBMIT <const> = timing.stage("submit")

local record Application
    --- Configures the world owned by an application.
    type EntryPlugin = function(world: types.World, app: Application)

    record Config
        --- Caller-writable. Sets the window to open, as
        --- [`Options`](tealdoc:tecs.platform.window.Options) describes it. The
        --- application passes the table through whole.
        window: Window.Options
        --- Caller-writable. Marks this run as a development run.
        ---
        --- Tecs creates the device with validation layers enabled and writes
        --- the log file below by default. This setting also joins
        --- the three settings `clearCrash` looks at, beside `mcpPort` and
        --- `watch`, to decide whether resuming after a gameplay crash is
        --- something this build does at all.
        debug: boolean
        --- Caller-writable. Sets how many frames the CPU may run ahead of the
        --- GPU. The device defaults to two.
        framesInFlight: integer
        --- Caller-writable. Selects `"vsync"`, `"immediate"` or `"mailbox"`
        --- presentation. The device defaults to `"vsync"`.
        presentMode: string
        --- Caller-writable. Sets the light every surface receives before any
        --- light entity contributes,
        --- as red, green and blue. Defaults to white.
        ---
        --- White rather than a dim gray, because a scene that has placed no
        --- lights is the first thing anyone builds and it should look like
        --- what it is: sprites at their own color, with lights adding on top
        --- of them. A game doing its own lighting turns this down to the
        --- level it wants the unlit parts of the scene to sit at.
        ambientLight: {number}
        --- Caller-writable. Configures sound output. Omitted takes the defaults, which open the
        --- platform's default device.
        audio: Audio.Config
        --- Caller-writable. Sets a JSON Lines log file under the writable root.
        --- Omitted creates one when `mcpPort` or `debug` is set and otherwise
        --- keeps logging at the platform destination.
        logFile: string
        --- Caller-writable. Sets the lowest priority that reaches the log, as one of
        --- `log.TRACE`, `log.VERBOSE`, `log.DEBUG`, `log.INFO`, `log.WARN`,
        --- `log.ERROR` or `log.CRITICAL`. Omitted leaves the platform default.
        --- The level applies to every category and does not change whether
        --- `logFile` stores the accepted messages.
        logLevel: integer
        --- Caller-writable. Sets the file name under the writable root that
        --- receives a checkpoint when the platform backgrounds or terminates
        --- the application.
        --- Omitted means no checkpoint, and `stageCheckpoint` says so.
        ---
        --- See `Application:stageCheckpoint` for what a game has to do, which
        --- is the part that matters.
        checkpoint: string
        --- Caller-writable. Sets the MCP server port. Omitted means no server, since a game
        --- should not open a socket nobody asked for.
        mcpPort: integer
        --- Caller-writable. Watches loaded content files and reloads them when
        --- they change. Omitted means no watcher, on the same footing as the
        --- server above: a poll of the filesystem is not something to start
        --- because a build happened to be able to. A release refuses it.
        watch: watcher.Config
        --- Caller-writable. Sets the renderer buffer capacity in instances.
        --- Defaults to 65536.
        ---
        --- An instance is a row the GPU draws: every renderable entity is one,
        --- and so is every glyph of every text, which an instance producer
        --- writes into a run of its own rather than spawning an entity per
        --- glyph. This is a ceiling rather than a hint. Rows past it are
        --- dropped rather than growing a buffer mid-frame, and
        --- `renderer.dropped` counts them.
        ---
        --- Sized independently of `maxEntities` beside it, because the two
        --- count different things: a world full of entities that carry no
        --- [`Renderable`](tealdoc:tecs.components.Renderable) needs no instances at all,
        --- and one text entity needs
        --- one instance per character.
        capacity: integer
        --- Caller-writable. Sets the seconds one fixed step covers. Must be greater than zero. Defaults
        --- to 1/60.
        timestep: number
        --- Caller-writable. Sets the most fixed steps one update runs before the overload policy
        --- applies. Must be a positive integer. Defaults to 10.
        fixedMaxSteps: integer
        --- Caller-writable. Selects what becomes of catch-up that did not fit. Defaults to "drop",
        --- which bounds a frame's work and reports the loss through
        --- `world:getStats`. "accumulate" keeps every second instead.
        fixedOverload: ecs.FixedOverload
        --- Caller-writable. Sets the world's entity slot capacity. Defaults to 2^20, and 2^22 - 1
        --- is the ceiling the packed id format allows.
        ---
        --- Concurrent slots rather than lifetime spawns: a slot is given back
        --- when the world despawns the entity, then the next entity reuses it.
        --- The world preallocates this many slots, so it is a memory decision as much
        --- as a limit, and a game that knows its population sets it rather
        --- than paying for a million slots it will not use.
        maxEntities: integer
        --- Caller-writable. Gives each archetype a run with room to grow rather than packing the
        --- runs end to end. Defaults to false, which packs.
        ---
        --- Packed, a run cannot grow without shifting every run after it, so a
        --- spawn anywhere rewrites every instance in the scene. Reserved, it
        --- grows into its own slack and the archetypes around it are left
        --- alone. The cull also dispatches over the slack
        --- as well as over the rows, and that reserving needs headroom: a
        --- `capacity` sized to exactly the population leaves nothing to
        --- reserve out of and the setting does nothing.
        ---
        --- Worth it for a scene that spawns into one archetype while most of
        --- the world sits in others, which is what a game with a level and
        --- projectiles in it looks like. Worth nothing for a scene held in a
        --- single archetype, where there is no other run to leave alone.
        ---
        --- Not named for debugging, unlike `debugMaxFrames` below, because it
        --- is not a debugging setting: it is a tuning one, measured at 15.4x
        --- on a mixed-archetype spawner scene. A name with `debug` in it would
        --- warn off exactly the shipped games that should turn it on.
        reserveRuns: boolean
        --- Caller-writable. Rewrites the rows a spawn or a despawn wrote rather than the
        --- archetype's whole run. Defaults to false, which rewrites the run.
        ---
        --- A row moving into an archetype has every column newly written at
        --- that row, so a structural change dirties every column of the
        --- archetype it lands on and the run is resynced whole. The rest of
        --- the run did not change, and the ECS records which rows did, so this
        --- makes one spawn cost the rows it wrote rather than the archetype's
        --- population. It composes with `reserveRuns` above rather than
        --- replacing it: reserving keeps a spawn from moving the archetypes
        --- around it, and this keeps it from rewriting the one it landed in.
        ---
        --- Two things are deliberately left out of it. A value write through
        --- `archetype:getMut` names a column and not a
        --- row, so it still rewrites the run; that includes a
        --- `batchSpawn` fill callback, which declares intent on the whole
        --- column it writes new rows into. And an archetype carrying
        --- [`PreviousTransform`](tealdoc:tecs.components.PreviousTransform) is
        --- interpolated, so its drawn positions move on every frame that falls
        --- at a new point in the fixed step whatever the world did.
        partialRewrites: boolean
        --- Caller-writable. Fits many images into each layer of the renderer's image array
        --- rather than one. Defaults to false, where the ceiling on distinct
        --- images is the array's layer count and a small image costs a whole
        --- cell. On, the ceiling is the array's area instead.
        packImages: boolean
        --- Caller-writable. Enables entity shadows and configures their cost. Nil, the
        --- default, means an [`Occluder`](tealdoc:tecs.components.Occluder) or a
        --- [`DropShadow`](tealdoc:tecs.components.DropShadow) on an entity draws
        --- the entity and casts nothing, because the targets that would hold a
        --- shadow are never built. An empty table turns them on with every
        --- default; see `Deferred.ShadowOptions` for the seven numbers.
        shadows: Deferred.ShadowOptions
        --- Caller-writable. Stops after this many iterations. This lets an automated run drive a
        --- real window to completion without a human closing it.
        debugMaxFrames: integer

        --- Caller-writable. Sets the game plugin that receives the world and
        --- this application.
        ---
        --- Called at the end of initialization, after every engine subsystem is
        --- installed and before the startup phases run, so it can register a
        --- `Startup` system and have it run this initialization rather than the
        --- next one.
        ---
        --- One entry point rather than a list, because composing plugins is
        --- something the world already does: `world:addPlugin` takes an
        --- `tecs.Plugin` and is how the engine installs its own, so a game with
        --- several calls it from in here and needs no second mechanism.
        ---
        --- The world comes first because every plugin the world takes is
        --- `function(world)`, so this reads as that shape with one more thing
        --- and code moves between here and a delegated plugin without a silent
        --- argument swap.
        plugin: EntryPlugin
    end

    --- Read-only. Exposes the application window.
    window: Window
    --- Read-only. Exposes the GPU device.
    device: Device
    --- Read-only. Exposes the world driven by this application.
    world: types.World
    --- Read-only. Exposes the renderer that extracts this world.
    renderer: Renderer
    --- Read-only. Exposes current input state.
    input: Input
    --- Read-only. Exposes the audio mixer.
    audio: Audio
    --- Read-only. Exposes the debug server when configuration requested one.
    mcp: mcp.Server

    --- Caller-writable. Set to true to leave the loop at the end of the
    --- current iteration.
    quitRequested: boolean
    --- Engine-owned. Reports true while the platform has the application in
    --- the background. The loop still runs, but simulation and rendering do
    --- not.
    suspended: boolean
    --- Engine-owned. Reports seconds of simulated time. The frame delta
    --- advances it so a replay reproduces the value exactly.
    elapsed: number
    --- Engine-owned. Reports completed application iterations.
    frame: integer

    -- Declared here because `_init` wires the debug server and the file
    -- watcher to it before it is defined.

    --- Clears a recoverable gameplay crash so development can render another
    --- frame. Reload the world before trusting it.
    ---
    --- The method works only when `debug`, `mcpPort` or `watch` marks the run
    --- for development. It refuses to continue after incomplete graphics
    --- recovery.
    ---
    --- @return Returns whether the loop resumed.
    --- @return Returns the reason when the loop could not resume.
    clearCrash: function(self: Application): boolean, string

    _config: Application.Config
    _simulate: function(self: Application, dt: number)
    _recover: function(self: Application)
    _receive: function(self: Application, event: events.Event)
    --- The frame this iteration acquired, held so that recovery can resolve one
    --- the throw left open. It survives into the next iteration and is
    --- harmless there: a frame that submitted or canceled is already
    --- resolved, and resolving it again does nothing.
    _frame: Frame
    --- Traceback of a gameplay crash. Once set, the loop stops simulating and
    --- rendering but keeps draining events and answering the debug server.
    --- Cleared only by `clearCrash`, and only on the terms stated there.
    _crashed: string
    --- Why recovery could not put the device back the way the engine intended,
    --- or nil while every recovery so far was clean. Latched for the life of
    --- the process, because nothing later makes an unclean one clean again.
    _forcedRecovery: string
    --- Where the checkpoint is written, resolved once, or nil when none was
    --- configured.
    _checkpointPath: string
    --- The last bytes staged, and whether they have been written since. Held
    --- rather than written eagerly: the whole point is that the write happens
    --- at the one moment the platform gives, not on the frame that prepared
    --- the state.
    _checkpointBytes: string
    _checkpointStaged: boolean
    _shutdownDone: boolean
end

local ApplicationMT <const>: metatable<Application> = {__index = Application}

-------------------------------------------------------------------------------
-- The crash guard
-------------------------------------------------------------------------------

--- What a guarded emit is about to deliver. Held here rather than captured, so
--- the per-event path allocates no closure.
local emitting: Application = nil
local emittingEvent: events.Event = nil

local function traceback(err: any): string
    return debug.traceback(tostring(err), 2)
end

--- Runs `body`, and records rather than propagates whatever it throws.
---
--- Every entry into a game's own code goes through this, so the line that
--- fails is post-mortem debuggable wherever it was written. The loop keeps
--- draining events so the window still closes, and keeps answering the debug
--- server so an agent that was watching gets the traceback rather than a
--- refused connection. That was already true of a system, and it is the
--- moment the tooling is most useful and the worst one to lose.
---
--- Engine code is deliberately not guarded. An engine that throws is a bug
--- here rather than in the game, and swallowing it would hide it.
---
--- This is also the only finally the language offers. A throw leaves whatever
--- it was inside half done: a render or compute pass open, a command buffer
--- holding a swapchain texture the presenter is waiting for, or a world stuck
--- in deferred mutation because a throw skipped the pop that ends a query loop.
--- Recovery runs here rather than at each of the five call sites, because a
--- call site that forgot it would be a leak nobody could see.
local function guard(self: Application, what: string, body: function): boolean
    local ok, failure = xpcall(body, traceback) as (boolean, string)
    if ok then
        return true
    end

    LOGGER:error("%s crashed, still serving:\n%s", what, failure)

    -- The first traceback wins, and every later one is logged rather than
    -- kept. Whatever went wrong first is the one that explains the fault; a
    -- throw after it is usually the consequence, and there are two paths that
    -- produce one: the teardown still runs `world:shutdown` on a world that
    -- crashed, and a `Shutdown` system reaching for what the crash left half
    -- built throws in its turn. Overwriting would replace the explanation
    -- with the symptom, on the run where the explanation is all there is.
    --
    -- Recorded before anything is put back, for the same reason: recovery has
    -- its own failures to report and none of them may take this slot either.
    if self._crashed == nil then
        self._crashed = failure
        mcp.setCrashed(failure)
    end

    self:_recover()
    return false
end

--- Puts back what a throw was holding.
---
--- Ordered outwards from the scarcest thing: the command buffer, which holds a
--- slot in a finite pool and possibly the swapchain texture the display is
--- waiting on; then the world, whose staged mutations every later read would
--- otherwise miss; then the latency sample, which is measuring against a frame
--- whose submission will never happen.
---
--- An individual guard protects each step, so a failure does not stop the
--- ones after it and none of them can throw out of the guard that called this.
--- The log places their reports beside the crash, never in place of it.
---
--- It also records how clean the recovery was, which is what `clearCrash`
--- reads. Putting a command buffer back is not the same as putting the device
--- back: a pass that had to be force-ended recorded half of what it meant to,
--- and canceling a frame instead of submitting it keeps it from the GPU
--- at all. Either way the device is in a state the engine did not intend, and
--- resuming on top of that is guessing.
function Application:_recover()
    local frame = self._frame
    if frame ~= nil then
        -- Read across the abandon rather than asked for, because `abandon`
        -- reports whether it succeeded and not what it had to do. Nothing else
        -- closes a pass, and recovery runs on the thread that owns the device,
        -- so a drop here is this frame's.
        local openBefore <const> = passscope.openCount()
        local failure = frame:abandon()
        if failure ~= nil then
            LOGGER:error("the frame could not be resolved: %s", failure)
            self._forcedRecovery = "the frame could not be resolved: " .. failure
        elseif passscope.openCount() < openBefore then
            self._forcedRecovery = "a pass was force-ended to resolve the frame"
        elseif frame.state == "canceled" then
            self._forcedRecovery = "the frame was canceled rather than submitted"
        end
    end

    local world = self.world
    if world ~= nil then
        local ok, failure = pcall(world.unwind, world) as (boolean, any)
        if not ok then
            LOGGER:error("the world could not be unwound: %s", tostring(failure))
        end
    end

    -- A throw between `FixedFirst` and `FixedLast` leaves the fixed-phase gate
    -- latched, so every later query would answer from the latched sets rather
    -- than the frame's. The engine enters and leaves that phase twice a frame
    -- through the same call, so this is the ordinary way out taken late.
    local held = self.input
    if held ~= nil then
        held:exitFixedPhase()
    end

    timing.abandonInput()
end

--- The body of a guarded emit, as one function rather than one per event.
local function deliver()
    emitting.world:emit(0, emittingEvent)
end

--- What the drain below delivers to, held here for the reason `emitting` is:
--- an iteration should not allocate a closure to be able to receive an event,
--- and it allocates one whether or not the queue turned out to hold any.
local receiving: Application = nil

local function receive(event: events.Event)
    receiving:_receive(event)
end

--- Builds an application. Return the result from the entry chunk.
---
--- Reached as `tecs.newApplication`, at the root rather than under a module,
--- because an application is not a subsystem: it owns the window, the device,
--- the input, the renderer and the audio. Tecs hands it to the entry plugin
--- beside the world.
---
--- @param config Tecs reads this table here and ignores later changes. This
---     call opens nothing.
--- @return The application, at rest until the host's first callback.
function Application.newApplication(config: Application.Config): Application
    local self = setmetatable({} as Application, ApplicationMT)
    self._config = config or {} as Application.Config
    self._shutdownDone = false
    self.quitRequested = false
    self.suspended = false
    self.elapsed = 0.0
    self.frame = 0
    self._checkpointStaged = false
    return self
end

-------------------------------------------------------------------------------
-- The checkpoint
-------------------------------------------------------------------------------

--- Writes the staged checkpoint, if there is one that has not been written.
---
--- Through a neighboring file and a rename, so the checkpoint on disk is
--- either the previous one or this one and never half of either. That is not
--- fussiness: this runs when the platform is about to stop the process, and
--- the write that gets interrupted is the one nobody was watching.
---
--- Reports rather than raises. A platform callback calls it, where
--- there is nobody left to catch anything and a failed save must not also cost
--- the game its orderly shutdown.
local function flushCheckpoint(self: Application, occasion: string): boolean
    local path <const> = self._checkpointPath
    if path == nil or not self._checkpointStaged then
        return false
    end

    local bytes <const> = self._checkpointBytes
    local pending <const> = path .. ".new"
    local wrote, writeFailure = files.write(pending, bytes)
    if not wrote then
        LOGGER:error("the checkpoint could not be written to %s: %s", pending, tostring(writeFailure))
        return false
    end

    local moved, moveFailure = files.rename(pending, path)
    if not moved then
        LOGGER:error("the checkpoint could not be moved into place at %s: %s", path, tostring(moveFailure))
        files.remove(pending)
        return false
    end

    self._checkpointStaged = false
    LOGGER:info("checkpoint written on %s: %d bytes to %s", occasion, #bytes, path)
    return true
end

--- Hands the engine the bytes to write when the platform backgrounds us.
---
--- Call this from an ordinary system, on an ordinary frame, whenever the state
--- worth keeping has changed. Nothing is written here; the bytes are held, and
--- `_willEnterBackground` writes them at the one moment the platform gives.
---
--- What this takes is bytes rather than a function that produces them, and
--- that is the whole design rather than an inconvenience. iOS allows roughly
--- five seconds from the backgrounding callback returning and Android rather
--- less, and at this project's scale a world is not serializable inside any of
--- it: the platform could kill a callback part way through four million entities
--- through and leave nothing behind. A function would let a game postpone the
--- serializing into exactly that callback while looking like it had prepared
--- something. A string cannot: by the time it exists, the expensive half has
--- already happened on a frame that could afford it. The host times the hook
--- and says so past 250 ms, which is the check on the rest.
---
--- Staging again replaces the previous bytes; there is one checkpoint, not a
--- queue. Staging and then backgrounding twice writes once, because a write
--- no changes only gives the platform another chance to interrupt the write for nothing.
---
--- The counterpart is `readCheckpoint`, which is how the next run gets it back.
--- Raises when the config names no `checkpoint`, because silently holding bytes
--- that will never be written is the one failure a game would not notice.
function Application:stageCheckpoint(bytes: string)
    if self._checkpointPath == nil then
        error(
            "tecs: no checkpoint file is configured, so there is nowhere to "
                .. "write this; name one as `checkpoint` in the application "
                .. "config",
            2
        )
    end
    if bytes == nil then
        error("tecs: a checkpoint is bytes to write, and none were given", 2)
    end
    self._checkpointBytes = bytes
    self._checkpointStaged = true
end

--- Reads the bytes the last run left, or returns nil when there are none.
---
--- Read it while building the world, which is what the plugin and the startup
--- phases are for. Nil covers every reason there is nothing to resume from: a
--- first run, a game that never staged anything, a file the player deleted.
--- None of those is an error, so none of them raises.
function Application:readCheckpoint(): string
    local path <const> = self._checkpointPath
    if path == nil then
        return nil
    end
    return files.read(path, "checkpoint")
end

--- Returns the checkpoint path, or nil when the config names none.
function Application:checkpointPath(): string
    return self._checkpointPath
end

-------------------------------------------------------------------------------
-- Host contract
-------------------------------------------------------------------------------

--- Called once by the host before the first iteration.
function Application:_init(): boolean
    local config = self._config

    -- First of all, so it governs what everything below has to say about
    -- itself. SDL owns the priorities, so this needs no subsystem started.
    if config.logLevel ~= nil then
        log.setLevel(config.logLevel)
    end

    sdl.check(C.SDL_Init(K.SDL_INIT_VIDEO + K.SDL_INIT_GAMEPAD) as boolean, "SDL_Init")

    -- Before anything else that might have something to say. The platform
    -- destination works without this; the file is what makes a log queryable
    -- after the fact, and what SDL has no sink for. Written for a development
    -- run because that is who reads it back, and for a shipped one only when
    -- the game named a file itself.
    local logFile = config.logFile
    if logFile == nil and (config.mcpPort ~= nil or config.debug) then
        logFile = "log.jsonl"
    end
    if logFile ~= nil then
        log.openFile(files.writablePath(logFile))
    end

    -- Resolved before the game's plugin runs, so a game can read what the last
    -- run left while it is building the world it is going to put back.
    if config.checkpoint ~= nil then
        self._checkpointPath = files.writablePath(config.checkpoint)
    end

    -- Before the device, because the pack decides which shader format the
    -- device may claim, and that decides which backend SDL selects. The name
    -- is fixed rather than configurable: the build produces the pack and the
    -- engine finds it, and there is no version of that a game decides.
    local packPath = files.assetPath("shaders.tsp")
    local pack = shaderpack.read(packPath)
    if pack ~= nil then
        shadercompiler.usePack(pack)
    elseif not shadercompiler.available() then
        error(("tecs: this build links no shader compiler and there is no " .. "pack at %s"):format(packPath))
    end

    self.window = window.newWindow(config.window or {} as Window.Options)

    self.device = Device.create(self.window, {debug = config.debug})
    if config.framesInFlight ~= nil then
        self.device:setFramesInFlight(config.framesInFlight)
    end
    if config.presentMode ~= nil then
        self.device:setPresentMode(config.presentMode)
    end

    -- The window is what text input and the cursor modes act on, so input is
    -- created knowing it rather than being told later.
    self.input = input.newInput({window = self.window.handle})
    -- Passed through rather than validated here. `pipeline.new` is where a
    -- timestep of zero or a negative step count is refused, so there is one
    -- description of what is legal and it is the one the world enforces.
    self.world = ecs.newWorld({
        maxEntities = config.maxEntities,
        timestep = config.timestep,
        fixedMaxSteps = config.fixedMaxSteps,
        fixedOverload = config.fixedOverload,
    })
    self.renderer = Renderer.newRenderer(
        self.device.handle,
        self.device:getSwapchainFormat(),
        {
            ambient = config.ambientLight,
            capacity = config.capacity,
            reserveRuns = config.reserveRuns,
            partialRewrites = config.partialRewrites,
            packImages = config.packImages,
            shadows = config.shadows,
        }
    )
    self.renderer:install(self.world)

    -- Opened before the game's load, so a game may load a clip there. A
    -- machine with no output still gets an object: nothing here fails over
    -- the absence of a sound card.
    self.audio = audio.newAudio(config.audio)
    self.audio:install(self.world)

    -- Tweening and sequencing are one plugin, and it belongs to the engine
    -- rather than to the game: both drive entities through the fixed phases,
    -- and a game that forgot to install it would find its own authored
    -- timelines silently never advancing.
    sequence.plugin(self.world)

    -- Touch arrives normalized, so the converter needs the window size to
    -- report it in the same units as a mouse position. That is the logical
    -- size: a mouse position is in window coordinates, and scaling touch by
    -- the pixel size would put the two pointers a device-density factor apart
    -- on every high-density display.
    local width, height = self.window:getSize()
    eventHost.setTouchScale(width, height)

    -- Latched input is what lets a fixed step see a press that began and ended
    -- between two steps. Bracketing the fixed phases is the whole mechanism,
    -- so the engine installs it rather than leaving it to the game.
    local held = self.input
    self.world:addSystem({
        name = "tecs.EnterFixedInput",
        phase = ecs.phases.FixedFirst,
        run = function() held:enterFixedPhase() end,
    })
    self.world:addSystem({
        name = "tecs.ExitFixedInput",
        phase = ecs.phases.FixedLast,
        run = function() held:exitFixedPhase() end,
    })

    -- The debug tools carry the reloads, and both the server and the file
    -- watcher drive them, so they are bound when either is asked for rather
    -- than by the server alone.
    if config.mcpPort ~= nil or config.watch ~= nil then
        local tools = require("tecs.io.mcp.tools")
        tools.bind(self.renderer, self.world)

        -- The device's half of a shader reload. The tool re-reads the sources
        -- and refuses the reloads that would renumber a material; what it
        -- cannot do on its own is make a frame draw from what it read, which
        -- is a pipeline swap and belongs to whoever owns the device.
        local renderer = self.renderer
        tools.bindReload(function() renderer:rebuildPipelines() end)
    end

    if config.mcpPort ~= nil then
        -- Only the world. Which components exist is the ECS's registry to
        -- answer, and the tools read it there, so a game's own components are
        -- nameable without the game being told to say so.
        local mcpWorld = require("tecs.io.mcp.world")
        mcpWorld.bind(self.world)
        self.mcp = mcp.listen(config.mcpPort)

        -- Registered here rather than in the tool module, because it acts on
        -- this application and there is no other way for a tool to reach one.
        -- Callable after a crash for the obvious reason: every moment it is
        -- useful in is one.
        mcp.register({
            name = "clear_crash",
            description = "Lets the loop simulate and render again after a "
                .. "gameplay crash. A chance to look at another frame and to "
                .. "reload, not a repair: engine invariants are restored and "
                .. "the game's are not, so reload before trusting the world.",
            destructive = true,
            whenCrashed = true,
            inputSchema = {type = "object", properties = data.empty_array},
            handler = function(_: {string: any}): {string: any}
                local resumed, refusal = self:clearCrash()
                return {
                    resumed = resumed,
                    reason = refusal or data.null,
                }
            end,
        })
    end

    -- Before the game's plugin, so a pad that was already plugged in when the
    -- process started is there when the game asks for it. Waiting for an
    -- event would leave every such device invisible: the platform reports an
    -- addition, not a device that was there all along.
    self.input:refreshDevices()

    -- The game. Registration first, then the startup phases the registration
    -- put systems in, and both guarded: a game that throws while starting up
    -- leaves a traceback and a live debug server rather than a dead process,
    -- which is the same bargain a system in any other phase already gets.
    --
    -- Called rather than passed to `world:addPlugin`, which takes a plain
    -- `function(world)`. Anything this delegates to has that shape and goes
    -- through the world, which is what makes one entry point enough.
    --
    -- Startup runs here rather than in the first iteration so that everything
    -- it spawned is resident before the first frame is extracted, and so its
    -- cost lands before the clock resets rather than in the first frame's dt.
    local world = self.world
    local plugin = config.plugin
    if plugin ~= nil then
        guard(self, "the plugin", function() plugin(world, self) end)
    end
    if self._crashed == nil then
        guard(self, "startup", function() world:startup() end)
    end

    -- After the game's plugin, so the first look takes up everything the run has
    -- opened. Which reloader owns which kind is registered here rather than
    -- inside the watcher: the I/O modules know neither images nor clips, and
    -- the rules a reload may not break are stated once, in the functions the
    -- debug tools are wrappers over.
    --
    -- Each reload ends by asking to resume, which is what the watcher is for.
    -- A file that broke the game is a file someone is about to fix, and a
    -- loop that stays stopped after the fix has landed makes the watcher a
    -- notification rather than a tool. `clearCrash` decides whether that is
    -- allowed and says nothing when there is nothing to resume from, so the
    -- call costs a nil check on the ordinary path. A handler that raised
    -- never reaches it: the reload refused, so nothing has changed.
    if config.watch ~= nil then
        local tools = require("tecs.io.mcp.tools")
        watcher.on("shader", function() tools.reloadShaders(); self:clearCrash() end)
        watcher.on("image", function(change: watcher.Change) tools.reloadImage(change.path); self:clearCrash() end)
        watcher.on("sound", function(change: watcher.Change) tools.reloadSound(change.path); self:clearCrash() end)
        -- The metrics, not the atlas beside them. The atlas was loaded as an
        -- image and reloads as one, under the rect it already occupies; the
        -- metrics are what decides where a glyph is and how wide it is, so they
        -- are what has to be read again and laid out from.
        watcher.on("font", function(change: watcher.Change) tools.reloadFont(change.path); self:clearCrash() end)
        watcher.install(config.watch)
    end

    -- Startup cost must not land in the first iteration's dt.
    time.reset()
    return true
end

--- Folds one event into engine state, then emits it on the world's bus.
---
--- Observers see every event, including ones the engine acted on. An engine
--- that consumed events would leave a game unable to tell the difference
--- between an event it never received and one it mishandled.
---
--- The application folds input first, so an observer reading `app.input` inside its handler
--- sees the press it is being told about rather than the state before it.
---
--- Where this sits in the frame is worth being plain about, because an observer
--- is not a system. The drain runs before `world:update`, so an observer fires
--- ahead of every system in the frame the event belongs to, outside every
--- phase: no fixed step, no pause or state gating, and the world applies mutations at
--- once rather than deferred to a phase boundary. A game wanting a reaction in
--- phase does what `Input` does, which is fold the event into something a
--- system reads.
---
--- The application emits nothing for a kind nobody requested, which makes a
--- device-rate stream of motion cost a table lookup rather than a dispatch. The
--- application emits the record as it stands instead of copying it into an
--- event instance, so an observer receives the same reused record every other consumer sees
--- and the same borrow rule applies to it.
function Application:_receive(event: events.Event)
    -- Before anything acts on the event, so what is measured is the wait from
    -- the host's stamp rather than from some point inside the reaction.
    if timing.enabled and event.arrival ~= nil and eventHost.isInput(event.kind) then
        timing.inputArrived(event.arrival)
    end

    self.input:handleEvent(event)

    local kind = event.kind
    if kind == "quit" or kind == "windowCloseRequested" then
        self.quitRequested = true
    elseif kind == "windowResized" then
        -- Touch is normalized to the window, so the conversion to window
        -- coordinates has to follow the window rather than the size it had at
        -- startup.
        eventHost.setTouchScale(event.data1, event.data2)
    end
    -- Nothing is folded for the six lifecycle kinds. They are dispatched to a
    -- method at the instant they arrive and drained here afterwards, and on
    -- Android the drain is after the resume, so acting on them here would be
    -- acting a suspension too late. Observers still see them, like any event.

    -- Everything above this line is engine state, and it keeps being folded
    -- after a crash: quit still closes the window, input still tracks what is
    -- held, and `send_event` still reaches both, which is what makes it one of
    -- the tools that answers while crashed.
    --
    -- Nothing below it runs. A game whose systems stopped is not in a state to
    -- handle an event either, and delivering one has a specific cost rather
    -- than a vague risk: an observer that throws is a second crash, and the
    -- traceback it produces is the one nobody needed. Delivery resumes when
    -- `clearCrash` does.
    if self._crashed ~= nil then
        return
    end

    local eventType = events.typeOf(kind)
    if eventType == nil then
        return
    end

    local world = self.world
    if not world:hasObservers(0, eventType) then
        return
    end

    -- The bus routes on this and reads nothing else off the record, so stamping
    -- it is the whole of what delivery costs beyond the dispatch itself.
    event.eventId = eventType.eventId
    emitting = self
    emittingEvent = event
    guard(self, "an observer", deliver)
    emittingEvent = nil
end

--- Called once per iteration by the host. Returning false stops the loop.
---
--- `arrivals` is the host's parallel array of arrival stamps, one per queued
--- event.
function Application:_iterate(queue: loader.CValue, count: integer, arrivals: loader.CValue): boolean
    local dt = time.step()
    local frameStart = timing.begin()

    -- Everything SDL delivered since the previous iteration, taken whole by
    -- this iteration's step. Holding a batch back for a later step would cost
    -- an event a frame, which is what the latency stages are there to catch.
    self.input:beginFrame()
    receiving = self
    eventHost.drain(queue, count, receive, arrivals)

    if self.quitRequested then
        return false
    end

    -- The loading worker answers whenever it finishes, and nothing else in a
    -- frame is obliged to ask. A subsystem that loads assets of its own drains
    -- the same queue when it looks at its own waiting list, but a game that
    -- loaded an image and nothing else has no such subsystem, and its future
    -- would stay pending for the life of the process. Outside the suspension
    -- guard, because a decode that finished while backgrounded is finished.
    assets.update()

    -- The same argument, for the same reason: a child that has exited has
    -- exited, and a game that shelled out and did nothing else would otherwise
    -- hold a future that never settles. Costs a nil check on a
    -- process that has never started a child.
    platformOS.updateProcesses()
    platformOS.updateDialogs()

    -- Address resolution, connection attempts and generic stream transfers
    -- are finite asynchronous work just like the services above. A game with
    -- an Application gets one nonblocking poll every iteration, including
    -- while suspended or crashed, so its futures cannot stall because no
    -- system happened to ask the I/O module for progress.
    --
    -- This precedes the protocol-specific HTTP pump. Generic sources settle
    -- first, then transports with their own client lifecycle, then the file
    -- watcher. Costs one empty-list check when no source is pending.
    tecsIO.poll()

    -- And again for every open HTTP client. A transfer that completed while
    -- the game was backgrounded has completed, so this is outside the
    -- suspension guard like the two above it. It is outside the crash guard
    -- too, and for a reason the event path does not have: an observer that
    -- throws after a crash is a second traceback nobody needed, while a
    -- future's listeners already run inside the drain's own pcall, so nothing
    -- here can produce one. Not pumping would hold a socket open and let a
    -- transfer reach a deadline it had no reason to.
    --
    -- Costs an integer compare on a process that has never built a client.
    -- This module is what makes that true: the list of live clients does not
    -- initialize Reqwest, so a game with no HTTP in it starts no HTTP runtime.
    httpClients.pump()

    -- Outside the suspension and crash guards, for the reason above and one
    -- more: a shader edited to fix the crash is exactly what a stopped process
    -- is waiting for. Costs a clock read on a frame the interval has not
    -- elapsed on, and nothing at all when no watcher was asked for.
    watcher.poll()

    if not self.suspended then
        -- Answered on this thread, inside the frame, so a tool reads a world
        -- that is not mid-update. Polled before the guard below, so it keeps
        -- answering after a crash.
        if self.mcp ~= nil then
            self.mcp:poll()
        end

        if self._crashed == nil then
            -- Simulated time, so it advances when simulation does and not
            -- when the loop merely goes round. A crashed run that kept
            -- counting would hand the frame after a resume an `elapsed` with
            -- however long the fix took folded into it, and anything driven
            -- off it would jump by that much.
            self.elapsed = self.elapsed + dt
            self:_simulate(dt)
        end
    end

    -- Outside the suspension guard and outside the crash guard. Voices the
    -- mixer has finished with have to keep being reaped, and a sound that
    -- sticks because the game crashed or the window went to the background is
    -- a second failure on top of the first. The step goes in because a keyed
    -- cooldown is measured against it, which is also why it is this dt and not
    -- the suspension-guarded one: time passes while a game is suspended.
    if self.audio ~= nil then
        self.audio:update(dt)
    end

    timing.finish(FRAME, frameStart)

    self.frame = self.frame + 1
    local limit <const> = self._config.debugMaxFrames
    if limit ~= nil and self.frame >= limit then
        return false
    end
    return true
end

--- What a guarded frame runs, as one function rather than one per frame. Held
--- here for the reason `deliver` is: a frame should not allocate a closure to
--- be able to fail.
local simulating: Application = nil
local simulatingDt: number = 0.0
local simulatingStart: number = 0.0

local function step()
    local self <const> = simulating
    local t0 <const> = simulatingStart
    self.world:update(simulatingDt)

    local t1 = timing.begin()
    local frame = self.device:beginFrame()
    -- Recorded before anything is drawn into it, because everything after this
    -- line can throw and the recovery path has no other way to reach it.
    self._frame = frame
    local t2 = timing.begin()
    if frame == nil then
        return
    end

    self.renderer:render(frame)
    local t3 = timing.begin()
    frame:submit()
    local t4 = timing.begin()
    if timing.enabled then
        -- Simulation is the update without the extraction inside it. The
        -- renderer's sync system runs in RenderFirst, so its cost is in
        -- t1 - t0 and has to come back out: game work and extraction are
        -- separate stages, and a change that moves cost between them is
        -- invisible if they are one number.
        timing.mark(SIMULATE, (t1 - t0) - self.renderer:extractSeconds())
        timing.mark(ACQUIRE, t2 - t1)
        timing.mark(RECORD, t3 - t2)
        timing.mark(SUBMIT, t4 - t3)
        -- Submission is where the frame leaves us for the display, so it is
        -- where the event's path through the engine ends. A frame that
        -- acquired nothing never got there and is not a sample.
        timing.inputPresented(t1, t4)
    end
end

--- One frame of simulation and rendering, guarded.
---
--- A crash here does not end the process. The loop keeps draining events so the
--- window still closes, and keeps answering the debug server so an agent that
--- was watching gets the traceback rather than a refused connection. That is
--- the moment the tooling is most useful and the worst one to lose it in.
---
--- It also does not leak. Everything the frame holds is reachable from the
--- application while it is held, so `guard` can put all of it back; see
--- `_recover` for what "all of it" is.
function Application:_simulate(dt: number)
    local t0 = timing.begin()
    -- This step observes whatever the drain above delivered, so this is the
    -- moment the input stops waiting and starts being acted on.
    timing.inputConsumed(t0)
    simulating = self
    simulatingDt = dt
    simulatingStart = t0
    guard(self, "gameplay", step)
end

--- Returns the gameplay traceback, or nil while the game is healthy.
function Application:crashed(): string
    return self._crashed
end

function Application:clearCrash(): boolean, string
    if self._crashed == nil then
        return true
    end

    local config <const> = self._config
    if not config.debug and config.mcpPort == nil and config.watch == nil then
        return false, "this build sets none of debug, mcpPort or watch, so it " .. "does not resume after a crash"
    end
    if self._forcedRecovery ~= nil then
        return false,
            "recovery was not clean, so the device is not in the "
                .. "state the engine intended: "
                .. self._forcedRecovery
    end

    self._crashed = nil
    mcp.setCrashed(nil)
    LOGGER:warn(
        "resuming after a crash; engine state is restored and the "
            .. "world may be inconsistent, so reload before trusting it"
    )
    return true
end

-------------------------------------------------------------------------------
-- The platform lifecycle
-------------------------------------------------------------------------------

--- Memory is short and the platform is asking for whatever can be given back.
---
--- A full collection rather than a step: the platform asks for the low
--- water mark, and the pause it costs is cheaper than the alternative, which
--- on iOS is process termination. Everything else belongs to the game, and a game
--- with caches of its own answers `events.on.lowMemory` on the bus, where it
--- is one observer among the rest and has a whole frame to do it in.
function Application:_lowMemory()
    local before <const> = collectgarbage("count")
    collectgarbage("collect")
    local after <const> = collectgarbage("count")
    LOGGER:warn("low memory: gave back %.0f KB, still holding %.0f KB", before - after, after)
end

--- The platform is about to put the application in the background.
---
--- The one hook with a deadline behind it. iOS allows roughly five seconds
--- from here and Android rather less, and the host says so past 250 ms, so
--- what happens here is a write of bytes the game already had: see
--- `stageCheckpoint` for why the surface takes bytes rather than a callback.
---
--- This callback sets suspension rather than waiting for the queued event,
--- because Android blocks the process as soon as the platform dispatches it
--- and there may be no drain until the resume.
function Application:_willEnterBackground()
    self.suspended = true
    flushCheckpoint(self, "backgrounding")
end

--- The application is in the background and the platform has stopped drawing.
---
--- Waits for the device to go idle, so nothing is left in flight across a
--- suspension whose length is not ours to decide.
---
--- What is deliberately not here is releasing the graphics device, which is
--- where an engine that has ported to Android ends up. Three things have to be
--- true before it can be, and none of them is today. Every GPU handle in the
--- one owner would need to reach and release every GPU handle in the process,
--- recreated: they are not, they belong to the backend, the deferred pipeline,
--- the image array and every buffer, and a recreation that missed one is a
--- use-after-free rather than a black frame. The image array would have to be
--- the image array would need to support refilling, but `Renderer:registerImage`
--- releases the source pixels,
--- because the array holds them, so there is nothing on the CPU to upload
--- again. And it would have to be testable: none of these events fires on the
--- platforms the suite runs on, so a recovery path written now is a path whose
--- first execution is on a player's phone.
---
--- So this states the gap rather than half closing it. A game shipping to
--- mobile today loses its device on backgrounding and the process does not
--- come back; the checkpoint above is what makes that survivable, which is why
--- it landed first.
function Application:_didEnterBackground()
    if self.device ~= nil then
        self.device:waitForIdle()
    end
end

--- The application is in the foreground again.
---
--- The clock restarts rather than integrating the gap. Whatever the platform
--- did during suspension is not elapsed game time, and a dt of however
--- long the player was reading their mail would put every fixed step of it
--- through in one frame.
---
--- The other half of what device loss will need, when there is any: this is
--- the last moment before the frame a player sees.
function Application:_didEnterForeground()
    self.suspended = false
    time.reset()
end

--- Handles the platform ending the process.
---
--- The last call in. SDL ends the loop as soon as it has dispatched this, so
--- no iteration follows it, and this method defers or retries nothing.
---
--- This method offers the checkpoint again because termination from the foreground
--- never went through a backgrounding, and one already written costs a boolean
--- to skip.
function Application:_terminating()
    flushCheckpoint(self, "termination")
end

--- Called once by the host, however the loop ended.
function Application:_shutdown(): boolean
    if self._shutdownDone then
        return true
    end
    self._shutdownDone = true

    if timing.auto then
        local report = timing.format()
        if report ~= "" then
            io.stderr:write(report .. "\n")
        end
    end

    -- The game's teardown, and the first thing here for the same reason the
    -- rest of this function is ordered at all: a `Shutdown` system releasing
    -- something has to run while what it holds still exists. The window, the
    -- device, the renderer, the world and the audio are all live at this point
    -- and none of them is after it.
    --
    -- Run whenever there is a world to run them on, rather than only after a
    -- clean startup. A game that acquired something in a `PreStartup` system
    -- and threw in the next one still has to be given the chance to give it
    -- back, and that is exactly the run where nothing else will.
    if self.world ~= nil then
        local world = self.world
        guard(self, "shutdown", function() world:shutdown() end)
    end

    watcher.uninstall()
    if self.mcp ~= nil then
        self.mcp:destroy()
    end
    -- Before SDL_Quit, since closing a device after the subsystem it belongs
    -- to has gone is undefined.
    if self.input ~= nil then
        self.input:destroy()
    end
    if self.audio ~= nil then
        self.audio:destroy()
    end
    -- After the audio, which drains its own outstanding loads through the
    -- worker this stops. A thread still decoding into a state that is being
    -- torn down is the one way asset loading can outlive the process it
    -- belongs to.
    assets.shutdown()
    -- A child outlives the process that started it unless something ends it,
    -- and the worker waiting on one would be a thread inside a library about
    -- to be unmapped. So teardown kills: gently, then forcibly, then joins.
    platformOS.shutdownProcesses()
    log.closeFile()

    if self.device ~= nil then
        self.device:waitForIdle()
        if self.renderer ~= nil then
            self.renderer:destroy()
        end
        self.device:destroy()
    end
    if self.window ~= nil then
        self.window:destroy()
    end
    C.SDL_Quit()
    return true
end

return Application
