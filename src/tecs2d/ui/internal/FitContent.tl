--- FitContent component for auto-sizing containers to fit their children.
--- Measures child bounds and updates LayoutBox (and optionally a render component).

local tecs <const> = require("tecs")

local ChildOf <const> = tecs.builtins.ChildOf
local RelativeTransform <const> = tecs.builtins.RelativeTransform

local type Component = tecs.Component
local type World = tecs.World

local LayoutBox: Component

local record FitContentConfig
    padding: number
    paddingTop: number
    paddingRight: number
    paddingBottom: number
    paddingLeft: number
    adjust: Component
end

--- Auto-sizes a container to fit its children with optional padding.
--- Requires LayoutBox on the same entity.
local record FitContent is Component
    --- Uniform padding applied on all sides (used if per-side padding is 0).
    padding: number

    --- Padding for top edge.
    paddingTop: number

    --- Padding for right edge.
    paddingRight: number

    --- Padding for bottom edge.
    paddingBottom: number

    --- Padding for left edge.
    paddingLeft: number

    --- Component ID to update with new dimensions (0 = none).
    --- The component must have width/height fields or a setSize method.
    adjustComponentId: integer

    --- Creates a new FitContent component from positional args.
    --- For the table form, use `FitContent.new({ padding = 10, adjust = ... })`.
    ---
    --- @param padding Uniform padding in world units.
    --- @param adjustComponent Optional component to update dimensions on.
    --- @return the created FitContent component.
    metamethod __call: function(
        self,
        padding?: number,
        adjustComponent?: Component
    ): FitContent

    new: function(config: FitContentConfig): FitContent

    --- Reusable bounding-box accumulator for measuring child layout bounds.
    record MeasureCtx
        world: World
        hasChildren: boolean
        minX: number
        minY: number
        maxX: number
        maxY: number
    end

    --- Accumulate one child's layout bounds (RelativeTransform position plus
    --- LayoutBox offset and size) into ctx. Children missing RelativeTransform
    --- or LayoutBox are ignored. Usable directly as a world:targets visitor.
    measureChild: function(childId: integer, ctx: MeasureCtx)

    --- Plugin to install FitContent systems.
    plugin: function(world: World)
end

local record Sizable
    width: number
    height: number
end

local function resolveAdjustId(c: Component): integer
    if c then
        local componentId = c.componentId
        if componentId and type(componentId) == "number" then
            return componentId as integer
        end
    end
    return 0
end

-- LayoutBox is lazily required (as a generic Component) to avoid a circular
-- dependency, so column reads are cast into the structural shape used here.
local record SizableBox
    width: number
    height: number
    offsetX: number
    offsetY: number
    originX: number
    originY: number
end

function FitContent.measureChild(childId: integer, ctx: FitContent.MeasureCtx)
    if not LayoutBox then
        LayoutBox = require("tecs2d.ui.internal.LayoutBox")
    end
    local relTransform = ctx.world:get(childId, RelativeTransform)
    local childBox = ctx.world:get(childId, LayoutBox) as SizableBox
    if relTransform and childBox then
        ctx.hasChildren = true
        local left = relTransform.x + childBox.offsetX
        local top = relTransform.y + childBox.offsetY
        local right = left + childBox.width
        local bottom = top + childBox.height
        if left < ctx.minX then ctx.minX = left end
        if top < ctx.minY then ctx.minY = top end
        if right > ctx.maxX then ctx.maxX = right end
        if bottom > ctx.maxY then ctx.maxY = bottom end
    end
end

