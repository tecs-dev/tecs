--[=[
Owns mesh geometry residency and the device half of mesh frame staging.

Geometry is append-only immutable content. Registering a mesh copies its
vertices and indices once into device-local buffers, then every instance names
the resulting zero-based slot. Frame-varying instances and bounds use the same
rotating mapped-slot contract as sprites, but no buffer or staging allocation
is shared between the domains.

The first drawing contract writes one indexed indirect command per extracted
instance. It deliberately performs no visibility work yet. A later compute
cull can compact or replace the same command stream without changing mesh
residency, extraction, or the deferred contribution seam.
]=]

local type assets = require("tecs.assets")
local loader <const> = require("tecs.ffi.loader")
local Buffer <const> = require("tecs.gpu.Buffer")
local Frame <const> = require("tecs.gpu.Frame")
local Shader <const> = require("tecs.gpu.Shader")
local GraphicsPipeline <const> = require("tecs.gpu.GraphicsPipeline")
local RenderPass <const> = require("tecs.gpu.RenderPass")
local Deferred <const> = require("tecs.gpu.Deferred")
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
    commands: Buffer
    pipeline: GraphicsPipeline

    _bounds: Buffer
    _regions: {MeshRegion}
    _regionByAsset: {integer: MeshRegion}
    _device: loader.CPtr
    _destroyed: boolean
    _count: integer
    _viewProjection: loader.CArray
    _geometryBuffers: {loader.CValue}
end

local MeshBackendMT <const>: metatable<MeshBackend> = {__index = MeshBackend}

local function buildGeometry(device: loader.CPtr, deferred: Deferred): GraphicsPipeline
    local albedoFormat, normalFormat, ormFormat, emissionFormat = deferred:geometryFormats()
    local vertex = Shader.load(device, "mesh.vert", {})
    local fragment = Shader.load(device, "mesh.frag", {})
    local pipeline = GraphicsPipeline.create(
        device,
        {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormats = {albedoFormat, normalFormat, ormFormat, emissionFormat},
            depth = deferred:geometryDepth(),
            cull = GraphicsPipeline.CULL_BACK,
            name = "mesh.opaque",
        }
    )
    vertex:destroy()
    fragment:destroy()
    return pipeline
end

function MeshBackend.create(device: loader.CPtr, deferred: Deferred, options: MeshBackendOptions): MeshBackend
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
    self._count = 0
    self._geometryBuffers = {}
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
    self.commands = Buffer.create(
        device,
        {
            usage = {"indirect"},
            size = self.capacity * meshlayout.COMMAND_BYTES,
            name = "mesh.commands",
        }
    )
    self.pipeline = buildGeometry(device, deferred)
    return self
end

function MeshBackend:mapSlot(slot: integer): loader.CArray, loader.CArray, loader.CArray
    return self.instances:mapSlotAs(slot, "float *", false),
        self._bounds:mapSlotAs(slot, "float *", false),
        self.commands:mapSlotAs(slot, "SDL_GPUIndexedIndirectDrawCommand *", false)
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
    self.commands:markSlotRanges(slot, packet.commandRanges)
    self.instances:flushSlot(slot, frame.commandBuffer)
    self._bounds:flushSlot(slot, frame.commandBuffer)
    self.commands:flushSlot(slot, frame.commandBuffer)
    self._count = packet.count
    self._viewProjection = packet.viewProjection
end

function MeshBackend:recordGeometry(context: Deferred.PassContext)
    if self._count == 0 then
        return
    end
    context.pass:bindPipeline(self.pipeline.handle)
    context.pass:pushVertexUniform(0, self._viewProjection, 64)
    local buffers <const> = self._geometryBuffers
    buffers[1] = self.vertices.handle
    buffers[2] = self.instances.handle
    context.pass:bindVertexStorageBuffers(0, buffers)
    context.pass:bindIndexBuffer(self.indices.handle, RenderPass.INDEX_UINT32)
    context.pass:drawIndexedIndirect(self.commands.handle, 0, self._count)
end

function MeshBackend:rebuildPipeline(deferred: Deferred)
    local replacement <const> = buildGeometry(self._device, deferred)
    local old <const> = self.pipeline
    self.pipeline = replacement
    old:destroy()
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
    self.commands:destroy()
    self.pipeline:destroy()
end

return MeshBackend
