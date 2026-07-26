local tecs <const> = require("tecs")
local tecsInternal <const> = require("tecs.internal.types")
local tweeneval <const> = require("tecs2d.sequence.internal.tweeneval")

local type World = tecs.World
local type WorldImpl = tecsInternal.WorldImpl
local type Component = tecs.Component
local type ControlSelector = string | Timeline

-- Curves, targets, tracking sources, and the slot loop are the sequencer's
-- evaluation core. What is left here is the scheduling around them: what a
-- timeline is, when a playback advances, and how it ends.
local type OperationKind = tweeneval.OperationKind
local type EasingName = tweeneval.EasingName
local type EasingFunction = tweeneval.EasingFunction
local type TargetName = tweeneval.TargetName
local type Target = tweeneval.Target
local type TrackSource = tweeneval.TrackSource
local type TrackSourceImpl = tweeneval.TrackSourceImpl
local type Slot = tweeneval.Slot
local type TweenSlotState = tweeneval.TweenSlotState

local EASINGS <const> = tweeneval.easings
local evaluateSlots <const> = tweeneval.evaluateSlots

local enum PlaybackMode
    "once"
    "loop"
    "pingPong"
end

local record PlaybackOptions
    --- Playback mode. Defaults to "once".
    mode: PlaybackMode
    --- Pass count for finite loop/ping-pong playback.
    count: integer
    --- Playback speed multiplier. Defaults to 1.
    speed: number
    --- Delay before playback begins, in seconds.
    delay: number
end

local record RunOptions
    --- Nested timeline playback mode. Defaults to "once".
    mode: PlaybackMode
    --- Pass count for the nested timeline.
    count: integer
end

local type TimelineNode = {any}

local record EmitSlot
    time: number
    name: string
    order: integer
end

local record RunSlot
    timeline: TimelineImpl
    timelineId: integer
    startTime: number
    effectiveDuration: number
    mode: PlaybackMode
    passCount: integer
end

--- Sequential timeline nodes with an optional replacement channel.
local record TimelineSpec is {TimelineNode}
    --- Playing another timeline on this channel cancels the current one.
    channel: string
end

--- An immutable compiled tween timeline.
local interface Timeline
    --- Play this timeline on an entity.
    play: function(self: Timeline, world: World, entity: integer, options?: PlaybackOptions): integer
end

--- Runtime representation of a compiled tween timeline.
local record TimelineImpl is Timeline
    slots: {Slot}
    runs: {RunSlot}
    emits: {EmitSlot}
    totalDuration: number
    stateSize: integer
    channel: string
    presetName: string
    pinned: boolean

end

local record Cursor
    --- Identifies this playback for its whole life, so a waiter can tell
    --- one run of a timeline from another on the same entity and channel.
    playbackId: integer
    timelineId: integer
    stateSize: integer
    state: {TweenSlotState}
    children: {Cursor}
    elapsed: number
    direction: integer
    mode: PlaybackMode
    remainingPasses: integer
    nextEmit: integer
    rate: number
    paused: boolean
    delay: number
    completed: boolean
    cancelled: boolean
    _lastCycleIndex: integer
end

--- Component present while an entity has active tween playback.
local interface TweenPlayback is tecs.Component end

--- Snapshot-durable runtime playback state.
local record TweenPlaybackImpl is TweenPlayback
    cursors: {Cursor}
end

--- Event emitted by an `emit` timeline node.
local record TweenEvent is tecs.Event
    --- Entity whose timeline emitted the event.
    entity: integer
    --- Authored event name.
    name: string
    --- Timeline channel, when present.
    channel: string | nil
    --- Runtime timeline template id.
    timelineId: integer

    init: function(self: TweenEvent, entity: integer, name: string, channel: string | nil, timelineId: integer)
end

--- Event emitted after one root timeline playback completes.
local record TweenComplete is tecs.Event
    --- Entity whose timeline completed.
    entity: integer
    --- Timeline channel, when present.
    channel: string | nil
    --- Runtime timeline template id.
    timelineId: integer
    --- The playback token `play` returned for this run.
    playback: integer

    init: function(self: TweenComplete, entity: integer, channel: string | nil, timelineId: integer, playback: integer)
end

--- Why a playback ended without completing.
local enum CancelReason
    --- `tween.cancel` matched it.
    "cancelled"
    --- Another playback took over its channel.
    "replaced"
    --- Its entity died, or lost its playback component.
    "targetLost"
end

--- Event emitted when a root timeline playback ends without completing.
---
--- Every playback ends exactly once, with either this or `TweenComplete`,
--- so a waiter on a token always hears back.
local record TweenCancelled is tecs.Event
    --- Entity whose timeline ended.
    entity: integer
    --- Timeline channel, when present.
    channel: string | nil
    --- Runtime timeline template id.
    timelineId: integer
    --- The playback token `play` returned for this run.
    playback: integer
    --- Why it ended.
    reason: CancelReason

    init: function(self: TweenCancelled, entity: integer, channel: string | nil, timelineId: integer, playback: integer, reason: CancelReason)
end

function TweenEvent.init(e: TweenEvent, entity: integer, name: string, channel: string | nil, timelineId: integer)
    e.entity = entity
    e.name = name
    e.channel = channel
    e.timelineId = timelineId
end

function TweenComplete.init(e: TweenComplete, entity: integer, channel: string | nil, timelineId: integer, playback: integer)
    e.entity = entity
    e.channel = channel
    e.timelineId = timelineId
    e.playback = playback
end

function TweenCancelled.init(e: TweenCancelled, entity: integer, channel: string | nil, timelineId: integer, playback: integer, reason: CancelReason)
    e.entity = entity
    e.channel = channel
    e.timelineId = timelineId
    e.playback = playback
    e.reason = reason
end

local record Registry
    nextId: integer
    --- Monotonic playback token, handed out by `play`.
    nextPlaybackId: integer
    byId: {integer: TimelineImpl}
    refcounts: {integer: integer}
    objectIds: {TimelineImpl: integer}
    named: {string: integer}
end

local REGISTRY <const>: tecs.Key<Registry> = tecs.newKey("tecs2d.tween.registry")
local SNAPSHOT_DATA_KEY <const> = "tecs2d.tween.registry"

