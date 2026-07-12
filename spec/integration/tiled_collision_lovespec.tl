--- Love2D integration suite: tilemap collision must follow the tilemap
--- entity's Transform. The fixture map renders at (200, 80) with a solid
--- floor row at world y 128..144; a ball dropped above it must come to
--- rest on the floor instead of falling through (which happens when the
--- collision bodies are built at the origin).
---
--- Run via `make test-love FILE_MATCH='tiled_collision'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/tiledphysics"

-- Floor tile probe: middle of the floor row at world (248, 136); the
-- camera maps world 1:1 to the 320x240 screen.
local FLOOR_PROBE <const> = {{248 / 320, 136 / 240}}

local function ballY(app: fixture.App): number
    local values = fixture.runLua(app, [[
        local tecs = require("tecs")
        local t = world:get(_G.tecsTestBall, tecs.builtins.Transform)
        return t.y
    ]])
    return tonumber(values[1])
end

describe("tiled collision: geometry follows the tilemap Transform", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("renders the floor at the transform-offset position", function()
        local ok = fixture.eventually(fixture.callTimeout, function(): boolean
            local p = fixture.probePixels(app, FLOOR_PROBE)[1]
            if p[2] > 0.9 and p[1] < 0.1 then return true end
            return nil
        end)
        luassert.is_true(ok == true, "floor tiles not rendered at the offset position")
    end)

    it("physics debug overlay draws on toggle and clears on re-toggle", function()
        -- The floor collider's top edge runs along world y=128. The debug
        -- overlay draws red outlines (default color r=1); the tile under
        -- it is green. Buffers allocate lazily on the first enabled frame,
        -- so this exercises that path end to end.
        local EDGE_PROBE = {{248 / 320, 128 / 240}}

        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            world:emit(0, gfx.PhysicsDebugToggle())
            return true
        ]])
        local drawn = fixture.eventually(fixture.callTimeout, function(): boolean
            local p = fixture.probePixels(app, EDGE_PROBE)[1]
            if p[1] > 0.8 then return true end
            return nil
        end)
        luassert.is_true(drawn == true, "debug overlay never drew the collider outline")

        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            world:emit(0, gfx.PhysicsDebugToggle())
            return true
        ]])
        local cleared = fixture.eventually(fixture.callTimeout, function(): boolean
            local p = fixture.probePixels(app, EDGE_PROBE)[1]
            if p[1] < 0.1 then return true end
            return nil
        end)
        luassert.is_true(cleared == true, "debug overlay did not clear after toggling off")
    end)

    it("debug map reports the tilemap and reads tiles at a point", function()
        local m = app.client:call("cmd_map", {})
        luassert.is_true(m.loaded as boolean, "tilemap should be loaded")
        luassert.is_true(tonumber(m.width) > 0)
        luassert.is_true(tonumber(m.tilewidth) > 0)
        luassert.is_true(#(m.layers as {any}) >= 1)

        -- A point on the floor row must report a tile layer with a gid.
        local mapX = tonumber(m.x)
        local mapY = tonumber(m.y)
        local tw = tonumber(m.tilewidth)
        local th = tonumber(m.tileheight)
        local floorY = mapY + (tonumber(m.height) - 1) * th + th / 2
        local info = app.client:call("cmd_map_info", {x = mapX + tw / 2, y = floorY})
        luassert.is_true(info.inside as boolean, "probe point must be inside the map")
        local sawGid = false
        for _, layer in ipairs(info.layers as {any}) do
            if tonumber((layer as {string: any}).gid) > 0 then sawGid = true end
        end
        luassert.is_true(sawGid, "floor tile should carry a gid on some layer")
        app.client:call("cmd_draw_clear", {tag = "tile"})
    end)

    it("drops the ball onto the floor instead of through it", function()
        -- Wait for the ball to settle: two consecutive samples nearly equal.
        local settled = fixture.eventually(8, function(): number
            local y1 = ballY(app)
            if y1 > 400 then return y1 end  -- clearly fell through; stop early
            local y2: number
            fixture.eventually(0.3, function(): boolean
                y2 = ballY(app)
                return nil
            end)
            if y2 ~= nil and math.abs(y2 - y1) < 0.5 then return y2 end
            return nil
        end)
        luassert.is_number(settled, "ball never settled")
        -- Resting on the floor: center at floor top (128) minus radius (8).
        luassert.is_true(settled < 128,
            "ball fell through the floor (settled y = " .. tostring(settled)
            .. ", floor top is 128)")
        luassert.is_true(settled > 110,
            "ball stopped implausibly high (settled y = " .. tostring(settled) .. ")")
    end)
end)
