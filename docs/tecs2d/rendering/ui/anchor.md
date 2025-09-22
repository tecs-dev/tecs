# Anchor

Positions entities relative to viewport bounds using anchor percentages and pixel offsets. Automatically resolves the
correct viewport dimensions based on the entity's layer coordinate space (screen, virtual, or world).

## Basic Usage

```lua
local ui = require("tecs2d.ui")
local Anchor = ui.Anchor

-- Bottom-left corner, 20px from edges
world:spawn(
    Transform(0, 0, 0, HUD_LAYER),
    Anchor(0, 1, 20, -20),
    Text(font, "Score: 0"),
    Pivot(0, 1)
)

-- Centered on screen
world:spawn(
    Transform(0, 0, 0, HUD_LAYER),
    Anchor(0.5, 0.5, 0, 0),
    Text(font, "PAUSED")
)

-- Top-right corner with offset
world:spawn(
    Transform(0, 0, 0, HUD_LAYER),
    Anchor(1, 0, -20, 20),
    Text(font, "HP: 100"),
    Pivot(1, 0)
)
```

## Fields

| Field     | Type   | Description                                          |
| --------- | ------ | ---------------------------------------------------- |
| `anchorX` | number | Horizontal anchor (0-1). 0=left, 0.5=center, 1=right |
| `anchorY` | number | Vertical anchor (0-1). 0=top, 0.5=center, 1=bottom   |
| `offsetX` | number | Pixel offset from anchor X                           |
| `offsetY` | number | Pixel offset from anchor Y                           |

## Constructor

```lua
Anchor(anchorX, anchorY)              -- No offset
Anchor(anchorX, anchorY, offsetX, offsetY)  -- With offset
```

## How It Works

Each frame, the `ui.ComputeAnchor` system resolves viewport bounds from the entity's layer, then writes to
`Transform.x` and `Transform.y`:

```
transform.x = vpLeft + anchorX * vpWidth + offsetX
transform.y = vpTop  + anchorY * vpHeight + offsetY
```

The viewport bounds depend on the layer's coordinate space:

| Space       | Left/Top            | Width/Height                 |
| ----------- | ------------------- | ---------------------------- |
| `"screen"`  | 0, 0                | screenWidth, screenHeight    |
| `"virtual"` | 0, 0                | virtualWidth, virtualHeight  |
| `"world"`   | camera visX1, visY1 | visX2 - visX1, visY2 - visY1 |

For world-space layers, the anchor tracks the camera; as the camera moves or zooms, anchored entities reposition
automatically.

## Anchored Parent with Children

Anchor works well with `ChildOf` + `RelativeTransform` to create groups of elements anchored together:

```lua
-- Parent anchored to bottom-left
local hudRoot = world:spawn(
    Transform(0, 0, 0, HUD_LAYER),
    Anchor(0, 1, 20, -180)
)
world:commit()

-- Children positioned relative to parent
world:spawn(
    Transform(0, 0, 0, HUD_LAYER),
    ChildOf(hudRoot),
    RelativeTransform(0, 0),
    Text(font, "Line 1")
)
world:spawn(
    Transform(0, 0, 0, HUD_LAYER),
    ChildOf(hudRoot),
    RelativeTransform(0, 30),
    Text(font, "Line 2")
)
```

## System Order

`ui.ComputeAnchor` runs in PostUpdate after layout systems and before RelativeTransform:

```
PostUpdate:
  ui.ComputeLayoutBox
  ui.ComputeFitContent
  ui.ComputeAnchor        -- resolves anchor → Transform.x/y
  ui.RelativeTransform     -- composes parent + child transforms
```

This means Anchor sets the parent position, then RelativeTransform offsets children from that position.

## Requirements

- Anchor only requires `Transform` on the same entity. No LayoutBox needed.
- The `ui.plugin` is auto-installed by `tecs2d.run`. If not using `tecs2d.run`, install it manually: `world:addPlugin(ui.plugin)`
- The render pipeline must be available as a world resource (created by `tecs2d.run` or `gfx.newPipeline`).
