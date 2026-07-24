--- Dirty-gated resolver for Flow arrangement and FitContent sizing.

local tecs <const> = require("tecs")
local dirty <const> = require("tecs2d.ui.internal.dirty")
local FitContent <const> = require("tecs2d.ui.internal.FitContent")
local Flow <const> = require("tecs2d.ui.internal.Flow")
local FlowOrder <const> = require("tecs2d.ui.internal.FlowOrder")
    as tecs.ScalarComponent<number>
local LayoutBox <const> = require("tecs2d.ui.internal.LayoutBox")

local ChildOf <const> = tecs.builtins.ChildOf
local RelativeTransform <const> = tecs.builtins.RelativeTransform

local type Component = tecs.Component
local type World = tecs.World

local record layout
    plugin: function(world: World)
end

local record Sizable
    width: number
    height: number
end

local record SizableBox
    width: number
    height: number
    offsetX: number
    offsetY: number
    originX: number
    originY: number
end

local record GatherCtx
    world: World
    count: integer
    ids: {integer}
    orders: {number}
end

local installed <const>: {World: boolean} =
    setmetatable({}, {__mode = "k"} as metatable<{World: boolean}>)

local function gatherChild(childId: integer, ctx: GatherCtx)
    if not ctx.world:get(childId, RelativeTransform)
            or not ctx.world:get(childId, LayoutBox) then
        return
    end
    local count = ctx.count + 1
    ctx.count = count
    ctx.ids[count] = childId
    local order = ctx.world:get(childId, FlowOrder) as any
    ctx.orders[count] = order and order as number or 0
end

local function sortChildren(ids: {integer}, orders: {number}, count: integer)
    for i = 2, count do
        local id = ids[i]
        local order = orders[i]
        local j = i - 1
        while j >= 1 do
            local beforeOrder = orders[j]
            local beforeId = ids[j]
            if beforeOrder < order
                    or (beforeOrder == order and beforeId < id) then
                break
            end
            ids[j + 1] = beforeId
            orders[j + 1] = beforeOrder
            j = j - 1
        end
        ids[j + 1] = id
        orders[j + 1] = order
    end
end

local function padding(fit: FitContent): number, number, number, number
    if not fit then return 0, 0, 0, 0 end
    local top = fit.paddingTop > 0 and fit.paddingTop or fit.padding
    local right = fit.paddingRight > 0 and fit.paddingRight or fit.padding
    local bottom = fit.paddingBottom > 0 and fit.paddingBottom or fit.padding
    local left = fit.paddingLeft > 0 and fit.paddingLeft or fit.padding
    return top, right, bottom, left
end

local function alignOffset(align: string, available: number): number
    if align == "center" then return available * 0.5 end
    if align == "end" then return available end
    return 0
end

