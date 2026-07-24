---
description: "Arrange UI children in ordered rows or columns with optional wrapping and alignment"
---

# Flow

`Flow` arranges an entity's direct children in a row or column. It is an
optional layout policy: children still use ordinary `ChildOf`,
`RelativeTransform`, and `LayoutBox` components, and custom systems can position
children without using Flow.

## Basic Usage

```teal
local tecs = require("tecs")
local ui = require("tecs2d.ui")

local ChildOf = tecs.builtins.ChildOf
local RelativeTransform = tecs.builtins.RelativeTransform

local panel = world:spawn(
    Transform(40, 40),
    LayoutBox(300, 200, 0, 0),
    ui.Flow("down", 8)
)

for i = 1, 5 do
    world:spawn(
        Transform(),
        ChildOf(panel),
        RelativeTransform(),
        LayoutBox(120, 30, 0, 0),
        ui.FlowOrder(i)
    )
end
```

Flow writes only each child's `RelativeTransform.x` and
`RelativeTransform.y`. It preserves z, rotation, and scale.

## Configuration

The positional constructor creates a single row or column:

```teal
ui.Flow("right", 10)
ui.Flow("down", 6)
```

Use `Flow.new` for wrapping and alignment:

```teal
ui.Flow.new({
    direction = "down",
    wrap = "right",
    gap = 4,
    lineGap = 16,
    maxItems = 8,
    align = "center",
})
```

| Field      | Values                                | Default |
| ---------- | ------------------------------------- | ------- |
| direction  | `right`, `left`, `down`, `up`         | `right` |
| wrap       | `none` or a perpendicular direction   | `none`  |
| gap        | Space between items                   | `0`     |
| lineGap    | Space between wrapped rows or columns | `gap`   |
| maxItems   | Maximum items per row or column       | `0`     |
| align      | `start`, `center`, `end`              | `start` |

The wrap direction must be perpendicular to the item direction. For example,
`direction = "down", wrap = "right"` fills a column from top to bottom and
then starts the next column to its right.

## Ordering

`world:targets` does not promise relationship insertion order, so Flow sorts
children explicitly. `FlowOrder` is an optional scalar component:

```teal
world:spawn(
    ChildOf(panel),
    RelativeTransform(),
    LayoutBox(100, 24),
    ui.FlowOrder(20)
)
```

Children sort by `FlowOrder`, then by entity ID. Children without
`FlowOrder` use order `0`.

## Wrapping

Set `maxItems` to wrap after a fixed number of children:

```teal
ui.Flow.new({
    direction = "down",
    wrap = "right",
    maxItems = 8,
})
```

When `maxItems` is zero, Flow wraps against the parent's fixed `LayoutBox`
extent on the main axis. A horizontal flow uses the parent's width; a vertical
flow uses its height.

Size-driven wrapping cannot use an axis that `FitContent` is also fitting,
because that would make the wrapping constraint depend on its own result. Keep
that axis fixed or provide `maxItems`.

## FitContent and Padding

Flow and [FitContent](./fitcontent) resolve together. When both are present,
Flow uses the FitContent padding as its content inset:

```teal
world:spawn(
    Transform(100, 100),
    Rectangle(400, 100),
    LayoutBox(Rectangle, nil, 0, 0),
    ui.Flow("right", 10),
    ui.FitContent.new({
        padding = 10,
        fit = "height",
        adjust = Rectangle,
    })
)
```

This keeps the width fixed while allowing the height and rectangle to follow
the arranged content.

Nested Flow and FitContent containers are resolved to a stable layout in the
same update. Settled layouts are dirty-gated and do not scan their children
every frame.

## Requirements

A Flow container requires `LayoutBox`. Participating direct children require:

- `ChildOf(flowContainer)`
- `RelativeTransform`
- `LayoutBox`

Children missing either `RelativeTransform` or `LayoutBox` are ignored.
