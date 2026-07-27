--- Turns a world into a frame packet.
---
--- The world-facing half of rendering, and the half that moves to the
--- simulation thread when the pipeline splits. It touches queries, archetypes
--- and components, and it never touches a device: the staging it writes into
--- arrives as a pair of mapped pointers, and what it did with them leaves as
--- ranges in a packet.
---
--- The sync walks archetype columns and writes instances straight into mapped
--- staging. There is no intermediate array: the column is contiguous C memory
--- and so is the destination, so a row becomes a handful of float stores into
--- driver memory rather than a copy between two buffers.
---
--- Instances pack as four vec4s: a 2x2 basis, an origin, a colour, and a UV
--- rect. A precomputed basis costs less on the GPU than a per-vertex sincos.
---
--- Which layer an image occupies is the backend's answer, not the image's
--- identity: layers are handed out as images register, so the number depends on
--- load order. A Sprite therefore names its image, and a registry here maps
--- that name to a layer. Resolving happens once, when the Sprite is built or
--- the first time a restored one is written, and the answer is cached in the
--- Sprite so extraction reads a field per row rather than a lookup.
---
--- That dirty gating is the point. Walking every entity every frame is the
--- cost that decides whether a large world is affordable, and most frames
--- change very little. Layer zero is a white pixel, so an entity with no
--- Sprite samples it and textured and untextured geometry share one path.

local ecs <const> = require("tecs.ecs")
local loader <const> = require("tecs.ffi.loader")
local Camera <const> = require("tecs.gfx.Camera")
local FramePacket <const> = require("tecs.FramePacket")
local components <const> = require("tecs.components")
local layers <const> = require("tecs.gfx.layers")
local timing <const> = require("tecs.timing")
local instancelayout <const> = require("tecs.gpu.instancelayout")

local type TextureArray = require("tecs.gpu.TextureArray")

--- Extraction: the world-facing half of the frame, and the half that moves to
--- the simulation thread when the pipeline splits.
local EXTRACT <const> = timing.stage("extract")

local INSTANCE_FLOATS <const> = instancelayout.FLOATS
local INSTANCE_BYTES <const> = instancelayout.BYTES
local BOUND_FLOATS <const> = instancelayout.BOUND_FLOATS
local BOUND_BYTES <const> = instancelayout.BOUND_BYTES
local UNBOUNDED <const> = instancelayout.UNBOUNDED
local extentOf <const> = instancelayout.extentOf
local packSlot <const> = instancelayout.packSlot

local PI <const> = math.pi
local TWO_PI <const> = math.pi * 2.0

--- Something that draws instances without owning entities.
---
--- Text is the reason this exists. A glyph is a textured quad like any other,
--- but making each one an entity puts every glyph in the world into one
--- archetype, so editing one string marks that column dirty and rewrites all of
--- them; and spawning or despawning glyphs moves an archetype's length, which
--- forces the whole scene to be laid out again. A producer sidesteps both: it
--- is laid out as its own run, and it says which parts of that run changed.
---
--- It writes the same sixteen floats and four bounds floats every other
--- instance carries, so culling, depth, layers and materials all apply to it
--- without knowing it is not an entity.
local record InstanceProducer
    --- Instances to reserve. Changing it moves the layout, so a producer that
    --- can avoid changing it should.
    count: function(self: InstanceProducer): integer

    --- Sub-ranges written since the last sync, as flat one-based inclusive
    --- pairs, and cleared by returning them. Empty means nothing changed and
    --- the run is skipped.
    takeDirty: function(self: InstanceProducer): {integer}

    --- Writes instances `first` through `last` of its run. `base` is the
    --- instance index the run starts at, so instance `first` is written at
    --- `base + first - 1`.
    write: function(self: InstanceProducer, floats: loader.CArray,
                    bounds: loader.CArray, base: integer,
                    first: integer, last: integer)
end

--- One archetype's contiguous run in the instance buffer.
local record Run
    offset: integer
    length: integer
end

