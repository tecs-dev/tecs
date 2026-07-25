--- Object-layer bindings: spawning gameplay entities from Tiled objects
--- through bundles registered on the world.
---
--- Bindings are per-world so two worlds can map the same Tiled class to
--- different bundles. Spawned entities are durable gameplay state, not a
--- derived projection of the map, so they are saved normally and the
--- caller guards against a second spawn after a snapshot load.

local tecs <const> = require("tecs")
local types <const> = require("tecs2d.tiled.types")

local builtins <const> = tecs.builtins
local Transform <const> = builtins.Transform

local type ObjectData = types.ObjectData
local type TilemapData = types.TilemapData

local record objects
    --- Parsed Tiled object data.
    type ObjectData = ObjectData
    --- Fully parsed Tiled map data.
    type TilemapData = TilemapData

    --- Binds a Tiled object class to a bundle registered on the world.
    record Binding
        --- Name of a bundle created with `world:newBundle`. Its first
        --- required component must be `Transform`.
        bundle: string

        --- Returns the bundle's remaining required components, in
        --- declaration order. The leading Transform comes from the
        --- object's position, rotation, and render layer.
        values: function(world: tecs.World, object: ObjectData): {tecs.Component}
    end

    --- Bind a Tiled object class for one world.
    register: function(world: tecs.World, class: string, binding: Binding)

    --- The binding for a class, or nil when the class is unbound.
    binding: function(world: tecs.World, class: string): Binding | nil

    --- World-space center of an object, in map-local coordinates.
    center: function(object: ObjectData): number, number

    --- Spawn every bound object in the map's object layers, parented to
    --- the map entity so despawning the map despawns its objects.
    spawnAll: function(
        world: tecs.World,
        data: TilemapData,
        originX: number,
        originY: number,
        baseLayer: integer,
        mapEntity: integer
    ): integer
end

local registry <const>: {tecs.World: {string: objects.Binding}} =
    setmetatable({}, {__mode = "k"} as metatable<{tecs.World: {string: objects.Binding}}>)

function objects.register(world: tecs.World, class: string, binding: objects.Binding)
    if not class or class == "" then
        error("tiled.registerObject requires a non-empty class", 3)
    end
    if not binding or not binding.bundle then
        error("tiled.registerObject requires a binding with a bundle name", 3)
    end
    local bindings = registry[world]
    if not bindings then
        bindings = {}
        registry[world] = bindings
    end
    bindings[class] = binding
end

function objects.binding(world: tecs.World, class: string): objects.Binding | nil
    local bindings = registry[world]
    if not bindings then return nil end
    return bindings[class]
end

-- Tiled anchors rectangles at their top-left and tile objects at their
-- bottom-left. Both become a center so the spawned Transform matches the
-- pivot convention the renderer already uses.
function objects.center(object: ObjectData): number, number
    local w <const> = object.width or 0
    local h <const> = object.height or 0
    if object.gid and object.gid ~= 0 then
        return object.x + w / 2, object.y - h / 2
    end
    return object.x + w / 2, object.y + h / 2
end

function objects.spawnAll(
    world: tecs.World,
    data: TilemapData,
    originX: number,
    originY: number,
    baseLayer: integer,
    mapEntity: integer
): integer
    local bindings = registry[world]
    if not bindings then return 0 end

    local spawned = 0
    local mapLayers <const> = data.layers
    for li = 1, #mapLayers do
        local layer = mapLayers[li]
        if layer.type ~= "objectgroup" or not layer.objects then goto continueLayer end

        local renderLayer <const> = baseLayer + (layer.groupIndex or 1) - 1
        local offsetX <const> = originX + (layer.offsetx or 0)
        local offsetY <const> = originY + (layer.offsety or 0)
        local layerObjects <const> = layer.objects

        for oi = 1, #layerObjects do
            local object = layerObjects[oi]
            local binding = object.class and bindings[object.class]
            if not binding then goto continueObject end

            local optionalBundle = world:getBundle(binding.bundle)
            if not optionalBundle then
                error("tiled: object class '" .. tostring(object.class)
                    .. "' is bound to unregistered bundle '" .. binding.bundle .. "'")
            end
            local bundle <const> = optionalBundle as tecs.Bundle
            if bundle.required[1] ~= "Transform" then
                error("tiled: bundle '" .. binding.bundle
                    .. "' must declare Transform as its first required component")
            end

            local cx, cy = objects.center(object)
            local transform = Transform.new({
                x = offsetX + cx,
                y = offsetY + cy,
                layer = renderLayer,
                rotation = math.rad(object.rotation or 0),
            })

            local id: integer
            if binding.values then
                local rest <const> = binding.values(world, object)
                id = bundle:spawn(transform, table.unpack(rest))
            else
                id = bundle:spawn(transform)
            end
            world:set(id, builtins.ChildOf(mapEntity))
            spawned = spawned + 1

            ::continueObject::
        end

        ::continueLayer::
    end
    return spawned
end

return objects
