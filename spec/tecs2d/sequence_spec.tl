require("busted")

local luassert <const> = require("luassert")
local tecs <const> = require("tecs")
local sequence <const> = require("tecs2d.sequence")

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

    describe("handles", function()
        it("returns nil status for a handle this world never issued", function()
            luassert.is_nil(sequence.status(world, 123456789))
        end)

        it("does not confuse a recycled slot with its previous handle", function()
            sequence.registerAction(world, "spec.noop", function() end)
            local prog = sequence.define(uniqueName(), {sequence.call("spec.noop")})

            local first = sequence.play(world, prog)
            sequence.cancel(world, first)
            -- Querying a finished handle releases its slot for reuse.
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