local record ExtractorOptions
    --- Instances the buffers are sized for. Rows beyond it are dropped rather
    --- than growing anything mid-frame.
    capacity: integer
    --- UV extent of the white pixel within its cell, as the backend uploaded
    --- it. An image smaller than a cell does not reach the cell's edge, so
    --- sampling 0..1 would read the undefined remainder rather than the image.
    whiteU1: number
    whiteV1: number
end

local record Extractor
    type InstanceProducer = InstanceProducer
    type Options = ExtractorOptions

    --- What the view is looking at. The game's camera: read here, written by
    --- whoever is playing, and copied into every packet.
    camera: Camera
    capacity: integer

    --- Seconds the last extraction took. Zero unless timing is on.
    _extractSeconds: number
    --- How far through the current fixed step this frame falls, 0 to 1. Read
    --- once per sync rather than per row, since it is the same for every
    --- entity in the frame.
    _alpha: number
    --- Alpha the previous sync drew at, so a frame that lands at the same
    --- point in the step as the last one rewrites nothing.
    _lastAlpha: number
    _world: ecs.World
    _renderables: ecs.Query
    _lightSources: ecs.Query
    --- Producers, in the order they were added, which is the order their runs
    --- are laid out after the archetypes.
    _producers: {InstanceProducer}
    --- Where each producer's run starts and how long it is, so a change in
    --- length is noticed the same way an archetype's is.
    _producerRuns: {integer}
    --- Instance index each producer's run begins at this sync.
    _producerBase: {integer}
    _runs: {ecs.Archetype: Run}
    _seen: {ecs.Archetype: integer}

    --- The staging this frame writes into, as the backend mapped it, and the
    --- slot it belongs to. Held rather than asked for per run: the addresses
    --- are the only thing the device half hands over, and they change only
    --- when the slot rotates.
    _instances: loader.CArray
    _bounds: loader.CArray
    _slot: integer

    _whiteU1: number
    _whiteV1: number
    --- Texture-array layer each registered image name occupies, keyed by the
    --- name's index. This is the registry a Sprite's name resolves through.
    _slotByImage: {integer: integer}
    --- Region each registered image name occupies, so registering a name a
    --- second time answers with the layer it already has.
    _regionByImage: {integer: TextureArray.Region}
    --- Image name index a row asked for that nothing is registered under, or
    --- nil. Held rather than raised where it is found, because that point is
    --- inside a query cursor: see `syncInstances`.
    _missingImage: integer
end

local ExtractorMT <const>: metatable<Extractor> = { __index = Extractor }

--- Builds an extractor. Nothing here needs a device.
function Extractor.create(options: ExtractorOptions): Extractor
    local self = setmetatable({} as Extractor, ExtractorMT)
    self.camera = Camera.create()
    self.capacity = options.capacity
    self._extractSeconds = 0.0
    self._alpha = 1.0
    self._lastAlpha = 1.0
    self._producers = {}
    self._producerRuns = {}
    self._producerBase = {}
    self._runs = {}
    self._seen = {}
    self._slot = 0
    self._whiteU1 = options.whiteU1
    self._whiteV1 = options.whiteV1
    self._slotByImage = {}
    self._regionByImage = {}
    return self
end

--- Points the extractor at the staging slot it writes into next.
---
--- The backend owns the buffers, because the device does. What crosses is an
--- address and the slot it belongs to, which is the same thing that crosses
--- once the two halves are on different threads.
function Extractor:setStaging(slot: integer, instances: loader.CArray,
                              bounds: loader.CArray)
    self._slot = slot
    self._instances = instances
    self._bounds = bounds
end

--- Texture-array layer the given image name index resolves to.
---
--- Fails on a name nothing was registered under. A sprite naming an image the
--- renderer has never seen has no layer to sample, and every layer that does
--- exist holds some other image, so there is nothing to fall back to that is
--- not a wrong picture on the quad.
local function missingImageMessage(image: integer): string
    local name = components.imageName(image)
    if name == nil then
        return "tecs: a Sprite names no image; build one with "
            .. "Renderer:registerImage or Renderer:sprite"
    end
    return ("tecs: no image is registered as '%s'"):format(name)
