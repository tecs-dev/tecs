--- BMFont parser for bitmap font atlases.
--- Parses BMFont text format (.fnt) and JSON format (.json) files.
--- Supports MSDF/SDF fonts: when a font has distanceField metadata,
--- it is automatically rendered with the MSDF shader pipeline.

local lg <const> = love.graphics
local json <const> = require("tecs.utils.json")

-- Font cache to avoid loading the same font multiple times
-- Each font load creates a GPU texture, so caching is essential for performance
local fontCache: {string: any} = {}

local record bmfont
    --- Metrics for a single character in the atlas.
    record BMFontChar
        --- Unicode codepoint
        id: integer
        --- X position in atlas (pixels)
        x: number
        --- Y position in atlas (pixels)
        y: number
        --- Glyph width in atlas (pixels)
        width: number
        --- Glyph height in atlas (pixels)
        height: number
        --- X offset when rendering (pixels)
        xoffset: number
        --- Y offset when rendering (pixels)
        yoffset: number
        --- Horizontal advance to next glyph (pixels)
        xadvance: number
        --- Atlas page index (0 for single-page fonts)
        page: integer
    end

    --- Distance field info for MSDF fonts.
    record DistanceField
        --- Field type: "msdf", "sdf", or "psdf"
        fieldType: string
        --- Distance range in pixels
        distanceRange: number
    end

    --- A loaded BMFont with metrics and atlas.
    record BMFont
        --- Font type: "bitmap", "msdf", "sdf", or "psdf"
        type: string
        --- Font face name
        face: string
        --- Font size in pixels
        size: number
        --- Line height (distance between baselines)
        lineHeight: number
        --- Baseline offset from top
        base: number
        --- Atlas texture width
        scaleW: number
        --- Atlas texture height
        scaleH: number
        --- Atlas image filename (relative to font file)
        page: string
        --- Character metrics keyed by codepoint
        chars: {integer: BMFontChar}
        --- Kerning pairs keyed by "first:second" codepoint strings.
        --- String keys are used (rather than packed integers) to support
        --- Unicode codepoints beyond the BMP without collision.
        kernings: {string: number}
        --- The loaded atlas texture
        atlas: love.graphics.Image
        --- Distance field info (for MSDF/SDF fonts)
        distanceField: DistanceField

        --- Get character metrics for a codepoint.
        --- Returns nil if character not found.
        getChar: function(BMFont, codepoint: integer): BMFontChar

        --- Get kerning amount between two codepoints.
        --- Returns 0 if no kerning defined.
        getKerning: function(BMFont, left: integer, right: integer): number

        --- Check if this is an MSDF/SDF font.
        isSDF: function(BMFont): boolean

        --- Attach an atlas image to a parsed BMFont.
        --- Sets appropriate texture filter based on font type (linear for SDF, nearest for bitmap).
        --- @param atlasImage The atlas texture to attach
        setAtlas: function(BMFont, atlasImage: love.graphics.Image)
    end

    --- Load a BMFont from a .fnt or .json file.
    --- Automatically detects format by extension.
    --- @param fontPath Path to the font definition file
    --- @return BMFont The loaded font
    load: function(fontPath: string): BMFont

    --- Load a BMFont from text format (.fnt file).
    --- @param fntPath Path to the .fnt file
    --- @return BMFont The loaded font
    loadText: function(fntPath: string): BMFont

    --- Load a BMFont from JSON format (.json file).
    --- Supports msdf-bmfont and msdf-bmfont-web output.
    --- @param jsonPath Path to the .json file
    --- @return BMFont The loaded font
    loadJson: function(jsonPath: string): BMFont

    --- Parse font file content into a BMFont without loading the atlas.
    --- The atlas field will be nil; read the .page field to get the atlas filename,
    --- then load the image and assign it to .atlas before use.
    --- @param content The font file content as string
    --- @param fontPath Path for format detection (uses extension)
    --- @return BMFont with metrics populated but atlas=nil
    parse: function(content: string, fontPath: string): BMFont
end

local BMFont <const> = bmfont.BMFont

function BMFont:getChar(codepoint: integer): bmfont.BMFontChar
    return self.chars[codepoint]
end

function BMFont:getKerning(left: integer, right: integer): number
    return self.kernings[left .. ":" .. right] or 0
end

function BMFont:isSDF(): boolean
    return self.type == "msdf" or self.type == "sdf" or self.type == "psdf"
end

function BMFont:setAtlas(atlasImage: love.graphics.Image)
    if self:isSDF() then
        atlasImage:setFilter("linear", "linear")
    else
        atlasImage:setFilter("nearest", "nearest")
    end
    self.atlas = atlasImage
