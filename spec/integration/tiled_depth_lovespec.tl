--- Love2D integration suite: tiled parser depth. Loads a map that
--- references an external .tsj tileset (file resolution + late tileset
--- registration), renders a horizontally-flipped GID (flip flags ride
--- the high bits into the chunk SSBO and flip UVs on the GPU), and
--- asserts the documented rejection of infinite maps.
---
--- Run via `make test-love FILE_MATCH='tiled_depth'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local W <const> = 320.0
local H <const> = 240.0

-- Map spawned at (100, 100), 16px tiles. Tile 1 is asymmetric: left
-- half red, right half blue. Tile 2 is solid green.
local MAP_X <const> = 100
local MAP_Y <const> = 100
local FLIP_H <const> = 2147483648  -- 0x80000000

local function probe(app: fixture.App, x: number, y: number): {number}
    return fixture.probePixels(app, {{x / W, y / H}})[1]
end

describe("tiled depth: external tilesets, flips, infinite rejection", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, string.format([[
            local json = require("tecs.utils.json")
            -- The tiled loader resolves paths under the assets/ root;
            -- the save directory shadows the game directory for reads,
            -- so fixture files live in a save-dir assets/ folder.
            love.filesystem.createDirectory("assets")
            love.filesystem.remove("assets/tdepth_ts.png")
            love.filesystem.remove("assets/tdepth_ts.tsj")
            love.filesystem.remove("assets/tdepth_map.tmj")

            -- Tileset image: tile 1 = red|blue halves, tile 2 = green.
            local img = love.image.newImageData(32, 16)
            for y = 0, 15 do
                for x = 0, 7 do img:setPixel(x, y, 1, 0, 0, 1) end
                for x = 8, 15 do img:setPixel(x, y, 0, 0, 1, 1) end
                for x = 16, 31 do img:setPixel(x, y, 0, 1, 0, 1) end
            end
            love.filesystem.write("assets/tdepth_ts.png", img:encode("png"))

            love.filesystem.write("assets/tdepth_ts.tsj", json.serialize({
                name = "tdepth", tilewidth = 16, tileheight = 16,
                tilecount = 2, columns = 2,
                image = "tdepth_ts.png", imagewidth = 32, imageheight = 16,
                margin = 0, spacing = 0,
            }))

            love.filesystem.write("assets/tdepth_map.tmj", json.serialize({
                width = 3, height = 1, tilewidth = 16, tileheight = 16,
                orientation = "orthogonal", renderorder = "right-down",
                infinite = false,
                tilesets = {{firstgid = 1, source = "tdepth_ts.tsj"}},
                layers = {{
                    type = "tilelayer", name = "ground",
                    visible = true, opacity = 1,
                    width = 3, height = 1,
                    x = 0, y = 0,
                    data = {1, %d, 2},
                }},
            }))
            return true
        ]], FLIP_H + 1))

        fixture.runLua(app, string.format([[
            local tecs = require("tecs")
            local tiled = require("tecs.tiled")
            local Transform = tecs.builtins.Transform
            _G.tecsDepthMap = world:spawn(
                tiled.Tilemap.new({path = "tdepth_map.tmj"}),
                Transform(%d, %d, 0, 1))
            return true
        ]], MAP_X, MAP_Y))
    end)

    teardown(function()
        if app then
            pcall(function()
                fixture.runLua(app, [[
                    love.filesystem.remove("assets/tdepth_ts.png")
                    love.filesystem.remove("assets/tdepth_ts.tsj")
                    love.filesystem.remove("assets/tdepth_map.tmj")
                    return true
                ]])
            end)
        end
        fixture.stop(app)
    end)

    it("renders tiles from an external .tsj tileset", function()
        -- Third tile (gid 2, solid green) at grid (2, 0).
        local drawn = fixture.eventually(fixture.callTimeout, function(): boolean
            local p = probe(app, MAP_X + 2 * 16 + 8, MAP_Y + 8)
            if p[2] > 0.8 and p[1] < 0.2 then return true end
            return nil
        end)
        luassert.is_true(drawn == true, "external-tileset map never rendered")
    end)

    it("renders an unflipped asymmetric tile with red left, blue right", function()
        local p = probe(app, MAP_X + 4, MAP_Y + 8)
        luassert.is_true(p[1] > 0.8 and p[3] < 0.2, string.format(
            "tile 1 left half should be red, got (%.2f, %.2f, %.2f)", p[1], p[2], p[3]))
        p = probe(app, MAP_X + 12, MAP_Y + 8)
        luassert.is_true(p[3] > 0.8 and p[1] < 0.2, string.format(
            "tile 1 right half should be blue, got (%.2f, %.2f, %.2f)", p[1], p[2], p[3]))
    end)

    it("mirrors a horizontally-flipped GID", function()
        -- Second tile: gid 1 with the H-flip bit. Halves swap.
        local p = probe(app, MAP_X + 16 + 4, MAP_Y + 8)
        luassert.is_true(p[3] > 0.8 and p[1] < 0.2, string.format(
            "flipped tile left half should be blue, got (%.2f, %.2f, %.2f)", p[1], p[2], p[3]))
        p = probe(app, MAP_X + 16 + 12, MAP_Y + 8)
        luassert.is_true(p[1] > 0.8 and p[3] < 0.2, string.format(
            "flipped tile right half should be red, got (%.2f, %.2f, %.2f)", p[1], p[2], p[3]))
    end)

    it("rejects infinite maps with the documented error", function()
        local values = fixture.runLua(app, [[
            local tiled = require("tecs.tiled")
            local ok, err = pcall(function()
                tiled.parseTiledMap({
                    width = 2, height = 2, tilewidth = 16, tileheight = 16,
                    infinite = true,
                    layers = {}, tilesets = {},
                })
            end)
            return tostring(ok), tostring(err)
        ]])
        luassert.equals("false", values[1], "infinite map should be rejected")
        luassert.is_true(values[2]:find("infinite maps are not supported", 1, true) ~= nil,
            "rejection should carry the documented message, got: " .. tostring(values[2]))
    end)
end)
