--[=[
Owns mesh geometry residency and the device half of mesh frame staging.

Geometry is append-only immutable content. Registering a mesh copies its
vertices and indices once into device-local buffers, then every instance names
the resulting zero-based slot. Frame-varying instances and bounds use the same
rotating mapped-slot contract as sprites, but no buffer or staging allocation
is shared between the domains.

The CPU writes one source indexed command per extracted instance. Three
ordered compute passes mark spheres against the camera frustum, scan survivor
counts, and compact whole commands into a GPU-only indirect buffer. The CPU
still submits the fixed extracted command count; cleared trailing commands
carry zero instances, so no visibility count crosses back from the GPU.
]=]

local type assets = require("tecs.assets")
local loader <const> = require("tecs.ffi.loader")
local sdl <const> = require("tecs.ffi.sdl3")
local Buffer <const> = require("tecs.gpu.Buffer")
local Frame <const> = require("tecs.gpu.Frame")
local Shader <const> = require("tecs.gpu.Shader")
local GraphicsPipeline <const> = require("tecs.gpu.GraphicsPipeline")
local ComputePipeline <const> = require("tecs.gpu.ComputePipeline")
local ComputePass <const> = require("tecs.gpu.ComputePass")
local TextureArray <const> = require("tecs.gpu.TextureArray")
local Sampler <const> = require("tecs.gpu.Sampler")
local RenderPass <const> = require("tecs.gpu.RenderPass")
local Deferred <const> = require("tecs.gpu.Deferred")
local MeshFramePacket <const> = require("tecs.internal.render.MeshFramePacket")
local meshlayout <const> = require("tecs.gpu.meshlayout")
local frustum <const> = require("tecs.internal.render.frustum")

local C <const> = sdl.C
local CULL_GROUP <const> = 256
local MATERIAL_FLOATS <const> = 40

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
    materialCapacity: integer
    textureWidth: integer
    textureHeight: integer
    textureLayers: integer
    packTextures: boolean
end

local record MeshMaterialData
    name: string
    model: integer
    baseColorTexture: integer
    normalTexture: integer
    metallicRoughnessTexture: integer
    occlusionTexture: integer
    emissiveTexture: integer
    alphaCutoff: number
    baseR: number
    baseG: number
    baseB: number
    baseA: number
    emissiveR: number
    emissiveG: number
    emissiveB: number
    metallic: number
    roughness: number
    normalScale: number
    occlusionStrength: number
end

local record MeshBackend
    type Options = MeshBackendOptions
    type Region = MeshRegion
    type MaterialData = MeshMaterialData

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
    materials: Buffer
    images: TextureArray
    sampler: Sampler
    pipeline: GraphicsPipeline
    materialCapacity: integer
    materialCount: integer
    textureCount: integer

    _bounds: Buffer
    _slots: Buffer
    _blocks: Buffer
    _visibleCommands: Buffer
    _markPipeline: ComputePipeline
    _scanPipeline: ComputePipeline
    _compactPipeline: ComputePipeline
    _markPass: ComputePass
    _scanPass: ComputePass
    _compactPass: ComputePass
    _cullUniform: loader.CArray
    _markWrites: {loader.CValue}
    _markReads: {loader.CValue}
    _scanWrites: {loader.CValue}
    _compactWrites: {loader.CValue}
    _compactReads: {loader.CValue}
    _regions: {MeshRegion}
    _regionByAsset: {integer: MeshRegion}
    _materialSlotByAsset: {integer: integer}
    _textureRegions: {TextureArray.Region}
    _textureByName: {string: integer}
    _device: loader.CPtr
    _destroyed: boolean
    _count: integer
    _viewProjection: loader.CArray
    _geometryBuffers: {loader.CValue}
    _fragmentBuffers: {loader.CValue}
    _fragmentTextures: {loader.CValue}
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
    self.materialCapacity = options.materialCapacity
    self.materialCount = 1
    self.textureCount = 0
    self._device = device
    self._destroyed = false
    self._regions = {}
    self._regionByAsset = {}
    self._materialSlotByAsset = {}
    self._textureRegions = {}
    self._textureByName = {}
    self._count = 0
    self._geometryBuffers = {}
    self._fragmentBuffers = {}
    self._fragmentTextures = {}
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
            usage = {"computeRead"},
            size = self.capacity * meshlayout.COMMAND_BYTES,
            name = "mesh.commands",
        }
    )
    self.materials = Buffer.create(
        device,
        {
            usage = {"storage"},
            size = self.materialCapacity * MATERIAL_FLOATS * 4,
            name = "mesh.materials",
        }
    )
    self.images = TextureArray.create(
        device,
        {
            width = options.textureWidth,
            height = options.textureHeight,
            layers = options.textureLayers,
            pack = options.packTextures,
        }
    )
    self.sampler = Sampler.create(device, {filter = Sampler.FILTER_LINEAR, address = Sampler.ADDRESS_REPEAT})

    -- Slot zero is neutral metallic-roughness PBR. Negative texture layers
    -- select shader constants, so the texture array need not spend residency
    -- on fallback texels.
    local neutral <const> = loader.newArray("float[?]", MATERIAL_FLOATS)
    neutral[0] = 0
    for lane = 1, 5 do
        neutral[lane] = -1
    end
    neutral[6] = 0.5
    neutral[28], neutral[29], neutral[30], neutral[31] = 1, 1, 1, 1
    neutral[32], neutral[33], neutral[34] = 0, 0, 0
    neutral[36], neutral[37], neutral[38], neutral[39] = 0, 0.65, 1, 1
    self.materials:upload(neutral, MATERIAL_FLOATS * 4)
    self._slots = Buffer.create(
        device, {usage = {"computeRead", "computeWrite"}, size = self.capacity * 4, name = "mesh.cull.slots"}
    )
    self._blocks = Buffer.create(
        device,
        {
            usage = {"computeRead", "computeWrite"},
            size = math.ceil(self.capacity / CULL_GROUP) * 4,
            name = "mesh.cull.blocks",
        }
    )
    self._visibleCommands = Buffer.create(
        device,
        {
            usage = {"indirect", "computeWrite"},
            size = self.capacity * meshlayout.COMMAND_BYTES,
            name = "mesh.visibleCommands",
        }
    )
    self._markPipeline = ComputePipeline.load(device, "mesh.mark.comp", {})
    self._scanPipeline = ComputePipeline.load(device, "mesh.scan.comp", {})
    self._compactPipeline = ComputePipeline.load(device, "mesh.compact.comp", {})
    self._cullUniform = loader.newArray("float[28]")
    self._markWrites = {}
    self._markReads = {}
    self._scanWrites = {}
    self._compactWrites = {}
    self._compactReads = {}
    self.pipeline = buildGeometry(device, deferred)
    return self
