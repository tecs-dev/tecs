--- Immediate debug drawing facade backed by a dedicated render world.
---
--- The debugger intentionally keeps its existing immediate layout code, but
--- every draw call below becomes a normal Tecs2D drawable entity. The facade
--- is active only while the debug world's RenderLast systems build a frame.

local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")
local bmfont <const> = require("tecs2d.gfx.bmfont")
local ui <const> = require("tecs2d.ui")
local MarkerBatch <const> = require("tecs2d.debug.internal.MarkerBatch")
local bit <const> = require("bit")

local Transform <const> = tecs.builtins.Transform
local RelativeTransform <const> = tecs.builtins.RelativeTransform
local ChildOf <const> = tecs.builtins.ChildOf
local native <const> = love.graphics
local FONT_PATH <const> = "tecs2d/assets/fonts/jetbrainsmono-extrabold-msdf.json"

local record DebugFont
    metrics: bmfont.BMFont
    height: number
    scale: number
    drawOffsetX: number
    drawOffsetY: number

    getHeight: function(self): number
    getWidth: function(self, text: string): number
    getWrap: function(self, text: string, limit: number): number, {string}
end

local record FitSlot
    parent: integer
    child: integer
end

local record DebugView
    world: tecs.World
    entities: {integer}
    fitSlots: {FitSlot}
    fitCount: integer
    color: {number}
    font: DebugFont
    defaultFont: DebugFont
    lineWidth: number
    clip: {number}
    z: number
    markers: MarkerBatch
end

local active: DebugView = nil

local record debugdraw
    type View = DebugView
    type Font = DebugFont
    beginFrame: function(view: DebugView)
    endFrame: function()
    newView: function(world: tecs.World): DebugView
    push: function(mode?: string)
    pop: function()
    origin: function()
    setColor: function(r: number, g: number, b: number, a?: number)
    setFont: function(font: DebugFont)
    getFont: function(): DebugFont
    setLineWidth: function(width: number)
    setScissor: function(x?: number, y?: number, width?: number, height?: number)
    getWidth: function(): number
    getHeight: function(): number
    newFont: function(size: number): DebugFont
    rectangle: function(mode: string, x: number, y: number, width: number, height: number, rx?: number, ry?: number)
    line: function(x1: number, y1: number, x2: number, y2: number)
    circle: function(mode: string, x: number, y: number, radius: number)
    selectionMarker: function(x: number, y: number, radius: number): boolean
    drawBatches: function(view: DebugView)
    fitText: function(
        value: any,
        x: number,
        y: number,
        paddingX: number,
        paddingY: number,
        background: {number},
        radius?: number,
        originX?: number,
        originY?: number
    ): integer
    print: function(value: any, x: number, y: number)
    printf: function(value: any, x: number, y: number, limit: number, align?: string)
    draw: function(texture: love.graphics.Image, x: number, y: number, rotation?: number, sx?: number, sy?: number)
end

local band <const> = bit.band
local bor <const> = bit.bor
local lshift <const> = bit.lshift

local function decodeUtf8(text: string, i: integer): integer, integer
    local b1 = text:byte(i)
    if b1 < 0x80 then
        return b1, i + 1
    elseif b1 >= 0xC0 and b1 < 0xE0 then
        local b2 = text:byte(i + 1)
        if not b2 then return b1, i + 1 end
        return bor(lshift(band(b1, 0x1F), 6), band(b2, 0x3F)), i + 2
    elseif b1 < 0xF0 then
        local b2, b3 = text:byte(i + 1), text:byte(i + 2)
        if not b3 then return b1, i + 1 end
        return bor(lshift(band(b1, 0x0F), 12), lshift(band(b2, 0x3F), 6),
            band(b3, 0x3F)), i + 3
    elseif b1 < 0xF8 then
        local b2, b3, b4 = text:byte(i + 1), text:byte(i + 2), text:byte(i + 3)
        if not b4 then return b1, i + 1 end
        return bor(lshift(band(b1, 0x07), 18), lshift(band(b2, 0x3F), 12),
            lshift(band(b3, 0x3F), 6), band(b4, 0x3F)), i + 4
    end
    return b1, i + 1
end

local fontMetrics: bmfont.BMFont = nil
local fontMinXOffset = 0.0
local fontMinYOffset = 0.0

