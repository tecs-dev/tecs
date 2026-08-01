--[=[
A camera maps world coordinates to one viewport.

The camera stores the view center in world units, zoom, and rotation. Callers
write these fields directly:

```teal
local camera <const> = app.renderer.sprites.camera
camera.x = player.x
camera.y = player.y
camera.zoom = 2
camera.rotation = 0
```

Position names the center rather than a corner. The default view starts at the
world origin. World Y and screen Y both increase downward.

## Coordinate conversion

Each conversion takes the viewport dimensions because one camera can serve
targets of different sizes:

```teal
local worldX <const>, worldY <const> =
    camera:toWorld(mouseX, mouseY, width, height)

local screenX <const>, screenY <const> =
    camera:toScreen(worldX, worldY, width, height)
```

Use the same dimensions for conversion and rendering. `toWorld`, `toScreen`,
and `matrix` then share one mapping, and points round-trip. `viewBounds`
returns a conservative axis-aligned world rectangle when the camera rotates.

`matrix` reuses the camera's sixteen-float array, and `viewBounds` reuses its
four-element table. Copy either result before retaining it across another call.
]=]
-- Implementation details:
-- The world-to-clip matrix owns the only Y flip. `matrix`, `toScreen`, and
-- `toWorld` each spell out the same negated scale so a mismatch stays visible
-- in review. The renderer and cull consume the same camera type regardless of
-- projection.

local loader <const> = require("tecs.ffi.loader")

local sin <const>, cos <const> = math.sin, math.cos

--- Defines optional camera construction values.
local record Camera2DOptions
    --- Caller-writable. Sets the center of the view in world units. Both
    --- values default to zero.
    x: number
    --- Caller-writable. Sets the center of the view in world units. Both
    --- values default to zero.
    y: number
    --- Caller-writable. Sets the zoom and defaults to one. Zero or less
    --- divides through in every method here and is not rejected.
    zoom: number
    --- Caller-writable. Sets the rotation in radians and defaults to zero.
    rotation: number
end

--- Represents a view onto the world.
---
--- Assign every field directly, frame by frame. A renderer copies the values it
--- draws from during extraction, so moving a camera afterwards affects the next
--- frame, not the one in flight.
local record Camera2D
    --- Names the options accepted by `newCamera2D` so a game can annotate the table it
    --- passes without reaching into this file.
    type Options = Camera2DOptions

    --- Caller-writable. Sets the horizontal center of the view in world units.
    x: number
    --- Caller-writable. Sets the vertical center of the view in world units.
    --- Increasing y moves the view towards the bottom of the world.
    y: number
    --- Caller-writable. Sets the zoom. Values above one magnify about the
    --- center without moving the point under the middle of the window.
    zoom: number
    --- Caller-writable. Sets the rotation in radians. Positive values turn the
    --- scene counter-clockwise on screen.
    rotation: number
    --- Engine-owned. Stores the sixteen floats that `matrix` rewrites.
    --- Ordinary game code should ignore this field.
    _matrix: loader.CArray
    --- Engine-owned. Stores the four numbers that `viewBounds` rewrites.
    --- Ordinary game code should ignore this field.
    _view: {number}

    --- Creates a camera. Everything defaults to an unrotated, unzoomed view at
    --- the world origin, which a renderer then recenters if the game never
    --- moves it.
    --- @param options Omit for the default view. The constructor stores every
    ---     value without validation.
    --- @return Returns a camera whose fields the caller assigns directly.
    newCamera2D: function(options?: Camera2DOptions): Camera2D

    --- Writes the world-to-clip matrix for a viewport of `width` by `height`.
    ---
    --- Column major, because that is how a GLSL `mat4` reads a uniform: the
    --- first four floats are the first column, not the first row. Transposing
    --- these is a mistake that renders something plausible rather than nothing,
    --- which is how it survives review.
    --- @param width Viewport width in pixels.
    --- @param height Viewport height in pixels.
    --- @return The camera's own sixteen-float array, rewritten in place. It is
    ---     valid until the next call on this camera, so a caller that needs to
    ---     keep it copies it rather than holding the pointer.
    matrix: function(self, width: number, height: number): loader.CArray

    --- Returns the world-space rectangle this camera can see as minX, minY,
    --- maxX, and maxY.
    ---
    --- When rotated, an axis-aligned box encloses the view's corners, so culling
    --- keeps a little more than it must.
    --- Keeping too much costs a few instances; keeping too little drops
    --- geometry that should have drawn, which is why the error goes this way.
    --- @param width Viewport width in pixels.
    --- @param height Viewport height in pixels.
    --- @return The camera's own four-element table, rewritten in place. It is
    ---     valid until the next call on this camera, so a caller that needs to
    ---     keep it copies it rather than holding the table.
    viewBounds: function(self, width: number, height: number): {number}

    --- Converts a screen point to world space.
    ---
    --- The inverse of what the matrix does, written out rather than inverted,
    --- so the Y flip appears once here in the same place it appears above.
    --- @param screenX Pixels from the left of the viewport.
    --- @param screenY Pixels from the top of the viewport, running down.
    --- @param width Viewport width in pixels, the same one the matrix was built
    ---     with.
    --- @param height Viewport height in pixels, the same one the matrix was
    ---     built with.
    --- @return The world x, then the world y. Points outside the viewport
    ---     convert too, and land outside the view rectangle.
    toWorld: function(self, screenX: number, screenY: number, width: number, height: number): number, number

    --- Converts a world point to screen space.
    ---
    --- Exactly the inverse of `toWorld` at the same width and height, and the
    --- same mapping the matrix applies, so a point round-trips.
    --- @param worldX World x.
    --- @param worldY World y, running down.
    --- @param width Viewport width in pixels, the same one the matrix was built
    ---     with.
    --- @param height Viewport height in pixels, the same one the matrix was
    ---     built with.
    --- @return Returns screen x from the left and screen y from the top, in
    ---     pixels. The function does not clamp either value to the viewport.
    toScreen: function(self, worldX: number, worldY: number, width: number, height: number): number, number
