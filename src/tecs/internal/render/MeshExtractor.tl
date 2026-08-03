--[=[
Turns 3D scene columns into mesh-domain staging and a frame packet.

This extractor is intentionally independent of sprite layout and queries. It
writes a fixed mesh instance record and a world-space bounding sphere directly
into mapped staging. It rewrites the compact resident range each frame because
archetype iteration order can change after structural mutation. The frame
packet keeps this policy separate from device upload so a measured retained
strategy can replace it without changing the backend contract.

Optional skin and morph columns write compact locator records. A combined
domain appends the skin offset to each morph locator so its vertex shader stays
inside the backend's storage-buffer limit. A domain that omits either feature
never queries that component or owns its dedicated storage.
]=]

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local loader <const> = require("tecs.ffi.loader")
local Camera3D <const> = require("tecs.gfx.Camera3D")
local MeshFramePacket <const> = require("tecs.internal.render.MeshFramePacket")
local components <const> = require("tecs.components")
local timing <const> = require("tecs.timing")
local renderprofile <const> = require("tecs.internal.render.renderprofile")
local meshlayout <const> = require("tecs.gpu.meshlayout")
local meshlightlayout <const> = require("tecs.gpu.meshlightlayout")
local meshlocalshadowlayout <const> = require("tecs.gpu.meshlocalshadowlayout")
local meshconstants <const> = require("tecs.internal.render.meshconstants")
local bit <const> = require("bit")

local Transform3D <const> = ecs.Transform3D
local ALPHA_OPAQUE <const> = meshconstants.ALPHA_OPAQUE
local ALPHA_BLEND <const> = meshconstants.ALPHA_BLEND

local abs <const> = math.abs
local max <const> = math.max

local record MeshExtractorOptions
    capacity: integer
    transparency: boolean
    doubleSided: boolean
    skinning: boolean
    morphing: boolean
    lightCapacity: integer
    shadowCapacity: integer
end

local record MeshDraw
    slot: integer
    firstVertex: integer
    firstIndex: integer
    indexCount: integer
    firstMorphVertex: integer
    vertexCount: integer
    morphTargetCount: integer
end

local record MorphRegion
    firstWeight: integer
    weightCount: integer
end

local record MeshExtractor
    type Options = MeshExtractorOptions

    camera: Camera3D
    capacity: integer

    _world: types.World
    _renderables: types.Query
    _instances: loader.CArray
    _bounds: loader.CArray
    _commands: loader.CArray
    _skins: loader.CArray
    _morphs: loader.CArray
    _slot: integer
    _drawByAsset: {integer: MeshDraw}
    _materialSlotByAsset: {integer: integer}
    _alphaModeBySlot: {integer: integer}
    _doubleSidedBySlot: {integer: boolean}
    _transparency: boolean
    _doubleSided: boolean
    _skinning: boolean
    _morphing: boolean
    _lightCapacity: integer
    _shadowCapacity: integer
    _pointLights: types.Query
    _spotLights: types.Query
    _skinSlotByAsset: {integer: integer}
    _morphByAsset: {integer: MorphRegion}
    _extractSeconds: number
end

local MeshExtractorMT <const>: metatable<MeshExtractor> = {__index = MeshExtractor}

function MeshExtractor.create(options: MeshExtractorOptions): MeshExtractor
    local self = setmetatable({} as MeshExtractor, MeshExtractorMT)
    self.camera = Camera3D.newCamera3D()
    self.capacity = options.capacity
    self._slot = 0
    self._drawByAsset = {}
    self._materialSlotByAsset = {}
    self._alphaModeBySlot = {[0] = ALPHA_OPAQUE}
    self._doubleSidedBySlot = {[0] = false}
    self._transparency = options.transparency
    self._doubleSided = options.doubleSided
    self._skinning = options.skinning
    self._morphing = options.morphing
    self._lightCapacity = options.lightCapacity or 0
    self._shadowCapacity = options.shadowCapacity or 0
    self._skinSlotByAsset = {}
    self._morphByAsset = {}
    self._extractSeconds = 0.0
    return self
end

