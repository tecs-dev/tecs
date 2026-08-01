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

Skin and morph deformation are independent opt-in buffer and shader lanes.
Morph deltas are immutable mesh residency, while complete weight vectors are
retained and staged only when registered or updated. Rigid domains keep the
base bindings and shader variant.

An enabled shadow lane repeats that same mark, scan, and compact sequence
against the light volume before camera culling reuses the scratch buffers.
Only its compacted indirect commands reach the shadow raster pass, so meshes
outside both views cost bounds tests rather than vertex and triangle work.
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
local dirtyranges <const> = require("tecs.gpu.dirtyranges")
local frustum <const> = require("tecs.internal.render.frustum")

local C <const> = sdl.C
local CULL_GROUP <const> = 256
local SORT_BUCKETS <const> = 256
local MATERIAL_FLOATS <const> = 40
local CULL_FLOATS <const> = 44
local CULL_BYTES <const> = CULL_FLOATS * 4
local SHADOW_FLOATS <const> = 28
local SHADOW_BYTES <const> = SHADOW_FLOATS * 4
local JOINT_FLOATS <const> = 16
local JOINT_BYTES <const> = JOINT_FLOATS * 4

local interface MeshShadowOptions
    distance: number
    directionX: number
    directionY: number
    directionZ: number
    r: number
    g: number
    b: number
    intensity: number
    strength: number
    bias: number
    softness: number
end

local interface MeshFogOptions
    start: number
    finish: number
    r: number
    g: number
    b: number
end

local record MeshRegion
    slot: integer
    firstVertex: integer
    vertexCount: integer
    firstIndex: integer
    indexCount: integer
    firstMorphVertex: integer
    morphTargetCount: integer
end

local record SkinRegion
    firstJoint: integer
    jointCount: integer
end

local record MorphRegion
    firstWeight: integer
    weightCount: integer
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
    transparency: boolean
    shadows: MeshShadowOptions
    skinning: boolean
    jointCapacity: integer
    morphing: boolean
    morphVertexCapacity: integer
    morphWeightCapacity: integer
    vertexColors: boolean
    fog: MeshFogOptions
end

local record MeshMaterialData
    name: string
    model: integer
    alphaMode: integer
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
    type ShadowOptions = MeshShadowOptions
    type SkinRegion = SkinRegion
    type MorphRegion = MorphRegion
    type FogOptions = MeshFogOptions

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
    blendPipeline: GraphicsPipeline
    shadowPipeline: GraphicsPipeline
    materialCapacity: integer
    materialCount: integer
    textureCount: integer
    jointCapacity: integer
    jointCount: integer
    morphVertexCapacity: integer
    morphVertexCount: integer
    morphWeightCapacity: integer
    morphWeightCount: integer

    updateSkin: function(self, region: SkinRegion, matrices: {number})
    updateMorph: function(self, region: MorphRegion, weights: {number})

    _bounds: Buffer
    _skinVertices: Buffer
    _instanceSkins: Buffer
    _jointMatrices: Buffer
    _jointValues: loader.CArray
    _jointRanges: dirtyranges
    _morphVertices: Buffer
    _instanceMorphs: Buffer
    _morphWeights: Buffer
    _colorVertices: Buffer
    _morphValues: loader.CArray
    _morphRanges: dirtyranges
    _slots: Buffer
    _blocks: Buffer
    _visibleCommands: Buffer
    _shadowCommands: Buffer
    _markPipeline: ComputePipeline
    _scanPipeline: ComputePipeline
    _compactPipeline: ComputePipeline
    _shadowMarkPipeline: ComputePipeline
    _rankPipeline: ComputePipeline
    _placePipeline: ComputePipeline
    _markPass: ComputePass
    _scanPass: ComputePass
    _compactPass: ComputePass
    _blendScanPass: ComputePass
    _blendCompactPass: ComputePass
    _rankPass: ComputePass
    _bucketScanPass: ComputePass
    _placePass: ComputePass
    _cullUniform: loader.CArray
    _markWrites: {loader.CValue}
    _markReads: {loader.CValue}
    _scanWrites: {loader.CValue}
    _compactWrites: {loader.CValue}
    _compactReads: {loader.CValue}
    _shadowMarkWrites: {loader.CValue}
    _shadowMarkReads: {loader.CValue}
    _shadowCompactWrites: {loader.CValue}
    _shadowCompactReads: {loader.CValue}
    _blendSlots: Buffer
    _blendBlocks: Buffer
    _blendCommands: Buffer
    _blendSorted: Buffer
    _blendBuckets: Buffer
    _blendRanks: Buffer
    _blendCounts: Buffer
    _blendScanWrites: {loader.CValue}
    _blendCompactWrites: {loader.CValue}
    _blendCompactReads: {loader.CValue}
    _rankWrites: {loader.CValue}
    _rankReads: {loader.CValue}
    _bucketScanWrites: {loader.CValue}
    _placeWrites: {loader.CValue}
    _placeReads: {loader.CValue}
    _regions: {MeshRegion}
    _regionByAsset: {integer: MeshRegion}
    _materialSlotByAsset: {integer: integer}
    _skinRegionByAsset: {integer: SkinRegion}
    _morphRegionByAsset: {integer: MorphRegion}
    _textureRegions: {TextureArray.Region}
    _textureByName: {string: integer}
    _device: loader.CPtr
    _deferred: Deferred
    _destroyed: boolean
    _count: integer
    _viewProjection: loader.CArray
    _viewUniform: loader.CArray
    _geometryBuffers: {loader.CValue}
    _fragmentBuffers: {loader.CValue}
    _fragmentTextures: {loader.CValue}
    _forwardBuffers: {loader.CValue}
    _forwardTextures: {loader.CValue}
    _transparent: boolean
    _blending: boolean
    _shadows: boolean
    _skinning: boolean
    _morphing: boolean
    _vertexColors: boolean
    _fogging: boolean
    _fog: MeshFogOptions
    _fogUniform: loader.CArray
    _shadowActive: boolean
    _shadow: MeshShadowOptions
    _shadowUniform: loader.CArray
