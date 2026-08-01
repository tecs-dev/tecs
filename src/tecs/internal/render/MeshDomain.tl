--[=[
Owns the complete 3D mesh rendering lane.

The domain joins mesh extraction to geometry residency and device staging. It
does not own the deferred graph, presentation, capture, or frame-slot rotation.
`Renderer` creates it only when `meshes` options are present, so a 2D-only
application loads no mesh implementation and allocates none of these buffers.

This first stage prepares packets but contributes no draw pass. Opaque mesh
geometry can be added against the resident buffers without changing the public
asset or entity contract.
]=]

local type types = require("tecs.types")
local type assets = require("tecs.assets")
local loader <const> = require("tecs.ffi.loader")
local Buffer <const> = require("tecs.gpu.Buffer")
local Frame <const> = require("tecs.gpu.Frame")
local Camera3D <const> = require("tecs.gfx.Camera3D")
local MeshExtractor <const> = require("tecs.internal.render.MeshExtractor")
local MeshBackend <const> = require("tecs.internal.render.MeshBackend")
local MeshFramePacket <const> = require("tecs.internal.render.MeshFramePacket")
local components <const> = require("tecs.components")

local DEFAULT_CAPACITY <const> = 65536
local DEFAULT_VERTEX_CAPACITY <const> = 1048576
local DEFAULT_INDEX_CAPACITY <const> = 3145728

local record MeshDomainOptions
    --- Caller-writable. Sets the maximum resident mesh-instance count and
    --- defaults to 65,536.
    capacity: integer
    --- Caller-writable. Sets the immutable geometry ceiling in vertices and
    --- defaults to 1,048,576.
    vertexCapacity: integer
    --- Caller-writable. Sets the immutable geometry ceiling in 32-bit indices
    --- and defaults to 3,145,728.
    indexCapacity: integer
end

local record MeshDomain
    type Options = MeshDomainOptions

    --- Caller-writable. Controls the perspective view used by this domain.
    camera: Camera3D
    --- Read-only. Reports the mesh-instance capacity fixed at creation.
    capacity: integer
    --- Read-only. Reports the vertex capacity fixed at creation.
    vertexCapacity: integer
    --- Read-only. Reports the 32-bit index capacity fixed at creation.
    indexCapacity: integer
    --- Read-only. Reports the instances resident after the last extraction.
    count: integer
    --- Read-only. Reports the instances the last extraction could not fit.
    dropped: integer
    --- Read-only. Reports the instances rewritten by the last extraction.
    rewritten: integer
    --- Read-only. Reports meshes registered for immutable residency.
    meshCount: integer
    --- Read-only. Reports vertices registered for immutable residency.
    vertexCount: integer
    --- Read-only. Reports indices registered for immutable residency.
    indexCount: integer
    --- Engine-owned. Exposes immutable vertex storage to the future opaque
    --- mesh pass. Ordinary game code should ignore it.
    vertices: Buffer
    --- Engine-owned. Exposes immutable 32-bit index storage to the future
    --- opaque mesh pass. Ordinary game code should ignore it.
    indices: Buffer
    --- Engine-owned. Exposes mesh instances to the future cull and draw
    --- passes. Ordinary game code should ignore it.
    instances: Buffer

    _extractor: MeshExtractor
    _backend: MeshBackend
    _packet: MeshFramePacket
    _centerXByAsset: {integer: number}
    _centerYByAsset: {integer: number}
    _centerZByAsset: {integer: number}
    _radiusByAsset: {integer: number}
end

local MeshDomainMT <const>: metatable<MeshDomain> = {__index = MeshDomain}

local function positive(name: string, value: integer): integer
    if value < 1 or value ~= math.floor(value) then
        error(("tecs: %s must be a positive integer"):format(name), 3)
    end
    return value
end

