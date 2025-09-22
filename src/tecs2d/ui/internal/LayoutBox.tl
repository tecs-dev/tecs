--- LayoutBox component for UI layout with origin support.
--- Provides dimensions and origin configuration for UI elements.

local tecs <const> = require("tecs")
local render_types <const> = require("tecs2d.gfx.types")
local PivotModule <const> = require("tecs2d.gfx.internal.Pivot")

local ChildOf <const> = tecs.builtins.ChildOf
local Transform <const> = tecs.builtins.Transform
local RelativeTransform <const> = tecs.builtins.RelativeTransform

local type Component = tecs.Component
local type World = tecs.World
local type Rect = render_types.Rect

-- Pivot record for type safety
local record PivotData
    x: number
    y: number
end

local math_sin <const> = math.sin
local math_cos <const> = math.cos

--- Defines the layout dimensions and origin of an entity for positioning calculations.
--- Can be fixed dimensions or dynamically computed from a render component.
local record LayoutBox is Component
    --- The width of the entity for layout purposes.
    width: number

    --- The height of the entity for layout purposes.
    height: number

    --- Offset from Transform position to top-left corner (computed from origin).
    --- For originX=0.5, originY=0.5: offsetX = -width/2, offsetY = -height/2
    --- For originX=0, originY=0: offsetX = 0, offsetY = 0
    offsetX: number
    offsetY: number

    --- Origin X as a percentage (0-1). 0 = left edge, 0.5 = center, 1 = right edge.
    --- Defaults to 0.5 (centered) for backward compatibility.
    originX: number

    --- Origin Y as a percentage (0-1). 0 = top edge, 0.5 = center, 1 = bottom edge.
    --- Defaults to 0.5 (centered) for backward compatibility.
    originY: number

    --- The component ID to query for dimensions (0 = use fixed width/height).
    sourceComponentId: integer

    --- Creates a new LayoutBox component.
    ---
    --- @param widthOrComponent Fixed width, or a Component to dynamically query for dimensions.
    --- @param height Fixed height (only used if first param is a number).
    --- @param originX Origin X (0-1), defaults to 0.5.
    --- @param originY Origin Y (0-1), defaults to 0.5.
    --- @return the created LayoutBox component.
    metamethod __call: function(
        self,
        widthOrComponent: Component | number,
        height?: number,
        originX?: number,
        originY?: number
    ): LayoutBox

    --- Plugin to install LayoutBox systems (ComputeLayoutBox, origin-aware transforms).
    plugin: function(world: World)
end

tecs.newFFIComponent({
    name = "LayoutBox",
    container = LayoutBox,
    fields = {
        {"width", "float"},
        {"height", "float"},
        {"offsetX", "float"},
        {"offsetY", "float"},
        {"originX", "float"},
        {"originY", "float"},
        {"sourceComponentId", "int32_t"}
    },
    init = function(
        instance: LayoutBox,
        widthOrComponent: number | Component,
        height: number,
        originX: number,
        originY: number
    )
        -- Default origin to 0.5 (centered) for backward compatibility
        local ox = originX or 0.5
        local oy = originY or 0.5

        if type(widthOrComponent) == "number" then
            -- Fixed dimensions: LayoutBox(100, 50) or LayoutBox(100, 50, 0, 0)
            local w, h = widthOrComponent as number, height or 0
            -- Compute offset from origin
            local offsetX = -w * ox
            local offsetY = -h * oy
            instance.width = w
            instance.height = h
            instance.offsetX = offsetX
            instance.offsetY = offsetY
            instance.originX = ox
            instance.originY = oy
            instance.sourceComponentId = 0
        else
            -- Component container reference: LayoutBox(Rectangle) or LayoutBox(Rectangle, nil, 0, 0)
            local component = widthOrComponent as Component
            local componentId = component.componentId
            if not componentId or type(componentId) ~= "number" then
                error("LayoutBox: Component reference must have a valid componentId")
            end
            -- Dimensions will be computed from component; offset computed after dimensions known
            instance.width = 0
            instance.height = 0
            instance.offsetX = 0
            instance.offsetY = 0
            instance.originX = ox
            instance.originY = oy
            instance.sourceComponentId = componentId as integer
        end
    end
})