tecs.newComponent({
    name = "FitContent",
    container = FitContent,
    fields = {
        "padding",
        "paddingTop",
        "paddingRight",
        "paddingBottom",
        "paddingLeft",
        "adjustComponentId"
    },
    defaults = {0, 0, 0, 0, 0, 0},
    __call = function(instance: FitContent, padding?: number, adjustComponent?: Component)
        instance.padding = padding or 0
        instance.adjustComponentId = resolveAdjustId(adjustComponent)
    end,
    new = function(data: {string: any}): FitContent
        local config = data as FitContentConfig
        return {
            padding = config.padding or 0,
            paddingTop = config.paddingTop or 0,
            paddingRight = config.paddingRight or 0,
            paddingBottom = config.paddingBottom or 0,
            paddingLeft = config.paddingLeft or 0,
            adjustComponentId = resolveAdjustId(config.adjust),
        }
    end,
})

function FitContent.plugin(world: World)
    -- Lazy require to avoid circular dependency
    LayoutBox = require("tecs2d.ui.internal.LayoutBox")

    local fitContentQuery = world:query({
        name = "FitContent",
        include = {FitContent, LayoutBox}
    })

    -- Reusable measurement context. Hoisted to plugin scope so the
    -- world:targets visitor doesn't allocate a fresh table per parent.
    local measureCtx: FitContent.MeasureCtx = {
        world = world, hasChildren = false,
        minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0
    }
    local measureChild <const> = FitContent.measureChild

    world:addSystem({
        name = "ui.ComputeFitContent",
        phase = tecs.phases.PostUpdate,
        after = {"ui.ComputeLayoutBox"},
        run = function()
            for archetype, len, entities in fitContentQuery:iter() do
                local fitContents = archetype:get(FitContent)
                local layoutBoxes = archetype:getMut(LayoutBox)

                for row = 1, len do
                    local fitContent = fitContents[row]
                    local layoutBox = layoutBoxes[row] as SizableBox
                    local parentId = entities[row]

                    -- 1. Measure children via the reverse-indexed ChildOf
                    -- relationship: O(own-children) per parent, no allocation.
                    measureCtx.hasChildren = false
                    measureCtx.minX = math.huge
                    measureCtx.minY = math.huge
                    measureCtx.maxX = -math.huge
                    measureCtx.maxY = -math.huge
                    world:targets(parentId, ChildOf, measureChild, measureCtx)
                    local minX = measureCtx.minX
                    local minY = measureCtx.minY
                    local maxX = measureCtx.maxX
                    local maxY = measureCtx.maxY
                    local hasChildren = measureCtx.hasChildren

                    if not hasChildren then
                        minX, minY, maxX, maxY = 0, 0, 0, 0
                    end

                    -- 2. Calculate dimensions with padding
                    local padTop = fitContent.paddingTop > 0 and fitContent.paddingTop or fitContent.padding
                    local padRight = fitContent.paddingRight > 0 and fitContent.paddingRight or fitContent.padding
                    local padBottom = fitContent.paddingBottom > 0 and fitContent.paddingBottom or fitContent.padding
                    local padLeft = fitContent.paddingLeft > 0 and fitContent.paddingLeft or fitContent.padding

                    local contentWidth = maxX - minX
                    local contentHeight = maxY - minY
                    local newWidth = contentWidth + padLeft + padRight
                    local newHeight = contentHeight + padTop + padBottom

                    -- 3. Update LayoutBox
                    layoutBox.width = newWidth
                    layoutBox.height = newHeight
                    layoutBox.offsetX = -newWidth * layoutBox.originX
                    layoutBox.offsetY = -newHeight * layoutBox.originY

                    -- 4. Update render component if specified
                    if fitContent.adjustComponentId > 0 then
                        local comp = tecs.getComponentById(fitContent.adjustComponentId)
                        if comp then
                            local renderData = world:get(parentId, comp) as Sizable
                            if renderData and (renderData.width ~= newWidth
                                or renderData.height ~= newHeight) then
                                renderData.width = newWidth
                                renderData.height = newHeight
                                -- cdata writes through world:get don't
                                -- signal the dirty model; without this the
                                -- GPU sync never re-uploads the new size.
                                world:markComponentDirty(parentId, comp)
                            end
                        end
                    end
                end
            end
        end
    })
end

return FitContent
