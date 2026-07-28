--- Sprites at scale, and what extraction rewrites when almost nothing moved.
---
--- `make bench` measures one regime: every entity moves every frame, which is
--- the case where the dirty gate can never help and where the instance layout
--- never shifts. A game is not that. A game is mostly still, with a few things
--- animating and a steady trickle of things appearing and disappearing, and
--- the cost of those regimes is not the cost of the dense one.
---
--- Four regimes, because they stress different parts of the sync:
---
---   static   nothing changes after the field is built, so every archetype is
---            clean and the sync should write nothing at all. The floor, and
---            the only regime with an exact expected answer: zero.
---   dense    every sprite advances its animation on every fixed step, so
---            every Sprite column is dirty and the whole scene is rewritten.
---            Comparable to `make bench`, and the ceiling the other three are
---            measured against.
---   sparse   a small fraction animates and the rest hold their frame. The
---            entities are structurally identical, so they share an archetype
---            and the dirty bit is the archetype's rather than the row's: one
---            animating sprite marks the column every other sprite lives in.
---            What this measures is how far that ceiling is above the number
---            of sprites that actually changed.
---   churn    sprites appear and disappear at a steady rate, the population
---            held level. `syncInstances` sets `relayout` whenever any
---            archetype's length or offset moves, and `relayout` forces every
---            archetype dirty, so this is where a single spawn is charged the
---            whole scene.
---
--- The report prints `rewritten` beside the stage table for that reason. It is
--- the cheaper and more diagnostic signal of the two: frame time is a noisy
--- consequence, while the counter says outright how many instances were
--- rewritten to express a change of a known size. If it tracks the instance
--- count rather than the changed count, the cliff is real and no amount of
--- timing noise hides it.
---
--- The picture the sprites carry is the atlas the engine already ships, cut
--- into a grid. Extraction never looks at what a texel holds, so the content
--- is not part of what is being measured and a bench that needed its own
--- artwork would be carrying it for nothing.

local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local assets <const> = require("tecs.assets")
local filesystem <const> = require("tecs.platform.filesystem")
local sheet <const> = require("tecs.gfx.sheet")
local animation <const> = require("tecs.gfx.animation")
local timing <const> = require("tecs.timing")
local Transform <const> = tecs.Transform
local Tint <const> = tecs.gfx.Tint
local Sprite <const> = tecs.gfx.Sprite
local Renderable <const> = tecs.gfx.Renderable
local Animation <const> = animation.Animation

--- Sprites in the resident field. The churn pool sits on top of this, so the
--- instance count is this plus `BENCH_SPAWN * BENCH_LIFETIME` in that regime.
local COUNT <const> = math.floor(tonumber(os.getenv("BENCH_SPRITES")) or 200000)

--- "static", "dense", "sparse" or "churn".
local MODE <const> = os.getenv("BENCH_MODE") or "dense"

--- Fraction of the field that animates in `sparse`, 0 to 1. Every sprite
--- carries an Animation either way, so the fraction changes which of them are
--- playing and not which archetype they live in. That is the point: a crowd
--- where a few characters are walking is one archetype, not two.
local CHURN <const> = tonumber(os.getenv("BENCH_CHURN")) or 0.01

--- Resolve playback on the GPU rather than on the host.
---
--- The regime this changes is `dense` and `sparse`, and what it should change
--- is `rewritten`: a frame advancing stops being a write to the Sprite column,
--- so it stops rewriting every instance in the archetype. `churn` is untouched
--- either way, because what drives that one is the layout moving.
local GPU <const> = os.getenv("BENCH_GPU_ANIM") == "1"

--- Sprites spawned per frame in `churn`, each despawned `BENCH_LIFETIME`
--- frames later, so the population is level while the identities turn over.
local SPAWN_RATE <const> = math.floor(tonumber(os.getenv("BENCH_SPAWN")) or 64)
local LIFETIME <const> = math.floor(tonumber(os.getenv("BENCH_LIFETIME")) or 60)

--- The field the sprites are scattered over, and the viewport looking at it.
--- Copied from the shapes bench so the dense regime is comparable to it: about
--- a tenth of the field is on screen and culling does the work it exists for.
local AREA_W <const> = tonumber(os.getenv("BENCH_AREA_W")) or 4000.0
local AREA_H <const> = tonumber(os.getenv("BENCH_AREA_H")) or 2400.0

local WARMUP <const> = math.floor(tonumber(os.getenv("BENCH_WARMUP")) or 120)
local FRAMES <const> = math.floor(tonumber(os.getenv("BENCH_FRAMES")) or 300)

local WIDTH <const> = 1280
local HEIGHT <const> = 720

