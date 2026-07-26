#!/usr/bin/env luajit
-- Tween runtime benchmarks: reaching and evaluating a playback, with nothing
-- downstream of it.
--
-- Usage: make tween-bench
--
-- The Love scenario (benches/love2d/app/scenarios/tweens.lua) measures the
-- same work inside a real frame, where it is swamped by what a moving
-- Transform costs the renderer. This one runs a bare tecs world and one
-- world:update per iteration, so what it reports is the runtime itself:
--
--   tween     the shipping runtime -- query, archetype, TweenPlayback,
--             cursor list, registry lookup, per playback per frame
--   sequence  the same timeline compiled to a program, walked from its
--             clock's dense active array
--
-- Both variants are asserted to produce identical Transform.x before timing,
-- so a difference in speed is never a difference in work.

package.path = "../../build/?.lua;../../build/?/init.lua;../?.lua;" .. package.path

local bench = require("lib.bench")
local tecs = require("tecs")
local tween = require("tecs2d.tween")
local sequence = require("tecs2d.sequence")

local Transform = tecs.builtins.Transform

local DT = 1 / 60

local function spec(slots)
    if slots == 1 then
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

local programSeq = 0
local function uniqueProgramName()
    programSeq = programSeq + 1
    return "bench.tween" .. programSeq
end

local function setupTween(case)
    local world = tecs.newWorld()
    world:addPlugin(tween.plugin)
    world:startup()
    local timeline = tween.timeline(spec(case.params.slots))
    for _ = 1, case.params.count do
        timeline:play(world, world:spawn(Transform(0, 0, 0, 1)))
    end
    return world
end

local function setupSequence(case)
    local world = tecs.newWorld()
    world:addPlugin(sequence.plugin)
    world:startup()
    local program = sequence.timeline(uniqueProgramName(), spec(case.params.slots))
    for _ = 1, case.params.count do
        sequence.play(world, program, {owner = world:spawn(Transform(0, 0, 0, 1))})
    end
    -- play schedules the first instruction one tick out, so one update lands
    -- every eval and the timed updates are all steady state.
    world:update(0)
    return world
end

-- A world with the playbacks' entities and no playbacks: the floor both
-- variants are read against.
local function setupNone(case)
    local world = tecs.newWorld()
    world:addPlugin(sequence.plugin)
    world:startup()
    for _ = 1, case.params.count do
        world:spawn(Transform(0, 0, 0, 1))
    end
    return world
end

local function update(world)
    world:update(DT)
end

-- Same work, or the comparison means nothing.
local function verify()
    local case = {params = {count = 4, slots = 1}}
    local a, b = setupTween(case), setupSequence(case)
    for _ = 1, 20 do
        update(a)
        update(b)
    end
    local ax = a:get(1, Transform).x
    local bx = b:get(1, Transform).x
    if math.abs(ax - bx) > 1e-9 then
        error(string.format(
            "variants disagree: tween x=%.17g, sequence x=%.17g", ax, bx))
    end
    io.write(string.format(
        "verified: both paths reach Transform.x = %.6f after 20 frames\n\n", ax))
end

verify()

bench.suite({
    name = "Tween runtime",
    warmupIterations = 50,
    iterations = 300,
    baseline = "tween",
    variants = {
        {name = "tween", setup = setupTween, run = update},
        {name = "sequence", setup = setupSequence, run = update},
        {name = "none", setup = setupNone, run = update},
    },
    cases = {
        {
            name = "playbacks x slots",
            parameters = {count = {2000, 20000}, slots = {1, 4}},
        },
    },
})
