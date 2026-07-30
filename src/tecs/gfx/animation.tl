--[=[
Sprite sheets, fixed-step playback, Aseprite slices, pivots, and reloads.

A [`Sheet`](tealdoc:tecs.gfx.animation.Sheet) divides one image into frames and
names frame ranges with tags. An
[`Animation`](tealdoc:tecs.gfx.animation.Animation) selects a sheet tag and
carries speed, loop, and playback state.

```teal
local hero <const> = tecs.gfx.animation.grid({
    name = "hero",
    imageWidth = 256,
    imageHeight = 32,
    frameWidth = 32,
    frameHeight = 32,
    tags = {
        idle = {from = 1, to = 4},
        run = {from = 5, to = 8},
    },
})

hero:bind(app.renderer:sprite("hero.png"))
world:addPlugin(tecs.gfx.animation.plugin)

world:spawn(
    tecs.Transform(64, 64, 0, 1, 0, 32, 32),
    hero:sprite(),
    tecs.gfx.animation.of(hero, "run"),
    tecs.gfx.Renderable()
)
```

Playback advances in fixed steps. Machines that replay the same simulation
therefore select the same frames. `frameOf` and `timeOf` report playback on
the same fixed-step clock.

## Sheet sources

Use `grid` for uniform cells, `rects` for an explicit frame list, `build` for a
custom sheet, or `fromAseprite` for an Aseprite JSON export. Frames count from
one. Tags name inclusive frame spans and may play forward, reverse, or
ping-pong.

Bind a sheet to a renderer sprite before drawing it. Every entity playing that
sheet shares its frame and timing data.

## Slices and pivots

Aseprite slices may move between frames. A
[`Pivot`](tealdoc:tecs.gfx.animation.Pivot) bound to a slice follows that
movement, which keeps attachments such as hands, muzzles, and feet on the part
of the drawing they name.

## Reloads

Re-exporting a sheet under the same name can replace its frame, tag, slice, and
timing data in place. Existing entities retain the sheet id and continue from
their playback state. A replacement must preserve the bound image dimensions.
]=]
-- Implementation details:
-- A system encodes what each entity is playing into its `Sprite` and the vertex
-- shader resolves the frame from a shared table and the fixed-step clock, so a
-- frame changing writes nothing at all.
--
-- Components carry an interned sheet id because FFI columns cannot hold the
-- shared sheet table. Frame tables store each slice offset from the middle of
-- where the slice goes, so the pivot a moving slice carries is resolved where
-- the frame is.

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local components <const> = require("tecs.components")
local sheet <const> = require("tecs.gfx.sheet")
local frametable <const> = require("tecs.gfx.frametable")

local type Component = ecs.Component
local type World = types.World
local type Query = types.Query
local type Sheet = sheet.Sheet

local Sprite <const> = components.Sprite
local Pivot <const> = sheet.Pivot

local floor <const> = math.floor

local TICK_HZ <const> = frametable.TICK_HZ

--- Playback rate an animation runs at when nothing says otherwise, which is
--- the timing the sheet's frames were authored with.
local DEFAULT_SPEED <const> = 1.0

--- What `Animation.frame` holds once the encoder has written a row.
---
--- Deliberately not a frame index. No sheet numbers a frame this, so nothing
--- can mistake it for one, and what it says is only the opposite of what zero
--- says: this entity's [`Sprite`](tealdoc:tecs.components.Sprite) carries a live
--- playback and the phase is in
--- there rather than in `time`.
local ENCODED <const> = -1

--- Stores playback state for one entity.
---
--- What an entity is playing lives here and where its cycle has got to lives in
--- its [`Sprite`](tealdoc:tecs.components.Sprite), which carries the playback
--- the shader resolves. So `frame` is not an index: the encoder writes
--- `ENCODED` to say the [`Sprite`](tealdoc:tecs.components.Sprite) carries a
--- live playback, and zero says the entity is to start its cycle again. Which
--- frame is showing is `animation.frameOf`.
---
--- `time` is the phase the cycle starts or resumes from, in seconds, and stays
--- inside the cycle. Nothing advances it while playback runs, so it neither
--- grows without bound nor loses precision to its own age.
local record Animation is Component
    --- Caller-writable. Selects a sheet by its `Sheet.id` registration index.
    --- Zero plays nothing.
    sheet: number
    --- Caller-writable. Selects a tag by its `Sheet:tagId` index. Zero plays the
    --- whole sheet in order.
    tag: number
    --- Caller-writable. Multiplies the timing the sheet carries. One is the timing as
    --- authored, two is twice as fast. Zero or less holds the current frame and
    --- stops time advancing, which is a pause that leaves `playing` alone.
    ---
    --- How long each frame is held is the sheet's answer and not an entity's,
    --- because that is where an artist sets it: a hold frame is a frame with a
    --- long duration, which no single rate can express.
    speed: number
    --- Engine-owned. Carries the phase the cycle starts or resumes from, in
    --- seconds. Ordinary game code should read `timeOf`, which reports where the
    --- cycle has got to; this field stays where playback was last started from.
    --- The cycle duration is the sum of the durations of the frames the tag
    --- visits. Changing `speed` leaves the phase where it is, so playback
    --- carries on from the frame it was showing rather than jumping.
    time: number
    --- Engine-owned. Says whether the Sprite carries a live playback, and never
    --- which frame that playback is showing. Ordinary game code should use
    --- `frameOf`. Zero asks for the cycle to start again, which is what `play`,
    --- `restart`, `of` and a restored snapshot write.
    frame: number
    --- Caller-writable. Controls whether the tag restarts after its last frame.
    loop: boolean
    --- Caller-writable. Controls whether time advances.
    playing: boolean
