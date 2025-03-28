local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local assets <const> = require("tecs_assets")
local GameState <const> = require("game_state")

local lg <const> = love.graphics
local LOGGER <const> = tecs.logging.getLogger("assets-example")

local NUM_TEMP_FILES <const> = 10000
local LINES_PER_FILE <const> = 2000

local record LoadingScreenPlugin
    world: tecs.World
    manager: assets.AssetManager
    loadingFont: love.graphics.Font
    startTime: number
    loadCompleteTime: number
    isLoadingComplete: boolean
    hasStartedLoading: boolean

    init: function(self, world: tecs.World)
    render: function(self)
    generateTempAssets: function(self)
    startLoading: function(self)
    cleanupTempAssets: function(self)
end

function LoadingScreenPlugin.new(): LoadingScreenPlugin
    return setmetatable({}, {__index = LoadingScreenPlugin})
end

function LoadingScreenPlugin:init(world: tecs.World)
    self.world = world
    self.manager = world.resources[assets.MANAGER]
    self.loadingFont = lg.newFont(24)
    self.startTime = love.timer.getTime()

    -- Generate temporary asset files
    self:generateTempAssets()

    world:setState(GameState, "loading")

    local input = tecs2d.input

    -- Add system to check for loading completion and handle escape
    world:addSystem({
        name = "LoadingScreenUpdate",
        phase = tecs.phases.Update,
        runIf = function(): boolean
            return world:inState(GameState, "loading")
        end,
        run = function()
            -- Check if escape is pressed
            if input.isKeyReleased("escape") then
                tecs2d.quit(0)
                return
            end

            -- Start loading after first frame
            if not self.hasStartedLoading then
                self.hasStartedLoading = true
                self:startLoading()
            end

            -- Check if loading is complete
            if self.hasStartedLoading and not self.isLoadingComplete and not self.manager:isLoading() then
                self.isLoadingComplete = true
                self.loadCompleteTime = love.timer.getTime()
                LOGGER:info("Assets loaded!")
            end

            -- Transition to playing after showing complete message
            if self.isLoadingComplete then
                local elapsed = love.timer.getTime() - self.loadCompleteTime
                if elapsed > 2.0 then  -- Wait 2 seconds after loading completes
                    self.isLoadingComplete = false  -- Reset for next time
                    self.hasStartedLoading = false  -- Reset for reload
                    world:setState(GameState, "playing")
                end
            end
        end
    })

    world:addSystem({
        name = "LoadingScreenRender",
        phase = tecs.phases.Render,
        runIf = function(): boolean
            return world:inState(GameState, "loading")
        end,
        run = function()
            self:render()
        end
    })
end

function LoadingScreenPlugin:render()
    local width, height = lg.getWidth(), lg.getHeight()

    lg.setColor(0.05, 0.05, 0.1, 1)
    lg.rectangle("fill", 0, 0, width, height)

    local stats = self.manager:getStats()
    local total = stats.completedCount + stats.runningCount
    local progress = total == 0 and 0 or (stats.completedCount / total)

    lg.setFont(self.loadingFont)
    lg.setColor(0.9, 0.9, 0.9, 1)
    local title = "Loading Assets..."
    local titleWidth = self.loadingFont:getWidth(title)
    lg.print(title, width / 2 - titleWidth / 2, height / 2 - 80)

    local barWidth = 400
    local barHeight = 30
    local barX = width / 2 - barWidth / 2
    local barY = height / 2 - barHeight / 2

    lg.setColor(0.2, 0.2, 0.3, 1)
    lg.rectangle("fill", barX, barY, barWidth, barHeight)

    lg.setColor(0.1, 0.1, 0.2, 1)
    lg.setLineWidth(2)
    lg.rectangle("line", barX, barY, barWidth, barHeight)

    if progress > 0 then
        -- Draw progress bar with gradient effect
        lg.setColor(0.2, 0.5, 0.9, 1)
        lg.rectangle("fill", barX, barY, barWidth * progress, barHeight)
    end

    lg.setColor(0.7, 0.7, 0.7, 1)
    lg.setFont(lg.newFont(16))
    local percentText = string.format("%d%% (%d/%d)", math.floor(progress * 100), stats.completedCount, total)
    local percentWidth = lg.getFont():getWidth(percentText)
    lg.print(percentText, width / 2 - percentWidth / 2, barY + barHeight + 20)

    -- Show additional stats
    lg.setColor(0.5, 0.5, 0.5, 1)
    lg.setFont(lg.newFont(12))
    local cacheText = string.format("Cached: %d | Pinned: %d", stats.currentAssetCount, stats.pinnedAssetCount)
    local cacheWidth = lg.getFont():getWidth(cacheText)
    lg.print(cacheText, width / 2 - cacheWidth / 2, barY + barHeight + 45)

    -- Show different status based on loading state
    if self.isLoadingComplete then
        -- Show completion message
        lg.setColor(0.2, 0.9, 0.2, 1)
        lg.setFont(lg.newFont(24))
        local completeText = "Complete!"
        local completeWidth = lg.getFont():getWidth(completeText)
        lg.print(completeText, width / 2 - completeWidth / 2, barY + barHeight + 70)

        lg.setColor(0.6, 0.6, 0.6, 1)
        lg.setFont(lg.newFont(14))
        local transitionText = "Starting game..."
        local transitionWidth = lg.getFont():getWidth(transitionText)
        lg.print(transitionText, width / 2 - transitionWidth / 2, barY + barHeight + 105)
    else
        -- Show loading animation
        local elapsed = love.timer.getTime() - self.startTime
        local dots = string.rep(".", math.floor(elapsed * 2) % 4)
        lg.setColor(0.5, 0.5, 0.5, 1)
        lg.setFont(lg.newFont(14))
        local statusText = "Please wait" .. dots
        local statusWidth = lg.getFont():getWidth(statusText)
        lg.print(statusText, width / 2 - statusWidth / 2, barY + barHeight + 70)
    end
