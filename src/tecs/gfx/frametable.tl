--- Animation frame tables, in the shape a shader reads them.
---
--- Playback on the GPU means the instance stops carrying a resolved region and
--- starts carrying enough to compute one: which animation is playing, when it
--- started, and how fast it runs. The regions themselves move here, once,
--- shared by every entity playing the same thing.
---
--- What a playback is: one sheet, one tag, registered together and given an
--- index. A thousand entities walking the same cycle share one, for the reason
--- they already share one sheet. Speed is deliberately not part of the key: it
--- rides the instance, so two entities playing one tag at two speeds are one
--- registration and not two tables.
---
--- The table is three regions of one buffer, all floats:
---
---   directory   four per playback: where its entries and ticks are, how many
---               ticks its cycle runs for, and how many steps it visits
---   ticks       one per millisecond of the cycle, holding the offset of the
---               entry in force at that millisecond
---   entries     eight per step of the cycle: the region, the array layer, and
---               a pivot offset stage 2 fills in
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
--- one reserved. Reserved rather than trimmed: stage 2 writes the pivot, and a
--- slice generation would go in the eighth if a caller ever needs to reject a
--- layer that was reallocated under it. Widening this later would mean
--- rewriting an upload format already in use.
local ENTRY_FLOATS <const> = 8

--- One registered playback, on the host side.
local record Playback
    source: Sheet
    tag: integer
    --- Sheet frame shown at each step of the cycle, which is `Sheet._order`
    --- with the direction already spent.
    order: {integer}
    --- Step in force at each tick, one-based into `order`.
    ticks: {integer}
    --- Offsets into the assembled buffer, filled in when it is assembled.
    entryBase: integer
    tickBase: integer
end

local record frametable
    --- Ticks per second of clip time.
    TICK_HZ: number
    DIRECTORY_FLOATS: integer
    ENTRY_FLOATS: integer

    --- Registers a sheet and tag, or answers the index they already have.
    ---
    --- Cheap to call repeatedly: the pair is cached, so the encode pass calls
    --- this per row without building anything after the first.
    --- @param source The sheet to play. Nil raises.
    --- @param tag A tag index from `Sheet:tagId`, or zero for the whole sheet.
    --- @return The index an instance carries, counting from one.
    register: function(source: Sheet, tag: integer): integer

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
    encode: function(target: Sprite, id: integer, start: number, rate: number,
                     loop: boolean)

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

--- The assembled buffer, the floats it holds, and what it was assembled from.
local buffer: loader.CArray = nil
local capacity = 0
local liveFloats = 0
local assembledAt = -1

function frametable.revision(): integer
    local current <const> = sheet.revision()
    if current ~= sheetsAt then
        sheetsAt = current
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
        if time <= timing[step] then return step end
    end
    return steps
end

function frametable.register(source: Sheet, tag: integer): integer
    if source == nil then
        error("tecs: a playback needs a sheet", 2)
    end
    tag = tag or 0

    local key <const> = source.id .. ":" .. tag
    local existing <const> = ids[key]
    if existing ~= nil then return existing end

    local order <const> = source._order[tag]
    if order == nil then
        error(("tecs: sheet '%s' has no tag %d"):format(source.name, tag), 2)
    end
    local timing <const> = source._timing[tag]
    local steps <const> = #order

    -- At least one tick, so a sheet of one instant frame still has somewhere to
    -- land rather than dividing into an empty table.
    local cycle <const> = source._cycle[tag] or 0.0
    local count = floor(cycle * TICK_HZ + 0.5)
    if count < 1 then count = 1 end

    -- Sampled at the middle of each tick rather than its edge. A boundary
    -- authored in whole milliseconds then falls between two samples instead of
    -- on one, so which side a tick lands on does not turn on a comparison
    -- against a value the other side computed slightly differently.
    local ticks: {integer} = {}
    for tick = 0, count - 1 do
        ticks[tick + 1] = stepAt(timing, steps, (tick + 0.5) / TICK_HZ)
    end

    local id <const> = #playbacks + 1
    playbacks[id] = {
        source = source,
        tag = tag,
        order = order,
        ticks = ticks,
        entryBase = 0,
        tickBase = 0,
    }
    ids[key] = id
    changes = changes + 1
    return id
end

function frametable.tickCount(id: integer): integer
    local playback <const> = playbacks[id]
    if playback == nil then return 0 end
    return #playback.ticks
end

function frametable.frameAt(id: integer, tick: number, loop: boolean): integer
    local playback <const> = playbacks[id]
    if playback == nil then return 1 end
    local ticks <const> = playback.ticks
    local count <const> = #ticks

    local at: number
    if loop then
        at = tick % count
    else
        at = tick
        if at < 0.0 then at = 0.0 end
        if at > count - 1 then at = count - 1 end
    end

    local index = floor(at) + 1
    if index < 1 then index = 1 end
    if index > count then index = count end
    return playback.order[ticks[index]]
end

-------------------------------------------------------------------------------
-- The encoding an instance carries
-------------------------------------------------------------------------------

function frametable.isPlayback(target: Sprite): boolean
    return target.u0 < 0.0
end

function frametable.playbackOf(target: Sprite): integer
    if target.u0 >= 0.0 then return 0 end
    return floor(-target.u0 + 0.5)
end

function frametable.encode(target: Sprite, id: integer, start: number,
                           rate: number, loop: boolean)
    target.u0 = -id
    target.v0 = start
    target.u1 = rate
    target.v1 = loop and 1.0 or 0.0
end

-------------------------------------------------------------------------------
-- Assembly
-------------------------------------------------------------------------------

--- Writes one playback's frame entries and hands back where they went.
local function writeEntries(data: loader.CArray, at: integer,
                            playback: Playback): integer
    local source <const> = playback.source
    local uvs <const> = source._uvs
    local layer <const> = source._slot
    local order <const> = playback.order

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
        -- Stage 2 writes the pivot offset here. Zero is a pivot that does not
        -- move between frames, which is what the host already folded into the
        -- origin, so zero is also the correct value for every sheet today.
        data[base + 5] = 0.0
        data[base + 6] = 0.0
        data[base + 7] = 0.0
    end

    return at + #order * ENTRY_FLOATS
end

--- Lays the three regions out and writes them.
local function assemble()
    local count <const> = #playbacks

    local total = count * DIRECTORY_FLOATS
    for id = 1, count do
        local playback <const> = playbacks[id]
        total = total + #playback.ticks + #playback.order * ENTRY_FLOATS
    end
    if total < 1 then total = 1 end

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
            data[tickBase + tick - 1] =
                entryBase + (ticks[tick] - 1) * ENTRY_FLOATS
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
    assembledAt = -1
    liveFloats = 0
end

return frametable
