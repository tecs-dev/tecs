--- Sprite-sheet playback.
---
--- An `Animation` says which tag of a sheet is playing, how fast, whether it
--- repeats, whether it is running, and where in the tag it has got to.
---
--- There are two paths from that to a picture and `useGPU` chooses between them.
--- On, which is the default, `tecs.EncodeAnimation` writes which playback the
--- entity is on into its `Sprite` and the vertex shader resolves the frame, so a
--- frame changing writes nothing at all. Off, `tecs.AdvanceAnimation` walks
--- every playing animation on every fixed step and writes the frame's region
--- into the `Sprite` itself. They agree on the frame and differ on what they
--- write to reach it; `animation.frameOf` is what answers either way.
---
--- Playback is quantised to the fixed step whichever path it takes, because
--- animation is simulation. Two machines fed the same recording have to show the
--- same frame, and a system driven by frame time shows a different one on the
--- machine that drew more frames. So the host path runs in `FixedPostUpdate`,
--- late enough that gameplay logic in `FixedUpdate` has already chosen what
--- should be playing, and the GPU path's clock counts whole fixed steps.
---
--- The component carries a sheet id rather than a sheet. A component is plain
--- C memory and a sheet is a table, and the indirection is the point besides:
--- every entity playing one walk cycle shares one sheet.
---
--- An entity carrying a `Pivot` bound to one of the sheet's slices has it follow
--- the slice, because an Aseprite slice moves from frame to frame and a pivot
--- that did not follow it would drift off the part of the drawing it names. On
--- the host that is a fresh resolve on every frame the sprite changes; on the
--- GPU the entity carries the middle of where the slice goes and the frame table
--- carries each step's offset from it.

local ecs <const> = require("tecs.ecs")
local components <const> = require("tecs.components")
local sheet <const> = require("tecs.gfx.sheet")
local frametable <const> = require("tecs.gfx.frametable")

local type Component = ecs.Component
local type World = ecs.World
local type Query = ecs.Query
local type Sheet = sheet.Sheet

local Sprite <const> = components.Sprite
local Pivot <const> = sheet.Pivot

local floor <const> = math.floor

local TICK_HZ <const> = frametable.TICK_HZ

--- Playback rate an animation runs at when nothing says otherwise, which is
--- the timing the sheet's frames were authored with.
local DEFAULT_SPEED <const> = 1.0

--- What `Animation.frame` holds once playback on the GPU has encoded a row.
---
--- Deliberately not a frame index. No sheet numbers a frame this, so nothing
--- can mistake it for one, and what it says is only the opposite of what zero
--- says: this entity's `Sprite` carries a live playback and the phase is in
--- there rather than in `time`.
local ENCODED <const> = -1

--- Playback state for one entity.
---
--- `frame` is the frame the `Sprite` was last written from, as an index into
--- the whole sheet rather than into the tag. Zero means nothing has been
--- written yet, which is how a fresh or restored Animation gets its region on
--- the first step it runs instead of drawing whatever the Sprite held.
---
--- With playback on the GPU it stops being an index and keeps only the zero:
--- the encoder writes `ENCODED` to say the `Sprite` carries a live playback,
--- and zero still means the entity is to start its cycle again. Which frame is
--- showing is `animation.frameOf` on either path.
---
--- `time` is seconds into the tag's cycle and stays inside it: a looping
--- animation wraps and a one-shot parks at the end, so it never grows without
--- bound and never loses precision to its own age.
local record Animation is Component
    --- Registration index of the sheet, from `Sheet.id`. Zero plays nothing.
    sheet: number
    --- Index of the tag within that sheet, from `Sheet:tagId`. Zero plays the
    --- whole sheet in order.
    tag: number
    --- Multiplier on the timing the sheet carries. One is the timing as
    --- authored, two is twice as fast. Zero or less holds the current frame and
    --- stops time advancing, which is a pause that leaves `playing` alone.
    ---
    --- How long each frame is held is the sheet's answer and not an entity's,
    --- because that is where an artist sets it: a hold frame is a frame with a
    --- long duration, which no single rate can express.
    speed: number
    --- Seconds into the cycle, which is the sum of the durations of the frames
    --- the tag visits. Changing `speed` leaves this where it is, so playback
    --- carries on from the frame it was showing rather than jumping.
    time: number
    --- Frame the Sprite currently shows, or zero for none yet. With playback
    --- on the GPU it is only that zero, and `animation.frameOf` is the frame.
    frame: number
    --- Whether the tag restarts after its last frame.
    loop: boolean
    --- Whether time advances.
    playing: boolean
