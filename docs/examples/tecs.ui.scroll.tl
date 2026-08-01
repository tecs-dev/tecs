-- #region tecs.ui.Scroll
--[=[
Creates a fixed viewport and changes its retained vertical offset.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local world <const> = tecs.ecs.newWorld()
local panel <const> = world:spawn(ui.Style({width = 480, height = 360}))

local viewport <const> = world:spawn(
    ui.Style({width = "100%", height = 240}), ui.Scroll(), tecs.ecs.RelativeTransform2D(), tecs.ecs.ChildOf(panel)
)

local scroll <const> = world:getMut(viewport, ui.Scroll)
scroll.y = scroll.y + 80
-- #endregion tecs.ui.Scroll

-- #region tecs.ui.Scrollbar
--[=[
Composes a square vertical thumb from ordinary renderer components.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local world <const> = tecs.ecs.newWorld()
local viewport <const> = world:spawn(ui.Style({width = 480, height = 240}), ui.Scroll())

world:spawn(
    ui.Scrollbar("vertical", 12, 4, 28),
    ui.Interaction({focusable = false, draggable = true}),
    tecs.ecs.RelativeTransform2D(0, 0, 10),
    tecs.gfx.Tint(0.32, 0.82, 1, 1),
    tecs.gfx.Material(tecs.gfx.materials.id("rounded"), 0),
    tecs.gfx.Renderable2D(),
    tecs.ecs.ChildOf(viewport)
)
-- #endregion tecs.ui.Scrollbar

-- #region tecs.ui.reveal
--[=[
Centers a selected row through every retained ancestor viewport.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local world <const> = tecs.ecs.newWorld()
local viewport <const> = world:spawn(ui.Style({height = 240}), ui.Scroll())
local selectedRow <const> = world:spawn(
    ui.Style({height = 44}), tecs.ecs.RelativeTransform2D(), tecs.ecs.ChildOf(viewport)
)

if not ui.reveal(world, selectedRow, "center") then
    print("selected row has no retained layout")
end
-- #endregion tecs.ui.reveal
