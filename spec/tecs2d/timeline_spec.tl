require("busted")

local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local sequence <const> = require("tecs2d.sequence")
local type EasingFunction = sequence.EasingFunction

local Transform <const> = tecs.builtins.Transform

-- These structural views are intentionally test-only. The public handles are
-- narrow; this suite inspects compiler/playback state only when testing the
-- compiler and snapshot implementation itself.
local interface TargetImpl
    init: function(
        world: tecs.World, entity: integer, relative: boolean,
        t1: number, t2: number, t3: number, t4: number
    ): number, number, number, number, number, number, number, number
    apply: function(
        world: tecs.World, entity: integer, t: number,
        s1: number, s2: number, s3: number, s4: number,
        d1: number, d2: number, d3: number, d4: number
    )
end

local interface TimelineSlotImpl
    startTime: number
    endTime: number
end

local interface TimelineImpl
    slots: {TimelineSlotImpl}
    totalDuration: number
end

-- Timelines compile to programs, which are global and keyed by name, so
-- every test compiles under a name of its own.
local nameCounter = 0
local function uniqueName(): string
    nameCounter = nameCounter + 1
    return "spec.timeline" .. tostring(nameCounter)
end

local function makeWorld(): tecs.World
    local world = tecs.newWorld()
    world:addPlugin(sequence.plugin)
    world:startup()
    return world
end

local function tick(world: tecs.World, dt: number)
    world:update(dt)
end

--- Compile a spec and start it on an entity, returning the handle.
---
--- `play` schedules a playback's first instruction one tick out, so the
--- zero-length update below lands the eval and leaves the timeline running
--- from elapsed zero. Every test after it advances real time.
local function play(
    world: tecs.World,
    entity: integer,
    spec: sequence.TimelineSpec,
    params?: {string: any},
    channel?: string
): sequence.Handle
    local handle <const> = sequence.play(world, sequence.timeline(uniqueName(), spec),
        {owner = entity, params = params, channel = channel})
    world:update(0)
    return handle
end

--- Compile a spec and hand back its compiled form. Compiling writes the
--- resolved slots into the spec table itself, so the same table is both.
local function compile(spec: sequence.TimelineSpec): sequence.TimelineSpec
    sequence.timeline(uniqueName(), spec)
    return spec
end

--- Whether a playback is still running.
local function isPlaying(world: tecs.World, handle: sequence.Handle): boolean
    local status <const> = sequence.status(world, handle)
    return status ~= nil and status.state == "running"
end

-------------------------------------------------------------------------------
-- Easing tests
-------------------------------------------------------------------------------

describe("easing", function()
    local allEasings: {string: EasingFunction} = {
        linear = sequence.easing.linear,
        quadIn = sequence.easing.quadIn,
        quadOut = sequence.easing.quadOut,
        quadInOut = sequence.easing.quadInOut,
        quadOutIn = sequence.easing.quadOutIn,
        cubicIn = sequence.easing.cubicIn,
        cubicOut = sequence.easing.cubicOut,
        cubicInOut = sequence.easing.cubicInOut,
        cubicOutIn = sequence.easing.cubicOutIn,
        quartIn = sequence.easing.quartIn,
        quartOut = sequence.easing.quartOut,
        quartInOut = sequence.easing.quartInOut,
        quartOutIn = sequence.easing.quartOutIn,
        quintIn = sequence.easing.quintIn,
        quintOut = sequence.easing.quintOut,
        quintInOut = sequence.easing.quintInOut,
        quintOutIn = sequence.easing.quintOutIn,
        sineIn = sequence.easing.sineIn,
        sineOut = sequence.easing.sineOut,
        sineInOut = sequence.easing.sineInOut,
        sineOutIn = sequence.easing.sineOutIn,
        expoIn = sequence.easing.expoIn,
        expoOut = sequence.easing.expoOut,
        expoInOut = sequence.easing.expoInOut,
        expoOutIn = sequence.easing.expoOutIn,
        backIn = sequence.easing.backIn,
        backOut = sequence.easing.backOut,
        backInOut = sequence.easing.backInOut,
        backOutIn = sequence.easing.backOutIn,
        elasticIn = sequence.easing.elasticIn,
        elasticOut = sequence.easing.elasticOut,
        elasticInOut = sequence.easing.elasticInOut,
        elasticOutIn = sequence.easing.elasticOutIn,
        bounceIn = sequence.easing.bounceIn,
        bounceOut = sequence.easing.bounceOut,
        bounceInOut = sequence.easing.bounceInOut,
        bounceOutIn = sequence.easing.bounceOutIn,
    }

    for name, fn in pairs(allEasings) do
        it(name .. ": f(0) == 0 and f(1) == 1", function()
            luassert.is_near(0, fn(0), 1e-9, name .. "(0) should be 0")
            luassert.is_near(1, fn(1), 1e-9, name .. "(1) should be 1")
        end)
    end

    it("linear: f(0.5) == 0.5", function()
        luassert.is_near(0.5, sequence.easing.linear(0.5), 1e-9)
    end)
end)

