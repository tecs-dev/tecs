--- In-game debugger overlay (micro-editor style command mode). Installed by the
--- debug plugin; toggled with Ctrl+/. Freezes gameplay and draws a status line
--- plus a command line. Type a command and Enter to run it; Tab cycles
--- completions. Click toggles the entity under the cursor in the selection;
--- drag box-selects; Shift+drag moves the selection.
---
--- The commands themselves live in the shared registry (tecs2d.debug.commands);
--- this module is the human surface: input, mouse gestures, completion,
--- history, and drawing. Agents reach the same registry over MCP
--- (get_debug_context and the debug_* command tools).

local tecs <const> = require("tecs")
local input <const> = require("tecs2d.input")
local gfxtypes <const> = require("tecs2d.gfx.types")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local recording <const> = require("tecs2d.debug.internal.recording")
local freeze <const> = require("tecs2d.debug.internal.freeze")
local annotations <const> = require("tecs2d.debug.internal.annotations")
local leader <const> = require("tecs2d.debug.internal.leader")
local rewind <const> = require("tecs2d.debug.internal.rewind")
local commands <const> = require("tecs2d.debug.commands")

local HRULE <const> = commands.HRULE
local SECTION_MARK <const> = commands.SECTION_MARK

local Transform <const> = tecs.builtins.Transform

local lg <const> = love.graphics

-- One vertical slice of a popup body laid out in columns: its lines, the
-- tab-split cells, per-tab x offsets, and total pixel width.
local record PopupBlock
    lines: {string}
    rows: {{string}}
    colX: {number}
    width: number
end

-- Popup panel state (lines, visibility, paging, optional thumbnail), one
-- table so the overlay closures stay under LuaJIT's 60-upvalue limit. Also
-- carries the overlay's per-frame draw caches (popup layout, auto-preview,
-- wrapped prompt rows, Tab-cycle bar) so the render path allocates nothing
-- while its inputs are unchanged.
local record PopupState
    lines: {string}
    shown: boolean
    page: integer
    -- Thumbnail drawn under the popup (screenshot info); lives exactly as
    -- long as the popup does and is released on dismissal.
    image: love.graphics.Image
    -- Measured popup layout, valid while the lines table reference, screen
    -- width, and per-page row count are unchanged; paging reuses it.
    measuredLines: {string}
    measuredSw: number
    measuredPerPage: integer
    blocks: {PopupBlock}
    pageGroups: {{integer}}
    -- Auto-preview: the last seen command line, the command it names, and
    -- the usage popup built for that command.
    lastCommandLine: string
    previewCmd: commands.Command
    previewFor: commands.Command
    previewLines: {string}
    -- Wrapped command-line rows keyed on prompt text and screen width; the
    -- input pass (bar height) and the draw pass share one getWrap call.
    cmdRowsText: string
    cmdRowsSw: number
    cmdRows: {string}
    -- Tab-cycle bar layout, rebuilt when completions are assigned: display
    -- labels, section names for pills, per-label widths, and x offsets.
    barLabels: {string}
    barSectionOf: {integer: string}
    barWidths: {number}
    barX: {number}
end

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
    -- The click that activated or dismissed the menu is swallowed until the
    -- button releases, so it cannot become a phantom drag/box selection.
    swallow: boolean
end

-- Mouse-gesture state (drag select, shift-move, middle-pan), one table so the
-- input closure stays under LuaJIT's 60-upvalue limit.
local record GestureState
    dragStartX: number
    dragStartY: number
    dragging: boolean
    -- True while the current left-button gesture began inside the world view;
    -- presses on the toolbar rows (or swallowed by the menu) must not drag.
    pressInView: boolean
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
    selectArea: function()
    clickSelect: function()
    openMenuUnderMouse: function()
end

local MENU_HINT <const> = "menu: arrows + enter run a row, esc closes"

-- Pill shade for completion sections without an accent color.
local DEFAULT_PILL <const>: {number} = {0.22, 0.27, 0.30}

local format <const> = string.format
local getTime <const> = love.timer.getTime

local UNDER_MOUSE_PX <const> = 24         -- pick radius in screen pixels
local ENTITY_COUNT_INTERVAL <const> = 0.5 -- seconds between status-bar entity-count refreshes
local PAD_X <const> = 18                  -- horizontal padding inside the bars
local PAD_Y <const> = 8                   -- vertical padding inside the bars

local function releasePopupImage(popup: PopupState)
    if popup.image then
        -- Free the GPU texture now rather than at the next GC cycle.
        local obj = popup.image as love.Object
        obj:release()
        popup.image = nil
    end
end

local function dismissPopup(popup: PopupState)
    popup.shown = false
    popup.measuredLines = nil
    releasePopupImage(popup)
end

local function showPopup(popup: PopupState, lines: {string})
    if not lines then return end
    popup.lines = lines
    popup.shown = true
    popup.page = 0
    popup.measuredLines = nil
end

