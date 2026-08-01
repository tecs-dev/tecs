--[=[
A perspective camera maps a right-handed 3D world to one viewport.

World +X points right, +Y points up, and the default camera looks along -Z.
The camera orientation is a quaternion in `(x, y, z, w)` order that turns
camera-local coordinates into world coordinates. Position and orientation are
caller-writable fields:

```teal
local camera <const> = tecs.gfx.newCamera3D({
    x = 0,
    y = 2,
    z = 6,
    verticalFov = math.rad(60),
})
camera.rotationY = math.sin(math.rad(15) * 0.5)
camera.rotationW = math.cos(math.rad(15) * 0.5)
```

`matrix` writes a column-major world-to-clip matrix with depth in `[0, 1]`.
It reuses one sixteen-float array, so copy the result before retaining it
across another call on the same camera.
]=]

local loader <const> = require("tecs.ffi.loader")

local sqrt <const>, tan <const> = math.sqrt, math.tan
local PI <const> = math.pi

--- Defines optional perspective-camera construction values.
local record Camera3DOptions
    --- Caller-writable. Sets the world-space x coordinate and defaults to zero.
    x: number
    --- Caller-writable. Sets the world-space y coordinate and defaults to zero.
    y: number
    --- Caller-writable. Sets the world-space z coordinate and defaults to zero.
    z: number
    --- Caller-writable. Sets the orientation quaternion x component and
    --- defaults to zero.
    rotationX: number
    --- Caller-writable. Sets the orientation quaternion y component and
    --- defaults to zero.
    rotationY: number
    --- Caller-writable. Sets the orientation quaternion z component and
    --- defaults to zero.
    rotationZ: number
    --- Caller-writable. Sets the orientation quaternion scalar component and
    --- defaults to one.
    rotationW: number
    --- Caller-writable. Sets the vertical field of view in radians and
    --- defaults to pi divided by three.
    verticalFov: number
    --- Caller-writable. Sets the positive near-plane distance and defaults to
    --- 0.1 world units.
    near: number
    --- Caller-writable. Sets the far-plane distance and defaults to 1000 world units.
    far: number
end

--- Represents one perspective view into a right-handed 3D world.
local record Camera3D
    --- Names the options accepted by `newCamera3D`.
    type Options = Camera3DOptions

    --- Caller-writable. Sets the world-space x coordinate.
    x: number
    --- Caller-writable. Sets the world-space y coordinate.
    y: number
    --- Caller-writable. Sets the world-space z coordinate.
    z: number
    --- Caller-writable. Sets the local-to-world orientation quaternion x
    --- component.
    rotationX: number
    --- Caller-writable. Sets the local-to-world orientation quaternion y
    --- component.
    rotationY: number
    --- Caller-writable. Sets the local-to-world orientation quaternion z
    --- component.
    rotationZ: number
    --- Caller-writable. Sets the local-to-world orientation quaternion scalar
    --- component.
    rotationW: number
    --- Caller-writable. Sets the vertical field of view in radians between
    --- zero and pi.
    verticalFov: number
    --- Caller-writable. Sets the positive near-plane distance.
    near: number
    --- Caller-writable. Sets the far-plane distance, which must exceed `near`.
    far: number
    --- Engine-owned. Stores the sixteen floats that `matrix` rewrites.
    --- Ordinary game code should ignore this field.
    _matrix: loader.CArray

    --- Creates a perspective camera.
    --- @param options Omit for an identity camera at the origin looking along negative z.
    --- @return A camera whose fields the caller assigns directly.
    newCamera3D: function(options?: Camera3DOptions): Camera3D

    --- Writes the column-major world-to-clip matrix for a viewport.
    ---
    --- The method normalizes the camera quaternion while calculating the view,
    --- without modifying the caller's fields. Clip depth maps `near` to zero
    --- and `far` to one.
    --- @param width The positive viewport width in pixels.
    --- @param height The positive viewport height in pixels.
    --- @return The camera's own sixteen-float array, valid until the next call
    ---     on this camera.
    matrix: function(self, width: number, height: number): loader.CArray
