--- Love2D integration suite: polled input-state semantics. The input
--- module builds its state from love events, so injected events drive
--- the real per-frame contract: isKeyPressed edges fire on exactly one
--- Update frame, isKeyDown holds between press and release, latched
--- edges reach exactly one FixedUpdate tick, wheel movement accumulates,
--- and mouse buttons mirror the keyboard semantics. An in-app recorder
--- system samples the API every frame (the edge windows are one frame,
--- far shorter than an MCP round trip).
---
--- Run via `make test-love FILE_MATCH='input_state'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("spec.integration.harness.fixture")

local socket <const> = require("socket")
local sleep <const> = socket.sleep as function(number)

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local function rec(app: fixture.App, field: string): number
    local values = fixture.runLua(app, "return _G.tecsInputRec." .. field)
    return tonumber(values[1])
end

local function waitRec(app: fixture.App, field: string, expected: number, label: string)
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        if rec(app, field) == expected then return true end
        return nil
    end)
    luassert.is_true(ok == true, string.format(
        "%s: expected %s == %d, got %d", label, field, expected, rec(app, field)))
end

describe("input state: per-frame edge and hold semantics", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local input = require("tecs2d.input")
            _G.tecsInputRec = {
                pressed = 0, released = 0, downFrames = 0,
                fixedPressed = 0,
                mousePressed = 0, mouseReleased = 0, mouseDownFrames = 0,
                wheelY = 0,
            }
            local r = _G.tecsInputRec
            world:addSystem({
                name = "test.InputRecorder",
                phase = tecs.phases.Update,
                run = function()
                    if input.isKeyPressed("space") then r.pressed = r.pressed + 1 end
                    if input.isKeyReleased("space") then r.released = r.released + 1 end
                    if input.isKeyDown("space") then r.downFrames = r.downFrames + 1 end
                    if input.isMousePressed(1) then r.mousePressed = r.mousePressed + 1 end
                    if input.isMouseReleased(1) then r.mouseReleased = r.mouseReleased + 1 end
                    if input.isMouseDown(1) then r.mouseDownFrames = r.mouseDownFrames + 1 end
                    local _, wy = input.getMouseWheelMovement()
                    r.wheelY = r.wheelY + wy
                end,
            })
            world:addSystem({
                name = "test.InputRecorderFixed",
                phase = tecs.phases.FixedUpdate,
                run = function()
                    if input.isKeyPressed("space") then r.fixedPressed = r.fixedPressed + 1 end
                end,
            })
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("a key press edge fires on exactly one Update frame", function()
        app.client:call("send_love_event", {event = "keypressed", args = {"space", "space", false}})
        waitRec(app, "pressed", 1, "press edge should fire once")
        -- Many frames later it must still be exactly one.
        sleep(0.3)
        luassert.equals(1, rec(app, "pressed"), "press edge fired on more than one frame")
    end)

    it("isKeyDown holds from press until release", function()
        local d1 = rec(app, "downFrames")
        sleep(0.2)
        local d2 = rec(app, "downFrames")
        luassert.is_true(d2 > d1, "isKeyDown should stay true while the key is held")

        app.client:call("send_love_event", {event = "keyreleased", args = {"space", "space"}})
        waitRec(app, "released", 1, "release edge should fire once")
        local d3 = rec(app, "downFrames")
        sleep(0.2)
        luassert.equals(d3, rec(app, "downFrames"), "isKeyDown stayed true after release")
    end)

    it("latched press edges reach exactly one FixedUpdate tick", function()
        luassert.equals(1, rec(app, "fixedPressed"),
            "the press should have latched into exactly one FixedUpdate tick")
    end)

    it("mouse buttons follow the same edge and hold semantics", function()
        app.client:call("send_love_event", {event = "mousepressed", args = {100, 100, 1, false, 1}})
        waitRec(app, "mousePressed", 1, "mouse press edge")
        local d1 = rec(app, "mouseDownFrames")
        sleep(0.2)
        luassert.is_true(rec(app, "mouseDownFrames") > d1, "isMouseDown should hold")

        app.client:call("send_love_event", {event = "mousereleased", args = {100, 100, 1, false, 1}})
        waitRec(app, "mouseReleased", 1, "mouse release edge")
        sleep(0.3)
        luassert.equals(1, rec(app, "mousePressed"), "mouse press edge fired more than once")
    end)

    it("wheel movement accumulates the pushed deltas", function()
        app.client:call("send_love_event", {event = "wheelmoved", args = {0, -3}})
        app.client:call("send_love_event", {event = "wheelmoved", args = {0, 2}})
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            if math.abs(rec(app, "wheelY")) == 1 then return true end
            return nil
        end)
        luassert.is_true(ok == true, string.format(
            "wheel total should be -3 + 2 = +-1, got %d", rec(app, "wheelY")))
    end)
end)
