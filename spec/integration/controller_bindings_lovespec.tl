--- Love2D integration suite: controller bindings, keyboard half. The
--- auto-installed control manager maps physical inputs to logical
--- actions; injected key events must drive isPressed/isDown/isReleased
--- edges, getRaw values, and runtime rebinding. (The gamepad half needs
--- an SDL virtual device and is covered separately.)
---
--- Run via `make test-love FILE_MATCH='controller_bindings'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local socket <const> = require("socket")
local sleep <const> = socket.sleep as function(number)

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local function rec(app: fixture.App, field: string): number
    local values = fixture.runLua(app, "return _G.tecsCtrlRec." .. field)
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

local function pressKey(app: fixture.App, key: string)
    app.client:call("send_love_event", {event = "keypressed", args = {key, key, false}})
end

local function releaseKey(app: fixture.App, key: string)
    app.client:call("send_love_event", {event = "keyreleased", args = {key, key}})
end

describe("controller bindings: keys drive logical actions", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local controller = require("tecs.controller")
            local manager = world.resources[controller]
            _G.tecsCtrl = manager:addController({
                controls = {
                    jump = {"key:space"},
                    fire = {"key:f", "key:j"},
                },
            }, {})

            _G.tecsCtrlRec = {
                jumpPressed = 0, jumpReleased = 0, jumpDownFrames = 0,
                firePressed = 0, jumpRaw = 0,
            }
            local r = _G.tecsCtrlRec
            world:addSystem({
                name = "test.CtrlRecorder",
                phase = tecs.phases.Update,
                run = function()
                    local ctrl = _G.tecsCtrl
                    if ctrl:isPressed("jump") then r.jumpPressed = r.jumpPressed + 1 end
                    if ctrl:isReleased("jump") then r.jumpReleased = r.jumpReleased + 1 end
                    if ctrl:isDown("jump") then r.jumpDownFrames = r.jumpDownFrames + 1 end
                    if ctrl:isPressed("fire") then r.firePressed = r.firePressed + 1 end
                    r.jumpRaw = ctrl:getRaw("jump")
                end,
            })
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("a bound key press fires the action edge exactly once", function()
        pressKey(app, "space")
        waitRec(app, "jumpPressed", 1, "jump press edge")
        sleep(0.3)
        luassert.equals(1, rec(app, "jumpPressed"), "jump edge fired on more than one frame")
        luassert.equals(1, rec(app, "jumpRaw"), "getRaw should read 1 while held")
    end)

    it("the action stays down until the key releases", function()
        local d1 = rec(app, "jumpDownFrames")
        sleep(0.2)
        luassert.is_true(rec(app, "jumpDownFrames") > d1, "jump should stay down while held")

        releaseKey(app, "space")
        waitRec(app, "jumpReleased", 1, "jump release edge")
        luassert.equals(0, rec(app, "jumpRaw"), "getRaw should read 0 after release")
        local d2 = rec(app, "jumpDownFrames")
        sleep(0.2)
        luassert.equals(d2, rec(app, "jumpDownFrames"), "jump stayed down after release")
    end)

    it("any of multiple bound keys triggers the action", function()
        pressKey(app, "f")
        waitRec(app, "firePressed", 1, "fire via first binding")
        releaseKey(app, "f")
        pressKey(app, "j")
        waitRec(app, "firePressed", 2, "fire via second binding")
        releaseKey(app, "j")
    end)

    it("unbound keys do nothing", function()
        pressKey(app, "q")
        sleep(0.3)
        releaseKey(app, "q")
        luassert.equals(1, rec(app, "jumpPressed"), "unbound key affected jump")
        luassert.equals(2, rec(app, "firePressed"), "unbound key affected fire")
    end)

    it("rebinding takes effect at runtime", function()
        fixture.runLua(app, [[
            _G.tecsCtrl:rebind({controls = {
                jump = {"key:k"},
                fire = {"key:f", "key:j"},
            }})
            return true
        ]])
        -- The old key no longer triggers the action.
        pressKey(app, "space")
        sleep(0.3)
        releaseKey(app, "space")
        luassert.equals(1, rec(app, "jumpPressed"), "old binding still triggers after rebind")

        -- The new key does.
        pressKey(app, "k")
        waitRec(app, "jumpPressed", 2, "rebound key should trigger jump")
        releaseKey(app, "k")
    end)
end)
