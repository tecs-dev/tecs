--- Love2D integration suite: tiled features beyond basic rendering.
---   - D+H flip combinations on animated tiles must match Tiled's
---     "rotate 90 degrees clockwise" semantics
---   - external .tsj tilesets must resolve their image relative to the
---     .tsj file's directory, not the map's
---
--- Run via `make test-love FILE_MATCH='tiled_features'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/compliance"

local function classify(p: {number}): string
    if p[1] > 0.7 and p[3] < 0.3 then return "red" end
    if p[3] > 0.7 and p[1] < 0.3 then return "blue" end
    if p[2] > 0.7 and p[1] < 0.3 and p[3] < 0.3 then return "green" end
    return "none"
end

local function expectColor(app: fixture.App, fx: number, fy: number, color: string, what: string)
    local seen: string = nil
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        seen = classify(fixture.probePixels(app, {{fx, fy}})[1])
        if seen == color then return true end
        return nil
    end)
    luassert.is_true(ok == true,
        what .. ": expected " .. color .. ", got " .. tostring(seen))
end

describe("tiled features: flips and external tilesets", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("renders D+H flipped animated tiles rotated 90 degrees clockwise", function()
        -- Tile image: left half red, right half blue. Rotated 90 degrees
        -- clockwise (Tiled's D+H), the left edge becomes the top edge.
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local tiled = require("tecs.tiled")
            local Transform = tecs.builtins.Transform

            local mapData = {
                width = 1, height = 1,
                tilewidth = 16, tileheight = 16,
                layers = {{
                    type = "tilelayer", name = "t", visible = true, opacity = 1,
                    width = 1, height = 1,
                    -- gid 1 with H (0x80000000) and D (0x20000000) flags
                    data = {1 + 0x80000000 + 0x20000000},
                }},
                tilesets = {{
                    firstgid = 1, name = "flip",
                    tilewidth = 16, tileheight = 16,
                    tilecount = 1, columns = 1,
                    image = "inline", imagewidth = 16, imageheight = 16,
                    -- Single-frame animation forces the sprite path, which
                    -- is where CPU-side flip decoding happens.
                    tiles = {{id = 0, animation = {{tileid = 0, duration = 100000}}}},
                }},
            }
            local map = tiled.parseTiledMap(mapData)
            local d = love.image.newImageData(16, 16)
            for y = 0, 15 do
                for x = 0, 15 do
                    if x < 8 then d:setPixel(x, y, 1, 0, 0, 1)
                    else d:setPixel(x, y, 0, 0, 1, 1) end
                end
            end
            local image = love.graphics.newImage(d)
            image:setFilter("nearest", "nearest")
            map.tilesets[1].image = image
            world:spawn(
                tiled.Tilemap.new({data = map}),
                Transform(100, 100, 0, 1))
            return true
        ]])
        expectColor(app, 108 / 320, 103 / 240, "red", "top of D+H tile")
        expectColor(app, 108 / 320, 113 / 240, "blue", "bottom of D+H tile")
    end)

    it("resolves external tileset images relative to the .tsj directory", function()
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local tiled = require("tecs.tiled")
            local Transform = tecs.builtins.Transform

            love.filesystem.createDirectory("assets/maps")
            love.filesystem.createDirectory("assets/tilesets")

            local d = love.image.newImageData(16, 16)
            for y = 0, 15 do
                for x = 0, 15 do
                    d:setPixel(x, y, 0, 1, 0, 1)
                end
            end
            love.filesystem.write("assets/tilesets/terrain.png", d:encode("png"))
            love.filesystem.write("assets/tilesets/terrain.tsj", [=[{
                "name": "terrain", "tilewidth": 16, "tileheight": 16,
                "tilecount": 1, "columns": 1,
                "image": "terrain.png", "imagewidth": 16, "imageheight": 16
            }]=])
            love.filesystem.write("assets/maps/level.tmj", [=[{
                "width": 2, "height": 1, "tilewidth": 16, "tileheight": 16,
                "layers": [{
                    "type": "tilelayer", "name": "ground", "visible": true,
                    "opacity": 1, "width": 2, "height": 1, "data": [1, 1]
                }],
                "tilesets": [{"firstgid": 1, "source": "../tilesets/terrain.tsj"}]
            }]=])

            world:spawn(
                tiled.Tilemap.new({path = "maps/level.tmj"}),
                Transform(150, 150, 0, 1))
            return true
        ]])
        expectColor(app, 158 / 320, 158 / 240, "green", "external tileset tile")
    end)
end)
