--- Bodies falling into a pile, which is the shape a game's frame actually has.
---
--- The shapes benchmark's simulation is a loop that moves every transform by
--- the same amount: uniform, cheap, and unrepresentative. Physics is neither.
--- It is expensive, it never touches the GPU, and it is lumpy, because the
--- frame where a stack collapses costs far more than the one before it.
---
--- That makes this the benchmark a frame-structure change has to be judged
--- against. Simulation and rendering are serialized, so physics adds directly
--- to frame time and every spike in it lands on the frame. Neither effect
--- shows up on a scene whose simulation is a loop.
---
--- Run it before and after any change to the frame structure. The numbers to
--- compare are p50 and p95 together: an optimization that improves the median
--- while worsening the tail has made the game feel worse, and physics is where
--- that trade shows up.

local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local box2d <const> = require("tecs.box2d")
local materials <const> = require("tecs.gpu.materials")
local timing <const> = require("tecs.timing")
local time <const> = require("tecs.platform.time")
local Transform <const> = tecs.Transform
local Tint <const> = tecs.gfx.Tint
local Material <const> = tecs.gfx.Material
local Renderable <const> = tecs.gfx.Renderable

--- Dynamic bodies. The default is chosen so a frame costs enough that
--- simulation is the larger stage, which is the regime a frame-structure
--- change has to survive.
local BODIES <const> = math.floor(tonumber(os.getenv("BENCH_BODIES")) or 4000)

--- Dropped in waves rather than all at once, so the scene passes through
--- settling, collapsing and resting instead of only one of them.
local WAVES <const> = math.floor(tonumber(os.getenv("BENCH_WAVES")) or 8)

--- Frames between waves. Counted in frames rather than seconds so both sides
--- of an A/B see the same scene: on a wall-clock schedule a faster build
--- reaches fewer waves in the same run and the two are not comparable.
local WAVE_FRAMES <const> = math.floor(tonumber(os.getenv("BENCH_WAVE_FRAMES")) or 45)

--- Four jets keep the pile from settling, one in each corner, each aimed along
--- the wall it sits beside so together they turn the contents over clockwise
--- rather than throwing them at the ceiling.
---
--- Without them the pile falls asleep and the benchmark goes bimodal, most
--- frames costing nothing and a few costing everything, which measures the
--- idle frame rather than the simulation. A steady churn keeps the
--- distribution tight enough that a ten percent change is visible in it.
local BLOWER_FORCE <const> = tonumber(os.getenv("BENCH_BLOWER")) or 900.0
local BLOWER_RADIUS <const> = tonumber(os.getenv("BENCH_BLOWER_RADIUS")) or 220.0

--- Long enough for every wave to land and the pile to start churning, so
--- measurement starts with the full body count present and moving.
local WARMUP <const> = math.floor(tonumber(os.getenv("BENCH_WARMUP")) or (WAVES * WAVE_FRAMES + 240))
local FRAMES <const> = math.floor(tonumber(os.getenv("BENCH_FRAMES")) or 900)

local WIDTH <const> = 1280
local HEIGHT <const> = 720

--- Half-extent of a body, in world pixels. Small enough that the box holds
--- many of them, since contact count is what makes a step expensive.
local SIZE <const> = tonumber(os.getenv("BENCH_SIZE")) or 3.0

--- Wall thickness, and the inset from the window a wall sits at.
local WALL <const> = 20.0

local spawned = 0

-- Measuring is the whole point of this file, so it does not wait to be asked.
timing.enable()

--- Real wall time between iterations, which is the frame time a player feels.
--- Recorded from the clock provider, since the dt the world receives is pinned
--- and reporting that back would only restate the constant.
local DELTA <const> = timing.stage("delta")

--- Interior of the box, in world pixels.
local MIN_X <const> = WALL * 2
local MAX_X <const> = WIDTH - WALL * 2
local MIN_Y <const> = WALL * 2

