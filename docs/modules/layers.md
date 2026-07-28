---
description: "Layer bands, the depth they resolve to, and what a layer does to its contents: sorting, positioning, parallax and lighting"
outline: deep
---

# layers

A layer is a band of the depth range. Everything drawn on a layer sorts within that band and never
against another one, so a HUD on layer 8 covers a world on layer 1 whatever the two contain. A layer is
what a `Transform` carries alongside its position, and it defaults to one.

The band formula is fixed rather than configurable. Content is authored against what it produces: change
how a layer maps to depth and every scene built on it re-sorts, which is a change nobody can see coming
from the diff. What a layer does configure is how its contents sort within its own band, where they are
positioned, and whether they are lit. Those decide where a game puts a thing, so they are settled before
content is authored rather than after: whether a layer is screen-space is the difference between a HUD
written in pixels and one written in world units.

## Requiring it

```teal
local tecs <const> = require("tecs")
```

`tecs.layers` is the module. `tecs` is also set as a global, so the require line is optional.

## Module values

| Value           | Type      | Value   | Description                                                                                |
| --------------- | --------- | ------- | ------------------------------------------------------------------------------------------ |
| `MAX`           | `integer` | `16`    | Bands the depth range divides into, and the highest layer index.                           |
| `maxZ`          | `number`  | `1000`  | Highest z a scene is expected to use, which sets the resolution of sorting within a band.  |
| `maxY`          | `number`  | `10000` | Half the world extent a scene is expected to occupy, for normalising position into a band. |
| `virtualWidth`  | `number`  | `1920`  | Width of the resolution a virtual-coordinate layer is authored in.                         |
| `virtualHeight` | `number`  | `1080`  | Height of that resolution.                                                                 |

`MAX` is load-bearing at sixteen. A sort mode packs into two bits, the table the vertex shader reads is
sized to it, and the shader recovers a layer by multiplying a depth by it. `LAYER_BANDS` in
`assets/shaders/instance.vert.glsl` is the same number, and the two only work while they agree. Raising
it is not a constant change.

A scene reaching past `maxZ` still draws, with entities beyond the edge resting on it and no longer
sorting against each other. A scene larger than `maxY` still sorts, with entities beyond the edge
compressed against it.

There is one virtual resolution for every virtual-coordinate layer, because it is the design size a
layout is drawn against and a game has one of those. It is scaled to fill the target, so the layout keeps
its proportions within itself at any window size and stretches with the window's aspect.

## Sort modes

`layers.Sort` is an enum of three strings.

| Sort          | What decides the order within the band                                                                                                                                                                                        |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `"topdown"`   | World y and z together: lower on the screen draws in front of what is above it, and z carries the greater share of the band, so a character standing on a crate reads as on top of it. What a top-down or side-on game wants. |
| `"z"`         | Only z. What a HUD wants, where position means nothing and the author has said what covers what.                                                                                                                              |
| `"isometric"` | World x plus world y plus z, for a diamond grid where both axes move an entity towards the viewer.                                                                                                                            |

## Configuring a layer

### configure

Sets what a layer does with its contents.

```teal
function layers.configure(layer: integer, config: layers.Config)
```

**Parameters:**

- `layer`: one to `MAX`. Anything else raises.
- `config`: the whole of what the layer is. Raises on a missing or unknown `sort`, and on asking for
  `screenSpace` and `virtualCoords` together.

::: warning Replaces, never amends
A `Config` is the whole of what a layer is, so a field left out is that field's default and not whatever
the layer held before. This says what a layer is rather than amending what it was.
:::

**`Config` fields:**

