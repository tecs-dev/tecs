--[=[
Owns the complete 2D sprite rendering lane.

The domain joins world extraction to sprite GPU resources, but it does not own
the frame graph, presentation, capture, or staging-slot rotation. `Renderer`
owns those cross-domain concerns and calls this domain explicitly, so adding a
mesh domain later adds another cold orchestration call rather than a domain
branch inside sprite extraction, culling, or drawing.
]=]

local type types = require("tecs.types")
local loader <const> = require("tecs.ffi.loader")
local Buffer <const> = require("tecs.gpu.Buffer")
local Frame <const> = require("tecs.gpu.Frame")
local Deferred <const> = require("tecs.gpu.Deferred")
local TextureArray <const> = require("tecs.gpu.TextureArray")
local Camera2D <const> = require("tecs.gfx.Camera2D")
local SpriteExtractor <const> = require("tecs.internal.render.SpriteExtractor")
local SpriteBackend <const> = require("tecs.internal.render.SpriteBackend")
local SpriteFramePacket <const> = require("tecs.internal.render.SpriteFramePacket")
local assets <const> = require("tecs.assets")
local components <const> = require("tecs.components")

local type InstanceProducer = SpriteExtractor.InstanceProducer
local type ClipRegion = SpriteBackend.ClipRegion
local type ComputeStage = SpriteBackend.ComputeStage

local DEFAULT_CAPACITY <const> = 65536

local record SpriteDomainOptions
    --- Caller-writable. Sets the maximum resident sprite-instance count.
    --- Rows beyond this fixed ceiling are dropped instead of growing a buffer
    --- under a frame that may still read it.
    capacity: integer
    --- Caller-writable. Sets the image-array cell size in pixels.
    cell: integer
    --- Caller-writable. Sets the image-array layer count.
    layers: integer
    --- Caller-writable. Gives archetype runs room to grow without moving every
    --- later run. Defaults to false, which packs runs end to end.
    reserveRuns: boolean
    --- Caller-writable. Rewrites only structurally changed rows instead of a
    --- whole archetype run. Defaults to false.
    partialRewrites: boolean
    --- Caller-writable. Packs many images into each array layer. Defaults to
    --- false, which gives each image its own layer.
    packImages: boolean
end

local record SpriteDomain
    type Options = SpriteDomainOptions
    type InstanceProducer = InstanceProducer
    type ClipRegion = ClipRegion
    type ComputeStage = ComputeStage

    --- Caller-writable. Controls the 2D view. The first drawable frame centers
    --- it on the viewport.
    camera: Camera2D
    --- Read-only. Reports the instance capacity fixed at creation.
    capacity: integer
    --- Read-only. Reports the instances resident after the last extraction.
    count: integer
    --- Read-only. Reports the instances the last extraction could not fit.
    dropped: integer
    --- Read-only. Reports the instances rewritten by the last extraction.
    rewritten: integer
    --- Read-only. Provides the sprite image array.
    images: TextureArray
    --- Engine-owned. Exposes sprite instances to custom compute stages.
    --- Ordinary game code should ignore it.
    instances: Buffer

    _extractor: SpriteExtractor
    _backend: SpriteBackend
    _packet: SpriteFramePacket
    _centered: boolean
end

local SpriteDomainMT <const>: metatable<SpriteDomain> = {__index = SpriteDomain}

--- Creates the sprite lane against a renderer-owned deferred pipeline.
function SpriteDomain._create(device: loader.CPtr, deferred: Deferred, options: SpriteDomainOptions): SpriteDomain
    options = options or {}
    local self = setmetatable({} as SpriteDomain, SpriteDomainMT)
    self.capacity = options.capacity or DEFAULT_CAPACITY
    self.count = 0
    self.dropped = 0
    self.rewritten = 0
    self._centered = false
    self._packet = SpriteFramePacket.create()

    local backend = SpriteBackend.create(
        device,
        deferred,
        {
            capacity = self.capacity,
            cell = options.cell,
            layers = options.layers,
            packImages = options.packImages,
        }
    )
    self._backend = backend
    self.images = backend.images
    self.instances = backend.instances

    local extractor = SpriteExtractor.create({
        capacity = self.capacity,
        reserveRuns = options.reserveRuns,
        partialRewrites = options.partialRewrites,
        whiteU0 = backend.whiteU0,
        whiteV0 = backend.whiteV0,
        whiteU1 = backend.whiteU1,
        whiteV1 = backend.whiteV1,
    })
    self._extractor = extractor
    self.camera = extractor.camera
    return self