local function validLight(radius: number, r: number, g: number, b: number, intensity: number)
    if radius <= 0.0 then
        error("tecs: a 3D light radius must be greater than 0", 2)
    end
    if r < 0.0 or g < 0.0 or b < 0.0 or intensity < 0.0 then
        error("tecs: 3D light colors and intensity must be non-negative", 2)
    end
end

local function packLight(
    packet: MeshFramePacket,
    transform: ecs.Transform3D,
    radius: number,
    r: number,
    g: number,
    b: number,
    intensity: number,
    directionX: number,
    directionY: number,
    directionZ: number,
    outerCosine: number,
    innerCosine: number,
    kind: integer,
    shadowSlot: integer
)
    local count <const> = packet.lightCount
    local lights <const> = packet.lights
    local base <const> = count * meshlightlayout.FLOATS
    lights[base], lights[base + 1], lights[base + 2], lights[base + 3] = transform.x, transform.y, transform.z, radius
    lights[base + 4], lights[base + 5], lights[base + 6], lights[base + 7] = r, g, b, intensity
    lights[base + 8], lights[base + 9], lights[base + 10], lights[base + 11] = directionX,
        directionY,
        directionZ,
        outerCosine
    lights[base + 12], lights[base + 13], lights[base + 14], lights[base + 15] = innerCosine, kind, shadowSlot, 0.0
    packet.lightCount = count + 1
end

local function selectShadow(
    self: MeshExtractor,
    packet: MeshFramePacket,
    transform: ecs.Transform3D,
    radius: number,
    kind: integer,
    outerAngle: number
): integer
    local slot <const> = packet.shadowLightCount
    if slot >= self._shadowCapacity then
        return 0
    end
    local values <const> = packet.shadowLights
    local base <const> = slot * meshlocalshadowlayout.LIGHT_FLOATS
    values[base], values[base + 1], values[base + 2], values[base + 3] = transform.x, transform.y, transform.z, radius
    values[base + 4], values[base + 5], values[base + 6], values[base + 7] = transform.rotationX,
        transform.rotationY,
        transform.rotationZ,
        transform.rotationW
    values[base + 8], values[base + 9], values[base + 10], values[base + 11] = kind, outerAngle, 0.0, 0.0
    packet.shadowLightCount = slot + 1
    return slot + 1
end

local function syncLights(self: MeshExtractor, packet: MeshFramePacket)
    if self._lightCapacity == 0 then
        return
    end
    for archetype, length in self._pointLights:iter() do
        local transforms <const> = archetype:get(Transform3D)
        local sources <const> = archetype:get(components.PointLight3D)
        local stop = self._lightCapacity - packet.lightCount
        if stop > length then
            stop = length
        end
        for row = 1, stop do
            local source <const> = sources[row]
            local transform <const> = transforms[row]
            validLight(source.radius, source.r, source.g, source.b, source.intensity)
            local shadowSlot = 0
            if bit.band(source.flags as integer, components.LIGHT_CASTS_SHADOWS) ~= 0 then
                shadowSlot = selectShadow(self, packet, transform, source.radius, 0, 0.0)
            end
            packLight(
                packet,
                transform,
                source.radius,
                source.r,
                source.g,
                source.b,
                source.intensity,
                0.0,
                0.0,
                0.0,
                -2.0,
                1.0,
                0,
                shadowSlot
            )
        end
    end
    for archetype, length in self._spotLights:iter() do
        local transforms <const> = archetype:get(Transform3D)
        local sources <const> = archetype:get(components.SpotLight3D)
        local stop = self._lightCapacity - packet.lightCount
        if stop > length then
            stop = length
        end
        for row = 1, stop do
            local transform <const> = transforms[row]
            local source <const> = sources[row]
            validLight(source.radius, source.r, source.g, source.b, source.intensity)
            if
                source.innerAngle < 0.0
                or source.outerAngle <= 0.0
                or source.innerAngle > source.outerAngle
                or source.outerAngle >= math.pi * 0.5
            then
                error("tecs: a 3D spot light requires 0 <= innerAngle <= outerAngle < pi / 2", 2)
            end
            local qx, qy, qz, qw = transform.rotationX, transform.rotationY, transform.rotationZ, transform.rotationW
            local lengthSquared <const> = qx * qx + qy * qy + qz * qz + qw * qw
            if lengthSquared <= 0.0 then
                error("tecs: a 3D spot light transform requires a non-zero rotation quaternion", 2)
            end
            local inverse <const> = 1.0 / lengthSquared
            local directionX <const> = -2.0 * (qx * qz + qw * qy) * inverse
            local directionY <const> = 2.0 * (qw * qx - qy * qz) * inverse
            local directionZ <const> = (2.0 * (qx * qx + qy * qy) - lengthSquared) * inverse
            local shadowSlot = 0
            if bit.band(source.flags as integer, components.LIGHT_CASTS_SHADOWS) ~= 0 then
                shadowSlot = selectShadow(self, packet, transform, source.radius, 1, source.outerAngle)
            end
            packLight(
                packet,
                transform,
                source.radius,
                source.r,
                source.g,
                source.b,
                source.intensity,
                directionX,
                directionY,
                directionZ,
                math.cos(source.outerAngle),
                math.cos(source.innerAngle),
                1,
                shadowSlot
            )
        end
    end
