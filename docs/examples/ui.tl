-- A complete retained UI application. Copy this file to a Tecs project's
-- main.tl and run it with `tecs run`.

local tecs <const> = require("tecs")
local type uiTypes = require("tecs.ui")
local type UiEvent = uiTypes.Event

local ui <const> = tecs.ui
local ChildOf <const> = tecs.ecs.ChildOf
local RelativeTransform <const> = tecs.ecs.RelativeTransform
local Tint <const> = tecs.gfx.Tint
local Renderable <const> = tecs.gfx.Renderable
local Material <const> = tecs.gfx.Material
local materials <const> = tecs.gfx.materials

local function uiExamplePlugin(world: tecs.World, app: tecs.Application)
    tecs.gfx.layers.configure(
        16,
        {
            sort = "z",
            screenSpace = true,
            unlit = true,
        }
    )
    world:addPlugin(tecs.gfx.textPlugin({renderer = app.renderer}))
    world:addPlugin(ui.plugin(app, {wheelStep = 36}))

    local controls: {{integer}} = {}
    world:addSystem({
        name = "example.SpawnUi",
        phase = tecs.ecs.phases.Startup,
        run = function()
            local headingFont <const> = tecs.gfx.newTTF({
                source = "fonts/JetBrainsMono-ExtraBold.ttf",
                name = "example-heading-24",
                size = 24,
                raster = "alpha",
            }):wait().value
            local font <const> = tecs.gfx.newTTF({
                source = "fonts/JetBrainsMono-ExtraBold.ttf",
                name = "example-ui-16",
                size = 16,
                raster = "alpha",
            }):wait().value
            local root <const> = world:spawn(
                ui.Style({
                    width = "100%",
                    height = "100%",
                    justifyContent = "center",
                    alignItems = "center",
                    padding = "24px",
                }),
                ui.Root("screen"),
                tecs.Transform(0, 0, 0, 16)
            )

            local panel <const> = world:spawn(
                ui.Style({
                    width = 420,
                    height = 540,
                    flexDirection = "column",
                    padding = 20,
                    gap = 12,
                }),
                RelativeTransform(),
                ChildOf(root)
            )
            world:spawn(
                ui.Style({position = "absolute", inset = 0}),
                ui.Paint(true),
                RelativeTransform(0, 0, 0),
                Tint(0.035, 0.055, 0.09, 0.97),
                Material(materials.id("rounded"), 0.04),
                Renderable(),
                ChildOf(panel)
            )

            local heading <const> = world:spawn(
                ui.Style({
                    width = "100%",
                    height = 54,
                }),
                RelativeTransform(),
                ChildOf(panel)
            )
            world:spawn(
                ui.Style({
                    position = "absolute",
                    width = 40,
                    height = 40,
                    inset = {left = 0, top = 5},
                }),
                ui.Paint(true),
                RelativeTransform(0, 0, 1),
                Tint(0.32, 0.82, 1.0, 1.0),
                Material(materials.id("circle"), 0),
                Renderable(),
                ChildOf(heading)
            )
            world:spawn(
                ui.Style({
                    position = "absolute",
                    inset = {left = 56, top = 0},
                }),
                ui.Intrinsic("text"),
                RelativeTransform(0, 0, 2),
                Tint(0.94, 0.97, 1.0, 1.0),
                tecs.gfx.Text.new({
                    text = "Retained, composed UI",
                    font = headingFont,
                    size = 24,
                }),
                ChildOf(heading)
            )

            local status <const> = world:spawn(
                ui.Style({
                    width = "100%",
                }),
                ui.Intrinsic("text"),
                RelativeTransform(0, 0, 2),
                Tint(0.58, 0.7, 0.84, 1.0),
                tecs.gfx.Text.new({
                    text = "Click, Tab, Return, or scroll",
                    font = font,
                    size = 16,
                }),
                ChildOf(panel)
            )

            local function setStatus(message: string)
                local value <const> = world:getMut(status, tecs.gfx.Text)
                value.text = message
            end

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
                    height = 504,
                    flexDirection = "column",
                    gap = 8,
                }),
                RelativeTransform(),
                ChildOf(viewport)
            )
            world:spawn(
                ui.Scrollbar("vertical", 6, 2, 18),
                ui.Interaction({focusable = false, draggable = true, order = 100}),
                RelativeTransform(0, 0, 10),
                Tint(0.32, 0.82, 1.0, 0.85),
                Material(materials.id("rounded"), 0.5),
                Renderable(),
                ChildOf(viewport)
            )

            local function spawnButton(label: string, tabIndex: integer)
                local button <const> = world:spawn(
                    ui.Style({
                        width = "100%",
                        height = 48,
                    }),
                    ui.Interaction({tabIndex = tabIndex}),
                    RelativeTransform(),
                    ChildOf(content)
                )
                local visual <const> = world:spawn(
                    ui.Style({position = "absolute", inset = 0}),
                    ui.Paint(true),
                    RelativeTransform(0, 0, 1),
                    Tint(0.12, 0.20, 0.30, 1.0),
                    Material(materials.id("rounded"), 0.16),
                    Renderable(),
                    ChildOf(button)
                )
                world:spawn(
                    ui.Style({
                        position = "absolute",
                        inset = {left = 14, top = 13},
                    }),
                    ui.Intrinsic("text"),
                    RelativeTransform(0, 0, 2),
                    Tint(0.9, 0.95, 1.0, 1.0),
                    tecs.gfx.Text.new({
                        text = label,
                        font = font,
                        size = 16,
                    }),
                    ChildOf(button)
                )
                controls[#controls + 1] = {button, visual}
                world:observe(
                    button,
                    ui.Event,
                    function(event: UiEvent)
                        if event.kind == "activate" then
                            setStatus(("%s via %s"):format(label, event.source))
                        end
                    end
                )
            end

            spawnButton("Rectangle instance", 1)
            spawnButton("Circle material", 2)
            spawnButton("Distance-field text", 3)
            spawnButton("Nested clipping", 4)
            spawnButton("Dirty transforms", 5)
            spawnButton("Bubbling events", 6)
            spawnButton("Keyboard focus", 7)
            spawnButton("Pointer capture", 8)
            spawnButton("GPU instancing", 9)
        end,
    })

    world:addSystem({
        name = "example.UiState",
        phase = tecs.ecs.phases.Update,
        run = function()
            for index = 1, #controls do
                local pair <const> = controls[index]
                local state <const> = world:get(pair[1], ui.InteractionState)
                local tint <const> = world:get(pair[2], Tint)
                local r, g, b = 0.12, 0.20, 0.30
                if state.pressed then
                    r, g, b = 0.14, 0.47, 0.62
                elseif state.hovered then
                    r, g, b = 0.17, 0.34, 0.48
                elseif state.focused then
                    r, g, b = 0.18, 0.29, 0.46
                end
                if tint.r ~= r or tint.g ~= g or tint.b ~= b then
                    local changed <const> = world:getMut(pair[2], Tint)
                    changed.r, changed.g, changed.b = r, g, b
                end
            end
        end,
    })
end

return tecs.newApplication({
    window = {
        title = "Tecs retained UI",
        width = 960,
        height = 640,
    },
    ambientLight = {1, 1, 1},
    capacity = 512,
    maxEntities = 1024,
    debug = true,
    debugMaxFrames = tonumber(os.getenv("TECS_FRAMES")) as integer,
    plugin = uiExamplePlugin,
})