end

function MeshBackend:registerTexture(image: assets.Image): integer
    local existing = self._textureByName[image.path]
    if existing ~= nil then
        image:release()
        return existing
    end
    if image.pixels == nil then
        error(("tecs: image '%s' has been released"):format(image.path), 2)
    end
    local region <const> = self.images:add(image.pixels, image.width, image.height, image.pitch)
    image:release()
    self.textureCount = self.textureCount + 1
    self._textureRegions[self.textureCount] = region
    self._textureByName[image.path] = self.textureCount
    return self.textureCount
end

local function writeRegion(target: loader.CArray, at: integer, region: TextureArray.Region)
    if region == nil then
        target[at] = -1
        return
    end
    target[at] = region.layer
end

local function textureRegion(self: MeshBackend, texture: integer, field: string): TextureArray.Region
    if texture == 0 then
        return nil
    end
    local region = self._textureRegions[texture]
    if region == nil then
        error(("tecs: mesh material %s names unknown texture %s"):format(field, tostring(texture)), 3)
    end
    return region
end

function MeshBackend:registerMaterial(asset: integer, data: MeshMaterialData): integer
    local existing = self._materialSlotByAsset[asset]
    if existing ~= nil then
        return existing
    end
    local baseColor <const> = textureRegion(self, data.baseColorTexture, "baseColorTexture")
    local normal <const> = textureRegion(self, data.normalTexture, "normalTexture")
    local metallicRoughness <const> = textureRegion(self, data.metallicRoughnessTexture, "metallicRoughnessTexture")
    local occlusion <const> = textureRegion(self, data.occlusionTexture, "occlusionTexture")
    local emissive <const> = textureRegion(self, data.emissiveTexture, "emissiveTexture")
    if self.materialCount >= self.materialCapacity then
        error(("tecs: mesh material capacity is %d"):format(self.materialCapacity), 2)
    end
    local slot <const> = self.materialCount
    local values <const> = loader.newArray("float[?]", MATERIAL_FLOATS)
    values[0] = data.model
    writeRegion(values, 1, baseColor)
    writeRegion(values, 2, normal)
    writeRegion(values, 3, metallicRoughness)
    writeRegion(values, 4, occlusion)
    writeRegion(values, 5, emissive)
    -- UV rectangles occupy independent lanes after the layer header.
    local textureRegions <const> = {baseColor, normal, metallicRoughness, occlusion, emissive}
    for index = 1, 5 do
        local region = textureRegions[index]
        local at <const> = 8 + (index - 1) * 4
        if region == nil then
            values[at], values[at + 1], values[at + 2], values[at + 3] = 0, 0, 1, 1
        else
            values[at], values[at + 1], values[at + 2], values[at + 3] = region.u0, region.v0, region.u1, region.v1
        end
    end
    values[6] = data.alphaCutoff
    values[28], values[29], values[30], values[31] = data.baseR, data.baseG, data.baseB, data.baseA
    values[32], values[33], values[34] = data.emissiveR, data.emissiveG, data.emissiveB
    values[36], values[37] = data.metallic, data.roughness
    values[38], values[39] = data.normalScale, data.occlusionStrength
    self.materials:upload(values, MATERIAL_FLOATS * 4, slot * MATERIAL_FLOATS * 4)
    self._materialSlotByAsset[asset] = slot
    self.materialCount = slot + 1
    return slot
