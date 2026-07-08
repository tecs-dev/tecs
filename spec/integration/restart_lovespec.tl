--- Love2D integration suite: engine restart. The MCP restart tool quits
--- with love's "restart" code, which re-runs the whole tecs2d loop in
--- the same process: fresh world, rebuilt GPU resources, and a
--- re-listening MCP server on the same port. Covers the restart
--- machinery end to end (previously zero coverage).
---
--- Run via `make test-love FILE_MATCH='restart'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("spec.integration.harness.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local W <const> = 320.0
local H <const> = 240.0

describe("restart: the loop reboots into a fresh, working world", function()
    local app: fixture.App
    local baselineEntities: integer

    setup(function()
        app = fixture.start(APP_DIR)
        baselineEntities = tonumber(app.client:call("get_stats", {}).entities) as integer
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(Transform(160, 120, 0, 1), gfx.Rectangle(30, 30), gfx.Color(1, 0, 0, 1))
            return true
        ]])
        local drawn = fixture.eventually(fixture.callTimeout, function(): boolean
            local p = fixture.probePixels(app, {{0.5, 0.5}})[1]
            if p[1] > 0.8 then return true end
            return nil
        end)
        luassert.is_true(drawn == true, "pre-restart marker never rendered")
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("restart produces a fresh world on the same MCP port", function()
        local result = app.client:call("restart", {})
        luassert.is_true(result.restarting == true, "restart tool did not acknowledge")

        -- The server drops and re-listens; poll with tryCall until the
        -- rebooted world answers. The fresh world must be back at the
        -- baseline entity count (the marker is gone). Lingering kernel
        -- connection state from this suite's own earlier requests can
        -- hold the port for up to ~30 seconds on macOS; the server
        -- rebinds in the background until it clears.
        local lastSeen: string = "no response"
        local fresh = fixture.eventually(40, function(): boolean
            -- tryCall returns the raw envelope; use a pcall'd call for
            -- the unwrapped result (it raises while the server is down).
            local ok, stats = pcall(function(): {string: any}
                return app.client:call("get_stats", {}, 2)
            end)
            if ok and stats then
                lastSeen = "entities=" .. tostring(stats.entities)
                if tonumber(stats.entities) == baselineEntities then
                    return true
                end
            elseif not ok then
                lastSeen = tostring(stats)
            end
            return nil
        end)
        luassert.is_true(fresh == true, string.format(
            "restarted world never came back at baseline %d (last: %s)",
            baselineEntities, lastSeen))

        -- The marker's pixels are gone with it. Probes are pcall-wrapped:
        -- the server may still be mid-reboot on early polls.
        local cleared = fixture.eventually(fixture.callTimeout, function(): boolean
            local ok, p = pcall(function(): {number}
                return fixture.probePixels(app, {{0.5, 0.5}})[1]
            end)
            if ok and p[1] < 0.1 then return true end
            return nil
        end)
        luassert.is_true(cleared == true, "pre-restart content still renders after restart")
    end)

    it("the rebooted pipeline renders new content", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(Transform(160, 120, 0, 1), gfx.Circle(16), gfx.Color(0, 1, 0, 1))
            return true
        ]])
        local drawn = fixture.eventually(fixture.callTimeout, function(): boolean
            local p = fixture.probePixels(app, {{0.5, 0.5}})[1]
            if p[2] > 0.8 then return true end
            return nil
        end)
        luassert.is_true(drawn == true, "post-restart world never rendered new content")
    end)
end)