end

--- Registers sprite extraction on a world.
function SpriteDomain:_install(world: types.World)
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

--- Points the next extraction at one renderer-selected staging slot.
function SpriteDomain:_setStaging(slot: integer)
    self._extractor:setStaging(slot, self._backend:mapSlot(slot))
end

--- Centers the default 2D camera once the first drawable frame has a size.
function SpriteDomain:_center(frame: Frame)
    local packet <const> = self._packet
    if self._centered or packet.count == 0 then
        return
    end
    self._centered = true
    self.camera.x = frame.width * 0.5
    self.camera.y = frame.height * 0.5
    packet:setCamera(self.camera)
end

--- Uploads and culls the last extracted sprite packet.
function SpriteDomain:_prepare(frame: Frame)
    self._backend:prepare(self._packet, frame)
end

function SpriteDomain:_recordOccluders(context: Deferred.PassContext)
    self._backend:recordOccluders(context)
end

function SpriteDomain:_recordDropShadows(context: Deferred.PassContext)
    self._backend:recordDropShadows(context)
end

function SpriteDomain:_recordGeometry(context: Deferred.PassContext)
    self._backend:recordGeometry(context)
end

function SpriteDomain:_recordForward(context: Deferred.PassContext)
    self._backend:recordForward(context)
end

--- Returns whether the current packet can contribute to the shadow lane.
function SpriteDomain:_castsThisFrame(): boolean
    return self._backend:castsThisFrame()
end

--- Uploads a decoded image and returns a sprite selecting the whole image.
---
--- The path identifies the image for this domain's lifetime. Re-registering
--- it returns the existing region. The call releases valid decoded pixels.
--- @param decoded The caller supplies a ready image that still owns its pixels.
--- @return Returns a fresh sprite that selects the whole image.
--- @return Returns the domain-owned live region that contains the image.
function SpriteDomain:registerImage(decoded: assets.Image): components.Sprite, TextureArray.Region
    if decoded.pixels == nil then
        error(("tecs: the pixels of '%s' have been released"):format(decoded.path), 2)
    end
    local image = components.imageId(decoded.path)
    local region = self._extractor:regionOf(image)
    if region == nil then
        region = self._backend:addImage(decoded.pixels, decoded.width, decoded.height, decoded.pitch)
        self._extractor:registerImage(image, region)
    end
    decoded:release()
    return components.Sprite(image, region.u0, region.v0, region.u1, region.v1, region.layer), region
end

--- Uploads a decoded image over the one registered under its path.
---
--- The replacement keeps the registered layer and rectangle, so existing
--- sprites keep their identity. Missing pixels, an unknown path, or a size
--- change raises. The call releases valid decoded pixels.
--- @param decoded The caller supplies an image matching a registered path and size.
--- @return Returns a fresh sprite selecting the unchanged region.
--- @return Returns the domain-owned live region.
function SpriteDomain:replaceImage(decoded: assets.Image): components.Sprite, TextureArray.Region
    if decoded.pixels == nil then
        error(("tecs: the pixels of '%s' have been released"):format(decoded.path), 2)
    end
    local image = components.imageId(decoded.path)
    local region = self._extractor:regionOf(image)
    if region == nil then
        error(("tecs: no image is registered as '%s', so there is nothing to replace"):format(decoded.path), 2)
    end
    if decoded.width ~= region.width or decoded.height ~= region.height then
        error(
            ("tecs: '%s' was registered at %dx%d and is now %dx%d; a replacement keeps the size"):format(
                decoded.path, region.width, region.height, decoded.width, decoded.height
            ),
            2
        )
    end
    self._backend:replaceImage(region, decoded.pixels, decoded.width, decoded.height, decoded.pitch)
    decoded:release()
    return components.Sprite(image, region.u0, region.v0, region.u1, region.v1, region.layer), region
