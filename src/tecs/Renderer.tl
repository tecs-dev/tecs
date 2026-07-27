--- Feeds the deferred pipeline from a world.
---
--- Two halves and the seam between them. `Extractor` is world-facing: queries,
--- archetype runs, relayout detection, dirty gating, producers and the
--- interpolation alpha, writing instances straight into mapped staging.
--- `Backend` is device-facing: the buffers, the flush, the cull, the deferred
--- pass graph and the image array. A `FramePacket` is everything that crosses,
--- and neither half holds a reference to the other.
---
--- The line is where the thread boundary falls. The extractor runs inside
--- `world:update`, in RenderFirst, and the backend runs afterwards against a
--- frame, so the extraction needs no command buffer and the render needs no
--- world. This object is what still sees both: it owns the packet, rotates the
--- staging slot, and hands the backend's mapped addresses to the extractor.
---
--- What a game holds is this. `renderer.camera` is the extractor's camera and
--- `renderer.images` is the backend's array, named here so neither half has to
--- be reached for by name.

local ecs <const> = require("tecs.ecs")
local loader <const> = require("tecs.ffi.loader")
local Buffer <const> = require("tecs.gpu.Buffer")
local Frame <const> = require("tecs.gpu.Frame")
local Texture <const> = require("tecs.gpu.Texture")
local TextureArray <const> = require("tecs.gpu.TextureArray")
local Deferred <const> = require("tecs.gpu.Deferred")
local Camera <const> = require("tecs.gfx.Camera")
local Extractor <const> = require("tecs.Extractor")
local Backend <const> = require("tecs.Backend")
local FramePacket <const> = require("tecs.FramePacket")
local assets <const> = require("tecs.assets")
local components <const> = require("tecs.components")

local type InstanceProducer = Extractor.InstanceProducer
local type ClipRegion = Backend.ClipRegion

--- Instances the buffers are sized for. This is a ceiling, not a hint: rows
--- beyond it are dropped rather than growing the buffer mid-frame.
local DEFAULT_CAPACITY <const> = 65536

local record RendererOptions
    --- Ambient colour applied everywhere.
    ambient: {number}
    --- Instances the buffer is sized for.
    capacity: integer
    --- Cell size of the image array.
    cell: integer
    --- Layers the image array holds.
    layers: integer
end

local record Renderer
    type InstanceProducer = InstanceProducer
    type ClipRegion = ClipRegion

    --- What the view is looking at. Centred on the viewport the first time a
    --- frame is drawn, so a scene that never mentions a camera sees world
    --- coordinates as screen coordinates.
    camera: Camera
    capacity: integer
    --- Instances the last sync left resident.
    count: integer
    --- Instances the last sync could not fit.
    dropped: integer
    --- Instances the last sync actually rewrote. Zero on a still frame.
    rewritten: integer
    --- Every image, one binding, so the scene is one draw.
    images: TextureArray
    --- The instance buffer the scene is drawn from, and the staging behind it.
    instances: Buffer
    --- The pipeline the packet is drawn through, so a caller can add targets
    --- and passes around the three it already has.
    deferred: Deferred

    _extractor: Extractor
    _backend: Backend
    _packet: FramePacket
    --- Staging slot the next extraction writes into, rotated after each
    --- submission.
    ---
    --- Rotating is what lets the mapping skip cycling. Cycling exists so a
    --- write cannot land in memory the GPU is still copying out of, and it pays
    --- for that with a fresh driver allocation every frame. Writing to a slot
    --- the GPU is not reading gives the same guarantee and allocates nothing.
    _slot: integer
    _centred: boolean
end

local RendererMT <const>: metatable<Renderer> = { __index = Renderer }

--- Builds a renderer for `device`.
function Renderer.create(device: loader.CPtr, swapchainFormat: integer,
                         options: RendererOptions): Renderer
    options = options or {}

    local self = setmetatable({} as Renderer, RendererMT)
    self.capacity = options.capacity or DEFAULT_CAPACITY
    self.count = 0
    self.dropped = 0
    self.rewritten = 0
    self._centred = false
    self._slot = 0
    self._packet = FramePacket.create()

    local backend = Backend.create(device, swapchainFormat, {
        ambient = options.ambient,
        capacity = self.capacity,
        cell = options.cell,
        layers = options.layers,
    })
    self._backend = backend
    self.images = backend.images
    self.instances = backend.instances
    self.deferred = backend.deferred

    -- The white pixel's extent is the backend's answer, decided by uploading
    -- it, and the extractor needs it for every row that carries no Sprite. It
    -- crosses once, at construction, rather than being asked for per frame.
    local extractor = Extractor.create({
        capacity = self.capacity,
        whiteU1 = backend.whiteU1,
        whiteV1 = backend.whiteV1,
    })
    self._extractor = extractor
    self.camera = extractor.camera
    extractor:setStaging(self._slot, backend:mapSlot(self._slot))

    return self
