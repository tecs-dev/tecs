--- Debug annotations: world-space shapes and text drawn over the game, plus
--- entity id labels. This is the single owner of ad-hoc debug drawing: the
--- `draw` registry command writes the store (so both the operator and the
--- debug_draw_* MCP tools go through one path) and the debug.Annotations
--- system renders it every frame, panel open or closed.
---
--- Annotations may be pinned to an entity: x/y (and x2/y2) become offsets
--- from its Transform, and the annotation is removed when the entity dies.
--- Durations use wall-clock time so annotations appear and expire while the
--- game is frozen.

local tecs <const> = require("tecs")
local gfxtypes <const> = require("tecs2d.gfx.types")
local pipelinekey <const> = require("tecs2d.gfx.internal.pipelinekey")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")

local Transform <const> = tecs.builtins.Transform
local lg <const> = love.graphics

-- Id labels and bounds outlines are a full walk of Transform entities while
-- enabled; cap the rendered count so a huge world stays interactive.
local MAX_ID_LABELS <const> = 200
local MAX_BOUNDS <const> = 200
-- Grid lines per axis before the step doubles to stay readable when zoomed out.
local MAX_GRID_LINES <const> = 200

-- Size-bearing gfx components in resolution priority order, each paired with
-- how its size is read: "wh" (width/height), "r" (radius), "rr"
-- (radiusX/radiusY). Sprite dimensions live in renderer-owned metadata
-- (SpriteData), not the Sprite component itself.
local SIZE_SHAPES <const>: {{string}} = {
    {"RepeatedSprite", "wh"},
    {"SpriteData", "wh"},
    {"Rectangle", "wh"},
    {"Circle", "r"},
    {"Ellipse", "rr"},
}

local record annotations
    enum Kind
        "rect"
        "circle"
        "line"
        "text"
    end

    record Annotation
        id: integer
        kind: Kind
        x: number
        y: number
        w: number
        h: number
        radius: number
        x2: number
        y2: number
        text: string
        r: number
        g: number
        b: number
        a: number
        tag: string
        -- Wall-clock expiry; nil = persistent.
        expiresAt: number
        lineWidth: number
        fontSize: number
        -- When nonzero, positions are offsets from this entity's Transform
        -- and the annotation dies with the entity.
        entity: integer
    end

    record Store
        list: {Annotation}
        nextId: integer

        --- Add an annotation (id is assigned) and return its id.
        add: function(self: Store, a: Annotation): integer

        --- Remove by tag or id; with neither, remove everything.
        --- Returns the number removed.
        clear: function(self: Store, tag?: string, id?: integer): integer

        --- Drop expired annotations and ones whose entity died. Called by the
        --- draw system each frame; isAlive is injected for testability.
        sweep: function(self: Store, now: number, isAlive: function(integer): boolean)
    end

    KEY: tecs.Key<Store>

    --- Create an empty store (no world wiring; unit-testable).
    newStore: function(): Store

    --- Create the store resource and install the debug.Annotations render
    --- system (annotations + entity id labels when ctx.showIds).
    install: function(w: tecs.World, ctx: debugcontext.Context): Store
end

annotations.KEY = tecs.newKey()