end

function LoadingScreenPlugin:generateTempAssets()
    -- Create assets directory if it doesn't exist
    -- Note: Files are written to Love2D's save directory (not the game directory)
    love.filesystem.createDirectory("assets")

    -- Log where files are being written
    local saveDir = love.filesystem.getSaveDirectory()
    LOGGER:info("Writing demo files to: %s/assets/", saveDir)

    -- Clean up any existing temp files from previous runs
    local existingFiles = love.filesystem.getDirectoryItems("assets")
    local cleanedCount = 0
    for _, file in ipairs(existingFiles) do
        if file:match("^temp_%d+%.txt$") or file:match("^message%d+%.txt$") then
            love.filesystem.remove("assets/" .. file)
            cleanedCount = cleanedCount + 1
        end
    end
    if cleanedCount > 0 then
        LOGGER:info("Cleaned up %d files from previous run", cleanedCount)
    end

    -- Generate many small files to demonstrate loading
    local messages = {
        "Welcome to the Stagecoach Asset Loading Demo!",
        "This demonstrates non-blocking asset loading with progress tracking.",
        "Assets are loaded in background threads without freezing the game!",
        "Loading is artificially slowed to demonstrate the progress bar.",
        "Stagecoach uses worker threads for true async loading!"
    }

    -- Pre-generate the padding content once for efficiency
    local paddingContent = ""
    for j = 1, LINES_PER_FILE do
        paddingContent = paddingContent .. string.format("Line %d: Additional content to make the file larger and slower to load.\n", j)
    end

    -- Generate temp files for visible loading
    for i = 1, NUM_TEMP_FILES do
        local filename = string.format("assets/temp_%04d.txt", i)
        local header = string.format("File %d: %s\n", i, messages[(i - 1) % #messages + 1])
        local content = header .. paddingContent
        love.filesystem.write(filename, content)
    end

    -- Also create the main message files for gameplay
    for i, msg in ipairs(messages) do
        love.filesystem.write(string.format("assets/message%d.txt", i), msg)
    end
end

function LoadingScreenPlugin:startLoading()
    -- Load all the generated temp files
    for i = 1, NUM_TEMP_FILES do
        local filename = string.format("temp_%04d.txt", i)
        self.manager:loadFile(filename)
    end

    -- Load the main message files
    for i = 1, 5 do
        self.manager:loadFile(string.format("message%d.txt", i)):pin()
    end
end

function LoadingScreenPlugin:cleanupTempAssets()
    LOGGER:info("Cleaning up demo files on exit...")
    local cleanedCount = 0

    -- Clean up temp files
    for i = 1, NUM_TEMP_FILES do
        local filename = string.format("assets/temp_%04d.txt", i)
        if love.filesystem.remove(filename) then
            cleanedCount = cleanedCount + 1
        end
    end

    -- Clean up message files
    for i = 1, 5 do
        local filename = string.format("assets/message%d.txt", i)
        if love.filesystem.remove(filename) then
            cleanedCount = cleanedCount + 1
        end
    end

    LOGGER:info("Cleaned up %d demo files", cleanedCount)
end

function LoadingScreenPlugin.plugin(): tecs.Plugin
    return function(world: tecs.World)
        local plugin = LoadingScreenPlugin.new()
        plugin:init(world)

        -- Hook cleanup to Love2D's quit event
        local originalQuit = love.quit
        love.quit = function(): boolean
            plugin:cleanupTempAssets()
            if originalQuit then
                return originalQuit()
            end
            return false
        end
    end
end

return LoadingScreenPlugin