-------------------------------------------------------------------------------
-- Target tests
-------------------------------------------------------------------------------

describe("targets", function()
    local world: tecs.World

    before_each(function()
        world = makeWorld()
    end)

    after_each(function()
        if world then
            world:shutdown()
        end
    end)

    it("tween.field init/apply captures start value and tweens to target", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local target <const> = sequence.target.field(Transform, "x") as TargetImpl
        local s1, s2, s3, s4, d1, d2, d3, d4 = target.init(world, entity, false, 200, 0, 0, 0)

        target.apply(world, entity, 0, s1, s2, s3, s4, d1, d2, d3, d4)
        luassert.is_near(0, world:get(entity, Transform).x, 1e-3)

        target.apply(world, entity, 0.5, s1, s2, s3, s4, d1, d2, d3, d4)
        luassert.is_near(100, world:get(entity, Transform).x, 1e-3)

        target.apply(world, entity, 1, s1, s2, s3, s4, d1, d2, d3, d4)
        luassert.is_near(200, world:get(entity, Transform).x, 1e-3)
    end)

    it("convenience targets are reusable references", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local s1, s2, s3, s4, d1, d2, d3, d4: number, number, number, number, number, number, number, number

        local translateX <const> = sequence.target.translateX as TargetImpl
        s1, s2, s3, s4, d1, d2, d3, d4 = translateX.init(world, entity, false, 100, 0, 0, 0)
        translateX.apply(world, entity, 1, s1, s2, s3, s4, d1, d2, d3, d4)
        luassert.is_near(100, world:get(entity, Transform).x, 1e-3)

        local translateY <const> = sequence.target.translateY as TargetImpl
        s1, s2, s3, s4, d1, d2, d3, d4 = translateY.init(world, entity, false, 50, 0, 0, 0)
        translateY.apply(world, entity, 1, s1, s2, s3, s4, d1, d2, d3, d4)
        luassert.is_near(50, world:get(entity, Transform).y, 1e-3)

        local rotation <const> = sequence.target.rotation as TargetImpl
        s1, s2, s3, s4, d1, d2, d3, d4 = rotation.init(world, entity, false, math.pi, 0, 0, 0)
        rotation.apply(world, entity, 1, s1, s2, s3, s4, d1, d2, d3, d4)
        luassert.is_near(math.pi, world:get(entity, Transform).rotation, 1e-3)
    end)

    it("tween.field works with custom components", function()
        local CustomComp = tecs.newComponent({
            name = "TweenTestCustom",
            container = {} as tecs.Component,
            fields = {"fill"},
            init = function(instance: tecs.Component, fill: number)
                (instance as {string: any}).fill = fill
            end
        })

        local entity = world:spawn(Transform(0, 0), CustomComp(0) as tecs.Component)
        tick(world, 0)

        local tweenFill <const> = sequence.target.field(CustomComp, "fill") as TargetImpl
        local s1, s2, s3, s4, d1, d2, d3, d4 = tweenFill.init(world, entity, false, 1, 0, 0, 0)
        tweenFill.apply(world, entity, 0.5, s1, s2, s3, s4, d1, d2, d3, d4)
        luassert.is_near(0.5, (world:get(entity, CustomComp) as {string:number}).fill, 1e-3)
    end)

    it("tween.target rejects more than two fields", function()
        local CustomComp = tecs.newComponent({
            name = "TweenTestTooManyFields",
            container = {} as tecs.Component,
            fields = {"a", "b", "c"},
        })

        luassert.has_error(function()
            sequence.target.of(CustomComp, {"a", "b", "c"})
        end, "tween.target supports one or two fields")
    end)
end)

-------------------------------------------------------------------------------
-- Timeline system tests
-------------------------------------------------------------------------------

