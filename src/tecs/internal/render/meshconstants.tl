-- Integer identities shared by mesh-domain extraction and residency.
-- `assets/shaders/include/meshenums.glsl` mirrors these at the GPU boundary.

local record meshconstants
    ALPHA_OPAQUE: integer
    ALPHA_MASK: integer
    ALPHA_BLEND: integer
end

meshconstants.ALPHA_OPAQUE = 0
meshconstants.ALPHA_MASK = 1
meshconstants.ALPHA_BLEND = 2

return meshconstants
