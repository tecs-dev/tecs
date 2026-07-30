--- Steady-state shape field, matching the previous engine's `shapes` bench.
---
--- The point is comparability, so the scene is copied rather than invented: a
--- 4000x2400 area viewed through a 1280x720 window, so roughly a tenth of the
--- field is on screen and culling does the work it exists for. Deferred with
--- white ambient and no point lights, vsync off.
---
--- Two movement modes, because the engine being compared against interpolates
--- between fixed steps and this one does not yet. `fixed` moves in FixedUpdate,
--- so most frames re-upload nothing; `frame` moves every frame, so every
--- instance is rewritten every frame. The first is what the scene does, the
--- second is what the comparison's work per rendered frame looks like. Both are
--- reported rather than one being chosen.

local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local Transform <const> = tecs.Transform
local Tint <const> = tecs.gfx.Tint
local Renderable <const> = tecs.gfx.Renderable
local Material <const> = tecs.gfx.Material
local materials <const> = require("tecs.gpu.materials")
local timing <const> = require("tecs.timing")

--- Shapes of each kind: this many circles and this many rectangles, matching
--- the reference bench. Both are the same quad with the same instance format;
--- only the material the fragment shader evaluates differs.
local PER_KIND <const> = math.floor(tonumber(os.getenv("BENCH_SHAPES")) or 100000)
local COUNT <const> = PER_KIND * 2

local AREA_W <const> = tonumber(os.getenv("BENCH_AREA_W")) or 4000.0
local AREA_H <const> = tonumber(os.getenv("BENCH_AREA_H")) or 2400.0

--- "fixed" or "frame".
local MODE <const> = os.getenv("BENCH_MODE") or "frame"
local WARMUP <const> = math.floor(tonumber(os.getenv("BENCH_WARMUP")) or 120)
local FRAMES <const> = math.floor(tonumber(os.getenv("BENCH_FRAMES")) or 300)

local WIDTH <const> = 1280
local HEIGHT <const> = 720

--- Fills the area, centerd on the viewport so the visible fraction matches.
local function spawnField(world: tecs.World)
    local originX <const> = (WIDTH - AREA_W) * 0.5
    local originY <const> = (HEIGHT - AREA_H) * 0.5

    -- Seeded exactly as the reference scene does, so the field is uniform and
    -- identical on every run. An arithmetic sequence was tried first and gave a
    -- lattice of diagonal stripes rather than a field, which changes both the
    -- visible fraction and the overdraw.
    math.randomseed(42)
    local rand <const> = math.random

    -- Circles and rectangles are separate spawns, so each lands in its own
    -- archetype and stays contiguous. That is also what keeps the fragment
    -- shader's material branch coherent across a warp.
    --- Circles are 6 to 16 across, rectangles 10 to 30 per side, matching the
    --- reference scene's size distribution.
    local function fill(material: string, param: number, base: number, spread: number)
        local id = materials.id(material)
        world:batchSpawn(
            PER_KIND,
            {Transform, Tint, Material, Renderable},
            function(archetype: tecs.ecs.Archetype, firstRow: integer, lastRow: integer)
                -- batchSpawn skips FFI defaults, so every field is written here.
                local transforms = archetype:getMut(Transform)
                local tints = archetype:getMut(Tint)
                local materialColumn = archetype:getMut(Material)

                for row = firstRow, lastRow do
                    local entry = materialColumn[row]
                    entry.id = id
                    entry.param = param

                    local transform = transforms[row]
                    transform.x = originX + rand() * AREA_W
                    transform.y = originY + rand() * AREA_H
                    -- Written because batchSpawn skips defaults, so an unset field
                    -- holds whatever the column's memory held before. Neither is
                    -- read while depth comes from elsewhere, and both would be read
                    -- as garbage the moment it does.
                    transform.z = 0.0
                    transform.layer = 1
                    -- Unrotated, as the reference is. Rotation would not change
                    -- what the sync costs, since the basis is built either way.
                    transform.rotation = 0.0
                    transform.scaleX = base + rand() * spread
                    transform.scaleY = base + rand() * spread

                    local tint = tints[row]
                    tint.r = rand()
                    tint.g = rand()
                    tint.b = rand()
                    tint.a = 1.0
                end
            end
        )
    end

    fill("circle", 0.0, 6.0, 10.0)
    fill("rounded", 0.25, 10.0, 20.0)
end

-- Measuring is the whole point of this file, so it does not wait to be asked.
timing.enable()

--- Wall time between iterations, which is the frame time a player feels. The
--- engine's own `frame` stage covers the iteration only, so the gap between
--- the two is the host loop and the presentation wait around it.
local DELTA <const> = timing.stage("delta")

return tecs.newApplication({
    window = {title = "shapes", width = WIDTH, height = HEIGHT},
    presentMode = "immediate",
    ambientLight = {1.0, 1.0, 1.0},
    capacity = COUNT + 64,
    -- The default ceiling is a million slots, so a scale run has to raise it
    -- rather than discovering the limit as a spawn failure.
    maxEntities = COUNT + 1024,
    debugMaxFrames = WARMUP + FRAMES,

    plugin = function(world: tecs.World, app: tecs.Application)
        local renderer = app.renderer
        spawnField(world)

        -- Translation only, matching the reference scene. Rotation would make
        -- the sync recompute a basis per entity per frame, which is a different
        -- amount of work and would not be comparable.
        local moving = world:query({include = {Transform, Renderable}})
        local phase = MODE == "fixed" and tecs.ecs.phases.FixedUpdate or tecs.ecs.phases.Update

        world:addSystem({
            name = "bench.Drift",
            phase = phase,
            run = function(dt: number)
                local step = dt * 40.0
                for archetype, length in moving:iter() do
                    local transforms = archetype:getMut(Transform)
                    for row = 1, length do
                        local transform = transforms[row]
                        local x = transform.x + step
                        -- Wrap rather than branch on a bound per axis, so the
                        -- field stays put and the work per frame is constant.
                        if x > AREA_W then
                            x = x - AREA_W
                        end
                        transform.x = x
                    end
                end
            end,
        })

        -- The bench's own bookkeeping, in `First` so it runs ahead of every
        -- system whose cost it is about to record. Counting frames here rather
        -- than reading the loop's counter keeps the harness inside the world
        -- like everything else it measures.
        local frame = 0
        world:addSystem({
            name = "bench.Sample",
            phase = tecs.ecs.phases.First,
            run = function(dt: number)
                -- Warmup frames are the ones that built and first uploaded the
                -- scene. Dropping them from every stage at once is what makes
                -- the report a distribution of the steady state rather than of
                -- the run.
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
            phase = tecs.ecs.phases.Shutdown,
            run = function()
                print(("frames after %d warmup, %d of %d instances synced"):format(WARMUP, renderer.count, COUNT))
                local report = timing.format()
                if report ~= "" then
                    print(report)
                end
            end,
        })

        print(
            ("shapes: %d circles + %d rects over %.0fx%.0f, viewport %dx%d, mode %s"):format(
                PER_KIND, PER_KIND, AREA_W, AREA_H, WIDTH, HEIGHT, MODE
            )
        )
    end,
})