end

--- Returns the region occupied by a registered image.
--- @param path The caller supplies the path used during registration.
--- @return Returns the domain-owned live region, or nil when none matches.
function SpriteDomain:regionOf(path: string): TextureArray.Region
    return self._extractor:regionOf(components.imageId(path))
end

--- Returns whether archetype runs have room to grow.
--- @return Returns the fixed creation setting.
function SpriteDomain:reservesRuns(): boolean
    return self._extractor:reservesRuns()
end

--- Returns a sprite for a registered image.
---
--- UVs are fractions of the image. Omitted values select the whole image. An
--- unknown name raises.
--- @param name The caller supplies the registered image path.
--- @param u0 The caller supplies the left fraction or omits it for zero.
--- @param v0 The caller supplies the top fraction or omits it for zero.
--- @param u1 The caller supplies the right fraction or omits it for one.
--- @param v1 The caller supplies the bottom fraction or omits it for one.
--- @return Returns a fresh sprite mapped into the image-array region.
function SpriteDomain:sprite(name: string, u0?: number, v0?: number, u1?: number, v1?: number): components.Sprite
    return self._extractor:sprite(name, u0, v0, u1, v1)
end

--- Returns a sprite's natural size in source-image pixels.
--- @param sprite The caller supplies a sprite registered on this domain.
--- @return Returns its width, or zero when the image is unresolved.
--- @return Returns its height, or zero when the image is unresolved.
function SpriteDomain:spriteSize(sprite: components.Sprite): number, number
    if sprite == nil or sprite.image == 0 then
        return 0, 0
    end
    local region = self._extractor:regionOf(sprite.image as integer)
    if region == nil then
        return 0, 0
    end
    if sprite.u0 < 0 then
        return region.width, region.height
    end
    local spanU = region.u1 - region.u0
    local spanV = region.v1 - region.v0
    if spanU == 0 or spanV == 0 then
        return 0, 0
    end
    return math.abs((sprite.u1 - sprite.u0) / spanU) * region.width,
        math.abs((sprite.v1 - sprite.v0) / spanV) * region.height
end

--- Assigns a clipping rectangle in target pixels.
--- @param index The caller supplies an integer from 1 through 255.
--- @param region The caller supplies the target-pixel rectangle.
function SpriteDomain:setClipRegion(index: integer, region: ClipRegion)
    self._backend:setClipRegion(index, region)
end

--- Stops one clip-region index from clipping.
--- @param index The caller supplies an integer from 1 through 255.
function SpriteDomain:clearClipRegion(index: integer)
    self._backend:clearClipRegion(index)
end

--- Adds a retained instance producer after archetype instances.
--- @param producer The caller supplies a producer destroyed with the domain.
function SpriteDomain:addProducer(producer: InstanceProducer)
    self._extractor:addProducer(producer)
end

--- Adds a compute stage between staging flush and sprite culling.
--- @param stage The caller supplies a stage retained and destroyed by the domain.
function SpriteDomain:addComputeStage(stage: ComputeStage)
    self._backend:addComputeStage(stage)
end

function SpriteDomain:_rebuildPipelines()
    self._backend:rebuildPipelines()
end

function SpriteDomain:_device(): loader.CPtr
    return self._backend:device()
end

function SpriteDomain:_extractSeconds(): number
    return self._extractor:extractSeconds()
end

function SpriteDomain:_destroy()
    self._extractor:destroy()
    self._backend:destroy()
end

return SpriteDomain
