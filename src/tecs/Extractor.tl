--[=[
Turns a world into a frame packet.

The world-facing half of rendering. It touches queries, archetypes and
components, and it never touches a device: the staging it writes into
arrives as a pair of mapped pointers, and what it did with them leaves as
ranges in a packet. That is what lets a world be extracted with no device
at all, and what keeps every dirty bit consumed in one place.

The sync walks archetype columns and writes instances straight into mapped
staging. There is no intermediate array: the column is contiguous C memory
and so is the destination, so a row becomes a handful of float stores into
driver memory rather than a copy between two buffers.

Instances pack as four vec4s: a 2x2 basis, an origin, a color, and a UV
rect. A precomputed basis costs less on the GPU than a per-vertex sincos.
The origin is the quad's middle, which is the entity's position until a
`Pivot` says the quad hangs off some other point of itself.

Which layer an image occupies is the backend's answer, not the image's
identity: layers are handed out as images register, so the number depends on
load order. A Sprite therefore names its image, and a registry here maps
that name to a layer. Resolving happens once, when the Sprite is built or
the first time a restored one is written, and the answer is cached in the
Sprite so extraction reads a field per row rather than a lookup.

That dirty gating is the point. Walking every entity every frame is the
cost that decides whether a large world is affordable, and most frames
change very little. Layer zero is a white pixel, so an entity with no
Sprite samples it and textured and untextured geometry share one path.
]=]

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local loader <const> = require("tecs.ffi.loader")
local Camera <const> = require("tecs.gfx.Camera")
local FramePacket <const> = require("tecs.FramePacket")
local components <const> = require("tecs.components")
local layers <const> = require("tecs.gfx.layers")
local sheet <const> = require("tecs.gfx.sheet")
local timing <const> = require("tecs.timing")
local instancelayout <const> = require("tecs.gpu.instancelayout")

local type TextureArray = require("tecs.gpu.TextureArray")

--- Extraction: the world-facing half of the frame.
local EXTRACT <const> = timing.stage("extract")

--- The pose every drawn row is written from, bound once rather than read
--- off the module at each of the seven places below that name it.
local Transform <const> = ecs.Transform

local INSTANCE_FLOATS <const> = instancelayout.FLOATS
local INSTANCE_BYTES <const> = instancelayout.BYTES
local BOUND_FLOATS <const> = instancelayout.BOUND_FLOATS
local BOUND_BYTES <const> = instancelayout.BOUND_BYTES
local UNBOUNDED <const> = instancelayout.UNBOUNDED
local HIDDEN <const> = instancelayout.HIDDEN
local HIDDEN_DEPTH <const> = instancelayout.HIDDEN_DEPTH
local extentOf <const> = instancelayout.extentOf
local packSlot <const> = instancelayout.packSlot
--- Largest cast height a slot holds, which a 0 to 1 height is quantised onto.
local TOP_STEP <const> = instancelayout.HEIGHTS - 1

local Pivot <const> = sheet.Pivot

local PI <const> = math.pi
local TWO_PI <const> = math.pi * 2.0
local cos <const> = math.cos
local sin <const> = math.sin
local floor <const> = math.floor

--- Room a run that has grown once is given to grow again, as a fraction of the
--- rows it holds, and the room any run is given whatever that works out to.
---
--- A quarter puts a growing run's reallocations on a geometric schedule, so a
--- scene that spawns steadily pays a bounded number of stores per spawn rather
--- than a run rewrite each. The fraction is withheld until a run has actually
--- outgrown its slot, because an archetype that never grows would otherwise
--- hold a quarter of itself in slack for ever: a still scene is the common one
--- and it should occupy what it occupies.
local SLACK_RATIO <const> = 0.25
local MIN_SLACK <const> = 16

--- What a compaction has to reclaim to be worth the full rewrite it costs, as
--- a fraction of the extent a fresh layout would occupy, and the floor below
--- which reclaiming anything is not worth a rewrite.
---
--- Half means the extent the cull is dispatched over settles between one and
--- one and a half times what the rows alone need, and that a compaction is
--- paid for by the spawns and despawns that made it necessary.
local RECLAIM_RATIO <const> = 0.5
local MIN_RECLAIM <const> = 512

--- Reservations, widest first, as a compaction tries them against what the
--- buffer has room for.
local RESERVE_FULL <const> = 2
local RESERVE_FLOOR <const> = 1
local RESERVE_NONE <const> = 0

