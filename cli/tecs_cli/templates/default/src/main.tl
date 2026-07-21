package.path = package.path .. ";./vendor/share/lua/5.1/?.lua;./vendor/share/lua/5.1/?/init.lua"
package.cpath = package.cpath .. ";./vendor/lib/lua/5.1/?.so;./vendor/lib/lua/5.1/?.dll"

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local gfx <const> = require("tecs2d.gfx")
local tween <const> = require("tecs2d.tween")
local mcp <const> = require("tecs2d.mcp")
local debugPlugin <const> = require("tecs2d.debug")

local Transform <const> = tecs.builtins.Transform
local FONT <const> = "tecs2d/assets/fonts/tiny-font.fnt"
local VIRTUAL_WIDTH <const> = 480
local VIRTUAL_HEIGHT <const> = 360

local function gamePlugin(world: tecs.World)
    -- Adds a debug console and integrated MCP tools to your game. Both are
    -- disabled automatically in `tecs dist` builds; construct with
    -- {enableInDist = true} to keep them.
    world:addPlugin(mcp.new())
    world:addPlugin(debugPlugin.new())

    -- Spawn entities on startup
    world:addSystem({
        name = "SpawnHello",
        phase = tecs.phases.Startup,
        run = function()
            -- Background on layer 1: higher layers always draw on top, so a
            -- full-bleed background belongs on its own lower layer. Within one
            -- layer, draw order follows that layer's sortMode (see render.layers
            -- below), not spawn order -- so keep backgrounds off gameplay layers
            -- or order with Transform.z.
            world:spawn(
                -- Transform is (x, y, z, layer, rotation?, scaleX?, scaleY?) --
                -- the 4th arg is the layer, not scale.
                Transform(VIRTUAL_WIDTH / 2, VIRTUAL_HEIGHT / 2, 0, 1),
                gfx.Rectangle(VIRTUAL_WIDTH, VIRTUAL_HEIGHT),
                gfx.Color(0.08, 0.09, 0.12, 1),
                gfx.Pivot(0.5, 0.5)
            )

            -- Greeting text on layer 2 (content) -- a WORLD-space layer, viewed
            -- by the camera. The camera is center-based and starts at world
            -- (0, 0), so world coordinates are centered on the origin (not
            -- top-left like virtual space). Pan/zoom in the debugger, camera
            -- follow, and camera:toWorld(pointer) all work on this layer.
            --
            -- Spawned half the bob amplitude below center so the pingPong
            -- oscillates symmetrically around the origin.
            local BOB <const> = 12 -- half the rendered text height
            local hello = world:spawn(
                Transform(0, BOB, 0, 2),
                gfx.Text(FONT, "HELLO TECS2D!", 4),
                gfx.Color(0.9, 0.96, 1.0, 1),
                gfx.Pivot(0.5, 0.5)
            )

            -- Idle bob: ease up by one text height and back, forever. Tweens
            -- are ECS data (snapshot-safe); see `tecs docs tecs2d/tween`.
            tween.timeline({
                tween.to(0.9, tween.sineInOut, tween.translateY, -BOB),
            }):play(world, hello, {mode = "pingPong"})
        end,
    })
end

-- Setup the Love2D game.
love.run = tecs2d.run({
    fps = 60,
    quitOnEscape = true,
    game = gamePlugin,
    render = {
        virtualHeight = VIRTUAL_HEIGHT,
        lightingMode = "none",
        layers = {
            -- Layers default to WORLD space, rendered through the camera --
            -- keep gameplay there so camera follow/zoom/shake and
            -- camera:toWorld(pointer) work. Reserve space = "virtual" for
            -- screen-fixed chrome only (full-bleed backdrops, HUD overlays).
            [1] = {name = "background", space = "virtual"},
            [2] = {name = "content"},
        },
    },
})