end

--- Requests [`Completed`](tealdoc:tecs.gfx.animation.Completed) and
--- [`Looped`](tealdoc:tecs.gfx.animation.Looped) events for an entity.
---
--- The event query visits only entities carrying this tag. A game can request
--- events for a handful of entities without walking the rest of its animated
--- crowd. Adding the tag costs one archetype move and nothing per step.
local record AnimationEvents is Component
end

--- Reports when a non-looping tag runs past its
--- last frame. The animation stops and holds that frame, so this fires once per
--- playthrough and never again until something restarts it.
local record Completed is ecs.Event
    --- Read-only. Identifies the entity whose animation completed.
    entity: integer
    --- Read-only. Reports the sheet that completed.
    sheet: Sheet
    --- Read-only. Reports the tag that finished, or the empty string for a
    --- whole sheet.
    tag: string

    --- Creates a completed event value.
    --- @param self The completed event type.
    --- @param entity The entity whose animation completed.
    --- @param sheet The sheet that completed.
    --- @param tag The tag that completed, or an empty string for the whole sheet.
    --- @return The completed event value.
    metamethod __call: function(self, entity: integer, sheet: Sheet, tag: string): Completed
end

--- Reports when a looping tag passes its last frame
--- and restarts.
---
--- Once per step at most, not once per cycle: a step long enough to cover
--- several cycles wraps the time once and reports one loop, so counting these
--- is not a way to count playthroughs.
local record Looped is ecs.Event
    --- Read-only. Identifies the entity whose animation looped.
    entity: integer
    --- Read-only. Reports the sheet that looped.
    sheet: Sheet
    --- Read-only. Reports the tag that wrapped, or the empty string for a
    --- whole sheet.
    tag: string

    --- Creates a looped event value.
    --- @param self The looped event type.
    --- @param entity The entity whose animation looped.
    --- @param sheet The sheet that looped.
    --- @param tag The tag that looped, or an empty string for the whole sheet.
    --- @return The looped event value.
    metamethod __call: function(self, entity: integer, sheet: Sheet, tag: string): Looped
end

--- Configures how an animation plays.
local record PlayOptions
    --- Caller-writable. Multiplies the sheet's own timing and defaults to one.
    speed: number
    --- Caller-writable. Controls whether the tag restarts after its last
    --- frame. Defaults to true.
    loop: boolean
    --- Caller-writable. Controls whether playback starts immediately. Defaults
    --- to true.
    playing: boolean
end