--- A layer no row carries, for the band cache a run starts empty.
---
--- `Transform.layer` is an `int32_t`, so anything outside that width is a
--- value the first row can never match and the cache is always cold on the
--- first comparison rather than on a flag tested once a row.
local NO_LAYER <const> = 2 ^ 31

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
    write: function(
        self: InstanceProducer,
        floats: loader.CArray,
        bounds: loader.CArray,
        base: integer,
        first: integer,
        last: integer
    )
end

--- One archetype's contiguous run in the instance buffer.
local record Run
    offset: integer
    --- Rows the run held after the last sync wrote it.
    length: integer
    --- Slots the run owns from `offset`. Equal to `length` when runs are
    --- packed, and at least it when they are reserved: the difference is the
    --- room the archetype grows into, written as hidden.
    capacity: integer
    --- Rows this sync writes, after the buffer's ceiling truncated them.
    pending: integer
    --- Set when this sync gave the run a different offset or reservation, so
    --- its bytes are stale whatever the component bits say.
    moved: boolean
    --- Set once the archetype has outgrown a reservation, which is what earns
    --- it the room to grow again.
    grown: boolean
end

local record ExtractorOptions
    --- Instances the buffers are sized for. Rows beyond it are dropped rather
    --- than growing anything mid-frame.
    capacity: integer
    --- Give each archetype a run with room to grow rather than packing the
    --- runs end to end. Defaults to false, which packs.
    ---
    --- Packed, a run cannot grow without shifting every run after it, so one
    --- spawn anywhere rewrites every instance in the scene. Reserved, it grows
    --- into its own slack and the archetypes around it are left alone; what it
    --- costs is that the cull is dispatched over the slack as well as over the
    --- rows.
    reserveRuns: boolean
    --- UV extent of the white pixel within its cell, as the backend uploaded
    --- it. An image smaller than a cell does not reach the cell's edge, so
    --- sampling 0..1 would read the undefined remainder rather than the image.
    whiteU0: number
    whiteV0: number
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
    _world: types.World
    _renderables: types.Query
    _lightSources: types.Query
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
    --- Reserve room in each run rather than packing them end to end.
    _reserve: boolean
    --- Slots the reserved runs cover, live and slack together. This is what
    --- the cull is dispatched over, and it is where the next run is allocated.
    _high: integer

    --- The staging this frame writes into, as the backend mapped it, and the
    --- slot it belongs to. Held rather than asked for per run: the addresses
    --- are the only thing the device half hands over, and they change only
    --- when the slot rotates.
    _instances: loader.CArray
    _bounds: loader.CArray
    _slot: integer

    _whiteU0: number
    _whiteV0: number
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
    --- inside a query iteration: see `syncInstances`.
    _missingImage: integer
end

local ExtractorMT <const>: metatable<Extractor> = {__index = Extractor}

--- Builds an extractor. Nothing here needs a device.
function Extractor.create(options: ExtractorOptions): Extractor
    local self = setmetatable({} as Extractor, ExtractorMT)
    self.camera = Camera.newCamera()
    self.capacity = options.capacity
    self._extractSeconds = 0.0
    self._alpha = 1.0
    self._lastAlpha = 1.0
    self._producers = {}
    self._producerRuns = {}
    self._producerBase = {}
    self._runs = {}
    self._seen = {}
    self._reserve = options.reserveRuns == true
    self._high = 0
    self._slot = 0
    self._whiteU0 = options.whiteU0
    self._whiteV0 = options.whiteV0
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
function Extractor:setStaging(slot: integer, instances: loader.CArray, bounds: loader.CArray)
    self._slot = slot
    self._instances = instances
    self._bounds = bounds
end

local function missingImageMessage(image: integer): string
    local name = components.imageName(image)
    if name == nil then
        return "tecs: a Sprite names no image; build one with " .. "Renderer:registerImage or Renderer:sprite"
    end
    return ("tecs: no image is registered as '%s'"):format(name)
end

--- Texture-array layer the given image name index resolves to.
---
--- Fails on a name nothing was registered under. A sprite naming an image the
--- renderer has never seen has no layer to sample, and every layer that does
--- exist holds some other image, so there is nothing to fall back to that is
--- not a wrong picture on the quad.
local function slotOf(self: Extractor, image: integer): integer
    local slot = self._slotByImage[image]
    if slot ~= nil then
        return slot
    end
    error(missingImageMessage(image), 2)
end

