--[=[
Owns the complete 3D mesh rendering lane.

The domain joins mesh extraction to geometry residency, device staging, an
opaque deferred contribution, and an optional transparent forward
contribution. It does not own the deferred graph, presentation, capture, or
frame-slot rotation.
`Renderer` creates it only when `meshes` options are present, so a 2D-only
application loads no mesh implementation and allocates none of these buffers.

Mesh materials select metallic-roughness Cook-Torrance, unlit, or Lambert
dispatch with integer `MATERIAL_*` constants. Lambert keeps matte direct light
independent of the viewer while sharing texture, normal, occlusion, fog,
shadow, and local-light infrastructure with the PBR path.

The backend culls world-space bounding spheres and compacts indexed commands
on the GPU. A domain created with `transparency = true` also classifies glTF
`BLEND` materials, compacts them separately, and stably sorts their complete
commands back to front. A domain without that option creates none of the
sorting buffers, compute pipelines, or forward graphics pipeline.
A domain created with `doubleSided = true` classifies opaque and masked
materials into a second compacted command lane and draws it through a cull-none
pipeline. A domain without that option creates none of those resources.
A domain created with `shadows` adds three camera-frustum directional shadow
cascades. Each light-space center snaps to shadow texels so camera translation
does not slide the sampling grid under stationary geometry. Opaque and masked
meshes cast; opaque, masked, and blended meshes receive. The maps, pipeline,
and lighting shader variant do not exist otherwise.
A domain created with `skinning` adds separate vertex influence,
per-instance palette-offset, and joint-matrix buffers plus skinned geometry and
shadow shader variants. A rigid domain retains the original vertex and
instance layouts and creates none of those resources.
A domain created with `morphing` adds immutable position, normal, and tangent
deltas, per-instance locators, retained weight vectors, and morph shader
variants. A domain without it creates none of those resources. When both
deformation lanes exist, morphing runs before skinning.
A domain created with `vertexColors = true` adds a separate immutable RGBA
vertex stream and matching shader variants. The base vertex stride is unchanged
when the lane is disabled.
A domain created with `lights` extracts point and spot lights into its own
buffer and bins them in screen tiles for each 3D view. A domain without it
creates no local-light buffers, compute pipeline, queries, or shader variant.
A domain created with `probe` shades meshes from six world-space irradiance
faces. A domain without it pushes no probe uniform and selects shader variants
that perform no probe work.
A domain created with `environment` owns a separate six-layer mipmapped image,
adds roughness-dependent specular environment lighting, and can draw that image
as the sky. Its six decoded RGBA8 faces are registered once after asynchronous
loading. A domain without it allocates and binds none of those resources.
A domain created with `ssao` reconstructs opaque positions from depth into a
scaled single-channel target, edge-blurs it, and multiplies it into authored
ambient occlusion. Its targets, sampler, uniforms, and three pipelines are
absent otherwise, and its result never reaches transparent meshes or sprites.
Mipmapped RGBA8 layers generate their chains on the GPU after upload. A domain
using `TEXTURE_BC3` instead consumes complete chains prepared by the asset
importer and keeps them compressed in GPU memory. This format is an explicit
integer option and never changes the sprite texture array.
]=]

local type types = require("tecs.types")
local type assets = require("tecs.assets")
local loader <const> = require("tecs.ffi.loader")
local Frame <const> = require("tecs.gpu.Frame")
local Deferred <const> = require("tecs.gpu.Deferred")
local Camera3D <const> = require("tecs.gfx.Camera3D")
local Model3D <const> = require("tecs.gfx.Model3D")
local MeshExtractor <const> = require("tecs.internal.render.MeshExtractor")
local MeshBackend <const> = require("tecs.internal.render.MeshBackend")
local MeshFramePacket <const> = require("tecs.internal.render.MeshFramePacket")
local domainmetrics <const> = require("tecs.internal.render.domainmetrics")
local type DomainStats = domainmetrics.Stats
local meshconstants <const> = require("tecs.internal.render.meshconstants")
local type modeltypes = require("tecs.internal.render.modeltypes")
local components <const> = require("tecs.components")

local DEFAULT_CAPACITY <const> = 65536
local DEFAULT_VERTEX_CAPACITY <const> = 1048576
local DEFAULT_INDEX_CAPACITY <const> = 3145728
local DEFAULT_MATERIAL_CAPACITY <const> = 1024
local DEFAULT_TEXTURE_SIZE <const> = 1024
local DEFAULT_TEXTURE_LAYERS <const> = 16
local DEFAULT_ENVIRONMENT_SIZE <const> = 64
local DEFAULT_JOINT_CAPACITY <const> = 4096
local DEFAULT_MORPH_VERTEX_CAPACITY <const> = 1048576
local DEFAULT_MORPH_WEIGHT_CAPACITY <const> = 65536
local meshlightlayout <const> = require("tecs.gpu.meshlightlayout")

local record MeshMaterialOptions
    --- Caller-writable. Supplies the stable, non-empty material name used by
    --- snapshots and duplicate registration.
    name: string
    --- Caller-writable. Selects one of the domain's `MATERIAL_*` integer
    --- constants and defaults to `MATERIAL_METALLIC_ROUGHNESS`.
    model: integer
    --- Caller-writable. Selects opaque, masked, or blended rendering with an
    --- `ALPHA_*` integer constant and defaults to `ALPHA_OPAQUE`.
    alphaMode: integer
    --- Caller-writable. Renders both triangle faces and defaults to false.
    --- This requires `meshes.doubleSided = true`.
    doubleSided: boolean
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

