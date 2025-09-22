# FitContent

Auto-sizes a container to fit its children with optional padding.

## Basic Usage

```lua
local ui = require("tecs2d.ui")
local FitContent = ui.FitContent
local LayoutBox = ui.LayoutBox

-- Container that auto-sizes to fit children with 10px padding
local container = world:spawn(
    Transform(100, 100),
    Rectangle(0, 0),  -- size set by FitContent
    LayoutBox(Rectangle, nil, 0, 0),
    FitContent(10, Rectangle)
)

-- Add a child
world:spawn(
    ChildOf(container),
    RelativeTransform.new({x = 0, y = 0}),
    Text(font, "Hello!"),
    LayoutBox(Text, nil, 0, 0)
)
```

## Fields

| Field               | Type    | Description                             |
| ------------------- | ------- | --------------------------------------- |
| `padding`           | number  | Uniform padding on all sides            |
| `paddingTop`        | number  | Top padding (overrides uniform)         |
| `paddingRight`      | number  | Right padding (overrides uniform)       |
| `paddingBottom`     | number  | Bottom padding (overrides uniform)      |
| `paddingLeft`       | number  | Left padding (overrides uniform)        |
| `adjustComponentId` | integer | Component to update with new dimensions |

## Constructor

```lua
-- Uniform padding, no render adjustment
FitContent(10)

-- Uniform padding, adjust Rectangle component
FitContent(10, Rectangle)

-- Config table for per-side padding
FitContent({
    padding = 10,
    paddingTop = 20,
    adjust = Rectangle
})
```

## How It Works

Each frame, FitContent:

1. Measures the bounding box of all children with LayoutBox
2. Adds padding to calculate final dimensions
3. Updates the entity's LayoutBox width/height
4. Optionally updates a render component's width/height

## Requirements

FitContent **requires** a LayoutBox component on the same entity. Children must also have LayoutBox for measurement.

```lua
-- This works
world:spawn(
    Transform(0, 0),
    Rectangle(0, 0),
    LayoutBox(Rectangle, nil, 0, 0),
    FitContent(10, Rectangle)
)

-- Children need LayoutBox too
world:spawn(
    ChildOf(container),
    RelativeTransform.new({x = 0, y = 0}),
    Text(font, "Content"),
    LayoutBox(Text, nil, 0, 0)  -- Required for measurement
)
```

## Dynamic Resizing

FitContent recalculates every frame, so containers automatically resize when children change:

```lua
-- Text changes → container resizes automatically
local text = world:get(textEntity, Text)
text:setText("Longer text content!")
-- Container will grow on next frame
```