end

function MeshBackend:materialSlot(asset: integer): integer
    return self._materialSlotByAsset[asset]
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
    if self._count == 0 then
        return
    end

    local groups <const> = math.ceil(self._count / CULL_GROUP)
    local uniform <const> = self._cullUniform
    frustum.write(packet.viewProjection, uniform)
    uniform[24] = self._count
    uniform[25] = groups
    uniform[26] = self.capacity
    uniform[27] = 0.0

    local markWrites <const> = self._markWrites
    markWrites[1] = self._slots.handle
    markWrites[2] = self._blocks.handle
    markWrites[3] = self._visibleCommands.handle
    local markReads <const> = self._markReads
    markReads[1] = self._bounds.handle
    local mark <const> = ComputePass.begin(frame.commandBuffer, markWrites, self._markPass)
    self._markPass = mark
    mark:bindPipeline(self._markPipeline.handle)
    mark:bindStorageBuffers(0, markReads)
    C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, uniform, 112)
    mark:dispatch(groups)
    mark:finish()

    local scanWrites <const> = self._scanWrites
    scanWrites[1] = self._blocks.handle
    local scan <const> = ComputePass.begin(frame.commandBuffer, scanWrites, self._scanPass)
    self._scanPass = scan
    scan:bindPipeline(self._scanPipeline.handle)
    C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, uniform, 112)
    scan:dispatch(1)
    scan:finish()

    local compactWrites <const> = self._compactWrites
    compactWrites[1] = self._visibleCommands.handle
    local compactReads <const> = self._compactReads
    compactReads[1] = self._slots.handle
    compactReads[2] = self._blocks.handle
    compactReads[3] = self.commands.handle
    local compact <const> = ComputePass.begin(frame.commandBuffer, compactWrites, self._compactPass)
    self._compactPass = compact
    compact:bindPipeline(self._compactPipeline.handle)
    compact:bindStorageBuffers(0, compactReads)
    C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, uniform, 112)
    compact:dispatch(groups)
    compact:finish()
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
    local fragmentBuffers <const> = self._fragmentBuffers
    fragmentBuffers[1] = self.materials.handle
    context.pass:bindFragmentStorageBuffers(0, fragmentBuffers)
    local textures <const> = self._fragmentTextures
    textures[1] = self.images.handle
    context.pass:bindTextures(0, textures, self.sampler.handle)
    context.pass:bindIndexBuffer(self.indices.handle, RenderPass.INDEX_UINT32)
    context.pass:drawIndexedIndirect(self._visibleCommands.handle, 0, self._count)
end

function MeshBackend:rebuildPipeline(deferred: Deferred)
    local geometry <const> = buildGeometry(self._device, deferred)
    local mark <const> = ComputePipeline.load(self._device, "mesh.mark.comp", {})
    local scan <const> = ComputePipeline.load(self._device, "mesh.scan.comp", {})
    local compact <const> = ComputePipeline.load(self._device, "mesh.compact.comp", {})
    local oldGeometry, oldMark, oldScan, oldCompact <const> = self.pipeline,
        self._markPipeline,
        self._scanPipeline,
        self._compactPipeline
    self.pipeline, self._markPipeline, self._scanPipeline, self._compactPipeline = geometry, mark, scan, compact
    oldGeometry:destroy()
    oldMark:destroy()
    oldScan:destroy()
    oldCompact:destroy()
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
    self.materials:destroy()
    self.images:destroy()
    self.sampler:destroy()
    self._slots:destroy()
    self._blocks:destroy()
    self._visibleCommands:destroy()
    self._markPipeline:destroy()
    self._scanPipeline:destroy()
    self._compactPipeline:destroy()
    self.pipeline:destroy()
end

return MeshBackend
