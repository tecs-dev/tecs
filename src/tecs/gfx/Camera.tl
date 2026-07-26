--- What the view is looking at.
---
--- One type with a projection mode rather than a 2D camera and a 3D one. The
--- only thing that differs between them is how the matrix is built; everything
--- reading it, the vertex shader and the cull, does not care.
---
--- Position is the centre of the view, matching how a camera is normally
--- described and how the engine this replaces describes one. A renderer with
--- no camera set centres a default on the first frame it draws, so a scene
--- that never mentions a camera behaves as though world coordinates were
--- screen coordinates.
---
--- The Y flip lives here and only here. World Y runs down from the top-left
--- while clip Y runs up, and the two disagreeing in more than one place is a
--- mistake this codebase has made before: a camera, a screen-space conversion
--- and a mask's texture coordinates all have to agree, and they only can if one
--- of them decides.

local loader <const> = require("tecs.ffi.loader")

local sin <const>, cos <const> = math.sin, math.cos

local record Camera
    --- Centre of the view, in world units.
    x: number
    y: number
    --- Above one magnifies. Applied about the centre.
    zoom: number
    --- Radians, counter-clockwise on screen.
    rotation: number
    --- "orthographic" today. The field exists so a perspective mode can be
    --- added without a second camera type, which is the whole reason there is
    --- a mode rather than a name.
    projection: string

    _matrix: loader.CArray
    _view: {number}
end

local CameraMT <const>: metatable<Camera> = { __index = Camera }

local record CameraOptions
    x: number
    y: number
    zoom: number
    rotation: number
    projection: string
end

--- Creates a camera. Everything defaults to an unrotated, unzoomed view at the
--- world origin, which a renderer then recentres if the game never moves it.
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
    self._view = { 0.0, 0.0, 0.0, 0.0 }
    return self
end

--- Writes the world-to-clip matrix for a viewport of `width` by `height`.
---
--- Column major, because that is how a GLSL `mat4` reads a uniform: the first
--- four floats are the first column, not the first row. Transposing these is a
--- mistake that renders something plausible rather than nothing, which is how
--- it survives review.
function Camera:matrix(width: number, height: number): loader.CArray
    local m = self._matrix

    -- Scale to clip space, with Y negated because world Y runs down.
    local sx = 2.0 * self.zoom / width
    local sy = -2.0 * self.zoom / height

    local c = cos(self.rotation)
    local s = sin(self.rotation)

    -- Rotating the world by -rotation is what turns the camera by +rotation.
    local m00 = sx * c
    local m01 = sx * s
    local m10 = -sy * s
    local m11 = sy * c

    for index = 0, 15 do m[index] = 0.0 end
    m[0] = m00
    m[1] = m10
    m[4] = m01
    m[5] = m11
    m[10] = 1.0
    m[15] = 1.0
    -- Translation is the transformed camera position, negated, so the centre
    -- of the view lands at the centre of clip space.
    m[12] = -(m00 * self.x + m01 * self.y)
    m[13] = -(m10 * self.x + m11 * self.y)

    return m
end

--- The world-space rectangle this camera can see, as minX, minY, maxX, maxY.
---
--- Conservative when rotated: the corners of the rotated view are bounded by an
--- axis-aligned box, so the cull keeps a little more than it must. Keeping too
--- much costs a few instances; keeping too little drops geometry that should
--- have drawn, which is why the error goes this way.
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

--- Converts a screen point to world space.
---
--- The inverse of what the matrix does, written out rather than inverted, so
--- the Y flip appears once here in the same place it appears above.
function Camera:toWorld(screenX: number, screenY: number,
                        width: number, height: number): number, number
    local dx = (screenX - width * 0.5) / self.zoom
    local dy = (screenY - height * 0.5) / self.zoom

    local c = cos(self.rotation)
    local s = sin(self.rotation)
    return self.x + dx * c - dy * s, self.y + dx * s + dy * c
end

--- Converts a world point to screen space.
function Camera:toScreen(worldX: number, worldY: number,
                         width: number, height: number): number, number
    local dx = worldX - self.x
    local dy = worldY - self.y

    local c = cos(self.rotation)
    local s = sin(self.rotation)
    local rx = dx * c + dy * s
    local ry = -dx * s + dy * c
    return width * 0.5 + rx * self.zoom, height * 0.5 + ry * self.zoom
end

return Camera