end

local MeshBackendMT <const>: metatable<MeshBackend> = {__index = MeshBackend}

local function vertexDefines(
    skinning: boolean, morphing: boolean, vertexColors: boolean, fogging: boolean
): {string: string}
    if not skinning and not morphing and not vertexColors and not fogging then
        return nil
    end
    local defines: {string: string} = {}
    if skinning then
        defines.MESH_SKINNING = "1"
    end
    if morphing then
        defines.MESH_MORPHING = "1"
    end
    if vertexColors then
        defines.MESH_VERTEX_COLORS = "1"
    end
    if fogging then
        defines.MESH_FOG = "1"
    end
    return defines
end

local function fragmentDefines(shadows: boolean, fogging: boolean): {string: string}
    if not shadows and not fogging then
        return nil
    end
    local defines: {string: string} = {}
    if shadows then
        defines.MESH_SHADOWS = "1"
    end
    if fogging then
        defines.MESH_FOG = "1"
    end
    return defines
end

local function buildGeometry(
    device: loader.CPtr,
    deferred: Deferred,
    shadows: boolean,
    skinning: boolean,
    morphing: boolean,
    vertexColors: boolean,
    fogging: boolean
): GraphicsPipeline
    local albedoFormat, normalFormat, ormFormat, emissionFormat = deferred:geometryFormats()
    local vertex = Shader.load(
        device, "mesh.vert", {defines = vertexDefines(skinning, morphing, vertexColors, fogging)}
    )
    local fragment = Shader.load(device, "mesh.frag", {defines = fragmentDefines(shadows, fogging)})
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

local function buildForward(
    device: loader.CPtr,
    deferred: Deferred,
    shadows: boolean,
    skinning: boolean,
    morphing: boolean,
    vertexColors: boolean,
    fogging: boolean
): GraphicsPipeline
    local vertex = Shader.load(
        device, "mesh.vert", {defines = vertexDefines(skinning, morphing, vertexColors, fogging)}
    )
    local fragment = Shader.load(device, "mesh.forward.frag", {defines = fragmentDefines(shadows, fogging)})
    local pipeline = GraphicsPipeline.create(
        device,
        {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormat = deferred:forwardFormat(),
            depth = deferred:forwardDepth(),
            cull = GraphicsPipeline.CULL_BACK,
            blendMode = GraphicsPipeline.BLEND_PREMULTIPLIED,
            name = "mesh.forward",
        }
    )
    vertex:destroy()
    fragment:destroy()
    return pipeline
end

