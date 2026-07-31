--[=[
Feeds the deferred pipeline from a world.

An application owns one renderer. Install it on a world, then call `render`
with each frame. Use `camera` to control the view, `images` to inspect image
residency, and `deferred` to add targets or passes. Call `destroy` when the
device shuts down.
]=]

-- Implementation details:
-- Renderer joins two independent halves. Extractor reads the world, applies
-- dirty gating and interpolation, and writes instances into mapped staging.
-- Backend owns buffers, culling, the pass graph, and the image array.
-- FramePacket is the only data that crosses between them.
--
-- This is a dependency boundary rather than a thread boundary. Extraction
-- runs during RenderFirst, and Backend consumes the packet afterwards on the
-- main thread. Renderer owns the packet and mapped staging addresses because
-- it is the only object that sees both halves.

local type types = require("tecs.types")
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
local screenshot <const> = require("tecs.gfx.screenshot")

local type InstanceProducer = Extractor.InstanceProducer
local type ClipRegion = Backend.ClipRegion
local type ComputeStage = Backend.ComputeStage

--- Sets the instance capacity for renderer buffers. The renderer drops rows
--- beyond this ceiling instead of growing a buffer mid-frame.
local DEFAULT_CAPACITY <const> = 65536

--- Ambient light when none was asked for.
---
--- White, so a scene with no lights in it draws its own colors rather than a
--- fraction of them. A dim default makes the first thing anyone builds look
--- broken and makes lighting the price of seeing anything at all; at white,
--- lights add on top of a scene that is already legible.
local DEFAULT_AMBIENT <const>: {number} = {1.0, 1.0, 1.0}

--- `RendererOptions` configures fixed renderer resources at creation.
local record RendererOptions
    --- Caller-writable. The caller sets `ambient` before `newRenderer` reads it.
    --- It contains red, green and blue and defaults to white.
    ambient: {number}
    --- Caller-writable. The caller sets `capacity` before creation to fix the
    --- maximum resident instance count.
    capacity: integer
    --- Caller-writable. The caller sets `cell` before creation to choose the
    --- image-array cell size in pixels.
    cell: integer
    --- Caller-writable. The caller sets `layers` before creation to choose the
    --- image-array layer count.
    layers: integer
    --- Caller-writable. The caller sets `reserveRuns` before creation. It
    --- defaults to false, which packs archetype runs end to end.
    ---
    --- With packed runs, one spawn shifts every later run and makes the
    --- renderer rewrite and upload the whole scene. Reserved runs let an
    --- archetype grow into its own slack and keep the rest of the scene
    --- resident. Culling also covers that slack.
    reserveRuns: boolean
    --- Caller-writable. The caller sets `partialRewrites` before creation. It
    --- defaults to false, which rewrites an archetype's whole run whenever a
    --- spawn or a despawn touched it.
    ---
    --- A row moving into an archetype has every column newly written at that
    --- row, so a structural change dirties every column of the archetype it
    --- lands on. The rest of the run did not change, and the ECS records which
    --- rows did, so this makes one spawn cost the rows it wrote rather than the
    --- archetype's population. A value write is unaffected and still rewrites
    --- the run, because it declares a column rather than a row.
    partialRewrites: boolean
    --- Caller-writable. The caller sets `packImages` before creation to fit
    --- many images into each array layer. It defaults to false.
    packImages: boolean
    --- Caller-writable. The caller sets `shadows` before creation to enable and
    --- configure shadows. Nil disables them; an empty record uses defaults.
    shadows: Deferred.ShadowOptions
end

