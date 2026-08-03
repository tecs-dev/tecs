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
local domainmetrics <const> = require("tecs.internal.render.domainmetrics")
local type DomainStats = domainmetrics.Stats
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

local interface SpriteDomain is DomainStats
    --- Caller-writable. Controls the 2D view. The first drawable frame centers
    --- it on the viewport.
    camera: Camera2D
    --- Read-only. Reports the instance capacity fixed at creation.
    capacity: integer
    --- Read-only. Provides the sprite image array.
    images: TextureArray
    --- Engine-owned. Exposes sprite instances to custom compute stages.
    --- Ordinary game code should ignore it.
    instances: Buffer

    --- Uploads a decoded image and returns a sprite selecting the whole image.
    ---
    --- The path identifies the image for this domain's lifetime. Re-registering
    --- it returns the existing region. The call releases valid decoded pixels.
    --- @param decoded The caller supplies a ready image that still owns its pixels.
    --- @return Returns a fresh sprite that selects the whole image.
    --- @return Returns the domain-owned live region that contains the image.
    registerImage: function(self, decoded: assets.Image): components.Sprite, TextureArray.Region

    --- Uploads a decoded image over the one registered under its path.
    ---
    --- The replacement keeps the registered layer and rectangle, so existing
    --- sprites keep their identity. Missing pixels, an unknown path, or a size
    --- change raises. The call releases valid decoded pixels.
    --- @param decoded The caller supplies an image matching a registered path and size.
    --- @return Returns a fresh sprite selecting the unchanged region.
    --- @return Returns the domain-owned live region.
    replaceImage: function(self, decoded: assets.Image): components.Sprite, TextureArray.Region

    --- Returns the region occupied by a registered image.
    --- @param path The caller supplies the path used during registration.
    --- @return Returns the domain-owned live region, or nil when none matches.
    regionOf: function(self, path: string): TextureArray.Region

    --- Returns whether archetype runs have room to grow.
    --- @return Returns the fixed creation setting.
    reservesRuns: function(self): boolean

    --- Returns a sprite for a registered image.
    ---
    --- UVs are fractions of the image. Omitted values select the whole image.
    --- An unknown name raises.
    --- @param name The caller supplies the registered image path.
    --- @param u0 The caller supplies the left fraction or omits it for zero.
    --- @param v0 The caller supplies the top fraction or omits it for zero.
    --- @param u1 The caller supplies the right fraction or omits it for one.
    --- @param v1 The caller supplies the bottom fraction or omits it for one.
    --- @return Returns a fresh sprite mapped into the image-array region.
    sprite: function(self, name: string, u0?: number, v0?: number, u1?: number, v1?: number): components.Sprite

    --- Returns a sprite's natural size in source-image pixels.
    --- @param sprite The caller supplies a sprite registered on this domain.
    --- @return Returns its width, or zero when the image is unresolved.
    --- @return Returns its height, or zero when the image is unresolved.
    spriteSize: function(self, sprite: components.Sprite): number, number

    --- Assigns a clipping rectangle in target pixels.
    --- @param index The caller supplies an integer from 1 through 255.
    --- @param region The caller supplies the target-pixel rectangle.
    setClipRegion: function(self, index: integer, region: ClipRegion)

    --- Stops one clip-region index from clipping.
    --- @param index The caller supplies an integer from 1 through 255.
    clearClipRegion: function(self, index: integer)

    --- Adds a retained instance producer after archetype instances.
    --- @param producer The caller supplies a producer destroyed with the domain.
    addProducer: function(self, producer: InstanceProducer)

    --- Adds a compute stage between staging flush and sprite culling.
    --- @param stage The caller supplies a stage retained and destroyed by the domain.
    addComputeStage: function(self, stage: ComputeStage)
end

local interface SpriteDomainInternal is SpriteDomain
    _install: function(self, world: types.World)
    _setStaging: function(self, slot: integer)
    _center: function(self, frame: Frame)
    _prepare: function(self, frame: Frame, camera?: Camera2D, width?: number, height?: number, upload?: boolean)
    _recordOccluders: function(self, context: Deferred.PassContext)
    _recordDropShadows: function(self, context: Deferred.PassContext)
    _recordGeometry: function(self, context: Deferred.PassContext)
    _recordForward: function(self, context: Deferred.PassContext)
    _castsThisFrame: function(self): boolean
    _rebuildPipelines: function(self)
    _device: function(self): loader.CPtr
    _destroy: function(self)