--- Whether archetype runs are laid out with room to grow.
---
--- What a caller does with the answer is diagnose a layout: a scene that
--- expected reservations and did not get them sized its capacity too tightly
--- to leave anything to reserve out of, which looks like the setting being
--- ignored rather than the buffer being full.
function Extractor:reservesRuns(): boolean
    return self._reserve
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
function Extractor:sprite(name: string, u0?: number, v0?: number, u1?: number, v1?: number): components.Sprite
    local image = components.imageId(name)
    local slot = slotOf(self, image)
    local region = self._regionByImage[image]
    -- Fractions of the image mapped into the rectangle the image occupies,
    -- which is a sub-rect of the cell and starts wherever the packer put it.
    local spanU <const> = region.u1 - region.u0
    local spanV <const> = region.v1 - region.v0
    return components.Sprite(
        image,
        region.u0 + (u0 or 0.0) * spanU,
        region.v0 + (v0 or 0.0) * spanV,
        region.u0 + (u1 or 1.0) * spanU,
        region.v0 + (v1 or 1.0) * spanV,
        slot
    )
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
local function writeRun(
    self: Extractor, packet: FramePacket, archetype: ecs.Archetype, length: integer, offset: integer
)
    local floats = self._instances
    local bounds = self._bounds
    -- Rows in this run whose tint asks for blending. Counted here rather than
    -- derived later because the sign that carries it is written here, so the
    -- count and the lane are right together or wrong together.
    local blended = 0
    local transforms = archetype:get(Transform)
    local tints = archetype:get(components.Tint)
    local sprites = archetype:get(components.Sprite)
    local materialColumn = archetype:get(components.Material)
    -- Absent on every archetype that clips nothing, which is the common case:
    -- the rows below then write the texture-array layer on its own and the
    -- fragments they produce never look at the region table.
    local clips = archetype:get(components.Clip)
    -- Absent on every archetype that turns about its middle, which is most of
    -- them: the rows below then draw the quad centerd on the entity.
    local pivots = archetype:get(Pivot)
    -- Which of the two casting roles this archetype is, decided once for the
    -- run because the columns are per archetype: an entity either carries the
    -- component or it is in a different archetype. Only the height and whether
    -- a row is blended are left per row.
    --
    -- An occluder before a drop-shadow caster, because an entity carrying both
    -- has asked for the one that changes what a light does, and taking the
    -- other would unblock the light without saying so.
    local casts = archetype:get(components.Occluder)
    local castSignX = 1.0
    if casts == nil then
        -- Read as the other column because the only field either carries is
        -- the same height at the same offset, and the rows below want one
        -- name for it rather than a branch per row over which of the two the
        -- run turned out to be.
        casts = archetype:get(components.DropShadow) as {components.Occluder}
        castSignX = -1.0
    end
    -- Loop invariant: an archetype either carries the previous transform or it
    -- does not, so an entity that is not interpolated costs one test per run
    -- rather than anything per row.
    local previous = archetype:get(components.PreviousTransform)
    local alpha <const> = self._alpha

    -- What the layer decides, resolved when the layer changes rather than
    -- once a row. A layer is a Transform field and so a row's own, but an
    -- archetype is a set of components and a game moves whole archetypes
    -- between layers rather than single rows: a run almost always resolves
    -- this once and the rows after it pay one comparison.
    local bandLayer = NO_LAYER
    local bandBase = 0.0
    local bandSort = 0
    local bandCulled = true

    for row = 1, length do
        local transform = transforms[row]
        local tint = tints[row]

        local layer = 0.0
        local u0, v0 = self._whiteU0, self._whiteV0
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
                    -- runs inside a query iteration, and an error thrown out
                    -- of one leaves the world deferred, which silently queues
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

        -- Blending wins over casting, so a translucent row in a caster's
        -- archetype is drawn forward and casts nothing. The two are exclusive
        -- in the bound's signs, and a silhouette of something the G-buffer
        -- never saw is the half of the pair that would be a lie.
        local blend <const> = tint.a < 1.0
        local casting <const> = casts ~= nil and not blend

        -- The clip region rides above the layer in one float, and a caster's
        -- height above that. Region zero and height zero pack to the layer
        -- unchanged, so an archetype with neither column writes exactly what
        -- it wrote before either existed.
        local clip = 0
        if clips ~= nil then
            clip = clips[row].index as integer
        end
        local packedSlot = layer
        if casting then
            local height = casts[row].height
            if height < 0.0 then
                height = 0.0
            elseif height > 1.0 then
                height = 1.0
            end
            packedSlot = packSlot(clip, layer, floor(height * TOP_STEP + 0.5))
        elseif clip ~= 0 then
            packedSlot = packSlot(clip, layer)
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
        if entityLayer ~= bandLayer then
            bandLayer = entityLayer
            bandBase, bandSort = layers.bandOf(entityLayer)
            bandCulled = layers.viewCulled(entityLayer)
        end

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

        -- Where the quad's middle goes. Without a pivot that is the entity's
        -- own position. With one the middle moves so that the point the pivot
        -- names lands on the position instead, which is what makes the basis
        -- turn and scale the quad about the pivot rather than about its
        -- middle.
        --
        -- Folded in here rather than sent to the shader because it is an
        -- affine shift of the very basis the vertex applies: moving the middle
        -- by -basis * pivot is the same geometry as offsetting every corner by
        -- -pivot, vertex for vertex. Sending it instead would need a fifth
        -- vec4 in the instance, which is sixteen more bytes streamed for every
        -- instance in the world to say something almost none of them have
        -- anything to say about.
        local centerX = originX
        local centerY = originY
        -- What the bound has to cover beyond the quad itself, which is nothing
        -- unless a pivot follows a slice that moves between frames. Playback on
        -- the GPU resolves the frame after this is written, so the shader can
        -- offset the quad by up to the slice's travel and the bound is grown by
        -- exactly that. Zero for a pivot written directly and for a slice with
        -- one key, and the bound is then bit for bit what it always was.
        local growX = 0.0
        local growY = 0.0
        if pivots ~= nil then
            local pivot = pivots[row]
            -- Quad-local units, where the quad's corners run -0.5 to 0.5 and
            -- the fraction runs from the frame's top left. Both axes measure
            -- the same way, because the vertex shader reads the frame's UV
            -- straight off the corner.
            local px <const> = pivot.x - 0.5
            local py <const> = pivot.y - 0.5
            local halfX <const> = pivot.halfX
            local halfY <const> = pivot.halfY
            if halfX ~= 0.0 or halfY ~= 0.0 then
                -- The travel is a fraction of the frame, so it scales with the
                -- quad and turns with it. `extentOf` covers a box of that size
                -- at this rotation, which is exactly the travel unturned and
                -- conservative in the safe direction turned.
                growX, growY = extentOf(angle, halfX * 2.0 * scaleX, halfY * 2.0 * scaleY)
            end
            if angle == 0.0 then
                centerX = originX - px * scaleX
                centerY = originY - py * scaleY
            else
                -- The same basis `instance.vert.glsl` builds, column major:
                -- the columns are (c * scaleX, s * scaleX) and
                -- (-s * scaleY, c * scaleY).
                local c <const> = cos(angle)
                local s <const> = sin(angle)
                centerX = originX - (c * scaleX * px - s * scaleY * py)
                centerY = originY - (s * scaleX * px + c * scaleY * py)
            end
        end

        local base = (offset + row - 1) * INSTANCE_FLOATS
        floats[base] = angle
        floats[base + 1] = scaleX
        floats[base + 2] = scaleY
        -- The band this entity's layer owns, and where in it the sort mode
        -- puts it. Zero is nearest, so a higher layer resolves to a smaller
        -- value and covers everything below it whatever the two contain.
        --
        -- Sorted on the entity's position rather than on the quad's middle,
        -- which is the whole reason a pivot at the feet is worth having: two
        -- characters standing on the same line sort together however tall
        -- either drawing is.
        floats[base + 3] = layers.depthIn(bandBase, bandSort, transform.z, originX, originY)

        floats[base + 4] = centerX
        floats[base + 5] = centerY
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
        if not bandCulled then
            -- The layer draws its contents somewhere the view rectangle does
            -- not describe, so a world bound would cull what is on screen. A
            -- bound no view can be outside of hands the decision to the layer.
            ex = UNBOUNDED
            ey = UNBOUNDED
        else
            ex, ey = extentOf(angle, scaleX, scaleY)
            ex = ex + growX
            ey = ey + growY
        end

        -- Centerd on the quad and not on the entity, because the extents
        -- above are half extents about the quad's middle. A pivot moves the
        -- geometry within its bound, so the bound moves with it and stays
        -- exactly as big as it was: growing it instead would keep offscreen
        -- instances alive for every pivoted entity in the world to cover a
        -- shift that is already known here. A slice that moves between frames
        -- is the one case where the shift is not known here, and only that case
        -- pays for it, in `growX` and `growY` above.
        local bound = (offset + row - 1) * BOUND_FLOATS
        bounds[bound] = centerX
        bounds[bound + 1] = centerY
        -- A half extent is a length and its sign carries nothing, so the two
        -- signs together are what tell the cull which of the four lanes a row
        -- belongs in. The cull takes the magnitudes for the view test and the
        -- signs for the lane, so a lane costs no fetch of its own: the mark
        -- pass already reads this bound and deliberately never touches the
        -- 64-byte instance.
        if blend then
            bounds[bound + 2] = -ex
            bounds[bound + 3] = ey
            blended = blended + 1
        elseif casting then
            bounds[bound + 2] = ex * castSignX
            bounds[bound + 3] = -ey
        else
            bounds[bound + 2] = ex
            bounds[bound + 3] = ey
        end
    end

    packet.blendCount = packet.blendCount + blended
    packet.instanceRanges:mark(offset * INSTANCE_BYTES, length * INSTANCE_BYTES)
    packet.boundsRanges:mark(offset * BOUND_BYTES, length * BOUND_BYTES)
