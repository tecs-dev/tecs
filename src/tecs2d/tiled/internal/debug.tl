--- Debug visualization plugin for Tiled objects.
---
--- Spawns visual shapes (rectangles, ellipses, polygons) for objects
--- loaded from Tiled object layers. Useful for debugging collision shapes
--- and object placement.
---
--- Usage:
---   world:addPlugin(tiled.debugPlugin)
---   world:emit(0, tiled.DebugToggle)  -- toggle on/off

local tecs <const> = require("tecs")
local gfx <const> = require("tecs2d.gfx")
local types <const> = require("tecs2d.tiled.types")

local Transform <const> = tecs.builtins.Transform

local Rectangle <const> = gfx.Rectangle
local Ellipse <const> = gfx.Ellipse
local Circle <const> = gfx.Circle
local Color <const> = gfx.Color
local Unlit <const> = gfx.Unlit

--- Configuration for the debug plugin.
local record DebugConfig
    --- The render layer for debug shapes (default: 15, high layer to draw on top)
    renderLayer: integer

    --- Color for debug shapes (default: semi-transparent green)
    color: {number, number, number, number}

    --- Whether to draw filled shapes (default: false, draws outlines only)
    filled: boolean

    --- Line width for outlines (default: 2)
    lineWidth: number

    --- Only show objects from layers matching these names (nil = show all)
    layerFilter: {string}

    --- Only show objects with these class names (nil = show all)
    classFilter: {string}
end

local record debugVis
    --- Configuration type for debug rendering.
    type DebugConfig = DebugConfig

    --- Default configuration for debug rendering.
    defaultConfig: DebugConfig

    --- Tag component added to all debug shape entities.
    TiledDebugShape: tecs.Component

    --- Event to toggle debug shapes on/off. Emit to world address 0.
    record DebugToggle is tecs.Event
        metamethod __call: function(self): DebugToggle
    end

    --- Spawn debug shapes for all objects in a loaded tilemap.
    spawnDebugShapes: function(
        world: tecs.World, config: DebugConfig,
        data: types.TilemapData, mapX: number, mapY: number
    )
end

-- Register tag component (bitset storage, no data)
debugVis.TiledDebugShape = tecs.newTagComponent({name = "TiledDebugShape"})
local TiledDebugShape <const> = debugVis.TiledDebugShape

-- Register toggle event
local DebugToggle <const> = debugVis.DebugToggle
tecs.newFFIEvent(DebugToggle, {}, "TiledDebugToggle")

debugVis.defaultConfig = {
    renderLayer = 15,
    color = {0.0, 1.0, 0.5, 0.6},  -- Semi-transparent green
    filled = false,
    lineWidth = 2.0,
    layerFilter = nil,
    classFilter = nil,
}

local function shouldShowObject(config: DebugConfig, layerName: string, className: string): boolean
    if config.layerFilter then
        local found = false
        local filter <const> = config.layerFilter
        for i = 1, #filter do
            if filter[i] == layerName then
                found = true
                break
            end
        end
        if not found then
            return false
        end
    end

    if config.classFilter then
        local found = false
        local filter <const> = config.classFilter
        for i = 1, #filter do
            if filter[i] == className then
                found = true
                break
            end
        end
        if not found then
            return false
        end
    end

    return true
end

function debugVis.spawnDebugShapes(
    world: tecs.World,
    cfg: DebugConfig,
    data: types.TilemapData,
    mapX: number,
    mapY: number
)
    local lineWidth = cfg.filled and 0 or cfg.lineWidth
    local renderLayer = cfg.renderLayer

    local layers <const> = data.layers
    for li = 1, #layers do
        local layer = layers[li]
        if layer.type == "objectgroup" and layer.objects then
            local objects <const> = layer.objects
            for oi = 1, #objects do
                local obj = objects[oi]
                local className = obj.class or ""

                if not shouldShowObject(cfg, layer.name, className) then
                    goto continue
                end

                local x = mapX + layer.offsetx + obj.x
                local y = mapY + layer.offsety + obj.y

                -- Use distinct colors per shape type when using default color
                local colorR, colorG, colorB, colorA: number, number, number, number
                local useDistinctColors = cfg.color[1] == debugVis.defaultConfig.color[1]
                    and cfg.color[2] == debugVis.defaultConfig.color[2]
                    and cfg.color[3] == debugVis.defaultConfig.color[3]
                if useDistinctColors then
                    if obj.shape == "rectangle" then
                        colorR, colorG, colorB, colorA = 0.0, 1.0, 0.0, 1.0
                    elseif obj.shape == "ellipse" then
                        colorR, colorG, colorB, colorA = 1.0, 0.0, 1.0, 1.0
                    elseif obj.shape == "point" then
                        colorR, colorG, colorB, colorA = 1.0, 1.0, 0.0, 1.0
                    elseif obj.shape == "polygon" then
                        colorR, colorG, colorB, colorA = 0.0, 0.5, 1.0, 1.0
                    elseif obj.shape == "polyline" then
                        colorR, colorG, colorB, colorA = 1.0, 0.5, 0.0, 1.0
                    else
                        colorR, colorG, colorB, colorA = cfg.color[1], cfg.color[2], cfg.color[3], cfg.color[4]
                    end
                else
                    colorR, colorG, colorB, colorA = cfg.color[1], cfg.color[2], cfg.color[3], cfg.color[4]
                end

                if obj.shape == "rectangle" then
                    world:spawn(
                        Rectangle(obj.width, obj.height, lineWidth),
                        Transform.new({x = x + obj.width / 2, y = y + obj.height / 2, layer = renderLayer}),
                        Color(colorR, colorG, colorB, colorA),
                        Unlit, TiledDebugShape
                    )
                elseif obj.shape == "ellipse" then
                    local radiusX = obj.width / 2
                    local radiusY = obj.height / 2
                    world:spawn(
                        Ellipse(radiusX, radiusY, lineWidth),
                        Transform.new({x = x + radiusX, y = y + radiusY, layer = renderLayer}),
                        Color(colorR, colorG, colorB, colorA),
                        Unlit, TiledDebugShape
                    )
                elseif obj.shape == "point" then
                    world:spawn(
                        Circle(6, lineWidth),
                        Transform.new({x = x, y = y, layer = renderLayer}),
                        Color(colorR, colorG, colorB, colorA),
                        Unlit, TiledDebugShape
                    )
                end

                ::continue::
            end
        end
    end
end

return debugVis
