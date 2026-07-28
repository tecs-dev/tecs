---
description: "Layer bands, the depth they resolve to, and what a layer does to its contents: sorting, positioning, parallax and lighting"
outline: deep
---

# tecs.gfx.layers

A layer is a band of the depth range. Everything drawn on a layer sorts within that band and never
against another one, so a HUD on layer 8 covers a world on layer 1 whatever the two contain. A layer is
what a `Transform` carries alongside its position, and it defaults to one.

The band formula is fixed rather than configurable. Content is authored against what it produces: change
how a layer maps to depth and every scene built on it re-sorts, which is a change nobody can see coming
from the diff. What a layer does configure is how its contents sort within its own band, where they are
positioned, and whether they are lit. Those decide where a game puts a thing, so they are settled before
content is authored rather than after: whether a layer is screen-space is the difference between a HUD
written in pixels and one written in world units.

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
tecs.gfx.layers.configure(1, { sort = "topdown", parallax = 0.5 })
tecs.gfx.layers.configure(2, { sort = "topdown" })
tecs.gfx.layers.configure(8, { sort = "z", screenSpace = true, unlit = true })
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

What a device's depth target holds is the other half of that comparison, and
[`Renderer:depthSortCollapse`](/modules/gfx/#tecs.gfx.Renderer.depthSortCollapse) is what makes the two
answerable: it
reports the world units that collapse onto one depth value there, which is the factor `maxY` and `maxZ`
divide by to resolve the sort again.

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
the [Renderer](/modules/gfx/). Zero, the default, means no clipping, and a world that clips nothing
pays for it exactly nowhere.

The rectangle is in target pixels and is tested against the fragment's own position, which is what a
scrollable list inside a panel means and is right for world contents and screen-space layers alike. It is
not a world rectangle, so it does not move with the camera.

Regions do not nest. A region is one rectangle, so a panel inside a panel is set up as the intersection of
the two and the fragment tests once. `Renderer:clearClipRegion` puts a region back to clipping nothing
rather than to clipping everything out, so an index handed out and taken back leaves instances still
pointing at it drawing whole instead of silently vanishing.

The cull knows nothing about regions. An instance entirely outside its region is still drawn and then
thrown away a fragment at a time, which is correct and wasteful; keeping a clipped thing off screen is
worth doing with a layer or a position rather than with a large region.
<!-- @generated by docs/scripts/reference.py from src/tecs/gfx/layers.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/gfx/layers.tl`.

<a id="tecs.gfx.layers.Config"></a>

### tecs.gfx.layers.Config

<pre><code v-pre>record <a href="#tecs.gfx.layers.Config">tecs.gfx.layers.Config</a>
</code></pre>

Everything a layer decides about its contents. A field left out takes
its default, so this says what a layer is rather than amending what it
was.
<a id="tecs.gfx.layers.Config.sort"></a>

### tecs.gfx.layers.Config.sort

<pre><code v-pre><a href="#tecs.gfx.layers.Config.sort">tecs.gfx.layers.Config.sort</a>: <a href="#tecs.gfx.layers.Sort">Sort</a>
</code></pre>

How contents sort within the layer's band. Required: a sort is the
one thing every layer has an opinion about.
<a id="tecs.gfx.layers.Config.screenSpace"></a>

### tecs.gfx.layers.Config.screenSpace

<pre><code v-pre><a href="#tecs.gfx.layers.Config.screenSpace">tecs.gfx.layers.Config.screenSpace</a>: boolean
</code></pre>

Contents are positioned in screen pixels and ignore the camera
entirely. What a HUD wants. Defaults to false.
<a id="tecs.gfx.layers.Config.ignoreZoom"></a>

### tecs.gfx.layers.Config.ignoreZoom

<pre><code v-pre><a href="#tecs.gfx.layers.Config.ignoreZoom">tecs.gfx.layers.Config.ignoreZoom</a>: boolean
</code></pre>

Contents follow the camera's position but not its zoom, so they
stay a constant size on screen while moving with the world.
Defaults to false.
<a id="tecs.gfx.layers.Config.virtualCoords"></a>

### tecs.gfx.layers.Config.virtualCoords

<pre><code v-pre><a href="#tecs.gfx.layers.Config.virtualCoords">tecs.gfx.layers.Config.virtualCoords</a>: boolean
</code></pre>

Contents are positioned in `virtualWidth` by `virtualHeight`, which
is scaled to fill the target. Defaults to false, and cannot be
combined with `screenSpace`.
<a id="tecs.gfx.layers.Config.unlit"></a>

### tecs.gfx.layers.Config.unlit

<pre><code v-pre><a href="#tecs.gfx.layers.Config.unlit">tecs.gfx.layers.Config.unlit</a>: boolean
</code></pre>

Contents bypass the lighting pass and appear at their own colour.
Defaults to false. A material can ask for the same thing, and a
fragment is lit only where the material and the layer agree.
<a id="tecs.gfx.layers.Config.parallax"></a>

### tecs.gfx.layers.Config.parallax

<pre><code v-pre><a href="#tecs.gfx.layers.Config.parallax">tecs.gfx.layers.Config.parallax</a>: number
</code></pre>

How much the camera's position carries the contents. One moves them
with the world; a half drifts them at half speed, which is what a
background wants. Defaults to one.
<a id="tecs.gfx.layers.MAX"></a>

### tecs.gfx.layers.MAX

<pre><code v-pre><a href="#tecs.gfx.layers.MAX">tecs.gfx.layers.MAX</a>: integer
</code></pre>

Bands the depth range divides into.

Load-bearing at sixteen. A sort mode packs into two bits, the table the
vertex shader reads is sized to it, and the shader recovers a layer by
multiplying a depth by it. `LAYER_BANDS` in
`assets/shaders/instance.vert.glsl` is the same number, and the two only
work while they agree. Raising it is not a constant change.
<a id="tecs.gfx.layers.Sort"></a>

### tecs.gfx.layers.Sort

<pre><code v-pre>enum <a href="#tecs.gfx.layers.Sort">tecs.gfx.layers.Sort</a>
</code></pre>

<a id="tecs.gfx.layers.Sort.&quot;isometric&quot;"></a>

### tecs.gfx.layers.Sort.&quot;isometric&quot;

X plus Y plus z, for a diamond grid where both axes move an entity
towards the viewer.
<a id="tecs.gfx.layers.Sort.&quot;topdown&quot;"></a>

### tecs.gfx.layers.Sort.&quot;topdown&quot;

Lower on the screen draws in front, with z breaking ties. What a
top-down or side-on game wants: a character below a crate is in
front of it.
<a id="tecs.gfx.layers.Sort.&quot;z&quot;"></a>

### tecs.gfx.layers.Sort.&quot;z&quot;

Only z decides. What a HUD wants, where position means nothing and
the author has said what covers what.
<a id="tecs.gfx.layers.configure"></a>

### tecs.gfx.layers.configure

<pre><code v-pre>function <a href="#tecs.gfx.layers.configure">tecs.gfx.layers.configure</a>(layer: integer, config: layers.Config)
</code></pre>

Sets what a layer does with its contents.

Replaces the layer's configuration rather than amending it: a `Config`
is the whole of what a layer is, so a field left out is that field's
default and not whatever the layer held before.

#### Parameters

| Type                             | Name                      | Description                                                                                          |
| -------------------------------- | ------------------------- | ---------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code>       | <code v-pre>layer</code>  | One to `MAX`. Anything else raises.                                                                  |
| <code v-pre>layers.Config</code> | <code v-pre>config</code> | Raises on a missing or unknown `sort`, and on asking for `screenSpace` and `virtualCoords` together. |

<a id="tecs.gfx.layers.depthOf"></a>

### tecs.gfx.layers.depthOf

<pre><code v-pre>function <a href="#tecs.gfx.layers.depthOf">tecs.gfx.layers.depthOf</a>(layer: integer, z: number, x: number, y: number): number
</code></pre>

Depth for one entity, in zero to one with zero nearest.

Exact ties carry no tie-breaker. Instances are drawn in index order and
the depth test lets an equal fragment through, so two entities at the
same depth already resolve the same way every frame: the later one wins.
Nudging depth by identity would resolve them the other way, since a
larger value is farther, and quietly invert the order a scene was built
expecting.

#### Parameters

| Type                       | Name                     | Description                                                                                                                                                                                                                            |
| -------------------------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | <code v-pre>layer</code> | One to `MAX`, which picks the band and, through `sortOf`, what the rest of the arguments mean. Outside that range this takes the nearest layer whole and goes on sorting within it, because a band is the only thing a depth can name. |
| <code v-pre>number</code>  | <code v-pre>z</code>     | Height in the sort, against `maxZ`. Read by every sort mode.                                                                                                                                                                           |
| <code v-pre>number</code>  | <code v-pre>x</code>     | World x, read only by the isometric sort, against `maxY`.                                                                                                                                                                              |
| <code v-pre>number</code>  | <code v-pre>y</code>     | World y, read by the topdown and isometric sorts, against `maxY`. Larger is lower on screen and so nearer.                                                                                                                             |

#### Returns

| Type                      | Description                                                                                                                                                                                                                                     |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>number</code> | A depth inside the layer's own band, whatever the arguments were: each of them is normalised and then held to zero and one, so a scene reaching past what the module was told to expect stops sorting rather than spilling into the next layer. |

<a id="tecs.gfx.layers.depthResolution"></a>

### tecs.gfx.layers.depthResolution

<pre><code v-pre>function <a href="#tecs.gfx.layers.depthResolution">tecs.gfx.layers.depthResolution</a>(): number
</code></pre>

The smallest depth difference `depthOf` produces between two entities
one unit apart, taken over every sort mode.

What a depth buffer has to hold. A format whose own step is larger than
this keeps the bands, so layer order is never at risk, and loses the
sort inside them: the two entities land on one depth value and draw in
the order they were written rather than the order they were sorted
into.

Every mode is counted rather than the one a scene is using, because
`configure` may put any layer on any sort at any point after the depth
target exists. Derived from `MAX`, `maxZ` and `maxY`, so raising an
extent moves this with it.

#### Returns

| Type                      | Description                                                                                                                                                           |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>number</code> | A depth difference, in the input that moves depth least. That is the topdown sort's y at the defaults, which spends the smallest share of a band on the widest range. |

<a id="tecs.gfx.layers.entryOf"></a>

### tecs.gfx.layers.entryOf

<pre><code v-pre>function <a href="#tecs.gfx.layers.entryOf">tecs.gfx.layers.entryOf</a>(layer: integer): number, number, number, number
</code></pre>

The four floats the vertex shader reads for one layer: its mode, its
parallax offset factor, whether it ignores zoom, and whether it is lit.

Handed over as a group because they are packed as a group, which happens
when `revision` moves rather than every frame.

#### Parameters

| Type                       | Name                     | Description                                                                              |
| -------------------------- | ------------------------ | ---------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | <code v-pre>layer</code> | One to `MAX`. Outside that every return is nil, since only that range is ever filled in. |

#### Returns

| Type                      | Description                                                                                                                 |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>number</code> | The positioning mode, then the camera position's multiplier, then one when the layer ignores zoom, then one when it is lit. |
| <code v-pre>number</code> |                                                                                                                             |
| <code v-pre>number</code> |                                                                                                                             |
| <code v-pre>number</code> |                                                                                                                             |

<a id="tecs.gfx.layers.maxY"></a>

### tecs.gfx.layers.maxY

<pre><code v-pre><a href="#tecs.gfx.layers.maxY">tecs.gfx.layers.maxY</a>: number
</code></pre>

Half the world extent a scene is expected to occupy, for normalising
position into a band. A scene larger than this still sorts, with
entities beyond the edge compressed against it.
<a id="tecs.gfx.layers.maxZ"></a>

### tecs.gfx.layers.maxZ

<pre><code v-pre><a href="#tecs.gfx.layers.maxZ">tecs.gfx.layers.maxZ</a>: number
</code></pre>

Highest z a scene is expected to use, which sets the resolution of
sorting within a band. A scene reaching past this still draws, with
entities beyond the edge resting on it and no longer sorting against
each other.
<a id="tecs.gfx.layers.revision"></a>

### tecs.gfx.layers.revision

<pre><code v-pre>function <a href="#tecs.gfx.layers.revision">tecs.gfx.layers.revision</a>(): integer
</code></pre>

How many times the table has been configured.

#### Returns

| Type                       | Description                                                                                                                                                  |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>integer</code> | A count that starts at zero and only rises. A consumer compares it against the value it packed at, so the number itself means nothing beyond having changed. |

<a id="tecs.gfx.layers.sortOf"></a>

### tecs.gfx.layers.sortOf

<pre><code v-pre>function <a href="#tecs.gfx.layers.sortOf">tecs.gfx.layers.sortOf</a>(layer: integer): integer
</code></pre>

How a layer sorts, as the identifier `depthOf` takes.

#### Parameters

| Type                       | Name                     | Description                                                                                                         |
| -------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | <code v-pre>layer</code> | One to `MAX`. Outside that this answers topdown rather than raising, since it is the default every layer starts on. |

#### Returns

| Type                       | Description                                                                         |
| -------------------------- | ----------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | The sort identifier, which is an internal number and not one of the `Sort` strings. |

<a id="tecs.gfx.layers.viewCulled"></a>

### tecs.gfx.layers.viewCulled

<pre><code v-pre>function <a href="#tecs.gfx.layers.viewCulled">tecs.gfx.layers.viewCulled</a>(layer: integer): boolean
</code></pre>

Whether the camera's view rectangle decides if this layer is drawn.

False on a layer the camera does not place where its world bound says:
screen-space and virtual-coordinate contents have no world position for
the view to test, and parallax and ignore-zoom draw them somewhere the
bound does not describe. Extraction reads this per row and writes a
bound no view can be outside of for those, so the layer is drawn
whatever the camera is looking at. Culling is given up on a layer that
asks for one of these, and kept exactly on every layer that does not.

#### Parameters

| Type                       | Name                     | Description                                                                                    |
| -------------------------- | ------------------------ | ---------------------------------------------------------------------------------------------- |
| <code v-pre>integer</code> | <code v-pre>layer</code> | One to `MAX`. Outside that this answers true, which is what an unconfigured layer answers too. |

#### Returns

| Type                       | Description                                                  |
| -------------------------- | ------------------------------------------------------------ |
| <code v-pre>boolean</code> | Whether extraction should write this row's real world bound. |

<a id="tecs.gfx.layers.virtualHeight"></a>

### tecs.gfx.layers.virtualHeight

<pre><code v-pre><a href="#tecs.gfx.layers.virtualHeight">tecs.gfx.layers.virtualHeight</a>: number
</code></pre>

<a id="tecs.gfx.layers.virtualWidth"></a>

### tecs.gfx.layers.virtualWidth

<pre><code v-pre><a href="#tecs.gfx.layers.virtualWidth">tecs.gfx.layers.virtualWidth</a>: number
</code></pre>

The resolution a virtual-coordinate layer is authored in.

One resolution for every such layer, because it is the design size a
layout is drawn against and a game has one of those. It is scaled to
fill the target, so the layout keeps its proportions within itself at
any window size and stretches with the window's aspect.