end

function MeshExtractor:registerMaterial(asset: integer, slot: integer, alphaMode: integer, doubleSided?: boolean)
    self._materialSlotByAsset[asset] = slot
    self._alphaModeBySlot[slot] = alphaMode
    self._doubleSidedBySlot[slot] = doubleSided
end

function MeshExtractor:setStaging(
    slot: integer,
    instances: loader.CArray,
    bounds: loader.CArray,
    commands: loader.CArray,
    skins?: loader.CArray,
    morphs?: loader.CArray
)
    self._slot = slot
    self._instances = instances
    self._bounds = bounds
    self._commands = commands
    self._skins = skins
    self._morphs = morphs
end

function MeshExtractor:registerSkin(asset: integer, slot: integer)
    self._skinSlotByAsset[asset] = slot
end

function MeshExtractor:registerMorph(asset: integer, firstWeight: integer, weightCount: integer)
    self._morphByAsset[asset] = {firstWeight = firstWeight, weightCount = weightCount}
end

function MeshExtractor:registerMesh(
    asset: integer,
    slot: integer,
    firstVertex: integer,
    firstIndex: integer,
    indexCount: integer,
    firstMorphVertex?: integer,
    vertexCount?: integer,
    morphTargetCount?: integer
)
    self._drawByAsset[asset] = {
        slot = slot,
        firstVertex = firstVertex,
        firstIndex = firstIndex,
        indexCount = indexCount,
        firstMorphVertex = firstMorphVertex or 0,
        vertexCount = vertexCount or 0,
        morphTargetCount = morphTargetCount or 0,
    }
end

local function missingMeshMessage(asset: integer): string
    local name <const> = components.meshName(asset)
    if name == nil then
        return "tecs: a Mesh names no asset; build one with renderer.meshes:registerMesh"
    end
    return ("tecs: no mesh is registered as '%s'"):format(name)
end

