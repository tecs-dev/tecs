--- Owns the debugger's isolated ECS world and composited render pipeline.

local tecs <const> = require("tecs")
local events <const> = require("tecs2d.events")
local gfx <const> = require("tecs2d.gfx")
local tween <const> = require("tecs2d.tween")
local ui <const> = require("tecs2d.ui")
local debugdraw <const> = require("tecs2d.debug.internal.debugdraw")
local toolworldkey <const> = require("tecs2d.debug.internal.toolworldkey")

local record State
    world: tecs.World
    pipeline: gfx.Pipeline
    view: debugdraw.View
    cursorAlphaEntity: integer
    lastTime: number
end

local record toolworld
    KEY: tecs.Key<toolworldkey.State>
    install: function(world: tecs.World, uiHeight: number)
end

toolworld.KEY = toolworldkey.KEY

function toolworld.install(world: tecs.World, uiHeight: number)
    assert(uiHeight > 0, "debug uiHeight must be greater than zero")
    debugdraw.setScreenScale(math.max(1, love.graphics.getHeight() / uiHeight))
    assert(world.resources[gfx.PIPELINE], "debug plugin requires a render pipeline")
    local tools = tecs.newWorld({maxEntities = 4096})
    local pipeline = gfx.newPipeline({
        world = tools,
        composite = true,
        lightingMode = "none",
        lerpingEnabled = false,
        layers = {[1] = {name = "debug", space = "screen", unlit = true, sortMode = "z"}},
        sizeHints = {sprites = 8, circles = 32, lines = 128, rects = 256, textEntities = 256, textGlyphs = 8192},
    })
    tools:addPlugin(ui.new({origin = "topLeft"}))
    tools:addPlugin(tween.plugin)
    local cursorAlphaEntity = tools:spawn(gfx.Color(1, 1, 1, 1))
    local cursorAlpha = tween.field(gfx.Color, "a")
    tween.timeline({
        channel = "debug.cursor",
        tween.wait(0.8),
        tween.to(0.06, tween.sineIn, cursorAlpha, 0),
        tween.wait(0.1),
        tween.to(0.06, tween.sineOut, cursorAlpha, 1),
    }):play(tools, cursorAlphaEntity, {mode = "loop"})
    local state: State = {
        world = tools,
        pipeline = pipeline,
        view = debugdraw.newView(tools),
        cursorAlphaEntity = cursorAlphaEntity,
        lastTime = love.timer.getTime(),
    }
    world.resources[toolworldkey.KEY] = (state as any) as toolworldkey.State

    -- Resize events belong to the game world. Forward them to the isolated
    -- tools pipeline so its composite canvas continues to cover the window.
    world:observe(0, events.Resize, function(e: events.Resize)
        state.pipeline:setScreenSize(e.width, e.height)
        debugdraw.setScreenScale(math.max(1, e.height / uiHeight))
    end)

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
            debugdraw.drawBatches(state.view)
            if debugdraw.hasRetainedDraws(state.view) then
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
