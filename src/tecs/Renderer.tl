--- Feeds the deferred pipeline from a world.
---
--- Two halves and the seam between them. `Extractor` is world-facing: queries,
--- archetype runs, relayout detection, dirty gating, producers and the
--- interpolation alpha, writing instances straight into mapped staging.
--- `Backend` is device-facing: the buffers, the flush, the cull, the deferred
--- pass graph and the image array. A `FramePacket` is everything that crosses,
--- and neither half holds a reference to the other.
---
--- The line is a dependency rule, not a thread boundary. Both halves run on
--- the main thread, one after the other: the extractor inside `world:update`,
--- in RenderFirst, and the backend afterwards against a frame. What the rule
--- buys is that extraction needs no command buffer and rendering needs no
--- world, so a world extracts with no device behind it and the backend is
--- exercised with no world in front of it. This object is what still sees
--- both: it owns the packet, rotates the staging slot, and hands the backend's
--- mapped addresses to the extractor.
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
local screenshot <const> = require("tecs.gfx.screenshot")

local type InstanceProducer = Extractor.InstanceProducer
local type ClipRegion = Backend.ClipRegion
local type ComputeStage = Backend.ComputeStage

--- Instances the buffers are sized for. This is a ceiling, not a hint: rows
--- beyond it are dropped rather than growing the buffer mid-frame.
local DEFAULT_CAPACITY <const> = 65536

--- Ambient light when none was asked for.
---
--- White, so a scene with no lights in it draws its own colours rather than a
--- fraction of them. A dim default makes the first thing anyone builds look
--- broken and makes lighting the price of seeing anything at all; at white,
--- lights add on top of a scene that is already legible.
local DEFAULT_AMBIENT <const>: {number} = {1.0, 1.0, 1.0}

local record RendererOptions
    --- Light every surface receives before any light entity contributes, as
    --- red, green and blue. Defaults to white.
    ambient: {number}
    --- Instances the buffer is sized for.
    capacity: integer
    --- Cell size of the image array.
    cell: integer
    --- Layers the image array holds.
    layers: integer
    --- Give each archetype a run with room to grow rather than packing the
    --- runs end to end. Defaults to false, which packs.
    ---
    --- Packed, one spawn anywhere shifts every run after it and the whole
    --- scene is rewritten and re-uploaded. Reserved, an archetype grows into
    --- its own slack and the rest of the scene stays resident, and the cull is
    --- dispatched over the slack as well as over the rows.
    reserveRuns: boolean
    --- Fit many images into each layer of the image array rather than one.
    --- Defaults to false. On, the ceiling on distinct images is the array's
    --- area rather than its layer count, and a small image costs its own size
    --- rather than a whole cell.
    packImages: boolean
    --- Let entities cast shadows, and tune what they cost. Nil, the default,
    --- means an `Occluder` or a `DropShadow` on an entity draws the entity and
    --- casts nothing, because the targets that would hold a shadow are never
    --- built. An empty table turns them on with every default.
    shadows: Deferred.ShadowOptions
end

--- The renderer a game holds, and the only object that sees both halves.
---
--- One is created per device and installed on a world, after which it does its
--- work from the system it registered and from `render`. It owns the packet,
--- the extractor and the backend, and `destroy` takes all three with it.
local record Renderer
    --- Re-exported for whoever writes one and passes it to `addProducer`.
    type InstanceProducer = InstanceProducer
    --- Re-exported for whoever names a rectangle for `setClipRegion`.
    type ClipRegion = ClipRegion
    --- Re-exported for whoever implements one and passes it to
    --- `addComputeStage`.
    type ComputeStage = ComputeStage

    --- What the view is looking at. Centred on the viewport the first time a
    --- frame is drawn, so a scene that never mentions a camera sees world
    --- coordinates as screen coordinates.
    camera: Camera
    --- Instances the buffers were sized for, fixed at creation. Nothing grows,
    --- so this is what `dropped` counts against.
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

    --- The world-facing half. `camera` above is its camera, named here so
    --- neither half has to be reached for.
    _extractor: Extractor
    --- The device-facing half. `images`, `instances` and `deferred` above are
    --- its, on the same terms.
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
    --- again, so a game that moves the camera itself is not moved back.
    _centred: boolean
