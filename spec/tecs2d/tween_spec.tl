require("busted")

local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local tween <const> = require("tecs2d.tween")
local type EasingFunction = function(t: number): number

local Transform <const> = tecs.builtins.Transform

local function makeWorld(): tecs.World
    local world = tecs.newWorld()
    world:addPlugin(tween.plugin)
    return world
end

local function tick(world: tecs.World, dt: number)
    world:update(dt)
end

-------------------------------------------------------------------------------
-- Easing tests
-------------------------------------------------------------------------------

describe("easing", function()
    local allEasings: {string: EasingFunction} = {
        linear = tween.linear,
        quadIn = tween.quadIn,
        quadOut = tween.quadOut,
        quadInOut = tween.quadInOut,
        quadOutIn = tween.quadOutIn,
        cubicIn = tween.cubicIn,
        cubicOut = tween.cubicOut,
        cubicInOut = tween.cubicInOut,
        cubicOutIn = tween.cubicOutIn,
        quartIn = tween.quartIn,
        quartOut = tween.quartOut,
        quartInOut = tween.quartInOut,
        quartOutIn = tween.quartOutIn,
        quintIn = tween.quintIn,
        quintOut = tween.quintOut,
        quintInOut = tween.quintInOut,
        quintOutIn = tween.quintOutIn,
        sineIn = tween.sineIn,
        sineOut = tween.sineOut,
        sineInOut = tween.sineInOut,
        sineOutIn = tween.sineOutIn,
        expoIn = tween.expoIn,
        expoOut = tween.expoOut,
        expoInOut = tween.expoInOut,
        expoOutIn = tween.expoOutIn,
        backIn = tween.backIn,
        backOut = tween.backOut,
        backInOut = tween.backInOut,
        backOutIn = tween.backOutIn,
        elasticIn = tween.elasticIn,
        elasticOut = tween.elasticOut,
        elasticInOut = tween.elasticInOut,
        elasticOutIn = tween.elasticOutIn,
        bounceIn = tween.bounceIn,
        bounceOut = tween.bounceOut,
        bounceInOut = tween.bounceInOut,
        bounceOutIn = tween.bounceOutIn,
    }

    for name, fn in pairs(allEasings) do
        it(name .. ": f(0) == 0 and f(1) == 1", function()
            luassert.is_near(0, fn(0), 1e-9, name .. "(0) should be 0")
            luassert.is_near(1, fn(1), 1e-9, name .. "(1) should be 1")
        end)
    end

    it("linear: f(0.5) == 0.5", function()
        luassert.is_near(0.5, tween.linear(0.5), 1e-9)
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

        local target <const> = tween.field(Transform, "x")
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

        s1, s2, s3, s4, d1, d2, d3, d4 = tween.translateX.init(world, entity, false, 100, 0, 0, 0)
        tween.translateX.apply(world, entity, 1, s1, s2, s3, s4, d1, d2, d3, d4)
        luassert.is_near(100, world:get(entity, Transform).x, 1e-3)

        s1, s2, s3, s4, d1, d2, d3, d4 = tween.translateY.init(world, entity, false, 50, 0, 0, 0)
        tween.translateY.apply(world, entity, 1, s1, s2, s3, s4, d1, d2, d3, d4)
        luassert.is_near(50, world:get(entity, Transform).y, 1e-3)

        s1, s2, s3, s4, d1, d2, d3, d4 = tween.rotation.init(world, entity, false, math.pi, 0, 0, 0)
        tween.rotation.apply(world, entity, 1, s1, s2, s3, s4, d1, d2, d3, d4)
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

        local tweenFill <const> = tween.field(CustomComp, "fill")
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
            tween.target(CustomComp, {"a", "b", "c"})
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

        tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        })
            :play(world, entity)

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 1e-1)

        tick(world, 0.5)
        luassert.is_near(100, world:get(entity, Transform).x, 1e-1)
    end)

    it("cursor is removed on completion", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline({
            tween.to(0.5, tween.linear, tween.translateX, 100),
        })
            :play(world, entity)

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

        tween.timeline({
            tween.to(0.5, tween.linear, tween.translateX, 100),
            tween.to(0.5, tween.linear, tween.translateY, 200),
        })
            :play(world, entity)

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

        tween.timeline({
            tween.to(0.3, tween.linear, tween.translateX, 100),
            tween.wait(0.2),
            tween.to(0.3, tween.linear, tween.translateY, 100),
        })
            :play(world, entity)

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

        tween.timeline({
            tween.to(0.1, "linear", "transform.x", 100),
            tween.wait(1),
        }):play(world, entity)

        tick(world, 0.1)
        local transform = world:getMut(entity, Transform)
        transform.x = 40
        tick(world, 0.2)

        luassert.is_near(40, world:get(entity, Transform).x, 1e-9)
    end)

    it("pingPong: direction reverses, values go back", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        }):play(world, entity, {mode = "pingPong", count = 2})

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

        local completed = false
        world:observe(0, tween.TweenComplete, function()
            completed = true
        end)
        tween.timeline({
            tween.to(0.5, tween.linear, tween.translateX, 100),
        }):play(world, entity, {mode = "loop", count = 2})

        tick(world, 0.5)
        luassert.is_false(completed)

        tick(world, 0.5)
        luassert.is_true(completed)
    end)

    it("consumes every loop pass crossed by one update", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline({
            tween.adjust(1, "linear", "transform.x", 10),
        }):play(world, entity, {mode = "loop", count = 3})

        tick(world, 2.5)
        luassert.is_near(25, world:get(entity, Transform).x, 1e-9)

        local playback <const> = world:get(entity, tween.TweenPlayback)
        luassert.is_not_nil(playback)
        luassert.is_near(0.5, playback.cursors[1].elapsed, 1e-9)
        luassert.are.equal(1, playback.cursors[1].remainingPasses)
    end)

    it("preserves ping-pong overshoot in the same update", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline({
            tween.to(1, "linear", "transform.x", 100),
        }):play(world, entity, {mode = "pingPong", count = 2})

        tick(world, 1.25)
        luassert.is_near(75, world:get(entity, Transform).x, 1e-9)
    end)

    it("loop() infinite: keeps running", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline({
            tween.to(0.5, tween.linear, tween.translateX, 100),
        }):play(world, entity, {mode = "loop"})

        for _ = 1, 10 do
            tick(world, 0.25)
            tick(world, 0.25)
        end

        luassert.is_truthy(world:isAlive(entity))
    end)

    it("timeline removed when target entity dies", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        }):play(world, entity, {mode = "loop"})

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

        local called = false
        world:observe(0, tween.TweenComplete, function(ev: tween.TweenComplete)
            if ev.entity == entity then
                luassert.is_nil(ev.channel)
                called = true
            end
        end)
        tween.timeline({
            tween.to(0.5, tween.linear, tween.translateX, 100),
        })
            :play(world, entity)

        tick(world, 0.25)
        luassert.is_false(called)

        tick(world, 0.5)
        luassert.is_true(called)
    end)