end

local function slotOf(self: Extractor, image: integer): integer
    local slot = self._slotByImage[image]
    if slot ~= nil then return slot end
    error(missingImageMessage(image), 2)
end

--- Records the layer and region an image name was uploaded into.
---
--- The upload itself belongs to whoever owns the device. What comes back is
--- the answer this side resolves names with, which is plain numbers and is
--- what a snapshot's name has to be turned into again on the next run.
function Extractor:registerImage(image: integer, region: TextureArray.Region)
    self._slotByImage[image] = region.layer
    self._regionByImage[image] = region
end

--- The region an image name occupies, or nil if it was never registered.
function Extractor:regionOf(image: integer): TextureArray.Region
    return self._regionByImage[image]
end

--- A resolved Sprite for a registered image, ready to spawn.
---
--- UVs are fractions of the image rather than of the cell it sits in, so a
--- sub-rect of an atlas is written as the fraction it occupies and the padding
--- a cell may carry stays the renderer's business. Omitted, they select the
--- whole image.
---
--- Fails on a name nothing is registered under, because the alternative is a
--- quad that draws whichever image happens to hold that layer.
function Extractor:sprite(name: string, u0?: number, v0?: number,
                          u1?: number, v1?: number): components.Sprite
    local image = components.imageId(name)
    local slot = slotOf(self, image)
    local region = self._regionByImage[image]
    return components.Sprite(image,
        (u0 or 0.0) * region.u1, (v0 or 0.0) * region.v1,
        (u1 or 1.0) * region.u1, (v1 or 1.0) * region.v1, slot)
end

