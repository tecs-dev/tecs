--- In-game debugger overlay (Helix-style command mode). Installed by the
--- debug plugin; toggled with Ctrl+/. Freezes gameplay and draws a status line
--- plus a command line. Type a command and Enter to run it; Tab cycles
--- completions through a multi-column panel. Click or box-drag replaces the
--- selection; Shift adds, and Ctrl-drag moves the current selection.
---
--- The commands themselves live in the shared registry (tecs2d.debug.commands);
--- this module is the human surface: input, mouse gestures, completion,
--- history, and drawing. Agents reach the same registry over MCP through
--- the cmd_* command tools (cmd_context, cmd_select, ...).

local tecs <const> = require("tecs")
local input <const> = require("tecs2d.input")
local gfx <const> = require("tecs2d.gfx")
local gfxtypes <const> = require("tecs2d.gfx.types")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local core <const> = require("tecs2d.debug.internal.core")
local leader <const> = require("tecs2d.debug.internal.leader")
local commands <const> = require("tecs2d.debug.commands")
local Popup <const> = require("tecs2d.debug.internal.Popup")
local markup <const> = require("tecs2d.debug.internal.markup")
local completionview <const> =
    require("tecs2d.debug.internal.completionview")
local popupview <const> = require("tecs2d.debug.internal.popupview")
local toolworldkey <const> = require("tecs2d.debug.internal.toolworldkey")

local SECTION_MARK <const> = commands.SECTION_MARK

local Transform <const> = tecs.builtins.Transform

local lg <const> = require("tecs2d.debug.internal.debugdraw")

local type PopupState = Popup

-- One row of the right-click context menu: a label plus what activating it
-- does (run a registry command, fill the prompt, and/or copy to clipboard).
local record MenuRow
    label: string
    run: string
    fill: string
    clip: string
end

-- Context-menu state, one table so the input closure stays under LuaJIT's
-- 60-upvalue limit.
local record MenuState
    open: boolean
    rows: {MenuRow}
    header: string
    x: number
    y: number
    w: number
    rowH: number
    index: integer
    mouseX: number
    mouseY: number
    -- The click that activated or dismissed the menu is swallowed until the
    -- button releases, so it cannot become a phantom drag/box selection.
    swallow: boolean
end

-- Mouse-gesture state (drag select, Ctrl-move, middle-pan), one table so the
-- input closure stays under LuaJIT's 60-upvalue limit.
local record GestureState
    dragStartX: number
    dragStartY: number
    dragging: boolean
    -- True while the current left-button gesture began inside the world view;
    -- presses on the debugger chrome (or swallowed by the menu) must not drag.
    pressInView: boolean
    -- Shift state captured when the left gesture begins; releasing Shift
    -- before the mouse button must not change replace vs add semantics.
    selectionAdditive: boolean
    moving: boolean
    moveStartWX: number
    moveStartWY: number
    moveOrigins: {integer: {number}}
    panning: boolean
    panLastX: number
    panLastY: number
end

-- Selection/menu callbacks the mouse-gesture handler raises back into the
-- overlay; they carry the pick-query and menu wiring that stays inside
-- install(). Built once per install, never per frame.
local record GestureCallbacks
    selectArea: function(boolean)
    clickSelect: function(boolean)
    openMenuUnderMouse: function()
end

local MENU_HINT <const> = "menu: arrows + enter run a row, esc closes"

local format <const> = string.format
local getTime <const> = love.timer.getTime

local UNDER_MOUSE_PX <const> = 24         -- pick radius in screen pixels
local PAD_X <const> = 12                  -- horizontal padding inside the bars
local PAD_Y <const> = 4                   -- vertical padding inside the bars
local INFO_PAD_X <const> = 6
local POPUP_SCROLL_ROWS <const> = 3

local COMMAND_BAR <const>: {number} = {0.1804, 0.2157, 0.2353, 1}
local POPUP_ACCENT <const>: {number} = {0.66, 0.51, 0.90, 1}
local DEBUG_BG <const>: {number} = {0.58, 0.42, 0.82, 1}
local DEBUG_TEXT <const>: {number} = {0.94, 0.92, 0.98, 1}
local COMMAND_HINT <const>: {number} = {0.40, 0.40, 0.40, 1}
local POPUP_BG <const>: {number} = {0.1059, 0.0745, 0.1373, 1}
local CONTEXT_BG <const>: {number} = {0.1451, 0.1098, 0.1804, 1}
local ENTITY_LABEL_BG <const>: {number} = {0.11, 0.13, 0.16, 0.85}
local RECORDING_BG <const>: {number} = {0, 0, 0, 0.6}

local function coordinateLabel(ctx: debugcontext.Context): string
    return format("m %.0f,%.0f>%.0f,%.0f  c %.0f,%.0f z%.2f",
        ctx.mouseScreenX, ctx.mouseScreenY, ctx.mouseWorldX, ctx.mouseWorldY,
        ctx.cameraX, ctx.cameraY, ctx.cameraZoom)
end

local function compactCoordinateLabel(ctx: debugcontext.Context): string
    return format("m %.0f,%.0f  c %.0f,%.0f z%.2f",
        ctx.mouseWorldX, ctx.mouseWorldY,
        ctx.cameraX, ctx.cameraY, ctx.cameraZoom)
end

local function cameraLabel(ctx: debugcontext.Context): string
    return format("c %.0f,%.0f z%.2f",
        ctx.cameraX, ctx.cameraY, ctx.cameraZoom)
end

local function dismissPopup(popup: PopupState)
    popup:dismiss()
end

local function showPopup(popup: PopupState, lines: {string}, modal: boolean,
        title?: string, language?: string, semanticBlocks?: {{string}},
        closable?: boolean, imagePath?: string, maxColumns?: integer,
        document?: markup.Document, scrollToEnd?: boolean)
    if not lines and not document then return end
    popup:show({
        lines = lines or {},
        title = title,
        language = language,
        blocks = semanticBlocks,
        modal = modal,
        closable = closable,
        imagePath = imagePath,
        maxColumns = maxColumns,
        document = document,
        scrollToEnd = scrollToEnd,
    })
end

-- Entities already labeled this frame (a mark and a note can hit the same
-- entity); cleared at the start of each label pass so drawing allocates
-- nothing per frame.
-- Mark name / note star above one annotated entity.
local function drawEntityLabel(w: tecs.World, ctx: debugcontext.Context,
        cam: gfxtypes.Camera, font: lg.Font, eid: integer,
        labelSeen: {integer: boolean})
    if labelSeen[eid] then return end
    labelSeen[eid] = true
    if not w:isAlive(eid) then return end
    local t = w:get(eid, Transform)
    if not t then return end
    local label = ctx.marks[eid] or ""
    if ctx.notes[eid] then
        label = (label ~= "") and (label .. " *") or "*"
    end
    if label == "" then return end
    local sx, sy = cam:toScreen(t.x, t.y)
    local tw = font:getWidth(label)
    local scale = lg.getScreenScale()
    lg.setColor(0.8275, 0.7765, 0.6667, 1)
    lg.fitText("entityLabel." .. tostring(eid), label,
        sx / scale - tw / 2 - 5, sy / scale - 40, 5, 2,
        ENTITY_LABEL_BG, 3)
end