local record animation
    --- Configures `of` and `play`.
    type PlayOptions = PlayOptions

    --- Read-only. Exposes the playback-state component for one entity.
    Animation: Animation

    --- Read-only. Exposes the event emitted when a non-looping tag finishes.
    Completed: Completed

    --- Read-only. Exposes the event emitted when a looping tag restarts.
    Looped: Looped

    --- Read-only. Exposes the tag that requests
    --- [`Completed`](tealdoc:tecs.gfx.animation.Completed) and
    --- [`Looped`](tealdoc:tecs.gfx.animation.Looped) events for an entity.
    AnimationEvents: AnimationEvents

    --- Creates an [`Animation`](tealdoc:tecs.gfx.animation.Animation) that
    --- plays a named sheet tag and is ready to spawn.
    ---
    --- Omit the tag to play the whole sheet in order. Fails on a tag the sheet
    --- does not carry, since the alternative is a typo that plays every
    --- frame.
    ---
    --- The entity also needs a [`Sprite`](tealdoc:tecs.components.Sprite),
    --- which the query matches and playback writes what is playing into. An
    --- [`Animation`](tealdoc:tecs.gfx.animation.Animation) on its own draws
    --- nothing.
    --- @param source The sheet to play. Nil raises.
    --- @param tag A tag the sheet names, or nil for the whole sheet. A name the
    ---     sheet does not carry raises here rather than reporting and playing
    ---     the whole sheet, because an author naming a tag at this call has one
    ---     in mind and the sheet is already in hand to check against.
    --- @param options Defaults are the sheet's own timing, looping, and
    ---     playing.
    --- @return A component value, not an entity: pass it to `world:spawn` or
    ---     `world:set` yourself.
    of: function(source: Sheet, tag?: string, options?: PlayOptions): Animation

    --- Points a live entity at a tag and restarts it there.
    ---
    --- Restarting is the point: time and frame both reset, so the next step
    --- writes the tag's first frame whatever the entity was showing. An entity
    --- carrying no Animation gets one.
    --- @param world The world the entity lives in.
    --- @param entity A live entity with a
    ---     [`Sprite`](tealdoc:tecs.components.Sprite).
    --- @param source The sheet to play. Nil raises.
    --- @param tag A tag the sheet names, or nil for the whole sheet. A name the
    ---     sheet does not carry raises, as it does in `of`.
    --- @param options Defaults are the sheet's own timing, looping, and
    ---     playing.
    play: function(world: World, entity: integer, source: Sheet, tag?: string, options?: PlayOptions)

    --- Plays an entity's animation again from the start of its tag.
    ---
    --- The sheet, tag, speed and loop flag are left as they are; what resets
    --- is where in the cycle playback has got to and whether it is running. For
    --- replaying a one-shot that has finished, and for rewinding one that has
    --- not.
    --- @param world The world the entity lives in.
    --- @param entity A live entity.
    --- @return Whether there was an Animation to restart. False leaves the
    ---     entity untouched, since there is nothing to say what it would play.
    restart: function(world: World, entity: integer): boolean

    --- Returns an animation's position in its tag cycle, in seconds.
    ---
    --- Recomputed on the call rather than kept in a column, because keeping it
    --- means writing every animating entity on every step and that is the cost
    --- resolving the frame in the shader exists to remove. A few hundred calls a step is free; it
    --- stops being free somewhere in the tens of thousands, which is a game
    --- asking a question this is the wrong shape for.
    --- @param world The world the entity lives in.
    --- @param entity A live entity.
    --- @return Seconds into the cycle, wrapped for a looping tag and clamped at
    ---     the end for a one-shot. Zero for an entity carrying no Animation and
    ---     for one whose sheet this run does not have.
    timeOf: function(world: World, entity: integer): number

    --- Returns the sheet frame shown by an entity's animation.
    ---
    --- The same answer the vertex shader draws, because both are `frameAt` over
    --- the same tag: the shader reads a table built from it and this calls it.
    --- What a hitbox on frame five, a footstep on frame three or a muzzle on an
    --- animated hand asks for.
    --- @param world The world the entity lives in.
    --- @param entity A live entity.
    --- @return A frame index into the whole sheet, counting from one, or zero
    ---     for an entity with nothing to play.
    frameOf: function(world: World, entity: integer): integer

    --- Adds the systems that drive playback.
    ---
    --- Call this once for each world that plays sprite sheets. A second call on
    --- the same world does nothing.
    ---
    --- It installs three systems, all in `PostUpdate` so they land before
    --- extraction whatever order a game added its plugins in.
    --- `tecs.EncodeAnimation` writes what each entity is playing into its
    --- [`Sprite`](tealdoc:tecs.components.Sprite) and writes nothing on a step
    --- where nothing changed what is playing. `tecs.ReportAnimation` derives
    --- [`Completed`](tealdoc:tecs.gfx.animation.Completed) and
    --- [`Looped`](tealdoc:tecs.gfx.animation.Looped) for entities carrying
    --- [`AnimationEvents`](tealdoc:tecs.gfx.animation.AnimationEvents).
    --- `tecs.RebaseAnimation` moves the playback clock's origin every few hours
    --- of uptime and re-anchors every animated row on it, which is the one
    --- update in a hundred thousand that writes every playing animation.
    --- @param world The world to add the systems to.
    plugin: function(world: World)

    --- Exposes sheet types and constructors through the animation module.
    ---
    --- Constructing a sheet and playing one are one subject, so a game asks one
    --- module about both. The file stays its own because `frametable` reads it
    --- and this module reads `frametable`, and a Teal cycle is a cycle even
    --- through a type-only require.
    ---
    --- Three of the names change on the way through. `byId`, `byName` and
    --- `revision` each leave their subject implicit, and the implicit subject
    --- here would be an animation rather than a sheet; the other eight say what
    --- they answer with in their return type and are unambiguous as they stand.

    --- Selects how a tag walks its span.
    type Direction = sheet.Direction
    --- One frame, as `rects` and the builder take it.
    type Rect = sheet.Rect
    --- A named span of frames, as the constructors take it.
    type Tag = sheet.Tag
    --- A named region that moves across the frames.
    type Slice = sheet.Slice
    --- Defines where a slice sits from one frame onward.
    type SliceKey = sheet.SliceKey
    --- Configures `grid`.
    type GridOptions = sheet.GridOptions
    --- Configures `rects`.
    type RectsOptions = sheet.RectsOptions
    --- Configures `fromAseprite`.
    type AsepriteOptions = sheet.AsepriteOptions
    --- Builds custom sheets one frame at a time.
    type Builder = sheet.Builder

    --- Read-only. Exposes an image divided into frames.
    Sheet: sheet.Sheet

    --- Read-only. Exposes the pivot component that controls where an entity's
    --- quad turns and scales.
    Pivot: sheet.Pivot

    --- Read-only. Reports how many milliseconds a frame remains visible when
    --- nothing overrides its duration.
    DEFAULT_DURATION: number

    --- Creates a sheet whose frames form a uniform grid.
    --- @param options Raises on a missing name, a non-positive image or frame
    ---     size, a grid that fits no cells, or a `count` past what the grid
    ---     holds. Frames come out in row-major order.
    --- @return The finished sheet, already registered under its name and
    ---     carrying an `id`.
    grid: function(options: sheet.GridOptions): sheet.Sheet

    --- Creates a sheet from explicitly listed frame rectangles.
    --- @param options Raises on a missing name, a non-positive image size, an
    ---     empty frame list, or a frame with no positive size.
    --- @return The finished sheet, already registered under its name and
    ---     carrying an `id`.
    rects: function(options: sheet.RectsOptions): sheet.Sheet

    --- Creates a builder for a sheet that the other constructors cannot
    --- describe.
    --- @param name Name to register the finished sheet under.
    --- @param imageWidth Size of the image the frames are cut from, in pixels.
    --- @param imageHeight The other size, in pixels.
    --- @return Returns a builder that registers the sheet when `finish` runs.
    build: function(name: string, imageWidth: number, imageHeight: number): sheet.Builder

    --- Creates a sheet from an Aseprite JSON export.
    --- @param options Raises on a missing name or an export the reader cannot
    ---     make a sheet out of.
    --- @return The finished sheet, already registered.
    fromAseprite: function(options: sheet.AsepriteOptions): sheet.Sheet

    --- Folds a re-exported sheet into the one already registered under its
    --- name, in place, so an entity playing the old id shows the new frames.
    --- @param built A sheet from any constructor here, registered moments ago
    ---     under a name something else already holds.
    --- @return Returns the live sheet and nil, or nil and the refusal reason.
    replace: function(built: sheet.Sheet): sheet.Sheet, string

    --- Returns the sheet represented by a process-wide id.
    --- @param id An id a constructor handed out.
    --- @return The sheet, or nil when the id names none.
    findSheetById: function(id: integer): sheet.Sheet

    --- Returns the sheet registered under a name.
    --- @param name The name a constructor registered.
    --- @return The sheet, or nil when the name names none.
    findSheetByName: function(name: string): sheet.Sheet

    --- Returns how many times any sheet's frames have changed.
    ---
    --- What a cache of anything derived from a sheet compares against, so a
    --- sheet replaced or rebound under a running game invalidates it.
    --- @return A number that only ever increases.
    sheetRevision: function(): integer
