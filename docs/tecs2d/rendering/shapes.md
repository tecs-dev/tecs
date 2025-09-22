# Shapes

Tecs provides GPU-accelerated shape components for rendering circles, ellipses, arcs, rectangles, lines, and custom
meshes. All shapes are rendered using GPU instancing with compute shader culling.

## Common Patterns

All shape components require a `Transform` component for positioning:

```lua
local tecs = require("tecs")
local gfx = require("tecs2d.gfx")

world:spawn(
    tecs.builtins.Transform(100, 100),  -- Position
    gfx.Circle(20),                  -- Shape
    gfx.Color(1, 0.5, 0, 1)          -- Optional: color
)
```

Shapes can be combined with styling components:

- `Color` - RGBA tinting
- `BlendMode` - Blend mode (add, multiply, etc.)
- `Unlit` - Skip dynamic lighting
- `Pivot` - Custom pivot point
- *See [Styling](./styling) for details on these components.*

For advanced visual effects, shapes can also use [Materials](./materials).

## Circle

Renders filled or outlined circles. The transform position is the center of the circle.

```lua
-- Filled circle (default)
gfx.Circle(radius)

-- Outlined circle with line width
gfx.Circle(radius, lineWidth)
```

**Parameters:**

| Parameter     | Type     | Default    | Description                                                                                |
| ------------- | -------- | ---------- | ------------------------------------------------------------------------------------------ |
| `radius`      | number   | required   | Circle radius in pixels                                                                    |
| `lineWidth`   | number   | nil        | Line width for outline. If nil/0, draws filled. ([dirty tracking](#changing-line-width))   |

**Examples:**

```lua
-- Filled red circle
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Circle(30),
    gfx.Color(1, 0, 0, 1)
)

-- Outlined circle with thick anti-aliased line
world:spawn(
    tecs.builtins.Transform(200, 100),
    gfx.Circle(25, 3),
    gfx.Color(0, 1, 0, 1),
)
```

## Ellipse

Renders filled or outlined ellipses. The transform position is the center of the ellipse.

```lua
-- Filled ellipse (default)
gfx.Ellipse(radiusX, radiusY)

-- Outlined ellipse with line width
gfx.Ellipse(radiusX, radiusY, lineWidth)
```

**Parameters:**

| Parameter     | Type     | Default    | Description                                                                                |
| ------------- | -------- | ---------- | ------------------------------------------------------------------------------------------ |
| `radiusX`     | number   | required   | Horizontal radius in pixels                                                                |
| `radiusY`     | number   | required   | Vertical radius in pixels                                                                  |
| `lineWidth`   | number   | nil        | Line width for outline. If nil/0, draws filled. ([dirty tracking](#changing-line-width))   |

**Examples:**

```lua
-- Shadow ellipse under a character
world:spawn(
    tecs.builtins.Transform(x, y + 10),
    gfx.Ellipse(40, 15),
    gfx.Color(0, 0, 0, 0.3)
)
```

## Arc

Renders filled or outlined arc segments (pie slices or arc outlines). Arcs are defined by start and end angles in
radians.

```lua
-- Filled arc (pie slice)
gfx.Arc(radiusX, radiusY, startAngle, endAngle)

-- Outlined arc with line width
gfx.Arc(radiusX, radiusY, startAngle, endAngle, lineWidth)
```

**Parameters:**

| Parameter      | Type     | Default    | Description                                                                                |
| -------------- | -------- | ---------- | ------------------------------------------------------------------------------------------ |
| `radiusX`      | number   | required   | Horizontal radius in pixels                                                                |
| `radiusY`      | number   | required   | Vertical radius in pixels                                                                  |
| `startAngle`   | number   | 0          | Starting angle in radians                                                                  |
| `endAngle`     | number   | 2*pi       | Ending angle in radians                                                                    |
| `lineWidth`    | number   | nil        | Line width for outline. If nil/0, draws filled. ([dirty tracking](#changing-line-width))   |

**Angle Reference:**
- `0` = right
- `math.pi / 2` = down
- `math.pi` = left
- `math.pi * 1.5` = up

**Examples:**

```lua
-- Pac-man shape
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Arc(30, 30, math.pi / 6, 2 * math.pi - math.pi / 6),
    gfx.Color(1, 1, 0, 1)
)

-- Progress indicator (half circle arc outline)
world:spawn(
    tecs.builtins.Transform(200, 100),
    gfx.Arc(40, 40, 0, math.pi, 4),
    gfx.Color(0, 1, 0, 1),
)
```

## Rectangle

Renders filled or outlined rectangles. The transform position is the center of the rectangle.

```lua
-- Filled rectangle (default)
gfx.Rectangle(width, height)

-- Outlined rectangle with line width
gfx.Rectangle(width, height, lineWidth)
```

**Parameters:**

| Parameter     | Type     | Default    | Description                                                                                |
| ------------- | -------- | ---------- | ------------------------------------------------------------------------------------------ |
| `width`       | number   | required   | Width in pixels                                                                            |
| `height`      | number   | required   | Height in pixels                                                                           |
| `lineWidth`   | number   | nil        | Line width for outline. If nil/0, draws filled. ([dirty tracking](#changing-line-width))   |

**Examples:**

```lua
-- Platform
world:spawn(
    tecs.builtins.Transform(200, 300),
    gfx.Rectangle(100, 20),
    gfx.Color(0.5, 0.3, 0.2, 1)
)

-- Debug bounding box
world:spawn(
    tecs.builtins.Transform(x, y),
    gfx.Rectangle(50, 50, 1),
    gfx.Color(1, 0, 0, 0.5)
)
```

### Rounded Corners

Add rounded corners to rectangles with the `RoundedCorners` component:

```lua
-- Uniform corner radius
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Rectangle(80, 40),
    gfx.RoundedCorners(10),  -- 10px corner radius
    gfx.Color(0.2, 0.4, 0.8, 1)
)

-- Different horizontal and vertical radii (elliptical corners)
world:spawn(
    tecs.builtins.Transform(200, 100),
    gfx.Rectangle(80, 40),
    gfx.RoundedCorners(15, 8),  -- rx=15, ry=8
    gfx.Color(0.8, 0.4, 0.2, 1)
)
```

**Note:** `RoundedCorners` requires a `Rectangle` component on the same entity.

## Line

Renders line segments. Endpoints are relative to the transform position.

```lua
gfx.Line(x1, y1, x2, y2, width?)
```

**Parameters:**

| Parameter   | Type     | Default   | Description                                                     |
| ----------- | -------- | --------- | --------------------------------------------------------------- |
| `x1`        | number   | 0         | Start X relative to transform                                   |
| `y1`        | number   | 0         | Start Y relative to transform                                   |
| `x2`        | number   | 0         | End X relative to transform                                     |
| `y2`        | number   | 0         | End Y relative to transform                                     |
| `width`     | number   | 1         | Line width in pixels ([dirty tracking](#changing-line-width))   |

**Examples:**

```lua
-- Simple line (1px default width)
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Line(0, 0, 50, 50),
    gfx.Color(1, 0, 0, 1)
)

-- Thick horizontal line centered at transform
world:spawn(
    tecs.builtins.Transform(200, 100),
    gfx.Line(-30, 0, 30, 0, 5),
    gfx.Color(0, 1, 0, 1),
)

-- Rotating line (e.g., clock hand)
world:spawn(
    tecs.builtins.Transform(x, y, 0, 1, { rotation = math.pi / 4 }),
    gfx.Line(0, 0, 0, -40, 3),
    gfx.Color(1, 1, 1, 1)
)
```

**Notes:**
- Line endpoints scale with `Transform.scaleX` and `Transform.scaleY`
- Rotation is applied around the transform position
- Edges are anti-aliased by default; flip the entire scene to hard pixel
  cutoffs with `pipeline:setRoughGeometry(true)`

## Mesh

Renders custom geometry using GPU instancing. This is useful for complex shapes that can't be expressed with the
built-in primitives.

### Defining a Mesh

First, register a mesh definition with a [Love2D Mesh](https://love2d.org/wiki/Mesh):

```lua
local gfx = require("tecs2d.gfx")

-- Create a Love2D mesh (triangle example)
local vertices = {
    {0, -20, 0, 0, 1, 1, 1, 1},    -- top
    {-17, 15, 0, 0, 1, 1, 1, 1},   -- bottom-left
    {17, 15, 0, 0, 1, 1, 1, 1},    -- bottom-right
}
local loveMesh = love.graphics.newMesh(vertices, "triangles", "static")

-- Register the mesh definition
gfx.MeshDefinition.new("triangle", loveMesh, 1000)  -- name, mesh, capacity
```

### Using a Mesh

Spawn entities with the `Mesh` component referencing the definition name:

```lua
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Mesh("triangle"),
    gfx.Color(1, 0, 0, 1)
)
```

**Parameters:**

| Parameter      | Type     | Description                             |
| -------------- | -------- | --------------------------------------- |
| `definition`   | string   | Name of the registered MeshDefinition   |

### Styling

Meshes support all the same styling components as built-in shapes:

```lua
world:spawn(
    tecs.builtins.Transform(100, 100),
    gfx.Mesh("triangle"),
    gfx.Color(1, 0, 0, 1),              -- Tinting (multiplied with vertex colors)
    gfx.blend.AdditiveBlend(),           -- Blend mode
    gfx.Unlit,                           -- Skip dynamic lighting
    gfx.Pivot(0.5, 0.5)                 -- Custom pivot point
)
```

For advanced effects, meshes can also use [Materials](./materials).

**Notes:**
- Mesh geometry is defined once and shared by all instances
- Each instance can have its own transform, color, and styling
- The mesh is GPU-instanced for efficient rendering of many copies
- Vertex colors in the mesh are multiplied by the `Color` component

## Changing Line Width

Tecs uses a two-tier syncing architecture for GPU rendering. Transform properties (position, rotation, scale) sync
automatically every frame, but metadata properties like `lineWidth` only sync when the column carrying the change
is marked dirty on the archetype. This avoids uploading unchanged data to the GPU every frame.

If you modify `lineWidth` after spawning, fetch the column with
`archetype:getMut(...)` so the renderer shadow buffer re-uploads the
changes:

```lua
for archetype, len in query:iter() do
    local circles = archetype:getMut(gfx.Circle)
    for i = 1, len do
        circles[i].lineWidth = math.sin(time) * 2 + 3
    end
end
```

*See [Dirty Tracking](/tecs/components/dirty-tracking) for more details.*

## Rect Interface

All shape components implement the `Rect` interface, which returns bounding box information:

```lua
local circle = world:get(entity, gfx.Circle)
local offsetX, offsetY, width, height = circle:getRect()
```

The returned values are:
- `offsetX`, `offsetY`: Offset from the entity position to the top-left corner
- `width`, `height`: Dimensions of the bounding box

This is used internally by the rendering pipeline for culling calculations. You can also use it for gameplay logic like
collision detection, mouse hit-testing, or spatial queries:

```lua
-- Check if a point is within an entity's bounding box
local function pointInEntity(world, entity, px, py)
    local transform = world:get(entity, tecs.builtins.Transform)
    local shape = world:get(entity, gfx.Rectangle) -- or Circle, Ellipse, etc.
    local ox, oy, w, h = shape:getRect()
    local left = transform.x + ox
    local top = transform.y + oy
    return px >= left and px <= left + w and py >= top and py <= top + h
end
```