--[=[
Owns the complete 3D mesh rendering lane.

The domain joins mesh extraction to geometry residency, device staging, and an
opaque deferred contribution. It does not own the deferred graph,
presentation, capture, or frame-slot rotation.
`Renderer` creates it only when `meshes` options are present, so a 2D-only
application loads no mesh implementation and allocates none of these buffers.

The backend culls world-space bounding spheres and compacts indexed commands
on the GPU. That work and every buffer it touches remain private to this lane.
]=]

local type types = require("tecs.types")
local type assets = require("tecs.assets")
local ecs <const> = require("tecs.ecs")
local loader <const> = require("tecs.ffi.loader")
local Buffer <const> = require("tecs.gpu.Buffer")
local Frame <const> = require("tecs.gpu.Frame")
local Deferred <const> = require("tecs.gpu.Deferred")
local Camera3D <const> = require("tecs.gfx.Camera3D")
local MeshExtractor <const> = require("tecs.internal.render.MeshExtractor")
local MeshBackend <const> = require("tecs.internal.render.MeshBackend")
local MeshFramePacket <const> = require("tecs.internal.render.MeshFramePacket")
local components <const> = require("tecs.components")
local Transform3D <const> = ecs.Transform3D

local DEFAULT_CAPACITY <const> = 65536
local DEFAULT_VERTEX_CAPACITY <const> = 1048576
local DEFAULT_INDEX_CAPACITY <const> = 3145728
local DEFAULT_MATERIAL_CAPACITY <const> = 1024
local DEFAULT_TEXTURE_SIZE <const> = 1024
local DEFAULT_TEXTURE_LAYERS <const> = 16

local record MeshMaterialOptions
    --- Caller-writable. Supplies the stable, non-empty material name used by
    --- snapshots and duplicate registration.
    name: string
    --- Caller-writable. Selects one of the domain's `MATERIAL_*` integer
    --- constants and defaults to `MATERIAL_METALLIC_ROUGHNESS`.
    model: integer
    --- Caller-writable. Selects a texture returned by `registerTexture`, or
    --- zero for the white fallback.
    baseColorTexture: integer
    --- Caller-writable. Selects a tangent-space normal texture, or zero for a
    --- flat normal.
    normalTexture: integer
    --- Caller-writable. Selects a glTF metallic-roughness texture, or zero.
    metallicRoughnessTexture: integer
    --- Caller-writable. Selects an occlusion texture, or zero for no
    --- occlusion.
    occlusionTexture: integer
    --- Caller-writable. Selects an emissive texture, or zero for black.
    emissiveTexture: integer
    --- Caller-writable. Discards base alpha below this threshold and defaults
    --- to 0.5.
    alphaCutoff: number
    --- Caller-writable. Multiplies the base-color texture's red channel.
    baseR: number
    --- Caller-writable. Multiplies the base-color texture's green channel.
    baseG: number
    --- Caller-writable. Multiplies the base-color texture's blue channel.
    baseB: number
    --- Caller-writable. Multiplies the base-color texture's alpha channel.
    baseA: number
    --- Caller-writable. Multiplies emissive red.
    emissiveR: number
    --- Caller-writable. Multiplies emissive green.
    emissiveG: number
    --- Caller-writable. Multiplies emissive blue.
    emissiveB: number
    --- Caller-writable. Multiplies sampled metallic and defaults to 1.
    metallic: number
    --- Caller-writable. Multiplies sampled roughness and defaults to 1.
    roughness: number
    --- Caller-writable. Scales tangent-space normal xy and defaults to 1.
    normalScale: number
    --- Caller-writable. Scales sampled occlusion and defaults to 1.
    occlusionStrength: number
