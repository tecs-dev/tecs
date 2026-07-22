local tecs <const> = require("tecs")
local assets <const> = require("tecs2d.assets")
local gfx <const> = require("tecs2d.gfx")
local input <const> = require("tecs2d.input")
local ui <const> = require("tecs2d.ui")
local loading <const> = require("loading")

local Transform <const> = tecs.builtins.Transform
local FONT <const> = "assets/press-start-2p.fnt"

local record gameplay
    plugin: function(): tecs.Plugin
end

function gameplay.plugin(): tecs.Plugin
    return function(world: tecs.World)
        local loadingScreen = assert(world.resources[loading.KEY], "loading screen plugin is missing")

        world:spawn(
            Transform(0, 0, 0),
            ui.Anchor(0.5, 0.5),
            gfx.Rectangle(800, 600),
            gfx.Color(0.07, 0.085, 0.12)
        )
        world:spawn(
            Transform(0, 0, 2), ui.Anchor(0.5, 0, 0, 70),
            gfx.Text(FONT, "GAMEPLAY WORLD RUNNING", 1.1), ui.LayoutBox(gfx.Text),
            gfx.Color(0.35, 0.9, 0.55)
        )
        world:spawn(
            Transform(0, 0, 2), ui.Anchor(0.5, 0, 0, 115),
            gfx.Text(FONT, "ENTER: show cached loading flow   ESC: quit", 0.55), ui.LayoutBox(gfx.Text),
            gfx.Color(0.58, 0.64, 0.74)
        )

        local messageIds: {integer} = {}
        for i = 1, 5 do
            messageIds[i] = world:spawn(
                Transform(0, 0, 2), ui.Anchor(0.5, 0, 0, 185 + (i - 1) * 48),
                gfx.Text(FONT, "", 0.62), ui.LayoutBox(gfx.Text),
                gfx.Color(0.78, 0.82, 0.9)
            )
        end
        local statsId = world:spawn(
            Transform(0, 0, 2), ui.Anchor(0.5, 1, 0, -75),
            gfx.Text(FONT, "", 0.52), ui.LayoutBox(gfx.Text),
            gfx.Color(0.48, 0.56, 0.68)
        )

        local populated = false
        world:addSystem({
            name = "assets.GameplayUpdate",
            phase = tecs.phases.Update,
            run = function()
                -- No loading predicate: this system simply cannot run while
                -- the world is suspended.
                if not populated then
                    populated = true
                    for i = 1, 5 do
                        local text = world:get(messageIds[i], gfx.Text)
                        if text then
                            text:setText(string.format("%d. %s", i,
                                assets.loadFile(string.format("message%d.txt", i)).value))
                        end
                    end
                end

                local stats = assets.getStats()
                local statsText = world:get(statsId, gfx.Text)
                if statsText then
                    statsText:setText(string.format("lifetime %d complete | %d cached | %.1fs",
                        stats.completedCount, stats.currentAssetCount, love.timer.getTime()))
                end

                if input.isKeyPressed("return") then
                    loadingScreen:start()
                end
            end,
        })
    end
end

return gameplay