function layout.plugin(world: World)
    if installed[world] then return end
    installed[world] = true

    local flowQuery = world:query({
        name = "ui.Flow",
        include = {Flow, LayoutBox},
    })
    local fitQuery = world:query({
        name = "ui.FitContent",
        include = {FitContent, LayoutBox},
    })

    local gatherCtx: GatherCtx = {
        world = world,
        count = 0,
        ids = {},
        orders = {},
    }
    local lineStarts: {integer} = {}
    local lineEnds: {integer} = {}
    local lineCrosses: {number} = {}
    local scratchRelative = RelativeTransform(0, 0)
    local scratchBox = LayoutBox(0, 0)

    local measureCtx: FitContent.MeasureCtx = {
        world = world,
        hasChildren = false,
        minX = 0,
        minY = 0,
        maxX = 0,
        maxY = 0,
    }

    local function setChildPosition(
        childId: integer,
        x: number,
        y: number
    ): boolean
        -- Compare the float32 values that will actually land in the FFI
        -- column, otherwise fractional gaps can keep the resolver open.
        scratchRelative.x = x
        scratchRelative.y = y
        x = scratchRelative.x
        y = scratchRelative.y
        local current = world:get(childId, RelativeTransform)
        if current.x == x and current.y == y then return false end
        local mut = world:getMut(childId, RelativeTransform)
        mut.x = x
        mut.y = y
        return true
    end

    local function arrangeParent(
        parentId: integer,
        flow: Flow,
        parentBox: SizableBox,
        fit: FitContent
    ): boolean
        gatherCtx.count = 0
        world:targets(parentId, ChildOf, gatherChild, gatherCtx)
        local count = gatherCtx.count
        if count == 0 then return false end

        local ids = gatherCtx.ids
        local orders = gatherCtx.orders
        sortChildren(ids, orders, count)

        local horizontal = flow.direction == "right"
            or flow.direction == "left"
        local wrapEnabled = flow.wrap ~= "none"
        local padTop, padRight, padBottom, padLeft = padding(fit)
        local availableMain = horizontal
            and parentBox.width - padLeft - padRight
            or parentBox.height - padTop - padBottom

        if wrapEnabled and flow.maxItems == 0 and fit
                and ((horizontal and fit.fitWidth)
                    or (not horizontal and fit.fitHeight)) then
            error(
                "Flow: size-driven wrapping requires a fixed main axis "
                .. "or maxItems"
            )
        end

        local lineCount = 0
        local lineStart = 1
        local lineItems = 0
        local lineMain: number = 0
        local lineCross: number = 0

        for i = 1, count do
            local childBox = world:get(ids[i], LayoutBox) as SizableBox
            local itemMain = horizontal and childBox.width or childBox.height
            local itemCross = horizontal and childBox.height or childBox.width
            local nextMain = lineItems == 0
                and itemMain
                or lineMain + flow.gap + itemMain
            local breaksByCount = flow.maxItems > 0
                and lineItems >= flow.maxItems
            local breaksBySize = flow.maxItems == 0
                and availableMain > 0
                and lineItems > 0
                and nextMain > availableMain

            if wrapEnabled and (breaksByCount or breaksBySize) then
                lineCount = lineCount + 1
                lineStarts[lineCount] = lineStart
                lineEnds[lineCount] = i - 1
                lineCrosses[lineCount] = lineCross
                lineStart = i
                lineItems = 0
                lineMain = 0
                lineCross = 0
                nextMain = itemMain
            end

            lineItems = lineItems + 1
            lineMain = nextMain
            if itemCross > lineCross then lineCross = itemCross end
        end

        lineCount = lineCount + 1
        lineStarts[lineCount] = lineStart
        lineEnds[lineCount] = count
        lineCrosses[lineCount] = lineCross

        local left = parentBox.offsetX + padLeft
        local top = parentBox.offsetY + padTop
        local right = parentBox.offsetX + parentBox.width - padRight
        local bottom = parentBox.offsetY + parentBox.height - padBottom
        local changed = false

        if horizontal then
            local crossCursor = flow.wrap == "up" and bottom or top
            for line = 1, lineCount do
                local rowHeight = lineCrosses[line]
                local rowTop: number
                if flow.wrap == "up" then
                    rowTop = crossCursor - rowHeight
                    crossCursor = rowTop - flow.lineGap
                else
                    rowTop = crossCursor
                    crossCursor = rowTop + rowHeight + flow.lineGap
                end

                local mainCursor = flow.direction == "left" and right or left
                for i = lineStarts[line], lineEnds[line] do
                    local childId = ids[i]
                    local childBox = world:get(childId, LayoutBox) as SizableBox
                    local childLeft: number
                    if flow.direction == "left" then
                        childLeft = mainCursor - childBox.width
                        mainCursor = childLeft - flow.gap
                    else
                        childLeft = mainCursor
                        mainCursor = childLeft + childBox.width + flow.gap
                    end
                    local childTop = rowTop
                        + alignOffset(flow.align, rowHeight - childBox.height)
                    changed = setChildPosition(
                        childId,
                        childLeft - childBox.offsetX,
                        childTop - childBox.offsetY
                    ) or changed
                end
            end
        else
            local crossCursor = flow.wrap == "left" and right or left
            for line = 1, lineCount do
                local columnWidth = lineCrosses[line]
                local columnLeft: number
                if flow.wrap == "left" then
                    columnLeft = crossCursor - columnWidth
                    crossCursor = columnLeft - flow.lineGap
                else
                    columnLeft = crossCursor
                    crossCursor = columnLeft + columnWidth + flow.lineGap
                end

                local mainCursor = flow.direction == "up" and bottom or top
                for i = lineStarts[line], lineEnds[line] do
                    local childId = ids[i]
                    local childBox = world:get(childId, LayoutBox) as SizableBox
                    local childTop: number
                    if flow.direction == "up" then
                        childTop = mainCursor - childBox.height
                        mainCursor = childTop - flow.gap
                    else
                        childTop = mainCursor
                        mainCursor = childTop + childBox.height + flow.gap
                    end
                    local childLeft = columnLeft
                        + alignOffset(flow.align, columnWidth - childBox.width)
                    changed = setChildPosition(
                        childId,
                        childLeft - childBox.offsetX,
                        childTop - childBox.offsetY
                    ) or changed
                end
            end
        end

        for i = 1, count do
            ids[i] = nil
            orders[i] = nil
        end
        for i = 1, lineCount do
            lineStarts[i] = nil
            lineEnds[i] = nil
            lineCrosses[i] = nil
        end
        return changed
    end

    local function arrangeAll(): boolean
        local changed = false
        for archetype, len, entities in flowQuery:iter() do
            local flows = archetype:get(Flow)
            local boxes = archetype:get(LayoutBox)
            local fits = archetype:get(FitContent)
            for row = 1, len do
                changed = arrangeParent(
                    entities[row],
                    flows[row],
                    boxes[row] as SizableBox,
                    fits and fits[row] or nil
                ) or changed
            end
        end
        return changed
    end

    local function fitAll(): boolean
        local changed = false
        for archetype, len, entities in fitQuery:iter() do
            local fits = archetype:get(FitContent)
            local boxes = archetype:get(LayoutBox)
            local mutBoxes: {SizableBox} = nil

            for row = 1, len do
                local fit = fits[row]
                local box = boxes[row] as SizableBox
                local parentId = entities[row]

                measureCtx.hasChildren = false
                measureCtx.minX = math.huge
                measureCtx.minY = math.huge
                measureCtx.maxX = -math.huge
                measureCtx.maxY = -math.huge
                world:targets(
                    parentId,
                    ChildOf,
                    FitContent.measureChild,
                    measureCtx
                )

                local contentWidth: number = 0
                local contentHeight: number = 0
                if measureCtx.hasChildren then
                    contentWidth = measureCtx.maxX - measureCtx.minX
                    contentHeight = measureCtx.maxY - measureCtx.minY
                end
                local padTop, padRight, padBottom, padLeft = padding(fit)
                local width = fit.fitWidth
                    and contentWidth + padLeft + padRight
                    or box.width
                local height = fit.fitHeight
                    and contentHeight + padTop + padBottom
                    or box.height

                scratchBox.width = width
                scratchBox.height = height
                scratchBox.offsetX = -width * box.originX
                scratchBox.offsetY = -height * box.originY
                width = scratchBox.width
                height = scratchBox.height
                local offsetX = scratchBox.offsetX
                local offsetY = scratchBox.offsetY

                if box.width ~= width or box.height ~= height
                        or box.offsetX ~= offsetX or box.offsetY ~= offsetY then
                    if not mutBoxes then
                        mutBoxes = archetype:getMut(LayoutBox) as {SizableBox}
                    end
                    local mut = mutBoxes[row]
                    mut.width = width
                    mut.height = height
                    mut.offsetX = offsetX
                    mut.offsetY = offsetY
                    changed = true
                end

                if fit.adjustComponentId > 0 then
                    local component = tecs.getComponentById(
                        fit.adjustComponentId
                    )
                    if component then
                        local value = world:get(parentId, component) as Sizable
                        local adjustChanged = false
                        if value then
                            if fit.fitWidth and value.width ~= width then
                                value.width = width
                                adjustChanged = true
                            end
                            if fit.fitHeight and value.height ~= height then
                                value.height = height
                                adjustChanged = true
                            end
                            if adjustChanged then
                                world:markComponentDirty(parentId, component)
                            end
                        end
                    end
                end
            end
        end
        return changed
    end

    local layoutWatch = dirty.watch(world, "layout", {
        FitContent as Component,
        Flow as Component,
        FlowOrder as Component,
        LayoutBox as Component,
        RelativeTransform as Component,
        ChildOf as Component,
    })

    world:addSystem({
        name = "ui.ResolveLayout",
        phase = tecs.phases.PostUpdate,
        after = {"ui.ComputeLayoutBox"},
        before = {"ui.ComputeAnchor", "ui.RelativeTransform"},
        run = function()
            if not dirty.changed(world, layoutWatch) then return end
            local MAX_PASSES <const> = 32
            for _ = 1, MAX_PASSES do
                local flowChanged = arrangeAll()
                local fitChanged = fitAll()
                if not flowChanged and not fitChanged then break end
            end
        end,
    })
end

return layout