--- Controls one directional light and its three mesh shadow cascades at runtime.
--- The renderer reads assignments on the next frame. Rendering raises when
--- `distance` does not exceed the camera near plane, a light color or
--- `intensity` is negative,
--- `strength` is outside zero through one, `bias`, `softness`, or
--- `depthPadding` is negative, cascade controls are outside their ranges,
--- or the three direction fields form a zero vector.
local interface MeshShadowTuning
    --- Caller-writable. Sets the maximum camera distance covered by directional
    --- shadows in world units, must exceed the camera near plane, and defaults
    --- to 100.
    distance: number
    --- Caller-writable. Blends logarithmic and uniform cascade placement from
    --- zero through one and defaults to 0.7. Larger values reserve more detail
    --- near the camera.
    splitLambda: number
    --- Caller-writable. Cross-fades each cascade boundary over this fraction
    --- of the cascade's depth range, ranges from zero through 0.5, and defaults
    --- to 0.1.
    splitBlend: number
    --- Caller-writable. Extends each light-space depth range in world units to
    --- keep off-frustum casters and receivers, must be non-negative, and
    --- defaults to 20.
    depthPadding: number
    --- Caller-writable. Sets the x direction light rays travel and defaults
    --- to negative 0.5.
    directionX: number
    --- Caller-writable. Sets the y direction light rays travel and defaults
    --- to negative one.
    directionY: number
    --- Caller-writable. Sets the z direction light rays travel and defaults
    --- to negative 0.5. The three direction fields must not all be zero.
    directionZ: number
    --- Caller-writable. Sets non-negative directional-light red and defaults
    --- to one.
    r: number
    --- Caller-writable. Sets non-negative directional-light green and
    --- defaults to one.
    g: number
    --- Caller-writable. Sets non-negative directional-light blue and defaults
    --- to one.
    b: number
    --- Caller-writable. Scales directional-light contribution, must be
    --- non-negative, and defaults to one.
    intensity: number
    --- Caller-writable. Sets shadow occlusion from zero to one and defaults
    --- to one.
    strength: number
    --- Caller-writable. Sets non-negative receiver clip-depth bias and
    --- defaults to 0.0015.
    bias: number
    --- Caller-writable. Sets the 3x3 PCF radius in texels. Zero selects one
    --- sample and the default is one.
    softness: number
end

--- Configures one directional light and its three mesh shadow cascades.
local record MeshShadowOptions is MeshShadowTuning
    --- Caller-writable. Sets every shadow-map size relative to the frame and
    --- defaults to one. It must be positive and is fixed at renderer creation.
    scale: number
end

--- Configures independently allocated GPU skeletal-deformation resources.
local record MeshSkinningOptions
    --- Caller-writable. Sets the total resident joint-matrix ceiling and
    --- defaults to 4,096.
    jointCapacity: integer
end

--- Configures independently allocated GPU morph-deformation resources.
local record MeshMorphingOptions
    --- Caller-writable. Sets the resident target-vertex ceiling and defaults
    --- to 1,048,576. One target on a 1,000-vertex mesh consumes 1,000.
    vertexCapacity: integer
    --- Caller-writable. Sets the total per-instance weight ceiling and
    --- defaults to 65,536.
    weightCapacity: integer
end

--- Configures point and spot shadows inside the optional local-light lane.
local record MeshLocalShadowOptions
    --- Caller-writable. Sets how many flagged local lights may cast shadows
    --- and defaults to four. Selection follows stable light extraction order.
    capacity: integer
    --- Caller-writable. Sets one atlas cell edge in pixels and defaults to 256.
    --- A point light consumes six cells and a spot light consumes one.
    size: integer
    --- Caller-writable. Sets normalized receiver depth bias and defaults to
    --- 0.002.
    bias: number
    --- Caller-writable. Sets the 3x3 PCF radius in texels. Zero selects one
    --- sample and the default is one.
    softness: number
end

--- Configures independently allocated point and spot light resources.
local record MeshLightOptions
    --- Caller-writable. Sets the extracted 3D local-light ceiling and defaults
    --- to 256. Lights beyond it are ignored in stable extraction order.
    capacity: integer
    --- Caller-writable. Enables the independently allocated local-shadow
    --- atlas. Nil keeps its resources and shader variants absent.
    shadows: MeshLocalShadowOptions
end

--- Controls linear camera-distance fog at runtime.
local interface MeshFogTuning
    --- Caller-writable. Sets the distance where fog begins and defaults to 20.
    start: number
    --- Caller-writable. Sets the distance where fog is complete, must exceed
    --- `start`, and defaults to 100.
    finish: number
    --- Caller-writable. Sets fog red from zero through one.
    r: number
    --- Caller-writable. Sets fog green from zero through one.
    g: number
    --- Caller-writable. Sets fog blue from zero through one.
    b: number
end

--- Enables the mesh-only fog shader and G-buffer variants.
local record MeshFogOptions is MeshFogTuning
end

--- Controls one mesh-only ambient-cube light probe at runtime.
---
--- Each RGB triplet is irradiance arriving from the named world-space axis.
--- The shader blends the six faces by the squared components of the surface
--- normal. Values must be non-negative and may exceed one for HDR lighting.
local interface MeshProbeTuning
    --- Caller-writable. Sets irradiance arriving from positive world X.
    positiveX: {number}
    --- Caller-writable. Sets irradiance arriving from negative world X.
    negativeX: {number}
    --- Caller-writable. Sets irradiance arriving from positive world Y.
    positiveY: {number}
    --- Caller-writable. Sets irradiance arriving from negative world Y.
    negativeY: {number}
    --- Caller-writable. Sets irradiance arriving from positive world Z.
    positiveZ: {number}
    --- Caller-writable. Sets irradiance arriving from negative world Z.
    negativeZ: {number}
    --- Caller-writable. Scales all six faces and defaults to one.
    intensity: number
end

--- Enables the mesh-only ambient-cube probe shader variants.
local record MeshProbeOptions is MeshProbeTuning
end

