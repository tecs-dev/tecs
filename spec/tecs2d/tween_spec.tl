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

        tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :once()
            :apply(world, entity)

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 1e-1)

        tick(world, 0.5)
        luassert.is_near(100, world:get(entity, Transform).x, 1e-1)
    end)

    it("cursor is removed on completion", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline()
            :to(0.5, tween.linear, tween.translateX, 100)
            :once()
            :apply(world, entity)

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

    it("step: second group does not start until first finishes", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline()
            :to(0.5, tween.linear, tween.translateX, 100)
            :step()
            :to(0.5, tween.linear, tween.translateY, 200)
            :once()
            :apply(world, entity)

        tick(world, 0.25)
        luassert.is_near(50, world:get(entity, Transform).x, 1e-1)
        luassert.is_near(0, world:get(entity, Transform).y, 1e-1)

        tick(world, 0.5)
        luassert.is_near(100, world:get(entity, Transform).x, 1e-1)
        luassert.is_near(100, world:get(entity, Transform).y, 2)
    end)

    it("step with pause: extra time gap between groups", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline()
            :to(0.3, tween.linear, tween.translateX, 100)
            :step(0.2)
            :to(0.3, tween.linear, tween.translateY, 100)
            :once()
            :apply(world, entity)

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

    it("pingPong: direction reverses, values go back", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :pingPong(1) -- play forward + 1 reverse = 2 total
            :apply(world, entity)

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 1e-1)

        tick(world, 0.5)

        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        tick(world, 0.5)
        luassert.is_near(0, world:get(entity, Transform).x, 2)
    end)

    it("loop(n): plays correct number of times", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local completed = false
        world:observe(0, tween.TweenComplete, function()
            completed = true
        end)
        tween.timeline()
            :to(0.5, tween.linear, tween.translateX, 100)
            :loop(1) -- plays 2 times total
            :apply(world, entity)

        tick(world, 0.5)
        luassert.is_false(completed)

        tick(world, 0.5)
        luassert.is_true(completed)
    end)

    it("loop() infinite: keeps running", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline()
            :to(0.5, tween.linear, tween.translateX, 100)
            :loop()
            :apply(world, entity)

        for _ = 1, 10 do
            tick(world, 0.25)
            tick(world, 0.25)
        end

        luassert.is_truthy(world:isAlive(entity))
    end)

    it("timeline removed when target entity dies", function()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :loop()
            :apply(world, entity)

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
                called = true
            end
        end)
        tween.timeline()
            :to(0.5, tween.linear, tween.translateX, 100)
            :once()
            :apply(world, entity)

        tick(world, 0.25)
        luassert.is_false(called)

        tick(world, 0.5)
        luassert.is_true(called)
    end)
end)

-------------------------------------------------------------------------------
-- Builder tests
-------------------------------------------------------------------------------

