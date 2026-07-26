--- Layer-effects fixture: retro (pixelMode) rendering with a passthrough
--- layer effect active, so the multi-pass layer-effects path runs. The
--- whole virtual view (80x60 at 4x) is covered by a green rectangle;
--- probes anywhere on screen must see green. Used to verify the effect
--- canvases track the render resolution across pixel-mode toggles.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs")
local mcp <const> = require("tecs.mcp")
local gfx <const> = require("tecs.gfx")

local Transform <const> = tecs.builtins.Transform

local VIRTUAL_HEIGHT <const> = 60

local PASSTHROUGH <const> = [[
vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    return Texel(tex, uv);
}
]]

local function gamePlugin(world: tecs.World)
    world:addPlugin(mcp.new({
        port = tonumber(os.getenv("TECS_MCP_PORT")) or mcp.DEFAULT_PORT,
    }))

    local pipeline = world.resources[gfx.PIPELINE] as gfx.Pipeline
    pipeline:getCamera():setPosition(40, 30)
    pipeline:setLayerEffect(1, love.graphics.newShader(PASSTHROUGH))

    -- Green rectangle covering the whole 80x60 virtual view.
    world:spawn(
        Transform(40, 30, 0, 1) as tecs.Component,
        gfx.Rectangle(80, 60) as tecs.Component,
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
