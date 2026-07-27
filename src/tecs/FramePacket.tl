--- One frame's worth of render data, as it crosses from the world to the GPU.
---
--- The extractor fills one and the backend consumes it. Neither reaches into
--- the other: everything the backend needs to record a frame is here, and
--- nothing here needs a world to read it.
---
--- What is deliberately *not* here is the instance and bounds bytes. Those are
--- already in the mapped staging the backend owns, written straight into it by
--- the extractor, and copying them into a packet would be the intermediate copy
--- the whole design exists to avoid. What crosses is where they went: the slot
--- that was written and the byte ranges within it.
---
--- Nothing here is heap-backed and nothing refers to a Lua object. The record
--- itself is a Lua table today and becomes a native slot struct when rendering
--- moves to its own state: the scalars become struct fields, the ranges and the
--- lights are already C storage, and the whole thing is then published by
--- flipping a slot's state rather than by handing over a reference.

local loader <const> = require("tecs.ffi.loader")
local dirtyranges <const> = require("tecs.gpu.dirtyranges")
local lightlayout <const> = require("tecs.gpu.lightlayout")

local type Camera = require("tecs.gfx.Camera")

local LIGHT_FLOATS <const> = lightlayout.FLOATS
local MAX_LIGHTS <const> = lightlayout.MAX

local record FramePacket
    --- Staging slot the instance and bounds bytes were written into. The
    --- backend flushes this slot and no other.
    slot: integer

    --- Instances resident after this frame's extraction, which is what the
    --- cull is dispatched over.
    count: integer
    --- Instances the extraction could not fit within the capacity.
    dropped: integer
    --- Instances the extraction actually rewrote. Zero on a still frame.
    rewritten: integer

    --- Where the view was when the frame was extracted, copied rather than
    --- referenced: the camera the game holds keeps moving, and a frame is
    --- drawn from where it was when it was built.
    ---
    --- The projection mode is not carried because there is one, and a second
    --- one arrives as an enum rather than as the string a camera names it by.
    cameraX: number
    cameraY: number
    cameraZoom: number
    cameraRotation: number

    --- Fixed steps the world had run when this frame was extracted.
    ---
    --- What GPU-side animation resolves a frame against. It crosses in the
    --- packet rather than being read where it is used, so every pass that draws
    --- one frame resolves against one number: a shadow reading a clock a
    --- moment later than the sprite that cast it is exactly the drift this
    --- avoids by construction.
    stepClock: number

    --- Lights, `lightlayout.FLOATS` each, in the order the lighting pass reads
    --- them.
    lights: loader.CArray
    lightCount: integer

    --- Bytes of the instance buffer this frame wrote, and of the bounds
    --- buffer. The backend records these against the staging slot and flushes
    --- it; nothing else decides what is copied.
    instanceRanges: dirtyranges
    boundsRanges: dirtyranges
end

local FramePacketMT <const>: metatable<FramePacket> = { __index = FramePacket }

--- Builds an empty packet, with its storage allocated once.
function FramePacket.create(): FramePacket
    local self = setmetatable({} as FramePacket, FramePacketMT)
    self.slot = 0
    self.count = 0
    self.dropped = 0
    self.rewritten = 0
    self.cameraX = 0.0
    self.cameraY = 0.0
    self.cameraZoom = 1.0
    self.cameraRotation = 0.0
    self.stepClock = 0.0
    self.lights = loader.newArray("float[?]", MAX_LIGHTS * LIGHT_FLOATS)
    self.lightCount = 0
    self.instanceRanges = dirtyranges.create()
    self.boundsRanges = dirtyranges.create()
    return self
end

--- Clears everything a frame reports, ready to be filled again.
---
--- The counts are not cleared: an extraction writes all three before it
--- returns, and a packet that reported zero drawn between being reset and
--- being filled would be a state no consumer should be able to observe.
function FramePacket:begin(slot: integer)
    self.slot = slot
    self.lightCount = 0
    self.instanceRanges:clear()
    self.boundsRanges:clear()
end

--- Copies a camera's state in. The camera itself never crosses.
function FramePacket:setCamera(camera: Camera)
    self.cameraX = camera.x
    self.cameraY = camera.y
    self.cameraZoom = camera.zoom
    self.cameraRotation = camera.rotation
end

--- Appends one light, dropping it if the frame is already full.
---
--- Positions are in the lighting target's pixels; see `Deferred.Light` for
--- what each value means.
function FramePacket:addLight(x: number, y: number, z: number, radius: number,
                              r: number, g: number, b: number,
                              intensity: number)
    local index = self.lightCount
    if index >= MAX_LIGHTS then return end
    self.lightCount = index + 1

    local base <const> = index * LIGHT_FLOATS
    local lights <const> = self.lights
    lights[base] = x
    lights[base + 1] = y
    lights[base + 2] = z
    lights[base + 3] = radius
    lights[base + 4] = r
    lights[base + 5] = g
    lights[base + 6] = b
    lights[base + 7] = intensity
end

return FramePacket
