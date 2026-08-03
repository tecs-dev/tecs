--[=[
Acquires and decodes assets without blocking the SDL host.

Loads return their values directly. Inside a frame system dispatched by
`world:update`, a worker decode transparently suspends the logical update:

```teal no-format
return tecs.newApplication({
    plugin = function(world: tecs.World, app: tecs.Application)
        local loaded = false
        world:addSystem({
            name = "game.SpawnHero",
            phase = tecs.ecs.phases.PreUpdate,
            run = function()
                if loaded then
                    return
                end
                local image <const> = tecs.assets.loadImage(
                    tecs.io.files.assetPath("sprites/hero.png")
                )
                local sprite <const> = app.renderer.sprites:registerImage(image)
                world:spawn(
                    tecs.Transform2D(100, 100),
                    sprite,
                    tecs.gfx.Renderable2D()
                )
                loaded = true
            end,
        })
    end,
})
```

The loader decodes pixels but creates no GPU resource. The renderer decides
texture residency. Audio follows the same split between decoded clips and
voices.

Image cache misses read through SDL AsyncIO, decode in the bounded native CPU
lane, and publish on the main thread. `newMesh` constructs immutable
procedural geometry synchronously. `loadGLTF` decodes glTF 2.0 and GLB scenes
through the maintained Rust glTF importer on a warmed isolated worker,
including images, metallic-roughness materials, vertex colors, alpha masks,
`BLEND` modes, skins, and node animation clips including morph weights. One
opaque native allocation retains the import; the main thread borrows its
geometry through flat views instead of serializing large strings through the
worker channel. Both produce CPU-owned data that the mesh domain consumes when
it becomes resident. A model with a `BLEND` material requires a mesh domain
created with `transparency = true`.

Primitives without authored tangents use MikkTSpace tangent generation.
Tangent discontinuities split vertices while color, skin, and morph streams
follow the split, preserving normal-map seams without changing authored
tangents.

One imported primitive becomes one independently bounded GPU-culling command.
The decoder splits a primitive above 65,536 triangles into bounded commands,
remapping the vertices and optional color, skin, and morph streams in each
chunk. Meshoptimizer then reorders opaque and masked triangles for the vertex
cache and remaps every vertex stream into first-use order. Alpha-blended
triangles retain their authored order because order affects their result, but
their vertex streams still receive the lossless fetch remap.

The repository's large-scene fetch command can replace source images with
complete BC3 mip chains in KTX2 containers. The maintained Rust parser
validates the container before exposing its blocks. Those images remain
compressed through upload and
require a mesh domain created with `textureFormat = tecs.assets.IMAGE_BC3`,
`mipmaps = true`, and `packTextures = false`. PNG, JPEG, SVG, and ordinary glTF
images remain decoded RGBA8.

## Lifetime

[`Application`](tealdoc:tecs.Application) installs and shuts down the asset
lanes. Headless code calls `install` before model or sound loading and
`shutdown` afterwards. A load outside a world update blocks and drives its
private producer until the value or failure arrives; a system suspends at the
same direct call.

Release a payload after its consumer takes ownership. The final release frees
the decoded memory.

Overlapping image loads for one path share a decode and receive holds on the
same image. A later load after settlement decodes again. Sound loads never
share.

`loadString` reads a complete file into a binary-safe string without
interpreting it. Image loads accept PNG, JPEG, static SVG, and linear BC3 KTX2
mip chains. SVG renders at
its intrinsic dimensions. It uses the bundled JetBrains Mono for all text and
ignores external image references, so installed fonts and the worker's current
directory cannot change its pixels. `tecs.audio.decoders()` reports the sound
formats linked into the current build. Sound mode `"resident"` decodes the
complete clip, `"stream"` opens a source for each voice, and `"auto"` chooses
from the duration threshold.

Release each payload after its consumer takes ownership.
]=]

local ffi <const> = require("ffi")
local sdl3mixer <const> = require("tecs.ffi.sdl3mixer")
local rust <const> = require("tecs.ffi.rust")
local loader <const> = require("tecs.ffi.loader")
local workers <const> = require("tecs.workers")
local content <const> = require("tecs.platform.content")
local Completion <const> = require("tecs.internal.completion")
local task <const> = require("tecs.internal.taskruntime")
local runtime <const> = require("tecs.internal.runtime")
local fileasync <const> = require("tecs.internal.fileasync")
local cpuimage <const> = require("tecs.internal.cpuimage")
local adapter <const> = require("tecs.platform.adapter")
local storagebackend <const> = require("tecs.platform.storagebackend")
local time <const> = require("tecs.platform.time")
local meshlayout <const> = require("tecs.gpu.meshlayout")

local runtimePoll: function(): integer
local function pollRuntime(): integer
    return runtimePoll()
end

local MIX <const> = sdl3mixer.C
local RUST <const> = rust.C
local IMAGE_RGBA8 <const> = 0
local IMAGE_BC3 <const> = 1

