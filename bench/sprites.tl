--- Sprites at scale, and what extraction rewrites when almost nothing moved.
---
--- `cargo xtask bench shapes` measures one regime: every entity moves every frame, which is
--- the case where the dirty gate can never help and where the instance layout
--- never shifts. A game is not that. A game is mostly still, with a few things
--- animating and a steady trickle of things appearing and disappearing, and
--- the cost of those regimes is not the cost of the dense one.
---
--- Five regimes, because they stress different parts of the sync:
---
---   static   nothing changes after the field is built, so every archetype is
---            clean and the sync should write nothing at all. The floor, and
---            the only regime with an exact expected answer: zero.
---   dense    every sprite advances its animation on every fixed step, so
---            every Sprite column is dirty and the whole scene is rewritten.
---            Comparable to `cargo xtask bench shapes`, and the ceiling the other three are
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
---            whole scene. `BENCH_RESERVE` is the other layout, where a run
---            grows into slack of its own instead. What that can show here is
---            bounded: the resident field and the churn pool carry the same
---            components and share one archetype, so there is no second run
---            for a reservation to leave alone, and a spawn marks the columns
---            the whole field lives in either way. `spawner` is the regime
---            that can answer it. `BENCH_PARTIAL` is the setting that reaches
---            this one: it writes the rows the spawns and swap-pops wrote
---            rather than the run they landed in, and the two compose, so the
---            pair to compare here is reserved against reserved.
---   spawner  a still field spread over many archetypes, and a wave of
---            sprites rising and falling in an archetype of its own. Every
---            frame the wave moves by `BENCH_SPAWN` rows in one direction or
---            the other, so no frame leaves the pool's length where the last
---            one left it, and the field it sits beside never changes at all.
---            That is the one shape the two layouts answer differently:
---            packed, a length that moved lays the whole scene out again and
---            rewrites a field nothing touched; reserved, the wave grows into
---            slack of its own and the field stays resident. What reserving
---            pays for it is also only visible here, because it is paid in
---            compactions: the slots a growing run leaves behind stay in the
---            extent until one reclaims them, and a compaction rewrites
---            everything at once.
---
--- The report prints `rewritten` beside the stage table for that reason. It is
--- the cheaper and more diagnostic signal of the two: frame time is a noisy
--- consequence, while the counter says outright how many instances were
--- rewritten to express a change of a known size. If it tracks the instance
--- count rather than the changed count, the cliff is real and no amount of
--- timing noise hides it.
---
--- One thing it does not count is the slots a reserved layout blanks when a
--- run moves or shrinks, which are written and uploaded like any other. So
--- `rewritten` is the signal for a change in what the dirty gate lets through,
--- and the `extract` stage is the one to compare two layouts on.
---
--- The other number to read carefully is the instance count, which is the
--- extent the cull is dispatched over and not a population. A reserved layout
--- holds slack inside that extent, so the line reads more instances synced
--- than there are sprites, and the difference is what reserving costs the
--- cull. Neither number is the layout comparison; `extract` p50 and p95 are.
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
local files <const> = require("tecs.io.files")
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

--- "static", "dense", "sparse", "churn" or "spawner".
local MODE <const> = os.getenv("BENCH_MODE") or "dense"

--- Fraction of the field that animates in `sparse`, 0 to 1. Every sprite
--- carries an Animation either way, so the fraction changes which of them are
--- playing and not which archetype they live in. That is the point: a crowd
--- where a few characters are walking is one archetype, not two.
local CHURN <const> = tonumber(os.getenv("BENCH_CHURN")) or 0.01

--- Reads a switch whose unset value is somebody else's default.
---
--- Three states rather than two, because the bench exists to compare a setting
--- against itself: unset takes the default a game gets, `0` and `1` force a
--- side. Anything else is a typo, and a typo that reads as `0` would be
--- measured and reported as if it had been asked for.
local function switch(name: string, byDefault: boolean): boolean
    local value <const> = os.getenv(name)
    if value == nil or value == "" then
        return byDefault
    end
    if value ~= "0" and value ~= "1" then
        error(("tecs: %s takes 0 or 1, not '%s'"):format(name, value), 0)
    end
    return value == "1"
end

