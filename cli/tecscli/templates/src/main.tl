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

return tecs.application.create({
    window = {title = "{{title}}", width = 1280, height = 720},

    -- Your game is a plugin: handed the world, which holds everything that
    -- exists, and the application, which holds everything that does not. It
    -- registers what should happen and returns.
    plugin = function(world: tecs.ecs.World, app: tecs.application.Application)
        print(("{{name}} on tecs %s, drawing through %s"):format(tecs.version, app.device.driver))

        -- Drawing text is opt-in, because a font atlas is uploaded into one
        -- particular renderer. This is what teaches the world to draw strings.
        world:addPlugin(tecs.text.plugin({renderer = app.renderer}))

        -- Measuring first is how the greeting ends up centred. It reads the
        -- font and touches no entity.
        local greeting <const> = tecs.text.Text.new({
            text = "Hello Tecs",
            font = tecs.text.defaultFont(),
            size = 96,
        })
        local textWidth <const>, textHeight <const> = tecs.text.measure(greeting)
        local width <const>, height <const> = app.window:getPixelSize()
        local restY <const> = (height - textHeight) * 0.5

        -- An entity is an id and the components on it, and that is the whole
        -- model: where it is, what colour it is, what it says. There is no
        -- sprite object to make and no draw call to issue.
        local label <const> = world:spawn(
            tecs.components.Transform((width - textWidth) * 0.5, restY),
            tecs.components.Tint(0.93, 0.96, 1.0, 1.0),
            greeting
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
