local tecs <const> = require("tecs")
local assets <const> = require("tecs2d.assets")
local gfx <const> = require("tecs2d.gfx")
local input <const> = require("tecs2d.input")
local suspension <const> = require("tecs2d.suspension")
local ui <const> = require("tecs2d.ui")

local Transform <const> = tecs.builtins.Transform
local FONT <const> = "assets/press-start-2p.fnt"
local FIXTURE_COUNT <const> = 128
local MINIMUM_DISPLAY_SECONDS <const> = 1.0
local HOLDER <const> = "assets.loading"

local record LoadingScreenPlugin
    world: tecs.World
    batch: assets.LoadBatch
    loadingWorld: tecs.World
    pipeline: gfx.Pipeline
    active: boolean
    startedAt: number
    lastTime: number
    progressBarId: integer
    countTextId: integer
    statusTextId: integer

    init: function(self, world: tecs.World)
    start: function(self)
    stop: function(self)
    createFixtures: function(self)
    createBatch: function(self): assets.LoadBatch
    createWorld: function(self)
    updateAndComposite: function(self)
end

local record loading
    KEY: tecs.Key<LoadingScreenPlugin>
    plugin: function(): tecs.Plugin
end

loading.KEY = tecs.newKey("assets.loadingScreen")

local function spawnText(
    world: tecs.World,
    anchorY: number,
    offsetY: number,
    text: string,
    scale: number,
    color: gfx.Color
): integer
    return world:spawn(
        Transform(0, 0, 10),
        ui.Anchor(0.5, anchorY, 0, offsetY),
        gfx.Text(FONT, text, scale),
        ui.LayoutBox(gfx.Text),
        color
    )
end

function LoadingScreenPlugin.new(): LoadingScreenPlugin
    return setmetatable({active = false}, {__index = LoadingScreenPlugin})
end

function LoadingScreenPlugin:createFixtures()
    love.filesystem.createDirectory("assets")
    local payload = string.rep("Tecs async loading fixture: 0123456789abcdef\n", 1536)
    for i = 1, FIXTURE_COUNT do
        local path = string.format("assets/loading_fixture_%03d.txt", i)
        if not love.filesystem.getInfo(path) then
            assert(love.filesystem.write(path, string.format("fixture %d\n", i) .. payload))
        end
    end

    local messages = {
        "The gameplay world needed no loading predicate.",
        "Its update phases paused while rendering continued.",
        "A separate ECS world owned this loading interface.",
        "Both pipelines shared immutable GPU resources.",
        "A LoadBatch reported progress for this operation.",
    }
    for i = 1, #messages do
        local path = string.format("assets/message%d.txt", i)
        if not love.filesystem.getInfo(path) then
            assert(love.filesystem.write(path, messages[i]))
        end
    end
end

function LoadingScreenPlugin:createBatch(): assets.LoadBatch
    local batch = assets.newBatch()
    for i = 1, FIXTURE_COUNT do
        batch:track(assets.loadFile(string.format("loading_fixture_%03d.txt", i)))
    end
    for i = 1, 5 do
        local handle = batch:track(assets.loadFile(string.format("message%d.txt", i)))
        assets.pin(handle)
    end
    assets.pin(batch:track(assets.loadImage("running.png")))
    assets.pin(batch:track(assets.loadJson("running.json")))
    assets.pin(batch:track(assets.loadBMFont("press-start-2p.fnt")))
    batch:seal()
    return batch
end