--- Reads a fraction whose unset value is the bench's own.
---
--- Strict for the reason `switch` is: this one decides which reservation is
--- measured, and a value that did not parse would fall back to the default and
--- be reported under the name that was asked for.
local function fraction(name: string, byDefault: number): number
    local value <const> = os.getenv(name)
    if value == nil or value == "" then
        return byDefault
    end
    local parsed <const> = tonumber(value)
    if parsed == nil or parsed < 0.0 then
        error(("tecs: %s takes a fraction of zero or more, not '%s'"):format(name, value), 0)
    end
    return parsed
end

--- Lay each archetype out in a run with room to grow rather than packing the
--- runs end to end.
---
--- Off is the engine's default, so unset measures what a game gets. What it
--- changes is what a length or an offset moving costs: packed, a run cannot
--- grow without shifting every run after it and the whole scene is rewritten;
--- reserved, a run grows into its own slack and the runs around it stay where
--- they are. `capacity` below is what decides whether the reservation is real.
local RESERVE <const> = switch("BENCH_RESERVE", false)

--- Rewrite the rows a spawn or a despawn wrote rather than the archetype's run.
---
--- Off is the engine's default, so unset measures what a game gets. The regime
--- this changes is `churn`, and it is the other half of what `BENCH_RESERVE`
--- cannot reach: reserving stops a spawn moving the runs around it, and this
--- stops it rewriting the run it landed in, which in this bench is the whole
--- field. `static` should not move at all, and `dense` and `sparse` should not
--- either: a Sprite column a value write dirtied still rewrites its run, and
--- any movement there is the split between value dirt and structural dirt
--- being wrong in the permissive direction.
local PARTIAL <const> = switch("BENCH_PARTIAL", false)

--- Sprites spawned per frame in `churn`, each despawned `BENCH_LIFETIME`
--- frames later, so the population is level while the identities turn over.
---
--- In `spawner` the same rate is the rows the wave moves per frame, up on a
--- rising frame and down on a falling one.
local SPAWN_RATE <const> = math.floor(tonumber(os.getenv("BENCH_SPAWN")) or 64)
local LIFETIME <const> = math.floor(tonumber(os.getenv("BENCH_LIFETIME")) or 60)

--- Frames the `spawner` wave takes to fill, and as many again to empty.
---
--- One is the smallest wave there is: the pool appears and is gone again, so
--- every frame either creates the archetype or empties it. Longer waves keep
--- the archetype alive and make the run grow, which is what puts slots behind
--- it and eventually asks for a compaction.
local WAVE <const> = math.floor(tonumber(os.getenv("BENCH_WAVE")) or LIFETIME)

--- Archetypes the resident field is spread over in `spawner`.
---
--- More than one is what gives a reservation something to leave alone, and the
--- number matters beyond that: `Extractor` reclaims an extent voluntarily only
--- once the slack in it passes both half of a fresh layout and a floor of 512
--- slots, and the least a still run can hold is `MIN_SLACK`, which is sixteen.
--- So a scene with 32 archetypes or fewer cannot reach that floor on slack
--- alone, and the trigger is out of reach whatever the capacity is. Sixty-four
--- puts it within reach without making the field's archetypes so small that
--- the floor is all any of them holds.
local FIELDS <const> = math.floor(tonumber(os.getenv("BENCH_FIELDS")) or 64)

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
local ATLAS <const> = "bench/sprites.png"
local COLUMNS <const> = 4
local ROWS <const> = 4

--- Milliseconds each frame is held. Shorter than a fixed step, so a playing
--- animation changes frame on every step it runs rather than on some of them:
--- "every sprite advances" has to mean every sprite writes.
local FRAME_MS <const> = 8.0

--- Sprites the churn pool holds once it is full, or the `spawner` wave holds
--- at its crest.
local POOL <const> = MODE == "churn" and SPAWN_RATE * LIFETIME or MODE == "spawner" and SPAWN_RATE * WAVE or 0
local TOTAL <const> = COUNT + POOL

