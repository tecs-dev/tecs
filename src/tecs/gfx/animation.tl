--- Sprite-sheet playback.
---
--- An `Animation` says which range of a sheet is playing, how fast, whether it
--- repeats, whether it is running, and where in the range it has got to. The
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

local ecs <const> = require("tecs.ecs")
local components <const> = require("tecs.components")
local sheet <const> = require("tecs.gfx.sheet")

local type Component = ecs.Component
local type World = ecs.World
local type Query = ecs.Query
local type Sheet = sheet.Sheet

local Sprite <const> = components.Sprite

local floor <const> = math.floor

--- Playback state for one entity.
---
--- `frame` is the frame the `Sprite` was last written from, as an index into
--- the whole sheet rather than into the range. Zero means nothing has been
--- written yet, which is how a fresh or restored Animation gets its region on
--- the first step it runs instead of drawing whatever the Sprite held.
---
--- `time` is seconds into the range's cycle and stays inside it: a looping
--- animation wraps and a one-shot parks at the end, so it never grows without
--- bound and never loses precision to its own age.
local record Animation is Component
    --- Registration index of the sheet, from `Sheet.id`. Zero plays nothing.
    sheet: number
    --- Index of the range within that sheet, from `Sheet:rangeId`. Zero plays
    --- the whole sheet in order.
    range: number
    --- Frames per second. Zero or less holds the first frame.
    fps: number
    --- Seconds into the cycle.
    time: number
    --- Frame the Sprite currently shows, or zero for none yet.
    frame: number
    --- Whether the range restarts after its last frame.
    loop: boolean
    --- Whether time advances.
    playing: boolean
end

--- Emitted at address zero when a range that does not loop reaches its last
--- frame. The animation stops there, so this fires once per playthrough.
local record Completed is ecs.Event
    entity: integer
    sheet: Sheet
    --- Name of the range that finished, or the empty string for a whole sheet.
    range: string

    metamethod __call: function(
        self, entity: integer, sheet: Sheet, range: string
    ): Completed
end

--- Emitted at address zero when a looping range passes its last frame and
--- restarts. Fires once per wrap.
local record Looped is ecs.Event
    entity: integer
    sheet: Sheet
    --- Name of the range that wrapped, or the empty string for a whole sheet.
    range: string

    metamethod __call: function(
        self, entity: integer, sheet: Sheet, range: string
    ): Looped
end

--- How an animation should play.
local record PlayOptions
    --- Frames per second. Defaults to `sheet.DEFAULT_FPS`.
    fps: number
    --- Whether the range restarts after its last frame. Defaults to true.
    loop: boolean
    --- Whether it starts running. Defaults to true.
    playing: boolean
end

local record animation
    type PlayOptions = PlayOptions

    --- Playback state for one entity.
    Animation: Animation

    --- Emitted when a range that does not loop reaches its last frame.
    Completed: Completed

    --- Emitted when a looping range passes its last frame and restarts.
    Looped: Looped

    --- An Animation playing a named range of a sheet, ready to spawn.
    of: function(
        source: Sheet, range?: string, options?: PlayOptions
    ): Animation

    --- Points a live entity at a range and restarts it there.
    play: function(
        world: World, entity: integer, source: Sheet,
        range?: string, options?: PlayOptions
    )

    --- Adds the system that advances playback.
    plugin: function(world: World)
end

ecs.newFFIComponent({
    name = "Animation",
    container = Animation,
    fields = {
        { "sheet", "int32_t" },
        { "range", "int32_t" },
        { "fps", "float" },
        { "time", "float" },
        { "frame", "int32_t" },
        { "loop", "bool" },
        { "playing", "bool" },
    },
    defaults = { 0, 0, sheet.DEFAULT_FPS, 0, 0, true, true },
    -- A sheet id and a range id are this process's answers, decided by the
    -- order sheets were built in. What crosses a save is the pair of names,
    -- resolved again on the way back in. The frame is deliberately dropped:
    -- zero makes the first step rewrite the Sprite's region, so a restored
    -- entity does not depend on the region its Sprite was saved holding.
    serialize = function(instance: Animation): {string: any}
        local source = sheet.byId(instance.sheet as integer)
        local name: string = nil
        local range: string = nil
        if source ~= nil then
            name = source.name
            range = source:rangeName(instance.range as integer)
        end
        return {
            sheet = name,
            range = range,
            fps = instance.fps,
            time = instance.time,
            loop = instance.loop,
            playing = instance.playing,
        }
    end,
    deserialize = function(_world: World, data: {string: any}): Animation
        local source = sheet.byName(data.sheet as string)
        local id, range = 0, 0
        if source ~= nil then
            id = source.id
            range = source:rangeId(data.range as string)
        end
        return Animation(id, range, data.fps as number, data.time as number,
            0, data.loop as boolean, data.playing as boolean)
    end,
})