end

--- Marks the bytes a run of instances occupies, in both range lists.
local function markRun(packet: FramePacket, offset: integer, count: integer)
    if count <= 0 then
        return
    end
    packet.instanceRanges:mark(offset * INSTANCE_BYTES, count * INSTANCE_BYTES)
    packet.boundsRanges:mark(offset * BOUND_BYTES, count * BOUND_BYTES)
end

--- Puts `count` slots from `offset` where no view can see them.
---
--- The same treatment a producer gives a slot it holds and is not drawing:
--- the instance zeroed, the depth parked at the back of its band so nothing
--- that reached the draw could occlude, and a cull bound out where no finite
--- view overlaps it. The mark pass rejects it on that bound, so a hidden slot
--- costs a bounds read and a scan lane and never reaches the draw.
local function hideRun(self: Extractor, packet: FramePacket, offset: integer, count: integer)
    if count <= 0 then
        return
    end
    local floats = self._instances
    local bounds = self._bounds
    -- Two things below are safe because a zero is positive, not because it is
    -- zero, and neither survives being written any other way.
    --
    -- The region's first float is the playback sentinel: `isPlayback` in
    -- assets/shaders/include/playback.glsl takes a negative one as "this
    -- carries a playback", so a zeroed region decodes as a static instance
    -- with a degenerate rect and resolves nothing against the frame table. The
    -- geometry pass and the shadow pass both resolve one and the particle
    -- simulate pass writes the same encoding from compute, so this is no
    -- longer one shader's business.
    --
    -- A half extent's sign bit is the caster flag `cullNegativeW` in
    -- assets/shaders/include/cull.glsl reads. The drop-shadow lane claims a
    -- conservative fan-out per caster in the mark pass, before anything looks
    -- at where the bound is, so a hidden slot must read as no caster on the
    -- sign alone.
    for slot = offset, offset + count - 1 do
        local base = slot * INSTANCE_FLOATS
        for index = 0, INSTANCE_FLOATS - 1 do
            floats[base + index] = 0.0
        end
        floats[base + 3] = HIDDEN_DEPTH

        local bound = slot * BOUND_FLOATS
        bounds[bound] = HIDDEN
        bounds[bound + 1] = HIDDEN
        bounds[bound + 2] = 0.0
        bounds[bound + 3] = 0.0
    end
    markRun(packet, offset, count)
