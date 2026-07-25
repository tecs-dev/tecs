--- Retained debugger UI backed by a dedicated render world.
---
--- UI systems open an explicit owner, address each element by a semantic key,
--- and close the owner after updating it. A key spawns one normal Tecs2D
--- entity, mutates that entity while it remains present, and despawns it when
--- the owner no longer emits the key. One-frame diagnostic geometry bypasses
--- ECS storage and goes through PrimitiveBatch instead.

local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")
local bmfont <const> = require("tecs2d.gfx.bmfont")
local ui <const> = require("tecs2d.ui")
local PrimitiveBatch <const> = require("tecs2d.debug.internal.PrimitiveBatch")
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

local record DrawState
    id: integer
    parent: integer
    x: number
    y: number
    z: number
    rotation: number
    scaleX: number
    scaleY: number
    layer: integer
    r: number
    g: number
    b: number
    a: number
    clipMinX: number
    clipMinY: number
    clipMaxX: number
    clipMaxY: number
end

local record Element
    kind: string
    state: DrawState
    child: integer
    childState: DrawState
    width: number
    height: number
    lineWidth: number
    radiusX: number
    radiusY: number
    x1: number
    y1: number
    x2: number
    y2: number
    radius: number
    text: string
    scale: number
    paddingX: number
    paddingY: number
    originX: number
    originY: number
    texture: love.graphics.Image
    scrollX: number
    scrollY: number
    contentWidth: number
    contentHeight: number
    anchorX: number
    anchorY: number
end

local record Owner
    elements: {string: Element}
    seen: {string: boolean}
end

local record DebugView
    world: tecs.World
    owners: {string: Owner}
    owner: Owner
    ownerName: string
    color: {number}
    font: DebugFont
    defaultFont: DebugFont
    lineWidth: number
    clip: {number}
    z: number
    primitives: PrimitiveBatch
    parents: {integer}
    -- Compatibility name for diagnostics that report selection marker count.
    markers: PrimitiveBatch
end

local active: DebugView = nil
local screenScale = 1.0

