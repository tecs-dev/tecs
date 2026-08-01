--[=[
Turns 3D scene columns into mesh-domain staging and a frame packet.

This extractor is intentionally independent of sprite layout and queries. It
writes a fixed mesh instance record and a world-space bounding sphere directly
into mapped staging. The first version rewrites the resident mesh range each
frame, matching the headless contract benchmark; retained dirty-gated runs can
replace that policy without changing the packet or backend.
]=]

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local loader <const> = require("tecs.ffi.loader")
local Camera3D <const> = require("tecs.gfx.Camera3D")
local MeshFramePacket <const> = require("tecs.internal.render.MeshFramePacket")
local components <const> = require("tecs.components")
local timing <const> = require("tecs.timing")
local meshlayout <const> = require("tecs.gpu.meshlayout")

local EXTRACT <const> = timing.stage("extract")
local Transform3D <const> = ecs.Transform3D

local abs <const> = math.abs
local max <const> = math.max

local record MeshExtractorOptions
    capacity: integer
end

local record MeshDraw
    slot: integer
    firstVertex: integer
    firstIndex: integer
    indexCount: integer
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
    _slot: integer
    _drawByAsset: {integer: MeshDraw}
    _extractSeconds: number
end

local MeshExtractorMT <const>: metatable<MeshExtractor> = {__index = MeshExtractor}

function MeshExtractor.create(options: MeshExtractorOptions): MeshExtractor
    local self = setmetatable({} as MeshExtractor, MeshExtractorMT)
    self.camera = Camera3D.newCamera3D()
    self.capacity = options.capacity
    self._slot = 0
    self._drawByAsset = {}
    self._extractSeconds = 0.0
    return self
end

function MeshExtractor:setStaging(
    slot: integer, instances: loader.CArray, bounds: loader.CArray, commands: loader.CArray
)
    self._slot = slot
    self._instances = instances
    self._bounds = bounds
    self._commands = commands
end

function MeshExtractor:registerMesh(
    asset: integer, slot: integer, firstVertex: integer, firstIndex: integer, indexCount: integer
)
    self._drawByAsset[asset] = {
        slot = slot,
        firstVertex = firstVertex,
        firstIndex = firstIndex,
        indexCount = indexCount,
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
    local written = 0
    local dropped = 0
    local missing = 0

    for archetype, length in self._renderables:iter() do
        local transforms <const> = archetype:get(Transform3D)
        local meshes <const> = archetype:get(components.Mesh)
        local bounds <const> = archetype:get(components.Bounds3D)
        local materials <const> = archetype:get(components.Material)
        local tints <const> = archetype:get(components.Tint)
        local resolved = false

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
                    instances[base + 11] = material.id
                    instances[base + 12] = material.param
                    instances[base + 13] = tint.r
                    instances[base + 14] = tint.g
                    instances[base + 15] = tint.b

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
    end

    if written > 0 then
        packet.instanceRanges:mark(0, written * meshlayout.INSTANCE_BYTES)
        packet.boundsRanges:mark(0, written * meshlayout.BOUND_BYTES)
        packet.commandRanges:mark(0, written * meshlayout.COMMAND_BYTES)
    end
    packet.count = written
    packet.dropped = dropped
    packet.rewritten = written
    self._extractSeconds = timing.finish(EXTRACT, started)

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
            components.Material,
            components.Tint,
            components.Renderable3D,
        },
    })
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
