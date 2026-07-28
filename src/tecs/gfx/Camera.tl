--- What the view is looking at.
---
--- One type with a projection mode rather than a 2D camera and a 3D one. The
--- only thing that differs between them is how the matrix is built; everything
--- reading it, the vertex shader and the cull, does not care.
---
--- Position is the centre of the view rather than a corner, so a camera that
--- has never been moved shows the world origin in the middle of the window. A
--- renderer with no camera set centres a default on the first frame it draws,
--- so a scene that never mentions a camera behaves as though world coordinates
--- were screen coordinates.
---
--- The Y flip lives here and only here. World Y runs down from the top-left
--- while clip Y runs up, and the three things that have to agree about it are
--- the matrix, `toScreen` and `toWorld`. They agree by all deriving from the
--- same negated Y scale, written out in each rather than shared, so a change to
--- one of them is visibly a change the other two have not had.
---
--- Every method takes the viewport's width and height rather than storing them,
--- because a camera outlives a window size and the pair a call is answered
--- against has to be the pair the frame is being drawn at. Passing one size to
--- `matrix` and another to `toWorld` produces two mappings that do not invert.

local loader <const> = require("tecs.ffi.loader")

local sin <const>, cos <const> = math.sin, math.cos

--- What a camera is created with. Every field is optional.
local record CameraOptions
    --- Centre of the view, in world units. Both default to zero.
    x: number
    y: number
    --- Defaults to one. Zero or less divides through in every method here and
    --- is not rejected.
    zoom: number
    --- Defaults to zero.
    rotation: number
    --- Defaults to "orthographic", and nothing else is implemented. Any string
    --- is accepted and stored, and `matrix` builds an orthographic projection
    --- whatever it says.
    projection: string
end

local record Camera
    --- Centre of the view, in world units.
    x: number
    y: number
    --- Above one magnifies. Applied about the centre, so zooming does not move
    --- what is under the middle of the window.
    zoom: number
    --- Radians. Positive turns the scene counter-clockwise on screen, which is
    --- the camera itself turning the other way: at a quarter turn, a point at
    --- +X from the camera in the world is drawn above the centre of the window.
    rotation: number
    --- "orthographic" today. The field exists so a perspective mode can be
    --- added without a second camera type, which is the whole reason there is
    --- a mode rather than a name. Nothing reads it yet, so setting anything
    --- else changes what the camera reports about itself and not what it draws.
    projection: string

    _matrix: loader.CArray
    _view: {number}

    --- Creates a camera. Everything defaults to an unrotated, unzoomed view at
    --- the world origin, which a renderer then recentres if the game never
    --- moves it.
    --- @param options Omit for the default view. No field is validated; the
    ---     values are taken as given.
    --- @return A camera whose fields are plain and meant to be assigned to
    ---     directly, frame by frame.
    create: function(options?: CameraOptions): Camera

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

    --- The world-space rectangle this camera can see, as minX, minY, maxX,
    --- maxY.
    ---
    --- Conservative when rotated: the corners of the rotated view are bounded
    --- by an axis-aligned box, so the cull keeps a little more than it must.
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
    --- @return The screen x in pixels from the left, then the screen y in
    ---     pixels from the top. Neither is clamped to the viewport.
    toScreen: function(self, worldX: number, worldY: number, width: number, height: number): number, number
end

local CameraMT <const>: metatable<Camera> = {__index = Camera}

function Camera.create(options?: CameraOptions): Camera
    options = options or {}
    local self = setmetatable({} as Camera, CameraMT)
    self.x = options.x or 0.0
    self.y = options.y or 0.0
    self.zoom = options.zoom or 1.0
    self.rotation = options.rotation or 0.0
    self.projection = options.projection or "orthographic"
    -- Reused rather than allocated per frame: this is written every frame and
    -- read straight into a uniform.
    self._matrix = loader.newArray("float[16]")
    self._view = {0.0, 0.0, 0.0, 0.0}
    return self
end

function Camera:matrix(width: number, height: number): loader.CArray
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
    -- Translation is the transformed camera position, negated, so the centre
    -- of the view lands at the centre of clip space.
    m[12] = -(m00 * self.x + m01 * self.y)
    m[13] = -(m10 * self.x + m11 * self.y)

    return m
end

function Camera:viewBounds(width: number, height: number): {number}
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

function Camera:toWorld(screenX: number, screenY: number, width: number, height: number): number, number
    local dx = (screenX - width * 0.5) / self.zoom
    local dy = (screenY - height * 0.5) / self.zoom

    local c = cos(self.rotation)
    local s = sin(self.rotation)
    return self.x + dx * c - dy * s, self.y + dx * s + dy * c
end

function Camera:toScreen(worldX: number, worldY: number, width: number, height: number): number, number
    local dx = worldX - self.x
    local dy = worldY - self.y

    local c = cos(self.rotation)
    local s = sin(self.rotation)
    local rx = dx * c + dy * s
    local ry = -dx * s + dy * c
    return width * 0.5 + rx * self.zoom, height * 0.5 + ry * self.zoom
end

return Camera
