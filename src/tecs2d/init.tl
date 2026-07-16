local events <const> = require("tecs2d.events")
local input <const> = require("tecs2d.input")
local handlers <const> = require("tecs2d.internal.handlers")
local frameclock <const> = require("tecs2d.internal.frameclock")
local crash <const> = require("tecs2d.internal.crash")
local logging <const> = require("tecs.utils.logging")
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

        --- Optional. When true, pressing Escape requests a clean quit with
        --- exit code 0.
        quitOnEscape: boolean

        --- Optional development hot-reload support.
        hotReload: HotReloadConfig
    end

    --- Creates a Love2D run function from a RunConfig table. Assign directly to `love.run`.
    --- Auto-installs tecs2d's built-in plugins before the game plugin.
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
local tecs2dExports <const> = tecs2d as {string: any}
tecs2dExports.Quit = events.Quit
tecs2dExports.KeyPressed = events.KeyPressed
tecs2dExports.KeyReleased = events.KeyReleased
tecs2dExports.MousePressed = events.MousePressed
tecs2dExports.MouseReleased = events.MouseReleased
tecs2dExports.JoystickAdded = events.JoystickAdded
tecs2dExports.JoystickRemoved = events.JoystickRemoved
tecs2dExports.DirectoryDropped = events.DirectoryDropped
tecs2dExports.FileDropped = events.FileDropped
tecs2dExports.Focus = events.Focus
tecs2dExports.MouseFocus = events.MouseFocus
tecs2dExports.Resize = events.Resize
tecs2dExports.Visible = events.Visible
tecs2dExports.Exposed = events.Exposed
tecs2dExports.Occluded = events.Occluded
tecs2dExports.LocaleChanged = events.LocaleChanged
tecs2dExports.ThemeChanged = events.ThemeChanged
tecs2dExports.DropBegan = events.DropBegan
tecs2dExports.DropMoved = events.DropMoved
tecs2dExports.DropCompleted = events.DropCompleted
tecs2dExports.AudioDisconnected = events.AudioDisconnected
tecs2dExports.SensorUpdated = events.SensorUpdated
tecs2dExports.JoystickSensorUpdated = events.JoystickSensorUpdated
tecs2dExports.TouchPressed = events.TouchPressed
tecs2dExports.TouchMoved = events.TouchMoved
tecs2dExports.TouchReleased = events.TouchReleased

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

local function installQuitOnEscape(world: tecs.World)
    world:addSystem({
        name = "love.QuitOnEscape",
        phase = tecs.phases.First,
        run = function()
            if input.isKeyPressed("escape") then
                tecs2d.quit(0)
            end
        end
    })
end

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
        local removeFile <const> = love_fs_any.remove as function(string): boolean, string
        local removeResult: {any} = {pcall(function()
            removeFile(state.snapshotPath)
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
    frameclock.nominal = timestep
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

    if config.quitOnEscape == true then
        installQuitOnEscape(world)
    end

    -- Auto-install render pipeline
    local renderConfig = config.render or {} as gfx.RenderConfig
    renderConfig.world = world
    local pipelineInstance = gfx.newPipeline(renderConfig)

    -- Random state travels with snapshots: love.math's default generator is
    -- the framework's sanctioned RNG (the conventions steer games to
    -- love.math.random), so capturing it makes hot reload, rewind, and input
    -- replay deterministic for games that use randomness. Lua's raw
    -- math.random has no readable state and stays outside this guarantee.
    world:addSnapshotHandler({
        name = "tecs2d.randomState",
        save = function(_w: tecs.World): any
            -- Guarded: test harnesses mock love without love.math.
            local lm = love.math as {string: any}
            if not (lm and lm.getRandomState) then return nil end
            return {state = (lm.getRandomState as function(): string)()}
        end,
        load = function(_w: tecs.World, value: any)
            local data = value as {string: any}
            local state = data and data.state as string
            local lm = love.math as {string: any}
            if state and lm and lm.setRandomState then
                (lm.setRandomState as function(string))(state)
            end
        end,
    })

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

        -- Apply time scale from render pipeline; a replay provider may then
        -- substitute the recorded per-frame dt (tecs2d.internal.frameclock).
        local timeScale = pipelineInstance:getTimeScale()
        local scaledDt = frameclock.apply(dt * timeScale)

        -- Update game time for GPU animations
        local pipelineAny <const> = pipelineInstance as {string: any}
        pipelineAny.gameTime = pipelineInstance:getTime() + scaledDt

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

-- Replacement for LÖVE's default error handler. The default blue screen
-- stops the world's systems dead: the MCP socket stays bound but nothing
-- serves it, so an agent's next tool call hangs. This handler logs the
-- traceback to the log ring and stderr (the bridge's game_logs captures
-- both), notifies crash observers (the MCP plugin flips into crashed mode),
-- and keeps pumping registered transports from inside the error screen so
-- tools answer "game_crashed: <traceback>" instead of timing out.
local function errorHandler(msg: string): function(): number
    local trace = debug.traceback("Error: " .. tostring(msg), 3)
    trace = trace:gsub("\n[^\n]+$", "")
    pcall(function()
        logging.getLogger("tecs2d.crash"):error("%s", trace)
    end)
    io.stderr:write(trace .. "\n")
    io.stderr:flush()
    crash.notify(trace)

    pcall(function()
        love.graphics.reset()
        love.graphics.origin()
        if love.mouse then
            love.mouse.setVisible(true)
            love.mouse.setGrabbed(false)
            love.mouse.setRelativeMode(false)
        end
        if love.window and love.window.requestAttention then
            love.window.requestAttention()
        end
    end)

    local shown = "The game crashed (the MCP server is still answering).\n\n" .. trace
    return function(): number
        love.event.pump()
        for name, a in love.event.poll() do
            if name == "quit" then
                return (tonumber(a) or 1) as number
            elseif name == "keypressed" and a == "escape" then
                return 1
            end
        end
        crash.pump()
        pcall(function()
            love.graphics.clear(0.16, 0.09, 0.09)
            love.graphics.setColor(1, 1, 1, 1)
            love.graphics.printf(shown, 24, 24, love.graphics.getWidth() - 48)
            love.graphics.present()
        end)
        if love.timer then love.timer.sleep(0.05) end
        return nil
    end
end

function tecs2d.run(config: tecs2d.RunConfig): (function(): function(): number | string)
    assert(config.game, "config.game is required")
    config.fps = config.fps or 60
    assert(config.fps > 0, "config.fps must be a positive number")
    love.errorhandler = errorHandler
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
