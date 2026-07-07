require("busted")

local luassert <const> = require("luassert")
local tileset <const> = require("tecs2d.tiled.internal.tileset")
local animation <const> = require("tecs2d.tiled.internal.animation")
local types <const> = require("tecs2d.tiled.types")

describe("tiled animations", function()
    it("skips zero-duration animations instead of hanging", function()
        local ts: types.TilesetData = {
            firstgid = 1, name = "t",
            tilewidth = 16, tileheight = 16, tilecount = 2, columns = 2,
            tiles = {
                [0] = {id = 0, animation = {
                    {tileid = 0, duration = 0},
                    {tileid = 1, duration = 0},
                }},
                [1] = {id = 1, animation = {
                    {tileid = 0, duration = 100},
                    {tileid = 1, duration = 100},
                }},
            },
        } as types.TilesetData

        tileset.initializeAnimationStates(ts)
        luassert.is_nil(ts._animationStates[0], "zero-duration animation got a state")
        luassert.is_table(ts._animationStates[1], "valid animation missing its state")

        local map: types.TilemapData = {
            _animatedTilesets = {ts},
        } as types.TilemapData

        -- Pre-fix this loops forever on the zero-duration state; a
        -- completing call is the assertion. Durations are in Tiled's
        -- millisecond units, so 150 lands in the second frame.
        animation.updateAnimations(map, 150)
        luassert.are.equal(2, ts._animationStates[1].currentFrame)
    end)

    it("survives a hand-built zero-length state", function()
        local ts: types.TilesetData = {
            firstgid = 1, name = "t",
            tilewidth = 16, tileheight = 16, tilecount = 1, columns = 1,
            tiles = {[0] = {id = 0, animation = {{tileid = 0, duration = 0}}}},
            _animatedTiles = {0},
            _animationStates = {[0] = {totalTime = 0, time = 0, currentFrame = 1}},
        } as types.TilesetData
        local map: types.TilemapData = {
            _animatedTilesets = {ts},
        } as types.TilemapData
        animation.updateAnimations(map, 0.1)
        luassert.are.equal(1, ts._animationStates[0].currentFrame)
    end)
end)
