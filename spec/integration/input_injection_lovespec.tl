--- Love2D integration suite: input event flow. LÖVE events pushed via
--- the send_love_event MCP tool must travel through the event poller
--- into world observers as tecs2d event records with their payloads
--- intact (key constants, mouse coordinates and button, wheel delta).
--- Covers handlers.pollEvents and the events module end to end.
---
--- Run via `make test-love FILE_MATCH='input_injection'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

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
            local tecs2d = require("tecs2d")
            _G.tecsKey = nil
            _G.tecsKeyUp = nil
            _G.tecsMouse = nil
            world:observe(0, tecs2d.KeyPressed, function(e)
                _G.tecsKey = {key = e.key, isrepeat = e.isrepeat}
            end)
            world:observe(0, tecs2d.KeyReleased, function(e)
                _G.tecsKeyUp = {key = e.key}
            end)
            world:observe(0, tecs2d.MousePressed, function(e)
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
end)