function MeshExtractor:extract(packet: MeshFramePacket)
    local started <const> = timing.begin()
    packet:begin(self._slot)

    local instances <const> = self._instances
    local spheres <const> = self._bounds
    local commands <const> = self._commands
    local instanceSkins <const> = self._skins
    local instanceMorphs <const> = self._morphs
    local written = 0
    local dropped = 0
    local missing = 0
    local blended = 0
    local doubleSided = 0

    for archetype, length in self._renderables:iter() do
        local transforms <const> = archetype:get(Transform3D)
        local meshes <const> = archetype:get(components.Mesh)
        local bounds <const> = archetype:get(components.Bounds3D)
        local materials <const> = archetype:get(components.MeshMaterial)
        local tints <const> = archetype:get(components.Tint)
        local skins = self._skinning and archetype:get(components.MeshSkin) or nil
        local morphs = self._morphing and archetype:get(components.MeshMorph) or nil
        local resolved = false
        local skinResolved = false
        local morphResolved = false

        for row = 1, length do
            if written >= self.capacity then
                dropped = dropped + 1
            else
                local mesh = meshes[row]
                local meshSlot = mesh.slot as integer
                local draw = self._drawByAsset[mesh.asset as integer]
                if draw == nil then
                    if missing == 0 then
                        missing = mesh.asset as integer
                    end
                elseif meshSlot < 0 then
                    meshSlot = draw.slot
                    mesh.slot = meshSlot
                    resolved = true
                end

                if draw ~= nil and meshSlot >= 0 then
                    local transform = transforms[row]
                    local material = materials[row]
                    local materialSlot = material.slot as integer
                    if materialSlot < 0 then
                        materialSlot = self._materialSlotByAsset[material.asset as integer]
                        if materialSlot == nil then
                            error(
                                ("tecs: no mesh material is registered as '%s'"):format(
                                    components.meshMaterialName(material.asset as integer)
                                ),
                                2
                            )
                        end
                        material.slot = materialSlot
                        resolved = true
                    end
                    local tint = tints[row]
                    local base <const> = written * meshlayout.INSTANCE_FLOATS
                    instances[base] = transform.x
                    instances[base + 1] = transform.y
                    instances[base + 2] = transform.z
                    instances[base + 3] = transform.rotationX
                    instances[base + 4] = transform.rotationY
                    instances[base + 5] = transform.rotationZ
                    instances[base + 6] = transform.rotationW
                    instances[base + 7] = transform.scaleX
                    instances[base + 8] = transform.scaleY
                    instances[base + 9] = transform.scaleZ
                    instances[base + 10] = meshSlot
                    instances[base + 11] = materialSlot
                    local alphaMode <const> = self._transparency and self._alphaModeBySlot[materialSlot] or ALPHA_OPAQUE
                    local bothFaces <const> = self._doubleSided and self._doubleSidedBySlot[materialSlot] == true
                    instances[base + 12] = alphaMode + (bothFaces and 4 or 0)
                    if alphaMode == ALPHA_BLEND then
                        blended = blended + 1
                    elseif bothFaces then
                        doubleSided = doubleSided + 1
                    end
                    instances[base + 13] = tint.r
                    instances[base + 14] = tint.g
                    instances[base + 15] = tint.b
                    local skinSlot = -1
                    if self._skinning then
                        if skins ~= nil then
                            local skin = skins[row]
                            skinSlot = skin.slot as integer
                            if skinSlot < 0 then
                                skinSlot = self._skinSlotByAsset[skin.asset as integer]
                                if skinSlot == nil then
                                    error(
                                        ("tecs: no mesh skin is registered as '%s'"):format(
                                            components.meshSkinName(skin.asset as integer)
                                        ),
                                        2
                                    )
                                end
                                skin.slot = skinSlot
                                skinResolved = true
                            end
                        end
                        if not self._morphing then
                            instanceSkins[written] = skinSlot
                        end
                    end
                    if self._morphing then
                        local morphBase <const> = written * (
                            self._skinning and meshlayout.DEFORM_INSTANCE_FLOATS or meshlayout.MORPH_INSTANCE_FLOATS
                        )
                        local firstWeight = -1
                        local weightCount = 0
                        if morphs ~= nil then
                            local morph = morphs[row]
                            firstWeight = morph.slot as integer
                            local region = self._morphByAsset[morph.asset as integer]
                            if firstWeight < 0 then
                                if region == nil then
                                    error(
                                        ("tecs: no mesh morph is registered as '%s'"):format(
                                            components.meshMorphName(morph.asset as integer)
                                        ),
                                        2
                                    )
                                end
                                firstWeight = region.firstWeight
                                morph.slot = firstWeight
                                morphResolved = true
                            end
                            if region == nil then
                                region = self._morphByAsset[morph.asset as integer]
                            end
                            weightCount = region ~= nil and region.weightCount or 0
                        end
                        if firstWeight >= 0 and weightCount ~= draw.morphTargetCount then
                            error(
                                ("tecs: mesh morph has %d weights, but geometry needs %d"):format(
                                    weightCount, draw.morphTargetCount
                                ),
                                2
                            )
                        end
                        instanceMorphs[morphBase] = firstWeight >= 0 and draw.firstMorphVertex or -1
                        instanceMorphs[morphBase + 1] = draw.firstVertex
                        instanceMorphs[morphBase + 2] = draw.vertexCount
                        instanceMorphs[morphBase + 3] = firstWeight
                        instanceMorphs[morphBase + 4] = firstWeight >= 0 and draw.morphTargetCount or 0
                        if self._skinning then
                            instanceMorphs[morphBase + 5] = skinSlot
                        end
                    end

                    local command = commands[written] as loader.CStruct
                    command.num_indices = draw.indexCount
                    command.num_instances = 1
                    command.first_index = draw.firstIndex
                    command.vertex_offset = draw.firstVertex
                    command.first_instance = written

                    local bound = bounds[row]
                    local boundBase <const> = written * meshlayout.BOUND_FLOATS
                    local centerX <const> = bound.centerX * transform.scaleX
                    local centerY <const> = bound.centerY * transform.scaleY
                    local centerZ <const> = bound.centerZ * transform.scaleZ
                    local twiceX <const> = 2.0 * (transform.rotationY * centerZ - transform.rotationZ * centerY)
                    local twiceY <const> = 2.0 * (transform.rotationZ * centerX - transform.rotationX * centerZ)
                    local twiceZ <const> = 2.0 * (transform.rotationX * centerY - transform.rotationY * centerX)
                    spheres[boundBase] = transform.x + centerX + transform.rotationW * twiceX + transform.rotationY * twiceZ - transform.rotationZ * twiceY
                    spheres[boundBase + 1] = transform.y + centerY + transform.rotationW * twiceY + transform.rotationZ * twiceX - transform.rotationX * twiceZ
                    spheres[boundBase + 2] = transform.z + centerZ + transform.rotationW * twiceZ + transform.rotationX * twiceY - transform.rotationY * twiceX
                    spheres[boundBase + 3] = bound.radius * max(
                        abs(transform.scaleX), max(abs(transform.scaleY), abs(transform.scaleZ))
                    )
                    written = written + 1
                end
            end
        end

        if resolved then
            -- The direct cdata writes above update engine-owned residency.
            -- Mark the column once after the walk so snapshots and any later
            -- dirty-gated consumer observe that write.
            archetype:getMut(components.Mesh)
        end
        if skinResolved then
            archetype:getMut(components.MeshSkin)
        end
        if morphResolved then
            archetype:getMut(components.MeshMorph)
        end
    end

    if written > 0 then
        packet.instanceRanges:mark(0, written * meshlayout.INSTANCE_BYTES)
        packet.boundsRanges:mark(0, written * meshlayout.BOUND_BYTES)
        packet.commandRanges:mark(0, written * meshlayout.COMMAND_BYTES)
        if self._skinning and not self._morphing then
            packet.skinRanges:mark(0, written * 4)
        end
        if self._morphing then
            packet.morphRanges:mark(
                0, written * (self._skinning and meshlayout.DEFORM_INSTANCE_BYTES or meshlayout.MORPH_INSTANCE_BYTES)
            )
        end
    end
    packet.count = written
    packet.dropped = dropped
    packet.rewritten = written
    packet.blendCount = blended
    packet.doubleSidedCount = doubleSided
    syncLights(self, packet)
    self._extractSeconds = timing.finish(renderprofile.meshes, started)

    if missing ~= 0 then
        error(missingMeshMessage(missing), 2)
    end
end

function MeshExtractor:install(world: types.World, packet: MeshFramePacket, published: function())
    self._world = world
    self._renderables = world:newQuery({
        include = {
            Transform3D,
            components.Mesh,
            components.Bounds3D,
            components.MeshMaterial,
            components.Tint,
            components.Renderable3D,
        },
    })
    if self._lightCapacity > 0 then
        self._pointLights = world:newQuery({include = {Transform3D, components.PointLight3D}})
        self._spotLights = world:newQuery({include = {Transform3D, components.SpotLight3D}})
    end
    world:addSystem({
        -- This system name is externally typed and stays stable if the module
        -- later moves.
        name = "tecs.SyncMeshRenderState",
        phase = ecs.phases.RenderFirst,
        run = function()
            self:extract(packet)
            if published ~= nil then
                published()
            end
        end,
    })
end

function MeshExtractor:extractSeconds(): number
    return self._extractSeconds
end

return MeshExtractor
