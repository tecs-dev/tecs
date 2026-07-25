--- Love integration suite: oversized Tiled tileset atlases automatically
--- bypass the TileChunk texture arrays and render through the direct
--- SpriteBatch fallback. The test loads an actual .tmj plus external .tsj,
--- checks asymmetric-tile flips, and exercises the runtime dirty rebuild.
---
--- Run via `make test-love FILE_MATCH='tiled_oversized'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("tecs2d.testing.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"
local W <const> = 320.0
local H <const> = 240.0
local MAP_X <const> = 100
local MAP_Y <const> = 100
local FLIP_H <const> = 2147483648
local FIRST_GID <const> = 101

local function probe(app: fixture.App, x: number, y: number): {number}
    return fixture.probePixels(app, {{x / W, y / H}})[1]
end

local function waitPixel(
    app: fixture.App,
    x: number,
    y: number,
    check: function({number}): boolean,
    label: string
)
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        if check(probe(app, x, y)) then return true end
        return nil
    end)
    local p = probe(app, x, y)
    luassert.is_true(ok == true, string.format(
        "%s: got (%.2f, %.2f, %.2f)", label, p[1], p[2], p[3]))
end

local function isRed(p: {number}): boolean
    return p[1] > 0.8 and p[2] < 0.2 and p[3] < 0.2
end

local function isGreen(p: {number}): boolean
    return p[2] > 0.8 and p[1] < 0.2 and p[3] < 0.2
end

local function isBlue(p: {number}): boolean
    return p[3] > 0.8 and p[1] < 0.2 and p[2] < 0.2
end

describe("tiled: oversized tileset fallback", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, string.format([[
            local json = require("tecs.utils.json")
            love.filesystem.createDirectory("assets")
            love.filesystem.remove("assets/toversized_ts.png")
            love.filesystem.remove("assets/toversized_ts.tsj")
            love.filesystem.remove("assets/toversized_map.tmj")

            -- Width 2050 deliberately exceeds the TileChunk array tier.
            -- Tile 1 has red/blue halves; tile 2 is solid green. The
            -- transparent remainder makes the source atlas genuinely
            -- oversized without bloating the fixture.
            local img = love.image.newImageData(2050, 16)
            for y = 0, 15 do
                for x = 0, 7 do img:setPixel(x, y, 1, 0, 0, 1) end
                for x = 8, 15 do img:setPixel(x, y, 0, 0, 1, 1) end
                for x = 16, 31 do img:setPixel(x, y, 0, 1, 0, 1) end
            end
            love.filesystem.write("assets/toversized_ts.png", img:encode("png"))

            love.filesystem.write("assets/toversized_ts.tsj", json.serialize({
                name = "toversized",
                tilewidth = 16,
                tileheight = 16,
                tilecount = 128,
                columns = 128,
                image = "toversized_ts.png",
                imagewidth = 2050,
                imageheight = 16,
                margin = 0,
                spacing = 0,
                tiles = {{
                    id = 2,
                    animation = {
                        {tileid = 0, duration = 200},
                        {tileid = 1, duration = 200},
                    },
                }},
            }))

            love.filesystem.write("assets/toversized_map.tmj", json.serialize({
                width = 4,
                height = 1,
                tilewidth = 16,
                tileheight = 16,
                orientation = "orthogonal",
                renderorder = "right-down",
                infinite = false,
                tilesets = {{firstgid = %d, source = "toversized_ts.tsj"}},
                layers = {{
                    type = "tilelayer",
                    name = "ground",
                    visible = true,
                    opacity = 1,
                    width = 4,
                    height = 1,
                    x = 0,
                    y = 0,
                    data = {%d, %d, %d, %d},
                }},
            }))

            local tecs = require("tecs")
            local tiled = require("tecs2d.tiled")
            _G.tecsOversizedMap = world:spawn(
                tiled.Tilemap.new({path = "toversized_map.tmj"}),
                tecs.builtins.Transform(%d, %d, 0, 1))
            return true
        ]],
            FIRST_GID,
            FIRST_GID,
            FLIP_H + FIRST_GID,
            FIRST_GID + 1,
            FIRST_GID + 2,
            MAP_X,
            MAP_Y
        ))
    end)

    teardown(function()
        if app then
            pcall(function()
                fixture.runLua(app, [[
                    love.filesystem.remove("assets/toversized_ts.png")
                    love.filesystem.remove("assets/toversized_ts.tsj")
                    love.filesystem.remove("assets/toversized_map.tmj")
                    return true
                ]])
            end)
            fixture.stop(app)
        end
    end)

    it("automatically tags and renders an oversized tileset", function()
        waitPixel(app, MAP_X + 4, MAP_Y + 8, isRed,
            "unflipped tile left half should be red")
        waitPixel(app, MAP_X + 12, MAP_Y + 8, isBlue,
            "unflipped tile right half should be blue")

        local values = fixture.runLua(app, [[
            local tiled = require("tecs2d.tiled")
            local internal = require("tecs2d.gfx.internal.tilechunk")
            local map = world:get(_G.tecsOversizedMap, tiled.Tilemap).data
            local chunkId = map.layers[1]._chunkEntities[1]
            local imageWidth = map.tilesets[1].image:getWidth()
            return tostring(imageWidth), tostring(world:has(
                chunkId, internal.DirectTileChunk))
        ]])
        luassert.equals("2050", values[1])
        luassert.equals("true", values[2],
            "Tiled should route the oversized atlas through DirectTileChunk")
    end)

    it("preserves horizontal tile flips", function()
        waitPixel(app, MAP_X + 16 + 4, MAP_Y + 8, isBlue,
            "flipped tile left half should be blue")
        waitPixel(app, MAP_X + 16 + 12, MAP_Y + 8, isRed,
            "flipped tile right half should be red")
    end)

    it("rebuilds its SpriteBatch after a runtime tile edit", function()
        waitPixel(app, MAP_X + 4, MAP_Y + 8, isRed,
            "tile should render before its runtime edit")
        fixture.runLua(app, [[
            local tiled = require("tecs2d.tiled")
            local map = world:get(_G.tecsOversizedMap, tiled.Tilemap).data
            map:setTile(1, 1, 1, 102)
            return true
        ]])
        waitPixel(app, MAP_X + 8, MAP_Y + 8, isGreen,
            "edited tile should turn green")
    end)

    it("compacts animated frames from the oversized atlas", function()
        local animatedX <const> = MAP_X + 3 * 16
        waitPixel(app, animatedX + 4, MAP_Y + 8, isRed,
            "oversized-atlas animation should render its red frame")
        waitPixel(app, animatedX + 8, MAP_Y + 8, isGreen,
            "oversized-atlas animation should advance to its green frame")

        local values = fixture.runLua(app, [[
            local tiled = require("tecs2d.tiled")
            local gfx = require("tecs2d.gfx")
            local instances = require("tecs2d.gfx.internal.sprite.instance")
            local map = world:get(_G.tecsOversizedMap, tiled.Tilemap).data
            local spriteId = map.layers[1]._animatedSpriteEntities[1]
            local sprite = world:get(spriteId, gfx.Sprite)
            local sheet = instances.getSheet(sprite:getInstance())
            local width, height = sheet:getSheetSize()
            return tostring(width), tostring(height)
        ]])
        luassert.equals("32", values[1])
        luassert.equals("16", values[2],
            "animation frames should be copied into a compact SpriteSheet")
    end)
end)
