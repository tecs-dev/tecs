--- Animation frame tables, in the shape a shader reads them.
---
--- Playback on the GPU means the instance stops carrying a resolved region and
--- starts carrying enough to compute one: which animation is playing, when it
--- started, and how fast it runs. The regions themselves move here, once,
--- shared by every entity playing the same thing.
---
--- What a playback is: one sheet, one tag and one slice, registered together
--- and given an index. A thousand entities walking the same cycle share one,
--- for the reason they already share one sheet. Speed is deliberately not part
--- of the key: it rides the instance, so two entities playing one tag at two
--- speeds are one registration and not two tables.
---
--- The slice is part of the key because a pivot follows the slice it names and
--- a slice moves from frame to frame. What the entry carries is the offset from
--- the middle of where the slice goes over the cycle, so two playbacks of one
--- tag bound to two slices want different offsets for the same frame. A slice
--- with a single key, and no slice at all, both give an offset of zero on every
--- frame, which is the overwhelming majority and costs the same as before.
---
--- The table is three regions of one buffer, all floats:
---
---   directory   four per playback: where its entries and ticks are, how many
---               ticks its cycle runs for, and how many steps it visits
---   ticks       one per millisecond of the cycle, holding the offset of the
---               entry in force at that millisecond
---   entries     eight per step of the cycle: the region, the array layer, and
---               the pivot offset that step is drawn at
---
--- A millisecond is the resolution because a millisecond is the unit the model
--- is authored in: `Builder:frame` takes milliseconds and `sheet.fromAseprite`
--- passes the export's own durations through. Every boundary an artist can
--- write therefore lands on a tick boundary, so the table reproduces
--- `Sheet:frameAt` exactly rather than approximately, and `frametable.frameAt`
--- is here so a spec can hold the two to that.
---
--- A lookup is then constant time whatever the tag holds: one directory read,
--- one tick read, one entry read. A scan of cumulative durations would cost the
--- length of the tag, and it would cost it in the vertex shader, once per
--- vertex, for every pass that draws the sprite.
---
--- Everything here is floats, including the offsets and counts, so nothing on
--- either side bit-casts. A float32 carries integers exactly to 16,777,216 and
--- every value written here is far below that.

local loader <const> = require("tecs.ffi.loader")
local components <const> = require("tecs.components")
local sheet <const> = require("tecs.gfx.sheet")

local type Sheet = sheet.Sheet
local type Sprite = components.Sprite

local floor <const> = math.floor

--- Ticks per second of clip time, which is milliseconds.
local TICK_HZ <const> = 1000.0

--- Floats per directory entry: entry base, tick base, tick count, step count.
local DIRECTORY_FLOATS <const> = 4

--- Floats per frame entry: u0, v0, u1, v1, array layer, pivot x, pivot y, and
--- one reserved. Reserved rather than trimmed: a slice generation would go in
--- the eighth if a caller ever needs to reject a layer that was reallocated
--- under it. Widening this later would mean rewriting an upload format already
--- in use.
local ENTRY_FLOATS <const> = 8

--- Where a quad sits when nothing names a point on it, which is its middle.
local CENTRE <const> = 0.5

--- One registered playback, on the host side.
local record Playback
    source: Sheet
    tag: integer
    --- Slice the pivot follows, or zero for a playback that moves none.
    slice: integer
    --- Sheet frame shown at each step of the cycle, which is `Sheet._order`
    --- with the direction already spent.
    order: {integer}
    --- Step in force at each tick, one-based into `order`.
    ticks: {integer}
    --- Pivot offset at each step of the cycle, as a fraction of the frame from
    --- the middle pivot below. Zero on every step unless the slice moves.
    pivotX: {number}
    pivotY: {number}
    --- The middle of the pivots the cycle visits, and half their travel. The
    --- middle is what an entity's `Pivot` carries and the host folds into the
    --- quad's origin; the travel is what the cull bound grows by.
    midX: number
    midY: number
    halfX: number
    halfY: number
    --- Offsets into the assembled buffer, filled in when it is assembled.
    entryBase: integer
    tickBase: integer