describe("timeline system", function()
    local world: tecs.World

    before_each(function()
        world = makeWorld()
    end)

    after_each(function()
        if world then
            world:shutdown()
        end
    end)

    it("basic tween advances and updates target each frame", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        })

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 1e-1)

        tick(world, 0.5)
        luassert.is_near(100, world:get(entity, Transform).x, 1e-1)
    end)

    it("cursor is removed on completion", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateX, 100),
        })

        tick(world, 0.25)
        luassert.is_near(50, world:get(entity, Transform).x, 1e-1)

        tick(world, 0.5)
        luassert.is_near(100, world:get(entity, Transform).x, 1e-1)

        -- Verify timeline removed: manually change x and check it stays
        local t = world:get(entity, Transform)
        t.x = 999
        world:markComponentDirty(entity, Transform as tecs.Component)
        tick(world, 0.1)
        luassert.is_near(999, world:get(entity, Transform).x, 1e-1)
    end)

    it("runs root entries sequentially", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateX, 100),
            sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateY, 200),
        })

        tick(world, 0.25)
        luassert.is_near(50, world:get(entity, Transform).x, 1e-1)
        luassert.is_near(0, world:get(entity, Transform).y, 1e-1)

        tick(world, 0.5)
        luassert.is_near(100, world:get(entity, Transform).x, 1e-1)
        luassert.is_near(100, world:get(entity, Transform).y, 2)
    end)

    it("wait adds a gap between entries", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(0.3, sequence.easing.linear, sequence.target.translateX, 100),
            sequence.tweenWait(0.2),
            sequence.tweenTo(0.3, sequence.easing.linear, sequence.target.translateY, 100),
        })

        tick(world, 0.3)
        luassert.is_near(100, world:get(entity, Transform).x, 1e-1)
        luassert.is_near(0, world:get(entity, Transform).y, 1e-1)

        -- During pause
        tick(world, 0.2)
        luassert.is_near(0, world:get(entity, Transform).y, 1e-1)

        -- After pause + second tween
        tick(world, 0.3)
        luassert.is_near(100, world:get(entity, Transform).y, 1e-1)
    end)

    it("does not rewrite a completed slot during a wait", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(0.1, "linear", "transform.x", 100),
            sequence.tweenWait(1),
        })

        tick(world, 0.1)
        local transform = world:getMut(entity, Transform)
        transform.x = 40
        tick(world, 0.2)

        luassert.is_near(40, world:get(entity, Transform).x, 1e-9)
    end)

    it("pingPong: direction reverses, values go back", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        }, {mode = "pingPong", count = 2})

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 1e-1)

        tick(world, 0.5)

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        tick(world, 0.5)
        luassert.is_near(0, world:get(entity, Transform).x, 2)
    end)

    it("loop count is the total number of passes", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local handle = play(world, entity, {
            sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateX, 100),
        }, {mode = "loop", count = 2})

        tick(world, 0.5)
        luassert.is_true(isPlaying(world, handle))

        tick(world, 0.5)
        luassert.equals("completed", sequence.status(world, handle).state)
    end)

    it("consumes every loop pass crossed by one update", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenAdjust(1, "linear", "transform.x", 10),
        }, {mode = "loop", count = 3})
        local handle <const> = sequence.playbacks(world)[1]

        tick(world, 2.5)
        luassert.is_near(25, world:get(entity, Transform).x, 1e-9)

        luassert.is_true(isPlaying(world, handle),
            "two of three passes are done; the third is still running")
    end)

    it("preserves ping-pong overshoot in the same update", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(1, "linear", "transform.x", 100),
        }, {mode = "pingPong", count = 2})

        tick(world, 1.25)
        luassert.is_near(75, world:get(entity, Transform).x, 1e-9)
    end)

    it("loop() infinite: keeps running", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateX, 100),
        }, {mode = "loop"})

        for _ = 1, 10 do
            tick(world, 0.25)
            tick(world, 0.25)
        end

        luassert.is_truthy(world:isAlive(entity))
    end)

    it("timeline removed when target entity dies", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        }, {mode = "loop"})

        tick(world, 0.1)
        world:despawn(entity)
        tick(world, 0.1)

        -- Should not error on further ticks
        tick(world, 0.1)
        tick(world, 0.1)
    end)

    it("TweenComplete event fires when timeline finishes", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local handle = play(world, entity, {
            sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateX, 100),
        })

        tick(world, 0.25)
        luassert.is_true(isPlaying(world, handle))

        tick(world, 0.5)
        luassert.equals("completed", sequence.status(world, handle).state)
    end)
end)

-------------------------------------------------------------------------------
-- Playback token tests
-------------------------------------------------------------------------------