function annotations.Store:add(a: annotations.Annotation): integer
    a.id = self.nextId
    self.nextId = self.nextId + 1
    self.list[#self.list + 1] = a
    return a.id
end

function annotations.Store:clear(tag?: string, id?: integer): integer
    if not tag and not id then
        local n = #self.list
        self.list = {}
        return n
    end
    local removed = 0
    for i = #self.list, 1, -1 do
        local a = self.list[i]
        if (tag and a.tag == tag) or (id and a.id == id) then
            table.remove(self.list, i)
            removed = removed + 1
        end
    end
    return removed
end

function annotations.Store:sweep(now: number, isAlive: function(integer): boolean)
    for i = #self.list, 1, -1 do
        local a = self.list[i]
        if (a.expiresAt and now >= a.expiresAt)
            or (a.entity ~= 0 and not isAlive(a.entity)) then
            table.remove(self.list, i)
        end
    end
end

function annotations.newStore(): annotations.Store
    local self: annotations.Store = {
        list = {},
        nextId = 1,
    } as annotations.Store
    setmetatable(self as {string: any}, {__index = annotations.Store})
    return self
end

function annotations.install(w: tecs.World, ctx: debugcontext.Context): annotations.Store
    local store = annotations.newStore()
    w.resources[annotations.KEY] = store

    local idQuery = w:query({name = "debug.IdLabels", include = {Transform}})

    -- Text annotations and id labels persist across frames; cache fonts by
    -- size so drawing never churns font objects in a hot path.
    local fontCache: {number: love.graphics.Font} = {}
    local function fontFor(size: number): love.graphics.Font
        local f = fontCache[size]
        if not f then
            f = lg.newFont(size)
            fontCache[size] = f
        end
        return f
    end

    local function isAlive(eid: integer): boolean
        return w:isAlive(eid)
    end

    -- Size-bearing gfx components, resolved by name so this module never
    -- forces the gfx shape modules to load. Misses retry (registration
    -- happens whenever the pipeline installs, possibly after us).
    local sizeComps: {string: tecs.Component} = {}
    local function sizeComp(name: string): tecs.Component
        local comp = sizeComps[name]
        if comp == nil then
            local ok, resolved = pcall(tecs.componentByName, name)
            comp = ok and resolved or nil
            if comp then sizeComps[name] = comp end
        end
        return comp
    end

    -- First size-bearing column the archetype carries plus how to read it,
    -- resolved once per archetype (not per row). nil when nothing declares
    -- a size.
    local function sizeColumn(archetype: tecs.Archetype): {any}, string
        for i = 1, #SIZE_SHAPES do
            local shape = SIZE_SHAPES[i]
            local comp = sizeComp(shape[1])
            local col = comp and archetype:get(comp) as {any}
            if col then return col, shape[2] end
        end
        return nil, nil
    end

    -- Axis-aligned size of one row from a resolved size column.
    local function rowSize(col: {any}, kind: string, row: integer, sx: number, sy: number): number, number
        sx, sy = math.abs(sx), math.abs(sy)
        local s = col[row] as {string: number}
        if kind == "wh" then
            return s.width * sx, s.height * sy
        elseif kind == "r" then
            return s.radius * 2 * sx, s.radius * 2 * sy
        end
        return s.radiusX * 2 * sx, s.radiusY * 2 * sy
    end

    local function drawGrid(ctxRef: debugcontext.Context, cam: gfxtypes.Camera, sw: number, sh: number)
        -- Cover the visible view under any rotation by boxing all four corners.
        local x1, y1 = cam:toWorld(0, 0)
        local x2, y2 = cam:toWorld(sw, 0)
        local x3, y3 = cam:toWorld(0, sh)
        local x4, y4 = cam:toWorld(sw, sh)
        local minX = math.min(x1, x2, x3, x4)
        local maxX = math.max(x1, x2, x3, x4)
        local minY = math.min(y1, y2, y3, y4)
        local maxY = math.max(y1, y2, y3, y4)

        local gw, gh = ctxRef.gridW, ctxRef.gridH
        if gw <= 0 or gh <= 0 then return end
        -- Zoomed far out, double the step until the line count stays sane.
        while (maxX - minX) / gw > MAX_GRID_LINES do gw = gw * 2 end
        while (maxY - minY) / gh > MAX_GRID_LINES do gh = gh * 2 end

        lg.setColor(1, 1, 1, 0.14)
        lg.setLineWidth(1)
        local startX = math.floor((minX - ctxRef.gridOX) / gw) * gw + ctxRef.gridOX
        local x = startX
        while x <= maxX do
            local ax, ay = cam:toScreen(x, minY)
            local bx, by = cam:toScreen(x, maxY)
            lg.line(ax, ay, bx, by)
            x = x + gw
        end
        local startY = math.floor((minY - ctxRef.gridOY) / gh) * gh + ctxRef.gridOY
        local y = startY
        while y <= maxY do
            local ax, ay = cam:toScreen(minX, y)
            local bx, by = cam:toScreen(maxX, y)
            lg.line(ax, ay, bx, by)
            y = y + gh
        end
    end

    w:addSystem({
        name = "debug.Annotations",
        phase = tecs.phases.PostRender,
        run = function()
            local hasIds = ctx.showIds
            local hasBounds = ctx.showBounds
            local hasGrid = ctx.gridEnabled
            local hasOverlays = hasIds or hasBounds or hasGrid
            if #store.list == 0 and not hasOverlays then return end

            local pipeline = w.resources[pipelinekey.PIPELINE]
            if not pipeline then return end
            local cam = pipeline:getCamera()

            store:sweep(love.timer.getTime(), isAlive)
            if #store.list == 0 and not hasOverlays then return end

            -- World-units-to-screen-pixels scale, from the camera itself so
            -- any zoom / virtual-resolution combination is handled.
            local ox = cam:toScreen(0, 0)
            local ux = cam:toScreen(1, 0)
            local worldScale = math.abs(ux - ox)
            if worldScale <= 0 then worldScale = 1 end

            lg.push("all")
            lg.origin()
            -- The render pipeline may leave a custom shader, blend mode, or an
            -- offscreen canvas active depending on which pass ran last; reset
            -- so immediate-mode draws actually land on screen.
            lg.setCanvas()
            lg.setShader()
            lg.setBlendMode("alpha", "alphamultiply")

            local sw = lg.getWidth()
            local sh = lg.getHeight()

            -- The grid draws first so annotations and labels stay readable
            -- on top of it.
            if hasGrid then
                drawGrid(ctx, cam, sw, sh)
            end

            if hasBounds then
                lg.setColor(0.35, 0.85, 1.0, 0.6)
                lg.setLineWidth(1)
                local shown = 0
                -- The outer query loop must run to completion; only the row
                -- loop stops once the cap is reached.
                for archetype, len in idQuery:iter() do
                    if shown < MAX_BOUNDS then
                        local col, kind = sizeColumn(archetype)
                        if col then
                            local transforms = archetype:get(Transform)
                            for row = 1, len do
                                if shown >= MAX_BOUNDS then break end
                                local t = transforms[row]
                                local bw, bh = rowSize(col, kind, row, t.scaleX, t.scaleY)
                                if bw > 0 and bh > 0 then
                                    local cxs, cys = cam:toScreen(t.x, t.y)
                                    if cxs >= -bw * worldScale and cxs <= sw + bw * worldScale
                                        and cys >= -bh * worldScale and cys <= sh + bh * worldScale then
                                        lg.rectangle("line",
                                            cxs - bw * worldScale / 2, cys - bh * worldScale / 2,
                                            bw * worldScale, bh * worldScale)
                                        shown = shown + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end

            for i = 1, #store.list do
                local a = store.list[i]
                local ax, ay = a.x, a.y
                local bx, by = a.x2, a.y2
                if a.entity ~= 0 then
                    local t = w:get(a.entity, Transform)
                    if t then
                        ax, ay = t.x + a.x, t.y + a.y
                        bx, by = t.x + a.x2, t.y + a.y2
                    end
                end
                lg.setColor(a.r, a.g, a.b, a.a)
                lg.setLineWidth(a.lineWidth)
                if a.kind == "rect" then
                    local sx, sy = cam:toScreen(ax, ay)
                    lg.rectangle("line", sx, sy, a.w * worldScale, a.h * worldScale)
                elseif a.kind == "circle" then
                    local sx, sy = cam:toScreen(ax, ay)
                    lg.circle("line", sx, sy, a.radius * worldScale)
                elseif a.kind == "line" then
                    local sx1, sy1 = cam:toScreen(ax, ay)
                    local sx2, sy2 = cam:toScreen(bx, by)
                    lg.line(sx1, sy1, sx2, sy2)
                elseif a.kind == "text" then
                    local sx, sy = cam:toScreen(ax, ay)
                    lg.setFont(fontFor(a.fontSize))
                    lg.print(a.text, sx, sy)
                end
            end

            if hasIds then
                local font = fontFor(12)
                lg.setFont(font)
                local fh = font:getHeight()
                local shown = 0
                -- The outer query loop must run to completion; only the row
                -- loop stops once the cap is reached.
                for archetype, len, entities in idQuery:iter() do
                    if shown < MAX_ID_LABELS then
                        local transforms = archetype:get(Transform)
                        for row = 1, len do
                            if shown >= MAX_ID_LABELS then break end
                            local t = transforms[row]
                            local sx, sy = cam:toScreen(t.x, t.y)
                            if sx >= -40 and sx <= sw + 40 and sy >= -20 and sy <= sh + 20 then
                                local label = tostring(entities[row])
                                local tw = font:getWidth(label)
                                lg.setColor(0.11, 0.13, 0.16, 0.8)
                                lg.rectangle("fill", sx - tw / 2 - 2, sy - fh - 8, tw + 4, fh + 2)
                                lg.setColor(1, 1, 1, 0.95)
                                lg.print(label, sx - tw / 2, sy - fh - 7)
                                shown = shown + 1
                            end
                        end
                    end
                end
            end

            lg.pop()
        end,
    })
    return store
end

return annotations
