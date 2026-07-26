--- The application the entry chunk returns.
---
--- SDL drives the loop, so this is not a function that runs until done. It is
--- an object the host calls back into: once to initialise, once per iteration,
--- once to shut down. An entry file returns one instead of blocking, because
--- on iOS there is no loop for it to block in.
---
--- The underscored methods are the host's contract, not the game's.

local tecs <const> = require("tecs")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local clock <const> = require("tecs.platform.clock")
local events <const> = require("tecs.platform.events")
local Input <const> = require("tecs.platform.Input")
local Window <const> = require("tecs.platform.Window")
local Device <const> = require("tecs.gpu.Device")
local Renderer <const> = require("tecs.Renderer")
local components <const> = require("tecs.components")
local paths <const> = require("tecs.platform.paths")
local log <const> = require("tecs.log")
local mcp <const> = require("tecs.mcp")

local LOGGER <const> = log.get("tecs.app")
local shaderpack <const> = require("tecs.gpu.shaderpack")
local shadercompiler <const> = require("tecs.gpu.shadercompiler")

local C <const> = sdl.C
local K <const> = sdl.K

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
        --- Log file name, under the writable root. Defaults to `log.jsonl`.
        --- Set to "" to write only to the platform's own destination.
        logFile: string
        --- Port for the MCP server. Omitted means no server, since a game
        --- should not open a socket nobody asked for.
        mcpPort: integer
        capacity: integer
        maxEntities: integer
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
    world: tecs.World
    renderer: Renderer
    input: Input
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
    --- Per-phase frame timing, accumulated when TECS2D_TIMING is set.
    _timing: {string: number}
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
    if os.getenv("TECS2D_TIMING") ~= nil then
        self._timing = { update = 0, acquire = 0, record = 0, submit = 0, frames = 0 }
    end
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
        error(("tecs2d: this build links no shader compiler and there is no "
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

    self.input = Input.create()
    self.world = tecs.newWorld({ maxEntities = config.maxEntities })
    self.renderer = Renderer.create(self.device.handle,
        self.device:getSwapchainFormat(), {
            ambient = config.ambient,
            capacity = config.capacity,
        })
    self.renderer:install(self.world)

    -- Tweening and sequencing are installed here once they are ported. They
    -- belong to the engine rather than to the game, because both drive
    -- entities through the fixed phases and a game that forgot one would find
    -- its own authored timelines silently never advancing.

    -- Touch arrives normalised, so the converter needs the window size to
    -- report it in the same units as a mouse position.
    local width, height = self.window:getPixelSize()
    events.setTouchScale(width, height)

    -- Latched input is what lets a fixed step see a press that began and ended
    -- between two steps. Bracketing the fixed phases is the whole mechanism,
    -- so the engine installs it rather than leaving it to the game.
    local input = self.input
    self.world:addSystem({
        name = "tecs.EnterFixedInput",
        phase = tecs.phases.FixedFirst,
        run = function() input:enterFixedPhase() end,
    })
    self.world:addSystem({
        name = "tecs.ExitFixedInput",
        phase = tecs.phases.FixedLast,
        run = function() input:exitFixedPhase() end,
    })

    if config.mcpPort ~= nil then
        local tools = require("tecs.mcp.tools")
        tools.bind(self.renderer, self.world)

        -- The engine's own components, plus the ECS builtins. A game adds its
        -- own through mcpWorld.register, since nothing here can know them.
        local mcpWorld = require("tecs.mcp.world")
        -- Both tables carry more than components, so a candidate has to look
        -- like one rather than merely be present.
        local known: {string: tecs.Component} = {}
        local function collect(source: {string: any})
            for name, value in pairs(source) do
                if type(value) == "table"
                    and (value as {string: any}).componentName ~= nil then
                    known[name] = value as tecs.Component
                end
            end
        end
        collect(components as {string: any})
        collect(tecs.builtins as {string: any})
        mcpWorld.bind(self.world, known)
        self.mcp = mcp.listen(config.mcpPort)
    end

    if config.load ~= nil then config.load(self) end

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
    self.input:handleEvent(event)

    local kind = event.kind
    if kind == "quit" or kind == "windowCloseRequested" then
        self.quitRequested = true
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
function Application:_iterate(queue: loader.CValue, count: integer): boolean
    local dt = clock.step()

    self.input:beginFrame()
    events.drain(queue, count, function(event: events.Event)
        self:_receive(event)
    end)

    if self.quitRequested then return false end

    if not self.suspended then
        self.elapsed = self.elapsed + dt
        if self._config.update ~= nil then self._config.update(self, dt) end

        -- Answered on this thread, inside the frame, so a tool reads a world
        -- that is not mid-update. Polled before the guard below, so it keeps
        -- answering after a crash.
        if self.mcp ~= nil then self.mcp:poll() end

        if self._crashed == nil then self:_simulate(dt) end
    end

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
    local t0 = clock.now()
    local ok, failure = xpcall(function(): boolean
        self.world:update(dt)

        local t1 = clock.now()
        local frame = self.device:beginFrame()
        local t2 = clock.now()
        if frame ~= nil then
            self.renderer:render(frame)
            local t3 = clock.now()
            frame:submit()
            local t4 = clock.now()
            if self._timing ~= nil then
                local t = self._timing
                t.update = t.update + (t1 - t0)
                t.acquire = t.acquire + (t2 - t1)
                t.record = t.record + (t3 - t2)
                t.submit = t.submit + (t4 - t3)
                t.frames = t.frames + 1
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

    local t = self._timing
    if t ~= nil and t.frames > 0 then
        local n = t.frames
        io.stderr:write(("timing over %d frames (ms/frame):\n"):format(math.floor(n) as integer))
        io.stderr:write(("  update  %.3f\n  acquire %.3f\n  record  %.3f\n  submit  %.3f\n")
            :format(t.update / n * 1000, t.acquire / n * 1000,
                    t.record / n * 1000, t.submit / n * 1000))
    end

    if self._started and self._config.quit ~= nil then
        self._config.quit(self)
    end

    if self.mcp ~= nil then self.mcp:destroy() end
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