--- Controls one mesh-only specular environment at runtime.
---
--- The first implementation selects from the GPU-generated mip chain by
--- material roughness and uses an analytic split-sum BRDF approximation. It
--- deliberately keeps the six-face upload contract separate from ordinary
--- material textures so enabling it changes no material residency limits.
local interface MeshEnvironmentTuning
    --- Caller-writable. Scales reflected environment light, must be
    --- non-negative, and defaults to one.
    intensity: number
    --- Caller-writable. Scales the environment shown behind geometry, must be
    --- non-negative, and defaults to one. Zero hides the sky without removing
    --- reflected environment light.
    skyboxIntensity: number
    --- Caller-writable. Rotates the environment around world Y in radians and
    --- defaults to zero.
    rotation: number
end

--- Enables independently allocated specular-environment resources.
local record MeshEnvironmentOptions is MeshEnvironmentTuning
    --- Caller-writable. Sets every square face's width and height in pixels,
    --- defaults to 64, and is fixed at renderer creation.
    size: integer
end

--- Supplies the six decoded RGBA8 faces of one specular environment.
---
--- Faces use the conventional positive X, negative X, positive Y, negative Y,
--- positive Z, negative Z order. `registerEnvironment` consumes every image
--- after validating the complete set.
local record MeshEnvironmentFaces
    --- Caller-writable. Supplies the face viewed along positive world X.
    positiveX: assets.Image
    --- Caller-writable. Supplies the face viewed along negative world X.
    negativeX: assets.Image
    --- Caller-writable. Supplies the face viewed along positive world Y.
    positiveY: assets.Image
    --- Caller-writable. Supplies the face viewed along negative world Y.
    negativeY: assets.Image
    --- Caller-writable. Supplies the face viewed along positive world Z.
    positiveZ: assets.Image
    --- Caller-writable. Supplies the face viewed along negative world Z.
    negativeZ: assets.Image
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
    --- Caller-writable. Allocates and linearly filters a complete mip chain.
    --- This requires `packTextures = false`. Smaller RGBA images repeat their
    --- edge through the rest of the cell before mip generation.
    mipmaps: boolean
    --- Caller-writable. Selects decoded RGBA8 or imported BC3 storage with a
    --- `TEXTURE_*` integer constant and defaults to `TEXTURE_RGBA8`. BC3
    --- requires mipmaps and disables texture packing.
    textureFormat: integer
    --- Caller-writable. Enables the independently allocated transparent mesh
    --- lane and defaults to false.
    transparency: boolean
    --- Caller-writable. Enables independently allocated double-sided command
    --- and pipeline resources and defaults to false.
    doubleSided: boolean
    --- Caller-writable. Enables and configures one independently allocated
    --- directional mesh-shadow lane. Nil disables it.
    shadows: MeshShadowOptions
    --- Caller-writable. Enables independently allocated skin attributes,
    --- per-instance palette offsets, joint matrices, and shader variants. Nil
    --- disables GPU skinning.
    skinning: MeshSkinningOptions
    --- Caller-writable. Enables independently allocated morph deltas,
    --- per-instance metadata and weights, and shader variants. Nil disables
    --- GPU morphing.
    morphing: MeshMorphingOptions
    --- Caller-writable. Enables independently allocated point and spot light
    --- extraction, buffers, screen-tile binning, and shader variants. Nil
    --- disables local 3D lights.
    lights: MeshLightOptions
    --- Caller-writable. Enables a separate immutable linear RGBA vertex-color
    --- stream and shader variants. Defaults to false. A colored procedural or
    --- glTF mesh requires this option.
    vertexColors: boolean
    --- Caller-writable. Enables linear camera-distance fog for meshes. Nil
    --- omits its shader variants and runtime work.
    fog: MeshFogOptions
    --- Caller-writable. Enables diffuse environment lighting for meshes. Nil
    --- omits its shader variants and runtime work.
    probe: MeshProbeOptions
    --- Caller-writable. Enables a six-face specular environment and optional
    --- skybox. Nil allocates no environment texture or sampler.
    environment: MeshEnvironmentOptions
    --- Caller-writable. Enables half-resolution screen-space ambient
    --- occlusion for opaque meshes. Nil allocates no AO targets or pipelines.
    ssao: Deferred.SSAOOptions
end

local type RegisteredPrimitive = Model3D.Primitive

