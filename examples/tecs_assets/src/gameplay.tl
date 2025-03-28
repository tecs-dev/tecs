local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local assets <const> = require("tecs_assets")
local GameState <const> = require("game_state")

local lg <const> = love.graphics

local record GameplayPlugin
    world: tecs.World
    manager: assets.AssetManager
    messages: {string}
    titleFont: love.graphics.Font
    messageFont: love.graphics.Font

    init: function(self, world: tecs.World)
    update: function(self)
    render: function(self)
end

function GameplayPlugin.new(): GameplayPlugin
    return setmetatable({
        messages = {}
    }, {__index = GameplayPlugin})
end

function GameplayPlugin:init(world: tecs.World)
    self.world = world
    self.manager = world.resources[assets.MANAGER]

    local input = tecs2d.input

    world:addSystem({
        name = "GameplayUpdate",
        phase = tecs.phases.Update,
        runIf = function(): boolean
            return world:inState(GameState, "playing")
        end,
        run = function()
            self:update()
            if input.isKeyReleased("escape") then
                tecs2d.quit(0)
            elseif input.isKeyReleased("return") then
                self.messages = {}
                -- Force garbage collection to free memory
                collectgarbage("collect")
                collectgarbage("collect")
                world:setState(GameState, "loading")
            end
        end
    })

    world:addSystem({
        name = "GameplayRender",
        phase = tecs.phases.Render,
        runIf = function(): boolean
            return world:inState(GameState, "playing")
        end,
        run = function()
            self:render()
        end
    })
end

function GameplayPlugin:update()
    if #self.messages == 0 then
        self.titleFont = lg.newFont(32)
        self.messageFont = lg.newFont(20)

        -- Load the generated message files
        for i = 1, 5 do
            local handle = self.manager:loadFile(string.format("message%d.txt", i))
            local success, value = pcall(function(): string
                return handle.value as string
            end)
            if success and value then
                table.insert(self.messages, value)
            end
        end
    end
end

function GameplayPlugin:render()
    local width, height = lg.getWidth(), lg.getHeight()

    lg.setColor(0.1, 0.1, 0.15, 1)
    lg.rectangle("fill", 0, 0, width, height)

    lg.setFont(self.titleFont or lg.newFont(32))
    lg.setColor(0.2, 0.8, 0.2, 1)
    local title = "Now Playing..."
    local titleWidth = lg.getFont():getWidth(title)
    lg.print(title, width / 2 - titleWidth / 2, 50)

    lg.setFont(lg.newFont(16))
    lg.setColor(0.6, 0.6, 0.6, 1)
    local instruction = "Press ENTER to reload assets | Press ESC to quit"
    local instructionWidth = lg.getFont():getWidth(instruction)
    lg.print(instruction, width / 2 - instructionWidth / 2, 106)

    if #self.messages > 0 then
        lg.setColor(0.15, 0.15, 0.2, 1)
        lg.rectangle("fill", 50, 150, width - 100, height - 200, 10, 10)

        lg.setColor(0.2, 0.2, 0.3, 1)
        lg.setLineWidth(2)
        lg.rectangle("line", 50, 150, width - 100, height - 200, 10, 10)

        lg.setFont(self.messageFont or lg.newFont(20))
        lg.setColor(0.9, 0.9, 0.9, 1)
        lg.print("Loaded Messages:", 80, 180)

        lg.setFont(lg.newFont(16))
        lg.setColor(0.7, 0.7, 0.8, 1)
        local y = 240
        for i, message in ipairs(self.messages) do
            lg.print(string.format("%d. %s", i, message), 100, y)
            y = y + 30
        end

        -- Show asset stats with heading
        local stats = self.manager:getStats()

        lg.setFont(self.messageFont or lg.newFont(20))
        lg.setColor(0.9, 0.9, 0.9, 1)
        lg.print("AssetManager Stats:", 80, height - 180)

        lg.setFont(lg.newFont(16))
        lg.setColor(0.7, 0.7, 0.8, 1)
        local statsText = string.format("Completed: %d | Running: %d | Cached: %d | Pinned: %d",
            stats.completedCount, stats.runningCount, stats.currentAssetCount, stats.pinnedAssetCount)
        lg.print(statsText, 100, height - 130)

        lg.setColor(0.5, 0.5, 0.5, 1)
        lg.setFont(lg.newFont(14))
        local time = string.format("Time: %.2f seconds", love.timer.getTime())
        lg.print(time, width - 200, height - 35)
    else
        lg.setColor(0.5, 0.5, 0.5, 1)
        lg.setFont(lg.newFont(18))
        local noContent = "No content loaded yet..."
        local noContentWidth = lg.getFont():getWidth(noContent)
        lg.print(noContent, width / 2 - noContentWidth / 2, height / 2)
    end
end

function GameplayPlugin.plugin(): tecs.Plugin
    return function(world: tecs.World)
        local plugin = GameplayPlugin.new()
        plugin:init(world)
    end
end

return GameplayPlugin