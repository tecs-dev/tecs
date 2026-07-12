--- Love2D integration suite: snapshot save/load round-trip in a live
--- app. Builds a scene, saves a snapshot to the LOVE save directory,
--- mutates the world (recolor, despawn, extra spawn), then restores and
--- verifies both entity state and rendered pixels return to the saved
--- scene. Covers component serialize/deserialize, clear-before-load,
--- and the GPU resync after a restore.
---
--- Run via `make test-love FILE_MATCH='snapshot_roundtrip'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local SNAPSHOT_FILE <const> = "tecs_test_snapshot_roundtrip.json"

local W <const> = 320.0
local H <const> = 240.0

-- Scene layout: red rect at (80, 120), green circle at (240, 120);
-- the mutation phase adds a magenta rect at (160, 60).
local RECT_PROBE <const> = {80 / W, 120 / H}
local CIRCLE_PROBE <const> = {240 / W, 120 / H}
local EXTRA_PROBE <const> = {160 / W, 60 / H}

local function waitScene(app: fixture.App, check: function({{number}}): boolean, label: string)
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        local pixels = fixture.probePixels(app, {RECT_PROBE, CIRCLE_PROBE, EXTRA_PROBE})
        if check(pixels) then return true end
        return nil
    end)
    local pixels = fixture.probePixels(app, {RECT_PROBE, CIRCLE_PROBE, EXTRA_PROBE})
    luassert.is_true(ok == true, string.format(
        "%s: rect=(%.2f,%.2f,%.2f) circle=(%.2f,%.2f,%.2f) extra=(%.2f,%.2f,%.2f)",
        label,
        pixels[1][1], pixels[1][2], pixels[1][3],
        pixels[2][1], pixels[2][2], pixels[2][3],
        pixels[3][1], pixels[3][2], pixels[3][3]))
end

local function savedScene(pixels: {{number}}): boolean
    local rect, circle, extra = pixels[1], pixels[2], pixels[3]
    return rect[1] > 0.8 and rect[2] < 0.2          -- red rect
        and circle[2] > 0.8 and circle[1] < 0.2     -- green circle
        and extra[1] < 0.1 and extra[3] < 0.1       -- nothing at the extra slot
end

describe("snapshot round-trip: world and pixels restore", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, string.format([[
            love.filesystem.remove(%q)
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            _G.tecsSnapRect = world:spawn(
                Transform(80, 120, 0, 1), gfx.Rectangle(30, 30), gfx.Color(1, 0, 0, 1))
            _G.tecsSnapCircle = world:spawn(
                Transform(240, 120, 0, 1), gfx.Circle(15), gfx.Color(0, 1, 0, 1))
            return true
        ]], SNAPSHOT_FILE))
        waitScene(app, savedScene, "initial scene never rendered")
    end)

    teardown(function()
        if app then
            pcall(function()
                fixture.runLua(app, string.format("love.filesystem.remove(%q) return true", SNAPSHOT_FILE))
            end)
        end
        fixture.stop(app)
    end)

    it("saves a snapshot to the save directory", function()
        local result = app.client:call("cmd_snapshot_save", {
            format = "json",
            name = SNAPSHOT_FILE,
        })
        luassert.is_string(result.path as string, "cmd_snapshot_save returned no path")
        luassert.is_true(tonumber(result.number) >= 1, "cmd_snapshot_save returned no number")
    end)

    it("mutations change the world after the save", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            -- Recolor the rect blue, drop the circle, add an extra shape.
            local color = world:getMut(_G.tecsSnapRect, gfx.Color)
            color.r, color.g, color.b = 0, 0, 1
            world:despawn(_G.tecsSnapCircle)
            world:spawn(Transform(160, 60, 0, 1), gfx.Rectangle(30, 30), gfx.Color(1, 0, 1, 1))
            return true
        ]])
        waitScene(app, function(pixels: {{number}}): boolean
            local rect, circle, extra = pixels[1], pixels[2], pixels[3]
            return rect[3] > 0.8 and rect[1] < 0.2      -- rect now blue
                and circle[2] < 0.1                     -- circle gone
                and extra[1] > 0.8 and extra[3] > 0.8   -- magenta extra present
        end, "mutated scene never rendered")
    end)

    it("loading the snapshot restores entities and pixels", function()
        app.client:call("cmd_snapshot_load", {
            format = "json",
            ref = SNAPSHOT_FILE,
        })
        -- The saved scene: red rect back, green circle back, extra gone
        -- (load clears the world first).
        waitScene(app, savedScene, "restored scene never rendered")

        local values = fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform
            local rects, circles = 0, 0
            local q = world:query({include = {Transform, gfx.Rectangle}})
            for _, len in q:iter() do rects = rects + len end
            local q2 = world:query({include = {Transform, gfx.Circle}})
            for _, len in q2:iter() do circles = circles + len end
            return rects, circles
        ]])
        luassert.equals("1", values[1], "expected exactly one rectangle after restore")
        luassert.equals("1", values[2], "expected exactly one circle after restore")
    end)
end)
