--- {{name}}: a line of text that drifts up and down.
---
--- Small on purpose. It is four things every game starts from, and nothing
--- else: an entity, some text, a tween, and a system.
---
--- Two things about this file that are not obvious. It returns an application
--- instead of running one, because the host owns the loop and calls into this
--- a frame at a time; there is no `while true` to write. And `tecs` is a
--- global, already loaded before your first line, so nothing here requires it.

--- How far the greeting travels from where it rests, in pixels, and how many
--- seconds one sweep of that takes.
local TRAVEL <const> = 60.0
local SWEEP <const> = 1.2

return tecs.newApplication({
    window = {title = "{{title}}", width = 1280, height = 720},

    -- Your game is a plugin: handed the world, which holds everything that
    -- exists, and the application, which holds everything that does not. It
    -- registers what should happen and returns.
    plugin = function(world: tecs.World, app: tecs.Application)
        print(("{{name}} on tecs %s, drawing through %s"):format(tecs.version, app.device.driver))

        -- Drawing text is opt-in because SDF glyphs become renderer instances.
        world:addPlugin(tecs.gfx.textPlugin({renderer = app.renderer}))

        -- Measuring first is how the greeting ends up centerd. It reads the
        -- font and touches no entity.
        local greeting <const> = tecs.gfx.Text.new({
            text = "Hello Tecs",
            font = tecs.gfx.newTTF({
                source = "fonts/JetBrainsMono-ExtraBold.ttf",
                size = 64,
            }),
            size = 96,
        })
        local textWidth <const>, textHeight <const> = tecs.gfx.measureText(greeting)
        local width <const>, height <const> = app.window:getPixelSize()
        local restY <const> = (height - textHeight) * 0.5

        -- An entity is an id and the components on it, and that is the whole
        -- model: where it is, what color it is, what it says. There is no
        -- sprite object to make and no draw call to issue.
        local label <const> = world:spawn(
            tecs.Transform2D((width - textWidth) * 0.5, restY), tecs.gfx.Tint(0.93, 0.96, 1.0, 1.0), greeting
        )

        -- The motion, which this file never computes. A timeline is compiled
        -- once under a name and played on the entity that owns it. "pingPong"
        -- runs the sweep out and back forever, and "sineInOut" is the curve
        -- that makes the turn at either end a sine rather than a bounce.
        local bob <const> = tecs.sequence.timeline(
            "{{name}}.bob",
            {
                tecs.sequence.tweenTo(SWEEP, "sineInOut", "transform.y", restY - TRAVEL),
            }
        )
        tecs.sequence.play(world, bob, {owner = label, params = {mode = "pingPong"}})

        -- Work that happens every frame is a system, and a system names the
        -- phase it belongs to rather than a place in a list.
        world:addSystem({
            name = "{{name}}.Quit",
            phase = tecs.ecs.phases.Update,
            run = function()
                if app.input:keyPressed("escape") then
                    app.quitRequested = true
                end
            end,
        })

        print("  escape or close the window to quit")
    end,
})