--- Adds a producer, laid out after the archetypes in the order added.
---
--- A producer draws instances it owns rather than entities, which is what lets
--- a subsystem whose items are not entities take part in the one draw
--- everything else goes through.
function Extractor:addProducer(producer: InstanceProducer)
    self._producers[#self._producers + 1] = producer
end

--- Writes one archetype's rows into its run.
---
--- Columns are read, not mutated, so `get` is correct here. Taking `getMut`
--- would mark these components dirty on every archetype every frame, which
--- would make the gate below always true and defeat its own purpose.
local function writeRun(self: Extractor, packet: FramePacket,
                        archetype: ecs.Archetype, length: integer,
                        offset: integer)
    local floats = self._instances
    local bounds = self._bounds
    local transforms = archetype:get(components.Transform)
    local tints = archetype:get(components.Tint)
    local sprites = archetype:get(components.Sprite)
    local materialColumn = archetype:get(components.Material)
    -- Absent on every archetype that clips nothing, which is the common case:
    -- the rows below then write the texture-array layer on its own and the
    -- fragments they produce never look at the region table.
    local clips = archetype:get(components.Clip)
    -- Loop invariant: an archetype either carries the previous transform or it
    -- does not, so an entity that is not interpolated costs one test per run
    -- rather than anything per row.
    local previous = archetype:get(components.PreviousTransform)
    local alpha <const> = self._alpha

    for row = 1, length do
        local transform = transforms[row]
        local tint = tints[row]

        local layer = 0.0
        local u0, v0 = 0.0, 0.0
        local u1, v1 = self._whiteU1, self._whiteV1
        if sprites ~= nil then
            local sprite = sprites[row]
            layer = sprite.slot
            if layer < 0 then
                -- A sprite arrives unresolved when it came from a snapshot,
                -- which carries its image's name because a layer is this
                -- process's answer and not something a save can hold. Caching
                -- the answer back into the column keeps the read above a field
                -- access: one lookup per sprite, not one per row per frame. The
                -- write is deliberately not marked dirty, since this pass is
                -- writing the row it belongs to now.
                local image <const> = sprite.image as integer
                local resolved <const> = self._slotByImage[image]
                if resolved == nil then
                    -- Reported after the loop rather than raised here. This
                    -- runs inside a query cursor, and an error thrown through
                    -- one leaves the world deferred, which silently queues
                    -- every spawn made after it: the frame would take the
                    -- world down with it instead of only itself. The row is
                    -- written against layer zero and the slot is left
                    -- unresolved, so a name registered later still resolves.
                    self._missingImage = image
                    layer = 0
                else
                    layer = resolved
                    sprite.slot = layer
                end
            end
            u0, v0, u1, v1 = sprite.u0, sprite.v0, sprite.u1, sprite.v1
        end

        -- The clip region rides above the layer in one float. Region zero
        -- packs to the layer unchanged, so an archetype with no Clip column
        -- writes exactly what it wrote before there were regions.
        local packedSlot = layer
        if clips ~= nil then
            packedSlot = packSlot(clips[row].index as integer, layer)
        end

        -- Material and parameter share one float: the integer part selects and
        -- the fraction carries the parameter, which is a ratio in 0..1 for
        -- every material that has one. Keeps the instance at four vec4s.
        local material = 0.0
        if materialColumn ~= nil then
            local entry = materialColumn[row]
            local param = entry.param
            if param < 0.0 then
                param = 0.0
            elseif param > 0.999 then
                param = 0.999
            end
            material = entry.id + param
        end

        local entityLayer <const> = transform.layer as integer
        local angle = transform.rotation
        local scaleX = transform.scaleX
        local scaleY = transform.scaleY
        local originX = transform.x
        local originY = transform.y

        if previous ~= nil then
            local before = previous[row]
            originX = before.x + (originX - before.x) * alpha
            originY = before.y + (originY - before.y) * alpha

            -- The shortest arc, because an angle that crossed pi would
            -- otherwise be interpolated the long way round and the entity
            -- would spin backwards through nearly a full turn on that frame.
            local turn = angle - before.rotation
            if turn > PI then
                turn = turn - TWO_PI
            elseif turn < -PI then
                turn = turn + TWO_PI
            end
            angle = before.rotation + turn * alpha
        end

        local base = (offset + row - 1) * INSTANCE_FLOATS
        floats[base] = angle
        floats[base + 1] = scaleX
        floats[base + 2] = scaleY
        -- The band this entity's layer owns, and where in it the sort mode
        -- puts it. Zero is nearest, so a higher layer resolves to a smaller
        -- value and covers everything below it whatever the two contain.
        floats[base + 3] = layers.depthOf(entityLayer, transform.z,
            originX, originY)

        floats[base + 4] = originX
        floats[base + 5] = originY
        floats[base + 6] = packedSlot
        floats[base + 7] = material

        floats[base + 8] = tint.r
        floats[base + 9] = tint.g
        floats[base + 10] = tint.b
        floats[base + 11] = tint.a

        floats[base + 12] = u0
        floats[base + 13] = v0
        floats[base + 14] = u1
        floats[base + 15] = v1

        local ex: number
        local ey: number
        if not layers.viewCulled(entityLayer) then
            -- The layer draws its contents somewhere the view rectangle does
            -- not describe, so a world bound would cull what is on screen. A
            -- bound no view can be outside of hands the decision to the layer.
            ex = UNBOUNDED
            ey = UNBOUNDED
        else
            ex, ey = extentOf(angle, scaleX, scaleY)
        end

        local bound = (offset + row - 1) * BOUND_FLOATS
        bounds[bound] = originX
        bounds[bound + 1] = originY
        bounds[bound + 2] = ex
        bounds[bound + 3] = ey
    end

    packet.instanceRanges:mark(offset * INSTANCE_BYTES,
        length * INSTANCE_BYTES)
    packet.boundsRanges:mark(offset * BOUND_BYTES, length * BOUND_BYTES)
end

--- Marks the bytes a run of instances occupies, in both range lists.
local function markRun(packet: FramePacket, offset: integer, count: integer)
    if count <= 0 then return end
    packet.instanceRanges:mark(offset * INSTANCE_BYTES, count * INSTANCE_BYTES)
    packet.boundsRanges:mark(offset * BOUND_BYTES, count * BOUND_BYTES)
end

--- Rewrites only what changed.
---
--- The layout is rebuilt when the set of archetypes or their lengths move,
--- because a run cannot grow in place without shifting its neighbours. Short
--- of that, an archetype whose Transform, Tint, and Sprite columns are all
--- clean is skipped entirely: its bytes are already resident and correct.
local function syncInstances(self: Extractor, packet: FramePacket)
    local runs = self._runs
    local seen = self._seen
    for archetype in pairs(seen) do seen[archetype] = nil end

    local total = 0
    local relayout = false
    for archetype, length in self._renderables:iter() do
        seen[archetype] = length
        local run = runs[archetype]
        if run == nil or run.length ~= length or run.offset ~= total then
            relayout = true
        end
        total = total + length
    end

    -- An archetype that went away leaves a hole, so the layout must move.
    for archetype in pairs(runs) do
        if seen[archetype] == nil then
            runs[archetype] = nil
            relayout = true
        end
    end

    -- Producers are laid out after the archetypes, in the order they were
    -- added. A producer whose count moved shifts everything after it, which is
    -- the same condition an archetype's length changing creates.
    local producers <const> = self._producers
    local producerRuns <const> = self._producerRuns
    local producerBase: {integer} = self._producerBase
    for index = 1, #producers do
        local count = producers[index]:count()
        producerBase[index] = total
        if producerRuns[index * 2 - 1] ~= total
            or producerRuns[index * 2] ~= count then
            relayout = true
        end
        producerRuns[index * 2 - 1] = total
        producerRuns[index * 2] = count
        total = total + count
    end

    local dropped = 0
    if total > self.capacity then
        dropped = total - self.capacity
        total = self.capacity
    end

    -- An interpolated entity's drawn position moves with alpha even when the
    -- simulation did not touch its transform, so the dirty bits alone would
    -- hold it still between fixed steps. Alpha standing still is the case
    -- where they are enough: a frame rate matching the step rate rewrites
    -- nothing, which is what makes this cost nothing when it buys nothing.
    local interpolating <const> = self._alpha ~= self._lastAlpha
    self._lastAlpha = self._alpha

    local rewritten = 0
    local offset = 0
    -- A cursor rather than iter, because this stops once the buffer is full and
    -- leaving an archetype loop early through iter leaves the world deferred,
    -- which silently queues every spawn made after it.
    local cursor = self._renderables:cursor()
    for archetype, length in cursor:iter() do
        if offset >= self.capacity then break end
        if offset + length > self.capacity then
            length = self.capacity - offset
        end

        local run = runs[archetype]
        local dirty = relayout
            or archetype:isComponentDirty(components.Transform)
            or archetype:isComponentDirty(components.Tint)
            or archetype:isComponentDirty(components.Sprite)
            or archetype:isComponentDirty(components.Material)
            or archetype:isComponentDirty(components.Clip)
            or (interpolating
                and archetype:get(components.PreviousTransform) ~= nil)

        if dirty then
            writeRun(self, packet, archetype, length, offset)
            rewritten = rewritten + length
        end

        if run == nil then
            runs[archetype] = { offset = offset, length = length }
        else
            run.offset = offset
            run.length = length
        end
        offset = offset + length
    end
    cursor:close()

    -- A Sprite naming an image nothing registered is still an error: every
    -- layer that exists holds some other picture, so drawing one of those
    -- instead would turn a broken asset into an art bug nobody traces back.
    -- What the cursor above buys is that it is only this frame's error. The
    -- world is whole, and a caller that catches this can register the image
    -- and draw again.
    local missing <const> = self._missingImage
    if missing ~= nil then
        self._missingImage = nil
        error(missingImageMessage(missing), 2)
    end

    if #producers > 0 then
        local floats = self._instances
        local bounds = self._bounds
        for index = 1, #producers do
            local producer = producers[index]
            local base = producerBase[index]
            local count = producerRuns[index * 2]
            if base + count > self.capacity then
                count = self.capacity - base
                if count < 0 then count = 0 end
            end

            local ranges = producer:takeDirty()
            if relayout and count > 0 then
                producer:write(floats, bounds, base, 1, count)
                markRun(packet, base, count)
                rewritten = rewritten + count
            else
                for entry = 1, #ranges, 2 do
                    local first = ranges[entry]
                    local last = ranges[entry + 1]
                    if last > count then last = count end
                    if first <= last then
                        producer:write(floats, bounds, base, first, last)
                        markRun(packet, base + first - 1, last - first + 1)
                        rewritten = rewritten + (last - first + 1)
                    end
                end
            end
        end
    end

    packet.count = total
    packet.dropped = dropped
    packet.rewritten = rewritten
end

--- Collects lights from the world into the packet.
local function syncLights(self: Extractor, packet: FramePacket)
    for archetype, length in self._lightSources:iter() do
        local transforms = archetype:get(components.Transform)
        local sources = archetype:get(components.PointLight)
        for row = 1, length do
            local transform = transforms[row]
            local source = sources[row]
            packet:addLight(transform.x, transform.y, source.height,
                source.radius, source.r, source.g, source.b, source.intensity)
        end
    end
end

--- Fills `packet` from the world as it stands right now.
---
--- Everything a frame is drawn from is settled here: the instance and bounds
--- bytes go into the staging the backend mapped, and where they went, how many
--- there are, where the view was and what is lighting it go into the packet.
function Extractor:extract(packet: FramePacket)
    local started = timing.begin()
    packet:begin(self._slot)

    -- Whatever the fixed steps left unconsumed, as a fraction of one step.
    -- Read here rather than per row: it is the same for the whole frame.
    local timestep, accumulator = self._world:getFixedTiming()
    self._alpha = timestep > 0.0 and accumulator / timestep or 1.0
    if self._alpha > 1.0 then self._alpha = 1.0 end

    syncInstances(self, packet)
    syncLights(self, packet)
    packet:setCamera(self.camera)

    self._extractSeconds = timing.finish(EXTRACT, started)
end

--- Registers the sync system and queries on `world`.
---
--- Syncing runs inside the world's update, in RenderFirst. Rendering happens
--- afterwards against a frame, so the two stay separable: the sync needs no
--- command buffer and the render needs no world.
--- @param published Called once the packet is filled, which is the moment it
---     would be handed over. What flips a slot's state when there is one.
function Extractor:install(world: ecs.World, packet: FramePacket,
                           published: function())
    self._world = world

    -- Snapshotting before anything in the step moves is what makes the pair a
    -- pair: taken later, the two would be the same value and every frame would
    -- draw the entity where the step left it.
    local interpolated = world:query({
        include = { components.Transform, components.PreviousTransform },
    })
    world:addSystem({
        name = "tecs.SnapshotTransforms",
        phase = ecs.phases.FixedFirst,
        run = function()
            for archetype, length in interpolated:iter() do
                local transforms = archetype:get(components.Transform)
                -- Mutable, because this writes every row it visits: the whole
                -- column is what the next frame interpolates from.
                local before = archetype:getMut(components.PreviousTransform)
                for row = 1, length do
                    local transform = transforms[row]
                    local target = before[row]
                    target.x = transform.x
                    target.y = transform.y
                    target.rotation = transform.rotation
                end
            end
        end,
    })

    self._renderables = world:query({
        include = {
            components.Transform, components.Tint, components.Renderable,
        },
    })
    self._lightSources = world:query({
        include = { components.Transform, components.PointLight },
    })

    world:addSystem({
        name = "tecs.SyncRenderState",
        phase = ecs.phases.RenderFirst,
        run = function()
            self:extract(packet)
            if published ~= nil then published() end
        end,
    })
end

--- Seconds the last extraction took, or zero when nothing is being measured.
function Extractor:extractSeconds(): number
    return self._extractSeconds or 0.0
end

return Extractor
