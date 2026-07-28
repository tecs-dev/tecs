---
description: "The view: centre, zoom, rotation, the world-to-clip matrix, the view rectangle, and converting between screen and world"
outline: deep
---

# tecs.camera.Camera

A camera is what the view is looking at: a centre in world units, a zoom, a rotation, and a projection
mode. It is one type rather than a 2D camera and a 3D one, because the only thing that would differ
between them is how the matrix is built, and nothing reading the matrix, neither the vertex shader nor
the cull, cares which built it.

Position is the centre of the view rather than a corner, so a camera that has never been moved shows the
world origin in the middle of the window. The renderer centres a default camera on the first frame it
draws, so a scene that never mentions a camera behaves as though world coordinates were screen
coordinates. See [Renderer](/modules/renderer) for how a camera reaches a frame.

## Creating a camera

### create

Creates a camera. Everything defaults to an unrotated, unzoomed view at the world origin.

```teal
function Camera.create(options?: CameraOptions): Camera
```

**Parameters:**

- `options`: omit for the default view. No field is validated; the values are taken as given.

**Returns:** a camera whose fields are plain and meant to be assigned to directly, frame by frame.

**`CameraOptions` fields:**

| Field        | Type     | Default          | Description                                                                               |
| ------------ | -------- | ---------------- | ----------------------------------------------------------------------------------------- |
| `x`          | `number` | `0`              | Centre of the view in world units.                                                        |
| `y`          | `number` | `0`              | Centre of the view in world units.                                                        |
| `zoom`       | `number` | `1`              | Above one magnifies. Zero or less is not rejected.                                        |
| `rotation`   | `number` | `0`              | Radians.                                                                                  |
| `projection` | `string` | `"orthographic"` | Any string is accepted and stored; the projection built is orthographic whatever it says. |

**Example:**

```teal
local camera <const> = tecs.camera.Camera.create({ x = 400, y = 300, zoom = 2 })
```

## Fields

Every field is plain and assignable. A game moves a camera by writing to it, once per frame if it likes.

| Field        | Type     | Description                                                                                                                                                                                                             |
| ------------ | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `x`          | `number` | Centre of the view, in world units.                                                                                                                                                                                     |
| `y`          | `number` | Centre of the view, in world units.                                                                                                                                                                                     |
| `zoom`       | `number` | Above one magnifies. Applied about the centre, so zooming does not move what is under the middle of the window.                                                                                                         |
| `rotation`   | `number` | Radians. Positive turns the scene counter-clockwise on screen, which is the camera itself turning the other way: at a quarter turn, a point at +X from the camera in the world is drawn above the centre of the window. |
| `projection` | `string` | `"orthographic"` today. Nothing reads it yet, so setting anything else changes what the camera reports about itself and not what it draws.                                                                              |

The `projection` field exists so a perspective mode can be added without a second camera type, which is
the whole reason there is a mode rather than a name.

```teal
camera.x = player.x
camera.y = player.y
camera.zoom = camera.zoom * 1.01
```

## The viewport size is passed, never stored

Every method takes the viewport's width and height rather than the camera holding them, because a camera
outlives a window size and the pair a call is answered against has to be the pair the frame is being
drawn at.

::: warning
Passing one size to `matrix` and another to `toWorld` produces two mappings that do not invert. Use the
same width and height for every call about the same frame.
:::

## The Y flip

World Y runs down from the top left while clip Y runs up. The flip lives in this module and only here,
and the three things that have to agree about it are the matrix, `toScreen` and `toWorld`. They agree by
all deriving from the same negated Y scale, written out in each rather than shared, so a change to one
of them is visibly a change the other two have not had.

## Methods

### matrix

Writes the world-to-clip matrix for a viewport of `width` by `height`.

```teal
function Camera:matrix(width: number, height: number): loader.CArray
```

**Parameters:**

- `width`: viewport width in pixels.
- `height`: viewport height in pixels.

**Returns:** the camera's own sixteen-float array, rewritten in place.

The matrix is column major, because that is how a GLSL `mat4` reads a uniform: the first four floats are
the first column, not the first row. Transposing these is a mistake that renders something plausible
rather than nothing, which is how it survives review.

Z passes through untouched and W stays one: depth is written by the vertex shader from the layer band
rather than projected from world space. See [layers](/modules/layers).

::: warning
The array is valid until the next call on this camera. A caller that needs to keep it copies it rather
than holding the pointer.
:::

### viewBounds

The world-space rectangle this camera can see.

```teal
function Camera:viewBounds(width: number, height: number): {number}
```

**Parameters:**

- `width`: viewport width in pixels.
- `height`: viewport height in pixels.

**Returns:** the camera's own four-element table, rewritten in place, as `minX`, `minY`, `maxX`, `maxY`.

Conservative when rotated: the corners of the rotated view are bounded by an axis-aligned box, so the
cull keeps a little more than it must. Keeping too much costs a few instances; keeping too little drops
geometry that should have drawn, which is why the error goes this way.

::: warning
The table is valid until the next call on this camera. A caller that needs to keep it copies it rather
than holding the table.
:::

**Example:**

