--- Screen-phase steady state: a lit world scene plus a screen-space HUD
--- layer full of unlit shapes. Measures the per-frame cost of the screen
--- render phase (G-buffer + lighting pass) relative to what an unlit
--- screen layer actually needs.

local tecs = require("tecs")
local gfx = require("tecs2d.gfx")

local Transform = tecs.builtins.Transform

local WORLD_SHAPES = 2000
local HUD_SHAPES = 400
local HUD_LAYER = 12
local AREA_W, AREA_H = 2400, 1400

return {
    render = {
        lightingMode = "deferred",
        ambientLight = {0.3, 0.3, 0.3},
        lerpingEnabled = false,
        cameraPosition = {AREA_W / 2, AREA_H / 2},
        layers = {
            [HUD_LAYER] = {name = "hud", space = "screen", unlit = true},
        },
    },
    meta = {worldShapes = WORLD_SHAPES, hudShapes = HUD_SHAPES},
    setup = function(world)
        math.randomseed(42)
        local rand = math.random

        for _ = 1, WORLD_SHAPES do
            world:spawn(
                Transform(rand() * AREA_W, rand() * AREA_H, 0, 1),
                gfx.Rectangle(20, 20),
                gfx.Color(0.5 + rand() * 0.5, 0.5, 0.4, 1)
            )
        end

        world:spawn(
            Transform(AREA_W / 2, AREA_H / 2, 0.5, 2),
            gfx.Light(400, 1.5, 0.4, 1.0, 0.9, 0.8)
        )

        for _ = 1, HUD_SHAPES do
            world:spawn(
                Transform(rand() * 1280, rand() * 720, 0, HUD_LAYER),
                gfx.Rectangle(16, 16),
                gfx.Color(rand(), rand(), 0.8, 1)
            )
        end
    end,
}