describe("playback tokens", function()
    local world: tecs.World

    before_each(function()
        world = makeWorld()
    end)

    after_each(function()
        if world then world:shutdown() end
    end)

    local function shortSpec(): sequence.TimelineSpec
        return {
            sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateX, 100),
        }
    end

    local function playShort(
        entity: integer, channel?: string
    ): sequence.Handle
        local handle <const> = sequence.play(world,
            sequence.timeline(uniqueName(), shortSpec()),
            {owner = entity, channel = channel})
        world:update(0)
        return handle
    end

    local function stateOf(handle: sequence.Handle): string
        local status <const> = sequence.status(world, handle)
        return status and status.state as string or nil
    end

    it("hands every playback its own handle", function()
        local a = world:spawn(Transform(0, 0))
        local b = world:spawn(Transform(0, 0))
        tick(world, 0)

        local first = playShort(a)
        local second = playShort(a)
        local third = playShort(b)

        luassert.is_number(first)
        luassert.not_equals(first, second, "two runs on one entity are two playbacks")
        luassert.not_equals(second, third)
        luassert.is_true(isPlaying(world, first))
    end)

    it("reports a completed playback on its handle", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local handle = playShort(entity)
        luassert.is_true(isPlaying(world, handle))

        tick(world, 0.6)
        luassert.equals("completed", stateOf(handle))
    end)

    it("reports a cancelled playback", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local handle = playShort(entity)
        luassert.is_true(sequence.cancel(world, handle))

        luassert.equals("cancelled", stateOf(handle))
        luassert.is_false(isPlaying(world, handle))
    end)

    it("reports a playback replaced on its channel", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local first = playShort(entity, "move")
        local second = playShort(entity, "move")

        luassert.equals("cancelled", stateOf(first),
            "the second playback took the channel from the first")
        luassert.is_true(isPlaying(world, second))
    end)

    it("reports a playback whose entity died", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local handle = playShort(entity)
        world:despawn(entity)
        world:commit()

        luassert.equals("cancelled", stateOf(handle),
            "a dead owner must not leave a playback running")
        luassert.is_false(isPlaying(world, handle))
    end)

    it("ends a playback exactly once", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local handle = playShort(entity)
        luassert.is_true(sequence.cancel(world, handle))
        luassert.is_false(sequence.cancel(world, handle),
            "a finished playback cannot end a second time")
        tick(world, 1.0)
        world:despawn(entity)
        world:commit()
        luassert.equals("cancelled", stateOf(handle))
    end)

    it("keeps a handle meaningful across a snapshot", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)
        local handle = playShort(entity)

        local saved = world:saveSnapshot().buffer
        world:loadSnapshot(saved)

        luassert.is_true(isPlaying(world, handle),
            "the same handle names the same playback after a load")
        tick(world, 0.6)
        luassert.equals("completed", stateOf(handle))
    end)

    it("does not reissue a handle after a snapshot load", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)
        local first = playShort(entity)

        local saved = world:saveSnapshot().buffer
        world:loadSnapshot(saved)

        local second = playShort(entity)
        luassert.not_equals(first, second)
    end)
end)

-------------------------------------------------------------------------------
-- Timeline compilation tests
-------------------------------------------------------------------------------