local record tween
    --- Root playback behavior.
    type PlaybackMode = PlaybackMode
    --- Name of a built-in easing curve.
    type EasingName = EasingName
    --- Function mapping normalized progress to eased progress.
    type EasingFunction = EasingFunction
    --- Name of a built-in component-field target.
    type TargetName = TargetName
    --- Component-field animation target.
    type Target = Target
    --- Live component-field tracking source.
    type TrackSource = TrackSource
    --- Compiled immutable timeline.
    type Timeline = Timeline
    --- One authored timeline operation.
    type TimelineNode = TimelineNode
    --- Sequential list of authored timeline operations.
    type TimelineSpec = TimelineSpec
    --- Root playback options.
    type PlaybackOptions = PlaybackOptions
    --- Nested timeline playback options.
    type RunOptions = RunOptions
    --- Component present while an entity has active tween playback.
    TweenPlayback: TweenPlayback
    --- Component selecting a dynamic tracking source entity.
    TrackingTarget: tweeneval.TrackingTarget
    --- Event emitted by authored `emit` nodes.
    TweenEvent: TweenEvent
    --- Event emitted when root playback completes.
    TweenComplete: TweenComplete
    --- Event emitted when root playback ends without completing.
    TweenCancelled: TweenCancelled
    --- Why a playback ended without completing.
    type CancelReason = CancelReason

    --- Linear easing.
    linear: EasingFunction
    --- Quadratic ease-in.
    quadIn: EasingFunction
    --- Quadratic ease-out.
    quadOut: EasingFunction
    --- Quadratic ease-in-out.
    quadInOut: EasingFunction
    --- Quadratic ease-out-in.
    quadOutIn: EasingFunction
    --- Cubic ease-in.
    cubicIn: EasingFunction
    --- Cubic ease-out.
    cubicOut: EasingFunction
    --- Cubic ease-in-out.
    cubicInOut: EasingFunction
    --- Cubic ease-out-in.
    cubicOutIn: EasingFunction
    --- Quartic ease-in.
    quartIn: EasingFunction
    --- Quartic ease-out.
    quartOut: EasingFunction
    --- Quartic ease-in-out.
    quartInOut: EasingFunction
    --- Quartic ease-out-in.
    quartOutIn: EasingFunction
    --- Quintic ease-in.
    quintIn: EasingFunction
    --- Quintic ease-out.
    quintOut: EasingFunction
    --- Quintic ease-in-out.
    quintInOut: EasingFunction
    --- Quintic ease-out-in.
    quintOutIn: EasingFunction
    --- Sinusoidal ease-in.
    sineIn: EasingFunction
    --- Sinusoidal ease-out.
    sineOut: EasingFunction
    --- Sinusoidal ease-in-out.
    sineInOut: EasingFunction
    --- Sinusoidal ease-out-in.
    sineOutIn: EasingFunction
    --- Exponential ease-in.
    expoIn: EasingFunction
    --- Exponential ease-out.
    expoOut: EasingFunction
    --- Exponential ease-in-out.
    expoInOut: EasingFunction
    --- Exponential ease-out-in.
    expoOutIn: EasingFunction
    --- Overshooting ease-in.
    backIn: EasingFunction
    --- Overshooting ease-out.
    backOut: EasingFunction
    --- Overshooting ease-in-out.
    backInOut: EasingFunction
    --- Overshooting ease-out-in.
    backOutIn: EasingFunction
    --- Elastic ease-in.
    elasticIn: EasingFunction
    --- Elastic ease-out.
    elasticOut: EasingFunction
    --- Elastic ease-in-out.
    elasticInOut: EasingFunction
    --- Elastic ease-out-in.
    elasticOutIn: EasingFunction
    --- Bouncing ease-in.
    bounceIn: EasingFunction
    --- Bouncing ease-out.
    bounceOut: EasingFunction
    --- Bouncing ease-in-out.
    bounceInOut: EasingFunction
    --- Bouncing ease-out-in.
    bounceOutIn: EasingFunction

    --- Target one numeric field.
    field: function(component: Component, fieldName: string): Target
    --- Target two numeric fields together.
    field2: function(component: Component, fieldA: string, fieldB: string): Target
    --- Target an angle using the shortest rotation.
    angle: function(component: Component, fieldName: string): Target
    --- Infer a scalar or pair target from one or two field names.
    target: function(component: Component, field: string | {string}): Target
    --- Track fields on the tweened entity.
    sourceSelf: function(component: Component, field: string | {string}): TrackSource
    --- Track fields on the entity registered under a world key.
    sourceKey: function(key: string, component: Component, field: string | {string}): TrackSource
    --- Track fields selected by the entity's TrackingTarget component.
    sourceTrackingTarget: function(component: Component, field: string | {string}): TrackSource
    --- Track fields on the target of a relationship component.
    sourceRelationship: function(relationship: Component, component: Component, field: string | {string}): TrackSource

    --- Built-in Transform.x target.
    translateX: Target
    --- Built-in Transform.y target.
    translateY: Target
    --- Built-in Transform x/y target.
    translateXY: Target
    --- Built-in Transform.rotation target.
    rotation: Target
    --- Built-in shortest-path Transform.rotation target.
    rotationShortest: Target
    --- Built-in Transform.scaleX target.
    scaleX: Target
    --- Built-in Transform.scaleY target.
    scaleY: Target
    --- Built-in Transform scale x/y target.
    scaleXY: Target
    --- Built-in Color alpha target.
    alpha: Target
    --- Built-in Color RGBA target.
    color: Target

    --- Animate to absolute target values.
    to: function(
        duration: number, easing: EasingName | EasingFunction, target: TargetName | Target,
        t1: number, t2?: number, t3?: number, t4?: number
    ): TimelineNode
    --- Animate by relative target deltas.
    adjust: function(
        duration: number, easing: EasingName | EasingFunction, target: TargetName | Target,
        t1: number, t2?: number, t3?: number, t4?: number
    ): TimelineNode
    --- Animate toward values read continuously from another source.
    track: function(
        duration: number, easing: EasingName | EasingFunction, target: TargetName | Target,
        source: TrackSource
    ): TimelineNode
    --- Advance the timeline cursor without changing a component.
    wait: function(duration: number): TimelineNode
    --- Emit a named TweenEvent at the cursor position.
    emit: function(name: string): TimelineNode
    --- Run a nested timeline.
    run: function(timeline: Timeline, options?: RunOptions): TimelineNode
    --- Run nodes concurrently.
    parallel: function(...: TimelineNode): TimelineNode
    --- Compile an authored timeline specification.
    timeline: function(spec: TimelineSpec): Timeline
    --- Register a snapshot-safe named timeline preset in one world.
    registerPreset: function(world: World, name: string, timeline: Timeline): Timeline
    --- Play a compiled timeline or named preset on an entity.
    --- @return A token identifying this playback, carried by the
    --- `TweenComplete` or `TweenCancelled` event that ends it.
    play: function(world: World, entity: integer, timelineOrName: Timeline | string, options?: PlaybackOptions): integer
    --- Cancel matching playback; selector may be a channel, preset, or timeline.
    cancel: function(world: World, entity: integer, selector?: ControlSelector)
    --- Whether a playback token is still running on an entity.
    isPlaying: function(world: World, entity: integer, playback: integer): boolean
    --- Pause matching playback.
    pause: function(world: World, entity: integer, selector?: ControlSelector)
    --- Resume matching playback.
    resume: function(world: World, entity: integer, selector?: ControlSelector)
    --- Install tween playback and snapshot integration in a world.
    plugin: function(world: World)
