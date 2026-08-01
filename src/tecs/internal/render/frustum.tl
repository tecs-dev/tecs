-- Extracts normalized world-space planes from a column-major world-to-clip
-- matrix. SDL's clip depth is zero to one, so the near plane is row three
-- rather than row four plus row three.

local type loader = require("tecs.ffi.loader")

local record frustum
    write: function(matrix: loader.CArray, destination: loader.CArray)
end

local sqrt <const> = math.sqrt

local function plane(destination: loader.CArray, at: integer, x: number, y: number, z: number, w: number)
    local inverse <const> = 1.0 / sqrt(x * x + y * y + z * z)
    destination[at] = x * inverse
    destination[at + 1] = y * inverse
    destination[at + 2] = z * inverse
    destination[at + 3] = w * inverse
end

function frustum.write(matrix: loader.CArray, destination: loader.CArray)
    -- Rows of a column-major matrix.
    local r0x <const> = matrix[0] as number
    local r0y <const> = matrix[4] as number
    local r0z <const> = matrix[8] as number
    local r0w <const> = matrix[12] as number
    local r1x <const> = matrix[1] as number
    local r1y <const> = matrix[5] as number
    local r1z <const> = matrix[9] as number
    local r1w <const> = matrix[13] as number
    local r2x <const> = matrix[2] as number
    local r2y <const> = matrix[6] as number
    local r2z <const> = matrix[10] as number
    local r2w <const> = matrix[14] as number
    local r3x <const> = matrix[3] as number
    local r3y <const> = matrix[7] as number
    local r3z <const> = matrix[11] as number
    local r3w <const> = matrix[15] as number

    plane(destination, 0, r3x + r0x, r3y + r0y, r3z + r0z, r3w + r0w)
    plane(destination, 4, r3x - r0x, r3y - r0y, r3z - r0z, r3w - r0w)
    plane(destination, 8, r3x + r1x, r3y + r1y, r3z + r1z, r3w + r1w)
    plane(destination, 12, r3x - r1x, r3y - r1y, r3z - r1z, r3w - r1w)
    plane(destination, 16, r2x, r2y, r2z, r2w)
    plane(destination, 20, r3x - r2x, r3y - r2y, r3z - r2z, r3w - r2w)
end

return frustum