local function buildShadow(
    device: loader.CPtr, deferred: Deferred, skinning: boolean, morphing: boolean, vertexColors: boolean
): GraphicsPipeline
    local vertex = Shader.load(
        device, "mesh.shadow.vert", {defines = vertexDefines(skinning, morphing, vertexColors, false)}
    )
    local fragment = Shader.load(device, "mesh.shadow.frag", {})
    local pipeline = GraphicsPipeline.create(
        device,
        {
            vertexShader = vertex,
            fragmentShader = fragment,
            colorFormat = deferred:meshShadowFormat(),
            cull = GraphicsPipeline.CULL_NONE,
            blendMode = GraphicsPipeline.BLEND_MIN,
            name = "mesh.shadows",
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
    self.jointCapacity = options.jointCapacity or 0
    self.jointCount = 0
    self.morphVertexCapacity = options.morphVertexCapacity or 0
    self.morphVertexCount = 0
    self.morphWeightCapacity = options.morphWeightCapacity or 0
    self.morphWeightCount = 0
    self._device = device
    self._deferred = deferred
    self._destroyed = false
    self._regions = {}
    self._regionByAsset = {}
    self._materialSlotByAsset = {}
    self._skinRegionByAsset = {}
    self._morphRegionByAsset = {}
    self._textureRegions = {}
    self._textureByName = {}
    self._count = 0
    self._transparent = options.transparency
    self._blending = false
    self._shadows = options.shadows ~= nil
    self._skinning = options.skinning
    self._morphing = options.morphing
    self._vertexColors = options.vertexColors
    self._fogging = options.fog ~= nil
    self._fog = options.fog
    if self._fogging then
        self._viewUniform = loader.newArray("float[24]")
        self._fogUniform = loader.newArray("float[4]")
    end
    self._shadowActive = false
    self._shadow = options.shadows
    if self._shadows then
        self._shadowUniform = loader.newArray("float[?]", SHADOW_FLOATS)
    end
    self._geometryBuffers = {}
    self._fragmentBuffers = {}
    self._fragmentTextures = {}
    self._forwardBuffers = {}
    self._forwardTextures = {}
    self.vertices = Buffer.create(
        device,
        {
            usage = {"storage"},
            size = self.vertexCapacity * meshlayout.VERTEX_BYTES,
            name = "mesh.vertices",
        }
    )
    if self._vertexColors then
        self._colorVertices = Buffer.create(
            device,
            {
                usage = {"storage"},
                size = self.vertexCapacity * meshlayout.COLOR_VERTEX_BYTES,
                name = "mesh.vertexColors",
            }
        )
    end
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
    if self._skinning then
        self._skinVertices = Buffer.create(
            device,
            {
                usage = {"storage"},
                size = self.vertexCapacity * meshlayout.SKIN_VERTEX_BYTES,
                name = "mesh.skinVertices",
            }
        )
        self._instanceSkins = Buffer.create(
            device,
            {
                usage = {"storage"},
                size = self.capacity * 4,
                name = "mesh.instanceSkins",
            }
        )
        self._jointMatrices = Buffer.create(
            device,
            {
                usage = {"storage"},
                size = self.jointCapacity * JOINT_BYTES,
                name = "mesh.joints",
            }
        )
        self._jointValues = loader.newArray("float[?]", self.jointCapacity * JOINT_FLOATS)
        self._jointRanges = dirtyranges.create()
    end
    if self._morphing then
        self._morphVertices = Buffer.create(
            device,
            {
                usage = {"storage"},
                size = self.morphVertexCapacity * meshlayout.MORPH_VERTEX_BYTES,
                name = "mesh.morphVertices",
            }
        )
        self._instanceMorphs = Buffer.create(
            device,
            {
                usage = {"storage"},
                size = self.capacity * meshlayout.MORPH_INSTANCE_BYTES,
                name = "mesh.instanceMorphs",
            }
        )
        self._morphWeights = Buffer.create(
            device,
            {
                usage = {"storage"},
                size = self.morphWeightCapacity * 4,
                name = "mesh.morphWeights",
            }
        )
        self._morphValues = loader.newArray("float[?]", self.morphWeightCapacity)
        self._morphRanges = dirtyranges.create()
    end
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
    neutral[7] = 0
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
    self._markPipeline = ComputePipeline.load(
        device, self._transparent and "mesh.lanes.mark.comp" or "mesh.mark.comp", {}
    )
    self._scanPipeline = ComputePipeline.load(device, "mesh.scan.comp", {})
    self._compactPipeline = ComputePipeline.load(device, "mesh.compact.comp", {})
    self._cullUniform = loader.newArray("float[?]", CULL_FLOATS)
    self._markWrites = {}
    self._markReads = {}
    self._scanWrites = {}
    self._compactWrites = {}
    self._compactReads = {}
    self._shadowMarkWrites = {}
    self._shadowMarkReads = {}
    self._shadowCompactWrites = {}
    self._shadowCompactReads = {}
    self._blendScanWrites = {}
    self._blendCompactWrites = {}
    self._blendCompactReads = {}
    self._rankWrites = {}
    self._rankReads = {}
    self._bucketScanWrites = {}
    self._placeWrites = {}
    self._placeReads = {}
    self.pipeline = buildGeometry(
        device, deferred, self._shadows, self._skinning, self._morphing, self._vertexColors, self._fogging
    )
    if self._shadows then
        self._shadowCommands = Buffer.create(
            device,
            {
                usage = {"indirect", "computeWrite"},
                size = self.capacity * meshlayout.COMMAND_BYTES,
                name = "mesh.shadow.commands",
            }
        )
        if self._transparent then
            self._shadowMarkPipeline = ComputePipeline.load(device, "mesh.mark.comp", {defines = {MESH_ALPHA = "1"}})
        end
        self.shadowPipeline = buildShadow(device, deferred, self._skinning, self._morphing, self._vertexColors)
    end
    if self._transparent then
        local groups <const> = math.ceil(self.capacity / CULL_GROUP)
        self._blendSlots = Buffer.create(
            device, {usage = {"computeRead", "computeWrite"}, size = self.capacity * 4, name = "mesh.blend.slots"}
        )
        self._blendBlocks = Buffer.create(
            device, {usage = {"computeRead", "computeWrite"}, size = groups * 4, name = "mesh.blend.blocks"}
        )
        self._blendCommands = Buffer.create(
            device,
            {
                usage = {"computeRead", "computeWrite"},
                size = self.capacity * meshlayout.COMMAND_BYTES,
                name = "mesh.blend.commands",
            }
        )
        self._blendSorted = Buffer.create(
            device,
            {
                usage = {"indirect", "computeWrite"},
                size = self.capacity * meshlayout.COMMAND_BYTES,
                name = "mesh.blend.sorted",
            }
        )
        self._blendBuckets = Buffer.create(
            device, {usage = {"computeRead", "computeWrite"}, size = self.capacity * 4, name = "mesh.blend.buckets"}
        )
        self._blendRanks = Buffer.create(
            device, {usage = {"computeRead", "computeWrite"}, size = self.capacity * 4, name = "mesh.blend.ranks"}
        )
        self._blendCounts = Buffer.create(
            device,
            {usage = {"computeRead", "computeWrite"}, size = groups * SORT_BUCKETS * 4, name = "mesh.blend.counts"}
        )
        self._rankPipeline = ComputePipeline.load(device, "mesh.rank.comp", {})
        self._placePipeline = ComputePipeline.load(device, "mesh.place.comp", {})
        self.blendPipeline = buildForward(
            device, deferred, self._shadows, self._skinning, self._morphing, self._vertexColors, self._fogging
        )
    end
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
    values[7] = data.alphaMode
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

function MeshBackend:mapSlot(slot: integer): loader.CArray, loader.CArray, loader.CArray, loader.CArray, loader.CArray
    return self.instances:mapSlotAs(slot, "float *", false),
        self._bounds:mapSlotAs(slot, "float *", false),
        self.commands:mapSlotAs(slot, "SDL_GPUIndexedIndirectDrawCommand *", false),
        self._skinning and self._instanceSkins:mapSlotAs(slot, "float *", false) or nil,
        self._morphing and self._instanceMorphs:mapSlotAs(slot, "float *", false) or nil
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
    if mesh.colorVertices ~= nil and not self._vertexColors then
        error("tecs: colored geometry requires meshes.vertexColors = true", 2)
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
        firstMorphVertex = self.morphVertexCount,
        morphTargetCount = mesh.morphTargetCount,
    } as MeshRegion
    self.vertices:upload(
        mesh.vertices, mesh.vertexCount * meshlayout.VERTEX_BYTES, region.firstVertex * meshlayout.VERTEX_BYTES
    )
    if self._vertexColors then
        local colors = mesh.colorVertices
        if colors == nil then
            colors = loader.newArray("float[?]", mesh.vertexCount * meshlayout.COLOR_VERTEX_FLOATS)
            for vertex = 0, mesh.vertexCount - 1 do
                local at <const> = vertex * meshlayout.COLOR_VERTEX_FLOATS
                colors[at], colors[at + 1], colors[at + 2], colors[at + 3] = 1.0, 1.0, 1.0, 1.0
            end
        end
        self._colorVertices:upload(
            colors, mesh.vertexCount * meshlayout.COLOR_VERTEX_BYTES, region.firstVertex * meshlayout.COLOR_VERTEX_BYTES
        )
    end
    if mesh.skinVertices ~= nil then
        if not self._skinning then
            error("tecs: skinned geometry requires meshes.skinning", 2)
        end
        self._skinVertices:upload(
            mesh.skinVertices,
            mesh.vertexCount * meshlayout.SKIN_VERTEX_BYTES,
            region.firstVertex * meshlayout.SKIN_VERTEX_BYTES
        )
    end
    if mesh.morphVertices ~= nil then
        if not self._morphing then
            error("tecs: morphed geometry requires meshes.morphing", 2)
        end
        local morphVertices <const> = mesh.vertexCount * mesh.morphTargetCount
        if self.morphVertexCount + morphVertices > self.morphVertexCapacity then
            error(
                ("tecs: mesh morph vertex capacity is %d, but registering '%s' needs %d"):format(
                    self.morphVertexCapacity, mesh.name, self.morphVertexCount + morphVertices
                ),
                2
            )
        end
        self._morphVertices:upload(
            mesh.morphVertices,
            morphVertices * meshlayout.MORPH_VERTEX_BYTES,
            region.firstMorphVertex * meshlayout.MORPH_VERTEX_BYTES
        )
        self.morphVertexCount = self.morphVertexCount + morphVertices
    end
    self.indices:upload(mesh.indices, mesh.indexCount * 4, region.firstIndex * 4)

    self.vertexCount = nextVertices
    self.indexCount = nextIndices
    self.meshCount = self.meshCount + 1
    self._regions[region.slot + 1] = region
    self._regionByAsset[asset] = region
    mesh:release()
    return region
end

function MeshBackend:registerSkin(asset: integer, matrices: {number}): SkinRegion
    if not self._skinning then
        error("tecs: mesh skinning is not enabled", 2)
    end
    local existing = self._skinRegionByAsset[asset]
    if existing ~= nil then
        return existing
    end
    if matrices == nil or #matrices == 0 or #matrices % JOINT_FLOATS ~= 0 then
        error("tecs: a mesh skin needs a non-empty multiple of 16 matrix floats", 2)
    end
    local jointCount <const> = math.floor(#matrices / JOINT_FLOATS)
    if self.jointCount + jointCount > self.jointCapacity then
        error(
            ("tecs: mesh joint capacity is %d, but registration needs %d"):format(
                self.jointCapacity, self.jointCount + jointCount
            ),
            2
        )
    end
    local region <const> = {firstJoint = self.jointCount, jointCount = jointCount} as SkinRegion
    self._skinRegionByAsset[asset] = region
    self.jointCount = self.jointCount + jointCount
    self:updateSkin(region, matrices)
    return region
end

function MeshBackend:updateSkin(region: SkinRegion, matrices: {number})
    if region == nil or matrices == nil or #matrices ~= region.jointCount * JOINT_FLOATS then
        error("tecs: mesh skin matrix count does not match its registered joint count", 2)
    end
    local first <const> = region.firstJoint * JOINT_FLOATS
    for index = 1, #matrices do
        local value <const> = matrices[index]
        if value == nil or value ~= value or value == math.huge or value == -math.huge then
            error(("tecs: mesh skin matrix float %d is not finite"):format(index), 2)
        end
        self._jointValues[first + index - 1] = value
    end
    self._jointRanges:mark(region.firstJoint * JOINT_BYTES, region.jointCount * JOINT_BYTES)
end

function MeshBackend:skinRegion(asset: integer): SkinRegion
    return self._skinRegionByAsset[asset]
end

function MeshBackend:registerMorph(asset: integer, weights: {number}): MorphRegion
    if not self._morphing then
        error("tecs: mesh morphing is not enabled", 2)
    end
    local existing = self._morphRegionByAsset[asset]
    if existing ~= nil then
        return existing
    end
    if weights == nil or #weights == 0 then
        error("tecs: mesh morph weights cannot be empty", 2)
    end
    if self.morphWeightCount + #weights > self.morphWeightCapacity then
        error(
            ("tecs: mesh morph weight capacity is %d, but registration needs %d"):format(
                self.morphWeightCapacity, self.morphWeightCount + #weights
            ),
            2
        )
    end
    local region <const> = {firstWeight = self.morphWeightCount, weightCount = #weights} as MorphRegion
    self._morphRegionByAsset[asset] = region
    self.morphWeightCount = self.morphWeightCount + #weights
    self:updateMorph(region, weights)
    return region
end

function MeshBackend:updateMorph(region: MorphRegion, weights: {number})
    if region == nil or weights == nil or #weights ~= region.weightCount then
        error("tecs: mesh morph weight count does not match its registered target count", 2)
    end
    for index, weight in ipairs(weights) do
        if weight == nil or weight ~= weight or weight == math.huge or weight == -math.huge then
            error(("tecs: mesh morph weight %d is not finite"):format(index), 2)
        end
        self._morphValues[region.firstWeight + index - 1] = weight
    end
    self._morphRanges:mark(region.firstWeight * 4, region.weightCount * 4)
end

function MeshBackend:morphRegion(asset: integer): MorphRegion
    return self._morphRegionByAsset[asset]
end

function MeshBackend:regionOf(asset: integer): MeshRegion
    return self._regionByAsset[asset]
end

local function writeShadowUniform(self: MeshBackend, packet: MeshFramePacket)
    local shadow <const> = self._shadow
    local distance <const> = shadow.distance
    if distance <= 0.0 then
        error("tecs: mesh shadow distance must be greater than 0", 3)
    end
    if shadow.intensity < 0.0 then
        error("tecs: mesh shadow intensity must be greater than or equal to 0", 3)
    end
    if shadow.strength < 0.0 or shadow.strength > 1.0 then
        error("tecs: mesh shadow strength must be between 0 and 1", 3)
    end
    if shadow.bias < 0.0 or shadow.softness < 0.0 then
        error("tecs: mesh shadow bias and softness must be greater than or equal to 0", 3)
    end
    if shadow.r < 0.0 or shadow.g < 0.0 or shadow.b < 0.0 then
        error("tecs: mesh shadow light color must be greater than or equal to 0", 3)
    end

    local dx, dy, dz = shadow.directionX, shadow.directionY, shadow.directionZ
    local magnitude <const> = math.sqrt(dx * dx + dy * dy + dz * dz)
    if magnitude == 0.0 then
        error("tecs: mesh shadow direction must not be zero", 3)
    end
    dx, dy, dz = dx / magnitude, dy / magnitude, dz / magnitude

    local ux, uy, uz = 0.0, 1.0, 0.0
    if math.abs(dy) > 0.99 then
        ux, uy = 1.0, 0.0
    end
    local rx, ry, rz = uy * dz - uz * dy, uz * dx - ux * dz, ux * dy - uy * dx
    local rightLength <const> = math.sqrt(rx * rx + ry * ry + rz * rz)
    rx, ry, rz = rx / rightLength, ry / rightLength, rz / rightLength
    local vx, vy, vz = dy * rz - dz * ry, dz * rx - dx * rz, dx * ry - dy * rx

    local cx, cy, cz <const> = packet.cameraX, packet.cameraY, packet.cameraZ
    local inverse <const> = 1.0 / distance
    local depthInverse <const> = 0.5 * inverse
    local uniform <const> = self._shadowUniform
    uniform[0], uniform[4], uniform[8] = rx * inverse, ry * inverse, rz * inverse
    uniform[1], uniform[5], uniform[9] = vx * inverse, vy * inverse, vz * inverse
    uniform[2], uniform[6], uniform[10] = dx * depthInverse, dy * depthInverse, dz * depthInverse
    uniform[3], uniform[7], uniform[11] = 0.0, 0.0, 0.0
    uniform[12] = -(rx * cx + ry * cy + rz * cz) * inverse
    uniform[13] = -(vx * cx + vy * cy + vz * cz) * inverse
    uniform[14] = 0.5 - (dx * cx + dy * cy + dz * cz) * depthInverse
    uniform[15] = 1.0
    uniform[16], uniform[17], uniform[18], uniform[19] = dx, dy, dz, shadow.intensity
    uniform[20], uniform[21], uniform[22], uniform[23] = shadow.r, shadow.g, shadow.b, shadow.strength
    uniform[24], uniform[25] = shadow.bias, shadow.softness
    uniform[26], uniform[27] = self._shadowActive and 1.0 or 0.0, 0.0
    self._deferred:setMeshLight(-dx, -dy, -dz, shadow.intensity, shadow.r, shadow.g, shadow.b)
end

function MeshBackend:prepare(packet: MeshFramePacket, frame: Frame)
    local slot <const> = packet.slot
    self.instances:markSlotRanges(slot, packet.instanceRanges)
    self._bounds:markSlotRanges(slot, packet.boundsRanges)
    self.commands:markSlotRanges(slot, packet.commandRanges)
    if self._skinning then
        self._instanceSkins:markSlotRanges(slot, packet.skinRanges)
        local ranges <const> = self._jointRanges
        local source <const> = loader.bytePointer(self._jointValues as loader.CValue)
        for entry = 0, ranges.count - 1 do
            local offset, size = ranges:at(entry)
            self._jointMatrices:writeSlot(slot, offset, source + offset, size)
        end
        ranges:clear()
    end
    if self._morphing then
        self._instanceMorphs:markSlotRanges(slot, packet.morphRanges)
        local ranges <const> = self._morphRanges
        local source <const> = loader.bytePointer(self._morphValues as loader.CValue)
        for entry = 0, ranges.count - 1 do
            local offset, size = ranges:at(entry)
            self._morphWeights:writeSlot(slot, offset, source + offset, size)
        end
        ranges:clear()
    end
    self.instances:flushSlot(slot, frame.commandBuffer)
    self._bounds:flushSlot(slot, frame.commandBuffer)
    self.commands:flushSlot(slot, frame.commandBuffer)
    if self._skinning then
        self._instanceSkins:flushSlot(slot, frame.commandBuffer)
        self._jointMatrices:flushSlot(slot, frame.commandBuffer)
    end
    if self._morphing then
        self._instanceMorphs:flushSlot(slot, frame.commandBuffer)
        self._morphWeights:flushSlot(slot, frame.commandBuffer)
    end
    self._count = packet.count
    self._viewProjection = packet.viewProjection
    if self._fogging then
        local fog <const> = self._fog
        if fog.start < 0.0 or fog.finish <= fog.start then
            error("tecs: mesh fog finish must be greater than its non-negative start", 2)
        end
        if fog.r < 0.0 or fog.r > 1.0 or fog.g < 0.0 or fog.g > 1.0 or fog.b < 0.0 or fog.b > 1.0 then
            error("tecs: mesh fog colors must be between 0 and 1", 2)
        end
        local view <const> = self._viewUniform
        for lane = 0, 15 do
            view[lane] = packet.viewProjection[lane]
        end
        view[16], view[17], view[18], view[19] = packet.cameraX, packet.cameraY, packet.cameraZ, fog.start
        view[20], view[21], view[22], view[23] = 1.0 / (fog.finish - fog.start), 0.0, 0.0, 0.0
        self._fogUniform[0], self._fogUniform[1], self._fogUniform[2], self._fogUniform[3] = fog.r, fog.g, fog.b, 0.0
        self._deferred:setMeshFog(fog.r, fog.g, fog.b)
    end
    self._blending = self._transparent and packet.blendCount > 0
    self._shadowActive = self._shadows and packet.count > packet.blendCount
    if self._shadows then
        writeShadowUniform(self, packet)
    end
    if self._count == 0 then
        return
    end

    local groups <const> = math.ceil(self._count / CULL_GROUP)
    local uniform <const> = self._cullUniform
    if self._shadowActive then
        frustum.write(self._shadowUniform, uniform)
        uniform[24] = self._count
        uniform[25] = groups
        uniform[26] = self.capacity
        uniform[27] = 0.0

        local markWrites <const> = self._shadowMarkWrites
        markWrites[1] = self._slots.handle
        markWrites[2] = self._blocks.handle
        markWrites[3] = self._shadowCommands.handle
        local markReads <const> = self._shadowMarkReads
        markReads[1] = self._bounds.handle
        if self._transparent then
            markReads[2] = self.instances.handle
        end
        local mark <const> = ComputePass.begin(frame.commandBuffer, markWrites, self._markPass)
        self._markPass = mark
        mark:bindPipeline((self._shadowMarkPipeline or self._markPipeline).handle)
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

        local compactWrites <const> = self._shadowCompactWrites
        compactWrites[1] = self._shadowCommands.handle
        local compactReads <const> = self._shadowCompactReads
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

    frustum.write(packet.viewProjection, uniform)
    uniform[24] = self._count
    uniform[25] = groups
    uniform[26] = self.capacity
    uniform[27] = 0.0
    if self._transparent then
        for lane = 0, 15 do
            uniform[28 + lane] = packet.viewProjection[lane]
        end
    end

    local markWrites <const> = self._markWrites
    markWrites[1] = self._slots.handle
    markWrites[2] = self._blocks.handle
    markWrites[3] = self._visibleCommands.handle
    local markReads <const> = self._markReads
    markReads[1] = self._bounds.handle
    if self._transparent then
        markReads[2] = self.instances.handle
        markWrites[4] = self._blendSlots.handle
        markWrites[5] = self._blendBlocks.handle
        markWrites[6] = self._blendCommands.handle
        markWrites[7] = self._blendSorted.handle
    end
    local mark <const> = ComputePass.begin(frame.commandBuffer, markWrites, self._markPass)
    self._markPass = mark
    mark:bindPipeline(self._markPipeline.handle)
    mark:bindStorageBuffers(0, markReads)
    C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, uniform, self._transparent and CULL_BYTES or 112)
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

    if self._blending then
        local blendScanWrites <const> = self._blendScanWrites
        blendScanWrites[1] = self._blendBlocks.handle
        local blendScan <const> = ComputePass.begin(frame.commandBuffer, blendScanWrites, self._blendScanPass)
        self._blendScanPass = blendScan
        blendScan:bindPipeline(self._scanPipeline.handle)
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, uniform, 112)
        blendScan:dispatch(1)
        blendScan:finish()

        local blendCompactWrites <const> = self._blendCompactWrites
        blendCompactWrites[1] = self._blendCommands.handle
        local blendCompactReads <const> = self._blendCompactReads
        blendCompactReads[1] = self._blendSlots.handle
        blendCompactReads[2] = self._blendBlocks.handle
        blendCompactReads[3] = self.commands.handle
        local blendCompact <const> = ComputePass.begin(frame.commandBuffer, blendCompactWrites, self._blendCompactPass)
        self._blendCompactPass = blendCompact
        blendCompact:bindPipeline(self._compactPipeline.handle)
        blendCompact:bindStorageBuffers(0, blendCompactReads)
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, uniform, 112)
        blendCompact:dispatch(groups)
        blendCompact:finish()

        local rankWrites <const> = self._rankWrites
        rankWrites[1] = self._blendBuckets.handle
        rankWrites[2] = self._blendRanks.handle
        rankWrites[3] = self._blendCounts.handle
        local rankReads <const> = self._rankReads
        rankReads[1] = self._bounds.handle
        rankReads[2] = self._blendCommands.handle
        local rank <const> = ComputePass.begin(frame.commandBuffer, rankWrites, self._rankPass)
        self._rankPass = rank
        rank:bindPipeline(self._rankPipeline.handle)
        rank:bindStorageBuffers(0, rankReads)
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, uniform, CULL_BYTES)
        rank:dispatch(groups)
        rank:finish()

        uniform[25] = groups * SORT_BUCKETS
        local bucketScanWrites <const> = self._bucketScanWrites
        bucketScanWrites[1] = self._blendCounts.handle
        local bucketScan <const> = ComputePass.begin(frame.commandBuffer, bucketScanWrites, self._bucketScanPass)
        self._bucketScanPass = bucketScan
        bucketScan:bindPipeline(self._scanPipeline.handle)
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, uniform, 112)
        bucketScan:dispatch(1)
        bucketScan:finish()

        uniform[25] = groups
        local placeWrites <const> = self._placeWrites
        placeWrites[1] = self._blendSorted.handle
        local placeReads <const> = self._placeReads
        placeReads[1] = self._blendCommands.handle
        placeReads[2] = self._blendBuckets.handle
        placeReads[3] = self._blendRanks.handle
        placeReads[4] = self._blendCounts.handle
        local place <const> = ComputePass.begin(frame.commandBuffer, placeWrites, self._placePass)
        self._placePass = place
        place:bindPipeline(self._placePipeline.handle)
        place:bindStorageBuffers(0, placeReads)
        C.SDL_PushGPUComputeUniformData(frame.commandBuffer, 0, uniform, CULL_BYTES)
        place:dispatch(groups)
        place:finish()
    end