end

local record frametable
    --- Ticks per second of clip time.
    TICK_HZ: number
    DIRECTORY_FLOATS: integer
    ENTRY_FLOATS: integer

    --- Registers a sheet, tag and slice, or answers the index they have.
    ---
    --- Cheap to call repeatedly: the triple is cached, so the encode pass calls
    --- this per row without building anything after the first.
    --- @param source The sheet to play. Nil raises.
    --- @param tag A tag index from `Sheet:tagId`, or zero for the whole sheet.
    --- @param slice A slice index from `Sheet:sliceId` for a pivot that follows
    ---     it, or zero for a playback whose pivot does not move.
    --- @return The index an instance carries, counting from one.
    register: function(source: Sheet, tag: integer, slice?: integer): integer

    --- Where a playback's pivot sits and how far it travels.
    ---
    --- The middle is the point an entity's `Pivot` carries and extraction folds
    --- into the quad's origin, and the frame table holds each step's offset from
    --- it, so the two together place the quad exactly where a host that resolved
    --- the frame would have. The travel is half the range of those offsets,
    --- which is what the cull bound grows by and is zero for a slice that stays
    --- put.
    --- @param id An index from `register`. Anything else answers the middle of
    ---     the frame and no travel, which is where a quad naming no point sits.
    --- @return The middle pivot's x and y, then half its travel in each axis,
    ---     all as fractions of the frame.
    pivotOf: function(id: integer): number, number, number, number

    --- How many times the table has changed since the process started.
    ---
    --- Moves when a playback is registered and when any sheet is rebound, since
    --- a rebind moves every region this copied. Whoever uploads the buffer
    --- compares this against what it uploaded last rather than being told.
    revision: function(): integer

    --- The assembled buffer and how many floats of it are live.
    ---
    --- Assembled here rather than as playbacks arrive, because a registration
    --- moves everything after it and registrations come in bursts at load.
    --- @return The floats, then the count. The array is reused across calls and
    ---     is only valid until the next one that follows a revision change.
    floats: function(): loader.CArray, integer

    --- Whether a Sprite's region fields carry a playback rather than a region.
    ---
    --- A region is never negative: every one the engine produces comes from an
    --- image's rect scaled by a non-negative fraction. So the sign of `u0` is
    --- free, and it costs nothing to write because that field is written
    --- either way.
    isPlayback: function(target: Sprite): boolean

    --- The playback index a Sprite carries, or zero for a plain region.
    playbackOf: function(target: Sprite): integer

    --- Writes a playback into a Sprite's region fields.
    ---
    --- `rate` is clip ticks per fixed step, which is the fixed step in seconds
    --- times the entity's speed times `TICK_HZ`. Zero means held: `start` is
    --- then read as the tick to hold rather than as the step playback began on,
    --- which is what freezes an entity without stopping the world's clock.
    --- @param target The Sprite to write. Its other fields are left alone.
    --- @param id An index from `register`.
    --- @param start The fixed step playback began on, or the tick to hold.
    --- @param rate Clip ticks per fixed step, or zero to hold.
    --- @param loop Whether the cycle repeats rather than parking at its end.
    encode: function(target: Sprite, id: integer, start: number, rate: number, loop: boolean)

    --- Ticks one pass through a playback's cycle takes.
    --- @param id An index from `register`. Anything else answers zero.
    tickCount: function(id: integer): integer

    --- The sheet frame a playback shows at a tick.
    ---
    --- The host's half of what the shader does, and the reason it exists is
    --- that the two have to agree: `animation.frameOf` answers gameplay from
    --- here, and a spec walks every tick of every tag holding this to
    --- `Sheet:frameAt`.
    --- @param id An index from `register`.
    --- @param tick Ticks into the cycle. Outside it wraps or clamps by `loop`.
    --- @param loop Whether to wrap rather than clamp.
    --- @return A frame index into the whole sheet, counting from one.
    frameAt: function(id: integer, tick: number, loop: boolean): integer

    --- Forgets every registration. For tests, which build sheets per case.
    reset: function()