end

--- A fresh run for an archetype nothing has laid out yet.
local function newRun(): Run
    return {
        offset = 0,
        length = 0,
        capacity = 0,
        pending = 0,
        moved = false,
        grown = false,
    }
end

--- Slots a run of this length is given under a reservation, its room to grow
--- included. `RESERVE_NONE` is what a packed layout would give it.
local function reservedIn(reserve: integer, length: integer, grown: boolean): integer
    if reserve == RESERVE_NONE then
        return length
    end
    if reserve == RESERVE_FLOOR or not grown then
        return length + MIN_SLACK
    end
    local slack = floor(length * SLACK_RATIO)
    if slack < MIN_SLACK then
        slack = MIN_SLACK
    end
    return length + slack
end

--- Slots a run of this length is given, its room to grow included.
local function reservedFor(length: integer, grown: boolean): integer
    return reservedIn(RESERVE_FULL, length, grown)
end

--- Puts a run at the end of the extent, with room to grow into.
---
--- The slack is opportunistic: what does not fit is not reserved and a run
--- that does not fit at all is truncated, so reserving never drops a row a
--- packed layout would have kept.
local function allocateRun(self: Extractor, run: Run, length: integer)
    local high <const> = self._high
    local want = reservedFor(length, run.grown)
    local room <const> = self.capacity - high
    if want > room then
        want = room
    end
    if want < 0 then
        want = 0
    end
    run.offset = high
    run.capacity = want
    run.moved = true
    self._high = high + want
