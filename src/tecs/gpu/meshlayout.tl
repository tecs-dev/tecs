--[=[
Fixed storage layouts shared by mesh assets, extraction, and the mesh backend.

Mesh vertices are immutable content. Instances and bounds are frame data. The
three widths live here so the writer and eventual shaders cannot silently
choose different strides while the mesh domain is being landed in stages.
]=]

local record meshlayout
    VERTEX_FLOATS: integer
    VERTEX_BYTES: integer
    INSTANCE_FLOATS: integer
    INSTANCE_BYTES: integer
    BOUND_FLOATS: integer
    BOUND_BYTES: integer
end

-- position.xyz, normal.xyz, tangent.xyzw, uv.xy
meshlayout.VERTEX_FLOATS = 12
meshlayout.VERTEX_BYTES = meshlayout.VERTEX_FLOATS * 4

-- position.xyz, rotation.xyzw, scale.xyz, mesh slot, material id and param,
-- then three lanes reserved for the first drawing contract.
meshlayout.INSTANCE_FLOATS = 16
meshlayout.INSTANCE_BYTES = meshlayout.INSTANCE_FLOATS * 4

-- World-space bounding sphere: center.xyz and radius.
meshlayout.BOUND_FLOATS = 4
meshlayout.BOUND_BYTES = meshlayout.BOUND_FLOATS * 4

return meshlayout
