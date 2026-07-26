--- Love2D integration suite: a sequence save file is self-contained.
---
--- The in-process snapshot specs cannot prove this. The program registry is
--- process-global and never pruned, so a load in the process that compiled
--- the program finds the original version and reuses it, and the serialized
--- bytecode is never read. This spec saves in one Love process, kills it,
--- and loads in a second one that has never seen the program: the only way
--- the encounter can carry on is out of the save file itself.
---
--- Run via `make test-love FILE_MATCH='sequence_snapshot'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"
local SAVE_PATH <const> = "sequence-lovespec.save"

-- Registering the actions is all a fresh process should need: actions are
-- code, rebound by name, and the program itself has to arrive in the save.
local REGISTER_ACTIONS <const> = [[
    local sequence = require("tecs2d.sequence")
    _G.tecsSeq = {marks = {}}
    sequence.registerAction(world, "lovespec.mark", function(_w, ctx)
        local marks = _G.tecsSeq.marks
        marks[#marks + 1] = ctx.args[1]
    end)
    return true
]]

describe("sequence: a save resumes in a process that never compiled it", function()
    local first: fixture.App
    local second: fixture.App

    local function marks(app: fixture.App): string
        return fixture.runLua(app, [[
            return table.concat(_G.tecsSeq.marks, ",")
        ]])[1]
    end

    setup(function()
        first = fixture.start(APP_DIR)
        fixture.runLua(first, "love.filesystem.remove('" .. SAVE_PATH .. "') return true")
        fixture.runLua(first, REGISTER_ACTIONS)

        -- A program with work on both sides of a long wait, so the save
        -- lands mid-sequence with instructions still ahead of it.
        fixture.runLua(first, [[
            local tecs = require("tecs")
            local sequence = require("tecs2d.sequence")
            _G.tecsSeqActor = world:spawn(tecs.builtins.Transform(0, 0, 0, 1))
            world:commit()
            sequence.timeline("lovespec.slide", {
                sequence.tweenTo(0.4, "linear", "transform.x", 100),
            })
            local program = sequence.define("lovespec.encounter", {
                sequence.call("lovespec.mark", "before"),
                sequence.waitSignal("lovespec.go"),
                sequence.call("lovespec.mark", "after"),
                sequence.playTween("lovespec.slide", sequence.bind("actor")),
                sequence.waitTween(),
                sequence.call("lovespec.mark", "moved"),
                sequence.loop(2, {
                    sequence.call("lovespec.mark", "again"),
                    sequence.waitSteps(1),
                }),
            })
            _G.tecsSeqHandle = sequence.play(world, program,
                {bindings = {actor = _G.tecsSeqActor}})
            return true
        ]])
    end)

    teardown(function()
        if second then
            fixture.runLua(second, "love.filesystem.remove('" .. SAVE_PATH .. "') return true")
            fixture.stop(second)
        end
        if first then fixture.stop(first) end
    end)

    it("saves a playback parked mid-program", function()
        local parked = fixture.eventually(fixture.callTimeout, function(): boolean
            if marks(first) == "before" then return true end
            return nil
        end)
        luassert.is_true(parked == true, "the sequence never reached its wait")

        local blocked = fixture.runLua(first, [[
            local sequence = require("tecs2d.sequence")
            local status = sequence.status(world, _G.tecsSeqHandle)
            return status.waitingFor, status.pc, status.program
        ]])
        luassert.equals("lovespec.go", blocked[1])
        luassert.equals("lovespec.encounter", blocked[3])

        local wrote = fixture.runLua(first, [[
            local snapshot = world:saveSnapshot()
            return love.filesystem.write("]] .. SAVE_PATH .. [[", tostring(snapshot.buffer))
        ]])
        luassert.equals("true", wrote[1], "the snapshot was not written")
    end)

    it("carries the program into a process that never defined it", function()
        fixture.stop(first)
        first = nil

        second = fixture.start(APP_DIR)
        fixture.runLua(second, REGISTER_ACTIONS)

        local before = fixture.runLua(second, [[
            local sequence = require("tecs2d.sequence")
            return sequence.program("lovespec.encounter") == nil
        ]])
        luassert.equals("true", before[1],
            "the fresh process already knows the program; the test proves nothing")

        local loaded = fixture.runLua(second, [[
            local payload = love.filesystem.read("]] .. SAVE_PATH .. [[")
            if not payload then return "missing save" end
            world:loadSnapshot(payload)
            local sequence = require("tecs2d.sequence")
            local program = sequence.program("lovespec.encounter")
            return program ~= nil and program.version or "no program"
        ]])
        luassert.equals("1", loaded[1],
            "the restored program did not come back from the save file")

        -- Restored from bytecode alone, it still sits at its wait, still
        -- knows what it is waiting for, and still has its instructions.
        local resumedMarks = marks(second)
        luassert.equals("", resumedMarks, "the restored playback re-ran its first call")

        local waiting = fixture.runLua(second, [[
            local sequence = require("tecs2d.sequence")
            return sequence.waitingOn(world, "lovespec.go")
        ]])
        luassert.equals("1", waiting[1], "the restored playback is not parked on its signal")

        -- A program can name another: playTween carries a timeline's name.
        -- The named one is not running when the save is written, so nothing
        -- would have collected it from the live cursors.
        local timeline = fixture.runLua(second, [[
            local sequence = require("tecs2d.sequence")
            return sequence.program("lovespec.slide") ~= nil
        ]])
        luassert.equals("true", timeline[1],
            "the timeline the program names did not travel with it")
    end)

    it("runs the restored instructions to the end", function()
        fixture.runLua(second, [[
            local sequence = require("tecs2d.sequence")
            sequence.signal(world, "lovespec.go")
            return true
        ]])

        local finished = fixture.eventually(fixture.callTimeout, function(): boolean
            if marks(second) == "after,moved,again,again" then return true end
            return nil
        end)
        -- "moved" is only reached by playing the timeline the save carried
        -- and waiting for that playback to finish.
        luassert.is_true(finished == true,
            "restored program did not run to completion, saw: " .. marks(second))

        local live = fixture.runLua(second, [[
            local sequence = require("tecs2d.sequence")
            return sequence.activeCount(world)
        ]])
        luassert.equals("0", live[1], "the restored playback never retired")
    end)

end)