end

ecs.newFFIComponent({
    name = "Animation",
    container = Animation,
    fields = {
        {"sheet", "int32_t"},
        {"tag", "int32_t"},
        {"speed", "float"},
        {"time", "float"},
        {"frame", "int32_t"},
        {"loop", "bool"},
        {"playing", "bool"},
    },
    defaults = {0, 0, DEFAULT_SPEED, 0, 0, true, true},
    -- A sheet id and a tag id are this process's answers, decided by the
    -- order sheets were built in. What crosses a save is the pair of names,
    -- resolved again on the way back in. A tag the sheet has since lost
    -- resolves to zero and the sheet reports it, once for the whole restore
    -- however many entities carry the name. The frame is deliberately dropped:
    -- zero makes the first step rewrite the Sprite's region, so a restored
    -- entity does not depend on the region its Sprite was saved holding.
    serialize = function(instance: Animation): {string: any}
        local source = sheet.byId(instance.sheet as integer)
        local name: string = nil
        local tag: string = nil
        if source ~= nil then
            name = source.name
            tag = source:tagName(instance.tag as integer)
        end
        return {
            sheet = name,
            tag = tag,
            speed = instance.speed,
            time = instance.time,
            loop = instance.loop,
            playing = instance.playing,
        }
    end,
    deserialize = function(_world: World, data: {string: any}): Animation
        local source = sheet.byName(data.sheet as string)
        local id, tag = 0, 0
        if source ~= nil then
            id = source.id
            tag = source:tagId(data.tag as string)
        end
        return Animation(
            id, tag, data.speed as number, data.time as number, 0, data.loop as boolean, data.playing as boolean
        )
    end,
})

ecs.newComponent({
    name = "AnimationEvents",
    container = AnimationEvents,
})

animation.Animation = Animation
animation.Completed = Completed
animation.Looped = Looped
animation.AnimationEvents = AnimationEvents

-- Sheets, reached through here rather than through a module of their own. The
-- functions are the same objects rather than wrappers, so nothing is a call
-- deeper for going through this name.
animation.Sheet = sheet.Sheet
animation.Pivot = sheet.Pivot
animation.DEFAULT_DURATION = sheet.DEFAULT_DURATION
animation.grid = sheet.grid
animation.rects = sheet.rects
animation.build = sheet.build
animation.fromAseprite = sheet.fromAseprite
animation.replace = sheet.replace
animation.findSheetById = sheet.byId
animation.findSheetByName = sheet.byName
animation.sheetRevision = sheet.revision

