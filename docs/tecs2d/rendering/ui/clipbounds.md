# ClipBounds

Clips (hides) any part of an entity's rendering that falls outside a rectangular region. Works on all renderable
types: sprites, shapes, text, lines, arcs, circles, ellipses, rectangles, and meshes.

ClipBounds is a standalone component. You can add it directly to any entity; it does not require UI components. The
[LayoutNode](./layoutnode) system uses ClipBounds internally to implement scroll container clipping, but you can use it
independently for any rectangular masking.

## Basic Usage

```lua
local gfx = require("tecs2d.gfx")
local ClipBounds = gfx.ClipBounds

-- Clip a sprite to a 200x100 region
world:spawn(
    Transform(150, 75),
    Sprite("player"),
    ClipBounds(50, 25, 250, 125)  -- minX, minY, maxX, maxY
)

-- Clip a shape
world:spawn(
    Transform(100, 100),
    Circle(50),
    ClipBounds(80, 80, 120, 120)  -- Only the center 40x40 area is visible
)
```

## Fields

| Field  | Type   | Description                      |
| ------ | ------ | -------------------------------- |
| `minX` | number | Left edge of the clip region     |
| `minY` | number | Top edge of the clip region      |
| `maxX` | number | Right edge of the clip region    |
| `maxY` | number | Bottom edge of the clip region   |

All values are in **world-space coordinates**.

## Constructor

```lua
ClipBounds(minX, minY, maxX, maxY)
```

All parameters are optional and default to 0.

## Updating at Runtime

ClipBounds lives in the metadata buffer, so you must mark the entity dirty after modifying it. You can either
modify in-place and mark dirty, or replace the component with `world:set()` (which marks dirty automatically):

```lua
-- Option 1: modify in-place + mark dirty
local clip = world:get(entityId, ClipBounds)
clip.minX = newMinX
clip.minY = newMinY
clip.maxX = newMaxX
clip.maxY = newMaxY
world:markComponentDirty(entityId, ClipBounds)

-- Option 2: replace the component (marks dirty automatically)
world:set(entityId, ClipBounds(newMinX, newMinY, newMaxX, newMaxY))
```

See [Dirty Tracking](/tecs/components/dirty-tracking) for more details and efficient bulk approaches.

## Automatic Clipping with LayoutNode

If you use [LayoutNode](./layoutnode) for scrollable containers, ClipBounds is propagated automatically to all
descendant entities. You do not need to manage it manually in that case. See the
[LayoutNode documentation](./layoutnode) for details.
