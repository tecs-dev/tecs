--- Multi-column completion panel for the debugger overlay.

local commands <const> = require("tecs2d.debug.commands")
local Popup <const> = require("tecs2d.debug.internal.Popup")
local lg <const> = require("tecs2d.debug.internal.debugdraw")

local SECTION_MARK <const> = commands.SECTION_MARK
local COMPLETION_ROWS <const> = 8
local COMPLETION_PAD <const> = 6
local COMPLETION_BG <const>: {number} = {0.1059, 0.0745, 0.1373, 0.98}
local TECS_PURPLE <const>: {number} = {0.4196, 0.2471, 0.6902, 1}
local POPUP_ACCENT <const>: {number} = {0.66, 0.51, 0.90, 1}

local record completionview
    draw: function(
        popup: Popup,
        completions: {string},
        font: lg.Font,
        completionIndex: integer,
        width: number,
        panelBottom: number,
        hint: string
    )
end

local function rebuild(popup: Popup, completions: {string}, font: lg.Font)
    local labels: {string} = {}
    local widths: {number} = {}
    for i = 1, #completions do
        local entry = completions[i]
        labels[i] = entry:sub(1, 1) == SECTION_MARK
            and entry:sub(2) or entry
        widths[i] = font:getWidth(labels[i])
    end
    popup.barLabels = labels
    popup.barCompletions = completions
    popup.barWidths = widths
    popup.barScroll = 0
    popup.barScrollForIndex = 0
    popup.barHitValue = popup.barHitValue or {}
    popup.barHitX = popup.barHitX or {}
    popup.barHitY = popup.barHitY or {}
    popup.barHitW = popup.barHitW or {}
    popup.barHitH = popup.barHitH or {}
    popup.barHitCount = 0
end

local function addHit(popup: Popup, value: integer,
        x: number, y: number, width: number, height: number,
        screenWidth: number, top: number, bottom: number)
    local left = math.max(0, x)
    local right = math.min(screenWidth, x + width)
    local clippedTop = math.max(top, y)
    local clippedBottom = math.min(bottom, y + height)
    if right <= left or clippedBottom <= clippedTop then return end
    local n = popup.barHitCount + 1
    popup.barHitCount = n
    popup.barHitValue[n] = value
    popup.barHitX[n] = left
    popup.barHitY[n] = clippedTop
    popup.barHitW[n] = right - left
    popup.barHitH[n] = clippedBottom - clippedTop
end