end

--- Asks for `Completed` and `Looped` on an entity.
---
--- Nothing is emitted for an entity that does not carry this, and the reason is
--- the archetype: a crowd of animating entities is visited by no query at all
--- while the handful that a game listens to sit together and are walked on
--- their own. Adding it costs an archetype move once and nothing per step.
---
--- With playback resolved on the host the events are emitted whether or not
--- this is carried, since the system that advances the frame is already looking
--- at the row when it wraps.
local record AnimationEvents is Component
end

--- Emitted at address zero on the step a tag that does not loop runs past its
--- last frame. The animation stops and holds that frame, so this fires once per
--- playthrough and never again until something restarts it.
local record Completed is ecs.Event
    entity: integer
    sheet: Sheet
    --- Name of the tag that finished, or the empty string for a whole sheet.
    tag: string

    metamethod __call: function(self, entity: integer, sheet: Sheet, tag: string): Completed
end

--- Emitted at address zero on the step a looping tag passes its last frame
--- and restarts.
---
--- Once per step at most, not once per cycle: a step long enough to cover
--- several cycles wraps the time once and reports one loop, so counting these
--- is not a way to count playthroughs.
local record Looped is ecs.Event
    entity: integer
    sheet: Sheet
    --- Name of the tag that wrapped, or the empty string for a whole sheet.
    tag: string

    metamethod __call: function(self, entity: integer, sheet: Sheet, tag: string): Looped
end

--- How an animation should play.
local record PlayOptions
    --- Multiplier on the sheet's own timing. Defaults to one.
    speed: number
    --- Whether the tag restarts after its last frame. Defaults to true.
    loop: boolean
    --- Whether it starts running. Defaults to true.
    playing: boolean
end

