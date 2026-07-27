--- Sprite-sheet playback.
---
--- An `Animation` says which tag of a sheet is playing, how fast, whether it
--- repeats, whether it is running, and where in the tag it has got to. The
--- system installed by `animation.plugin` advances it and writes the frame's
--- region into the entity's `Sprite`, which is what the renderer reads.
---
--- Playback advances in the fixed phases, because animation is simulation. Two
--- machines fed the same recording have to show the same frame, and a system
--- driven by frame time shows a different one on the machine that drew more
--- frames. `FixedPostUpdate` is late enough that gameplay logic in
--- `FixedUpdate` has already chosen what should be playing.
---
--- The component carries a sheet id rather than a sheet. A component is plain
--- C memory and a sheet is a table, and the indirection is the point besides:
--- every entity playing one walk cycle shares one sheet.
---
--- An entity carrying a `Pivot` bound to one of the sheet's slices has it
--- resolved again on every frame the sprite changes, because an Aseprite slice
--- moves from frame to frame and a pivot that did not follow it would drift
--- off the part of the drawing it names.

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

local TICK_HZ <const> = frametable.TICK_HZ

--- Playback rate an animation runs at when nothing says otherwise, which is
--- the timing the sheet's frames were authored with.
local DEFAULT_SPEED <const> = 1.0

--- Playback state for one entity.
---
--- `frame` is the frame the `Sprite` was last written from, as an index into
--- the whole sheet rather than into the tag. Zero means nothing has been
--- written yet, which is how a fresh or restored Animation gets its region on
--- the first step it runs instead of drawing whatever the Sprite held.
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
    --- Frame the Sprite currently shows, or zero for none yet.
    frame: number
    --- Whether the tag restarts after its last frame.
    loop: boolean
    --- Whether time advances.
    playing: boolean
end

--- Emitted at address zero on the step a tag that does not loop runs past its
--- last frame. The animation stops and holds that frame, so this fires once per
--- playthrough and never again until something restarts it.
local record Completed is ecs.Event
    entity: integer
    sheet: Sheet
    --- Name of the tag that finished, or the empty string for a whole sheet.
    tag: string

    metamethod __call: function(
        self, entity: integer, sheet: Sheet, tag: string
    ): Completed
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

    metamethod __call: function(
        self, entity: integer, sheet: Sheet, tag: string
    ): Looped
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

local record animation
    type PlayOptions = PlayOptions

    --- Playback state for one entity.
    Animation: Animation

    --- Emitted when a tag that does not loop runs past its last frame.
    Completed: Completed

    --- Emitted when a looping tag passes its last frame and restarts.
    Looped: Looped

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
    --- where nothing changed what is playing.
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
    --- Set before `plugin`, since it decides which system that installs. Worlds
    --- already carrying one keep it.
    --- @param enabled Defaults to false while this is being measured against
    ---     the host path.
    useGPU: function(enabled: boolean)

    --- Whether playback resolves on the GPU.
    usesGPU: function(): boolean
end

ecs.newFFIComponent({
    name = "Animation",
    container = Animation,
    fields = {
        { "sheet", "int32_t" },
        { "tag", "int32_t" },
        { "speed", "float" },
        { "time", "float" },
        { "frame", "int32_t" },
        { "loop", "bool" },
        { "playing", "bool" },
    },
    defaults = { 0, 0, DEFAULT_SPEED, 0, 0, true, true },
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
        return Animation(id, tag, data.speed as number, data.time as number,
            0, data.loop as boolean, data.playing as boolean)
    end,
})

animation.Animation = Animation
animation.Completed = Completed
animation.Looped = Looped

animation.Completed.init = function(event: Completed, entity: integer,
                                    source: Sheet, tag: string)
    event.entity, event.sheet, event.tag = entity, source, tag
end
ecs.newEvent(animation.Completed)