```teal
local bounds <const> = camera:viewBounds(width, height)
local minX <const>, minY <const>, maxX <const>, maxY <const> =
    bounds[1], bounds[2], bounds[3], bounds[4]
```

### toWorld

Converts a screen point to world space.

```teal
function Camera:toWorld(screenX: number, screenY: number, width: number, height: number): number, number
```

**Parameters:**

- `screenX`: pixels from the left of the viewport.
- `screenY`: pixels from the top of the viewport, running down.
- `width`: viewport width in pixels, the same one the matrix was built with.
- `height`: viewport height in pixels, the same one the matrix was built with.

**Returns:** the world x, then the world y. Points outside the viewport convert too, and land outside the
view rectangle.

This is the inverse of what the matrix does, written out rather than inverted, so the Y flip appears once
here in the same place it appears in the matrix.

**Example:**

```teal
local worldX <const>, worldY <const> = camera:toWorld(mouseX, mouseY, width, height)
```

### toScreen

Converts a world point to screen space.

```teal
function Camera:toScreen(worldX: number, worldY: number, width: number, height: number): number, number
```

**Parameters:**

- `worldX`: world x.
- `worldY`: world y, running down.
- `width`: viewport width in pixels, the same one the matrix was built with.
- `height`: viewport height in pixels, the same one the matrix was built with.

**Returns:** the screen x in pixels from the left, then the screen y in pixels from the top. Neither is
clamped to the viewport.

Exactly the inverse of `toWorld` at the same width and height, and the same mapping the matrix applies,
so a point round-trips.

## What lighting does with the view