end

local RendererMT <const>: metatable<Renderer> = {__index = Renderer}

--- Builds a renderer for `device`.
---
--- @param swapchainFormat The `SDL_GPUTextureFormat` present copies into.
--- @param options Every field has a default, and nil is accepted at runtime
---     even though the signature does not mark it optional.
function Renderer.create(device: loader.CPtr, swapchainFormat: integer, options: RendererOptions): Renderer
    options = options or {}

    local self = setmetatable({} as Renderer, RendererMT)
    self.capacity = options.capacity or DEFAULT_CAPACITY
    self.count = 0
    self.dropped = 0
    self.rewritten = 0
    self._centred = false
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
--- Two systems, not one: the transform snapshot the interpolation reads runs
--- in FixedFirst, before anything in the step has moved, and the extraction
--- itself runs in RenderFirst. The counts above are published as the second
--- returns, so a system later in the frame reads this frame's numbers.
---
--- @param world The queries and both systems are added here and nowhere else,
---     so a renderer that was created and never installed draws an empty
---     packet rather than failing.
function Renderer:install(world: ecs.World)
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
--- The image is registered under its path, which is what a Sprite names it by
--- and what a snapshot stores. Registering a path a second time answers with
--- the layer it already holds instead of consuming another, so a name means
--- one image for the life of the renderer however many times it is asked for.
--- The path is what identifies it rather than the spelling of the path: two
--- ways of writing one path are one image, since the array's layers are few
--- and none of them is ever given back.
---
--- A Sprite is returned rather than a bare region because an image smaller
--- than a cell does not reach the cell's edge, so the UV range is not 0..1 and
--- a caller guessing it would sample the undefined remainder. The second
--- return is the region, which reports the size that was uploaded.
---
--- The handle's pixels are released here: the array holds them now.
---
--- @param handle Must have loaded: any other status raises, and the pixels are
---     released whether the path was new or already registered.
--- @return A Sprite selecting the whole image, ready to spawn.
--- @return Where it landed, which reports the size that was uploaded rather
---     than the cell's. The renderer's own record, not a copy.
function Renderer:registerImage(handle: assets.Handle): components.Sprite, TextureArray.Region
    if handle.status ~= "ready" then
        error(("tecs: image '%s' is %s"):format(handle.path, handle.status), 2)
    end

    local image = components.imageId(handle.path)
    local region = self._extractor:regionOf(image)
    if region == nil then
        region = self._backend:addImage(handle.pixels, handle.width, handle.height, handle.pitch)
        self._extractor:registerImage(image, region)
    end
    handle:release()

    return components.Sprite(image, region.u0, region.v0, region.u1, region.v1, region.layer), region
end