end

--- Finds a run that outgrew its reservation somewhere it fits.
---
--- Extended where it stands when it is already the last run, which is what a
--- scene with one growing archetype does, and moved to the end otherwise. The
--- slots a move leaves behind stay inside the extent the cull walks until a
--- compaction reclaims them, so they are hidden on the way out.
local function growRun(self: Extractor, packet: FramePacket, run: Run, length: integer)
    if run.offset + run.capacity == self._high then
        local want = reservedFor(length, true)
        local room <const> = self.capacity - run.offset
        if want > room then
            want = room
        end
        run.capacity = want
        run.moved = true
        self._high = run.offset + want
        return
    end
    hideRun(self, packet, run.offset, run.capacity)
    allocateRun(self, run, length)
end

--- Lays every run out again from zero, reclaiming what growth left behind.
---
--- Every run moves, so this is the full-scene rewrite the reservation exists
--- to avoid. What keeps it from happening every frame is the trigger, not the
--- policy: see `layoutReserved`.
---
--- The reservation it lays out with is the widest one the buffer affords, and
--- the last of the three is what a packed layout does. That is the whole of
--- the interaction between reserving and `capacity`: room to grow is what is
--- left over after the rows, never taken from them, so a world sized to fit
--- exactly still fits exactly and drops exactly what it dropped.
local function compactRuns(self: Extractor)
    local runs <const> = self._runs
    local seen <const> = self._seen
    local capacity <const> = self.capacity

    local reserve = RESERVE_FULL
    while reserve > RESERVE_NONE do
        local total = 0
        for archetype, length in pairs(seen) do
            local run = runs[archetype]
            total = total + reservedIn(reserve, length, run ~= nil and run.grown)
        end
        if total <= capacity then
            break
        end
        reserve = reserve - 1
    end

    local offset = 0
    for archetype, length in pairs(seen) do
        local run = runs[archetype]
        if run == nil then
            run = newRun()
            runs[archetype] = run
        end
        local want = reservedIn(reserve, length, run.grown)
        local room <const> = capacity - offset
        if want > room then
            want = room
        end
        if want < 0 then
            want = 0
        end
        run.offset = offset
        run.capacity = want
        run.moved = true
        offset = offset + want
    end
    self._high = offset
end

--- Lays the archetypes out end to end, in query order.
---
--- Returns the slots the runs cover, the rows past the ceiling, and whether
--- the layout moved. A run cannot grow without shifting its neighbors, so any
--- length or offset that changed rewrites every run this sync.
local function layoutPacked(self: Extractor): integer, integer, boolean
    local runs <const> = self._runs
    local seen <const> = self._seen
    local capacity <const> = self.capacity

    local total = 0
    local relayout = false
    for archetype, length in self._renderables:iter() do
        seen[archetype] = length
        local run = runs[archetype]
        if run == nil then
            run = newRun()
            runs[archetype] = run
            relayout = true
        elseif run.length ~= length or run.offset ~= total then
            relayout = true
        end

        local placed = length
        local room <const> = capacity - total
        if placed > room then
            placed = room
        end
        if placed < 0 then
            placed = 0
        end
        run.offset = total
        run.capacity = placed
        run.pending = placed
        total = total + length
    end

    -- An archetype that went away leaves a hole, so the layout must move.
    for archetype in pairs(runs) do
        if seen[archetype] == nil then
            runs[archetype] = nil
            relayout = true
        end
    end

    if total > capacity then
        return capacity, total - capacity, relayout
    end
    return total, 0, relayout
end