animation.Completed.init = function(event: Completed, entity: integer, source: Sheet, tag: string)
    event.entity, event.sheet, event.tag = entity, source, tag
end
ecs.newEvent(animation.Completed)

animation.Looped.init = function(event: Looped, entity: integer, source: Sheet, tag: string)
    event.entity, event.sheet, event.tag = entity, source, tag
end
ecs.newEvent(animation.Looped)

-------------------------------------------------------------------------------
-- Authoring
-------------------------------------------------------------------------------

function animation.of(source: Sheet, tag?: string, options?: PlayOptions): Animation
    if source == nil then
        error("tecs: an animation needs a sheet", 2)
    end
    local tagId = 0
    if tag ~= nil then
        -- Fails on a name the sheet does not carry.
        source:tag(tag)
        tagId = source:tagId(tag)
    end
    options = options or {}
    local loop = options.loop
    if loop == nil then
        loop = true
    end
    local playing = options.playing
    if playing == nil then
        playing = true
    end
    return Animation(source.id, tagId, options.speed or DEFAULT_SPEED, 0.0, 0, loop, playing)
end

function animation.play(world: World, entity: integer, source: Sheet, tag?: string, options?: PlayOptions)
    local built <const> = animation.of(source, tag, options)
    if not world:has(entity, Animation) then
        world:set(entity, built)
        return
    end
    local current <const> = world:getMut(entity, Animation)
    current.sheet = built.sheet
    current.tag = built.tag
    current.speed = built.speed
    current.time = 0.0
    current.frame = 0
    current.loop = built.loop
    current.playing = built.playing
end

function animation.restart(world: World, entity: integer): boolean
    if not world:has(entity, Animation) then
        return false
    end
    local current <const> = world:getMut(entity, Animation)
    current.time = 0.0
    -- Zero is no frame written yet, so the next step writes the tag's first
    -- one whatever the entity was showing.
    current.frame = 0
    current.playing = true
    return true
end

-------------------------------------------------------------------------------
-- Playback
-------------------------------------------------------------------------------