--- The atlas the sprites are cut from, and the grid it is cut into.
local ATLAS <const> = "fonts/jetbrainsmono-extrabold-msdf.png"
local COLUMNS <const> = 4
local ROWS <const> = 4

--- Milliseconds each frame is held. Shorter than a fixed step, so a playing
--- animation changes frame on every step it runs rather than on some of them:
--- "every sprite advances" has to mean every sprite writes.
local FRAME_MS <const> = 8.0

--- Sprites the churn pool holds once it is full.
local POOL <const> = MODE == "churn" and SPAWN_RATE * LIFETIME or 0
local TOTAL <const> = COUNT + POOL

--- Sprites whose animation is playing, which is the number of sprites that
--- change anything on a fixed step.
local PLAYING <const> = MODE == "dense" and COUNT or MODE == "sparse" and math.floor(COUNT * CHURN) or 0

timing.enable()

--- Wall time between iterations, which is the frame time a player feels. The
--- engine's own `frame` stage covers the iteration only, so the gap between
--- the two is the host loop and the presentation wait around it.
local DELTA <const> = timing.stage("delta")

local playbook: sheet.Sheet = nil
local resident: tecs.gfx.Sprite = nil

--- The churn pool, as a ring. A sprite spawned into a slot is despawned when
--- the ring comes round to that slot again, which is `LIFETIME` frames later,
--- so the population settles without a list being rebuilt every frame.
local ring: {integer} = {}
local ringAt = 0

local rewrittenTotal = 0
local rewrittenPeak = 0
local quietFrames = 0
local instances = 0

--- Scatters `count` sprites over the field.
---
--- One archetype for the lot: every sprite carries the same components, and in
--- `sparse` the ones that stand still carry an Animation that is not playing
--- rather than no Animation at all. Splitting them would put the movers in an
--- archetype of their own and the dirty gate would then be exact, which is a
--- different scene from the one a game has.
local function scatter(world: tecs.World, count: integer, animated: boolean)
    if count < 1 then
        return
    end

    local types: {tecs.ecs.Component} = animated and {Transform, Tint, Sprite, Renderable, Animation}
        or {Transform, Tint, Sprite, Renderable}

    local originX <const> = (WIDTH - AREA_W) * 0.5
    local originY <const> = (HEIGHT - AREA_H) * 0.5
    local playing <const> = PLAYING
    local cycle <const> = playbook:cycle(0)
    local rand <const> = math.random

    world:batchSpawn(
        count,
        types,
        function(archetype: tecs.ecs.Archetype, firstRow: integer, lastRow: integer)
            -- batchSpawn skips FFI defaults, so every field is written here.
            local transforms = archetype:getMut(Transform)
            local tints = archetype:getMut(Tint)
            local sprites = archetype:getMut(Sprite)
            local animations = animated and archetype:getMut(Animation) or nil

            for row = firstRow, lastRow do
                local transform = transforms[row]
                transform.x = originX + rand() * AREA_W
                transform.y = originY + rand() * AREA_H
                transform.z = 0.0
                transform.layer = 1
                transform.rotation = 0.0
                transform.scaleX = 12.0 + rand() * 16.0
                transform.scaleY = 12.0 + rand() * 16.0

                local tint = tints[row]
                tint.r = rand()
                tint.g = rand()
                tint.b = rand()
                tint.a = 1.0

                local target = sprites[row]
                target.image = resident.image
                target.slot = resident.slot
                target.u0 = resident.u0
                target.v0 = resident.v0
                target.u1 = resident.u1
                target.v1 = resident.v1

                if animations ~= nil then
                    local instance = animations[row]
                    instance.sheet = playbook.id
                    instance.tag = 0
                    instance.speed = 1.0
                    -- Spread through the cycle rather than started together, so
                    -- the field is not one animation drawn many times and the
                    -- frames a step has to write are not all the same frame.
                    instance.time = rand() * cycle
                    instance.frame = 0
                    instance.loop = true
                    instance.playing = row <= playing
                end
            end
        end
    )
end

--- One sprite, for the churn pool.
local function spawnOne(world: tecs.World, at: integer): integer
    local originX <const> = (WIDTH - AREA_W) * 0.5
    local originY <const> = (HEIGHT - AREA_H) * 0.5
    return world:spawn(
        Transform(
            originX + (at % 613) / 613.0 * AREA_W, originY + (at % 419) / 419.0 * AREA_H, 0.0, 1, 0.0, 18.0, 18.0
        ),
        Tint(1.0, 0.9, 0.4, 1.0),
        Sprite(resident.image, resident.u0, resident.v0, resident.u1, resident.v1, resident.slot),
        Renderable()
    )
end

