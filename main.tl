--- Demo entry point.
---
--- Entities are the interface. Everything on screen is a spawned entity with a
--- Transform2D, the lights are entities too, and systems move them. Nothing
--- here touches a buffer, a pass, or a command buffer.

-- Our build first, so it wins over the ECS repo's own engine tree.
package.path = "build/?.lua;build/?/init.lua;"
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local Transform2D <const> = tecs2d.components.Transform2D
local Tint <const> = tecs2d.components.Tint
local PointLight <const> = tecs2d.components.PointLight
local Renderable <const> = tecs2d.components.Renderable

local COUNT <const> = math.floor(tonumber(os.getenv("TECS2D_INSTANCES")) or 4000)
local LIGHTS <const> = 3

--- Seeds a sunflower spiral of renderable quads.
local function spawnField(world: tecs.World, width: number, height: number)
    local centreX = width * 0.5
    local centreY = height * 0.5
    local extent = math.min(width, height) * 0.46
    local golden = 2.39996

    for index = 0, COUNT - 1 do
        local angle = index * golden
        local radius = math.sqrt(index / COUNT) * extent
        local size = 6.0 + 10.0 * (1.0 - radius / extent)
        local hue = index / COUNT

        world:spawn(
            Transform2D(
                centreX + math.cos(angle) * radius,
                centreY + math.sin(angle) * radius,
                angle,
                size, size
            ),
            Tint(
                0.55 + 0.45 * math.cos(6.28318 * hue),
                0.55 + 0.45 * math.cos(6.28318 * (hue + 0.33)),
                0.55 + 0.45 * math.cos(6.28318 * (hue + 0.67)),
                1.0
            ),
            Renderable()
        )
    end
end

local function spawnLights(world: tecs.World, width: number, height: number)
    local palette <const> = {
        { 1.0, 0.42, 0.35 },
        { 0.38, 1.0, 0.62 },
        { 0.42, 0.58, 1.0 },
    }
    for index = 1, LIGHTS do
        local colour = palette[index]
        world:spawn(
            Transform2D(width * 0.5, height * 0.5, 0, 1, 1),
            PointLight(120.0, math.min(width, height) * 0.7,
                colour[1], colour[2], colour[3], 3.0)
        )
    end
end

os.exit(tecs2d.run({
    window = { title = "tecs2d", width = 1280, height = 720 },
    debug = true,
    ambient = { 0.05, 0.05, 0.08 },
    capacity = COUNT + 16,
    maxFrames = tonumber(os.getenv("TECS2D_FRAMES")) as integer,
    presentMode = os.getenv("TECS2D_PRESENT"),

    load = function(app: tecs2d.App)
        local width, height = app.window:getPixelSize()
        print(("tecs2d %s"):format(tecs2d.version))
        print(("  driver: %s"):format(app.device.driver))
        print(("  window: %dx%d px"):format(width, height))

        spawnField(app.world, width, height)
        spawnLights(app.world, width, height)

        local elapsed = 0.0

        -- Rotation is a write, so the column is taken with getMut. Reads use
        -- get: taking getMut to read would mark the component dirty on every
        -- archetype every frame and defeat every dirty-gated consumer.
        local spinning = app.world:query({ include = { Transform2D, Renderable } })
        app.world:addSystem({
            name = "demo.Spin",
            phase = tecs.phases.Update,
            run = function(dt: number)
                elapsed = elapsed + dt
                for archetype, length in spinning:iter() do
                    local transforms = archetype:getMut(Transform2D)
                    for row = 1, length do
                        transforms[row].rotation = transforms[row].rotation + dt * 1.5
                    end
                end
            end,
        })

        local orbiting = app.world:query({ include = { Transform2D, PointLight } })
        app.world:addSystem({
            name = "demo.OrbitLights",
            phase = tecs.phases.Update,
            run = function()
                local index = 0
                for archetype, length in orbiting:iter() do
                    local transforms = archetype:getMut(Transform2D)
                    for row = 1, length do
                        local angle = elapsed * 0.6 + index * 2.094
                        transforms[row].x = width * (0.5 + 0.3 * math.cos(angle))
                        transforms[row].y = height * (0.5 + 0.3 * math.sin(angle))
                        index = index + 1
                    end
                end
            end,
        })

        print(("  %d renderable entities, %d light entities"):format(COUNT, LIGHTS))
        print("  escape or close the window to quit")
    end,

    update = function(app: tecs2d.App)
        -- Reads the base layer, so this stops responding on its own if a
        -- menu layer is ever pushed over it.
        if app.input:isKeyPressed("escape") then
            app.quitRequested = true
        end
    end,

    quit = function(app: tecs2d.App)
        print(("ran %d frames over %.2fs (%.2f ms/frame, %d drawn)"):format(
            app.frame, app.elapsed,
            app.elapsed / math.max(app.frame, 1) * 1000, app.renderer.count))
    end,
}))
