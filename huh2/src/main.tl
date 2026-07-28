--- huh2.
---
--- Returns an application rather than blocking. SDL owns the loop, so the host
--- drives this from its callbacks and nothing here is a `while true`.
---
--- Entities are the interface: everything on screen is a spawned entity with a
--- Transform, and systems move them. Nothing here touches a buffer, a pass or a
--- command buffer.

local COUNT <const> = 240

--- Seeds a ring of renderable quads.
---
--- `batchSpawn` rather than a spawn each, because one call resolves the
--- archetype once and the callback writes columns in place. It skips FFI
--- defaults, so every field is written here.
local function spawnRing(world: tecs.ecs.World, width: number, height: number)
    local Transform <const> = tecs.ecs.builtins.Transform
    local Tint <const> = tecs.gfx.Tint
    local Renderable <const> = tecs.gfx.Renderable

    local centerX <const> = width * 0.5
    local centerY <const> = height * 0.5
    local radius <const> = math.min(width, height) * 0.32

    world:batchSpawn(
        COUNT,
        {Transform, Tint, Renderable},
        function(archetype: tecs.ecs.Archetype, firstRow: integer, lastRow: integer)
            local transforms = archetype:getMut(Transform)
            local tints = archetype:getMut(Tint)
            for row = firstRow, lastRow do
                local index = row - firstRow
                local angle = index / COUNT * math.pi * 2
                local transform = transforms[row]
                transform.x = centerX + math.cos(angle) * radius
                transform.y = centerY + math.sin(angle) * radius
                transform.rotation = angle
                transform.scaleX = 14
                transform.scaleY = 14

                local hue = index / COUNT
                local tint = tints[row]
                tint.r = 0.5 + 0.5 * math.cos(6.28318 * hue)
                tint.g = 0.5 + 0.5 * math.cos(6.28318 * (hue + 0.33))
                tint.b = 0.5 + 0.5 * math.cos(6.28318 * (hue + 0.67))
                tint.a = 1.0
            end
        end
    )
end

return tecs.application.create({
    window = {title = "huh2", width = 1280, height = 720},
    ambientLight = {0.06, 0.06, 0.09},
    capacity = COUNT + 64,

    -- The game is a plugin, which is the only way in. It is handed the world
    -- and the application, and it registers what should happen rather than
    -- being called by the loop directly.
    plugin = function(world: tecs.ecs.World, app: tecs.application.Application)
        local width <const>, height <const> = app.window:getPixelSize()

        -- What came up, said once at startup. Worth keeping: the driver and
        -- the pixel size are the two things that differ between machines, and
        -- the first question about a window that looks wrong is which of them
        -- is not what you expected.
        print(("%s on %s, %dx%d px"):format(tecs.version, app.device.driver, width, height))

        spawnRing(world, width, height)

        world:spawn(
            tecs.ecs.builtins.Transform(width * 0.5, height * 0.5, 0, 1),
            tecs.gfx.PointLight(200.0, math.min(width, height) * 0.8, 1.0, 0.92, 0.8, 3.0)
        )

        local elapsed = 0.0
        local spinning <const> = world:query({include = {tecs.ecs.builtins.Transform, tecs.gfx.Renderable}})

        -- Rotation is a write, so the column is taken with getMut. Reads use
        -- get: taking getMut to read marks the component dirty on every
        -- archetype every frame and defeats every dirty-gated consumer.
        world:addSystem({
            name = "huh2.Spin",
            phase = tecs.ecs.phases.Update,
            run = function(dt: number)
                elapsed = elapsed + dt
                for archetype, length in spinning:iter() do
                    local transforms = archetype:getMut(tecs.ecs.builtins.Transform)
                    for row = 1, length do
                        transforms[row].rotation = transforms[row].rotation + dt
                    end
                end
            end,
        })

        local input <const> = app.input
        world:addSystem({
            name = "huh2.Quit",
            phase = tecs.ecs.phases.Update,
            run = function()
                if input:keyPressed("escape") then
                    app.quitRequested = true
                end
            end,
        })
    end,
})
