--- Typed debugger-popup documents and their optional authored markup.
--- Built-in help constructs Documents directly; custom command results may
--- provide markup text, which is parsed into the same model before layout.

local record markup
    record Span
        text: string
        style: string
    end

    record Line
        text: string
        style: string
        language: string
        spans: {Span}
        --- Layout hint set for flow rows that span explicit column groups.
        span: boolean
    end

    record Block
        --- "flow" or "columns".
        kind: string
        lines: {Line}
        columns: {{Line}}
        columnMode: string
        columnCount: integer
    end

    record Document
        title: Line
        blocks: {Block}
    end

    new: function(title?: string): Document
    line: function(text: string, style?: string, language?: string): Line
    add: function(document: Document, line: Line)
    text: function(document: Document, text: string, style?: string)
    section: function(document: Document, text: string)
    definition: function(document: Document, term: string, body: string)
    rule: function(document: Document)
    code: function(document: Document, language: string, source: string)
    columns: function(document: Document, columns: {{Line}}, mode?: string,
        count?: integer)
    parse: function(source: string): Document, string
    plainLines: function(document: Document): {string}
end

local INLINE_STYLES <const>: {string: boolean} = {
    key = true,
    code = true,
    arg = true,
    accent = true,
    muted = true,
    warning = true,
}