--- Instance slots past the population, so a reserved layout has something to
--- reserve out of.
---
--- `Extractor` gives a run that has outgrown its slot `length` plus a quarter
--- of it, with a floor of sixteen, and when the buffer cannot afford that it
--- drops the whole layout to the floor and then to no reservation at all. So
--- the headroom decides which of the three is measured, and a capacity sized
--- to the population alone reserves sixteen slots for two hundred thousand
--- sprites and reports a packed layout under a reserved name.
---
--- A quarter of the population plus the floor is therefore what the widest
--- reservation asks for in the four regimes that hold every sprite in one
--- archetype: `static` and `churn` carry Transform, Tint, Sprite and
--- Renderable, and `dense` and `sparse` carry those plus Animation, so the sum
--- over archetypes is one term. `spawner` spreads the field over `FIELDS`
--- archetypes and puts the wave in one more, and every one of them is given
--- the floor before any of them is given a quarter, so the floor is counted
--- per run there. Packed takes the same headroom and never uses it, which is
--- the point: the two layouts are compared at one capacity and the flag is the
--- only thing that differs.
---
--- The fraction is a knob because it is the memory the reservation costs, and
--- because it is what decides which of the three reservations a compaction
--- settles on. Shrinking it is how the tiers below the widest one are reached.
local SLACK <const> = fraction("BENCH_SLACK", 0.25)
local FLOORS <const> = MODE == "spawner" and 16 * (FIELDS + 1) or 0
local HEADROOM <const> = math.floor(TOTAL * SLACK) + 16 + FLOORS

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

--- The `spawner` wave, as a stack, and the rows it holds. Rising frames push
--- and falling frames pop, so what a frame does to the pool's length is one
--- comparison rather than a list walk.
local wave: {integer} = {}
local waveHeld = 0
local waveRising = true

local rewrittenTotal = 0
local rewrittenPeak = 0
local quietFrames = 0
local instances = 0