describe("timeline compilation", function()
    it("parallel entries get the same start time", function()
        local def <const> = {
            sequence.tweenParallel(
                sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateX, 100),
                sequence.tweenTo(0.3, sequence.easing.linear, sequence.target.translateY, 100)),
        }

        local impl <const> = compile(def) as TimelineImpl
        luassert.is_equal(impl.slots[1].startTime, impl.slots[2].startTime)
        luassert.is_equal(0, impl.slots[1].startTime)
    end)

    it("parallel advances by its longest entry", function()
        local def <const> = {
            sequence.tweenParallel(
                sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateX, 100),
                sequence.tweenTo(0.3, sequence.easing.linear, sequence.target.translateY, 100)),
            sequence.tweenTo(0.4, sequence.easing.linear, sequence.target.rotation, 1),
        }

        luassert.is_equal(0.5, (compile(def) as TimelineImpl).slots[3].startTime)
    end)

    it("wait advances the time offset", function()
        local def <const> = {
            sequence.tweenTo(0.3, sequence.easing.linear, sequence.target.translateX, 100),
            sequence.tweenWait(0.2),
            sequence.tweenTo(0.4, sequence.easing.linear, sequence.target.translateY, 100),
        }

        luassert.is_equal(0.5, (compile(def) as TimelineImpl).slots[2].startTime)
    end)

    it("compiles the supplied nodes in place", function()
        local operation = sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateX, 100)
        local spec = {operation}
        local timeline <const> = spec

        luassert.is_true(rawequal(timeline, spec))
        local impl <const> = compile(timeline) as TimelineImpl
        luassert.is_true(rawequal(impl.slots[1], operation))
        luassert.is_equal(0, impl.slots[1].startTime)
        luassert.is_equal(0.5, impl.slots[1].endTime)
    end)

    it("resolves serializable easing and target names", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(1.0, "linear", "transform.x", 100),
        })

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        world:shutdown()
    end)

    it("supports sequential branches inside parallel", function()
        local def <const> = {
            sequence.tweenParallel(
                {
                    sequence.tweenTo(0.2, "linear", "transform.x", 10),
                    sequence.tweenTo(0.3, "linear", "transform.y", 20)},
                sequence.tweenTo(0.4, "linear", "transform.rotation", 1)),
            sequence.tweenTo(0.1, "linear", "transform.scaleX", 2),
        }

        local impl <const> = compile(def) as TimelineImpl
        luassert.is_equal(0, impl.slots[1].startTime)
        luassert.is_equal(0.2, impl.slots[2].startTime)
        luassert.is_equal(0, impl.slots[3].startTime)
        luassert.is_equal(0.5, impl.slots[4].startTime)
    end)

    it("rejects malformed entries", function()
        luassert.has_error(function()
            sequence.timeline(uniqueName(), {{} as any} as sequence.TimelineSpec)
        end, nil)
    end)

    it("does not accept a named sequence", function()
        luassert.has_error(function()
            sequence.timeline(uniqueName(), ({
                sequence = {
                    sequence.tweenTo(0.5, "linear", "transform.x", 100),
                },
            } as any) as sequence.TimelineSpec)
        end, nil)
    end)

    it("reusable: same def played on multiple entities creates independent timelines", function()
        local world = makeWorld()

        local e1 = world:spawn(Transform(0, 0))
        local e2 = world:spawn(Transform(0, 0))
        tick(world, 0)

        local def <const> = {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        }

        play(world, e1, def)
        tick(world, 0.5)

        play(world, e2, def)
        tick(world, 0.25)

        luassert.is_near(75, world:get(e1, Transform).x, 2)
        luassert.is_near(25, world:get(e2, Transform).x, 2)

        world:shutdown()
    end)

    it("keeps multiple plays created in one deferred scope", function()
        local world = makeWorld()
        world:spawn(Transform(0, 0))
        tick(world, 0)

        local query <const> = world:query({include = {Transform}})
        local xProgram <const> = sequence.timeline(uniqueName(), {
            sequence.tweenTo(1, "linear", "transform.x", 100),
        })
        local yProgram <const> = sequence.timeline(uniqueName(), {
            sequence.tweenTo(1, "linear", "transform.y", 100),
        })
        local played = false
        world:addSystem({
            name = "tween.SpecDeferredPlay",
            phase = tecs.phases.Update,
            run = function()
                if played then return end
                for _, len, entities in query:iter() do
                    for i = 1, len do
                        sequence.play(world, xProgram, {owner = entities[i]})
                        sequence.play(world, yProgram, {owner = entities[i]})
                    end
                end
                played = true
            end,
        })

        tick(world, 0)
        tick(world, 0)
        luassert.equals(2, sequence.activeCount(world),
            "both timelines started from inside the deferred region")
        world:shutdown()
    end)

    it("run uses the child timeline duration", function()
        local sub <const> = {
            sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateY, 100),
        }

        local def <const> = {
            sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateX, 100),
            sequence.tweenRun(sub),
        }

        luassert.is_near(1.0, (compile(def) as TimelineImpl).totalDuration, 1e-9)
    end)

    it("run options repeat a child for a finite pass count", function()
        local sub <const> = {
            sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateY, 100),
        }

        local def <const> = {
            sequence.tweenRun(sub, {mode = "loop", count = 3}),
        }

        luassert.is_near(1.5, (compile(def) as TimelineImpl).totalDuration, 1e-9)
    end)

    it("consumes every nested run pass crossed by one update", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local child <const> = {
            sequence.tweenAdjust(1, "linear", "transform.x", 10),
        }
        play(world, entity, {
            sequence.tweenRun(child, {mode = "loop", count = 3}),
        })

        tick(world, 2.5)
        luassert.is_near(25, world:get(entity, Transform).x, 1e-9)
        world:shutdown()
    end)

    it("run pingPong alternates child passes", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)
        local child <const> = {
            sequence.tweenTo(1.0, "linear", "transform.x", 100),
        }
        play(world, entity, {
            sequence.tweenRun(child, {mode = "pingPong", count = 2}),
        })

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        tick(world, 0.5)
        luassert.is_near(100, world:get(entity, Transform).x, 2)
        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        tick(world, 0.5)
        luassert.is_near(0, world:get(entity, Transform).x, 2)
        world:shutdown()
    end)

    it("rejects an unbounded nested run", function()
        local sub <const> = {
            sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateY, 100),
        }

        luassert.has_error(function()
            sequence.timeline(uniqueName(), {
                sequence.tweenRun(sub, {mode = "loop"}),
            })
        end, nil)
    end)

    it("cancel removes active cursor", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        }, {mode = "loop"})

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        sequence.cancelOwnedBy(world, entity)

        local t = world:get(entity, Transform)
        t.x = 999
        world:markComponentDirty(entity, Transform as tecs.Component)

        tick(world, 0.5)
        luassert.is_near(999, world:get(entity, Transform).x, 1e-1)

        world:shutdown()
    end)

    it("can reapply an anonymous timeline after completion", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local def <const> = {
            sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateX, 100),
        }

        play(world, entity, def)
        tick(world, 0.6)
        luassert.is_near(100, world:get(entity, Transform).x, 2)

        local transform = world:getMut(entity, Transform)
        transform.x = 0
        world:markComponentDirty(entity, Transform as tecs.Component)

        play(world, entity, def)
        tick(world, 0.25)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        world:shutdown()
    end)

    it("can reapply an anonymous timeline after cancel", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local def <const> = {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        }

        play(world, entity, def, {mode = "loop"})
        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        sequence.cancelOwnedBy(world, entity)
        tick(world, 0.01)

        local transform = world:getMut(entity, Transform)
        transform.x = 0
        world:markComponentDirty(entity, Transform as tecs.Component)

        play(world, entity, def, {mode = "loop"})
        tick(world, 0.25)
        luassert.is_near(25, world:get(entity, Transform).x, 2)

        world:shutdown()
    end)

    it("resumes active playbacks after snapshot load", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        })

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        local snap = world:saveSnapshot()
        world:loadSnapshot(snap)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        tick(world, 0.25)
        luassert.is_near(75, world:get(entity, Transform).x, 2)

        world:shutdown()
    end)

    it("resumes active playbacks after table snapshot load", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        })

        tick(world, 0.5)
        local snap = world:saveSnapshot({format = "table"})

        world:loadSnapshot(snap)
        tick(world, 0.25)
        luassert.is_near(75, world:get(entity, Transform).x, 2)

        world:shutdown()
    end)

    it("restores playback mode, remaining passes, and direction", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(1.0, "linear", "transform.x", 100),
        }, {mode = "pingPong", count = 2})

        tick(world, 1.0)
        luassert.is_near(100, world:get(entity, Transform).x, 2)
        local snap = world:saveSnapshot({format = "table"})
        world:loadSnapshot(snap)

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        tick(world, 0.5)
        luassert.is_near(0, world:get(entity, Transform).x, 2)
        luassert.equals(0, sequence.activeCount(world))

        world:shutdown()
    end)

    it("serializes nested run templates across snapshot load", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local child <const> = {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateY, 100),
        }

        local parent <const> = {
            sequence.tweenTo(0.5, sequence.easing.linear, sequence.target.translateX, 50),
            sequence.tweenRun(child),
        }

        play(world, entity, parent)
        tick(world, 0.75)
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        luassert.is_near(25, world:get(entity, Transform).y, 2)

        local snap = world:saveSnapshot({format = "table"})
        world:loadSnapshot(snap)
        tick(world, 0.25)

        luassert.is_near(50, world:get(entity, Transform).x, 2)
        luassert.is_near(50, world:get(entity, Transform).y, 2)

        world:shutdown()
    end)

    it("plays a timeline by name straight after compiling it", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        sequence.timeline("spec.immediate", {
            sequence.tweenTo(1, "linear", "transform.x", 100),
        })
        sequence.play(world, sequence.program("spec.immediate"), {owner = entity})
        world:update(0)

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 1e-9)
        world:shutdown()
    end)

    it("keeps a timeline nothing is playing across a snapshot load", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        sequence.timeline("spec.inactive", {
            sequence.tweenTo(0.1, "linear", "transform.x", 10),
        })
        sequence.play(world, sequence.program("spec.inactive"), {owner = entity})
        world:update(0)
        tick(world, 0.2)
        luassert.equals(0, sequence.activeCount(world))

        local snap <const> = world:saveSnapshot({format = "table"})
        world:loadSnapshot(snap)
        local transform = world:getMut(entity, Transform)
        transform.x = 0

        sequence.play(world, sequence.program("spec.inactive"), {owner = entity})
        world:update(0)
        tick(world, 0.05)
        luassert.is_near(5, world:get(entity, Transform).x, 1e-9)
        world:shutdown()
    end)

    it("does not duplicate templates across save/load/play cycles", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        -- Keep cursors and their templates live at save time.
        local child <const> = {
            sequence.tweenTo(0.2, sequence.easing.linear, sequence.target.translateY, 10),
        }
        local preset <const> = sequence.timeline("spec.nested", {
            sequence.tweenTo(0.2, sequence.easing.linear, sequence.target.translateX, 10),
            sequence.tweenRun(child, {mode = "loop", count = 3}),
        })

        local function programCount(snap: {string:any}): integer
            local inner = snap.snapshot as {string:any}
            local dataEntries = inner and inner.data as {{string:any}}
            if not dataEntries then return -1 end
            for i = 1, #dataEntries do
                if dataEntries[i].key == "tecs2d.sequence" then
                    local payload = dataEntries[i].value as {string:any}
                    local programs = payload.programs as {any}
                    return programs and #programs or -1
                end
            end
            return -1
        end

        sequence.play(world, preset, {owner = entity, params = {mode = "loop"}})
        world:update(0)
        tick(world, 0.5)
        local first = world:saveSnapshot({format = "table"}) as {string:any}
        local baseline = programCount(first)
        luassert.is_true(baseline > 0, "no programs serialized")

        -- Two load -> replay -> save rounds must not grow the registry.
        for _ = 1, 2 do
            world:loadSnapshot(first as any)
            sequence.play(world, sequence.program("spec.nested"),
                {owner = entity, params = {mode = "loop"}})
            tick(world, 0.5)
        end
        local final = world:saveSnapshot({format = "table"}) as {string:any}
        luassert.equals(baseline, programCount(final),
            "the program list grew across save/load/play cycles")

        world:shutdown()
    end)

    it("serializes active custom field2 targets", function()
        local world = makeWorld()
        local PairComp = tecs.newComponent({
            name = "TweenTestPair",
            container = {} as tecs.Component,
            fields = {"x", "y"},
            init = function(instance: tecs.Component, x: number, y: number)
                local data = instance as {string:any}
                data.x = x
                data.y = y
            end
        })
        local entity = world:spawn(PairComp(0, 0) as tecs.Component)
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.field2(PairComp, "x", "y"), 100, 200),
        })

        tick(world, 0.5)
        local snap = world:saveSnapshot({format = "table"})
        world:loadSnapshot(snap)
        tick(world, 0.25)

        local pair = world:get(entity, PairComp) as {string:number}
        luassert.is_near(75, pair.x, 2)
        luassert.is_near(150, pair.y, 2)

        world:shutdown()
    end)

    it("serializes active custom angle targets", function()
        local world = makeWorld()
        local AngleComp = tecs.newComponent({
            name = "TweenTestAngle",
            container = {} as tecs.Component,
            fields = {"theta"},
            init = function(instance: tecs.Component, theta: number)
                (instance as {string:any}).theta = theta
            end
        })
        local entity = world:spawn(AngleComp(0) as tecs.Component)
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.angle(AngleComp, "theta"), math.pi / 2),
        })

        tick(world, 0.5)
        local snap = world:saveSnapshot({format = "table"})
        world:loadSnapshot(snap)
        tick(world, 0.25)

        luassert.is_near(math.pi * 0.375, (world:get(entity, AngleComp) as {string:number}).theta, 0.1)

        world:shutdown()
    end)

    it("serializes one shared program for several playbacks of it", function()
        local world = makeWorld()
        local e1 = world:spawn(Transform(0, 0))
        local e2 = world:spawn(Transform(0, 0))
        tick(world, 0)

        local fade <const> = sequence.timeline(uniqueName(), {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        })

        sequence.play(world, fade, {owner = e1})
        sequence.play(world, fade, {owner = e2})
        world:update(0)

        local out = world:saveSnapshot({format = "table"}) as {string:any}
        local snap = out.snapshot as {string:any}
        local data = snap.data as {{string:any}}
        local payload: {string:any} = nil
        for i = 1, #data do
            if data[i].key == "tecs2d.sequence" then
                payload = data[i].value as {string:any}
                break
            end
        end

        luassert.is_truthy(payload)
        luassert.equals(1, #(payload.programs as {{string:any}}),
            "two playbacks of one timeline carry it once")

        world:shutdown()
    end)

    it("emits named tween events", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local seen = false
        world:observe(0, sequence.Event, function(ev: sequence.Event)
            if ev.name == "flash" and ev.args[1] == entity then
                seen = true
            end
        end)

        play(world, entity, {
            sequence.tweenTo(0.2, sequence.easing.linear, sequence.target.translateX, 10),
            sequence.tweenEmit("flash"),
        })

        tick(world, 0.2)
        luassert.is_true(seen)

        world:shutdown()
    end)

    it("tracks a target resolved from TweenTrackingTarget", function()
        local world = makeWorld()
        local player = world:spawn(tecs.builtins.Key("player"), Transform(100, 50))
        local missile = world:spawn(Transform(0, 0), sequence.TrackingTarget(0, "player"))
        tick(world, 0)

        play(world, missile, {
            sequence.tweenTrack(1.0, sequence.easing.linear, sequence.target.translateXY, sequence.source.tracking(Transform, {"x", "y"})),
        })

        tick(world, 0.5)
        luassert.is_near(50, world:get(missile, Transform).x, 2)
        luassert.is_near(25, world:get(missile, Transform).y, 2)

        local pt = world:getMut(player, Transform)
        pt.x = 200
        pt.y = 100
        world:markComponentDirty(player, Transform as tecs.Component)

        tick(world, 0.25)
        luassert.is_near(150, world:get(missile, Transform).x, 3)
        luassert.is_near(75, world:get(missile, Transform).y, 3)

        world:shutdown()
    end)

    it("tracks a target resolved from sourceRelationship", function()
        local world = makeWorld()
        local parent = world:spawn(Transform(100, 50))
        local child = world:spawn(Transform(0, 0), tecs.builtins.ChildOf(parent) as tecs.Component)
        tick(world, 0)

        play(world, child, {
            sequence.tweenTrack(1.0, sequence.easing.linear, sequence.target.translateXY,
                sequence.source.related(tecs.builtins.ChildOf, Transform, {"x", "y"})),
        })

        tick(world, 0.5)
        luassert.is_near(50, world:get(child, Transform).x, 2)
        luassert.is_near(25, world:get(child, Transform).y, 2)

        local pt = world:getMut(parent, Transform)
        pt.x = 200
        pt.y = 100
        world:markComponentDirty(parent, Transform as tecs.Component)

        tick(world, 0.25)
        luassert.is_near(150, world:get(child, Transform).x, 3)
        luassert.is_near(75, world:get(child, Transform).y, 3)

        world:shutdown()
    end)

    it("play speed option multiplies playback rate", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        }, {speed = 2})

        tick(world, 0.25) -- 0.25 * 2 = 0.5 effective
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        world:shutdown()
    end)

    it("play speed works with shared timeline def", function()
        local world = makeWorld()
        local e1 = world:spawn(Transform(0, 0))
        local e2 = world:spawn(Transform(0, 0))
        tick(world, 0)

        local def <const> = {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        }

        play(world, e1, def)
        play(world, e2, def, {speed = 2})

        tick(world, 0.5)
        luassert.is_near(50, world:get(e1, Transform).x, 2)
        luassert.is_near(100, world:get(e2, Transform).x, 2)

        world:shutdown()
    end)

    it("pause and resume", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local handle <const> = play(world, entity, {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        })

        tick(world, 0.25)
        luassert.is_near(25, world:get(entity, Transform).x, 2)

        sequence.pause(world, handle)
        tick(world, 0.5) -- should not advance
        luassert.is_near(25, world:get(entity, Transform).x, 2)

        sequence.resume(world, handle)
        tick(world, 0.25)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        world:shutdown()
    end)

    it("delay postpones playback start", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        }, {delay = 0.5})

        tick(world, 0.25) -- still in delay
        luassert.is_near(0, world:get(entity, Transform).x, 2)

        tick(world, 0.25) -- delay ends, 0s of tween elapsed
        luassert.is_near(0, world:get(entity, Transform).x, 2)

        tick(world, 0.5) -- 0.5s into tween
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        world:shutdown()
    end)

    it("delay with shared timeline for staggering", function()
        local world = makeWorld()
        local e1 = world:spawn(Transform(0, 0))
        local e2 = world:spawn(Transform(0, 0))
        tick(world, 0)

        local def <const> = {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        }

        play(world, e1, def, {delay = 0})
        play(world, e2, def, {delay = 0.5})

        tick(world, 0.5)
        luassert.is_near(50, world:get(e1, Transform).x, 2)
        luassert.is_near(0, world:get(e2, Transform).x, 2)

        tick(world, 0.5)
        luassert.is_near(100, world:get(e1, Transform).x, 2)
        luassert.is_near(50, world:get(e2, Transform).x, 2)

        world:shutdown()
    end)

    it("channel cancels previous tween on same entity+channel", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local moveRight = {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        }

        local moveDown = {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateY, 200),
        }

        play(world, entity, moveRight, nil, "movement")
        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        -- Play on the same owner and channel: cancels moveRight
        play(world, entity, moveDown, nil, "movement")
        tick(world, 0.5)

        -- x should stay at 50 (cancelled), y should be at 100
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        luassert.is_near(100, world:get(entity, Transform).y, 2)

        world:shutdown()
    end)

    it("pause and resume act on one playback, not on the entity", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local movement <const> = play(world, entity, {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        }, nil, "movement")

        play(world, entity, {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateY, 100),
        }, nil, "fade")

        tick(world, 0.25)
        sequence.pause(world, movement)
        tick(world, 0.25)
        luassert.is_near(25, world:get(entity, Transform).x, 2)
        luassert.is_near(50, world:get(entity, Transform).y, 2)

        sequence.resume(world, movement)
        tick(world, 0.25)
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        luassert.is_near(75, world:get(entity, Transform).y, 2)

        world:shutdown()
    end)

    it("cancel can select by preset name", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local preset <const> = sequence.timeline("spec.moveRight", {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        })

        local handle <const> = sequence.play(world, preset, {owner = entity})
        world:update(0)
        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        sequence.cancel(world, handle)
        local t = world:getMut(entity, Transform)
        t.x = 999
        world:markComponentDirty(entity, Transform as tecs.Component)
        tick(world, 0.5)
        luassert.is_near(999, world:get(entity, Transform).x, 2)

        world:shutdown()
    end)

    it("cancel can select by timeline reference", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local moveX <const> = {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        }
        local moveY <const> = {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateY, 100),
        }

        local xHandle <const> = play(world, entity, moveX)
        play(world, entity, moveY)
        tick(world, 0.5)

        sequence.cancel(world, xHandle)
        tick(world, 0.25)
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        luassert.is_near(75, world:get(entity, Transform).y, 2)

        world:shutdown()
    end)

    it("no channel does not cancel other tweens", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        play(world, entity, {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateX, 100),
        })

        play(world, entity, {
            sequence.tweenTo(1.0, sequence.easing.linear, sequence.target.translateY, 100),
        })

        tick(world, 0.5)
        -- Both should be running
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        luassert.is_near(50, world:get(entity, Transform).y, 2)

        world:shutdown()
    end)
end)