end)

-------------------------------------------------------------------------------
-- Timeline compilation tests
-------------------------------------------------------------------------------

describe("timeline compilation", function()
    it("parallel entries get the same start time", function()
        local def <const> = tween.timeline({
            tween.parallel(
                tween.to(0.5, tween.linear, tween.translateX, 100),
                tween.to(0.3, tween.linear, tween.translateY, 100)),
        })

        luassert.is_equal(def.slots[1].startTime, def.slots[2].startTime)
        luassert.is_equal(0, def.slots[1].startTime)
    end)

    it("parallel advances by its longest entry", function()
        local def <const> = tween.timeline({
            tween.parallel(
                tween.to(0.5, tween.linear, tween.translateX, 100),
                tween.to(0.3, tween.linear, tween.translateY, 100)),
            tween.to(0.4, tween.linear, tween.rotation, 1),
        })

        luassert.is_equal(0.5, def.slots[3].startTime)
    end)

    it("wait advances the time offset", function()
        local def <const> = tween.timeline({
            tween.to(0.3, tween.linear, tween.translateX, 100),
            tween.wait(0.2),
            tween.to(0.4, tween.linear, tween.translateY, 100),
        })

        luassert.is_equal(0.5, def.slots[2].startTime)
    end)

    it("compiles the supplied nodes in place", function()
        local operation = tween.to(0.5, tween.linear, tween.translateX, 100)
        local spec = {operation}
        local timeline <const> = tween.timeline(spec)

        luassert.is_true(rawequal(timeline, spec))
        luassert.is_true(timeline.slots[1] == operation)
        luassert.is_equal(0, timeline.slots[1].startTime)
        luassert.is_equal(0.5, timeline.slots[1].endTime)
    end)

    it("resolves serializable easing and target names", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline({
            tween.to(1.0, "linear", "transform.x", 100),
        }):play(world, entity)

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        world:shutdown()
    end)

    it("supports sequential branches inside parallel", function()
        local def <const> = tween.timeline({
            tween.parallel(
                {
                    tween.to(0.2, "linear", "transform.x", 10),
                    tween.to(0.3, "linear", "transform.y", 20)},
                tween.to(0.4, "linear", "transform.rotation", 1)),
            tween.to(0.1, "linear", "transform.scaleX", 2),
        })

        luassert.is_equal(0, def.slots[1].startTime)
        luassert.is_equal(0.2, def.slots[2].startTime)
        luassert.is_equal(0, def.slots[3].startTime)
        luassert.is_equal(0.5, def.slots[4].startTime)
    end)

    it("rejects malformed entries", function()
        luassert.has_error(function()
            tween.timeline({{} as any})
        end, nil)
    end)

    it("does not accept a named sequence", function()
        luassert.has_error(function()
            tween.timeline({
                sequence = {
                    tween.to(0.5, "linear", "transform.x", 100),
                },
            })
        end, nil)
    end)

    it("reusable: same def played on multiple entities creates independent timelines", function()
        local world = makeWorld()

        local e1 = world:spawn(Transform(0, 0))
        local e2 = world:spawn(Transform(0, 0))
        tick(world, 0)

        local def <const> = tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        })

        def:play(world, e1)
        tick(world, 0.5)

        def:play(world, e2)
        tick(world, 0.25)

        luassert.is_near(75, world:get(e1, Transform).x, 2)
        luassert.is_near(25, world:get(e2, Transform).x, 2)

        world:shutdown()
    end)

    it("keeps multiple plays created in one deferred scope", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local query <const> = world:query({include = {Transform}})
        local moveX <const> = tween.timeline({
            tween.to(1, "linear", "transform.x", 100),
        })
        local moveY <const> = tween.timeline({
            tween.to(1, "linear", "transform.y", 100),
        })
        local played = false
        world:addSystem({
            name = "tween.SpecDeferredPlay",
            phase = tecs.phases.Update,
            run = function()
                if played then return end
                for _, len, entities in query:iter() do
                    for i = 1, len do
                        moveX:play(world, entities[i])
                        moveY:play(world, entities[i])
                    end
                end
                played = true
            end,
        })

        tick(world, 0)
        local playback <const> = world:get(entity, tween.TweenPlayback)
        luassert.is_not_nil(playback)
        luassert.are.equal(2, #playback.cursors)
        world:shutdown()
    end)

    it("run uses the child timeline duration", function()
        local sub <const> = tween.timeline({
            tween.to(0.5, tween.linear, tween.translateY, 100),
        })

        local def <const> = tween.timeline({
            tween.to(0.5, tween.linear, tween.translateX, 100),
            tween.run(sub),
        })

        luassert.is_near(1.0, def.totalDuration, 1e-9)
    end)

    it("run options repeat a child for a finite pass count", function()
        local sub <const> = tween.timeline({
            tween.to(0.5, tween.linear, tween.translateY, 100),
        })

        local def <const> = tween.timeline({
            tween.run(sub, {mode = "loop", count = 3}),
        })

        luassert.is_near(1.5, def.totalDuration, 1e-9)
    end)

    it("consumes every nested run pass crossed by one update", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local child <const> = tween.timeline({
            tween.adjust(1, "linear", "transform.x", 10),
        })
        tween.timeline({
            tween.run(child, {mode = "loop", count = 3}),
        }):play(world, entity)

        tick(world, 2.5)
        luassert.is_near(25, world:get(entity, Transform).x, 1e-9)
        world:shutdown()
    end)

    it("run pingPong alternates child passes", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)
        local child <const> = tween.timeline({
            tween.to(1.0, "linear", "transform.x", 100),
        })
        tween.timeline({
            tween.run(child, {mode = "pingPong", count = 2}),
        }):play(world, entity)

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
        local sub <const> = tween.timeline({
            tween.to(0.5, tween.linear, tween.translateY, 100),
        })

        luassert.has_error(function()
            tween.timeline({
                tween.run(sub, {mode = "loop"}),
            })
        end, nil)
    end)

    it("cancel removes active cursor", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        }):play(world, entity, {mode = "loop"})

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        tween.cancel(world, entity)

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

        local def <const> = tween.timeline({
            tween.to(0.5, tween.linear, tween.translateX, 100),
        })

        def:play(world, entity)
        tick(world, 0.6)
        luassert.is_near(100, world:get(entity, Transform).x, 2)

        local transform = world:getMut(entity, Transform)
        transform.x = 0
        world:markComponentDirty(entity, Transform as tecs.Component)

        def:play(world, entity)
        tick(world, 0.25)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        world:shutdown()
    end)

    it("can reapply an anonymous timeline after cancel", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local def <const> = tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        })

        def:play(world, entity, {mode = "loop"})
        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        tween.cancel(world, entity)
        tick(world, 0.01)

        local transform = world:getMut(entity, Transform)
        transform.x = 0
        world:markComponentDirty(entity, Transform as tecs.Component)

        def:play(world, entity, {mode = "loop"})
        tick(world, 0.25)
        luassert.is_near(25, world:get(entity, Transform).x, 2)

        world:shutdown()
    end)

    it("resumes active playbacks after snapshot load", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        })
            :play(world, entity)

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

        tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        })
            :play(world, entity)

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

        tween.timeline({
            tween.to(1.0, "linear", "transform.x", 100),
        }):play(world, entity, {mode = "pingPong", count = 2})

        tick(world, 1.0)
        luassert.is_near(100, world:get(entity, Transform).x, 2)
        local snap = world:saveSnapshot({format = "table"})
        world:loadSnapshot(snap)

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        tick(world, 0.5)
        luassert.is_near(0, world:get(entity, Transform).x, 2)
        luassert.is_nil(world:get(entity, tween.TweenPlayback))

        world:shutdown()
    end)

    it("serializes nested run templates across snapshot load", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local child <const> = tween.timeline({
            tween.to(1.0, tween.linear, tween.translateY, 100),
        })

        local parent <const> = tween.timeline({
            tween.to(0.5, tween.linear, tween.translateX, 50),
            tween.run(child),
        })

        parent:play(world, entity)
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

    it("plays a preset by name immediately after registration", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.registerPreset(world, "spec.immediate", tween.timeline({
            tween.to(1, "linear", "transform.x", 100),
        }))
        tween.play(world, entity, "spec.immediate")

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 1e-9)
        world:shutdown()
    end)

    it("keeps inactive presets across snapshot load", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.registerPreset(world, "spec.inactive", tween.timeline({
            tween.to(0.1, "linear", "transform.x", 10),
        }))
        tween.play(world, entity, "spec.inactive")
        tick(world, 0.2)
        luassert.is_nil(world:get(entity, tween.TweenPlayback))

        local snap <const> = world:saveSnapshot({format = "table"})
        world:loadSnapshot(snap)
        local transform = world:getMut(entity, Transform)
        transform.x = 0

        tween.play(world, entity, "spec.inactive")
        tick(world, 0.05)
        luassert.is_near(5, world:get(entity, Transform).x, 1e-9)
        world:shutdown()
    end)

    it("does not duplicate templates across save/load/play cycles", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        -- Keep cursors and their templates live at save time.
        local child <const> = tween.timeline({
            tween.to(0.2, tween.linear, tween.translateY, 10),
        })
        local preset <const> = tween.registerPreset(world, "spec.nested", tween.timeline({
            tween.to(0.2, tween.linear, tween.translateX, 10),
            tween.run(child, {mode = "loop", count = 3}),
        }))

        local function templateCount(snap: {string:any}): integer
            local inner = snap.snapshot as {string:any}
            local dataEntries = inner and inner.data as {{string:any}}
            if not dataEntries then return -1 end
            for i = 1, #dataEntries do
                if dataEntries[i].key == "tecs2d.tween.registry" then
                    local tweenData = dataEntries[i].value as {string:any}
                    local templates = tweenData.templates as {any}
                    return templates and #templates or -1
                end
            end
            return -1
        end

        preset:play(world, entity, {mode = "loop"})
        tick(world, 0.5)
        local first = world:saveSnapshot({format = "table"}) as {string:any}
        local baseline = templateCount(first)
        luassert.is_true(baseline > 0, "no templates serialized")

        -- Two load -> replay -> save rounds must not grow the registry.
        for _ = 1, 2 do
            world:loadSnapshot(first as any)
            tween.play(world, entity, "spec.nested", {mode = "loop"})
            tick(world, 0.5)
        end
        local final = world:saveSnapshot({format = "table"}) as {string:any}
        luassert.are.equal(baseline, templateCount(final),
            "template registry grew across save/load/play cycles")

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

        tween.timeline({
            tween.to(1.0, tween.linear, tween.field2(PairComp, "x", "y"), 100, 200),
        })
            :play(world, entity)

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

        tween.timeline({
            tween.to(1.0, tween.linear, tween.angle(AngleComp, "theta"), math.pi / 2),
        })
            :play(world, entity)

        tick(world, 0.5)
        local snap = world:saveSnapshot({format = "table"})
        world:loadSnapshot(snap)
        tick(world, 0.25)

        luassert.is_near(math.pi * 0.375, (world:get(entity, AngleComp) as {string:number}).theta, 0.1)

        world:shutdown()
    end)

    it("serializes one shared template for multiple active cursors", function()
        local world = makeWorld()
        local e1 = world:spawn(Transform(0, 0))
        local e2 = world:spawn(Transform(0, 0))
        tick(world, 0)

        local fade <const> = tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        })

        fade:play(world, e1)
        fade:play(world, e2)

        local out = world:saveSnapshot({format = "table"}) as {string:any}
        local snap = out.snapshot as {string:any}
        local data = snap.data as {{string:any}}
        local registry: {string:any} = nil
        for i = 1, #data do
            if data[i].key == "tecs2d.tween.registry" then
                registry = data[i].value as {string:any}
                break
            end
        end

        luassert.is_truthy(registry)
        luassert.equals(1, #(registry.templates as {{string:any}}))

        world:shutdown()
    end)

    it("emits named tween events", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local seen = false
        world:observe(0, tween.TweenEvent, function(ev: tween.TweenEvent)
            if ev.entity == entity and ev.name == "flash" then
                luassert.is_nil(ev.channel)
                seen = true
            end
        end)

        tween.timeline({
            tween.to(0.2, tween.linear, tween.translateX, 10),
            tween.emit("flash"),
        })
            :play(world, entity)

        tick(world, 0.2)
        luassert.is_true(seen)

        world:shutdown()
    end)

    it("tracks a target resolved from TweenTrackingTarget", function()
        local world = makeWorld()
        local player = world:spawn(tecs.builtins.Key("player"), Transform(100, 50))
        local missile = world:spawn(Transform(0, 0), tween.TrackingTarget(0, "player"))
        tick(world, 0)

        tween.timeline({
            tween.track(1.0, tween.linear, tween.translateXY, tween.sourceTrackingTarget(Transform, {"x", "y"})),
        })
            :play(world, missile)

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

        tween.timeline({
            tween.track(1.0, tween.linear, tween.translateXY,
                tween.sourceRelationship(tecs.builtins.ChildOf, Transform, {"x", "y"})),
        })
            :play(world, child)

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

        tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        })
            :play(world, entity, {speed = 2})

        tick(world, 0.25) -- 0.25 * 2 = 0.5 effective
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        world:shutdown()
    end)

    it("play speed works with shared timeline def", function()
        local world = makeWorld()
        local e1 = world:spawn(Transform(0, 0))
        local e2 = world:spawn(Transform(0, 0))
        tick(world, 0)

        local def <const> = tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        })

        def:play(world, e1)
        def:play(world, e2, {speed = 2})

        tick(world, 0.5)
        luassert.is_near(50, world:get(e1, Transform).x, 2)
        luassert.is_near(100, world:get(e2, Transform).x, 2)

        world:shutdown()
    end)

    it("pause and resume", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        })
            :play(world, entity)

        tick(world, 0.25)
        luassert.is_near(25, world:get(entity, Transform).x, 2)

        tween.pause(world, entity)
        tick(world, 0.5) -- should not advance
        luassert.is_near(25, world:get(entity, Transform).x, 2)

        tween.resume(world, entity)
        tick(world, 0.25)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        world:shutdown()
    end)

    it("delay postpones playback start", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        })
            :play(world, entity, {delay = 0.5})

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

        local def <const> = tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        })

        def:play(world, e1, {delay = 0})
        def:play(world, e2, {delay = 0.5})

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

        local moveRight = tween.timeline({
            channel = "movement",
            tween.to(1.0, tween.linear, tween.translateX, 100),
        })

        local moveDown = tween.timeline({
            channel = "movement",
            tween.to(1.0, tween.linear, tween.translateY, 200),
        })

        moveRight:play(world, entity)
        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        -- Play new tween on same channel: cancels moveRight
        moveDown:play(world, entity)
        tick(world, 0.5)

        -- x should stay at 50 (cancelled), y should be at 100
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        luassert.is_near(100, world:get(entity, Transform).y, 2)

        world:shutdown()
    end)

    it("pause/resume can select by channel", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline({
            channel = "movement",
            tween.to(1.0, tween.linear, tween.translateX, 100),
        })
            :play(world, entity)

        tween.timeline({
            channel = "fade",
            tween.to(1.0, tween.linear, tween.translateY, 100),
        })
            :play(world, entity)

        tick(world, 0.25)
        tween.pause(world, entity, "movement")
        tick(world, 0.25)
        luassert.is_near(25, world:get(entity, Transform).x, 2)
        luassert.is_near(50, world:get(entity, Transform).y, 2)

        tween.resume(world, entity, "movement")
        tick(world, 0.25)
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        luassert.is_near(75, world:get(entity, Transform).y, 2)

        world:shutdown()
    end)

    it("cancel can select by preset name", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local preset <const> = tween.registerPreset(world, "spec.moveRight", tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        }))

        preset:play(world, entity)
        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        tween.cancel(world, entity, "spec.moveRight")
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

        local moveX <const> = tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        })
        local moveY <const> = tween.timeline({
            tween.to(1.0, tween.linear, tween.translateY, 100),
        })

        moveX:play(world, entity)
        moveY:play(world, entity)
        tick(world, 0.5)

        tween.cancel(world, entity, moveX)
        tick(world, 0.25)
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        luassert.is_near(75, world:get(entity, Transform).y, 2)

        world:shutdown()
    end)

    it("no channel does not cancel other tweens", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline({
            tween.to(1.0, tween.linear, tween.translateX, 100),
        })
            :play(world, entity)

        tween.timeline({
            tween.to(1.0, tween.linear, tween.translateY, 100),
        })
            :play(world, entity)

        tick(world, 0.5)
        -- Both should be running
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        luassert.is_near(50, world:get(entity, Transform).y, 2)

        world:shutdown()
    end)
end)
