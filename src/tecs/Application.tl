--- The application the entry chunk returns.
---
--- SDL drives the loop, so this is not a function that runs until done. It is
--- an object the host calls back into: once to initialize, once per iteration,
--- once to shut down. An entry file returns one instead of blocking, because
--- on iOS there is no loop for it to block in.
---
--- The underscored methods are the host's contract, not the game's.
---
--- A game's own code runs in systems and observers, and there is one way in:
--- `config.plugin`. It is handed the world and this application, and registers
--- what it wants to happen, which the world then runs. Nothing here calls back
--- into a game per frame or per event, because the world already does both and
--- does them better: a system's order is declared by its phase, both are
--- visible to the debug server, and both run inside a guard that keeps the
--- process alive and inspectable after the game throws.
---
--- So the four lifecycle points a game used to be handed map onto what the ECS
--- already had:
---
---   startup    `PreStartup`, `Startup`, `PostStartup`, run once by
---              `world:startup` at the end of initialization
---   per frame  the ordinary phases, run by `world:update`
---   per event  `world:observe(0, events.on.<kind>, handler)`
---   teardown   `PreShutdown`, `Shutdown`, `PostShutdown`, run once by
---              `world:shutdown` before anything is destroyed
---
--- A plugin needs to reach the objects that are not world state, and it is
--- handed them rather than asked to look them up: the window, the device, the
--- input, the renderer, the audio and `quitRequested` all hang off the
--- application it is passed beside the world.
---
--- Six of the underscored methods are not per frame at all. SDL dispatches
--- the platform lifecycle from its event watcher rather than queueing it, and
--- the host calls one method per event at the instant it arrives, because on
--- Android the process blocks as soon as backgrounding has been sent and the
--- next iteration is after the resume. `_lowMemory`, `_willEnterBackground`,
--- `_didEnterBackground`, `_willEnterForeground`, `_didEnterForeground` and
--- `_terminating` are those six, and five of them are answered here.
---
--- `_willEnterForeground` is deliberately not. It says the application is
--- about to be visible again and nothing in the engine has anything to do
--- with that yet: the clock and the suspension belong to `_didEnterForeground`
--- beside them, which is when the platform is actually drawing again. A game
--- that wants the earlier moment observes `events.on.appWillEnterForeground`,
--- because every lifecycle event is queued as well as dispatched.
---
--- Which is the rule for the other five too. The hook is where the engine
--- meets a deadline the event stream cannot; a game reads the transitions off
--- the bus like any other event. The one thing a game cannot do that way is
--- save state on being backgrounded, because there may be no later drain to
--- do it in, and `stageCheckpoint` is the surface for exactly that.

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
local filesystem <const> = require("tecs.platform.filesystem")
local system <const> = require("tecs.platform.system")
local httpClients <const> = require("tecs.net.http.clients")
local watch <const> = require("tecs.platform.watch")
local log <const> = require("tecs.log")
local mcp <const> = require("tecs.mcp")
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
    record Config
        --- The window to open, as `Window.Options` describes it. Passed
        --- through whole rather than copied field by field, so everything a
        --- window can be created with is reachable from here and a field
        --- added there needs nothing added here.
        window: Window.Options
        --- Marks this run as a development one, which two things read.
        ---
        --- The device is created with its validation layers on, and the log
        --- file below is written without being asked for. It is also one of
        --- the three settings `clearCrash` looks at, beside `mcpPort` and
        --- `watch`, to decide whether resuming after a gameplay crash is
        --- something this build does at all.
        debug: boolean
        framesInFlight: integer
        presentMode: string
        --- Light every surface receives before any light entity contributes,
        --- as red, green and blue. Defaults to white.
        ---
        --- White rather than a dim gray, because a scene that has placed no
        --- lights is the first thing anyone builds and it should look like
        --- what it is: sprites at their own color, with lights adding on top
        --- of them. A game doing its own lighting turns this down to the
        --- level it wants the unlit parts of the scene to sit at.
        ambientLight: {number}
        --- Sound output. Omitted takes the defaults, which open the
        --- platform's default device.
        audio: Audio.Config
        --- Log file name, under the writable root, written as JSON Lines
        --- beside the platform's own destination rather than instead of it.
        ---
        --- Omitted, one is written when `mcpPort` or `debug` is set and not
        --- otherwise. The file exists for the debug server, which is what
        --- makes `get_logs` a seek and a read rather than a ring buffer kept
        --- in the process, so it follows the thing that reads it: a game
        --- should no more write a file nobody asked for than open a socket
        --- nobody asked for. Nothing is lost by that, because SDL already
        --- dispatches to a destination a human can read on every platform;
        --- see `log`. A shipped game that wants a crash log in the field
        --- names one here, since where a game writes user data is the game's
        --- decision and not the engine's.
        logFile: string
        --- Lowest priority that reaches the log at all, as one of
        --- `log.TRACE`, `log.VERBOSE`, `log.DEBUG`, `log.INFO`, `log.WARN`,
        --- `log.ERROR` or `log.CRITICAL`. Omitted leaves SDL's own default.
        ---
        --- Applies to every category, ours and SDL's, and it is set before
        --- anything here has had a chance to say something. Separate from
        --- `logFile` above, which decides durability rather than volume: a
        --- game wanting everything kept and little of it shown sets both.
        logLevel: integer
        --- File name, under the writable root, that a checkpoint is written
        --- to when the platform backgrounds or terminates the application.
        --- Omitted means no checkpoint, and `stageCheckpoint` says so.
        ---
        --- See `Application:stageCheckpoint` for what a game has to do, which
        --- is the part that matters.
        checkpoint: string
        --- Port for the MCP server. Omitted means no server, since a game
        --- should not open a socket nobody asked for.
        mcpPort: integer
        --- Watches the content files this run has loaded and reloads them when
        --- they change. Omitted means no watcher, on the same footing as the
        --- server above: a poll of the filesystem is not something to start
        --- because a build happened to be able to. A release refuses it.
        watch: watch.Config
        --- Instances the renderer's buffers are sized for. Defaults to 65536.
        ---
        --- An instance is a row the GPU draws: every renderable entity is one,
        --- and so is every glyph of every text, since a glyph is an entity
        --- like any other. This is a ceiling rather than a hint. Rows past it
        --- are dropped rather than growing a buffer mid-frame, and
        --- `renderer.dropped` counts them.
        ---
        --- Sized independently of `maxEntities` beside it, because the two
        --- count different things: a world full of entities that carry no
        --- `Renderable` needs no instances at all, and one text entity needs
        --- one instance per character.
        capacity: integer
        --- Seconds one fixed step covers. Must be greater than zero. Defaults
        --- to 1/60.
        timestep: number
        --- The most fixed steps one update runs before the overload policy
        --- applies. Must be a positive integer. Defaults to 10.
        fixedMaxSteps: integer
        --- What becomes of the catch-up that did not fit. Defaults to "drop",
        --- which bounds a frame's work and reports the loss through
        --- `world:getStats`. "accumulate" keeps every second instead.
        fixedOverload: ecs.FixedOverload
        --- Entity slots the world is sized for. Defaults to 2^20, and 2^22 - 1
        --- is the ceiling the packed id format allows.
        ---
        --- Concurrent slots rather than lifetime spawns: a slot is given back
        --- when the entity is despawned and reused by the next one. The arena
        --- is preallocated for this many, so it is a memory decision as much
        --- as a limit, and a game that knows its population sets it rather
        --- than paying for a million slots it will not use.
        maxEntities: integer
        --- Give each archetype a run with room to grow rather than packing the
        --- runs end to end. Defaults to false, which packs.
        ---
        --- Packed, a run cannot grow without shifting every run after it, so a
        --- spawn anywhere rewrites every instance in the scene. Reserved, it
        --- grows into its own slack and the archetypes around it are left
        --- alone. What it costs is that the cull is dispatched over the slack
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
        --- Fit many images into each layer of the renderer's image array
        --- rather than one. Defaults to false, where the ceiling on distinct
        --- images is the array's layer count and a small image costs a whole
        --- cell. On, the ceiling is the array's area instead.
        packImages: boolean
        --- Let entities cast shadows, and tune what they cost. Nil, the
        --- default, means an `Occluder` or a `DropShadow` on an entity draws
        --- the entity and casts nothing, because the targets that would hold a
        --- shadow are never built. An empty table turns them on with every
        --- default; see `Deferred.ShadowOptions` for the seven numbers.
        shadows: Deferred.ShadowOptions
        --- Stops after this many iterations. Lets an automated run drive a
        --- real window to completion without a human closing it.
        debugMaxFrames: integer

        --- The game, as one function handed the world and this application.
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
        plugin: function(world: types.World, app: Application)
    end

    window: Window
    device: Device
    world: types.World
    renderer: Renderer
    input: Input
    audio: Audio
    --- The debug server, when one was asked for.
    mcp: mcp.Server

    --- Set to true to leave the loop at the end of the current iteration.
    quitRequested: boolean
    --- True while the platform has the application in the background. The
    --- loop still runs, but simulation and rendering do not.
    suspended: boolean
    --- Seconds of simulated time, advanced by the frame dt so a replay
    --- reproduces it exactly.
    elapsed: number
    --- Iterations completed.
    frame: integer

    --- Declared here because `_init` wires the debug server and the file
    --- watcher to it before it is defined. Its contract is at the definition.
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
--- holding a swapchain texture the presenter is waiting for, a world stuck in
--- deferred mutation because the pop that ends a query loop was skipped.
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
--- that will never be submitted.
---
--- Every step is protected on its own, so a step that fails does not stop the
--- ones after it and none of them can throw out of the guard that called this.
--- What they report is logged beside the crash, never in place of it.
---
--- It also records how clean the recovery was, which is what `clearCrash`
--- reads. Putting a command buffer back is not the same as putting the device
--- back: a pass that had to be force-ended recorded half of what it meant to,
--- and a frame that was canceled rather than submitted never reached the GPU
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
--- the input, the renderer and the audio, and is handed to the entry plugin
--- beside the world.
---
--- @param config Read here, so a field changed on the table afterwards is not
---     seen. Nothing is opened yet.
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
--- Reports rather than raises. It is called from a platform callback, where
--- there is nobody left to catch anything and a failed save must not also cost
--- the game its orderly shutdown.
local function flushCheckpoint(self: Application, occasion: string): boolean
    local path <const> = self._checkpointPath
    if path == nil or not self._checkpointStaged then
        return false
    end

    local bytes <const> = self._checkpointBytes
    local pending <const> = path .. ".new"
    local wrote, writeFailure = filesystem.write(pending, bytes)
    if not wrote then
        LOGGER:error("the checkpoint could not be written to %s: %s", pending, tostring(writeFailure))
        return false
    end

    local moved, moveFailure = filesystem.rename(pending, path)
    if not moved then
        LOGGER:error("the checkpoint could not be moved into place at %s: %s", path, tostring(moveFailure))
        filesystem.remove(pending)
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
--- it: a callback that walked four million entities would be killed part way
--- through and leave nothing behind. A function would let a game postpone the
--- serializing into exactly that callback while looking like it had prepared
--- something. A string cannot: by the time it exists, the expensive half has
--- already happened on a frame that could afford it. The host times the hook
--- and says so past 250 ms, which is the check on the rest.
---
--- Staging again replaces what was staged; there is one checkpoint, not a
--- queue. Staging and then backgrounding twice writes once, because a write
--- nothing has changed since is a second chance to be interrupted for nothing.
---
--- The counterpart is `readCheckpoint`, which is how the next run gets it back.
--- Raises when no `checkpoint` was configured, because silently holding bytes
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

