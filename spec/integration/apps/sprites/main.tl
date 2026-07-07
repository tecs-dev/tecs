--- Sprite fixture: one animated sprite at the center of a 320x240 window
--- with lighting disabled. The sheet is built at runtime: frame 0 is solid
--- red, frame 1 solid blue, 150 ms each, so pixel probes can tell exactly
--- which frame is showing. The sprite entity and sheet are exposed through
--- globals for run_lua-driven tests.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local mcp <const> = require("tecs2d.mcp")
local gfx <const> = require("tecs2d.gfx")

local Transform <const> = tecs.builtins.Transform

local WIDTH <const> = 320
local HEIGHT <const> = 240
local FRAME_MS <const> = 150

local function gamePlugin(world: tecs.World)
    world:addPlugin(mcp.new({
        port = tonumber(os.getenv("TECS_MCP_PORT")) or mcp.DEFAULT_PORT,
    }))

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    pipeline:getCamera():setPosition(WIDTH / 2, HEIGHT / 2)

    -- Two 16x16 frames side by side: red, then blue.
    local imageData = love.image.newImageData(32, 16)
    for y = 0, 15 do
        for x = 0, 15 do
            imageData:setPixel(x, y, 1, 0, 0, 1)
            imageData:setPixel(x + 16, y, 0, 0, 1, 1)
        end
    end
    local image = love.graphics.newImage(imageData)
    local sheet = gfx.SpriteSheet.builder(image, "sprite-fixture")
        :frame(0, 0, 16, 16, FRAME_MS)
        :frame(16, 0, 16, 16, FRAME_MS)
        :tag("play", 0, 1)
        :build()

    local globals = _G as {string: any}
    globals.tecsTestSheet = sheet
    globals.tecsTestSprite = world:spawn(
        Transform(WIDTH / 2, HEIGHT / 2, 0, 1) as tecs.Component,
        gfx.Sprite.fromSheet(sheet, "play") as tecs.Component
    )
end

love.run = tecs2d.run({
    fps = 60,
    game = gamePlugin,
    render = {
        virtualHeight = HEIGHT,
        lightingMode = "none",
    },
})
