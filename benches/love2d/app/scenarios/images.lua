--- Static direct-image steady state. Every visible entity issues one
--- unbatched draw of the same texture, isolating gfx.Image's per-image cost
--- without including asset loading or texture creation in measured frames.
--- Set TECS_BENCH_IMAGES to measure scaling at another draw count.

local tecs = require("tecs")
local gfx = require("tecs2d.gfx")

local Transform = tecs.builtins.Transform

local IMAGES = tonumber(os.getenv("TECS_BENCH_IMAGES")) or 256
local COLUMNS = 32
local SPACING = 20
local START_X = 320
local START_Y = 160

return {
    render = {
        lightingMode = "none",
        lerpingEnabled = false,
        cameraPosition = {640, 360},
    },
    meta = {images = IMAGES},
    setup = function(world)
        local imageData = love.image.newImageData(16, 16)
        imageData:mapPixel(function(x, y)
            local checker = (math.floor(x / 4) + math.floor(y / 4)) % 2
            if checker == 0 then
                return 0.2, 0.7, 1.0, 1.0
            end
            return 0.9, 0.3, 0.5, 1.0
        end)
        local texture = love.graphics.newImage(imageData)
        texture:setFilter("nearest", "nearest")

        for i = 1, IMAGES do
            local index = i - 1
            local column = index % COLUMNS
            local row = math.floor(index / COLUMNS) % 20
            world:spawn(
                Transform(
                    START_X + column * SPACING,
                    START_Y + row * SPACING,
                    index * 0.0001,
                    1
                ),
                gfx.Image.fromTexture(texture)
            )
        end
    end,
}