end

local CameraMT <const>: metatable<Camera2D> = {__index = Camera2D}

function Camera2D.newCamera2D(options?: Camera2DOptions): Camera2D
    options = options or {}
    local self = setmetatable({} as Camera2D, CameraMT)
    self.x = options.x or 0.0
    self.y = options.y or 0.0
    self.zoom = options.zoom or 1.0
    self.rotation = options.rotation or 0.0
    -- Reused rather than allocated per frame: this is written every frame and
    -- read straight into a uniform.
    self._matrix = loader.newArray("float[16]")
    self._view = {0.0, 0.0, 0.0, 0.0}
    return self
end

function Camera2D:matrix(width: number, height: number): loader.CArray
    local m = self._matrix

    -- Scale to clip space, with Y negated because world Y runs down.
    local sx = 2.0 * self.zoom / width
    local sy = -2.0 * self.zoom / height

    local c = cos(self.rotation)
    local s = sin(self.rotation)

    -- The transpose of the usual rotation, so world offsets are turned by
    -- -rotation before the Y negation above flips the result back. What comes
    -- out is the scene turning counter-clockwise on screen by +rotation.
    local m00 = sx * c
    local m01 = sx * s
    local m10 = -sy * s
    local m11 = sy * c

    for index = 0, 15 do
        m[index] = 0.0
    end
    m[0] = m00
    m[1] = m10
    m[4] = m01
    m[5] = m11
    -- Z passes through untouched and W stays one: depth is written by the
    -- vertex shader from the layer band rather than projected from world space.
    m[10] = 1.0
    m[15] = 1.0
    -- Translation is the transformed camera position, negated, so the center
    -- of the view lands at the center of clip space.
    m[12] = -(m00 * self.x + m01 * self.y)
    m[13] = -(m10 * self.x + m11 * self.y)

    return m
end

function Camera2D:viewBounds(width: number, height: number): {number}
    local halfWidth = width * 0.5 / self.zoom
    local halfHeight = height * 0.5 / self.zoom

    local c = math.abs(cos(self.rotation))
    local s = math.abs(sin(self.rotation))
    local extentX = halfWidth * c + halfHeight * s
    local extentY = halfWidth * s + halfHeight * c

    local view = self._view
    view[1] = self.x - extentX
    view[2] = self.y - extentY
    view[3] = self.x + extentX
    view[4] = self.y + extentY
    return view
end

function Camera2D:toWorld(screenX: number, screenY: number, width: number, height: number): number, number
    local dx = (screenX - width * 0.5) / self.zoom
    local dy = (screenY - height * 0.5) / self.zoom

    local c = cos(self.rotation)
    local s = sin(self.rotation)
    return self.x + dx * c - dy * s, self.y + dx * s + dy * c
end

function Camera2D:toScreen(worldX: number, worldY: number, width: number, height: number): number, number
    local dx = worldX - self.x
    local dy = worldY - self.y

    local c = cos(self.rotation)
    local s = sin(self.rotation)
    local rx = dx * c + dy * s
    local ry = -dx * s + dy * c
    return width * 0.5 + rx * self.zoom, height * 0.5 + ry * self.zoom
end

return Camera2D