end

frametable.TICK_HZ = TICK_HZ
frametable.DIRECTORY_FLOATS = DIRECTORY_FLOATS
frametable.ENTRY_FLOATS = ENTRY_FLOATS

--- Registered playbacks, by index, and the pair each was registered under.
local playbacks: {Playback} = {}
local ids: {string: integer} = {}

--- Bumped by registration. Compared against the sheet registry's own revision
--- as well, so a rebind that moved every region is noticed without a sheet
--- having to know anything about this module.
local changes = 0
local sheetsAt = sheet.revision()

--- Whether a sheet's frames have moved since the last assembly.
---
--- A rebind moves regions and re-reading them costs a walk of the entries, which
--- happens on every assembly anyway. Overwriting a sheet in place can move the
--- steps of a cycle and how long each is held, and rebuilding a tick table costs
--- the length of the cycle, so that is done only when a sheet says it happened
--- rather than on every registration.
local framesMoved = false

--- The assembled buffer, the floats it holds, and what it was assembled from.
local buffer: loader.CArray = nil
local capacity = 0
local liveFloats = 0
local assembledAt = -1

function frametable.revision(): integer
    local current <const> = sheet.revision()
    if current ~= sheetsAt then
        sheetsAt = current
        framesMoved = true
        changes = changes + 1
    end
    return changes
end

--- Which step of a cycle is in force at a time, one-based.
---
--- The same scan `Sheet:frameAt` runs, answering the step rather than the frame
--- it shows. Run once per tick when a playback is registered and never again.
local function stepAt(timing: {number}, steps: integer, time: number): integer
    for step = 1, steps do
        if time <= timing[step] then
            return step
        end
    end
    return steps
end

--- Works out where a playback's pivot sits at each step of its cycle.
---
--- What an entry carries is an offset from the middle of the pivots the cycle
--- visits rather than the pivot itself, and the reason is the cull bound. The
--- host folds the middle into the quad's origin as it always did and grows the
--- bound by the travel, so a slice that stays put has an offset of zero on
--- every step, folds exactly as before, and keeps a bound that is exact.
---
--- Run when the playback is registered and again whenever a sheet's frames
--- move, since a re-export can move the slice a playback follows.
local function resolvePivots(playback: Playback)
    local order <const> = playback.order
    local steps <const> = #order
    local pivotX <const> = playback.pivotX
    local pivotY <const> = playback.pivotY
    local slice <const> = playback.slice

    if slice < 1 then
        playback.midX, playback.midY = CENTRE, CENTRE
        playback.halfX, playback.halfY = 0.0, 0.0
        for step = 1, steps do
            pivotX[step], pivotY[step] = 0.0, 0.0
        end
        return
    end

    local source <const> = playback.source
    local minX, maxX = math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge
    for step = 1, steps do
        local x <const>, y <const> = source:pivotOf(slice, order[step])
        pivotX[step], pivotY[step] = x, y
        if x < minX then
            minX = x
        end
        if x > maxX then
            maxX = x
        end
        if y < minY then
            minY = y
        end
        if y > maxY then
            maxY = y
        end
    end

    local midX <const> = (minX + maxX) * 0.5
    local midY <const> = (minY + maxY) * 0.5
    playback.midX, playback.midY = midX, midY
    playback.halfX = (maxX - minX) * 0.5
    playback.halfY = (maxY - minY) * 0.5
    for step = 1, steps do
        pivotX[step] = pivotX[step] - midX
        pivotY[step] = pivotY[step] - midY
    end
end

function frametable.pivotOf(id: integer): number, number, number, number
    local playback <const> = playbacks[id]
    if playback == nil then
        return CENTRE, CENTRE, 0.0, 0.0
    end
    -- Assembled on demand, because a rebind or a re-export can move the slice
    -- since this was registered and a caller asking where the pivot is wants
    -- the answer the shader is about to draw with.
    frametable.floats()
    return playback.midX, playback.midY, playback.halfX, playback.halfY