-- Mouse gestures while no context menu owns the mouse: a left press in the
-- world view starts a box-select drag (or a Ctrl-move of the selection),
-- release commits it, right-click opens the menu (or cancels a move),
-- middle-drag pans, and the wheel zooms toward the cursor. `view` is the
-- debugger's input layer; a press swallowed by the menu or on the chrome
-- rows never starts a drag (gesture.pressInView).
local function handleMouseGestures(gesture: GestureState, menu: MenuState, popup: PopupState,
        ctx: debugcontext.Context, w: tecs.World, view: input.View,
        pipeline: gfxtypes.Pipeline, inView: boolean, cb: GestureCallbacks)
    local shiftHeld = view.isKeyDown("lshift") or view.isKeyDown("rshift")
    local ctrlHeld = view.isKeyDown("lctrl") or view.isKeyDown("rctrl")

    -- A press that closed the menu stays swallowed until release.
    local swallowing = menu.swallow
    if swallowing and not view.isMouseDown(1) then
        menu.swallow = false
    end

    if view.isMousePressed(1) then
        gesture.pressInView = not swallowing and inView
        gesture.selectionAdditive = shiftHeld
    end
    if not swallowing and view.isMousePressed(1) and inView then
        -- Interacting with the world replaces reading the popup.
        dismissPopup(popup)
        if ctrlHeld and #ctx.selected > 0 then
            -- Begin moving the selection; record originals so a
            -- right-click can put them back.
            gesture.moving = true
            gesture.moveStartWX, gesture.moveStartWY = ctx.mouseWorldX, ctx.mouseWorldY
            gesture.moveOrigins = {}
            for i = 1, #ctx.selected do
                local eid = ctx.selected[i]
                if w:isAlive(eid) then
                    local t = w:get(eid, Transform)
                    if t then gesture.moveOrigins[eid] = {t.x, t.y} end
                end
            end
        else
            gesture.dragStartX = input.mouseX
            gesture.dragStartY = input.mouseY
            gesture.dragging = false
            ctx.hasArea = false
        end
    end
    if gesture.moving and view.isMouseDown(1) then
        -- Drag the selection to follow the cursor's world-space delta.
        local dx = ctx.mouseWorldX - gesture.moveStartWX
        local dy = ctx.mouseWorldY - gesture.moveStartWY
        for eid, origin in pairs(gesture.moveOrigins) do
            if w:isAlive(eid) then
                local t = w:getMut(eid, Transform)
                if t then
                    t.x = origin[1] + dx
                    t.y = origin[2] + dy
                end
            end
        end
    elseif gesture.pressInView and view.isMouseDown(1) then
        local moved = math.abs(input.mouseX - gesture.dragStartX) + math.abs(input.mouseY - gesture.dragStartY)
        if moved > 4 then
            gesture.dragging = true
        end
        if gesture.dragging and pipeline then
            local cam = pipeline:getCamera()
            ctx.hasArea = true
            ctx.areaX1, ctx.areaY1 = cam:toWorld(gesture.dragStartX, gesture.dragStartY)
            ctx.areaX2, ctx.areaY2 = ctx.mouseWorldX, ctx.mouseWorldY
        end
    end
    if not swallowing and view.isMouseReleased(1) then
        if gesture.moving then
            gesture.moving = false
            gesture.moveOrigins = {}
        elseif gesture.dragging then
            -- ctx.hasArea stays set: the released box keeps
            -- drawing and is the crop region for `screenshot`
            -- until the next left press clears it.
            cb.selectArea(gesture.selectionAdditive)
        elseif gesture.pressInView and inView then
            cb.clickSelect(gesture.selectionAdditive)
        end
        gesture.dragging = false
        gesture.pressInView = false
    end
    -- Right-click opens the context menu on the entity under the
    -- cursor, or the world position when nothing is there.
    if view.isMousePressed(2) and not gesture.moving and inView then
        cb.openMenuUnderMouse()
    end
    -- Right-click during a move cancels it, restoring the originals.
    if view.isMousePressed(2) and gesture.moving then
        for eid, origin in pairs(gesture.moveOrigins) do
            if w:isAlive(eid) then
                local t = w:getMut(eid, Transform)
                if t then
                    t.x = origin[1]
                    t.y = origin[2]
                end
            end
        end
        gesture.moving = false
        gesture.moveOrigins = {}
    end
    -- Middle-drag pans the camera: keep the grabbed world point under
    -- the cursor by moving the camera the opposite of the cursor's
    -- world-space delta (correct under any zoom/rotation).
    if view.isMousePressed(3) and inView then
        gesture.panning = true
        gesture.panLastX = input.mouseX
        gesture.panLastY = input.mouseY
    end
    if view.isMouseReleased(3) then
        gesture.panning = false
    end
    if gesture.panning and view.isMouseDown(3) and pipeline then
        local cam = pipeline:getCamera()
        local wx1, wy1 = cam:toWorld(gesture.panLastX, gesture.panLastY)
        local wx2, wy2 = cam:toWorld(input.mouseX, input.mouseY)
        local cx, cy = cam:getPosition()
        cam:setPosition(cx - (wx2 - wx1), cy - (wy2 - wy1))
        gesture.panLastX = input.mouseX
        gesture.panLastY = input.mouseY
    end

    -- Mouse wheel zooms toward the cursor: keep the world point under
    -- the cursor fixed while scaling the zoom.
    local _, wheelY = view.getMouseWheelMovement()
    if wheelY ~= 0 and pipeline and inView then
        dismissPopup(popup)
        local cam = pipeline:getCamera()
        local bx, by = cam:toWorld(input.mouseX, input.mouseY)
        local z = cam:getZoom() * (1.1 ^ wheelY)
        if z < 0.05 then z = 0.05 elseif z > 50 then z = 50 end
        cam:setZoom(z)
        local ax, ay = cam:toWorld(input.mouseX, input.mouseY)
        local cx, cy = cam:getPosition()
        cam:setPosition(cx + (bx - ax), cy + (by - ay))
    end
end

local record overlay
    --- Overlay options.
    record Options
        --- Leader modifier held with a toggle key (default "ctrl").
        leaderKey: string

        --- Key that, with the leader, toggles the debugger (default "/").
        debugToggleKey: string

        --- Key that, with the leader, toggles the stats HUD (default ".").
        --- Used for the keys help; the stats HUD itself handles the toggle.
        statsToggleKey: string

        --- Optional ffmpeg executable path/name (used for offline assembly).
        recordingFfmpegPath: string

        --- Optional save-directory subfolder for recording outputs.
        recordingOutputDir: string

        --- Optional default recording countdown in seconds.
        recordingCountdown: number

        --- Default recording capture FPS (default 30).
        recordingFps: integer

        --- Default recording output scale multiplier (default 1).
        recordingScale: number

        --- Captured image format: "png" (default), "tga", "jpg", or "bmp".
        recordingFrameFormat: string

        --- Max frames in flight before dropping (default 8).
        recordingRingSize: integer
    end

    --- Ensure the headless debugger core (context, registry, freeze,
    --- recorder, diagnostic visuals) and install the overlay systems on top of it.
    install: function(w: tecs.World, opts: Options): debugcontext.Context
end