local interface MeshDomain is DomainStats
    type Options = MeshDomainOptions
    type MaterialOptions = MeshMaterialOptions
    type ShadowOptions = MeshShadowOptions
    type Shadow = MeshShadowTuning
    type SkinningOptions = MeshSkinningOptions
    type MorphingOptions = MeshMorphingOptions
    type LightOptions = MeshLightOptions
    type LocalShadowOptions = MeshLocalShadowOptions
    type FogOptions = MeshFogOptions
    type Fog = MeshFogTuning
    type ProbeOptions = MeshProbeOptions
    type Probe = MeshProbeTuning
    type EnvironmentOptions = MeshEnvironmentOptions
    type Environment = MeshEnvironmentTuning
    type EnvironmentFaces = MeshEnvironmentFaces
    type SSAOOptions = Deferred.SSAOOptions
    type SSAO = Deferred.SSAO
    type RegisteredPrimitive = RegisteredPrimitive
    type Model3D = Model3D

    --- Read-only. Selects metallic-roughness PBR material dispatch.
    MATERIAL_METALLIC_ROUGHNESS: integer
    --- Read-only. Selects unlit material dispatch.
    MATERIAL_UNLIT: integer
    --- Read-only. Selects diffuse-only Lambert material dispatch.
    MATERIAL_LAMBERT: integer
    --- Read-only. Selects an opaque material that ignores base alpha.
    ALPHA_OPAQUE: integer
    --- Read-only. Selects an opaque material that discards below `alphaCutoff`.
    ALPHA_MASK: integer
    --- Read-only. Selects a material drawn in the sorted forward lane.
    ALPHA_BLEND: integer
    --- Read-only. Selects decoded RGBA8 mesh textures.
    TEXTURE_RGBA8: integer
    --- Read-only. Selects imported BC3 mesh textures with complete mip chains.
    TEXTURE_BC3: integer

    --- Caller-writable. Controls the perspective view used by this domain.
    camera: Camera3D
    --- Read-only. Reports the mesh-instance capacity fixed at creation.
    capacity: integer
    --- Read-only. Reports the vertex capacity fixed at creation.
    vertexCapacity: integer
    --- Read-only. Reports the 32-bit index capacity fixed at creation.
    indexCapacity: integer
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
    --- Read-only. Reports resident joint matrices in the optional skin lane.
    jointCount: integer
    --- Read-only. Reports resident target vertices in the optional morph lane.
    morphVertexCount: integer
    --- Read-only. Reports resident per-instance weights in the optional morph lane.
    morphWeightCount: integer
    --- Read-only. Reports whether this domain owns the optional transparent
    --- command and pipeline resources.
    transparency: boolean
    --- Read-only. Reports whether this domain owns optional double-sided
    --- command and pipeline resources.
    doubleSided: boolean
    --- Read-only. Reports whether mesh images own complete mip chains.
    mipmaps: boolean
    --- Read-only. Reports the selected `TEXTURE_*` storage format.
    textureFormat: integer
    --- Read-only. Reports whether this domain owns mesh-shadow resources.
    shadows: boolean
    --- Read-only. Reports whether this domain owns GPU skinning resources.
    skinning: boolean
    --- Read-only. Reports whether this domain owns GPU morph resources.
    morphing: boolean
    --- Read-only. Reports whether point and spot mesh lights are enabled.
    localLights: boolean
    --- Read-only. Reports whether the local-light shadow atlas is enabled.
    localShadows: boolean
    --- Read-only. Reports shadowed local lights selected for the last frame.
    localShadowCount: integer
    --- Read-only. Reports the fixed local-light capacity, or zero when the
    --- lane is disabled.
    lightCapacity: integer
    --- Read-only. Reports local lights extracted for the last frame.
    lightCount: integer
    --- Read-only. Reports whether this domain owns vertex-color resources.
    vertexColors: boolean
    --- Read-only. Reports whether mesh fog shader variants are enabled.
    fogging: boolean
    --- Read-only. Reports whether ambient-cube probe variants are enabled.
    probing: boolean
    --- Read-only. Reports whether specular-environment resources are enabled.
    environmentLighting: boolean
    --- Read-only. Reports the fixed square environment face size, or zero
    --- while the lane is disabled.
    environmentSize: integer
    --- Read-only. Reports whether all six environment faces were uploaded.
    environmentReady: boolean
    --- Caller-writable. Controls enabled screen-space ambient occlusion. Nil
    --- while the domain omits `ssao`.
    ssao: Deferred.SSAO
    --- Caller-writable. Controls the enabled directional light and shadow cascades.
    --- Nil while shadows are disabled.
    shadow: MeshShadowTuning
    --- Caller-writable. Controls enabled mesh fog. Nil while fog is disabled.
    fog: MeshFogTuning
    --- Caller-writable. Controls enabled diffuse ambient-cube lighting. Nil
    --- while the probe is disabled.
    probe: MeshProbeTuning
    --- Caller-writable. Controls enabled specular environment lighting. Nil
    --- while the environment lane is disabled.
    environment: MeshEnvironmentTuning
    --- Replaces all six faces of the enabled specular environment.
    ---
    --- Every face must be a square RGBA8 image of `environmentSize` pixels.
    --- Validation happens before any upload; a successful call consumes all
    --- six image holds and regenerates the roughness mip chain.
    --- @param faces The caller supplies one decoded image per world-space axis.
    registerEnvironment: function(self, faces: MeshEnvironmentFaces)
    --- Registers immutable CPU geometry in this domain.
    --- @param mesh The caller supplies CPU geometry that this call consumes.
    --- @return Returns a mesh component ready to spawn.
    --- @return Returns its asset-derived local bounding sphere.
    registerMesh: function(self, mesh: assets.Mesh): components.Mesh, components.Bounds3D

    --- Registers one fixed-size joint palette for GPU deformation.
    --- @param name The caller supplies a stable non-empty palette name.
    --- @param matrices The caller supplies sixteen column-major floats per joint.
    --- @return Returns a palette component ready to spawn.
    registerSkin: function(self, name: string, matrices: {number}): components.MeshSkin

    --- Replaces every matrix in a registered palette before the next frame.
    --- @param skin The caller supplies the component returned by `registerSkin`.
    --- @param matrices The caller supplies the same matrix count used at registration.
    updateSkin: function(self, skin: components.MeshSkin, matrices: {number})

    --- Registers one fixed-size morph-weight vector.
    --- @param name The caller supplies a stable non-empty weight-vector name.
    --- @param weights The caller supplies one finite value per target.
    --- @return Returns a morph component ready to spawn.
    registerMorph: function(self, name: string, weights: {number}): components.MeshMorph

    --- Replaces every value in a registered morph-weight vector.
    --- @param morph The caller supplies the component returned by `registerMorph`.
    --- @param weights The caller supplies the same count used at registration.
    updateMorph: function(self, morph: components.MeshMorph, weights: {number})

    --- Registers shared residency for one decoded glTF model.
    --- @param model The caller supplies model data that this call consumes.
    --- @return Returns resident resources that create independent instances.
    registerModel: function(self, model: assets.Model): Model3D

    --- Uploads one decoded image into mesh-domain texture residency.
    ---
    --- Images share one linearly filtered array. Registration consumes the
    --- caller's image hold and returns a compact integer used by material options.
    --- Texture count is independent from triangle and instance counts.
    --- @param image The caller supplies decoded pixels that this call consumes.
    --- @return Returns a positive texture identity local to this domain.
    registerTexture: function(self, image: assets.Image): integer

    --- Registers one immutable mesh material and returns its ECS reference.
    ---
    --- Registering the same normalized name again returns the original slot.
    --- Texture fields are integer identities returned by `registerTexture`; zero
    --- selects the semantic fallback without consuming a texture layer.
    --- @param options The caller supplies a stable name and optional PBR inputs.
    --- @return Returns a material component ready to spawn.
    registerMaterial: function(self, options: MeshMaterialOptions): components.MeshMaterial

    --- Returns a component for material data already registered by name.
    --- @param name The caller supplies the stable registered name.
    --- @return Returns a material component carrying the resident slot.
    material: function(self, name: string): components.MeshMaterial

    --- Returns components for geometry already registered under a name.
    --- @param name The caller supplies the registered mesh name.
    --- @return Returns a mesh component carrying the resident slot.
    --- @return Returns its asset-derived local bounding sphere.
    mesh: function(self, name: string): components.Mesh, components.Bounds3D