end

--- Reads a tag's steps and the step in force at each tick out of a sheet.
---
--- Ticks are sampled at the middle rather than at the edge. A boundary authored
--- in whole milliseconds then falls between two samples instead of on one, so
--- which side a tick lands on does not turn on a comparison against a value the
--- other side computed slightly differently.
local function planTicks(playback: Playback)
    local source <const> = playback.source
    local tag <const> = playback.tag
    local order <const> = source._order[tag]
    local timing <const> = source._timing[tag]
    local steps <const> = #order

    -- At least one tick, so a sheet of one instant frame still has somewhere to
    -- land rather than dividing into an empty table.
    local cycle <const> = source._cycle[tag] or 0.0
    local count = floor(cycle * TICK_HZ + 0.5)
    if count < 1 then
        count = 1
    end

    local ticks: {integer} = {}
    for tick = 0, count - 1 do
        ticks[tick + 1] = stepAt(timing, steps, (tick + 0.5) / TICK_HZ)
    end

    playback.order = order
    playback.ticks = ticks
end

function frametable.register(source: Sheet, tag: integer, slice?: integer): integer
    if source == nil then
        error("tecs: a playback needs a sheet", 2)
    end
    tag = tag or 0
    slice = slice or 0

    local key <const> = source.id .. ":" .. tag .. ":" .. slice
    local existing <const> = ids[key]
    if existing ~= nil then
        return existing
    end

    if source._order[tag] == nil then
        error(("tecs: sheet '%s' has no tag %d"):format(source.name, tag), 2)
    end

    local id <const> = #playbacks + 1
    local playback <const>: Playback = {
        source = source,
        tag = tag,
        slice = slice,
        order = nil,
        ticks = nil,
        pivotX = {},
        pivotY = {},
        midX = CENTRE,
        midY = CENTRE,
        halfX = 0.0,
        halfY = 0.0,
        entryBase = 0,
        tickBase = 0,
    }
    planTicks(playback)
    resolvePivots(playback)
    playbacks[id] = playback
    ids[key] = id
    changes = changes + 1
    return id
end

function frametable.tickCount(id: integer): integer
    local playback <const> = playbacks[id]
    if playback == nil then
        return 0
    end
    return #playback.ticks
end

function frametable.frameAt(id: integer, tick: number, loop: boolean): integer
    local playback <const> = playbacks[id]
    if playback == nil then
        return 1
    end
    local ticks <const> = playback.ticks
    local count <const> = #ticks

    local at: number
    if loop then
        at = tick % count
    else
        at = tick
        if at < 0.0 then
            at = 0.0
        end
        if at > count - 1 then
            at = count - 1
        end
    end

    local index = floor(at) + 1
    if index < 1 then
        index = 1
    end
    if index > count then
        index = count
    end
    return playback.order[ticks[index]]
end

-------------------------------------------------------------------------------
-- The encoding an instance carries
-------------------------------------------------------------------------------

function frametable.isPlayback(target: Sprite): boolean
    return target.u0 < 0.0
end

function frametable.playbackOf(target: Sprite): integer
    if target.u0 >= 0.0 then
        return 0
    end
    return floor(-target.u0 + 0.5)
end

function frametable.encode(target: Sprite, id: integer, start: number, rate: number, loop: boolean)
    target.u0 = -id
    target.v0 = start
    target.u1 = rate
    target.v1 = loop and 1.0 or 0.0
end

-------------------------------------------------------------------------------
-- Assembly
-------------------------------------------------------------------------------

