--- Love2D integration suite: window resize handling. Resizing via
--- love.window.setMode must flow through the Resize event into
--- setScreenSize: canvases rebuild at the new resolution, the virtual
--- width recomputes, and world content keeps rendering where the camera
--- math says it should. Covers the resize observer path and the canvas
--- rebuild (including cached shadow-mask invalidation).
---
--- Run via `make test-love FILE_MATCH='resize'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("spec.integration.harness.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

--- Probe the marker through the camera's own toScreen, normalized by the
--- app's reported window size, so assertions hold at any resolution.
local function waitMarkerVisible(app: fixture.App, label: string)
    local values = fixture.runLua(app, [[
        local gfx = require("tecs2d.gfx")
        local cam = world.resources[gfx.PIPELINE]:getCamera()
        local sx, sy = cam:toScreen(160, 120)
        local w, h = love.graphics.getDimensions()
        return sx / w, sy / h
    ]])
    local fx = tonumber(values[1])
    local fy = tonumber(values[2])
    luassert.is_number(fx, label .. ": no toScreen result")

    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        local p = fixture.probePixels(app, {{fx, fy}})[1]
        if p[1] > 0.8 and p[2] < 0.2 then return true end
        return nil
    end)
    local p = fixture.probePixels(app, {{fx, fy}})[1]
    luassert.is_true(ok == true, string.format(
        "%s: marker not red at (%.3f, %.3f); pixel = (%.2f, %.2f, %.2f)",
        label, fx, fy, p[1], p[2], p[3]))
end

describe("resize: pipeline follows window size changes", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(Transform(160, 120, 0, 1), gfx.Rectangle(14, 14), gfx.Color(1, 0, 0, 1))
            return true
        ]])
        waitMarkerVisible(app, "before resize")
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("re-renders correctly after growing the window", function()
        fixture.runLua(app, "love.window.setMode(640, 480) return true")
        local resized = fixture.eventually(fixture.callTimeout, function(): boolean
            local values = fixture.runLua(app, [[
                local gfx = require("tecs2d.gfx")
                local p = world.resources[gfx.PIPELINE]
                return p.screenWidth, p.screenHeight
            ]])
            if tonumber(values[1]) == 640 and tonumber(values[2]) == 480 then
                return true
            end
            return nil
        end)
        luassert.is_true(resized == true, "pipeline never picked up the new window size")
        waitMarkerVisible(app, "after growing to 640x480")
    end)

    it("re-renders correctly after shrinking back", function()
        fixture.runLua(app, "love.window.setMode(320, 240) return true")
        local resized = fixture.eventually(fixture.callTimeout, function(): boolean
            local values = fixture.runLua(app, [[
                local gfx = require("tecs2d.gfx")
                return world.resources[gfx.PIPELINE].screenWidth
            ]])
            if tonumber(values[1]) == 320 then return true end
            return nil
        end)
        luassert.is_true(resized == true, "pipeline never returned to 320x240")
        waitMarkerVisible(app, "after shrinking to 320x240")
    end)
end)
