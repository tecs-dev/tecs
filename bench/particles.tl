--- GPU particle emitters, at rest and under load.
---
--- Four regimes over the same scene, selected by `BENCH_REGIME`, because the
--- question this stage is judged on is not one number:
---
---   idle     a pool of sixty-four thousand slots and no emitter at all. What
---            reserving the pool costs a scene that never uses it, which is
---            the row that decides whether the reservation is affordable
---   small    sixteen thousand live particles
---   large    sixty-four thousand live particles
---   churn    sixty-four thousand at a tenth of the lifetime, so the whole
---            field is replaced several times a second and the emit and spawn
---            passes carry their worst case rather than their steady one
---
--- Read against `make bench`, which is the gate on whether a pool costs a
--- scene with no particles in it. Nothing here has a Renderable, so what the
--- frame stage measures is the three compute passes, the cull over the pool's
--- run and the one draw that consumes what survives.

local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local particles <const> = require("tecs.gfx.particles")
local timing <const> = require("tecs.timing")

local Transform <const> = tecs.components.Transform

local REGIME <const> = os.getenv("BENCH_REGIME") or "large"
local WARMUP <const> = math.floor(tonumber(os.getenv("BENCH_WARMUP")) or 120)
local FRAMES <const> = math.floor(tonumber(os.getenv("BENCH_FRAMES")) or 300)

local WIDTH <const> = 1280
local HEIGHT <const> = 720

--- Slots the pool reserves, whichever regime is running. Held constant so the
--- idle row measures the same reservation the loaded rows fill.
local POOL <const> = 65536

--- Emitters the field is spread over, so the emit pass is dispatched over a
--- realistic number rather than over one, and the host walks a realistic
--- number too. Adjustable, because separating what the field costs from what
--- the emitters cost means moving one without the other.
local EMITTERS <const> = math.floor(tonumber(os.getenv("BENCH_EMITTERS")) or 64)

--- Live particles, and the lifetime that holds them. A steady emitter holds
--- `rate * lifetime` of them, so the pair decides both the field's size and
--- how often the whole of it is replaced.
local REGIMES <const>: {string: {number}} = {
    -- live particles, seconds of lifetime
    idle = {0, 0},
    small = {16384, 2.0},
    large = {65536, 2.0},
    churn = {65536, 0.2},
}

local settings <const> = REGIMES[REGIME]
if settings == nil then
    error(("bench: '%s' is not a regime; use idle, small, large or churn"):format(REGIME), 0)
end
local LIVE <const> = math.floor(settings[1])
local LIFETIME <const> = settings[2]

--- Spread over the viewport, so most of the field is on screen and the cull
--- does the work it exists for rather than rejecting everything.
local function spawnEmitters(world: tecs.World)
    if LIVE == 0 then
        return
    end

    local perEmitter <const> = math.floor(LIVE / EMITTERS)
    local effect <const> = particles.effect({
        name = "benchSparks",
        capacity = perEmitter,
        overflow = "replace",
        schedule = {rate = perEmitter / LIFETIME, looping = true},
        spawn = {
            shape = "disc",
            width = 60.0,
            direction = 0.0,
            spread = math.pi * 2.0,
            space = "world",
        },
        initial = {
            lifetime = LIFETIME,
            speed = {min = 20.0, max = 90.0},
            size = {min = 3.0, max = 9.0},
            rotation = {min = 0.0, max = math.pi * 2.0},
            angularVelocity = {min = -4.0, max = 4.0},
            accelerationY = {min = 40.0, max = 120.0},
            color = "#ffd080",
        },
        update = {
            drag = 0.4,
            tangentialAcceleration = {min = -60.0, max = 60.0},
            size = particles.curve({{0.0, 0.2}, {0.1, 1.0}, {1.0, 0.1}}),
            color = particles.gradient({
                {0.0, "#fff4c0"},
                {1.0, "#ff8020"},
            }),
        },
        render = {layer = 1},
    })

    -- A grid over the viewport, so the emitters are spread rather than stacked
    -- and the field covers what the camera can see.
    local columns <const> = math.ceil(math.sqrt(EMITTERS))
    for index = 0, EMITTERS - 1 do
        local column <const> = index % columns
        local row <const> = math.floor(index / columns)
        world:spawn(
            Transform((column + 0.5) * WIDTH / columns, (row + 0.5) * HEIGHT / columns),
            particles.ParticleEmitter({effect = effect, seed = index + 1})
        )
    end
end

timing.enable()

--- Wall time between iterations, which is the frame time a player feels.
local DELTA <const> = timing.stage("delta")

return tecs.application({
    window = {title = "particles", width = WIDTH, height = HEIGHT},
    presentMode = "immediate",
    ambientLight = {1.0, 1.0, 1.0},
    capacity = POOL + 1024,
    maxEntities = 4096,
    debugMaxFrames = WARMUP + FRAMES,

    plugin = function(world: tecs.World, app: tecs.Application)
        local renderer = app.renderer
        world:addPlugin(particles.plugin({
            renderer = renderer,
            capacity = POOL,
            maxEmitters = EMITTERS + 8,
        }))
        spawnEmitters(world)

        -- In `First`, so the sample is taken ahead of the systems it covers.
        local frame = 0
        world:addSystem({
            name = "bench.Sample",
            phase = tecs.phases.First,
            run = function(dt: number)
                if frame == WARMUP then
                    timing.reset()
                end
                if frame >= WARMUP then
                    timing.mark(DELTA, dt)
                end
                frame = frame + 1
            end,
        })

        world:addSystem({
            name = "bench.Report",
            phase = tecs.phases.Shutdown,
            run = function()
                print(("frames after %d warmup, %d instances resident"):format(WARMUP, renderer.count))
                local report = timing.format()
                if report ~= "" then
                    print(report)
                end
            end,
        })

        print(
            ("particles: regime %s, %d live over %d emitters in a pool of " .. "%d, viewport %dx%d"):format(
                REGIME, LIVE, LIVE > 0 and EMITTERS or 0, POOL, WIDTH, HEIGHT
            )
        )
    end,
})
