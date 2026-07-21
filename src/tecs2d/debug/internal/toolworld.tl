--- Owns the debugger's isolated ECS world and composited render pipeline.

local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")
local ui <const> = require("tecs2d.ui")
local debugdraw <const> = require("tecs2d.debug.internal.debugdraw")

local KEY: tecs.Key<State> = tecs.newKey("tecs2d.debug.toolWorld")

local record State
    world: tecs.World
    pipeline: gfx.Pipeline
    view: debugdraw.View
    lastTime: number
end

local record toolworld
    KEY: tecs.Key<State>
    install: function(world: tecs.World)
end

toolworld.KEY = KEY

function toolworld.install(world: tecs.World)
    local primary = assert(world.resources[gfx.PIPELINE], "debug plugin requires a render pipeline")
    local tools = tecs.newWorld({maxEntities = 4096})
    local pipeline = gfx.newPipeline({
        world = tools,
        sharedWith = primary,
        lightingMode = "none",
        lerpingEnabled = false,
        layers = {[1] = {name = "debug", space = "screen", unlit = true}},
        sizeHints = {sprites = 8, circles = 32, lines = 128, rects = 256, textEntities = 256, textGlyphs = 8192},
    })
    tools:addPlugin(ui.plugin)
    local state: State = {
        world = tools,
        pipeline = pipeline,
        view = debugdraw.newView(tools),
        lastTime = love.timer.getTime(),
    }
    world.resources[KEY] = state

    world:addSystem({
        name = "debug.DrawBegin",
        phase = tecs.phases.RenderLast,
        before = {"debug.RecordingIndicator", "debug.Overlay", "debug.StatsRender"},
        run = function()
            debugdraw.beginFrame(state.view)
        end,
    })
    world:addSystem({
        name = "debug.DrawComposite",
        phase = tecs.phases.RenderLast,
        after = {"debug.RecordingIndicator", "debug.Overlay", "debug.StatsRender"},
        before = {"love.Present"},
        run = function()
            debugdraw.endFrame()
            local now = love.timer.getTime()
            local dt = now - state.lastTime
            state.lastTime = now
            state.world:update(dt)
            if #state.view.entities > 0 then
                state.pipeline:render()
            end
        end,
    })
    world:addSystem({
        name = "debug.ToolWorldStartup",
        phase = tecs.phases.PostStartup,
        run = function() state.world:startup() end,
    })
    world:addSystem({
        name = "debug.ToolWorldShutdown",
        phase = tecs.phases.PreShutdown,
        run = function() state.world:shutdown() end,
    })
end

return toolworld
