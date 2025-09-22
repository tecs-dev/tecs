--- Tile animation system with global sync.
---
--- All tiles with the same animation definition share a single AnimationState,
--- so water tiles all animate in sync (classic tilemap behavior).

local types <const> = require("tecs2d.tiled.types")

local type TilemapData = types.TilemapData
local type TilesetData = types.TilesetData

local record animation
    --- Update all tile animations in a tilemap.
    --- @param map The tilemap data
    --- @param dt Delta time in seconds
    updateAnimations: function(map: TilemapData, dt: number)

    --- Get the current animation frame's local tile ID.
    --- @param tileset The tileset
    --- @param localId The base tile's local ID
    --- @return The local ID of the current animation frame, or the original if not animated
    getCurrentFrameTileId: function(tileset: TilesetData, localId: integer): integer
end

function animation.updateAnimations(map: TilemapData, dt: number)
    -- Only update tilesets that have animations
    local animatedTilesets <const> = map._animatedTilesets
    for i = 1, #animatedTilesets do
        local tileset = animatedTilesets[i]
        local animatedTiles <const> = tileset._animatedTiles
        for j = 1, #animatedTiles do
            local localId = animatedTiles[j]
            local state = tileset._animationStates[localId]
            if state then
                -- Advance time
                state.time = state.time + dt

                -- Loop animation
                while state.time >= state.totalTime do
                    state.time = state.time - state.totalTime
                end

                -- Update current frame by accumulating durations
                local tile = tileset.tiles[localId]
                if tile and tile.animation then
                    local elapsed: number = 0
                    local frames <const> = tile.animation
                    for frameIdx = 1, #frames do
                        elapsed = elapsed + frames[frameIdx].duration
                        if state.time < elapsed then
                            state.currentFrame = frameIdx
                            break
                        end
                    end
                end
            end
        end
    end
end

function animation.getCurrentFrameTileId(tileset: TilesetData, localId: integer): integer
    local tile = tileset.tiles[localId]
    if not tile or not tile.animation then
        return localId
    end

    local state = tileset._animationStates[localId]
    if not state then
        return localId
    end

    local frame = tile.animation[state.currentFrame]
    if frame then
        return frame.tileid
    end

    return localId
end

return animation