--- Writes what each row is playing into its `Sprite`.
---
--- What the shader reads is not a frame but an animation, a start and a rate, so
--- this runs when what is playing changes and not when a frame does. The gate
--- is the `Animation` column's own dirty bit, which is set by exactly the
--- things that change what is playing: a spawn, an archetype move, `play`,
--- `restart`, and any direct write through `getMut`. A step where nothing
--- changed visits no archetype and writes nothing, which is the whole point.
---
--- `held` is for the archetypes carrying `Paused`. The world's clock does not
--- stop for them, so holding has to be said rather than assumed, and a rate of
--- zero says it: the encoding then carries the tick to hold instead of the step
--- playback began on. An entity moving in or out of `Paused` changes archetype,
--- and a move marks every component on the destination dirty, so the freeze and
--- the thaw both arrive here without anything having to notice them.
---
--- `clock` is the step count this update began on and not the one it has
--- reached, because `Animation.time` is the phase before this update's steps
--- ran: an entity spawned between two updates, and a snapshot loaded between
--- them, were both written before the fixed loop. Anchoring on the count now
--- would make an entity's phase depend on how many fixed steps happened to fall
--- inside the update it was first seen in, and two machines fed the same steps
--- in different sized updates would show different frames. That is the promise
--- the fixed step is quantised to keep.
local function encode(world: World, query: Query, held: boolean, clock: number)
    local timestep <const> = world:getFixedTiming()

    for archetype, length in query:iter() do
        -- The Pivot column joins the gate because a playback is keyed on the
        -- slice as well as the tag: pointing an entity at another slice changes
        -- which playback it is on, and nothing about its Animation moved to say
        -- so. An archetype carrying no Pivot answers false and pays a lookup.
        if archetype:isComponentDirty(Animation) or archetype:isComponentDirty(Pivot) then
            -- Mutable because the mark below is a write. The column is already
            -- dirty, which is why this archetype is being visited at all, so
            -- this declares the intent rather than changing what is gated.
            local animations <const> = archetype:getMut(Animation)
            local sprites <const> = archetype:getMut(Sprite)
            -- Absent on every archetype that turns about its middle, which is
            -- most of them.
            local pivots <const> = archetype:get(Pivot)
            local moved = false
            -- Sheets are few and neighboring rows tend to share one, and a
            -- crowd playing one cycle shares the tag and the slice as well.
            local cachedId = 0
            local cachedTag = -1
            local cachedSlice = -1
            local cached: Sheet = nil
            local playback = 0
            local count = 0
            local midX, midY, halfX, halfY = 0.5, 0.5, 0.0, 0.0

            for row = 1, length do
                local instance <const> = animations[row]
                local sheetId <const> = instance.sheet as integer
                local tagId <const> = instance.tag as integer
                if sheetId ~= cachedId then
                    cached = sheet.byId(sheetId)
                    cachedId = sheetId
                    cachedTag = -1
                end

                if cached ~= nil then
                    -- A slice bound to another sheet names nothing here: a
                    -- frame index counts through this sheet's frames and means
                    -- something else in another's, so the playback follows no
                    -- slice and the pivot stays where it was written.
                    local sliceId = 0
                    if pivots ~= nil and pivots[row].sheet as integer == sheetId then
                        sliceId = pivots[row].slice as integer
                    end

                    if tagId ~= cachedTag or sliceId ~= cachedSlice then
                        cachedTag, cachedSlice = tagId, sliceId
                        playback = frametable.register(cached, tagId, sliceId)
                        count = frametable.tickCount(playback)
                        midX, midY, halfX, halfY = frametable.pivotOf(playback)
                    end

                    -- The middle of where the slice goes over the cycle, which
                    -- extraction folds into the quad's origin, and how far
                    -- either side of it the frame table can move the quad. Both
                    -- are the playback's answer rather than the frame's, so a
                    -- frame changing still writes nothing.
                    if sliceId > 0 then
                        if not moved then
                            archetype:getMut(Pivot)
                            moved = true
                        end
                        local target <const> = pivots[row]
                        target.x, target.y = midX, midY
                        target.halfX, target.halfY = halfX, halfY
                    end

                    -- Where in the cycle the entity is, in ticks.
                    --
                    -- The encoding the row already carries is the live answer
                    -- and `Animation.time` is not: nothing advances `time` on
                    -- this path, so it is the phase the entity was last started
                    -- from and it stays there. Reading it here would send an
                    -- entity back to that phase every time anything re-encoded
                    -- it, and an archetype move re-encodes everything it moved,
                    -- because a move marks every component on the destination
                    -- dirty. So a row still playing what it was carries on from
                    -- where it is, and only a row that was reset, restored or
                    -- never encoded reads the component.
                    --
                    -- Two things say which. `frame` is zero exactly when the
                    -- component was written by something meaning to start the
                    -- cycle again: `play`, `restart`, `of` and `deserialize`
                    -- all write zero and nothing else does, which is the same
                    -- job the field already had. And the region fields have to
                    -- hold a playback rather than a region, since a game that
                    -- put its own `Sprite` on the entity left no phase there to
                    -- read.
                    --
                    -- Which is what makes a freeze, a thaw and a speed change
                    -- hold their position too, rather than only an archetype
                    -- move: all three are this same re-encode.
                    local target <const> = sprites[row]
                    local ticks: number
                    if instance.frame ~= 0 and frametable.isPlayback(target) then
                        local was <const> = target.u1
                        ticks = was == 0.0 and target.v0 or (clock - target.v0) * was
                    else
                        ticks = instance.time * TICK_HZ
                    end

                    local speed <const> = instance.speed
                    local running <const> = not held and instance.playing and speed > 0.0
                    if running then
                        local rate <const> = timestep * speed * TICK_HZ
                        -- A one-shot parks one whole cycle in and stops, so
                        -- finding one there and playing is something having
                        -- asked for it again. It starts over, because advancing
                        -- from the end would park it again on every step from
                        -- here and complete on each of them.
                        --
                        -- Which is why a one-shot nothing is listening to is
                        -- the one thing a re-encode cannot hold: `playing` is
                        -- what parks it, `Completed` is what clears `playing`,
                        -- and with no subscriber it stays true. Past its end
                        -- and playing reads as asked-again either way, so the
                        -- entity starts over. Opting into `AnimationEvents`
                        -- parks it and this then holds it at the last frame.
                        if not instance.loop and ticks >= count then
                            ticks = 0.0
                        end
                        frametable.encode(target, playback, clock - ticks / rate, rate, instance.loop)
                    else
                        frametable.encode(target, playback, ticks, 0.0, instance.loop)
                    end

                    -- Not a frame index on this path: which frame is showing is
                    -- the shader's answer and `frameOf`'s, and a number here
                    -- would go stale between encodes while looking like one to
                    -- trust. What it says is only what zero already said, the
                    -- other way round: this Sprite carries a live playback, so
                    -- the phase above comes out of it.
                    instance.frame = ENCODED
                end
            end
        end
    end
end