animation.Looped.init = function(event: Looped, entity: integer,
                                 source: Sheet, tag: string)
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
    if loop == nil then loop = true end
    local playing = options.playing
    if playing == nil then playing = true end
    return Animation(source.id, tagId, options.speed or DEFAULT_SPEED,
        0.0, 0, loop, playing)
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
    if not world:has(entity, Animation) then return false end
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
                local cycle <const> = (instance.playing and speed > 0)
                    and (source._cycle[tagId] or 0.0) or 0.0

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
                if advanced or instance.frame == 0
                    or (slot >= 0 and sprites[row].slot ~= slot) then
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
                    world:emit(0, animation.Completed, entities[row], source,
                        source:tagName(tagId))
                elseif looped and wantsLooped then
                    world:emit(0, animation.Looped, entities[row], source,
                        source:tagName(tagId))
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Playback on the GPU
-------------------------------------------------------------------------------

--- Whether `plugin` installs the encoder rather than the advance system.
local useGPU = false

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
local function encode(world: World, query: Query, held: boolean)
    local timestep <const> = world:getFixedTiming()
    local clock <const> = world:fixedStepCount()

    for archetype, length in query:iter() do
        if archetype:isComponentDirty(Animation) then
            local animations <const> = archetype:get(Animation)
            local sprites <const> = archetype:getMut(Sprite)
            -- Sheets are few and neighbouring rows tend to share one, and a
            -- crowd playing one cycle shares the tag as well.
            local cachedId = 0
            local cachedTag = -1
            local cached: Sheet = nil
            local playback = 0

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
                    if tagId ~= cachedTag then
                        cachedTag = tagId
                        playback = frametable.register(cached, tagId)
                    end

                    -- Where in the cycle the entity is, in ticks. `time` is
                    -- what the host path advances and what a snapshot carries,
                    -- so reading the phase from it is what makes the two paths
                    -- interchangeable and a restored entity resume where it was.
                    local ticks <const> = instance.time * TICK_HZ
                    local speed <const> = instance.speed
                    local running <const> = not held and instance.playing
                        and speed > 0.0
                    if running then
                        local rate <const> = timestep * speed * TICK_HZ
                        frametable.encode(sprites[row], playback,
                            clock - ticks / rate, rate, instance.loop)
                    else
                        frametable.encode(sprites[row], playback, ticks, 0.0,
                            instance.loop)
                    end
                end
            end
        end
    end
end

--- Worlds the plugin has already installed into.
local installed: {World: boolean} =
    setmetatable({}, { __mode = "k" } as metatable<{World: boolean}>)

function animation.plugin(world: World)
    if installed[world] then return end
    installed[world] = true

    if useGPU then
        -- Not a logic query: a paused entity still has to be told it is
        -- holding, and one that has never been encoded still has to be
        -- encoded. Which of the two it is decides the rate, so they are two
        -- queries rather than one and a test per row.
        local running <const> = world:query({
            name = "tecs.EncodedSprites",
            include = { Animation, Sprite },
            exclude = { ecs.builtins.Paused },
        })
        local paused <const> = world:query({
            name = "tecs.EncodedPausedSprites",
            include = { Animation, Sprite, ecs.builtins.Paused },
        })

        -- `PostUpdate` rather than a render phase, so this lands before
        -- extraction whatever order the renderer and this plugin were
        -- installed in.
        world:addSystem({
            name = "tecs.EncodeAnimation",
            phase = ecs.phases.PostUpdate,
            run = function()
                encode(world, running, false)
                encode(world, paused, true)
            end,
        })
        return
    end

    local animated <const> = world:query({
        name = "tecs.AnimatedSprites",
        type = "logic",
        include = { Animation, Sprite },
    })

    world:addSystem({
        name = "tecs.AdvanceAnimation",
        phase = ecs.phases.FixedPostUpdate,
        run = function(dt: number)
            advance(world, animated, dt)
        end,
    })
end

return animation