end

-------------------------------------------------------------------------------
-- Easing
-------------------------------------------------------------------------------

-- Every curve is a top-level field here, and the same set is a namespace on
-- the evaluation core. Copied by name so adding a curve there needs no edit
-- beyond the field declaration above.
do
    local tw = tween as {string: EasingFunction}
    for name, fn in pairs(EASINGS) do
        tw[name as string] = fn
    end
end

-------------------------------------------------------------------------------
-- Components and events
-------------------------------------------------------------------------------

local function serializeState(state: {TweenSlotState}, count: integer): {{number}}
    local out: {{number}} = {}
    for i = 0, count - 1 do
        local s <const> = state[i]
        out[i + 1] = {s.init, s.applied, s.lastT, s.s1, s.s2, s.s3, s.s4, s.d1, s.d2, s.d3, s.d4}
    end
    return out
end

local function deserializeState(rows: {{number}}): {TweenSlotState}
    local count = rows and #rows or 0
    local state = tweeneval.newState(count)
    for i = 1, count do
        local row <const> = rows[i]
        local s <const> = state[i - 1]
        s.init = row[1] or 0
        s.applied = row[2] or 0
        s.lastT = row[3] or 0
        s.s1 = row[4] or 0
        s.s2 = row[5] or 0
        s.s3 = row[6] or 0
        s.s4 = row[7] or 0
        s.d1 = row[8] or 0
        s.d2 = row[9] or 0
        s.d3 = row[10] or 0
        s.d4 = row[11] or 0
    end
    return state
end

local function serializeCursor(c: Cursor): {string:any}
    local children: {{string:any}} = nil
    if c.children then
        children = {}
        for i = 1, #c.children do
            children[i] = serializeCursor(c.children[i])
        end
    end
    local data: {string:any} = {
        playbackId = c.playbackId,
        timelineId = c.timelineId,
        elapsed = c.elapsed,
        direction = c.direction,
        mode = c.mode,
        remainingPasses = c.remainingPasses,
        nextEmit = c.nextEmit,
        rate = c.rate,
        paused = c.paused,
        delay = c.delay,
        completed = c.completed,
        cancelled = c.cancelled,
        lastCycleIndex = c._lastCycleIndex,
        stateSize = c.stateSize,
        state = serializeState(c.state, c.stateSize),
        children = children,
    }
    return data
end

local function deserializeCursor(data: {string:any}): Cursor
    local children: {Cursor} = nil
    local savedChildren = data.children as {{string:any}}
    if savedChildren then
        children = {}
        for i = 1, #savedChildren do
            children[i] = deserializeCursor(savedChildren[i])
        end
    end
    return {
        playbackId = data.playbackId as integer,
        timelineId = data.timelineId as integer,
        stateSize = (data.stateSize as integer) or #(data.state as {{number}} or {}),
        state = deserializeState(data.state as {{number}}),
        children = children,
        elapsed = (data.elapsed as number) or 0,
        direction = (data.direction as integer) or 1,
        mode = assert(data.mode as PlaybackMode, "Tween snapshot cursor mode is required"),
        remainingPasses = assert(data.remainingPasses as integer,
            "Tween snapshot cursor remainingPasses is required"),
        nextEmit = (data.nextEmit as integer) or 1,
        rate = (data.rate as number) or 1,
        paused = data.paused == true,
        delay = (data.delay as number) or 0,
        completed = data.completed == true,
        cancelled = data.cancelled == true,
        _lastCycleIndex = (data.lastCycleIndex as integer) or 0,
    }
end

tween.TweenPlayback = tecs.newComponent({
    name = "TweenPlayback",
    container = TweenPlaybackImpl,
    new = function(data: {string:any}): TweenPlaybackImpl
        local cursors: {Cursor} = {}
        local saved = data and (data.cursors as {{string:any}})
        if saved then
            for i = 1, #saved do
                cursors[i] = deserializeCursor(saved[i])
            end
        end
        return { cursors = cursors } as TweenPlaybackImpl
    end,
    serialize = function(instance: TweenPlaybackImpl): {string:any}
        local cursors: {{string:any}} = {}
        for i = 1, #(instance.cursors or {}) do
            cursors[i] = serializeCursor(instance.cursors[i])
        end
        return { cursors = cursors }
    end,
})

tween.TrackingTarget = tweeneval.TrackingTarget

tween.TweenEvent = TweenEvent
tween.TweenComplete = TweenComplete
tween.TweenCancelled = TweenCancelled
tecs.newEvent(TweenEvent)
tecs.newEvent(TweenComplete)
tecs.newEvent(TweenCancelled)

-------------------------------------------------------------------------------
-- Targets and tracking sources
-------------------------------------------------------------------------------

tween.field = tweeneval.target.field
tween.field2 = tweeneval.target.field2
tween.angle = tweeneval.target.angle
tween.target = tweeneval.target.of
tween.sourceSelf = tweeneval.source.own
tween.sourceKey = tweeneval.source.key
tween.sourceTrackingTarget = tweeneval.source.tracking
tween.sourceRelationship = tweeneval.source.related

tween.translateX = tweeneval.target.translateX
tween.translateY = tweeneval.target.translateY
tween.translateXY = tweeneval.target.translateXY
tween.rotation = tweeneval.target.rotation
tween.rotationShortest = tweeneval.target.rotationShortest
tween.scaleX = tweeneval.target.scaleX
tween.scaleY = tweeneval.target.scaleY
tween.scaleXY = tweeneval.target.scaleXY
tween.alpha = tweeneval.target.alpha
tween.color = tweeneval.target.color

