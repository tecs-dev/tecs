--[=[
Owns mesh geometry residency and the device half of mesh frame staging.

Geometry is append-only immutable content. Registering a mesh copies its
vertices and indices once into device-local buffers, then every instance names
the resulting zero-based slot. Frame-varying instances and bounds use the same
rotating mapped-slot contract as sprites, but no buffer or staging allocation
is shared between the domains.

This backend deliberately records no draw yet. Its first landing proves asset
residency, extraction, and upload isolation before an opaque pass makes those
buffers part of the deferred graph.
]=]

local type assets = require("tecs.assets")
local loader <const> = require("tecs.ffi.loader")
local Buffer <const> = require("tecs.gpu.Buffer")
local Frame <const> = require("tecs.gpu.Frame")
local MeshFramePacket <const> = require("tecs.internal.render.MeshFramePacket")
local meshlayout <const> = require("tecs.gpu.meshlayout")

local record MeshRegion
    slot: integer
    firstVertex: integer
    vertexCount: integer
    firstIndex: integer
    indexCount: integer
end

local record MeshBackendOptions
    capacity: integer
    vertexCapacity: integer
    indexCapacity: integer
end

local record MeshBackend
    type Options = MeshBackendOptions
    type Region = MeshRegion

    capacity: integer
    vertexCapacity: integer
    indexCapacity: integer
    vertexCount: integer
    indexCount: integer
    meshCount: integer
    vertices: Buffer
    indices: Buffer
    instances: Buffer

    _bounds: Buffer
    _regions: {MeshRegion}
    _regionByAsset: {integer: MeshRegion}
    _device: loader.CPtr
    _destroyed: boolean
end

local MeshBackendMT <const>: metatable<MeshBackend> = {__index = MeshBackend}

function MeshBackend.create(device: loader.CPtr, options: MeshBackendOptions): MeshBackend
    local self = setmetatable({} as MeshBackend, MeshBackendMT)
    self.capacity = options.capacity
    self.vertexCapacity = options.vertexCapacity
    self.indexCapacity = options.indexCapacity
    self.vertexCount = 0
    self.indexCount = 0
    self.meshCount = 0
    self._device = device
    self._destroyed = false
    self._regions = {}
    self._regionByAsset = {}
    self.vertices = Buffer.create(
        device,
        {
            usage = {"storage"},
            size = self.vertexCapacity * meshlayout.VERTEX_BYTES,
            name = "mesh.vertices",
        }
    )
    self.indices = Buffer.create(
        device,
        {
            usage = {"index"},
            size = self.indexCapacity * 4,
            name = "mesh.indices",
        }
    )
    self.instances = Buffer.create(
        device,
        {
            usage = {"storage"},
            size = self.capacity * meshlayout.INSTANCE_BYTES,
            name = "mesh.instances",
        }
    )
    self._bounds = Buffer.create(
        device,
        {
            usage = {"storage"},
            size = self.capacity * meshlayout.BOUND_BYTES,
            name = "mesh.bounds",
        }
    )
    return self
end

function MeshBackend:mapSlot(slot: integer): loader.CArray, loader.CArray
    return self.instances:mapSlotAs(slot, "float *", false), self._bounds:mapSlotAs(slot, "float *", false)
end

function MeshBackend:registerMesh(asset: integer, mesh: assets.Mesh): MeshRegion
    local existing = self._regionByAsset[asset]
    if existing ~= nil then
        mesh:release()
        return existing
    end
    if mesh.vertices == nil or mesh.indices == nil then
        error(("tecs: mesh '%s' has been released"):format(mesh.name), 2)
    end

    local nextVertices <const> = self.vertexCount + mesh.vertexCount
    if nextVertices > self.vertexCapacity then
        error(
            ("tecs: mesh vertex capacity is %d, but registering '%s' needs %d"):format(
                self.vertexCapacity, mesh.name, nextVertices
            ),
            2
        )
    end
    local nextIndices <const> = self.indexCount + mesh.indexCount
    if nextIndices > self.indexCapacity then
        error(
            ("tecs: mesh index capacity is %d, but registering '%s' needs %d"):format(
                self.indexCapacity, mesh.name, nextIndices
            ),
            2
        )
    end

    local region <const> = {
        slot = self.meshCount,
        firstVertex = self.vertexCount,
        vertexCount = mesh.vertexCount,
        firstIndex = self.indexCount,
        indexCount = mesh.indexCount,
    } as MeshRegion
    self.vertices:upload(
        mesh.vertices, mesh.vertexCount * meshlayout.VERTEX_BYTES, region.firstVertex * meshlayout.VERTEX_BYTES
    )
    self.indices:upload(mesh.indices, mesh.indexCount * 4, region.firstIndex * 4)

    self.vertexCount = nextVertices
    self.indexCount = nextIndices
    self.meshCount = self.meshCount + 1
    self._regions[region.slot + 1] = region
    self._regionByAsset[asset] = region
    mesh:release()
    return region
end

function MeshBackend:regionOf(asset: integer): MeshRegion
    return self._regionByAsset[asset]
end

function MeshBackend:prepare(packet: MeshFramePacket, frame: Frame)
    local slot <const> = packet.slot
    self.instances:markSlotRanges(slot, packet.instanceRanges)
    self._bounds:markSlotRanges(slot, packet.boundsRanges)
    self.instances:flushSlot(slot, frame.commandBuffer)
    self._bounds:flushSlot(slot, frame.commandBuffer)
end

function MeshBackend:device(): loader.CPtr
    return self._device
end

function MeshBackend:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    self.vertices:destroy()
    self.indices:destroy()
    self.instances:destroy()
    self._bounds:destroy()
end

return MeshBackend