end

local record SpriteDomainImpl is SpriteDomainInternal
    _extractor: SpriteExtractor
    _backend: SpriteBackend
    _packet: SpriteFramePacket
    _centered: boolean
end

local record SpriteDomainModule
    type Domain = SpriteDomain
    type Internal = SpriteDomainInternal
    type Options = SpriteDomainOptions
    type InstanceProducer = InstanceProducer
    type ClipRegion = ClipRegion
    type ComputeStage = ComputeStage

    _create: function(device: loader.CPtr, deferred: Deferred, options: SpriteDomainOptions): SpriteDomainInternal
end

local SpriteDomainMT <const>: metatable<SpriteDomainImpl> = {__index = SpriteDomainImpl}

--- Creates the sprite lane against a renderer-owned deferred pipeline.
function SpriteDomainModule._create(
    device: loader.CPtr, deferred: Deferred, options: SpriteDomainOptions
): SpriteDomainInternal
    options = options or {}
    local self = setmetatable({} as SpriteDomainImpl, SpriteDomainMT)
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
function SpriteDomainImpl:_install(world: types.World)
    self._extractor:install(
        world,
        self._packet,
        function() domainmetrics.publish(self, self._packet as domainmetrics.Frame) end
    )
end

--- Points the next extraction at one renderer-selected staging slot.
function SpriteDomainImpl:_setStaging(slot: integer)
    self._extractor:setStaging(slot, self._backend:mapSlot(slot))
end

--- Centers the default 2D camera once the first drawable frame has a size.
function SpriteDomainImpl:_center(frame: Frame)
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
function SpriteDomainImpl:_prepare(frame: Frame, camera?: Camera2D, width?: number, height?: number, upload?: boolean)
    self._backend:prepare(self._packet, frame, camera, width, height, upload)
end

function SpriteDomainImpl:_recordOccluders(context: Deferred.PassContext)
    self._backend:recordOccluders(context)
end

function SpriteDomainImpl:_recordDropShadows(context: Deferred.PassContext)
    self._backend:recordDropShadows(context)
end

function SpriteDomainImpl:_recordGeometry(context: Deferred.PassContext)
    self._backend:recordGeometry(context)
end

function SpriteDomainImpl:_recordForward(context: Deferred.PassContext)
    self._backend:recordForward(context)
end

--- Returns whether the current packet can contribute to the shadow lane.
function SpriteDomainImpl:_castsThisFrame(): boolean
    return self._backend:castsThisFrame()
end

function SpriteDomainImpl:registerImage(decoded: assets.Image): components.Sprite, TextureArray.Region
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

function SpriteDomainImpl:replaceImage(decoded: assets.Image): components.Sprite, TextureArray.Region
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

function SpriteDomainImpl:regionOf(path: string): TextureArray.Region
    return self._extractor:regionOf(components.imageId(path))
end

function SpriteDomainImpl:reservesRuns(): boolean
    return self._extractor:reservesRuns()
end

function SpriteDomainImpl:sprite(name: string, u0?: number, v0?: number, u1?: number, v1?: number): components.Sprite
    return self._extractor:sprite(name, u0, v0, u1, v1)
end

function SpriteDomainImpl:spriteSize(sprite: components.Sprite): number, number
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

function SpriteDomainImpl:setClipRegion(index: integer, region: ClipRegion)
    self._backend:setClipRegion(index, region)
end

function SpriteDomainImpl:clearClipRegion(index: integer)
    self._backend:clearClipRegion(index)
end

function SpriteDomainImpl:addProducer(producer: InstanceProducer)
    self._extractor:addProducer(producer)
end

function SpriteDomainImpl:addComputeStage(stage: ComputeStage)
    self._backend:addComputeStage(stage)
end

function SpriteDomainImpl:_rebuildPipelines()
    self._backend:rebuildPipelines()
end

function SpriteDomainImpl:_device(): loader.CPtr
    return self._backend:device()
end

function SpriteDomainImpl:extractSeconds(): number
    return self._extractor:extractSeconds()
end

function SpriteDomainImpl:_destroy()
    self._extractor:destroy()
    self._backend:destroy()
end

return SpriteDomainModule
