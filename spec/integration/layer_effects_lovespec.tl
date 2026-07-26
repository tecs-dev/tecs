--- Love2D integration suite: layer-effect canvases must track the render
--- resolution. In pixelMode the effects pipeline renders at virtual
--- resolution; its canvases must be virtual-sized at startup and resize
--- when pixel mode toggles, or the frame gets clipped to a virtual-res
--- corner after setPixelMode(false).
---
--- Run via `make test-love FILE_MATCH='layer_effects'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/layereffects"

--- Probe points spread across the frame; the fixture fills the whole view
--- with green, so all of them must be green in every mode.
local PROBES <const> = {{0.1, 0.5}, {0.5, 0.5}, {0.9, 0.5}, {0.9, 0.9}}

local function allGreen(app: fixture.App): string
    local probes = fixture.probePixels(app, PROBES)
    for i, p in ipairs(probes) do
        if not (p[2] > 0.9 and p[1] < 0.1) then
            return string.format("probe %d (%.1f, %.1f) not green: r=%.2f g=%.2f b=%.2f",
                i, PROBES[i][1], PROBES[i][2], p[1], p[2], p[3])
        end
    end
    return nil
end

local function expectAllGreen(app: fixture.App, what: string)
    local failure: string
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        failure = allGreen(app)
        if failure == nil then return true end
        return nil
    end)
    luassert.is_true(ok == true, what .. ": " .. tostring(failure))
end

describe("layer effects: canvases track render resolution", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("creates effect canvases at the virtual resolution", function()
        local values = fixture.runLua(app, [[
            local gfx = require("tecs.gfx")
            local p = world.resources[gfx.PIPELINE]
            return p.layerEffectsManager.accumulator:getWidth(),
                p.layerEffectsManager.accumulator:getHeight(),
                p.scaledWidth, p.scaledHeight
        ]])
        luassert.are.equal(values[3], values[1],
            "accumulator width " .. values[1] .. " != render width " .. values[3])
        luassert.are.equal(values[4], values[2],
            "accumulator height " .. values[2] .. " != render height " .. values[4])
    end)

    it("renders the full frame in pixel mode", function()
        expectAllGreen(app, "initial retro frame")
    end)

    it("survives a window resize event", function()
        app.client:call("send_love_event", {event = "resize", args = {320, 240}})
        expectAllGreen(app, "after resize event")
    end)

    it("renders the full frame after setPixelMode(false)", function()
        fixture.runLua(app, [[
            local gfx = require("tecs.gfx")
            world.resources[gfx.PIPELINE]:setPixelMode(false)
            return true
        ]])
        expectAllGreen(app, "after setPixelMode(false)")
    end)

    it("renders the full frame after toggling pixel mode back on", function()
        fixture.runLua(app, [[
            local gfx = require("tecs.gfx")
            world.resources[gfx.PIPELINE]:setPixelMode(true)
            return true
        ]])
        expectAllGreen(app, "after setPixelMode(true)")
    end)
end)
