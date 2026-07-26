--- Love2D integration suite: suspension, step, and time-scale semantics. A
--- tween drives an entity's Transform.x so motion is observable from outside;
--- suspension must stop it exactly, cmd_step must advance it by a bounded
--- amount and suspend again, releasing suspension must restore motion, and a
--- higher time scale must move it proportionally faster.
--- Covers the MCP control surface, the pipeline's gameTime/timeScale
--- plumbing, and the tween plugin under the real frame loop.
---
--- Run via `make test-love FILE_MATCH='pause_timescale'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local socket <const> = require("socket")
local sleep <const> = socket.sleep as function(number)

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local function markerX(app: fixture.App): number
    local values = fixture.runLua(app, [[
        local tecs = require("tecs")
        local t = world:get(_G.tecsMover, tecs.builtins.Transform)
        return t.x
    ]])
    return tonumber(values[1])
end

local function setSuspended(app: fixture.App, suspended: boolean)
    local action = suspended and "suspend" or "resume"
    fixture.runLua(app, "require('tecs.internal.suspension').ensure(world):"
        .. action .. "('spec') return true")
end

describe("pause and time scale: motion control from MCP", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs.gfx")
            local sequence = require("tecs.sequence")
            local Transform = tecs.builtins.Transform
            _G.tecsMover = world:spawn(
                Transform(20, 120, 0, 1), gfx.Rectangle(10, 10), gfx.Color(1, 0, 0, 1))
            -- Long, slow, linear drift so every phase of the suite has motion.
            sequence.play(world, sequence.timeline("spec.drift", {
                sequence.tweenTo(120, "linear", "transform.x", 20000),
            }), {owner = _G.tecsMover})
            return true
        ]])
        local moving = fixture.eventually(fixture.callTimeout, function(): boolean
            if markerX(app) > 21 then return true end
            return nil
        end)
        luassert.is_true(moving == true, "tween never started moving the marker")
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("suspension stops gameplay", function()
        setSuspended(app, true)
        -- Let any in-flight frame drain, then sample twice.
        sleep(0.2)
        local x1 = markerX(app)
        sleep(0.3)
        local x2 = markerX(app)
        luassert.equals(x1, x2, string.format(
            "marker moved while paused (%.4f -> %.4f)", x1, x2))
    end)

    it("step advances a bounded number of frames and freezes again", function()
        setSuspended(app, true)
        local before = markerX(app)
        app.client:call("cmd_step", {n = 10})
        -- Stepping spans ~10 frames of wall time; wait until the marker
        -- settles (two identical samples) before judging the distance.
        local settled = fixture.eventually(fixture.callTimeout, function(): number
            local x1 = markerX(app)
            sleep(0.15)
            local x2 = markerX(app)
            if x2 == x1 and x1 > before then return x1 end
            return nil
        end)
        luassert.is_number(settled, "marker never settled after step")

        -- The tween moves ~2.8px per 60Hz frame; 10 stepped frames is
        -- ~28px. Anything far past that means step failed to re-pause.
        local advance = settled - before
        luassert.is_true(advance > 0 and advance < 60, string.format(
            "step advanced an unreasonable distance: %.2fpx", advance))

        sleep(0.3)
        luassert.equals(settled, markerX(app), "marker kept moving after step completed")
    end)

    it("releasing suspension restores motion", function()
        setSuspended(app, true)
        local before = markerX(app)
        setSuspended(app, false)
        local moving = fixture.eventually(fixture.callTimeout, function(): boolean
            if markerX(app) > before + 1 then return true end
            return nil
        end)
        luassert.is_true(moving == true, "marker did not move after resume")
    end)

    it("time scale changes motion speed proportionally", function()
        -- Measure drift over the same wall-clock window at 1x and 4x.
        app.client:call("cmd_camera_timescale", {scale = 1.0})
        sleep(0.1)
        local a1 = markerX(app)
        sleep(0.5)
        local slowDx = markerX(app) - a1

        app.client:call("cmd_camera_timescale", {scale = 4.0})
        sleep(0.1)
        local b1 = markerX(app)
        sleep(0.5)
        local fastDx = markerX(app) - b1

        app.client:call("cmd_camera_timescale", {scale = 1.0})
        luassert.is_true(slowDx > 0, "no motion at 1x time scale")
        luassert.is_true(fastDx > slowDx * 2, string.format(
            "4x time scale should move much faster than 1x (1x %.3f, 4x %.3f)",
            slowDx, fastDx))
    end)
end)
