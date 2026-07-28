--- Demo entry point.
---
--- Returns an application rather than blocking: SDL owns the loop, so the host
--- drives this from its callbacks.
---
--- Entities are the interface. Everything on screen is a spawned entity with a
--- Transform, the lights are entities too, and systems move them. Nothing
--- here touches a buffer, a pass, or a command buffer.
---
--- The game is a plugin, which is the only way in. It is handed the world and
--- the application everything that is not world state hangs off, and it
--- registers what should happen: systems for per-frame work, an observer for
--- the one platform event it cares about, and a `Shutdown` system for the
--- closing summary. Nothing in this file is called by the loop directly.

-- Where this tree was compiled to: the build says so during development, the
-- host says so for an installed run, and neither is the working directory. Our
-- tree comes first so it wins over the ECS repo's own copy of the engine.
local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local shadercompiler <const> = require("tecs.gpu.shadercompiler")
local shaderpack <const> = require("tecs.gpu.shaderpack")
local Transform <const> = tecs.ecs.builtins.Transform
local Tint <const> = tecs.gfx.Tint
local PointLight <const> = tecs.gfx.PointLight
local Renderable <const> = tecs.gfx.Renderable

local COUNT <const> = math.floor(tonumber(os.getenv("TECS_INSTANCES")) or 4000)

--- How far the field spreads relative to the window. Above one, most of the
--- world sits outside the view, which is the case culling exists for.
local WORLD <const> = tonumber(os.getenv("TECS_WORLD")) or 1.0

-- Scales quad size without moving anything, so a bench can separate the cost
-- of covering pixels from the cost of having instances.
local SCALE <const> = tonumber(os.getenv("TECS_SCALE")) or 1.0
local LIGHTS <const> = math.floor(tonumber(os.getenv("TECS_LIGHTS")) or 3)

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

    world:batchSpawn(
        COUNT,
        {Transform, Tint, Renderable},
        function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer)
            -- batchSpawn skips FFI defaults, so every field is written here.
            local transforms = archetype:getMut(Transform)
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
        end
    )
end

local function spawnLights(world: tecs.World, width: number, height: number)
    local palette <const> = {
        {1.0, 0.42, 0.35},
        {0.38, 1.0, 0.62},
        {0.42, 0.58, 1.0},
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
            Transform(x, y, 0, 1, 0, 1, 1),
            PointLight(120.0, math.min(width, height) * 0.7, colour[1], colour[2], colour[3], 3.0)
        )
    end
end

return tecs.application.create({
    window = {
        title = "tecs",
        width = math.floor(tonumber(os.getenv("TECS_WIDTH")) or 1280),
        height = math.floor(tonumber(os.getenv("TECS_HEIGHT")) or 720),
    },
    framesInFlight = tonumber(os.getenv("TECS_INFLIGHT")) as integer,
    debug = true,
    ambientLight = {0.05, 0.05, 0.08},
    -- Headroom over the field for the lights and for a glyph per character of
    -- the caption, since a glyph is an entity and an instance like any other.
    capacity = COUNT + 256,
    maxEntities = COUNT + 512,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    presentMode = os.getenv("TECS_PRESENT"),
    mcpPort = tonumber(os.getenv("TECS_MCP")) as integer,

    plugin = function(world: tecs.World, app: tecs.application.Application)
        local width, height = app.window:getPixelSize()
        print(("tecs %s"):format(tecs.version))
        print(("  driver: %s"):format(app.device.driver))
        print(("  window: %dx%d px"):format(width, height))

        -- Which of the two shader paths ran. Worth saying out loud: a packaged
        -- build and a compiling one produce the same frame, so nothing else
        -- distinguishes them.
        local pack = shadercompiler.pack()
        if pack ~= nil then
            local count = 0
            for _ in pairs(pack.shaders) do
                count = count + 1
            end
            print(
                ("  shaders: %d from a %s pack built for %s"):format(
                    count, shaderpack.formatName(pack.format), pack.target
                )
            )
        else
            print("  shaders: compiled from source")
        end

        local t0 = tecs.time.now()
        spawnField(world, width, height)
        local t1 = tecs.time.now()
        spawnLights(world, width, height)
        print(("  spawn: %.0f ms for %d entities"):format((t1 - t0) * 1000, COUNT))

        -- Text is entities too. The plugin lays the string out into one child
        -- entity per glyph, and each of those is an ordinary renderable that
        -- the same cull and the same draw pick up.
        world:addPlugin(tecs.text.plugin({renderer = app.renderer}))
        world:spawn(
            Transform(24, 24, 0, 1),
            Tint(0.92, 0.96, 1.0, 1.0),
            tecs.text.Text.new({
                text = ("tecs %s\n%d entities"):format(tecs.version, COUNT),
                font = tecs.text.defaultFont(),
                size = 28,
            })
        )

        local elapsed = 0.0

        -- Rotation is a write, so the column is taken with getMut. Reads use
        -- get: taking getMut to read would mark the component dirty on every
        -- archetype every frame and defeat every dirty-gated consumer.
        local static = os.getenv("TECS_STATIC") ~= nil
        local spinning = world:query({include = {Transform, Renderable}})
        if not static then
            world:addSystem({
                name = "demo.Spin",
                phase = tecs.ecs.phases.Update,
                run = function(dt: number)
                    elapsed = elapsed + dt
                    for archetype, length in spinning:iter() do
                        local transforms = archetype:getMut(Transform)
                        for row = 1, length do
                            transforms[row].rotation = transforms[row].rotation + dt * 1.5
                        end
                    end
                end,
            })
        end

        local orbiting = world:query({include = {Transform, PointLight}})
        world:addSystem({
            name = "demo.OrbitLights",
            phase = tecs.ecs.phases.Update,
            run = function()
                local index = 0
                for archetype, length in orbiting:iter() do
                    local transforms = archetype:getMut(Transform)
                    for row = 1, length do
                        local angle = elapsed * 0.6 + index * 2.094
                        transforms[row].x = width * (0.5 + 0.3 * math.cos(angle))
                        transforms[row].y = height * (0.5 + 0.3 * math.sin(angle))
                        index = index + 1
                    end
                end
            end,
        })

        local input = app.input
        world:addSystem({
            name = "demo.Quit",
            phase = tecs.ecs.phases.Update,
            run = function()
                -- Reads the base layer, so this stops responding on its own if
                -- a menu layer is ever pushed over it.
                if input:keyPressed("escape") then
                    app.quitRequested = true
                end
            end,
        })

        -- One kind, one handler. A game that also cared about drops would ask
        -- for `events.on.dropFile` beside this and be called for drops only,
        -- rather than for every event with a branch at the top.
        world:observe(
            0, tecs.events.on.appWillEnterBackground, function() print("  backgrounded, simulation suspended") end
        )

        -- Teardown is a phase like any other, so the summary is a system in it
        -- rather than a callback the loop has to remember to call.
        world:addSystem({
            name = "demo.Report",
            phase = tecs.ecs.phases.Shutdown,
            run = function()
                print(
                    ("ran %d frames over %.2fs (%.2f ms/frame, %d drawn, " .. "%d resynced)"):format(
                        app.frame,
                        app.elapsed,
                        app.elapsed / math.max(app.frame, 1) * 1000,
                        app.renderer.count,
                        app.renderer.rewritten
                    )
                )
            end,
        })

        print(("  %d renderable entities, %d light entities"):format(COUNT, LIGHTS))
        print("  escape or close the window to quit")
    end,
})