--- A `Renderer` feeds the deferred pipeline from one world.
---
--- Create one per device and install it on a world. `destroy` releases every
--- resource it owns.
local record Renderer
    --- `Options` names the configuration that
    --- `newRenderer` reads.
    type Options = RendererOptions
    --- `InstanceProducer` names a custom instance source.
    type InstanceProducer = InstanceProducer
    --- `ClipRegion` names a target-pixel clipping
    --- rectangle.
    type ClipRegion = ClipRegion
    --- `ComputeStage` names a custom compute stage.
    type ComputeStage = ComputeStage

    --- Caller-writable. The caller changes `camera` to control the current
    --- view. The first frame centers it on the viewport.
    camera: Camera
    --- Read-only. Reports the instance capacity fixed at creation.
    capacity: integer
    --- Read-only. Reports the instances resident after the last sync.
    count: integer
    --- Read-only. Reports the instances the last sync could not fit.
    dropped: integer
    --- Read-only. Reports the instances rewritten by the last sync.
    rewritten: integer
    --- Read-only. Provides access to the renderer's image array.
    images: TextureArray
    --- Engine-owned. Exposes the instance buffer to custom compute stages;
    --- ordinary game code should ignore it.
    instances: Buffer
    --- Read-only. Provides access to the pass graph for custom targets and
    --- passes.
    deferred: Deferred

    --- Engine-owned. Stores the world-facing half; ordinary game code should
    --- ignore it.
    _extractor: Extractor
    --- Engine-owned. Stores the device-facing half; ordinary game code should
    --- ignore it.
    _backend: Backend
    --- The one packet, refilled each extraction rather than allocated per
    --- frame, so what `render` draws is always the last extraction's.
    _packet: FramePacket
    --- Staging slot the next extraction writes into, rotated after each
    --- submission.
    ---
    --- Rotating is what lets the mapping skip cycling. Cycling exists so a
    --- write cannot land in memory the GPU is still copying out of, and it pays
    --- for that with a fresh driver allocation every frame. Writing to a slot
    --- the GPU is not reading gives the same guarantee and allocates nothing.
    _slot: integer
    --- Whether the camera has been put in the middle of the viewport yet. It
    --- happens on the first frame that has something to draw, once and never
    --- again, so later game movement keeps control.
    _centerd: boolean
end

local RendererMT <const>: metatable<Renderer> = {__index = Renderer}