--- The playback surface: the `Animation` component, its two events, the
--- constructors and controls over it, and the system that advances it.
---
--- Nothing here is installed for you. A world that draws no sprite sheets pays
--- for none of it until `plugin` is called.
local record animation
    --- What `of` and `play` take.
    type PlayOptions = PlayOptions

    --- Playback state for one entity.
    Animation: Animation

    --- Emitted when a tag that does not loop runs past its last frame.
    Completed: Completed

    --- Emitted when a looping tag passes its last frame and restarts.
    Looped: Looped

    --- Asks for `Completed` and `Looped` on an entity.
    AnimationEvents: AnimationEvents

    --- An Animation playing a named tag of a sheet, ready to spawn.
    ---
    --- Omit the tag to play the whole sheet in order. Fails on a tag the sheet
    --- does not carry, since the alternative is a typo that plays every
    --- frame.
    ---
    --- The entity also needs a `Sprite`, which is what the query matches on and
    --- what playback writes the frame's region into. An Animation on its own
    --- advances nothing.
    --- @param source The sheet to play. Nil raises.
    --- @param tag A tag the sheet names, or nil for the whole sheet.
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
    --- @param entity A live entity, which needs a `Sprite` for playback to
    ---     reach it.
    --- @param source The sheet to play. Nil raises.
    --- @param tag A tag the sheet names, or nil for the whole sheet.
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

    --- How far into its tag's cycle an entity's animation has got, in seconds.
    ---
    --- Recomputed on the call rather than kept in a column, because keeping it
    --- means writing every animating entity on every step and that is the cost
    --- the GPU path exists to remove. A few hundred calls a step is free; it
    --- stops being free somewhere in the tens of thousands, which is a game
    --- asking a question this is the wrong shape for.
    --- @param world The world the entity lives in.
    --- @param entity A live entity.
    --- @return Seconds into the cycle, wrapped for a looping tag and clamped at
    ---     the end for a one-shot. Zero for an entity carrying no Animation and
    ---     for one whose sheet this run does not have.
    timeOf: function(world: World, entity: integer): number

    --- The sheet frame an entity's animation is showing.
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

    --- Adds the system that advances playback.
    ---
    --- Not installed for you, so a world that draws no sprite sheets pays
    --- nothing for the query. Call it once; a second call on the same world is
    --- ignored, because adding a system twice under one name is an error.
    ---
    --- Which system depends on `useGPU`. On the host it is
    --- `tecs.AdvanceAnimation` in `FixedPostUpdate`, whose query is a logic
    --- query, so a paused entity holds the frame it is on. On the GPU it is
    --- `tecs.EncodeAnimation` in `PostUpdate`, which writes nothing on a step
    --- where nothing changed what is playing, followed by
    --- `tecs.ReportAnimation`, which derives `Completed` and `Looped` for the
    --- entities carrying `AnimationEvents` and writes nothing at all.
    --- @param world The world to add the system to.
    plugin: function(world: World)

    --- Chooses whether playback is resolved on the GPU.
    ---
    --- Off, a system walks every playing animation on every fixed step and
    --- writes the frame's region into the entity's `Sprite`, which marks that
    --- column dirty and has extraction rewrite every instance in the
    --- archetype. One animating sprite therefore costs a rewrite of everything
    --- structurally like it, which is what stops a large animated scene being
    --- affordable.
    ---
    --- On, the `Sprite` carries which animation is playing rather than the
    --- region it resolved to, and the vertex shader works the region out from
    --- a shared table and a clock. A frame changing then writes nothing at all,
    --- so what a step costs is what actually changed rather than what is
    --- shaped like it.
    ---
    --- Three things read differently with this on. `Animation.frame` and
    --- `Animation.time` stop being written, and `frameOf` and `timeOf` answer
    --- from the clock instead. `Completed` and `Looped` reach only the entities
    --- carrying `AnimationEvents`, and a one-shot that finishes leaves `playing`
    --- alone unless something is listening for it. And the `Sprite` carries a
    --- playback rather than a region, so its layer and image stop following the
    --- sheet: the frame table carries both and the shader reads them there.
    ---
    --- On is the default. Set this before `plugin`, since it decides which
    --- systems that installs, and worlds already carrying them keep them.
    --- @param enabled False puts playback back on the host, for a world that
    ---     wants events and frame queries without opting in or recomputing and
    ---     is small enough to pay a walk of every animation on every step.
    useGPU: function(enabled: boolean)

    --- Whether playback resolves on the GPU.
    usesGPU: function(): boolean
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
    -- resolved again on the way back in. The frame is deliberately dropped:
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

