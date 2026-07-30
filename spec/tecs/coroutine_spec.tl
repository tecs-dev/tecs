require("busted")
local tecs <const> = require("tecs")
local Future <const> = require("tecs.Future")
local luassert = require("luassert")

local type World = tecs.World

local FRAME <const> = 1 / 60

-- Component names are global, so each spec that declares one needs its own.
local componentId = 0
local function nextComponentId(): integer
    componentId = componentId + 1
    return componentId
end

-- Drives `count` frames at a fixed dt, which is what a coroutine system's waits are
-- counted in.
local function frames(world: World, count: integer, dt?: number)
    for _ = 1, count do
        world:update(dt or FRAME)
    end
end

describe(
    "coroutine systems",
    function()
        describe(
            "registration",
            function()
                it(
                    "refuses a system with neither run nor coroutine",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        luassert.has_error(
                            function()
                                world:addSystem({name = "empty", phase = tecs.ecs.phases.Update})
                            end
                        )
                    end
                )

                it(
                    "refuses a system with both run and coroutine",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        luassert.has_error(
                            function()
                                world:addSystem({
                                    name = "both",
                                    phase = tecs.ecs.phases.Update,
                                    run = function() end,
                                    coroutine = function() end,
                                })
                            end
                        )
                    end
                )

                it(
                    "refuses a coroutine system in every phase that does not run once per frame",
                    function()
                        local denied <const> = {
                            {tecs.ecs.phases.PreStartup, "PreStartup"},
                            {tecs.ecs.phases.Startup, "Startup"},
                            {tecs.ecs.phases.PostStartup, "PostStartup"},
                            {tecs.ecs.phases.FixedFirst, "FixedFirst"},
                            {tecs.ecs.phases.FixedUpdate, "FixedUpdate"},
                            {tecs.ecs.phases.FixedLast, "FixedLast"},
                            {tecs.ecs.phases.RenderFirst, "RenderFirst"},
                            {tecs.ecs.phases.Render, "Render"},
                            {tecs.ecs.phases.RenderLast, "RenderLast"},
                            {tecs.ecs.phases.PreShutdown, "PreShutdown"},
                            {tecs.ecs.phases.Shutdown, "Shutdown"},
                            {tecs.ecs.phases.PostShutdown, "PostShutdown"},
                        }
                        for i = 1, #denied do
                            local world <const> = tecs.ecs.newWorld()
                            local phase <const> = denied[i][1] as tecs.Phase
                            local name <const> = denied[i][2] as string
                            local ok <const>, err <const> = pcall(
                                function()
                                    world:addSystem({
                                        name = "parked",
                                        phase = phase,
                                        coroutine = function(w: World) w:yield() end,
                                    })
                                end
                            )
                            luassert.is_false(ok, name .. " should refuse a coroutine system")
                            luassert.is_truthy(
                                (tostring(err)):find(name, 1, true),
                                name .. " should be named in its own rejection"
                            )
                        end
                    end
                )

                it(
                    "accepts a coroutine system in every phase that runs once per frame",
                    function()
                        local allowed <const> = {
                            tecs.ecs.phases.First,
                            tecs.ecs.phases.PreUpdate,
                            tecs.ecs.phases.Update,
                            tecs.ecs.phases.PostUpdate,
                            tecs.ecs.phases.Last,
                        }
                        for i = 1, #allowed do
                            local world <const> = tecs.ecs.newWorld()
                            world:addSystem({
                                name = "parked",
                                phase = allowed[i] as tecs.Phase,
                                coroutine = function(w: World) while true do w:yield() end end,
                            })
                            frames(world, 2)
                        end
                    end
                )

                it(
                    "leaves the name free after refusing a denied phase",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        pcall(
                            function()
                                world:addSystem({
                                    name = "taken",
                                    phase = tecs.ecs.phases.Render,
                                    coroutine = function(w: World) w:yield() end,
                                })
                            end
                        )
                        world:addSystem({
                            name = "taken",
                            phase = tecs.ecs.phases.Update,
                            run = function() end,
                        })
                    end
                )
            end
        )

        describe(
            "parking",
            function()
                it(
                    "carries locals across frames and resumes on the next line",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local seen: {integer} = {}
                        world:addSystem({
                            name = "counting",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                local at = 0
                                while true do
                                    at = at + 1
                                    seen[#seen + 1] = at
                                    w:yield()
                                end
                            end,
                        })

                        frames(world, 3)
                        luassert.same({1, 2, 3}, seen)
                    end
                )

                it(
                    "returns the dt of the frame it resumed on, not the one it parked on",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local seen: {number} = {}
                        world:addSystem({
                            name = "timing",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                while true do
                                    seen[#seen + 1] = w:yield()
                                end
                            end,
                        })

                        world:update(0.25)
                        world:update(0.5)
                        world:update(0.125)
                        luassert.same({0.5, 0.125}, seen)
                    end
                )

                it(
                    "sleeps for a number of seconds counted in its own phase dt",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local ticks = 0
                        world:addSystem({
                            name = "sleeping",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                while true do
                                    ticks = ticks + 1
                                    w:yield(0.5)
                                end
                            end,
                        })

                        frames(world, 1, 0.1)
                        luassert.equal(1, ticks)
                        frames(world, 4, 0.1)
                        luassert.equal(1, ticks, "still short of half a second")
                        frames(world, 1, 0.1)
                        luassert.equal(2, ticks, "the sixth tenth crosses it")
                    end
                )

                it(
                    "does not age a wait while runIf gates the system off",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local ticks = 0
                        local gate = false
                        world:addSystem({
                            name = "gated",
                            phase = tecs.ecs.phases.Update,
                            runIf = function(): boolean return gate end,
                            coroutine = function(w: World)
                                while true do
                                    ticks = ticks + 1
                                    w:yield(0.5)
                                end
                            end,
                        })

                        frames(world, 10, 0.1)
                        luassert.equal(0, ticks, "a gated system never started")
                        gate = true
                        frames(world, 1, 0.1)
                        luassert.equal(1, ticks)
                        frames(world, 4, 0.1)
                        luassert.equal(1, ticks)
                        frames(world, 1, 0.1)
                        luassert.equal(2, ticks)
                    end
                )
            end
        )

        describe(
            "settling",
            function()
                it(
                    "parks on a pending future and answers with its value",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local future <const> = Future.pending() as tecs.Future<string>
                        local got: string = nil
                        local finished = false

                        world:addSystem({
                            name = "awaiting",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                got = future:yield(w)
                                finished = true
                            end,
                        })

                        frames(world, 3)
                        luassert.is_nil(got, "nothing settled it yet")

                        future:complete("done")
                        frames(world, 1)
                        luassert.equal("done", got, "the wait answers with the value, not the future")
                        luassert.is_true(finished)
                    end
                )

                it(
                    "raises at the wait when the future fails",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local future <const> = Future.pending() as tecs.Future<string>
                        local caught: string = nil
                        local past = false

                        world:addSystem({
                            name = "recovering",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                local ok <const>, err <const> = pcall(function(): string
                                    return future:yield(w)
                                end)
                                if not ok then
                                    caught = tostring(err)
                                end
                                past = true
                            end,
                        })

                        frames(world, 1)
                        future:fail("disk on fire")
                        frames(world, 1)
                        luassert.is_truthy(caught, "a failed future raises rather than returning")
                        luassert.is_truthy((caught):find("recovering", 1, true), "names the system")
                        luassert.is_truthy((caught):find("disk on fire", 1, true), "carries the reason")
                        luassert.is_true(past, "pcall lets the body carry on")
                    end
                )

                it(
                    "raises at the wait when the future is canceled",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local future <const> = Future.pending() as tecs.Future<string>
                        local caught: string = nil

                        world:addSystem({
                            name = "abandoned",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                local ok <const>, err <const> = pcall(function(): string
                                    return future:yield(w)
                                end)
                                if not ok then
                                    caught = tostring(err)
                                end
                            end,
                        })

                        frames(world, 1)
                        future:abandon(nil)
                        frames(world, 1)
                        luassert.is_truthy(caught)
                        luassert.is_truthy((caught):find("canceled", 1, true))
                    end
                )

                it(
                    "does not give up a slot for a future that has already settled",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local seen: {string} = {}

                        world:addSystem({
                            name = "cached",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                seen[#seen + 1] = (Future.settled("a") as tecs.Future<string>):yield(w)
                                seen[#seen + 1] = (Future.settled("b") as tecs.Future<string>):yield(w)
                                seen[#seen + 1] = (Future.settled("c") as tecs.Future<string>):yield(w)
                            end,
                        })

                        frames(world, 1)
                        luassert.same({"a", "b", "c"}, seen, "three settled waits finish in one frame")
                    end
                )

                it(
                    "raises at the wait for an already-settled failure without parking",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local caught: string = nil

                        world:addSystem({
                            name = "cachedFailure",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                local ok <const>, err <const> = pcall(function(): string
                                    return (Future.failed("gone") as tecs.Future<string>):yield(w)
                                end)
                                if not ok then
                                    caught = tostring(err)
                                end
                            end,
                        })

                        frames(world, 1)
                        luassert.is_truthy(caught, "the early-return path raises too")
                        luassert.is_truthy((caught):find("gone", 1, true))
                    end
                )

                it(
                    "still answers with a delta time when the wait had no value",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local plain: number = nil
                        local slept: number = nil

                        world:addSystem({
                            name = "timings",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                plain = w:yield()
                                slept = w:yield(0.05)
                            end,
                        })

                        frames(world, 1)
                        frames(world, 1, 0.25)
                        frames(world, 1, 0.125)
                        luassert.equal(0.25, plain)
                        luassert.equal(0.125, slept)
                    end
                )

                it(
                    "is not woken by a future it stopped waiting for",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local first <const> = Future.pending() as tecs.Future<string>
                        local second <const> = Future.pending() as tecs.Future<string>
                        local reached = 0

                        world:addSystem({
                            name = "twoWaits",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                -- Times out rather than settling, so the body
                                -- moves on while the first future is still live
                                -- and still holding this system's listener.
                                pcall(function() first:yield(w, 50) end)
                                reached = 1
                                second:yield(w)
                                reached = 2
                            end,
                        })

                        frames(world, 1)
                        frames(world, 5, 0.02)
                        luassert.equal(1, reached, "the first wait gave up")

                        -- The listener the abandoned wait left behind must not
                        -- count as the second wait's answer.
                        first:complete("first")
                        frames(world, 3)
                        luassert.equal(1, reached, "the second wait is still pending")

                        second:complete("second")
                        frames(world, 1)
                        luassert.equal(2, reached)
                    end
                )
            end
        )

        describe(
            "timeouts",
            function()
                it(
                    "raises at the yield when the budget runs out",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local future <const> = Future.pending() as tecs.Future<string>
                        local caught: string = nil

                        world:addSystem({
                            name = "impatient",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                local ok <const>, err <const> = pcall(function() future:yield(w, 100) end)
                                if not ok then
                                    caught = tostring(err)
                                end
                            end,
                        })

                        frames(world, 1)
                        luassert.is_nil(caught)
                        frames(world, 20)
                        luassert.is_truthy(caught, "the wait should have given up")
                        luassert.is_truthy((caught):find("timed out", 1, true))
                        luassert.is_truthy((caught):find("impatient", 1, true))
                    end
                )

                it(
                    "does not raise when the future settles inside the budget",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local future <const> = Future.pending() as tecs.Future<string>
                        local ok = false

                        world:addSystem({
                            name = "patient",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                future:yield(w, 10000)
                                ok = true
                            end,
                        })

                        frames(world, 5)
                        future:complete("in time")
                        frames(world, 1)
                        luassert.is_true(ok)
                    end
                )
            end
        )

        describe(
            "death",
            function()
                it(
                    "unregisters itself when the body returns",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local steps = 0

                        world:addSystem({
                            name = "task",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                for _ = 1, 3 do
                                    steps = steps + 1
                                    w:yield()
                                end
                            end,
                        })

                        frames(world, 10)
                        luassert.equal(3, steps)
                        luassert.has_error(function() world:removeSystem("task") end)
                    end
                )

                it(
                    "frees the name for a fresh registration once it is done",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local runs = 0
                        local function once(w: World)
                            runs = runs + 1
                            w:yield()
                        end

                        world:addSystem({name = "once", phase = tecs.ecs.phases.Update, coroutine = once})
                        frames(world, 3)
                        luassert.equal(1, runs)

                        world:addSystem({name = "once", phase = tecs.ecs.phases.Update, coroutine = once})
                        frames(world, 3)
                        luassert.equal(2, runs)
                    end
                )

                it(
                    "raises onward like any other system failure, carrying its own traceback",
                    function()
                        local world <const> = tecs.ecs.newWorld()

                        world:addSystem({
                            name = "raising",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                w:yield()
                                error("deliberate")
                            end,
                        })

                        frames(world, 1)
                        local ok <const>, err <const> = pcall(function() world:update(FRAME) end)
                        luassert.is_false(ok, "a coroutine system failure stops the frame like a run failure")
                        local message <const> = tostring(err)
                        luassert.is_truthy((message):find("raising", 1, true), "names the system")
                        luassert.is_truthy((message):find("deliberate", 1, true), "carries the error")
                        luassert.is_truthy(
                            (message):find("stack traceback", 1, true),
                            "carries the body's own traceback rather than the scheduler's"
                        )
                    end
                )

                it(
                    "unregisters a body that raised, so the next frame does not resume it",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local after = 0

                        world:addSystem({
                            name = "raising",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                w:yield()
                                error("deliberate")
                            end,
                        })
                        world:addSystem({
                            name = "following",
                            phase = tecs.ecs.phases.Update,
                            after = {"raising"},
                            run = function() after = after + 1 end,
                        })

                        frames(world, 1)
                        pcall(function() world:update(FRAME) end)
                        luassert.has_error(
                            function() world:removeSystem("raising") end,
                            nil,
                            "the failed body is already gone"
                        )

                        after = 0
                        frames(world, 3)
                        luassert.equal(3, after, "the surviving systems keep running")
                    end
                )

                it(
                    "stops resuming a body removed while it was parked",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local ticks = 0

                        world:addSystem({
                            name = "doomed",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                while true do
                                    ticks = ticks + 1
                                    w:yield()
                                end
                            end,
                        })

                        frames(world, 2)
                        luassert.equal(2, ticks)
                        world:removeSystem("doomed")
                        frames(world, 3)
                        luassert.equal(2, ticks)
                    end
                )
            end
        )

        describe(
            "guards",
            function()
                it(
                    "raises when yield is called outside a coroutine system",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        luassert.has_error(function() world:yield() end)

                        local reached = false
                        world:addSystem({
                            name = "plainRun",
                            phase = tecs.ecs.phases.Update,
                            run = function(_dt: number, w: World)
                                local ok <const> = pcall(function() w:yield() end)
                                reached = not ok
                            end,
                        })
                        frames(world, 1)
                        luassert.is_true(reached, "a run system may not yield")
                    end
                )

                it(
                    "raises when yielding during query iteration",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local Position <const> = tecs.ecs.newComponent({
                            name = "CoroPosition_" .. tostring(nextComponentId()),
                            container = {x = 0},
                        })
                        world:spawn(Position)

                        local caught: string = nil
                        world:addSystem({
                            name = "iterating",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                local query <const> = w:newQuery({all = {Position}})
                                local cursor <const> = query:newCursor()
                                for _archetype in cursor:iter() do
                                    local ok <const>, err <const> = pcall(function() w:yield() end)
                                    if not ok then
                                        caught = tostring(err)
                                    end
                                    break
                                end
                                cursor:close()
                            end,
                        })

                        frames(world, 1)
                        luassert.is_truthy(caught, "yielding inside iteration should raise")
                        luassert.is_truthy((caught):find("query iteration", 1, true))
                    end
                )

                it(
                    "leaves the world committing normally after that raise",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local Position <const> = tecs.ecs.newComponent({
                            name = "CoroPosition_" .. tostring(nextComponentId()),
                            container = {x = 0},
                        })
                        world:spawn(Position)

                        world:addSystem({
                            name = "iterating",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                local query <const> = w:newQuery({all = {Position}})
                                local cursor <const> = query:newCursor()
                                for _archetype in cursor:iter() do
                                    pcall(function() w:yield() end)
                                    break
                                end
                                cursor:close()
                            end,
                        })
                        world:addSystem({
                            name = "spawning",
                            phase = tecs.ecs.phases.PostUpdate,
                            run = function(_dt: number, w: World) w:spawn(Position) end,
                        })

                        frames(world, 1)
                        local query <const> = world:newQuery({all = {Position}})
                        local seen = 0
                        for _archetype, length in query:iter() do
                            seen = seen + length
                        end
                        luassert.equal(2, seen, "the later spawn applied rather than staging")
                    end
                )

                it(
                    "rejects a sleep that is not a length of time",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local caught: string = nil
                        world:addSystem({
                            name = "confused",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(w: World)
                                local ok <const>, err <const> = pcall(function() w:yield(-1) end)
                                if not ok then
                                    caught = tostring(err)
                                end
                            end,
                        })
                        frames(world, 1)
                        luassert.is_truthy(caught)
                    end
                )

                it(
                    "rejects yielding on a future without the dispatching world",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local future <const> = Future.pending() as tecs.Future<string>
                        local caught: string = nil
                        world:addSystem({
                            name = "worldless",
                            phase = tecs.ecs.phases.Update,
                            coroutine = function(_w: World)
                                local ok <const>, err <const> = pcall(function()
                                    return future:yield(nil)
                                end)
                                if not ok then
                                    caught = tostring(err)
                                end
                            end,
                        })
                        frames(world, 1)
                        luassert.is_truthy(caught)
                    end
                )

                it(
                    "rejects yielding on a future from outside a coroutine system",
                    function()
                        local world <const> = tecs.ecs.newWorld()
                        local future <const> = Future.pending() as tecs.Future<string>
                        luassert.has_error(function() return future:yield(world) end)
                    end
                )
            end
        )
    end
)