describe("builder", function()
    it(":to() entries in same group get same startTime", function()
        local def <const> = tween.timeline()
            :to(0.5, tween.linear, tween.translateX, 100)
            :to(0.3, tween.linear, tween.translateY, 100)
            :once()

        luassert.is_equal(def.slots[1].startTime, def.slots[2].startTime)
        luassert.is_equal(0, def.slots[1].startTime)
    end)

    it(":step() computes correct time offset from longest entry", function()
        local def <const> = tween.timeline()
            :to(0.5, tween.linear, tween.translateX, 100)
            :to(0.3, tween.linear, tween.translateY, 100)
            :step()
            :to(0.4, tween.linear, tween.rotation, 1)
            :once()

        luassert.is_equal(0.5, def.slots[3].startTime)
    end)

    it(":step(pause) adds pause time to offset", function()
        local def <const> = tween.timeline()
            :to(0.3, tween.linear, tween.translateX, 100)
            :step(0.2)
            :to(0.4, tween.linear, tween.translateY, 100)
            :once()

        luassert.is_equal(0.5, def.slots[2].startTime)
    end)

    it("finalizers freeze the builder", function()
        local builder <const> = tween.timeline()
            :to(0.5, tween.linear, tween.translateX, 100)

        builder:once()

        luassert.has_error(function()
            builder:to(0.5, tween.linear, tween.translateY, 100)
        end, nil)
    end)

    it("reusable: same def applied to multiple entities creates independent timelines", function()
        local world = makeWorld()

        local e1 = world:spawn(Transform(0, 0))
        local e2 = world:spawn(Transform(0, 0))
        tick(world, 0)

        local def <const> = tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :once()

        def:apply(world, e1)
        tick(world, 0.5)

        def:apply(world, e2)
        tick(world, 0.25)

        luassert.is_near(75, world:get(e1, Transform).x, 2)
        luassert.is_near(25, world:get(e2, Transform).x, 2)

        world:shutdown()
    end)

    it(":run() inlines sub-timeline with correct offset and duration", function()
        local sub <const> = tween.timeline()
            :to(0.5, tween.linear, tween.translateY, 100)
            :once()

        local def <const> = tween.timeline()
            :to(0.5, tween.linear, tween.translateX, 100)
            :step()
            :run(sub)
            :once()

        luassert.is_near(1.0, def.totalDuration, 1e-9)
    end)

    it(":run(infinite, n) caps to n cycles", function()
        local sub <const> = tween.timeline()
            :to(0.5, tween.linear, tween.translateY, 100)
            :loop()

        local def <const> = tween.timeline()
            :run(sub, 3)
            :once()

        luassert.is_near(1.5, def.totalDuration, 1e-9)
    end)

    it(":run(infinite) without count errors", function()
        local sub <const> = tween.timeline()
            :to(0.5, tween.linear, tween.translateY, 100)
            :loop()

        luassert.has_error(function()
            tween.timeline()
                :run(sub)
                :once()
        end, nil)
    end)

    it("cancel removes active cursor", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :loop()
            :apply(world, entity)

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

        local def <const> = tween.timeline()
            :to(0.5, tween.linear, tween.translateX, 100)
            :once()

        def:apply(world, entity)
        tick(world, 0.6)
        luassert.is_near(100, world:get(entity, Transform).x, 2)

        local transform = world:getMut(entity, Transform)
        transform.x = 0
        world:markComponentDirty(entity, Transform as tecs.Component)

        def:apply(world, entity)
        tick(world, 0.25)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        world:shutdown()
    end)

    it("can reapply an anonymous timeline after cancel", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        local def <const> = tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :loop()

        def:apply(world, entity)
        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        tween.cancel(world, entity)
        tick(world, 0.01)

        local transform = world:getMut(entity, Transform)
        transform.x = 0
        world:markComponentDirty(entity, Transform as tecs.Component)

        def:apply(world, entity)
        tick(world, 0.25)
        luassert.is_near(25, world:get(entity, Transform).x, 2)

        world:shutdown()
    end)

    it("resumes active playbacks after snapshot load", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :once()
            :apply(world, entity)

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

        tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :once()
            :apply(world, entity)

        tick(world, 0.5)
        local snap = world:saveSnapshot({format = "table"})

        world:loadSnapshot(snap)
        tick(world, 0.25)
        luassert.is_near(75, world:get(entity, Transform).x, 2)

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

        tween.timeline()
            :to(1.0, tween.linear, tween.field2(PairComp, "x", "y"), 100, 200)
            :once()
            :apply(world, entity)

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

        tween.timeline()
            :to(1.0, tween.linear, tween.angle(AngleComp, "theta"), math.pi / 2)
            :once()
            :apply(world, entity)

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

        local fade <const> = tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :once()

        fade:apply(world, e1)
        fade:apply(world, e2)

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
                seen = true
            end
        end)

        tween.timeline()
            :to(0.2, tween.linear, tween.translateX, 10)
            :emit("flash")
            :once()
            :apply(world, entity)

        tick(world, 0.2)
        luassert.is_true(seen)

        world:shutdown()
    end)

    it("tracks a target resolved from TweenTrackingTarget", function()
        local world = makeWorld()
        local player = world:spawn(tecs.builtins.Key("player"), Transform(100, 50))
        local missile = world:spawn(Transform(0, 0), tween.TrackingTarget(0, "player"))
        tick(world, 0)

        tween.timeline()
            :track(1.0, tween.linear, tween.translateXY, tween.sourceTrackingTarget(Transform, {"x", "y"}))
            :loop()
            :apply(world, missile)

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

    it("apply speed parameter multiplies playback rate", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :once()
            :apply(world, entity, 2)

        tick(world, 0.25) -- 0.25 * 2 = 0.5 effective
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        world:shutdown()
    end)

    it("apply speed works with shared timeline def", function()
        local world = makeWorld()
        local e1 = world:spawn(Transform(0, 0))
        local e2 = world:spawn(Transform(0, 0))
        tick(world, 0)

        local def <const> = tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :once()

        def:apply(world, e1)
        def:apply(world, e2, 2)

        tick(world, 0.5)
        luassert.is_near(50, world:get(e1, Transform).x, 2)
        luassert.is_near(100, world:get(e2, Transform).x, 2)

        world:shutdown()
    end)

    it("pause and resume", function()
        local world = makeWorld()
        local entity = world:spawn(Transform(0, 0))
        tick(world, 0)

        tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :once()
            :apply(world, entity)

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

        tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :once()
            :apply(world, entity, 1, 0.5) -- speed 1, delay 0.5s

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

        local def <const> = tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :once()

        def:apply(world, e1, 1, 0)   -- no delay
        def:apply(world, e2, 1, 0.5) -- 0.5s delay

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

        local moveRight = tween.timeline()
            :channel("movement")
            :to(1.0, tween.linear, tween.translateX, 100)
            :once()

        local moveDown = tween.timeline()
            :channel("movement")
            :to(1.0, tween.linear, tween.translateY, 200)
            :once()

        moveRight:apply(world, entity)
        tick(world, 0.5)
        luassert.is_near(50, world:get(entity, Transform).x, 2)

        -- Apply new tween on same channel: cancels moveRight
        moveDown:apply(world, entity)
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

        tween.timeline()
            :channel("movement")
            :to(1.0, tween.linear, tween.translateX, 100)
            :once()
            :apply(world, entity)

        tween.timeline()
            :channel("fade")
            :to(1.0, tween.linear, tween.translateY, 100)
            :once()
            :apply(world, entity)

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

        local preset <const> = tween.registerPreset("spec.moveRight", tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :loop())

        preset:apply(world, entity)
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

        local moveX <const> = tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :loop()
        local moveY <const> = tween.timeline()
            :to(1.0, tween.linear, tween.translateY, 100)
            :loop()

        moveX:apply(world, entity)
        moveY:apply(world, entity)
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

        tween.timeline()
            :to(1.0, tween.linear, tween.translateX, 100)
            :once()
            :apply(world, entity)

        tween.timeline()
            :to(1.0, tween.linear, tween.translateY, 100)
            :once()
            :apply(world, entity)

        tick(world, 0.5)
        -- Both should be running
        luassert.is_near(50, world:get(entity, Transform).x, 2)
        luassert.is_near(50, world:get(entity, Transform).y, 2)

        world:shutdown()
    end)
end)
