--- Retro (pixelMode) fixture: integer-scaled low-res rendering in a window
--- whose height is NOT an integer multiple of the virtual height, so the
--- camera's screen mapping must use the integer upscale + letterbox rather
--- than the fractional screen/virtual ratio. A green 2x2 world-pixel
--- rectangle sits away from the camera center so mapping errors displace
--- cam:toScreen() visibly.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs")
local mcp <const> = require("tecs.mcp")
local gfx <const> = require("tecs.gfx")

local Transform <const> = tecs.builtins.Transform

local VIRTUAL_HEIGHT <const> = 60

local function gamePlugin(world: tecs.World)
    world:addPlugin(mcp.new({
        port = tonumber(os.getenv("TECS_MCP_PORT")) or mcp.DEFAULT_PORT,
    }))

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    -- Virtual view is 80x60 at 4x integer scale; center the camera on it.
    pipeline:getCamera():setPosition(40, 30)

    -- Green 2x2 world-pixel marker at (75, 55): 35 world px right of and
    -- 25 below the camera center, near the virtual view's corner.
    world:spawn(
        Transform(75, 55, 0, 1) as tecs.Component,
        gfx.Rectangle(2, 2) as tecs.Component,
        gfx.Color(0, 1, 0, 1) as tecs.Component
    )
end

love.run = tecs.run({
    fps = 60,
    game = gamePlugin,
    render = {
        virtualHeight = VIRTUAL_HEIGHT,
        pixelMode = true,
        lightingMode = "none",
    },
})
