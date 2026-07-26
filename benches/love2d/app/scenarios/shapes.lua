--- Shape steady state: a large field of circles and rectangles. Static by
--- default; TECS_BENCH_FIXED=1 moves every Transform in FixedUpdate, and
--- TECS_BENCH_INTERPOLATE=1 enables presentation interpolation.

local tecs = require("tecs")
local gfx = require("tecs2d.gfx")

local Transform = tecs.builtins.Transform

local SHAPES_PER_TYPE = tonumber(os.getenv("TECS_BENCH_SHAPES")) or 8000
local CIRCLES = SHAPES_PER_TYPE
local RECTS = SHAPES_PER_TYPE
local FIXED = os.getenv("TECS_BENCH_FIXED") == "1"
local INTERPOLATE = os.getenv("TECS_BENCH_INTERPOLATE") == "1"
local AREA_W, AREA_H = 4000, 2400

return {
    render = {
        lightingMode = "deferred",
        ambientLight = {1.0, 1.0, 1.0},
        lerpingEnabled = false,
        cameraPosition = {AREA_W / 2, AREA_H / 2},
        disableInterpolation = not INTERPOLATE,
        sizeHints = {circles = CIRCLES + 64, rects = RECTS + 64},
    },
    meta = {
        circles = CIRCLES,
        rects = RECTS,
        fixedMovement = FIXED,
        interpolationEnabled = INTERPOLATE,
    },
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

        if FIXED then
            local query = world:query({include = {Transform}})
            world:addSystem({
                name = "bench.MoveShapes",
                phase = tecs.phases.FixedUpdate,
                run = function(dt)
                    for archetype, len in query:iter() do
                        local transforms = archetype:getMut(Transform)
                        for i = 1, len do
                            transforms[i].x =
                                transforms[i].x + dt * 20
                        end
                    end
                end,
            })
        end
    end,
}
