--- tecs2d public surface.
---
--- Owns the process loop. Rendering is explicit: each frame acquires a
--- command buffer, records into it, and submits. Pacing comes from the
--- swapchain acquire blocking on the presentation engine, so the loop does
--- not sleep or spin to hit a target frame rate.

local tecs <const> = require("tecs")
local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")
local clock <const> = require("tecs2d.platform.clock")
local events <const> = require("tecs2d.platform.events")
local Window <const> = require("tecs2d.platform.Window")
local Device <const> = require("tecs2d.gpu.Device")
local Frame <const> = require("tecs2d.gpu.Frame")
local RenderPass <const> = require("tecs2d.gpu.RenderPass")
local Renderer <const> = require("tecs2d.ecs.Renderer")
local components <const> = require("tecs2d.ecs.components")

local C <const> = sdl.C
local K <const> = sdl.K

local record App
    window: Window
    device: Device
    --- The world this app drives. Entities are the interface: anything that
    --- renders or updates per frame lives here.
    world: tecs.World
    --- Feeds the deferred pipeline from the world.
    renderer: Renderer
    --- Set to true to leave the loop at the end of the current frame.
    quitRequested: boolean
    --- Seconds since the loop started, advanced by the frame dt so a replay
    --- reproduces it exactly.
    elapsed: number
    --- Frames completed since the loop started.
    frame: integer
end

local record WindowConfig
    title: string
    width: integer
    height: integer
    resizable: boolean
    highPixelDensity: boolean
end

local record RunConfig
    window: WindowConfig
    --- Enables GPU backend validation layers.
    debug: boolean
    --- Frames the CPU may run ahead of the GPU. Resource retirement depth
    --- must match this.
    framesInFlight: integer
    --- Ambient colour applied by the lighting pass.
    ambient: {number}
    --- Instances the render buffer is sized for.
    capacity: integer
    --- Presentation pacing: "vsync" (default), "immediate", or "mailbox".
    --- Benchmarks use immediate so a frame's real cost is observable.
    presentMode: string
    --- Stops after this many frames. Lets an automated run drive a real
    --- window to completion without a human closing it.
    maxFrames: integer

    load: function(app: App)
    update: function(app: App, dt: number)
    event: function(app: App, event: loader.CValue)
    quit: function(app: App)
end

local record tecs2d
    App: App
    Renderer: Renderer
    components: components
    RunConfig: RunConfig
    Window: Window
    Device: Device
    Frame: Frame
    RenderPass: RenderPass
    clock: clock
    events: events
    --- Version of this engine build.
    version: string
end

tecs2d.Renderer = Renderer
tecs2d.components = components
tecs2d.Window = Window
tecs2d.Device = Device
tecs2d.Frame = Frame
tecs2d.RenderPass = RenderPass
tecs2d.clock = clock
tecs2d.events = events
tecs2d.version = "0.1.0"

--- Runs the application to completion. Returns the process exit code.
function tecs2d.run(config: RunConfig): integer
    sdl.check(C.SDL_Init(K.SDL_INIT_VIDEO) as boolean, "SDL_Init")

    local windowConfig = config.window or {} as WindowConfig
    local window = Window.create({
        title = windowConfig.title,
        width = windowConfig.width,
        height = windowConfig.height,
        resizable = windowConfig.resizable,
        highPixelDensity = windowConfig.highPixelDensity,
    })

    local device = Device.create(window, { debug = config.debug })
    if config.framesInFlight ~= nil then
        device:setFramesInFlight(config.framesInFlight)
    end
    if config.presentMode ~= nil then
        device:setPresentMode(config.presentMode)
    end

    local world = tecs.newWorld()
    local renderer = Renderer.create(device.handle, device:getSwapchainFormat(), {
        ambient = config.ambient,
        capacity = config.capacity,
    })
    renderer:install(world)

    local app = setmetatable({} as App, { __index = App })
    app.window = window
    app.device = device
    app.world = world
    app.renderer = renderer
    app.quitRequested = false
    app.elapsed = 0.0
    app.frame = 0

    if config.load ~= nil then config.load(app) end

    -- Startup cost must not land in the first frame's dt.
    clock.reset()

    local onEvent = config.event
    local handler = function(event: loader.CValue)
        local kind = event.type
        if kind == C.SDL_EVENT_QUIT then
            app.quitRequested = true
        elseif kind == C.SDL_EVENT_WINDOW_CLOSE_REQUESTED then
            app.quitRequested = true
        end
        if onEvent ~= nil then onEvent(app, event) end
    end

    while not app.quitRequested do
        local dt = clock.step()
        events.poll(handler)
        if app.quitRequested then break end

        app.elapsed = app.elapsed + dt
        if config.update ~= nil then config.update(app, dt) end

        -- The world runs to completion before a frame is acquired. Syncing
        -- needs no command buffer and rendering needs no world, so the two
        -- stay separable and the swapchain is held for as little as possible.
        world:update(dt)

        local frame = device:beginFrame()
        if frame ~= nil then
            renderer:render(frame)
            frame:submit()
        end

        app.frame = app.frame + 1
        if config.maxFrames ~= nil and app.frame >= config.maxFrames then
            app.quitRequested = true
        end
    end

    if config.quit ~= nil then config.quit(app) end

    device:waitForIdle()
    renderer:destroy()
    device:destroy()
    window:destroy()
    C.SDL_Quit()
    return 0
end

return tecs2d