-- Measure one popup column block: split lines on tabs and align the tab
-- columns within the block (proportional overlay font).
local function measurePopupBlock(font: love.graphics.Font, gap: number, lines: {string}): PopupBlock
    local rows: {{string}} = {}
    local colW: {number} = {}
    for i = 1, #lines do
        if lines[i] == HRULE then
            rows[i] = {}
        else
            local cols: {string} = {}
            for seg in (lines[i] .. "\t"):gmatch("(.-)\t") do
                cols[#cols + 1] = seg
            end
            rows[i] = cols
            -- Only tab-separated (name<tab>desc) lines drive column
            -- alignment, so a long single-column line does not push the
            -- description column right.
            if #cols > 1 then
                for j = 1, #cols do
                    local wj = font:getWidth(cols[j])
                    if not colW[j] or wj > colW[j] then colW[j] = wj end
                end
            end
        end
    end
    local colX: {number} = {0}
    for j = 2, #colW do colX[j] = colX[j - 1] + colW[j - 1] + gap end
    local width: number = 0
    for i = 1, #lines do
        if lines[i] ~= HRULE then
            local cols = rows[i]
            local nc = #cols
            if nc >= 1 then
                local ci = (nc < #colX and nc or #colX) as integer
                local xEnd = colX[ci] + font:getWidth(cols[nc])
                if xEnd > width then width = xEnd end
            end
        end
    end
    return {lines = lines, rows = rows, colX = colX, width = width}
end

local EMPTY_GROUP <const>: {integer} = {}

-- Draw the popup panel below the command line (goto targets, info, ...).
-- popup.lines[1] is a green header; the body flows into as many perPage-tall
-- columns as the screen width permits, and popup.page (clamped here) picks
-- which column group is visible. py is the panel's top edge; sw/sh are the
-- screen dimensions.
local function drawPopup(popup: PopupState, font: love.graphics.Font,
        sw: number, sh: number, py: number)
    local fh = font:getHeight()
    local lineH = fh + 6
    local perPage = math.max(1, math.floor((sh - py - 24) / lineH) - 1)
    local gap = font:getWidth("  ")
    local gutter = font:getWidth("        ")
    local popupLines = popup.lines

    -- Layout cache: measuring is skipped while the lines table reference,
    -- screen width, and per-page row count are unchanged (paging reuses it).
    if popup.measuredLines ~= popupLines or popup.measuredSw ~= sw
        or popup.measuredPerPage ~= perPage then
        popup.measuredLines = popupLines
        popup.measuredSw = sw
        popup.measuredPerPage = perPage
        -- Slice the body into perPage-tall blocks, then group blocks into
        -- pages by available width. Short popups are one block.
        local blocks: {PopupBlock} = {}
        local slice: {string} = {}
        for i = 2, #popupLines do
            slice[#slice + 1] = popupLines[i]
            if #slice == perPage or i == #popupLines then
                blocks[#blocks + 1] = measurePopupBlock(font, gap, slice)
                slice = {}
            end
        end
        local maxContentW = sw - PAD_X * 4
        local pageGroups: {{integer}} = {}
        local cur: {integer} = {}
        local curW: number = 0
        for k = 1, #blocks do
            local bw = blocks[k].width
            local addW = (#cur == 0) and bw or (curW + gutter + bw)
            if #cur > 0 and addW > maxContentW then
                pageGroups[#pageGroups + 1] = cur
                cur = {k}
                curW = bw
            else
                cur[#cur + 1] = k
                curW = addW
            end
        end
        if #cur > 0 then pageGroups[#pageGroups + 1] = cur end
        popup.blocks = blocks
        popup.pageGroups = pageGroups
    end
    local blocks = popup.blocks
    local pageGroups = popup.pageGroups
    local pages = math.max(1, #pageGroups)
    if popup.page < 0 then popup.page = 0 end
    if popup.page >= pages then popup.page = pages - 1 end
    local group = pageGroups[popup.page + 1] or EMPTY_GROUP

    local header = popupLines[1]
    if pages > 1 then
        header = header .. format("   (page %d/%d  <- ->)", popup.page + 1, pages)
    end

    local contentW: number = font:getWidth(header)
    local maxRows = 0
    for gi = 1, #group do
        local blk = blocks[group[gi]]
        local groupW: number = 0
        for gj = 1, gi do
            groupW = groupW + blocks[group[gj]].width + ((gj > 1) and gutter or 0)
        end
        if groupW > contentW then contentW = groupW end
        if #blk.lines > maxRows then maxRows = #blk.lines end
    end
    local panelW = contentW + PAD_X + 8
    local panelH = lineH * (maxRows + 1) + 12
    lg.setColor(0.09, 0.11, 0.14, 0.96)
    lg.rectangle("fill", PAD_X, py, panelW, panelH, 4, 4)
    -- Thumbnail (screenshot info): scaled to fit under the panel.
    if popup.image then
        local iw = popup.image:getWidth()
        local ih = popup.image:getHeight()
        local maxW = sw - PAD_X * 2
        local maxH = sh - (py + panelH) - PAD_X * 2
        if iw > 0 and ih > 0 and maxH > 24 then
            local scale = math.min(maxW / iw, maxH / ih, 1)
            local ty = py + panelH + 8
            lg.setColor(0.09, 0.11, 0.14, 0.96)
            lg.rectangle("fill", PAD_X, ty, iw * scale + 8, ih * scale + 8, 4, 4)
            lg.setColor(1, 1, 1, 1)
            lg.draw(popup.image, PAD_X + 4, ty + 4, 0, scale, scale)
            lg.setColor(0.4, 0.8, 1.0, 0.9)
            lg.setLineWidth(1)
            lg.rectangle("line", PAD_X + 4, ty + 4, iw * scale, ih * scale)
        end
    end
    lg.setColor(0.6549, 0.7529, 0.5020, 1)                 -- header (green)
    lg.print(header, PAD_X * 2, py + 8)

    local bx: number = PAD_X * 2
    for gi = 1, #group do
        local blk = blocks[group[gi]]
        for i = 1, #blk.lines do
            local yy = py + 8 + lineH * i
            local line = blk.lines[i]
            if line == HRULE then
                lg.setColor(0.35, 0.40, 0.46, 0.8)
                lg.setLineWidth(1)
                lg.line(bx, yy + lineH * 0.5, bx + blk.width, yy + lineH * 0.5)
            else
                local br, bg, bb = 0.8275, 0.7765, 0.6667  -- content (tan)
                if line:sub(1, 1) ~= " " then
                    br, bg, bb = 0.498, 0.733, 0.702       -- heading (aqua)
                    -- Command-section headings ("Edit:") take the section's
                    -- accent color, matching the strip.
                    local accent = commands.SECTION_COLORS[line:match("^(%w+):")]
                    if accent then
                        br, bg, bb = accent[1], accent[2], accent[3]
                    end
                end
                local cols = blk.rows[i]
                -- Blue the first (name) column of an indented
                -- "name<tab>desc" line: parameter names, subcommand names,
                -- mark names.
                local nameCol = line:sub(1, 1) == " " and #cols > 1
                for j = 1, #cols do
                    if nameCol and j == 1 then
                        lg.setColor(0.45, 0.70, 1.0, 1)    -- name (blue)
                    else
                        lg.setColor(br, bg, bb, 1)
                    end
                    lg.print(cols[j], bx + blk.colX[j], yy)
                end
            end
        end
        bx = bx + blk.width + gutter
    end
end

-- Tab-cycle bar layout: display labels (section entries become padded pill
-- names), per-label widths, and x offsets. Built when completions are
-- assigned, so the per-frame draw only does scroll/highlight math.
local function buildCompletionBar(popup: PopupState, completions: {string},
        font: love.graphics.Font)
    local labels: {string} = {}
    local sectionOf: {integer: string} = {}
    local widths: {number} = {}
    local xs: {number} = {}
    local gap = font:getWidth("   ")
    local x: number = PAD_X
    for i = 1, #completions do
        local entry = completions[i]
        if entry:sub(1, 1) == SECTION_MARK then
            local section = entry:sub(2)
            labels[i] = " " .. section .. " "
            sectionOf[i] = section
        else
            labels[i] = entry
        end
        xs[i] = x
        widths[i] = font:getWidth(labels[i])
        x = x + widths[i] + gap
    end
    popup.barLabels = labels
    popup.barSectionOf = sectionOf
    popup.barWidths = widths
    popup.barX = xs
end

-- Entities already labeled this frame (a mark and a note can hit the same
-- entity); cleared at the start of each label pass so drawing allocates
-- nothing per frame.
local labelSeen: {integer: boolean} = {}

-- Mark name / note star above one annotated entity.
local function drawEntityLabel(w: tecs.World, ctx: debugcontext.Context,
        cam: gfxtypes.Camera, font: love.graphics.Font, fh: number, eid: integer)
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
    lg.setColor(0.11, 0.13, 0.16, 0.85)
    lg.rectangle("fill", sx - tw / 2 - 5, sy - 40, tw + 10, fh + 4, 3, 3)
    lg.setColor(0.8275, 0.7765, 0.6667, 1)
    lg.print(label, sx - tw / 2, sy - 38)
end

-- Name-bearing components for the context-menu header, resolved by name so
-- the overlay never forces those modules to load. Misses retry (games may
-- register them after the first menu opens); successes are memoized.
local HEADER_COMPONENTS <const>: {string} = {"Name", "Key"}
local headerComps: {string: tecs.Component} = {}
local function headerComponent(name: string): tecs.Component
    local comp = headerComps[name]
    if comp == nil then
        local ok, resolved = pcall(tecs.componentByName, name)
        comp = ok and resolved or nil
        if comp then headerComps[name] = comp end
    end
    return comp
end

-- Mouse gestures while no context menu owns the mouse: a left press in the
-- world view starts a box-select drag (or a shift-move of the selection),
-- release commits it, right-click opens the menu (or cancels a move),
-- middle-drag pans, and the wheel zooms toward the cursor. `view` is the
-- debugger's input layer; a press swallowed by the menu or on the toolbar
-- rows never starts a drag (gesture.pressInView).
local function handleMouseGestures(gesture: GestureState, menu: MenuState, popup: PopupState,
        ctx: debugcontext.Context, w: tecs.World, view: input.View,
        pipeline: gfxtypes.Pipeline, inView: boolean, cb: GestureCallbacks)
    local shiftHeld = view.isKeyDown("lshift") or view.isKeyDown("rshift")

    -- A press that closed the menu stays swallowed until release.
    local swallowing = menu.swallow
    if swallowing and not view.isMouseDown(1) then
        menu.swallow = false
    end

    if view.isMousePressed(1) then
        gesture.pressInView = not swallowing and inView
    end
    if not swallowing and view.isMousePressed(1) and inView then
        -- Interacting with the world replaces reading the popup.
        dismissPopup(popup)
        if shiftHeld and #ctx.selected > 0 then
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
            cb.selectArea()
        elseif gesture.pressInView and inView then
            cb.clickSelect()
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
    if view.isMousePressed(3) then
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
    if wheelY ~= 0 and pipeline then
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

        --- Captured image format: "png" (default), "tga", or "jpg".
        recordingFrameFormat: string

        --- Max frames in flight before dropping (default 8).
        recordingRingSize: integer
    end

    --- Create the DebugContext resource, build the command registry, and
    --- install the overlay systems.
    install: function(w: tecs.World, opts: Options): debugcontext.Context
end

function overlay.install(w: tecs.World, opts: overlay.Options): debugcontext.Context
    local leaderKey = opts.leaderKey
    local debugToggleKey = opts.debugToggleKey
    local statsToggleKey = opts.statsToggleKey
    local overlayFont = lg.newFont(20)
    local wasTextInput = false
    local ctx = debugcontext.new()
    w.resources[debugcontext.KEY] = ctx
    local recorder = recording.new(ctx, {
        ffmpegPath = opts.recordingFfmpegPath,
        outputDir = opts.recordingOutputDir,
        countdown = opts.recordingCountdown,
        fps = opts.recordingFps,
        scale = opts.recordingScale,
        frameFormat = opts.recordingFrameFormat,
        ringSize = opts.recordingRingSize,
    })
    w.resources[recording.KEY] = recorder
    local fz = freeze.ensure(w)
    local store = annotations.install(w, ctx)

    local registry = commands.build({
        world = w,
        ctx = ctx,
        recorder = recorder,
        freeze = fz,
        annotations = store,
        keys = {leader = leaderKey, debugToggle = debugToggleKey, statsToggle = statsToggleKey},
    })
    w.resources[commands.KEY] = registry

    local pickQuery = w:query({name = "debug.Pick", include = {Transform}})

    -- UI-only state (not part of the shared context).
    local completions: {string} = {}
    local completionBase = ""
    local completionIndex = 0
    local cycling = false
    -- Holding Tab auto-repeats the cycle: one step on press, a short delay,
    -- then faster stepping while held.
    local TAB_REPEAT_DELAY <const> = 0.35
    local TAB_REPEAT_INTERVAL <const> = 0.07
    local tabHeldFor = 0.0
    local tabRepeatIn = 0.0
    local entityCountAt = 0.0
    local gesture: GestureState = {
        dragStartX = 0.0,
        dragStartY = 0.0,
        dragging = false,
        pressInView = false,
        moving = false,
        moveStartWX = 0.0,
        moveStartWY = 0.0,
        moveOrigins = {},
        panning = false,
        panLastX = 0.0,
        panLastY = 0.0,
    }
    local historyPos = 0
    local popup: PopupState = {
        lines = {},
        shown = false,
        page = 0,
    }
    -- Right-click context menu state.
    local menu: MenuState = {
        open = false, rows = {}, header = "",
        x = 0, y = 0, w = 0, rowH = 0, index = 1, swallow = false,
    }
    local hideOverlayFrame = false
    local recorderLastAt = getTime()

    -- Input-stack token held while the debugger command line is open, so the
    -- game (a lower layer) stops seeing keyboard/mouse and its hotkeys do not
    -- fire while you type. 0 means the debugger holds no layer.
    local captureToken = 0
    local function reader(): input.View
        if ctx.open and captureToken ~= 0 then
            return input.stack[captureToken]
        end
        -- Closed, the only read is the toggle. The debugger is a god layer:
        -- read through whatever layer is on top so Ctrl+/ still opens while a
        -- game modal holds the input stack.
        local depth = input.stackDepth()
        if depth > 0 then
            return input.stack[depth]
        end
        return input.base
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

    -- Left click toggles the nearest entity under the cursor in/out of the set.
    local function clickSelect()
        local list = underMouse()
        if #list == 0 then return end
        local id = list[1]
        if debugcontext.isSelected(ctx, id) then
            debugcontext.removeSelected(ctx, id)
        else
            debugcontext.addSelected(ctx, id)
        end
        debugcontext.pushEvent(ctx, "selection", {selected = #ctx.selected, clicked = id})
    end

    -- Drag release: add every entity inside the world-space box to the set.
    local function selectArea()
        local minX = math.min(ctx.areaX1, ctx.areaX2)
        local maxX = math.max(ctx.areaX1, ctx.areaX2)
        local minY = math.min(ctx.areaY1, ctx.areaY2)
        local maxY = math.max(ctx.areaY1, ctx.areaY2)
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
        debugcontext.pushEvent(ctx, "selection", {selected = #ctx.selected, boxed = true})
    end

    local function resetCompletions()
        cycling = false
        completionIndex = 0
        completions = {}
        completionBase = ""
        popup.barLabels = nil
    end

    -- Wrapped command-line rows at the current window width, so long commands
    -- (set/spawn with Lua tables) wrap instead of running off screen. Used by
    -- both the draw pass and the input pass (click-through guard); cached on
    -- the prompt text and screen width so both passes share one getWrap call.
    local function commandLineRows(sw: number): {string}
        if popup.cmdRows and popup.cmdRowsText == ctx.command and popup.cmdRowsSw == sw then
            return popup.cmdRows
        end
        local _, wrapped = overlayFont:getWrap("> " .. ctx.command, sw - PAD_X * 3)
        if #wrapped == 0 then wrapped = {"> "} end
        popup.cmdRowsText = ctx.command
        popup.cmdRowsSw = sw
        popup.cmdRows = wrapped
        return wrapped
    end

    local function executeCommand(text: string)
        local result = registry:execute(text)
        if not result then
            return
        end
        dismissPopup(popup)
        if result.popup then
            showPopup(popup, result.popup)
            ctx.message = ""
            if result.popupImagePath then
                local ok, img = pcall(love.graphics.newImage, result.popupImagePath)
                if ok then
                    popup.image = img as love.graphics.Image
                end
            end
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

    -- "#42 boss Player": id, then the mark, then a Name/Key component's
    -- string when the game defines one.
    local function entityHeader(eid: integer): string
        local label = "#" .. tostring(eid)
        local markName = ctx.marks[eid]
        if markName then label = label .. " " .. markName end
        for ci = 1, #HEADER_COMPONENTS do
            local comp = headerComponent(HEADER_COMPONENTS[ci])
            if comp then
                local v = w:get(eid, comp) as any
                local text: string = nil
                if type(v) == "string" then
                    text = v as string
                elseif type(v) == "table" or type(v) == "cdata" then
                    local okS, fields = pcall(function(): {string: any}
                        local serialize = (comp as {string: any}).serialize
                            as function(any): {string: any}
                        return serialize and serialize(v) or nil
                    end)
                    if okS and fields then
                        local candidate = fields.name or fields.value or fields.key or fields.text
                        if type(candidate) == "string" then
                            text = candidate as string
                        end
                    end
                end
                if text then label = label .. " " .. text end
            end
        end
        return label
    end

    -- Build and place the menu for an entity (or the world when eid is nil).
    local function openMenu(eid: integer)
        if eid then
            local id = tostring(eid)
            menu.header = entityHeader(eid)
            menu.rows = {
                {label = "Info", run = "info " .. id},
                {label = "Select", run = "select " .. id},
                {label = "Select Only", run = "select " .. id .. " replace"},
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
                {label = "Draw Marker",
                    run = format("draw circle %.1f %.1f 8 seconds=5 tag=marker", wx, wy)},
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
        menu.x = math.min(input.mouseX, lg.getWidth() - menu.w)
        menu.y = math.min(input.mouseY, lg.getHeight() - totalH)
        if menu.x < 0 then menu.x = 0 end
        if menu.y < 0 then menu.y = 0 end
        menu.index = 1
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
        ctx.message = "Hit [TAB] to see commands"
        if captureToken == 0 then
            captureToken = input.pushStack()
        end
        if not debugRecordingActive() then
            fz:acquire("debugger")
            ctx.frozen = true
        end
        debugcontext.pushEvent(ctx, "open")
    end

    local function doClose()
        closeMenu()
        ctx.open = false
        releasePopupImage(popup)
        love.keyboard.setTextInput(wasTextInput)
        if captureToken ~= 0 then
            input.popStack(captureToken)
            captureToken = 0
        end
        fz:release("debugger")
        ctx.frozen = false
        debugcontext.pushEvent(ctx, "close")
    end

    -- Apply surface-directed side effects raised by commands (from the command
    -- line or over MCP): panel close, quit, one-frame chrome hide.
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
        elseif sig.action == "quit" then
            sig.action = ""
            love.event.quit()
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
                    fz:release("debugger")
                    ctx.frozen = false
                end
            elseif ctx.open and not ctx.frozen then
                fz:acquire("debugger")
                ctx.frozen = true
            end

            -- Toggle with Ctrl+<key>. Re-opening while profiling stops it.
            if leaderDown() and reader().isKeyPressed(debugToggleKey) then
                if ctx.open then
                    doClose()
                else
                    doOpen()
                    if registry.profiler.session then
                        showPopup(popup, registry:finishProfile())
                    end
                end
            end

            -- A timed profile auto-finishes: reopen the debugger with results.
            local prof = registry.profiler
            if prof.session and prof.deadline > 0 and now >= prof.deadline then
                if not ctx.open then doOpen() end
                showPopup(popup, registry:finishProfile())
            end

            -- Commands invoked over MCP may raise signals while the panel is
            -- closed (e.g. a screenshot's chrome hide); honor them every frame.
            consumeSignals()

            -- Time-travel ring capture: wall-clock interval, and never while
            -- the freeze controller is held (whoever holds it).
            rewind.tick(ctx, w, now, fz:isFrozen())

            -- Delayed screenshots count down on wall-clock time and fire even
            -- while the panel is closed or the game is frozen.
            for i = #registry.pendingShots, 1, -1 do
                local shot = registry.pendingShots[i]
                shot.dueIn = shot.dueIn - frameDt
                if shot.dueIn <= 0 then
                    table.remove(registry.pendingShots, i)
                    shot.fire()
                end
            end

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

            -- Refresh the status-bar entity count on a throttle.
            if now - entityCountAt >= ENTITY_COUNT_INTERVAL then
                entityCountAt = now
                ctx.entityCount = w:getStats().entities
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
            if not menuTookInput and not leaderDown() and input.textInput ~= "" then
                ctx.command = ctx.command .. input.textInput
                ctx.message = ""
                dismissPopup(popup)
                resetCompletions()
            end
            if not menuTookInput and reader().isKeyPressed("backspace") then
                ctx.command = ctx.command:sub(1, -2)
                ctx.message = ""
                dismissPopup(popup)
                resetCompletions()
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
                if not tabStep and cycling and tabHeldFor >= TAB_REPEAT_DELAY then
                    tabRepeatIn = tabRepeatIn - frameDt
                    if tabRepeatIn <= 0 then
                        tabStep = true
                        tabRepeatIn = TAB_REPEAT_INTERVAL
                    end
                end
            else
                tabHeldFor = 0.0
                tabRepeatIn = 0.0
            end
            if tabStep and not menuTookInput then
                ctx.message = ""
                dismissPopup(popup)
                local backward = reader().isKeyDown("lshift") or reader().isKeyDown("rshift")
                if not cycling then
                    completionBase, completions = registry:complete(ctx.command)
                    buildCompletionBar(popup, completions, overlayFont)
                    completionIndex = 0
                    -- On an empty line, start the cycle at the last used
                    -- command (whichever direction) so Tab-Enter repeats
                    -- recent work.
                    if ctx.command == "" then
                        local hist = registry.history
                        local last = hist[#hist]
                        local firstWord = last and last:match("^(%S+)")
                        if firstWord then
                            for ci = 1, #completions do
                                if completions[ci] == firstWord then
                                    completionIndex = backward and (ci + 1) or (ci - 1)
                                    break
                                end
                            end
                        end
                    end
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
                end
            end
            -- Up/Down browse the command history (persisted by the registry).
            local history = registry.history
            if not menuTookInput and reader().isKeyPressed("up") and #history > 0 then
                if historyPos < #history then historyPos = historyPos + 1 end
                ctx.command = history[#history - historyPos + 1]
                ctx.message = ""
                dismissPopup(popup)
                resetCompletions()
            end
            if not menuTookInput and reader().isKeyPressed("down") then
                if historyPos > 0 then historyPos = historyPos - 1 end
                ctx.command = (historyPos == 0) and "" or history[#history - historyPos + 1]
                ctx.message = ""
                dismissPopup(popup)
                resetCompletions()
            end
            -- Left/Right page a multi-page popup (does not dismiss it).
            if popup.shown then
                if reader().isKeyPressed("left") then popup.page = popup.page - 1 end
                if reader().isKeyPressed("right") then popup.page = popup.page + 1 end
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

            -- Auto-preview: once the command line names a command, show that
            -- command's generated popup (how to use it), including as arguments
            -- are typed and while Tab-cycling. Running the command (Enter) may
            -- replace it: `help`, for example, swaps in the full command listing.
            -- The named command and its usage lines are cached; the preview
            -- reasserts whenever the popup shows anything else.
            if ctx.command ~= popup.lastCommandLine then
                popup.lastCommandLine = ctx.command
                local previewWord = ctx.command:match("^(%S+)")
                popup.previewCmd = previewWord and registry.byName[previewWord]
            end
            local previewCmd = popup.previewCmd
            if previewCmd then
                if popup.previewFor ~= previewCmd then
                    popup.previewFor = previewCmd
                    popup.previewLines = commands.usagePopup(previewCmd)
                end
                if popup.lines ~= popup.previewLines or not popup.shown then
                    popup.lines = popup.previewLines
                    popup.shown = true
                end
            end

            -- A command run this frame may have raised exit/quit.
            consumeSignals()
            if not ctx.open then
                return
            end

            -- Mouse. The status + command bars sit at the top; ignore clicks
            -- there so the toolbar is not click-through.
            local ifh = overlayFont:getHeight()
            local barsHeight = 2 * (ifh + PAD_Y * 2) +
                (#commandLineRows(lg.getWidth()) - 1) * ifh
            local inView = ctx.mouseScreenY > barsHeight

            -- The open context menu owns the mouse: hover highlights, click
            -- activates or closes, right-click closes.
            local menuAteMouse = menu.open
            if menuAteMouse then
                local hover = menuRowAt(input.mouseX, input.mouseY)
                if hover then menu.index = hover end
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

    w:addSystem({
        name = "debug.RecordingShutdown",
        phase = tecs.phases.PreShutdown,
        run = function()
            recorder:shutdown()
        end,
    })

    -- Frame capture for the permission-free "frames" recording backend. Runs
    -- every frame regardless of overlay visibility, grabbing the finished frame
    -- after the world has rendered (PostRender) and before present.
    w:addSystem({
        name = "debug.RecordingCapture",
        phase = tecs.phases.PostRender,
        run = function()
            recorder:captureFrame()
        end,
    })

    -- Recording indicator (remaining/elapsed time). Drawn only on frames that
    -- are NOT being captured, so the game renders it for the operator but it
    -- never appears in the recorded video. Runs after the capture system so
    -- capturedThisFrame is current.
    w:addSystem({
        name = "debug.RecordingIndicator",
        phase = tecs.phases.PostRender,
        run = function()
            if ctx.recording.status ~= "recording" then return end
            if recorder.capturedThisFrame then return end
            local r = ctx.recording
            local text: string
            if r.duration > 0 then
                local remaining = math.max(0, r.duration - (getTime() - r.startedAt))
                text = format("REC  %ds left", math.ceil(remaining))
            else
                local elapsed = getTime() - r.startedAt
                text = format("REC  %d:%02d", math.floor(elapsed / 60), math.floor(elapsed % 60))
            end
            lg.push("all")
            lg.origin()
            lg.setFont(overlayFont)
            local pad = 8
            local dotW = 18
            local tw = overlayFont:getWidth(text)
            local th = overlayFont:getHeight()
            local boxW = dotW + tw + pad * 2
            local boxH = th + pad
            local bx = lg.getWidth() - boxW - pad
            local by = pad
            lg.setColor(0, 0, 0, 0.6)
            lg.rectangle("fill", bx, by, boxW, boxH, 6, 6)
            lg.setColor(1, 0.2, 0.15, 1)
            lg.circle("fill", bx + pad + 4, by + boxH / 2, 5)
            lg.setColor(1, 1, 1, 1)
            lg.print(text, bx + pad + dotW, by + pad / 2)
            lg.pop()
        end,
    })

    -- Overlay draw.
    w:addSystem({
        name = "debug.Overlay",
        phase = tecs.phases.PostRender,
        run = function()
            if not ctx.open then
                return
            end
            -- Skip drawing the chrome for one frame while a screenshot captures.
            if hideOverlayFrame then
                hideOverlayFrame = false
                return
            end

            lg.push("all")
            lg.origin()
            lg.setFont(overlayFont)

            local fh = overlayFont:getHeight()
            local rowH = fh + PAD_Y * 2
            local sw = lg.getWidth()
            local pipeline = w.resources[pipelinekey.PIPELINE]

            if ctx.recording.status == "countdown" then
                local label = "RECORDING IN " .. tostring(math.ceil(ctx.recording.countdown))
                lg.setColor(0, 0, 0, 0.72)
                lg.rectangle("fill", 0, 0, sw, rowH * 2)
                lg.setColor(1, 0.18, 0.12, 1)
                lg.printf(label, 0, PAD_Y, sw, "center")
            elseif ctx.recording.status == "stopping" then
                lg.setColor(0, 0, 0, 0.72)
                lg.rectangle("fill", 0, 0, sw, rowH * 2)
                lg.setColor(1, 0.85, 0.2, 1)
                lg.printf("STOPPING RECORDING", 0, PAD_Y, sw, "center")
            end

            -- Drag-selected area (world -> screen).
            if ctx.hasArea and pipeline then
                local cam = pipeline:getCamera()
                local x1, y1 = cam:toScreen(ctx.areaX1, ctx.areaY1)
                local x2, y2 = cam:toScreen(ctx.areaX2, ctx.areaY2)
                local rx = math.min(x1, x2)
                local ry = math.min(y1, y2)
                lg.setColor(0.3, 0.7, 1.0, 0.15)
                lg.rectangle("fill", rx, ry, math.abs(x2 - x1), math.abs(y2 - y1))
                lg.setColor(0.4, 0.8, 1.0, 0.9)
                lg.setLineWidth(1)
                lg.rectangle("line", rx, ry, math.abs(x2 - x1), math.abs(y2 - y1))
            end

            -- Highlight every selected entity.
            if pipeline and #ctx.selected > 0 then
                local cam = pipeline:getCamera()
                lg.setColor(1.0, 0.85, 0.2, 1)
                lg.setLineWidth(2)
                for i = 1, #ctx.selected do
                    local sid = ctx.selected[i]
                    if w:isAlive(sid) then
                        local t = w:get(sid, Transform)
                        if t then
                            local sx, sy = cam:toScreen(t.x, t.y)
                            local r = 14
                            lg.rectangle("line", sx - r, sy - r, r * 2, r * 2)
                            lg.line(sx, sy - r - 6, sx, sy - r)
                            lg.line(sx, sy + r, sx, sy + r + 6)
                            lg.line(sx - r - 6, sy, sx - r, sy)
                            lg.line(sx + r, sy, sx + r + 6, sy)
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
                    lg.rectangle("line", sx - r, sy - r, r * 2, r * 2)
                    lg.line(sx, sy - r - 8, sx, sy - r + 6)
                    lg.line(sx, sy + r - 6, sx, sy + r + 8)
                    lg.line(sx - r - 8, sy, sx - r + 6, sy)
                    lg.line(sx + r - 6, sy, sx + r + 8, sy)
                end
            end

            -- Mark names / note markers above annotated entities, so it is
            -- visible in-game which entities carry marks or notes.
            if pipeline then
                local cam = pipeline:getCamera()
                for k in pairs(labelSeen) do labelSeen[k] = nil end
                for eid in pairs(ctx.marks) do
                    drawEntityLabel(w, ctx, cam, overlayFont, fh, eid)
                end
                for eid in pairs(ctx.notes) do
                    drawEntityLabel(w, ctx, cam, overlayFont, fh, eid)
                end
            end

            -- Status/top bar (bg #a7c080): coordinates, or the command list
            -- while Tab-cycling, which takes over this row instead of a new one.
            lg.setColor(0.6549, 0.7529, 0.5020, 1)
            lg.rectangle("fill", 0, 0, sw, rowH)
            if cycling and #completions > 0 then
                -- Section separators render as pills in the section's dark
                -- shade with a white label; commands render as plain text.
                -- Layout comes from the completion-time cache; only the
                -- scroll/highlight math runs per frame.
                if not popup.barLabels then
                    buildCompletionBar(popup, completions, overlayFont)
                end
                local labels = popup.barLabels
                local sectionOf = popup.barSectionOf
                local widths = popup.barWidths
                local xs = popup.barX
                local hx = xs[completionIndex] or 0.0
                local scrollX = 0.0
                if hx > sw * 0.6 then scrollX = hx - sw * 0.4 end
                lg.setScissor(0, 0, sw, rowH)
                for i = 1, #labels do
                    local x = xs[i] - scrollX
                    local cw = widths[i]
                    if i == completionIndex then
                        lg.setColor(0.1804, 0.2157, 0.2353, 1)
                        lg.rectangle("fill", x - 6, 0, cw + 12, rowH)
                        lg.setColor(0.8275, 0.7765, 0.6667, 1)
                    elseif sectionOf[i] then
                        -- Pill in the section's dark shade, white label.
                        local accent = commands.SECTION_COLORS_BAR[sectionOf[i]]
                            or DEFAULT_PILL
                        lg.setColor(accent[1], accent[2], accent[3], 1)
                        lg.rectangle("fill", x - 6, 0, cw + 12, rowH)
                        lg.setColor(1, 1, 1, 1)
                    else
                        lg.setColor(0.1804, 0.2157, 0.2353, 1)
                    end
                    lg.print(labels[i], x, PAD_Y)
                end
                lg.setScissor()
            else
                lg.setColor(0.1804, 0.2157, 0.2353, 1)
                lg.print(format(
                    "mouse: %.0f,%.0f -> %.0f,%.0f   cam: %.0f,%.0f z%.2f   fps: %.0f   ents: %d%s",
                    ctx.mouseScreenX, ctx.mouseScreenY, ctx.mouseWorldX, ctx.mouseWorldY,
                    ctx.cameraX, ctx.cameraY, ctx.cameraZoom, love.timer.getFPS(),
                    ctx.entityCount,
                    (#ctx.selected > 0) and ("   sel: " .. tostring(#ctx.selected)) or ""
                ), PAD_X, PAD_Y)
            end

            -- Command line (below status, flush): bg #2e373c, text #d3c6aa.
            -- Long commands wrap onto extra rows instead of running off screen.
            local cmdLines = commandLineRows(sw)
            local cmdBarH = rowH + (#cmdLines - 1) * fh
            lg.setColor(0.1804, 0.2157, 0.2353, 1)
            lg.rectangle("fill", 0, rowH, sw, cmdBarH)
            lg.setColor(0.8275, 0.7765, 0.6667, 1)
            for i = 1, #cmdLines do
                lg.print(cmdLines[i], PAD_X, rowH + PAD_Y + (i - 1) * fh)
            end
            -- Tall block cursor at the end of the last wrapped row.
            local cursorX = PAD_X + overlayFont:getWidth(cmdLines[#cmdLines])
            local cursorY = rowH + PAD_Y + (#cmdLines - 1) * fh
            local blockW = overlayFont:getWidth("0")
            lg.rectangle("fill", cursorX + 1, cursorY, blockW, fh)
            -- Status line: reserved for the initial hint and notifications; the
            -- per-command usage lives in the popup, not here. Hidden once the
            -- prompt wraps (no room to its right).
            local hint = ctx.message
            if hint ~= "" and #cmdLines == 1 then
                lg.setColor(0.522, 0.573, 0.537, 1)
                lg.print(hint, cursorX + blockW + PAD_X * 2, cursorY)
            end

            -- Popup panel below the command line; Left/Right page through
            -- the column groups.
            if popup.shown and #popup.lines > 0 then
                drawPopup(popup, overlayFont, sw, lg.getHeight(), rowH + cmdBarH + 10)
            end

            -- Context menu: dark panel, header row, hover/keyboard highlight.
            if menu.open then
                local mfh = overlayFont:getHeight()
                local totalH = menu.rowH * (#menu.rows + 1) + 8
                lg.setFont(overlayFont)
                lg.setColor(0.09, 0.11, 0.14, 0.97)
                lg.rectangle("fill", menu.x, menu.y, menu.w, totalH, 4, 4)
                lg.setColor(0.35, 0.42, 0.30, 1)
                lg.setLineWidth(1)
                lg.rectangle("line", menu.x, menu.y, menu.w, totalH, 4, 4)
                lg.setColor(0.6549, 0.7529, 0.5020, 1)
                lg.print(menu.header, menu.x + 12, menu.y + 6)
                for i = 1, #menu.rows do
                    local ry = menu.y + menu.rowH * i + 4
                    if i == menu.index then
                        lg.setColor(0.25, 0.32, 0.40, 1)
                        lg.rectangle("fill", menu.x + 4, ry, menu.w - 8, menu.rowH - 2, 3, 3)
                    end
                    lg.setColor(0.8275, 0.7765, 0.6667, 1)
                    lg.print(menu.rows[i].label, menu.x + 12, ry + (menu.rowH - mfh) / 2)
                end
            end

            lg.pop()
        end
    })

    return ctx
end

return overlay
