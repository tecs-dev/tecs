-- Shared CPU and shader-facing sizes for opt-in local mesh shadows.

local record meshlocalshadowlayout
    --- Floats retained per shadowed local light at extraction time.
    LIGHT_FLOATS: integer
    --- Faces reserved per shadow slot. Point lights use all six and spot
    --- lights use the first.
    FACES: integer
    --- Floats in one column-major light view-projection matrix.
    MATRIX_FLOATS: integer
end

meshlocalshadowlayout.LIGHT_FLOATS = 12
meshlocalshadowlayout.FACES = 6
meshlocalshadowlayout.MATRIX_FLOATS = 16

return meshlocalshadowlayout