-------------------------------------------------------------------------------
-- Template serialization
-------------------------------------------------------------------------------

local serializeTarget <const> = tweeneval.serializeTarget
local deserializeTarget <const> = tweeneval.deserializeTarget
local serializeSource <const> = tweeneval.serializeSource
local deserializeSource <const> = tweeneval.deserializeSource

local function serializeTimeline(tl: Timeline): {string:any}
    local impl <const> = tl as TimelineImpl
    local slots: {{string:any}} = {}
    for i = 1, #(impl.slots or {}) do
        local s <const> = impl.slots[i]
        slots[i] = {
            kind = s.kind,
            target = serializeTarget(s.target),
            source = serializeSource(s.source),
            easing = s.easingName,
            t1 = s.t1, t2 = s.t2, t3 = s.t3, t4 = s.t4,
            relative = s.relative,
            startTime = s.startTime,
            endTime = s.endTime,
            duration = s.duration,
            stateIndex = s.stateIndex,
        }
    end
    local runs: {{string:any}} = nil
    if impl.runs then
        runs = {}
        for i = 1, #impl.runs do
            local r <const> = impl.runs[i]
            runs[i] = {
                timelineId = r.timelineId,
                timeline = r.timeline and serializeTimeline(r.timeline) or nil,
                startTime = r.startTime,
                effectiveDuration = r.effectiveDuration,
                mode = r.mode,
                passCount = r.passCount,
            }
        end
    end
    return {
        slots = slots,
        runs = runs,
        emits = impl.emits,
        totalDuration = impl.totalDuration,
        stateSize = impl.stateSize,
        channel = impl.channel,
        presetName = impl.presetName,
        pinned = impl.pinned,
    }
end

local TIMELINE_MT <const>: metatable<TimelineImpl> = { __index = TimelineImpl }

local function deserializeTimeline(data: {string:any}): TimelineImpl
    local slots: {Slot} = {}
    local savedSlots = data.slots as {{string:any}}
    for i = 1, #(savedSlots or {}) do
        local s <const> = savedSlots[i]
        local easingName <const> = s.easing as EasingName
        slots[i] = {
            kind = (s.kind as OperationKind) or "to",
            target = deserializeTarget(s.target as {string:any}),
            source = deserializeSource(s.source as {string:any}),
            easingName = easingName,
            easing = assert(EASINGS[easingName], "Unknown tween easing " .. tostring(easingName)),
            t1 = (s.t1 as number) or 0,
            t2 = (s.t2 as number) or 0,
            t3 = (s.t3 as number) or 0,
            t4 = (s.t4 as number) or 0,
            relative = s.relative == true,
            startTime = (s.startTime as number) or 0,
            endTime = (s.endTime as number) or 0,
            duration = (s.duration as number) or 0,
            stateIndex = (s.stateIndex as integer) or (i - 1),
        }
    end
    local runs: {RunSlot} = nil
    local savedRuns = data.runs as {{string:any}}
    if savedRuns then
        runs = {}
        for i = 1, #savedRuns do
            local r <const> = savedRuns[i]
            runs[i] = {
                timeline = r.timeline and deserializeTimeline(r.timeline as {string:any}) or nil,
                timelineId = (r.timelineId as integer) or 0,
                startTime = (r.startTime as number) or 0,
                effectiveDuration = (r.effectiveDuration as number) or 0,
                mode = assert(r.mode as PlaybackMode, "Tween snapshot run mode is required"),
                passCount = assert(r.passCount as integer, "Tween snapshot run passCount is required"),
            }
        end
    end
    return setmetatable({
        slots = slots,
        runs = runs,
        emits = data.emits as {EmitSlot},
        totalDuration = (data.totalDuration as number) or 0,
        stateSize = (data.stateSize as integer) or #slots,
        channel = data.channel as string,
        presetName = data.presetName as string,
        pinned = data.pinned == true,
    } as TimelineImpl, TIMELINE_MT)
end

-------------------------------------------------------------------------------
-- Registry
-------------------------------------------------------------------------------

local function newRegistry(): Registry
    return {
        nextId = 1,
        nextPlaybackId = 1,
        byId = {},
        refcounts = {},
        objectIds = setmetatable({} as {TimelineImpl: integer}, { __mode = "k" }),
        named = {},
    }
end

local function registry(world: World): Registry
    local r = world.resources[REGISTRY]
    if not r then
        r = newRegistry()
        world.resources[REGISTRY] = r
    end
    return r
end

local function internTimeline(world: World, tl: TimelineImpl): integer
    local reg <const> = registry(world)
    local existing = reg.objectIds[tl]
    if existing then return existing end
    if tl.presetName then
        local named = reg.named[tl.presetName]
        if named then
            reg.objectIds[tl] = named
            return named
        end
    end
    local id <const> = reg.nextId
    reg.nextId = id + 1
    reg.byId[id] = tl
    reg.objectIds[tl] = id
    reg.refcounts[id] = 0
    if tl.presetName then
        reg.named[tl.presetName] = id
        tl.pinned = true
    end
    if tl.runs then
        for i = 1, #tl.runs do
            tl.runs[i].timelineId = internTimeline(world, tl.runs[i].timeline)
        end
    end
    return id
end

local function incRef(reg: Registry, id: integer)
    reg.refcounts[id] = (reg.refcounts[id] or 0) + 1
end

local function decRef(reg: Registry, id: integer)
    local tl = reg.byId[id]
    if not tl then return end
    local n = (reg.refcounts[id] or 0) - 1
    if n > 0 then
        reg.refcounts[id] = n
        return
    end
    reg.refcounts[id] = 0
    if tl.pinned then return end
    reg.byId[id] = nil
    reg.objectIds[tl] = nil
    reg.refcounts[id] = nil
end