end

local interface MeshDomainInternal is MeshDomain
    _install: function(self, world: types.World)
    _setStaging: function(self, slot: integer)
    _recordGeometry: function(self, context: Deferred.PassContext)
    _recordForward: function(self, context: Deferred.PassContext)
    _castsThisFrame: function(self): boolean
    _recordShadowMap: function(self, context: Deferred.PassContext, cascade: integer)
    _rebuildPipelines: function(self, deferred: Deferred)
    _prepare: function(self, frame: Frame, camera?: Camera3D, width?: number, height?: number, upload?: boolean)
    _device: function(self): loader.CPtr
    _destroy: function(self)
end

local record MeshDomainImpl is MeshDomainInternal
    _extractor: MeshExtractor
    _backend: MeshBackend
    _packet: MeshFramePacket
    _centerXByAsset: {integer: number}
    _centerYByAsset: {integer: number}
    _centerZByAsset: {integer: number}
    _radiusByAsset: {integer: number}
    _modelCount: integer
end

local record MeshDomainModule
    type Domain = MeshDomain
    type Internal = MeshDomainInternal
    type Options = MeshDomainOptions
    type MaterialOptions = MeshMaterialOptions
    type ShadowOptions = MeshShadowOptions
    type Shadow = MeshShadowTuning
    type SkinningOptions = MeshSkinningOptions
    type MorphingOptions = MeshMorphingOptions
    type LightOptions = MeshLightOptions
    type LocalShadowOptions = MeshLocalShadowOptions
    type FogOptions = MeshFogOptions
    type Fog = MeshFogTuning
    type ProbeOptions = MeshProbeOptions
    type Probe = MeshProbeTuning
    type EnvironmentOptions = MeshEnvironmentOptions
    type Environment = MeshEnvironmentTuning
    type EnvironmentFaces = MeshEnvironmentFaces
    type SSAOOptions = Deferred.SSAOOptions
    type SSAO = Deferred.SSAO
    type RegisteredPrimitive = RegisteredPrimitive
    type Model3D = Model3D

    MATERIAL_METALLIC_ROUGHNESS: integer
    MATERIAL_UNLIT: integer
    MATERIAL_LAMBERT: integer
    TEXTURE_RGBA8: integer
    TEXTURE_BC3: integer
    _create: function(device: loader.CPtr, deferred: Deferred, options: MeshDomainOptions): MeshDomainInternal
end

local MATERIAL_METALLIC_ROUGHNESS <const> = 0
local MATERIAL_UNLIT <const> = 1
local MATERIAL_LAMBERT <const> = 2
local ALPHA_OPAQUE <const> = meshconstants.ALPHA_OPAQUE
local ALPHA_MASK <const> = meshconstants.ALPHA_MASK
local ALPHA_BLEND <const> = meshconstants.ALPHA_BLEND
local TEXTURE_RGBA8 <const> = assets.IMAGE_RGBA8
local TEXTURE_BC3 <const> = assets.IMAGE_BC3

MeshDomainModule.MATERIAL_METALLIC_ROUGHNESS = MATERIAL_METALLIC_ROUGHNESS
MeshDomainModule.MATERIAL_UNLIT = MATERIAL_UNLIT
MeshDomainModule.MATERIAL_LAMBERT = MATERIAL_LAMBERT
MeshDomainModule.TEXTURE_RGBA8 = TEXTURE_RGBA8
MeshDomainModule.TEXTURE_BC3 = TEXTURE_BC3

MeshDomainImpl.MATERIAL_METALLIC_ROUGHNESS = MATERIAL_METALLIC_ROUGHNESS
MeshDomainImpl.MATERIAL_UNLIT = MATERIAL_UNLIT
MeshDomainImpl.MATERIAL_LAMBERT = MATERIAL_LAMBERT
MeshDomainImpl.ALPHA_OPAQUE = ALPHA_OPAQUE
MeshDomainImpl.ALPHA_MASK = ALPHA_MASK
MeshDomainImpl.ALPHA_BLEND = ALPHA_BLEND
MeshDomainImpl.TEXTURE_RGBA8 = TEXTURE_RGBA8
MeshDomainImpl.TEXTURE_BC3 = TEXTURE_BC3

local MeshDomainMT <const>: metatable<MeshDomainImpl> = {__index = MeshDomainImpl}

local function positive(name: string, value: integer): integer
    if value < 1 or value ~= math.floor(value) then
        error(("tecs: %s must be a positive integer"):format(name), 3)
    end
    return value
