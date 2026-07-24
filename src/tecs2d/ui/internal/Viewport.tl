local tecs <const> = require("tecs")
local LayoutBox <const> = require("tecs2d.ui.internal.LayoutBox")
local ClipBounds <const> = require("tecs2d.gfx.internal.ClipBounds")
local dirty <const> = require("tecs2d.ui.internal.dirty")

local Transform <const> = tecs.builtins.Transform
local ChildOf <const> = tecs.builtins.ChildOf
local RelativeTransform <const> = tecs.builtins.RelativeTransform

--- A viewport that provides clipping and scrolling for its children.
--- Children use ChildOf + RelativeTransform to position within the viewport.
--- Requires LayoutBox component for dimensions.
local record Viewport is tecs.Component
    --- Scroll offset (how much content is shifted)
    scrollX: number
    scrollY: number

    --- Total content size (for scroll bounds)
    contentWidth: number
    contentHeight: number

    --- Create a new Viewport component.
    metamethod __call: function(
        self,
        scrollX?: number,
        scrollY?: number,
        contentWidth?: number,
        contentHeight?: number
    ): Viewport

    --- Plugin to install Viewport systems.
    plugin: function(world: tecs.World)
end

tecs.newFFIComponent({
    name = "Viewport",
    container = Viewport,
    fields = {
        {"scrollX", "float"},
        {"scrollY", "float"},
        {"contentWidth", "float"},
        {"contentHeight", "float"}
    },
    defaults = {0, 0, 0, 0},
    -- Viewport requires a user-specified LayoutBox for dimensions
    -- (no meaningful default). Users must add `LayoutBox(w, h)` on
    -- the same entity; the layout query below includes both.
})