animation.Animation = Animation
animation.Completed = Completed
animation.Looped = Looped

animation.Completed.init = function(event: Completed, entity: integer,
                                    source: Sheet, range: string)
    event.entity, event.sheet, event.range = entity, source, range
end
ecs.newEvent(animation.Completed)

animation.Looped.init = function(event: Looped, entity: integer,
                                 source: Sheet, range: string)
    event.entity, event.sheet, event.range = entity, source, range
end
ecs.newEvent(animation.Looped)

-------------------------------------------------------------------------------
-- Authoring
-------------------------------------------------------------------------------

--- An Animation playing a named range of a sheet, ready to spawn.
---
--- Omit the range to play the whole sheet in order. Fails on a range the sheet
--- does not carry, since the alternative is a typo that plays every frame.
function animation.of(source: Sheet, range?: string,
                      options?: PlayOptions): Animation
    if source == nil then
        error("tecs: an animation needs a sheet", 2)
    end
    local rangeId = 0
    if range ~= nil then
        -- Fails on a name the sheet does not carry.
        source:range(range)
        rangeId = source:rangeId(range)
    end
    options = options or {}
    local loop = options.loop
    if loop == nil then loop = true end
    local playing = options.playing
    if playing == nil then playing = true end
    return Animation(source.id, rangeId, options.fps or sheet.DEFAULT_FPS,
        0.0, 0, loop, playing)
end

--- Points a live entity at a range and restarts it there.
---
--- Restarting is the point: time and frame both reset, so the next step writes
--- the range's first frame whatever the entity was showing. An entity carrying
--- no Animation gets one.
function animation.play(world: World, entity: integer, source: Sheet,
                        range?: string, options?: PlayOptions)
    local built <const> = animation.of(source, range, options)
    if not world:has(entity, Animation) then
        world:set(entity, built)
        return
    end
    local current <const> = world:getMut(entity, Animation)
    current.sheet = built.sheet
    current.range = built.range
    current.fps = built.fps
    current.time = 0.0
    current.frame = 0
    current.loop = built.loop
    current.playing = built.playing
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
        -- its Sprite column clean, which is what the renderer skips on.
        local marked = false
        local sprites: {components.Sprite} = nil
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
                local rangeId = instance.range as integer
                local from, to = 1, source.count
                local start = source._from[rangeId]
                if start ~= nil then
                    from, to = start, source._to[rangeId]
                end
                local span <const> = to - from + 1

                local fps <const> = instance.fps
                local time = instance.time
                local completed, looped = false, false

                if instance.playing and fps > 0 then
                    if not marked then
                        archetype:getMut(Animation)
                        marked = true
                    end
                    time = time + dt
                    local cycle <const> = span / fps
                    if time >= cycle then
                        if instance.loop then
                            time = time % cycle
                            looped = true
                        else
                            -- Parked one whole cycle in, which the clamp below
                            -- reads as the last frame. Holding the time rather
                            -- than the index keeps one field the answer.
                            time = cycle
                            instance.playing = false
                            completed = true
                        end
                    end
                    instance.time = time
                end

                local index = floor(time * fps)
                if index >= span then
                    index = span - 1
                elseif index < 0 then
                    index = 0
                end

                local frame <const> = from + index
                if frame ~= instance.frame then
                    if not marked then
                        archetype:getMut(Animation)
                        marked = true
                    end
                    instance.frame = frame
                    if sprites == nil then
                        sprites = archetype:getMut(Sprite)
                    end
                    local target = sprites[row]
                    local base <const> = (frame - 1) * 4
                    local uvs <const> = source._uvs
                    target.u0 = uvs[base + 1]
                    target.v0 = uvs[base + 2]
                    target.u1 = uvs[base + 3]
                    target.v1 = uvs[base + 4]
                end

                if completed and wantsCompleted then
                    world:emit(0, animation.Completed, entities[row], source,
                        source:rangeName(rangeId))
                elseif looped and wantsLooped then
                    world:emit(0, animation.Looped, entities[row], source,
                        source:rangeName(rangeId))
                end
            end
        end
    end
end

--- Worlds the plugin has already installed into.
local installed: {World: boolean} =
    setmetatable({}, { __mode = "k" } as metatable<{World: boolean}>)

--- Adds the system that advances playback.
---
--- Not installed for you, so a world that draws no sprite sheets pays nothing
--- for the query. Call it once; a second call on the same world is ignored,
--- because adding a system twice under one name is an error.
---
--- The query is a logic query, so a paused entity holds the frame it is on.
--- Animation runs on the simulation clock and a pause stops the simulation.
function animation.plugin(world: World)
    if installed[world] then return end
    installed[world] = true

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