--- Builds a renderer for `device`.
---
--- @param device The engine supplies the GPU device that owns renderer
---     resources.
--- @param swapchainFormat The engine supplies the texture format used for
---     presentation copies.
--- @param options The caller supplies creation options or nil for defaults.
--- @return Returns a caller-owned renderer that `destroy` releases.
function Renderer.newRenderer(device: loader.CPtr, swapchainFormat: integer, options: RendererOptions): Renderer
    options = options or {}

    local self = setmetatable({} as Renderer, RendererMT)
    self.capacity = options.capacity or DEFAULT_CAPACITY
    self.count = 0
    self.dropped = 0
    self.rewritten = 0
    self._centerd = false
    self._slot = 0
    self._packet = FramePacket.create()

    -- A copy rather than the constant itself, so a caller reaching for
    -- `renderer.deferred.ambient` and writing into it moves this renderer's
    -- light and not every renderer's.
    local ambient <const> = options.ambient or {DEFAULT_AMBIENT[1], DEFAULT_AMBIENT[2], DEFAULT_AMBIENT[3]}

    local backend = Backend.create(
        device,
        swapchainFormat,
        {
            ambient = ambient,
            capacity = self.capacity,
            cell = options.cell,
            layers = options.layers,
            packImages = options.packImages,
            shadows = options.shadows,
        }
    )
    self._backend = backend
    self.images = backend.images
    self.instances = backend.instances
    self.deferred = backend.deferred

    -- The white pixel's extent is the backend's answer, decided by uploading
    -- it, and the extractor needs it for every row that carries no Sprite. It
    -- crosses once, at construction, rather than being asked for per frame.
    local extractor = Extractor.create({
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
    extractor:setStaging(self._slot, backend:mapSlot(self._slot))

    return self
end

--- Registers the sync system and queries on `world`.
---
--- An uninstalled renderer draws an empty scene.
---
--- @param world The caller supplies the world this renderer reads.
function Renderer:install(world: types.World)
    self._extractor:install(
        world,
        self._packet,
        function()
            local packet = self._packet
            self.count = packet.count
            self.dropped = packet.dropped
            self.rewritten = packet.rewritten
        end
    )
end

--- Uploads a decoded image into the array and returns a Sprite for it.
---
--- The path identifies the image for the renderer's lifetime. Re-registering
--- it returns the existing region. The call releases the decoded pixels and
--- raises when they no longer exist.
---
--- @param decoded The caller supplies a ready image that still owns its pixels.
--- @return Returns a fresh Sprite that selects the whole image.
--- @return Returns the renderer-owned live region that contains the image.
function Renderer:registerImage(decoded: assets.Image): components.Sprite, TextureArray.Region
    -- The payload's own existence rather than a status word. An `Image` that
    -- exists is a load that finished, so the only thing left to refuse is one
    -- whose last holder already gave the pixels back.
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

--- Uploads a decoded image over the one already registered under its path.
---
--- The replacement keeps the registered layer and rectangle, so existing
--- Sprites keep their identity. The call raises for missing pixels, an
--- unregistered path or a size change and releases valid decoded pixels.
---
--- @param decoded The caller supplies a ready image that matches a registered
---     path and size.
--- @return Returns a fresh Sprite that selects the unchanged region.
--- @return Returns the renderer-owned live region.
function Renderer:replaceImage(decoded: assets.Image): components.Sprite, TextureArray.Region
    if decoded.pixels == nil then
        error(("tecs: the pixels of '%s' have been released"):format(decoded.path), 2)
    end

    local image = components.imageId(decoded.path)
    local region = self._extractor:regionOf(image)
    if region == nil then
        error(("tecs: no image is registered as '%s', so there is nothing to " .. "replace"):format(decoded.path), 2)
    end
    if decoded.width ~= region.width or decoded.height ~= region.height then
        error(
            (
                "tecs: '%s' was registered at %dx%d and is now %dx%d; a "
                .. "replacement keeps the size, because the sprites drawing it "
                .. "already hold the old rect"
            ):format(decoded.path, region.width, region.height, decoded.width, decoded.height),
            2
        )
    end

    self._backend:replaceImage(region, decoded.pixels, decoded.width, decoded.height, decoded.pitch)
    decoded:release()

    return components.Sprite(image, region.u0, region.v0, region.u1, region.v1, region.layer), region
end

--- Rebuilds every pipeline from the shader sources as they read now.
---
--- A source that no longer compiles raises and leaves the current pipelines
--- intact. Call this only between passes.
function Renderer:rebuildPipelines()
    self._backend:rebuildPipelines()
end

--- Returns the region that a registered image occupies.
---
--- @param path The caller supplies the path used during registration.
--- @return Returns the renderer-owned live region, or nil when no image uses
---     that path.
function Renderer:regionOf(path: string): TextureArray.Region
    return self._extractor:regionOf(components.imageId(path))
end

--- Returns the world units that collapse onto one depth value.
---
--- Zero means the depth target preserves the full layer sort. A positive value
--- means entities closer than that value share depth and retain write order.
--- Query this during setup or after changing layer extents, not per frame.
--- @return Returns zero when the depth format preserves the layer sort, or the
---     collapse width otherwise.
function Renderer:depthSortCollapse(): number
    return Texture.depthSortCollapse(self.deferred.graph.depthFormat)
end

--- Returns whether archetype runs have room to grow.
---
--- @return Returns the fixed creation setting.
function Renderer:reservesRuns(): boolean
    return self._extractor:reservesRuns()
end

--- Returns a Sprite for a registered image.
---
--- UVs are fractions of the image rather than of the cell it sits in. Omitted,
--- they select the whole image. The call fails when no registration matches
--- the name.
---
--- @param name The caller supplies the registered image path.
--- @param u0 The caller supplies the left image fraction or omits it for zero.
--- @param v0 The caller supplies the top image fraction or omits it for zero.
--- @param u1 The caller supplies the right image fraction or omits it for one.
--- @param v1 The caller supplies the bottom image fraction or omits it for one.
--- @return Returns a fresh Sprite mapped into the image's array region.
function Renderer:sprite(name: string, u0?: number, v0?: number, u1?: number, v1?: number): components.Sprite
    return self._extractor:sprite(name, u0, v0, u1, v1)
end

--- Returns a sprite's natural width and height in source-image pixels.
---
--- A static sub-rectangle returns its fraction of the registered image. A GPU
--- animation encoding returns the whole image because its current frame lives
--- in the frame table rather than in the sprite's UV fields.
---
--- @param sprite The caller supplies a [`Sprite`](tealdoc:tecs.components.Sprite)
---     whose image has been registered on this renderer.
--- @return Returns natural source width, or zero when the image is unresolved.
--- @return Returns natural source height, or zero when the image is unresolved.
function Renderer:spriteSize(sprite: components.Sprite): number, number
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

--- Points region `index` at a rectangle in target pixels.
---
--- Fragments of an instance carrying `Clip(index)` are kept where they land
--- inside the rectangle and thrown away where they do not. Region zero is not
--- a region and cannot be set: it is what an instance says when it wants no
--- clipping at all.
---
--- @param index The caller supplies an integer from 1 through 255. Other values
---     raise.
--- @param region The caller supplies the target-pixel rectangle. Nil raises;
---     `clearClipRegion` removes one.
function Renderer:setClipRegion(index: integer, region: ClipRegion)
    self._backend:setClipRegion(index, region)
end

--- Stops region `index` clipping anything.
---
--- Instances still naming it draw whole rather than disappearing, so an
--- adapter handing indices out and taking them back leaves nothing behind that
--- silently removes content.
---
--- @param index The caller supplies an integer from 1 through 255. Clearing an
---     unused index succeeds.
function Renderer:clearClipRegion(index: integer)
    self._backend:clearClipRegion(index)
end

--- Adds a producer after archetype instances in registration order.
---
--- @param producer The caller supplies a producer that the renderer retains
---     until `destroy`, when it calls the producer's optional teardown hook
---     before releasing backend resources.
function Renderer:addProducer(producer: InstanceProducer)
    self._extractor:addProducer(producer)
end

--- Adds a compute stage between staging flush and culling.
---
--- @param stage The caller supplies a stage that the renderer retains and
---     destroys.
function Renderer:addComputeStage(stage: ComputeStage)
    self._backend:addComputeStage(stage)
end

--- Returns the GPU device this renderer uses.
---
--- For a stage that has to build its own pipelines and buffers before there is
--- a frame to record onto.
---
--- @return Returns the engine-owned device. `destroy` does not release it.
function Renderer:device(): loader.CPtr
    return self._backend:device()
end

--- Returns the seconds consumed by the last extraction.
---
--- Read by the frame loop, which subtracts it from the update to leave
--- simulation on its own. Extraction runs inside `world:update`, so the two
--- are one number until something takes them apart.
---
--- @return Returns elapsed seconds, or zero when measurement is inactive.
function Renderer:extractSeconds(): number
    return self._extractor:extractSeconds()
end

--- Draws the last extracted world state into `frame`.
---
--- @param frame The engine supplies an open frame. The method records commands
---     without submitting it, so callers may add later passes.
function Renderer:render(frame: Frame)
    local packet = self._packet

    -- The camera centers itself the first time there is something to draw, and
    -- the size to center on is only known once there is a frame to draw into.
    -- Written to the camera the game holds, since that is where a game reads it
    -- back from, and copied into the packet this frame is drawn from.
    if not self._centerd and packet.count > 0 then
        self._centerd = true
        self.camera.x = frame.width * 0.5
        self.camera.y = frame.height * 0.5
        packet:setCamera(self.camera)
    end

    -- Rotated before the frame is recorded rather than after, so a throw
    -- inside the recording cannot skip it. That frame is still resolved: the
    -- recovery path submits whatever copy passes were encoded before the
    -- throw, and if the extractor were still pointed at the slot they read
    -- from, the next extraction would write into memory the GPU is copying
    -- out of.
    --
    -- Which slot this frame uploads from is decided by the packet, not by
    -- this field, so moving the rotation earlier does not move what is drawn.
    -- Mapping does not cycle, so it neither waits on nor reallocates the slot
    -- the frame below is about to flush.
    local slot = (self._slot + 1) % Buffer.slotCount
    self._slot = slot
    self._extractor:setStaging(slot, self._backend:mapSlot(slot))

    self._backend:consume(packet, frame)
end

--- Returns the composited image from the last frame.
---
--- @return Returns the renderer-owned scene target. The next frame overwrites
---     its contents.
function Renderer:captureTexture(): Texture
    return self._backend:captureTexture()
end

--- Encodes the composited image from the last frame as PNG bytes.
---
--- Texture readback waits for the GPU work that produced the frame.
---
--- @return Returns PNG bytes, or nil when readback or encoding fails.
--- @return Returns the failure reason when the first return is nil.
function Renderer:screenshot(): string, string
    return screenshot.encode(self:captureTexture())
end

--- Writes the composited image from the last frame as a PNG.
---
--- @param path The caller supplies the destination path.
--- @return Returns whether capture, encoding and writing succeeded.
--- @return Returns the failure reason when the first return is false.
function Renderer:saveScreenshot(path: string): boolean, string
    if path == nil or path == "" then
        error("tecs: a screenshot path is required", 2)
    end
    return screenshot.save(self:captureTexture(), path)
end

--- Releases everything the renderer owns. Safe to call more than once.
function Renderer:destroy()
    self._extractor:destroy()
    self._backend:destroy()
end

return Renderer