function LoadingScreenPlugin:createWorld()
    local gamePipeline = assert(self.world.resources[gfx.PIPELINE], "loading screen requires a render pipeline")
    local loadingWorld = tecs.newWorld({maxEntities = 64})
    local pipeline = gfx.newPipeline({
        world = loadingWorld,
        sharedWith = gamePipeline,
        lightingMode = "none",
        lerpingEnabled = false,
        layers = {[1] = {name = "loading", space = "screen", unlit = true}},
        sizeHints = {rects = 4, textEntities = 8, textGlyphs = 512},
    })
    loadingWorld:addPlugin(ui.plugin)

    loadingWorld:spawn(
        Transform(0, 0, 0),
        ui.Anchor(0.5, 0.5),
        gfx.Rectangle(800, 600),
        gfx.Color(0.035, 0.045, 0.08, 0.97)
    )
    spawnText(loadingWorld, 0.5, -105, "LOADING ASSETS", 1.25, gfx.Color(0.85, 0.9, 1))
    loadingWorld:spawn(
        Transform(0, 0, 5),
        ui.Anchor(0.5, 0.5, 0, -15),
        gfx.Rectangle(440, 34),
        gfx.Color(0.12, 0.14, 0.22)
    )
    self.progressBarId = loadingWorld:spawn(
        Transform(0, 0, 6),
        ui.Anchor(0.5, 0.5, -220, -15),
        gfx.Pivot(0, 0.5),
        gfx.Rectangle(0, 26),
        gfx.Color(0.24, 0.58, 0.95)
    )
    self.countTextId = spawnText(loadingWorld, 0.5, 35, "0%", 0.7, gfx.Color(0.72, 0.76, 0.86))
    self.statusTextId = spawnText(loadingWorld, 0.5, 82, "Starting workers...", 0.62, gfx.Color(0.52, 0.58, 0.7))

    local plugin = self
    loadingWorld:addSystem({
        name = "assets.LoadingUiUpdate",
        phase = tecs.phases.Update,
        run = function()
            local batch = plugin.batch
            local bar = loadingWorld:getMut(plugin.progressBarId, gfx.Rectangle)
            if bar then bar.width = 440 * batch.progress end

            local count = loadingWorld:get(plugin.countTextId, gfx.Text)
            if count then
                count:setText(string.format("%d%%  %d/%d", math.floor(batch.progress * 100),
                    batch.completedCount, batch.totalCount))
            end

            local status = loadingWorld:get(plugin.statusTextId, gfx.Text)
            if status then
                if batch.isComplete and not batch.isSuccessful then
                    status:setText(string.format("%d failed - press ENTER to retry", batch.failedCount))
                elseif batch.isComplete then
                    status:setText("Complete - resuming gameplay")
                else
                    local dots = string.rep(".", math.floor(love.timer.getTime() * 3) % 4)
                    status:setText("Loading on worker threads" .. dots)
                end
            end
        end,
    })

    loadingWorld:startup()
    self.loadingWorld = loadingWorld
    self.pipeline = pipeline
end

function LoadingScreenPlugin:start()
    if self.active then return end
    self:createFixtures()
    self.batch = self:createBatch()
    self.startedAt = love.timer.getTime()
    self.lastTime = self.startedAt
    self.active = true
    suspension.suspend(self.world, HOLDER)
    self:createWorld()
end

function LoadingScreenPlugin:stop()
    if not self.active then return end
    self.active = false
    if self.loadingWorld then
        self.loadingWorld:shutdown()
    end
    self.loadingWorld = nil
    self.pipeline = nil
    self.batch = nil
    suspension.resume(self.world, HOLDER)
end

function LoadingScreenPlugin:updateAndComposite()
    if not self.active then return end
    local now = love.timer.getTime()
    local dt = math.min(now - self.lastTime, 0.25)
    self.lastTime = now
    self.loadingWorld:update(dt)
    self.pipeline:render()

    if self.batch.isComplete and not self.batch.isSuccessful and input.isKeyPressed("return") then
        self.batch = self:createBatch()
        self.startedAt = now
    elseif self.batch.isComplete and self.batch.isSuccessful
        and now - self.startedAt >= MINIMUM_DISPLAY_SECONDS then
        self:stop()
    end
end

function LoadingScreenPlugin:init(world: tecs.World)
    self.world = world
    world.resources[loading.KEY] = self

    world:addSystem({
        name = "assets.CompositeLoadingWorld",
        phase = tecs.phases.RenderLast,
        before = {"love.Present"},
        run = function() self:updateAndComposite() end,
    })
    world:addSystem({
        name = "assets.ShutdownLoadingWorld",
        phase = tecs.phases.PreShutdown,
        run = function() self:stop() end,
    })
    self:start()
end

function loading.plugin(): tecs.Plugin
    return function(world: tecs.World)
        LoadingScreenPlugin.new():init(world)
    end
end

return loading