end

function MeshBackend:castsThisFrame(): boolean
    return self._shadowActive
end

function MeshBackend:recordShadowMap(context: Deferred.PassContext)
    if not self._shadowActive then
        return
    end
    context.pass:bindPipeline(self.shadowPipeline.handle)
    context.pass:pushVertexUniform(0, self._shadowUniform, 64)
    local buffers <const> = self._geometryBuffers
    buffers[1] = self.vertices.handle
    buffers[2] = self.instances.handle
    local bufferSlot = 3
    if self._vertexColors then
        buffers[bufferSlot] = self._colorVertices.handle
        bufferSlot = bufferSlot + 1
    end
    if self._morphing then
        buffers[bufferSlot] = self._morphVertices.handle
        buffers[bufferSlot + 1] = self._instanceMorphs.handle
        buffers[bufferSlot + 2] = self._morphWeights.handle
        bufferSlot = bufferSlot + 3
    end
    if self._skinning then
        buffers[bufferSlot] = self._skinVertices.handle
        buffers[bufferSlot + 1] = self._instanceSkins.handle
        buffers[bufferSlot + 2] = self._jointMatrices.handle
    end
    context.pass:bindVertexStorageBuffers(0, buffers)
    local fragmentBuffers <const> = self._fragmentBuffers
    fragmentBuffers[1] = self.materials.handle
    context.pass:bindFragmentStorageBuffers(0, fragmentBuffers)
    local textures <const> = self._fragmentTextures
    textures[1] = self.images.handle
    context.pass:bindTextures(0, textures, self.sampler.handle)
    context.pass:bindIndexBuffer(self.indices.handle, RenderPass.INDEX_UINT32)
    context.pass:drawIndexedIndirect(self._shadowCommands.handle, 0, self._count)
