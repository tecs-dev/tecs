require("busted")

local luassert <const> = require("luassert")
local parser <const> = require("tecs2d.tiled.internal.parser")
local json <const> = require("tecs.utils.json")

local function minimalMap(layerData: any, encoding?: string): {string: any}
    local layer: {string: any} = {
        type = "tilelayer",
        name = "ground",
        visible = true,
        opacity = 1,
        width = 2,
        height = 2,
        data = layerData,
    }
    if encoding then
        layer.encoding = encoding
    end
    return {
        width = 2,
        height = 2,
        tilewidth = 16,
        tileheight = 16,
        layers = {layer},
        tilesets = {},
    }
end

describe("tiled parser", function()
    it("parses raw array tile data", function()
        local map = parser.parseTiledMap(minimalMap({1, 2, 3, 0}))
        local layer = map.layers[1]
        luassert.equals(1, layer.data[0])
        luassert.equals(2, layer.data[1])
        luassert.equals(3, layer.data[2])
        luassert.equals(0, layer.data[3])
    end)

    it("treats csv-encoded array data as a raw array", function()
        -- Tiled's JSON export declares encoding "csv" but stores a plain
        -- JSON array; string CSV only exists in the TMX format.
        local map = parser.parseTiledMap(minimalMap({4, 5, 6, 7}, "csv"))
        local layer = map.layers[1]
        luassert.equals(4, layer.data[0])
        luassert.equals(7, layer.data[3])
    end)

    it("parses string csv tile data", function()
        local map = parser.parseTiledMap(minimalMap("8,9,10,11", "csv"))
        local layer = map.layers[1]
        luassert.equals(8, layer.data[0])
        luassert.equals(11, layer.data[3])
    end)

    it("rejects string csv data with the wrong entry count", function()
        luassert.has_error(function()
            parser.parseTiledMap(minimalMap("1,2,3", "csv"))
        end)
        luassert.has_error(function()
            parser.parseTiledMap(minimalMap("1,2,3,4,5", "csv"))
        end)
    end)

    it("rejects raw array data with the wrong entry count", function()
        luassert.has_error(function()
            parser.parseTiledMap(minimalMap({1, 2, 3}))
        end)
    end)

    it("rejects tile layers without data", function()
        luassert.has_error(function()
            parser.parseTiledMap(minimalMap(nil))
        end)
    end)

    it("rejects infinite maps with a clear error", function()
        local data = minimalMap({1, 2, 3, 0})
        data.infinite = true
        local ok, err = pcall(function()
            parser.parseTiledMap(data)
        end)
        luassert.is_false(ok)
        luassert.matches("infinite maps are not supported", tostring(err))
    end)

    it("serializes tile layers to valid JSON with plain GID arrays", function()
        local map = parser.parseTiledMap(minimalMap({1, 2, 3, 0}))
        local out = map:toJSON()
        local decoded = json.parse(out) as {string: any}
        local layers = decoded.layers as {{string: any}}
        local layerData = layers[1].data as {integer}
        luassert.same({1, 2, 3, 0}, layerData)
    end)
end)
