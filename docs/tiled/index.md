---
description: "Load TMX maps and TSX tilesets, render animated layers, edit tiles, and create gameplay entities"
order: 30
---

# Tiled maps

[Tiled](https://www.mapeditor.org/) is a map editor for authoring tile layers,
objects and collision outlines. Tecs reads its XML **TMX maps and TSX tilesets**
through the official [Rust tiled library](https://github.com/mapeditor/rs-tiled).
Save a map as TMX in Tiled and keep its referenced tilesets and images beside it
in the same relative directory structure.

Run the complete example from the checkout:

```bash
nupp task ex-tiled
```

Arrow keys pan the camera. Space replaces a wall tile with a path and restores
it on the next press. The water animates from TSX frames, and the bouncing
circles collide with the wall outlines authored in that tileset. Close the
window to stop, or use `nupp task ex-tiled --frames 120` for a bounded run.
The editable sources are `assets/maps/demo.tmx` and `assets/maps/terrain.tsx`.

## Load and display a map

Inside your application plugin:

```nupp
const map = tecs.tiled.load(tecs.files.assetPath("maps/demo.tmx"))
const entity = tecs.tiled.spawn(app.world, map, {collision = true})
app.world:spawn(tecs.gfx.Camera2D(512, 320, 1), tecs.gfx.ActiveCamera)
```

`load` synchronously reads the map and external TSX files and templates. It
raises at the call when a file cannot be read or decoded. Load during setup
or a loading screen. Images are decoded to RGBA8 when a map is projected into
the world. PNG and JPEG are supported, including Tiled color-key transparency.

`spawn` installs the map system and creates an entity carrying `Tilemap` and
`Transform2D`. The parent transform moves, rotates, scales and layers the map.
You can also install once and spawn the component yourself:

```nupp
tecs.tiled.install(world)
world:spawn(
    tecs.tiled.Tilemap({path = tecs.files.assetPath("maps/demo.tmx")}),
    tecs.ecs.Transform2D(100, 50)
)
```

Tiles draw as ordinary sprite entities through Tecs batching and GPU culling.
`TileSource` retains the local tile ID, tileset name, class and custom
properties. Despawning the map cascades to its children. Removing `Tilemap`
removes its generated visuals while preserving gameplay objects.

## Layers, tilesets and animation

Tecs supports orthogonal finite and infinite maps, atlas and image-collection
tilesets, CSV and compressed base64 tile data, and horizontal, vertical and
diagonal flip flags. Infinite maps retain negative tile coordinates.

Nested groups are flattened in document order. Their visibility, offsets,
opacity, tint and parallax multiply or accumulate into each child layer.
Every map layer uses the parent's graphics layer and adds its flattened layer
index to the parent's z value. Configure that graphics layer with
`tecs.gfx.layers.configure(layer, {sort = "z"})` for ordered overlaps.

Image layers support horizontal and vertical repetition. Tecs reuses visible
repeat quads and updates their coverage as the camera moves or the window
resizes. Parallax uses the map's authored origin. Tile objects without a
registered gameplay factory render as sprites with their size, rotation,
flip flags and tileset alignment.

TSX animation durations become seconds. Instances advance their animation
clock with world updates and change the sprite only when its frame changes.
Atlas spacing and margins are respected.

Other map orientations and non-normal layer blend modes raise an error.
TMJ and TSJ JSON files are not input formats. Map loading currently creates
all nonempty tile entities; infinite-map support is not an on-demand world
streamer. Materials use the normal sprite material unless game code changes
an entity's `Material`.

## Read and edit tiles

```nupp
const _, layer = tecs.tiled.getLayer(map, "Terrain")
const index = assert(layer)
const previous = tecs.tiled.getTile(map, index, 10, 15)
tecs.tiled.setTile(map, index, 10, 15, {tileset = 1, id = 4})
tecs.tiled.setTile(map, index, 10, 15, nil) -- clear the cell
```

Layer and tileset indices are **one-based**. Tile IDs within a tileset and
cell coordinates are **zero-based**. `getTile` returns nil for an empty cell.
Use `setTile` for edits: it validates the coordinate and tile reference and
rebuilds only that cell in every live instance sharing the map. The same edit
updates its collision boundaries. Mutating `map.layers[].cells` directly does
not notify instances.

`worldToTile(map, x, y)` floors **local map pixels** to tile coordinates;
`tileToWorld` returns their top-left local pixel position. If the map parent
has a transform, first convert your world position into that local space.

## Gameplay objects

Register a class before spawning the map:

```nupp
tecs.tiled.registerObject("SpawnPoint", function(exclusive world: tecs.ecs.World, object: tecs.tiled.Object): integer
    return world:spawn(tecs.ecs.Name(object.name))
end)
```

The factory receives the authored ID, class, name, properties, position,
rotation, dimensions, visibility and shape. Shapes retain rectangle, ellipse,
polygon, polyline, point or text metadata. Custom properties retain booleans,
numbers, strings, file values, object IDs, colors, classes and lists.

Return a newly spawned entity. Tecs attaches it to the map with `ChildOf` and
sets its local transform from the object's position and rotation. Factories
own the entity's gameplay components. Registered classes take precedence over
the default tile-object sprite. Non-tile objects without a factory remain
available as metadata and create no entity.

Snapshots preserve gameplay objects and map edits. On restoration, Tecs
rebuilds generated visuals and collision boundaries without running the
factories again or duplicating the restored objects.

## Collision

Pass `{collision = true}` to `spawn` or `Tilemap` to turn tile collision
objects into static Rapier boundaries. Tecs installs physics if the world has
none; install `tecs.physics` first to choose gravity or other settings.

Rectangles and polygons become closed segment outlines; polylines remain open.
Ellipses use a 32-segment outline. These are boundaries, not filled polygon
colliders. Each tile's outline is independent, so adjacent tiles retain their
shared edges. Tile offsets and flip flags apply to collision as well as drawing.

Moving or rotating the map moves its static bodies. Scaling the map rebuilds
the boundaries. Clearing or replacing a tile removes its old boundaries;
Rapier receives those changes on the following fixed step. Parallax changes
presentation and does not move physical boundaries with the camera.

The complete callable surface is in [tecs.tiled](tecs.tiled). See
[tecs.physics](tecs.physics) for bodies, raycasts and direct segment colliders.