| Field           | Type          | Default  | Description                                                                                                                                             |
| --------------- | ------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sort`          | `layers.Sort` | required | How contents sort within the layer's band. A sort is the one thing every layer has an opinion about.                                                    |
| `screenSpace`   | `boolean`     | `false`  | Contents are positioned in screen pixels and ignore the camera entirely. What a HUD wants.                                                              |
| `ignoreZoom`    | `boolean`     | `false`  | Contents follow the camera's position but not its zoom, so they stay a constant size on screen while moving with the world.                             |
| `virtualCoords` | `boolean`     | `false`  | Contents are positioned in `virtualWidth` by `virtualHeight`, which is scaled to fill the target. Cannot be combined with `screenSpace`.                |
| `unlit`         | `boolean`     | `false`  | Contents bypass the lighting pass and appear at their own colour.                                                                                       |
| `parallax`      | `number`      | `1`      | How much the camera's position carries the contents. One moves them with the world; a half drifts them at half speed, which is what a background wants. |

A material can also ask to be unlit, and a fragment is lit only where the material and the layer agree.

**Example:**

```teal
tecs.layers.configure(1, { sort = "topdown", parallax = 0.5 })
tecs.layers.configure(2, { sort = "topdown" })
tecs.layers.configure(8, { sort = "z", screenSpace = true, unlit = true })
```

## Culling

The cull tests a world bound against the world rectangle the camera sees, which only means something on
a layer the camera places where that bound says. Screen-space and virtual-coordinate contents have no
world position for the view to test, and parallax and ignore-zoom draw them somewhere the bound does not
describe.

Extraction reads `viewCulled` per row and writes a bound no view can be outside of for those layers, so
the layer is drawn whatever the camera is looking at. Culling is given up on a layer that asks for one of
these, and kept exactly on every layer that does not, which is where the entities are.

### viewCulled

Whether the camera's view rectangle decides if this layer is drawn.

```teal
function layers.viewCulled(layer: integer): boolean
```

**Parameters:**

- `layer`: one to `MAX`. Outside that this answers true, which is what an unconfigured layer answers too.

**Returns:** whether extraction should write this row's real world bound. False on a layer positioned in
screen pixels or virtual coordinates, on one with a parallax other than one, and on one that ignores
zoom.

## Depth

### depthOf

Depth for one entity, in zero to one with zero nearest.

```teal
function layers.depthOf(layer: integer, z: number, x: number, y: number): number
```

**Parameters:**

- `layer`: one to `MAX`, which picks the band and, through `sortOf`, what the rest of the arguments mean.
  Outside that range this takes the nearest layer whole and goes on sorting within it, because a band is
  the only thing a depth can name.
- `z`: height in the sort, against `maxZ`. Read by every sort mode.
- `x`: world x, read only by the isometric sort, against `maxY`.
- `y`: world y, read by the topdown and isometric sorts, against `maxY`. Larger is lower on screen and so
  nearer.

**Returns:** a depth inside the layer's own band, whatever the arguments were. Each of them is normalised
and then held to zero and one, so a scene reaching past what the module was told to expect stops sorting
rather than spilling into the next layer.

Higher layers are nearer, so layer `MAX` occupies the band closest to zero. A sliver is left at the end
of each band, so the far end of one never reaches the near end of the next.

::: info Exact ties carry no tie-breaker
Instances are drawn in index order and the depth test lets an equal fragment through, so two entities at
the same depth already resolve the same way every frame: the later one wins. Nudging depth by identity
would resolve them the other way, since a larger value is farther, and quietly invert the order a scene
was built expecting.
:::

### depthResolution

The smallest depth difference `depthOf` produces between two entities one unit apart, taken over every
sort mode.

```teal
function layers.depthResolution(): number
```

**Returns:** a depth difference, in the input that moves depth least. That is the topdown sort's y at the
defaults, which spends the smallest share of a band on the widest range.

This is what a depth buffer has to hold. A format whose own step is larger than this keeps the bands, so
layer order is never at risk, and loses the sort inside them: the two entities land on one depth value
and draw in the order they were written rather than the order they were sorted into.

Every mode is counted rather than the one a scene is using, because `configure` may put any layer on any
sort at any point after the depth target exists. The number is derived from `MAX`, `maxZ` and `maxY`, so
raising an extent moves it.

## Reading the table back

These three are what the renderer packs into the uniform the vertex shader reads. A game rarely calls
them, and they are here because the table is public.

### sortOf

How a layer sorts, as the identifier `depthOf` takes.

```teal
function layers.sortOf(layer: integer): integer
```

**Parameters:**

- `layer`: one to `MAX`. Outside that this answers topdown rather than raising, since it is the default
  every layer starts on.

**Returns:** the sort identifier, which is an internal number and not one of the `Sort` strings.

### entryOf

The four floats the vertex shader reads for one layer.

```teal
function layers.entryOf(layer: integer): number, number, number, number
```

**Parameters:**

- `layer`: one to `MAX`. Outside that every return is nil, since only that range is ever filled in.

**Returns:** the positioning mode, then the camera position's multiplier, which is one minus `parallax`,
then one when the layer ignores zoom, then one when it is lit.

They are handed over as a group because they are packed as a group, which happens when `revision` moves
rather than every frame.

### revision

How many times the table has been configured.

```teal
function layers.revision(): integer
```

**Returns:** a count that starts at zero and only rises. A consumer compares it against the value it
packed at, so the number itself means nothing beyond having changed.

## Clipping is a separate opt-in

A layer decides where its contents are placed and how they sort; it does not bound them. Keeping an
entity's fragments inside a rectangle is the `Clip` component, whose index names a rectangle set through
the [Renderer](/modules/Renderer). Zero, the default, means no clipping, and a world that clips nothing
pays for it exactly nowhere.

## Design record

- [Layers](https://github.com/tecs-dev/tecs/blob/main/README.md#layers)
- [Clip regions](https://github.com/tecs-dev/tecs/blob/main/README.md#clip-regions)
