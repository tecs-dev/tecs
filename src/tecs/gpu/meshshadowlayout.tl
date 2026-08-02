--[=[
Fixed layout shared by directional-shadow preparation and rendering.

The shader mirrors these widths. Keeping the Lua-side counts here prevents
the renderer, deferred graph, and mesh backend from choosing different
cascade or uniform layouts while the optional shadow lane evolves.
]=]

local record meshshadowlayout
    CASCADES: integer
    MATRIX_FLOATS: integer
    UNIFORM_FLOATS: integer
    UNIFORM_BYTES: integer
end

meshshadowlayout.CASCADES = 3
meshshadowlayout.MATRIX_FLOATS = 16
-- Three matrices, splits, camera-depth row, direction, color/strength, tuning.
meshshadowlayout.UNIFORM_FLOATS = 68
meshshadowlayout.UNIFORM_BYTES = meshshadowlayout.UNIFORM_FLOATS * 4

return meshshadowlayout