--- Emits `Completed` and `Looped` for the entities that asked for them.
---
--- Derived rather than observed, and that is what makes it free. Whether an
--- entity crossed its cycle between two step counts is a function of the start
--- and the rate its `Sprite` already carries, so this reads two columns and
--- writes nothing: no `getMut`, no dirty column, and no rewrite of a run
--- because a crowd of animations wrapped.
---
--- The one write is the flag a finished one-shot parks behind, which is what
--- `Completed` has always meant and is the only thing here a caller can see
--- afterwards. It costs one row on the step it finishes and nothing before or
--- after, and only rows carrying `AnimationEvents` reach this at all.
local function report(world: World, query: Query, from: number, to: number)
    -- Hoisted, because a large world wrapping animations would otherwise ask
    -- the bus the same question once per wrap.
    local wantsCompleted <const> = world:hasObservers(0, animation.Completed)
    local wantsLooped <const> = world:hasObservers(0, animation.Looped)

    -- Walked whether or not anything is listening, because carrying
    -- `AnimationEvents` is what asks for this and observing is a separate
    -- question: a one-shot's flag has to park for a game that reads it later
    -- rather than subscribing. The tag is what keeps the walk small.
    for archetype, length, entities in query:iter() do
        local animations <const> = archetype:get(Animation)
        local sprites <const> = archetype:get(Sprite)
        local parked = false
        local cachedId = 0
        local cached: Sheet = nil

        for row = 1, length do
            local target <const> = sprites[row]
            -- A held playback has no rate and cannot cross anything, which is
            -- what a paused entity and one whose speed is zero both look like
            -- from here. A row that has never been encoded carries a region.
            local rate <const> = target.u1
            if rate > 0.0 and frametable.isPlayback(target) then
                local id <const> = frametable.playbackOf(target)
                local count <const> = frametable.tickCount(id)
                local start <const> = target.v0
                -- Clamped, because an entity encoded during this step started
                -- at a clock this window opened before and would otherwise
                -- read as having come round from behind zero.
                local before = (from - start) * rate
                if before < 0.0 then
                    before = 0.0
                end
                local after <const> = (to - start) * rate

                if count > 0 and after > before then
                    local instance <const> = animations[row]
                    local looped <const> = instance.loop and floor(after / count) > floor(before / count)
                    local completed <const> = not instance.loop and before < count and after >= count

                    if completed or looped then
                        local sheetId <const> = instance.sheet as integer
                        if sheetId ~= cachedId then
                            cached = sheet.byId(sheetId)
                            cachedId = sheetId
                        end
                    end

                    if completed and cached ~= nil then
                        -- Parked one whole cycle in, which is where the encode
                        -- above reads as finished, so a later encode holds the
                        -- last frame rather than starting the cycle again. The shader is already
                        -- drawing that frame, because a one-shot clamps at its
                        -- last tick whether or not anything is listening.
                        if not parked then
                            archetype:getMut(Animation)
                            parked = true
                        end
                        instance.playing = false
                        instance.time = count / TICK_HZ
                        if wantsCompleted then
                            world:emit(
                                0, animation.Completed, entities[row], cached, cached:tagName(instance.tag as integer)
                            )
                        end
                    elseif looped and wantsLooped and cached ~= nil then
                        world:emit(0, animation.Looped, entities[row], cached, cached:tagName(instance.tag as integer))
                    end
                end
            end
        end
    end
end

--- Re-anchors every encoded row on a clock whose origin has just moved.
---
--- Two things go wrong in a world left running for hours, and one walk answers
--- both. The clock is a float the shader subtracts a start step from, so a count
--- that only ever grew would stop naming every step at all; and the ticks a row
--- is into its cycle are that difference times a rate, so a row that has been
--- playing since the world started would have its frame boundaries quantise to
--- more than a whole step. Moving the origin fixes the first. What fixes the
--- second is that this folds each row's phase into the cycle it repeats over
--- before re-anchoring it, so the elapse a row carries is bounded by the period
--- rather than by the world's age.
---
--- The fold is invisible: what comes off is a whole number of cycles, which is
--- what the shader's own wrap takes off anyway. What it costs is one rewrite of
--- every animated row and the upload behind it, once every
--- `frametable.REBASE_STEPS`, which is two and a half hours at sixty hertz.
---
--- Nothing here reads the `Animation` column. The rate, the loop flag and the
--- playback are all in the encoding, so where a row is playing from moves
--- without resolving what it is playing.
local function rebase(query: Query, clock: number, shift: number)
    -- Where the rows were anchored, which is what the clock read before the
    -- origin moved under them.
    local before <const> = clock + shift

    for archetype, length in query:iter() do
        local sprites <const> = archetype:get(Sprite)
        local wrote = false

        for row = 1, length do
            local target <const> = sprites[row]
            -- A held row carries the tick it is holding rather than a step, so
            -- the origin moving under it changes nothing. That is what a paused
            -- entity and one whose speed is zero both look like from here.
            local rate <const> = target.u1
            if rate > 0.0 and frametable.isPlayback(target) then
                local count <const> = frametable.tickCount(frametable.playbackOf(target))
                if count > 0 then
                    local ticks = (before - target.v0) * rate
                    if target.v1 ~= 0.0 then
                        ticks = ticks % count
                    elseif ticks > count then
                        -- A one-shot clamps at its last tick, so parking it one
                        -- whole cycle in holds the frame it was already holding
                        -- and reads as finished to the next encode.
                        ticks = count
                    end
                    if not wrote then
                        archetype:getMut(Sprite)
                        wrote = true
                    end
                    target.v0 = clock - ticks / rate
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Asking what an entity is showing
-------------------------------------------------------------------------------

