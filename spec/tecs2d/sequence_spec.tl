require("busted")

local luassert <const> = require("luassert")
local tecs <const> = require("tecs")
local sequence <const> = require("tecs2d.sequence")
local tween <const> = require("tecs2d.tween")

-- Programs are process-global and keyed by name, so every test uses a unique
-- name to keep versions from leaking between cases.
local nameCounter = 0
local function uniqueName(): string
    nameCounter = nameCounter + 1
    return "spec.program" .. tostring(nameCounter)
end

-- Advance whole fixed steps. tecs2d.sequence ticks in FixedFirst, so the
-- world's timestep is what drives it.
local function stepWorld(world: tecs.World, steps: integer)
    local timestep = world:getFixedTiming()
    for _ = 1, steps do
        world:update(timestep)
    end
end

describe("tecs2d.sequence", function()
    local world: tecs.World

    before_each(function()
        world = tecs.newWorld()
        world:addPlugin(sequence.plugin)
        world:startup()
    end)

    describe("authoring", function()
        it("rejects malformed nodes", function()
            luassert.has_error(function() sequence.call("") end)
            luassert.has_error(function() sequence.wait(-1) end)
            luassert.has_error(function() sequence.waitSteps(1.5) end)
            luassert.has_error(function() sequence.emit("") end)
            luassert.has_error(function() sequence.loop(2, {}) end)
            luassert.has_error(function() sequence.bind("") end)
        end)

        it("rejects a non-node entry", function()
            luassert.has_error(function()
                sequence.define(uniqueName(), {{} as sequence.Node})
            end)
        end)

        it("versions a redefined name", function()
            local name = uniqueName()
            local first = sequence.define(name, {sequence.waitSteps(1)})
            local second = sequence.define(name, {sequence.waitSteps(2)})

            luassert.equals(1, first.version)
            luassert.equals(2, second.version)
            luassert.equals(2, sequence.program(name).version)
        end)

        it("returns nil for an undefined program", function()
            luassert.is_nil(sequence.program("spec.neverDefined"))
        end)

        it("keeps a superseded version while a playback still runs it", function()
            local name = uniqueName()
            sequence.registerAction(world, "spec.noop", function() end)
            local v1 = sequence.define(name, {
                sequence.waitSteps(3),
                sequence.call("spec.noop"),
            })
            local handle = sequence.play(world, v1)
            sequence.define(name, {sequence.call("spec.noop")})

            luassert.equals(1, sequence.program(name, 1).version,
                "the running version must stay reachable after it is superseded")

            stepWorld(world, 5)
            luassert.equals("completed", sequence.status(world, handle).state)
            luassert.is_nil(sequence.program(name, 1),
                "the superseded version is released with its last playback")
            luassert.equals(2, sequence.program(name).version,
                "the newest version is always kept")
        end)

        it("keeps a superseded version alive for a branch of it", function()
            local name = uniqueName()
            sequence.registerAction(world, "spec.noop", function() end)
            local v1 = sequence.define(name, {
                sequence.parallel(
                    {sequence.waitSteps(2), sequence.call("spec.noop")},
                    {sequence.waitSteps(6), sequence.call("spec.noop")}
                ),
            })
            sequence.play(world, v1)
            sequence.define(name, {sequence.call("spec.noop")})

            stepWorld(world, 4)
            luassert.is_not_nil(sequence.program(name, 1),
                "a live branch still holds the version its program came from")

            stepWorld(world, 4)
            luassert.is_nil(sequence.program(name, 1))
        end)

        it("releases a version when its last playback is cancelled", function()
            local name = uniqueName()
            local v1 = sequence.define(name, {sequence.waitSteps(20)})
            local handle = sequence.play(world, v1)
            sequence.define(name, {sequence.waitSteps(1)})

            luassert.is_not_nil(sequence.program(name, 1))
            sequence.cancel(world, handle)
            luassert.is_nil(sequence.program(name, 1))
        end)

        it("releases versions the playbacks a snapshot load discarded held", function()
            local name = uniqueName()
            local v1 = sequence.define(name, {sequence.waitSteps(20)})

            local empty = world:saveSnapshot().buffer
            sequence.play(world, v1)
            sequence.define(name, {sequence.waitSteps(1)})
            luassert.is_not_nil(sequence.program(name, 1))

            -- Loading a snapshot taken before it started throws the playback
            -- away, and the version it was the last user of goes with it.
            world:loadSnapshot(empty)
            luassert.equals(0, sequence.activeCount(world))
            luassert.is_nil(sequence.program(name, 1))
        end)
    end)

    describe("clocks", function()
        it("defaults a program to the fixed clock", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local prog = sequence.define(uniqueName(), {
                sequence.waitSteps(2),
                sequence.call("spec.count"),
            })
            sequence.play(world, prog)

            stepWorld(world, 2)
            luassert.equals(0, calls)
            stepWorld(world, 1)
            luassert.equals(1, calls)
        end)

        it("counts frames, not fixed steps, on the frame clock", function()
            local fixedCalls, frameCalls = 0, 0
            sequence.registerAction(world, "spec.fixed", function()
                fixedCalls = fixedCalls + 1
            end)
            sequence.registerAction(world, "spec.frame", function()
                frameCalls = frameCalls + 1
            end)

            local onFixed = sequence.define(uniqueName(), {
                sequence.waitSteps(1),
                sequence.call("spec.fixed"),
            })
            local onFrame = sequence.define(uniqueName(), {
                sequence.waitSteps(1),
                sequence.call("spec.frame"),
            }, {clock = "frame"})

            sequence.play(world, onFixed)
            sequence.play(world, onFrame)

            -- Three frames worth of dt in one update runs three fixed
            -- iterations but only one frame. The two clocks must not agree.
            local timestep = world:getFixedTiming()
            world:update(timestep * 3)

            luassert.equals(1, fixedCalls, "the fixed clock ticks per fixed iteration")
            luassert.equals(0, frameCalls, "the frame clock ticks once per frame")

            world:update(timestep)
            luassert.equals(1, frameCalls)
        end)

        it("measures a frame wait in frames however many steps pass", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local prog = sequence.define(uniqueName(), {
                sequence.waitSteps(2),
                sequence.call("spec.count"),
            }, {clock = "frame"})
            sequence.play(world, prog)

            -- Five fixed iterations in one update is still one frame, so the
            -- two counters walk away from each other.
            local timestep = world:getFixedTiming()
            world:update(timestep * 5)
            luassert.equals(0, calls)
            world:update(timestep * 5)
            luassert.equals(0, calls, "two frames in, the wait is not up")

            world:update(timestep)
            luassert.equals(1, calls, "three frames in, it is")
            luassert.is_true(sequence.currentStep(world) > 10,
                "the fixed clock ran far ahead while the frame clock counted three")
        end)

        it("runs a forked branch on its program's clock", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local prog = sequence.define(uniqueName(), {
                sequence.parallel(
                    {sequence.waitSteps(1), sequence.call("spec.count")},
                    {sequence.waitSteps(1), sequence.call("spec.count")}
                ),
            }, {clock = "frame"})
            sequence.play(world, prog)

            local timestep = world:getFixedTiming()
            world:update(timestep)
            world:update(timestep)
            luassert.equals(2, calls, "branches inherit the clock they were forked on")
        end)

        it("rejects an unknown clock", function()
            luassert.has_error(function()
                sequence.define(uniqueName(), {sequence.waitSteps(1)},
                    {clock = "wallclock" as sequence.ClockId})
            end)
        end)
    end)

    describe("playback", function()
        it("runs the first instruction on the next step, not inside play", function()
            local ran = false
            sequence.registerAction(world, "spec.mark", function() ran = true end)
            local prog = sequence.define(uniqueName(), {sequence.call("spec.mark")})

            sequence.play(world, prog)
            luassert.is_false(ran, "play must not execute inline")

            stepWorld(world, 1)
            luassert.is_true(ran)
        end)

        it("reports completion", function()
            sequence.registerAction(world, "spec.noop", function() end)
            local prog = sequence.define(uniqueName(), {sequence.call("spec.noop")})
            local handle = sequence.play(world, prog)

            stepWorld(world, 1)
            luassert.equals("completed", sequence.status(world, handle).state)
        end)

        it("waits the requested number of steps", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local prog = sequence.define(uniqueName(), {
                sequence.call("spec.count"),
                sequence.waitSteps(3),
                sequence.call("spec.count"),
            })
            sequence.play(world, prog)

            stepWorld(world, 1)
            luassert.equals(1, calls)
            stepWorld(world, 2)
            luassert.equals(1, calls, "still waiting")
            stepWorld(world, 1)
            luassert.equals(2, calls)
        end)

        it("treats waitSteps(0) as a yield to the next step", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local prog = sequence.define(uniqueName(), {
                sequence.call("spec.count"),
                sequence.waitSteps(0),
                sequence.call("spec.count"),
            })
            sequence.play(world, prog)

            stepWorld(world, 1)
            luassert.equals(1, calls, "the yield must not run both calls in one step")
            stepWorld(world, 1)
            luassert.equals(2, calls)
        end)

        it("converts seconds to whole steps, rounding to nearest", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            -- Default timestep is 1/60, so 0.05s is 3 steps.
            local prog = sequence.define(uniqueName(), {
                sequence.wait(0.05),
                sequence.call("spec.count"),
            })
            sequence.play(world, prog)

            stepWorld(world, 3)
            luassert.equals(0, calls)
            stepWorld(world, 1)
            luassert.equals(1, calls)
        end)

        it("waits at least one step for a small non-zero duration", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local prog = sequence.define(uniqueName(), {
                sequence.wait(0.0001),
                sequence.call("spec.count"),
            })
            sequence.play(world, prog)

            stepWorld(world, 1)
            luassert.equals(0, calls)
            stepWorld(world, 1)
            luassert.equals(1, calls)
        end)

        it("pauses and resumes", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local prog = sequence.define(uniqueName(), {
                sequence.waitSteps(1),
                sequence.call("spec.count"),
            })
            local handle = sequence.play(world, prog)

            luassert.is_true(sequence.pause(world, handle))
            luassert.equals("paused", sequence.status(world, handle).state)
            stepWorld(world, 5)
            luassert.equals(0, calls, "a paused playback must not advance")

            luassert.is_true(sequence.resume(world, handle))
            stepWorld(world, 2)
            luassert.equals(1, calls)
        end)

        it("cancels", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local prog = sequence.define(uniqueName(), {
                sequence.waitSteps(2),
                sequence.call("spec.count"),
            })
            local handle = sequence.play(world, prog)

            luassert.is_true(sequence.cancel(world, handle))
            stepWorld(world, 5)
            luassert.equals(0, calls)
            luassert.equals("cancelled", sequence.status(world, handle).state)
        end)
    end)

    describe("loops", function()
        it("repeats a counted block", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local prog = sequence.define(uniqueName(), {
                sequence.loop(3, {
                    sequence.call("spec.count"),
                    sequence.waitSteps(1),
                }),
            })
            sequence.play(world, prog)

            stepWorld(world, 6)
            luassert.equals(3, calls)
        end)

        it("gives each loop in a nest its own count", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local prog = sequence.define(uniqueName(), {
                sequence.loop(2, {
                    sequence.loop(3, {
                        sequence.call("spec.count"),
                        sequence.waitSteps(0),
                    }),
                    sequence.waitSteps(0),
                }),
            })
            sequence.play(world, prog)

            stepWorld(world, 20)
            luassert.equals(6, calls, "the inner block runs count(inner) x count(outer) times")
        end)

        it("repeats forever when count is nil", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local prog = sequence.define(uniqueName(), {
                sequence.loop(nil, {
                    sequence.call("spec.count"),
                    sequence.waitSteps(1),
                }),
            })
            local handle = sequence.play(world, prog)

            stepWorld(world, 8)
            luassert.is_true(calls >= 4, "expected repeated execution, got " .. tostring(calls))
            luassert.equals("running", sequence.status(world, handle).state)
        end)
    end)

    describe("branches", function()
        local order: {string}

        local function record(name: string)
            sequence.registerAction(world, "spec." .. name, function()
                order[#order + 1] = name
            end)
        end

        before_each(function()
            order = {}
            record("a")
            record("b")
            record("c")
            record("done")
        end)

        it("rejects a malformed branch block", function()
            luassert.has_error(function() sequence.fork({}) end)
            luassert.has_error(function() sequence.parallel() end)
            luassert.has_error(function() sequence.parallel({sequence.call("spec.a")}, {}) end)
        end)

        it("runs every block of a parallel and continues after all of them", function()
            local prog = sequence.define(uniqueName(), {
                sequence.parallel(
                    {sequence.waitSteps(3), sequence.call("spec.a")},
                    {sequence.waitSteps(1), sequence.call("spec.b")}
                ),
                sequence.call("spec.done"),
            })
            local handle = sequence.play(world, prog)

            stepWorld(world, 2)
            luassert.same({"b"}, order, "the short block runs without waiting for the long one")

            stepWorld(world, 3)
            luassert.same({"b", "a", "done"}, order)
            luassert.equals("completed", sequence.status(world, handle).state)
            luassert.equals(0, sequence.activeCount(world))
        end)

        it("costs no extra step when the blocks do not wait", function()
            local prog = sequence.define(uniqueName(), {
                sequence.parallel(
                    {sequence.call("spec.a")},
                    {sequence.call("spec.b")}
                ),
                sequence.call("spec.done"),
            })
            sequence.play(world, prog)

            stepWorld(world, 1)
            luassert.same({"a", "b", "done"}, order,
                "blocks run in fork order, and the join resumes in the same step")
        end)

        it("reports its live branches while parked at a join", function()
            local prog = sequence.define(uniqueName(), {
                sequence.parallel(
                    {sequence.waitSteps(4), sequence.call("spec.a")},
                    {sequence.waitSteps(2), sequence.call("spec.b")}
                ),
                sequence.call("spec.done"),
            })
            local handle = sequence.play(world, prog)

            stepWorld(world, 1)
            local status = sequence.status(world, handle)
            luassert.equals(2, status.branches)
            luassert.is_true(status.joining)
            luassert.is_nil(status.wakeAt, "a joining playback waits on branches, not a time")
            luassert.equals(3, sequence.activeCount(world))

            stepWorld(world, 2)
            luassert.equals(1, sequence.status(world, handle).branches)
        end)

        it("falls through a join with no branches", function()
            local prog = sequence.define(uniqueName(), {
                sequence.join(),
                sequence.call("spec.done"),
            })
            sequence.play(world, prog)

            stepWorld(world, 1)
            luassert.same({"done"}, order)
        end)

        it("keeps running the program while an unjoined branch works", function()
            local prog = sequence.define(uniqueName(), {
                sequence.fork({sequence.waitSteps(2), sequence.call("spec.a")}),
                sequence.call("spec.b"),
                sequence.waitSteps(4),
                sequence.call("spec.done"),
            })
            sequence.play(world, prog)

            stepWorld(world, 5)
            luassert.same({"b", "a", "done"}, order)
        end)

        it("cancels unjoined branches when the program ends", function()
            local prog = sequence.define(uniqueName(), {
                sequence.fork({sequence.waitSteps(3), sequence.call("spec.a")}),
                sequence.call("spec.done"),
            })
            sequence.play(world, prog)

            stepWorld(world, 6)
            luassert.same({"done"}, order, "a branch never outlives the playback that forked it")
            luassert.equals(0, sequence.activeCount(world))
        end)

        it("cancels the whole tree when the root is cancelled", function()
            local prog = sequence.define(uniqueName(), {
                sequence.parallel(
                    {sequence.fork({sequence.waitSteps(2), sequence.call("spec.a")}),
                     sequence.waitSteps(3), sequence.call("spec.b")},
                    {sequence.waitSteps(3), sequence.call("spec.c")}
                ),
                sequence.call("spec.done"),
            })
            local handle = sequence.play(world, prog)

            stepWorld(world, 1)
            luassert.equals(4, sequence.activeCount(world), "root, two branches, one grandchild")

            luassert.is_true(sequence.cancel(world, handle))
            luassert.equals(0, sequence.activeCount(world))
            stepWorld(world, 6)
            luassert.same({}, order)
        end)

        it("cancels the whole tree when the owner despawns", function()
            local owner = world:spawn()
            local prog = sequence.define(uniqueName(), {
                sequence.parallel(
                    {sequence.waitSteps(3), sequence.call("spec.a")},
                    {sequence.waitSteps(3), sequence.call("spec.b")}
                ),
                sequence.call("spec.done"),
            })
            sequence.play(world, prog, {owner = owner})

            stepWorld(world, 1)
            luassert.equals(3, sequence.activeCount(world))

            world:despawn(owner)
            world:commit()
            luassert.equals(0, sequence.activeCount(world))
            stepWorld(world, 6)
            luassert.same({}, order)
        end)

        it("proceeds through a join when a branch cancels itself", function()
            sequence.registerAction(world, "spec.selfCancel", function(w, ctx)
                sequence.cancel(w, ctx.handle)
            end)
            local prog = sequence.define(uniqueName(), {
                sequence.parallel(
                    {sequence.call("spec.selfCancel"), sequence.call("spec.a")},
                    {sequence.waitSteps(2), sequence.call("spec.b")}
                ),
                sequence.call("spec.done"),
            })
            local handle = sequence.play(world, prog)

            stepWorld(world, 3)
            luassert.same({"b", "done"}, order, "a cancelled branch leaves the join one short")
            luassert.equals("completed", sequence.status(world, handle).state)
        end)

        it("faults the playback when a branch faults, taking its siblings", function()
            sequence.registerAction(world, "spec.boom", function() error("branch boom") end)
            local prog = sequence.define(uniqueName(), {
                sequence.parallel(
                    {sequence.call("spec.boom")},
                    {sequence.waitSteps(3), sequence.call("spec.b")}
                ),
                sequence.call("spec.done"),
            })
            local handle = sequence.play(world, prog)

            stepWorld(world, 5)
            luassert.same({}, order, "a faulted branch stops the tree, siblings included")

            local status = sequence.status(world, handle)
            luassert.equals("faulted", status.state)
            luassert.equals("branchFaulted", status.fault)
            luassert.is_truthy(status.faultMessage:find("branch boom", 1, true))
            luassert.equals(0, sequence.activeCount(world))
        end)

        it("charges one instruction budget per step across joins", function()
            local prog = sequence.define(uniqueName(), {
                sequence.loop(nil, {
                    sequence.parallel({sequence.call("spec.a")}),
                }),
            })
            local handle = sequence.play(world, prog, {budget = 32})

            -- Without a per-step budget, each join would re-arm it and this
            -- loop would never hand the step back.
            stepWorld(world, 1)
            local status = sequence.status(world, handle)
            luassert.equals("faulted", status.state)
            luassert.equals("budgetExceeded", status.fault)
            luassert.equals(0, sequence.activeCount(world))
        end)

        it("pauses and resumes the whole tree", function()
            local prog = sequence.define(uniqueName(), {
                sequence.parallel(
                    {sequence.waitSteps(2), sequence.call("spec.a")},
                    {sequence.waitSteps(2), sequence.call("spec.b")}
                ),
                sequence.call("spec.done"),
            })
            local handle = sequence.play(world, prog)
            stepWorld(world, 1)

            luassert.is_true(sequence.pause(world, handle))
            stepWorld(world, 5)
            luassert.same({}, order, "pausing a playback pauses its branches")

            luassert.is_true(sequence.resume(world, handle))
            stepWorld(world, 3)
            luassert.same({"a", "b", "done"}, order)
        end)

        it("restores a tree parked at a join", function()
            local prog = sequence.define(uniqueName(), {
                sequence.parallel(
                    {sequence.waitSteps(3), sequence.call("spec.a")},
                    {sequence.waitSteps(5), sequence.call("spec.b")}
                ),
                sequence.call("spec.done"),
            })
            local handle = sequence.play(world, prog)
            stepWorld(world, 1)

            local saved = world:saveSnapshot().buffer
            stepWorld(world, 4)
            luassert.same({"a"}, order)

            world:loadSnapshot(saved)
            order = {}

            local status = sequence.status(world, handle)
            luassert.is_true(status.joining, "the root belongs at its join, not in the wake heap")
            luassert.equals(2, status.branches)
            luassert.equals(3, sequence.activeCount(world))

            stepWorld(world, 6)
            luassert.same({"a", "b", "done"}, order)
        end)

        it("renders branches in a disassembly", function()
            local prog = sequence.define(uniqueName(), {
                sequence.parallel({sequence.call("spec.a")}, {sequence.call("spec.b")}),
                sequence.call("spec.done"),
            })
            local text = sequence.disassemble(prog)

            luassert.is_truthy(text:find("FORK", 1, true))
            luassert.is_truthy(text:find("JOIN", 1, true))
        end)
    end)

    describe("signals", function()
        local function blockingProgram(): sequence.Program
            return sequence.define(uniqueName(), {
                sequence.waitSignal("gate"),
                sequence.call("spec.count"),
            })
        end

        before_each(function()
            sequence.registerAction(world, "spec.count", function() end)
        end)

        it("blocks until the signal is raised", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local handle = sequence.play(world, blockingProgram())

            stepWorld(world, 5)
            luassert.equals(0, calls)
            luassert.equals("gate", sequence.status(world, handle).waitingFor)
            luassert.is_nil(sequence.status(world, handle).wakeAt)
            luassert.equals(1, sequence.waitingOn(world, "gate"))

            sequence.signal(world, "gate")
            stepWorld(world, 1)
            luassert.equals(1, calls)
            luassert.equals(0, sequence.waitingOn(world, "gate"))
        end)

        it("delivers on the step after the signal, not the same one", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            sequence.play(world, blockingProgram())
            stepWorld(world, 1)

            -- Raising from an action would otherwise let one signal cascade
            -- through several playbacks inside a single step.
            sequence.registerAction(world, "spec.raise", function(w)
                sequence.signal(w, "gate")
            end)
            sequence.play(world, sequence.define(uniqueName(), {
                sequence.call("spec.raise"),
            }))

            stepWorld(world, 1)
            luassert.equals(0, calls, "the waiter must not run in the raising step")
            stepWorld(world, 1)
            luassert.equals(1, calls)
        end)

        it("wakes every playback blocked on the name", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            for _ = 1, 3 do sequence.play(world, blockingProgram()) end
            stepWorld(world, 1)

            luassert.equals(3, sequence.waitingOn(world, "gate"))
            luassert.equals(3, sequence.signal(world, "gate"))
            stepWorld(world, 1)
            luassert.equals(3, calls)
        end)

        it("does not remember a signal nothing was waiting on", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            luassert.equals(0, sequence.signal(world, "gate"))
            stepWorld(world, 1)

            sequence.play(world, blockingProgram())
            stepWorld(world, 3)
            luassert.equals(0, calls, "an earlier signal must not satisfy a later wait")
        end)

        it("releases the channel when a blocked playback is cancelled", function()
            local handle = sequence.play(world, blockingProgram())
            stepWorld(world, 1)
            luassert.equals(1, sequence.waitingOn(world, "gate"))

            sequence.cancel(world, handle)
            luassert.equals(0, sequence.waitingOn(world, "gate"))
        end)

        it("restores blocked playbacks and undelivered signals", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            sequence.play(world, blockingProgram())
            stepWorld(world, 1)

            local saved = world:saveSnapshot().buffer
            world:loadSnapshot(saved)

            luassert.equals(1, sequence.waitingOn(world, "gate"),
                "a blocked cursor belongs in its channel, not the wake heap")
            sequence.signal(world, "gate")
            stepWorld(world, 1)
            luassert.equals(1, calls)
        end)

        it("keeps a resumed waiter parked when the signal has not arrived", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local handle = sequence.play(world, blockingProgram())
            stepWorld(world, 1)

            luassert.is_true(sequence.pause(world, handle))
            luassert.is_true(sequence.resume(world, handle))
            stepWorld(world, 2)
            luassert.equals(0, calls, "resuming must not stand in for the signal")
            luassert.equals(1, sequence.waitingOn(world, "gate"))

            sequence.signal(world, "gate")
            stepWorld(world, 1)
            luassert.equals(1, calls)
        end)

        it("holds a signal delivered while the waiter is paused", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local handle = sequence.play(world, blockingProgram())
            stepWorld(world, 1)

            luassert.is_true(sequence.pause(world, handle))
            sequence.signal(world, "gate")
            stepWorld(world, 2)
            luassert.equals(0, calls, "a paused waiter must not run on delivery")

            luassert.is_true(sequence.resume(world, handle))
            stepWorld(world, 2)
            luassert.equals(1, calls, "the delivered signal must not be lost")
        end)

        it("rejects an empty signal name", function()
            luassert.has_error(function() sequence.waitSignal("") end)
            luassert.has_error(function() sequence.signal(world, "") end)
        end)
    end)

    describe("query waits", function()
        local Add <const> = tecs.newComponent({
            name = "SpecSequenceAdd",
            container = {} as tecs.Component,
            fields = {"hp"},
            init = function(instance: tecs.Component, hp: number)
                (instance as {string: any}).hp = hp
            end,
        })

        local calls: integer
        local spawned: {integer}

        before_each(function()
            calls = 0
            spawned = {}
            sequence.registerQuery(world, "spec.adds", {include = {Add}})
            sequence.registerAction(world, "spec.done", function() calls = calls + 1 end)
            sequence.registerAction(world, "spec.spawnAdd", function(w)
                spawned[#spawned + 1] = w:spawn(Add(1) as tecs.Component)
            end)
            sequence.registerAction(world, "spec.clearAdds", function(w)
                for i = 1, #spawned do w:despawn(spawned[i]) end
                spawned = {}
            end)
        end)

        it("rejects a malformed wait", function()
            luassert.has_error(function() sequence.waitQuery("", "any") end)
            luassert.has_error(function()
                sequence.waitQuery("spec.adds", "sometimes" as sequence.QueryCondition)
            end)
        end)

        it("blocks until the query matches", function()
            local prog = sequence.define(uniqueName(), {
                sequence.waitQuery("spec.adds", "any"),
                sequence.call("spec.done"),
            })
            local handle = sequence.play(world, prog)

            stepWorld(world, 4)
            luassert.equals(0, calls)
            local status = sequence.status(world, handle)
            luassert.equals("spec.adds", status.waitingQuery)
            luassert.equals("any", status.waitingCondition)
            luassert.is_nil(status.wakeAt)

            world:spawn(Add(1) as tecs.Component)
            world:commit()
            stepWorld(world, 1)
            luassert.equals(1, calls)
        end)

        it("resumes a wait whose condition already holds", function()
            local prog = sequence.define(uniqueName(), {
                sequence.waitQuery("spec.adds", "empty"),
                sequence.call("spec.done"),
            })
            sequence.play(world, prog)

            -- A condition, not an edge: nothing has to change for this to
            -- proceed, so it costs one step rather than waiting forever.
            stepWorld(world, 1)
            luassert.equals(0, calls)
            stepWorld(world, 1)
            luassert.equals(1, calls)
        end)

        it("sees an entity a call spawned in the same step", function()
            local prog = sequence.define(uniqueName(), {
                sequence.call("spec.spawnAdd"),
                sequence.waitQuery("spec.adds", "any"),
                sequence.call("spec.done"),
            })
            sequence.play(world, prog)

            stepWorld(world, 2)
            luassert.equals(1, calls)
        end)

        it("does not resolve against an iteration that has not run", function()
            -- Sequences advance first in a fixed iteration, so at the
            -- instruction itself the world still reflects the previous one.
            -- Testing there would find this query empty and walk straight
            -- past the wait, moments before the wave system fills it.
            local pending = true
            world:addSystem({
                name = "spec.wave",
                phase = tecs.phases.FixedUpdate,
                run = function()
                    if not pending then return end
                    pending = false
                    spawned[1] = world:spawn(Add(1) as tecs.Component)
                end,
            })

            local prog = sequence.define(uniqueName(), {
                sequence.waitQuery("spec.adds", "empty"),
                sequence.call("spec.done"),
            })
            sequence.play(world, prog)

            stepWorld(world, 5)
            luassert.equals(0, calls)

            world:despawn(spawned[1])
            world:commit()
            stepWorld(world, 2)
            luassert.equals(1, calls)
        end)

        it("waits for a wave to be cleared", function()
            local prog = sequence.define(uniqueName(), {
                sequence.loop(3, {sequence.call("spec.spawnAdd")}),
                sequence.waitQuery("spec.adds", "empty"),
                sequence.call("spec.done"),
            })
            sequence.play(world, prog)

            stepWorld(world, 3)
            luassert.equals(0, calls)
            luassert.equals(3, #spawned)

            world:despawn(spawned[1])
            world:commit()
            stepWorld(world, 2)
            luassert.equals(0, calls, "one of three is not the wave")

            world:despawn(spawned[2])
            world:despawn(spawned[3])
            world:commit()
            stepWorld(world, 2)
            luassert.equals(1, calls)
        end)

        it("faults on an unregistered query", function()
            local prog = sequence.define(uniqueName(), {
                sequence.waitQuery("spec.neverRegistered", "any"),
            })
            local handle = sequence.play(world, prog)

            stepWorld(world, 1)
            local status = sequence.status(world, handle)
            luassert.equals("faulted", status.state)
            luassert.equals("unregisteredQuery", status.fault)
        end)

        it("releases the wait when a parked playback is cancelled", function()
            local prog = sequence.define(uniqueName(), {
                sequence.waitQuery("spec.adds", "any"),
                sequence.call("spec.done"),
            })
            local handle = sequence.play(world, prog)
            stepWorld(world, 2)

            luassert.is_true(sequence.cancel(world, handle))
            world:spawn(Add(1) as tecs.Component)
            world:commit()
            stepWorld(world, 2)
            luassert.equals(0, calls)
            luassert.equals(0, sequence.activeCount(world))
        end)

        it("re-tests a restored wait against the restored world", function()
            local prog = sequence.define(uniqueName(), {
                sequence.waitQuery("spec.adds", "any"),
                sequence.call("spec.done"),
            })
            local handle = sequence.play(world, prog)
            stepWorld(world, 2)
            luassert.equals("spec.adds", sequence.status(world, handle).waitingQuery)

            local saved = world:saveSnapshot().buffer
            world:spawn(Add(1) as tecs.Component)
            world:commit()
            stepWorld(world, 2)
            luassert.equals(1, calls)

            -- The restored world has no matching entity, so the restored
            -- cursor goes back to waiting rather than resuming on a
            -- condition that only held in the world it left.
            world:loadSnapshot(saved)
            calls = 0
            stepWorld(world, 3)
            luassert.equals(0, calls)
            luassert.equals("spec.adds", sequence.status(world, handle).waitingQuery)

            world:spawn(Add(1) as tecs.Component)
            world:commit()
            stepWorld(world, 1)
            luassert.equals(1, calls)
        end)
    end)

    describe("event signals", function()
        it("raises a signal every time an event is emitted", function()
            local calls = 0
            sequence.registerAction(world, "spec.done", function() calls = calls + 1 end)
            sequence.signalOnEvent(world, "died", tecs.builtins.OnDespawn)

            local prog = sequence.define(uniqueName(), {
                sequence.waitSignal("died"),
                sequence.call("spec.done"),
            })
            sequence.play(world, prog)
            local victim = world:spawn()
            stepWorld(world, 2)
            luassert.equals(0, calls)

            world:despawn(victim)
            world:commit()
            stepWorld(world, 1)
            luassert.equals(1, calls)
        end)
    end)

    describe("bindings and ownership", function()
        it("resolves a binding through the context", function()
            local seen: integer = nil
            local target = world:spawn()
            sequence.registerAction(world, "spec.look", function(_w, ctx)
                seen = ctx:entity("boss")
            end)
            local prog = sequence.define(uniqueName(), {sequence.call("spec.look")})

            sequence.play(world, prog, {bindings = {boss = target}})
            stepWorld(world, 1)
            luassert.equals(target, seen)
        end)

        it("resolves a bind reference in call arguments", function()
            local seen: any = nil
            local target = world:spawn()
            sequence.registerAction(world, "spec.look", function(_w, ctx)
                seen = ctx.args[1]
            end)
            local prog = sequence.define(uniqueName(), {
                sequence.call("spec.look", sequence.bind("boss")),
            })

            sequence.play(world, prog, {bindings = {boss = target}})
            stepWorld(world, 1)
            luassert.equals(target, seen)
        end)

        it("reports a dead binding as nil", function()
            local seen: integer = 0
            local target = world:spawn()
            sequence.registerAction(world, "spec.look", function(_w, ctx)
                seen = ctx:entity("boss")
            end)
            local prog = sequence.define(uniqueName(), {
                sequence.waitSteps(1),
                sequence.call("spec.look"),
            })

            sequence.play(world, prog, {bindings = {boss = target}})
            world:despawn(target)
            stepWorld(world, 3)
            luassert.is_nil(seen)
        end)

        it("cancels playbacks when their owner despawns", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local owner = world:spawn()
            local prog = sequence.define(uniqueName(), {
                sequence.waitSteps(2),
                sequence.call("spec.count"),
            })
            local handle = sequence.play(world, prog, {owner = owner})

            world:despawn(owner)
            world:commit()
            stepWorld(world, 5)

            luassert.equals(0, calls)
            luassert.equals("cancelled", sequence.status(world, handle).state)
        end)
    end)

    describe("tweens", function()
        local Transform <const> = tecs.builtins.Transform
        local calls: integer
        local actor: integer

        before_each(function()
            world:addPlugin(tween.plugin)
            calls = 0
            actor = world:spawn(Transform(0, 0))
            world:commit()
            sequence.registerAction(world, "spec.done", function() calls = calls + 1 end)
            tween.registerPreset(world, "spec.slide", tween.timeline({
                tween.to(0.5, tween.linear, tween.translateX, 100),
            }))
            local channelled: tween.TimelineSpec = {
                tween.to(0.5, tween.linear, tween.translateY, 100),
            }
            channelled.channel = "move"
            tween.registerPreset(world, "spec.channelled", tween.timeline(channelled))
        end)

        local function playAndWait(preset: string): sequence.Handle
            local prog = sequence.define(uniqueName(), {
                sequence.playTween(preset, sequence.bind("actor")),
                sequence.waitTween(),
                sequence.call("spec.done"),
            })
            return sequence.play(world, prog, {bindings = {actor = actor}})
        end

        it("rejects a malformed step", function()
            luassert.has_error(function()
                sequence.playTween("", sequence.bind("actor"))
            end)
            luassert.has_error(function()
                sequence.playTween("spec.slide", "actor" as sequence.EntityRef)
            end)
        end)

        it("waits for the playback it started", function()
            local handle = playAndWait("spec.slide")

            stepWorld(world, 2)
            luassert.equals(0, calls, "the tween is still running")
            luassert.is_number(sequence.status(world, handle).waitingTween)

            stepWorld(world, 60)
            luassert.equals(1, calls)
            luassert.equals("completed", sequence.status(world, handle).tweenOutcome)
            luassert.is_near(100, world:get(actor, Transform).x, 1e-1)
        end)

        it("resumes when the playback is cancelled", function()
            local handle = playAndWait("spec.slide")
            stepWorld(world, 2)

            tween.cancel(world, actor)
            stepWorld(world, 2)
            luassert.equals(1, calls, "a cancelled tween must not leave the sequence waiting")
            luassert.equals("cancelled", sequence.status(world, handle).tweenOutcome)
        end)

        it("resumes when another playback takes its channel", function()
            local handle = playAndWait("spec.channelled")
            stepWorld(world, 2)

            tween.play(world, actor, "spec.channelled")
            stepWorld(world, 2)
            luassert.equals(1, calls)
            luassert.equals("replaced", sequence.status(world, handle).tweenOutcome)
        end)

        it("resumes when the bound entity dies", function()
            local handle = playAndWait("spec.slide")
            stepWorld(world, 2)

            world:despawn(actor)
            world:commit()
            stepWorld(world, 2)
            luassert.equals(1, calls)
            luassert.equals("targetLost", sequence.status(world, handle).tweenOutcome)
        end)

        it("does not wait at all when the binding is already gone", function()
            world:despawn(actor)
            world:commit()
            local handle = playAndWait("spec.slide")

            stepWorld(world, 1)
            luassert.equals(1, calls, "a dead actor is a game state, not a wait")
            luassert.equals("targetLost", sequence.status(world, handle).tweenOutcome)
        end)

        it("faults on an unregistered preset", function()
            local handle = playAndWait("spec.neverRegistered")

            stepWorld(world, 1)
            local status = sequence.status(world, handle)
            luassert.equals("faulted", status.state)
            luassert.equals("unregisteredTween", status.fault)
        end)

        it("resumes the same wait after a snapshot", function()
            local handle = playAndWait("spec.slide")
            stepWorld(world, 2)
            local pc = sequence.status(world, handle).pc

            local saved = world:saveSnapshot().buffer
            world:loadSnapshot(saved)

            local status = sequence.status(world, handle)
            luassert.equals(pc, status.pc, "the restored cursor sits where it was")
            luassert.is_number(status.waitingTween)

            stepWorld(world, 60)
            luassert.equals(1, calls)
            luassert.equals("completed", sequence.status(world, handle).tweenOutcome)
        end)

        it("renders tween steps in a disassembly", function()
            local prog = sequence.define(uniqueName(), {
                sequence.playTween("spec.slide", sequence.bind("actor")),
                sequence.waitTween(),
            })
            local text = sequence.disassemble(prog)
            luassert.is_truthy(text:find("PLAYTWEEN", 1, true))
            luassert.is_truthy(text:find("WAITTWEEN", 1, true))
            luassert.is_truthy(text:find("bind(actor)", 1, true))
        end)
    end)

    describe("events", function()
        it("emits with name, args, and handle", function()
            local received: sequence.Event = nil
            world:observe(0, sequence.Event, function(e: sequence.Event)
                received = e
            end)
            local prog = sequence.define(uniqueName(), {
                sequence.emit("boss.ready", 7),
            })
            local handle = sequence.play(world, prog)

            stepWorld(world, 1)
            luassert.is_not_nil(received)
            luassert.equals("boss.ready", received.name)
            luassert.equals(7, received.args[1])
            luassert.equals(handle, received.handle)
        end)
    end)

    describe("faults", function()
        it("faults on an unregistered action", function()
            local prog = sequence.define(uniqueName(), {sequence.call("spec.missing")})
            local handle = sequence.play(world, prog)

            stepWorld(world, 1)
            local status = sequence.status(world, handle)
            luassert.equals("faulted", status.state)
            luassert.equals("unregisteredAction", status.fault)
        end)

        it("faults when an action raises, keeping the pc", function()
            sequence.registerAction(world, "spec.boom", function()
                error("boom")
            end)
            local prog = sequence.define(uniqueName(), {
                sequence.waitSteps(1),
                sequence.call("spec.boom"),
            })
            local handle = sequence.play(world, prog)

            stepWorld(world, 3)
            local status = sequence.status(world, handle)
            luassert.equals("faulted", status.state)
            luassert.equals("actionError", status.fault)
            luassert.equals(1, status.pc, "pc points at the failing instruction")
            luassert.is_truthy(status.faultMessage:find("boom"))
        end)

        it("faults a loop that never waits, naming the program", function()
            sequence.registerAction(world, "spec.noop", function() end)
            local name = uniqueName()
            local prog = sequence.define(name, {
                sequence.loop(nil, {sequence.call("spec.noop")}),
            })
            local handle = sequence.play(world, prog, {budget = 32})

            stepWorld(world, 1)
            local status = sequence.status(world, handle)
            luassert.equals("faulted", status.state)
            luassert.equals("budgetExceeded", status.fault)
            luassert.equals(name, status.program)
        end)
    end)

    describe("arena", function()
        it("recycles slots as playbacks finish", function()
            sequence.registerAction(world, "spec.noop", function() end)
            local prog = sequence.define(uniqueName(), {sequence.call("spec.noop")})

            for _ = 1, 50 do
                sequence.play(world, prog)
                stepWorld(world, 1)
            end

            -- A bounded arena hands the next playback a low slot rather than
            -- growing once per sequence ever played.
            local handle = sequence.play(world, prog)
            luassert.is_true(handle % 1048576 <= 2,
                "expected a recycled slot, got slot " .. tostring(handle % 1048576))
        end)

        it("reports a finished playback until its slot is reused", function()
            sequence.registerAction(world, "spec.noop", function() end)
            local prog = sequence.define(uniqueName(), {sequence.call("spec.noop")})
            local handle = sequence.play(world, prog)
            stepWorld(world, 1)

            luassert.equals("completed", sequence.status(world, handle).state)

            sequence.play(world, prog)
            luassert.is_nil(sequence.status(world, handle),
                "a reused slot must not report the previous playback's state")
        end)
    end)

    describe("handles", function()
        it("returns nil status for a handle this world never issued", function()
            luassert.is_nil(sequence.status(world, 123456789))
        end)

        it("does not confuse a recycled slot with its previous handle", function()
            sequence.registerAction(world, "spec.noop", function() end)
            local prog = sequence.define(uniqueName(), {sequence.call("spec.noop")})

            local first = sequence.play(world, prog)
            sequence.cancel(world, first)

            local second = sequence.play(world, prog)
            luassert.not_equals(first, second, "a reused slot must bump its generation")
            luassert.is_nil(sequence.status(world, first))
            luassert.is_not_nil(sequence.status(world, second))
        end)
    end)

    describe("snapshots", function()
        -- The program registry is process-global and never pruned, so an
        -- in-process load finds the original version and reuses it rather
        -- than rebuilding from the serialized bytecode. These cases prove
        -- cursor state and version pinning; that a save file is genuinely
        -- self-contained is only observable from a fresh process.
        it("resumes mid-sequence at the same instruction", function()
            local calls = 0
            sequence.registerAction(world, "spec.count", function() calls = calls + 1 end)
            local prog = sequence.define(uniqueName(), {
                sequence.call("spec.count"),
                sequence.waitSteps(4),
                sequence.call("spec.count"),
            })
            local handle = sequence.play(world, prog)

            stepWorld(world, 1)
            luassert.equals(1, calls)

            local saved = world:saveSnapshot().buffer
            stepWorld(world, 1)
            world:loadSnapshot(saved)

            -- The remaining wait resumes rather than restarting or firing early.
            luassert.equals("running", sequence.status(world, handle).state)
            stepWorld(world, 3)
            luassert.equals(1, calls, "still waiting after restore")
            stepWorld(world, 1)
            luassert.equals(2, calls)
        end)

        it("keeps running the program version it started with", function()
            local seen: {string} = {}
            sequence.registerAction(world, "spec.a", function() seen[#seen + 1] = "old" end)
            sequence.registerAction(world, "spec.b", function() seen[#seen + 1] = "new" end)

            local name = uniqueName()
            local v1 = sequence.define(name, {
                sequence.waitSteps(2),
                sequence.call("spec.a"),
            })
            sequence.play(world, v1)
            stepWorld(world, 1)

            local saved = world:saveSnapshot().buffer

            -- Redefining after the save is what a hot reload looks like.
            sequence.define(name, {
                sequence.waitSteps(2),
                sequence.call("spec.b"),
            })
            world:loadSnapshot(saved)
            stepWorld(world, 4)

            luassert.same({"old"}, seen)
            luassert.equals(2, sequence.program(name).version)
        end)

        it("restores bindings and ownership", function()
            local seen: integer = nil
            local target = world:spawn()
            local owner = world:spawn()
            sequence.registerAction(world, "spec.look", function(_w, ctx)
                seen = ctx:entity("boss")
            end)
            local prog = sequence.define(uniqueName(), {
                sequence.waitSteps(2),
                sequence.call("spec.look"),
            })
            sequence.play(world, prog, {owner = owner, bindings = {boss = target}})

            local saved = world:saveSnapshot().buffer
            world:loadSnapshot(saved)
            stepWorld(world, 4)

            luassert.equals(target, seen)
        end)

        it("rejects a payload written by an unknown layout version", function()
            local prog = sequence.define(uniqueName(), {sequence.waitSteps(4)})
            local handle = sequence.play(world, prog)

            local saved = world:saveSnapshot({format = "table"})
            local entries = saved.snapshot.data
            local patched = false
            for i = 1, #entries do
                if entries[i].key == "tecs2d.sequence" then
                    local payload = entries[i].value as {string: any}
                    luassert.is_number(payload.version, "payload must carry its layout version")
                    payload.version = 99
                    patched = true
                end
            end
            luassert.is_true(patched, "the sequencer must write a snapshot payload")

            luassert.has_error(function() world:loadSnapshot(saved) end)
            -- A rejected load must not have half-cleared the arena.
            luassert.equals("running", sequence.status(world, handle).state)
            luassert.equals(1, sequence.activeCount(world))
        end)

        it("drops nothing when no sequences are active", function()
            local saved = world:saveSnapshot().buffer
            world:loadSnapshot(saved)
            luassert.equals(0, sequence.activeCount(world))
        end)
    end)

    describe("scheduling order", function()
        it("runs playbacks with the same wake step in play order", function()
            local order: {string} = {}
            sequence.registerAction(world, "spec.a", function() order[#order + 1] = "a" end)
            sequence.registerAction(world, "spec.b", function() order[#order + 1] = "b" end)
            sequence.registerAction(world, "spec.c", function() order[#order + 1] = "c" end)

            sequence.play(world, sequence.define(uniqueName(), {sequence.call("spec.a")}))
            sequence.play(world, sequence.define(uniqueName(), {sequence.call("spec.b")}))
            sequence.play(world, sequence.define(uniqueName(), {sequence.call("spec.c")}))

            stepWorld(world, 1)
            luassert.same({"a", "b", "c"}, order)
        end)
    end)

    describe("programs as data", function()
        local order: {string}

        before_each(function()
            order = {}
            sequence.registerAction(world, "spec.mark", function(_w, ctx)
                order[#order + 1] = tostring(ctx.args[1])
            end)
        end)

        it("builds the same program a node list would", function()
            local prog = sequence.defineData(uniqueName(), {
                {op = "call", action = "spec.mark", args = {"a"}},
                {op = "waitSteps", steps = 2},
                {op = "call", action = "spec.mark", args = {"b"}},
            })
            luassert.is_not_nil(prog)
            sequence.play(world, prog)

            stepWorld(world, 1)
            luassert.same({"a"}, order)
            stepWorld(world, 2)
            luassert.same({"a", "b"}, order)
        end)

        it("carries every control-flow step", function()
            local prog = sequence.defineData(uniqueName(), {
                {op = "parallel", blocks = {
                    {{op = "waitSteps", steps = 1}, {op = "call", action = "spec.mark", args = {"x"}}},
                    {{op = "call", action = "spec.mark", args = {"y"}}},
                }},
                {op = "loop", count = 2, nodes = {
                    {op = "call", action = "spec.mark", args = {"loop"}},
                    {op = "waitSteps", steps = 1},
                }},
                {op = "emit", event = "spec.done"},
            })
            luassert.is_not_nil(prog)
            sequence.play(world, prog)

            stepWorld(world, 6)
            luassert.same({"y", "x", "loop", "loop"}, order)
        end)

        it("rebuilds a binding reference", function()
            local seen: any = nil
            local target = world:spawn()
            sequence.registerAction(world, "spec.look", function(_w, ctx)
                seen = ctx.args[1]
            end)
            local prog = sequence.defineData(uniqueName(), {
                {op = "call", action = "spec.look", args = {{bind = "boss"}}},
            })
            sequence.play(world, prog, {bindings = {boss = target}})

            stepWorld(world, 1)
            luassert.equals(target, seen)
        end)

        it("takes the clock like define does", function()
            local prog = sequence.defineData(uniqueName(),
                {{op = "waitSteps", steps = 1}, {op = "call", action = "spec.mark", args = {"f"}}},
                {clock = "frame"})
            sequence.play(world, prog)

            local timestep = world:getFixedTiming()
            world:update(timestep * 4)
            luassert.same({}, order, "one update is one frame")
            world:update(timestep)
            luassert.same({"f"}, order)
        end)

        it("reports the path to a bad entry rather than raising", function()
            local prog, err = sequence.defineData(uniqueName(), {
                {op = "call", action = "spec.mark"},
                {op = "nonsense"},
            })
            luassert.is_nil(prog)
            luassert.is_truthy(err:find("program[2]", 1, true), err)
            luassert.is_truthy(err:find("unknown op", 1, true), err)

            local nested, nestedErr = sequence.defineData(uniqueName(), {
                {op = "parallel", blocks = {
                    {{op = "call", action = "spec.mark"}},
                    {{op = "wait"}},
                }},
            })
            luassert.is_nil(nested)
            luassert.is_truthy(nestedErr:find("blocks[2]", 1, true), nestedErr)
        end)

        it("rejects an empty program and a missing field", function()
            luassert.is_nil(sequence.defineData(uniqueName(), {}))
            luassert.is_nil(sequence.defineData(uniqueName(), {{op = "call"}}))
            luassert.is_nil(sequence.defineData(uniqueName(),
                {{op = "waitQuery", query = "q", condition = "sometimes"}}))
        end)

        it("names the steps it accepts", function()
            local ops = sequence.dataOps()
            luassert.is_true(#ops > 5)
            local seen: {string: boolean} = {}
            for i = 1, #ops do seen[ops[i]] = true end
            luassert.is_true(seen.call and seen.wait and seen.parallel and seen.playTween)
        end)
    end)

    describe("upcoming", function()
        before_each(function()
            sequence.registerAction(world, "spec.noop", function() end)
        end)

        it("reports the straight-line run ahead with its timings", function()
            local prog = sequence.define(uniqueName(), {
                sequence.waitSteps(2),
                sequence.call("spec.noop", "first"),
                sequence.waitSteps(3),
                sequence.emit("spec.done"),
            })
            local handle = sequence.play(world, prog)

            local ahead = sequence.upcoming(world, handle)
            luassert.equals(2, #ahead)
            -- One tick to reach the first instruction, then the wait it makes.
            luassert.equals(3, ahead[1].ticks)
            luassert.equals("call", ahead[1].kind)
            luassert.equals("spec.noop", ahead[1].name)
            luassert.equals("first", ahead[1].args[1])
            luassert.equals(6, ahead[2].ticks, "waits accumulate")
            luassert.equals("emit", ahead[2].kind)
        end)

        it("counts down as the playback advances", function()
            local prog = sequence.define(uniqueName(), {
                sequence.waitSteps(4),
                sequence.call("spec.noop"),
            })
            local handle = sequence.play(world, prog)

            stepWorld(world, 2)
            luassert.equals(3, sequence.upcoming(world, handle)[1].ticks)
            stepWorld(world, 2)
            luassert.equals(1, sequence.upcoming(world, handle)[1].ticks)
        end)

        it("reports only what is due within the window", function()
            local prog = sequence.define(uniqueName(), {
                sequence.call("spec.noop", "now"),
                sequence.waitSteps(9),
                sequence.call("spec.noop", "later"),
            })
            local handle = sequence.play(world, prog)

            luassert.equals(1, #sequence.upcoming(world, handle, 3))
            luassert.equals(2, #sequence.upcoming(world, handle, 20))
        end)

        it("stops where the program branches", function()
            local prog = sequence.define(uniqueName(), {
                sequence.call("spec.noop", "certain"),
                sequence.loop(2, {sequence.waitSteps(1), sequence.call("spec.noop", "maybe")}),
            })
            local handle = sequence.play(world, prog)

            local ahead = sequence.upcoming(world, handle)
            luassert.equals(2, #ahead, "the loop body is reached, its repeat is not predicted")
            luassert.equals("certain", ahead[1].args[1])
            luassert.equals("maybe", ahead[2].args[1])
        end)

        it("predicts nothing for a playback parked on something other than time", function()
            local prog = sequence.define(uniqueName(), {
                sequence.waitSignal("spec.gate"),
                sequence.call("spec.noop"),
            })
            local handle = sequence.play(world, prog)
            stepWorld(world, 1)

            luassert.same({}, sequence.upcoming(world, handle),
                "a signal has no predictable arrival")
        end)

        it("reports nothing for a finished or unknown playback", function()
            local prog = sequence.define(uniqueName(), {sequence.call("spec.noop")})
            local handle = sequence.play(world, prog)
            stepWorld(world, 1)

            luassert.same({}, sequence.upcoming(world, handle))
            luassert.same({}, sequence.upcoming(world, 123456789))
        end)
    end)

    describe("disassembly", function()
        it("renders every instruction with its index", function()
            local name = uniqueName()
            local prog = sequence.define(name, {
                sequence.call("spec.lock", 1, "two"),
                sequence.wait(0.5),
                sequence.emit("done"),
            })
            local text = sequence.disassemble(prog)

            luassert.is_truthy(text:find(name, 1, true))
            luassert.is_truthy(text:find("CALL", 1, true))
            luassert.is_truthy(text:find("WAIT", 1, true))
            luassert.is_truthy(text:find("EMIT", 1, true))
            luassert.is_truthy(text:find("END", 1, true))
        end)

        it("rejects a non-program", function()
            luassert.has_error(function()
                sequence.disassemble({} as sequence.Program)
            end)
        end)
    end)
end)
