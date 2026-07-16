--- Love2D integration suite: retro-mode camera screen mapping. In
--- integer-scaled pixelMode, cam:toScreen must land on the pixel where
--- content actually renders (integer upscale + letterbox), not the
--- fractional screenHeight/virtualHeight mapping.
---
--- Fixture: 320x250 window, virtual 80x60 at 4x (letterboxed 5 px top and
--- bottom), camera at (40, 30), green 2x2 marker at world (75, 55).
--- Expected screen center of the marker: (160 + 35*4, 125 + 25*4) =
--- (300, 225). The fractional mapping puts toScreen ~6 px off, past the
--- marker's edge.
---
--- Run via `make test-love FILE_MATCH='retro_camera'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/retro"

local SCREEN_W <const> = 320.0
local SCREEN_H <const> = 250.0
local MARKER_X <const> = 300.0  -- 160 + 35 * 4
local MARKER_Y <const> = 225.0  -- 125 + 25 * 4

local function isGreen(p: {number}): boolean
    return p[2] > 0.9 and p[1] < 0.1 and p[3] < 0.1
end

describe("retro camera: toScreen matches rendered positions", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("renders the marker at the integer-scaled position", function()
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            local p = fixture.probePixels(app, {{MARKER_X / SCREEN_W, MARKER_Y / SCREEN_H}})[1]
            if isGreen(p) then return true end
            return nil
        end)
        luassert.is_true(ok == true, "marker not at the expected integer-scaled screen position")
    end)

    it("cmd_screenshot captures at virtual scale by default", function()
        -- The window (320x250) is a scale-up of the 80x60 virtual space;
        -- captures default to virtual scale so readers pay for the game's
        -- actual pixels, not the blowup. full=true keeps the native size.
        local png_util = require("tecs2d.testing.png_util")
        local function shotHeight(args: {string: any}): integer
            local res = app.client:call("cmd_screenshot", args)
            local fullPath = res.full as string
            local h = fixture.eventually(fixture.callTimeout, function(): integer
                local fh = io.open(fullPath, "rb")
                if not fh then return nil end
                local bytes = fh:read("*a")
                fh:close()
                local hdr = png_util.parseHeader(bytes)
                if hdr then return hdr.height end
                return nil
            end)
            luassert.is_not_nil(h, "screenshot never appeared at " .. tostring(fullPath))
            return h
        end
        luassert.are.equal(60, shotHeight({name = "virt-default.png"}))
        luassert.are.equal(250, shotHeight({name = "virt-native.png", full = true}))
    end)

    it("toScreen agrees with the rendered position", function()
        local values = fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            local pipeline = world.resources[gfx.PIPELINE]
            local sx, sy = pipeline:getCamera():toScreen(75, 55)
            return sx, sy
        ]])
        local sx = tonumber(values[1])
        local sy = tonumber(values[2])
        luassert.is_true(math.abs(sx - MARKER_X) < 1.5,
            "toScreen x off by " .. tostring(sx - MARKER_X) .. " px")
        luassert.is_true(math.abs(sy - MARKER_Y) < 1.5,
            "toScreen y off by " .. tostring(sy - MARKER_Y) .. " px")

        -- The probed pixel at toScreen must be the marker itself.
        local p = fixture.probePixels(app, {{sx / SCREEN_W, sy / SCREEN_H}})[1]
        luassert.is_true(isGreen(p),
            "pixel at toScreen(75, 55) is not the marker (toScreen: "
            .. tostring(sx) .. ", " .. tostring(sy) .. ")")
    end)

    it("toWorld inverts toScreen", function()
        local values = fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            local cam = world.resources[gfx.PIPELINE]:getCamera()
            local sx, sy = cam:toScreen(75, 55)
            local wx, wy = cam:toWorld(sx, sy)
            return wx, wy
        ]])
        luassert.is_true(math.abs(tonumber(values[1]) - 75) < 0.01, "toWorld x: " .. values[1])
        luassert.is_true(math.abs(tonumber(values[2]) - 55) < 0.01, "toWorld y: " .. values[2])
    end)
end)