--- Scatters `count` sprites over the field, in the archetype `marker` names.
---
--- One archetype for the lot when there is no marker: every sprite carries the
--- same components, and in `sparse` the ones that stand still carry an
--- Animation that is not playing rather than no Animation at all. Splitting
--- them would put the movers in an archetype of their own and the dirty gate
--- would then be exact, which is a different scene from the one a game has.
---
--- A marker is how `spawner` gets the other shape deliberately. It carries no
--- data and nothing reads it, so it changes which archetype a sprite lives in
--- and nothing else about the frame.
local function scatter(world: tecs.World, count: integer, animated: boolean, marker?: tecs.ecs.Component)
    if count < 1 then
        return
    end

    local types: {tecs.ecs.Component} = animated and {Transform, Tint, Sprite, Renderable, Animation}
        or {Transform, Tint, Sprite, Renderable}
    if marker ~= nil then
        types[#types + 1] = marker
    end

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

--- One sprite, for the churn pool or the `spawner` wave.
---
--- It carries no marker, which is what puts it in the field's archetype in
--- `churn` and in an archetype of its own in `spawner`, where the field carries
--- one. Marking it after the spawn instead would move the row twice and charge
--- the regime a transition a game does not pay.
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
    capacity = TOTAL + HEADROOM,
    reserveRuns = RESERVE,
    partialRewrites = PARTIAL,
    -- The default ceiling is a million slots, so a scale run has to raise it
    -- rather than discovering the limit as a spawn failure.
    maxEntities = TOTAL + 1024,
    debugMaxFrames = WARMUP + FRAMES,

    plugin = function(world: tecs.World, app: tecs.Application)
        local renderer = app.renderer
        if MODE ~= "static" and MODE ~= "dense" and MODE ~= "sparse" and MODE ~= "churn" and MODE ~= "spawner" then
            error(("tecs: no sprite bench regime '%s'"):format(MODE))
        end
        if MODE == "spawner" and (FIELDS < 1 or WAVE < 1 or SPAWN_RATE < 1) then
            error("tecs: the spawner regime needs BENCH_FIELDS, BENCH_WAVE and BENCH_SPAWN of at least one", 0)
        end

        -- Blocking, because the field cannot be built before the sheet knows
        -- which layer its frames live on and there is no frame to poll from
        -- yet. A game polls `assets.update` instead.
        if not assets.installed() then
            assets.install()
        end
        local decoding <const> = assets.loadImage(files.assetPath(ATLAS))
        assets.waitAll()
        if decoding.status ~= "ready" then
            error(("tecs: cannot load '%s': %s"):format(ATLAS, decoding.error or decoding.status))
        end
        local decoded <const> = decoding.value
        local imageWidth <const> = decoded.width
        local imageHeight <const> = decoded.height
        resident = renderer:registerImage(decoded)

        playbook = sheet.grid({
            name = "bench.sprites",
            imageWidth = imageWidth,
            imageHeight = imageHeight,
            frameWidth = imageWidth / COLUMNS,
            frameHeight = imageHeight / ROWS,
            duration = FRAME_MS,
        }):bind(resident)

        if MODE ~= "static" then
            animation.plugin(world)
        end

        math.randomseed(42)
        if MODE == "spawner" then
            -- A marker per archetype, and the field split evenly between
            -- them. The remainder goes to the first rather than being
            -- dropped, so the population is the one the report names.
            local share <const> = math.floor(COUNT / FIELDS)
            for index = 1, FIELDS do
                local marker <const> = tecs.ecs.newTagComponent({name = ("BenchSpriteField%03d"):format(index)})
                scatter(world, index == 1 and COUNT - share * (FIELDS - 1) or share, false, marker)
            end
        else
            scatter(world, COUNT, MODE == "dense" or MODE == "sparse")
        end

        if MODE == "churn" then
            print(
                ("sprites: %d resident + %d churning, %d spawned and %d " .. "despawned per frame"):format(
                    COUNT, POOL, SPAWN_RATE, SPAWN_RATE
                )
            )
        elseif MODE == "spawner" then
            print(
                ("sprites: %d still over %d archetypes, a wave of %d in one " .. "more, %d rows a frame"):format(
                    COUNT, FIELDS, POOL, SPAWN_RATE
                )
            )
        else
            print(("sprites: %d sprites over %.0fx%.0f, %d animating"):format(COUNT, AREA_W, AREA_H, PLAYING))
        end
        -- Churn and sampling both sit in `First`, ahead of every other system
        -- in the frame. A sprite spawned here is applied at the next phase
        -- boundary and extracted in the frame that spawned it.
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
                elseif MODE == "spawner" then
                    -- Every frame moves the pool's length, which is the
                    -- whole point: a length that stood still is a layout
                    -- neither of the two has to lay out again, and that is
                    -- the case `churn` already covers. The turn is taken at
                    -- the crest and at nothing left, so the wave is
                    -- `WAVE` frames up and `WAVE` frames down whatever the
                    -- rate is.
                    if waveRising then
                        for _ = 1, SPAWN_RATE do
                            waveHeld = waveHeld + 1
                            wave[waveHeld] = spawnOne(world, ringAt)
                            ringAt = ringAt + 1
                        end
                        if waveHeld >= POOL then
                            waveRising = false
                        end
                    else
                        for _ = 1, SPAWN_RATE do
                            if waveHeld < 1 then
                                break
                            end
                            world:despawn(wave[waveHeld])
                            wave[waveHeld] = nil
                            waveHeld = waveHeld - 1
                        end
                        if waveHeld < 1 then
                            waveRising = true
                        end
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
                -- Said again at the end, so a pasted report carries what it
                -- was measuring rather than only what came out.
                print(
                    ("sprites: mode %s, runs %s, rewrites %s"):format(
                        MODE, RESERVE and "reserved" or "packed", PARTIAL and "partial" or "whole-run"
                    )
                )
                -- The first number is the extent the cull is dispatched
                -- over, which a reserved layout holds slack inside, so it
                -- reads above the population and is not one. The gap is
                -- what reserving costs the cull.
                print(
                    ("%d of %d instances synced, %d changing per fixed step"):format(
                        instances,
                        TOTAL,
                        MODE == "churn" and SPAWN_RATE * 2 or MODE == "spawner" and SPAWN_RATE or PLAYING
                    )
                )
                -- `rewritten` counts the slots written from a component column
                -- and not the ones a reserved layout blanks when a run moves,
                -- an archetype leaves or a run shrinks, so it under-reports
                -- reserved and the two layouts are not comparable through it.
                -- The `extract` stage below is, p50 and p95 together.
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
            (
                "sprites: mode %s, runs %s in %d slots, "
                .. "rewrites %s, viewport %dx%d, measuring %d frames after %d warmup"
            ):format(
                MODE,
                RESERVE and "reserved" or "packed",
                TOTAL + HEADROOM,
                PARTIAL and "partial" or "whole-run",
                WIDTH,
                HEIGHT,
                FRAMES,
                WARMUP
            )
        )
    end,
})
