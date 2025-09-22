--- Procedurally generated 16x16 pixel art icons for the audio demo.

local lg <const> = love.graphics

local record icons
    drum: love.graphics.Image
    guitar: love.graphics.Image
    keyboard: love.graphics.Image
    speaker: love.graphics.Image
    smiley: love.graphics.Image
end

local function setPixel(data: love.image.ImageData, x: integer, y: integer, r: number, g: number, b: number)
    if x >= 0 and x < 16 and y >= 0 and y < 16 then
        data:setPixel(x, y, r, g, b, 1)
    end
end

local function fillCircle(
    data: love.image.ImageData, cx: number, cy: number, radius: number, r: number, g: number, b: number
)
    for y = 0, 15 do
        for x = 0, 15 do
            local dx, dy = x - cx, y - cy
            if dx*dx + dy*dy <= radius*radius then
                setPixel(data, x, y, r, g, b)
            end
        end
    end
end

local function drawLine(
    data: love.image.ImageData, x1: integer, y1: integer, x2: integer, y2: integer, r: number, g: number, b: number
)
    local dx = math.abs(x2 - x1)
    local dy = math.abs(y2 - y1)
    local sx = x1 < x2 and 1 or -1
    local sy = y1 < y2 and 1 or -1
    local err = dx - dy

    while true do
        setPixel(data, x1, y1, r, g, b)
        if x1 == x2 and y1 == y2 then break end
        local e2 = 2 * err
        if e2 > -dy then err = err - dy; x1 = x1 + sx end
        if e2 < dx then err = err + dx; y1 = y1 + sy end
    end
end

local function fillRect(
    data: love.image.ImageData, x: integer, y: integer, w: integer, h: integer, r: number, g: number, b: number
)
    for py = y, y + h - 1 do
        for px = x, x + w - 1 do
            setPixel(data, px, py, r, g, b)
        end
    end
end

local function createDrumIcon(): love.graphics.Image
    local data = love.image.newImageData(16, 16)
    fillCircle(data, 7.5, 9, 6, 0.8, 0.3, 0.2)
    fillCircle(data, 7.5, 7, 5, 0.9, 0.8, 0.7)
    drawLine(data, 2, 2, 8, 8, 0.6, 0.4, 0.2)
    drawLine(data, 13, 2, 7, 8, 0.6, 0.4, 0.2)
    local img = lg.newImage(data)
    ;(img as love.graphics.Texture):setFilter("nearest", "nearest")
    return img
end

local function createGuitarIcon(): love.graphics.Image
    local data = love.image.newImageData(16, 16)
    fillCircle(data, 8, 10, 5, 0.6, 0.3, 0.1)
    fillCircle(data, 8, 10, 2, 0.2, 0.1, 0.05)
    fillRect(data, 7, 1, 3, 7, 0.5, 0.25, 0.1)
    fillRect(data, 6, 0, 5, 2, 0.4, 0.2, 0.1)
    local img = lg.newImage(data)
    ;(img as love.graphics.Texture):setFilter("nearest", "nearest")
    return img
end

local function createKeyboardIcon(): love.graphics.Image
    local data = love.image.newImageData(16, 16)
    fillRect(data, 1, 4, 14, 10, 0.95, 0.95, 0.95)
    fillRect(data, 3, 4, 2, 5, 0.1, 0.1, 0.1)
    fillRect(data, 7, 4, 2, 5, 0.1, 0.1, 0.1)
    fillRect(data, 11, 4, 2, 5, 0.1, 0.1, 0.1)
    for x = 1, 14, 2 do
        drawLine(data, x, 4, x, 13, 0.7, 0.7, 0.7)
    end
    local img = lg.newImage(data)
    ;(img as love.graphics.Texture):setFilter("nearest", "nearest")
    return img
end

local function createSpeakerIcon(): love.graphics.Image
    local data = love.image.newImageData(16, 16)
    fillRect(data, 2, 3, 6, 10, 0.3, 0.3, 0.35)
    fillCircle(data, 5, 8, 3, 0.2, 0.2, 0.25)
    fillCircle(data, 5, 8, 1, 0.4, 0.4, 0.45)
    for i = 0, 2 do
        local x = 10 + i * 2
        drawLine(data, x, 5 + i, x, 11 - i, 0.5, 0.7, 0.9)
    end
    local img = lg.newImage(data)
    ;(img as love.graphics.Texture):setFilter("nearest", "nearest")
    return img
end

local function createSmileyIcon(): love.graphics.Image
    local data = love.image.newImageData(16, 16)
    fillCircle(data, 7.5, 7.5, 7, 1.0, 0.85, 0.2)
    fillCircle(data, 5, 6, 1.5, 0.1, 0.1, 0.1)
    fillCircle(data, 10, 6, 1.5, 0.1, 0.1, 0.1)
    for x = 4, 11 do
        local y = 9 + math.floor((x - 7.5) * (x - 7.5) * 0.15)
        setPixel(data, x, y, 0.1, 0.1, 0.1)
    end
    local img = lg.newImage(data)
    ;(img as love.graphics.Texture):setFilter("nearest", "nearest")
    return img
end

function icons.load(): icons
    return {
        drum = createDrumIcon(),
        guitar = createGuitarIcon(),
        keyboard = createKeyboardIcon(),
        speaker = createSpeakerIcon(),
        smiley = createSmileyIcon()
    }
end

return icons