return tecs.newApplication({
    window = {title = "sprites", width = WIDTH, height = HEIGHT},
    presentMode = "immediate",
    ambientLight = {1.0, 1.0, 1.0},
    capacity = TOTAL + 64,
    -- The default ceiling is a million slots, so a scale run has to raise it
    -- rather than discovering the limit as a spawn failure.
    maxEntities = TOTAL + 1024,
    debugMaxFrames = WARMUP + FRAMES,

    plugin = function(world: tecs.World, app: tecs.Application)
        local renderer = app.renderer
        if MODE ~= "static" and MODE ~= "dense" and MODE ~= "sparse" and MODE ~= "churn" then
            error(("tecs: no sprite bench regime '%s'"):format(MODE))
        end

        -- Blocking, because the field cannot be built before the sheet knows
        -- which layer its frames live on and there is no frame to poll from
        -- yet. A game polls `assets.update` instead.
        if not assets.installed() then
            assets.install()
        end
        local handle <const> = assets.loadImage(filesystem.assetPath(ATLAS))
        assets.waitAll()
        if handle.status ~= "ready" then
            error(("tecs: cannot load '%s': %s"):format(ATLAS, handle.error or handle.status))
        end
        local imageWidth <const> = handle.width
        local imageHeight <const> = handle.height
        resident = renderer:registerImage(handle)

        playbook = sheet.grid({
            name = "bench.sprites",
            imageWidth = imageWidth,
            imageHeight = imageHeight,
            frameWidth = imageWidth / COLUMNS,
            frameHeight = imageHeight / ROWS,
            duration = FRAME_MS,
        }):bind(resident)

        animation.useGPU(GPU)
        if MODE ~= "static" then
            animation.plugin(world)
        end

        math.randomseed(42)
        scatter(world, COUNT, MODE == "dense" or MODE == "sparse")

        if MODE == "churn" then
            print(
                ("sprites: %d resident + %d churning, %d spawned and %d " .. "despawned per frame"):format(
                    COUNT, POOL, SPAWN_RATE, SPAWN_RATE
                )
            )
        else
            print(("sprites: %d sprites over %.0fx%.0f, %d animating"):format(COUNT, AREA_W, AREA_H, PLAYING))
        end
        -- The churn and the sampling both sit in `First`, which is where the
        -- loop used to call this from: ahead of every system in the frame, so a
        -- sprite spawned here is extracted by the frame that spawned it. The
        -- one thing that is not the same is that a spawn from inside the step
        -- is applied at the next phase boundary rather than at once, which is
        -- what every other spawn in a world already does.
        local frame = 0
        world:addSystem({
            name = "bench.Churn",
            phase = tecs.ecs.phases.First,
            run = function(dt: number)
                -- Warmup frames are the ones that built and first uploaded the
                -- scene. Dropping them from every stage at once is what makes
                -- the report a distribution of the steady state rather than of
                -- the run.
                if frame == WARMUP then
                    timing.reset()
                end

                if MODE == "churn" then
                    local size <const> = POOL
                    for _ = 1, SPAWN_RATE do
                        local slot <const> = ringAt % size + 1
                        local previous <const> = ring[slot]
                        if previous ~= nil then
                            world:despawn(previous)
                        end
                        ring[slot] = spawnOne(world, ringAt)
                        ringAt = ringAt + 1
                    end
                end

                if frame >= WARMUP then
                    timing.mark(DELTA, dt)
                    -- One frame behind, since the counter is published by the
                    -- sync and this runs ahead of it. Over a run of hundreds
                    -- that shifts the window by one frame and nothing else.
                    local written <const> = renderer.rewritten
                    rewrittenTotal = rewrittenTotal + written
                    if written > rewrittenPeak then
                        rewrittenPeak = written
                    end
                    if written == 0 then
                        quietFrames = quietFrames + 1
                    end
                    instances = renderer.count
                end
                frame = frame + 1
            end,
        })

        world:addSystem({
            name = "bench.Report",
            phase = tecs.ecs.phases.Shutdown,
            run = function()
                local frames <const> = math.max(1, frame - WARMUP)
                print(
                    ("%d of %d instances synced, %d changing per fixed step"):format(
                        instances, TOTAL, MODE == "churn" and SPAWN_RATE * 2 or PLAYING
                    )
                )
                print(
                    ("rewritten %.0f mean and %d peak per frame, %d of %d " .. "frames rewrote nothing"):format(
                        rewrittenTotal / frames, rewrittenPeak, quietFrames, frames
                    )
                )
                local report = timing.format()
                if report ~= "" then
                    print(report)
                end
            end,
        })

        print(
            ("sprites: mode %s, playback on the %s, viewport %dx%d, " .. "measuring %d frames after %d warmup"):format(
                MODE, GPU and "GPU" or "host", WIDTH, HEIGHT, FRAMES, WARMUP
            )
        )
    end,
})
