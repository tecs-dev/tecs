--[=[
Fixed storage layouts shared by mesh assets, extraction, and the mesh backend.

Mesh vertices are immutable content. Instances and bounds are frame data. The
storage widths live here so writers and shaders cannot silently choose
different strides while the mesh domain grows.
]=]

local record meshlayout
    VERTEX_FLOATS: integer
    VERTEX_BYTES: integer
    COLOR_VERTEX_FLOATS: integer
    COLOR_VERTEX_BYTES: integer
    SKIN_VERTEX_FLOATS: integer
    SKIN_VERTEX_BYTES: integer
    MORPH_VERTEX_FLOATS: integer
    MORPH_VERTEX_BYTES: integer
    MORPH_INSTANCE_FLOATS: integer
    MORPH_INSTANCE_BYTES: integer
    INSTANCE_FLOATS: integer
    INSTANCE_BYTES: integer
    BOUND_FLOATS: integer
    BOUND_BYTES: integer
    COMMAND_BYTES: integer
end

-- position.xyz, normal.xyz, tangent.xyzw, uv.xy
meshlayout.VERTEX_FLOATS = 12
meshlayout.VERTEX_BYTES = meshlayout.VERTEX_FLOATS * 4

-- Linear RGBA. This is a separate optional buffer so meshes that do not use
-- vertex colors retain the base vertex bandwidth and residency exactly.
meshlayout.COLOR_VERTEX_FLOATS = 4
meshlayout.COLOR_VERTEX_BYTES = meshlayout.COLOR_VERTEX_FLOATS * 4

-- joints.xyzw and normalized weights.xyzw. This is a separate optional
-- buffer so an unskinned domain keeps the existing vertex stride and
-- residency exactly.
meshlayout.SKIN_VERTEX_FLOATS = 8
meshlayout.SKIN_VERTEX_BYTES = meshlayout.SKIN_VERTEX_FLOATS * 4

-- position.xyz, normal.xyz, and tangent.xyz deltas. Targets are stored
-- consecutively, each with vertexCount entries.
meshlayout.MORPH_VERTEX_FLOATS = 9
meshlayout.MORPH_VERTEX_BYTES = meshlayout.MORPH_VERTEX_FLOATS * 4

-- first morph vertex, base vertex, vertices per target, first weight, and
-- target count. A negative first morph vertex disables deformation.
meshlayout.MORPH_INSTANCE_FLOATS = 5
meshlayout.MORPH_INSTANCE_BYTES = meshlayout.MORPH_INSTANCE_FLOATS * 4

-- position.xyz, rotation.xyzw, scale.xyz, mesh slot, material id and param,
-- then opaque base color rgb from Tint.
meshlayout.INSTANCE_FLOATS = 16
meshlayout.INSTANCE_BYTES = meshlayout.INSTANCE_FLOATS * 4

-- World-space bounding sphere: center.xyz and radius.
meshlayout.BOUND_FLOATS = 4
meshlayout.BOUND_BYTES = meshlayout.BOUND_FLOATS * 4

-- SDL_GPUIndexedIndirectDrawCommand: four uints and one signed int.
meshlayout.COMMAND_BYTES = 20

return meshlayout