local function restoreRegistry(world: World, data: {string:any})
    local reg = newRegistry()
    local maxId = 0
    local templates = data and (data.templates as {{string:any}})
    if templates then
        for i = 1, #templates do
            local item <const> = templates[i]
            local id <const> = item.id as integer
            local tl <const> = deserializeTimeline(item.timeline as {string:any})
            reg.byId[id] = tl
            -- Register the object identity too: a later play of a restored
            -- preset must resolve to this entry rather than interning a
            -- duplicate template.
            reg.objectIds[tl] = id
            reg.refcounts[id] = 0
            if tl.presetName then reg.named[tl.presetName] = id end
            if id > maxId then maxId = id end
        end
    end
    -- Rewire nested run() children to the registered instances via their
    -- saved timelineIds, so replaying a restored timeline reuses them
    -- instead of interning fresh copies on every save/load/play cycle.
    for _, tl in pairs(reg.byId) do
        if tl.runs then
            for i = 1, #tl.runs do
                local run = tl.runs[i]
                if run.timelineId and reg.byId[run.timelineId] then
                    run.timeline = reg.byId[run.timelineId]
                end
            end
        end
    end
    reg.nextId = maxId + 1
    -- Tokens keep counting up across a load, so a handle saved before the
    -- snapshot cannot be reissued to a different playback after it.
    reg.nextPlaybackId = (data and (data.nextPlaybackId as integer)) or 1
    world.resources[REGISTRY] = reg
end

-------------------------------------------------------------------------------
-- Cursor methods and playback creation
-------------------------------------------------------------------------------

local function playbackMode(mode?: PlaybackMode, count?: integer, finite?: boolean): PlaybackMode, integer
    local resolved <const> = mode or "once"
    assert(resolved == "once" or resolved == "loop" or resolved == "pingPong",
        "Tween mode must be once, loop, or pingPong")
    if resolved == "once" then
        assert(count == nil, "Tween count is only valid with loop or pingPong mode")
        return resolved, 1
    end
    if count ~= nil then
        assert(count > 0, "Tween count must be greater than 0")
        return resolved, count
    end
    assert(not finite, "Nested loop and pingPong runs require a finite count")
    return resolved, -1
end

local function createCursor(
    world: World,
    tl: TimelineImpl,
    target: integer,
    mode: PlaybackMode,
    passCount: integer,
    rate: number,
    delay: number
): Cursor
    local id <const> = internTimeline(world, tl)
    local state = tweeneval.newState(tl.stateSize)
    local children: {Cursor} = nil
    if tl.runs then
        children = {}
        for i = 1, #tl.runs do
            local run <const> = tl.runs[i]
            children[i] = createCursor(world, run.timeline, target, run.mode, run.passCount, 1, 0)
        end
    end
    incRef(registry(world), id)
    return {
        timelineId = id,
        stateSize = tl.stateSize,
        state = state,
        children = children,
        elapsed = 0,
        direction = 1,
        mode = mode,
        remainingPasses = passCount,
        nextEmit = 1,
        rate = rate,
        delay = delay or 0,
        _lastCycleIndex = 0,
    }
end

local function playbackFor(world: World, entity: integer): TweenPlaybackImpl
    local pb = world:getMut(entity, TweenPlaybackImpl)
    if pb then return pb end
    -- A prior play in this defer scope may already have staged the component.
    -- Read through the ECS transaction before creating another staged value.
    pb = (world as WorldImpl):oldValueOf(entity, TweenPlaybackImpl) as TweenPlaybackImpl
    if pb then return pb end
    local created <const> = TweenPlaybackImpl.new({})
    world:set(entity, created)
    return created
end

local function cursorTimeline(world: World, c: Cursor): TimelineImpl
    return registry(world).byId[c.timelineId]
end

-- A playback ends exactly once. Every path that ends one early routes
-- through here, so a waiter on a token always hears back, and hears back
-- once.
local function endCursor(world: World, entity: integer, c: Cursor, reason: CancelReason)
    if c.cancelled then return end
    c.cancelled = true
    local tl <const> = cursorTimeline(world, c)
    world:emit(0, TweenCancelled, entity, tl and tl.channel or nil,
        c.timelineId, c.playbackId, reason)
end