local record debugdraw
    type View = DebugView
    type Font = DebugFont
    beginFrame: function(view: DebugView)
    endFrame: function()
    newView: function(world: tecs.World): DebugView
    beginOwner: function(name: string)
    endOwner: function()
    releaseOwner: function(name: string)
    hasRetainedDraws: function(view: DebugView): boolean
    setColor: function(r: number, g: number, b: number, a?: number)
    setFont: function(font: DebugFont)
    getFont: function(): DebugFont
    setLineWidth: function(width: number)
    setScissor: function(x?: number, y?: number, width?: number, height?: number)
    setScreenScale: function(scale: number)
    getScreenScale: function(): number
    getWidth: function(): number
    getHeight: function(): number
    newFont: function(size: number): DebugFont
    beginLayout: function(key: string, x: number, y: number,
        width: number, height: number, scrollX?: number, scrollY?: number,
        contentWidth?: number, contentHeight?: number,
        anchorX?: number, anchorY?: number)
    endLayout: function()
    rectangle: function(key: string, mode: string, x: number, y: number,
        width: number, height: number, rx?: number, ry?: number)
    alphaRectangle: function(key: string, mode: string, x: number, y: number,
        width: number, height: number, rx?: number, ry?: number)
    line: function(key: string, x1: number, y1: number, x2: number, y2: number)
    circle: function(key: string, mode: string, x: number, y: number, radius: number)
    batchRectangle: function(mode: string, x: number, y: number,
        width: number, height: number): boolean
    batchLine: function(x1: number, y1: number, x2: number, y2: number): boolean
    batchCircle: function(mode: string, x: number, y: number, radius: number): boolean
    selectionMarker: function(x: number, y: number, radius: number): boolean
    drawBatches: function(view: DebugView)
    fitText: function(
        key: string,
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
    print: function(key: string, value: any, x: number, y: number)
    printf: function(key: string, value: any, x: number, y: number,
        limit: number, align?: string)
    draw: function(key: string, texture: love.graphics.Image, x: number,
        y: number, rotation?: number, sx?: number, sy?: number)
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
    -- Match Love's newFont(size) convention: size selects the face size,
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
            if space then
                cursor = cursor
                    + (space as bmfont.BMFontChar).xadvance * self.scale * 4
            end
            previous = nil
        elseif codepoint >= 32 then
            local char = self.metrics:getChar(codepoint)
            if char then
                local glyph = char as bmfont.BMFontChar
                if previous then
                    cursor = cursor + self.metrics:getKerning(previous, codepoint) * self.scale
                end
                cursor = cursor + glyph.xadvance * self.scale
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

local NO_CLIP_MIN <const> = -3.4e38
local NO_CLIP_MAX <const> = 3.4e38

local function clipValues(v: DebugView): number, number, number, number
    local clip = v.clip
    if clip then return clip[1], clip[2], clip[3], clip[4] end
    return NO_CLIP_MIN, NO_CLIP_MIN, NO_CLIP_MAX, NO_CLIP_MAX
end

local function newState(v: DebugView, id: integer, x: number, y: number,
        z: number, rotation?: number, scaleX?: number, scaleY?: number,
        parent?: integer): DrawState
    local c = v.color
    local minX, minY, maxX, maxY = clipValues(v)
    return {
        id = id,
        parent = parent,
        x = x,
        y = y,
        z = z,
        rotation = rotation or 0,
        scaleX = scaleX or 1,
        scaleY = scaleY or scaleX or 1,
        layer = 1,
        r = c[1],
        g = c[2],
        b = c[3],
        a = c[4],
        clipMinX = minX,
        clipMinY = minY,
        clipMaxX = maxX,
        clipMaxY = maxY,
    }
end

local function destroyElement(v: DebugView, element: Element)
    if element.child and v.world:isAlive(element.child) then
        v.world:despawn(element.child)
    end
    if element.state and v.world:isAlive(element.state.id) then
        v.world:despawn(element.state.id)
    end
end

function debugdraw.newView(world: tecs.World): DebugView
    local defaultFont = fontAtSize(native.getFont():getHeight())
    local primitives = PrimitiveBatch.new()
    return {
        world = world,
        owners = {},
        owner = nil,
        ownerName = nil,
        color = {1, 1, 1, 1},
        font = defaultFont,
        defaultFont = defaultFont,
        lineWidth = 1,
        clip = nil,
        z = 0,
        primitives = primitives,
        markers = primitives,
        parents = {},
    }
end

function debugdraw.beginFrame(view: DebugView)
    active = view
    view.owner = nil
    view.ownerName = nil
    view.color[1], view.color[2], view.color[3], view.color[4] = 1, 1, 1, 1
    view.font = view.defaultFont
    view.lineWidth = 1
    view.clip = nil
    view.z = 0
    view.primitives:clear()
    for i = #view.parents, 1, -1 do view.parents[i] = nil end
end

function debugdraw.endFrame()
    local v = active
    assert(not v or not v.owner, "debug draw owner left open")
    assert(not v or #v.parents == 0, "debug layout container left open")
    active = nil
end

local function view(): DebugView
    return assert(active, "debug draw used outside its frame")
end

function debugdraw.beginOwner(name: string)
    local v = view()
    assert(not v.owner, "debug draw owners cannot be nested")
    local owner = v.owners[name]
    if not owner then
        owner = {elements = {}, seen = {}}
        v.owners[name] = owner
    end
    for key in pairs(owner.seen) do owner.seen[key] = nil end
    v.owner = owner
    v.ownerName = name
end

function debugdraw.endOwner()
    local v = view()
    local owner = assert(v.owner, "no debug draw owner is open")
    for key, element in pairs(owner.elements) do
        if not owner.seen[key] then
            destroyElement(v, element)
            owner.elements[key] = nil
        end
    end
    v.owner = nil
    v.ownerName = nil
end

function debugdraw.releaseOwner(name: string)
    local v = view()
    assert(v.ownerName ~= name, "cannot release the open debug draw owner")
    local owner = v.owners[name]
    if not owner then return end
    for _, element in pairs(owner.elements) do destroyElement(v, element) end
    v.owners[name] = nil
end

function debugdraw.hasRetainedDraws(v: DebugView): boolean
    for _, owner in pairs(v.owners) do
        if next(owner.elements) ~= nil then return true end
    end
    return false
end

local function element(key: string, kind: string): Element
    local v = view()
    local owner = assert(v.owner, "retained draw used without beginOwner")
    assert(not owner.seen[key], "duplicate debug UI key '" .. key .. "'")
    owner.seen[key] = true
    local found = owner.elements[key]
    if found and found.kind ~= kind then
        destroyElement(v, found)
        owner.elements[key] = nil
        found = nil
    end
    return found
end

local function putElement(key: string, value: Element)
    local owner = assert(view().owner, "retained draw used without beginOwner")
    owner.elements[key] = value
end

local function depth(): number
    local v = view()
    v.z = v.z + 1
    return v.z
end

local function currentParent(v: DebugView): integer
    return v.parents[#v.parents]
end

local function transformParts(v: DebugView, x: number, y: number, z: number,
        rotation?: number, scaleX?: number, scaleY?: number): {tecs.Component}, integer
    local parent = currentParent(v)
    local rot = rotation or 0
    local sx = scaleX or 1
    local sy = scaleY or scaleX or 1
    if parent then
        return {
            Transform(0, 0, 0, 1),
            ChildOf(parent),
            RelativeTransform(x, y, z, rot, sx, sy),
        }, parent
    end
    return {Transform(x, y, z, 1, rot, sx, sy)}, nil
end

local function resetForParent(v: DebugView, key: string, slot: Element,
        parent: integer): Element
    if slot and slot.state.parent ~= parent then
        destroyElement(v, slot)
        assert(v.owner).elements[key] = nil
        return nil
    end
    return slot
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

local function updateTransform(v: DebugView, state: DrawState, x: number, y: number,
        z: number, rotation?: number, scaleX?: number, scaleY?: number)
    local rot = rotation or 0
    local sx = scaleX or 1
    local sy = scaleY or scaleX or 1
    if state.x ~= x or state.y ~= y or state.z ~= z or state.rotation ~= rot
            or state.scaleX ~= sx or state.scaleY ~= sy or state.layer ~= 1 then
        if state.parent then
            local relative = v.world:getMut(state.id, RelativeTransform)
            relative.x, relative.y, relative.z = x, y, z
            relative.rotation = rot
            relative.scaleX, relative.scaleY = sx, sy
        else
            local transform = v.world:getMut(state.id, Transform)
            transform.x, transform.y, transform.z = x, y, z
            transform.rotation = rot
            transform.scaleX, transform.scaleY = sx, sy
            transform.layer = 1
        end
        state.x, state.y, state.z = x, y, z
        state.rotation, state.scaleX, state.scaleY = rot, sx, sy
        state.layer = 1
    end
end

local function updateColor(v: DebugView, state: DrawState, c: {number})
    local a = c[4] or 1
    if state.r ~= c[1] or state.g ~= c[2] or state.b ~= c[3] or state.a ~= a then
        setColorValue(v.world:getMut(state.id, gfx.Color), c)
        state.r, state.g, state.b, state.a = c[1], c[2], c[3], a
    end
end

local function updateClip(v: DebugView, state: DrawState)
    local minX, minY, maxX, maxY = clipValues(v)
    if state.clipMinX ~= minX or state.clipMinY ~= minY
            or state.clipMaxX ~= maxX or state.clipMaxY ~= maxY then
        local clip = v.world:getMut(state.id, gfx.ClipBounds)
        clip.minX, clip.minY = minX, minY
        clip.maxX, clip.maxY = maxX, maxY
        state.clipMinX, state.clipMinY = minX, minY
        state.clipMaxX, state.clipMaxY = maxX, maxY
    end
end

local function updateState(v: DebugView, state: DrawState, x: number, y: number,
        z: number, rotation?: number, scaleX?: number, scaleY?: number)
    updateTransform(v, state, x, y, z, rotation, scaleX, scaleY)
    updateColor(v, state, v.color)
    updateClip(v, state)
end

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
        local scale = screenScale
        v.clip = {
            x * scale,
            (y as number) * scale,
            ((x as number) + (width as number)) * scale,
            ((y as number) + (height as number)) * scale,
        }
    end
end

function debugdraw.setScreenScale(scale: number)
    screenScale = math.max(0.01, scale)
end

function debugdraw.getScreenScale(): number return screenScale end
function debugdraw.getWidth(): number return native.getWidth() / screenScale end
function debugdraw.getHeight(): number return native.getHeight() / screenScale end
function debugdraw.newFont(size: number): DebugFont
    return fontAtSize(size)
end

--- Open a retained UI container. Draw calls made before endLayout use local
--- coordinates and become children of this entity. Viewport owns descendant
--- clipping and scroll translation; optional anchors position root containers
--- relative to the screen viewport.
function debugdraw.beginLayout(key: string, x: number, y: number,
        width: number, height: number, scrollX?: number, scrollY?: number,
        contentWidth?: number, contentHeight?: number,
        anchorX?: number, anchorY?: number)
    local v = view()
    local scale = screenScale
    x, y = x * scale, y * scale
    width, height = width * scale, height * scale
    local sx = (scrollX or 0) * scale
    local sy = (scrollY or 0) * scale
    local cw = (contentWidth or width / scale) * scale
    local ch = (contentHeight or height / scale) * scale
    local anchored = anchorX ~= nil or anchorY ~= nil
    assert(not anchored or not currentParent(v),
        "only root debugger layouts may use viewport anchors")
    local kind = anchored and "anchoredLayout" or "layout"
    -- Layout containers do not render. Keeping their authored depth at zero
    -- prevents hierarchy composition from adding the container's draw order
    -- to every descendant and lifting early children over later siblings.
    local z = 0
    local parent = currentParent(v)
    local slot = resetForParent(v, key, element(key, kind), parent)
    if not slot then
        local parts: {tecs.Component}
        if anchored then
            parts = {
                Transform(0, 0, z, 1),
                ui.Anchor(anchorX or 0, anchorY or 0, x, y),
            }
        else
            parts, parent = transformParts(v, x, y, z)
        end
        parts[#parts + 1] = ui.LayoutBox(width, height)
        parts[#parts + 1] = ui.Viewport(sx, sy, cw, ch)
        local id = v.world:spawn(table.unpack(parts))
        slot = {
            kind = kind,
            state = newState(v, id, x, y, z, nil, nil, nil, parent),
            width = width,
            height = height,
            scrollX = sx,
            scrollY = sy,
            contentWidth = cw,
            contentHeight = ch,
            anchorX = anchorX,
            anchorY = anchorY,
        }
        putElement(key, slot)
    else
        if anchored then
            if slot.anchorX ~= anchorX or slot.anchorY ~= anchorY
                    or slot.state.x ~= x or slot.state.y ~= y then
                local anchor = v.world:getMut(slot.state.id, ui.Anchor)
                anchor.anchorX, anchor.anchorY = anchorX or 0, anchorY or 0
                anchor.offsetX, anchor.offsetY = x, y
                slot.anchorX, slot.anchorY = anchorX, anchorY
                slot.state.x, slot.state.y = x, y
            end
            if slot.state.z ~= z then
                v.world:getMut(slot.state.id, Transform).z = z
                slot.state.z = z
            end
        else
            updateTransform(v, slot.state, x, y, z)
        end
        if slot.width ~= width or slot.height ~= height then
            local box = v.world:getMut(slot.state.id, ui.LayoutBox)
            box.width, box.height = width, height
            slot.width, slot.height = width, height
        end
        if slot.scrollX ~= sx or slot.scrollY ~= sy
                or slot.contentWidth ~= cw or slot.contentHeight ~= ch then
            local node = v.world:getMut(slot.state.id, ui.Viewport)
            node.scrollX, node.scrollY = sx, sy
            node.contentWidth, node.contentHeight = cw, ch
            slot.scrollX, slot.scrollY = sx, sy
            slot.contentWidth, slot.contentHeight = cw, ch
        end
    end
    v.parents[#v.parents + 1] = slot.state.id
end

function debugdraw.endLayout()
    local parents = view().parents
    assert(#parents > 0, "no debugger layout container is open")
    parents[#parents] = nil
end

local function drawRectangle(key: string, mode: string, x: number, y: number,
        width: number, height: number, rx: number, ry: number,
        alphaBlend: boolean)
    local v = view()
    local scale = screenScale
    x, y, width, height = x * scale, y * scale, width * scale, height * scale
    local z = depth()
    local lineWidth = mode == "line" and v.lineWidth * scale or 0
    local radiusX = (rx or 0) * scale
    local radiusY = (ry or rx or 0) * scale
    local kind = alphaBlend and "alphaRectangle" or "rectangle"
    local parent = currentParent(v)
    local slot = resetForParent(v, key, element(key, kind), parent)
    if not slot then
        local minX, minY, maxX, maxY = clipValues(v)
        local parts: {tecs.Component}
        parts, parent = transformParts(v, x, y, z)
        parts[#parts + 1] = gfx.Rectangle(width, height, lineWidth)
        parts[#parts + 1] = ui.LayoutBox(gfx.Rectangle)
        parts[#parts + 1] = color()
        parts[#parts + 1] = gfx.RoundedCorners(radiusX, radiusY)
        parts[#parts + 1] = gfx.ClipBounds(minX, minY, maxX, maxY)
        parts[#parts + 1] = gfx.Unlit()
        if alphaBlend then
            parts[#parts + 1] = gfx.blend.ForwardAlphaBlend()
        end
        local id = v.world:spawn(table.unpack(parts))
        slot = {
            kind = kind,
            state = newState(v, id, x, y, z, nil, nil, nil, parent),
            width = width,
            height = height,
            lineWidth = lineWidth,
            radiusX = radiusX,
            radiusY = radiusY,
        }
        putElement(key, slot)
        return
    end
    updateState(v, slot.state, x, y, z)
    if slot.width ~= width or slot.height ~= height or slot.lineWidth ~= lineWidth then
        local rectangle = v.world:getMut(slot.state.id, gfx.Rectangle)
        rectangle.width, rectangle.height = width, height
        rectangle.lineWidth = lineWidth
        slot.width, slot.height, slot.lineWidth = width, height, lineWidth
    end
    if slot.radiusX ~= radiusX or slot.radiusY ~= radiusY then
        local corners = v.world:getMut(slot.state.id, gfx.RoundedCorners)
        corners.rx, corners.ry = radiusX, radiusY
        slot.radiusX, slot.radiusY = radiusX, radiusY
    end
end

function debugdraw.rectangle(key: string, mode: string, x: number, y: number,
        width: number, height: number, rx?: number, ry?: number)
    drawRectangle(key, mode, x, y, width, height, rx or 0, ry or rx or 0, false)
end

function debugdraw.alphaRectangle(key: string, mode: string, x: number, y: number,
        width: number, height: number, rx?: number, ry?: number)
    drawRectangle(key, mode, x, y, width, height, rx or 0, ry or rx or 0, true)
end

function debugdraw.line(key: string, x1: number, y1: number,
        x2: number, y2: number)
    local v = view()
    local scale = screenScale
    x1, y1, x2, y2 = x1 * scale, y1 * scale, x2 * scale, y2 * scale
    local z = depth()
    local width = v.lineWidth * scale
    local parent = currentParent(v)
    local slot = resetForParent(v, key, element(key, "line"), parent)
    if not slot then
        local minX, minY, maxX, maxY = clipValues(v)
        local parts: {tecs.Component}
        parts, parent = transformParts(v, 0, 0, z)
        parts[#parts + 1] = gfx.Line(x1, y1, x2, y2, width)
        parts[#parts + 1] = color()
        parts[#parts + 1] = gfx.ClipBounds(minX, minY, maxX, maxY)
        parts[#parts + 1] = gfx.Unlit()
        local id = v.world:spawn(table.unpack(parts))
        slot = {kind = "line", state = newState(v, id, 0, 0, z,
                nil, nil, nil, parent),
            x1 = x1, y1 = y1, x2 = x2, y2 = y2, width = width}
        putElement(key, slot)
        return
    end
    updateState(v, slot.state, 0, 0, z)
    if slot.x1 ~= x1 or slot.y1 ~= y1 or slot.x2 ~= x2 or slot.y2 ~= y2
            or slot.width ~= width then
        local line = v.world:getMut(slot.state.id, gfx.Line)
        line.x1, line.y1, line.x2, line.y2 = x1, y1, x2, y2
        line.width = width
        slot.x1, slot.y1, slot.x2, slot.y2 = x1, y1, x2, y2
        slot.width = width
    end
end

function debugdraw.circle(key: string, mode: string, x: number, y: number,
        radius: number)
    local v = view()
    local scale = screenScale
    x, y, radius = x * scale, y * scale, radius * scale
    local z = depth()
    local lineWidth = mode == "line" and v.lineWidth * scale or 0
    local parent = currentParent(v)
    local slot = resetForParent(v, key, element(key, "circle"), parent)
    if not slot then
        local minX, minY, maxX, maxY = clipValues(v)
        local parts: {tecs.Component}
        parts, parent = transformParts(v, x, y, z)
        parts[#parts + 1] = gfx.Circle(radius, lineWidth)
        parts[#parts + 1] = ui.LayoutBox(gfx.Circle, nil, 0.5, 0.5)
        parts[#parts + 1] = color()
        parts[#parts + 1] = gfx.ClipBounds(minX, minY, maxX, maxY)
        parts[#parts + 1] = gfx.Unlit()
        local id = v.world:spawn(table.unpack(parts))
        slot = {kind = "circle", state = newState(v, id, x, y, z,
                nil, nil, nil, parent),
            radius = radius, lineWidth = lineWidth}
        putElement(key, slot)
        return
    end
    updateState(v, slot.state, x, y, z)
    if slot.radius ~= radius or slot.lineWidth ~= lineWidth then
        local circle = v.world:getMut(slot.state.id, gfx.Circle)
        circle.radius, circle.lineWidth = radius, lineWidth
        slot.radius, slot.lineWidth = radius, lineWidth
    end
end

function debugdraw.selectionMarker(x: number, y: number, radius: number): boolean
    return view().primitives:selection(x, y, radius * screenScale)
end

function debugdraw.drawBatches(v: DebugView)
    v.primitives:draw()
end

function debugdraw.batchRectangle(mode: string, x: number, y: number,
        width: number, height: number): boolean
    local v = view()
    local c = v.color
    return v.primitives:rectangle(mode, x, y, width, height,
        v.lineWidth * screenScale,
        c[1], c[2], c[3], c[4])
end

function debugdraw.batchLine(x1: number, y1: number,
        x2: number, y2: number): boolean
    local v = view()
    local c = v.color
    return v.primitives:line(x1, y1, x2, y2, v.lineWidth * screenScale,
        c[1], c[2], c[3], c[4])
end

function debugdraw.batchCircle(mode: string, x: number, y: number,
        radius: number): boolean
    local v = view()
    local c = v.color
    return v.primitives:circle(mode, x, y, radius, v.lineWidth * screenScale,
        c[1], c[2], c[3], c[4])
end

--- Draw a text-backed panel whose render rectangle is sized by the UI system.
--- The caller still receives the measured font API for immediate positioning
--- and hit testing, but visual sizing has one source of truth: LayoutBox(Text).
function debugdraw.fitText(key: string, value: any, x: number, y: number, paddingX: number,
        paddingY: number, background: {number}, radius?: number,
        originX?: number, originY?: number): integer
    local v = view()
    local screen = screenScale
    x, y = x * screen, y * screen
    paddingX, paddingY = paddingX * screen, paddingY * screen
    local ox = originX or 0
    local oy = originY or 0
    local z = depth()
    local textValue = tostring(value)
    local scale = v.font.scale * screen
    local cornerRadius = (radius or 0) * screen
    local relativeX = paddingX * (1 - 2 * ox)
    local relativeY = paddingY * (1 - 2 * oy)
    local minX, minY, maxX, maxY = clipValues(v)
    local layoutParent = currentParent(v)
    local slot = resetForParent(v, key, element(key, "fitText"), layoutParent)
    if not slot then
        local parts: {tecs.Component}
        parts, layoutParent = transformParts(v, x, y, z)
        parts[#parts + 1] = gfx.Rectangle(0, 0)
        parts[#parts + 1] = ui.LayoutBox(gfx.Rectangle, nil, ox, oy)
        parts[#parts + 1] = ui.FitContent.new({
            paddingTop = paddingY,
            paddingRight = paddingX,
            paddingBottom = paddingY,
            paddingLeft = paddingX,
            adjust = gfx.Rectangle,
        })
        parts[#parts + 1] = tableColor(background)
        parts[#parts + 1] = gfx.RoundedCorners(cornerRadius)
        parts[#parts + 1] = gfx.ClipBounds(minX, minY, maxX, maxY)
        parts[#parts + 1] = gfx.Unlit()
        local parent = v.world:spawn(table.unpack(parts))
        local child = v.world:spawn(
            Transform(0, 0, 0, 1),
            ChildOf(parent),
            RelativeTransform.new({
                x = relativeX,
                y = relativeY,
                z = 1,
            }),
            gfx.Text(FONT_PATH, textValue, scale, scale),
            ui.LayoutBox(gfx.Text, nil, ox, oy),
            color(),
            gfx.ClipBounds(minX, minY, maxX, maxY),
            gfx.blend.ForwardAlphaBlend(),
            gfx.Unlit()
        )
        local parentState = newState(v, parent, x, y, z,
            nil, nil, nil, layoutParent)
        parentState.r, parentState.g, parentState.b = background[1], background[2], background[3]
        parentState.a = background[4] or 1
        slot = {
            kind = "fitText",
            state = parentState,
            child = child,
            childState = newState(v, child, 0, 0, 0),
            text = textValue,
            scale = scale,
            paddingX = paddingX,
            paddingY = paddingY,
            radius = cornerRadius,
            originX = ox,
            originY = oy,
        }
        putElement(key, slot)
        return parent
    end

    updateTransform(v, slot.state, x, y, z)
    updateColor(v, slot.state, background)
    updateClip(v, slot.state)
    updateColor(v, slot.childState, v.color)
    updateClip(v, slot.childState)
    if slot.radius ~= cornerRadius then
        local corners = v.world:getMut(slot.state.id, gfx.RoundedCorners)
        corners.rx, corners.ry = cornerRadius, cornerRadius
        slot.radius = cornerRadius
    end
    if slot.paddingX ~= paddingX or slot.paddingY ~= paddingY then
        local fit = v.world:getMut(slot.state.id, ui.FitContent)
        fit.padding = 0
        fit.paddingTop, fit.paddingRight = paddingY, paddingX
        fit.paddingBottom, fit.paddingLeft = paddingY, paddingX
        local relative = v.world:getMut(slot.child, RelativeTransform)
        relative.x, relative.y = relativeX, relativeY
        slot.paddingX, slot.paddingY = paddingX, paddingY
    end
    if slot.originX ~= ox or slot.originY ~= oy then
        local parentBox = v.world:getMut(slot.state.id, ui.LayoutBox)
        parentBox.inheritsOrigin = 0
        parentBox.originX, parentBox.originY = ox, oy
        local childBox = v.world:getMut(slot.child, ui.LayoutBox)
        childBox.inheritsOrigin = 0
        childBox.originX, childBox.originY = ox, oy
        -- Origin also changes the child's padding direction.
        local relative = v.world:getMut(slot.child, RelativeTransform)
        relative.x, relative.y = relativeX, relativeY
        slot.originX, slot.originY = ox, oy
    end
    if slot.text ~= textValue or slot.scale ~= scale then
        local text = v.world:get(slot.child, gfx.Text)
        if slot.text ~= textValue then text:setText(textValue) end
        if slot.scale ~= scale then text:setScale(scale, scale) end
        slot.text, slot.scale = textValue, scale
    end
    return slot.state.id
end


function debugdraw.print(key: string, value: any, x: number, y: number)
    local v = view()
    -- Measurement and rendering use the same parsed bitmap-font metrics.
    local screen = screenScale
    local scale = v.font.scale * screen
    local textValue = tostring(value)
    local drawX = (x + v.font.drawOffsetX) * screen
    local drawY = (y + v.font.drawOffsetY) * screen
    local z = depth()
    local parent = currentParent(v)
    local slot = resetForParent(v, key, element(key, "text"), parent)
    if not slot then
        local minX, minY, maxX, maxY = clipValues(v)
        local parts: {tecs.Component}
        parts, parent = transformParts(v, drawX, drawY, z)
        parts[#parts + 1] = gfx.Text(FONT_PATH, textValue, scale, scale)
        parts[#parts + 1] = ui.LayoutBox(gfx.Text)
        parts[#parts + 1] = color()
        parts[#parts + 1] = gfx.ClipBounds(minX, minY, maxX, maxY)
        parts[#parts + 1] = gfx.blend.ForwardAlphaBlend()
        parts[#parts + 1] = gfx.Unlit()
        local id = v.world:spawn(table.unpack(parts))
        slot = {kind = "text", state = newState(v, id, drawX, drawY, z,
                nil, nil, nil, parent),
            text = textValue, scale = scale}
        putElement(key, slot)
        return
    end
    updateState(v, slot.state, drawX, drawY, z)
    if slot.text ~= textValue or slot.scale ~= scale then
        local text = v.world:get(slot.state.id, gfx.Text)
        if slot.text ~= textValue then text:setText(textValue) end
        if slot.scale ~= scale then text:setScale(scale, scale) end
        slot.text, slot.scale = textValue, scale
    end
end

function debugdraw.printf(key: string, value: any, x: number, y: number,
        limit: number, align?: string)
    local text = tostring(value)
    if align == "center" then
        x = x + (limit - view().font:getWidth(text)) * 0.5
    elseif align == "right" then
        x = x + limit - view().font:getWidth(text)
    end
    debugdraw.print(key, text, x, y)
end

function debugdraw.draw(key: string, texture: love.graphics.Image, x: number,
        y: number, rotation?: number, sx?: number, sy?: number)
    local v = view()
    local screen = screenScale
    x, y = x * screen, y * screen
    local z = depth()
    local scaleX = (sx or 1) * screen
    local scaleY = (sy or sx or 1) * screen
    local parent = currentParent(v)
    local slot = resetForParent(v, key, element(key, "sprite"), parent)
    if not slot then
        local minX, minY, maxX, maxY = clipValues(v)
        local sprite = gfx.Sprite.fromTexture(texture as love.graphics.Texture,
            {centered = false})
        local parts: {tecs.Component}
        parts, parent = transformParts(v, x, y, z, rotation, scaleX, scaleY)
        parts[#parts + 1] = sprite
        parts[#parts + 1] = ui.LayoutBox(gfx.Sprite)
        parts[#parts + 1] = color()
        parts[#parts + 1] = gfx.ClipBounds(minX, minY, maxX, maxY)
        parts[#parts + 1] = gfx.Unlit()
        local id = v.world:spawn(table.unpack(parts))
        slot = {kind = "sprite",
            state = newState(v, id, x, y, z, rotation, scaleX, scaleY, parent),
            texture = texture}
        putElement(key, slot)
        return
    end
    if slot.texture ~= texture then
        v.world:set(slot.state.id,
            gfx.Sprite.fromTexture(texture as love.graphics.Texture, {centered = false}))
        slot.texture = texture
    end
    updateState(v, slot.state, x, y, z, rotation, scaleX, scaleY)
end

return debugdraw