local function parseSpans(text: string, lineNumber?: integer): {markup.Span}, string
    local spans: {markup.Span} = {}
    local cursor = 1
    while cursor <= #text do
        local openStart, openEnd, style = text:find("%[([%a]+)%]", cursor)
        if not openStart then
            spans[#spans + 1] = {text = text:sub(cursor), style = "body"}
            break
        end
        if openStart > cursor then
            spans[#spans + 1] = {text = text:sub(cursor, openStart - 1),
                style = "body"}
        end
        if not INLINE_STYLES[style] then
            spans[#spans + 1] = {text = text:sub(openStart, openEnd),
                style = "body"}
            cursor = openEnd + 1
        else
            local close = "[/" .. style .. "]"
            local closeStart, closeEnd = text:find(close, openEnd + 1, true)
            if not closeStart then
                return nil, "line " .. tostring(lineNumber or 1)
                    .. ": expected " .. close
            end
            spans[#spans + 1] = {
                text = text:sub(openEnd + 1, closeStart - 1),
                style = style,
            }
            cursor = closeEnd + 1
        end
    end
    if #spans == 0 then spans[1] = {text = "", style = "body"} end
    return spans
end

function markup.line(text: string, style?: string, language?: string): markup.Line
    local spans: {markup.Span}
    if style == "code" then
        spans = {{text = text, style = "code"}}
    else
        local parsed, err = parseSpans(text)
        if not parsed then error("popup markup: " .. err) end
        spans = parsed
    end
    local plain = ""
    for i = 1, #spans do plain = plain .. spans[i].text end
    return {
        text = plain,
        style = style or "body",
        language = language,
        spans = spans,
    }
end

function markup.new(title?: string): markup.Document
    return {
        title = title and markup.line(title, "title") or nil,
        blocks = {},
    }
end

local function flow(document: markup.Document): markup.Block
    local block = document.blocks[#document.blocks]
    if not block or block.kind ~= "flow" then
        block = {kind = "flow", lines = {}}
        document.blocks[#document.blocks + 1] = block
    end
    return block
end

function markup.add(document: markup.Document, line: markup.Line)
    local block = flow(document)
    block.lines[#block.lines + 1] = line
end

function markup.text(document: markup.Document, text: string, style?: string)
    markup.add(document, markup.line(text, style or "body"))
end

function markup.section(document: markup.Document, text: string)
    markup.add(document, markup.line(text, "section"))
end

function markup.definition(document: markup.Document, term: string, body: string)
    markup.add(document, markup.line(term, "definitionTerm"))
    for line in (body .. "\n"):gmatch("(.-)\n") do
        markup.add(document, markup.line(line, "definitionBody"))
    end
end

function markup.rule(document: markup.Document)
    markup.add(document, markup.line("", "rule"))
end

function markup.code(document: markup.Document, language: string, source: string)
    for line in (source .. "\n"):gmatch("(.-)\n") do
        markup.add(document, markup.line(line, "code", language))
    end
end

function markup.columns(document: markup.Document, columns: {{markup.Line}},
        mode?: string, count?: integer)
    document.blocks[#document.blocks + 1] = {
        kind = "columns",
        columns = columns,
        columnMode = mode or "auto",
        columnCount = count or 0,
    }
end

local function directive(line: string): string, string
    local name, rest = line:match("^@([%a]+)%s*(.*)$")
    return name, rest
end

local function parseContentLine(raw: string, style: string,
        lineNumber: integer, language?: string): markup.Line, string
    local spans, err = parseSpans(raw, lineNumber)
    if not spans then return nil, err end
    local plain = ""
    for i = 1, #spans do plain = plain .. spans[i].text end
    return {text = plain, style = style, language = language, spans = spans}
end

local function splitLines(source: string): {string}
    local lines: {string} = {}
    source = source:gsub("\r\n", "\n"):gsub("\r", "\n")
    if source:sub(-1) ~= "\n" then source = source .. "\n" end
    for line in source:gmatch("(.-)\n") do lines[#lines + 1] = line end
    return lines
end

local function collectCode(lines: {string}, start: integer,
        language: string): {markup.Line}, integer, string
    local out: {markup.Line} = {}
    local i = start
    while i <= #lines do
        local name = directive(lines[i])
        if name == "endCode" then return out, i + 1 end
        if name and name:match("^end") then
            return nil, i, "line " .. tostring(i)
                .. ": expected @endCode, found @" .. name
        end
        out[#out + 1] = {
            text = lines[i], style = "code", language = language,
            spans = {{text = lines[i], style = "code"}},
        }
        i = i + 1
    end
    return nil, i, "line " .. tostring(start - 1) .. ": missing @endCode"
end

local function collectDefinition(lines: {string}, start: integer,
        term: string): {markup.Line}, integer, string
    local out: {markup.Line} = {markup.line(term, "definitionTerm")}
    local i = start
    while i <= #lines do
        local name = directive(lines[i])
        if name == "endDef" then return out, i + 1 end
        if name and name:match("^end") then
            return nil, i, "line " .. tostring(i)
                .. ": expected @endDef, found @" .. name
        end
        local parsed, err = parseContentLine(lines[i], "definitionBody", i)
        if not parsed then return nil, i, err end
        out[#out + 1] = parsed
        i = i + 1
    end
    return nil, i, "line " .. tostring(start - 1) .. ": missing @endDef"
end

local function parseColumn(lines: {string}, start: integer): {markup.Line},
        integer, string, string
    local out: {markup.Line} = {}
    local i = start
    while i <= #lines do
        local name, rest = directive(lines[i])
        if name == "column" or name == "endColumns" then
            return out, i, name
        elseif name == "code" then
            local codeLines, nextLine, err = collectCode(lines, i + 1,
                rest ~= "" and rest or "text")
            if not codeLines then return nil, nextLine, nil, err end
            for j = 1, #codeLines do out[#out + 1] = codeLines[j] end
            i = nextLine
        elseif name == "def" then
            if rest == "" then return nil, i, nil, "line " .. tostring(i)
                .. ": @def requires a term" end
            local definition, nextLine, err = collectDefinition(lines, i + 1, rest)
            if not definition then return nil, nextLine, nil, err end
            for j = 1, #definition do out[#out + 1] = definition[j] end
            i = nextLine
        elseif name == "section" or name == "text" then
            local parsed, err = parseContentLine(rest,
                name == "section" and "section" or "body", i)
            if not parsed then return nil, i, nil, err end
            out[#out + 1] = parsed
            i = i + 1
        elseif name == "rule" then
            out[#out + 1] = markup.line("", "rule")
            i = i + 1
        elseif name then
            return nil, i, nil, "line " .. tostring(i)
                .. ": unexpected @" .. name .. " inside @columns"
        else
            local parsed, err = parseContentLine(lines[i], "body", i)
            if not parsed then return nil, i, nil, err end
            out[#out + 1] = parsed
            i = i + 1
        end
    end
    return nil, i, nil, "line " .. tostring(start - 1) .. ": missing @endColumns"
end

function markup.parse(source: string): markup.Document, string
    local lines = splitLines(source)
    local document = markup.new()
    local i = 1
    while i <= #lines do
        local name, rest = directive(lines[i])
        if name == "title" then
            if document.title then
                return nil, "line " .. tostring(i) .. ": duplicate @title"
            end
            local title, err = parseContentLine(rest, "title", i)
            if not title then return nil, err end
            document.title = title
            i = i + 1
        elseif name == "section" or name == "text" then
            local parsed, err = parseContentLine(rest,
                name == "section" and "section" or "body", i)
            if not parsed then return nil, err end
            markup.add(document, parsed)
            i = i + 1
        elseif name == "rule" then
            markup.rule(document)
            i = i + 1
        elseif name == "def" then
            if rest == "" then
                return nil, "line " .. tostring(i) .. ": @def requires a term"
            end
            local definition, nextLine, err = collectDefinition(lines, i + 1, rest)
            if not definition then return nil, err end
            for j = 1, #definition do markup.add(document, definition[j]) end
            i = nextLine
        elseif name == "code" then
            local codeLines, nextLine, err = collectCode(lines, i + 1,
                rest ~= "" and rest or "text")
            if not codeLines then return nil, err end
            for j = 1, #codeLines do markup.add(document, codeLines[j]) end
            i = nextLine
        elseif name == "columns" then
            local mode = rest ~= "" and rest or "auto"
            local count = tonumber(mode)
            if mode ~= "auto" and not count then
                return nil, "line " .. tostring(i)
                    .. ": @columns expects auto or a positive integer"
            end
            if count and count < 1 then
                return nil, "line " .. tostring(i)
                    .. ": @columns count must be positive"
            end
            i = i + 1
            local columns: {{markup.Line}} = {}
            while i <= #lines do
                local columnName = directive(lines[i])
                if columnName == "endColumns" then break end
                if columnName ~= "column" then
                    return nil, "line " .. tostring(i)
                        .. ": expected @column or @endColumns"
                end
                local column, nextLine, stop, err = parseColumn(lines, i + 1)
                if not column then return nil, err end
                columns[#columns + 1] = column
                i = nextLine
                if stop == "endColumns" then break end
            end
            if i > #lines or directive(lines[i]) ~= "endColumns" then
                return nil, "line " .. tostring(i) .. ": missing @endColumns"
            end
            if #columns == 0 then
                return nil, "line " .. tostring(i) .. ": @columns requires @column"
            end
            markup.columns(document, columns, count and "fixed" or "auto",
                count and (count as integer) or 0)
            i = i + 1
        elseif name and name:match("^end") then
            return nil, "line " .. tostring(i) .. ": unexpected @" .. name
        elseif name then
            return nil, "line " .. tostring(i) .. ": unknown directive @" .. name
        else
            local parsed, err = parseContentLine(lines[i], "body", i)
            if not parsed then return nil, err end
            markup.add(document, parsed)
            i = i + 1
        end
    end
    return document
end

function markup.plainLines(document: markup.Document): {string}
    local out: {string} = {}
    if document.title then out[#out + 1] = document.title.text end
    for _, block in ipairs(document.blocks) do
        if block.kind == "flow" then
            for _, line in ipairs(block.lines) do
                if line.style == "rule" then
                    out[#out + 1] = string.rep("-", 40)
                else
                    out[#out + 1] = line.text
                end
            end
        else
            for ci, column in ipairs(block.columns) do
                if ci > 1 then out[#out + 1] = "" end
                for _, line in ipairs(column) do out[#out + 1] = line.text end
            end
        end
    end
    return out
end

return markup
