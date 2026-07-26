--- Steady-state shape field, matching the Love-backed engine's `shapes` bench.
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

local root = os.getenv("TECS2D_LUA")
    or (_G as {string: any})["__tecs2dContent"] as string
    or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then root = root:sub(1, -2) end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local Transform2D <const> = tecs2d.components.Transform2D
local Tint <const> = tecs2d.components.Tint
local Renderable <const> = tecs2d.components.Renderable

--- Shapes of each kind. The reference bench spawns this many circles and this
--- many rectangles; everything here is a quad, which is noted in the report
--- because it is the one part of the scene that is not equivalent.
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

local samples: {number} = {}
local sampled = 0

--- Fills the area, centred on the viewport so the visible fraction matches.
local function spawnField(world: tecs.World)
    local originX <const> = (WIDTH - AREA_W) * 0.5
    local originY <const> = (HEIGHT - AREA_H) * 0.5

    -- A fixed multiplier rather than a random source: the layout has to be the
    -- same on every run for the numbers to be comparable between them.
    local golden <const> = 2.39996

    world:batchSpawn(COUNT, { Transform2D, Tint, Renderable },
        function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer)
            -- batchSpawn skips FFI defaults, so every field is written here.
            local transforms = archetype:getMut(Transform2D)
            local tints = archetype:getMut(Tint)

            for row = firstRow, lastRow do
                local index = row - firstRow
                local angle = index * golden
                local u = (index % 977) / 977.0
                local v = (index % 1583) / 1583.0

                local transform = transforms[row]
                transform.x = originX + u * AREA_W
                transform.y = originY + v * AREA_H
                transform.rotation = angle
                transform.scaleX = 12.0
                transform.scaleY = 12.0

                local tint = tints[row]
                tint.r = 0.35 + 0.65 * u
                tint.g = 0.35 + 0.65 * v
                tint.b = 0.85
                tint.a = 1.0
            end
        end)
end

--- Sorts a copy and reads a percentile out of it.
local function percentile(values: {number}, fraction: number): number
    local sorted: {number} = {}
    for i = 1, #values do sorted[i] = values[i] end
    table.sort(sorted)
    local index = math.floor(#sorted * fraction)
    if index < 1 then index = 1 end
    if index > #sorted then index = #sorted end
    return sorted[index]
end

return tecs2d.application({
    window = { title = "shapes", width = WIDTH, height = HEIGHT },
    presentMode = "immediate",
    ambient = { 1.0, 1.0, 1.0 },
    capacity = COUNT + 64,
    maxFrames = WARMUP + FRAMES,

    load = function(app: tecs2d.Application)
        spawnField(app.world)

        -- Translation only, matching the reference scene. Rotation would make
        -- the sync recompute a basis per entity per frame, which is a different
        -- amount of work and would not be comparable.
        local moving = app.world:query({ include = { Transform2D, Renderable } })
        local phase = MODE == "fixed" and tecs.phases.FixedUpdate
            or tecs.phases.Update

        app.world:addSystem({
            name = "bench.Drift",
            phase = phase,
            run = function(dt: number)
                local step = dt * 40.0
                for archetype, length in moving:iter() do
                    local transforms = archetype:getMut(Transform2D)
                    for row = 1, length do
                        local transform = transforms[row]
                        local x = transform.x + step
                        -- Wrap rather than branch on a bound per axis, so the
                        -- field stays put and the work per frame is constant.
                        if x > AREA_W then x = x - AREA_W end
                        transform.x = x
                    end
                end
            end,
        })

        print(("shapes: %d quads over %.0fx%.0f, viewport %dx%d, mode %s")
            :format(COUNT, AREA_W, AREA_H, WIDTH, HEIGHT, MODE))
    end,

    update = function(app: tecs2d.Application, dt: number)
        if app.frame >= WARMUP then
            sampled = sampled + 1
            samples[sampled] = dt * 1000.0
        end
    end,

    quit = function(app: tecs2d.Application)
        if sampled == 0 then return end
        local total = 0.0
        for i = 1, sampled do total = total + samples[i] end
        print(("frames %d after %d warmup"):format(sampled, WARMUP))
        print(("  p50   %.2f ms"):format(percentile(samples, 0.50)))
        print(("  p95   %.2f ms"):format(percentile(samples, 0.95)))
        print(("  mean  %.2f ms"):format(total / sampled))
        print(("  drawn %d of %d instances synced"):format(
            app.renderer.count, COUNT))
    end,
})
