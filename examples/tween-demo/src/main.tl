--- Tween Demo
--- Interactive demo: left/right to select easing, hotkeys to trigger tweens

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local input <const> = require("tecs2d.input")
local mcp <const> = require("tecs2d.mcp")
local tween <const> = require("tecs2d.tween")

local Transform <const> = tecs.builtins.Transform
local Text <const> = gfx.Text

local FONT <const> = "assets/press-start-2p.fnt"
local HUD_LAYER <const> = 4
local VIRTUAL_H <const> = 400

-- Virtual layer uses top-left origin: (0,0) is top-left, (vw, VIRTUAL_H) is bottom-right

-------------------------------------------------------------------------------
-- Easing menu
-------------------------------------------------------------------------------

local record EasingEntry
    name: string
    fn: function(t: number): number
end

local EASINGS: {EasingEntry} = {
    { name = "linear",      fn = tween.linear },
    { name = "quadIn",      fn = tween.quadIn },
    { name = "quadOut",     fn = tween.quadOut },
    { name = "quadInOut",   fn = tween.quadInOut },
    { name = "cubicIn",     fn = tween.cubicIn },
    { name = "cubicOut",    fn = tween.cubicOut },
    { name = "cubicInOut",  fn = tween.cubicInOut },
    { name = "sineInOut",   fn = tween.sineInOut },
    { name = "expoOut",     fn = tween.expoOut },
    { name = "backOut",     fn = tween.backOut },
    { name = "elasticOut",  fn = tween.elasticOut },
    { name = "bounceOut",   fn = tween.bounceOut },
}

