--- Shared floor utilities for demos
--- Provides a checkered or solid floor as a single entity

local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")

local Transform <const> = tecs.builtins.Transform
local Rectangle <const> = gfx.Rectangle
local Color <const> = gfx.Color
local Sprite <const> = gfx.Sprite
local RepeatedSprite <const> = gfx.RepeatedSprite

local record floor
    record Options
        worldWidth: number
        worldHeight: number
        tileSize: number
        layer: integer
        offsetX: number
        offsetY: number
        darkColor: {number, number, number, number}
        lightColor: {number, number, number, number}
    end
end

local DEFAULT_TILE_SIZE <const> = 64
local DEFAULT_LIGHT_GREEN <const> = {0.12, 0.25, 0.10, 1.0}

-- Cached checkered texture
local cachedTexture: love.graphics.Image = nil

--- Spawn a solid color floor (single Rectangle entity)
--- @param world tecs.World The ECS world
--- @param options floor.Options Configuration options
function floor.spawnSolid(world: tecs.World, options: floor.Options)
    local worldWidth = options.worldWidth
    local worldHeight = options.worldHeight
    local layer = options.layer or 1
    local color = options.lightColor or DEFAULT_LIGHT_GREEN

    world:spawn(
        Transform(worldWidth / 2, worldHeight / 2, -1, layer),
        Rectangle(worldWidth, worldHeight),
        Color(color[1], color[2], color[3], color[4])
    )
end

--- Spawn a checkered floor pattern using RepeatedSprite for efficient GPU tiling.
--- Uses a single entity regardless of floor size.
--- @param world tecs.World The ECS world
--- @param options floor.Options Configuration options
function floor.spawnCheckered(world: tecs.World, options: floor.Options)
    local worldWidth = options.worldWidth
    local worldHeight = options.worldHeight
    local tileSize = options.tileSize or DEFAULT_TILE_SIZE
    local layer = options.layer or 1
    local offsetX = options.offsetX or 0
    local offsetY = options.offsetY or 0

    -- Load checkered texture asset (cached)
    local texturePath <const> = "assets/checkered_green.png"
    if not cachedTexture then
        cachedTexture = love.graphics.newImage(texturePath)
        cachedTexture:setFilter("nearest", "nearest")
        cachedTexture:setWrap("repeat", "repeat")
    end

    -- Create sprite from texture. Passing `path` lets the sprite round-trip
    -- through snapshot save/load; without it the snapshot has no durable
    -- reference to the texture and drops the component on load.
    local sprite = Sprite.fromTexture(cachedTexture as love.graphics.Texture, {
        centered = false,
        pivotX = 0,
        pivotY = 0,
        path = texturePath,
    })

    -- Calculate scale to make sprite render at tileSize * 2 (one 2x2 checker pattern)
    local texW, texH = sprite:getDimensions()
    local targetSize = tileSize * 2
    local scaleX = targetSize / texW
    local scaleY = targetSize / texH

    -- Spawn floor entity with RepeatedSprite for GPU tiling.
    -- RepeatedSprite width/height is in sprite-local units (before Transform scale),
    -- so divide by scale to get the correct world-space coverage.
    world:spawn(
        Transform(offsetX, offsetY, -1, layer, 0, scaleX, scaleY),
        sprite,
        RepeatedSprite.new({
            repeatX = true,
            repeatY = true,
            width = worldWidth / scaleX,
            height = worldHeight / scaleY,
        })
    )
end

return floor