--- Advances every playing animation by one fixed step.
---
--- `dt` is the step the fixed phases run at and never frame time, which is
--- what makes the same sequence of steps produce the same frames however many
--- frames were drawn between them.
local function advance(world: World, query: Query, dt: number)
    -- Hoisted, because an animation looping twice a second across a large
    -- world would otherwise ask the bus the same question once per wrap.
    local wantsCompleted <const> = world:hasObservers(0, animation.Completed)
    local wantsLooped <const> = world:hasObservers(0, animation.Looped)

    for archetype, length, entities in query:iter() do
        local animations = archetype:get(Animation)
        -- `get` and `getMut` hand back the same column and only `getMut` sets
        -- the dirty bit, so each is taken the first time a row is actually
        -- written. An archetype whose frames all stood still this step leaves
        -- its Sprite column clean, which is what the renderer skips on. The
        -- Sprite column is read from the first row, because deciding whether a
        -- row needs writing means comparing against what it already holds.
        local marked = false
        local sprites <const> = archetype:get(Sprite)
        local wrote = false
        -- Absent on every archetype that turns about its middle, which is
        -- most of them. A pivot follows the slice it names and a slice moves
        -- from frame to frame, so it is rewritten exactly when the frame is.
        local pivots <const> = archetype:get(Pivot)
        local moved = false
        -- Sheets are few and neighbouring rows tend to share one.
        local cachedId = 0
        local cached: Sheet = nil

        for row = 1, length do
            local instance = animations[row]
            local sheetId = instance.sheet as integer
            if sheetId ~= cachedId then
                cached = sheet.byId(sheetId)
                cachedId = sheetId
            end
            local source = cached

            if source ~= nil then
                local tagId <const> = instance.tag as integer
                local time = instance.time
                local completed, looped = false, false
                -- Whether time moved this step. Everything below the advance
                -- turns on it, because a row whose time stood still shows the
                -- frame it already showed.
                local advanced = false

                -- The cycle is the sum of the durations of the frames the tag
                -- visits, which the sheet worked out when it was built: a
                -- pingpong tag counts the frames it passes twice twice, and a
                -- hold frame lengthens it by exactly its own duration. Read
                -- inside the test rather than above it, so a row that is not
                -- playing costs no table index to find that out.
                local speed <const> = instance.speed
                local cycle <const> = (instance.playing and speed > 0) and (source._cycle[tagId] or 0.0) or 0.0

                if cycle > 0 then
                    advanced = true
                    if not marked then
                        archetype:getMut(Animation)
                        marked = true
                    end
                    -- A one-shot parks at the end of its cycle and stops, so
                    -- finding one there and playing is something that set
                    -- `playing` back to true. That reads as asking for the
                    -- animation again, and it starts over: advancing from the
                    -- end instead would park it again on this step and on every
                    -- step after it, emitting Completed each time, forever.
                    if not instance.loop and time >= cycle then
                        time = 0.0
                    end
                    time = time + dt * speed
                    if time >= cycle then
                        if instance.loop then
                            time = time % cycle
                            looped = true
                        else
                            -- Parked one whole cycle in, which the lookup below
                            -- reads as the last step. Holding the time rather
                            -- than the index keeps one field the answer.
                            time = cycle
                            instance.playing = false
                            completed = true
                        end
                    end
                    instance.time = time
                end

                -- A frame is a region of an image, not a region on its own, so
                -- a sheet bound to another image moves the quad's layer as well
                -- as its UVs. The layer is compared rather than assumed to
                -- follow the frame index, because a sheet swapped under an
                -- entity can land on the index the last one left behind and the
                -- quad would go on sampling the old image with the new rect.
                --
                -- An unbound sheet names no image, so it writes the region
                -- alone and leaves whatever the entity's Sprite already had.
                local slot <const> = source._slot
                -- Three things can put a different frame on a row: time
                -- moving, the row never having had one, and the sheet having
                -- been bound to another image since it was written. All three
                -- are comparisons, where answering them the long way is a scan
                -- of the tag's cycle and a handful of writes into the Sprite
                -- column. Most sprites in a large world are standing still at
                -- any moment, and this is what stops them costing what a
                -- playing one does.
                if advanced or instance.frame == 0 or (slot >= 0 and sprites[row].slot ~= slot) then
                    local frame <const> = source:frameAt(tagId, time)
                    local target <const> = sprites[row]
                    local changed <const> = frame ~= instance.frame
                    if changed or (slot >= 0 and target.slot ~= slot) then
                        if changed then
                            if not marked then
                                archetype:getMut(Animation)
                                marked = true
                            end
                            instance.frame = frame
                        end
                        if not wrote then
                            archetype:getMut(Sprite)
                            wrote = true
                        end
                        local base <const> = (frame - 1) * 4
                        local uvs <const> = source._uvs
                        target.u0 = uvs[base + 1]
                        target.v0 = uvs[base + 2]
                        target.u1 = uvs[base + 3]
                        target.v1 = uvs[base + 4]
                        if slot >= 0 then
                            target.image = source._image
                            target.slot = slot
                        end
                    end

                    -- A slice bound to another sheet is left where it is: the
                    -- frame index counts through this sheet's frames and means
                    -- nothing in another's, so resolving there would move the
                    -- pivot to whatever that index happened to name.
                    if pivots ~= nil and changed then
                        local pivot <const> = pivots[row]
                        local slice <const> = pivot.slice as integer
                        if slice > 0 and pivot.sheet as integer == sheetId then
                            if not moved then
                                archetype:getMut(Pivot)
                                moved = true
                            end
                            pivot.x, pivot.y = source:pivotOf(slice, frame)
                        end
                    end
                end

                if completed and wantsCompleted then
                    world:emit(0, animation.Completed, entities[row], source, source:tagName(tagId))
                elseif looped and wantsLooped then
                    world:emit(0, animation.Looped, entities[row], source, source:tagName(tagId))
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Playback on the GPU
-------------------------------------------------------------------------------