end

function MeshBackend:recordGeometry(context: Deferred.PassContext)
    if self._count == 0 then
        return
    end
    context.pass:bindPipeline(self.pipeline.handle)
    context.pass:pushVertexUniform(
        0, self._fogging and self._viewUniform or self._viewProjection, self._fogging and 96 or 64
    )
    local buffers <const> = self._geometryBuffers
    buffers[1] = self.vertices.handle
    buffers[2] = self.instances.handle
    local bufferSlot = 3
    if self._vertexColors then
        buffers[bufferSlot] = self._colorVertices.handle
        bufferSlot = bufferSlot + 1
    end
    if self._morphing then
        buffers[bufferSlot] = self._morphVertices.handle
        buffers[bufferSlot + 1] = self._instanceMorphs.handle
        buffers[bufferSlot + 2] = self._morphWeights.handle
        bufferSlot = bufferSlot + 3
    end
    if self._skinning then
        buffers[bufferSlot] = self._skinVertices.handle
        buffers[bufferSlot + 1] = self._instanceSkins.handle
        buffers[bufferSlot + 2] = self._jointMatrices.handle
    end
    context.pass:bindVertexStorageBuffers(0, buffers)
    local fragmentBuffers <const> = self._fragmentBuffers
    fragmentBuffers[1] = self.materials.handle
    context.pass:bindFragmentStorageBuffers(0, fragmentBuffers)
    local textures <const> = self._fragmentTextures
    textures[1] = self.images.handle
    context.pass:bindTextures(self._shadows and 1 or 0, textures, self.sampler.handle)
    if self._shadows then
        C.SDL_PushGPUFragmentUniformData(context.commandBuffer, 0, self._shadowUniform, SHADOW_BYTES)
    end
    context.pass:bindIndexBuffer(self.indices.handle, RenderPass.INDEX_UINT32)
    context.pass:drawIndexedIndirect(self._visibleCommands.handle, 0, self._count)