--- Lays each archetype out in a run of its own, with room to grow.
---
--- A run that outgrows its reservation moves to the end of the extent rather
--- than shifting everything after it, so a spawn rewrites the archetype it
--- spawned into and leaves every other archetype resident. Nothing here
--- depends on the order the query hands archetypes over either, so an
--- archetype emptying and dropping out of that order costs nothing.
---
--- Compaction is what stops the extent drifting upwards for ever, and two
--- things ask for it: an allocation that no longer fits, and an extent far
--- enough above what a fresh layout would occupy to be worth the full rewrite.
--- The second is measured against the extent a compaction would actually
--- settle on, which is the widest of the three reservations that fits and not
--- always the widest one there is. That is what keeps a compaction from asking
--- for another one: the moment it runs the gap it triggers on is zero, and it
--- cannot open again until growth and shrinkage have put `RECLAIM_RATIO` of
--- that same layout back into it.
local function layoutReserved(self: Extractor, packet: FramePacket): integer, integer, boolean
    local runs <const> = self._runs
    local seen <const> = self._seen
    local capacity <const> = self.capacity

    -- What a compaction would produce at each of the three reservations, and
    -- what the runs that have outgrown their reservation want at the end of
    -- the extent. Only `RESERVE_FULL` needs a reservation worked out per run:
    -- `RESERVE_FLOOR` gives every run `MIN_SLACK` whatever it has grown into,
    -- and `RESERVE_NONE` gives it its rows, so both are sums this walk is
    -- already in a position to take. Picking the tier from a walk of its own
    -- would cost one per tier every frame and answer the same thing.
    local widest = 0
    local rows = 0
    local count = 0
    local needed = 0
    for archetype, length in self._renderables:iter() do
        seen[archetype] = length
        local run = runs[archetype]
        if run ~= nil and length > run.capacity then
            -- Outgrowing a reservation is what earns the next one, and it is
            -- settled here so a compaction lays the run out with the room it
            -- has just been shown to need.
            run.grown = true
        end
        local reserved <const> = reservedFor(length, run ~= nil and run.grown)
        widest = widest + reserved
        rows = rows + length
        count = count + 1
        if run == nil or length > run.capacity then
            needed = needed + reserved
        end
    end

    -- The same walk `compactRuns` makes, over the totals above rather than
    -- over the runs: widest first, and the first that fits is the one it would
    -- lay out with.
    local settled = widest
    if settled > capacity then
        settled = rows + count * MIN_SLACK
    end
    if settled > capacity then
        settled = rows
    end
    if settled > capacity then
        -- Rows alone that do not fit are truncated at the ceiling, which is
        -- where a compaction leaves the extent.
        settled = capacity
    end

    local high <const> = self._high
    local waste <const> = high - settled
    local compacting <const> = high + needed > capacity or (waste > settled * RECLAIM_RATIO and waste > MIN_RECLAIM)

    for archetype, run in pairs(runs) do
        if seen[archetype] == nil then
            -- The slots stay inside the extent the cull walks until something
            -- reclaims them, so an archetype that went away has to stop
            -- drawing on its own.
            if not compacting then
                hideRun(self, packet, run.offset, run.capacity)
            end
            runs[archetype] = nil
        end
    end

    if compacting then
        compactRuns(self)
    end

    local dropped = 0
    for archetype, length in pairs(seen) do
        local run = runs[archetype]
        if run == nil then
            run = newRun()
            runs[archetype] = run
            allocateRun(self, run, length)
        elseif length > run.capacity then
            growRun(self, packet, run, length)
        end

        local pending = length
        if pending > run.capacity then
            pending = run.capacity
        end
        run.pending = pending
        dropped = dropped + (length - pending)
    end

    return self._high, dropped, false
end

