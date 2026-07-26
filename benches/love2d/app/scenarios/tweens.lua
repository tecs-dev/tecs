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

local tecs = require("tecs")
local tween = require("tecs2d.tween")

local Transform = tecs.builtins.Transform

local TWEENS = tonumber(os.getenv("TECS_BENCH_TWEENS")) or 20000
local SLOTS = tonumber(os.getenv("TECS_BENCH_TWEEN_SLOTS")) or 1

return {
    render = {
        lightingMode = "forward",
        lerpingEnabled = false,
    },
    meta = {
        tweens = TWEENS,
        slotsPerTimeline = SLOTS,
    },
    setup = function(world)
        -- A duration far past the bench window, so every playback stays live
        -- for the whole run and nothing is measured mid-teardown.
        local timeline
        if SLOTS == 1 then
            timeline = tween.timeline({
                tween.to(1000.0, tween.linear, tween.translateX, 500),
            })
        else
            timeline = tween.timeline({
                tween.parallel(
                    tween.to(1000.0, tween.linear, tween.translateX, 500),
                    tween.to(1000.0, tween.linear, tween.translateY, 500),
                    tween.to(1000.0, tween.linear, tween.rotation, 3),
                    tween.to(1000.0, tween.linear, tween.scaleX, 2)),
            })
        end

        for _ = 1, TWEENS do
            timeline:play(world, world:spawn(Transform(0, 0, 0, 1)))
        end
    end,
}
