local tecs <const> = require("tecs")
local LayoutBox <const> = require("tecs2d.ui.internal.LayoutBox")
local ClipBounds <const> = require("tecs2d.gfx.internal.ClipBounds")

local Transform <const> = tecs.builtins.Transform
local ChildOf <const> = tecs.builtins.ChildOf

--- A layout node that provides clipping and scrolling for its children.
--- Children use ChildOf + RelativeTransform to position within the node.
--- Requires LayoutBox component for dimensions.
local record LayoutNode is tecs.Component
    --- Scroll offset (how much content is shifted)
    scrollX: number
    scrollY: number

    --- Total content size (for scroll bounds)
    contentWidth: number
    contentHeight: number

    --- Create a new LayoutNode component.
    metamethod __call: function(
        self,
        scrollX?: number,
        scrollY?: number,
        contentWidth?: number,
        contentHeight?: number
    ): LayoutNode

    --- Plugin to install LayoutNode systems.
    plugin: function(world: tecs.World)
end

tecs.newFFIComponent({
    name = "LayoutNode",
    container = LayoutNode,
    fields = {
        {"scrollX", "float"},
        {"scrollY", "float"},
        {"contentWidth", "float"},
        {"contentHeight", "float"}
    },
    defaults = {0, 0, 0, 0},
    -- LayoutNode requires a user-specified LayoutBox for dimensions
    -- (no meaningful default). Users must add `LayoutBox(w, h)` on
    -- the same entity; the layout query below includes both.
})

function LayoutNode.plugin(world: tecs.World)
    -- Query for LayoutNode entities (to compute their clip bounds)
    local layoutNodeQuery = world:query({
        name = "ui.LayoutNodeQuery",
        include = {LayoutNode, LayoutBox, Transform}
    })

    -- Query for entities with ChildOf and Transform
    local childTransformQuery = world:query({
        name = "ui.ChildTransformQuery",
        include = {ChildOf, Transform}
    })

    -----------------------------------------------------------------------
    -- Reusable walkUp contexts and visitors (allocated once at plugin init)
    -- so per-entity walks don't allocate closures every frame.
    -----------------------------------------------------------------------
    local record ScrollCtx
        offsets: {integer: {number, number}}
        x: number
        y: number
    end
    local scrollCtx: ScrollCtx = {offsets = {}, x = 0.0, y = 0.0}

    local function visitScrollAncestor(ancestorId: integer, _depth: integer, ctx: ScrollCtx): boolean
        local offset = ctx.offsets[ancestorId]
        if offset then
            ctx.x = ctx.x + offset[1]
            ctx.y = ctx.y + offset[2]
        end
        return true
    end

    local record BoundsCtx
        bounds: {integer: {number, number, number, number}}
        haveBounds: boolean
        minX: number
        minY: number
        maxX: number
        maxY: number
    end
    local boundsCtx: BoundsCtx = {bounds = {}, haveBounds = false, minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0}

    local function visitBoundsAncestor(ancestorId: integer, _depth: integer, ctx: BoundsCtx): boolean
        local b = ctx.bounds[ancestorId]
        if b then
            if not ctx.haveBounds then
                ctx.minX, ctx.minY, ctx.maxX, ctx.maxY = b[1], b[2], b[3], b[4]
                ctx.haveBounds = true
            else
                if b[1] > ctx.minX then ctx.minX = b[1] end
                if b[2] > ctx.minY then ctx.minY = b[2] end
                if b[3] < ctx.maxX then ctx.maxX = b[3] end
                if b[4] < ctx.maxY then ctx.maxY = b[4] end
            end
        end
        return true
    end

    -- Apply scroll offset to children of LayoutNodes
    -- This runs after RelativeTransform computes base positions
    world:addSystem({
        name = "ui.ApplyScrollOffset",
        phase = tecs.phases.PostUpdate,
        after = {"ui.RelativeTransform"},
        run = function()
            -- Build a map of LayoutNode entity ID -> scroll offset
            local scrollOffsets: {integer: {number, number}} = {}

            for archetype, len, entities in layoutNodeQuery:iter() do
                local layouts = archetype:get(LayoutNode)
                for i = 1, len do
                    local entityId = entities[i]
                    local layout = layouts[i]
                    if layout.scrollX ~= 0 or layout.scrollY ~= 0 then
                        scrollOffsets[entityId] = {layout.scrollX, layout.scrollY}
                    end
                end
            end

            -- Apply scroll offset to all descendants of LayoutNodes.
            -- Sums offsets from the full ancestor chain so nested scrolling containers compose their displacements.
            scrollCtx.offsets = scrollOffsets
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
        end
    })

    -- Apply ClipBounds from LayoutNode ancestors to descendants.
    -- Run in PostUpdate so changes commit before PreRender GPU sync.
    world:addSystem({
        name = "ui.ApplyClipBounds",
        phase = tecs.phases.PostUpdate,
        after = {"ui.ApplyScrollOffset"},
        run = function()
            -- Build a map of LayoutNode entity ID -> clip bounds
            local layoutBounds: {integer: {number, number, number, number}} = {}

            for archetype, len, entities in layoutNodeQuery:iter() do
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
                    local maxX = minX + box.width
                    local maxY = minY + box.height

                    layoutBounds[entityId] = {minX, minY, maxX, maxY}
                end
            end

            -- Apply ClipBounds to all entities that have a LayoutNode ancestor, and explicitly remove ClipBounds
            -- from entities that don't. Intersects bounds from EVERY LayoutNode ancestor so content inside an inner
            -- container can't escape an outer clipped one.
            boundsCtx.bounds = layoutBounds
            for _archetype, len, entities in childTransformQuery:iter() do
                for i = 1, len do
                    local entityId = entities[i]
                    boundsCtx.haveBounds = false
                    world:walkUp(entityId, ChildOf, visitBoundsAncestor, boundsCtx)
                    if boundsCtx.haveBounds then
                        world:set(entityId, ClipBounds(
                            boundsCtx.minX, boundsCtx.minY, boundsCtx.maxX, boundsCtx.maxY
                        ))
                    else
                        world:remove(entityId, ClipBounds)
                    end
                end
            end
        end
    })
end

return LayoutNode