--- Rewrites only what changed.
---
--- Which runs can be left alone is the layout's answer: packed, a length that
--- moved rewrites everything, and reserved, it rewrites the run it moved.
--- Short of that, an archetype whose Transform, Tint, and Sprite columns are
--- all clean is skipped entirely: its bytes are already resident and correct.
local function syncInstances(self: Extractor, packet: FramePacket)
    local runs = self._runs
    local seen = self._seen
    for archetype in pairs(seen) do
        seen[archetype] = nil
    end

    local reserve <const> = self._reserve
    local total, dropped, relayout: integer, integer, boolean
    if reserve then
        total, dropped, relayout = layoutReserved(self, packet)
    else
        total, dropped, relayout = layoutPacked(self)
    end

    -- Producers are laid out after the archetypes, in the order they were
    -- added. A producer whose count moved shifts everything after it, which is
    -- the same condition an archetype's length changing creates.
    local producerMoved = false
    local producers <const> = self._producers
    local producerRuns <const> = self._producerRuns
    local producerBase: {integer} = self._producerBase
    for index = 1, #producers do
        local count = producers[index]:count()
        producerBase[index] = total
        if producerRuns[index * 2 - 1] ~= total or producerRuns[index * 2] ~= count then
            -- Reserved, the archetypes are laid out where a producer cannot
            -- reach them, so a producer that moved rewrites the producers and
            -- nothing else.
            if reserve then
                producerMoved = true
            else
                relayout = true
            end
        end
        producerRuns[index * 2 - 1] = total
        producerRuns[index * 2] = count
        total = total + count
    end

    if total > self.capacity then
        dropped = dropped + (total - self.capacity)
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
    -- Runs to exhaustion, which is what `iter` requires and what makes it the
    -- right traversal: a cursor is allocated per call, and this is the frame
    -- path. Nothing below breaks or returns, an archetype the layout could not
    -- place is handled in the body rather than by leaving, and the one error
    -- this can raise is deferred to after the loop for exactly that reason.
    -- Adding an early exit here means going back to a cursor and closing it.
    for archetype, length in self._renderables:iter() do
        -- An archetype the layout above did not see has nowhere to be written,
        -- and one that lost rows since then would be written past its column.
        -- Both are the same structural change landing between the two walks,
        -- and both wait for the next sync, which lays the archetype out from
        -- what the world holds by then.
        local run = runs[archetype] or newRun()
        local pending = run.pending
        if pending > length then
            pending = length
        end
        -- Every component a row's instance is written from, so a change to any
        -- of them rewrites the run and one to nothing else leaves it standing.
        -- The two casting components are last because the chain short circuits:
        -- on an archetype something else already moved they are never asked,
        -- and a run being rewritten anyway carries the new height with it.
        local dirty = relayout
            or run.moved
            or run.length ~= pending
            or archetype:isComponentDirty(Transform)
            or archetype:isComponentDirty(components.Tint)
            or archetype:isComponentDirty(components.Sprite)
            or archetype:isComponentDirty(components.Material)
            or archetype:isComponentDirty(components.Clip)
            or archetype:isComponentDirty(Pivot)
            or archetype:isComponentDirty(components.Occluder)
            or archetype:isComponentDirty(components.DropShadow)
            or (interpolating and archetype:get(components.PreviousTransform) ~= nil)

        if dirty then
            writeRun(self, packet, archetype, pending, run.offset)
            rewritten = rewritten + pending
        end

        if reserve then
            -- Slots the run holds and is not drawing from. A run that moved
            -- landed on whatever the last tenant left there, so all of them
            -- are stale; one that stood still and shrank has only the rows it
            -- gave up to put out of sight.
            local stale <const> = run.moved and run.capacity or run.length
            if stale > pending then
                hideRun(self, packet, run.offset + pending, stale - pending)
            end
        end

        run.length = pending
        run.moved = false
    end

    -- A Sprite naming an image nothing registered is still an error: every
    -- layer that exists holds some other picture, so drawing one of those
    -- instead would turn a broken asset into an art bug nobody traces back.
    -- Raised here rather than where it is found, so it is only this frame's
    -- error: the loop above has finished and the world is whole, and a caller
    -- that catches this can register the image and draw again.
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
                if count < 0 then
                    count = 0
                end
            end

            local ranges = producer:takeDirty()
            if (relayout or producerMoved) and count > 0 then
                producer:write(floats, bounds, base, 1, count)
                markRun(packet, base, count)
                rewritten = rewritten + count
            else
                for entry = 1, #ranges, 2 do
                    local first = ranges[entry]
                    local last = ranges[entry + 1]
                    if last > count then
                        last = count
                    end
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
        local transforms = archetype:get(Transform)
        local sources = archetype:get(components.PointLight)
        for row = 1, length do
            local transform = transforms[row]
            local source = sources[row]
            packet:addLight(
                transform.x, transform.y, source.height, source.radius, source.r, source.g, source.b, source.intensity
            )
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
    if self._alpha > 1.0 then
        self._alpha = 1.0
    end

    -- Read once and carried, so every pass drawing this frame resolves an
    -- animation against the same step. Whole steps rather than seconds, which
    -- is what keeps playback on the simulation's clock rather than the frame's.
    packet.stepClock = self._world:fixedStepCount()

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
function Extractor:install(world: types.World, packet: FramePacket, published: function())
    self._world = world

    -- Snapshotting before anything in the step moves is what makes the pair a
    -- pair: taken later, the two would be the same value and every frame would
    -- draw the entity where the step left it.
    local interpolated = world:query({
        include = {Transform, components.PreviousTransform},
    })
    world:addSystem({
        name = "tecs.SnapshotTransforms",
        phase = ecs.phases.FixedFirst,
        run = function()
            for archetype, length in interpolated:iter() do
                local transforms = archetype:get(Transform)
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
        include = {Transform, components.Tint, components.Renderable},
    })
    self._lightSources = world:query({
        include = {Transform, components.PointLight},
    })

    world:addSystem({
        name = "tecs.SyncRenderState",
        phase = ecs.phases.RenderFirst,
        run = function()
            self:extract(packet)
            if published ~= nil then
                published()
            end
        end,
    })
end

--- Seconds the last extraction took, or zero when nothing is being measured.
function Extractor:extractSeconds(): number
    return self._extractSeconds or 0.0
end

return Extractor
