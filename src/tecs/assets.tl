--[=[
Reads bytes and decodes images and sounds on a worker.

Loads return their values directly. Inside a system dispatched by
`world:update`, a worker decode transparently suspends the logical update:

```teal no-format
return tecs.newApplication({
    plugin = function(world: tecs.World, app: tecs.Application)
        world:addSystem({
            name = "game.SpawnHero",
            phase = tecs.ecs.phases.Startup,
            run = function()
                local image <const> = tecs.assets.loadImage(
                    tecs.io.files.assetPath("sprites/hero.png")
                )
                local sprite <const> = app.renderer.sprites:registerImage(image)
                world:spawn(
                    tecs.Transform2D(100, 100),
                    sprite,
                    tecs.gfx.Renderable2D()
                )
            end,
        })
    end,
})
```

The loader decodes pixels but creates no GPU resource. The renderer decides
texture residency. Audio follows the same split between decoded clips and
voices.

`newMesh` constructs immutable procedural geometry synchronously. `loadGLTF`
decodes glTF 2.0 and GLB scenes on the worker, including images,
metallic-roughness materials, vertex colors, alpha masks, `BLEND` modes, skins,
and node animation clips including morph weights. Both produce
CPU-owned data that the mesh domain consumes when it becomes resident. A model
with a `BLEND` material requires a mesh domain created with
`transparency = true`.

One imported primitive becomes one independently bounded GPU-culling command.
The decoder splits a primitive above 65,536 triangles into bounded commands,
remapping the vertices and optional color, skin, and morph streams in each
chunk. Smaller primitives keep their authored order and representation.

The repository's large-scene fetch command can replace source images with
complete BC3 mip chains. Those images remain compressed through upload and
require a mesh domain created with `textureFormat = tecs.assets.IMAGE_BC3`,
`mipmaps = true`, and `packTextures = false`. Normal `loadImage` and ordinary
glTF images remain decoded RGBA8.

## Lifetime

[`Application`](tealdoc:tecs.Application) installs and shuts down the process-wide worker, and
[`runtime.poll`](/modules/runtime/#tecs.runtime.poll) updates it. Headless code
must call `install` before loading and `shutdown` afterwards. A load outside a
world update blocks and pumps its worker until the value or failure arrives.

Release a payload after its consumer takes ownership. The final release frees
the decoded memory.

Overlapping image loads for one path share a decode and receive holds on the
same image. A later load after settlement decodes again. Sound loads never
share.

`loadString` reads a complete file into a binary-safe string without
interpreting it. Image loads accept PNG, JPEG and static SVG. SVG renders at
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
local Future <const> = require("tecs.internal.completion")
local task <const> = require("tecs.internal.taskruntime")
local runtime <const> = require("tecs.internal.runtime")
local meshlayout <const> = require("tecs.gpu.meshlayout")

local record FutureOperations
    _subscribe: function(future: Future<any>, listener: function(Future<any>)): function()
end

local futureOperations <const> = Future as FutureOperations

local runtimePoll: function(): integer
local function pollRuntime(): integer
    return runtimePoll()
end

local MIX <const> = sdl3mixer.C
local RUST <const> = rust.C
local IMAGE_RGBA8 <const> = 0
local IMAGE_BC3 <const> = 1
local COMPRESSED_HEADER_BYTES <const> = 36
local COMPRESSED_MAGIC <const> = "TECSBC3\0"

--- Runs on the worker. Decodes to a normalized layout and returns an address.
local DECODER <const> = [==[
local ffi = require("ffi")
local mixer = require("tecs.ffi.sdl3mixer")
local rust = require("tecs.ffi.rust")
local loader = require("tecs.ffi.loader")
local files = require("tecs.io.files")
local workers = require("tecs.workers")
local gltf = require("tecs.internal.gltf")

local MIX = mixer.C
local RUST = rust.C

local self = workers.current()

local function decodeImage(task)
    local bytes = files.read(task.path, "image")
    if bytes == nil then
        return { id = task.id, error = "cannot decode " .. task.path }
    end

    local decoded = RUST.tecsImageDecode(
        ffi.cast("const uint8_t *", bytes),
        #bytes
    )
    if decoded == nil then
        local reason = loader.toString(RUST.tecsRustError())
        return {
            id = task.id,
            error = "cannot decode " .. task.path .. ": " .. reason,
        }
    end
    local width = tonumber(RUST.tecsImageWidth(decoded))
    local height = tonumber(RUST.tecsImageHeight(decoded))
    return {
        id = task.id,
        image = tonumber(ffi.cast("uintptr_t", decoded)),
        width = width,
        height = height,
        pitch = width * 4,
    }
end

local function readBytes(task)
    local bytes = files.read(task.path)
    if bytes == nil then
        return {id = task.id, error = "cannot read " .. task.path}
    end
    return {id = task.id, bytes = bytes}
end

local function decodeModel(task)
    local ok, result = pcall(gltf.decodeFile, task.path)
    if not ok then
        return {id = task.id, error = tostring(result)}
    end
    result.id = task.id
    return result
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
    elseif task.kind == "bytes" then
        self:send(readBytes(task))
    else
        self:send(decodeImage(task))
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

    --- Engine-owned. Stores the decoded image allocation until the last
    --- `release`. Ordinary game code should ignore this field.
    _image: loader.CValue

    --- Engine-owned. Retains imported compressed bytes while `pixels` points
    --- into them. Ordinary game code should ignore this field.
    _bytes: string

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
    --- Read-only. Reports the metallic factor.
    metallic: number
    --- Read-only. Reports the roughness factor.
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
    --- JOINTS_0, WEIGHTS_0, skins, inverse bind matrices, morph targets, mesh
    --- and node weights, and node animation clips are decoded. A
    --- sparse-accessor or non-triangle input raises at the direct load call
    --- instead of loading incompletely. A primitive above 65,536 triangles is split into
    --- independently bounded and culled mesh records.
    --- Registering a
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
end

local function uint32(bytes: string, offset: integer, path: string): integer
    local a, b, c, d <const> = string.byte(bytes, offset, offset + 3)
    if d == nil then
        error(("cannot decode %s: truncated compressed texture header"):format(path), 0)
    end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function imageFromBytes(bytes: string, path: string): Image
    if #bytes >= COMPRESSED_HEADER_BYTES and bytes:sub(1, 8) == COMPRESSED_MAGIC then
        local version <const> = uint32(bytes, 9, path)
        local width <const> = uint32(bytes, 13, path)
        local height <const> = uint32(bytes, 17, path)
        local storageWidth <const> = uint32(bytes, 21, path)
        local storageHeight <const> = uint32(bytes, 25, path)
        local levels <const> = uint32(bytes, 29, path)
        local byteCount <const> = uint32(bytes, 33, path)
        if version ~= 1 then
            error(("cannot decode %s: unsupported compressed texture version %d"):format(path, version), 0)
        end
        if
            width < 1
            or height < 1
            or width > storageWidth
            or height > storageHeight
            or levels < 1
            or byteCount ~= #bytes - COMPRESSED_HEADER_BYTES
        then
            error(("cannot decode %s: invalid compressed texture dimensions or length"):format(path), 0)
        end
        return setmetatable(
            {
                path = path,
                _bytes = bytes,
                pixels = (
                    loader.bytePointer(ffi.cast("const uint8_t *", bytes) as loader.CValue) + COMPRESSED_HEADER_BYTES
                ) as loader.CValue,
                width = width,
                height = height,
                storageWidth = storageWidth,
                storageHeight = storageHeight,
                levels = levels,
                byteCount = byteCount,
                pitch = 0,
                format = IMAGE_BC3,
                _refs = 1,
            } as Image,
            ImageMT
        )
    end
    local decoded = RUST.tecsImageDecode(ffi.cast("const uint8_t *", bytes), #bytes)
    if decoded == nil then
        error(("cannot decode %s: %s"):format(path, loader.toString(RUST.tecsRustError())), 0)
    end
    local width <const> = tonumber(RUST.tecsImageWidth(decoded)) as integer
    return setmetatable(
        {
            path = path,
            _image = decoded,
            pixels = RUST.tecsImagePixels(decoded) as loader.CValue,
            width = width,
            height = tonumber(RUST.tecsImageHeight(decoded)) as integer,
            pitch = width * 4,
            format = IMAGE_RGBA8,
            storageWidth = width,
            storageHeight = tonumber(RUST.tecsImageHeight(decoded)) as integer,
            levels = 1,
            byteCount = width * (tonumber(RUST.tecsImageHeight(decoded)) as integer) * 4,
            _refs = 1,
        } as Image,
        ImageMT
    )
end

local function modelFromWorker(result: {string: any}): Model
    local images: {Image} = {}
    local meshes: {Mesh} = {}
    local built, modelOrReason = pcall(function(): Model
        for index, source in ipairs(result.images as {{string: any}}) do
            images[index] = imageFromBytes(source.bytes as string, source.name as string)
        end
        for index, source in ipairs(result.meshes as {{string: any}}) do
            local vertexCount <const> = source.vertexCount as integer
            local indexCount <const> = source.indexCount as integer
            local vertices <const> = loader.newArray("float[?]", vertexCount * meshlayout.VERTEX_FLOATS)
            local indices <const> = loader.newArray("uint32_t[?]", indexCount)
            local skinVertices: loader.CArray = nil
            local colorVertices: loader.CArray = nil
            local morphVertices: loader.CArray = nil
            loader.copyTo(
                loader.bytePointer(vertices as loader.CValue),
                source.vertices as loader.CValue,
                vertexCount * meshlayout.VERTEX_BYTES
            )
            loader.copyTo(loader.bytePointer(indices as loader.CValue), source.indices as loader.CValue, indexCount * 4)
            if source.colorVertices ~= nil then
                colorVertices = loader.newArray("float[?]", vertexCount * meshlayout.COLOR_VERTEX_FLOATS)
                loader.copyTo(
                    loader.bytePointer(colorVertices as loader.CValue),
                    source.colorVertices as loader.CValue,
                    vertexCount * meshlayout.COLOR_VERTEX_BYTES
                )
            end
            if source.skinVertices ~= nil then
                skinVertices = loader.newArray("float[?]", vertexCount * meshlayout.SKIN_VERTEX_FLOATS)
                loader.copyTo(
                    loader.bytePointer(skinVertices as loader.CValue),
                    source.skinVertices as loader.CValue,
                    vertexCount * meshlayout.SKIN_VERTEX_BYTES
                )
            end
            local morphTargetCount <const> = source.morphTargetCount as integer or 0
            if source.morphVertices ~= nil then
                morphVertices = loader.newArray(
                    "float[?]", vertexCount * morphTargetCount * meshlayout.MORPH_VERTEX_FLOATS
                )
                loader.copyTo(
                    loader.bytePointer(morphVertices as loader.CValue),
                    source.morphVertices as loader.CValue,
                    vertexCount * morphTargetCount * meshlayout.MORPH_VERTEX_BYTES
                )
            end
            meshes[index] = setmetatable(
                {
                    name = source.name as string,
                    vertices = vertices,
                    colorVertices = colorVertices,
                    indices = indices,
                    skinVertices = skinVertices,
                    morphVertices = morphVertices,
                    morphTargetCount = morphTargetCount,
                    morphWeights = source.morphWeights as {number} or {},
                    vertexCount = vertexCount,
                    indexCount = indexCount,
                    centerX = source.centerX as number,
                    centerY = source.centerY as number,
                    centerZ = source.centerZ as number,
                    radius = source.radius as number,
                } as Mesh,
                MeshMT
            )
        end
        return setmetatable(
            {
                path = result.path as string,
                mipmaps = result.mipmaps == true,
                meshes = meshes,
                images = images,
                materials = result.materials as {ModelMaterial},
                skins = result.skins as {ModelSkin},
                nodes = result.nodes as {ModelNode},
                animations = result.animations as {ModelAnimation},
                draws = result.draws as {ModelDraw},
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
        error(tostring(modelOrReason), 0)
    end
    return modelOrReason as Model
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
    --- "bytes", "image", "model" or "sound", which decides what the answer
    --- is built into.
    kind: string
    path: string
    root: Future<any>
end

local pending: {integer: Entry} = {}
--- The same entries by root future, so the source's cancel hook can start from
--- the future whose last watcher has gone.
local byFuture: {Future<any>: Entry} = {}
--- Counted rather than walked, because `waitAll` reads it in a loop.
local pendingCount = 0
--- Tracks queued image decodes that have not answered yet, by path. A second
--- load of a path in this table joins the first rather than queueing a decode
--- of the same file beside it.
local imagesInFlight: {string: Future<any>} = {}
--- Tracks queued byte reads on the same terms. Separate from image decodes
--- because the same path may be requested in both representations at once.
local bytesInFlight: {string: Future<any>} = {}
local nextId = 1
local worker: workers.Worker = nil

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
    runtime.register("assets", 10, pollRuntime)
end

function assets.installed(): boolean
    return worker ~= nil
end

-------------------------------------------------------------------------------
-- Settling
-------------------------------------------------------------------------------

--- Settles when nothing is in flight, so `waitAll` is one `Future:wait` rather
--- than a wall-clock loop written again here.
---
--- Created on demand and dropped once it settles, because a wait that ran out
--- of time leaves it pending and the next one joins the same drain.
local idle: Future<integer> = nil

--- Forgets a load the worker has answered for.
local function retire(entry: Entry)
    pending[entry.id] = nil
    byFuture[entry.root] = nil
    pendingCount = pendingCount - 1

    -- Dropped at settlement rather than left for the next load of the path.
    -- `listen` stores a link's closure on the upstream and that closure holds
    -- the derived future, so a root still reachable through this table would
    -- keep every future ever derived from it alive for the life of the process.
    -- Nothing shows that until it is measured, which is why it is said here.
    local shared = entry.kind == "image" and imagesInFlight or entry.kind == "bytes" and bytesInFlight or nil
    if shared ~= nil and shared[entry.path] == entry.root then
        shared[entry.path] = nil
    end
end

--- Destroys what the worker sent for a decode nobody is waiting on any more.
---
--- Ownership transfers with the address whether or not anyone still wants it,
--- so this function frees the result instead of leaking it to a future that has
--- already settled "canceled".
local function discard(result: {string: any})
    if result.image ~= nil then
        RUST.tecsImageDestroy(ffi.cast("TecsImage *", ffi.cast("uintptr_t", result.image)) as loader.CValue)
    end
    if result.audio ~= nil then
        MIX.MIX_DestroyAudio(ffi.cast("MIX_Audio *", ffi.cast("uintptr_t", result.audio)) as loader.CValue)
    end
end

--- Settles one load result into its associated future.
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

    if entry.kind == "bytes" then
        root:complete(result.bytes as string)
        return true
    end

    if entry.kind == "sound" then
        local sound = setmetatable(
            {
                path = entry.path,
                resident = result.resident as boolean,
                durationMs = result.durationMs as integer,
                -- One holder, because sound does not dedupe: this future has one
                -- caller and no link of the caller's can add another.
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

    -- Ownership arrived with the address. The image stays alive until the last
    -- caller releases it, because the pixels are what they came for.
    local allocation = ffi.cast("TecsImage *", ffi.cast("uintptr_t", result.image)) as loader.CValue
    local image = setmetatable(
        {
            path = entry.path,
            _image = allocation,
            pixels = RUST.tecsImagePixels(allocation) as loader.CValue,
            width = result.width as integer,
            height = result.height as integer,
            pitch = result.pitch as integer,
            format = IMAGE_RGBA8,
            storageWidth = result.width as integer,
            storageHeight = result.height as integer,
            levels = 1,
            byteCount = (result.pitch as integer) * (result.height as integer),
            -- Zero, and counted up by each surviving caller's own link below. A
            -- caller that canceled first never runs one, which is what makes this
            -- exact rather than optimistic.
            _refs = 0,
        } as Image,
        ImageMT
    )
    root:complete(image)
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
    if pendingCount == 0 and idle ~= nil then
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
    if self._image == nil then
        self._bytes = nil
        self.pixels = nil
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
--- the whole of what a future needs from a worker channel.
local record Loader
    sliceMs: number
    defaultWaitMs: number

    poll: function(self: Loader): integer
    advance: function(self: Loader, ms: number): integer
    cancel: function(self: Loader, future: Future<any>)
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
function Loader:cancel(future: Future<any>)
    local entry = byFuture[future]
    if entry == nil then
        return
    end
    local shared = entry.kind == "image" and imagesInFlight or entry.kind == "bytes" and bytesInFlight or nil
    if shared ~= nil and shared[entry.path] == future then
        shared[entry.path] = nil
    end
end

local pump <const> = setmetatable(
    {
        -- Both live here rather than in `Future`, which is what lets a decode keep
        -- a shorter default than a child process without a second convention.
        sliceMs = SLICE_MS,
        defaultWaitMs = DEFAULT_WAIT_MS,
    } as Loader,
    LoaderMT
)

local source <const> = pump as Future.Source

-------------------------------------------------------------------------------
-- Loading
-------------------------------------------------------------------------------

--- A root future the loader owns and never hands out.
---
--- `Future.pending` counts whoever created a future as one of its watchers,
--- which is right for a caller holding what it created and wrong here. The
--- loader is the producer: the root lives in one of the shared-work tables and
--- every consumer of it is some caller's own derived future. A hold of the
--- loader's own would create a watcher nothing ever gives up, so the count
--- could never reach zero and let the source abandon the decode.
local function newRoot(): Future<any>
    local root = Future.pending(source) as Future<any>
    root._watchers = 0
    return root
end

--- Registers a load, and answers the future it will settle and the id the
--- worker will answer with.
local function queue(kind: string, path: string): Future<any>, integer
    if worker == nil then
        error("tecs: assets.install must run before loading", 3)
    end
    local id = nextId
    nextId = nextId + 1
    local root = newRoot()
    local entry: Entry = {id = id, kind = kind, path = path, root = root}
    pending[id] = entry
    byFuture[root] = entry
    pendingCount = pendingCount + 1
    return root, id
end

--- Counts one more holder of the decoded pixels, and answers them.
---
--- One per surviving caller of a shared decode: it is the transform of that
--- caller's own link, so it runs exactly when that caller's future settles
--- "ready" and never when the caller canceled first.
local function claim(image: Image): Image
    image._refs = image._refs + 1
    return image
end

local function awaitRoot<T>(root: Future<T>, operation: string): T
    if not task.active() then
        root:wait()
        if root.status == "ready" then
            return root.value
        end
        if root.status == "failed" then
            error(("tecs: %s failed: %s"):format(operation, root.error or "failed"), 3)
        end
        error(("tecs: %s was canceled: %s"):format(operation, root.error or "canceled"), 3)
    end
    local settled <const> = task.awaitCallback(function(resume: function(Future<T>)): function()
        return futureOperations._subscribe(root as Future<any>, resume as function(Future<any>))
    end)
    if settled.status == "ready" then
        return settled.value
    end
    if settled.status == "failed" then
        error(("tecs: %s failed: %s"):format(operation, settled.error or "failed"), 3)
    end
    error(("tecs: %s was canceled: %s"):format(operation, settled.error or "canceled"), 3)
end

--- Returns the one root settlement shared by overlapping image consumers.
local function imageRoot(path: string): Future<any>
    content.note(path, "image")
    local shared = imagesInFlight[path]
    if shared == nil then
        local root, id = queue("image", path)
        imagesInFlight[path] = root
        worker:send({id = id, kind = "image", path = path})
        shared = root
    end
    return shared
end

-- Internal callback view of one image load. This is the operation boundary the
-- Task prototype consumes directly: it adds one interest to the shared root,
-- reports one terminal outcome, and returns the matching cancellation action.
-- This private subscription is how a suspended system observes the shared
-- decode without allocating another completion object.
local function subscribeImage(
    path: string, listener: function(status: string, image: Image, reason: string)
): function()
    if type(listener) ~= "function" then
        error("tecs: image subscription needs a listener", 3)
    end
    local shared <const> = imageRoot(path)
    return futureOperations._subscribe(
        shared,
        function(settled: Future<any>)
            if settled.status == "ready" then
                listener("ready", claim(settled.value as Image), nil)
            else
                listener(settled.status, nil, settled.error)
            end
        end
    )
end

-- Kept outside the typed public module record. Engine internals may adapt the
-- callback operation directly while the supported surface stays value-based.
(assets as {string: any})._subscribeImage = subscribeImage

--- Loads an image and returns its decoded pixels.
---
--- Two loads of one path that overlap share a decode, because decoding the same
--- PNG twice at once duplicates work without producing another result.
--- They share the [`Image`](tealdoc:tecs.assets.Image), so the last caller to
--- release it frees the pixels. A load that starts after the first has settled
--- decodes again: nothing here is a cache.
---
--- @param path The caller supplies a PNG, JPEG or static SVG path. The loader
---     renders SVG at its intrinsic width and height, uses bundled JetBrains
---     Mono for text, and ignores external image references. Another format
---     fails during decoding.
--- @return Returns the decoded image. Inside a system, the call suspends only
---     while its decode is pending. A missing file or decode failure raises.
function assets.loadImage(path: string): Image
    return claim(awaitRoot(imageRoot(path), "image load") as Image)
end

--- Reads a complete file and returns its bytes.
---
--- The returned string preserves embedded NUL bytes. Overlapping reads of one
--- path share the worker task. A later read after settlement reads the file
--- again.
---
--- @param path The caller supplies an absolute path or one from
---     [`assetPath`](/modules/io/files/#tecs.io.files.assetPath).
--- @param kind The caller supplies the content kind used by file watching, or
---     omits it to record a document.
--- @return Returns the complete bytes. A missing or unreadable file raises
---     after the worker reports the failure.
function assets.loadString(path: string, kind?: string): string
    content.note(path, kind or "document")
    local shared = bytesInFlight[path]
    if shared == nil then
        local root, id = queue("bytes", path)
        bytesInFlight[path] = root
        worker:send({id = id, kind = "bytes", path = path})
        shared = root
    end
    return awaitRoot(shared as Future<string>, "file load")
end

function assets.loadGLTF(path: string): Model
    content.note(path, "model")
    local root, id = queue("model", path)
    root._watchers = 1
    worker:send({id = id, kind = "model", path = path})
    return awaitRoot(root as Future<Model>, "model load")
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
    if not sdl3mixer.init() then
        error("tecs: cannot load " .. path, 2)
    end
    local root, id = queue("sound", path)
    -- The one caller is the watcher `Future.pending` counts, so this root is
    -- handed out as it is: canceling it takes the count to zero and abandons
    -- the decode, which is what the only caller giving up should do.
    root._watchers = 1
    worker:send({
        id = id,
        kind = "sound",
        path = path,
        mode = mode,
        streamMs = streamMs,
    })
    return awaitRoot(root as Future<Sound>, "sound load")
end

-------------------------------------------------------------------------------
-- Draining
-------------------------------------------------------------------------------

--- Takes finished loads and resumes their waiting systems.
---
--- Polls without waiting and drains everything the worker has answered.
--- `tecs.runtime.poll` calls this automatically. Game systems and plugins must
--- not call it; a specialized host that drives no application calls the
--- process runtime instead.
---
--- @return How many loads settled this call, which is zero when nothing has
---     finished and also zero when no worker exists.
function assets.update(): integer
    return pump:poll()
end

runtimePoll = assets.update

--- Returns the number of loads still waiting on the worker.
---
--- @return Every load in flight in this process, not one caller's. A load every
---     caller has canceled is still counted until the worker answers for it, because
---     the address it sends still has to be taken and destroyed.
function assets.pending(): integer
    return pendingCount
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
    if pendingCount == 0 then
        return
    end
    if idle == nil then
        idle = Future.pending(source) as Future<integer>
    end
    idle:wait(timeoutMs)
end

--- Stops the loading worker.
---
--- Blocks until the thread exits. This call cancels loads still in flight, so
--- drain with `waitAll` first when their results matter.
--- Releasing an [`Image`](tealdoc:tecs.assets.Image) or a
--- [`Sound`](tealdoc:tecs.assets.Sound) that already settled still works afterwards; this
--- frees nothing.
function assets.shutdown()
    if worker == nil then
        return
    end
    worker:stop()
    worker = nil
    runtime.unregister("assets")
    pending = {}
    byFuture = {}
    imagesInFlight = {}
    bytesInFlight = {}
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