end

function MeshBackend:recordForward(context: Deferred.PassContext)
    if not self._blending then
        return
    end
    context.pass:bindPipeline(self.blendPipeline.handle)
    context.pass:pushVertexUniform(
        0, self._fogging and self._viewUniform or self._viewProjection, self._fogging and 96 or 64
    )
    local buffers <const> = self._forwardBuffers
    buffers[1] = self.vertices.handle
    buffers[2] = self.instances.handle
    local bufferSlot = 3
    if self._vertexColors then
        buffers[bufferSlot] = self._colorVertices.handle
        bufferSlot = bufferSlot + 1
    end
    if self._morphing then
        buffers[bufferSlot] = self._morphVertices.handle
        buffers[bufferSlot + 1] = self._instanceMorphs.handle
        buffers[bufferSlot + 2] = self._morphWeights.handle
        bufferSlot = bufferSlot + 3
    end
    if self._skinning then
        buffers[bufferSlot] = self._skinVertices.handle
        buffers[bufferSlot + 1] = self._instanceSkins.handle
        buffers[bufferSlot + 2] = self._jointMatrices.handle
    end
    context.pass:bindVertexStorageBuffers(0, buffers)
    local fragmentBuffers <const> = self._fragmentBuffers
    fragmentBuffers[1] = self.materials.handle
    context.pass:bindFragmentStorageBuffers(0, fragmentBuffers)
    self._deferred:bindLighting(context, 1)
    local textures <const> = self._forwardTextures
    textures[1] = self.images.handle
    context.pass:bindTextures(self._shadows and 1 or 0, textures, self.sampler.handle)
    if self._shadows then
        C.SDL_PushGPUFragmentUniformData(context.commandBuffer, 0, self._shadowUniform, SHADOW_BYTES)
    end
    if self._fogging then
        C.SDL_PushGPUFragmentUniformData(context.commandBuffer, 2, self._fogUniform, 16)
    end
    context.pass:bindIndexBuffer(self.indices.handle, RenderPass.INDEX_UINT32)
    context.pass:drawIndexedIndirect(self._blendSorted.handle, 0, self._count)