function completionview.draw(popup: Popup, completions: {string},
        font: lg.Font, completionIndex: integer, screenWidth: number,
        panelBottom: number, hint: string)
    if not popup.barLabels or popup.barCompletions ~= completions then
        rebuild(popup, completions, font)
    end
    local labels = popup.barLabels
    local widths = popup.barWidths
    local highlightedIndex = completionIndex
    if highlightedIndex == 0 then
        for i = 1, #completions do
            if completions[i]:sub(1, 1) ~= SECTION_MARK then
                highlightedIndex = i
                break
            end
        end
    end

    local lineHeight = font:getHeight() + 4
    local helpHeight = lineHeight + 2
    local usable = math.max(lineHeight,
        panelBottom - COMPLETION_PAD * 2 - helpHeight - 4)
    local rows = math.max(1, math.min(COMPLETION_ROWS,
        math.floor(usable / lineHeight)))
    local gutter = font:getWidth("   ")
    local itemPad = font:getWidth(" ")
    local selectedX, selectedW = 0.0, 0.0
    local totalWidth: number = COMPLETION_PAD
    local usedRows = 0

    local first = 1
    while first <= #completions do
        local last = math.min(#completions, first + rows - 1)
        local columnWidth: number = 0
        for i = first, last do
            columnWidth = math.max(columnWidth, widths[i])
        end
        columnWidth = columnWidth + itemPad * 2
        if highlightedIndex >= first and highlightedIndex <= last then
            selectedX, selectedW = totalWidth, columnWidth
        end
        usedRows = math.max(usedRows, last - first + 1)
        totalWidth = totalWidth + columnWidth + gutter
        first = last + 1
    end
    totalWidth = math.max(screenWidth,
        totalWidth - gutter + COMPLETION_PAD)
    local maxScroll = math.max(0, totalWidth - screenWidth)
    if popup.barScrollForIndex ~= highlightedIndex then
        local selectedRight = selectedX + selectedW
        if selectedX < popup.barScroll + COMPLETION_PAD then
            popup.barScroll = selectedX - COMPLETION_PAD
        elseif selectedRight
                > popup.barScroll + screenWidth - COMPLETION_PAD then
            popup.barScroll = selectedRight - screenWidth + COMPLETION_PAD
        end
        popup.barScrollForIndex = highlightedIndex
    end
    popup.barScroll = math.max(0, math.min(popup.barScroll, maxScroll))

    local panelHeight = helpHeight + usedRows * lineHeight + COMPLETION_PAD
    local panelTop = math.max(0, panelBottom - panelHeight)
    popup.barTop = panelTop
    popup.barBottom = panelBottom
    popup.barHitCount = 0

    lg.setColor(COMPLETION_BG[1], COMPLETION_BG[2],
        COMPLETION_BG[3], COMPLETION_BG[4])
    lg.rectangle("completion.background", "fill", 0, panelTop,
        screenWidth, panelBottom - panelTop)
    lg.setColor(TECS_PURPLE[1], TECS_PURPLE[2], TECS_PURPLE[3], 1)
    lg.rectangle("completion.header.background", "fill", 0, panelTop,
        screenWidth, helpHeight)
    lg.setColor(0.86, 0.80, 0.95, 1)
    lg.print("completion.header.hint", hint, COMPLETION_PAD, panelTop + 2)
    local controls = "Tab next  Shift+Tab previous"
    local controlsWidth = font:getWidth(controls)
    if controlsWidth < screenWidth * 0.45 then
        lg.setColor(0.66, 0.60, 0.74, 1)
        lg.print("completion.header.controls", controls,
            screenWidth - controlsWidth - COMPLETION_PAD, panelTop + 2)
    end

    local gridTop = panelTop + helpHeight
    local x = COMPLETION_PAD - popup.barScroll
    if highlightedIndex > 0 then
        local selectedRow = (highlightedIndex - 1) % rows
        lg.setColor(0.4784, 0.3412, 0.7608, 1)
        lg.alphaRectangle("completion.selection", "fill",
            selectedX - popup.barScroll,
            gridTop + selectedRow * lineHeight, selectedW, lineHeight)
    end
    lg.setScissor(0, gridTop, screenWidth, panelBottom - gridTop)
    first = 1
    while first <= #completions do
        local last = math.min(#completions, first + rows - 1)
        local columnWidth: number = 0
        for i = first, last do
            columnWidth = math.max(columnWidth, widths[i])
        end
        columnWidth = columnWidth + itemPad * 2
        for i = first, last do
            local y = gridTop + (i - first) * lineHeight
            local isSection = completions[i]:sub(1, 1) == SECTION_MARK
            if isSection then
                lg.setColor(POPUP_ACCENT[1], POPUP_ACCENT[2],
                    POPUP_ACCENT[3], 1)
            elseif i == highlightedIndex then
                lg.setColor(0.96, 0.93, 1.0, 1)
            else
                lg.setColor(0.72, 0.66, 0.84, 1)
            end
            lg.print("completion.item." .. tostring(i),
                labels[i], x + itemPad, y + 2)
            if not isSection then
                addHit(popup, i, x, y, columnWidth, lineHeight,
                    screenWidth, panelTop, panelBottom)
            end
        end
        x = x + columnWidth + gutter
        first = last + 1
    end
    lg.setScissor()
end

return completionview