end

function MeshDomainModule._create(
    device: loader.CPtr, deferred: Deferred, options: MeshDomainOptions
): MeshDomainInternal
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
    local jointCapacity = 0
    if options.skinning ~= nil then
        jointCapacity = positive(
            "mesh joint capacity", (options.skinning as MeshSkinningOptions).jointCapacity or DEFAULT_JOINT_CAPACITY
        )
    end
    local morphVertexCapacity = 0
    local morphWeightCapacity = 0
    if options.morphing ~= nil then
        local morphing <const> = options.morphing as MeshMorphingOptions
        morphVertexCapacity = positive(
            "mesh morph vertex capacity", morphing.vertexCapacity or DEFAULT_MORPH_VERTEX_CAPACITY
        )
        morphWeightCapacity = positive(
            "mesh morph weight capacity", morphing.weightCapacity or DEFAULT_MORPH_WEIGHT_CAPACITY
        )
    end
    local lightCapacity = 0
    local localShadowCapacity = 0
    local localShadowSize = 0
    local localShadowBias = 0.0
    local localShadowSoftness = 0.0
    if options.lights ~= nil then
        local lights <const> = options.lights as MeshLightOptions
        lightCapacity = positive("mesh light capacity", lights.capacity or meshlightlayout.DEFAULT_CAPACITY)
        if lights.shadows ~= nil then
            local shadows <const> = lights.shadows as MeshLocalShadowOptions
            localShadowCapacity = positive("mesh local shadow capacity", shadows.capacity or 4)
            localShadowSize = positive("mesh local shadow size", shadows.size or 256)
            localShadowBias = shadows.bias or 0.002
            localShadowSoftness = shadows.softness or 1.0
            if localShadowBias < 0.0 or localShadowSoftness < 0.0 then
                error("tecs: mesh local shadow bias and softness must be non-negative", 2)
            end
        end
    end

    local self = setmetatable({} as MeshDomainImpl, MeshDomainMT)
    self.capacity = capacity
    self.vertexCapacity = vertexCapacity
    self.indexCapacity = indexCapacity
    self.count = 0
    self.dropped = 0
    self.rewritten = 0
    self.meshCount = 0
    self._modelCount = 0
    self.vertexCount = 0
    self.indexCount = 0
    self.materialCount = 1
    self.textureCount = 0
    self.jointCount = 0
    self.morphVertexCount = 0
    self.morphWeightCount = 0
    self.transparency = options.transparency == true
    self.doubleSided = options.doubleSided == true
    self.mipmaps = options.mipmaps == true
    self.textureFormat = options.textureFormat or TEXTURE_RGBA8
    if self.textureFormat ~= TEXTURE_RGBA8 and self.textureFormat ~= TEXTURE_BC3 then
        error("tecs: meshes.textureFormat must be a MeshDomain.TEXTURE_* constant", 2)
    end
    if self.mipmaps and options.packTextures ~= false then
        error("tecs: meshes.mipmaps requires packTextures = false", 2)
    end
    if self.textureFormat == TEXTURE_BC3 and not self.mipmaps then
        error("tecs: meshes.TEXTURE_BC3 requires mipmaps = true", 2)
    end
    self.shadows = options.shadows ~= nil
    self.skinning = options.skinning ~= nil
    self.morphing = options.morphing ~= nil
    self.localLights = options.lights ~= nil
    self.localShadows = localShadowCapacity > 0
    self.localShadowCount = 0
    self.lightCapacity = lightCapacity
    self.lightCount = 0
    self.vertexColors = options.vertexColors == true
    self.fogging = options.fog ~= nil
    self.probing = options.probe ~= nil
    self.environmentLighting = options.environment ~= nil
    self.environmentSize = self.environmentLighting
        and positive(
            "mesh environment size", (options.environment as MeshEnvironmentOptions).size or DEFAULT_ENVIRONMENT_SIZE
        ) or 0
    self.environmentReady = false
    self.ssao = options.ssao ~= nil and deferred:meshSSAOTuning() or nil
    if self.shadows then
        local shadow <const> = options.shadows or {}
        self.shadow = {
            distance = shadow.distance or 100.0,
            splitLambda = shadow.splitLambda or 0.7,
            splitBlend = shadow.splitBlend or 0.1,
            depthPadding = shadow.depthPadding or 20.0,
            directionX = shadow.directionX or -0.5,
            directionY = shadow.directionY or -1.0,
            directionZ = shadow.directionZ or -0.5,
            r = shadow.r or 1.0,
            g = shadow.g or 1.0,
            b = shadow.b or 1.0,
            intensity = shadow.intensity or 1.0,
            strength = shadow.strength or 1.0,
            bias = shadow.bias or 0.0015,
            softness = shadow.softness or 1.0,
        }
    end
    if self.fogging then
        local fog <const> = options.fog or {}
        self.fog = {
            start = fog.start or 20.0,
            finish = fog.finish or 100.0,
            r = fog.r or 0.5,
            g = fog.g or 0.6,
            b = fog.b or 0.7,
        }
    end
    if self.probing then
        local probe <const> = options.probe or {}
        self.probe = {
            positiveX = probe.positiveX or {0.0, 0.0, 0.0},
            negativeX = probe.negativeX or {0.0, 0.0, 0.0},
            positiveY = probe.positiveY or {0.0, 0.0, 0.0},
            negativeY = probe.negativeY or {0.0, 0.0, 0.0},
            positiveZ = probe.positiveZ or {0.0, 0.0, 0.0},
            negativeZ = probe.negativeZ or {0.0, 0.0, 0.0},
            intensity = probe.intensity or 1.0,
        }
    end
    if self.environmentLighting then
        local environment <const> = options.environment or {}
        self.environment = {
            intensity = environment.intensity or 1.0,
            skyboxIntensity = environment.skyboxIntensity or 1.0,
            rotation = environment.rotation or 0.0,
        }
    end
    self._centerXByAsset = {}
    self._centerYByAsset = {}
    self._centerZByAsset = {}
    self._radiusByAsset = {}
    self._packet = MeshFramePacket.create(
        self.skinning and not self.morphing,
        self.morphing,
        self.localLights and lightCapacity or nil,
        self.localShadows and localShadowCapacity or nil
    )

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
            mipmaps = self.mipmaps,
            textureFormat = self.textureFormat,
            transparency = self.transparency,
            doubleSided = self.doubleSided,
            shadows = self.shadow as MeshBackend.ShadowOptions,
            shadowScale = options.shadows ~= nil and (options.shadows.scale or 1.0) or 1.0,
            skinning = self.skinning,
            jointCapacity = jointCapacity,
            morphing = self.morphing,
            morphVertexCapacity = morphVertexCapacity,
            morphWeightCapacity = morphWeightCapacity,
            localLights = self.localLights,
            localShadowCapacity = localShadowCapacity,
            localShadowSize = localShadowSize,
            localShadowBias = localShadowBias,
            localShadowSoftness = localShadowSoftness,
            vertexColors = self.vertexColors,
            fog = self.fog as MeshBackend.FogOptions,
            probe = self.probe as MeshBackend.ProbeOptions,
            environment = self.environment as MeshBackend.EnvironmentOptions,
            environmentSize = self.environmentSize,
        }
    )
    self._backend = backend

    local extractor <const> = MeshExtractor.create({
        capacity = capacity,
        transparency = self.transparency,
        doubleSided = self.doubleSided,
        skinning = self.skinning,
        morphing = self.morphing,
        lightCapacity = lightCapacity,
        shadowCapacity = localShadowCapacity,
    })
    self._extractor = extractor
    self.camera = extractor.camera
    return self