--- Uploads a decoded image over the one already registered under its path.
---
--- Identity is the point. The image keeps the layer and the rect it was given
--- at registration, so every `Sprite`, `Sheet` and glyph already spawned from
--- it goes on naming the right texels and the next frame simply draws the new
--- pixels. Nothing in the world is touched and nothing has to be invalidated.
---
--- The size has to match. A larger or smaller image needs a different rect, and
--- the UVs of the old one are already copied into every instance that uses it,
--- so this refuses rather than silently drawing part of a neighbour.
---
--- Fails on a path nothing is registered under, since there is no rect to write
--- into and adding one would be `registerImage`.
---
--- The handle's pixels are released here: the array holds them now.
---
--- @param handle Must have loaded, must name a path already registered, and
---     must be the same size it was registered at. Each of the three raises,
---     and the pixels are only released once all three have passed.
--- @return The same Sprite `registerImage` answered with, since neither the
---     layer nor the rect moved.
--- @return The region, unchanged, and still the renderer's own record.
function Renderer:replaceImage(handle: assets.Handle): components.Sprite, TextureArray.Region
    if handle.status ~= "ready" then
        error(("tecs: image '%s' is %s"):format(handle.path, handle.status), 2)
    end

    local image = components.imageId(handle.path)
    local region = self._extractor:regionOf(image)
    if region == nil then
        error(("tecs: no image is registered as '%s', so there is nothing to " .. "replace"):format(handle.path), 2)
    end
    if handle.width ~= region.width or handle.height ~= region.height then
        error(
            (
                "tecs: '%s' was registered at %dx%d and is now %dx%d; a "
                .. "replacement keeps the size, because the sprites drawing it "
                .. "already hold the old rect"
            ):format(handle.path, region.width, region.height, handle.width, handle.height),
            2
        )
    end

    self._backend:replaceImage(region, handle.pixels, handle.width, handle.height, handle.pitch)
    handle:release()

    return components.Sprite(image, region.u0, region.v0, region.u1, region.v1, region.layer), region
end

--- Rebuilds every pipeline from the shader sources as they read now.
---
--- The device's half of a shader reload: whoever asked for one has already
--- re-read the sources, and this is what makes the next frame draw from them.
--- A source that no longer compiles raises and changes nothing.
---
--- Not to be called from inside a pass. It waits for the device to go idle and
--- releases the handles a recorded pass would still be reading.
function Renderer:rebuildPipelines()
    self._backend:rebuildPipelines()
end

--- The region an image already occupies, or nil if none has registered it.
---
--- What `registerImage` answers, without a decoded handle to answer it with.
--- A caller that has lost its derived copy of a region, which a font atlas
--- does when its metrics are re-read, would otherwise have to decode the file
--- again only to be handed back the layer it already had and have its pixels
--- released undrawn.
---
--- @param path The path the image was registered under, spelled the same way.
--- @return The renderer's own record of where the image landed, not a copy.
---     Nil says nothing is registered under that path, which is the one answer
---     `registerImage` and `replaceImage` differ on.
function Renderer:regionOf(path: string): TextureArray.Region
    return self._extractor:regionOf(components.imageId(path))
end

--- World units that collapse onto one depth value on this device.
---
--- Zero on a device whose depth target holds everything the layer sort
--- produces, which is what a device offering `D32_FLOAT` or `D24_UNORM`
--- answers at any extents a scene is likely to use. Above zero, the target is
--- the floor SDL guarantees and its step is coarser than the sort's own: the
--- bands still hold, so a HUD still covers a world, and entities closer
--- together than this share a depth value and draw in the order they were
--- written rather than the order they were sorted into.
---
--- Reachable rather than only logged, because there is something to do about
--- it. Dividing `layers.maxY` and `layers.maxZ` by what this answers raises
--- the sort's own resolution by the same factor, after which this answers
--- zero and the scene sorts again inside a world that much smaller. A game
--- that would rather keep its extents can drop to the `z` sort on the layers
--- that matter, which resolves in the floor format with room to spare.
---
--- A startup question, asked once. It walks the format table and re-derives
--- what the sort resolves to, so it is not for a frame loop, and it reads the
--- extents as they are now rather than as they were when the target was
--- created, which is what makes asking again after narrowing them meaningful.
--- @return Zero, or world units, which is also the factor `layers.maxY` and
---     `layers.maxZ` divide by to resolve the sort again.
function Renderer:depthSortCollapse(): number
    return Texture.depthSortCollapse(self.deferred.graph.depthFormat)
end

--- Whether archetype runs are laid out with room to grow.
function Renderer:reservesRuns(): boolean
    return self._extractor:reservesRuns()
end