end

function MeshBackend:rebuildPipeline(deferred: Deferred)
    local geometry <const> = buildGeometry(
        self._device, deferred, self._shadows, self._skinning, self._morphing, self._vertexColors, self._fogging
    )
    local mark <const> = ComputePipeline.load(
        self._device, self._transparent and "mesh.lanes.mark.comp" or "mesh.mark.comp", {}
    )
    local scan <const> = ComputePipeline.load(self._device, "mesh.scan.comp", {})
    local compact <const> = ComputePipeline.load(self._device, "mesh.compact.comp", {})
    local blend: GraphicsPipeline = nil
    local rank: ComputePipeline = nil
    local place: ComputePipeline = nil
    local shadow: GraphicsPipeline = nil
    local shadowMark: ComputePipeline = nil
    if self._shadows then
        shadow = buildShadow(self._device, deferred, self._skinning, self._morphing, self._vertexColors)
        if self._transparent then
            shadowMark = ComputePipeline.load(self._device, "mesh.mark.comp", {defines = {MESH_ALPHA = "1"}})
        end
    end
    if self._transparent then
        blend = buildForward(
            self._device, deferred, self._shadows, self._skinning, self._morphing, self._vertexColors, self._fogging
        )
        rank = ComputePipeline.load(self._device, "mesh.rank.comp", {})
        place = ComputePipeline.load(self._device, "mesh.place.comp", {})
    end
    local oldGeometry, oldMark, oldScan, oldCompact <const> = self.pipeline,
        self._markPipeline,
        self._scanPipeline,
        self._compactPipeline
    self.pipeline, self._markPipeline, self._scanPipeline, self._compactPipeline = geometry, mark, scan, compact
    if self._shadows then
        local oldShadow, oldShadowMark <const> = self.shadowPipeline, self._shadowMarkPipeline
        self.shadowPipeline, self._shadowMarkPipeline = shadow, shadowMark
        oldShadow:destroy()
        if oldShadowMark ~= nil then
            oldShadowMark:destroy()
        end
    end
    if self._transparent then
        local oldBlend, oldRank, oldPlace <const> = self.blendPipeline, self._rankPipeline, self._placePipeline
        self.blendPipeline, self._rankPipeline, self._placePipeline = blend, rank, place
        oldBlend:destroy()
        oldRank:destroy()
        oldPlace:destroy()
    end
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
    if self._vertexColors then
        self._colorVertices:destroy()
    end
    self.indices:destroy()
    self.instances:destroy()
    if self._skinning then
        self._skinVertices:destroy()
        self._instanceSkins:destroy()
        self._jointMatrices:destroy()
    end
    if self._morphing then
        self._morphVertices:destroy()
        self._instanceMorphs:destroy()
        self._morphWeights:destroy()
    end
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
    if self._shadows then
        self._shadowCommands:destroy()
        if self._shadowMarkPipeline ~= nil then
            self._shadowMarkPipeline:destroy()
        end
        self.shadowPipeline:destroy()
    end
    if self._transparent then
        self._blendSlots:destroy()
        self._blendBlocks:destroy()
        self._blendCommands:destroy()
        self._blendSorted:destroy()
        self._blendBuckets:destroy()
        self._blendRanks:destroy()
        self._blendCounts:destroy()
        self._rankPipeline:destroy()
        self._placePipeline:destroy()
        self.blendPipeline:destroy()
    end
end

return MeshBackend