end

function MeshDomainImpl:registerTexture(image: assets.Image): integer
    if image == nil then
        error("tecs: mesh texture image is required", 2)
    end
    local texture <const> = self._backend:registerTexture(image)
    self.textureCount = self._backend.textureCount
    return texture
end

function MeshDomainImpl:registerEnvironment(faces: MeshEnvironmentFaces)
    if not self.environmentLighting then
        error("tecs: mesh environment lighting is not enabled", 2)
    end
    if faces == nil then
        error("tecs: mesh environment faces are required", 2)
    end
    self._backend:registerEnvironment(
        faces.positiveX, faces.negativeX, faces.positiveY, faces.negativeY, faces.positiveZ, faces.negativeZ
    )
    self.environmentReady = true
end

function MeshDomainImpl:registerMaterial(options: MeshMaterialOptions): components.MeshMaterial
    if options == nil or options.name == nil or options.name == "" then
        error("tecs: mesh material name cannot be empty", 2)
    end
    local asset <const> = components.meshMaterialId(options.name)
    local existing <const> = self._backend:materialSlot(asset)
    if existing ~= nil then
        return components.MeshMaterial(asset, existing)
    end
    local model <const> = options.model or MATERIAL_METALLIC_ROUGHNESS
    if model ~= MATERIAL_METALLIC_ROUGHNESS and model ~= MATERIAL_UNLIT and model ~= MATERIAL_LAMBERT then
        error(("tecs: invalid mesh material model %s"):format(tostring(model)), 2)
    end
    local alphaMode <const> = options.alphaMode or ALPHA_OPAQUE
    if alphaMode ~= ALPHA_OPAQUE and alphaMode ~= ALPHA_MASK and alphaMode ~= ALPHA_BLEND then
        error(("tecs: invalid mesh material alpha mode %s"):format(tostring(alphaMode)), 2)
    end
    if alphaMode == ALPHA_BLEND and not self.transparency then
        error("tecs: alpha-blended mesh materials require meshes.transparency = true", 2)
    end
    local doubleSided <const> = options.doubleSided == true
    if doubleSided and not self.doubleSided then
        error("tecs: double-sided mesh materials require meshes.doubleSided = true", 2)
    end
    local slot <const> = self._backend:registerMaterial(
        asset,
        {
            name = options.name,
            model = model,
            alphaMode = alphaMode,
            doubleSided = doubleSided,
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
    self._extractor:registerMaterial(asset, slot, alphaMode, doubleSided)
    self.materialCount = self._backend.materialCount
    return components.MeshMaterial(asset, slot)
end

function MeshDomainImpl:material(name: string): components.MeshMaterial
    local asset <const> = components.meshMaterialId(name)
    local slot <const> = self._backend:materialSlot(asset)
    if slot == nil then
        error(("tecs: no mesh material is registered as '%s'"):format(name), 2)
    end
    return components.MeshMaterial(asset, slot)
end

function MeshDomainImpl:registerModel(model: assets.Model): Model3D
    if model == nil then
        error("tecs: model data is required", 2)
    end
    local registered: Model3D = nil
    local ok, reason = pcall(function()
        if not self.transparency then
            for _, material in ipairs(model.materials) do
                if material.alphaMode == ALPHA_BLEND then
                    error("tecs: alpha-blended mesh materials require meshes.transparency = true", 0)
                end
            end
        end
        if not self.doubleSided then
            for _, material in ipairs(model.materials) do
                if material.doubleSided then
                    error("tecs: double-sided mesh materials require meshes.doubleSided = true", 0)
                end
            end
        end
        if model.mipmaps and not self.mipmaps then
            error("tecs: the model's sampler requires meshes.mipmaps = true", 0)
        end
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
                alphaMode = material.alphaMode,
                doubleSided = material.doubleSided,
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
        for _, draw in ipairs(model.draws) do
            if meshes[draw.mesh] == nil then
                error(("tecs: model draw names missing mesh %d"):format(draw.mesh), 0)
            end
            local material = materials[draw.material]
            if draw.material ~= 0 and material == nil then
                error(("tecs: model draw names missing material %d"):format(draw.material), 0)
            end
            if draw.skin ~= 0 and model.skins[draw.skin] == nil then
                error(("tecs: model draw names missing skin %d"):format(draw.skin), 0)
            end
        end
        self._modelCount = self._modelCount + 1
        registered = Model3D._create(
            self as modeltypes.Domain, model.path .. "#residency-" .. self._modelCount, model, meshes, bounds, materials
        )
    end) as (boolean, any)
    model:release()
    if not ok then
        error(tostring(reason), 0)
    end
    return registered
end

function MeshDomainImpl:_install(world: types.World)
    self._extractor:install(
        world,
        self._packet,
        function()
            local packet <const> = self._packet
            domainmetrics.publish(self, packet as domainmetrics.Frame)
            self.lightCount = packet.lightCount
            self.localShadowCount = packet.shadowLightCount
        end
    )
end

function MeshDomainImpl:_setStaging(slot: integer)
    self._extractor:setStaging(slot, self._backend:mapSlot(slot))
end

function MeshDomainImpl:_recordGeometry(context: Deferred.PassContext)
    self._backend:recordGeometry(context)
end

function MeshDomainImpl:_recordForward(context: Deferred.PassContext)
    self._backend:recordForward(context)
end

function MeshDomainImpl:_castsThisFrame(): boolean
    return self._backend:castsThisFrame()
end

function MeshDomainImpl:_recordShadowMap(context: Deferred.PassContext, cascade: integer)
    self._backend:recordShadowMap(context, cascade)
end

function MeshDomainImpl:_rebuildPipelines(deferred: Deferred)
    self._backend:rebuildPipeline(deferred)
end

function MeshDomainImpl:_prepare(frame: Frame, camera?: Camera3D, width?: number, height?: number, upload?: boolean)
    self._packet:setCamera(camera or self.camera, width or frame.width, height or frame.height)
    self._backend:prepare(self._packet, frame, upload)
end

function MeshDomainImpl:registerSkin(name: string, matrices: {number}): components.MeshSkin
    if not self.skinning then
        error("tecs: mesh skinning is not enabled", 2)
    end
    local asset <const> = components.meshSkinId(name)
    local region = self._backend:skinRegion(asset)
    if region == nil then
        region = self._backend:registerSkin(asset, matrices)
    end
    self._extractor:registerSkin(asset, region.firstJoint)
    self.jointCount = self._backend.jointCount
    return components.MeshSkin(asset, region.firstJoint)
end

function MeshDomainImpl:updateSkin(skin: components.MeshSkin, matrices: {number})
    if not self.skinning then
        error("tecs: mesh skinning is not enabled", 2)
    end
    if skin == nil then
        error("tecs: a mesh skin component is required", 2)
    end
    local region <const> = self._backend:skinRegion(skin.asset as integer)
    if region == nil then
        error(
            ("tecs: no mesh skin is registered as '%s'"):format(
                tostring(components.meshSkinName(skin.asset as integer))
            ),
            2
        )
    end
    self._backend:updateSkin(region, matrices)
end

function MeshDomainImpl:registerMorph(name: string, weights: {number}): components.MeshMorph
    if not self.morphing then
        error("tecs: mesh morphing is not enabled", 2)
    end
    local asset <const> = components.meshMorphId(name)
    local region = self._backend:morphRegion(asset)
    if region == nil then
        region = self._backend:registerMorph(asset, weights)
    end
    self._extractor:registerMorph(asset, region.firstWeight, region.weightCount)
    self.morphWeightCount = self._backend.morphWeightCount
    return components.MeshMorph(asset, region.firstWeight)
end

function MeshDomainImpl:updateMorph(morph: components.MeshMorph, weights: {number})
    if not self.morphing then
        error("tecs: mesh morphing is not enabled", 2)
    end
    if morph == nil then
        error("tecs: a mesh morph component is required", 2)
    end
    local region <const> = self._backend:morphRegion(morph.asset as integer)
    if region == nil then
        error(
            ("tecs: no mesh morph is registered as '%s'"):format(
                tostring(components.meshMorphName(morph.asset as integer))
            ),
            2
        )
    end
    self._backend:updateMorph(region, weights)
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
function MeshDomainImpl:registerMesh(mesh: assets.Mesh): components.Mesh, components.Bounds3D
    if mesh == nil then
        error("tecs: mesh data is required", 2)
    end
    if mesh.skinVertices ~= nil and not self.skinning then
        error("tecs: skinned geometry requires meshes.skinning", 2)
    end
    if mesh.morphVertices ~= nil and not self.morphing then
        error("tecs: morphed geometry requires meshes.morphing", 2)
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
    self._extractor:registerMesh(
        asset,
        region.slot,
        region.firstVertex,
        region.firstIndex,
        region.indexCount,
        region.firstMorphVertex,
        region.vertexCount,
        region.morphTargetCount
    )
    self.meshCount = self._backend.meshCount
    self.vertexCount = self._backend.vertexCount
    self.indexCount = self._backend.indexCount
    self.morphVertexCount = self._backend.morphVertexCount
    return components.Mesh(asset, region.slot), components.Bounds3D(centerX, centerY, centerZ, radius)
end

function MeshDomainImpl:mesh(name: string): components.Mesh, components.Bounds3D
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

function MeshDomainImpl:_device(): loader.CPtr
    return self._backend:device()
end

function MeshDomainImpl:extractSeconds(): number
    return self._extractor:extractSeconds()
end

function MeshDomainImpl:_destroy()
    self._backend:destroy()
end

return MeshDomainModule
