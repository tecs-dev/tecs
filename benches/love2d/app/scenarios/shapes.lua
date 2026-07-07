--- Static shape steady state: a large field of circles and rectangles that
--- never change. Measures per-frame shape shadow-column sync, render-state
--- walks, and cull dispatch when nothing is dirty.

local tecs = require("tecs")
local gfx = require("tecs2d.gfx")

local Transform = tecs.builtins.Transform

local CIRCLES = 8000
local RECTS = 8000
local AREA_W, AREA_H = 4000, 2400

return {
    render = {
        lightingMode = "deferred",
        ambientLight = {1.0, 1.0, 1.0},
        lerpingEnabled = false,
        cameraPosition = {AREA_W / 2, AREA_H / 2},
        sizeHints = {circles = CIRCLES + 64, rects = RECTS + 64},
    },
    meta = {circles = CIRCLES, rects = RECTS},
    setup = function(world)
        math.randomseed(42)
        local rand = math.random
        for _ = 1, CIRCLES do
            world:spawn(
                Transform(rand() * AREA_W, rand() * AREA_H, 0, 1),
                gfx.Circle(6 + rand() * 10),
                gfx.Color(rand(), rand(), rand(), 1)
            )
        end
        for _ = 1, RECTS do
            world:spawn(
                Transform(rand() * AREA_W, rand() * AREA_H, 0, 2),
                gfx.Rectangle(10 + rand() * 20, 10 + rand() * 20),
                gfx.Color(rand(), rand(), rand(), 1)
            )
        end
    end,
}
