--[=[
The optional 3D local-light record shared by extraction and GPU shading.

Each light occupies four vec4s: world position and radius, radiance and
intensity, forward direction and outer-cone cosine, then inner-cone cosine and
type. A point light uses type zero; a spot light uses type one. This module is
internal layout vocabulary and allocates nothing.
]=]

local record meshlightlayout
    --- Floats in one packed 3D local-light record.
    FLOATS: integer
    --- Bytes in one packed 3D local-light record.
    BYTES: integer
    --- Default light capacity for an enabled mesh-local-light lane.
    DEFAULT_CAPACITY: integer
end

meshlightlayout.FLOATS = 16
meshlightlayout.BYTES = meshlightlayout.FLOATS * 4
meshlightlayout.DEFAULT_CAPACITY = 256

return meshlightlayout
