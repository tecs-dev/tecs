---
description: "Spawning gameplay entities from Tiled object layers by binding an object class to a registered bundle"
outline: deep
---

# Object layers

Tiled object layers place non-tile things on a map: enemy spawns, checkpoints, doors, pickups, camera zones. Bind an
object *class* to a [bundle](/tecs/components/bundles) and every matching object in a loaded map spawns an entity.

```teal
local tiled = require("tecs2d.tiled")

world:newBundle("Enemy", {
    required = {Transform, Health},
    with = {[Velocity] = true},
})

tiled.registerObject(world, "enemy", {
    bundle = "Enemy",
    values = function(_world: tecs.World, object: tiled.ObjectData): {tecs.Component}
        return {Health(object.properties.health as number or 100)}
    end,
})
```

Give the object a class of `enemy` in Tiled (the editor labels the field *Type*), add a `health` custom property, and
the map spawns it. Objects whose class has no binding are ignored, so a map can carry editor-only markers alongside
gameplay objects.

Register bindings before the map loads. The `Tilemap` component loads during the next `First` phase, so registering in
your plugin body or a `Startup` system is early enough.

## tiled.registerObject {#tiled-register-object}

```teal
function tiled.registerObject(
    world: tecs.World,
    class: string,
    binding: tiled.ObjectBinding
)
```

**Parameters:**

- `world`: World whose bundles are used and whose objects are spawned. Bindings are per-world.
- `class`: The Tiled object class, which Tiled exports as the object's `type` field.
- `binding`: The bundle name and its required-component builder.

### ObjectBinding

| Field    | Type                                                        | Description                                                                          |
| -------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `bundle` | `string`                                                    | Name of a bundle created with `world:newBundle`. Its first required component must be `Transform`. |
| `values` | `function(world, object): {Component}`                      | Returns the bundle's remaining required components in declaration order. Omit when the bundle requires only a Transform. |

Tiled supplies the leading `Transform` itself, so `values` returns everything after it. A bundle whose first required
component is not `Transform` raises an error when the map loads, as does a binding naming a bundle that was never
registered.

## What Tiled supplies

The spawned `Transform` carries:

- **Position**: the object's center in world space, including the map entity's own `Transform` and the object layer's
  offset. Tiled anchors rectangles at their top-left and tile objects at their bottom-left; both are converted to a
  center so the transform matches the renderer's pivot convention.
- **Rotation**: the object's rotation, converted from Tiled's degrees to radians.
- **Layer**: the map's base layer plus the object layer's group index, matching how tile layers are assigned.

Everything else comes from the bundle and from `values`.

## Lifetime

Spawned objects are parented to the map entity with [`ChildOf`](/tecs/builtins#childof-relationship-component), which
cascades on delete. Despawning the map despawns the objects it spawned.

```teal
world:despawn(mapEntity)  -- the map's enemies, pickups, and doors go with it
```

## Objects are durable, not derived

Tile chunks and animated tile sprites are a *projection* of map data: they are excluded from snapshots and rebuilt on
load. Objects are not. An enemy that moved, took damage, or died is real game state, so objects are saved like any
other entity, and the `Tilemap` component records that its objects were already spawned. Loading a snapshot restores
the saved entities instead of spawning a second copy out of the map file.

This means edits to a map's object layer do not reach an existing save. That is the same constraint any game with
persistent level state has, and the fix is the same: version your maps and migrate, or start a new save.

## Reading tile objects

An object placed from a tileset carries a `gid`. Use
[`tiled.tileSourceFromGid`](/tecs2d/tiled/tile-source) inside `values` to turn it into a `TileSource` component so the
entity renders with the tile's artwork:

```teal
tiled.registerObject(world, "crate", {
    bundle = "Crate",
    values = function(_world: tecs.World, object: tiled.ObjectData): {tecs.Component}
        return {tiled.tileSourceFromGid(mapData, object.gid)}
    end,
})
```