--- Writes one playback's frame entries and hands back where they went.
local function writeEntries(data: loader.CArray, at: integer, playback: Playback): integer
    local source <const> = playback.source
    local uvs <const> = source._uvs
    local layer <const> = source._slot
    local order <const> = playback.order
    local pivotX <const> = playback.pivotX
    local pivotY <const> = playback.pivotY

    for step = 1, #order do
        local frame <const> = order[step]
        local from <const> = (frame - 1) * 4
        local base <const> = at + (step - 1) * ENTRY_FLOATS
        data[base] = uvs[from + 1]
        data[base + 1] = uvs[from + 2]
        data[base + 2] = uvs[from + 3]
        data[base + 3] = uvs[from + 4]
        -- Negative for a sheet bound to no image, which is what a sheet says
        -- before a renderer has given it one. The shader then keeps whatever
        -- layer the instance already carried, so an unbound sheet animates its
        -- region and leaves the picture alone exactly as it does on the host.
        data[base + 4] = layer
        -- How far this step's pivot sits from the middle the entity's `Pivot`
        -- carries, in fractions of the frame, which is the same units the
        -- quad's corners run in. Zero for a slice that stays put and for a
        -- playback that follows none, so the shader adds nothing and the quad
        -- lands where the host's fold alone would have put it.
        data[base + 5] = pivotX[step]
        data[base + 6] = pivotY[step]
        data[base + 7] = 0.0
    end

    return at + #order * ENTRY_FLOATS
end

--- Lays the three regions out and writes them.
local function assemble()
    local count <const> = #playbacks

    if framesMoved then
        -- A sheet was bound or overwritten in place. Binding moves regions,
        -- which the entry walk below re-reads whatever happens; overwriting can
        -- change how long a frame is held and how many steps a cycle runs for,
        -- and only a fresh tick table says the new answer.
        framesMoved = false
        for id = 1, count do
            planTicks(playbacks[id])
        end
    end

    local total = count * DIRECTORY_FLOATS
    for id = 1, count do
        local playback <const> = playbacks[id]
        total = total + #playback.ticks + #playback.order * ENTRY_FLOATS
    end
    if total < 1 then
        total = 1
    end

    if total > capacity then
        -- Grown in one go rather than per registration, and never while a frame
        -- is in flight: this runs on the host, and whoever uploads it does so
        -- between frames.
        capacity = total * 2
        buffer = loader.newArray("float[?]", capacity)
    end

    local data <const> = buffer
    local at = count * DIRECTORY_FLOATS

    -- Ticks first, then entries, so a playback's two regions are laid out in
    -- the order the shader reads them.
    for id = 1, count do
        local playback <const> = playbacks[id]
        playback.tickBase = at
        at = at + #playback.ticks
    end
    for id = 1, count do
        local playback <const> = playbacks[id]
        playback.entryBase = at
        -- Resolved again rather than trusted from registration, because this
        -- runs on every revision and a revision is a sheet's frames having
        -- moved. A re-export can move the slice a playback follows, and the
        -- offsets and the travel both have to follow it.
        resolvePivots(playback)
        at = writeEntries(data, at, playback)
    end

    for id = 1, count do
        local playback <const> = playbacks[id]
        local base <const> = (id - 1) * DIRECTORY_FLOATS
        data[base] = playback.entryBase
        data[base + 1] = playback.tickBase
        data[base + 2] = #playback.ticks
        data[base + 3] = #playback.order

        -- A tick holds the offset of the entry in force, absolute rather than
        -- an index into the playback's own entries, so the shader adds nothing
        -- to what it reads.
        local ticks <const> = playback.ticks
        local entryBase <const> = playback.entryBase
        local tickBase <const> = playback.tickBase
        for tick = 1, #ticks do
            data[tickBase + tick - 1] = entryBase + (ticks[tick] - 1) * ENTRY_FLOATS
        end
    end

    liveFloats = total
end

function frametable.floats(): loader.CArray, integer
    local current <const> = frametable.revision()
    if current ~= assembledAt then
        assembledAt = current
        assemble()
    end
    return buffer, liveFloats
end

function frametable.reset()
    playbacks = {}
    ids = {}
    changes = changes + 1
    framesMoved = false
    assembledAt = -1
    liveFloats = 0
end

return frametable
