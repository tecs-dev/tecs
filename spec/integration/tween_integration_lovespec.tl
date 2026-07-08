--- Love2D integration suite: tween plugin under the real frame loop.
--- Covers absolute :to() targets, relative :adjust() moves, loop counts,
--- completion events, and playback cleanup; the tween plugin is
--- auto-installed by tecs2d.run but was previously only unit-tested.
---
--- Run via `make test-love FILE_MATCH='tween_integration'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("spec.integration.harness.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local function transformX(app: fixture.App, globalName: string): number
    local values = fixture.runLua(app, string.format([[
        local tecs = require("tecs")
        local t = world:get(_G[%q], tecs.builtins.Transform)
        return t and t.x or -1
    ]], globalName))
    return tonumber(values[1])
end

local function waitX(app: fixture.App, globalName: string, expected: number, label: string)
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        if math.abs(transformX(app, globalName) - expected) < 0.5 then return true end
        return nil
    end)
    luassert.is_true(ok == true, string.format(
        "%s: expected x ~ %.1f, got %.3f", label, expected, transformX(app, globalName)))
end

describe("tween: timelines drive transforms in the live loop", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it(":to() reaches its absolute target and cleans up playback", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local tween = require("tecs2d.tween")
            local Transform = tecs.builtins.Transform
            _G.tecsTweenA = world:spawn(Transform(60, 60, 0, 1), gfx.Rectangle(8, 8), gfx.Color(1, 0, 0, 1))
            tween.timeline()
                :to(0.4, tween.linear, tween.translateX, 200)
                :once()
                :apply(world, _G.tecsTweenA)
            return true
        ]])
        waitX(app, "tecsTweenA", 200, "absolute :to() target")

        -- Playback removes itself once the timeline finishes.
        local cleaned = fixture.eventually(fixture.callTimeout, function(): boolean
            local values = fixture.runLua(app, [[
                local tween = require("tecs2d.tween")
                return world:get(_G.tecsTweenA, tween.TweenPlayback) == nil
            ]])
            if values[1] == "true" then return true end
            return nil
        end)
        luassert.is_true(cleaned == true, "TweenPlayback lingered after completion")
    end)

    it(":adjust() moves relative to the start value", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local tween = require("tecs2d.tween")
            local Transform = tecs.builtins.Transform
            _G.tecsTweenB = world:spawn(Transform(50, 90, 0, 1), gfx.Rectangle(8, 8), gfx.Color(0, 1, 0, 1))
            tween.timeline()
                :adjust(0.3, tween.linear, tween.translateX, 40)
                :once()
                :apply(world, _G.tecsTweenB)
            return true
        ]])
        waitX(app, "tecsTweenB", 90, "relative :adjust() by +40 from 50")
    end)

    it(":loop(n) repeats the timeline n times after the initial play", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local tween = require("tecs2d.tween")
            local Transform = tecs.builtins.Transform
            _G.tecsTweenC = world:spawn(Transform(30, 150, 0, 1), gfx.Rectangle(8, 8), gfx.Color(0, 0, 1, 1))
            tween.timeline()
                :adjust(0.2, tween.linear, tween.translateX, 25)
                :loop(3)
                :apply(world, _G.tecsTweenC)
            return true
        ]])
        -- loop(n) = n repeats on top of the initial play (once() is
        -- repeats=0), so +25 runs four times.
        waitX(app, "tecsTweenC", 30 + 25 * 4, "initial play plus three repeats of +25")
    end)

    it("emits TweenComplete when a timeline finishes", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local tween = require("tecs2d.tween")
            local Transform = tecs.builtins.Transform
            _G.tecsTweenD = world:spawn(Transform(60, 200, 0, 1), gfx.Rectangle(8, 8), gfx.Color(1, 1, 0, 1))
            -- TweenComplete is emitted to the global address (0) with
            -- the entity carried in the payload.
            _G.tecsTweenDone = false
            world:observe(0, tween.TweenComplete, function(e)
                if e.entity == _G.tecsTweenD then
                    _G.tecsTweenDone = true
                end
            end)
            tween.timeline()
                :to(0.2, tween.linear, tween.translateX, 120)
                :once()
                :apply(world, _G.tecsTweenD)
            return true
        ]])
        local done = fixture.eventually(fixture.callTimeout, function(): boolean
            local values = fixture.runLua(app, "return _G.tecsTweenDone")
            if values[1] == "true" then return true end
            return nil
        end)
        luassert.is_true(done == true, "TweenComplete never fired")
    end)
end)