--- The bytes the last run left, or nil when there are none.
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
    return filesystem.read(path, "checkpoint")
end

--- Where the checkpoint is written, or nil when none was configured.
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
        log.openFile(filesystem.writablePath(logFile))
    end

    -- Resolved before the game's plugin runs, so a game can read what the last
    -- run left while it is building the world it is going to put back.
    if config.checkpoint ~= nil then
        self._checkpointPath = filesystem.writablePath(config.checkpoint)
    end

    -- Before the device, because the pack decides which shader format the
    -- device may claim, and that decides which backend SDL selects. The name
    -- is fixed rather than configurable: the build produces the pack and the
    -- engine finds it, and there is no version of that a game decides.
    local packPath = filesystem.assetPath("shaders.tsp")
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
    events.setTouchScale(width, height)

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
        local tools = require("tecs.mcp.tools")
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
        local mcpWorld = require("tecs.mcp.world")
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
    -- inside the watcher: nothing in `tecs.platform` knows what an image or a
    -- clip is, and the rules a reload may not break are stated once, in the
    -- functions the debug tools are wrappers over.
    --
    -- Each reload ends by asking to resume, which is what the watcher is for.
    -- A file that broke the game is a file someone is about to fix, and a
    -- loop that stays stopped after the fix has landed makes the watcher a
    -- notification rather than a tool. `clearCrash` decides whether that is
    -- allowed and says nothing when there is nothing to resume from, so the
    -- call costs a nil check on the ordinary path. A handler that raised
    -- never reaches it: the reload refused, so nothing has changed.
    if config.watch ~= nil then
        local tools = require("tecs.mcp.tools")
        watch.on("shader", function() tools.reloadShaders(); self:clearCrash() end)
        watch.on("image", function(change: watch.Change) tools.reloadImage(change.path); self:clearCrash() end)
        watch.on("sound", function(change: watch.Change) tools.reloadSound(change.path); self:clearCrash() end)
        -- The metrics, not the atlas beside them. The atlas was loaded as an
        -- image and reloads as one, under the rect it already occupies; the
        -- metrics are what decides where a glyph is and how wide it is, so they
        -- are what has to be read again and laid out from.
        watch.on("font", function(change: watch.Change) tools.reloadFont(change.path); self:clearCrash() end)
        watch.install(config.watch)
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
--- Input is folded first, so an observer reading `app.input` inside its handler
--- sees the press it is being told about rather than the state before it.
---
--- Where this sits in the frame is worth being plain about, because an observer
--- is not a system. The drain runs before `world:update`, so an observer fires
--- ahead of every system in the frame the event belongs to, outside every
--- phase: no fixed step, no pause or state gating, and mutations are applied at
--- once rather than deferred to a phase boundary. A game wanting a reaction in
--- phase does what `Input` does, which is fold the event into something a
--- system reads.
---
--- Nothing is emitted for a kind nobody asked for, which is what makes a
--- device-rate stream of motion cost a table lookup rather than a dispatch. The
--- record is emitted as it stands rather than copied into an event instance,
--- so an observer is handed the same reused record every other consumer sees
--- and the same borrow rule applies to it.
function Application:_receive(event: events.Event)
    -- Before anything acts on the event, so what is measured is the wait from
    -- the host's stamp rather than from some point inside the reaction.
    if timing.enabled and event.arrival ~= nil and events.isInput(event.kind) then
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
        events.setTouchScale(event.data1, event.data2)
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
    events.drain(queue, count, receive, arrivals)

    if self.quitRequested then
        return false
    end

    -- The loading worker answers whenever it finishes, and nothing else in a
    -- frame is obliged to ask. A subsystem that loads assets of its own drains
    -- the same queue when it looks at its own waiting list, but a game that
    -- loaded an image and nothing else has no such subsystem, and its handle
    -- would stay "loading" for the life of the process. Outside the suspension
    -- guard, because a decode that finished while backgrounded is finished.
    assets.update()

    -- The same argument, for the same reason: a child that has exited has
    -- exited, and a game that shelled out and did nothing else would otherwise
    -- hold a handle that never leaves "running". Costs a nil check on a
    -- process that has never started a child.
    system.updateProcesses()
    system.updateDialogs()

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
    -- This module is what makes that true: `tecs.net.http` loads libcurl
    -- when it is required, and the list of live clients deliberately does not,
    -- so a game with no HTTP in it does not link one.
    httpClients.pump()

    -- Outside the suspension and crash guards, for the reason above and one
    -- more: a shader edited to fix the crash is exactly what a stopped process
    -- is waiting for. Costs a clock read on a frame the interval has not
    -- elapsed on, and nothing at all when no watcher was asked for.
    watch.poll()

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