end

local Camera3DMT <const>: metatable<Camera3D> = {__index = Camera3D}

local function validateProjection(verticalFov: number, near: number, far: number)
    if verticalFov <= 0.0 or verticalFov >= PI then
        error("Camera3D verticalFov must be greater than 0 and less than pi", 3)
    end
    if near <= 0.0 then
        error("Camera3D near must be greater than 0", 3)
    end
    if far <= near then
        error("Camera3D far must be greater than near", 3)
    end
end

function Camera3D.newCamera3D(options?: Camera3DOptions): Camera3D
    options = options or {}
    local verticalFov <const> = options.verticalFov or PI / 3.0
    local near <const> = options.near or 0.1
    local far <const> = options.far or 1000.0
    validateProjection(verticalFov, near, far)

    local self = setmetatable({} as Camera3D, Camera3DMT)
    self.x = options.x or 0.0
    self.y = options.y or 0.0
    self.z = options.z or 0.0
    self.rotationX = options.rotationX or 0.0
    self.rotationY = options.rotationY or 0.0
    self.rotationZ = options.rotationZ or 0.0
    self.rotationW = options.rotationW or 1.0
    self.verticalFov = verticalFov
    self.near = near
    self.far = far
    self._matrix = loader.newArray("float[16]")
    return self
end

function Camera3D:matrix(width: number, height: number): loader.CArray
    if width <= 0.0 or height <= 0.0 then
        error("Camera3D viewport width and height must be greater than 0", 2)
    end
    validateProjection(self.verticalFov, self.near, self.far)

    local qx, qy, qz, qw = self.rotationX, self.rotationY, self.rotationZ, self.rotationW
    local magnitude <const> = sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
    if magnitude == 0.0 then
        error("Camera3D rotation quaternion must not be zero", 2)
    end
    local inverseMagnitude <const> = 1.0 / magnitude
    qx = qx * inverseMagnitude
    qy = qy * inverseMagnitude
    qz = qz * inverseMagnitude
    qw = qw * inverseMagnitude

    local xx, yy, zz = qx * qx, qy * qy, qz * qz
    local xy, xz, yz = qx * qy, qx * qz, qy * qz
    local wx, wy, wz = qw * qx, qw * qy, qw * qz

    -- Local-to-world rotation. The view uses its transpose below.
    local r00 = 1.0 - 2.0 * (yy + zz)
    local r01 = 2.0 * (xy - wz)
    local r02 = 2.0 * (xz + wy)
    local r10 = 2.0 * (xy + wz)
    local r11 = 1.0 - 2.0 * (xx + zz)
    local r12 = 2.0 * (yz - wx)
    local r20 = 2.0 * (xz - wy)
    local r21 = 2.0 * (yz + wx)
    local r22 = 1.0 - 2.0 * (xx + yy)

    local tx = -(r00 * self.x + r10 * self.y + r20 * self.z)
    local ty = -(r01 * self.x + r11 * self.y + r21 * self.z)
    local tz = -(r02 * self.x + r12 * self.y + r22 * self.z)

    local focal <const> = 1.0 / tan(self.verticalFov * 0.5)
    local horizontal <const> = focal * height / width
    local depth <const> = self.far / (self.near - self.far)
    local depthOffset <const> = self.far * self.near / (self.near - self.far)
    local m = self._matrix

    -- Projection multiplied by the inverse camera transform, written directly
    -- in column-major order so no temporary matrices are allocated.
    m[0] = horizontal * r00
    m[1] = focal * r01
    m[2] = depth * r02
    m[3] = -r02
    m[4] = horizontal * r10
    m[5] = focal * r11
    m[6] = depth * r12
    m[7] = -r12
    m[8] = horizontal * r20
    m[9] = focal * r21
    m[10] = depth * r22
    m[11] = -r22
    m[12] = horizontal * tx
    m[13] = focal * ty
    m[14] = depth * tz + depthOffset
    m[15] = -tz
    return m
end

return Camera3D