end

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
    --- Caller-writable. Sets the material-table ceiling, including the
    --- built-in neutral slot, and defaults to 1,024.
    materialCapacity: integer
    --- Caller-writable. Sets the width of every mesh texture-array layer and
    --- defaults to 1,024 pixels.
    textureWidth: integer
    --- Caller-writable. Sets the height of every mesh texture-array layer and
    --- defaults to 1,024 pixels.
    textureHeight: integer
    --- Caller-writable. Sets the fixed mesh texture-array layer count and
    --- defaults to 16.
    textureLayers: integer
    --- Caller-writable. Packs multiple images into each texture layer and
    --- defaults to true.
    packTextures: boolean
end

--- Contains the complete component bundle for one registered model primitive.
local record RegisteredPrimitive
    --- Caller-writable. Contains the static scene transform decoded from glTF.
    transform: ecs.Transform3D
    --- Caller-writable. Selects the primitive's resident geometry.
    mesh: components.Mesh
    --- Caller-writable. Supplies its local-space bounding sphere.
    bounds: components.Bounds3D
    --- Caller-writable. Selects its resident PBR material.
    material: components.MeshMaterial
end

local record MeshDomain
    type Options = MeshDomainOptions
    type MaterialOptions = MeshMaterialOptions
    type RegisteredPrimitive = RegisteredPrimitive

    --- Read-only. Selects metallic-roughness PBR material dispatch.
    MATERIAL_METALLIC_ROUGHNESS: integer
    --- Read-only. Selects unlit material dispatch.
    MATERIAL_UNLIT: integer

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
    --- Read-only. Reports resident material slots, including the neutral
    --- built-in slot zero.
    materialCount: integer
    --- Read-only. Reports unique images uploaded to the mesh texture array.
    textureCount: integer
    --- Engine-owned. Exposes immutable vertex storage to the opaque
    --- mesh pass. Ordinary game code should ignore it.
    vertices: Buffer
    --- Engine-owned. Exposes immutable 32-bit index storage to the
    --- opaque mesh pass. Ordinary game code should ignore it.
    indices: Buffer
    --- Engine-owned. Exposes mesh instances to the opaque draw and GPU cull
    --- passes. Ordinary game code should ignore it.
    instances: Buffer
    --- Engine-owned. Exposes the resident material table to the mesh fragment
    --- stage. Ordinary game code should ignore it.
    materials: Buffer

    --- Registers immutable CPU geometry in this domain.
    --- @param mesh The caller supplies CPU geometry that this call consumes.
    --- @return Returns a mesh component ready to spawn.
    --- @return Returns its asset-derived local bounding sphere.
    registerMesh: function(self, mesh: assets.Mesh): components.Mesh, components.Bounds3D

    _extractor: MeshExtractor
    _backend: MeshBackend
    _packet: MeshFramePacket
    _centerXByAsset: {integer: number}
    _centerYByAsset: {integer: number}
    _centerZByAsset: {integer: number}
    _radiusByAsset: {integer: number}
end

local MeshDomainMT <const>: metatable<MeshDomain> = {__index = MeshDomain}

MeshDomain.MATERIAL_METALLIC_ROUGHNESS = 0
MeshDomain.MATERIAL_UNLIT = 1

local function positive(name: string, value: integer): integer
    if value < 1 or value ~= math.floor(value) then
        error(("tecs: %s must be a positive integer"):format(name), 3)
    end
    return value
end