Lights are placed in world units like everything else, and the lighting pass is handed the view so
it can take each fragment back out to the world rather than bringing the lights in. Moving the camera
therefore moves what is lit, and zoom scales what a light's radius covers on screen rather than what
it covers in the world. A light needs no conversion and no projection of its own; see
[`PointLight`](/modules/components#pointlight).

## What the camera does not place

A layer can ask to be positioned in screen pixels, in a virtual resolution, at its own parallax, or
outside the camera's zoom. Contents of such a layer are not placed where the camera would put them, and
the cull gives up on them rather than testing a world bound that does not describe where they draw.
[layers](/modules/layers) has the rules.
<!-- @generated by docs/scripts/reference.py from src/tecs/gfx/Camera.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/gfx/Camera.tl`.

<a id="tecs.camera.Camera.create"></a>

### tecs.camera.Camera.create

<pre><code v-pre>function <a href="#tecs.camera.Camera.create">tecs.camera.Camera.create</a>(options: CameraOptions): Camera
</code></pre>

Creates a camera. Everything defaults to an unrotated, unzoomed view at
the world origin, which a renderer then recentres if the game never
moves it.

#### Parameters

| Type                             | Name                       | Description                                                                      |
| -------------------------------- | -------------------------- | -------------------------------------------------------------------------------- |
| <code v-pre>CameraOptions</code> | <code v-pre>options</code> | Omit for the default view. No field is validated; the values are taken as given. |

#### Returns

| Type                      | Description                                                                           |
| ------------------------- | ------------------------------------------------------------------------------------- |
| <code v-pre>Camera</code> | A camera whose fields are plain and meant to be assigned to directly, frame by frame. |

<a id="tecs.camera.Camera.matrix"></a>

### tecs.camera.Camera.matrix

<pre><code v-pre>function <a href="#tecs.camera.Camera.matrix">tecs.camera.Camera.matrix</a>(self: Camera, width: number, height: number): loader.CArray
</code></pre>

Writes the world-to-clip matrix for a viewport of `width` by `height`.

Column major, because that is how a GLSL `mat4` reads a uniform: the
first four floats are the first column, not the first row. Transposing
these is a mistake that renders something plausible rather than nothing,
which is how it survives review.

#### Parameters

| Type                      | Name                      | Description                |
| ------------------------- | ------------------------- | -------------------------- |
| <code v-pre>Camera</code> | <code v-pre>self</code>   |                            |
| <code v-pre>number</code> | <code v-pre>width</code>  | Viewport width in pixels.  |
| <code v-pre>number</code> | <code v-pre>height</code> | Viewport height in pixels. |

#### Returns

| Type                             | Description                                                                                                                                                                            |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>loader.CArray</code> | The camera's own sixteen-float array, rewritten in place. It is valid until the next call on this camera, so a caller that needs to keep it copies it rather than holding the pointer. |

<a id="tecs.camera.Camera.projection"></a>

### tecs.camera.Camera.projection

<pre><code v-pre><a href="#tecs.camera.Camera.projection">tecs.camera.Camera.projection</a>: string
</code></pre>

"orthographic" today. The field exists so a perspective mode can be
added without a second camera type, which is the whole reason there is
a mode rather than a name. Nothing reads it yet, so setting anything
else changes what the camera reports about itself and not what it draws.
<a id="tecs.camera.Camera.rotation"></a>

### tecs.camera.Camera.rotation

<pre><code v-pre><a href="#tecs.camera.Camera.rotation">tecs.camera.Camera.rotation</a>: number
</code></pre>

Radians. Positive turns the scene counter-clockwise on screen, which is
the camera itself turning the other way: at a quarter turn, a point at
+X from the camera in the world is drawn above the centre of the window.
<a id="tecs.camera.Camera.toScreen"></a>

### tecs.camera.Camera.toScreen

<pre><code v-pre>function <a href="#tecs.camera.Camera.toScreen">tecs.camera.Camera.toScreen</a>(self: Camera, worldX: number, worldY: number, width: number, height: number): number, number
</code></pre>

Converts a world point to screen space.

Exactly the inverse of `toWorld` at the same width and height, and the
same mapping the matrix applies, so a point round-trips.

#### Parameters

| Type                      | Name                      | Description                                                        |
| ------------------------- | ------------------------- | ------------------------------------------------------------------ |
| <code v-pre>Camera</code> | <code v-pre>self</code>   |                                                                    |
| <code v-pre>number</code> | <code v-pre>worldX</code> | World x.                                                           |
| <code v-pre>number</code> | <code v-pre>worldY</code> | World y, running down.                                             |
| <code v-pre>number</code> | <code v-pre>width</code>  | Viewport width in pixels, the same one the matrix was built with.  |
| <code v-pre>number</code> | <code v-pre>height</code> | Viewport height in pixels, the same one the matrix was built with. |

#### Returns

| Type                      | Description                                                                                                         |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>number</code> | The screen x in pixels from the left, then the screen y in pixels from the top. Neither is clamped to the viewport. |
| <code v-pre>number</code> |                                                                                                                     |

<a id="tecs.camera.Camera.toWorld"></a>

### tecs.camera.Camera.toWorld

<pre><code v-pre>function <a href="#tecs.camera.Camera.toWorld">tecs.camera.Camera.toWorld</a>(self: Camera, screenX: number, screenY: number, width: number, height: number): number, number
</code></pre>

Converts a screen point to world space.

The inverse of what the matrix does, written out rather than inverted,
so the Y flip appears once here in the same place it appears above.

#### Parameters

| Type                      | Name                       | Description                                                        |
| ------------------------- | -------------------------- | ------------------------------------------------------------------ |
| <code v-pre>Camera</code> | <code v-pre>self</code>    |                                                                    |
| <code v-pre>number</code> | <code v-pre>screenX</code> | Pixels from the left of the viewport.                              |
| <code v-pre>number</code> | <code v-pre>screenY</code> | Pixels from the top of the viewport, running down.                 |
| <code v-pre>number</code> | <code v-pre>width</code>   | Viewport width in pixels, the same one the matrix was built with.  |
| <code v-pre>number</code> | <code v-pre>height</code>  | Viewport height in pixels, the same one the matrix was built with. |

#### Returns

| Type                      | Description                                                                                                  |
| ------------------------- | ------------------------------------------------------------------------------------------------------------ |
| <code v-pre>number</code> | The world x, then the world y. Points outside the viewport convert too, and land outside the view rectangle. |
| <code v-pre>number</code> |                                                                                                              |

<a id="tecs.camera.Camera.viewBounds"></a>

### tecs.camera.Camera.viewBounds

<pre><code v-pre>function <a href="#tecs.camera.Camera.viewBounds">tecs.camera.Camera.viewBounds</a>(self: Camera, width: number, height: number): {number}
</code></pre>

The world-space rectangle this camera can see, as minX, minY, maxX,
maxY.

Conservative when rotated: the corners of the rotated view are bounded
by an axis-aligned box, so the cull keeps a little more than it must.
Keeping too much costs a few instances; keeping too little drops
geometry that should have drawn, which is why the error goes this way.

#### Parameters

| Type                      | Name                      | Description                |
| ------------------------- | ------------------------- | -------------------------- |
| <code v-pre>Camera</code> | <code v-pre>self</code>   |                            |
| <code v-pre>number</code> | <code v-pre>width</code>  | Viewport width in pixels.  |
| <code v-pre>number</code> | <code v-pre>height</code> | Viewport height in pixels. |

#### Returns

| Type                        | Description                                                                                                                                                                         |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{number}</code> | The camera's own four-element table, rewritten in place. It is valid until the next call on this camera, so a caller that needs to keep it copies it rather than holding the table. |

<a id="tecs.camera.Camera.x"></a>

### tecs.camera.Camera.x

<pre><code v-pre><a href="#tecs.camera.Camera.x">tecs.camera.Camera.x</a>: number
</code></pre>

Centre of the view, in world units.
<a id="tecs.camera.Camera.y"></a>

### tecs.camera.Camera.y

<pre><code v-pre><a href="#tecs.camera.Camera.y">tecs.camera.Camera.y</a>: number
</code></pre>

The other half of it, running down: increasing y moves the view towards
the bottom of the world.
<a id="tecs.camera.Camera.zoom"></a>

### tecs.camera.Camera.zoom

<pre><code v-pre><a href="#tecs.camera.Camera.zoom">tecs.camera.Camera.zoom</a>: number
</code></pre>

Above one magnifies. Applied about the centre, so zooming does not move
what is under the middle of the window.
