--- Demo entry point.
---
--- Returns an application rather than blocking: SDL owns the loop, so the host
--- drives this from its callbacks.
---
--- Entities are the interface. Everything on screen is a spawned entity with a
--- Transform2D, the lights are entities too, and systems move them. Nothing
--- here touches a buffer, a pass, or a command buffer.

-- Where this tree was compiled to: the build says so during development, the
-- host says so for an installed run, and neither is the working directory. Our
-- tree comes first so it wins over the ECS repo's own copy of the engine.
local root = os.getenv("TECS2D_LUA")
    or (_G as {string: any})["__tecs2dContent"] as string
    or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then root = root:sub(1, -2) end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    -- Development only: the ECS is referenced in place rather than installed.
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local tecs2d <const> = require("tecs2d")
local shadercompiler <const> = require("tecs2d.gpu.shadercompiler")
local shaderpack <const> = require("tecs2d.gpu.shaderpack")
local Transform2D <const> = tecs2d.components.Transform2D
local Tint <const> = tecs2d.components.Tint
local PointLight <const> = tecs2d.components.PointLight
local Renderable <const> = tecs2d.components.Renderable

local COUNT <const> = math.floor(tonumber(os.getenv("TECS2D_INSTANCES")) or 4000)

--- How far the field spreads relative to the window. Above one, most of the
--- world sits outside the view, which is the case culling exists for.
local WORLD <const> = tonumber(os.getenv("TECS2D_WORLD")) or 1.0

-- Scales quad size without moving anything, so a bench can separate the cost
-- of covering pixels from the cost of having instances.
local SCALE <const> = tonumber(os.getenv("TECS2D_SCALE")) or 1.0
local LIGHTS <const> = math.floor(tonumber(os.getenv("TECS2D_LIGHTS")) or 3)

--- Seeds a sunflower spiral of renderable quads.
---
--- Uses batchSpawn rather than a spawn per entity. One spawn resolves the
--- archetype, allocates an id, and moves a row every time it is called, which
--- at a million entities is the difference between a fifth of a second and
--- twenty. The callback writes columns in place, so no component values are
--- constructed at all.
local function spawnField(world: tecs.World, width: number, height: number)
    local centreX = width * 0.5
    local centreY = height * 0.5
    local extent = math.min(width, height) * 0.46 * WORLD
    local golden <const> = 2.39996

    world:batchSpawn(COUNT, { Transform2D, Tint, Renderable },
        function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer)
            -- batchSpawn skips FFI defaults, so every field is written here.
            local transforms = archetype:getMut(Transform2D)
            local tints = archetype:getMut(Tint)

            for row = firstRow, lastRow do
                local index = row - firstRow
                local angle = index * golden
                local radius = math.sqrt(index / COUNT) * extent
                local size = (6.0 + 10.0 * (1.0 - radius / extent)) * SCALE
                local hue = index / COUNT

                local transform = transforms[row]
                transform.x = centreX + math.cos(angle) * radius
                transform.y = centreY + math.sin(angle) * radius
                transform.rotation = angle
                transform.scaleX = size
                transform.scaleY = size

                local tint = tints[row]
                tint.r = 0.55 + 0.45 * math.cos(6.28318 * hue)
                tint.g = 0.55 + 0.45 * math.cos(6.28318 * (hue + 0.33))
                tint.b = 0.55 + 0.45 * math.cos(6.28318 * (hue + 0.67))
                tint.a = 1.0
            end
        end)
end

local function spawnLights(world: tecs.World, width: number, height: number)
    local palette <const> = {
        { 1.0, 0.42, 0.35 },
        { 0.38, 1.0, 0.62 },
        { 0.42, 0.58, 1.0 },
    }
    local golden <const> = 2.39996
    for index = 1, LIGHTS do
        -- The palette cycles, and lights past the first three spread over the
        -- view so a bench with many of them is not three stacked in the middle.
        local colour = palette[(index - 1) % #palette + 1]
        local x, y = width * 0.5, height * 0.5
        if index > #palette then
            local radius = math.sqrt(index / LIGHTS) * math.min(width, height) * 0.45
            x = x + math.cos(index * golden) * radius
            y = y + math.sin(index * golden) * radius
        end
        world:spawn(
            Transform2D(x, y, 0, 1, 1),
            PointLight(120.0, math.min(width, height) * 0.7,
                colour[1], colour[2], colour[3], 3.0)
        )
    end
end

return tecs2d.application({
    window = {
        title = "tecs2d",
        width = math.floor(tonumber(os.getenv("TECS2D_WIDTH")) or 1280),
        height = math.floor(tonumber(os.getenv("TECS2D_HEIGHT")) or 720),
    },
    framesInFlight = tonumber(os.getenv("TECS2D_INFLIGHT")) as integer,
    debug = true,
    ambient = { 0.05, 0.05, 0.08 },
    capacity = COUNT + 16,
    maxEntities = COUNT + 64,
    maxFrames = tonumber(os.getenv("TECS2D_FRAMES")) as integer,
    presentMode = os.getenv("TECS2D_PRESENT"),
    mcpPort = tonumber(os.getenv("TECS2D_MCP")) as integer,

    load = function(app: tecs2d.Application)
        local width, height = app.window:getPixelSize()
        print(("tecs2d %s"):format(tecs2d.version))
        print(("  driver: %s"):format(app.device.driver))
        print(("  window: %dx%d px"):format(width, height))

        -- Which of the two shader paths ran. Worth saying out loud: a packaged
        -- build and a compiling one produce the same frame, so nothing else
        -- distinguishes them.
        local pack = shadercompiler.pack()
        if pack ~= nil then
            local count = 0
            for _ in pairs(pack.shaders) do count = count + 1 end
            print(("  shaders: %d from a %s pack built for %s"):format(
                count, shaderpack.formatName(pack.format), pack.target))
        else
            print("  shaders: compiled from source")
        end

        local t0 = tecs2d.clock.now()
        spawnField(app.world, width, height)
        local t1 = tecs2d.clock.now()
        spawnLights(app.world, width, height)
        print(("  spawn: %.0f ms for %d entities"):format((t1 - t0) * 1000, COUNT))

        local elapsed = 0.0

        -- Rotation is a write, so the column is taken with getMut. Reads use
        -- get: taking getMut to read would mark the component dirty on every
        -- archetype every frame and defeat every dirty-gated consumer.
        local static = os.getenv("TECS2D_STATIC") ~= nil
        local spinning = app.world:query({ include = { Transform2D, Renderable } })
        if not static then
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
        end

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

    update = function(app: tecs2d.Application)
        -- Reads the base layer, so this stops responding on its own if a
        -- menu layer is ever pushed over it.
        if app.input:isKeyPressed("escape") then
            app.quitRequested = true
        end
    end,

    event = function(_app: tecs2d.Application, event: tecs2d.events.Event)
        -- Every event reaches here, including ones the engine acted on, so a
        -- game can observe lifecycle without the engine handing it a
        -- second, parallel notification.
        if event.kind == "appWillEnterBackground" then
            print("  backgrounded, simulation suspended")
        end
    end,

    quit = function(app: tecs2d.Application)
        print(("ran %d frames over %.2fs (%.2f ms/frame, %d drawn, %d resynced)")
            :format(app.frame, app.elapsed,
                app.elapsed / math.max(app.frame, 1) * 1000,
                app.renderer.count, app.renderer.rewritten))
    end,
})
