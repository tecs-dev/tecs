require("busted")

_G.love = require("spec.love2d.love2d_mock")

local luassert <const> = require("luassert")
local tecs <const> = require("tecs")
local inputHandlers <const> = require("tecs2d.internal.handlers")
local inputtape <const> = require("tecs2d.debug.internal.inputtape")

-- Characterization: the tape had no unit coverage, only whatever the
-- integration suite happened to drive. These record what it does now, so the
-- move onto the sequencer's frame clock has to keep doing it.
describe("tecs2d.debug.internal.inputtape", function()
    local world: tecs.World
    local tape: inputtape.Tape
    local fired: {string}

    local function frames(n: integer)
        for _ = 1, n do world:update(1 / 60) end
    end

    before_each(function()
        world = tecs.newWorld()
        world:startup()
        tape = inputtape.ensure(world)
        fired = {}
        inputHandlers.onDispatch = function(name: string, ...: any)
            local args = {...}
            fired[#fired + 1] = name .. ":" .. tostring(args[1])
        end
    end)

    after_each(function()
        inputHandlers.onDispatch = nil
    end)

    describe("queueing", function()
        it("fires a row on the gameplay frame it names", function()
            luassert.equals(1, tape:queue({{at = 2, event = "keypressed", args = {"a"}}}, false))

            frames(1)
            luassert.same({}, fired, "at=2 must not fire on the first frame")
            frames(1)
            luassert.same({"keypressed:a"}, fired)
        end)

        it("counts `at` from queue time, not from world start", function()
            frames(3)
            tape:queue({{at = 1, event = "keypressed", args = {"a"}}}, false)
            frames(1)
            luassert.same({"keypressed:a"}, fired)
        end)

        it("fires rows due on one frame in the order they were queued", function()
            tape:queue({
                {at = 1, event = "keypressed", args = {"first"}},
                {at = 1, event = "keypressed", args = {"second"}},
            }, false)
            tape:queue({{at = 1, event = "keypressed", args = {"third"}}}, false)

            frames(1)
            luassert.same({"keypressed:first", "keypressed:second", "keypressed:third"}, fired)
        end)

        it("orders by frame before queue order", function()
            tape:queue({
                {at = 3, event = "keypressed", args = {"late"}},
                {at = 1, event = "keypressed", args = {"early"}},
            }, false)

            frames(3)
            luassert.same({"keypressed:early", "keypressed:late"}, fired)
        end)

        it("reports how many rows it accepted", function()
            local n, err = tape:queue({
                {at = 1, event = "keypressed", args = {"a"}},
                {at = 2, event = "keyreleased", args = {"a"}},
            }, false)
            luassert.equals(2, n)
            luassert.is_nil(err)
        end)
    end)

    describe("validation", function()
        it("queues nothing when any row is bad", function()
            local n, err = tape:queue({
                {at = 1, event = "keypressed", args = {"a"}},
                {at = 1, event = "nonsense", args = {}},
            }, false)
            luassert.is_nil(n)
            luassert.is_truthy(err)

            frames(2)
            luassert.same({}, fired, "a rejected batch must be atomic")
        end)

        it("rejects a non-positive or fractional frame", function()
            luassert.is_nil(tape:queue({{at = 0, event = "keypressed", args = {"a"}}}, false))
            luassert.is_nil(tape:queue({{at = 1.5, event = "keypressed", args = {"a"}}}, false))
        end)

        it("refuses escape unless forced", function()
            luassert.is_nil(tape:queue({{at = 1, event = "keypressed", args = {"escape"}}}, false))
            luassert.equals(1,
                tape:queue({{at = 1, event = "keypressed", args = {"escape"}}}, true))
        end)

        it("refuses events that need a device object", function()
            luassert.is_false(inputtape.tapeable("gamepadpressed"))
            luassert.is_true(inputtape.tapeable("keypressed"))
            luassert.is_nil(tape:queue({{at = 1, event = "gamepadpressed", args = {}}}, false))
        end)

        it("fills the arguments a short row leaves out", function()
            luassert.equals(1, tape:queue({{at = 1, event = "keypressed", args = {"a"}}}, false))
            luassert.is_nil(tape:queue({{at = 1, event = "mousepressed", args = {1}}}, false),
                "mouse rows need x, y, and button")
        end)
    end)

    describe("held inputs", function()
        it("remembers a press until its release", function()
            tape:queue({{at = 1, event = "keypressed", args = {"a"}}}, false)
            frames(1)
            luassert.same({"key:a"}, tape:heldIds())

            tape:queue({{at = 1, event = "keyreleased", args = {"a"}}}, false)
            frames(1)
            luassert.same({}, tape:heldIds())
        end)

        it("tracks mouse and touch by button and id", function()
            tape:queue({
                {at = 1, event = "mousepressed", args = {10, 20, 2}},
                {at = 1, event = "touchpressed", args = {"t1", 1, 2}},
            }, false)
            frames(1)
            luassert.same({"mouse:2", "touch:t1"}, tape:heldIds())
        end)
    end)

    describe("clear", function()
        it("drops pending rows and reports how many", function()
            tape:queue({
                {at = 5, event = "keypressed", args = {"a"}},
                {at = 6, event = "keypressed", args = {"b"}},
            }, false)

            local dropped, released = tape:clear()
            luassert.equals(2, dropped)
            luassert.equals(0, released)

            frames(8)
            luassert.same({}, fired, "cleared rows must never fire")
        end)

        it("synthesizes releases for what it left held", function()
            tape:queue({{at = 1, event = "keypressed", args = {"a"}}}, false)
            frames(1)
            fired = {}

            local dropped, released = tape:clear()
            luassert.equals(0, dropped)
            luassert.equals(1, released)
            luassert.same({"keyreleased:a"}, fired)
            luassert.same({}, tape:heldIds())
        end)
    end)

    describe("upcoming", function()
        it("reports pending rows within the window, soonest first", function()
            tape:queue({
                {at = 4, event = "keypressed", args = {"late"}},
                {at = 1, event = "keypressed", args = {"soon"}},
            }, false)

            local up = tape:upcoming(2)
            luassert.equals(1, #up, "only the row inside the window")
            luassert.equals(1, up[1]["in"])
            luassert.equals("keypressed", up[1].event)

            local all = tape:upcoming(10)
            luassert.equals(2, #all)
            luassert.equals(1, all[1]["in"])
            luassert.equals(4, all[2]["in"])
        end)

        it("counts down as frames pass", function()
            tape:queue({{at = 3, event = "keypressed", args = {"a"}}}, false)
            frames(1)
            luassert.equals(2, tape:upcoming(10)[1]["in"])
            frames(1)
            luassert.equals(1, tape:upcoming(10)[1]["in"])
        end)

        it("forgets a row once it has fired", function()
            tape:queue({{at = 1, event = "keypressed", args = {"a"}}}, false)
            frames(1)
            luassert.equals(0, #tape:upcoming(10))
        end)
    end)
end)
