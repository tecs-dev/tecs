-- Sprite playOnce Example
-- Demonstrates Sprite:playOnce(tag, callback) for animation completion callbacks.

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local SpriteSheet <const> = gfx.SpriteSheet
local mcp <const> = require("tecs2d.mcp")

local Text <const> = gfx.Text
local FONT_PATH <const> = "assets/press-start-2p.fnt"
local type Sprite = gfx.Sprite


local lg <const> = love.graphics

local Transform <const> = tecs.builtins.Transform

local WINDOW_WIDTH <const> = 800
local WINDOW_HEIGHT <const> = 600

local function examplePlugin(w: tecs.World)
    lg.setBackgroundColor(0.1, 0.1, 0.15)

    -- Add MCP for debugging
    w:addPlugin(mcp.new())

    -- Load sprite sheet from shared assets (symlinked to build/assets)
    local sheet = SpriteSheet.fromFile("assets/running.png")

    -- Spawn sprite in center of screen
    local spriteId = w:spawn(
        Transform(WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2),
        gfx.Sprite.fromSheet(sheet, "run", { speed = 1.0 })
    )

    -- Spawn HUD text on layer 2 (virtual space)
    local loopTextId = w:spawn(
        Transform(20, 20, 0, 2),
        Text(FONT_PATH, "Animation completions: 0", 1),
        gfx.Color(1, 1, 1, 1),
        gfx.Pivot(0, 0)
    )

    w:spawn(
        Transform(20, 60, 0, 2),
        Text(FONT_PATH, "Press ESC to quit", 1),
        gfx.Color(0.6, 0.6, 0.6, 1),
        gfx.Pivot(0, 0)
    )

    -- Track completion count (updated by playOnce callback, displayed by system)
    local loopCount = 0
    local lastDisplayedCount = 0

    -- Continuously replay the animation and count completions using playOnce.
    local onComplete: function(Sprite) = nil
    onComplete = function(anim: Sprite)
        loopCount = loopCount + 1
        print("Animation completed! Total completions: " .. tostring(loopCount))
        anim:playOnce("run", onComplete)
    end

    local sprite = w:get(spriteId, gfx.Sprite) as Sprite
    sprite:playOnce("run", onComplete)

    -- Update HUD text in a system (setText requires system context)
    w:addSystem({
        name = "UpdateLoopText",
        phase = tecs.phases.Update,
        run = function()
            if loopCount ~= lastDisplayedCount then
                lastDisplayedCount = loopCount
                local text = w:get(loopTextId, Text)
                if text then
                    text:setText("Animation completions: " .. tostring(loopCount))
                end
            end
        end
    })

end

love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = examplePlugin,
    render = {
        virtualHeight = WINDOW_HEIGHT,
        pixelMode = false,
        lightingMode = "none",
        cameraPosition = { WINDOW_WIDTH / 2, WINDOW_HEIGHT / 2 },
        layers = {
            [1] = { name = "default" },
            [2] = { name = "hud", space = "virtual" },
        },
    },
})
