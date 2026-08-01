-- #region tecs.ui.Style
--[=[
Builds a column whose width follows its parent up to 480 logical pixels.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local world <const> = tecs.ecs.newWorld()
local root <const> = world:spawn(ui.Style({width = 1280, height = 720}))

local panel <const> = world:spawn(
    ui.Style({
        width = "100%",
        maxWidth = 480,
        flexDirection = "column",
        padding = 20,
        gap = 12,
    }),
    tecs.ecs.RelativeTransform(),
    tecs.ecs.ChildOf(root)
)
-- #endregion tecs.ui.Style

-- #region tecs.ui.Root
--[=[
Creates a screen root that follows the application window automatically.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local world <const> = tecs.ecs.newWorld()

local root <const> = world:spawn(
    ui.Style({width = "100%", height = "100%"}),
    ui.Root("screen"),
    tecs.Transform(0, 0, 0, 16)
)
-- #endregion tecs.ui.Root

-- #region tecs.ui.Layout
--[=[
Reads the final logical size after the UI layout phase.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local world <const> = tecs.ecs.newWorld()
local panel <const> = world:spawn(ui.Style({width = 480, height = 320}))

local box <const> = world:get(panel, ui.Layout)
if box ~= nil then
    print(("%.0f x %.0f"):format(box.width, box.height))
end
-- #endregion tecs.ui.Layout

-- #region tecs.ui.Paint
--[=[
Stretches an ordinary rounded rectangle over its retained layout box.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local world <const> = tecs.ecs.newWorld()
local panel <const> = world:spawn(ui.Style({width = 480, height = 320}))

world:spawn(
    ui.Style({position = "absolute", inset = 0}),
    ui.Paint(true),
    tecs.ecs.RelativeTransform(0, 0, 1),
    tecs.gfx.Tint(0.1, 0.2, 0.3, 1),
    tecs.gfx.Material(tecs.gfx.materials.id("rounded"), 0.1),
    tecs.gfx.Renderable(),
    tecs.ecs.ChildOf(panel)
)
-- #endregion tecs.ui.Paint

-- #region tecs.ui.Intrinsic
--[=[
Selects natural text, image, or custom leaf measurements.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui

local wrappedText <const> = ui.Intrinsic("text", {wrap = true})
local imageSize <const> = ui.Intrinsic("image")
local customSize <const> = ui.Intrinsic(
    "custom",
    {width = 96, height = 28, minWidth = 48}
)
-- #endregion tecs.ui.Intrinsic
