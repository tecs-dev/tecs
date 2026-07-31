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
local platformEvents <const> = require("tecs.platform.events")
local shadercompiler <const> = require("tecs.gpu.shadercompiler")
local shaderpack <const> = require("tecs.gpu.shaderpack")
local materials <const> = require("tecs.gpu.materials")
local type uiTypes = require("tecs.ui")
local type assetTypes = require("tecs.assets")
local type componentTypes = require("tecs.components")
local type UiEvent = uiTypes.Event
local type Image = assetTypes.Image
local type Sprite = componentTypes.Sprite
local type Future = require("tecs.Future")
local Transform <const> = tecs.Transform
local RelativeTransform <const> = tecs.ecs.RelativeTransform
local ChildOf <const> = tecs.ecs.ChildOf
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
    local centerX = width * 0.5
    local centerY = height * 0.5
    local extent = math.min(width, height) * 0.46 * WORLD
    local golden <const> = 2.39996

    world:batchSpawn(
        COUNT,
        {Transform, Tint, Renderable},
        function(archetype: tecs.ecs.Archetype, firstRow: integer, lastRow: integer)
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
                transform.x = centerX + math.cos(angle) * radius
                transform.y = centerY + math.sin(angle) * radius
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
        local color = palette[(index - 1) % #palette + 1]
        local x, y = width * 0.5, height * 0.5
        if index > #palette then
            local radius = math.sqrt(index / LIGHTS) * math.min(width, height) * 0.45
            x = x + math.cos(index * golden) * radius
            y = y + math.sin(index * golden) * radius
        end
        world:spawn(
            Transform(x, y, 0, 1, 0, 1, 1),
            PointLight(120.0, math.min(width, height) * 0.7, color[1], color[2], color[3], 3.0)
        )
    end
end

return tecs.newApplication({
    window = {
        title = "tecs",
        width = math.floor(tonumber(os.getenv("TECS_WIDTH")) or 1280),
        height = math.floor(tonumber(os.getenv("TECS_HEIGHT")) or 720),
    },
    framesInFlight = tonumber(os.getenv("TECS_INFLIGHT")) as integer,
    debug = true,
    ambientLight = {0.05, 0.05, 0.08},
    -- Headroom over the field for lights, composed UI shapes, and one entity
    -- per glyph. Hitting the renderer capacity drops later instances.
    capacity = COUNT + 512,
    maxEntities = COUNT + 1024,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    presentMode = os.getenv("TECS_PRESENT"),
    mcpPort = tonumber(os.getenv("TECS_MCP")) as integer,

    plugin = function(world: tecs.World, app: tecs.Application)
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

        local t0 = tecs.platform.time.now()
        spawnField(world, width, height)
        local t1 = tecs.platform.time.now()
        spawnLights(world, width, height)
        print(("  spawn: %.0f ms for %d entities"):format((t1 - t0) * 1000, COUNT))

        -- Text is entities too. The plugin shapes the string and writes one
        -- renderer instance per glyph into the same cull and draw.
        world:addPlugin(tecs.gfx.textPlugin({renderer = app.renderer}))
        local font <const> = tecs.gfx.newTTF({
            source = "fonts/JetBrainsMono-ExtraBold.ttf",
            size = 64,
        }).value
        world:spawn(
            Transform(24, 24, 0, 1),
            Tint(0.92, 0.96, 1.0, 1.0),
            tecs.gfx.Text.new({
                text = ("tecs %s\n%d entities"):format(tecs.version, COUNT),
                font = font,
                size = 28,
            })
        )

        -- The UI is retained layout over the same entities and instance
        -- producers. Retained layout positions containers; these leaves remain
        -- ordinary rectangles, circles, images, and text.
        local ui <const> = tecs.ui
        tecs.gfx.layers.configure(
            16,
            {
                sort = "z",
                screenSpace = true,
                unlit = true,
            }
        )
        world:addPlugin(ui.plugin(app, {wheelStep = 36}))

        local uiRoot <const> = world:spawn(
            ui.Style({
                width = "100%",
                height = "100%",
                flexDirection = "row",
                justifyContent = "end",
                padding = 24,
            }),
            ui.Root("screen"),
            Transform(0, 0, 900, 16)
        )
        local panel <const> = world:spawn(
            ui.Style({
                width = 400,
                height = "100%",
                flexDirection = "column",
                padding = 20,
                gap = 12,
            }),
            RelativeTransform(),
            ChildOf(uiRoot)
        )
        world:spawn(
            ui.Style({position = "absolute", inset = 0}),
            ui.Paint(true),
            RelativeTransform(0, 0, 0),
            Tint(0.035, 0.055, 0.09, 0.96),
            tecs.gfx.Material(materials.id("rounded"), 0.04),
            Renderable(),
            ChildOf(panel)
        )

        local header <const> = world:spawn(ui.Style({height = 56, width = "100%"}), RelativeTransform(), ChildOf(panel))
        world:spawn(
            ui.Style({position = "absolute", width = 42, height = 42, inset = {left = 0, top = 4}}),
            ui.Paint(true),
            RelativeTransform(0, 0, 2),
            Tint(0.32, 0.82, 1.0, 1.0),
            tecs.gfx.Material(materials.id("circle"), 0),
            Renderable(),
            ChildOf(header)
        )
        world:spawn(
            ui.Style({position = "absolute", width = 310, height = 28, inset = {left = 58, top = 0}}),
            RelativeTransform(0, 0, 3),
            Tint(0.94, 0.97, 1.0, 1.0),
            tecs.gfx.Text.new({
                text = "Tecs UI",
                font = font,
                size = 25,
            }),
            ChildOf(header)
        )
        world:spawn(
            ui.Style({position = "absolute", width = 310, height = 20, inset = {left = 58, top = 32}}),
            RelativeTransform(0, 0, 3),
            Tint(0.54, 0.64, 0.76, 1.0),
            tecs.gfx.Text.new({
                text = "ECS retained, GPU instanced",
                font = font,
                size = 13,
            }),
            ChildOf(header)
        )

        local status <const> = world:spawn(
            ui.Style({height = 42, width = "100%"}),
            RelativeTransform(0, 0, 3),
            Tint(0.62, 0.75, 0.88, 1.0),
            tecs.gfx.Text.new({
                text = "Click, Tab, Shift-Tab, Return, or scroll",
                font = font,
                size = 13,
            }),
            ChildOf(panel)
        )

        local controls: {{integer}} = {}
        local function setStatus(message: string)
            local text = world:getMut(status, tecs.gfx.Text)
            if text ~= nil then
                text.text = message
            end
        end
        local function spawnButton(parent: integer, label: string, tabIndex: integer): integer
            local control <const> = world:spawn(
                ui.Style({width = "100%", height = 44}),
                ui.Interaction({tabIndex = tabIndex}),
                RelativeTransform(),
                ChildOf(parent)
            )
            local visual <const> = world:spawn(
                ui.Style({position = "absolute", inset = 0}),
                ui.Paint(true),
                RelativeTransform(0, 0, 1),
                Tint(0.12, 0.20, 0.30, 1.0),
                tecs.gfx.Material(materials.id("rounded"), 0.18),
                Renderable(),
                ChildOf(control)
            )
            world:spawn(
                ui.Style({position = "absolute", width = 300, height = 24, inset = {left = 14, top = 11}}),
                RelativeTransform(0, 0, 2),
                Tint(0.9, 0.95, 1.0, 1.0),
                tecs.gfx.Text.new({text = label, font = font, size = 16}),
                ChildOf(control)
            )
            controls[#controls + 1] = {control, visual}
            world:observe(
                control,
                ui.Event,
                function(event: UiEvent)
                    if event.kind == "activate" then
                        setStatus(("%s via %s"):format(label, event.source))
                    end
                end
            )
            return control
        end

        local actions <const> = world:spawn(
            ui.Style({
                width = "100%",
                height = 44,
                flexDirection = "row",
                gap = 10,
            }),
            RelativeTransform(),
            ChildOf(panel)
        )
        local function spawnCompactButton(label: string, tabIndex: integer)
            local control <const> = world:spawn(
                ui.Style({width = 112, height = 44}),
                ui.Interaction({tabIndex = tabIndex}),
                RelativeTransform(),
                ChildOf(actions)
            )
            local visual <const> = world:spawn(
                ui.Style({position = "absolute", inset = 0}),
                ui.Paint(true),
                RelativeTransform(0, 0, 1),
                Tint(0.12, 0.20, 0.30, 1.0),
                tecs.gfx.Material(materials.id("rounded"), 0.18),
                Renderable(),
                ChildOf(control)
            )
            world:spawn(
                ui.Style({position = "absolute", width = 90, height = 22, inset = {left = 12, top = 11}}),
                RelativeTransform(0, 0, 2),
                Tint(0.9, 0.95, 1.0, 1.0),
                tecs.gfx.Text.new({text = label, font = font, size = 15}),
                ChildOf(control)
            )
            controls[#controls + 1] = {control, visual}
            world:observe(
                control,
                ui.Event,
                function(event: UiEvent)
                    if event.kind == "activate" then
                        setStatus(("%s via %s"):format(label, event.source))
                    end
                end
            )
        end
        spawnCompactButton("Compose", 1)
        spawnCompactButton("Inspect", 2)
        spawnCompactButton("Ship", 3)

        local viewport <const> = world:spawn(
            ui.Style({
                width = "100%",
                flexGrow = 1,
                minHeight = 120,
            }),
            ui.Scroll(),
            RelativeTransform(),
            ChildOf(panel)
        )
        local content <const> = world:spawn(
            ui.Style({
                width = "100%",
                height = 508,
                flexDirection = "column",
                gap = 8,
            }),
            RelativeTransform(),
            ChildOf(viewport)
        )
        local labels <const> = {
            "Rectangle instance",
            "Circle material",
            "Text producer",
            "Image sprite",
            "Nested clipping",
            "Dirty transforms",
            "Focus navigation",
            "Bubbling events",
            "Pointer capture",
        }
        for index = 1, #labels do
            spawnButton(content, ("%02d  %s"):format(index, labels[index]), index + 3)
        end

        -- Images remain sprites. Loading and residency are asynchronous; once
        -- ready, this leaf simply joins the same retained hierarchy.
        tecs.assets.loadImage(tecs.io.files.assetPath("demo/ui-badge.svg")):map(function(image: Image): Sprite
            local sprite <const> = app.renderer:registerImage(image)
            return sprite
        end):onSettle(function(sprite: Future<Sprite>)
            if sprite.status == "ready" then
                world:spawn(
                    ui.Style({
                        position = "absolute",
                        width = 32,
                        height = 32,
                        inset = {right = 8, top = 6},
                    }),
                    ui.Paint(true),
                    RelativeTransform(0, 0, 3),
                    sprite.value,
                    Tint(1, 1, 1, 1),
                    Renderable(),
                    ChildOf(panel)
                )
            end
        end)

        world:addSystem({
            name = "demo.UiState",
            phase = tecs.ecs.phases.Update,
            run = function()
                for index = 1, #controls do
                    local pair = controls[index]
                    local state = world:get(pair[1], ui.InteractionState)
                    local tint = world:get(pair[2], Tint)
                    if state ~= nil and tint ~= nil then
                        local r, g, b = 0.12, 0.20, 0.30
                        if state.pressed then
                            r, g, b = 0.14, 0.47, 0.62
                        elseif state.hovered then
                            r, g, b = 0.17, 0.34, 0.48
                        elseif state.focused then
                            r, g, b = 0.18, 0.29, 0.46
                        end
                        if tint.r ~= r or tint.g ~= g or tint.b ~= b then
                            local changed = world:getMut(pair[2], Tint)
                            changed.r, changed.g, changed.b = r, g, b
                        end
                    end
                end
            end,
        })

        local elapsed = 0.0

        -- Rotation is a write, so the column is taken with getMut. Reads use
        -- get: taking getMut to read would mark the component dirty on every
        -- archetype every frame and defeat every dirty-gated consumer.
        local static = os.getenv("TECS_STATIC") ~= nil
        local spinning = world:newQuery({include = {Transform, Renderable}})
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

        local orbiting = world:newQuery({include = {Transform, PointLight}})
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
            0, platformEvents.on.appWillEnterBackground, function() print("  backgrounded, simulation suspended") end
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
