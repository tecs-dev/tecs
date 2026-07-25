---
description: "The FitContent component auto-sizing a LayoutBox container to fit its children with padding"
---

# FitContent

Auto-sizes a container to fit its children with optional padding.

## Basic Usage

```teal
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
| `paddingTop`        | number  | Positive top padding (otherwise uses uniform)    |
| `paddingRight`      | number  | Positive right padding (otherwise uses uniform)  |
| `paddingBottom`     | number  | Positive bottom padding (otherwise uses uniform) |
| `paddingLeft`       | number  | Positive left padding (otherwise uses uniform)   |
| `adjustComponentId` | integer | Component to update with new dimensions |
| `fitWidth`          | boolean | Fit the container and adjusted width    |
| `fitHeight`         | boolean | Fit the container and adjusted height   |

## Constructor

```teal
-- Uniform padding, no render adjustment
FitContent(10)

-- Uniform padding, adjust Rectangle component
FitContent(10, Rectangle)

-- Config table for per-side padding and per-axis fitting
FitContent.new({
    padding = 10,
    paddingTop = 20,
    fit = "width",
    adjust = Rectangle
})
```

`fit` accepts `both` (the default), `width`, or `height`. The positional
constructor fits both axes.

## How It Works

When relevant layout data changes, FitContent:

1. Measures the bounding box of all children with LayoutBox
2. Adds padding to calculate final dimensions
3. Updates the selected LayoutBox axes
4. Optionally updates the same axes on a render component

FitContent and [Flow](./flow) resolve together. This lets one axis remain a
fixed wrapping constraint while the other follows the arranged content:

```teal
world:spawn(
    Rectangle(400, 100),
    LayoutBox(Rectangle, nil, 0, 0),
    ui.Flow("right", 10),
    FitContent.new({
        padding = 10,
        fit = "height",
        adjust = Rectangle,
    })
)
```

## Requirements

FitContent **requires** a LayoutBox component on the same entity. Children must also have LayoutBox for measurement.

```teal
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

FitContent is dirty-gated, so containers resize after children change without
rescanning settled layouts every frame:

```teal
-- Text changes → container resizes automatically
local text = world:get(textEntity, Text)
text:setText("Longer text content!")
-- Container will grow on next frame
```
