--- Immediate debug drawing facade backed by a dedicated render world.
---
--- The debugger intentionally keeps its existing immediate layout code, but
--- every draw call below becomes a normal Tecs2D drawable entity. The facade
--- is active only while the debug world's RenderLast systems build a frame.

local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")
local ui <const> = require("tecs2d.ui")

local Transform <const> = tecs.builtins.Transform
local native <const> = love.graphics
local FONT_PATH <const> = "tecs2d/assets/fonts/tiny-font.fnt"

local record DebugView
    world: tecs.World
    entities: {integer}
    color: {number}
    font: love.graphics.Font
    lineWidth: number
    clip: {number}
    z: number
end

local active: DebugView = nil

local record debugdraw
    type View = DebugView
    beginFrame: function(view: DebugView)
    endFrame: function()
    newView: function(world: tecs.World): DebugView
    push: function(mode?: string)
    pop: function()
    origin: function()
    setColor: function(r: number, g: number, b: number, a?: number)
    setFont: function(font: love.graphics.Font)
    getFont: function(): love.graphics.Font
    setLineWidth: function(width: number)
    setScissor: function(x?: number, y?: number, width?: number, height?: number)
    getWidth: function(): number
    getHeight: function(): number
    newFont: function(size: number): love.graphics.Font
    rectangle: function(mode: string, x: number, y: number, width: number, height: number, rx?: number, ry?: number)
    line: function(x1: number, y1: number, x2: number, y2: number)
    circle: function(mode: string, x: number, y: number, radius: number)
    print: function(value: any, x: number, y: number)
    printf: function(value: any, x: number, y: number, limit: number, align?: string)
    draw: function(texture: love.graphics.Image, x: number, y: number, rotation?: number, sx?: number, sy?: number)
end

function debugdraw.newView(world: tecs.World): DebugView
    return {
        world = world,
        entities = {},
        color = {1, 1, 1, 1},
        font = native.getFont(),
        lineWidth = 1,
        clip = nil,
        z = 0,
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
    view.font = native.getFont()
    view.lineWidth = 1
    view.clip = nil
    view.z = 0
end

function debugdraw.endFrame()
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
    v.z = v.z + 0.0001
    return v.z
end

local function color(): gfx.Color
    local c = view().color
    return gfx.Color(c[1], c[2], c[3], c[4])
end

function debugdraw.push(_mode?: string) end
function debugdraw.pop() end
function debugdraw.origin() end

function debugdraw.setColor(r: number, g: number, b: number, a?: number)
    local c = view().color
    c[1], c[2], c[3], c[4] = r, g, b, a or 1
end

function debugdraw.setFont(font: love.graphics.Font)
    view().font = font
end

function debugdraw.getFont(): love.graphics.Font
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
function debugdraw.newFont(size: number): love.graphics.Font return native.newFont(size) end

function debugdraw.rectangle(mode: string, x: number, y: number, width: number, height: number, rx?: number, ry?: number)
    local parts: {tecs.Component} = {
        Transform(x + width * 0.5, y + height * 0.5, depth(), 1),
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
        ui.LayoutBox(gfx.Circle), color()})
end


function debugdraw.print(value: any, x: number, y: number)
    local v = view()
    -- The bundled bitmap font is 8px high. Love fonts remain the measurement
    -- source so the debugger's established layout and hit targets do not move.
    local scale = v.font:getHeight() / 8
    spawn({
        Transform(x, y, depth(), 1),
        gfx.Text(FONT_PATH, tostring(value), scale, scale),
        ui.LayoutBox(gfx.Text, nil, 0, 0),
        gfx.Pivot(0, 0),
        color(),
    })
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
        ui.LayoutBox(gfx.Sprite, nil, 0, 0),
        gfx.Pivot(0, 0),
        color(),
    })
end

return debugdraw