--- Whether `plugin` installs the encoder rather than the advance system.
local useGPU = true

function animation.useGPU(enabled: boolean)
    useGPU = enabled == true
end

function animation.usesGPU(): boolean
    return useGPU
end

--- Writes what each row is playing into its `Sprite`.
---
--- What the GPU reads is not a frame but an animation, a start and a rate, so
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
            -- Sheets are few and neighbouring rows tend to share one, and a
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
                        -- asked for it again. It starts over, exactly as the
                        -- host path does and for the same reason: advancing
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
                        -- Parked where the host path parks it, one whole cycle
                        -- in, so a later encode holds the last frame rather
                        -- than starting the cycle again. The shader is already
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

-------------------------------------------------------------------------------
-- Asking what an entity is showing
-------------------------------------------------------------------------------

--- Where an entity's animation has got to, as a sheet, a tag and a time.
---
--- One function behind both queries below, so the two cannot answer from
--- different places. With playback on the host the component carries the time
--- and this hands it over; with playback on the GPU the `Sprite` carries a
--- start and a rate and the time comes out of them and the clock.
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

    if not useGPU or not world:has(entity, Sprite) then
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
    local ticks = rate == 0.0 and target.v0 or (world:fixedStepCount() - target.v0) * rate
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

    if useGPU then
        -- Not a logic query: a paused entity still has to be told it is
        -- holding, and one that has never been encoded still has to be
        -- encoded. Which of the two it is decides the rate, so they are two
        -- queries rather than one and a test per row.
        local running <const> = world:query({
            name = "tecs.EncodedSprites",
            include = {Animation, Sprite},
            exclude = {ecs.builtins.Paused},
        })
        local paused <const> = world:query({
            name = "tecs.EncodedPausedSprites",
            include = {Animation, Sprite, ecs.builtins.Paused},
        })

        -- The step count each update began on, which is the count the last one
        -- ended at because nothing between two updates moves it.
        local began = world:fixedStepCount()

        -- `PostUpdate` rather than a render phase, so this lands before
        -- extraction whatever order the renderer and this plugin were
        -- installed in.
        world:addSystem({
            name = "tecs.EncodeAnimation",
            phase = ecs.phases.PostUpdate,
            run = function() encode(world, running, false, began); encode(world, paused, true, began) end,
        })

        -- Beside the encoder rather than in the fixed phases, because what says
        -- whether an entity crossed its cycle is the encoding, and the encoding
        -- for an entity that only just started playing is written above. A
        -- window of steps rather than one step: an update that ran several
        -- fixed steps reports one crossing over all of them, which is the
        -- contract `Looped` already had.
        local subscribed <const> = world:query({
            name = "tecs.AnimationSubscribers",
            include = {Animation, Sprite, AnimationEvents},
        })
        world:addSystem({
            name = "tecs.ReportAnimation",
            phase = ecs.phases.PostUpdate,
            run = function()
                local clock <const> = world:fixedStepCount()
                if clock ~= began then
                    report(world, subscribed, began, clock)
                    began = clock
                end
            end,
        })
        return
    end

    local animated <const> = world:query({
        name = "tecs.AnimatedSprites",
        type = "logic",
        include = {Animation, Sprite},
    })

    world:addSystem({
        name = "tecs.AdvanceAnimation",
        phase = ecs.phases.FixedPostUpdate,
        run = function(dt: number) advance(world, animated, dt) end,
    })
end

return animation