local function metrics(): bmfont.BMFont
    if not fontMetrics then
        fontMetrics = bmfont.parse(assert(love.filesystem.read(FONT_PATH)), FONT_PATH)
        for _, char in pairs(fontMetrics.chars) do
            if char.xoffset < fontMinXOffset then fontMinXOffset = char.xoffset end
            if char.yoffset < fontMinYOffset then fontMinYOffset = char.yoffset end
        end
    end
    return fontMetrics
end

local function fontAtSize(size: number): DebugFont
    local parsed = metrics()
    -- Match LÖVE's newFont(size) convention: size selects the face size,
    -- while getHeight() reports the scaled line height. Treating size as the
    -- line height made this font's 28px x-height only 8px tall at size 15.
    local scale = size / parsed.size
    return setmetatable({
        metrics = parsed,
        height = parsed.lineHeight * scale,
        scale = scale,
        drawOffsetX = -fontMinXOffset * scale,
        drawOffsetY = -fontMinYOffset * scale,
    }, {__index = DebugFont}) as DebugFont
end

function DebugFont:getHeight(): number return self.height end

function DebugFont:getWidth(text: string): number
    local cursor = 0.0
    local widest = 0.0
    local previous: integer = nil
    local i = 1
    while i <= #text do
        local codepoint: integer
        codepoint, i = decodeUtf8(text, i)
        if codepoint == 10 then
            if cursor > widest then widest = cursor end
            cursor = 0
            previous = nil
        elseif codepoint == 9 then
            local space = self.metrics:getChar(32)
            if space then cursor = cursor + space.xadvance * self.scale * 4 end
            previous = nil
        elseif codepoint >= 32 then
            local char = self.metrics:getChar(codepoint)
            if char then
                if previous then
                    cursor = cursor + self.metrics:getKerning(previous, codepoint) * self.scale
                end
                cursor = cursor + char.xadvance * self.scale
                previous = codepoint
            end
        end
    end
    if cursor > widest then widest = cursor end
    return widest
end

