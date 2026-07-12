--- Love2D integration suite: camera math consistency. A marker entity at
--- a known world position is probed at the screen position the camera's
--- own toScreen reports, across position, zoom, and rotation changes.
--- This ties the CPU camera transform (Camera.tl / shared ortho) to what
--- the GPU cull + render actually put on screen; divergence between the
--- two is the regression class this suite guards (e.g. tile-cull zoom,
--- Y-flip mismatches).
---
--- Run via `make test-love FILE_MATCH='camera_behaviors'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local W <const> = 320.0
local H <const> = 240.0

-- Marker: red 12x12 rect at world (200, 120).
local MARKER_X <const> = 200
local MARKER_Y <const> = 120

--- Ask the app where the camera maps the marker, then wait until that
--- screen pixel reads red.
local function waitMarkerAtToScreen(app: fixture.App, label: string)
    local values = fixture.runLua(app, string.format([[
        local gfx = require("tecs2d.gfx")
        local cam = world.resources[gfx.PIPELINE]:getCamera()
        local sx, sy = cam:toScreen(%d, %d)
        return sx, sy
    ]], MARKER_X, MARKER_Y))
    local sx = tonumber(values[1])
    local sy = tonumber(values[2])
    luassert.is_number(sx, label .. ": toScreen returned no x")
    luassert.is_number(sy, label .. ": toScreen returned no y")
    luassert.is_true(sx > 1 and sx < W - 1 and sy > 1 and sy < H - 1,
        string.format("%s: toScreen put the marker off screen (%.1f, %.1f)", label, sx, sy))

    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        local p = fixture.probePixels(app, {{sx / W, sy / H}})[1]
        if p[1] > 0.8 and p[2] < 0.2 then return true end
        return nil
    end)
    local p = fixture.probePixels(app, {{sx / W, sy / H}})[1]
    luassert.is_true(ok == true, string.format(
        "%s: marker not red at toScreen (%.1f, %.1f); pixel = (%.2f, %.2f, %.2f)",
        label, sx, sy, p[1], p[2], p[3]))
end

describe("camera behaviors: toScreen matches the rendered frame", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, string.format([[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            world:spawn(Transform(%d, %d, 0, 1), gfx.Rectangle(12, 12), gfx.Color(1, 0, 0, 1))
            return true
        ]], MARKER_X, MARKER_Y))
    end)

    teardown(function()
        fixture.stop(app)
    end)

    local function setCamera(x: number, y: number, zoom: number, rotation: number)
        fixture.runLua(app, string.format([[
            local gfx = require("tecs2d.gfx")
            local cam = world.resources[gfx.PIPELINE]:getCamera()
            cam:setPosition(%f, %f)
            cam:setZoom(%f)
            cam:setRotation(%f)
            return true
        ]], x, y, zoom, rotation))
    end

    it("toWorld inverts toScreen", function()
        local values = fixture.runLua(app, string.format([[
            local gfx = require("tecs2d.gfx")
            local cam = world.resources[gfx.PIPELINE]:getCamera()
            local sx, sy = cam:toScreen(%d, %d)
            local wx, wy = cam:toWorld(sx, sy)
            return wx, wy
        ]], MARKER_X, MARKER_Y))
        local wx = tonumber(values[1])
        local wy = tonumber(values[2])
        luassert.is_true(math.abs(wx - MARKER_X) < 0.5 and math.abs(wy - MARKER_Y) < 0.5,
            string.format("toWorld(toScreen(p)) drifted to (%.2f, %.2f)", wx, wy))
    end)

    it("renders the marker at toScreen under the default camera", function()
        waitMarkerAtToScreen(app, "default camera")
    end)

    it("keeps the marker at toScreen after a camera move", function()
        setCamera(MARKER_X, MARKER_Y, 1.0, 0.0)
        waitMarkerAtToScreen(app, "camera centered on marker")
        -- Centered camera: the marker should sit mid-screen.
        local p = fixture.probePixels(app, {{0.5, 0.5}})[1]
        luassert.is_true(p[1] > 0.8 and p[2] < 0.2,
            string.format("marker not at screen center; pixel = (%.2f, %.2f, %.2f)", p[1], p[2], p[3]))
    end)

    it("keeps the marker at toScreen under zoom", function()
        setCamera(160, 120, 2.0, 0.0)
        waitMarkerAtToScreen(app, "zoom 2.0")
        setCamera(160, 120, 0.5, 0.0)
        waitMarkerAtToScreen(app, "zoom 0.5")
    end)

    it("keeps the marker at toScreen under rotation", function()
        setCamera(160, 120, 1.0, math.pi / 6)
        waitMarkerAtToScreen(app, "rotation 30 degrees")
        setCamera(160, 120, 1.0, math.pi / 2)
        waitMarkerAtToScreen(app, "rotation 90 degrees")
    end)

    it("keeps the marker at toScreen under combined zoom, rotation, and offset", function()
        setCamera(180, 100, 1.5, -math.pi / 4)
        waitMarkerAtToScreen(app, "combined transform")
        setCamera(160, 120, 1.0, 0.0)
    end)
end)