--- A resolved Sprite for a registered image, ready to spawn.
---
--- UVs are fractions of the image rather than of the cell it sits in. Omitted,
--- they select the whole image. Fails on a name nothing is registered under.
---
--- @param name The path the image was registered under.
--- @param u0 Zero at the image's left edge and one at its right, not the
---     cell's. Defaults to zero, as `v0` does.
--- @param u1 Defaults to one, as `v1` does, so omitting all four is the whole
---     image.
--- @return A fresh Sprite, with the fractions already mapped into the rect the
---     image occupies within its cell.
function Renderer:sprite(name: string, u0?: number, v0?: number, u1?: number, v1?: number): components.Sprite
    return self._extractor:sprite(name, u0, v0, u1, v1)
end

--- Points region `index` at a rectangle in target pixels.
---
--- Fragments of an instance carrying `Clip(index)` are kept where they land
--- inside the rectangle and thrown away where they do not. Region zero is not
--- a region and cannot be set: it is what an instance says when it wants no
--- clipping at all.
---
--- @param index 1 through 255. Zero, a fraction, or anything outside that
---     raises.
--- @param region Nil raises rather than clearing; `clearClipRegion` is what
---     stops a region clipping.
function Renderer:setClipRegion(index: integer, region: ClipRegion)
    self._backend:setClipRegion(index, region)
end

--- Stops region `index` clipping anything.
---
--- Instances still naming it draw whole rather than disappearing, so an
--- adapter handing indices out and taking them back leaves nothing behind that
--- silently removes content.
---
--- @param index The same range `setClipRegion` takes. Clearing one nobody set
---     is not an error.
function Renderer:clearClipRegion(index: integer)
    self._backend:clearClipRegion(index)
end

--- Adds a producer, laid out after the archetypes in the order added.
---
--- @param producer Held for the life of the renderer; there is no way to take
---     one back out.
function Renderer:addProducer(producer: InstanceProducer)
    self._extractor:addProducer(producer)
end

--- Adds a stage recorded between the staging flush and the cull.
---
--- What a producer whose instances are written on the GPU needs beyond the
--- run a producer already gets: the run reserves the slots, and this is where
--- something is put in them.
---
--- @param stage Held until `destroy`, which calls its own. There is no way to
---     take one back out.
function Renderer:addComputeStage(stage: ComputeStage)
    self._backend:addComputeStage(stage)
end

--- The GPU device this renderer draws through.
---
--- For a stage that has to build its own pipelines and buffers before there is
--- a frame to record onto.
---
--- @return The `SDL_GPUDevice` handed to `create`. Not owned here: `destroy`
---     releases what was built on it and never the device itself.
function Renderer:device(): loader.CPtr
    return self._backend:device()
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
---
--- @param frame Recorded onto and not submitted, so a caller with passes of
---     its own records them after this and submits once. Its width and height
---     are what the camera's matrix and the view bounds are resolved against,
---     which is why they are not stored on the camera.
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

--- The composited image the last frame produced.
---
--- @return The scene target rather than the swapchain, so it can be read at any
---     point between frames. The renderer goes on drawing into it, so the next
---     frame overwrites what a caller has not already copied out.
function Renderer:captureTexture(): Texture
    return self._backend:captureTexture()
end

--- Encodes the composited image from the last frame as PNG bytes.
---
--- Synchronous: texture readback waits for the GPU work producing that frame.
function Renderer:screenshot(): string, string
    return screenshot.encode(self:captureTexture())
end

--- Writes the composited image from the last frame as a PNG.
---
--- The path is passed through the installed storage backend unchanged.
function Renderer:saveScreenshot(path: string): boolean, string
    if path == nil or path == "" then
        error("tecs: a screenshot path is required", 2)
    end
    return screenshot.save(self:captureTexture(), path)
end

--- Releases everything the renderer owns. Safe to call more than once.
function Renderer:destroy()
    self._backend:destroy()
end

return Renderer
