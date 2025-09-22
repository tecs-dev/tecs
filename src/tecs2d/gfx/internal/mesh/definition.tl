--- MeshDefinition registry for GPU-instanced mesh rendering.
--- Each definition owns its own per-instance output / material-params /
--- indirect-args buffers; the renderer issues one draw per definition
--- against the matching `love.graphics.Mesh` geometry.
---
--- Source-side data (Transform / Color / ClipBounds / Pivot / Material
--- per row + the resolved Mesh._definitionId) flows through the
--- renderer-owned shadow-column path: per-archetype shadow buffers
--- live on `shadow_state` instances built by `mesh/shadow_setup.tl`,
--- the cull dispatch (`mesh/shadow_dispatch.tl`) routes outputs into
--- the per-definition buffers held here.
local C <const> = require("ffi")

local gpuTypes <const> = require("tecs2d.gfx.internal.gpu.types")

local lg <const> = love.graphics

local record mesh_definition
    --- Get a mesh definition by its ID
    --- @param id The definition ID
    --- @return The MeshDefinition, or nil if not found
    getById: function(id: integer): MeshDefinition

    --- Get a mesh definition by its name
    --- @param name The definition name
    --- @return The MeshDefinition, or nil if not found
    getByName: function(name: string): MeshDefinition

    --- Get all registered mesh definitions (for renderer iteration)
    --- @return Map of all definitions by ID
    getAll: function(): {integer: MeshDefinition}

    --- A registered mesh definition for instanced rendering
    record MeshDefinition
        --- Unique ID (auto-assigned on registration)
        id: integer

        --- Name for serialization and lookup
        name: string

        --- User-provided Love2D mesh geometry
        mesh: love.graphics.Mesh

        --- Vertex count for indirect draw (cached from mesh)
        vertexCount: integer

        --- Per-instance output buffer (cull shader writes via atomicAdd).
        outputBuffer: love.graphics.Buffer

        --- Per-instance material params (cull writes in output order;
        --- render shader reads `materialParams[gl_InstanceID]`).
        materialParamsBuffer: love.graphics.Buffer

        --- Indirect draw arguments buffer (4 uint32: vertexCount,
        --- instanceCount, firstVertex, firstInstance).
        indirectBuffer: love.graphics.Buffer

        --- Indirect buffer reset data (uploaded each frame before
        --- the cull dispatch atomicAdd's into instanceCount).
        indirectResetData: love.data.ByteData

        --- Capacity (max visible instances) of `outputBuffer` /
        --- `materialParamsBuffer`.
        capacity: integer

        --- Mesh bounds for culling (pre-computed from vertices).
        --- Bounds are relative to mesh origin (0,0) and are
        --- definition-constant; the cull shader receives them as a
        --- `MeshBounds` uniform per dispatch.
        boundsCenterX: number
        boundsCenterY: number
        boundsHalfW: number
        boundsHalfH: number

        --- Grow output / material-params buffers to `newCapacity`.
        --- No-op if the new capacity is smaller than the current.
        grow: function(MeshDefinition, newCapacity: integer)
    end

    --- Create and register a new mesh definition
    --- @param name Unique name for lookup/serialization
    --- @param mesh The Love2D mesh geometry
    --- @param capacity Initial output capacity (default 1024).
    ---   Buffers grow on demand if visible instances exceed this.
    --- @return The new MeshDefinition
    new: function(name: string, mesh: love.graphics.Mesh, capacity?: integer): MeshDefinition
end

-------------------------------------------------------------------------------
-- Module-level registry
-------------------------------------------------------------------------------

local definitionRegistry: {integer: mesh_definition.MeshDefinition} = {}
local nameToId: {string: integer} = {}
local nextDefinitionId: integer = 1

function mesh_definition.getById(id: integer): mesh_definition.MeshDefinition
    return definitionRegistry[id]
end

function mesh_definition.getByName(name: string): mesh_definition.MeshDefinition
    local id = nameToId[name]
    if id then
        return definitionRegistry[id]
    end
    return nil
end

function mesh_definition.getAll(): {integer: mesh_definition.MeshDefinition}
    return definitionRegistry
end

-------------------------------------------------------------------------------
-- MeshDefinition implementation
-------------------------------------------------------------------------------

local MeshDefinition <const> = mesh_definition.MeshDefinition
local DEFINITION_MT <const>: metatable<MeshDefinition> = { __index = MeshDefinition }

function MeshDefinition:grow(newCapacity: integer)
    if newCapacity <= self.capacity then return end

    self.outputBuffer = lg.newBuffer(
        gpuTypes.MESH_FORMAT,
        newCapacity,
        {usage = "dynamic", shaderstorage = true}
    )
    self.materialParamsBuffer = lg.newBuffer(
        gpuTypes.MATERIAL_PARAMS_FORMAT,
        newCapacity,
        {usage = "dynamic", shaderstorage = true}
    )
    self.capacity = newCapacity
end

-------------------------------------------------------------------------------
-- Bounds computation
-------------------------------------------------------------------------------

-- Compute AABB bounds from mesh vertices
local function computeMeshBounds(mesh: love.graphics.Mesh): (number, number, number, number)
    local vertexCount = mesh:getVertexCount()
    if vertexCount == 0 then
        return 0, 0, 0, 0
    end

    local minX, minY = math.huge, math.huge
    local maxX, maxY = -math.huge, -math.huge

    for i = 1, vertexCount do
        local x, y = mesh:getVertexAttribute(i, 1) as (number, number)
        if x < minX then minX = x end
        if x > maxX then maxX = x end
        if y < minY then minY = y end
        if y > maxY then maxY = y end
    end

    local centerX = (minX + maxX) * 0.5
    local centerY = (minY + maxY) * 0.5
    local halfW = (maxX - minX) * 0.5
    local halfH = (maxY - minY) * 0.5

    return centerX, centerY, halfW, halfH
end

-------------------------------------------------------------------------------
-- Creation
-------------------------------------------------------------------------------

function mesh_definition.new(
    name: string,
    mesh: love.graphics.Mesh,
    capacity?: integer
): mesh_definition.MeshDefinition
    assert(name, "Missing mesh definition name")
    assert(mesh, "Missing Love2D mesh")

    if nameToId[name] then
        error("MeshDefinition '" .. name .. "' already registered")
    end

    local cap = capacity or 1024

    local vertexCount = mesh:getVertexCount() as integer
    local boundsCenterX, boundsCenterY, boundsHalfW, boundsHalfH = computeMeshBounds(mesh)

    -- Per-instance output buffer (cull writes here; render reads
    -- `instances[gl_InstanceID]` for vertex transform).
    local outputBuffer = lg.newBuffer(
        gpuTypes.MESH_FORMAT,
        cap,
        {usage = "dynamic", shaderstorage = true}
    )

    -- Per-instance material params, output-order so the render
    -- shader's `materialParams[gl_InstanceID]` lookup hits the right
    -- slot. Allocated lazily-equal to outputBuffer's capacity.
    local materialParamsBuffer = lg.newBuffer(
        gpuTypes.MATERIAL_PARAMS_FORMAT,
        cap,
        {usage = "dynamic", shaderstorage = true}
    )

    -- Indirect draw arguments. Cull atomicAdd's into instanceCount.
    local indirectFormat = {{format = "uint32"}} as love.graphics.BufferFormat
    local indirectBuffer = lg.newBuffer(indirectFormat, 4, {
        usage = "dynamic",
        shaderstorage = true,
        indirectarguments = true
    })

    -- Indirect reset data: uploaded each frame before cull dispatch.
    local indirectResetData = love.data.newByteData(16)
    local ptr = C.cast("uint32_t*", indirectResetData:getFFIPointer()) as {integer: integer}
    ptr[0] = vertexCount  -- vertexCount
    ptr[1] = 0            -- instanceCount (atomicAdd target)
    ptr[2] = 0            -- firstVertex
    ptr[3] = 0            -- firstInstance

    local defId = nextDefinitionId
    nextDefinitionId = nextDefinitionId + 1

    local def: mesh_definition.MeshDefinition = setmetatable({
        id = defId,
        name = name,
        mesh = mesh,
        vertexCount = vertexCount,
        outputBuffer = outputBuffer,
        materialParamsBuffer = materialParamsBuffer,
        indirectBuffer = indirectBuffer,
        indirectResetData = indirectResetData,
        capacity = cap,
        boundsCenterX = boundsCenterX,
        boundsCenterY = boundsCenterY,
        boundsHalfW = boundsHalfW,
        boundsHalfH = boundsHalfH,
    }, DEFINITION_MT)

    definitionRegistry[defId] = def
    nameToId[name] = defId

    return def
end

return mesh_definition