--- A closed box. Closed rather than open-topped because the jets are strong
--- enough to throw a body out of an open one, and a body that leaves stops
--- costing anything, which would quietly drain the benchmark of its load.
local function buildContainer(world: tecs.World)
    local function wall(x: number, y: number, halfWidth: number, halfHeight: number)
        local entity = world:spawn(
            Transform(x, y, 0, 1, 0, halfWidth * 2, halfHeight * 2), Tint(0.18, 0.18, 0.22, 1.0), Renderable()
        )
        box2d.attach(
            world,
            entity,
            {
                type = "static",
                halfWidth = halfWidth,
                halfHeight = halfHeight,
            }
        )
    end

    local halfWidth <const> = WIDTH * 0.5 - WALL
    local halfHeight <const> = HEIGHT * 0.5 - WALL
    wall(WIDTH * 0.5, HEIGHT - WALL, halfWidth, WALL) -- floor
    wall(WIDTH * 0.5, WALL, halfWidth, WALL) -- ceiling
    wall(WALL, HEIGHT * 0.5, WALL, halfHeight) -- left
    wall(WIDTH - WALL, HEIGHT * 0.5, WALL, halfHeight) -- right
end

--- Drops one wave of bodies above the pile.
local function dropWave(world: tecs.World, count: integer, rand: function(): number)
    local circleId <const> = materials.id("circle")
    local columns <const> = 96
    local spacing <const> = (MAX_X - MIN_X) / columns
    for index = 1, count do
        -- Inside the box, in the upper third, so a wave falls into whatever is
        -- already there rather than arriving from outside a wall.
        local column = index % columns
        local rowIndex = math.floor(index / columns)
        local x = MIN_X + SIZE + column * spacing + rand() * spacing * 0.5
        local y = MIN_Y + SIZE + rowIndex * (SIZE * 2.4) + rand() * 2.0

        local round = index % 3 == 0
        local entity = world:spawn(
            Transform(x, y, 0, 1, 0, SIZE * 2, SIZE * 2),
            Tint(0.3 + rand() * 0.7, 0.3 + rand() * 0.7, 0.5 + rand() * 0.5, 1.0),
            -- A mix, so the fragment shader's material branch is exercised
            -- rather than every instance taking the same path.
            round and Material(circleId, 0) or Material(0, 0),
            Renderable()
        )
        box2d.attach(
            world,
            entity,
            {
                type = "dynamic",
                radius = round and SIZE or nil,
                halfWidth = SIZE,
                halfHeight = SIZE,
                density = 1.0,
                friction = 0.3,
                restitution = 0.1,
            }
        )
        spawned = spawned + 1
    end
end