local function appendWrapped(font: DebugFont, paragraph: string, limit: number,
        lines: {string})
    if paragraph == "" then
        lines[#lines + 1] = ""
        return
    end
    local current = ""
    local lastSpace: integer = nil
    local i = 1
    while i <= #paragraph do
        local start = i
        local _codepoint: integer
        _codepoint, i = decodeUtf8(paragraph, i)
        local glyph = paragraph:sub(start, i - 1)
        local candidate = current .. glyph
        if current ~= "" and font:getWidth(candidate) > limit then
            if lastSpace then
                lines[#lines + 1] = current:sub(1, lastSpace - 1)
                current = current:sub(lastSpace + 1) .. glyph
                current = current:gsub("^ +", "")
            else
                lines[#lines + 1] = current
                current = glyph
            end
            lastSpace = current:match(".*() ")
        else
            current = candidate
            if glyph == " " then lastSpace = #current end
        end
    end
    lines[#lines + 1] = current
end

function DebugFont:getWrap(text: string, limit: number): number, {string}
    local lines: {string} = {}
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        appendWrapped(self, paragraph, limit, lines)
    end
    local widest = 0.0
    for i = 1, #lines do
        local width = self:getWidth(lines[i])
        if width > widest then widest = width end
    end
    return widest, lines
end

function debugdraw.newView(world: tecs.World): DebugView
    local defaultFont = fontAtSize(native.getFont():getHeight())
    return {
        world = world,
        entities = {},
        fitSlots = {},
        fitCount = 0,
        color = {1, 1, 1, 1},
        font = defaultFont,
        defaultFont = defaultFont,
        lineWidth = 1,
        clip = nil,
        z = 0,
        markers = MarkerBatch.new(),
    }
end

function debugdraw.beginFrame(view: DebugView)
    active = view
    for i = 1, #view.entities do
        local id = view.entities[i]
        if view.world:isAlive(id) then view.world:despawn(id) end
        view.entities[i] = nil
    end
    view.color[1], view.color[2], view.color[3], view.color[4] = 1, 1, 1, 1
    view.font = view.defaultFont
    view.lineWidth = 1
    view.clip = nil
    view.z = 0
    view.fitCount = 0
    view.markers:clear()
end

function debugdraw.endFrame()
    local v = active
    if v then
        -- FitContent panels are pooled instead of despawned every frame. Hide
        -- slots unused by this draw pass; reusing their stable entities keeps
        -- the GPU shadow registry from briefly interleaving retired panel
        -- rectangles with newly spawned text.
        for i = v.fitCount + 1, #v.fitSlots do
            local slot = v.fitSlots[i]
            if v.world:isAlive(slot.parent) then
                v.world:getMut(slot.parent, Transform).layer = 0
            end
        end
    end
    active = nil
end

local function view(): DebugView
    return assert(active, "debug draw used outside its frame")
end

local function spawn(parts: {tecs.Component}): integer
    local v = view()
    if v.clip then
        parts[#parts + 1] = gfx.ClipBounds(v.clip[1], v.clip[2], v.clip[3], v.clip[4])
    end
    parts[#parts + 1] = gfx.Unlit()
    local id = v.world:spawn(table.unpack(parts))
    v.entities[#v.entities + 1] = id
    return id
end

local function depth(): number
    local v = view()
    v.z = v.z + 1
    return v.z
end

local function color(): gfx.Color
    local c = view().color
    return gfx.Color(c[1], c[2], c[3], c[4])
end

local function tableColor(c: {number}): gfx.Color
    return gfx.Color(c[1], c[2], c[3], c[4] or 1)
end

local function setColorValue(dst: gfx.Color, src: {number})
    dst.r = src[1]
    dst.g = src[2]
    dst.b = src[3]
    dst.a = src[4] or 1
end

function debugdraw.push(_mode?: string) end
function debugdraw.pop() end
function debugdraw.origin() end

function debugdraw.setColor(r: number, g: number, b: number, a?: number)
    local c = view().color
    c[1], c[2], c[3], c[4] = r, g, b, a or 1
end

function debugdraw.setFont(font: DebugFont)
    view().font = font
end

function debugdraw.getFont(): DebugFont
    return view().font
end

function debugdraw.setLineWidth(width: number)
    view().lineWidth = width
end

function debugdraw.setScissor(x?: number, y?: number, width?: number, height?: number)
    local v = view()
    if x == nil then
        v.clip = nil
    else
        v.clip = {x, y as number, (x as number) + (width as number), (y as number) + (height as number)}
    end
end

function debugdraw.getWidth(): number return native.getWidth() end
function debugdraw.getHeight(): number return native.getHeight() end
function debugdraw.newFont(size: number): DebugFont
    return fontAtSize(size)
end

function debugdraw.rectangle(mode: string, x: number, y: number, width: number, height: number, rx?: number, ry?: number)
    local parts: {tecs.Component} = {
        Transform(x, y, depth(), 1),
        gfx.Rectangle(width, height, mode == "line" and view().lineWidth or 0),
        ui.LayoutBox(gfx.Rectangle),
        color(),
    }
    if rx and rx > 0 then parts[#parts + 1] = gfx.RoundedCorners(rx, ry) end
    spawn(parts)
end

function debugdraw.line(x1: number, y1: number, x2: number, y2: number)
    spawn({Transform(0, 0, depth(), 1), gfx.Line(x1, y1, x2, y2, view().lineWidth), color()})
end

function debugdraw.circle(mode: string, x: number, y: number, radius: number)
    spawn({Transform(x, y, depth(), 1), gfx.Circle(radius, mode == "line" and view().lineWidth or 0),
        ui.LayoutBox(gfx.Circle, nil, 0.5, 0.5), color()})
end

function debugdraw.selectionMarker(x: number, y: number, radius: number): boolean
    return view().markers:add(x, y, radius)
end

function debugdraw.drawBatches(v: DebugView)
    v.markers:draw()
end

--- Draw a text-backed panel whose render rectangle is sized by the UI system.
--- The caller still receives the measured font API for immediate positioning
--- and hit testing, but visual sizing has one source of truth: LayoutBox(Text).
function debugdraw.fitText(value: any, x: number, y: number, paddingX: number,
        paddingY: number, background: {number}, radius?: number,
        originX?: number, originY?: number): integer
    local v = view()
    local ox = originX or 0
    local oy = originY or 0
    local z = depth()
    local textValue = tostring(value)
    v.fitCount = v.fitCount + 1
    local slot = v.fitSlots[v.fitCount]
    if not slot then
        local parent = v.world:spawn(
            Transform(x, y, z, 1),
            gfx.Rectangle(0, 0),
            ui.LayoutBox(gfx.Rectangle, nil, ox, oy),
            ui.FitContent.new({
                paddingTop = paddingY,
                paddingRight = paddingX,
                paddingBottom = paddingY,
                paddingLeft = paddingX,
                adjust = gfx.Rectangle,
            }),
            tableColor(background),
            gfx.RoundedCorners(radius or 0),
            gfx.Unlit()
        )
        local child = v.world:spawn(
            Transform(0, 0, 0, 1),
            ChildOf(parent),
            RelativeTransform.new({
                x = paddingX * (1 - 2 * ox),
                y = paddingY * (1 - 2 * oy),
                z = 1,
            }),
            gfx.Text(FONT_PATH, textValue, v.font.scale, v.font.scale),
            ui.LayoutBox(gfx.Text, nil, ox, oy),
            color(),
            gfx.blend.ForwardAlphaBlend(),
            gfx.Unlit()
        )
        slot = {parent = parent, child = child}
        v.fitSlots[v.fitCount] = slot
        return parent
    end

    local parentTransform = v.world:getMut(slot.parent, Transform)
    parentTransform.x, parentTransform.y = x, y
    parentTransform.z, parentTransform.layer = z, 1
    parentTransform.rotation = 0
    parentTransform.scaleX, parentTransform.scaleY = 1, 1
    setColorValue(v.world:getMut(slot.parent, gfx.Color), background)
    local corners = v.world:getMut(slot.parent, gfx.RoundedCorners)
    corners.rx, corners.ry = radius or 0, radius or 0
    local fit = v.world:getMut(slot.parent, ui.FitContent)
    fit.padding = 0
    fit.paddingTop, fit.paddingRight = paddingY, paddingX
    fit.paddingBottom, fit.paddingLeft = paddingY, paddingX
    local parentBox = v.world:getMut(slot.parent, ui.LayoutBox)
    parentBox.inheritsOrigin = 0
    parentBox.originX, parentBox.originY = ox, oy

    local relative = v.world:getMut(slot.child, RelativeTransform)
    relative.x = paddingX * (1 - 2 * ox)
    relative.y = paddingY * (1 - 2 * oy)
    relative.z = 1
    relative.rotation = 0
    relative.scaleX, relative.scaleY = 1, 1
    setColorValue(v.world:getMut(slot.child, gfx.Color), v.color)
    local childBox = v.world:getMut(slot.child, ui.LayoutBox)
    childBox.inheritsOrigin = 0
    childBox.originX, childBox.originY = ox, oy
    local text = v.world:get(slot.child, gfx.Text)
    text:setText(textValue)
    text:setScale(v.font.scale, v.font.scale)
    return slot.parent
end


function debugdraw.print(value: any, x: number, y: number)
    local v = view()
    -- Measurement and rendering use the same parsed bitmap-font metrics.
    local scale = v.font.scale
    local parts: {tecs.Component} = {
        Transform(x + v.font.drawOffsetX, y + v.font.drawOffsetY, depth(), 1),
        gfx.Text(FONT_PATH, tostring(value), scale, scale),
        ui.LayoutBox(gfx.Text),
        color(),
        gfx.blend.ForwardAlphaBlend(),
    }
    spawn(parts)
end

function debugdraw.printf(value: any, x: number, y: number, limit: number, align?: string)
    local text = tostring(value)
    if align == "center" then
        x = x + (limit - view().font:getWidth(text)) * 0.5
    elseif align == "right" then
        x = x + limit - view().font:getWidth(text)
    end
    debugdraw.print(text, x, y)
end

function debugdraw.draw(texture: love.graphics.Image, x: number, y: number, rotation?: number, sx?: number, sy?: number)
    local sprite = gfx.Sprite.fromTexture(texture as love.graphics.Texture, {centered = false})
    spawn({
        Transform(x, y, depth(), 1, rotation or 0, sx or 1, sy or sx or 1),
        sprite,
        ui.LayoutBox(gfx.Sprite),
        color(),
    })
end

return debugdraw
