--- Private, engine-owned transient debugger visuals.
---
--- Grid lines, component bounds, and entity id backdrops have no persistent
--- identity and are rebuilt into one mesh each frame. They are not an MCP
--- drawing API; tools that need durable visuals spawn ordinary entities in
--- the debugger world.

local tecs <const> = require("tecs")
local gfxtypes <const> = require("tecs2d.gfx.types")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local PrimitiveBatch <const> = require("tecs2d.debug.internal.PrimitiveBatch")

local Transform <const> = tecs.builtins.Transform
local lg <const> = love.graphics

local MAX_ID_LABELS <const> = 200
local MAX_BOUNDS <const> = 200
local MAX_GRID_LINES <const> = 200

local SIZE_SHAPES <const>: {{string}} = {
    {"RepeatedSprite", "wh"},
    {"SpriteData", "wh"},
    {"Rectangle", "wh"},
    {"Circle", "r"},
    {"Ellipse", "rr"},
}

local record Label
    text: string
    x: number
    y: number
end

local record visuals
    install: function(w: tecs.World, ctx: debugcontext.Context)
end

function visuals.install(w: tecs.World, ctx: debugcontext.Context)
    local query = w:query({name = "debug.Visuals", include = {Transform}})
    local batch = PrimitiveBatch.new()
    local labels: {Label} = {}
    local font: love.graphics.Font = nil
    local sizeComps: {string: tecs.Component} = {}

    local function labelFont(): love.graphics.Font
        if not font then font = lg.newFont(12) end
        return font
    end

    local function sizeComp(name: string): tecs.Component
        local comp = sizeComps[name]
        if not comp then
            local ok, resolved = pcall(tecs.componentByName, name)
            comp = ok and resolved or nil
            if comp then sizeComps[name] = comp end
        end
        return comp
    end

    local function sizeColumn(archetype: tecs.Archetype): {any}, string
        for i = 1, #SIZE_SHAPES do
            local shape = SIZE_SHAPES[i]
            local comp = sizeComp(shape[1])
            local column = comp and archetype:get(comp) as {any}
            if column then return column, shape[2] end
        end
        return nil, nil
    end

    local function rowSize(column: {any}, kind: string, row: integer,
            sx: number, sy: number): number, number
        sx, sy = math.abs(sx), math.abs(sy)
        local shape = column[row] as {string: number}
        if kind == "wh" then
            return shape.width * sx, shape.height * sy
        elseif kind == "r" then
            return shape.radius * 2 * sx, shape.radius * 2 * sy
        end
        return shape.radiusX * 2 * sx, shape.radiusY * 2 * sy
    end

    local function addGrid(cam: gfxtypes.Camera, sw: number, sh: number)
        local x1, y1 = cam:toWorld(0, 0)
        local x2, y2 = cam:toWorld(sw, 0)
        local x3, y3 = cam:toWorld(0, sh)
        local x4, y4 = cam:toWorld(sw, sh)
        local minX = math.min(x1, x2, x3, x4)
        local maxX = math.max(x1, x2, x3, x4)
        local minY = math.min(y1, y2, y3, y4)
        local maxY = math.max(y1, y2, y3, y4)
        local gw, gh = ctx.gridW, ctx.gridH
        if gw <= 0 or gh <= 0 then return end
        while (maxX - minX) / gw > MAX_GRID_LINES do gw = gw * 2 end
        while (maxY - minY) / gh > MAX_GRID_LINES do gh = gh * 2 end

        local x = math.floor((minX - ctx.gridOX) / gw) * gw + ctx.gridOX
        while x <= maxX do
            local ax, ay = cam:toScreen(x, minY)
            local bx, by = cam:toScreen(x, maxY)
            if not batch:line(ax, ay, bx, by, 1, 1, 1, 1, 0.14) then break end
            x = x + gw
        end
        local y = math.floor((minY - ctx.gridOY) / gh) * gh + ctx.gridOY
        while y <= maxY do
            local ax, ay = cam:toScreen(minX, y)
            local bx, by = cam:toScreen(maxX, y)
            if not batch:line(ax, ay, bx, by, 1, 1, 1, 1, 0.14) then break end
            y = y + gh
        end
    end

    w:addSystem({
        name = "debug.Visuals",
        phase = tecs.phases.PostRender,
        run = function()
            if not ctx.showIds and not ctx.showBounds and not ctx.gridEnabled then return end
            local pipeline = w.resources[pipelinekey.PIPELINE]
            if not pipeline then return end
            local cam = pipeline:getCamera()
            local sw, sh = lg.getWidth(), lg.getHeight()
            local ox = cam:toScreen(0, 0)
            local ux = cam:toScreen(1, 0)
            local worldScale = math.max(math.abs(ux - ox), 0.0001)
            batch:clear()
            for i = #labels, 1, -1 do labels[i] = nil end

            if ctx.gridEnabled then addGrid(cam, sw, sh) end

            if ctx.showBounds then
                local shown = 0
                for archetype, len in query:iter() do
                    if shown < MAX_BOUNDS then
                        local column, kind = sizeColumn(archetype)
                        if column then
                            local transforms = archetype:get(Transform)
                            for row = 1, len do
                                if shown >= MAX_BOUNDS then break end
                                local t = transforms[row]
                                local bw, bh = rowSize(column, kind, row,
                                    t.scaleX, t.scaleY)
                                local sx, sy = cam:toScreen(t.x, t.y)
                                local pw, ph = bw * worldScale, bh * worldScale
                                if bw > 0 and bh > 0 and sx >= -pw and sx <= sw + pw
                                        and sy >= -ph and sy <= sh + ph then
                                    batch:rectangle("line", sx - pw / 2, sy - ph / 2,
                                        pw, ph, 1, 0.35, 0.85, 1, 0.6)
                                    shown = shown + 1
                                end
                            end
                        end
                    end
                end
            end

            if ctx.showIds then
                local idFont = labelFont()
                local fh = idFont:getHeight()
                local shown = 0
                for archetype, len, entities in query:iter() do
                    if shown < MAX_ID_LABELS then
                        local transforms = archetype:get(Transform)
                        for row = 1, len do
                            if shown >= MAX_ID_LABELS then break end
                            local sx, sy = cam:toScreen(transforms[row].x, transforms[row].y)
                            if sx >= -40 and sx <= sw + 40 and sy >= -20 and sy <= sh + 20 then
                                local text = tostring(entities[row])
                                local tw = idFont:getWidth(text)
                                batch:rectangle("fill", sx - tw / 2 - 2,
                                    sy - fh - 8, tw + 4, fh + 2, 0,
                                    0.11, 0.13, 0.16, 0.8)
                                labels[#labels + 1] = {
                                    text = text, x = sx - tw / 2, y = sy - fh - 7,
                                }
                                shown = shown + 1
                            end
                        end
                    end
                end
            end

            lg.push("all")
            lg.origin()
            lg.setCanvas()
            lg.setShader()
            lg.setBlendMode("alpha", "alphamultiply")
            batch:draw()
            if #labels > 0 then
                lg.setFont(labelFont())
                lg.setColor(1, 1, 1, 0.95)
                for i = 1, #labels do
                    local label = labels[i]
                    lg.print(label.text, label.x, label.y)
                end
            end
            lg.pop()
        end,
    })
end

return visuals
