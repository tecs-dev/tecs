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

`matrix` writes a column-major world-to-clip matrix with depth in `[0, 1]`,
and `inverseMatrix` writes its clip-to-world inverse. `matrices` writes both
from one camera calculation for code that needs the pair. Each result uses a
separate camera-owned sixteen-float array and remains valid until that same
result is written again.
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
    --- Engine-owned. Stores the sixteen floats that `inverseMatrix` rewrites.
    --- Ordinary game code should ignore this field.
    _inverseMatrix: loader.CArray
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

    --- Writes the column-major clip-to-world matrix for a viewport.
    ---
    --- This is the exact inverse of `matrix` at the same dimensions. Clip x
    --- and y range from negative one to one, clip z ranges from zero to one,
    --- and the caller divides the resulting xyz by w.
    --- @param width The positive viewport width in pixels.
    --- @param height The positive viewport height in pixels.
    --- @return The camera's own sixteen-float array, valid until the next call
    ---     to `inverseMatrix` on this camera.
    inverseMatrix: function(self, width: number, height: number): loader.CArray

    --- Writes the world-to-clip matrix and its clip-to-world inverse.
    ---
    --- This method normalizes the camera quaternion and derives the projection
    --- once, then writes both arrays. Use it when both matrices describe the
    --- same view.
    --- @param width The positive viewport width in pixels.
    --- @param height The positive viewport height in pixels.
    --- @return The camera's own world-to-clip sixteen-float array, valid until
    ---     the next call to `matrix` or `matrices` on this camera.
    --- @return The camera's own clip-to-world sixteen-float array, valid until
    ---     the next call to `inverseMatrix` or `matrices` on this camera.
    matrices: function(self, width: number, height: number): loader.CArray, loader.CArray
end

local Camera3DMT <const>: metatable<Camera3D> = {__index = Camera3D}

local function validateProjection(verticalFov: number, near: number, far: number, level?: integer)
    level = level or 3
    if verticalFov <= 0.0 or verticalFov >= PI then
        error("Camera3D verticalFov must be greater than 0 and less than pi", level)
    end
    if near <= 0.0 then
        error("Camera3D near must be greater than 0", level)
    end
    if far <= near then
        error("Camera3D far must be greater than near", level)
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
    self._inverseMatrix = loader.newArray("float[16]")
    return self
end

local function writeMatrices(self: Camera3D, width: number, height: number, writeView: boolean, writeInverse: boolean)
    if width <= 0.0 or height <= 0.0 then
        error("Camera3D viewport width and height must be greater than 0", 3)
    end
    validateProjection(self.verticalFov, self.near, self.far, 4)

    local qx, qy, qz, qw = self.rotationX, self.rotationY, self.rotationZ, self.rotationW
    local magnitude <const> = sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
    if magnitude == 0.0 then
        error("Camera3D rotation quaternion must not be zero", 3)
    end
    local inverseMagnitude <const> = 1.0 / magnitude
    qx, qy, qz, qw = qx * inverseMagnitude, qy * inverseMagnitude, qz * inverseMagnitude, qw * inverseMagnitude

    local xx, yy, zz = qx * qx, qy * qy, qz * qz
    local xy, xz, yz = qx * qy, qx * qz, qy * qz
    local wx, wy, wz = qw * qx, qw * qy, qw * qz
    local r00, r01, r02 = 1.0 - 2.0 * (yy + zz), 2.0 * (xy - wz), 2.0 * (xz + wy)
    local r10, r11, r12 = 2.0 * (xy + wz), 1.0 - 2.0 * (xx + zz), 2.0 * (yz - wx)
    local r20, r21, r22 = 2.0 * (xz - wy), 2.0 * (yz + wx), 1.0 - 2.0 * (xx + yy)

    local focal <const> = 1.0 / tan(self.verticalFov * 0.5)
    local horizontal <const> = focal * height / width
    local depth <const> = self.far / (self.near - self.far)
    local depthOffset <const> = self.far * self.near / (self.near - self.far)
    if writeView then
        local tx <const> = -(r00 * self.x + r10 * self.y + r20 * self.z)
        local ty <const> = -(r01 * self.x + r11 * self.y + r21 * self.z)
        local tz <const> = -(r02 * self.x + r12 * self.y + r22 * self.z)
        local m <const> = self._matrix

        -- Projection multiplied by the inverse camera transform, written
        -- directly in column-major order without temporary matrices.
        m[0], m[1], m[2], m[3] = horizontal * r00, focal * r01, depth * r02, -r02
        m[4], m[5], m[6], m[7] = horizontal * r10, focal * r11, depth * r12, -r12
        m[8], m[9], m[10], m[11] = horizontal * r20, focal * r21, depth * r22, -r22
        m[12], m[13], m[14], m[15] = horizontal * tx, focal * ty, depth * tz + depthOffset, -tz
    end
    if writeInverse then
        local inverseDepthOffset <const> = 1.0 / depthOffset
        local m <const> = self._inverseMatrix

        -- Inverse projection followed by the local-to-world camera transform.
        -- Written by columns so it is directly consumable by GLSL.
        m[0], m[1], m[2], m[3] = r00 / horizontal, r10 / horizontal, r20 / horizontal, 0.0
        m[4], m[5], m[6], m[7] = r01 / focal, r11 / focal, r21 / focal, 0.0
        m[8], m[9], m[10], m[11] = self.x * inverseDepthOffset,
            self.y * inverseDepthOffset,
            self.z * inverseDepthOffset,
            inverseDepthOffset
        m[12], m[13], m[14], m[15] = -r02 + self.x * depth * inverseDepthOffset,
            -r12 + self.y * depth * inverseDepthOffset,
            -r22 + self.z * depth * inverseDepthOffset,
            depth * inverseDepthOffset
    end
end

function Camera3D:matrix(width: number, height: number): loader.CArray
    writeMatrices(self, width, height, true, false)
    return self._matrix
end

function Camera3D:inverseMatrix(width: number, height: number): loader.CArray
    writeMatrices(self, width, height, false, true)
    return self._inverseMatrix
end

function Camera3D:matrices(width: number, height: number): loader.CArray, loader.CArray
    writeMatrices(self, width, height, true, true)
    return self._matrix, self._inverseMatrix
end

return Camera3D
