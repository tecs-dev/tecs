local events <const> = require("tecs2d.events")
local input <const> = require("tecs2d.input")
local handlers <const> = require("tecs2d.internal.handlers")
local tecs <const> = require("tecs")
local tecs_assets <const> = require("tecs2d.assets")
local tecs_audio <const> = require("tecs2d.audio")
local tecs_controller <const> = require("tecs2d.controller")
local tecs_tween <const> = require("tecs2d.tween")
local gfx <const> = require("tecs2d.gfx")
local tecs_tiled <const> = require("tecs2d.tiled")
local tecs_ui <const> = require("tecs2d.ui")

local LOGGER <const> = require("tecs.utils.logging").getLogger("tecs2d")

local lg_origin <const> = love.graphics.origin
local lg_clear <const> = love.graphics.clear
local lg_present <const> = love.graphics.present
local lg_isActive <const> = love.graphics.isActive
local lg_getBackgroundColor <const> = love.graphics.getBackgroundColor

local love_timer_step <const> = love.timer.step

--- Love2D integration module for Tecs.
--- Provides the game loop, Love2D events as ECS events, and application lifecycle.
local record tecs2d
    --- Configuration for tecs2d.run.
    record RunConfig
        --- Target frames per second (e.g., 60).
        fps: number

        --- The game plugin to run.
        game: tecs.Plugin

        --- Render pipeline configuration. Passed to gfx.newPipeline.
        render: gfx.RenderConfig

        --- Optional. Maximum number of concurrent entity slots. Must be a
        --- power of 2, at most 2^22. Defaults to 2^20 (~1M). See
        --- `tecs.World.Config.maxEntities`.
        maxEntities: integer
    end

    --- Creates a Love2D run function from a RunConfig table. Assign directly to `love.run`.
    --- Auto-installs the render pipeline, tiled plugin, and UI plugin before the game plugin.
    --- @param config RunConfig with fps, game plugin, and render settings.
    --- @return A function suitable for `love.run` that initializes and runs the game loop.
    run: function(config: RunConfig): (function(): function(): string | number)

    --- Triggers a quit event to exit the application cleanly.
    --- @param exitCode Optional exit code (defaults to 0 for success).
    quit: function(exitCode: number)

    ---------------------------------------------------------------------------
    -- Re-exported Love2D events
    ---------------------------------------------------------------------------
    type Quit = events.Quit
    type KeyPressed = events.KeyPressed
    type KeyReleased = events.KeyReleased
    type MousePressed = events.MousePressed
    type MouseReleased = events.MouseReleased
    type JoystickAdded = events.JoystickAdded
    type JoystickRemoved = events.JoystickRemoved
    type DirectoryDropped = events.DirectoryDropped
    type FileDropped = events.FileDropped
    type Focus = events.Focus
    type MouseFocus = events.MouseFocus
    type Resize = events.Resize
    type Visible = events.Visible
    type Exposed = events.Exposed
    type Occluded = events.Occluded
    type LocaleChanged = events.LocaleChanged
    type ThemeChanged = events.ThemeChanged
    type DropBegan = events.DropBegan
    type DropMoved = events.DropMoved
    type DropCompleted = events.DropCompleted
    type AudioDisconnected = events.AudioDisconnected
    type SensorUpdated = events.SensorUpdated
    type JoystickSensorUpdated = events.JoystickSensorUpdated
    type TouchPressed = events.TouchPressed
    type TouchMoved = events.TouchMoved
    type TouchReleased = events.TouchReleased
end

-- Re-export events at runtime
(tecs2d as {string:any}).Quit = events.Quit
(tecs2d as {string:any}).KeyPressed = events.KeyPressed
(tecs2d as {string:any}).KeyReleased = events.KeyReleased
(tecs2d as {string:any}).MousePressed = events.MousePressed
(tecs2d as {string:any}).MouseReleased = events.MouseReleased
(tecs2d as {string:any}).JoystickAdded = events.JoystickAdded
(tecs2d as {string:any}).JoystickRemoved = events.JoystickRemoved
(tecs2d as {string:any}).DirectoryDropped = events.DirectoryDropped
(tecs2d as {string:any}).FileDropped = events.FileDropped
(tecs2d as {string:any}).Focus = events.Focus
(tecs2d as {string:any}).MouseFocus = events.MouseFocus
(tecs2d as {string:any}).Resize = events.Resize
(tecs2d as {string:any}).Visible = events.Visible
(tecs2d as {string:any}).Exposed = events.Exposed
(tecs2d as {string:any}).Occluded = events.Occluded
(tecs2d as {string:any}).LocaleChanged = events.LocaleChanged
(tecs2d as {string:any}).ThemeChanged = events.ThemeChanged
(tecs2d as {string:any}).DropBegan = events.DropBegan
(tecs2d as {string:any}).DropMoved = events.DropMoved
(tecs2d as {string:any}).DropCompleted = events.DropCompleted
(tecs2d as {string:any}).AudioDisconnected = events.AudioDisconnected
(tecs2d as {string:any}).SensorUpdated = events.SensorUpdated
(tecs2d as {string:any}).JoystickSensorUpdated = events.JoystickSensorUpdated
(tecs2d as {string:any}).TouchPressed = events.TouchPressed
(tecs2d as {string:any}).TouchMoved = events.TouchMoved
(tecs2d as {string:any}).TouchReleased = events.TouchReleased

-------------------------------------------------------------------------------
-- game plugin
-------------------------------------------------------------------------------