return tecs.application.create({
    window = {title = "physics", width = WIDTH, height = HEIGHT},
    presentMode = "immediate",
    ambientLight = {1.0, 1.0, 1.0},
    capacity = BODIES + 64,
    debugMaxFrames = WARMUP + FRAMES,

    plugin = function(world: tecs.World, app: tecs.application.Application)
        local renderer = app.renderer

        -- Iterations completed, which is what the drop schedule and the warmup
        -- cut are both counted in. Incremented in `Last` so every phase in one
        -- iteration reads the same number.
        local frame = 0
        world:addSystem({
            name = "bench.Frame",
            phase = tecs.ecs.phases.Last,
            run = function() frame = frame + 1 end,
        })

        -- Physics runs in the fixed phases, as it always does. The comparison
        -- problem that creates is solved where it belongs: dt is pinned, so
        -- the accumulator releases exactly one fixed step per frame.
        --
        -- Left measured, the workload would be a function of the frame rate it
        -- produces. Cheap physics makes frames fast, fast frames accumulate
        -- fewer steps, fewer steps means less jet impulse, the pile settles,
        -- and the cost oscillates between runs by more than any change being
        -- measured. `time.provider` exists for exactly this: frames are the
        -- coordinate system and dt is data.
        -- The real dt is recorded here rather than in a system, which sees the
        -- pinned value: a stage fed the fiction would report the fiction. This
        -- is the one place that sees both.
        time.provider = function(realDt: number): number timing.mark(DELTA, realDt); return time.nominal end

        -- The A/B knob for the solver's thread pool. One worker starts no
        -- threads and runs every task inline, which is the no-executor path.
        world:addPlugin(box2d.plugin({
            gravity = {0.0, 900.0},
            workerCount = math.floor(tonumber(os.getenv("BENCH_WORKERS")) or 0) as integer,
        }))
        buildContainer(world)

        -- Seeded, so every run drops the same bodies in the same order and two
        -- measurements are of the same scene.
        math.randomseed(42)
        local rand <const> = math.random

        local perWave <const> = math.floor(BODIES / WAVES)
        local dropped = 0

        world:addSystem({
            name = "bench.Drop",
            phase = tecs.ecs.phases.Update,
            run = function()
                if dropped >= WAVES then
                    return
                end
                if frame < dropped * WAVE_FRAMES then
                    return
                end
                dropped = dropped + 1
                dropWave(world, perWave, rand)
            end,
        })

        -- x, y, then a unit direction. World Y runs down, so a positive y
        -- component pushes downward.
        local function jet(x: number, y: number, dx: number, dy: number): {number}
            local length = math.sqrt(dx * dx + dy * dy)
            return {x, y, dx / length, dy / length}
        end

        -- Each aimed along the wall beside it, so the four together circulate
        -- clockwise instead of fighting each other in the middle.
        local blowers <const>: {{number}} = {
            jet(WIDTH * 0.18, HEIGHT * 0.20, 1.0, 0.30), -- top left, right
            jet(WIDTH * 0.82, HEIGHT * 0.20, -0.30, 1.0), -- top right, down
            jet(WIDTH * 0.82, HEIGHT * 0.78, -1.0, -0.30), -- low right, left
            jet(WIDTH * 0.18, HEIGHT * 0.78, 0.30, -1.0), -- low left, up
        }
        local radiusSq <const> = BLOWER_RADIUS * BLOWER_RADIUS

        local blown = world:query({
            include = {Transform, box2d.RigidBody},
        })

        world:addSystem({
            name = "bench.Blowers",
            -- Beside the step rather than beside the frame, so a body takes
            -- the same impulse per step of simulated time however the frames
            -- fall.
            phase = tecs.ecs.phases.FixedUpdate,
            run = function()
                -- The physics step is fixed, so the push is too.
                local push = BLOWER_FORCE / 60.0
                for archetype, length in blown:iter() do
                    -- Read rather than getMut: the blowers change velocity
                    -- through Box2D, and the transform is written back by the
                    -- physics sync. Taking it mutable here would mark the
                    -- column dirty every frame and defeat the gate.
                    local transforms = archetype:get(Transform)
                    local bodies = archetype:get(box2d.RigidBody)
                    for row = 1, length do
                        local transform = transforms[row]
                        for index = 1, #blowers do
                            local blower = blowers[index]
                            local dx = transform.x - blower[1]
                            local dy = transform.y - blower[2]
                            local distanceSq = dx * dx + dy * dy
                            if distanceSq < radiusSq then
                                -- Falls off with distance, so a body at the
                                -- edge of the stream drifts rather than being
                                -- snapped into it.
                                local falloff = 1.0 - distanceSq / radiusSq
                                local strength = push * falloff
                                box2d.applyImpulseTo(bodies[row], blower[3] * strength, blower[4] * strength)
                                break
                            end
                        end
                    end
                end
            end,
        })

        world:addSystem({
            name = "bench.Sample",
            phase = tecs.ecs.phases.First,
            run = function()
                -- Everything before this built the scene: waves still landing,
                -- the pile still settling, archetypes still moving. Dropping
                -- those frames from every stage at once is what makes the
                -- report a distribution of the steady state rather than of the
                -- run.
                if frame == WARMUP then
                    timing.reset()
                end
            end,
        })

        world:addSystem({
            name = "bench.Report",
            phase = tecs.ecs.phases.Shutdown,
            run = function()
                print(
                    ("frames after %d warmup, %d bodies spawned, " .. "%d instances synced"):format(
                        WARMUP, spawned, renderer.count
                    )
                )
                local report = timing.format()
                if report ~= "" then
                    print(report)
                end
            end,
        })

        print(
            ("physics: %d bodies in %d waves, %d frames apart, " .. "measuring %d after %d warmup"):format(
                BODIES, WAVES, WAVE_FRAMES, FRAMES, WARMUP
            )
        )
    end,
})