local function tweenDemoPlugin(world: tecs.World)
    world:addPlugin(mcp.new())
    world:addPlugin(require("tecs2d.debug").new())

    -- Background
    world:spawn(
        Transform(0, 0, -10, 1, 0, 1, 1),
        gfx.Rectangle(2000, 2000),
        gfx.Color(0.08, 0.08, 0.12, 1)
    )

    ---------------------------------------------------------------------------
    -- Target shape (the thing being tweened)
    ---------------------------------------------------------------------------
    local target <const> = world:spawn(
        Transform(0, -40, 0, 1, 0, 1, 1),
        gfx.Rectangle(60, 60),
        gfx.Color(0.3, 0.6, 1.0, 1)
    )

    ---------------------------------------------------------------------------
    -- State
    ---------------------------------------------------------------------------
    local selectedEasing = 1

    ---------------------------------------------------------------------------
    -- HUD: easing selector and hotkeys at bottom of screen
    -- Virtual layer: (0,0) = top-left, (vw, VIRTUAL_H) = bottom-right
    ---------------------------------------------------------------------------
    local sw <const> = love.graphics.getWidth() as number
    local sh <const> = love.graphics.getHeight() as number
    local vw <const> = VIRTUAL_H * sw / sh
    local cx <const> = vw / 2

    local easingLabel <const> = world:spawn(
        Transform(cx, VIRTUAL_H - 80, 0, HUD_LAYER, 0, 1, 1),
        Text(FONT, "<  " .. EASINGS[selectedEasing].name .. "  >", 0.7),
        gfx.Color(1, 0.9, 0.3, 1),
        gfx.Pivot(0.5, 0.5)
    )

    world:spawn(
        Transform(cx, VIRTUAL_H - 41, 0, HUD_LAYER, 0, 1, 1),
        Text(FONT, "(M)ove  (R)ot  (C)olor  (P)ulse  (B)ounce", 0.45),
        gfx.Color(0.7, 0.7, 0.7, 1),
        gfx.Pivot(0.5, 0.5)
    )

    world:spawn(
        Transform(cx, VIRTUAL_H - 15, 0, HUD_LAYER, 0, 1, 1),
        Text(FONT, "(1) orbit    (2) reset", 0.45),
        gfx.Color(0.7, 0.7, 0.7, 1),
        gfx.Pivot(0.5, 0.5)
    )

    ---------------------------------------------------------------------------
    -- Helpers
    ---------------------------------------------------------------------------
    local function getEasing(): function(t: number): number
        return EASINGS[selectedEasing].fn
    end

    local lastAction: function() = nil

    local function playTween(def: tween.Timeline, options?: tween.PlaybackOptions)
        tween.cancel(world, target, "demo")
        def:play(world, target, options)
    end

    local function updateLabel()
        local text = world:get(easingLabel, Text)
        if text then
            text:setText("<  " .. EASINGS[selectedEasing].name .. "  >")
        end
        -- Re-trigger current tween with new easing
        if lastAction then
            lastAction()
        end
    end

    ---------------------------------------------------------------------------
    -- Input system
    ---------------------------------------------------------------------------
    world:addSystem({
        name = "TweenInput",
        phase = tecs.phases.PreUpdate,
        run = function()
            -- Easing selection
            if input.isKeyPressed("left") then
                selectedEasing = selectedEasing - 1
                if selectedEasing < 1 then selectedEasing = #EASINGS end
                updateLabel()
            end
            if input.isKeyPressed("right") then
                selectedEasing = selectedEasing + 1
                if selectedEasing > #EASINGS then selectedEasing = 1 end
                updateLabel()
            end

            -- Helper to reset target to base state before re-triggering
            local function resetTarget()
                local t = world:get(target, Transform)
                t.x = 0; t.y = -40; t.rotation = 0; t.scaleX = 1; t.scaleY = 1
                world:markComponentDirty(target, Transform)
                local col = world:get(target, gfx.Color)
                if col then
                    col.r = 0.3; col.g = 0.6; col.b = 1.0; col.a = 1
                    world:markComponentDirty(target, gfx.Color as tecs.Component)
                end
            end

            local function doMove()
                resetTarget()
                playTween(tween.timeline({
                    channel = "demo",
                    tween.to(0.7, getEasing(), tween.translateX, 250),
                    tween.to(1.0, getEasing(), tween.translateX, -250),
                    tween.to(0.7, getEasing(), tween.translateX, 0),
                }))
            end

            local function doRotate()
                resetTarget()
                playTween(tween.timeline({
                    channel = "demo",
                    tween.to(1.5, getEasing(), tween.rotation, math.pi * 2),
                }))
            end

            local function doColor()
                resetTarget()
                local Color <const> = gfx.Color
                playTween(tween.timeline({
                    channel = "demo",
                    tween.parallel(
                        tween.to(0.6, getEasing(), tween.field(Color, "r"), 1.0),
                        tween.to(0.6, getEasing(), tween.field(Color, "g"), 0.2),
                        tween.to(0.6, getEasing(), tween.field(Color, "b"), 0.3)),
                    tween.parallel(
                        tween.to(0.6, getEasing(), tween.field(Color, "r"), 0.2),
                        tween.to(0.6, getEasing(), tween.field(Color, "g"), 1.0),
                        tween.to(0.6, getEasing(), tween.field(Color, "b"), 0.4)),
                    tween.parallel(
                        tween.to(0.6, getEasing(), tween.field(Color, "r"), 1.0),
                        tween.to(0.6, getEasing(), tween.field(Color, "g"), 0.9),
                        tween.to(0.6, getEasing(), tween.field(Color, "b"), 0.2)),
                    tween.parallel(
                        tween.to(0.6, getEasing(), tween.field(Color, "r"), 0.3),
                        tween.to(0.6, getEasing(), tween.field(Color, "g"), 0.6),
                        tween.to(0.6, getEasing(), tween.field(Color, "b"), 1.0)),
                }))
            end

            local function doPulse()
                resetTarget()
                playTween(tween.timeline({
                    channel = "demo",
                    tween.parallel(
                        tween.to(0.6, getEasing(), tween.scaleX, 3),
                        tween.to(0.6, getEasing(), tween.scaleY, 3)),
                }), {mode = "pingPong"})
            end

            if input.isKeyPressed("m") then lastAction = doMove; doMove() end
            if input.isKeyPressed("r") then lastAction = doRotate; doRotate() end
            if input.isKeyPressed("c") then lastAction = doColor; doColor() end
            if input.isKeyPressed("p") then lastAction = doPulse; doPulse() end

            -- (B)ounce: spawn 500 squares that fall from above using shared def + speed
            if input.isKeyPressed("b") then
                local fallDef <const> = tween.timeline({
                    tween.to(2.0, getEasing(), tween.translateY, 0),
                    tween.wait(0.5),
                    tween.parallel(
                        tween.to(0.8, tween.sineIn, tween.scaleX, 0),
                        tween.to(0.8, tween.sineIn, tween.scaleY, 0)),
                })

                for _ = 1, 150 do
                    local size <const> = 4 + math.random() * 20
                    local startX <const> = (math.random() - 0.5) * 500
                    local startY <const> = -300 - math.random() * 200
                    local rate <const> = 0.4 + math.random() * 1.6
                    local r <const> = 0.2 + math.random() * 0.8
                    local g <const> = 0.2 + math.random() * 0.8
                    local b <const> = 0.2 + math.random() * 0.8
                    local e = world:spawn(
                        Transform(startX, startY, 0, 1, 0, 1, 1),
                        gfx.Rectangle(size, size),
                        gfx.Color(r, g, b, 1),
                        tecs.builtins.TTL(10)
                    )
                    fallDef:play(world, e, {speed = rate, delay = math.random() * 0.25})
                end
            end

            -- (1) orbit: move in a square while spinning and scaling
            local function doOrbit()
                resetTarget()
                playTween(tween.timeline({
                    channel = "demo",
                    tween.parallel(
                        tween.to(0.4, getEasing(), tween.translateX, 150),
                        tween.to(0.4, getEasing(), tween.translateY, -150),
                        tween.to(0.4, getEasing(), tween.rotation, math.pi / 2),
                        tween.to(0.4, getEasing(), tween.scaleX, 1.5),
                        tween.to(0.4, getEasing(), tween.scaleY, 1.5)),
                    tween.parallel(
                        tween.to(0.4, getEasing(), tween.translateX, 150),
                        tween.to(0.4, getEasing(), tween.translateY, 80),
                        tween.to(0.4, getEasing(), tween.rotation, math.pi)),
                    tween.parallel(
                        tween.to(0.4, getEasing(), tween.translateX, -150),
                        tween.to(0.4, getEasing(), tween.translateY, 80),
                        tween.to(0.4, getEasing(), tween.rotation, math.pi * 1.5),
                        tween.to(0.4, getEasing(), tween.scaleX, 0.5),
                        tween.to(0.4, getEasing(), tween.scaleY, 0.5)),
                    tween.parallel(
                        tween.to(0.4, getEasing(), tween.translateX, 0),
                        tween.to(0.4, getEasing(), tween.translateY, -40),
                        tween.to(0.4, getEasing(), tween.rotation, math.pi * 2),
                        tween.to(0.4, getEasing(), tween.scaleX, 1),
                        tween.to(0.4, getEasing(), tween.scaleY, 1)),
                }))
            end
            if input.isKeyPressed("1") then lastAction = doOrbit; doOrbit() end

            -- (2) reset: snap back to center
            if input.isKeyPressed("2") then
                lastAction = nil
                tween.cancel(world, target, "demo")
                resetTarget()
            end
        end
    })
end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = tweenDemoPlugin,
    render = {
        virtualHeight = VIRTUAL_H,
        pixelMode = false,
        lightingMode = "none",
        layers = {
            [1] = { name = "world" },
            [HUD_LAYER] = { name = "hud", space = "virtual" },
        },
    },
})