function Viewport.plugin(world: tecs.World)
    -- Query for Viewport entities (to compute their clip bounds)
    local viewportQuery = world:query({
        name = "ui.ViewportQuery",
        include = {Viewport, LayoutBox, Transform}
    })

    -- Query for layout children. RelativeTransform is required: the
    -- scroll offset is subtracted from Transform in place every frame,
    -- which is only stable for entities whose Transform is rebuilt from
    -- the parent first (the module contract: children use ChildOf +
    -- RelativeTransform). Without it the subtraction accumulates and the
    -- entity drifts by the scroll amount per frame.
    local childTransformQuery = world:query({
        name = "ui.ChildTransformQuery",
        include = {ChildOf, Transform, RelativeTransform}
    })

    -----------------------------------------------------------------------
    -- Reusable walkUp contexts, visitors, and per-frame maps (allocated
    -- once at plugin init) so per-entity walks and per-frame rebuilds
    -- don't allocate.
    -----------------------------------------------------------------------
    local record ScrollCtx
        offsetsX: {integer: number}
        offsetsY: {integer: number}
        x: number
        y: number
    end
    local scrollCtx: ScrollCtx = {offsetsX = {}, offsetsY = {}, x = 0.0, y = 0.0}

    local function visitScrollAncestor(ancestorId: integer, _depth: integer, ctx: ScrollCtx): boolean
        local ox = ctx.offsetsX[ancestorId]
        if ox then
            ctx.x = ctx.x + ox
            ctx.y = ctx.y + ctx.offsetsY[ancestorId]
        end
        return true
    end

    local record BoundsCtx
        minXByNode: {integer: number}
        minYByNode: {integer: number}
        maxXByNode: {integer: number}
        maxYByNode: {integer: number}
        haveBounds: boolean
        minX: number
        minY: number
        maxX: number
        maxY: number
    end
    local boundsCtx: BoundsCtx = {
        minXByNode = {}, minYByNode = {}, maxXByNode = {}, maxYByNode = {},
        haveBounds = false, minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0,
    }

    local function visitBoundsAncestor(ancestorId: integer, _depth: integer, ctx: BoundsCtx): boolean
        local bMinX = ctx.minXByNode[ancestorId]
        if bMinX then
            local bMinY = ctx.minYByNode[ancestorId]
            local bMaxX = ctx.maxXByNode[ancestorId]
            local bMaxY = ctx.maxYByNode[ancestorId]
            if not ctx.haveBounds then
                ctx.minX, ctx.minY, ctx.maxX, ctx.maxY = bMinX, bMinY, bMaxX, bMaxY
                ctx.haveBounds = true
            else
                if bMinX > ctx.minX then ctx.minX = bMinX end
                if bMinY > ctx.minY then ctx.minY = bMinY end
                if bMaxX < ctx.maxX then ctx.maxX = bMaxX end
                if bMaxY < ctx.maxY then ctx.maxY = bMaxY end
            end
        end
        return true
    end

    -- Keys written into the reused per-frame maps, so clearing walks the
    -- inserted entries instead of allocating fresh maps.
    local scrollNodeIds: {integer} = {}
    local boundsNodeIds: {integer} = {}

    -- Dirty gate shared by the layout passes: hierarchy or layout state
    -- changed this frame or at the end of the previous one (mutations
    -- made after PostUpdate, e.g. MCP run_lua, surface via the
    -- dirty carryover sampler). Per-child ancestor walks are only
    -- worth running when something that feeds them moved.
    local hierarchyWatch = dirty.watch(world, "hierarchy", {
        Transform, RelativeTransform, ChildOf,
        Viewport as tecs.Component, LayoutBox as tecs.Component,
    })
    local function hierarchyDirty(): boolean
        return dirty.changed(world, hierarchyWatch)
    end

    -- Apply scroll offset to children of Viewports
    -- This runs after RelativeTransform computes base positions
    world:addSystem({
        name = "ui.ApplyScrollOffset",
        phase = tecs.phases.PostUpdate,
        after = {"ui.RelativeTransform"},
        run = function()
            -- Transforms only recompose (ui.RelativeTransform) when the
            -- hierarchy gate opens; the scroll subtraction must track it
            -- exactly, or recomposed children lose their scroll offset.
            if not hierarchyDirty() then return end

            -- Build a map of Viewport entity ID -> scroll offset
            local offsetsX = scrollCtx.offsetsX
            local offsetsY = scrollCtx.offsetsY
            local scrollCount = 0

            for archetype, len, entities in viewportQuery:iter() do
                local layouts = archetype:get(Viewport)
                for i = 1, len do
                    local layout = layouts[i]
                    if layout.scrollX ~= 0 or layout.scrollY ~= 0 then
                        local entityId = entities[i]
                        offsetsX[entityId] = layout.scrollX
                        offsetsY[entityId] = layout.scrollY
                        scrollCount = scrollCount + 1
                        scrollNodeIds[scrollCount] = entityId
                    end
                end
            end

            -- Nothing scrolled: skip the per-child ancestor walks.
            if scrollCount == 0 then return end

            -- Apply scroll offset to all descendants of Viewports.
            -- Sums offsets from the full ancestor chain so nested scrolling containers compose their displacements.
            for archetype, len, entities in childTransformQuery:iter() do
                local transforms = archetype:getMut(Transform)
                for i = 1, len do
                    scrollCtx.x, scrollCtx.y = 0.0, 0.0
                    world:walkUp(entities[i], ChildOf, visitScrollAncestor, scrollCtx)
                    if scrollCtx.x ~= 0 or scrollCtx.y ~= 0 then
                        local transform = transforms[i]
                        transform.x = transform.x - scrollCtx.x
                        transform.y = transform.y - scrollCtx.y
                    end
                end
            end

            for i = 1, scrollCount do
                local entityId = scrollNodeIds[i]
                offsetsX[entityId] = nil
                offsetsY[entityId] = nil
                scrollNodeIds[i] = nil
            end
        end
    })

    -- Apply ClipBounds from Viewport ancestors to descendants.
    -- Run in PostUpdate so changes commit before PreRender GPU sync.
    world:addSystem({
        name = "ui.ApplyClipBounds",
        phase = tecs.phases.PostUpdate,
        after = {"ui.ApplyScrollOffset"},
        run = function()
            -- Clip bounds derive from container transforms and boxes;
            -- when nothing in the hierarchy moved this frame the bounds
            -- from the previous run are still correct.
            if not hierarchyDirty() then return end

            -- Build a map of Viewport entity ID -> clip bounds
            local minXByNode = boundsCtx.minXByNode
            local minYByNode = boundsCtx.minYByNode
            local maxXByNode = boundsCtx.maxXByNode
            local maxYByNode = boundsCtx.maxYByNode
            local boundsCount = 0

            for archetype, len, entities in viewportQuery:iter() do
                local boxes = archetype:get(LayoutBox)
                local transforms = archetype:get(Transform)

                for i = 1, len do
                    local entityId = entities[i]
                    local box = boxes[i]
                    local transform = transforms[i]

                    -- Compute world-space clip bounds from transform and box offset
                    -- offsetX/Y converts from transform position to visual top-left
                    local minX = transform.x + box.offsetX
                    local minY = transform.y + box.offsetY

                    minXByNode[entityId] = minX
                    minYByNode[entityId] = minY
                    maxXByNode[entityId] = minX + box.width
                    maxYByNode[entityId] = minY + box.height
                    boundsCount = boundsCount + 1
                    boundsNodeIds[boundsCount] = entityId
                end
            end

            -- Apply ClipBounds to all entities that have a Viewport ancestor, and explicitly remove ClipBounds
            -- from entities that don't. Intersects bounds from EVERY Viewport ancestor so content inside an inner
            -- container can't escape an outer clipped one. Rows whose bounds are unchanged are left alone so the
            -- ClipBounds column doesn't go dirty (and re-upload) every frame.
            for archetype, len, entities in childTransformQuery:iter() do
                local clipCol = archetype:get(ClipBounds)
                for i = 1, len do
                    local entityId = entities[i]
                    boundsCtx.haveBounds = false
                    world:walkUp(entityId, ChildOf, visitBoundsAncestor, boundsCtx)
                    if boundsCtx.haveBounds then
                        local existing = clipCol and clipCol[i]
                        if existing then
                            if existing.minX ~= boundsCtx.minX
                                    or existing.minY ~= boundsCtx.minY
                                    or existing.maxX ~= boundsCtx.maxX
                                    or existing.maxY ~= boundsCtx.maxY then
                                local mutCol = archetype:getMut(ClipBounds)
                                local mut = mutCol[i]
                                mut.minX = boundsCtx.minX
                                mut.minY = boundsCtx.minY
                                mut.maxX = boundsCtx.maxX
                                mut.maxY = boundsCtx.maxY
                            end
                        else
                            world:set(entityId, ClipBounds(
                                boundsCtx.minX, boundsCtx.minY, boundsCtx.maxX, boundsCtx.maxY
                            ))
                        end
                    elseif clipCol then
                        world:remove(entityId, ClipBounds)
                    end
                end
            end

            for i = 1, boundsCount do
                local entityId = boundsNodeIds[i]
                minXByNode[entityId] = nil
                minYByNode[entityId] = nil
                maxXByNode[entityId] = nil
                maxYByNode[entityId] = nil
                boundsNodeIds[i] = nil
            end
        end
    })
end

return Viewport
