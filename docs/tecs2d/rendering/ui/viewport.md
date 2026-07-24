---
description: "The Viewport component providing clipping and scrolling containers for child entities"
---

# Viewport

A container that provides clipping and scrolling for its children. Requires LayoutBox for dimensions.

## Basic Usage

```teal
local ui = require("tecs2d.ui")
local Viewport = ui.Viewport
local LayoutBox = ui.LayoutBox

-- Create a scrollable container
local container = world:spawn(
    Transform(50, 50),
    Rectangle(200, 300),
    LayoutBox(Rectangle, nil, 0, 0),  -- Top-left origin
    Viewport(0, 0, 200, 600)  -- scrollX, scrollY, contentWidth, contentHeight
)
```

## Fields

| Field           | Type   | Description              |
| --------------- | ------ | ------------------------ |
| `scrollX`       | number | Horizontal scroll offset |
| `scrollY`       | number | Vertical scroll offset   |
| `contentWidth`  | number | Total content width      |
| `contentHeight` | number | Total content height     |

## Constructor

```teal
Viewport(scrollX, scrollY, contentWidth, contentHeight)
```

All parameters are optional and default to 0.

## Requirements

Viewport requires a LayoutBox component on the same entity. Without one, the
entity is not processed as a viewport:

```teal
-- This works
world:spawn(
    Transform(0, 0),
    Rectangle(200, 300),
    LayoutBox(Rectangle),
    Viewport(0, 0, 200, 600)
)

-- This entity does not clip or scroll its children
world:spawn(
    Transform(0, 0),
    Viewport(0, 0, 200, 600)
)
```

## Scrolling

Children of a Viewport are clipped to its bounds and offset by the scroll values:

<p align="center">
<img src="./scrollable-container.png" alt="Scrollable Container" /><br/>
<em>See the <a href="https://github.com/tecs-dev/tecs/tree/main/examples/ui">UI example</a>.</em>
</p>

```teal
-- Update scroll position
local viewport = world:getMut(containerId, Viewport)
viewport.scrollY = viewport.scrollY + 10  -- Scroll down 10 pixels

-- Clamp to valid range
local layoutBox = world:get(containerId, LayoutBox)
local maxScroll = math.max(0, viewport.contentHeight - layoutBox.height)
viewport.scrollY = math.max(0, math.min(viewport.scrollY, maxScroll))
```
