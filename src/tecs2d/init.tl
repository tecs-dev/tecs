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
local love_fs <const> = love.filesystem
local love_fs_any <const> = love.filesystem as {string: any}

local HOT_RELOAD_SNAPSHOT_PATH <const> = ".tecs-hot-reload.snapshot"
local HOT_RELOAD_STAMP_PATH <const> = "build/.tecs-reload-stamp"

local function captureLoadedModuleBaseline(): {string: boolean}
    local baseline: {string: boolean} = {}
    for name, _ in pairs(package.loaded) do
        baseline[name as string] = true
    end
    return baseline
end

local MODULE_BASELINE <const> = captureLoadedModuleBaseline()

local function clearModuleCache(baseline: {string: boolean})
    local toRemove: {string} = {}
    for name, _ in pairs(package.loaded) do
        local moduleName = name as string
        if not baseline[moduleName] then
            toRemove[#toRemove + 1] = moduleName
        end
    end
    for i = 1, #toRemove do
        package.loaded[toRemove[i]] = nil
    end
    LOGGER:info("Cleared %d modules from cache before restart", #toRemove)
end

--- Love2D integration module for Tecs.
--- Provides the game loop, Love2D events as ECS events, and application lifecycle.
local record tecs2d
    --- Development hot-reload configuration. When enabled, tecs2d.run polls
    --- one build stamp file and preserves ECS state across Love2D restarts
    --- through a binary world snapshot.
    record HotReloadConfig
        enabled: boolean
        snapshotPath: string
        stampPath: string
        pollInterval: number
        debounce: number
        restoreOnStartup: boolean
        deleteAfterRestore: boolean
        saveOptions: tecs.SnapshotOptions
    end

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

        --- Optional development hot-reload support.
        hotReload: HotReloadConfig
    end

    --- Creates a Love2D run function from a RunConfig table. Assign directly to `love.run`.
    --- Auto-installs the render pipeline, tiled plugin, and UI plugin before the game plugin.
    --- @param config RunConfig with fps, game plugin, and render settings.
    --- @return A function suitable for `love.run` that initializes and runs the game loop.
    run: function(config: RunConfig): (function(): function(): string | number)

    --- Triggers a quit event to exit the application cleanly.
    --- @param exitCode Optional exit code (defaults to 0 for success).
    quit: function(exitCode: number)

    --- Triggers a Love2D restart event. If hotReload is enabled on the run
    --- loop, the world is snapshotted before the restart is returned.
    restart: function()

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

local record HotReloadState
    enabled: boolean
    snapshotPath: string
    stampPath: string
    pollInterval: number
    debounce: number
    restoreOnStartup: boolean
    deleteAfterRestore: boolean
    saveOptions: tecs.SnapshotOptions
    lastStampModtime: number
    pendingStampModtime: number
    pollElapsed: number
    debounceElapsed: number
end

local function makeHotReloadState(config: tecs2d.RunConfig): HotReloadState
    local cfg = config.hotReload
    local enabled = cfg ~= nil and cfg.enabled == true
    local saveOptions: tecs.SnapshotOptions = nil
    if cfg and cfg.saveOptions then
        saveOptions = cfg.saveOptions
    else
        saveOptions = {} as tecs.SnapshotOptions
    end

    return {
        enabled = enabled,
        snapshotPath = (cfg and cfg.snapshotPath) or HOT_RELOAD_SNAPSHOT_PATH,
        stampPath = (cfg and cfg.stampPath) or HOT_RELOAD_STAMP_PATH,
        pollInterval = (cfg and cfg.pollInterval) or 0.25,
        debounce = (cfg and cfg.debounce) or 0.25,
        restoreOnStartup = cfg == nil or cfg.restoreOnStartup ~= false,
        deleteAfterRestore = cfg == nil or cfg.deleteAfterRestore ~= false,
        saveOptions = saveOptions,
        lastStampModtime = nil,
        pendingStampModtime = nil,
        pollElapsed = 0,
        debounceElapsed = 0,
    } as HotReloadState
end

local function stampModtime(path: string): number
    local info = love_fs.getInfo(path)
    if not info then return nil end
    return (info as {string: any}).modtime as number
end

local function restoreHotReloadSnapshot(world: tecs.World, state: HotReloadState)
    if not state.enabled or not state.restoreOnStartup then return end
    if not love_fs.getInfo(state.snapshotPath) then return end

    local readResult: {any} = {pcall(function(): string
        return (love_fs.read as function(string): string)(state.snapshotPath)
    end)}
    if not readResult[1] or not readResult[2] then
        LOGGER:error("Hot reload restore failed reading %s: %s", state.snapshotPath, tostring(readResult[2]))
        return
    end
    local payload = readResult[2] as string

    local loadResult: {any} = {pcall(function()
        world:loadSnapshot(payload)
    end)}
    if not loadResult[1] then
        LOGGER:error("Hot reload restore failed loading %s: %s", state.snapshotPath, tostring(loadResult[2]))
        return
    end

    LOGGER:info("Restored hot reload snapshot from %s", state.snapshotPath)
    if state.deleteAfterRestore and love_fs_any.remove then
        local removeResult: {any} = {pcall(function()
            (love_fs_any.remove as function(string): boolean, string)(state.snapshotPath)
        end)}
        if not removeResult[1] then
            LOGGER:warn("Failed to remove hot reload snapshot %s: %s", state.snapshotPath, tostring(removeResult[2]))
        end
    end
end

local function runStartup(world: tecs.World, hotReload: HotReloadState)
    world:runPhase(tecs.phases.PreStartup)
    world:runPhase(tecs.phases.Startup)
    restoreHotReloadSnapshot(world, hotReload)
    world:runPhase(tecs.phases.PostStartup)
end

local function saveHotReloadSnapshot(world: tecs.World, state: HotReloadState): boolean
    if not state.enabled then return true end
    if state.saveOptions and state.saveOptions.format == "table" then
        LOGGER:error("Hot reload snapshots must use binary format; got format=table")
        return false
    end

    local result: {any} = {pcall(function()
        local out = world:saveSnapshot(state.saveOptions)
        local buf = out.buffer
        if not buf then
            error("saveSnapshot returned no binary buffer")
        end
        local writeOk, writeErr = (love_fs_any.write as function(string, string): boolean, string)(state.snapshotPath, tostring(buf))
        if writeOk == false then
            error(tostring(writeErr))
        end
    end)}
    if not result[1] then
        LOGGER:error("Hot reload snapshot save failed: %s", tostring(result[2]))
        return false
    end
    LOGGER:info("Saved hot reload snapshot to %s", state.snapshotPath)
    return true
end

local function updateHotReloadWatcher(state: HotReloadState, dt: number): boolean
    state.pollElapsed = state.pollElapsed + dt
    if state.pollElapsed >= state.pollInterval then
        state.pollElapsed = 0
        local modtime = stampModtime(state.stampPath)
        if modtime ~= state.lastStampModtime then
            state.lastStampModtime = modtime
            if modtime ~= nil then
                state.pendingStampModtime = modtime
                state.debounceElapsed = 0
            end
        end
    end

    if state.pendingStampModtime ~= nil then
        state.debounceElapsed = state.debounceElapsed + dt
        if state.debounceElapsed >= state.debounce then
            state.pendingStampModtime = nil
            state.debounceElapsed = 0
            return true
        end
    end
    return false
end

local function requestRestart(world: tecs.World, hotReload: HotReloadState, moduleBaseline: {string: boolean}): boolean
    if not saveHotReloadSnapshot(world, hotReload) then
        return false
    else
        world:shutdown()
        clearModuleCache(moduleBaseline)
        return true
    end
end

local function runLoop(config: tecs2d.RunConfig): (function(): number | string)
    local timestep <const> = 1 / config.fps
    local benchmarkMode <const> = os.getenv("TECS_BENCHMARK") ~= nil
    local hotReload <const> = makeHotReloadState(config)
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

    hotReload.lastStampModtime = stampModtime(hotReload.stampPath)
    runStartup(world, hotReload)

    return function(): integer | string
        local dt = love_timer_step()
        eventPoller(dt, world)

        -- Handle restart request from event poller
        if handlers.restartRequested then
            handlers.restartRequested = false
            if requestRestart(world, hotReload, MODULE_BASELINE) then
                return "restart"
            end
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

        if hotReload.enabled and updateHotReloadWatcher(hotReload, dt) then
            LOGGER:info("Hot reload stamp changed: %s", hotReload.stampPath)
            if requestRestart(world, hotReload, MODULE_BASELINE) then
                return "restart"
            end
        end

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

--- Triggers a restart event to reload the application.
function tecs2d.restart()
    love.event.quit("restart")
end

return tecs2d
