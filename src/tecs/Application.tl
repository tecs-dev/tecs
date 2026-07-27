--- The application the entry chunk returns.
---
--- SDL drives the loop, so this is not a function that runs until done. It is
--- an object the host calls back into: once to initialise, once per iteration,
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
---              `world:startup` at the end of initialisation
---   per frame  the ordinary phases, run by `world:update`
---   per event  `world:observe(0, events.on.<kind>, handler)`
---   teardown   `PreShutdown`, `Shutdown`, `PostShutdown`, run once by
---              `world:shutdown` before anything is destroyed
---
--- A plugin needs to reach the objects that are not world state, and it is
--- handed them rather than asked to look them up: the window, the device, the
--- input, the renderer, the audio and `quitRequested` all hang off the
--- application it is passed beside the world.

local ecs <const> = require("tecs.ecs")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local clock <const> = require("tecs.platform.clock")
local events <const> = require("tecs.platform.events")
local Input <const> = require("tecs.platform.Input")
local Window <const> = require("tecs.platform.Window")
local Device <const> = require("tecs.gpu.Device")
local Frame <const> = require("tecs.gpu.Frame")
local Renderer <const> = require("tecs.Renderer")
local Audio <const> = require("tecs.Audio")
local assets <const> = require("tecs.assets")
local sequence <const> = require("tecs.sequence")
local paths <const> = require("tecs.platform.paths")
local proc <const> = require("tecs.platform.proc")
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
        debug: boolean
        framesInFlight: integer
        presentMode: string
        ambient: {number}
        --- Shader pack to read, relative to the asset root. Defaults to
        --- `shaders.tsp`. A build that links a compiler runs without one.
        shaderPack: string
        --- Sound output. Omitted takes the defaults, which open the
        --- platform's default device.
        audio: Audio.Config
        --- Log file name, under the writable root. Defaults to `log.jsonl`.
        --- Set to "" to write only to the platform's own destination.
        logFile: string
        --- Port for the MCP server. Omitted means no server, since a game
        --- should not open a socket nobody asked for.
        mcpPort: integer
        --- Watches the content files this run has loaded and reloads them when
        --- they change. Omitted means no watcher, on the same footing as the
        --- server above: a poll of the filesystem is not something to start
        --- because a build happened to be able to. A release refuses it.
        watch: watch.Config
        capacity: integer
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
        reserveRuns: boolean
        --- Stops after this many iterations. Lets an automated run drive a
        --- real window to completion without a human closing it.
        maxFrames: integer

        --- The game, as one function handed the world and this application.
        ---
        --- Called at the end of initialisation, after every engine subsystem is
        --- installed and before the startup phases run, so it can register a
        --- `Startup` system and have it run this initialisation rather than the
        --- next one.
        ---
        --- One entry point rather than a list, because composing plugins is
        --- something the world already does: `world:addPlugin` takes an
        --- `ecs.Plugin` and is how the engine installs its own, so a game with
        --- several calls it from in here and needs no second mechanism.
        ---
        --- The world comes first because every plugin the world takes is
        --- `function(world)`, so this reads as that shape with one more thing
        --- and code moves between here and a delegated plugin without a silent
        --- argument swap.
        plugin: function(world: ecs.World, app: Application)
    end

    window: Window
    device: Device
    world: ecs.World
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

    _config: Application.Config
    _simulate: function(self: Application, dt: number)
    _recover: function(self: Application)
    --- The frame this iteration acquired, held so that recovery can resolve one
    --- the throw left open. It survives into the next iteration and is
    --- harmless there: a frame that submitted or cancelled is already
    --- resolved, and resolving it again does nothing.
    _frame: Frame
    --- Traceback of a gameplay crash. Once set, the loop stops simulating and
    --- rendering but keeps draining events and answering the debug server.
    _crashed: string
    _shutdownDone: boolean
end

local ApplicationMT <const>: metatable<Application> = { __index = Application }

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
    if ok then return true end

    -- Recorded before anything is put back. Recovery has its own failures to
    -- report and none of them may replace the traceback that says what
    -- actually went wrong.
    self._crashed = failure
    LOGGER:error("%s crashed, still serving:\n%s", what, failure)
    mcp.setCrashed(failure)
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
function Application:_recover()
    local frame = self._frame
    if frame ~= nil then
        local failure = frame:abandon()
        if failure ~= nil then
            LOGGER:error("the frame could not be resolved: %s", failure)
        end
    end

    local world = self.world
    if world ~= nil then
        local ok, failure = pcall(world.unwind, world) as (boolean, any)
        if not ok then
            LOGGER:error("the world could not be unwound: %s",
                tostring(failure))
        end
    end

    timing.abandonInput()
