--- The application the entry chunk returns.
---
--- SDL drives the loop, so this is not a function that runs until done. It is
--- an object the host calls back into: once to initialise, once per iteration,
--- once to shut down. An entry file returns one instead of blocking, because
--- on iOS there is no loop for it to block in.
---
--- The underscored methods are the host's contract, not the game's.

local tecs <const> = require("tecs")
local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")
local clock <const> = require("tecs2d.platform.clock")
local events <const> = require("tecs2d.platform.events")
local Input <const> = require("tecs2d.platform.Input")
local Window <const> = require("tecs2d.platform.Window")
local Device <const> = require("tecs2d.gpu.Device")
local Renderer <const> = require("tecs2d.Renderer")
local tween <const> = require("tecs2d.tween")
local sequence <const> = require("tecs2d.sequence")
local paths <const> = require("tecs2d.platform.paths")
local shaderpack <const> = require("tecs2d.gpu.shaderpack")
local shadercompiler <const> = require("tecs2d.gpu.shadercompiler")

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

    -- Installed by the engine rather than by the game. Both drive entities
    -- through the fixed phases and a game that forgot one would find its own
    -- authored timelines silently never advancing.
    self.world:addPlugin(tween.plugin)
    self.world:addPlugin(sequence.plugin)

    -- Touch arrives normalised, so the converter needs the window size to
    -- report it in the same units as a mouse position.
    local width, height = self.window:getPixelSize()
    events.setTouchScale(width, height)

    -- Latched input is what lets a fixed step see a press that began and ended
    -- between two steps. Bracketing the fixed phases is the whole mechanism,
    -- so the engine installs it rather than leaving it to the game.
    local input = self.input
    self.world:addSystem({
        name = "tecs2d.EnterFixedInput",
        phase = tecs.phases.FixedFirst,
        run = function() input:enterFixedPhase() end,
    })
    self.world:addSystem({
        name = "tecs2d.ExitFixedInput",
        phase = tecs.phases.FixedLast,
        run = function() input:exitFixedPhase() end,
    })

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

        self.world:update(dt)

        local frame = self.device:beginFrame()
        if frame ~= nil then
            self.renderer:render(frame)
            frame:submit()
        end
    end

    self.frame = self.frame + 1
    if self._config.maxFrames ~= nil and self.frame >= self._config.maxFrames then
        return false
    end
    return true
end

--- Called once by the host, however the loop ended.
function Application:_shutdown(): boolean
    if self._shutdownDone then return true end
    self._shutdownDone = true

    if self._started and self._config.quit ~= nil then
        self._config.quit(self)
    end

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
