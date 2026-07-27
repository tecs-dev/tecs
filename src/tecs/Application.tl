--- The application the entry chunk returns.
---
--- SDL drives the loop, so this is not a function that runs until done. It is
--- an object the host calls back into: once to initialise, once per iteration,
--- once to shut down. An entry file returns one instead of blocking, because
--- on iOS there is no loop for it to block in.
---
--- The underscored methods are the host's contract, not the game's.

local ecs <const> = require("tecs.ecs")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local clock <const> = require("tecs.platform.clock")
local events <const> = require("tecs.platform.events")
local Input <const> = require("tecs.platform.Input")
local Window <const> = require("tecs.platform.Window")
local Device <const> = require("tecs.gpu.Device")
local Renderer <const> = require("tecs.Renderer")
local Audio <const> = require("tecs.Audio")
local assets <const> = require("tecs.assets")
local components <const> = require("tecs.components")
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
--- The game's own per-frame callback. Its cost belongs to the simulation side
--- of any split, so leaving it outside every stage understates that side and
--- flatters anything that only moves the other one.
local GAME <const> = timing.stage("game")

local record WindowConfig
    title: string
    width: integer
    height: integer
    resizable: boolean
    highPixelDensity: boolean
end

local record Application
    record Config
        window: WindowConfig
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

        load: function(app: Application)
        update: function(app: Application, dt: number)
        event: function(app: Application, event: events.Event)
        quit: function(app: Application)
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
    --- Traceback of a gameplay crash. Once set, the loop stops simulating and
    --- rendering but keeps draining events and answering the debug server.
    _crashed: string
    _started: boolean
    _shutdownDone: boolean
end

local ApplicationMT <const>: metatable<Application> = { __index = Application }

--- Builds an application. Return the result from the entry chunk.
function Application.create(config: Application.Config): Application
    local self = setmetatable({} as Application, ApplicationMT)
    self._config = config or {} as Application.Config
    self._started = false
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

    local windowConfig = config.window or {} as WindowConfig
    self.window = Window.create({
        title = windowConfig.title,
        width = windowConfig.width,
        height = windowConfig.height,
        resizable = windowConfig.resizable,
        highPixelDensity = windowConfig.highPixelDensity,
    })

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
        -- The engine's own components, plus the ECS builtins. A game adds its
        -- own through mcpWorld.register, since nothing here can know them.
        local mcpWorld = require("tecs.mcp.world")
        -- Both tables carry more than components, so a candidate has to look
        -- like one rather than merely be present.
        local known: {string: ecs.Component} = {}
        local function collect(source: {string: any})
            for name, value in pairs(source) do
                if type(value) == "table"
                    and (value as {string: any}).componentName ~= nil then
                    known[name] = value as ecs.Component
                end
            end
        end
        collect(components as {string: any})
        collect(ecs.builtins as {string: any})
        mcpWorld.bind(self.world, known)
        self.mcp = mcp.listen(config.mcpPort)
    end

    -- Before the game's load, so a pad that was already plugged in when the
    -- process started is there when the game asks for it. Waiting for an
    -- event would leave every such device invisible: the platform reports an
    -- addition, not a device that was there all along.
    self.input:refreshDevices()

    if config.load ~= nil then config.load(self) end

    -- After the game's load, so the first look takes up everything the run has
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
    self._started = true
    return true
end

--- Folds one event into engine state, then hands it to the game.
---
--- The game sees every event, including ones the engine acted on. An engine
--- that consumed events would leave a game unable to tell the difference
--- between an event it never received and one it mishandled.
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

    local handler = self._config.event
    if handler ~= nil then handler(self, event) end
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
        if self._config.update ~= nil then
            local started = timing.begin()
            self._config.update(self, dt)
            timing.finish(GAME, started)
        end

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


--- One frame of simulation and rendering, guarded.
---
--- A crash here does not end the process. The loop keeps draining events so the
--- window still closes, and keeps answering the debug server so an agent that
--- was watching gets the traceback rather than a refused connection. That is
--- the moment the tooling is most useful and the worst one to lose it in.
function Application:_simulate(dt: number)
    local t0 = timing.begin()
    -- This step observes whatever the drain above delivered, so this is the
    -- moment the input stops waiting and starts being acted on.
    timing.inputConsumed(t0)
    local ok, failure = xpcall(function(): boolean
        self.world:update(dt)

        local t1 = timing.begin()
        local frame = self.device:beginFrame()
        local t2 = timing.begin()
        if frame ~= nil then
            self.renderer:render(frame)
            local t3 = timing.begin()
            frame:submit()
            local t4 = timing.begin()
            if timing.enabled then
                -- Simulation is the update without the extraction inside it.
                -- The renderer's sync system runs in RenderFirst, so its cost
                -- is in t1 - t0 and has to come back out: the two land on
                -- opposite sides of the pipelined boundary, and a change that
                -- moves cost between them is invisible if they are one number.
                timing.mark(SIMULATE, (t1 - t0) - self.renderer:extractSeconds())
                timing.mark(ACQUIRE, t2 - t1)
                timing.mark(RECORD, t3 - t2)
                timing.mark(SUBMIT, t4 - t3)
                -- Submission is where the frame leaves us for the display, so
                -- it is where the event's path through the engine ends. A
                -- frame that acquired nothing never got there and is not a
                -- sample.
                timing.inputPresented(t1, t4)
            end
        end
        return true
    end, function(err: any): string
        return debug.traceback(tostring(err), 2)
    end) as (boolean, string)

    if ok then return end

    self._crashed = failure as string
    LOGGER:error("gameplay crashed, still serving:\n%s", self._crashed)
    mcp.setCrashed(self._crashed)
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

    if self._started and self._config.quit ~= nil then
        self._config.quit(self)
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
