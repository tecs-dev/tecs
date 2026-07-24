--- UI layout steady state: scrolling containers full of child rects.
--- The containers scroll continuously (a realistic worst case for
--- Viewport: every frame recomputes scroll offsets and clip bounds
--- for every child), measuring the per-frame layout systems' cost and
--- allocation behavior.

local tecs = require("tecs")
local gfx = require("tecs2d.gfx")
local ui = require("tecs2d.ui")

local Transform = tecs.builtins.Transform
local ChildOf = tecs.builtins.ChildOf
local RelativeTransform = tecs.builtins.RelativeTransform

local CONTAINERS = 8
local ITEMS = 64

local containers = {}

return {
    render = {
        lightingMode = "deferred",
        ambientLight = {1.0, 1.0, 1.0},
        lerpingEnabled = false,
        cameraPosition = {640, 360},
    },
    meta = {containers = CONTAINERS, itemsPerContainer = ITEMS},
    setup = function(world)
        local containerW, containerH = 140, 500
        local contentHeight = ITEMS * 40 + 10
        local flat = os.getenv("TECS_BENCH_UI_FLAT") ~= nil
        local manual = os.getenv("TECS_BENCH_UI_MANUAL") ~= nil
        for c = 1, CONTAINERS do
            local x = 20 + (c - 1) * 155
            local container
            if flat or manual then
                container = world:spawn(
                    Transform(x, 100),
                    gfx.Rectangle(containerW, containerH),
                    ui.LayoutBox(gfx.Rectangle, nil, 0, 0),
                    gfx.Pivot(0, 0),
                    ui.Viewport(0, 0, containerW, contentHeight),
                    gfx.Color(0.15, 0.12, 0.20)
                )
            else
                container = world:spawn(
                    Transform(x, 100),
                    gfx.Rectangle(containerW, containerH),
                    ui.LayoutBox(gfx.Rectangle, nil, 0, 0),
                    gfx.Pivot(0, 0),
                    ui.Flow("down", 10),
                    ui.FitContent.new({
                        padding = 10,
                        fit = "width",
                        adjust = gfx.Rectangle,
                    }),
                    ui.Viewport(0, 0, containerW, contentHeight),
                    gfx.Color(0.15, 0.12, 0.20)
                )
            end
            containers[c] = container
            for i = 1, ITEMS do
                if flat then
                    world:spawn(
                        Transform(x + 10, 110 + (i - 1) * 40, 1),
                        gfx.Rectangle(containerW - 20, 30),
                        ui.LayoutBox(gfx.Rectangle, nil, 0, 0),
                        gfx.Pivot(0, 0),
                        gfx.Color(0.3 + (i % 5) * 0.1, 0.4, 0.6)
                    )
                elseif manual then
                    world:spawn(
                        Transform(0, 0, 1),
                        ChildOf(container),
                        RelativeTransform.new({
                            x = 10,
                            y = 10 + (i - 1) * 40,
                            z = 1,
                        }),
                        gfx.Rectangle(containerW - 20, 30),
                        ui.LayoutBox(gfx.Rectangle, nil, 0, 0),
                        ui.FlowOrder(i),
                        gfx.Pivot(0, 0),
                        gfx.Color(0.3 + (i % 5) * 0.1, 0.4, 0.6)
                    )
                else
                    world:spawn(
                        Transform(0, 0, 1),
                        ChildOf(container),
                        RelativeTransform.new({z = 1}),
                        gfx.Rectangle(containerW - 20, 30),
                        ui.LayoutBox(gfx.Rectangle, nil, 0, 0),
                        ui.FlowOrder(i),
                        gfx.Pivot(0, 0),
                        gfx.Color(0.3 + (i % 5) * 0.1, 0.4, 0.6)
                    )
                end
            end
        end
    end,
    tick = (not os.getenv("TECS_BENCH_UI_STATIC")) and function(world, frame)
        local Viewport = ui.Viewport
        for c = 1, CONTAINERS do
            local mut = world:getMut(containers[c], Viewport)
            if mut then
                mut.scrollY = (frame * 2) % 1000
            end
        end
    end or nil,
}