function overlay.install(w: tecs.World, opts: overlay.Options): debugcontext.Context
    local leaderKey = opts.leaderKey
    local debugToggleKey = opts.debugToggleKey
    local statsToggleKey = opts.statsToggleKey
    -- The bundled atlas is authored at 64px. A 21px face size is its smallest
    -- reliably crisp UI scale; keep the chrome dense with padding, not by
    -- shrinking the glyph field below the atlas's useful reconstruction range.
    local overlayFont = lg.newFont(21)
    local labelSeen: {integer: boolean} = {}
    local wasTextInput = false
    local registry = core.ensure(w, {
        ffmpegPath = opts.recordingFfmpegPath,
        outputDir = opts.recordingOutputDir,
        countdown = opts.recordingCountdown,
        fps = opts.recordingFps,
        scale = opts.recordingScale,
        frameFormat = opts.recordingFrameFormat,
        ringSize = opts.recordingRingSize,
    })
    -- The help command reads env.keys at run time; install the configured
    -- bindings over the core's defaults.
    registry.env.keys = {leader = leaderKey, debugToggle = debugToggleKey, statsToggle = statsToggleKey}
    local ctx = registry.env.ctx
    local recorder = registry.env.recorder
    local fz = registry.env.suspension
    local tools = assert(w.resources[toolworldkey.KEY],
        "debug overlay requires its tool world")

    local pickQuery = w:query({name = "debug.Pick", include = {Transform}})

    -- UI-only state (not part of the shared context).
    local completions: {string} = {}
    local completionBase = ""
    local completionIndex = 0
    local cycling = false
    -- Tab and Backspace repeat after the same deliberate initial pause.
    local KEY_REPEAT_DELAY <const> = 0.35
    local KEY_REPEAT_INTERVAL <const> = 0.07
    local tabHeldFor = 0.0
    local tabRepeatIn = 0.0
    local backspaceHeldFor = 0.0
    local backspaceRepeatIn = 0.0
    local popupArrowHeld = ""
    local popupArrowHeldFor = 0.0
    local popupArrowRepeatIn = 0.0
    local gesture: GestureState = {
        dragStartX = 0.0,
        dragStartY = 0.0,
        dragging = false,
        pressInView = false,
        selectionAdditive = false,
        moving = false,
        moveStartWX = 0.0,
        moveStartWY = 0.0,
        moveOrigins = {},
        panning = false,
        panLastX = 0.0,
        panLastY = 0.0,
    }
    local historyPos = 0
    local popup = Popup.new()
    -- Right-click context menu state.
    local menu: MenuState = {
        open = false, rows = {}, header = "",
        x = 0, y = 0, w = 0, rowH = 0, index = 1,
        mouseX = 0, mouseY = 0, swallow = false,
    }
    local hideOverlayFrame = false
    local recorderLastAt = getTime()

    -- The debugger is runtime tooling, not a game state. Its stable input
    -- layer can be pushed above any game/menu layer and popped independently.
    -- The debugger belongs to the runtime lane: loading a game snapshot must
    -- restore game-owned input beneath the still-open tool overlay.
    local captureLayer <const> = input.newLayer("debugger", {snapshot = false})
    local function reader(): input.View
        if ctx.open and captureLayer:isActive() then
            return captureLayer.view
        end
        -- Closed, only framework-global controls are read. Raw input keeps the
        -- debugger toggle available over any game-owned input layer.
        return input.raw.view
    end

    local function leaderDown(): boolean
        return leader.isDown(reader(), leaderKey)
    end

    local function pickRadius(): number
        local z = ctx.cameraZoom
        if z <= 0 then z = 1 end
        return UNDER_MOUSE_PX / z
    end

    -- Entities within the pick radius of the cursor, nearest first.
    local function underMouse(): {integer}
        local r = pickRadius()
        local r2 = r * r
        local ids: {integer} = {}
        local dists: {number} = {}
        for archetype, len, entities in pickQuery:iter() do
            local transforms = archetype:get(Transform)
            for i = 1, len do
                local t = transforms[i]
                local dx = t.x - ctx.mouseWorldX
                local dy = t.y - ctx.mouseWorldY
                local d = dx * dx + dy * dy
                if d <= r2 then
                    ids[#ids + 1] = entities[i]
                    dists[#dists + 1] = d
                end
            end
        end
        -- Insertion sort by distance; the under-cursor set is small.
        for i = 2, #ids do
            local id = ids[i]
            local dv = dists[i]
            local j = i - 1
            while j >= 1 and dists[j] > dv do
                ids[j + 1] = ids[j]
                dists[j + 1] = dists[j]
                j = j - 1
            end
            ids[j + 1] = id
            dists[j + 1] = dv
        end
        return ids
    end

    -- Plain click replaces the selection; Shift-click adds the nearest entity.
    local function clickSelect(additive: boolean)
        local list = underMouse()
        if not additive then ctx.selected = {} end
        if #list == 0 then
            debugcontext.pushEvent(ctx, "selection", {selected = #ctx.selected, clicked = 0})
            return
        end
        local id = list[1]
        debugcontext.addSelected(ctx, id)
        debugcontext.pushEvent(ctx, "selection", {
            selected = #ctx.selected, clicked = id, additive = additive})
    end

    -- Drag release: plain drag replaces; Shift-drag adds box hits to the set.
    local function selectArea(additive: boolean)
        local minX = math.min(ctx.areaX1, ctx.areaX2)
        local maxX = math.max(ctx.areaX1, ctx.areaX2)
        local minY = math.min(ctx.areaY1, ctx.areaY2)
        local maxY = math.max(ctx.areaY1, ctx.areaY2)
        if not additive then ctx.selected = {} end
        local seen: {integer: boolean} = {}
        for i = 1, #ctx.selected do seen[ctx.selected[i]] = true end
        for archetype, len, entities in pickQuery:iter() do
            local transforms = archetype:get(Transform)
            for i = 1, len do
                local t = transforms[i]
                if t.x >= minX and t.x <= maxX and t.y >= minY and t.y <= maxY then
                    local eid = entities[i]
                    if not seen[eid] then
                        seen[eid] = true
                        ctx.selected[#ctx.selected + 1] = eid
                    end
                end
            end
        end
        debugcontext.pushEvent(ctx, "selection", {
            selected = #ctx.selected, boxed = true, additive = additive})
    end

    local function resetCompletions()
        cycling = false
        completionIndex = 0
        completions = {}
        completionBase = ""
        popup.barTop = 0
        popup.barBottom = 0
    end

    local function refreshCompletions()
        resetCompletions()
        if ctx.command == "" then return end
        completionBase, completions = registry:complete(ctx.command)
        cycling = #completions > 0
    end

    -- Wrapped command-line rows at the current window width, so long commands
    -- (set/spawn with Lua tables) wrap instead of running off screen. Used by
    -- both the draw pass and the input pass (click-through guard); cached on
    -- the prompt text and screen width so both passes share one getWrap call.
    local function commandLineRows(sw: number): {string}
        if popup.cmdRows and popup.cmdRowsText == ctx.command and popup.cmdRowsSw == sw then
            return popup.cmdRows
        end
        local _, wrapped = overlayFont:getWrap(":" .. ctx.command, sw - PAD_X * 3)
        if #wrapped == 0 then wrapped = {":"} end
        popup.cmdRowsText = ctx.command
        popup.cmdRowsSw = sw
        popup.cmdRows = wrapped
        return wrapped
    end

    local function showPreviewHelp(helpCmd: commands.Command)
        if popup.previewFor ~= helpCmd then
            popup.previewFor = helpCmd
            popup.previewDocument = commands.usageDocument(helpCmd)
        end
        showPopup(popup, {}, true, nil, nil, nil, true, nil, nil,
            popup.previewDocument)
    end

    local function executeCommand(text: string)
        local result = registry:execute(text)
        if not result then
            return
        end
        dismissPopup(popup)
        local document = result.popupDocument
        if result.popupMarkup then
            local parsed, err = markup.parse(result.popupMarkup)
            if not parsed then
                ctx.message = "popup markup: " .. err
                return
            end
            document = parsed
        end
        if result.popup or document then
            local firstWord = text:match("^%s*(%S+)")
            local modal = result.popupModal
            if modal == nil then modal = firstWord == "help" end
            showPopup(popup, result.popup, modal,
                result.popupTitle, result.popupLanguage, result.popupBlocks,
                result.popupClosable, result.popupImagePath,
                result.popupMaxColumns, document, result.popupScrollToEnd)
            ctx.message = ""
        end
        if result.message ~= nil then
            ctx.message = result.message
        end
    end

    -- A "debug" recording keeps the debugger visible while the game keeps
    -- running, so pan/zoom and dynamic lighting stay live on camera. It is
    -- active for the whole armed-through-stopping window of such a recording.
    local function debugRecordingActive(): boolean
        local s = ctx.recording.status
        return (s == "countdown" or s == "recording" or s == "stopping")
            and not recorder.hideDebuggerOnStart
    end

    local function closeMenu()
        menu.open = false
        menu.rows = {}
        ctx.menuOpen = false
        ctx.menuTarget = 0
        if ctx.message == MENU_HINT then
            ctx.message = ""
        end
    end

    -- Build and place the menu for an entity (or the world when eid is nil).
    local function openMenu(eid: integer)
        if eid then
            local id = tostring(eid)
            menu.header = "#" .. id
            menu.rows = {
                {label = "Info", run = "info " .. id},
                {label = "Mark...", run = "select " .. id .. " replace", fill = "mark "},
                {label = "Note...", run = "select " .. id .. " replace", fill = "note "},
                {label = "Copy ID", clip = id},
                {label = "Set...", fill = "set " .. id .. " "},
                {label = "Remove...", fill = "remove " .. id .. " "},
                {label = "Despawn", run = "despawn " .. id},
            }
        else
            local wx, wy = ctx.mouseWorldX, ctx.mouseWorldY
            menu.header = format("World @ %.1f, %.1f", wx, wy)
            menu.rows = {
                {label = "Copy Position", clip = format("%.1f, %.1f", wx, wy)},
                {label = "Spawn...", fill = "spawn "},
                {label = "Physics Query",
                    run = format("physics query %.1f %.1f 32 32", wx - 16, wy - 16)},
            }
            local tx, ty = commands.tileAt(w, ctx, wx, wy)
            if tx then
                menu.rows[#menu.rows + 1] = {
                    label = format("Tile %d, %d", tx, ty),
                    run = format("map info %.1f %.1f", wx, wy),
                }
            end
        end
        local fh = overlayFont:getHeight()
        menu.rowH = fh + 8
        menu.w = overlayFont:getWidth(menu.header)
        for i = 1, #menu.rows do
            local lw = overlayFont:getWidth(menu.rows[i].label)
            if lw > menu.w then menu.w = lw end
        end
        menu.w = menu.w + 28
        local totalH = menu.rowH * (#menu.rows + 1) + 8
        local mouseX = input.mouseX / lg.getScreenScale()
        local mouseY = input.mouseY / lg.getScreenScale()
        menu.x = math.min(mouseX, lg.getWidth() - menu.w)
        menu.y = math.min(mouseY, lg.getHeight() - totalH)
        if menu.x < 0 then menu.x = 0 end
        if menu.y < 0 then menu.y = 0 end
        menu.index = 1
        menu.mouseX = mouseX
        menu.mouseY = mouseY
        menu.open = true
        ctx.menuOpen = true
        ctx.menuTarget = eid or 0
        -- The menu replaces whatever popup was up, and the status bar says
        -- how to leave it.
        dismissPopup(popup)
        ctx.message = MENU_HINT
    end

    -- Menu rows go through the same registry path as typed commands.
    local function activateMenuRow(row: MenuRow)
        closeMenu()
        if row.clip then
            love.system.setClipboardText(row.clip)
            ctx.message = "copied: " .. row.clip
        end
        if row.run then
            executeCommand(row.run)
        end
        if row.fill then
            ctx.command = row.fill
            ctx.message = ""
            refreshCompletions()
        end
    end

    -- Menu row index at a screen position, or nil outside the rows.
    local function menuRowAt(mx: number, my: number): integer
        if mx < menu.x or mx > menu.x + menu.w then return nil end
        local ri = math.floor((my - (menu.y + menu.rowH + 4)) / menu.rowH) + 1
        if ri >= 1 and ri <= #menu.rows then return ri end
        return nil
    end

    -- Raised by handleMouseGestures; built once so the per-frame mouse path
    -- allocates nothing.
    local gestureCallbacks: GestureCallbacks = {
        selectArea = selectArea,
        clickSelect = clickSelect,
        openMenuUnderMouse = function()
            openMenu(underMouse()[1])
        end,
    }

    local function doOpen()
        recorder:stopForDebugOpen()
        ctx.open = true
        wasTextInput = love.keyboard.hasTextInput()
        love.keyboard.setTextInput(true)
        ctx.command = ""
        historyPos = 0
        resetCompletions()
        dismissPopup(popup)
        ctx.message = ""
        if not captureLayer:isActive() then
            input.pushLayer(captureLayer)
        end
        if not debugRecordingActive() then
            fz:suspend("debugger")
            ctx.frozen = true
        end
        debugcontext.pushEvent(ctx, "open")
    end

    local function doClose()
        closeMenu()
        ctx.open = false
        popup:dismiss()
        love.keyboard.setTextInput(wasTextInput)
        if captureLayer:isActive() then
            input.popLayer(captureLayer)
        end
        fz:resume("debugger")
        ctx.frozen = false
        debugcontext.pushEvent(ctx, "close")
    end

    -- Apply surface-directed side effects raised by commands (from the command
    -- line or over MCP): panel close and one-frame chrome hide.
    local function consumeSignals()
        local sig = registry.signals
        if sig.hideOverlay then
            sig.hideOverlay = false
            -- Only meaningful while the panel draws; a closed panel has no
            -- chrome to hide, and latching would skip a frame on next open.
            hideOverlayFrame = ctx.open
        end
        if sig.action == "exit" then
            sig.action = ""
            if ctx.open then doClose() end
        end
    end

    -- Input. RenderFirst so it runs while frozen; the event poller (outside the
    -- phase system) has already refreshed input state.
    w:addSystem({
        name = "debug.Input",
        phase = tecs.phases.RenderFirst,
        run = function()
            local now = getTime()
            local frameDt = now - recorderLastAt
            recorder:update(frameDt)
            recorderLastAt = now
            -- Recording interplay. A normal recording force-closes the panel
            -- once it starts (the countdown still shows it). A "debug" recording
            -- keeps the panel open and the game unfrozen (lifting the countdown
            -- freeze) so the live game is captured with the overlay. When it
            -- ends, an open panel re-freezes to restore the normal debugger.
            if ctx.recording.status == "recording" and recorder.hideDebuggerOnStart then
                if ctx.open then doClose() end
            elseif debugRecordingActive() then
                if ctx.frozen then
                    fz:resume("debugger")
                    ctx.frozen = false
                end
            elseif ctx.open and not ctx.frozen then
                fz:suspend("debugger")
                ctx.frozen = true
            end

            -- Toggle with Ctrl+<key>. Re-opening while profiling stops it.
            if leaderDown() and reader().isKeyPressed(debugToggleKey) then
                if ctx.open then
                    doClose()
                else
                    doOpen()
                    if registry.profiler.session then
                        showPopup(popup, registry:finishProfile(), false)
                    end
                end
            end

            -- A timed profile auto-finishes in debug.CoreTick; surface its
            -- results here, reopening the debugger so the operator sees them.
            if registry.profileResult then
                local profPopup = registry.profileResult
                registry.profileResult = nil
                if not ctx.open then doOpen() end
                showPopup(popup, profPopup, false)
            end

            if registry.breakpointResult then
                local result = registry.breakpointResult
                registry.breakpointResult = nil
                if not ctx.open then doOpen() end
                showPopup(popup, result.popup, false,
                    result.popupTitle, result.popupLanguage,
                    result.popupBlocks, result.popupClosable,
                    result.popupImagePath, result.popupMaxColumns,
                    result.popupDocument, result.popupScrollToEnd)
            end

            -- Commands invoked over MCP may raise signals while the panel is
            -- closed (e.g. a screenshot's chrome hide); honor them every frame.
            consumeSignals()

            if not ctx.open then
                return
            end

            -- Sample pointer + camera.
            ctx.mouseScreenX = input.mouseX
            ctx.mouseScreenY = input.mouseY
            local pipeline = w.resources[pipelinekey.PIPELINE]
            if pipeline then
                local cam = pipeline:getCamera()
                ctx.mouseWorldX, ctx.mouseWorldY = cam:toWorld(input.mouseX, input.mouseY)
                ctx.cameraX, ctx.cameraY = cam:getPosition()
                ctx.cameraZoom = cam:getZoom()
                ctx.cameraRotation = cam:getRotation()
                ctx.cameraW, ctx.cameraH = cam:getVisibleDimensions()
            end

            -- The open context menu owns the keyboard: arrows move, Enter
            -- activates, Escape closes. Everything below is gated for the
            -- frame so closing cannot double-trigger handlers.
            local menuTookInput = menu.open
            if menuTookInput then
                if reader().isKeyPressed("escape") then
                    closeMenu()
                end
                if reader().isKeyPressed("down") and #menu.rows > 0 then
                    menu.index = menu.index % #menu.rows + 1
                end
                if reader().isKeyPressed("up") and #menu.rows > 0 then
                    menu.index = (menu.index - 2) % #menu.rows + 1
                end
                if (reader().isKeyPressed("return") or reader().isKeyPressed("kpenter"))
                    and menu.rows[menu.index] then
                    activateMenuRow(menu.rows[menu.index])
                end
            end

            -- Leader+Y yanks the last command's output to the clipboard.
            if leaderDown() and reader().isKeyPressed("y") then
                local lines = registry.lastOutput
                if lines and #lines > 0 then
                    love.system.setClipboardText(commands.flattenOutput(lines))
                    ctx.message = "yanked " .. tostring(#lines) .. " line(s) to clipboard"
                else
                    ctx.message = "nothing to yank yet"
                end
            end

            -- Ctrl+C clears prompt state. Escape clears the same state first,
            -- then closes the debugger once there is nothing left to clear.
            local hasPromptState = ctx.command ~= "" or popup.shown or cycling
            if leaderDown() and reader().isKeyPressed("c") then
                ctx.command = ""
                historyPos = 0
                dismissPopup(popup)
                resetCompletions()
            end
            if not menuTookInput and reader().isKeyPressed("escape") then
                if hasPromptState then
                    ctx.command = ""
                    historyPos = 0
                    dismissPopup(popup)
                    resetCompletions()
                else
                    registry.signals.action = "exit"
                end
            end

            -- Command line editing. The input stack clears pending text on
            -- push/pop, so nothing typed to toggle the panel leaks in here and
            -- the toggle character itself stays typeable (e.g. "/" in a path).
            local textInput <const> = reader().getTextInput()
            if not menuTookInput and not leaderDown() and textInput ~= "" then
                ctx.command = ctx.command .. textInput
                ctx.message = ""
                dismissPopup(popup)
                refreshCompletions()
            end
            local backspaceStep = reader().isKeyPressed("backspace")
            if reader().isKeyDown("backspace") then
                backspaceHeldFor = backspaceHeldFor + frameDt
                if not backspaceStep and backspaceHeldFor >= KEY_REPEAT_DELAY then
                    backspaceRepeatIn = backspaceRepeatIn - frameDt
                    if backspaceRepeatIn <= 0 then
                        backspaceStep = true
                        backspaceRepeatIn = KEY_REPEAT_INTERVAL
                    end
                end
            else
                backspaceHeldFor = 0.0
                backspaceRepeatIn = 0.0
            end
            if not menuTookInput and backspaceStep then
                ctx.command = ctx.command:sub(1, -2)
                ctx.message = ""
                dismissPopup(popup)
                refreshCompletions()
            end
            -- Delete despawns the current selection outright.
            if not menuTookInput and reader().isKeyPressed("delete") then
                ctx.message = "despawned " .. tostring(registry:despawnSelected()) .. " selected"
            end
            -- Tab completes the word under the cursor: the command name, a
            -- subcommand verb, or a per-command source (component names, mark
            -- names, systems, ...). Candidates come from the registry, so
            -- custom commands complete too. Holding Tab key-repeats the cycle.
            local tabStep = reader().isKeyPressed("tab")
            if reader().isKeyDown("tab") then
                tabHeldFor = tabHeldFor + frameDt
                if not tabStep and cycling and tabHeldFor >= KEY_REPEAT_DELAY then
                    tabRepeatIn = tabRepeatIn - frameDt
                    if tabRepeatIn <= 0 then
                        tabStep = true
                        tabRepeatIn = KEY_REPEAT_INTERVAL
                    end
                end
            else
                tabHeldFor = 0.0
                tabRepeatIn = 0.0
            end
            if tabStep and not menuTookInput then
                ctx.message = ""
                local followHelp = popup.shown
                    and popup.document == popup.previewDocument
                if not followHelp then dismissPopup(popup) end
                local backward = reader().isKeyDown("lshift") or reader().isKeyDown("rshift")
                if not cycling then
                    completionBase, completions = registry:complete(ctx.command)
                    completionIndex = 0
                    cycling = true
                end
                if #completions > 0 then
                    -- Section separator entries render in the strip but are
                    -- skipped while cycling.
                    repeat
                        if backward then
                            completionIndex = completionIndex - 1
                            if completionIndex < 1 then completionIndex = #completions end
                        else
                            completionIndex = (completionIndex % #completions) + 1
                        end
                    until completions[completionIndex]:sub(1, 1) ~= SECTION_MARK
                    ctx.command = completionBase .. completions[completionIndex]
                    if followHelp then
                        popup.lastCommandLine = ctx.command
                        local previewWord = ctx.command:match("^(%S+)")
                        popup.previewCmd = previewWord and registry.byName[previewWord]
                        if popup.previewCmd then
                            showPreviewHelp(popup.previewCmd)
                        else
                            dismissPopup(popup)
                        end
                    end
                end
            end
            -- A visible popup owns navigation through the debugger input
            -- layer. Up/Down repeat independently of the OS key-repeat rate;
            -- Page Up/Down move one viewport and Home/End jump absolutely.
            local history = registry.history
            if popup.shown and not menuTookInput then
                local held = ""
                if reader().isKeyDown("up") then
                    held = "up"
                elseif reader().isKeyDown("down") then
                    held = "down"
                end
                local heldChanged = held ~= popupArrowHeld
                if heldChanged then
                    popupArrowHeld = held
                    popupArrowHeldFor = 0
                    popupArrowRepeatIn = 0
                end
                -- The transition supplies the first step; subsequent steps
                -- come only from this timer, so OS repeat events cannot make
                -- scrolling run at a platform-dependent double rate.
                local arrowStep = held ~= "" and heldChanged
                if held ~= "" then
                    popupArrowHeldFor = popupArrowHeldFor + frameDt
                    if not arrowStep and popupArrowHeldFor >= KEY_REPEAT_DELAY then
                        popupArrowRepeatIn = popupArrowRepeatIn - frameDt
                        if popupArrowRepeatIn <= 0 then
                            arrowStep = true
                            popupArrowRepeatIn = KEY_REPEAT_INTERVAL
                        end
                    end
                else
                    popupArrowHeldFor = 0
                    popupArrowRepeatIn = 0
                end

                local pageRows = math.max(1, popup.visibleRows)
                if reader().isKeyPressed("home") then
                    popup.scroll = 0
                elseif reader().isKeyPressed("end") then
                    popup.scroll = popup.scrollMax
                elseif reader().isKeyPressed("pageup") then
                    popup.scroll = math.max(0, popup.scroll - pageRows)
                elseif reader().isKeyPressed("pagedown") then
                    popup.scroll = math.min(popup.scrollMax,
                        popup.scroll + pageRows)
                elseif arrowStep then
                    local direction = (held == "up") and -1 or 1
                    popup.scroll = math.max(0, math.min(popup.scrollMax,
                        popup.scroll + direction))
                end
            else
                popupArrowHeld = ""
                popupArrowHeldFor = 0
                popupArrowRepeatIn = 0
                -- Without a popup, Up/Down browse persisted history.
                if not menuTookInput and reader().isKeyPressed("up")
                    and #history > 0 then
                    if historyPos < #history then historyPos = historyPos + 1 end
                    ctx.command = history[#history - historyPos + 1]
                    ctx.message = ""
                    dismissPopup(popup)
                    refreshCompletions()
                end
                if not menuTookInput and reader().isKeyPressed("down") then
                    if historyPos > 0 then historyPos = historyPos - 1 end
                    ctx.command = (historyPos == 0) and ""
                        or history[#history - historyPos + 1]
                    ctx.message = ""
                    dismissPopup(popup)
                    refreshCompletions()
                end
            end
            -- Enter runs the line once; an empty line is a no-op so mashing
            -- Enter after a command cannot re-run anything.
            if not menuTookInput
                and (reader().isKeyPressed("return") or reader().isKeyPressed("kpenter"))
                and ctx.command ~= "" then
                registry:appendHistory(ctx.command)
                executeCommand(ctx.command)
                ctx.command = ""
                historyPos = 0
                resetCompletions()
            end

            -- Resolve the command named by the prompt for inline short help.
            -- Full usage is opt-in with F1 instead of obscuring the world on
            -- every command selection or keystroke.
            if ctx.command ~= popup.lastCommandLine then
                popup.lastCommandLine = ctx.command
                local previewWord = ctx.command:match("^(%S+)")
                popup.previewCmd = previewWord and registry.byName[previewWord]
            end
            if not menuTookInput and reader().isKeyPressed("f1") then
                local helpCmd = popup.previewCmd
                if helpCmd then
                    if popup.shown and popup.document == popup.previewDocument then
                        dismissPopup(popup)
                    else
                        showPreviewHelp(helpCmd)
                    end
                elseif popup.shown then
                    dismissPopup(popup)
                else
                    executeCommand("help")
                end
            end

            -- A command run this frame may have raised exit/quit.
            consumeSignals()
            if not ctx.open then
                return
            end

            -- Mouse. The status and command rows occupy the bottom edge;
            -- while cycling, the completion grid replaces the status row and
            -- grows upward from the command row.
            -- Hit rectangles come from the previous draw pass.
            local ifh = overlayFont:getHeight()
            local cmdBarH = ifh + PAD_Y * 2 +
                (#commandLineRows(lg.getWidth()) - 1) * ifh
            local contextH = ifh + PAD_Y * 2
            local contextY = lg.getHeight() - cmdBarH - contextH
            local chromeTop = contextY
            local completionVisible = cycling and #completions > 0
                and not (popup.shown and popup.modal)
            if completionVisible and popup.barTop > 0 then
                chromeTop = popup.barTop
            end
            local uiMouseX = input.mouseX / lg.getScreenScale()
            local uiMouseY = input.mouseY / lg.getScreenScale()
            local inView = uiMouseY < chromeTop
                and not (popup.shown and popup.modal)

            -- A closable popup's title control owns its press. Swallow the
            -- gesture through release so closing cannot begin a world drag.
            if not menu.open and reader().isMousePressed(1)
                    and popup:pressClose(uiMouseX, uiMouseY) then
                menu.swallow = true
                inView = false
            end

            -- A modal popup owns the wheel anywhere; ordinary command-output
            -- popups own it while hovered. Both consume it before completion
            -- scrolling or camera zoom beneath the debugger.
            local _, wheelY = reader().getMouseWheelMovement()
            local overPopup = popup.shown and (popup.modal
                or (uiMouseX >= popup.panelX
                    and uiMouseX <= popup.panelX + popup.panelW
                    and uiMouseY >= popup.panelY
                    and uiMouseY <= popup.panelY + popup.panelH))
            if not menu.open and overPopup and wheelY ~= 0 then
                popup.scroll = math.max(0, math.min(popup.scrollMax,
                    popup.scroll - wheelY * POPUP_SCROLL_ROWS))
                inView = false
            -- Wheel over the completion grid scrolls its columns horizontally
            -- and never reaches camera zoom.
            elseif not menu.open and completionVisible
                and uiMouseY >= popup.barTop
                and uiMouseY <= popup.barBottom and wheelY ~= 0 then
                popup.barScroll = popup.barScroll - wheelY * 120
                popup.barScrollForIndex = completionIndex
                inView = false
            end

            if not menu.open and completionVisible
                and reader().isMousePressed(1)
                and uiMouseY >= popup.barTop
                and uiMouseY <= popup.barBottom then
                for hi = 1, popup.barHitCount do
                    local hx = popup.barHitX[hi]
                    local hy = popup.barHitY[hi]
                    if uiMouseX >= hx and uiMouseX <= hx + popup.barHitW[hi]
                        and uiMouseY >= hy
                        and uiMouseY <= hy + popup.barHitH[hi] then
                        completionIndex = popup.barHitValue[hi]
                        if completions[completionIndex] then
                            ctx.command = completionBase .. completions[completionIndex]
                            ctx.message = ""
                            dismissPopup(popup)
                            refreshCompletions()
                        end
                        break
                    end
                end
            end

            -- The open context menu owns the mouse: hover highlights, click
            -- activates or closes, right-click closes.
            local menuAteMouse = menu.open
            if menuAteMouse then
                local hover = menuRowAt(uiMouseX, uiMouseY)
                local mouseMoved = uiMouseX ~= menu.mouseX or uiMouseY ~= menu.mouseY
                menu.mouseX = uiMouseX
                menu.mouseY = uiMouseY
                if mouseMoved and hover then menu.index = hover end
                if reader().isMousePressed(1) then
                    menu.swallow = true
                    if hover then
                        activateMenuRow(menu.rows[hover])
                    else
                        closeMenu()
                    end
                end
                if reader().isMousePressed(2) then
                    closeMenu()
                end
            end
            if not menuAteMouse then
                handleMouseGestures(gesture, menu, popup, ctx, w, reader(),
                    pipeline, inView, gestureCallbacks)
            end
        end
    })

    -- Recording indicator (remaining/elapsed time). Drawn only on frames that
    -- are NOT being captured, so the game renders it for the operator but it
    -- never appears in the recorded video. Runs after the core's capture
    -- system so capturedThisFrame is current.
    w:addSystem({
        name = "debug.RecordingIndicator",
        phase = tecs.phases.RenderLast,
        before = {"love.Present"},
        run = function()
            if ctx.recording.status ~= "recording" or recorder.capturedThisFrame then
                lg.releaseOwner("recording")
                return
            end
            local r = ctx.recording
            local text: string
            if r.duration > 0 then
                local remaining = math.max(0, r.duration - (getTime() - r.startedAt))
                text = format("REC  %ds left", math.ceil(remaining))
            else
                local elapsed = getTime() - r.startedAt
                text = format("REC  %d:%02d", math.floor(elapsed / 60), math.floor(elapsed % 60))
            end
            lg.setFont(overlayFont)
            lg.beginOwner("recording")
            local pad = 6
            local label = "   " .. text
            local boxW = overlayFont:getWidth(label) + pad * 2
            local boxH = overlayFont:getHeight() + pad
            lg.beginLayout("layout", -boxW - pad, pad, boxW, boxH,
                0, 0, boxW, boxH, 1, 0)
            lg.setColor(1, 1, 1, 1)
            lg.fitText("panel", label, 0, 0, pad, pad / 2, RECORDING_BG, 6)
            lg.setColor(1, 0.2, 0.15, 1)
            lg.circle("dot", "fill", pad + 4, boxH / 2, 5)
            lg.endLayout()
            lg.endOwner()
        end,
    })

    -- Overlay draw.
    w:addSystem({
        name = "debug.Overlay",
        -- RenderLast puts debugger chrome above user Render/PostRender systems;
        -- the explicit edge keeps it immediately before the frame is presented.
        phase = tecs.phases.RenderLast,
        before = {"love.Present"},
        run = function()
            if not ctx.open then
                lg.releaseOwner("overlay")
                return
            end
            -- Skip drawing the chrome for one frame while a screenshot captures.
            if hideOverlayFrame then
                hideOverlayFrame = false
                return
            end

            lg.setFont(overlayFont)
            lg.beginOwner("overlay")

            local fh = overlayFont:getHeight()
            local rowH = fh + PAD_Y * 2
            local sw = lg.getWidth()
            local pipeline = w.resources[pipelinekey.PIPELINE]

            if ctx.recording.status == "countdown" then
                local label = "RECORDING IN " .. tostring(math.ceil(ctx.recording.countdown))
                lg.setColor(0, 0, 0, 0.72)
                lg.rectangle("recordingModal.background", "fill", 0, 0, sw, rowH * 2)
                lg.setColor(1, 0.18, 0.12, 1)
                lg.printf("recordingModal.text", label, 0, PAD_Y, sw, "center")
            elseif ctx.recording.status == "stopping" then
                lg.setColor(0, 0, 0, 0.72)
                lg.rectangle("recordingModal.background", "fill", 0, 0, sw, rowH * 2)
                lg.setColor(1, 0.85, 0.2, 1)
                lg.printf("recordingModal.text", "STOPPING RECORDING",
                    0, PAD_Y, sw, "center")
            end

            -- Drag-selected area (world -> screen).
            if ctx.hasArea and pipeline then
                local cam = pipeline:getCamera()
                local x1, y1 = cam:toScreen(ctx.areaX1, ctx.areaY1)
                local x2, y2 = cam:toScreen(ctx.areaX2, ctx.areaY2)
                local rx = math.min(x1, x2)
                local ry = math.min(y1, y2)
                lg.setColor(0.3, 0.7, 1.0, 0.15)
                lg.batchRectangle("fill", rx, ry,
                    math.abs(x2 - x1), math.abs(y2 - y1))
                lg.setColor(0.4, 0.8, 1.0, 0.9)
                lg.setLineWidth(1)
                lg.batchRectangle("line", rx, ry,
                    math.abs(x2 - x1), math.abs(y2 - y1))
            end

            -- Selection membership is independent of its visualization. Only
            -- visible markers are submitted, and PrimitiveBatch draws them in a
            -- single mesh without consuming one tool-world entity per mark.
            if pipeline and #ctx.selected > 0 then
                local cam = pipeline:getCamera()
                for i = 1, #ctx.selected do
                    local sid = ctx.selected[i]
                    if w:isAlive(sid) then
                        local t = w:get(sid, Transform)
                        if t then
                            local sx, sy = cam:toScreen(t.x, t.y)
                            local r = 14
                            if sx >= -20 and sx <= sw + 20
                                    and sy >= -20 and sy <= lg.getHeight() + 20 then
                                if not lg.selectionMarker(sx, sy, r) then break end
                            end
                        end
                    end
                end
            end

            -- Cyan target around the context menu's entity, outside the
            -- selection square so both stay readable together.
            if pipeline and menu.open and ctx.menuTarget ~= 0 and w:isAlive(ctx.menuTarget) then
                local cam = pipeline:getCamera()
                local t = w:get(ctx.menuTarget, Transform)
                if t then
                    local sx, sy = cam:toScreen(t.x, t.y)
                    local r = 20
                    lg.setColor(0.35, 0.85, 1.0, 1)
                    lg.setLineWidth(2)
                    lg.batchRectangle("line", sx - r, sy - r, r * 2, r * 2)
                    lg.batchLine(sx, sy - r - 8, sx, sy - r + 6)
                    lg.batchLine(sx, sy + r - 6, sx, sy + r + 8)
                    lg.batchLine(sx - r - 8, sy, sx - r + 6, sy)
                    lg.batchLine(sx + r - 6, sy, sx + r + 8, sy)
                end
            end

            -- Mark names / note markers above annotated entities, so it is
            -- visible in-game which entities carry marks or notes.
            if pipeline then
                local cam = pipeline:getCamera()
                for k in pairs(labelSeen) do labelSeen[k] = nil end
                for eid in pairs(ctx.marks) do
                    drawEntityLabel(w, ctx, cam, overlayFont, eid, labelSeen)
                end
                for eid in pairs(ctx.notes) do
                    drawEntityLabel(w, ctx, cam, overlayFont, eid, labelSeen)
                end
            end

            -- Helix-style bottom chrome: context above, command line below.
            -- Completions replace context while cycling and grow upward in
            -- columns from the command line.
            local cmdLines = commandLineRows(sw)
            local cmdBarH = rowH + (#cmdLines - 1) * fh
            local contextH = rowH
            local commandY = lg.getHeight() - cmdBarH
            local contextY = commandY - contextH

            local helpModal = popup.shown and popup.modal
            if cycling and #completions > 0 and not helpModal then
                local completionHint = "completion"
                if popup.previewCmd then
                    completionHint = popup.previewCmd.shortHelp
                end
                lg.setFont(overlayFont)
                completionview.draw(popup, completions, overlayFont,
                    completionIndex, sw, commandY, completionHint)
            end

            local bottomH = contextH + cmdBarH
            lg.beginLayout("bottom.chrome", 0, -bottomH, sw, bottomH,
                0, 0, sw, bottomH, 0, 1)
            local contextLocalY = 0
            local commandLocalY = contextH

            -- Context row: mode/selection at left and pointer/camera
            -- coordinates at right. Completion mode covers this row.
            if not cycling or #completions == 0 or helpModal then
                local badge = "DEBUG"
                local badgeW = overlayFont:getWidth(badge) + INFO_PAD_X * 2
                -- The two status surfaces meet at badgeW without overlap.
                -- Overlapping opaque GPU rectangles could leave the badge
                -- behind the context row until another popup changed shape
                -- registration order.
                lg.setColor(DEBUG_BG[1], DEBUG_BG[2], DEBUG_BG[3], 1)
                lg.rectangle("status.badgeBackground", "fill",
                    0, contextLocalY, badgeW, contextH)
                lg.setColor(CONTEXT_BG[1], CONTEXT_BG[2], CONTEXT_BG[3], 1)
                lg.rectangle("status.background", "fill",
                    badgeW, contextLocalY, sw - badgeW, contextH)
                local coords = coordinateLabel(ctx)
                local maxCoordsW = math.max(0, sw - badgeW - INFO_PAD_X * 2)
                if overlayFont:getWidth(coords) > maxCoordsW then
                    coords = compactCoordinateLabel(ctx)
                end
                if overlayFont:getWidth(coords) > maxCoordsW then
                    coords = cameraLabel(ctx)
                end
                if overlayFont:getWidth(coords) > maxCoordsW then
                    coords = ""
                end
                local coordsW = coords == "" and 0
                    or overlayFont:getWidth(coords) + INFO_PAD_X * 2
                lg.setFont(overlayFont)
                lg.beginLayout("status.content", 0, contextLocalY,
                    math.max(0, sw - coordsW), contextH)
                local statusTail = format("  %s  selected %d  %d fps",
                    ctx.frozen and "paused" or "live", #ctx.selected,
                    math.floor(love.timer.getFPS()) as integer)
                local status = badge .. statusTail
                local showTail = overlayFont:getWidth(status)
                    + INFO_PAD_X * 2 <= sw - coordsW
                local statusTextY = PAD_Y
                lg.setColor(DEBUG_TEXT[1], DEBUG_TEXT[2], DEBUG_TEXT[3], 1)
                lg.print("status.badge", badge, INFO_PAD_X - 2, statusTextY + 2)
                if showTail then
                    lg.setColor(0.72, 0.66, 0.84, 1)
                    lg.print("status.tail", statusTail, badgeW, statusTextY)
                end
                local statusW = showTail and
                    (badgeW + overlayFont:getWidth(statusTail)) or badgeW
                local messageX = INFO_PAD_X + statusW + INFO_PAD_X * 3
                if ctx.message ~= "" then
                    if messageX < sw - coordsW then
                        lg.setColor(0.66, 0.60, 0.74, 1)
                        lg.print("status.message", ctx.message, messageX, statusTextY)
                    end
                end
                lg.endLayout()
                if coords ~= "" then
                    lg.setColor(0.8275, 0.7765, 0.6667, 1)
                    lg.print("status.coords", coords,
                        sw - overlayFont:getWidth(coords) - INFO_PAD_X,
                        contextLocalY + statusTextY)
                end
            end

            -- Long commands wrap upward within the bottom command row.
            lg.setFont(overlayFont)
            lg.setColor(COMMAND_BAR[1], COMMAND_BAR[2],
                COMMAND_BAR[3], COMMAND_BAR[4])
            lg.rectangle("command.background", "fill",
                0, commandLocalY, sw, cmdBarH)
            lg.setColor(0.8275, 0.7765, 0.6667, 1)
            for i = 1, #cmdLines do
                lg.print("command.line." .. tostring(i), cmdLines[i],
                    PAD_X, commandLocalY + PAD_Y + (i - 1) * fh)
            end
            -- Tall block cursor at the end of the last wrapped row.
            local cursorX = PAD_X + overlayFont:getWidth(cmdLines[#cmdLines])
            local cursorY = commandLocalY + PAD_Y + (#cmdLines - 1) * fh
            local blockW = overlayFont:getWidth("0")
            local cursorColor = tools.world:get(tools.cursorAlphaEntity, gfx.Color)
            lg.setColor(0.8275, 0.7765, 0.6667, cursorColor.a)
            lg.alphaRectangle("command.cursor", "fill",
                cursorX + 1, cursorY, blockW, fh)
            if ctx.command == "" then
                lg.setColor(COMMAND_HINT[1], COMMAND_HINT[2], COMMAND_HINT[3], 1)
                local enterHint = "Enter command..."
                local hintX = cursorX + blockW + INFO_PAD_X * 2
                lg.print("command.commandHint", enterHint, hintX, cursorY)
                lg.print("command.autocompleteHint", "[TAB] to autocomplete",
                    hintX + overlayFont:getWidth(enterHint) + INFO_PAD_X * 2,
                    cursorY)
            end
            lg.endLayout()

            -- Context menu: dark panel, header row, hover/keyboard highlight.
            if menu.open then
                local mfh = overlayFont:getHeight()
                local totalH = menu.rowH * (#menu.rows + 1) + 8
                lg.setFont(overlayFont)
                lg.beginLayout("menu.layout", menu.x, menu.y, menu.w, totalH)
                lg.setColor(POPUP_BG[1], POPUP_BG[2], POPUP_BG[3], 0.98)
                lg.rectangle("menu.background", "fill",
                    0, 0, menu.w, totalH, 4, 4)
                lg.setColor(POPUP_ACCENT[1], POPUP_ACCENT[2],
                    POPUP_ACCENT[3], 0.75)
                lg.setLineWidth(1)
                lg.rectangle("menu.border", "line",
                    0, 0, menu.w, totalH, 4, 4)
                lg.setColor(POPUP_ACCENT[1], POPUP_ACCENT[2],
                    POPUP_ACCENT[3], 1)
                lg.print("menu.header", menu.header, 12, 6)
                for i = 1, #menu.rows do
                    local ry = menu.rowH * i + 4
                    if i == menu.index then
                        lg.setColor(0.25, 0.32, 0.40, 1)
                        lg.rectangle("menu.selection", "fill", 4, ry,
                            menu.w - 8, menu.rowH - 2, 3, 3)
                    end
                    lg.setColor(0.8275, 0.7765, 0.6667, 1)
                    lg.print("menu.row." .. tostring(i), menu.rows[i].label,
                        12, ry + (menu.rowH - mfh) / 2)
                end
                lg.endLayout()
            end

            -- Command output/help draws last. F1/help popups add a scrim, so
            -- their contracts remain legible above menus, chrome, and game UI.
            if popup.shown and (#popup.lines > 0 or popup.title or popup.document) then
                popupview.draw(popup, overlayFont, sw, contextY, PAD_X)
            end

            lg.endOwner()
        end
    })

    return ctx
end

return overlay
