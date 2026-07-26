--- Love2D integration suite: input event flow. Love events pushed via
--- the send_love_event MCP tool must travel through the event poller
--- into world observers as tecs2d event records with their payloads
--- intact (key constants, mouse coordinates and button, wheel delta).
--- Covers handlers.pollEvents and the events module end to end.
---
--- Run via `make test-love FILE_MATCH='input_injection'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local function waitGlobal(app: fixture.App, expr: string, label: string): {string}
    local result = fixture.eventually(fixture.callTimeout, function(): {string}
        local values = fixture.runLua(app, "return " .. expr)
        if values[1] ~= nil and values[1] ~= "nil" then return values end
        return nil
    end)
    luassert.is_table(result, label .. " never arrived")
    return result
end

describe("input injection: love events reach world observers", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs2d = require("tecs")
            _G.tecsKey = nil
            _G.tecsKeyUp = nil
            _G.tecsMouse = nil
            world:observe(0, tecs.KeyPressed, function(e)
                _G.tecsKey = {key = e.key, isrepeat = e.isrepeat}
            end)
            world:observe(0, tecs.KeyReleased, function(e)
                _G.tecsKeyUp = {key = e.key}
            end)
            world:observe(0, tecs.MousePressed, function(e)
                _G.tecsMouse = {x = e.x, y = e.y, button = e.button}
            end)
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("keypressed reaches observers with the key constant", function()
        app.client:call("send_love_event", {
            event = "keypressed",
            args = {"space", "space", false},
        })
        local values = waitGlobal(app,
            "_G.tecsKey and _G.tecsKey.key, _G.tecsKey and tostring(_G.tecsKey.isrepeat)",
            "KeyPressed observer")
        luassert.equals("space", values[1], "wrong key constant delivered")
        luassert.equals("false", values[2], "isrepeat should be false")
    end)

    it("mousepressed carries coordinates and button", function()
        app.client:call("send_love_event", {
            event = "mousepressed",
            args = {123, 45, 2, false, 1},
        })
        local values = waitGlobal(app,
            "_G.tecsMouse and _G.tecsMouse.x, _G.tecsMouse and _G.tecsMouse.y, _G.tecsMouse and _G.tecsMouse.button",
            "MousePressed observer")
        luassert.equals(123, tonumber(values[1]), "wrong mouse x")
        luassert.equals(45, tonumber(values[2]), "wrong mouse y")
        luassert.equals(2, tonumber(values[3]), "wrong mouse button")
    end)

    it("keyreleased reaches its own observer", function()
        app.client:call("send_love_event", {
            event = "keyreleased",
            args = {"space", "space"},
        })
        local values = waitGlobal(app,
            "_G.tecsKeyUp and _G.tecsKeyUp.key", "KeyReleased observer")
        luassert.equals("space", values[1], "wrong key constant on release")
    end)

    it("intercepts at the top target while raw observers still receive the event", function()
        fixture.runLua(app, [[
            local input = require("tecs.input")
            local events = require("tecs.events")
            _G.tecsKey = nil
            _G.routeCounts = {top = 0, raw = 0}
            _G.routeLayer = input.newLayer("integration-modal")
            _G.routeLayer:observe(events.KeyPressed, function()
                _G.routeCounts.top = _G.routeCounts.top + 1
                -- Deliberately omit parent:emit: this layer consumes the key.
            end)
            input.raw:observe(events.KeyPressed, function()
                _G.routeCounts.raw = _G.routeCounts.raw + 1
            end, "integration-raw")
            input.pushLayer(_G.routeLayer)
            return true
        ]])

        app.client:call("send_love_event", {
            event = "keypressed",
            args = {"r", "r", false},
        })
        local values = waitGlobal(app,
            "_G.routeCounts.top == 1 and _G.routeCounts.top or nil, _G.routeCounts.raw, tostring(_G.tecsKey == nil)",
            "routed input counts")
        luassert.equals("1", values[1])
        luassert.equals("1", values[2])
        luassert.equals("true", values[3], "base observer received an intercepted key")

        fixture.runLua(app, [[
            local input = require("tecs.input")
            input.popLayer(_G.routeLayer)
            input.raw:stopObserving(require("tecs.events").KeyPressed, "integration-raw")
            _G.routeLayer = nil
            return true
        ]])
    end)

    it("rewires a popped parent and forwards the same event to the base", function()
        fixture.runLua(app, [[
            local input = require("tecs.input")
            local events = require("tecs.events")
            _G.tecsMouse = nil
            local lower = input.newLayer("lower")
            local upper = input.newLayer("upper")
            upper:observe(events.MousePressed, function(event)
                upper.parent:emit(event)
            end)
            input.pushLayer(lower)
            input.pushLayer(upper)
            input.popLayer(lower)
            _G.routeLayer = upper
            _G.rewiredToBase = upper.parent == input.base
            return true
        ]])

        app.client:call("send_love_event", {
            event = "mousepressed",
            args = {87, 65, 1, false, 1},
        })
        local values = waitGlobal(app,
            "_G.tecsMouse and _G.tecsMouse.x, _G.tecsMouse and _G.tecsMouse.y, tostring(_G.rewiredToBase)",
            "forwarded MousePressed")
        luassert.equals(87, tonumber(values[1]))
        luassert.equals(65, tonumber(values[2]))
        luassert.equals("true", values[3])

        fixture.runLua(app, [[
            require("tecs.input").popLayer(_G.routeLayer)
            _G.routeLayer = nil
            return true
        ]])
    end)
end)
