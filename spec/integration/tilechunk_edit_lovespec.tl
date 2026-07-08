--- Love2D integration suite: TileChunk rendering and runtime edits. A
--- chunk built from a procedural two-tile tileset (red, green) renders
--- its tile grid at the entity Transform; mutating the tiles array and
--- re-adding DirtyTileChunk must resync the GPU buffer (changed tile
--- recolors, cleared tile disappears). Covers the tilechunk SSBO slot
--- sync, texture-array registration, and the dirty-tag resync path.
---
--- Run via `make test-love FILE_MATCH='tilechunk_edit'`.

require("busted")
local luassert <const> = require("luassert")
local fixture <const> = require("spec.integration.harness.fixture")

local APP_DIR <const> = "build/test_deps/spec/integration/apps/shapes"

local W <const> = 320.0
local H <const> = 240.0

-- Chunk at (100, 100); 16px tiles. Tile grid (col, row) probes at the
-- tile centers.
local function tileCenter(col: integer, row: integer): {number}
    return {(100 + col * 16 + 8) / W, (100 + row * 16 + 8) / H}
end

local function waitTile(app: fixture.App, col: integer, row: integer,
        check: function({number}): boolean, label: string)
    local point = tileCenter(col, row)
    local ok = fixture.eventually(fixture.callTimeout, function(): boolean
        if check(fixture.probePixels(app, {point})[1]) then return true end
        return nil
    end)
    local p = fixture.probePixels(app, {point})[1]
    luassert.is_true(ok == true, string.format(
        "%s: tile (%d, %d) = (%.2f, %.2f, %.2f)", label, col, row, p[1], p[2], p[3]))
end

local function isRed(p: {number}): boolean return p[1] > 0.8 and p[2] < 0.2 end
local function isGreen(p: {number}): boolean return p[2] > 0.8 and p[1] < 0.2 end
local function isEmpty(p: {number}): boolean return p[1] < 0.1 and p[2] < 0.1 and p[3] < 0.1 end

describe("tilechunk: renders and resyncs edited tiles", function()
    local app: fixture.App

    setup(function()
        app = fixture.start(APP_DIR)
        fixture.runLua(app, [[
            local tecs = require("tecs")
            local gfx = require("tecs2d.gfx")
            local Transform = tecs.builtins.Transform

            -- Two-tile tileset: local id 1 = red, id 2 = green.
            local imgData = love.image.newImageData(32, 16)
            for y = 0, 15 do
                for x = 0, 15 do imgData:setPixel(x, y, 1, 0, 0, 1) end
                for x = 16, 31 do imgData:setPixel(x, y, 0, 1, 0, 1) end
            end
            local tileset = love.graphics.newImage(imgData)

            -- Sparse tiles table: the constructor must pad the holes
            -- with 0 without clobbering entries past them. Tiles 1 and
            -- 2 in the first row, tile 1 at grid (0, 1).
            local tiles = {}
            tiles[1] = 1
            tiles[2] = 2
            tiles[17] = 1
            _G.tecsChunk = world:spawn(
                Transform(100, 100, 0, 1),
                gfx.TileChunk.new({
                    tileset = tileset,
                    tileWidth = 16,
                    tileHeight = 16,
                    columns = 2,
                    tiles = tiles,
                }))
            return true
        ]])
    end)

    teardown(function()
        fixture.stop(app)
    end)

    it("renders the tile grid at the entity Transform", function()
        waitTile(app, 0, 0, isRed, "tile (0,0) should be red")
        waitTile(app, 1, 0, isGreen, "tile (1,0) should be green")
        waitTile(app, 0, 1, isRed, "tile (0,1) should be red")
        waitTile(app, 1, 1, isEmpty, "unset tile (1,1) should be empty")
    end)

    it("resyncs edited tiles when DirtyTileChunk is re-added", function()
        fixture.runLua(app, [[
            local gfx = require("tecs2d.gfx")
            local chunk = world:getMut(_G.tecsChunk, gfx.TileChunk)
            chunk.tiles[1] = 2      -- red -> green
            chunk.tiles[17] = 0     -- clear
            chunk.tiles[18] = 1     -- fill previously empty tile red
            world:set(_G.tecsChunk, gfx.DirtyTileChunk)
            return true
        ]])
        waitTile(app, 0, 0, isGreen, "edited tile (0,0) should turn green")
        waitTile(app, 0, 1, isEmpty, "cleared tile (0,1) should disappear")
        waitTile(app, 1, 1, isRed, "filled tile (1,1) should appear red")
    end)

    it("despawning the chunk clears all its tiles", function()
        fixture.runLua(app, "world:despawn(_G.tecsChunk) return true")
        waitTile(app, 0, 0, isEmpty, "despawned chunk should leave no tiles")
        waitTile(app, 1, 0, isEmpty, "despawned chunk should leave no tiles (1,0)")
    end)
end)