--- Runs on the worker. Decodes to a normalized layout and returns an address.
local DECODER <const> = [==[
local ffi = require("ffi")
local mixer = require("tecs.ffi.sdl3mixer")
local loader = require("tecs.ffi.loader")
local rust = require("tecs.ffi.rust")
local workers = require("tecs.workers")

local MIX = mixer.C
local RUST = rust.C
local self = workers.current()

local function decodeModel(task)
    local model = RUST.tecsModelLoad(task.path, #task.path)
    if model == nil then
        return {id = task.id, error = loader.toString(RUST.tecsRustError())}
    end
    return {id = task.id, model = tonumber(ffi.cast("uintptr_t", model))}
end

-- Length in milliseconds, or -1 when the container cannot say. A format that
-- only stores a bit rate is estimated from it, and one that streams forever
-- reports infinite; both are "unknown" as far as anything above cares.
local function durationOf(audio)
    local frames = MIX.MIX_GetAudioDuration(audio)
    if frames < 0 then return -1 end
    return tonumber(MIX.MIX_AudioFramesToMS(audio, frames))
end

-- Sound is read by the mixer's own decoders, which is what makes anything but
-- WAV loadable. No mixer is passed: a clip is independent of the output, so
-- loading works before one is open and on a machine that has none, and the
-- mixer converts what it reads either way.
--
-- `mode` decides whether the clip ends up resident:
--   "resident"  decoded once, up front, and held as PCM
--   "stream"    nothing held; each voice opens the file for itself
--   "auto"      resident under `streamMs`, streamed at or over it
--
-- The auto case reads the file twice when it turns out to be short: once
-- without decoding, to ask how long it is, and once to decode it. That is a
-- second read of a small file, off the main thread, against holding a decoded
-- copy of a piece of music.
local function decodeSound(task)
    local predecode = task.mode == "resident"
    local audio = MIX.MIX_LoadAudio(nil, task.path, predecode)
    if audio == nil then
        return { id = task.id, error = "cannot load " .. task.path }
    end

    local ms = durationOf(audio)
    if task.mode == "resident" then
        return {
            id = task.id, resident = true, durationMs = ms,
            audio = tonumber(ffi.cast("uintptr_t", audio)),
        }
    end

    if task.mode == "auto" and ms >= 0 and ms < task.streamMs then
        MIX.MIX_DestroyAudio(audio)
        audio = MIX.MIX_LoadAudio(nil, task.path, true)
        if audio == nil then
            return { id = task.id, error = "cannot decode " .. task.path }
        end
        return {
            id = task.id, resident = true, durationMs = ms,
            audio = tonumber(ffi.cast("uintptr_t", audio)),
        }
    end

    MIX.MIX_DestroyAudio(audio)
    return { id = task.id, resident = false, durationMs = ms }
end

while true do
    local task = self:receive()
    if task == nil then break end
    if task.kind == "sound" then
        self:send(decodeSound(task))
    elseif task.kind == "model" then
        self:send(decodeModel(task))
    else
        self:send({id = task.id, error = "unknown asset CPU job " .. tostring(task.kind)})
    end
end
]==]

--- Represents decoded pixels or an imported compressed mip chain and the
--- caller's hold on them.
---
--- What `loadImage` returns. Reference counts govern the pixels rather than
--- owning them outright, because two overlapping loads share a decode:
--- each caller holds the same [`Image`](tealdoc:tecs.assets.Image), and the last caller to release it
--- one that frees. Reading `pixels` after that is reading freed memory, which
--- is why a released image reads nil there rather than looking uploadable.
local record Image
    --- Read-only. Contains the requested path unchanged. The loader does not resolve it, so it is
    --- whatever the caller passed.
    path: string

    --- Read-only. Contains decoded RGBA pixels or BC3 blocks until the last
    --- `release`, then becomes nil.
    pixels: loader.CValue

    --- Read-only. Reports the width in pixels.
    width: integer

    --- Read-only. Reports the height in pixel rows.
    height: integer

    --- Read-only. Reports the row stride in bytes, which a decoder may pad
    --- beyond `width * 4`.
    pitch: integer

    --- Read-only. Selects decoded RGBA8 pixels or an imported BC3 mip chain
    --- with an `assets.IMAGE_*` integer constant.
    format: integer

    --- Read-only. Reports the texture width represented by the uploaded mip
    --- chain. It equals `width` for decoded RGBA8 images.
    storageWidth: integer

    --- Read-only. Reports the texture height represented by the uploaded mip
    --- chain. It equals `height` for decoded RGBA8 images.
    storageHeight: integer

    --- Read-only. Reports the number of consecutive mip levels in `pixels`.
    levels: integer

    --- Read-only. Reports bytes available from `pixels`. Decoded RGBA8 images
    --- report `pitch * height`.
    byteCount: integer

    --- Engine-owned. Stores the native image allocation until the last
    --- `release`. An image imported with a model instead borrows the model's
    --- allocation. Ordinary game code should ignore this field.
    _image: loader.CValue

    --- Engine-owned. Counts callers holding these pixels. Ordinary game code
    --- should ignore this field. The count includes one per completed load of
    --- the path.
    _refs: integer

    --- Gives up this caller's hold on the pixels, and frees at the last.
    ---
    --- Called once whatever needed them has taken a copy, which for an image
    --- means after the caller uploads it. Where several loads shared one decode,
    --- this releases one of them.
    ---
    --- Releasing an image already down to nothing does nothing, so a shutdown
    --- path need not know whether something else got there first.
    release: function(self: Image)
end

--- Represents a loaded clip and the caller's hold on it.
---
--- What `loadSound` returns. Two overlapping loads of one path do
--- not share, unlike images, so a [`Sound`](tealdoc:tecs.assets.Sound)
--- normally has one holder; the count is
--- here so that releasing twice frees once rather than twice.
local record Sound
    --- Read-only. Contains the requested path unchanged.
    path: string

    --- Read-only. Contains the loaded clip until the last `release`. It is nil for one that
    --- streams, which holds nothing, and nil once released.
    audio: loader.CValue

    --- Read-only. Reports whether memory holds the decoded audio. It is false for a clip each voice
    --- reads from the file for itself.
    resident: boolean

    --- Read-only. Reports the length in milliseconds, or -1 when the container
    --- cannot say.
    durationMs: integer

    --- Engine-owned. Counts callers holding this clip. Ordinary game code
    --- should ignore this field.
    _refs: integer

    --- Gives up this caller's hold on the clip, and frees at the last.
    ---
    --- A voice reads a clip where it lies, so release a clip when nothing
    --- will play it again. A track holds its own reference, so releasing one
    --- that is still sounding is safe: the mixer drops it when the last track
    --- using it does.
    ---
    --- Releasing a clip already down to nothing does nothing.
    release: function(self: Sound)
end

--- Describes one immutable indexed triangle mesh before GPU registration.
---
--- Vertices use one fixed interleaved layout: position xyz, normal xyz,
--- tangent xyzw, and texture uv. Indices are zero-based unsigned 32-bit
--- values. A mesh may therefore contain far more than 65,535 vertices, and a
--- primitive is one indexed range rather than one triangle.
---
--- `renderer.meshes:registerMesh` copies both arrays into device-local
--- storage and releases this object. The Lua-number constructor is intended
--- for procedural and example geometry. A file decoder can build the same
--- record directly without expanding a large mesh into Lua tables.
local record Mesh
    --- Read-only. Contains the stable name used by `meshId` and snapshots.
    name: string
    --- Read-only. Contains interleaved vertex floats until `release` runs.
    vertices: loader.CArray
    --- Read-only. Contains optional linear RGBA vertex colors until `release`
    --- runs. Nil means every vertex is white.
    colorVertices: loader.CArray
    --- Read-only. Contains zero-based unsigned 32-bit indices until `release`
    --- runs.
    indices: loader.CArray
    --- Read-only. Contains optional joint indices and weights as eight floats
    --- per vertex until `release` runs. Nil means rigid geometry.
    skinVertices: loader.CArray
    --- Read-only. Contains optional position, normal, and tangent deltas as
    --- nine floats per target vertex until `release` runs. Nil means the
    --- geometry has no morph targets.
    morphVertices: loader.CArray
    --- Read-only. Reports the number of consecutive morph targets.
    morphTargetCount: integer
    --- Read-only. Contains one default weight per morph target.
    morphWeights: {number}
    --- Read-only. Reports the number of vertices, not floats.
    vertexCount: integer
    --- Read-only. Reports the number of indices. It is always a multiple of
    --- three.
    indexCount: integer
    --- Read-only. Reports the local-space bounding-sphere center x.
    centerX: number
    --- Read-only. Reports the local-space bounding-sphere center y.
    centerY: number
    --- Read-only. Reports the local-space bounding-sphere center z.
    centerZ: number
    --- Read-only. Reports the non-negative local-space bounding-sphere radius.
    radius: number
    --- Gives up the CPU geometry. Calling it again does nothing.
    release: function(self: Mesh)
end

--- Supplies one procedural morph target to `newMesh`.
local record MeshMorphTarget
    --- Caller-writable. Supplies three position deltas per vertex.
    positions: {number}
    --- Caller-writable. Supplies three normal deltas per vertex, or nil for
    --- zero deltas.
    normals: {number}
    --- Caller-writable. Supplies three tangent deltas per vertex, or nil for
    --- zero deltas. Tangent handedness is unchanged.
    tangents: {number}
end

--- Supplies procedural geometry to `newMesh`.
local record MeshOptions
    --- Caller-writable. Supplies the stable non-empty mesh name.
    name: string
    --- Caller-writable. Supplies interleaved position xyz, normal xyz,
    --- tangent xyzw, and texture uv floats.
    vertices: {number}
    --- Caller-writable. Supplies optional linear RGBA colors, four per vertex.
    --- Nil makes every vertex white without allocating a color array.
    colors: {number}
    --- Caller-writable. Supplies zero-based triangle indices.
    indices: {integer}
    --- Caller-writable. Supplies four zero-based joint indices per vertex.
    --- Nil requires `weights` to be nil and builds rigid geometry.
    joints: {integer}
    --- Caller-writable. Supplies four non-negative joint weights per vertex.
    --- Each group is normalized by `newMesh` and requires `joints`.
    weights: {number}
    --- Caller-writable. Supplies morph targets in file order. Each target
    --- carries vertex-count-matched position deltas and optional normal and
    --- tangent deltas.
    morphTargets: {MeshMorphTarget}
    --- Caller-writable. Supplies one finite default weight per morph target.
    --- Omitted weights default to zero.
    morphWeights: {number}
end

--- Describes one decoded glTF material before GPU registration.
local record ModelMaterial
    --- Read-only. Contains the stable material name.
    name: string
    --- Read-only. Selects metallic-roughness PBR at zero or unlit at one.
    model: integer
    --- Read-only. Selects opaque, masked, or blended rendering with a
    --- `MeshDomain.ALPHA_*` integer constant.
    alphaMode: integer
    --- Read-only. Selects a one-based entry in `Model.images`, or zero.
    baseColorImage: integer
    --- Read-only. Selects a tangent-space normal image, or zero.
    normalImage: integer
    --- Read-only. Selects a glTF metallic-roughness image, or zero.
    metallicRoughnessImage: integer
    --- Read-only. Selects an occlusion image, or zero.
    occlusionImage: integer
    --- Read-only. Selects an emissive image, or zero.
    emissiveImage: integer
    --- Read-only. Reports the alpha-mask cutoff. Zero keeps every fragment.
    alphaCutoff: number
    --- Read-only. Reports the base-color red factor.
    baseR: number
    --- Read-only. Reports the base-color green factor.
    baseG: number
    --- Read-only. Reports the base-color blue factor.
    baseB: number
    --- Read-only. Reports the base-color alpha factor.
    baseA: number
    --- Read-only. Reports the emissive red factor.
    emissiveR: number
    --- Read-only. Reports the emissive green factor.
    emissiveG: number
    --- Read-only. Reports the emissive blue factor.
    emissiveB: number
    --- Caller-writable until model registration. Multiplies sampled metallic.
    --- This defaults to the decoded glTF factor.
    metallic: number
    --- Caller-writable until model registration. Multiplies sampled roughness.
    --- This defaults to the decoded glTF factor.
    roughness: number
    --- Read-only. Reports tangent-space normal strength.
    normalScale: number
    --- Read-only. Reports sampled occlusion strength.
    occlusionStrength: number
    --- Read-only. Reports whether both triangle faces must render.
    doubleSided: boolean
end

--- Describes one static primitive instance in a decoded glTF scene.
local record ModelDraw
    --- Read-only. Selects a one-based entry in `Model.meshes`.
    mesh: integer
    --- Read-only. Selects a one-based entry in `Model.materials`, or zero for
    --- the neutral material.
    material: integer
    --- Read-only. Selects a one-based entry in `Model.skins`, or zero for a
    --- rigid primitive.
    skin: integer
    --- Read-only. Selects the one-based scene node this primitive follows.
    node: integer
    --- Read-only. Contains this node's initial morph weights in target order.
    weights: {number}
    --- Read-only. Reports world translation x from the selected glTF scene.
    x: number
    --- Read-only. Reports world translation y.
    y: number
    --- Read-only. Reports world translation z.
    z: number
    --- Read-only. Reports world quaternion x.
    rotationX: number
    --- Read-only. Reports world quaternion y.
    rotationY: number
    --- Read-only. Reports world quaternion z.
    rotationZ: number
    --- Read-only. Reports world quaternion w.
    rotationW: number
    --- Read-only. Reports world scale x.
    scaleX: number
    --- Read-only. Reports world scale y.
    scaleY: number
    --- Read-only. Reports world scale z.
    scaleZ: number
end

--- Describes one initial joint palette decoded from a glTF skin instance.
local record ModelSkin
    --- Read-only. Contains the stable palette name used during registration.
    name: string
    --- Read-only. Contains column-major joint matrices, sixteen floats per
    --- joint, in the skinned mesh's local coordinate space.
    matrices: {number}
    --- Read-only. Selects the one-based mesh node whose local space contains
    --- this palette.
    node: integer
    --- Read-only. Contains one-based joint-node indices in palette order.
    joints: {integer}
    --- Read-only. Contains column-major inverse bind matrices, sixteen floats
    --- per joint.
    inverseBindMatrices: {number}
end

--- Describes one node in a decoded glTF transform hierarchy.
local record ModelNode
    --- Read-only. Selects the one-based parent node, or zero for a root.
    parent: integer
    --- Read-only. Contains the base translation x.
    x: number
    --- Read-only. Contains the base translation y.
    y: number
    --- Read-only. Contains the base translation z.
    z: number
    --- Read-only. Contains the base quaternion x.
    rotationX: number
    --- Read-only. Contains the base quaternion y.
    rotationY: number
    --- Read-only. Contains the base quaternion z.
    rotationZ: number
    --- Read-only. Contains the base quaternion scalar component.
    rotationW: number
    --- Read-only. Contains the base x scale.
    scaleX: number
    --- Read-only. Contains the base y scale.
    scaleY: number
    --- Read-only. Contains the base z scale.
    scaleZ: number
    --- Read-only. Contains a fixed column-major local matrix when the source
    --- node used `matrix`, or nil when its local matrix is composed from TRS.
    matrix: {number}
end

--- Describes one decoded glTF animation channel.
local record ModelAnimationChannel
    --- Read-only. Selects a one-based target node.
    node: integer
    --- Read-only. Selects `ANIMATION_TRANSLATION`, `ANIMATION_ROTATION`,
    --- `ANIMATION_SCALE`, or `ANIMATION_WEIGHTS`.
    path: integer
    --- Read-only. Selects `ANIMATION_LINEAR`, `ANIMATION_STEP`, or
    --- `ANIMATION_CUBIC`.
    interpolation: integer
    --- Read-only. Reports packed values per key. It is three for translation
    --- and scale, four for rotation, and the target count for morph weights.
    width: integer
    --- Read-only. Contains strictly increasing key times in seconds.
    times: {number}
    --- Read-only. Contains packed key values. Cubic keys contain incoming
    --- tangent, value, and outgoing tangent rows.
    values: {number}
end

--- Describes one decoded glTF node-animation clip.
local record ModelAnimation
    --- Read-only. Contains the authored clip name or a stable generated name.
    name: string
    --- Read-only. Reports the last key time in seconds.
    duration: number
    --- Read-only. Contains translation, rotation, scale, and morph-weight
    --- channels.
    channels: {ModelAnimationChannel}
end

--- Represents one decoded glTF 2.0 scene and its node animations.
---
--- Meshes use the same fixed vertex layout as `newMesh`. Images remain
--- decoded CPU pixels. `renderer.meshes:registerModel` consumes all of them
--- and returns shared residency that creates independently posed instances.
--- Skinning includes the initial joint pose. Morph data includes immutable
--- deltas and default weights. Animation clips retain allocation-stable CPU
--- sampling data for node transforms and morph weights.
local record Model
    --- Read-only. Contains the requested `.gltf` or `.glb` path unchanged.
    path: string
    --- Read-only. Reports whether the source sampler requires a complete
    --- linearly filtered mip chain.
    mipmaps: boolean
    --- Read-only. Contains unique decoded primitive geometry.
    meshes: {Mesh}
    --- Read-only. Contains unique decoded source images.
    images: {Image}
    --- Read-only. Contains decoded metallic-roughness material descriptions.
    materials: {ModelMaterial}
    --- Read-only. Contains initial joint palettes referenced by model draws.
    skins: {ModelSkin}
    --- Read-only. Contains every node in source-index order.
    nodes: {ModelNode}
    --- Read-only. Contains decoded translation, rotation, and scale clips.
    animations: {ModelAnimation}
    --- Read-only. Contains the selected scene's flattened static draws.
    draws: {ModelDraw}
    --- Releases every CPU mesh and image not already consumed. Calling it
    --- again does nothing.
    release: function(self: Model)
end

local record assets
    --- Read-only. Selects decoded, uncompressed RGBA8 image storage.
    IMAGE_RGBA8: integer
    --- Read-only. Selects a complete imported BC3 image mip chain.
    IMAGE_BC3: integer
    --- Read-only. Selects a translation animation channel.
    ANIMATION_TRANSLATION: integer
    --- Read-only. Selects a rotation animation channel.
    ANIMATION_ROTATION: integer
    --- Read-only. Selects a scale animation channel.
    ANIMATION_SCALE: integer
    --- Read-only. Selects a morph-weight animation channel.
    ANIMATION_WEIGHTS: integer
    --- Read-only. Selects linear interpolation.
    ANIMATION_LINEAR: integer
    --- Read-only. Selects held-key interpolation.
    ANIMATION_STEP: integer
    --- Read-only. Selects cubic-spline interpolation.
    ANIMATION_CUBIC: integer

    --- Read-only. Exposes the decoded image type.
    Image: Image

    --- Read-only. Exposes the loaded sound type.
    Sound: Sound

    --- Read-only. Exposes the immutable CPU mesh type.
    Mesh: Mesh

    --- Read-only. Exposes one procedural morph-target description.
    MeshMorphTarget: MeshMorphTarget

    --- Read-only. Exposes the decoded glTF scene type.
    Model: Model

    --- Read-only. Exposes one glTF material description.
    ModelMaterial: ModelMaterial

    --- Read-only. Exposes one flattened glTF primitive instance.
    ModelDraw: ModelDraw

    --- Read-only. Exposes one decoded initial joint palette.
    ModelSkin: ModelSkin

    --- Read-only. Exposes one decoded model node.
    ModelNode: ModelNode

    --- Read-only. Exposes one decoded node-animation clip.
    ModelAnimation: ModelAnimation

    --- Read-only. Exposes one decoded animation channel.
    ModelAnimationChannel: ModelAnimationChannel

    --- Builds procedural mesh data in the renderer's fixed vertex layout.
    --- @param options The caller supplies a name, interleaved vertices, and
    ---     zero-based triangle indices.
    --- @return Returns CPU geometry that `renderer.meshes:registerMesh`
    ---     consumes or the caller releases.
    newMesh: function(options: MeshOptions): Mesh

    --- Queues glTF 2.0 or GLB decoding on the asset worker.
    ---
    --- External buffers and images resolve relative to the model path. Data
    --- URIs and embedded GLB resources are supported. Triangle primitives,
    --- static node transforms, metallic-roughness PBR, normal, occlusion,
    --- emissive, alpha-mask, alpha-blended, and unlit materials are decoded.
    --- JOINTS_0, WEIGHTS_0, skins, inverse bind matrices, sparse accessors,
    --- morph targets, mesh and node weights, and node animation clips are
    --- decoded. Missing tangents are generated with MikkTSpace, splitting
    --- vertices at tangent discontinuities and remapping every optional vertex
    --- stream. Non-triangle input and texture-coordinate transforms raise at
    --- the direct load call instead of loading incompletely. A primitive above
    --- 65,536 triangles is split into independently bounded and culled mesh
    --- records. Opaque and masked records are optimized for vertex-cache and
    --- vertex-fetch locality. Alpha-blended records preserve authored triangle
    --- order and receive only the lossless vertex-fetch remap. Registering a
    --- model containing alpha blending requires a mesh domain created with
    --- `transparency = true`.
    --- @param path The caller supplies a `.gltf` or `.glb` asset path.
    --- @return Returns the decoded model. The call suspends its system while
    ---     the worker runs, or blocks when called outside a world update.
    loadGLTF: function(path: string): Model

    --- Reports whether the loading worker is running.
    ---
    --- For a subsystem that loads an asset of its own and has no way of knowing whether the
    --- game has started the worker yet.
    ---
    --- @return Whether the worker exists, which is a fact about the process rather
    ---     than about any world. False means a load raises rather than queueing,
    ---     so this is the guard rather than an optimization.
    installed: function(): boolean
end

assets.ANIMATION_TRANSLATION = 0
assets.ANIMATION_ROTATION = 1
assets.ANIMATION_SCALE = 2
assets.ANIMATION_WEIGHTS = 3
assets.ANIMATION_LINEAR = 0
assets.ANIMATION_STEP = 1
assets.ANIMATION_CUBIC = 2
assets.IMAGE_RGBA8 = IMAGE_RGBA8
assets.IMAGE_BC3 = IMAGE_BC3

local ImageMT <const>: metatable<Image> = {__index = Image}
local SoundMT <const>: metatable<Sound> = {__index = Sound}
local MeshMT <const>: metatable<Mesh> = {__index = Mesh}
local ModelMT <const>: metatable<Model> = {__index = Model}
local modelOwners <const>: {Model: loader.CValue} = setmetatable(
    {}, {__mode = "k"} as metatable<{Model: loader.CValue}>
)

function Mesh:release()
    self.vertices = nil
    self.colorVertices = nil
    self.indices = nil
    self.skinVertices = nil
    self.morphVertices = nil
end

function Model:release()
    for _, mesh in ipairs(self.meshes) do
        mesh:release()
    end
    for _, image in ipairs(self.images) do
        image:release()
    end
    local owner <const> = modelOwners[self]
    if owner ~= nil then
        modelOwners[self] = nil
        ffi.gc(owner as ffi.CData, nil)
        RUST.tecsModelDestroy(owner)
    end
end

local function imageFromInfo(path: string, info: {string: any}, allocation: loader.CValue, refs?: integer): Image
    local width <const> = tonumber(info.width) as integer
    local height <const> = tonumber(info.height) as integer
    local format <const> = tonumber(info.format) as integer
    return setmetatable(
        {
            path = path,
            _image = allocation,
            pixels = info.pixels as loader.CValue,
            width = width,
            height = height,
            pitch = format == IMAGE_RGBA8 and width * 4 or 0,
            format = format,
            storageWidth = tonumber(info.storage_width) as integer,
            storageHeight = tonumber(info.storage_height) as integer,
            levels = tonumber(info.levels) as integer,
            byteCount = tonumber(info.byte_count) as integer,
            _refs = refs or 1,
        } as Image,
        ImageMT
    )
end

local function imageFromAllocation(path: string, allocation: loader.CPtr, refs?: integer): Image
    local owner <const> = loader.newArray("TecsImageInfo[1]")
    if not RUST.tecsImageGetInfo(allocation, owner) then
        RUST.tecsImageDestroy(allocation)
        error("cannot read decoded image metadata", 0)
    end
    return imageFromInfo(path, owner[0] as {string: any}, allocation, refs)
end

local function imageFromBytes(bytes: string, path: string): Image
    local decoded = RUST.tecsImageDecode(ffi.cast("const uint8_t *", bytes), #bytes)
    if decoded == nil then
        error(("cannot decode %s: %s"):format(path, loader.toString(RUST.tecsRustError())), 0)
    end
    return imageFromAllocation(path, decoded)
end

local function modelFromWorker(result: {string: any}): Model
    local images: {Image} = {}
    local meshes: {Mesh} = {}
    local owner <const> = ffi.gc(
        ffi.cast("TecsModel *", ffi.cast("uintptr_t", result.model)) as ffi.CData,
        RUST.tecsModelDestroy as function(ffi.CData)
    ) as loader.CValue
    local infoOwner <const> = loader.newArray("TecsModelInfo[1]")
    if not RUST.tecsModelGetInfo(owner, infoOwner) then
        ffi.gc(owner as ffi.CData, nil)
        RUST.tecsModelDestroy(owner)
        error("cannot read imported model: " .. loader.toString(RUST.tecsRustError()), 0)
    end
    local info <const> = infoOwner[0] as {string: any}

    local function textAt(pointer: loader.CValue, length: any): string
        return loader.toBytes(pointer, tonumber(length) as integer)
    end

    local function numbersAt(pointer: loader.CValue, count: any, declaration?: string): {number}
        local length <const> = tonumber(count) as integer
        local source <const> = ffi.cast(declaration or "const float *", pointer) as loader.CArray
        local values: {number} = {}
        for index = 0, length - 1 do
            values[index + 1] = tonumber(source[index]) as number
        end
        return values
    end

    local built, modelOrReason = pcall(function(): Model
        local nativeImages <const> = info.images as loader.CArray
        for index = 0, (tonumber(info.image_count) as integer) - 1 do
            local source <const> = nativeImages[index] as {string: any}
            images[index + 1] = imageFromInfo(
                textAt(source.name as loader.CValue, source.name_length),
                source.image as {string: any},
                ffi.cast("TecsImage *", nil) as loader.CValue
            )
        end
        local nativeMeshes <const> = info.meshes as loader.CArray
        for index = 0, (tonumber(info.mesh_count) as integer) - 1 do
            local source <const> = nativeMeshes[index] as {string: any}
            local vertexCount <const> = tonumber(source.vertex_count) as integer
            local morphTargetCount <const> = tonumber(source.morph_target_count) as integer
            meshes[index + 1] = setmetatable(
                {
                    name = textAt(source.name as loader.CValue, source.name_length),
                    vertices = ffi.cast("float *", source.vertices) as loader.CArray,
                    colorVertices = source.color_vertices ~= nil
                        and ffi.cast("float *", source.color_vertices) as loader.CArray or nil,
                    indices = ffi.cast("uint32_t *", source.indices) as loader.CArray,
                    skinVertices = source.skin_vertices ~= nil
                        and ffi.cast("float *", source.skin_vertices) as loader.CArray or nil,
                    morphVertices = source.morph_vertices ~= nil
                        and ffi.cast("float *", source.morph_vertices) as loader.CArray or nil,
                    morphTargetCount = morphTargetCount,
                    morphWeights = numbersAt(source.morph_weights as loader.CValue, source.morph_weight_count),
                    vertexCount = vertexCount,
                    indexCount = tonumber(source.index_count) as integer,
                    centerX = tonumber(source.center_x) as number,
                    centerY = tonumber(source.center_y) as number,
                    centerZ = tonumber(source.center_z) as number,
                    radius = source.radius as number,
                } as Mesh,
                MeshMT
            )
        end

        local materials: {ModelMaterial} = {}
        local nativeMaterials <const> = info.materials as loader.CArray
        for index = 0, (tonumber(info.material_count) as integer) - 1 do
            local source <const> = nativeMaterials[index] as {string: any}
            materials[index + 1] = {
                name = textAt(source.name as loader.CValue, source.name_length),
                model = tonumber(source.model) as integer,
                alphaMode = tonumber(source.alpha_mode) as integer,
                baseColorImage = tonumber(source.base_color_image) as integer,
                normalImage = tonumber(source.normal_image) as integer,
                metallicRoughnessImage = tonumber(source.metallic_roughness_image) as integer,
                occlusionImage = tonumber(source.occlusion_image) as integer,
                emissiveImage = tonumber(source.emissive_image) as integer,
                alphaCutoff = tonumber(source.alpha_cutoff),
                baseR = tonumber(source.base_r),
                baseG = tonumber(source.base_g),
                baseB = tonumber(source.base_b),
                baseA = tonumber(source.base_a),
                emissiveR = tonumber(source.emissive_r),
                emissiveG = tonumber(source.emissive_g),
                emissiveB = tonumber(source.emissive_b),
                metallic = tonumber(source.metallic),
                roughness = tonumber(source.roughness),
                normalScale = tonumber(source.normal_scale),
                occlusionStrength = tonumber(source.occlusion_strength),
                doubleSided = tonumber(source.double_sided) ~= 0,
            }
        end

        local nodes: {ModelNode} = {}
        local nativeNodes <const> = info.nodes as loader.CArray
        for index = 0, (tonumber(info.node_count) as integer) - 1 do
            local source <const> = nativeNodes[index] as {string: any}
            nodes[index + 1] = {
                parent = tonumber(source.parent) as integer,
                x = tonumber(source.x),
                y = tonumber(source.y),
                z = tonumber(source.z),
                rotationX = tonumber(source.rotation_x),
                rotationY = tonumber(source.rotation_y),
                rotationZ = tonumber(source.rotation_z),
                rotationW = tonumber(source.rotation_w),
                scaleX = tonumber(source.scale_x),
                scaleY = tonumber(source.scale_y),
                scaleZ = tonumber(source.scale_z),
                matrix = tonumber(source.has_matrix) ~= 0 and numbersAt(source.matrix as loader.CValue, 16) or nil,
            }
        end

        local skins: {ModelSkin} = {}
        local nativeSkins <const> = info.skins as loader.CArray
        for index = 0, (tonumber(info.skin_count) as integer) - 1 do
            local source <const> = nativeSkins[index] as {string: any}
            local joints <const> = numbersAt(source.joints as loader.CValue, source.joint_count, "const uint32_t *")
            local integerJoints: {integer} = {}
            for joint, value in ipairs(joints) do
                integerJoints[joint] = value as integer
            end
            skins[index + 1] = {
                name = textAt(source.name as loader.CValue, source.name_length),
                matrices = numbersAt(source.matrices as loader.CValue, source.matrix_count),
                node = tonumber(source.node) as integer,
                joints = integerJoints,
                inverseBindMatrices = numbersAt(
                    source.inverse_bind_matrices as loader.CValue, source.inverse_bind_matrix_count
                ),
            }
        end

        local nativeChannels <const> = info.channels as loader.CArray
        local animations: {ModelAnimation} = {}
        local nativeAnimations <const> = info.animations as loader.CArray
        for index = 0, (tonumber(info.animation_count) as integer) - 1 do
            local source <const> = nativeAnimations[index] as {string: any}
            local channels: {ModelAnimationChannel} = {}
            local first <const> = tonumber(source.first_channel) as integer
            for channelIndex = 0, (tonumber(source.channel_count) as integer) - 1 do
                local channel <const> = nativeChannels[first + channelIndex] as {string: any}
                channels[channelIndex + 1] = {
                    node = tonumber(channel.node) as integer,
                    path = tonumber(channel.path) as integer,
                    interpolation = tonumber(channel.interpolation) as integer,
                    width = tonumber(channel.width) as integer,
                    times = numbersAt(channel.times as loader.CValue, channel.time_count),
                    values = numbersAt(channel.values as loader.CValue, channel.value_count),
                }
            end
            animations[index + 1] = {
                name = textAt(source.name as loader.CValue, source.name_length),
                duration = tonumber(source.duration),
                channels = channels,
            }
        end

        local draws: {ModelDraw} = {}
        local nativeDraws <const> = info.draws as loader.CArray
        for index = 0, (tonumber(info.draw_count) as integer) - 1 do
            local source <const> = nativeDraws[index] as {string: any}
            draws[index + 1] = {
                mesh = tonumber(source.mesh) as integer,
                material = tonumber(source.material) as integer,
                skin = tonumber(source.skin) as integer,
                node = tonumber(source.node) as integer,
                weights = numbersAt(source.weights as loader.CValue, source.weight_count),
                x = tonumber(source.x),
                y = tonumber(source.y),
                z = tonumber(source.z),
                rotationX = tonumber(source.rotation_x),
                rotationY = tonumber(source.rotation_y),
                rotationZ = tonumber(source.rotation_z),
                rotationW = tonumber(source.rotation_w),
                scaleX = tonumber(source.scale_x),
                scaleY = tonumber(source.scale_y),
                scaleZ = tonumber(source.scale_z),
            }
        end
        return setmetatable(
            {
                path = textAt(info.path as loader.CValue, info.path_length),
                mipmaps = tonumber(info.mipmaps) ~= 0,
                meshes = meshes,
                images = images,
                materials = materials,
                skins = skins,
                nodes = nodes,
                animations = animations,
                draws = draws,
            } as Model,
            ModelMT
        )
    end) as (boolean, any)
    if not built then
        for _, mesh in ipairs(meshes) do
            mesh:release()
        end
        for _, image in ipairs(images) do
            image:release()
        end
        ffi.gc(owner as ffi.CData, nil)
        RUST.tecsModelDestroy(owner)
        error(tostring(modelOrReason), 0)
    end
    local model <const> = modelOrReason as Model
    modelOwners[model] = owner
    return model
end

function assets.newMesh(options: MeshOptions): Mesh
    if options == nil then
        error("tecs: mesh options are required", 2)
    end
    local name <const> = options.name
    if name == nil or name == "" then
        error("tecs: a mesh name cannot be empty", 2)
    end

    local sourceVertices <const> = options.vertices
    local sourceIndices <const> = options.indices
    local vertexFloats <const> = sourceVertices and #sourceVertices or 0
    if vertexFloats == 0 or vertexFloats % meshlayout.VERTEX_FLOATS ~= 0 then
        error(
            ("tecs: mesh '%s' needs a non-empty multiple of %d vertex floats"):format(name, meshlayout.VERTEX_FLOATS), 2
        )
    end
    local indexCount <const> = sourceIndices and #sourceIndices or 0
    if indexCount == 0 or indexCount % 3 ~= 0 then
        error(("tecs: mesh '%s' needs a non-empty multiple of 3 indices"):format(name), 2)
    end

    local vertexCount <const>: integer = math.floor(vertexFloats / meshlayout.VERTEX_FLOATS)
    local sourceJoints <const> = options.joints
    local sourceWeights <const> = options.weights
    if (sourceJoints == nil) ~= (sourceWeights == nil) then
        error(("tecs: mesh '%s' joints and weights must be supplied together"):format(name), 2)
    end
    if sourceJoints ~= nil and (#sourceJoints ~= vertexCount * 4 or #sourceWeights ~= vertexCount * 4) then
        error(("tecs: mesh '%s' needs four joints and weights per vertex"):format(name), 2)
    end
    local sourceColors <const> = options.colors
    if sourceColors ~= nil and #sourceColors ~= vertexCount * meshlayout.COLOR_VERTEX_FLOATS then
        error(("tecs: mesh '%s' needs four colors per vertex"):format(name), 2)
    end
    local colorVertices: loader.CArray = nil
    if sourceColors ~= nil then
        colorVertices = loader.newArray("float[?]", vertexCount * meshlayout.COLOR_VERTEX_FLOATS)
        for index = 1, #sourceColors do
            local value <const> = sourceColors[index]
            if value == nil or value < 0.0 or value > 1.0 then
                error(("tecs: mesh '%s' color %d is outside 0..1"):format(name, index), 2)
            end
            colorVertices[index - 1] = value
        end
    end
    local vertices <const> = loader.newArray("float[?]", vertexFloats)
    local minX, minY, minZ = math.huge, math.huge, math.huge
    local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
    for index = 1, vertexFloats do
        local value <const> = sourceVertices[index]
        if value == nil then
            error(("tecs: mesh '%s' has a missing vertex float at %d"):format(name, index), 2)
        end
        vertices[index - 1] = value
        local lane <const> = (index - 1) % meshlayout.VERTEX_FLOATS
        if lane == 0 then
            minX = math.min(minX, value)
            maxX = math.max(maxX, value)
        elseif lane == 1 then
            minY = math.min(minY, value)
            maxY = math.max(maxY, value)
        elseif lane == 2 then
            minZ = math.min(minZ, value)
            maxZ = math.max(maxZ, value)
        end
    end

    local indices <const> = loader.newArray("uint32_t[?]", indexCount)
    for index = 1, indexCount do
        local value <const> = sourceIndices[index]
        if value == nil or value < 0 or value >= vertexCount or value ~= math.floor(value) then
            error(("tecs: mesh '%s' index %d is outside 0..%d"):format(name, index, vertexCount - 1), 2)
        end
        indices[index - 1] = value
    end

    local skinVertices: loader.CArray = nil
    if sourceJoints ~= nil then
        skinVertices = loader.newArray("float[?]", vertexCount * meshlayout.SKIN_VERTEX_FLOATS)
        for vertex = 0, vertexCount - 1 do
            local sourceBase <const> = vertex * 4
            local destinationBase <const> = vertex * meshlayout.SKIN_VERTEX_FLOATS
            local total = 0.0
            for lane = 0, 3 do
                local joint <const> = sourceJoints[sourceBase + lane + 1]
                local weight <const> = sourceWeights[sourceBase + lane + 1]
                if joint == nil or joint < 0 or joint ~= math.floor(joint) then
                    error(("tecs: mesh '%s' has an invalid joint at vertex %d"):format(name, vertex), 2)
                end
                if weight == nil or weight < 0 then
                    error(("tecs: mesh '%s' has an invalid weight at vertex %d"):format(name, vertex), 2)
                end
                skinVertices[destinationBase + lane] = joint
                skinVertices[destinationBase + 4 + lane] = weight
                total = total + weight
            end
            if total <= 1e-20 then
                error(("tecs: mesh '%s' has zero joint weight at vertex %d"):format(name, vertex), 2)
            end
            for lane = 0, 3 do
                skinVertices[destinationBase + 4 + lane] = (skinVertices[destinationBase + 4 + lane] as number) / total
            end
        end
    end

    local morphTargets <const> = options.morphTargets or {}
    local morphTargetCount <const> = #morphTargets
    local morphWeights <const> = options.morphWeights or {}
    if #morphWeights ~= 0 and #morphWeights ~= morphTargetCount then
        error(("tecs: mesh '%s' needs one default weight per morph target"):format(name), 2)
    end
    local morphVertices: loader.CArray = nil
    local morphRadius = 0.0
    if morphTargetCount > 0 then
        morphVertices = loader.newArray("float[?]", vertexCount * morphTargetCount * meshlayout.MORPH_VERTEX_FLOATS)
        for targetIndex, target in ipairs(morphTargets) do
            local positions <const> = target.positions
            local normals <const> = target.normals
            local tangents <const> = target.tangents
            if positions == nil or #positions ~= vertexCount * 3 then
                error(
                    ("tecs: mesh '%s' morph target %d needs three position deltas per vertex"):format(
                        name, targetIndex
                    ),
                    2
                )
            end
            if normals ~= nil and #normals ~= vertexCount * 3 then
                error(
                    ("tecs: mesh '%s' morph target %d needs three normal deltas per vertex"):format(name, targetIndex),
                    2
                )
            end
            if tangents ~= nil and #tangents ~= vertexCount * 3 then
                error(
                    ("tecs: mesh '%s' morph target %d needs three tangent deltas per vertex"):format(
                        name, targetIndex
                    ),
                    2
                )
            end
            for vertex = 0, vertexCount - 1 do
                local sourceBase <const> = vertex * 3
                local destination <const> = ((targetIndex - 1) * vertexCount + vertex) * meshlayout.MORPH_VERTEX_FLOATS
                for lane = 0, 2 do
                    local position <const> = positions[sourceBase + lane + 1]
                    local normal <const> = normals ~= nil and normals[sourceBase + lane + 1] or 0.0
                    local tangent <const> = tangents ~= nil and tangents[sourceBase + lane + 1] or 0.0
                    if
                        position == nil
                        or position ~= position
                        or position == math.huge
                        or position == -math.huge
                        or normal ~= normal
                        or normal == math.huge
                        or normal == -math.huge
                        or tangent ~= tangent
                        or tangent == math.huge
                        or tangent == -math.huge
                    then
                        error(
                            ("tecs: mesh '%s' morph target %d contains a non-finite delta"):format(name, targetIndex), 2
                        )
                    end
                    morphVertices[destination + lane] = position
                    morphVertices[destination + 3 + lane] = normal
                    morphVertices[destination + 6 + lane] = tangent
                end
            end
        end
        for vertex = 0, vertexCount - 1 do
            local displacement = 0.0
            for targetIndex = 1, morphTargetCount do
                local source <const> = ((targetIndex - 1) * vertexCount + vertex) * meshlayout.MORPH_VERTEX_FLOATS
                local dx, dy, dz <const> = morphVertices[source] as number,
                    morphVertices[source + 1] as number,
                    morphVertices[source + 2] as number
                displacement = displacement + math.sqrt(dx * dx + dy * dy + dz * dz)
            end
            morphRadius = math.max(morphRadius, displacement)
        end
    end
    local defaultMorphWeights: {number} = {}
    for index = 1, morphTargetCount do
        local weight <const> = #morphWeights == 0 and 0.0 or morphWeights[index]
        if weight == nil or weight ~= weight or weight == math.huge or weight == -math.huge then
            error(("tecs: mesh '%s' morph weight %d is not finite"):format(name, index), 2)
        end
        defaultMorphWeights[index] = weight
    end

    local centerX <const> = (minX + maxX) * 0.5
    local centerY <const> = (minY + maxY) * 0.5
    local centerZ <const> = (minZ + maxZ) * 0.5
    local radiusSquared: number = 0.0
    for vertex = 0, vertexCount - 1 do
        local base <const> = vertex * meshlayout.VERTEX_FLOATS
        local dx <const>: number = (vertices[base] as number) - centerX
        local dy <const>: number = (vertices[base + 1] as number) - centerY
        local dz <const>: number = (vertices[base + 2] as number) - centerZ
        local distanceSquared <const>: number = dx * dx + dy * dy + dz * dz
        if distanceSquared > radiusSquared then
            radiusSquared = distanceSquared
        end
    end

    return setmetatable(
        {
            name = name,
            vertices = vertices,
            colorVertices = colorVertices,
            indices = indices,
            skinVertices = skinVertices,
            morphVertices = morphVertices,
            morphTargetCount = morphTargetCount,
            morphWeights = defaultMorphWeights,
            vertexCount = vertexCount,
            indexCount = indexCount,
            centerX = centerX,
            centerY = centerY,
            centerZ = centerZ,
            radius = math.sqrt(radiusSquared) + morphRadius,
        } as Mesh,
        MeshMT
    )
end

--- One load the worker has been given and has not answered for.
---
--- The private root completion stays here rather than reaching callers. Each
--- direct load subscribes independently, which lets several loads share one
--- decode without exposing one completion object: see `loadImage`.
local record Entry
    id: integer
    --- "model" or "sound", which decides what the answer is built into.
    kind: string
    path: string
    root: Completion<any>
end

local pending: {integer: Entry} = {}
--- The same entries by root completion, so the source's cancel hook can start from
--- the completion whose last watcher has gone.
local byCompletion: {Completion<any>: Entry} = {}
--- Counted rather than walked, because `waitAll` reads it in a loop.
local pendingCount = 0
local nextId = 1
local worker: workers.Worker = nil

-- Image acquisition and decode do not use the Lua worker, but they are still
-- one asset load for ownership, coalescing, shutdown, and waitAll. A root is
-- shared only while this pipeline is in flight; publication removes it before
-- listeners run, so a later call deliberately starts a fresh decode.
local record ImageLoad
    path: string
    root: Completion<Image>
    current: Completion<any>
end

local imageLoads <const>: {string: ImageLoad} = {}
local imageByRoot <const>: {Completion<any>: ImageLoad} = {}
local imagePendingCount = 0
local imageSource: Completion.Source

--- Starts the loading worker.
---
--- Installing twice is installing once. Spawning unconditionally would leave
--- the first thread running with both its channels and nothing reading them,
--- and every queued decode would answer into an abandoned channel, so a load
--- in flight across the second call would never resolve.
---
--- @param luaPath `package.path` for the worker's own state, which shares no loaded modules
---     with this one. Defaults to this state's, which is what makes the worker resolve the
---     same modules the game does.
function assets.install(luaPath?: string)
    if worker ~= nil then
        return
    end
    worker = workers.spawn({
        source = DECODER,
        luaPath = luaPath or package.path,
    })
    runtime.register("assets", 10, pollRuntime, nil)
end

function assets.installed(): boolean
    return worker ~= nil
end

-------------------------------------------------------------------------------
-- Settling
-------------------------------------------------------------------------------

--- Settles when nothing is in flight, so `waitAll` is one `Completion:wait` rather
--- than a wall-clock loop written again here.
---
--- Created on demand and dropped once it settles, because a wait that ran out
--- of time leaves it pending and the next one joins the same drain.
local idle: Completion<integer> = nil

--- Forgets a load the worker has answered for.
local function retire(entry: Entry)
    pending[entry.id] = nil
    byCompletion[entry.root] = nil
    pendingCount = pendingCount - 1
end

--- Destroys what the worker sent for a decode nobody is waiting on any more.
---
--- Ownership transfers with the address whether or not anyone still wants it,
--- so this function frees the result instead of leaking it to a completion that has
--- already settled "canceled".
local function discard(result: {string: any})
    if result.audio ~= nil then
        MIX.MIX_DestroyAudio(ffi.cast("MIX_Audio *", ffi.cast("uintptr_t", result.audio)) as loader.CValue)
    end
    if result.model ~= nil then
        RUST.tecsModelDestroy(ffi.cast("TecsModel *", ffi.cast("uintptr_t", result.model)) as loader.CValue)
    end
end

--- Settles one load result into its associated completion.
local function settleResult(result: {string: any}): boolean
    local entry = pending[result.id as integer]
    if entry == nil then
        return false
    end
    retire(entry)
    local root = entry.root

    -- Canceled while the worker was still decoding: every caller gave up before
    -- this arrived.
    if root.status ~= "pending" then
        discard(result)
        return true
    end

    if result.error ~= nil then
        root:fail(result.error as string)
        return true
    end

    if entry.kind == "sound" then
        local sound = setmetatable(
            {
                path = entry.path,
                resident = result.resident as boolean,
                durationMs = result.durationMs as integer,
                -- One holder, because sound loads do not deduplicate.
                _refs = 1,
            } as Sound,
            SoundMT
        )
        if sound.resident then
            -- Ownership arrived with the address, exactly as it does for a
            -- surface. The mixer allocated this, so the mixer frees it.
            sound.audio = ffi.cast("MIX_Audio *", ffi.cast("uintptr_t", result.audio)) as loader.CValue
        end
        root:complete(sound)
        return true
    end

    if entry.kind == "model" then
        local built, model = pcall(modelFromWorker, result) as (boolean, any)
        if not built then
            root:fail(tostring(model))
        else
            root:complete(model as Model)
        end
        return true
    end

    root:fail("unknown asset CPU result")
    return true
end

--- Settles one load result, and ends a process-wide drain that this emptied.
---
--- The function settles the drain after the result rather than inside it, because a
--- listener the settlement runs is free to start another load and a `waitAll`
--- that returned before it did would have left one outstanding.
---
--- @return Whether the function matched the result to a queued decode. False for a result
---     arriving after `shutdown` dropped what it belonged to.
local function complete(result: {string: any}): boolean
    local answered = settleResult(result)
    if pendingCount == 0 and imagePendingCount == 0 and idle ~= nil then
        -- Cleared before it settles, so a load started from a listener on it
        -- opens a fresh drain rather than joining one that has already answered.
        local settling = idle
        idle = nil
        settling:complete(0)
    end
    return answered
end

function Image:release()
    -- Guarded rather than allowed to go negative: a shutdown path that releases
    -- what something else already released must free once, not twice.
    if self._refs <= 0 then
        return
    end
    self._refs = self._refs - 1
    if self._refs > 0 then
        return
    end
    RUST.tecsImageDestroy(self._image)
    self._image = nil
    self.pixels = nil
end

function Sound:release()
    if self._refs <= 0 then
        return
    end
    self._refs = self._refs - 1
    if self._refs > 0 then
        return
    end
    if self.audio ~= nil then
        MIX.MIX_DestroyAudio(self.audio)
        self.audio = nil
        self.resident = false
    end
end

-------------------------------------------------------------------------------
-- The source
-------------------------------------------------------------------------------

--- Milliseconds one blocking slice of a wait spends.
local SLICE_MS <const> = 16

--- Milliseconds a wait spends when the caller names nothing.
local DEFAULT_WAIT_MS <const> = 5000

--- What drives every private loader completion.
---
--- `poll` and `advance` are the same receive with a different budget, which is
--- the whole of what a completion needs from a worker channel.
local record Loader
    sliceMs: number
    defaultWaitMs: number

    poll: function(self: Loader): integer
    advance: function(self: Loader, ms: number): integer
    cancel: function(self: Loader, completion: Completion<any>)
end

local LoaderMT <const>: metatable<Loader> = {__index = Loader}

function Loader:poll(): integer
    if worker == nil then
        return 0
    end
    local completed = 0
    while true do
        local result = worker:receive(0)
        if result == nil then
            break
        end
        if complete(result as {string: any}) then
            completed = completed + 1
        end
    end
    return completed
end

function Loader:advance(ms: number): integer
    if worker == nil then
        return 0
    end
    local result = worker:receive(ms)
    if result == nil then
        return 0
    end
    return complete(result as {string: any}) and 1 or 0
end

--- Gives up a load whose last caller has gone.
---
--- The worker takes its tasks off a channel and cannot be told to drop one, so
--- the decode runs to the end whatever happens here. What this does is release
--- the path, so a later load of it starts a fresh decode rather than joining
--- one nobody wants; the entry stays queued, and `complete` destroys the
--- address when it arrives because ownership transfers with it either way.
function Loader:cancel(completion: Completion<any>)
    local entry = byCompletion[completion]
    if entry == nil then
        return
    end
end

local pump <const> = setmetatable(
    {
        -- Both live here rather than in `Completion`, which is what lets a decode keep
        -- a shorter default than a child process without a second convention.
        sliceMs = SLICE_MS,
        defaultWaitMs = DEFAULT_WAIT_MS,
    } as Loader,
    LoaderMT
)

local source <const> = pump as Completion.Source

-------------------------------------------------------------------------------
-- Loading
-------------------------------------------------------------------------------

local function forgetImage(entry: ImageLoad)
    if imageLoads[entry.path] ~= entry then
        return
    end
    imageLoads[entry.path] = nil
    imageByRoot[entry.root as Completion<any>] = nil
    imagePendingCount = imagePendingCount - 1
    if pendingCount == 0 and imagePendingCount == 0 and idle ~= nil then
        local settling <const> = idle
        idle = nil
        settling:complete(0)
    end
end

local function finishImage(entry: ImageLoad, image?: Image, reason?: string)
    forgetImage(entry)
    local root <const> = entry.root
    if root.status == "pending" then
        if image ~= nil then
            root:complete(image)
        else
            root:fail(reason or "image load failed")
        end
    elseif image ~= nil then
        -- Every consumer gave up after native publication won the race.
        image._refs = 1
        image:release()
    end
end

local function beginImage(path: string): Completion<Image>
    local root <const> = Completion.pending(imageSource) as Completion<Image>
    -- The producer is tracked by ImageLoad. Watchers are only direct callers,
    -- so canceling the last one can release the native stage.
    root._watchers = 0
    local entry: ImageLoad = {path = path, root = root}
    imageLoads[path] = entry
    imageByRoot[root as Completion<any>] = entry
    imagePendingCount = imagePendingCount + 1

    local read <const> = fileasync.read(path)
    entry.current = read as Completion<any>
    read:onSettle(function(settled: Completion<fileasync.NativeRead>)
        if settled.status ~= "ready" then
            finishImage(entry, nil, settled.error or "cannot read image")
            return
        end
        local result <const> = settled.value
        if root.status ~= "pending" then
            fileasync.release(result)
            forgetImage(entry)
            return
        end
        content.note(path, "image")
        local moved <const>, bytes = pcall(fileasync.takeBytes, result) as (boolean, loader.CPtr | string)
        if not moved then
            finishImage(entry, nil, tostring(bytes))
            return
        end
        local decode <const> = cpuimage.decode(bytes as loader.CPtr)
        entry.current = decode as Completion<any>
        decode:onSettle(function(decoded: Completion<loader.CPtr>)
            if decoded.status ~= "ready" then
                finishImage(entry, nil, decoded.error or "cannot decode image")
                return
            end
            local ok <const>, image = pcall(function(): Image
                return imageFromAllocation(path, cpuimage.take(decoded.value), 0)
            end) as (boolean, Image | string)
            if ok then
                finishImage(entry, image as Image)
            else
                finishImage(entry, nil, tostring(image))
            end
        end)
    end)
    return root
end

local record ImageSource
    sliceMs: number
    defaultWaitMs: number
    poll: function(self: ImageSource): integer
    advance: function(self: ImageSource, ms: number): integer
    cancel: function(self: ImageSource, completion: Completion<any>)
end

function ImageSource:poll(): integer
    return runtime.poll()
end

function ImageSource:advance(ms: number): integer
    for _, entry in pairs(imageLoads) do
        local current <const> = entry.current
        if current ~= nil and current.status == "pending" and current._source ~= nil then
            return current._source:advance(ms)
        end
    end
    return 0
end

function ImageSource:cancel(completion: Completion<any>)
    local entry <const> = imageByRoot[completion]
    if entry == nil then
        return
    end
    local current <const> = entry.current
    if current ~= nil and current.status == "pending" then
        current:cancel()
    end
    forgetImage(entry)
end

imageSource = {
    sliceMs = 1,
    defaultWaitMs = 30000,
    poll = ImageSource.poll,
    advance = ImageSource.advance,
    cancel = ImageSource.cancel,
} as ImageSource as Completion.Source

--- A root completion the loader owns and never hands out.
---
--- `Completion.pending` starts with one watcher, which is right when its caller
--- owns the operation. The loader owns only the producer side. Each direct load
--- adds its own subscription, so this removes the producer's initial hold.
local function newRoot(): Completion<any>
    local root = Completion.pending(source) as Completion<any>
    root._watchers = 0
    return root
end

--- Registers a load, and answers the completion it will settle and the id the
--- worker will answer with.
local function queue(kind: string, path: string): Completion<any>, integer
    if worker == nil then
        error("tecs: assets.install must run before loading", 3)
    end
    local id = nextId
    nextId = nextId + 1
    local root = newRoot()
    local entry: Entry = {id = id, kind = kind, path = path, root = root}
    pending[id] = entry
    byCompletion[root] = entry
    pendingCount = pendingCount + 1
    return root, id
end

local function awaitRoot<T>(root: Completion<T>, operation: string): T
    local settled = root
    if root.status == "pending" then
        if task.checkWait(operation) == "blocking" then
            root:wait()
        else
            settled = task.awaitCallback(function(resume: function(Completion<T>)): function()
                return Completion.subscribe(root as Completion<any>, resume as function(Completion<any>))
            end)
        end
    end
    if settled.status == "ready" then
        return settled.value
    end
    if settled.status == "failed" then
        error(("tecs: %s failed: %s"):format(operation, settled.error or "failed"), 3)
    end
    if settled.status == "pending" then
        error(("tecs: %s did not complete within its wait budget"):format(operation), 3)
    end
    error(("tecs: %s was canceled: %s"):format(operation, settled.error or "canceled"), 3)
end

--- Loads an image and returns its decoded pixels.
---
--- Two loads of one path that overlap share a decode, because decoding the same
--- PNG twice at once duplicates work without producing another result.
--- They share the [`Image`](tealdoc:tecs.assets.Image), so the last caller to
--- release it frees the pixels. A load that starts after the first has settled
--- decodes again: nothing here is a cache.
---
--- @param path The caller supplies a PNG, JPEG, static SVG, or linear BC3 KTX2
---     path. KTX2 input must contain one complete mip chain for one image.
---     The loader
---     renders SVG at its intrinsic width and height, uses bundled JetBrains
---     Mono for text, and ignores external image references. Another format
---     fails during decoding.
--- @return Returns the decoded image. Inside a system, the call suspends only
---     while its decode is pending. A missing file or decode failure raises.
function assets.loadImage(path: string): Image
    if type(path) ~= "string" or path == "" then
        error("tecs: image load needs a path", 2)
    end
    if adapter.storage() ~= storagebackend.sdl then
        local files <const> = require("tecs.io.files")
        local bytes <const> = files.read(path, "image")
        if bytes == nil then
            error("tecs: image load failed: cannot read " .. path, 2)
        end
        return imageFromBytes(bytes, path)
    end
    local root <const> = imageLoads[path] ~= nil and imageLoads[path].root or beginImage(path)
    local image <const> = awaitRoot(root, "image load")
    image._refs = image._refs + 1
    return image
end

--- Reads a complete file and returns its bytes.
---
--- The returned string preserves embedded NUL bytes. The operation uses the
--- common file lane; callers that need retained reuse store the returned
--- immutable string in their own asset resource.
---
--- @param path The caller supplies an absolute path or one from
---     [`assetPath`](/modules/io/files/#tecs.io.files.assetPath).
--- @param kind The caller supplies the content kind used by file watching, or
---     omits it to record a document.
--- @return Returns the complete bytes. A missing or unreadable file raises
---     after the worker reports the failure.
function assets.loadString(path: string, kind?: string): string
    local files <const> = require("tecs.io.files")
    local bytes <const> = files.read(path, kind)
    if bytes == nil then
        error("tecs: file load failed: cannot read " .. tostring(path), 2)
    end
    return bytes
end

function assets.loadGLTF(path: string): Model
    content.note(path, "model")
    task.checkWait("model load")
    local root, id = queue("model", path)
    worker:send({id = id, kind = "model", path = path})
    return awaitRoot(root as Completion<Model>, "model load")
end

--- Loads a sound and returns its decoded or streaming payload.
---
--- Whatever the mixer's decoders can read loads, so the format is the file's
--- business rather than the caller's.
---
--- `mode` is "resident", "stream", or "auto", and auto keeps anything shorter
--- than `streamMs` resident.
---
--- This call initializes the library instead of the worker because `MIX_Init`
--- does not support concurrent calls. Initialization before sending the task puts it
--- in order ahead of every decode without a lock.
---
--- Two overlapping loads of one path do not share, unlike images: each gets its
--- own clip, because that is what `MIX_LoadAudio` produces. The returned
--- [`Sound`](tealdoc:tecs.assets.Sound) has exactly one holder.
---
--- @param mode "resident", "stream" or "auto". Any other value selects "stream".
--- @param streamMs The boundary "auto" decides on, in milliseconds. Read only under
---     "auto", and a file whose length the container cannot state streams whatever it says.
--- @return Returns the loaded sound. Mixer initialization or decode failure
---     raises.
function assets.loadSound(path: string, mode: string, streamMs: integer): Sound
    content.note(path, "sound")
    task.checkWait("sound load")
    if not sdl3mixer.init() then
        error("tecs: cannot load " .. path, 2)
    end
    local root, id = queue("sound", path)
    worker:send({
        id = id,
        kind = "sound",
        path = path,
        mode = mode,
        streamMs = streamMs,
    })
    return awaitRoot(root as Completion<Sound>, "sound load")
end

-------------------------------------------------------------------------------
-- Draining
-------------------------------------------------------------------------------

local function pollAssets(): integer
    return pump:poll()
end

runtimePoll = pollAssets

--- Returns the number of asset loads still in flight.
---
--- @return Every image decode, model load, and sound load owned by this module,
---     not one caller's. `loadString` uses the shared file lane directly and is
---     not counted. A model or sound load every caller has canceled remains
---     counted until the worker answer is taken and destroyed.
function assets.pending(): integer
    return pendingCount + imagePendingCount
end

--- Blocks until every queued load has finished.
---
--- This global barrier is for startup, shutdown, and tests outside a system.
--- Applications use the process runtime during frames.
---
--- It waits on every load in this process, including work a subsystem started,
--- rather than only loads one caller initiated.
---
--- @param timeoutMs Wall-clock milliseconds, defaulting to 5000. Running out is not an
---     error and is not reported, so read `assets.pending` afterwards to tell the two
---     endings apart.
function assets.waitAll(timeoutMs?: number)
    if pendingCount == 0 and imagePendingCount == 0 then
        return
    end
    local deadline <const> = time.now() * 1000 + (timeoutMs or 5000)
    repeat
        runtime.poll()
        if pendingCount > 0 then
            pump:advance(1)
        elseif imagePendingCount > 0 then
            (imageSource as Completion.Source):advance(1)
        end
    until (pendingCount == 0 and imagePendingCount == 0) or time.now() * 1000 >= deadline
end

--- Stops the loading worker.
---
--- Blocks until the thread exits. This call cancels loads still in flight, so
--- drain with `waitAll` first when their results matter.
--- Releasing an [`Image`](tealdoc:tecs.assets.Image) or a
--- [`Sound`](tealdoc:tecs.assets.Sound) that already settled still works afterwards; this
--- frees nothing.
function assets.shutdown()
    local imageEntries: {ImageLoad} = {}
    for _, entry in pairs(imageLoads) do
        imageEntries[#imageEntries + 1] = entry
    end
    for index = 1, #imageEntries do
        local entry <const> = imageEntries[index]
        if entry.current ~= nil and entry.current.status == "pending" then
            entry.current:cancel()
        end
        forgetImage(entry)
        entry.root:abandon("the asset lanes were shut down")
    end
    cpuimage.shutdown()
    if worker == nil then
        return
    end
    worker:stop()
    worker = nil
    runtime.unregister("assets")
    pending = {}
    byCompletion = {}
    pendingCount = 0
    if idle ~= nil then
        -- The drain it was waiting for will not finish, and saying so is more
        -- truthful than settling it as though it had.
        local abandoned = idle
        idle = nil
        abandoned:abandon("the loading worker was shut down")
    end
end

return assets
