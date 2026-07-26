--- Love2D integration suite: scripting a scenario through one MCP tool.
---
--- cmd_program_play takes a whole scripted scenario as data -- input, waits,
--- spawns, signals -- schedules it, and hands back a handle. This drives the
--- tool the way an agent would, including the thing run_lua cannot do:
--- saving mid-program and resuming at the same step after a load.
---
--- Run via `make test-love FILE_MATCH='program'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"
local SAVE_PATH <const> = "program-lovespec.save"

describe("program: one tool schedules a whole scenario", function()
    local app: fixture.App

    local function marks(): string
        return fixture.runLua(app, "return table.concat(_G.tecsMarks, ',')")[1]
    end

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local sequence = require("tecs2d.sequence")
            _G.tecsMarks = {}
            sequence.registerAction(world, "spec.mark", function(_w, ctx)
                _G.tecsMarks[#_G.tecsMarks + 1] = ctx.args[1]
            end)
            love.filesystem.remove("]] .. SAVE_PATH .. [[")
            return true
        ]])
    end)

    teardown(function()
        if app then
            fixture.runLua(app, "love.filesystem.remove('" .. SAVE_PATH .. "') return true")
            fixture.stop(app)
        end
    end)

    it("plays a program given as data and reports what is left", function()
        local result = app.client:call("cmd_program_play", {
            steps = {
                {op = "call", action = "spec.mark", args = {"first"}},
                {op = "waitSteps", steps = 30},
                {op = "call", action = "spec.mark", args = {"second"}},
            },
        })
        luassert.is_number(result.handle)
        luassert.equals(3, result.steps)

        local ran = fixture.eventually(fixture.callTimeout, function(): boolean
            if marks() == "first" then return true end
            return nil
        end)
        luassert.is_true(ran == true, "the first step never ran, saw: " .. marks())

        local status = app.client:call("cmd_program_status", {handle = result.handle})
        luassert.equals("running", status.state)
        local ahead = status.upcoming as {{string: any}}
        luassert.is_true(#ahead >= 1, "status should predict the step still to come")
        luassert.equals("spec.mark", ahead[1].name)
    end)

    it("refuses a malformed program with the path to the bad step", function()
        local ok, err = pcall(function()
            app.client:call("cmd_program_play", {
                steps = {
                    {op = "call", action = "spec.mark"},
                    {op = "nonsense"},
                },
            })
        end)
        luassert.is_false(ok)
        luassert.is_truthy(tostring(err):find("program%[2%]"), tostring(err))
    end)

    it("injects input on the frame clock", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local input = require("tecs2d.input")
            _G.tecsKeys = 0
            world:addSystem({name = "spec.Keys", phase = tecs.phases.Update,
                run = function()
                    if input.isKeyPressed("space") then _G.tecsKeys = _G.tecsKeys + 1 end
                end})
            return true
        ]])

        app.client:call("cmd_program_play", {
            clock = "frame",
            steps = {
                {op = "input", event = "keypressed", args = {"space"}},
                {op = "waitSteps", steps = 2},
                {op = "input", event = "keyreleased", args = {"space"}},
            },
        })

        local pressed = fixture.eventually(fixture.callTimeout, function(): boolean
            local n = tonumber(fixture.runLua(app, "return _G.tecsKeys")[1])
            if n and n >= 1 then return true end
            return nil
        end)
        luassert.is_true(pressed == true, "the taped key press never reached the game")
    end)

    it("cancels a playback on request", function()
        local result = app.client:call("cmd_program_play", {
            steps = {
                {op = "waitSteps", steps = 600},
                {op = "call", action = "spec.mark", args = {"never"}},
            },
        })
        local cancelled = app.client:call("cmd_program_cancel", {handle = result.handle})
        luassert.is_true(cancelled.cancelled)

        local status = app.client:call("cmd_program_status", {handle = result.handle})
        luassert.equals("cancelled", status.state)
    end)

    it("survives a snapshot taken mid-program", function()
        -- Earlier cases left playbacks running; they would mark into this
        -- one's list.
        fixture.runLua(app, [[
            local sequence = require("tecs2d.sequence")
            for _, handle in ipairs(sequence.playbacks(world)) do
                sequence.cancel(world, handle)
            end
            _G.tecsMarks = {}
            return true
        ]])
        local result = app.client:call("cmd_program_play", {
            steps = {
                {op = "call", action = "spec.mark", args = {"before"}},
                {op = "waitSteps", steps = 240},
                {op = "call", action = "spec.mark", args = {"after"}},
            },
        })

        local started = fixture.eventually(fixture.callTimeout, function(): boolean
            if marks() == "before" then return true end
            return nil
        end)
        luassert.is_true(started == true)

        fixture.runLua(app, [[
            local snapshot = world:saveSnapshot()
            return love.filesystem.write("]] .. SAVE_PATH .. [[", tostring(snapshot.buffer))
        ]])

        -- Load it back and let the rest of the program run out. run_lua could
        -- not have done this: its work is a closure, and a closure does not
        -- survive a save.
        fixture.runLua(app, [[
            _G.tecsMarks = {}
            world:loadSnapshot(love.filesystem.read("]] .. SAVE_PATH .. [["))
            return true
        ]])

        local status = app.client:call("cmd_program_status", {handle = result.handle})
        luassert.equals("running", status.state,
            "the restored playback should still be mid-program")

        fixture.runLua(app, [[
            local sequence = require("tecs2d.sequence")
            sequence.registerAction(world, "spec.mark", function(_w, ctx)
                _G.tecsMarks[#_G.tecsMarks + 1] = ctx.args[1]
            end)
            return true
        ]])

        local finished = fixture.eventually(20, function(): boolean
            if marks() == "after" then return true end
            return nil
        end)
        luassert.is_true(finished == true,
            "the restored program never finished, saw: " .. marks())
    end)
end)