function MeshDomain._create(device: loader.CPtr, deferred: Deferred, options: MeshDomainOptions): MeshDomain
    options = options or {}
    local capacity <const> = positive("mesh capacity", options.capacity or DEFAULT_CAPACITY)
    local vertexCapacity <const> = positive("mesh vertex capacity", options.vertexCapacity or DEFAULT_VERTEX_CAPACITY)
    local indexCapacity <const> = positive("mesh index capacity", options.indexCapacity or DEFAULT_INDEX_CAPACITY)
    local materialCapacity <const> = positive(
        "mesh material capacity", options.materialCapacity or DEFAULT_MATERIAL_CAPACITY
    )
    local textureWidth <const> = positive("mesh texture width", options.textureWidth or DEFAULT_TEXTURE_SIZE)
    local textureHeight <const> = positive("mesh texture height", options.textureHeight or DEFAULT_TEXTURE_SIZE)
    local textureLayers <const> = positive("mesh texture layers", options.textureLayers or DEFAULT_TEXTURE_LAYERS)

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
    self.materialCount = 1
    self.textureCount = 0
    self._centerXByAsset = {}
    self._centerYByAsset = {}
    self._centerZByAsset = {}
    self._radiusByAsset = {}
    self._packet = MeshFramePacket.create()

    local backend <const> = MeshBackend.create(
        device,
        deferred,
        {
            capacity = capacity,
            vertexCapacity = vertexCapacity,
            indexCapacity = indexCapacity,
            materialCapacity = materialCapacity,
            textureWidth = textureWidth,
            textureHeight = textureHeight,
            textureLayers = textureLayers,
            packTextures = options.packTextures ~= false,
        }
    )
    self._backend = backend
    self.vertices = backend.vertices
    self.indices = backend.indices
    self.instances = backend.instances
    self.materials = backend.materials

    local extractor <const> = MeshExtractor.create({capacity = capacity})
    self._extractor = extractor
    self.camera = extractor.camera
    return self
end

--- Uploads one decoded image into mesh-domain texture residency.
---
--- Images share one linearly filtered array. Registration consumes the
--- caller's image hold and returns a compact integer used by material options.
--- Texture count is independent from triangle and instance counts.
--- @param image The caller supplies decoded pixels that this call consumes.
--- @return Returns a positive texture identity local to this domain.
function MeshDomain:registerTexture(image: assets.Image): integer
    if image == nil then
        error("tecs: mesh texture image is required", 2)
    end
    local texture <const> = self._backend:registerTexture(image)
    self.textureCount = self._backend.textureCount
    return texture
end

--- Registers one immutable mesh material and returns its ECS reference.
---
--- Registering the same normalized name again returns the original slot.
--- Texture fields are integer identities returned by `registerTexture`; zero
--- selects the semantic fallback without consuming a texture layer.
--- @param options The caller supplies a stable name and optional PBR inputs.
--- @return Returns a material component ready to spawn.
function MeshDomain:registerMaterial(options: MeshMaterialOptions): components.MeshMaterial
    if options == nil or options.name == nil or options.name == "" then
        error("tecs: mesh material name cannot be empty", 2)
    end
    local model <const> = options.model or MeshDomain.MATERIAL_METALLIC_ROUGHNESS
    if model ~= MeshDomain.MATERIAL_METALLIC_ROUGHNESS and model ~= MeshDomain.MATERIAL_UNLIT then
        error(("tecs: invalid mesh material model %s"):format(tostring(model)), 2)
    end
    local asset <const> = components.meshMaterialId(options.name)
    local slot <const> = self._backend:registerMaterial(
        asset,
        {
            name = options.name,
            model = model,
            baseColorTexture = options.baseColorTexture or 0,
            normalTexture = options.normalTexture or 0,
            metallicRoughnessTexture = options.metallicRoughnessTexture or 0,
            occlusionTexture = options.occlusionTexture or 0,
            emissiveTexture = options.emissiveTexture or 0,
            alphaCutoff = options.alphaCutoff or 0.5,
            baseR = options.baseR or 1.0,
            baseG = options.baseG or 1.0,
            baseB = options.baseB or 1.0,
            baseA = options.baseA or 1.0,
            emissiveR = options.emissiveR or 0.0,
            emissiveG = options.emissiveG or 0.0,
            emissiveB = options.emissiveB or 0.0,
            metallic = options.metallic or 1.0,
            roughness = options.roughness or 1.0,
            normalScale = options.normalScale or 1.0,
            occlusionStrength = options.occlusionStrength or 1.0,
        }
    )
    self._extractor:registerMaterial(asset, slot)
    self.materialCount = self._backend.materialCount
    return components.MeshMaterial(asset, slot)
end