--- Where an entity's animation has got to, as a sheet, a tag and a time.
---
--- One function behind both queries below, so the two cannot answer from
--- different places. The `Sprite` carries a start and a rate, and the time
--- comes out of them and the clock. An entity carrying no `Sprite` has nothing
--- to have been encoded into, so its component's phase is all there is.
local function phaseOf(world: World, entity: integer): Sheet, integer, number
    if not world:has(entity, Animation) then
        return nil, 0, 0.0
    end
    local instance <const> = world:get(entity, Animation)
    local source <const> = sheet.byId(instance.sheet as integer)
    if source == nil then
        return nil, 0, 0.0
    end
    local tagId <const> = instance.tag as integer

    if not world:has(entity, Sprite) then
        return source, tagId, instance.time
    end
    local target <const> = world:get(entity, Sprite)
    if not frametable.isPlayback(target) then
        -- Carrying a region rather than a playback, which is an entity that
        -- has not been encoded yet. What it is playing is what it says.
        return source, tagId, instance.time
    end

    local id <const> = frametable.playbackOf(target)
    local count <const> = frametable.tickCount(id)
    if count < 1 then
        return source, tagId, instance.time
    end

    local rate <const> = target.u1
    local ticks = rate == 0.0 and target.v0 or (frametable.clockOf(world) - target.v0) * rate
    if instance.loop then
        ticks = ticks % count
    elseif ticks < 0.0 then
        ticks = 0.0
    elseif ticks > count - 1 then
        ticks = count - 1
    end

    -- The middle of the tick, which is where the frame table samples. Answering
    -- from anywhere else in it would put this and the shader on opposite sides
    -- of a boundary authored in whole milliseconds.
    return source, tagId, (floor(ticks) + 0.5) / TICK_HZ
end

function animation.timeOf(world: World, entity: integer): number
    local _, _, time <const> = phaseOf(world, entity)
    return time
end

function animation.frameOf(world: World, entity: integer): integer
    local source <const>, tagId <const>, time <const> = phaseOf(world, entity)
    if source == nil then
        return 0
    end
    return source:frameAt(tagId, time)
end

--- Worlds the plugin has already installed into.
local installed: {World: boolean} = setmetatable({}, {__mode = "k"} as metatable<{World: boolean}>)

function animation.plugin(world: World)
    if installed[world] then
        return
    end
    installed[world] = true

    -- Not a logic query: a paused entity still has to be told it is holding,
    -- and one that has never been encoded still has to be encoded. Which of the
    -- two it is decides the rate, so they are two queries rather than one and a
    -- test per row.
    local running <const> = world:query({
        name = "tecs.EncodedSprites",
        include = {Animation, Sprite},
        exclude = {ecs.Paused},
    })
    local paused <const> = world:query({
        name = "tecs.EncodedPausedSprites",
        include = {Animation, Sprite, ecs.Paused},
    })

    -- The clock each update began on, which is what the last one ended at
    -- because nothing between two updates moves it. Read through the frame table
    -- rather than off the world, so it is in the units a start step is written
    -- in: the origin those two share is the frame table's to move.
    local began = frametable.clockOf(world)

    -- `PostUpdate` rather than a render phase, so this lands before extraction
    -- whatever order the renderer and this plugin were installed in.
    world:addSystem({
        name = "tecs.EncodeAnimation",
        phase = ecs.phases.PostUpdate,
        run = function() encode(world, running, false, began); encode(world, paused, true, began) end,
    })

    -- Beside the encoder rather than in the fixed phases, because what says
    -- whether an entity crossed its cycle is the encoding, and the encoding for
    -- an entity that only just started playing is written above. A window of
    -- steps rather than one step: an update that ran several fixed steps reports
    -- one crossing over all of them, which is the contract `Looped` already had.
    local subscribed <const> = world:query({
        name = "tecs.AnimationSubscribers",
        include = {Animation, Sprite, AnimationEvents},
    })
    world:addSystem({
        name = "tecs.ReportAnimation",
        phase = ecs.phases.PostUpdate,
        run = function()
            local clock <const> = frametable.clockOf(world)
            if clock ~= began then
                report(world, subscribed, began, clock)
                began = clock
            end
        end,
    })

    -- After the report and therefore after the encoder, because both read start
    -- steps against the clock this update began with and this is what changes
    -- what that clock means. Declared rather than left to registration order,
    -- since a report over a window whose ends were measured from two origins
    -- would emit whatever the difference happened to look like.
    world:addSystem({
        name = "tecs.RebaseAnimation",
        phase = ecs.phases.PostUpdate,
        after = {"tecs.ReportAnimation"},
        run = function()
            local shift <const> = frametable.rebaseClock(world)
            if shift > 0.0 then
                local clock <const> = frametable.clockOf(world)
                -- The paused query as well, because what says a row is held
                -- is the rate in its encoding and not which query found it.
                rebase(running, clock, shift)
                rebase(paused, clock, shift)
                began = began - shift
            end
        end,
    })
end

return animation