end

--- The body of a guarded emit, as one function rather than one per event.
local function deliver()
    emitting.world:emit(0, emittingEvent)
end

--- Builds an application. Return the result from the entry chunk.
function Application.create(config: Application.Config): Application
    local self = setmetatable({} as Application, ApplicationMT)
    self._config = config or {} as Application.Config
    self._shutdownDone = false
    self.quitRequested = false
    self.suspended = false
    self.elapsed = 0.0
    self.frame = 0
    return self
end

-------------------------------------------------------------------------------
-- Host contract
-------------------------------------------------------------------------------

--- Called once by the host before the first iteration.
function Application:_init(): boolean
    local config = self._config

    sdl.check(C.SDL_Init(K.SDL_INIT_VIDEO + K.SDL_INIT_GAMEPAD) as boolean,
        "SDL_Init")

    -- Before anything else that might have something to say. The platform
    -- destination works without this; the file is what makes a log queryable
    -- after the fact, and what SDL has no sink for.
    local logFile = config.logFile or "log.jsonl"
    if logFile ~= "" then
        log.openFile(paths.writable(logFile))
    end

    -- Before the device, because the pack decides which shader format the
    -- device may claim, and that decides which backend SDL selects.
    local packPath = paths.asset(config.shaderPack or "shaders.tsp")
    local pack = shaderpack.read(packPath)
    if pack ~= nil then
        shadercompiler.usePack(pack)
    elseif not shadercompiler.available() then
        error(("tecs: this build links no shader compiler and there is no "
            .. "pack at %s"):format(packPath))
    end

    self.window = Window.create(config.window or {} as Window.Options)

    self.device = Device.create(self.window, { debug = config.debug })
    if config.framesInFlight ~= nil then
        self.device:setFramesInFlight(config.framesInFlight)
    end
    if config.presentMode ~= nil then
        self.device:setPresentMode(config.presentMode)
    end

    -- The window is what text input and the cursor modes act on, so input is
    -- created knowing it rather than being told later.
    self.input = Input.create({ window = self.window.handle })
    self.world = ecs.newWorld({ maxEntities = config.maxEntities })
    self.renderer = Renderer.create(self.device.handle,
        self.device:getSwapchainFormat(), {
            ambient = config.ambient,
            capacity = config.capacity,
            reserveRuns = config.reserveRuns,
        })
    self.renderer:install(self.world)

    -- Opened before the game's load, so a game may load a clip there. A
    -- machine with no output still gets an object: nothing here fails over
    -- the absence of a sound card.
    self.audio = Audio.create(config.audio)
    self.audio:install(self.world)

    -- Tweening and sequencing are one plugin, and it belongs to the engine
    -- rather than to the game: both drive entities through the fixed phases,
    -- and a game that forgot to install it would find its own authored
    -- timelines silently never advancing.
    sequence.plugin(self.world)

    -- Touch arrives normalised, so the converter needs the window size to
    -- report it in the same units as a mouse position. That is the logical
    -- size: a mouse position is in window coordinates, and scaling touch by
    -- the pixel size would put the two pointers a device-density factor apart
    -- on every high-density display.
    local width, height = self.window:getSize()
    events.setTouchScale(width, height)

    -- Latched input is what lets a fixed step see a press that began and ended
    -- between two steps. Bracketing the fixed phases is the whole mechanism,
    -- so the engine installs it rather than leaving it to the game.
    local input = self.input
    self.world:addSystem({
        name = "tecs.EnterFixedInput",
        phase = ecs.phases.FixedFirst,
        run = function() input:enterFixedPhase() end,
    })
    self.world:addSystem({
        name = "tecs.ExitFixedInput",
        phase = ecs.phases.FixedLast,
        run = function() input:exitFixedPhase() end,
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
    if config.watch ~= nil then
        local tools = require("tecs.mcp.tools")
        watch.on("shader", function() tools.reloadShaders() end)
        watch.on("image", function(change: watch.Change)
            tools.reloadImage(change.path)
        end)
        watch.on("sound", function(change: watch.Change)
            tools.reloadSound(change.path)
        end)
        -- The metrics, not the atlas beside them. The atlas was loaded as an
        -- image and reloads as one, under the rect it already occupies; the
        -- metrics are what decides where a glyph is and how wide it is, so they
        -- are what has to be read again and laid out from.
        -- The metrics, not the atlas beside them. The atlas was loaded as an
        -- image and reloads as one, under the rect it already occupies; the
        -- metrics are what decides where a glyph is and how wide it is, so they
        -- are what has to be read again and laid out from.
        watch.on("font", function(change: watch.Change)
            tools.reloadFont(change.path)
        end)
        watch.install(config.watch)
    end

    -- Startup cost must not land in the first iteration's dt.
    clock.reset()
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
    if timing.enabled and event.arrival ~= nil
        and events.isInput(event.kind) then
        timing.inputArrived(event.arrival)
    end

    self.input:handleEvent(event)

    local kind = event.kind
    if kind == "quit" or kind == "windowCloseRequested" then
        self.quitRequested = true
    elseif kind == "windowResized" then
        -- Touch is normalised to the window, so the conversion to window
        -- coordinates has to follow the window rather than the size it had at
        -- startup.
        events.setTouchScale(event.data1, event.data2)
    elseif kind == "appWillEnterBackground" then
        self.suspended = true
    elseif kind == "appDidEnterForeground" then
        self.suspended = false
        -- Whatever the platform did while backgrounded is not elapsed game
        -- time, so the clock restarts rather than integrating the gap.
        clock.reset()
    end

    local eventType = events.typeOf(kind)
    if eventType == nil then return end

    local world = self.world
    if not world:hasObservers(0, eventType) then return end

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
function Application:_iterate(queue: loader.CValue, count: integer,
                              arrivals: loader.CValue): boolean
    local dt = clock.step()
    local frameStart = timing.begin()

    -- Everything SDL delivered since the previous iteration, taken whole by
    -- this iteration's step. Holding a batch back for a later step would cost
    -- an event a frame, which is what the latency stages are there to catch.
    self.input:beginFrame()
    events.drain(queue, count, function(event: events.Event)
        self:_receive(event)
    end, arrivals)

    if self.quitRequested then return false end

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
    proc.update()

    -- Outside the suspension and crash guards, for the reason above and one
    -- more: a shader edited to fix the crash is exactly what a stopped process
    -- is waiting for. Costs a clock read on a frame the interval has not
    -- elapsed on, and nothing at all when no watcher was asked for.
    watch.poll()

    if not self.suspended then
        self.elapsed = self.elapsed + dt

        -- Answered on this thread, inside the frame, so a tool reads a world
        -- that is not mid-update. Polled before the guard below, so it keeps
        -- answering after a crash.
        if self.mcp ~= nil then self.mcp:poll() end

        if self._crashed == nil then self:_simulate(dt) end
    end

    -- Outside the suspension guard and outside the crash guard. Voices the
    -- mixer has finished with have to keep being reaped, and a sound that
    -- sticks because the game crashed or the window went to the background is
    -- a second failure on top of the first. The step goes in because a keyed
    -- cooldown is measured against it, which is also why it is this dt and not
    -- the suspension-guarded one: time passes while a game is suspended.
    if self.audio ~= nil then self.audio:update(dt) end

    timing.finish(FRAME, frameStart)

    self.frame = self.frame + 1
    if self._config.maxFrames ~= nil and self.frame >= self._config.maxFrames then
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
    if frame == nil then return end

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

--- Called once by the host, however the loop ended.
function Application:_shutdown(): boolean
    if self._shutdownDone then return true end
    self._shutdownDone = true

    if timing.auto then
        local report = timing.format()
        if report ~= "" then io.stderr:write(report .. "\n") end
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
    if self.mcp ~= nil then self.mcp:destroy() end
    -- Before SDL_Quit, since closing a device after the subsystem it belongs
    -- to has gone is undefined.
    if self.input ~= nil then self.input:destroy() end
    if self.audio ~= nil then self.audio:destroy() end
    -- After the audio, which drains its own outstanding loads through the
    -- worker this stops. A thread still decoding into a state that is being
    -- torn down is the one way asset loading can outlive the process it
    -- belongs to.
    assets.shutdown()
    -- A child outlives the process that started it unless something ends it,
    -- and the worker waiting on one would be a thread inside a library about
    -- to be unmapped. So teardown kills: gently, then forcibly, then joins.
    proc.shutdown()
    log.closeFile()

    if self.device ~= nil then
        self.device:waitForIdle()
        if self.renderer ~= nil then self.renderer:destroy() end
        self.device:destroy()
    end
    if self.window ~= nil then self.window:destroy() end
    C.SDL_Quit()
    return true
end

return Application
