-- #region tecs.ui.Interaction
--[=[
Creates a focusable control with an explicit Tab position.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local world <const> = tecs.ecs.newWorld()
local panel <const> = world:spawn(ui.Style({width = 480, height = 360}))

local button <const> = world:spawn(
    ui.Style({width = 180, height = 44}),
    ui.Interaction({tabIndex = 1, draggable = false}),
    tecs.ecs.RelativeTransform2D(),
    tecs.ecs.ChildOf(panel)
)
-- #endregion tecs.ui.Interaction

-- #region tecs.ui.InteractionState
--[=[
Reads transient focus state without dirtying the retained control.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local world <const> = tecs.ecs.newWorld()
local button <const> = world:spawn(ui.Interaction({tabIndex = 1}))

local state <const> = world:get(button, ui.InteractionState)
if state ~= nil and state.focused then
    print("button has keyboard focus")
end
-- #endregion tecs.ui.InteractionState

-- #region tecs.ui.Event
--[=[
Handles pointer and keyboard activation through the same observer.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local type uiTypes = require("tecs.ui")
local type UiEvent = uiTypes.Event
local world <const> = tecs.ecs.newWorld()
local button <const> = world:spawn(ui.Interaction({tabIndex = 1}))

world:observe(
    button,
    ui.Event,
    function(event: UiEvent)
        if event.kind == "activate" then
            print("activated via", event.source)
        end
    end
)
-- #endregion tecs.ui.Event

-- #region tecs.ui.FocusScope
--[=[
Marks a dialog as a boundary for modal pointer and keyboard navigation.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local world <const> = tecs.ecs.newWorld()
local root <const> = world:spawn(ui.Style({width = 1280, height = 720}))

local dialog <const> = world:spawn(
    ui.Style({width = 440, height = 260}), ui.FocusScope(), tecs.ecs.RelativeTransform2D(), tecs.ecs.ChildOf(root)
)
-- #endregion tecs.ui.FocusScope

-- #region tecs.ui.focus
--[=[
Moves keyboard focus to an enabled, focusable control.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local world <const> = tecs.ecs.newWorld()
local saveButton <const> = world:spawn(ui.Interaction({tabIndex = 1}))

if not ui.focus(world, saveButton) then
    print("save button cannot receive focus")
end
-- #endregion tecs.ui.focus

-- #region tecs.ui.blur
--[=[
Clears the current keyboard focus when one exists.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local world <const> = tecs.ecs.newWorld()

if ui.focused(world) ~= nil then
    ui.blur(world)
end
-- #endregion tecs.ui.blur

-- #region tecs.ui.focused
--[=[
Finds the interaction that currently owns keyboard focus.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local world <const> = tecs.ecs.newWorld()

local current <const> = ui.focused(world)
if current ~= nil then
    print("focused entity", current)
end
-- #endregion tecs.ui.focused

-- #region tecs.ui.pushFocusScope
--[=[
Activates a modal scope and focuses its first control.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local world <const> = tecs.ecs.newWorld()
local dialog <const> = world:spawn(ui.FocusScope())
local firstDialogControl <const> = world:spawn(ui.Interaction({tabIndex = 1}), tecs.ecs.ChildOf(dialog))

if ui.pushFocusScope(world, dialog) then
    ui.focus(world, firstDialogControl)
end
-- #endregion tecs.ui.pushFocusScope

-- #region tecs.ui.popFocusScope
--[=[
Closes the active modal boundary and restores its saved focus.
]=]
local tecs <const> = require("tecs")
local ui <const> = tecs.ui
local world <const> = tecs.ecs.newWorld()
local dialog <const> = world:spawn(ui.FocusScope())

if not ui.popFocusScope(world, dialog) then
    print("dialog is not the active focus scope")
end
-- #endregion tecs.ui.popFocusScope
