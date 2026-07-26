#!/usr/bin/env luajit
-- Tween runtime benchmarks: reaching and evaluating a playback, with nothing
-- downstream of it.
--
-- Usage: make tween-bench
--
-- The Love scenario (benches/love2d/app/scenarios/tweens.lua) measures the
-- same work inside a real frame, where it is swamped by what a moving
-- Transform costs the renderer: the transform sync and the GPU upload cost
-- more per frame than the interpolation that dirtied them, and that cost
-- scales with entities rather than with playbacks.
--
-- This one runs a bare tecs world with one world:update per iteration, so
-- what it reports is the runtime itself: the dense active walk, the
-- evaluator, and the slot loop. "none" spawns the same entities and plays
-- nothing, which is the floor to read the rest against.

package.path = "../../build/?.lua;../../build/?/init.lua;../?.lua;" .. package.path

local bench = require("lib.bench")
local tecs = require("tecs")
local sequence = require("tecs2d.sequence")

local Transform = tecs.builtins.Transform

local DT = 1 / 60

local function spec(slots)
    if slots == 1 then
        return {
            sequence.tweenTo(1000.0, "linear", sequence.target.translateX, 500),
        }
    end
    return {
        sequence.tweenParallel(
            sequence.tweenTo(1000.0, "linear", sequence.target.translateX, 500),
            sequence.tweenTo(1000.0, "linear", sequence.target.translateY, 500),
            sequence.tweenTo(1000.0, "linear", sequence.target.rotation, 3),
            sequence.tweenTo(1000.0, "linear", sequence.target.scaleX, 2)),
    }
end

local programSeq = 0
local function uniqueProgramName()
    programSeq = programSeq + 1
    return "bench.tween" .. programSeq
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

-- A timeline that does nothing is a measurement of nothing.
local function verify()
    local world = setupSequence({params = {count = 4, slots = 1}})
    for _ = 1, 20 do update(world) end
    local x = world:get(1, Transform).x
    if not (x > 0) then
        error("the timeline did not move anything; the bench would measure idling")
    end
    io.write(string.format(
        "verified: Transform.x = %.6f after 20 frames\n\n", x))
end

verify()

bench.suite({
    name = "Tween runtime",
    warmupIterations = 50,
    iterations = 300,
    baseline = "none",
    variants = {
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
