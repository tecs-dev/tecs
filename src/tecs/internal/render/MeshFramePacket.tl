--[=[
One frame's immutable 3D mesh metadata at the world-to-GPU boundary.

The mesh extractor writes instance and bounding-sphere bytes directly into
domain-owned mapped staging, then records only their ranges here. The mesh
backend consumes this packet without reaching back into a world.
The sprite packet and its image, light, and 2D camera state remain separate.

One packet is allocated per mesh domain and reused. `begin` clears range state,
`setCamera` copies the view, and extraction assigns the three instance counts
before handing the packet to the backend. Nothing here owns mesh geometry or
refers to a Lua entity.
]=]

local loader <const> = require("tecs.ffi.loader")
local dirtyranges <const> = require("tecs.gpu.dirtyranges")
local meshlightlayout <const> = require("tecs.gpu.meshlightlayout")

local type Camera3D = require("tecs.gfx.Camera3D")

local record MeshFramePacket
    --- Staging slot whose instance and bounds ranges this frame names.
    slot: integer
    --- Mesh instances resident after extraction.
    count: integer
    --- Mesh instances dropped because the domain capacity was full.
    dropped: integer
    --- Mesh instances whose staging bytes extraction rewrote this frame.
    rewritten: integer
    --- Resident instances whose materials require the optional forward lane.
    blendCount: integer
    --- Resident opaque or masked instances requiring the optional
    --- double-sided lane.
    doubleSidedCount: integer
    --- Optional packed point and spot lights. Nil when local mesh lighting was
    --- not enabled for the domain.
    lights: loader.CArray
    --- Packed 3D local lights written this frame.
    lightCount: integer

    --- World-space camera x copied during extraction.
    cameraX: number
    --- World-space camera y copied during extraction.
    cameraY: number
    --- World-space camera z copied during extraction.
    cameraZ: number
    --- Positive near-plane distance used to build `viewProjection`.
    near: number
    --- Far-plane distance used to build `viewProjection`.
    far: number
    --- Column-major world-to-clip matrix with depth in `[0, 1]`.
    viewProjection: loader.CArray
    --- Column-major clip-to-world inverse of `viewProjection`.
    inverseViewProjection: loader.CArray

    --- Dirty byte ranges in the mesh instance staging buffer.
    instanceRanges: dirtyranges
    --- Dirty byte ranges in the bounding-sphere staging buffer.
    boundsRanges: dirtyranges
    --- Dirty byte ranges in the indexed-command staging buffer.
    commandRanges: dirtyranges
    --- Dirty byte ranges in optional per-instance skin-palette offsets. Nil
    --- when skin offsets share combined morph metadata or skinning is absent.
    skinRanges: dirtyranges
    --- Dirty byte ranges in optional per-instance morph metadata. Nil when
    --- the domain did not enable morphing.
    morphRanges: dirtyranges

    --- Creates a reusable empty packet.
    --- @return A packet with allocated matrix and range storage.
    create: function(skinning?: boolean, morphing?: boolean, lightCapacity?: integer): MeshFramePacket

    --- Begins writing one frame through a staging slot.
    --- @param slot The zero-based staging slot selected by the renderer.
    begin: function(self, slot: integer)

    --- Copies a camera and its matrix into the packet.
    --- @param camera The camera read now and not retained.
    --- @param width The positive viewport width passed to the camera.
    --- @param height The positive viewport height passed to the camera.
    setCamera: function(self, camera: Camera3D, width: number, height: number)
end

local MeshFramePacketMT <const>: metatable<MeshFramePacket> = {__index = MeshFramePacket}

function MeshFramePacket.create(skinning?: boolean, morphing?: boolean, lightCapacity?: integer): MeshFramePacket
    local self = setmetatable({} as MeshFramePacket, MeshFramePacketMT)
    self.slot = 0
    self.count = 0
    self.dropped = 0
    self.rewritten = 0
    self.blendCount = 0
    self.doubleSidedCount = 0
    self.lightCount = 0
    if lightCapacity ~= nil then
        self.lights = loader.newArray("float[?]", lightCapacity * meshlightlayout.FLOATS)
    end
    self.cameraX = 0.0
    self.cameraY = 0.0
    self.cameraZ = 0.0
    self.near = 0.1
    self.far = 1000.0
    self.viewProjection = loader.newArray("float[16]")
    self.inverseViewProjection = loader.newArray("float[16]")
    self.instanceRanges = dirtyranges.create()
    self.boundsRanges = dirtyranges.create()
    self.commandRanges = dirtyranges.create()
    if skinning then
        self.skinRanges = dirtyranges.create()
    end
    if morphing then
        self.morphRanges = dirtyranges.create()
    end
    return self
end

function MeshFramePacket:begin(slot: integer)
    self.slot = slot
    self.lightCount = 0
    self.instanceRanges:clear()
    self.boundsRanges:clear()
    self.commandRanges:clear()
    if self.skinRanges ~= nil then
        self.skinRanges:clear()
    end
    if self.morphRanges ~= nil then
        self.morphRanges:clear()
    end
end

function MeshFramePacket:setCamera(camera: Camera3D, width: number, height: number)
    self.cameraX = camera.x
    self.cameraY = camera.y
    self.cameraZ = camera.z
    self.near = camera.near
    self.far = camera.far

    local source <const> = camera:matrix(width, height)
    local destination <const> = self.viewProjection
    local inverseSource <const> = camera:inverseMatrix(width, height)
    local inverseDestination <const> = self.inverseViewProjection
    for index = 0, 15 do
        destination[index] = source[index]
        inverseDestination[index] = inverseSource[index]
    end
end

return MeshFramePacket
