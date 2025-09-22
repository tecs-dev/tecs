--- Procedural tileset generation for the tiled-collision example.
---
--- Creates a 4-tile tileset:
---   Tile 0: Grass floor
---   Tile 1: Wall (with collision)
---   Tile 2: Torch frame 1 (animated)
---   Tile 3: Torch frame 2 (animated)
--- We generate the tileset PNG at runtime to avoid committing binary files to git.

local lfs <const> = love.filesystem

local function generate()
    if lfs.getInfo("assets/tileset.png") then return end

    -- 4 tiles at 32x32 = 128x32 image
    local imageData = love.image.newImageData(128, 32)

    -- Tile 0: Green grass
    for py = 0, 31 do
        for px = 0, 31 do
            local v = (math.random() - 0.5) * 0.03
            imageData:setPixel(px, py, 0.1 + v, 0.22 + v, 0.1 + v, 1)
        end
    end

    -- Tile 1: Wall (gray stone with variation)
    for py = 0, 31 do
        for px = 0, 31 do
            local v = (math.random() - 0.5) * 0.1
            local base = 0.35 + v
            -- Add some brick-like pattern
            local brickX = px % 8 < 1
            local brickY = py % 8 < 1
            if brickX or brickY then
                base = base - 0.05
            end
            imageData:setPixel(32 + px, py, base, base * 0.95, base * 0.9, 1)
        end
    end

    -- Tile 2: Torch frame 1 (classic teardrop flame)
    for py = 0, 31 do
        for px = 0, 31 do
            -- Brown wooden handle (bottom half)
            if py >= 16 and py <= 28 and math.abs(px - 16) <= 2 then
                imageData:setPixel(64 + px, py, 0.55, 0.35, 0.15, 1)
            -- Teardrop flame shape (top half)
            elseif py >= 4 and py < 18 then
                local flameY = (py - 4) / 14  -- 0 at top, 1 at bottom of flame
                local maxWidth = 4 + flameY * 5  -- Wider at bottom, narrower at top
                local dx = math.abs(px - 16)
                if dx <= maxWidth then
                    local t = dx / maxWidth  -- 0 at center, 1 at edge
                    -- Yellow center, orange edge
                    local r = 1.0
                    local g = 0.9 - t * 0.4 - flameY * 0.2
                    local b = 0.2 - t * 0.15
                    imageData:setPixel(64 + px, py, r, g, b, 1)
                else
                    imageData:setPixel(64 + px, py, 0, 0, 0, 0)
                end
            else
                imageData:setPixel(64 + px, py, 0, 0, 0, 0)
            end
        end
    end

    -- Tile 3: Torch frame 2 (slightly different flame for animation)
    for py = 0, 31 do
        for px = 0, 31 do
            -- Brown wooden handle (bottom half)
            if py >= 16 and py <= 28 and math.abs(px - 16) <= 2 then
                imageData:setPixel(96 + px, py, 0.55, 0.35, 0.15, 1)
            -- Teardrop flame shape - slightly larger/offset
            elseif py >= 3 and py < 17 then
                local flameY = (py - 3) / 14
                local maxWidth = 5 + flameY * 5  -- Slightly wider flame
                local dx = math.abs(px - 16)
                if dx <= maxWidth then
                    local t = dx / maxWidth
                    local r = 1.0
                    local g = 0.85 - t * 0.35 - flameY * 0.25
                    local b = 0.15 - t * 0.1
                    imageData:setPixel(96 + px, py, r, g, b, 1)
                else
                    imageData:setPixel(96 + px, py, 0, 0, 0, 0)
                end
            else
                imageData:setPixel(96 + px, py, 0, 0, 0, 0)
            end
        end
    end

    lfs.createDirectory("assets")
    local fileData = imageData:encode("png") as love.Data
    lfs.write("assets/tileset.png", fileData:getString())
end

return generate