local function gamePlugin(world: tecs.World)
    -- Create and register asset manager with default root "assets"
    local assetManager = tecs_assets.new("assets")
    world.resources[tecs_assets] = assetManager

    -- Create and register audio manager
    world:addPlugin(tecs_audio.plugin())

    -- Register tween system
    world:addPlugin(tecs_tween.plugin)

    -- Create and register controller manager
    world:addPlugin(tecs_controller.plugin())

    -- Update asset manager each frame
    world:addSystem({
        name = "love.AssetUpdate",
        phase = tecs.phases.First,
        run = function()
            assetManager:update()
        end
    })

    -- Shutdown asset manager when game shuts down
    world:addSystem({
        name = "love.AssetShutdown",
        phase = tecs.phases.Shutdown,
        run = function()
            LOGGER:debug("Shutting down asset manager")
            assetManager:shutdown()
        end
    })

    world:addSystem({
        name = "love.RenderClear",
        phase = tecs.phases.RenderFirst,
        run = function()
            if lg_isActive() then
                lg_origin()
                lg_clear(lg_getBackgroundColor())
            end
        end
    })

    -- Still allow the use of love.draw.
    if love.draw then
        world:addSystem({
            name = "love.Draw",
            phase = tecs.phases.Render,
            run = love.draw
        })
    end

    world:addSystem({
        name = "love.Present",
        phase = tecs.phases.RenderLast,
        run = function()
            if lg_isActive() then
                lg_present()
            end
        end
    })

    -- We don't want the first frame's dt to include time taken by love.load.
    world:addSystem({
        name = "love.ResetTimer",
        phase = tecs.phases.PostStartup,
        run = love.timer.step
    })

    -- Mark when entering fixed phases
    world:addSystem({
        name = "love.EnterFixedPhase",
        phase = tecs.phases.FixedFirst,
        run = function()
            input.enterFixedPhase()
        end
    })

    -- Mark exit from fixed phases and clear latched events
    world:addSystem({
        name = "love.ExitFixedPhase",
        phase = tecs.phases.FixedLast,
        run = function()
            input.exitFixedPhase()
        end
    })

    -- Still allow the use of love.update.
    if love.update then
        world:addSystem({
            name = "love.Update",
            phase = tecs.phases.Update,
            run = love.update
        })
    end
end

-------------------------------------------------------------------------------
-- tecs2d.run function implementation
-------------------------------------------------------------------------------

local function runLoop(config: tecs2d.RunConfig): (function(): number | string)
    local timestep <const> = 1 / config.fps
    local benchmarkMode <const> = os.getenv("TECS_BENCHMARK") ~= nil
    if (love.load) then
        love.load(love.arg.parseGameArguments(arg), arg)
    end

    local world <const> = tecs.newWorld({
        timestep = timestep,
        maxEntities = config.maxEntities,
    })
    world:addPlugin(gamePlugin)

    -- Auto-install render pipeline
    local renderConfig = config.render or {} as gfx.RenderConfig
    renderConfig.world = world
    local pipelineInstance = gfx.newPipeline(renderConfig)

    -- Auto-install tiled plugin
    world:addPlugin(tecs_tiled.plugin)

    -- Auto-install UI plugin (anchors, layout boxes, fit content)
    world:addPlugin(tecs_ui.plugin)

    -- Add user's game plugin last (pipeline + tiled + ui already available)
    world:addPlugin(config.game)

    local eventPoller <const> = handlers.pollEvents(world)

    -- Reset both flags at loop start so a stale value from a prior run
    -- (same process, e.g. after a restart) doesn't trigger immediate exit.
    handlers.restartRequested = false
    handlers.quitRequested = false

    world:startup()

    return function(): integer | string
        local dt = love_timer_step()
        eventPoller(dt, world)

        -- Handle restart request from event poller
        if handlers.restartRequested then
            handlers.restartRequested = false
            world:shutdown()
            return "restart"
        end

        -- Handle quit request from event poller. Checked before world:update
        -- so we exit on the same frame the quit event was polled, and so a
        -- broken update() can't prevent quit.
        if handlers.quitRequested ~= false then
            local exitCode = handlers.quitRequested as integer
            handlers.quitRequested = false
            world:shutdown()
            return exitCode
        end

        -- see https://www.gafferongames.com/post/fix_your_timestep/
        if dt > 0.25 then
            dt = 0.25
        end

        -- Apply time scale from render pipeline
        local timeScale = pipelineInstance:getTimeScale()
        local scaledDt = dt * timeScale

        -- Update game time for GPU animations
        (pipelineInstance as {string: any}).gameTime = pipelineInstance:getTime() + scaledDt

        world:update(scaledDt)

        -- Sleep 1 ms to reclaim some CPU time, but only if the game can keep up with the target FPS.
        -- Skip sleep in benchmark mode (TECS_BENCHMARK=1) for accurate FPS measurements.
        if not benchmarkMode and timestep - dt > 0 then
            love.timer.sleep(0.001)
        end
    end
end

function tecs2d.run(config: tecs2d.RunConfig): (function(): function(): number | string)
    assert(config.game, "config.game is required")
    config.fps = config.fps or 60
    assert(config.fps > 0, "config.fps must be a positive number")
    return function(): function(): number | string
        return runLoop(config)
    end
end

--- Triggers a quit event to exit the application cleanly.
function tecs2d.quit(exitCode: number)
    exitCode = exitCode or 0
    love.event.push("quit", exitCode)
end

return tecs2d
