require("busted")
local tecs <const> = require("tecs")
local luassert = require("luassert")

describe(
    "runIf helpers",
    function()
        local world: tecs.World

        before_each(function() world = tecs.newWorld() end)

        describe(
            "after",
            function()
                it(
                    "should fire once after delay and remove itself",
                    function()
                        local callCount = 0
                        local systemName = "OneShotSystem"

                        world:addSystem({
                            name = systemName,
                            phase = tecs.phases.Update,
                            runIf = tecs.runif.after(0.1),
                            run = function(_dt: number, _world: tecs.World) callCount = callCount + 1 end,
                        })

                        -- Should not run immediately
                        world:update(0.05)
                        luassert.equals(0, callCount, "System should not run before delay")

                        -- Should fire after total 0.1 seconds
                        world:update(0.05)
                        luassert.equals(1, callCount, "System should run after delay")

                        -- System should be removed after running
                        world:update(0.1)
                        luassert.equals(1, callCount, "System should not run again after being removed")
                    end
                )

                it(
                    "should fire and self-remove on an unnamed system",
                    function()
                        local callCount = 0

                        world:addSystem({
                            phase = tecs.phases.Update,
                            runIf = tecs.runif.after(0.1),
                            run = function(_dt: number, _world: tecs.World) callCount = callCount + 1 end,
                        })

                        world:update(0.05)
                        luassert.equals(0, callCount)

                        world:update(0.05)
                        luassert.equals(1, callCount)

                        world:update(0.1)
                        luassert.equals(1, callCount, "System should self-remove even without explicit name")
                    end
                )

                it(
                    "should handle zero delay",
                    function()
                        local callCount = 0

                        world:addSystem({
                            name = "ImmediateSystem",
                            phase = tecs.phases.Update,
                            runIf = tecs.runif.after(0),
                            run = function(_dt: number, _world: tecs.World) callCount = callCount + 1 end,
                        })

                        world:update(0.001)
                        luassert.equals(1, callCount, "System should run immediately with zero delay")

                        world:update(0.001)
                        luassert.equals(1, callCount, "System should only run once")
                    end
                )
            end
        )

        describe(
            "every",
            function()
                it(
                    "should fire repeatedly at intervals",
                    function()
                        local callCount = 0

                        world:addSystem({
                            name = "RepeatingSystem",
                            phase = tecs.phases.Update,
                            runIf = tecs.runif.every(0.1),
                            run = function(_dt: number, _world: tecs.World) callCount = callCount + 1 end,
                        })

                        -- First interval
                        world:update(0.05)
                        luassert.equals(0, callCount)
                        world:update(0.05)
                        luassert.equals(1, callCount, "Should fire after first interval")

                        -- Second interval
                        world:update(0.1)
                        luassert.equals(2, callCount, "Should fire after second interval")

                        -- Third interval
                        world:update(0.1)
                        luassert.equals(3, callCount, "Should fire after third interval")
                    end
                )

                it(
                    "should handle jitter parameter without errors",
                    function()
                        local callCount = 0

                        -- Just verify that jitter doesn't cause errors
                        world:addSystem({
                            name = "JitteredSystem",
                            phase = tecs.phases.Update,
                            runIf = tecs.runif.every(0.05, 0.02),
                            run = function(_dt: number, _world: tecs.World) callCount = callCount + 1 end,
                        })

                        -- Run several updates - with jitter this should still work
                        for _ = 1, 30 do
                            world:update(0.01)
                        end
                        -- Over 0.3 seconds with interval ~0.05±0.02, should fire multiple times
                        -- We're not strict about the count due to randomness, just verify it fires
                        luassert.is_true(callCount > 0, "Should fire at least once with jitter")
                    end
                )

                it(
                    "should accumulate partial frames correctly",
                    function()
                        local callCount = 0

                        world:addSystem({
                            name = "AccumulatingSystem",
                            phase = tecs.phases.Update,
                            runIf = tecs.runif.every(0.1),
                            run = function(_dt: number, _world: tecs.World) callCount = callCount + 1 end,
                        })

                        -- Run with irregular intervals that accumulate to the target
                        world:update(0.03) -- 0.03 accumulated
                        luassert.equals(0, callCount)
                        world:update(0.03) -- 0.06 accumulated
                        luassert.equals(0, callCount)
                        world:update(0.04) -- 0.10 accumulated - should fire
                        luassert.equals(1, callCount)
                    end
                )
            end
        )

        describe(
            "cooldown",
            function()
                it(
                    "should fire immediately, then suppress until cooldown elapses",
                    function()
                        local callCount = 0

                        world:addSystem({
                            name = "CooldownSystem",
                            phase = tecs.phases.Update,
                            runIf = tecs.runif.cooldown(0.2),
                            run = function(_dt: number, _world: tecs.World) callCount = callCount + 1 end,
                        })

                        -- Should fire immediately on first update
                        world:update(0.01)
                        luassert.equals(1, callCount, "Should fire immediately on first call")

                        -- Should not fire during cooldown
                        world:update(0.1)
                        luassert.equals(1, callCount, "Should not fire during cooldown")

                        -- Still in cooldown
                        world:update(0.09)
                        luassert.equals(1, callCount, "Should still be in cooldown")

                        -- Cooldown elapsed, should fire again
                        world:update(0.01)
                        luassert.equals(2, callCount, "Should fire again after cooldown")
                    end
                )
            end
        )

        describe(
            "unique system names",
            function()
                it(
                    "should error when adding duplicate system names",
                    function()
                        world:addSystem({name = "DuplicateSystem", phase = tecs.phases.Update, run = function() end})

                        luassert.error_matches(
                            function()
                                world:addSystem({
                                    name = "DuplicateSystem", phase = tecs.phases.PostUpdate, run = function() end
                                })
                            end,
                            "System with name 'DuplicateSystem' already exists",
                            "Should error on duplicate system name"
                        )
                    end
                )

                it(
                    "should allow systems without names",
                    function()
                        -- Should not error when adding unnamed systems
                        local success1 = pcall(
                            function() world:addSystem({phase = tecs.phases.Update, run = function() end}) end
                        )

                        local success2 = pcall(
                            function() world:addSystem({phase = tecs.phases.Update, run = function() end}) end
                        )

                        -- Both systems should be added successfully without error
                        luassert.is_true(success1, "First unnamed system should be added without error")
                        luassert.is_true(success2, "Second unnamed system should be added without error")
                    end
                )
            end
        )

        describe(
            "removeSystem by name only",
            function()
                it(
                    "should remove system by name without specifying phase",
                    function()
                        local callCount = 0

                        world:addSystem({
                            name = "TestSystem",
                            phase = tecs.phases.Update,
                            run = function() callCount = callCount + 1 end,
                        })

                        world:update(0.01)
                        luassert.equals(1, callCount, "System should run before removal")

                        world:removeSystem("TestSystem")

                        world:update(0.01)
                        luassert.equals(1, callCount, "System should not run after removal")
                    end
                )

                it(
                    "should error when removing non-existent system",
                    function()
                        luassert.error_matches(
                            function() world:removeSystem("NonExistentSystem") end,
                            "System 'NonExistentSystem' not found",
                            "Should error when system not found"
                        )
                    end
                )
            end
        )

        describe(
            "inState",
            function()
                it(
                    "should run only when in specified state",
                    function()
                        world:createState("menu")
                        world:createState("playing")
                        world:createState("paused")

                        local callCount = 0

                        world:addSystem({
                            name = "PlayingOnlySystem",
                            phase = tecs.phases.Update,
                            runIf = tecs.runif.inState("playing"),
                            run = function() callCount = callCount + 1 end,
                        })

                        -- Should not run when no state is active
                        world:update(0.01)
                        luassert.equals(0, callCount, "Should not run with empty stack")

                        -- Should run in playing state
                        world:pushState("playing")
                        world:update(0.01)
                        luassert.equals(1, callCount, "Should run in playing state")

                        -- Should not run in paused state
                        world:pushState("paused")
                        world:update(0.01)
                        luassert.equals(1, callCount, "Should not run in paused state")
                    end
                )
            end
        )

        describe(
            "negate combinator",
            function()
                it(
                    "should invert another runIf predicate",
                    function()
                        world:createState("menu")
                        world:createState("playing")

                        local callCount = 0

                        world:addSystem({
                            name = "NotPlayingSystem",
                            phase = tecs.phases.Update,
                            runIf = tecs.runif.negate(tecs.runif.inState("playing")),
                            run = function() callCount = callCount + 1 end,
                        })

                        -- Push menu state first
                        world:pushState("menu")

                        -- Should run when NOT in playing state (currently in menu)
                        world:update(0.01)
                        luassert.equals(1, callCount, "Should run when not in playing state")

                        -- Should not run when in playing state
                        world:pushState("playing")
                        world:update(0.01)
                        luassert.equals(1, callCount, "Should not run when in playing state")

                        -- Should run again when back to menu
                        world:popState()
                        world:update(0.01)
                        luassert.equals(2, callCount, "Should run again when not in playing state")
                    end
                )
            end
        )

        describe(
            "both / either operand ordering",
            function()
                it(
                    "gate-first freezes the timer while the gate is closed",
                    function()
                        local gate = false
                        local pred = tecs.runif.both(function(): boolean return gate end, tecs.runif.every(1))

                        -- Two seconds pass while gated; the timer must NOT accumulate,
                        -- or reopening the gate would burst-fire the backlog.
                        luassert.is_false(pred(1.0, world, "s"))
                        luassert.is_false(pred(1.0, world, "s"))
                        gate = true
                        luassert.is_false(
                            pred(0.4, world, "s"), "the timer resumes from zero, not from the gated backlog"
                        )
                        luassert.is_true(pred(0.6, world, "s"), "the timer fires one interval after the gate opened")
                    end
                )

                it(
                    "timer-first keeps cadence and spends gated fires",
                    function()
                        local gate = false
                        local pred = tecs.runif.both(tecs.runif.every(1), function(): boolean return gate end)

                        luassert.is_false(pred(1.0, world, "s"), "fire spent while gated")
                        gate = true
                        luassert.is_false(pred(0.4, world, "s"), "the gated fire is not deferred to the next tick")
                        luassert.is_true(pred(0.6, world, "s"), "the timer keeps its own cadence")
                    end
                )
            end
        )

        describe(
            "every with jitter",
            function()
                it(
                    "clamps pathological jitter to a positive interval",
                    function()
                        local pred = tecs.runif.every(1, 5)
                        local fires = 0
                        for _ = 1, 1000 do
                            if pred(0.1, world, "s") then
                                fires = fires + 1
                            end
                        end
                        -- 100s of simulated time over clamped intervals averaging ~2s
                        -- yields well under 200 fires; nonpositive intervals fire on
                        -- roughly 40 percent of the 1000 frames.
                        luassert.is_true(fires < 200, "jitter >= interval must not fire every frame, got " .. fires)
                    end
                )

                -- Jitter comes off the world's `tecs.runif` stream rather than a
                -- process-wide generator, so the frames a jittered system fires on are
                -- a function of the world's seed and nothing else.
                local function schedule(seed: integer): {integer}
                    local scoped <const> = tecs.newWorld()
                    tecs.random.seed(scoped, seed)
                    local pred <const> = tecs.runif.every(0.1, 0.05)
                    local hits: {integer} = {}
                    for frame = 1, 600 do
                        if pred(1 / 60, scoped, "s") then
                            hits[#hits + 1] = frame
                        end
                    end
                    return hits
                end

                it(
                    "fires on the same frames for the same world seed",
                    function()
                        local first <const> = schedule(4242)
                        luassert.is_true(#first > 20, "only " .. tostring(#first) .. " fires to compare")
                        luassert.same(first, schedule(4242))
                    end
                )

                it(
                    "fires on different frames for a different world seed",
                    function()
                        local a <const> = schedule(4242)
                        local b <const> = schedule(4243)
                        local same = #a == #b
                        if same then
                            for i = 1, #a do
                                if a[i] ~= b[i] then
                                    same = false
                                end
                            end
                        end
                        luassert.is_false(same, "two seeds produced the same schedule")
                    end
                )

                it(
                    "carries its place through a snapshot",
                    function()
                        local scoped <const> = tecs.newWorld()
                        tecs.random.seed(scoped, 4242)

                        -- Rolled a few times first, so the save is taken mid-sequence and
                        -- restoring it is doing more than restarting from the seed.
                        local warm <const> = tecs.runif.every(0.1, 0.05)
                        for _ = 1, 120 do
                            warm(1 / 60, scoped, "s")
                        end

                        local out <const> = scoped:saveSnapshot()
                        local saved <const> = out.buffer
                        if saved == nil then
                            error("saveSnapshot returned no buffer")
                        end

                        -- A predicate's own elapsed time is closure state a snapshot does
                        -- not reach, so both runs start with a fresh one; what is asserted
                        -- is that the rolls the second makes are the restored ones.
                        local function drive(): {integer}
                            local pred <const> = tecs.runif.every(0.1, 0.05)
                            local hits: {integer} = {}
                            for frame = 1, 300 do
                                if pred(1 / 60, scoped, "s") then
                                    hits[#hits + 1] = frame
                                end
                            end
                            return hits
                        end

                        local expected <const> = drive()
                        scoped:loadSnapshot(saved)
                        luassert.same(expected, drive())
                    end
                )
            end
        )
    end
)