local function addCursor(world: World, entity: integer, tl: TimelineImpl, options?: PlaybackOptions): Cursor
    local pb <const> = playbackFor(world, entity)
    if tl.channel then
        for i = 1, #(pb.cursors or {}) do
            local existing <const> = pb.cursors[i]
            local etl <const> = cursorTimeline(world, existing)
            if etl and etl.channel == tl.channel then
                endCursor(world, entity, existing, "replaced")
            end
        end
    end
    local mode, passCount = playbackMode(options and options.mode, options and options.count)
    local speed <const> = options and options.speed or 1
    local delay <const> = options and options.delay or 0
    assert(speed > 0, "Tween speed must be greater than 0")
    assert(delay >= 0, "Tween delay must be at least 0")
    assert(passCount == 1 or tl.totalDuration > 0, "Repeating tween timelines must have a duration")
    local c <const> = createCursor(
        world, tl, entity, mode, passCount,
        speed, delay
    )
    local reg <const> = registry(world)
    c.playbackId = reg.nextPlaybackId
    reg.nextPlaybackId = c.playbackId + 1
    pb.cursors[#pb.cursors + 1] = c
    return c
end

function TimelineImpl:play(world: World, entity: integer, options?: PlaybackOptions): integer
    return addCursor(world, entity, self, options).playbackId
end

function tween.play(
    world: World,
    entity: integer,
    timelineOrName: Timeline | string,
    options?: PlaybackOptions
): integer
    if timelineOrName is string then
        local id = registry(world).named[timelineOrName]
        if not id then error("Unknown tween preset " .. timelineOrName) end
        return addCursor(world, entity, registry(world).byId[id], options).playbackId
    end
    return addCursor(world, entity, timelineOrName as TimelineImpl, options).playbackId
end

local function selectorTimelineId(world: World, selector: Timeline): integer
    local impl <const> = selector as TimelineImpl
    local reg <const> = registry(world)
    local id = reg.objectIds[impl]
    if id then return id end
    if impl.presetName then return reg.named[impl.presetName] end
    return nil
end

local function matchesCursor(world: World, c: Cursor, selector?: ControlSelector): boolean
    if not selector then return true end
    local tl = cursorTimeline(world, c)
    if not tl then return false end
    if selector is string then
        return tl.channel == selector or tl.presetName == selector
    end
    local id = selectorTimelineId(world, selector as Timeline)
    return id ~= nil and c.timelineId == id
end

function tween.cancel(world: World, entity: integer, selector?: ControlSelector)
    local pb = world:get(entity, TweenPlaybackImpl)
    if not pb then return end
    local mutable: TweenPlaybackImpl = nil
    for i = 1, #(pb.cursors or {}) do
        if matchesCursor(world, pb.cursors[i], selector) then
            if not mutable then mutable = world:getMut(entity, TweenPlaybackImpl) end
            endCursor(world, entity, mutable.cursors[i], "cancelled")
        end
    end
end

function tween.isPlaying(world: World, entity: integer, playback: integer): boolean
    if not world:isAlive(entity) then return false end
    local pb = world:get(entity, TweenPlaybackImpl)
    if not pb then return false end
    for i = 1, #(pb.cursors or {}) do
        local c = pb.cursors[i]
        if c.playbackId == playback then return not c.cancelled end
    end
    return false
end

function tween.pause(world: World, entity: integer, selector?: ControlSelector)
    local pb = world:get(entity, TweenPlaybackImpl)
    if not pb then return end
    local mutable: TweenPlaybackImpl = nil
    for i = 1, #(pb.cursors or {}) do
        if not pb.cursors[i].paused and matchesCursor(world, pb.cursors[i], selector) then
            if not mutable then mutable = world:getMut(entity, TweenPlaybackImpl) end
            mutable.cursors[i].paused = true
        end
    end
end

function tween.resume(world: World, entity: integer, selector?: ControlSelector)
    local pb = world:get(entity, TweenPlaybackImpl)
    if not pb then return end
    local mutable: TweenPlaybackImpl = nil
    for i = 1, #(pb.cursors or {}) do
        if pb.cursors[i].paused and matchesCursor(world, pb.cursors[i], selector) then
            if not mutable then mutable = world:getMut(entity, TweenPlaybackImpl) end
            mutable.cursors[i].paused = false
        end
    end
end

-------------------------------------------------------------------------------
-- Timeline compilation
-------------------------------------------------------------------------------

local resolveEasing <const> = tweeneval.resolveEasing
local resolveTargetValue <const> = tweeneval.resolveTargetValue

local function numericValue(value: any, position: integer): number
    if value == nil then return 0 end
    assert(value is number, "Tween value at position " .. tostring(position) .. " must be a number")
    return value as number
end

function tween.to(
    duration: number, easing: EasingName | EasingFunction, target: TargetName | Target,
    t1: number, t2?: number, t3?: number, t4?: number
): TimelineNode
    return {"to", duration, easing, target, t1, t2, t3, t4}
end

function tween.adjust(
    duration: number, easing: EasingName | EasingFunction, target: TargetName | Target,
    t1: number, t2?: number, t3?: number, t4?: number
): TimelineNode
    return {"adjust", duration, easing, target, t1, t2, t3, t4}
end

function tween.track(
    duration: number, easing: EasingName | EasingFunction,
    target: TargetName | Target, trackingSource: TrackSource
): TimelineNode
    return {"track", duration, easing, target, trackingSource}
end

function tween.wait(duration: number): TimelineNode
    return {"wait", duration}
end

function tween.emit(name: string): TimelineNode
    return {"emit", name}
end

function tween.run(timeline: Timeline, options?: RunOptions): TimelineNode
    return {"run", timeline, options}
end

function tween.parallel(...: TimelineNode): TimelineNode
    local node: {any} = {"parallel"}
    for i = 1, select("#", ...) do
        node[i + 1] = select(i, ...)
    end
    return node
end

local compileNode: function(TimelineNode, number, TimelineImpl): number

local function compileBlock(block: {TimelineNode}, startTime: number, tl: TimelineImpl): number
    local time = startTime
    for i = 1, #block do
        time = compileNode(block[i], time, tl)
    end
    return time
end

local function compileSlot(node: TimelineNode, startTime: number, tl: TimelineImpl): number
    local compiled <const> = (node as any) as {any:any}
    local authoredKind <const> = compiled[1] as OperationKind
    local duration <const> = compiled[2] as number
    assert(duration and duration > 0, "Tween duration must be greater than 0")
    local easingName, easingFn = resolveEasing(compiled[3])
    local target <const> = resolveTargetValue(compiled[4])
    assert(target, "Tween target is required")

    compiled.kind = authoredKind == "track" and "track" or "to"
    compiled.target = target
    compiled.source = authoredKind == "track" and (compiled[5] as TrackSourceImpl) or nil
    compiled.easingName = easingName
    compiled.easing = easingFn
    compiled.t1 = authoredKind == "track" and 0 or numericValue(compiled[5], 5)
    compiled.t2 = authoredKind == "track" and 0 or numericValue(compiled[6], 6)
    compiled.t3 = authoredKind == "track" and 0 or numericValue(compiled[7], 7)
    compiled.t4 = authoredKind == "track" and 0 or numericValue(compiled[8], 8)
    compiled.relative = authoredKind == "adjust"
    compiled.startTime = startTime
    compiled.endTime = startTime + duration
    compiled.duration = duration
    compiled.stateIndex = #tl.slots

    tl.slots[#tl.slots + 1] = node as Slot
    return compiled.endTime as number
end

compileNode = function(node: TimelineNode, startTime: number, tl: TimelineImpl): number
    local data <const> = (node as any) as {any:any}
    assert(data, "Tween timeline entry is required")
    local kind <const> = data[1]
    if kind is table then
        return compileBlock(data as {TimelineNode}, startTime, tl)
    end
    assert(kind is string, "Tween operation name must be a string")

    if kind == "to" or kind == "adjust" or kind == "track" then
        return compileSlot(node, startTime, tl)
    elseif kind == "wait" then
        local duration <const> = data[2] as number
        assert(duration and duration >= 0, "Tween wait duration must be at least 0")
        return startTime + duration
    elseif kind == "emit" then
        local name <const> = data[2] as string
        assert(name, "Tween emit name is required")
        data.time = startTime
        data.name = name
        data.order = #tl.emits + 1
        tl.emits[#tl.emits + 1] = node as EmitSlot
        return startTime
    elseif kind == "run" then
        local child <const> = data[2] as TimelineImpl
        assert(child and child.totalDuration, "Tween run requires a compiled timeline")
        local options <const> = data[3] as RunOptions
        local mode, passCount = playbackMode(options and options.mode, options and options.count, true)
        local duration <const> = child.totalDuration * passCount
        data.timeline = child
        data.startTime = startTime
        data.effectiveDuration = duration
        data.mode = mode
        data.passCount = passCount
        tl.runs[#tl.runs + 1] = node as RunSlot
        return startTime + duration
    elseif kind == "parallel" then
        local endTime = startTime
        local children <const> = data as {any}
        for i = 2, #children do
            local childEnd <const> = compileNode(children[i] as TimelineNode, startTime, tl)
            if childEnd > endTime then endTime = childEnd end
        end
        return endTime
    end
    error("Unknown tween operation " .. kind)
end

function tween.timeline(spec: TimelineSpec): Timeline
    local authored <const> = spec as {any:any}
    assert(authored.sequence == nil, "Tween timelines use an implicit sequence")
    local tl <const> = spec as TimelineImpl
    tl.slots = {}
    tl.runs = {}
    tl.emits = {}
    tl.totalDuration = compileBlock(spec, 0, tl)
    tl.stateSize = #tl.slots
    if #tl.runs == 0 then tl.runs = nil end
    if #tl.emits == 0 then
        tl.emits = nil
    else
        table.sort(tl.emits, function(a: EmitSlot, b: EmitSlot): boolean
            return a.time < b.time or (a.time == b.time and a.order < b.order)
        end)
    end
    return setmetatable(tl, TIMELINE_MT) as Timeline
end

function tween.registerPreset(world: World, name: string, timeline: Timeline): Timeline
    local impl <const> = timeline as TimelineImpl
    assert(name ~= "", "Tween preset name must not be empty")
    local reg <const> = registry(world)
    local existingId <const> = reg.named[name]
    if existingId then
        assert(reg.byId[existingId] == impl, "Tween preset " .. name .. " is already registered")
        return timeline
    end
    assert(not impl.presetName or impl.presetName == name,
        "Tween timeline is already registered as " .. tostring(impl.presetName))
    impl.presetName = name
    impl.pinned = true
    local id <const> = internTimeline(world, impl)
    reg.named[name] = id
    return timeline
end

-------------------------------------------------------------------------------
-- Evaluation
-------------------------------------------------------------------------------

local function fireEmits(c: Cursor, tl: TimelineImpl, world: World, target: integer, elapsed: number)
    local emits <const> = tl.emits
    if not emits then return end
    while c.nextEmit <= #emits do
        local evDef <const> = emits[c.nextEmit]
        if elapsed >= evDef.time then
            c.nextEmit = c.nextEmit + 1
            world:emit(0, TweenEvent, target, evDef.name, tl.channel, c.timelineId)
        else
            break
        end
    end
end

local evaluateCursor: function(Cursor, World, integer)
local resetCursorCycle: function(Cursor, World)

local function beginRunCycle(
    child: Cursor, childTl: TimelineImpl, runSlot: RunSlot, cycleIndex: integer, world: World
)
    if runSlot.mode == "loop" or cycleIndex % 2 == 0 then
        resetCursorCycle(child, world)
    end
    child.direction = runSlot.mode == "pingPong" and cycleIndex % 2 == 1 and -1 or 1
    if child.direction == -1 then
        child.nextEmit = (childTl.emits and #childTl.emits or 0) + 1
    else
        child.nextEmit = 1
    end
    child._lastCycleIndex = cycleIndex
    child.remainingPasses = runSlot.passCount - cycleIndex
end

local function evaluateRun(
    child: Cursor, childTl: TimelineImpl, runSlot: RunSlot,
    localElapsed: number, world: World, target: integer
)
    local cycleDuration <const> = childTl.totalDuration
    if cycleDuration <= 0 then return end

    local atEnd <const> = localElapsed >= runSlot.effectiveDuration
    local cycleIndex = atEnd and (runSlot.passCount - 1) or math.floor(localElapsed / cycleDuration)
    local cyclePos = atEnd and cycleDuration or (localElapsed % cycleDuration)

    if cycleIndex > child._lastCycleIndex then
        for completedCycle = child._lastCycleIndex, cycleIndex - 1 do
            child.elapsed = runSlot.mode == "pingPong" and completedCycle % 2 == 1 and 0 or cycleDuration
            evaluateCursor(child, world, target)
            beginRunCycle(child, childTl, runSlot, completedCycle + 1, world)
        end
    elseif cycleIndex < child._lastCycleIndex then
        child._lastCycleIndex = cycleIndex
        child.direction = runSlot.mode == "pingPong" and cycleIndex % 2 == 1 and -1 or 1
    end

    if runSlot.mode == "pingPong" and cycleIndex % 2 == 1 then
        cyclePos = cycleDuration - cyclePos
    end
    child.elapsed = cyclePos
    child.remainingPasses = runSlot.passCount - cycleIndex
    evaluateCursor(child, world, target)
    child.completed = atEnd
end

evaluateCursor = function(c: Cursor, world: World, target: integer)
    local tl <const> = cursorTimeline(world, c)
    if not tl then return end
    evaluateSlots(tl.slots, c.state, world, target, c.elapsed)
    fireEmits(c, tl, world, target, c.elapsed)
    if tl.runs and c.children then
        for i = 1, #tl.runs do
            local runSlot <const> = tl.runs[i]
            local child <const> = c.children[i]
            local runStart <const> = runSlot.startTime
            local runEnd <const> = runStart + runSlot.effectiveDuration
            local childTl <const> = cursorTimeline(world, child)
            if childTl and c.elapsed >= runStart and c.elapsed <= runEnd then
                evaluateRun(child, childTl, runSlot, c.elapsed - runStart, world, target)
            elseif childTl and c.elapsed > runEnd and not child.completed then
                evaluateRun(child, childTl, runSlot, runSlot.effectiveDuration, world, target)
            end
        end
    end
end

resetCursorCycle = function(c: Cursor, world: World)
    local tl <const> = cursorTimeline(world, c)
    if not tl then return end
    tweeneval.clearState(c.state, tl.stateSize)
    c.elapsed = 0
    c.direction = 1
    c.nextEmit = 1
    c.completed = false
    c._lastCycleIndex = 0
    if c.children then
        for i = 1, #c.children do
            resetCursorCycle(c.children[i], world)
        end
    end
end

local function advanceCursor(c: Cursor, dt: number, world: World, target: integer): boolean
    if c.paused then return false end
    local tl <const> = cursorTimeline(world, c)
    if not tl then return true end
    if c.delay > 0 then
        c.delay = c.delay - dt
        if c.delay > 0 then return false end
        dt = -c.delay
        c.delay = 0
    end
    local totalDuration <const> = tl.totalDuration
    if totalDuration <= 0 then
        evaluateCursor(c, world, target)
        world:emit(0, TweenComplete, target, tl.channel, c.timelineId, c.playbackId)
        return true
    end

    local remainingTime = dt * c.rate
    if remainingTime <= 0 then
        evaluateCursor(c, world, target)
        return false
    end

    while remainingTime > 0 do
        local distance <const> = c.direction == 1 and (totalDuration - c.elapsed) or c.elapsed
        if remainingTime < distance then
            c.elapsed = c.elapsed + remainingTime * c.direction
            evaluateCursor(c, world, target)
            return false
        end

        c.elapsed = c.direction == 1 and totalDuration or 0
        evaluateCursor(c, world, target)
        remainingTime = remainingTime - distance

        if c.remainingPasses == -1 or c.remainingPasses > 1 then
            if c.remainingPasses > 1 then c.remainingPasses = c.remainingPasses - 1 end
            if c.mode == "pingPong" then
                c.direction = -c.direction
                if c.direction == 1 then
                    resetCursorCycle(c, world)
                end
            else
                resetCursorCycle(c, world)
            end
        else
            world:emit(0, TweenComplete, target, tl.channel, c.timelineId, c.playbackId)
            return true
        end
    end

    return false
end

local function releaseCursor(reg: Registry, c: Cursor)
    if c.children then
        for i = 1, #c.children do
            releaseCursor(reg, c.children[i])
        end
    end
    decRef(reg, c.timelineId)
end

-------------------------------------------------------------------------------
-- Snapshot registry and plugin
-------------------------------------------------------------------------------

local function collectLiveTemplateIds(world: World, playbackQuery: tecs.Query): {integer:boolean}
    local live: {integer:boolean} = {}
    local reg = registry(world)
    local function markTemplate(id: integer)
        if live[id] then return end
        local tl <const> = reg.byId[id]
        if not tl then return end
        live[id] = true
        if tl.runs then
            for i = 1, #tl.runs do
                markTemplate(tl.runs[i].timelineId)
            end
        end
    end
    for archetype, len in playbackQuery:iter() do
        local playbacks = archetype:get(TweenPlaybackImpl)
        for i = 1, len do
            local pb = playbacks[i]
            for j = 1, #(pb.cursors or {}) do
                local function mark(c: Cursor)
                    markTemplate(c.timelineId)
                    if c.children then
                        for k = 1, #c.children do mark(c.children[k]) end
                    end
                end
                mark(pb.cursors[j])
            end
        end
    end
    for id, tl in pairs(reg.byId) do
        if tl.pinned then markTemplate(id) end
    end
    return live
end

function tween.plugin(world: World)
    if world.resources[REGISTRY] then return end
    world.resources[REGISTRY] = newRegistry()

    local playbackQuery = world:query({
        name = "tween.Playbacks",
        include = {TweenPlaybackImpl},
        onEntitiesRemoved = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
            local reg = registry(world)
            local playbacks = archetype:get(TweenPlaybackImpl)
            local entities = archetype.entities
            for row = firstRow, lastRow do
                local pb = playbacks[row]
                if pb then
                    for i = 1, #(pb.cursors or {}) do
                        -- Losing the component, usually with the entity,
                        -- ends anything still running on it.
                        endCursor(world, entities[row] as integer, pb.cursors[i], "targetLost")
                        releaseCursor(reg, pb.cursors[i])
                    end
                end
            end
        end
    })

    world:observe(0, tecs.builtins.OnSnapshotSave, function(ev: tecs.builtins.OnSnapshotSave)
        local reg <const> = registry(world)
        local live <const> = collectLiveTemplateIds(world, playbackQuery)
        local templates: {{string:any}} = {}
        for id, _ in pairs(live) do
            local tl = reg.byId[id]
            if tl then
                templates[#templates + 1] = { id = id, timeline = serializeTimeline(tl) }
            end
        end
        ev:addData(SNAPSHOT_DATA_KEY, {
            nextId = reg.nextId,
            nextPlaybackId = reg.nextPlaybackId,
            templates = templates,
        })
    end)

    world:observe(0, tecs.builtins.StartSnapshotLoad, function(ev: tecs.builtins.StartSnapshotLoad)
        ev:onData(SNAPSHOT_DATA_KEY, function(value: any)
            restoreRegistry(world, value as {string:any})
        end)
    end)

    world:observe(0, tecs.builtins.FinishSnapshotLoad, function()
        local reg <const> = registry(world)
        reg.refcounts = {}
        for archetype, len in playbackQuery:iter() do
            -- Rebuilding the registry reads cursor ids but does not mutate
            -- playback components.
            local playbacks = archetype:get(TweenPlaybackImpl)
            for i = 1, len do
                local pb = playbacks[i]
                for j = 1, #(pb.cursors or {}) do
                    local function rebuild(c: Cursor)
                        incRef(reg, c.timelineId)
                        if c.children then
                            for k = 1, #c.children do rebuild(c.children[k]) end
                        end
                    end
                    rebuild(pb.cursors[j])
                end
            end
        end
    end)

    -- Reused across frames: entities whose playback emptied this tick
    -- (component removal is deferred until after query iteration).
    local emptyEntities: {integer} = {}
    world:addSystem({
        name = "tween.Update",
        phase = tecs.phases.Update,
        run = function(dt: number)
            local reg <const> = registry(world)
            local emptyCount = 0
            for archetype, len, entities in playbackQuery:iter() do
                local playbacks = archetype:getMut(TweenPlaybackImpl)
                for i = 1, len do
                    local entity <const> = entities[i]
                    local pb = playbacks[i]
                    local cursors = pb.cursors
                    for cidx = #cursors, 1, -1 do
                        local c = cursors[cidx]
                        if not c.cancelled and not world:isAlive(entity) then
                            endCursor(world, entity, c, "targetLost")
                        end
                        local remove = c.cancelled
                        if not remove then
                            remove = advanceCursor(c, dt, world, entity)
                        end
                        if remove then
                            releaseCursor(reg, c)
                            table.remove(cursors, cidx)
                        end
                    end
                    if #cursors == 0 then
                        emptyCount = emptyCount + 1
                        emptyEntities[emptyCount] = entity
                    end
                end
            end
            for i = 1, emptyCount do
                if world:isAlive(emptyEntities[i]) then
                    world:remove(emptyEntities[i], TweenPlaybackImpl)
                end
                emptyEntities[i] = nil
            end
        end
    })
end

return tween
