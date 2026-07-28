-- A value that settles once, and the combinators over it.
--
-- Two of these cases are the reason the design has the shape it has rather than
-- checks on a surface. "does not grow the Lua stack" is what the iterative
-- drain exists for, and it is only reachable through `flatMap`, which builds
-- link N inside the settlement of link N-1 and so has no depth bound in the
-- source text. "runs dependents in registration order" is what makes a shelf
-- packer's coordinates, and therefore a saved world's sprites, reproducible for
-- a given arrival order.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local sdl = require("tecs.ffi.sdl3")
local sequence = require("tecs.sequence")
local Future = require("tecs.Future")

local C = sdl.C

--- A source under the test's control.
---
--- `advance` hands over whatever the test queued for it and answers at once,
--- which is what a real worker channel does when a message is already waiting.
--- Nothing here sleeps, so a wait against it spins its budget out against the
--- wall clock, which is exactly what the slice-counting defect hid.
local function newSource(settings)
    settings = settings or {}
    local source = {
        sliceMs = settings.sliceMs or 16,
        defaultWaitMs = settings.defaultWaitMs,
        polls = 0,
        advances = 0,
        canceled = {},
        -- Called on each advance, so a test can settle from inside a wait.
        onAdvance = settings.onAdvance,
    }
    function source:poll()
        self.polls = self.polls + 1
        return 0
    end
    function source:advance(ms)
        self.advances = self.advances + 1
        self.lastSlice = ms
        if self.onAdvance then
            return self.onAdvance(self) or 0
        end
        return 0
    end
    if settings.cancels ~= false then
        function source:cancel(future)
            self.canceled[#self.canceled + 1] = future
        end
    end
    return source
end

--- How many Lua frames are below this call.
local function stackDepth()
    local depth = 0
    while debug.getinfo(depth + 2, "") do
        depth = depth + 1
    end
    return depth
end

describe("tecs.Future", function()
    describe("states", function()
        it("starts pending and settles once", function()
            local future = Future.pending()
            assert.are.equal("pending", future.status)

            future:complete(7)
            assert.are.equal("ready", future.status)
            assert.are.equal(7, future.value)
            assert.is_nil(future.error)

            -- Settle-once: the first answer wins and the second is ignored
            -- rather than raising, because a source racing its own cancel is
            -- the normal case and neither side should have to check.
            future:complete(9)
            future:fail("late")
            assert.are.equal(7, future.value)
            assert.are.equal("ready", future.status)
        end)

        it("carries a failure as a value rather than a raise", function()
            local future = Future.pending()
            future:fail("no such file")
            assert.are.equal("failed", future.status)
            assert.are.equal("no such file", future.error)
            assert.is_nil(future.value)
        end)

        it("builds one already settled", function()
            assert.are.equal("ready", Future.settled(3).status)
            assert.are.equal(3, Future.settled(3).value)
            assert.are.equal("failed", Future.failed("nope").status)
            assert.are.equal("nope", Future.failed("nope").error)
        end)
    end)

    describe("onSettle", function()
        it("runs a listener when the future settles", function()
            local seen
            local future = Future.pending()
            future:onSettle(function(settled)
                seen = settled.value
            end)
            assert.is_nil(seen)

            future:complete("done")
            assert.are.equal("done", seen)
        end)

        it("runs a listener registered after settlement", function()
            local future = Future.settled("already")
            local seen
            future:onSettle(function(settled)
                seen = settled.value
            end)
            assert.are.equal("already", seen)
        end)

        -- The claim in the module's doc comment, and the one that reaches a
        -- snapshot: a dependent that registers an image allocates through a
        -- shelf packer whose coordinates depend on arrival order and end up in
        -- a Sprite component. Two dependents run in the other order pack
        -- differently.
        it("runs dependents in registration order", function()
            local order = {}
            local future = Future.pending()
            for index = 1, 3 do
                future:onSettle(function()
                    order[#order + 1] = index
                end)
            end
            future:complete(true)

            assert.are.same({ 1, 2, 3 }, order)
        end)

        it("keeps registration order across combinators on one future", function()
            local order = {}
            local future = Future.pending()
            future:map(function(value)
                order[#order + 1] = "map"
                return value
            end)
            future:onSettle(function()
                order[#order + 1] = "onSettle"
            end)
            future:recover(function()
                return 0
            end)
            future:onSettle(function()
                order[#order + 1] = "last"
            end)
            future:complete(1)

            assert.are.same({ "map", "onSettle", "last" }, order)
        end)

        it("logs a listener that raises and runs the rest", function()
            local reached = false
            local future = Future.pending()
            future:onSettle(function()
                error("listener boom")
            end)
            future:onSettle(function()
                reached = true
            end)
            future:complete(1)

            assert.is_true(reached, "one bad listener stopped the others")
        end)

        it("lets a listener settle another future", function()
            -- Forbidden by documentation in what this replaces. Legal here by
            -- construction, because the drain appends rather than recursing.
            local second = Future.pending()
            local first = Future.pending()
            first:onSettle(function()
                second:complete("from inside")
            end)
            first:complete(1)

            assert.are.equal("from inside", second.value)
        end)
    end)

    describe("map", function()
        it("carries the transform's result", function()
            local future = Future.pending()
            local mapped = future:map(function(value)
                return value * 2
            end)
            future:complete(21)

            assert.are.equal("ready", mapped.status)
            assert.are.equal(42, mapped.value)
        end)

        it("propagates a failure without calling the transform", function()
            local called = false
            local future = Future.pending()
            local mapped = future:map(function()
                called = true
            end)
            future:fail("decode failed")

            assert.is_false(called)
            assert.are.equal("failed", mapped.status)
            assert.are.equal("decode failed", mapped.error)
        end)

        it("turns a raise inside the transform into that link's failure", function()
            local future = Future.pending()
            local mapped = future:map(function()
                error("transform boom")
            end)
            future:complete(1)

            assert.are.equal("failed", mapped.status)
            assert.is_truthy(mapped.error:find("transform boom", 1, true))
        end)

        it("inherits the upstream's source", function()
            local source = newSource()
            local future = Future.pending(source)
            local mapped = future:map(function(value)
                return value
            end)
            assert.are.equal(source, mapped._source)
        end)
    end)

    describe("flatMap", function()
        it("adopts the future the transform starts", function()
            local outer = Future.pending()
            local inner = Future.pending()
            local chained = outer:flatMap(function(value)
                assert.are.equal("outer", value)
                return inner
            end)

            outer:complete("outer")
            assert.are.equal("pending", chained.status, "the inner has not settled")

            inner:complete("inner")
            assert.are.equal("ready", chained.status)
            assert.are.equal("inner", chained.value)
        end)

        it("adopts the inner future's failure", function()
            local outer = Future.pending()
            local chained = outer:flatMap(function()
                return Future.failed("second request failed")
            end)
            outer:complete(1)

            assert.are.equal("failed", chained.status)
            assert.are.equal("second request failed", chained.error)
        end)

        -- The reason `_source` is a field rather than something inherited once.
        -- A manifest read starts on one source and the request it names
        -- finishes on another, so a wait on the chain has to advance whichever
        -- one it is on now.
        it("moves the chain onto the inner future's source", function()
            local first = newSource()
            local second = newSource()
            local outer = Future.pending(first)
            local chained = outer:flatMap(function()
                return Future.pending(second)
            end)
            assert.are.equal(first, chained._source)

            outer:complete(1)
            assert.are.equal(second, chained._source, "the source did not move")
        end)

        it("propagates a failed outer without starting the inner", function()
            local started = false
            local outer = Future.pending()
            local chained = outer:flatMap(function()
                started = true
                return Future.settled(1)
            end)
            outer:fail("outer failed")

            assert.is_false(started)
            assert.are.equal("failed", chained.status)
            assert.are.equal("outer failed", chained.error)
        end)

        -- The one place "cancel only this link" needs a second sentence. There
        -- is a window where the chain has been canceled and the inner work has
        -- not been created, and canceling after the fact cannot reach into
        -- something that does not exist.
        it("never starts the inner when canceled before the outer settles", function()
            local started = false
            local outer = Future.pending()
            local chained = outer:flatMap(function()
                started = true
                return Future.settled("should not exist")
            end)

            chained:cancel()
            assert.are.equal("canceled", chained.status)

            outer:complete(1)
            assert.is_false(started, "the inner work was started for a canceled chain")
            assert.are.equal("canceled", chained.status)
        end)

        it("turns a raise inside the transform into that link's failure", function()
            local outer = Future.pending()
            local chained = outer:flatMap(function()
                error("chain boom")
            end)
            outer:complete(1)

            assert.are.equal("failed", chained.status)
            assert.is_truthy(chained.error:find("chain boom", 1, true))
        end)

        it("fails the link when the transform returns no future", function()
            local outer = Future.pending()
            local chained = outer:flatMap(function()
                return nil
            end)
            outer:complete(1)

            assert.are.equal("failed", chained.status)
        end)

        -- The drain's only real test. A recursive flatMap builds each link
        -- inside the settlement of the one before it, so a naive
        -- implementation, where settling calls its dependents which settle
        -- theirs, is as deep as the chain and discovers the limit inside the
        -- frame pump.
        it("does not grow the Lua stack over a thousand-link chain", function()
            local LINKS = 1000
            local depths = {}
            local made = 0

            local function step()
                made = made + 1
                depths[made] = stackDepth()
                if made >= LINKS then
                    return Future.settled(made)
                end
                return Future.settled(made):flatMap(step)
            end

            local start = Future.pending()
            local tail = start:flatMap(step)
            start:complete(0)

            assert.are.equal(LINKS, made, "the chain did not run to its end")
            assert.are.equal("ready", tail.status)
            assert.are.equal(LINKS, tail.value)

            local lowest, highest = depths[1], depths[1]
            for index = 2, LINKS do
                if depths[index] < lowest then
                    lowest = depths[index]
                end
                if depths[index] > highest then
                    highest = depths[index]
                end
            end
            assert.is_true(
                highest - lowest <= 2,
                ("the stack grew with the chain: %d frames at the first link, %d at the deepest"):format(
                    depths[1],
                    highest
                )
            )
        end)
    end)

    describe("recover", function()
        it("turns a failure into a value", function()
            local future = Future.pending()
            local recovered = future:recover(function(err)
                return "fallback: " .. err
            end)
            future:fail("missing")

            assert.are.equal("ready", recovered.status)
            assert.are.equal("fallback: missing", recovered.value)
        end)

        it("leaves a ready upstream alone", function()
            local called = false
            local future = Future.pending()
            local recovered = future:recover(function()
                called = true
                return "fallback"
            end)
            future:complete("real")

            assert.is_false(called)
            assert.are.equal("real", recovered.value)
        end)

        -- The whole reason "canceled" is a state of its own. A caller who
        -- canceled a load did not ask for a fallback value.
        it("does not recover a canceled upstream", function()
            local called = false
            local source = newSource()
            local future = Future.pending(source)
            local recovered = future:recover(function()
                called = true
                return "fallback"
            end)

            future:cancel()
            future:cancel()

            assert.is_false(called, "a cancellation was recovered from")
            assert.are.equal("canceled", recovered.status)
        end)
    end)

    describe("wait", function()
        it("returns at once for a future already settled", function()
            local source = newSource()
            local future = Future.settled(1)
            future:wait(1000)
            assert.are.equal(0, source.advances)
        end)

        it("returns at once for a future with no source", function()
            local future = Future.pending()
            local before = tonumber(C.SDL_GetTicks())
            future:wait(500)
            assert.is_true(tonumber(C.SDL_GetTicks()) - before < 100)
        end)

        it("advances the source until it settles", function()
            local future
            local source = newSource({
                onAdvance = function(self)
                    if self.advances >= 3 then
                        future:complete("arrived")
                    end
                    return 0
                end,
            })
            future = Future.pending(source)
            future:wait(2000)

            assert.are.equal("ready", future.status)
            assert.are.equal(3, source.advances)
        end)

        -- The first of the three defects the duplication carried. Every wait
        -- loop subtracted the nominal slice size whatever the slice actually
        -- cost, and a source answers as soon as one message arrives, so a
        -- "5000 ms" wait was really "at most 312 slices". Against a source that
        -- answers instantly the difference is the whole budget.
        it("spends a wall-clock budget rather than a count of slices", function()
            local BUDGET = 150
            local source = newSource({ sliceMs = 16 })
            local future = Future.pending(source)

            local before = tonumber(C.SDL_GetTicks())
            future:wait(BUDGET)
            local elapsed = tonumber(C.SDL_GetTicks()) - before

            assert.are.equal("pending", future.status)
            assert.is_true(
                elapsed >= BUDGET - 16,
                ("the wait returned after %d ms of a %d ms budget"):format(elapsed, BUDGET)
            )
            -- Slice counting would have stopped at ten. Reaching many more is
            -- what says the budget is time rather than turns.
            assert.is_true(
                source.advances > BUDGET / 16,
                ("only %d slices in %d ms, which is a slice count and not a clock"):format(source.advances, BUDGET)
            )
        end)

        it("never asks for a slice longer than the budget that is left", function()
            local source = newSource({ sliceMs = 1000 })
            local future = Future.pending(source)
            future:wait(30)
            assert.is_true(source.lastSlice <= 30)
        end)

        it("takes its default from the source", function()
            local source = newSource({ sliceMs = 5, defaultWaitMs = 40 })
            local future = Future.pending(source)

            local before = tonumber(C.SDL_GetTicks())
            future:wait()
            local elapsed = tonumber(C.SDL_GetTicks()) - before

            assert.are.equal("pending", future.status)
            assert.is_true(elapsed < 1000, "the wait used the 5000 ms fallback, not the source's")
        end)
    end)

    describe("cancel", function()
        it("settles as canceled and asks the source to stop the work", function()
            local source = newSource()
            local future = Future.pending(source)
            future:cancel()

            assert.are.equal("canceled", future.status)
            assert.are.equal(1, #source.canceled)
            assert.are.equal(future, source.canceled[1])
        end)

        it("is a no-op on a settled future", function()
            local source = newSource()
            local future = Future.pending(source)
            future:complete(1)
            future:cancel()

            assert.are.equal("ready", future.status)
            assert.are.equal(0, #source.canceled)
        end)

        -- The pending half of what `assets.Handle._shares` counted. Two loads
        -- of one path that overlap get the same future, so one of them giving
        -- up must not break the other.
        it("counts watchers, and only the last one stops the work", function()
            local source = newSource()
            local future = Future.pending(source)
            future._watchers = future._watchers + 1

            future:cancel()
            assert.are.equal("pending", future.status, "a shared load was canceled by one sharer")
            assert.are.equal(0, #source.canceled)

            future:cancel()
            assert.are.equal("canceled", future.status)
            assert.are.equal(1, #source.canceled)
        end)

        it("leaves the work running when a derived link is canceled", function()
            local source = newSource()
            local future = Future.pending(source)
            local mapped = future:map(function(value)
                return value
            end)

            mapped:cancel()
            assert.are.equal("canceled", mapped.status)
            assert.are.equal("pending", future.status, "the root was canceled by its dependent")
            assert.are.equal(0, #source.canceled)

            -- And the dropped link is not called when the root settles anyway.
            future:complete("still wanted")
            assert.are.equal("canceled", mapped.status)
        end)

        it("reaches the root when the last link goes", function()
            local source = newSource()
            local future = Future.pending(source)
            local mapped = future:map(function(value)
                return value
            end)

            future:cancel()
            assert.are.equal("pending", future.status, "the map link still wanted it")
            mapped:cancel()
            assert.are.equal("canceled", future.status)
            assert.are.equal(1, #source.canceled)
        end)

        -- The hook belongs to the source and answers for work the source
        -- started, so only the future the source made carries it. A derived
        -- link inherits the source to know what a wait advances and nothing
        -- else; without that distinction a `map` giving up would stop the
        -- decode its upstream is still waiting for.
        it("asks the source only about the future the source made", function()
            local source = newSource()
            local future = Future.pending(source)
            local mapped = future:map(function(value)
                return value
            end)

            mapped:cancel()
            assert.are.equal(0, #source.canceled, "a derived link reached the source's work")

            future:cancel()
            assert.are.equal(1, #source.canceled)
            assert.are.equal(future, source.canceled[1])
        end)

        it("leaves the work running when the source offers no hook", function()
            local source = newSource({ cancels = false })
            local future = Future.pending(source)
            future:cancel()
            assert.are.equal("canceled", future.status)
        end)

        it("propagates as canceled rather than failed", function()
            local future = Future.pending(newSource())
            future:cancel()
            assert.are.equal("canceled", future.status)

            local mapped = future:map(function(value)
                return value
            end)
            assert.are.equal("canceled", mapped.status)
            assert.are_not.equal("failed", mapped.status)
        end)

        -- The counting rule stated the other way round, because it is the
        -- surprising half. Chaining does not hand ownership over: the caller
        -- who started the work still holds a reference to it, so a dependent
        -- giving up leaves the work running and it is the starter's to stop.
        it("keeps the work for a dependent when one holder gives up", function()
            local source = newSource()
            local future = Future.pending(source)
            local mapped = future:map(function(value)
                return value .. "!"
            end)

            future:cancel()
            assert.are.equal("pending", future.status)

            future:complete("still arrived")
            assert.are.equal("still arrived!", mapped.value)
        end)
    end)

    describe("all", function()
        it("carries every value in input order whatever order they settle in", function()
            local first, second, third = Future.pending(), Future.pending(), Future.pending()
            local joined = Future.all({ first, second, third })

            third:complete("c")
            first:complete("a")
            assert.are.equal("pending", joined.status)
            second:complete("b")

            assert.are.equal("ready", joined.status)
            assert.are.same({ "a", "b", "c" }, joined.value)
        end)

        it("settles at once over nothing", function()
            local joined = Future.all({})
            assert.are.equal("ready", joined.status)
            assert.are.same({}, joined.value)
        end)

        it("takes inputs that had already settled", function()
            local joined = Future.all({ Future.settled(1), Future.settled(2) })
            assert.are.equal("ready", joined.status)
            assert.are.same({ 1, 2 }, joined.value)
        end)

        it("fails the join with the first input to fail", function()
            local first, second = Future.pending(), Future.pending()
            local joined = Future.all({ first, second })

            second:fail("second failed")
            assert.are.equal("failed", joined.status)
            assert.are.equal("second failed", joined.error)

            -- The other input is left alone: it may be shared with something
            -- outside the join, which is not this join's to stop.
            assert.are.equal("pending", first.status)
        end)

        it("keeps one source when every input shares it", function()
            local source = newSource()
            local joined = Future.all({ Future.pending(source), Future.pending(source) })
            assert.are.equal(source, joined._source)
        end)

        it("spreads a wait over the sources its inputs do not share", function()
            local first, second = newSource(), newSource()
            local joined = Future.all({ Future.pending(first), Future.pending(second) })

            assert.are_not.equal(first, joined._source)
            joined:wait(60)
            assert.is_true(first.advances > 0, "one source never got a slice")
            assert.is_true(second.advances > 0, "the other source never got a slice")
        end)

        it("decrements every input when the join is canceled", function()
            local source = newSource()
            local first, second = Future.pending(source), Future.pending(source)
            local joined = Future.all({ first, second })

            joined:cancel()
            assert.are.equal("canceled", joined.status)

            -- Each input is one holder lighter, and still held by whoever
            -- started it. That holder giving up is what finishes them, and it
            -- reaching zero here is what says the join let go.
            assert.are.equal("pending", first.status)
            first:cancel()
            second:cancel()
            assert.are.equal("canceled", first.status)
            assert.are.equal("canceled", second.status)
            assert.are.equal(2, #source.canceled)
        end)

        it("leaves an input the join never took", function()
            local source = newSource()
            local shared = Future.pending(source)
            local joined = Future.all({ shared })
            joined:cancel()

            -- One decrement, not a reach-through: the input is still the
            -- starter's, and something outside the join may hold it too.
            shared._watchers = shared._watchers + 1
            shared:cancel()
            assert.are.equal("pending", shared.status)
        end)

        it("does not nest a fan-in", function()
            -- Five hundred inputs is two frames deep, not five hundred: each
            -- listener decrements a counter and only the last one settles the
            -- join.
            local baseline = stackDepth()
            local inputs = {}
            for index = 1, 500 do
                inputs[index] = Future.pending()
            end
            local joined = Future.all(inputs)

            local depth
            joined:onSettle(function()
                depth = stackDepth()
            end)
            for index = 1, 500 do
                inputs[index]:complete(index)
            end

            assert.are.equal("ready", joined.status)
            assert.are.equal(500, #joined.value)
            assert.is_true(
                depth - baseline < 20,
                ("a fan-in nested to %d frames over its caller"):format((depth or 0) - baseline)
            )
        end)
    end)

    -- The sequencer has had a registry for waiting on work outside it and no
    -- engine registrant, so a program could wait for a query, a signal, a tween
    -- or a timer, and could not wait for anything asynchronous. This is the one
    -- provider that closes that.
    describe("the sequence bridge", function()
        local world

        before_each(function()
            world = tecs.ecs.newWorld()
            world:addPlugin(sequence.plugin)
            world:startup()
        end)

        local function stepWorld(steps)
            local timestep = world:getFixedTiming()
            for _ = 1, steps do
                world:update(timestep)
            end
        end

        local names = 0
        local function uniqueName()
            names = names + 1
            return "spec.future.program" .. tostring(names)
        end

        it("parks a program until the future settles", function()
            local loader = world:spawn(tecs.Transform(0, 0))
            world:commit()

            local future = Future.pending()
            Future.track(world, loader, "level1", future)

            local calls = 0
            sequence.registerAction(world, "spec.future.after", function()
                calls = calls + 1
            end)
            sequence.play(
                world,
                sequence.define(uniqueName(), {
                    sequence.await("tecs.future", sequence.bind("loader"), "level1"),
                    sequence.call("spec.future.after"),
                }),
                { bindings = { loader = loader } }
            )

            stepWorld(3)
            assert.are.equal(0, calls, "the program ran on past a future still in flight")

            future:complete("loaded")
            stepWorld(2)
            assert.are.equal(1, calls)
        end)

        it("does not wait for a future that already settled", function()
            local loader = world:spawn(tecs.Transform(0, 0))
            world:commit()
            Future.track(world, loader, "level1", Future.settled("loaded"))

            local calls = 0
            sequence.registerAction(world, "spec.future.after", function()
                calls = calls + 1
            end)
            sequence.play(
                world,
                sequence.define(uniqueName(), {
                    sequence.await("tecs.future", sequence.bind("loader"), "level1"),
                    sequence.call("spec.future.after"),
                }),
                { bindings = { loader = loader } }
            )

            stepWorld(2)
            assert.are.equal(1, calls)
        end)

        it("does not wait for a key nothing was tracked under", function()
            local loader = world:spawn(tecs.Transform(0, 0))
            world:commit()

            local calls = 0
            sequence.registerAction(world, "spec.future.after", function()
                calls = calls + 1
            end)
            sequence.play(
                world,
                sequence.define(uniqueName(), {
                    sequence.await("tecs.future", sequence.bind("loader"), "never"),
                    sequence.call("spec.future.after"),
                }),
                { bindings = { loader = loader } }
            )

            stepWorld(2)
            assert.are.equal(1, calls)
        end)

        it("keys by entity and key rather than by identity", function()
            -- What makes the wait survive a snapshot the future cannot: a
            -- restored cursor carries the provider name, the entity and the
            -- key, and a game re-issuing the work re-tracks it under the same
            -- key with no further cooperation.
            local loader = world:spawn(tecs.Transform(0, 0))
            world:commit()

            local first = Future.pending()
            Future.track(world, loader, "level1", first)

            local replacement = Future.pending()
            Future.track(world, loader, "level1", replacement)

            local calls = 0
            sequence.registerAction(world, "spec.future.after", function()
                calls = calls + 1
            end)
            sequence.play(
                world,
                sequence.define(uniqueName(), {
                    sequence.await("tecs.future", sequence.bind("loader"), "level1"),
                    sequence.call("spec.future.after"),
                }),
                { bindings = { loader = loader } }
            )

            stepWorld(2)
            assert.are.equal(0, calls)

            -- The first settling must not release a program waiting on the one
            -- that replaced it.
            first:complete("stale")
            stepWorld(2)
            assert.are.equal(0, calls)

            replacement:complete("fresh")
            stepWorld(2)
            assert.are.equal(1, calls)
        end)

        it("refuses a track with no key", function()
            assert.has_error(function()
                Future.track(world, 1, "", Future.pending())
            end)
        end)
    end)
end)