--- The gameplay traceback, or nil while the game is healthy.
function Application:crashed(): string
    return self._crashed
end

--- Another frame to look at and a chance to reload; the world may be
--- inconsistent, reload before trusting it.
---
--- That sentence is the whole contract, and the name is deliberately not
--- `recover` or `retry`: this is a debugging affordance, not fault tolerance.
--- What the guard put back are the engine's invariants, which are the ones it
--- can name: the command buffer is resolved, the passes are ended, the world
--- is applying mutations again. A game's invariants are not restored and
--- cannot be, because a system that threw halfway through its query left some
--- entities updated and some not, and nothing here knows which half or what
--- either half meant. So the frame after this is a frame to read, and the way
--- to get back to a world worth trusting is to reload the scene.
---
--- Two gates, and they are different kinds of thing.
---
--- The first is whether this build is a development one at all, which is
--- `debug`, `mcpPort` or `watch` in the config. A watcher counts because it is
--- the configuration that most wants this: a game running one is being edited,
--- and reloading the file that threw is exactly the way back. A shipped build
--- has none of the three, latches on the first crash and stays latched, which
--- is the right shipped behavior:
--- there is nobody there to read the frame, and carrying on with a world that
--- is provably inconsistent is how one bug becomes a corrupted save.
---
--- The second is severity, and it is narrower rather than a judgment about
--- how bad the throw looked. Recovery reports whether it had to force-end a
--- pass or cancel a frame instead of submitting it, and in either case the
--- device is not in the state the engine intended; see `_recover`. Those do
--- not resume, at any setting, because the next frame would be recorded
--- against a device nobody can describe.
---
--- The callers are the debug server's `clear_crash` tool and the file
--- watcher's reloads. Both mean the same thing: something about the run has
--- changed, try it again.
---
--- Physics resumability is a separate and open question: a solver stepped out
--- of is not obviously a solver that can be stepped again.
--- @return Whether the loop resumed, and why it did not.
function Application:clearCrash(): boolean, string
    if self._crashed == nil then
        return true
    end

    local config <const> = self._config
    if not config.debug and config.mcpPort == nil and config.watch == nil then
        return false, "this build sets none of debug, mcpPort or watch, so it " .. "does not resume after a crash"
    end
    if self._forcedRecovery ~= nil then
        return false, "recovery was not clean, so the device is not in the "
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
--- A full collection rather than a step: what is being asked for is the low
--- water mark, and the pause it costs is cheaper than the alternative, which
--- on iOS is being killed. Everything else belongs to the game, and a game
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
--- Suspension is set here rather than when the queued event is drained,
--- because on Android the process blocks as soon as this has been dispatched
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
--- process would have to be reachable from one place to be released and
--- recreated: they are not, they belong to the backend, the deferred pipeline,
--- the image array and every buffer, and a recreation that missed one is a
--- use-after-free rather than a black frame. The image array would have to be
--- refillable: the pixels behind it are released at `Renderer:registerImage`,
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
--- did while we were suspended is not elapsed game time, and a dt of however
--- long the player was reading their mail would put every fixed step of it
--- through in one frame.
---
--- The other half of what device loss will need, when there is any: this is
--- the last moment before the frame a player sees.
function Application:_didEnterForeground()
    self.suspended = false
    time.reset()
end

--- The process is being ended by the platform.
---
--- The last call in. SDL ends the loop as soon as it has dispatched this, so
--- there is no iteration after it and nothing here is deferred or retried.
---
--- The checkpoint is offered again because a termination out of the foreground
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

    watch.uninstall()
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
    system.shutdownProcesses()
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
