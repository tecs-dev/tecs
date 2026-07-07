--- Deferred lighting steady state: many static lights over a field of lit
--- and occluding shapes. Nothing changes after setup, so this measures the
--- per-frame cost of light sync, occluder mask, tile cull, and compose
--- when a dirty-gated pipeline could skip most of it.

local tecs = require("tecs")
local gfx = require("tecs2d.gfx")

local Transform = tecs.builtins.Transform

local LIGHTS = tonumber(os.getenv("TECS_BENCH_LIGHTS")) or 256
local OCCLUDERS = 256
local BACKGROUND = 1024
local AREA_W, AREA_H = 2400, 1400

local function rng()
    -- Deterministic layout across runs
    math.randomseed(42)
    return math.random
end

return {
    render = {
        lightingMode = "deferred",
        ambientLight = {0.1, 0.1, 0.1},
        lerpingEnabled = false,
        cameraPosition = {AREA_W / 2, AREA_H / 2},
        sizeHints = {lights = LIGHTS + 64},
    },
    meta = {lights = LIGHTS, occluders = OCCLUDERS, background = BACKGROUND},
    setup = function(world)
        local rand = rng()

        for _ = 1, BACKGROUND do
            world:spawn(
                Transform(rand() * AREA_W, rand() * AREA_H, 0, 1),
                gfx.Rectangle(24, 24),
                gfx.Color(0.6 + rand() * 0.4, 0.6, 0.5, 1)
            )
        end

        for _ = 1, OCCLUDERS do
            world:spawn(
                Transform(rand() * AREA_W, rand() * AREA_H, 0.1, 2),
                gfx.Rectangle(30, 30),
                gfx.Color(0.3, 0.3, 0.35, 1),
                gfx.Occluder(0.6)
            )
        end

        for _ = 1, LIGHTS do
            world:spawn(
                Transform(rand() * AREA_W, rand() * AREA_H, 0.5, 3),
                gfx.Light(180 + rand() * 120, 1.0 + rand(), 0.4, rand(), rand(), 1.0)
            )
        end
    end,
}
