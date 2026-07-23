--- Popup layout and rendering for the debugger overlay.

local commands <const> = require("tecs2d.debug.commands")
local Popup <const> = require("tecs2d.debug.internal.Popup")
local markup <const> = require("tecs2d.debug.internal.markup")
local lg <const> = require("tecs2d.debug.internal.debugdraw")

local HRULE <const> = commands.HRULE
local type PopupState = Popup
local type PopupBlock = Popup.Block

local PAD_X <const> = 12
local POPUP_RIGHT_PAD <const> = 16
local POPUP_SCROLLBAR_W <const> = 6
local POPUP_CONTENT_PAD_TOP <const> = 10
local POPUP_CONTENT_PAD_BOTTOM <const> = 10
local POPUP_SECTION_PAD_TOP <const> = 4
local POPUP_SECTION_PAD_BOTTOM <const> = 4

local POPUP_ACCENT <const>: {number} = {0.66, 0.51, 0.90, 1}
local DEBUG_TEXT <const>: {number} = {0.94, 0.92, 0.98, 1}
local POPUP_BG <const>: {number} = {0.1059, 0.0745, 0.1373, 1}

local record popupview
    draw: function(popup: Popup, font: lg.Font,
        width: number, height: number, y: number)
end

local function appendWrappedPopupLine(out: {string}, font: lg.Font,
        line: string, maxWidth: number)
    if font:getWidth(line) <= maxWidth then
        out[#out + 1] = line
        return
    end
    local indent = line:match("^(%s*)") or ""
    local content = line:sub(#indent + 1)
    local width = math.max(font:getWidth("word"),
        maxWidth - font:getWidth(indent))
    local _, wrapped = font:getWrap(content, width)
    for i = 1, #wrapped do out[#out + 1] = indent .. wrapped[i] end
end

local function slicedDocumentLine(line: markup.Line, first: integer,
        last: integer): markup.Line
    local spans: {markup.Span} = {}
    local offset = 1
    for _, span in ipairs(line.spans) do
        local spanLast = offset + #span.text - 1
        local from = math.max(first, offset)
        local to = math.min(last, spanLast)
        if from <= to then
            spans[#spans + 1] = {
                text = span.text:sub(from - offset + 1, to - offset + 1),
                style = span.style,
            }
        end
        offset = spanLast + 1
    end
    if #spans == 0 then spans[1] = {text = "", style = "body"} end
    return {
        text = line.text:sub(first, last),
        style = line.style,
        language = line.language,
        spans = spans,
        span = line.span,
    }
end

-- Character-range wrapping keeps inline styles attached to their source
-- ranges, including on continuation lines.
local function appendWrappedDocumentLine(out: {markup.Line}, font: lg.Font,
        line: markup.Line, maxWidth: number)
    if line.style == "rule" or line.text == "" then
        out[#out + 1] = line
        return
    end
    local indentW = line.style == "definitionBody" and font:getWidth("    ") or 0
    local width = math.max(font:getWidth("word"), maxWidth - indentW)
    if font:getWidth(line.text) <= width then
        out[#out + 1] = line
        return
    end
    local first = 1
    while first <= #line.text do
        while first <= #line.text and line.text:sub(first, first):match("%s") do
            first = first + 1
        end
        if first > #line.text then break end
        local last = first
        local breakAt: integer = nil
        while last <= #line.text
            and font:getWidth(line.text:sub(first, last)) <= width do
            if line.text:sub(last, last):match("%s") then breakAt = last end
            last = last + 1
        end
        if last <= #line.text and breakAt and breakAt >= first then
            last = breakAt
        else
            last = math.max(first, last - 1)
        end
        while last > first and line.text:sub(last, last):match("%s") do
            last = last - 1
        end
        out[#out + 1] = slicedDocumentLine(line, first, last)
        first = math.max(first + 1, last + 1)
    end
end

-- Wrap a syntax/name cell without losing the trailing tab that identifies it
-- to the renderer. Every continuation therefore retains name-column color.
local function appendWrappedPopupName(out: {string}, font: lg.Font,
        name: string, maxWidth: number)
    if font:getWidth(name) <= maxWidth then
        out[#out + 1] = name .. "\t"
        return
    end
    local indent = name:match("^(%s*)") or ""
    local content = name:sub(#indent + 1)
    local width = math.max(font:getWidth("word"),
        maxWidth - font:getWidth(indent))
    local _, wrapped = font:getWrap(content, width)
    for i = 1, #wrapped do
        out[#out + 1] = indent .. wrapped[i] .. "\t"
    end
end

-- Reflow popup text for the current screen. Every tabular definition uses a
-- term line followed by an indented description; width never changes that
-- presentation. Larger example sets share two columns when both halves fit.
local function layoutPopupLines(font: lg.Font, sw: number,
        lines: {string}, firstLine: integer): {string}
    local out: {string} = {}
    local maxWidth = math.max(font:getWidth("word"), sw - PAD_X * 6)

    local i = firstLine
    while i <= #lines do
        local line = lines[i]
        if line == "Examples:" then
            out[#out + 1] = line
            local examples: {string} = {}
            local j = i + 1
            while j <= #lines and lines[j]:match("^%s") and lines[j] ~= HRULE do
                examples[#examples + 1] = lines[j]
                j = j + 1
            end
            local paired = false
            if #examples >= 4 and sw >= 720 then
                local half = math.ceil(#examples / 2) as integer
                local leftWidth: number = 0
                local rightWidth: number = 0
                for ei = 1, half do
                    leftWidth = math.max(leftWidth, font:getWidth(examples[ei]))
                    if examples[ei + half] then
                        rightWidth = math.max(rightWidth,
                            font:getWidth(examples[ei + half]))
                    end
                end
                local columnGap = font:getWidth("      ")
                if leftWidth + columnGap + rightWidth <= maxWidth then
                    local spaceWidth = math.max(1, font:getWidth(" "))
                    for ei = 1, half do
                        local left = examples[ei]
                        local right = examples[ei + half]
                        if right then
                            local spaces = math.max(1, math.ceil(
                                (leftWidth - font:getWidth(left) + columnGap)
                                / spaceWidth))
                            out[#out + 1] = left .. string.rep(" ", spaces) .. right
                        else
                            out[#out + 1] = left
                        end
                    end
                    paired = true
                end
            end
            if not paired then
                for ei = 1, #examples do
                    appendWrappedPopupLine(out, font, examples[ei], maxWidth)
                end
            end
            i = j
        else
            local name, description = line:match("^(.-)\t(.*)$")
            if name then
                -- Whitespace-only terms are continuations emitted by a few
                -- compact command summaries; keep them in the preceding
                -- definition instead of drawing an empty highlighted term.
                if name:match("%S") then
                    appendWrappedPopupName(out, font, name, maxWidth)
                end
                if description ~= "" then
                    appendWrappedPopupLine(out, font,
                        "    " .. description, maxWidth)
                end
            else
                appendWrappedPopupLine(out, font, line, maxWidth)
            end
            i = i + 1
        end
    end
    return out
end

-- Measure one popup column block: split lines on tabs and align the tab
-- columns within the block.
local function measurePopupBlock(font: lg.Font, gap: number, lines: {string},
        documentLines?: {markup.Line}): PopupBlock
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
    if documentLines then
        width = 0
        for i = 1, #documentLines do
            local indentW = documentLines[i].style == "definitionBody"
                and font:getWidth("    ") or 0
            width = math.max(width, indentW + font:getWidth(documentLines[i].text))
        end
    end
    return {lines = lines, documentLines = documentLines,
        rows = rows, colX = colX, width = width}
end

-- Lightweight Lua coloring for inspector output. It is intentionally lexical:
-- identifiers, literals, comments, and punctuation are enough to make a data
-- dump scannable without pulling a parser into the overlay.
local function drawLuaLine(font: lg.Font, line: string, x: number, y: number,
        key: string)
    local i = 1
    local tokenIndex = 0
    while i <= #line do
        local start = i
        local c = line:sub(i, i)
        local kind = "punctuation"
        if c:match("%s") then
            kind = "space"
            repeat i = i + 1 until i > #line or not line:sub(i, i):match("%s")
        elseif c == "-" and line:sub(i, i + 1) == "--" then
            kind = "comment"
            i = #line + 1
        elseif c == '"' or c == "'" then
            kind = "string"
            local quote = c
            i = i + 1
            while i <= #line do
                local ch = line:sub(i, i)
                i = i + 1
                if ch == "\\" then
                    i = math.min(#line + 1, i + 1)
                elseif ch == quote then
                    break
                end
            end
        elseif c:match("[%a_]") then
            kind = "identifier"
            i = i + 1
            while i <= #line and line:sub(i, i):match("[%w_]") do i = i + 1 end
        elseif c:match("%d") or (c == "-" and line:sub(i + 1, i + 1):match("%d")) then
            kind = "number"
            i = i + 1
            while i <= #line and line:sub(i, i):match("[%w%.%+%-]") do i = i + 1 end
        else
            i = i + 1
        end
        local token = line:sub(start, i - 1)
        if kind == "identifier" and (token == "true" or token == "false"
            or token == "nil") then
            kind = "keyword"
        end
        if kind == "identifier" then
            lg.setColor(0.45, 0.70, 1.0, 1)
        elseif kind == "keyword" then
            lg.setColor(POPUP_ACCENT[1], POPUP_ACCENT[2], POPUP_ACCENT[3], 1)
        elseif kind == "string" then
            lg.setColor(0.80, 0.66, 0.94, 1)
        elseif kind == "number" then
            lg.setColor(0.94, 0.69, 0.48, 1)
        elseif kind == "comment" then
            lg.setColor(0.54, 0.49, 0.62, 1)
        else
            lg.setColor(0.8275, 0.7765, 0.6667, 1)
        end
        if kind ~= "space" then
            tokenIndex = tokenIndex + 1
            lg.print(key .. "." .. tostring(tokenIndex), token, x, y)
        end
        x = x + font:getWidth(token)
    end
end

local function setDocumentColor(style: string)
    if style == "section" or style == "accent" then
        lg.setColor(POPUP_ACCENT[1], POPUP_ACCENT[2], POPUP_ACCENT[3], 1)
    elseif style == "definitionTerm" or style == "arg" then
        lg.setColor(0.45, 0.70, 1.0, 1)
    elseif style == "key" then
        lg.setColor(0.92, 0.88, 0.98, 1)
    elseif style == "code" then
        lg.setColor(0.94, 0.69, 0.48, 1)
    elseif style == "muted" then
        lg.setColor(0.54, 0.49, 0.62, 1)
    elseif style == "warning" then
        lg.setColor(0.96, 0.45, 0.48, 1)
    elseif style == "title" then
        lg.setColor(DEBUG_TEXT[1], DEBUG_TEXT[2], DEBUG_TEXT[3], 1)
    else
        lg.setColor(0.8275, 0.7765, 0.6667, 1)
    end
end

local function drawDocumentLine(font: lg.Font, line: markup.Line,
        x: number, y: number, width: number, key: string)
    if line.style == "rule" then
        lg.setColor(0.35, 0.40, 0.46, 0.8)
        lg.setLineWidth(1)
        lg.line(key .. ".rule", x, y + (font:getHeight() + 6) * 0.5, x + width,
            y + (font:getHeight() + 6) * 0.5)
        return
    end
    if line.style == "code" and line.language == "lua" then
        drawLuaLine(font, line.text, x, y, key .. ".lua")
        return
    end
    if line.style == "definitionBody" then x = x + font:getWidth("    ") end
    for i, span in ipairs(line.spans) do
        local style = span.style ~= "body" and span.style or line.style
        setDocumentColor(style)
        lg.print(key .. ".span." .. tostring(i), span.text, x, y)
        x = x + font:getWidth(span.text)
    end
end

-- Draw a command output/help popup in the game view (goto targets, info, ...).
-- Explicit titles get a dedicated header band; semantic blocks may fill
-- multiple columns. The resulting body remains one vertically scrollable
-- document. py is the panel's top edge; sw/sh are the available dimensions.
function popupview.draw(popup: PopupState, font: lg.Font,
        sw: number, sh: number, py: number)
    local fh = font:getHeight()
    local lineH = fh + 6
    local sourceLines = popup.lines
    local document = popup.document
    local hasExplicitTitle = popup.title ~= nil
        or (document ~= nil and document.title ~= nil)
    local header = popup.title
        or (document and document.title and document.title.text)
        or (not document and sourceLines[1])
    local headerRows = header and 1 or 0
    local fixedHeight = 8 + headerRows * lineH
        + POPUP_CONTENT_PAD_TOP + POPUP_CONTENT_PAD_BOTTOM
    local maxBodyH = math.max(lineH, sh - py - fixedHeight)
    local gap = font:getWidth("  ")
    -- Layout cache: semantic blocks are packed into the number of columns the
    -- current viewport can hold. Ordinary popups remain one flowing column.
    if popup.measuredLines ~= sourceLines or popup.measuredSw ~= sw
        or popup.measuredBlocks ~= popup.semanticBlocks
        or popup.measuredDocument ~= document then
        popup.measuredLines = sourceLines
        popup.measuredBlocks = popup.semanticBlocks
        popup.measuredDocument = document
        popup.measuredSw = sw
        local gutter = font:getWidth("    ")
        if document then
            local columnCount = 1
            for _, block in ipairs(document.blocks) do
                if block.kind == "columns" then
                    local requested = block.columnMode == "fixed"
                        and block.columnCount or #block.columns
                    columnCount = math.max(columnCount, requested, #block.columns)
                end
            end
            if popup.maxColumns > 0 then
                columnCount = math.min(columnCount, popup.maxColumns)
            end
            local minW = font:getWidth(string.rep(" ", 24))
            local availableW = math.max(minW,
                sw - PAD_X * 4 - POPUP_RIGHT_PAD - POPUP_SCROLLBAR_W - 8)
            local fit = math.max(1,
                math.floor((availableW + gutter) / (minW + gutter))) as integer
            columnCount = math.min(columnCount, fit)
            local columnW = math.max(minW,
                (availableW - gutter * (columnCount - 1)) / columnCount)
            local raw: {{markup.Line}} = {}
            for ci = 1, columnCount do raw[ci] = {} end
            local function padColumns()
                local height = 0
                for ci = 1, columnCount do height = math.max(height, #raw[ci]) end
                for ci = 1, columnCount do
                    while #raw[ci] < height do
                        raw[ci][#raw[ci] + 1] = markup.line("", "spacer")
                    end
                end
            end
            for _, block in ipairs(document.blocks) do
                padColumns()
                if block.kind == "flow" then
                    local before = #raw[1]
                    for _, line in ipairs(block.lines) do
                        line.span = true
                        appendWrappedDocumentLine(raw[1], font, line, availableW)
                    end
                    local added = #raw[1] - before
                    for ci = 2, columnCount do
                        for _ = 1, added do
                            raw[ci][#raw[ci] + 1] = markup.line("", "spacer")
                        end
                    end
                else
                    for sourceColumn, lines in ipairs(block.columns) do
                        local ci = ((sourceColumn - 1) % columnCount) + 1
                        if sourceColumn > columnCount and #raw[ci] > 0 then
                            raw[ci][#raw[ci] + 1] = markup.line("", "spacer")
                        end
                        for _, line in ipairs(lines) do
                            appendWrappedDocumentLine(raw[ci], font, line, columnW)
                        end
                    end
                    padColumns()
                end
            end
            local columns: {PopupBlock} = {}
            for ci = 1, columnCount do
                local textLines: {string} = {}
                for li = 1, #raw[ci] do textLines[li] = raw[ci][li].text end
                columns[ci] = measurePopupBlock(font, gap, textLines, raw[ci])
            end
            popup.columns = columns
            popup.columnWidth = columnW
            popup.columnGap = gutter
            popup.block = columns[1]
        elseif popup.semanticBlocks and #popup.semanticBlocks > 0 then
            local naturalW: number = 0
            for bi = 1, #popup.semanticBlocks do
                local semantic = popup.semanticBlocks[bi]
                for li = 1, #semantic do
                    naturalW = math.max(naturalW, font:getWidth(semantic[li]))
                end
            end
            local minW = font:getWidth(string.rep(" ", 24))
            local maxW = font:getWidth(string.rep(" ", 44))
            local columnW = math.max(minW, math.min(maxW, naturalW))
            local availableW = math.max(columnW,
                sw - PAD_X * 4 - POPUP_RIGHT_PAD - POPUP_SCROLLBAR_W - 8)
            local columnCount = math.max(1,
                math.floor((availableW + gutter) / (columnW + gutter))) as integer
            columnCount = math.min(columnCount, #popup.semanticBlocks)
            if popup.maxColumns > 0 then
                columnCount = math.min(columnCount, popup.maxColumns)
            end
            local rawColumns: {{string}} = {}
            local heights: {integer} = {}
            for ci = 1, columnCount do rawColumns[ci], heights[ci] = {}, 0 end
            for bi = 1, #popup.semanticBlocks do
                local shortest = 1
                for ci = 2, columnCount do
                    if heights[ci] < heights[shortest] then shortest = ci end
                end
                local out = rawColumns[shortest]
                if #out > 0 then out[#out + 1] = "" end
                local semantic = popup.semanticBlocks[bi]
                for li = 1, #semantic do
                    appendWrappedPopupLine(out, font, semantic[li], columnW)
                end
                heights[shortest] = #out
            end
            local columns: {PopupBlock} = {}
            for ci = 1, columnCount do
                columns[ci] = measurePopupBlock(font, gap, rawColumns[ci])
            end
            popup.columns = columns
            popup.columnWidth = columnW
            popup.columnGap = gutter
            popup.block = columns[1]
        else
            local firstLine = popup.title and 1 or 2
            local body = layoutPopupLines(font, sw, sourceLines, firstLine)
            popup.block = measurePopupBlock(font, gap, body)
            popup.columns = {popup.block}
            popup.columnWidth = popup.block.width
            popup.columnGap = 0
        end
    end
    local columns = popup.columns
    local totalRows = 0
    for ci = 1, #columns do totalRows = math.max(totalRows, #columns[ci].lines) end

    -- Semantic section headings get real pixel padding rather than blank
    -- document rows. Scroll positions remain row-based, while layout and the
    -- scrollbar use the resulting variable row heights.
    local rowHeights: {number} = {}
    local rowTopPads: {number} = {}
    local totalContentH: number = 0
    for i = 1, totalRows do
        local section = false
        if document then
            for ci = 1, #columns do
                local lines = columns[ci].documentLines
                if lines and lines[i] and lines[i].style == "section" then
                    section = true
                    break
                end
            end
        end
        local topPad: number = 0
        if section then
            topPad = i == 1 and POPUP_SECTION_PAD_TOP or lineH
        end
        local bottomPad = section and POPUP_SECTION_PAD_BOTTOM or 0
        rowTopPads[i] = topPad
        rowHeights[i] = lineH + topPad + bottomPad
        totalContentH = totalContentH + rowHeights[i]
    end

    local bottomFirst = totalRows + 1
    local bottomHeight: number = 0
    for i = totalRows, 1, -1 do
        if bottomHeight > 0 and bottomHeight + rowHeights[i] > maxBodyH then
            break
        end
        bottomHeight = bottomHeight + rowHeights[i]
        bottomFirst = i
    end
    popup.scrollMax = math.max(0, bottomFirst - 1)
    if popup.scrollToEndPending then
        popup.scroll = popup.scrollMax
        popup.scrollToEndPending = false
    end
    popup.scroll = math.max(0, math.min(popup.scroll, popup.scrollMax))
    local firstRow = math.floor(popup.scroll) + 1
    local lastRow = firstRow - 1
    local bodyH: number = 0
    for i = firstRow, totalRows do
        if bodyH > 0 and bodyH + rowHeights[i] > maxBodyH then break end
        bodyH = bodyH + rowHeights[i]
        lastRow = i
    end
    local visibleRows = math.max(0, lastRow - firstRow + 1)
    -- The viewport height belongs to the document, not the current scroll
    -- slice. Variable-height section rows can leave less occupied space at
    -- the bottom; preserve that space instead of making the panel jump.
    bodyH = math.min(maxBodyH, totalContentH)
    local scrollable = totalContentH > bodyH
    popup.visibleRows = visibleRows
    local scrollbarSpace = scrollable and (POPUP_SCROLLBAR_W + 8) or 0
    local columnsW = #columns * popup.columnWidth
        + math.max(0, #columns - 1) * popup.columnGap
    local contentW = math.max(header and font:getWidth(header) or 0, columnsW)
    local panelW = math.min(sw - PAD_X * 2,
        contentW + PAD_X + POPUP_RIGHT_PAD + scrollbarSpace)
    local panelH = bodyH + lineH * headerRows + 8
        + POPUP_CONTENT_PAD_TOP + POPUP_CONTENT_PAD_BOTTOM
    popup.panelX, popup.panelY = PAD_X, py
    popup.panelW, popup.panelH = panelW, panelH
    if popup.modal then
        lg.setColor(0.035, 0.018, 0.055, 0.76)
        -- Dim the game view without partially covering the debugger's own
        -- forward-rendered status text and command line.
        lg.setScissor(0, 0, sw, math.max(0, sh - 1))
        lg.rectangle("popup.scrim", "fill", 0, 0, sw, sh)
        lg.setScissor()
    end
    lg.setColor(0.025, 0.012, 0.04, 0.75)
    lg.rectangle("popup.shadow", "fill", PAD_X + 4, py + 5,
        panelW, panelH, 4, 4)
    lg.setColor(POPUP_BG[1], POPUP_BG[2], POPUP_BG[3], POPUP_BG[4])
    lg.rectangle("popup.panel", "fill", PAD_X, py, panelW, panelH, 4, 4)
    lg.setColor(POPUP_ACCENT[1], POPUP_ACCENT[2], POPUP_ACCENT[3], 0.95)
    lg.setLineWidth(1)
    lg.rectangle("popup.border", "line", PAD_X, py, panelW, panelH, 4, 4)
    if hasExplicitTitle then
        lg.setColor(0.17, 0.11, 0.23, 1)
        lg.rectangle("popup.title.background", "fill", PAD_X + 1, py + 1,
            panelW - 2, lineH + 7, 4, 4)
        lg.setColor(POPUP_ACCENT[1], POPUP_ACCENT[2], POPUP_ACCENT[3], 0.8)
        lg.setLineWidth(2)
        lg.line("popup.title.rule", PAD_X + 1, py + lineH + 8,
            PAD_X + panelW - 1, py + lineH + 8)
        if popup.closable then
            local radius = 5
            popup.closeX = PAD_X + panelW - POPUP_RIGHT_PAD
            popup.closeY = py + 4 + lineH * 0.5
            popup.closeRadius = radius + 3
            lg.setColor(0.88, 0.24, 0.30, 1)
            lg.circle("popup.close", "fill", popup.closeX, popup.closeY, radius)
        else
            popup.closeRadius = 0
        end
    end
    -- Thumbnail (screenshot info): scaled to fit under the panel.
    if popup.image then
        local iw = popup.image:getWidth()
        local ih = popup.image:getHeight()
        local maxW = sw - PAD_X * 2
        local maxH = sh - (py + panelH) - PAD_X * 2
        if iw > 0 and ih > 0 and maxH > 24 then
            local scale = math.min(maxW / iw, maxH / ih, 1)
            local ty = py + panelH + 8
            lg.setColor(POPUP_BG[1], POPUP_BG[2], POPUP_BG[3], 0.98)
            lg.rectangle("popup.image.background", "fill", PAD_X, ty,
                iw * scale + 8, ih * scale + 8, 4, 4)
            lg.setColor(1, 1, 1, 1)
            lg.draw("popup.image", popup.image, PAD_X + 4, ty + 4,
                0, scale, scale)
            lg.setColor(POPUP_ACCENT[1], POPUP_ACCENT[2], POPUP_ACCENT[3], 0.9)
            lg.setLineWidth(1)
            lg.rectangle("popup.image.border", "line", PAD_X + 4, ty + 4,
                iw * scale, ih * scale)
        end
    end
    if hasExplicitTitle then
        lg.setColor(DEBUG_TEXT[1], DEBUG_TEXT[2], DEBUG_TEXT[3], 1)
    else
        lg.setColor(POPUP_ACCENT[1], POPUP_ACCENT[2], POPUP_ACCENT[3], 1)
    end
    if header then
        if document and document.title and not popup.title then
            drawDocumentLine(font, document.title, PAD_X * 2, py + 8,
                popup.columnWidth, "popup.title")
        else
            lg.print("popup.title", header, PAD_X * 2, py + 8)
        end
    end

    local bodyY = py + 8 + headerRows * lineH + POPUP_CONTENT_PAD_TOP
    lg.setScissor(PAD_X, bodyY, panelW, bodyH)
    local rowY: {number} = {}
    local nextY = bodyY
    for i = firstRow, lastRow do
        rowY[i] = nextY + rowTopPads[i]
        nextY = nextY + rowHeights[i]
    end
    for ci = 1, #columns do
        local col = columns[ci]
        local bx = PAD_X * 2 + (ci - 1) * (popup.columnWidth + popup.columnGap)
        local colLast = math.min(#col.lines, lastRow)
        for i = firstRow, colLast do
            local yy = rowY[i]
            local line = col.lines[i]
            if col.documentLines then
                drawDocumentLine(font, col.documentLines[i], bx, yy,
                    col.documentLines[i].span and columnsW or popup.columnWidth,
                    "popup.body." .. tostring(ci) .. "." .. tostring(i))
            elseif line == HRULE then
                lg.setColor(0.35, 0.40, 0.46, 0.8)
                lg.setLineWidth(1)
                lg.line("popup.rule." .. tostring(ci) .. "." .. tostring(i),
                    bx, yy + lineH * 0.5,
                    bx + popup.columnWidth, yy + lineH * 0.5)
            elseif popup.language == "lua" then
                drawLuaLine(font, line, bx, yy,
                    "popup.lua." .. tostring(ci) .. "." .. tostring(i))
            else
                local br, bg, bb = 0.8275, 0.7765, 0.6667
                if line:sub(1, 1) ~= " " then
                    br, bg, bb = POPUP_ACCENT[1], POPUP_ACCENT[2],
                        POPUP_ACCENT[3]
                end
                local cols = col.rows[i]
                local nameCol = line:sub(1, 1) == " " and #cols > 1
                for j = 1, #cols do
                    if nameCol and j == 1 then
                        lg.setColor(0.45, 0.70, 1.0, 1)
                    else
                        lg.setColor(br, bg, bb, 1)
                    end
                    lg.print("popup.cell." .. tostring(ci) .. "."
                        .. tostring(i) .. "." .. tostring(j),
                        cols[j], bx + col.colX[j], yy)
                end
            end
        end
    end
    lg.setScissor()

    if scrollable then
        local trackX = PAD_X + panelW - POPUP_SCROLLBAR_W - 7
        local trackY = bodyY + 2
        local trackH = math.max(1, bodyH - 4)
        local thumbH = math.max(18,
            trackH * math.min(1, bodyH / math.max(1, totalContentH)))
        local thumbTravel = math.max(0, trackH - thumbH)
        local thumbY = trackY
        if popup.scrollMax > 0 then
            local scrollOffset: number = 0
            for i = 1, firstRow - 1 do
                scrollOffset = scrollOffset + rowHeights[i]
            end
            local maxOffset = math.max(1, totalContentH - bodyH)
            thumbY = trackY + thumbTravel
                * math.min(1, scrollOffset / maxOffset)
        end
        lg.setColor(0.20, 0.14, 0.27, 1)
        lg.rectangle("popup.scroll.track", "fill", trackX, trackY,
            POPUP_SCROLLBAR_W, trackH, 3, 3)
        lg.setColor(POPUP_ACCENT[1], POPUP_ACCENT[2], POPUP_ACCENT[3], 0.95)
        lg.rectangle("popup.scroll.thumb", "fill", trackX, thumbY,
            POPUP_SCROLLBAR_W, thumbH, 3, 3)
    end
end


return popupview
