# Orbiting Shapes - Hierarchical Transform Demo

This example demonstrates the hierarchical transform system (`tecs.ui`) in action with interactive controls.

## What it shows

- A blue circle in the center of the screen (parent entity)
- Colored rectangles orbiting around the circle (child entities)
- Automatic transform propagation from parent to children
- Dynamic entity creation/destruction
- Camera zoom controls
- Debug stats overlay (FPS, entity count, memory usage)

## Interactive Controls

- **UP Arrow** - Add a satellite (max 32)
- **DOWN Arrow** - Remove a satellite (min 1)
- **= Key** - Zoom in
- **- Key** - Zoom out
- **ESC** - Quit

## How it works

1. The parent circle has a `Transform` component for its world position
2. Each satellite rectangle has:
   - `RelativeTransform` - defines its position relative to the parent
   - `ChildOf(parent)` - creates the parent-child relationship
3. The `HierarchicalTransformSystem` automatically computes each child's world `Transform` by composing:
   - Parent's world transform (rotation + position)
   - Child's relative transform (offset)
4. When the parent rotates, all children orbit around it automatically!
5. When satellites are added/removed, they automatically respawn evenly spaced around the circle

## Running the demo

From the tecs project root:

```bash
make example-orbiting-shapes
```

Or manually:

```bash
# Build
make
./examples/orbiting-shapes/run.sh
```

## Key components used

- `tecs.ui.RelativeTransform` - Position/rotation/scale relative to parent
- `tecs.builtins.ChildOf` - Parent-child relationship
- `tecs.ui.addHierarchicalTransformSystem` - System that propagates transforms
- `tecs.gfx.Circle` and `tecs.gfx.Rectangle` - Shape rendering
- `tecs.stats` - Debug statistics plugin
- `render.Camera` - Camera with zoom support
