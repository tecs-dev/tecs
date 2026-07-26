--- Tween playback load: N entities each running a long timeline that never
--- completes, on an otherwise empty scene. Measures the tween runtime -- how a
--- playback is reached and evaluated -- rather than rendering.
---
--- This is the baseline the unified-runtime work is measured against. The
--- shipping path reaches a cursor through
---   query -> archetype -> TweenPlayback -> pb.cursors -> registry lookup
--- once per playback per frame, which is most of its cost: a zero-slot
--- timeline still runs ~217ns/playback/frame, against ~70ns for the slot
--- evaluation itself.
---
--- TECS_BENCH_TWEENS       playbacks (default 20000)
--- TECS_BENCH_TWEEN_SLOTS  concurrent slots per timeline, 1 or 4 (default 1)
--- TECS_BENCH_TWEEN_ENTS   entities the playbacks are spread over (default:
---                         one each). Fewer entities than playbacks separates
---                         the runtime cost from the cost of what it dirties:
---                         a moving Transform re-uploads to the GPU every
---                         frame, which scales with entities, while reaching
---                         and evaluating a playback scales with playbacks.
--- TECS_BENCH_TWEEN_PATH   "tween" (the shipping runtime), "sequence" (the
---                         same timeline compiled to a program and run as an
---                         evaluator), or "none" (spawn the entities and play
---                         nothing). Default "tween".
---
--- "none" is the floor the other two are read against: the entities alone
--- cost transform sync and rendering every frame, and that is charged to both
--- paths. Subtract it before dividing by the playback count, or the shared
--- cost swamps the difference being measured.

local tecs = require("tecs")
local tween = require("tecs2d.tween")
local sequence = require("tecs2d.sequence")

local Transform = tecs.builtins.Transform

local TWEENS = tonumber(os.getenv("TECS_BENCH_TWEENS")) or 20000
local SLOTS = tonumber(os.getenv("TECS_BENCH_TWEEN_SLOTS")) or 1
local PATH = os.getenv("TECS_BENCH_TWEEN_PATH") or "tween"
local ENTS = tonumber(os.getenv("TECS_BENCH_TWEEN_ENTS")) or TWEENS

-- A duration far past the bench window, so every playback stays live for the
-- whole run and nothing is measured mid-teardown.
local function spec()
    if SLOTS == 1 then
        return {
            tween.to(1000.0, tween.linear, tween.translateX, 500),
        }
    end
    return {
        tween.parallel(
            tween.to(1000.0, tween.linear, tween.translateX, 500),
            tween.to(1000.0, tween.linear, tween.translateY, 500),
            tween.to(1000.0, tween.linear, tween.rotation, 3),
            tween.to(1000.0, tween.linear, tween.scaleX, 2)),
    }
end

return {
    render = {
        lightingMode = "forward",
        lerpingEnabled = false,
    },
    meta = {
        tweens = TWEENS,
        slotsPerTimeline = SLOTS,
        entities = ENTS,
        path = PATH,
    },
    setup = function(world)
        local entities = {}
        for i = 1, ENTS do
            entities[i] = world:spawn(Transform(0, 0, 0, 1))
        end
        if PATH == "none" then return end

        if PATH == "sequence" then
            local program = sequence.timeline("bench.tweens", spec())
            for i = 1, TWEENS do
                sequence.play(world, program,
                    {owner = entities[(i - 1) % ENTS + 1]})
            end
            return
        end
        if PATH ~= "tween" then
            error("TECS_BENCH_TWEEN_PATH must be 'tween', 'sequence', or 'none'")
        end
        local timeline = tween.timeline(spec())
        for i = 1, TWEENS do
            timeline:play(world, entities[(i - 1) % ENTS + 1])
        end
    end,
}