end

-- Parse a key=value pair from BMFont text format
local function parseKeyValue(str: string): string, string
    local key, value = str:match("([%w_]+)=(.+)")
    if not key then
        return nil, nil
    end
    -- Remove quotes from string values
    if value:sub(1, 1) == '"' then
        value = value:sub(2, -2)
    end
    return key, value
end

-- Parse a line of BMFont text format into key-value pairs.
-- Tokens are split on whitespace, but whitespace inside quoted values is
-- preserved so that entries like `face="Arial Bold"` stay as one token.
local function parseLine(line: string): string, {string: string}
    local parts: {string} = {}
    local i = 1
    local len = #line
    while i <= len do
        local c = line:sub(i, i)
        if c == ' ' or c == '\t' then
            i = i + 1
        else
            -- Find end of token, tracking whether we're inside quotes so
            -- spaces inside quoted values don't split the token.
            local j = i
            local inQuotes = false
            while j <= len do
                local ch = line:sub(j, j)
                if ch == '"' then
                    inQuotes = not inQuotes
                    j = j + 1
                elseif (ch == ' ' or ch == '\t') and not inQuotes then
                    break
                else
                    j = j + 1
                end
            end
            parts[#parts + 1] = line:sub(i, j - 1)
            i = j
        end
    end

    if #parts == 0 then
        return nil, {}
    end

    local tag = parts[1]
    local values: {string: string} = {}

    for idx = 2, #parts do
        local key, value = parseKeyValue(parts[idx])
        if key then
            values[key] = value
        end
    end

    return tag, values
end

-- Get directory from path
local function getDirectory(path: string): string
    local dir = path:match("(.*/)")
    return dir or ""
end

-- Get file extension (lowercase)
local function getExtension(path: string): string
    local ext = path:match("%.([^%.]+)$")
    return ext and ext:lower() or ""
end

-- Create font with metatable
local function createFont(): bmfont.BMFont
    local font: bmfont.BMFont = {
        type = "bitmap",
        face = "",
        size = 0,
        lineHeight = 0,
        base = 0,
        scaleW = 0,
        scaleH = 0,
        page = "",
        chars = {},
        kernings = {},
    }
    setmetatable(font, {__index = BMFont})
    return font
end

-- JSON data types for parsing
local record JsonChar
    id: number
    x: number
    y: number
    width: number
    height: number
    xoffset: number
    yoffset: number
    xadvance: number
    page: number
    chnl: number
end

local record JsonKerning
    first: number
    second: number
    amount: number
end

local record JsonInfo
    face: string
    size: number
end

local record JsonCommon
    lineHeight: number
    base: number
    scaleW: number
    scaleH: number
end

local record JsonDistanceField
    fieldType: string
    distanceRange: number
end

local record JsonBMFont
    pages: {string}
    chars: {JsonChar}
    kernings: {JsonKerning}
    info: JsonInfo
    common: JsonCommon
    distanceField: JsonDistanceField
end

-- Parse text format content into BMFont (without loading atlas)
local function parseTextContent(content: string): bmfont.BMFont
    local font = createFont()

    for line in content:gmatch("[^\r\n]+") do
        local tag, values = parseLine(line)

        if tag == "info" then
            font.face = values["face"] or ""
            font.size = tonumber(values["size"]) or 0

        elseif tag == "common" then
            font.lineHeight = tonumber(values["lineHeight"]) or 0
            font.base = tonumber(values["base"]) or 0
            font.scaleW = tonumber(values["scaleW"]) or 0
            font.scaleH = tonumber(values["scaleH"]) or 0

            local pageCount = tonumber(values["pages"]) or 1
            if pageCount > 1 then
                error("BMFont: multi-page fonts are not supported (found " .. pageCount .. " pages)")
            end

        elseif tag == "page" then
            local pageId = tonumber(values["id"]) or 0
            if pageId > 0 then
                error("BMFont: multi-page fonts are not supported (found page id " .. pageId .. ")")
            end
            font.page = values["file"] or ""

        elseif tag == "char" then
            local charPage = (tonumber(values["page"]) or 0) as integer
            if charPage > 0 then
                error("BMFont: multi-page fonts are not supported (char id " ..
                    (values["id"] or "?") .. " references page " .. charPage .. ")")
            end
            local char: bmfont.BMFontChar = {
                id = (tonumber(values["id"]) or 0) as integer,
                x = tonumber(values["x"]) or 0,
                y = tonumber(values["y"]) or 0,
                width = tonumber(values["width"]) or 0,
                height = tonumber(values["height"]) or 0,
                xoffset = tonumber(values["xoffset"]) or 0,
                yoffset = tonumber(values["yoffset"]) or 0,
                xadvance = tonumber(values["xadvance"]) or 0,
                page = charPage,
            }
            font.chars[char.id] = char

        elseif tag == "kerning" then
            local first = (tonumber(values["first"]) or 0) as integer
            local second = (tonumber(values["second"]) or 0) as integer
            local amount = tonumber(values["amount"]) or 0
            font.kernings[first .. ":" .. second] = amount
        end
    end

    return font
end

-- Parse JSON format content into BMFont (without loading atlas)
local function parseJsonContent(content: string): bmfont.BMFont
    local data = json.parse(content) as JsonBMFont
    if not data then
        error("Failed to parse BMFont JSON content")
    end

    local font = createFont()

    if data.info then
        font.face = data.info.face or ""
        font.size = data.info.size or 0
    end

    if data.common then
        font.lineHeight = data.common.lineHeight or 0
        font.base = data.common.base or 0
        font.scaleW = data.common.scaleW or 0
        font.scaleH = data.common.scaleH or 0
    end

    if data.pages then
        if #data.pages > 1 then
            error("BMFont: multi-page fonts are not supported (found " .. #data.pages .. " pages)")
        end
        if data.pages[1] then
            font.page = data.pages[1]
        end
    end

    if data.distanceField then
        font.distanceField = {
            fieldType = data.distanceField.fieldType or "msdf",
            distanceRange = data.distanceField.distanceRange or 4,
        }
        font.type = data.distanceField.fieldType or "msdf"
    end

    if data.chars then
        for _, c in ipairs(data.chars) do
            local charPage = (c.page or 0) as integer
            if charPage > 0 then
                error("BMFont: multi-page fonts are not supported (char id " ..
                    tostring(c.id or "?") .. " references page " .. charPage .. ")")
            end
            local char: bmfont.BMFontChar = {
                id = (c.id or 0) as integer,
                x = c.x or 0,
                y = c.y or 0,
                width = c.width or 0,
                height = c.height or 0,
                xoffset = c.xoffset or 0,
                yoffset = c.yoffset or 0,
                xadvance = c.xadvance or 0,
                page = charPage,
            }
            font.chars[char.id] = char
        end
    end

    if data.kernings then
        for _, k in ipairs(data.kernings) do
            local first = (k.first or 0) as integer
            local second = (k.second or 0) as integer
            local amount = k.amount or 0
            font.kernings[first .. ":" .. second] = amount
        end
    end

    return font
end

function bmfont.parse(content: string, fontPath: string): bmfont.BMFont
    local ext = getExtension(fontPath)

    if ext == "json" then
        return parseJsonContent(content)
    elseif ext == "fnt" then
        return parseTextContent(content)
    else
        error("BMFont.parse: unsupported file extension '" .. ext .. "', expected .json or .fnt: " .. fontPath)
    end
end

function bmfont.loadText(fntPath: string): bmfont.BMFont
    local content = love.filesystem.read(fntPath)
    if not content then
        error("Failed to read BMFont file: " .. fntPath)
    end

    local font = parseTextContent(content)
    if font.page == nil or font.page == "" then
        error("BMFont: atlas page filename missing in " .. fntPath)
    end
    local dir = getDirectory(fntPath)
    local atlasPath = dir .. font.page
    local atlasImage = lg.newImage(atlasPath)
    font:setAtlas(atlasImage)

    return font
end

function bmfont.loadJson(jsonPath: string): bmfont.BMFont
    local content = love.filesystem.read(jsonPath)
    if not content then
        error("Failed to read BMFont JSON file: " .. jsonPath)
    end

    local font = parseJsonContent(content)
    if font.page == nil or font.page == "" then
        error("BMFont: atlas page filename missing in " .. jsonPath)
    end
    local dir = getDirectory(jsonPath)
    local atlasPath = dir .. font.page
    local atlasImage = lg.newImage(atlasPath, {linear = font:isSDF()})
    font:setAtlas(atlasImage)

    return font
end

function bmfont.load(fontPath: string): bmfont.BMFont
    -- Check cache first to avoid creating duplicate GPU textures
    local cached = fontCache[fontPath]
    if cached then
        return cached as bmfont.BMFont
    end

    local ext = getExtension(fontPath)
    local font: bmfont.BMFont

    if ext == "json" then
        font = bmfont.loadJson(fontPath)
    elseif ext == "fnt" then
        font = bmfont.loadText(fontPath)
    else
        error("BMFont.load: unsupported file extension '" .. ext .. "', expected .json or .fnt: " .. fontPath)
    end

    -- Cache the loaded font
    fontCache[fontPath] = font
    return font
end

return bmfont