--- Composes a parent transform with a relative transform, handling origin properly.
--- For top-left origin parents (0,0): children positioned relative to visual top-left corner.
--- For other origins: children positioned relative to parent's transform position.
local function composeTransformsWithOrigin(
    parentTransform: tecs.builtins.Transform,
    relativeTransform: tecs.builtins.RelativeTransform,
    outputTransform: tecs.builtins.Transform,
    parentLayoutBox: LayoutBox,
    _childLayoutBox: LayoutBox
)
    local pRot, pScaleX, pScaleY = parentTransform.rotation, parentTransform.scaleX, parentTransform.scaleY

    -- Only apply parent offset for top-left origin parents (origin 0,0)
    -- This enables layout positioning (stacking, alignment) while preserving
    -- centered composition for FitContent and similar patterns
    local parentOffsetX: number = 0
    local parentOffsetY: number = 0
    if parentLayoutBox and parentLayoutBox.originX == 0 and parentLayoutBox.originY == 0 then
        parentOffsetX = parentLayoutBox.offsetX
        parentOffsetY = parentLayoutBox.offsetY
    end

    local relX = parentOffsetX + relativeTransform.x
    local relY = parentOffsetY + relativeTransform.y

    local cosRot = math_cos(pRot)
    local sinRot = math_sin(pRot)
    local scaledX = relX * pScaleX
    local scaledY = relY * pScaleY
    local rotatedX = scaledX * cosRot - scaledY * sinRot
    local rotatedY = scaledX * sinRot + scaledY * cosRot

    outputTransform.x = parentTransform.x + rotatedX
    outputTransform.y = parentTransform.y + rotatedY
    outputTransform.z = parentTransform.z + relativeTransform.z
    outputTransform.layer = parentTransform.layer
    outputTransform.rotation = pRot + relativeTransform.rotation
    outputTransform.scaleX = pScaleX * relativeTransform.scaleX
    outputTransform.scaleY = pScaleY * relativeTransform.scaleY
end

function LayoutBox.plugin(world: World)
    -- Compute LayoutBox dimensions from referenced components
    local layoutBoxQuery = world:query({
        name = "ComputeLayoutBox",
        include = {LayoutBox}
    })

    world:addSystem({
        name = "ui.ComputeLayoutBox",
        phase = tecs.phases.PostUpdate,
        run = function()
            for archetype, len, entities in layoutBoxQuery:iter() do
                local layoutBoxes = archetype:getMut(LayoutBox)
                -- Get Pivot component array from archetype (may be nil)
                local pivots = archetype:getMut(PivotModule)

                for row = 1, len do
                    local box = layoutBoxes[row]
                    local entity = entities[row]

                    -- Compute dimensions from source component if specified
                    if box.sourceComponentId > 0 then
                        local sourceComp = tecs.getComponentById(box.sourceComponentId)
                        if sourceComp then
                            local sourceData = world:get(entity, sourceComp) as Rect
                            if sourceData and sourceData.getRect then
                                local _offsetX, _offsetY, width, height = sourceData:getRect()
                                box.width = width
                                box.height = height
                                box.offsetX = -width * box.originX
                                box.offsetY = -height * box.originY
                            end
                        end
                    end

                    -- Sync LayoutBox origin to Pivot component
                    if pivots then
                        local pivot = pivots[row] as PivotData
                        if pivot then
                            pivot.x = box.originX
                            pivot.y = box.originY
                        end
                    end
                end
            end
        end
    })

    -- Origin-aware RelativeTransform system (replaces core's simple version for UI)
    local hierarchyQuery = world:query({
        name = "ui.RelativeTransform",
        include = {RelativeTransform, ChildOf, Transform}
    })

    -- Process one pass of the hierarchy. Returns true if any child's
    -- computed transform differs from its current Transform (indicating the
    -- parent moved and we need another pass).
    local function processHierarchy(): boolean
        local changed = false
        for archetype, len, entities in hierarchyQuery:iter() do
            local relativeTransforms = archetype:get(RelativeTransform)
            local transforms = archetype:getMut(Transform)
            local childLayoutBoxes = archetype:get(LayoutBox)
            for row = 1, len do
                local relativeTransform = relativeTransforms[row]
                local childOf = world:getFirstRelationship(entities[row], ChildOf)
                if not childOf then
                    goto continue
                end
                local parentId = childOf.target
                local parentTransform = world:get(parentId, Transform)
                if parentTransform then
                    local childTransform = transforms[row]
                    local parentLayoutBox = world:get(parentId, LayoutBox)
                    local childLayoutBox = childLayoutBoxes and childLayoutBoxes[row] or nil
                    local prevX, prevY = childTransform.x, childTransform.y
                    local prevRot, prevSX, prevSY = childTransform.rotation, childTransform.scaleX, childTransform.scaleY
                    composeTransformsWithOrigin(
                        parentTransform, relativeTransform, childTransform, parentLayoutBox, childLayoutBox
                    )
                    if childTransform.x ~= prevX or childTransform.y ~= prevY
                        or childTransform.rotation ~= prevRot
                        or childTransform.scaleX ~= prevSX
                        or childTransform.scaleY ~= prevSY then
                        changed = true
                    end
                end
                ::continue::
            end
        end
        return changed
    end

    world:addSystem({
        name = "ui.RelativeTransform",
        phase = tecs.phases.PostUpdate,
        after = {"ui.ComputeLayoutBox", "RelativeTransform"},  -- Run after core system to override
        run = function()
            -- Iterate the hierarchy until no child transform changes,
            -- which means every parent has been processed before any of
            -- its descendants. The hard cap is a safety bound, not a
            -- depth limit: in well-formed acyclic trees, convergence
            -- happens in <= tree-depth passes.
            local MAX_PASSES <const> = 32
            for _ = 1, MAX_PASSES do
                if not processHierarchy() then
                    break
                end
            end
        end
    })
end

return LayoutBox