end

--- Registers the sync system and queries on `world`.
function Renderer:install(world: ecs.World)
    self._extractor:install(world, self._packet, function()
        local packet = self._packet
        self.count = packet.count
        self.dropped = packet.dropped
        self.rewritten = packet.rewritten
    end)
end

--- Uploads a decoded image into the array and returns a Sprite for it.
---
--- The image is registered under its path, which is what a Sprite names it by
--- and what a snapshot stores. Registering a path a second time answers with
--- the layer it already holds instead of consuming another, so a name means
--- one image for the life of the renderer however many times it is asked for.
---
--- A Sprite is returned rather than a bare region because an image smaller
--- than a cell does not reach the cell's edge, so the UV range is not 0..1 and
--- a caller guessing it would sample the undefined remainder. The second
--- return is the region, which reports the size that was uploaded.
---
--- The handle's pixels are released here: the array holds them now.
function Renderer:registerImage(handle: assets.Handle): components.Sprite, TextureArray.Region
    if handle.status ~= "ready" then
        error(("tecs: image '%s' is %s"):format(handle.path, handle.status), 2)
    end

    local image = components.imageId(handle.path)
    local region = self._extractor:regionOf(image)
    if region == nil then
        region = self._backend:addImage(handle.pixels, handle.width,
            handle.height, handle.pitch)
        self._extractor:registerImage(image, region)
    end
    handle:release()

    return components.Sprite(image, 0.0, 0.0, region.u1, region.v1,
        region.layer), region
end

--- A resolved Sprite for a registered image, ready to spawn.
---
--- UVs are fractions of the image rather than of the cell it sits in. Omitted,
--- they select the whole image. Fails on a name nothing is registered under.
function Renderer:sprite(name: string, u0?: number, v0?: number,
                         u1?: number, v1?: number): components.Sprite
    return self._extractor:sprite(name, u0, v0, u1, v1)
end

--- Points region `index` at a rectangle in target pixels.
---
--- Fragments of an instance carrying `Clip(index)` are kept where they land
--- inside the rectangle and thrown away where they do not. Region zero is not
--- a region and cannot be set: it is what an instance says when it wants no
--- clipping at all.
function Renderer:setClipRegion(index: integer, region: ClipRegion)
    self._backend:setClipRegion(index, region)
end

--- Stops region `index` clipping anything.
function Renderer:clearClipRegion(index: integer)
    self._backend:clearClipRegion(index)
end

--- Adds a producer, laid out after the archetypes in the order added.
function Renderer:addProducer(producer: InstanceProducer)
    self._extractor:addProducer(producer)
end

--- Seconds the last extraction took, or zero when nothing is being measured.
---
--- Read by the frame loop, which subtracts it from the update to leave
--- simulation on its own. Extraction runs inside `world:update`, so the two
--- are one number until something takes them apart.
function Renderer:extractSeconds(): number
    return self._extractor:extractSeconds()
end

--- Draws the packet the last extraction produced.
function Renderer:render(frame: Frame)
    local packet = self._packet

    -- The camera centres itself the first time there is something to draw, and
    -- the size to centre on is only known once there is a frame to draw into.
    -- Written to the camera the game holds, since that is where a game reads it
    -- back from, and copied into the packet this frame is drawn from.
    if not self._centred and packet.count > 0 then
        self._centred = true
        self.camera.x = frame.width * 0.5
        self.camera.y = frame.height * 0.5
        packet:setCamera(self.camera)
    end

    self._backend:consume(packet, frame)

    -- Rotated after the copies are encoded, so the next extraction writes a
    -- slot this frame is not still uploading from.
    local slot = (self._slot + 1) % Buffer.slotCount
    self._slot = slot
    self._extractor:setStaging(slot, self._backend:mapSlot(slot))
end

--- The composited image the last frame produced.
function Renderer:captureTexture(): Texture
    return self._backend:captureTexture()
end

--- Releases everything the renderer owns. Safe to call more than once.
function Renderer:destroy()
    self._backend:destroy()
end

return Renderer