function MeshDomain._create(device: loader.CPtr, options: MeshDomainOptions): MeshDomain
    options = options or {}
    local capacity <const> = positive("mesh capacity", options.capacity or DEFAULT_CAPACITY)
    local vertexCapacity <const> = positive("mesh vertex capacity", options.vertexCapacity or DEFAULT_VERTEX_CAPACITY)
    local indexCapacity <const> = positive("mesh index capacity", options.indexCapacity or DEFAULT_INDEX_CAPACITY)

    local self = setmetatable({} as MeshDomain, MeshDomainMT)
    self.capacity = capacity
    self.vertexCapacity = vertexCapacity
    self.indexCapacity = indexCapacity
    self.count = 0
    self.dropped = 0
    self.rewritten = 0
    self.meshCount = 0
    self.vertexCount = 0
    self.indexCount = 0
    self._centerXByAsset = {}
    self._centerYByAsset = {}
    self._centerZByAsset = {}
    self._radiusByAsset = {}
    self._packet = MeshFramePacket.create()

    local backend <const> = MeshBackend.create(
        device,
        {
            capacity = capacity,
            vertexCapacity = vertexCapacity,
            indexCapacity = indexCapacity,
        }
    )
    self._backend = backend
    self.vertices = backend.vertices
    self.indices = backend.indices
    self.instances = backend.instances

    local extractor <const> = MeshExtractor.create({capacity = capacity})
    self._extractor = extractor
    self.camera = extractor.camera
    return self
end

function MeshDomain:_install(world: types.World)
    self._extractor:install(
        world,
        self._packet,
        function()
            local packet <const> = self._packet
            self.count = packet.count
            self.dropped = packet.dropped
            self.rewritten = packet.rewritten
        end
    )
end

function MeshDomain:_setStaging(slot: integer)
    self._extractor:setStaging(slot, self._backend:mapSlot(slot))
end

function MeshDomain:_prepare(frame: Frame)
    self._packet:setCamera(self.camera, frame.width, frame.height)
    self._backend:prepare(self._packet, frame)
end

--- Registers immutable CPU geometry in this domain.
---
--- Registration uploads vertices and 32-bit indices once, releases the CPU
--- arrays, and returns fresh components that already carry the resident slot.
--- Registering the same normalized name again keeps the first geometry,
--- releases the duplicate, and returns the existing slot and bounds.
--- @param mesh The caller supplies CPU geometry that this call consumes.
--- @return Returns a mesh component ready to spawn.
--- @return Returns its asset-derived local bounding sphere.
function MeshDomain:registerMesh(mesh: assets.Mesh): components.Mesh, components.Bounds3D
    if mesh == nil then
        error("tecs: mesh data is required", 2)
    end
    local asset <const> = components.meshId(mesh.name)
    local radius = self._radiusByAsset[asset]
    local centerX = self._centerXByAsset[asset]
    local centerY = self._centerYByAsset[asset]
    local centerZ = self._centerZByAsset[asset]
    local region = self._backend:registerMesh(asset, mesh)
    if radius == nil then
        centerX = mesh.centerX
        centerY = mesh.centerY
        centerZ = mesh.centerZ
        radius = mesh.radius
        self._centerXByAsset[asset] = centerX
        self._centerYByAsset[asset] = centerY
        self._centerZByAsset[asset] = centerZ
        self._radiusByAsset[asset] = radius
    end
    self._extractor:registerMesh(asset, region.slot)
    self.meshCount = self._backend.meshCount
    self.vertexCount = self._backend.vertexCount
    self.indexCount = self._backend.indexCount
    return components.Mesh(asset, region.slot), components.Bounds3D(centerX, centerY, centerZ, radius)
end

--- Returns components for geometry already registered under a name.
--- @param name The caller supplies the registered mesh name.
--- @return Returns a mesh component carrying the resident slot.
--- @return Returns its asset-derived local bounding sphere.
function MeshDomain:mesh(name: string): components.Mesh, components.Bounds3D
    local asset <const> = components.meshId(name)
    local region <const> = self._backend:regionOf(asset)
    local radius <const> = self._radiusByAsset[asset]
    if region == nil or radius == nil then
        error(("tecs: no mesh is registered as '%s'"):format(name), 2)
    end
    return components.Mesh(asset, region.slot),
        components.Bounds3D(
            self._centerXByAsset[asset], self._centerYByAsset[asset], self._centerZByAsset[asset], radius
        )
end

function MeshDomain:_device(): loader.CPtr
    return self._backend:device()
end

function MeshDomain:_extractSeconds(): number
    return self._extractor:extractSeconds()
end

function MeshDomain:_destroy()
    self._backend:destroy()
end

return MeshDomain