--- Returns a component for material data already registered by name.
--- @param name The caller supplies the stable registered name.
--- @return Returns a material component carrying the resident slot.
function MeshDomain:material(name: string): components.MeshMaterial
    local asset <const> = components.meshMaterialId(name)
    local slot <const> = self._backend:materialSlot(asset)
    if slot == nil then
        error(("tecs: no mesh material is registered as '%s'"):format(name), 2)
    end
    return components.MeshMaterial(asset, slot)
end

--- Registers every image, material, and primitive in a decoded static model.
---
--- Registration consumes the model's CPU geometry and image holds. The
--- returned records are caller-owned templates: spawn each record's transform,
--- mesh, bounds, and material beside `Tint` and `Renderable3D`.
--- @param model The caller supplies a ready `assets.Model` that this call
---     consumes.
--- @return Returns one registered record per primitive instance in the glTF
---     scene selected by the file.
function MeshDomain:registerModel(model: assets.Model): {RegisteredPrimitive}
    if model == nil then
        error("tecs: model data is required", 2)
    end
    local registered: {RegisteredPrimitive} = nil
    local ok, reason = pcall(function()
        local textures: {integer} = {}
        local function texture(index: integer): integer
            if index == 0 then
                return 0
            end
            local resident = textures[index]
            if resident ~= nil then
                return resident
            end
            local image = model.images[index]
            if image == nil then
                error(("tecs: model material names missing image %d"):format(index), 0)
            end
            resident = self:registerTexture(image)
            textures[index] = resident
            return resident
        end
        local materials: {components.MeshMaterial} = {}
        for index, material in ipairs(model.materials) do
            materials[index] = self:registerMaterial({
                name = material.name,
                model = material.model,
                baseColorTexture = texture(material.baseColorImage),
                normalTexture = texture(material.normalImage),
                metallicRoughnessTexture = texture(material.metallicRoughnessImage),
                occlusionTexture = texture(material.occlusionImage),
                emissiveTexture = texture(material.emissiveImage),
                alphaCutoff = material.alphaCutoff,
                baseR = material.baseR,
                baseG = material.baseG,
                baseB = material.baseB,
                baseA = material.baseA,
                emissiveR = material.emissiveR,
                emissiveG = material.emissiveG,
                emissiveB = material.emissiveB,
                metallic = material.metallic,
                roughness = material.roughness,
                normalScale = material.normalScale,
                occlusionStrength = material.occlusionStrength,
            })
        end
        local meshes: {components.Mesh} = {}
        local bounds: {components.Bounds3D} = {}
        for index, mesh in ipairs(model.meshes) do
            meshes[index], bounds[index] = self:registerMesh(mesh)
        end
        registered = {}
        for index, draw in ipairs(model.draws) do
            if meshes[draw.mesh] == nil then
                error(("tecs: model draw names missing mesh %d"):format(draw.mesh), 0)
            end
            local material = materials[draw.material]
            if draw.material ~= 0 and material == nil then
                error(("tecs: model draw names missing material %d"):format(draw.material), 0)
            end
            registered[index] = {
                transform = Transform3D.new({
                    x = draw.x,
                    y = draw.y,
                    z = draw.z,
                    rotationX = draw.rotationX,
                    rotationY = draw.rotationY,
                    rotationZ = draw.rotationZ,
                    rotationW = draw.rotationW,
                    scaleX = draw.scaleX,
                    scaleY = draw.scaleY,
                    scaleZ = draw.scaleZ,
                }),
                mesh = meshes[draw.mesh],
                bounds = bounds[draw.mesh],
                material = material or components.MeshMaterial(),
            }
        end
    end) as (boolean, any)
    model:release()
    if not ok then
        error(tostring(reason), 0)
    end
    return registered
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

function MeshDomain:_recordGeometry(context: Deferred.PassContext)
    self._backend:recordGeometry(context)
end

function MeshDomain:_rebuildPipelines(deferred: Deferred)
    self._backend:rebuildPipeline(deferred)
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
    self._extractor:registerMesh(asset, region.slot, region.firstVertex, region.firstIndex, region.indexCount)
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
