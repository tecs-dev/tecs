--- The part of a tween that runs every tick.
---
--- Easing curves, animation targets, tracking sources, and the slot loop that
--- turns elapsed time into component writes. Everything here is about
--- evaluating a value; nothing here knows what a timeline is, how a playback
--- is scheduled, or when it ends.
---
--- It lives under the sequencer rather than beside `tween` because the
--- sequencer is what evaluates it: an `eval` step walks these slots on its
--- clock's active set. Keeping the loop separate from the scheduling around it
--- is what lets one runtime serve both.

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local ffi <const> = require("ffi")
local components <const> = require("tecs.components")
local internalComponents <const> = require("tecs.internal.components")

local mathPi, mathSin, mathCos, mathPow <const> = math.pi, math.sin, math.cos, math.pow

local type World = types.World
local type Component = ecs.Component

--- What one authored timeline entry does.
local enum OperationKind
    "to"
    "adjust"
    "track"
    "wait"
    "emit"
    "run"
    "parallel"
end

--- How a target interpolates the fields it owns.
local enum TargetMode
    "field"
    "field2"
    "angle"
    "color"
end

--- Where a `track` operation reads its moving destination from.
local enum TrackSourceKind
    "self"
    "key"
    "trackingTarget"
    "relationship"
end

--- Name of a built-in easing curve.
local enum EasingName
    "linear"
    "quadIn"
    "quadOut"
    "quadInOut"
    "quadOutIn"
    "cubicIn"
    "cubicOut"
    "cubicInOut"
    "cubicOutIn"
    "quartIn"
    "quartOut"
    "quartInOut"
    "quartOutIn"
    "quintIn"
    "quintOut"
    "quintInOut"
    "quintOutIn"
    "sineIn"
    "sineOut"
    "sineInOut"
    "sineOutIn"
    "expoIn"
    "expoOut"
    "expoInOut"
    "expoOutIn"
    "backIn"
    "backOut"
    "backInOut"
    "backOutIn"
    "elasticIn"
    "elasticOut"
    "elasticInOut"
    "elasticOutIn"
    "bounceIn"
    "bounceOut"
    "bounceInOut"
    "bounceOutIn"
end

--- Name of a built-in component-field target.
local enum TargetName
    "transform.x"
    "transform.y"
    "transform.xy"
    "transform.rotation"
    "transform.rotationShortest"
    "transform.scaleX"
    "transform.scaleY"
    "transform.scaleXY"
    "color.a"
    "color.rgba"
end

-- Per-slot working state. One flat struct so a whole playback's state is a
-- single contiguous allocation the evaluation loop indexes rather than a
-- table per slot.
ffi.cdef([[
    typedef struct {
        double init;
        double applied;
        double lastT;
        double s1;
        double s2;
        double s3;
        double s4;
        double d1;
        double d2;
        double d3;
        double d4;
    } TweenSlotState;
]])

local record TweenSlotState
    init: number
    applied: number
    lastT: number
    s1: number
    s2: number
    s3: number
    s4: number
    d1: number
    d2: number
    d3: number
    d4: number
end

--- Function mapping normalized progress to eased progress.
local type EasingFunction = function(t: number): number

--- A component-field animation target.
local interface Target
end

--- Runtime target descriptor used by the tween compiler and evaluator.
local record TargetImpl is Target
    --- Stable serialized target identity.
    id: string
    --- Component whose fields are animated.
    component: Component
    --- Serialized component name.
    componentName: string
    --- Fields animated by this target.
    fields: {string}
    --- Target interpolation behavior.
    mode: TargetMode

    init: function(
        world: World, entity: integer, relative: boolean, t1: number, t2: number, t3: number, t4: number
    ): number, number, number, number, number, number, number, number

    apply: function(
        world: World,
        entity: integer,
        t: number,
        s1: number,
        s2: number,
        s3: number,
        s4: number,
        d1: number,
        d2: number,
        d3: number,
        d4: number
    )
end

--- A live component-field tracking source.
local interface TrackSource
end

--- Runtime tracking descriptor used by the tween evaluator.
local record TrackSourceImpl is TrackSource
    kind: TrackSourceKind
    key: string
    relationship: Component
    relationshipName: string
    component: Component
    componentName: string
    fields: {string}
end

-- Structural value returned for a targeted relationship instance. The
-- generic public Relationship container type intentionally does not expose
-- instance storage fields.
local interface RelationshipValue
    target: integer
end

--- One compiled interpolation: a target, a curve, and the window of the
--- timeline it covers.
local record Slot
    kind: OperationKind
    target: TargetImpl
    source: TrackSourceImpl
    easingName: EasingName
    easing: EasingFunction
    t1: number
    t2: number
    t3: number
    t4: number
    relative: boolean
    startTime: number
    endTime: number
    duration: number
    stateIndex: integer
end

--- Root playback behavior.
local enum PlaybackMode
    "once"
    "loop"
    "pingPong"
end

--- Nested timeline playback options.
local record RunOptions
    --- Nested timeline playback mode. Defaults to "once".
    mode: PlaybackMode
    --- Pass count for the nested timeline.
    count: integer
end

--- One authored timeline operation. Opaque; do not reuse a node across
--- timelines, because compiling one writes its resolved form into it.
local type TimelineNode = {any}

--- Sequential timeline operations.
local type TimelineSpec = {TimelineNode}

--- A named event the timeline emits when the cursor reaches its time.
local record EmitSlot
    time: number
    name: string
    order: integer
end

--- A nested timeline, and the window of the parent it occupies.
local record RunSlot
    timeline: TimelineImpl
    timelineId: integer
    startTime: number
    effectiveDuration: number
    mode: PlaybackMode
    passCount: integer
end

--- An immutable compiled tween timeline. Playing one is `sequence.play` on
--- the program it compiles to, so there is nothing to call on it directly.
local interface Timeline
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

--- Selects another entity as a dynamic tracking source.
local record TrackingTarget is ecs.Component
    --- Direct source entity, or zero to use key.
    entity: integer
    --- Source entity key used when entity is zero.
    key: string
end

--- The built-in easing curves.
---
--- Every curve maps 0 to 0 and 1 to 1; what varies is the path between them.
--- `In` accelerates, `Out` decelerates, `InOut` does both, and `OutIn` does
--- them in the opposite order.
local record Easings
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
end

--- The built-in animation targets, and the constructors for new ones.
local record Targets
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
    --- Built-in Tint alpha target.
    alpha: Target
    --- Built-in Tint RGBA target.
    color: Target

    --- Target one numeric field.
    field: function(component: Component, fieldName: string): Target
    --- Target two numeric fields together.
    field2: function(component: Component, fieldA: string, fieldB: string): Target
    --- Target an angle using the shortest rotation.
    angle: function(component: Component, fieldName: string): Target
    --- Infer a scalar or pair target from one or two field names.
    of: function(component: Component, field: string | {string}): Target
end

--- Where a `track` operation reads the value it is chasing.
local record Sources
    --- Track fields on the tweened entity itself.
    own: function(component: Component, field: string | {string}): TrackSource
    --- Track fields on the entity registered under a world key.
    key: function(key: string, component: Component, field: string | {string}): TrackSource
    --- Track fields selected by the entity's TrackingTarget component.
    tracking: function(component: Component, field: string | {string}): TrackSource
    --- Track fields on the target of a relationship component.
    related: function(relationship: Component, component: Component, field: string | {string}): TrackSource
end

local record tweeneval
    type OperationKind = OperationKind
    type TargetMode = TargetMode
    type TrackSourceKind = TrackSourceKind
    type EasingName = EasingName
    type EasingFunction = EasingFunction
    type TargetName = TargetName
    type Target = Target
    type TargetImpl = TargetImpl
    type TrackSource = TrackSource
    type TrackSourceImpl = TrackSourceImpl
    type Slot = Slot
    type TweenSlotState = TweenSlotState
    type Easings = Easings
    type Targets = Targets
    type Sources = Sources
    type PlaybackMode = PlaybackMode
    type RunOptions = RunOptions
    type TimelineNode = TimelineNode
    type TimelineSpec = TimelineSpec
    type EmitSlot = EmitSlot
    type RunSlot = RunSlot
    type Timeline = Timeline
    type TimelineImpl = TimelineImpl

    --- Authoring nodes. `to` and `adjust` interpolate to an absolute or a
    --- relative destination; `track` chases one that keeps moving.
    to: function(
        duration: number,
        easing: EasingName | EasingFunction,
        target: TargetName | Target,
        t1: number,
        t2?: number,
        t3?: number,
        t4?: number
    ): TimelineNode
    adjust: function(
        duration: number,
        easing: EasingName | EasingFunction,
        target: TargetName | Target,
        t1: number,
        t2?: number,
        t3?: number,
        t4?: number
    ): TimelineNode
    track: function(
        duration: number, easing: EasingName | EasingFunction, target: TargetName | Target, source: TrackSource
    ): TimelineNode

    --- Advance the cursor without changing anything.
    wait: function(duration: number): TimelineNode

    --- Emit a named event at the cursor position.
    emit: function(name: string): TimelineNode

    --- Run a nested timeline, given as its own spec or already compiled.
    --- Untyped because the two forms are both tables and Teal cannot tell
    --- them apart; `compile` decides by looking for a compiled duration.
    run: function(timeline: any, options?: RunOptions): TimelineNode

    --- Run nodes concurrently, ending when the longest of them does.
    parallel: function(...: TimelineNode): TimelineNode

    --- Compile authored nodes into a timeline.
    compile: function(spec: TimelineSpec): Timeline

    --- Validate a mode and pass count, resolving the defaults. `finite`
    --- rejects an endless repeat, which a nested run cannot express.
    playbackMode: function(mode?: PlaybackMode, count?: integer, finite?: boolean): PlaybackMode, integer

    --- Turn a compiled timeline into plain data, and back. The const pool of
    --- a program carries the first form; the evaluator reads the second.
    serializeTimeline: function(tl: Timeline): {string: any}
    deserializeTimeline: function(data: {string: any}): TimelineImpl

    --- Attach the timeline metatable to a freshly compiled timeline.
    asTimeline: function(tl: TimelineImpl): Timeline

    --- Component selecting a dynamic tracking source entity.
    TrackingTarget: TrackingTarget

    --- The built-in easing curves, by name.
    easing: Easings

    --- The built-in targets, and the constructors for new ones.
    target: Targets

    --- The tracking-source constructors.
    source: Sources

    --- Every built-in easing keyed by its name.
    easings: {EasingName: EasingFunction}

    --- Resolve an authored easing, given either as a name or as one of the
    --- built-in functions, to both.
    resolveEasing: function(value: any): EasingName, EasingFunction

    --- Resolve an authored target, given either as a built-in name or as a
    --- target value.
    resolveTargetValue: function(value: any): TargetImpl

    --- Turn a target or source into plain data, and back. This is the codec a
    --- compiled program's const pool carries.
    serializeTarget: function(t: Target): {string: any}
    deserializeTarget: function(data: {string: any}): TargetImpl
    serializeSource: function(s: TrackSource): {string: any}
    deserializeSource: function(data: {string: any}): TrackSourceImpl

    --- Read the four numbers a `track` slot is currently chasing.
    valuesFromSource: function(world: World, entity: integer, src: TrackSourceImpl): number, number, number, number

    --- Advance every slot to `elapsed`, writing the components they target.
    ---
    --- The whole loop is one instruction body rather than one per slot, so
    --- dispatch amortizes across the slots a timeline holds.
    evaluateSlots: function(slots: {Slot}, state: {TweenSlotState}, world: World, target: integer, elapsed: number)

    --- A zeroed state buffer for `count` slots.
    newState: function(count: integer): {TweenSlotState}

    --- Zero an existing state buffer, which restarts every slot.
    clearState: function(state: {TweenSlotState}, count: integer)
end

-------------------------------------------------------------------------------
-- Easing
-------------------------------------------------------------------------------

local easing: Easings = {}

function easing.linear(t: number): number
    return t
end

local EASING_NAMES: {EasingFunction: EasingName} = {}
local EASINGS: {EasingName: EasingFunction} = {}

local function registerEasing(name: EasingName, fn: EasingFunction)
    EASING_NAMES[fn] = name
    EASINGS[name] = fn
end

local function makeVariants(name: string, inFn: EasingFunction)
    local e = easing as {string: EasingFunction}
    e[name .. "In"] = inFn
    e[name .. "Out"] = function(t: number): number return 1 - inFn(1 - t) end
    e[name .. "InOut"] = function(t: number): number
        if t < 0.5 then
            return 0.5 * inFn(2 * t)
        end
        return 1 - 0.5 * inFn(2 - 2 * t)
    end
    e[name .. "OutIn"] = function(t: number): number
        if t < 0.5 then
            return 0.5 - 0.5 * inFn(1 - 2 * t)
        end
        return 0.5 + 0.5 * inFn(2 * t - 1)
    end
end

makeVariants("quad", function(t: number): number return t * t end)
makeVariants("cubic", function(t: number): number return t * t * t end)
makeVariants("quart", function(t: number): number return t * t * t * t end)
makeVariants("quint", function(t: number): number return t * t * t * t * t end)
makeVariants("sine", function(t: number): number return 1 - mathCos(t * mathPi * 0.5) end)
makeVariants(
    "expo",
    function(t: number): number
        if t == 0 then
            return 0
        end
        return mathPow(2, 10 * (t - 1))
    end
)
makeVariants("back", function(t: number): number local s <const> = 1.70158; return t * t * ((s + 1) * t - s) end)
makeVariants(
    "elastic",
    function(t: number): number
        if t == 0 then
            return 0
        end
        if t == 1 then
            return 1
        end
        local p <const> = 0.3
        return -mathPow(2, 10 * (t - 1)) * mathSin((t - 1 - p / 4) * (2 * mathPi) / p)
    end
)

do
    local function bounceOut(t: number): number
        if t < 1 / 2.75 then
            return 7.5625 * t * t
        elseif t < 2 / 2.75 then
            local u <const> = t - 1.5 / 2.75
            return 7.5625 * u * u + 0.75
        elseif t < 2.5 / 2.75 then
            local u <const> = t - 2.25 / 2.75
            return 7.5625 * u * u + 0.9375
        end
        local u <const> = t - 2.625 / 2.75
        return 7.5625 * u * u + 0.984375
    end
    local function bounceIn(t: number): number
        return 1 - bounceOut(1 - t)
    end
    easing.bounceIn = bounceIn
    easing.bounceOut = bounceOut
    easing.bounceInOut = function(t: number): number
        if t < 0.5 then
            return 0.5 * bounceIn(2 * t)
        end
        return 0.5 * bounceOut(2 * t - 1) + 0.5
    end
    easing.bounceOutIn = function(t: number): number
        if t < 0.5 then
            return 0.5 * bounceOut(2 * t)
        end
        return 0.5 * bounceIn(2 * t - 1) + 0.5
    end
end

do
    local names <const>: {EasingName} = {
        "linear",
        "quadIn",
        "quadOut",
        "quadInOut",
        "quadOutIn",
        "cubicIn",
        "cubicOut",
        "cubicInOut",
        "cubicOutIn",
        "quartIn",
        "quartOut",
        "quartInOut",
        "quartOutIn",
        "quintIn",
        "quintOut",
        "quintInOut",
        "quintOutIn",
        "sineIn",
        "sineOut",
        "sineInOut",
        "sineOutIn",
        "expoIn",
        "expoOut",
        "expoInOut",
        "expoOutIn",
        "backIn",
        "backOut",
        "backInOut",
        "backOutIn",
        "elasticIn",
        "elasticOut",
        "elasticInOut",
        "elasticOutIn",
        "bounceIn",
        "bounceOut",
        "bounceInOut",
        "bounceOutIn",
    }
    local e = easing as {string: EasingFunction}
    for i = 1, #names do
        registerEasing(names[i], e[names[i]])
    end
end

-------------------------------------------------------------------------------
-- Targets and tracking sources
-------------------------------------------------------------------------------

local TARGET_MT <const>: metatable<TargetImpl> = {__index = TargetImpl}
local targetInit: function(
    TargetImpl, World, integer, boolean, number, number, number, number
): (number, number, number, number, number, number, number, number)
local targetApply: function(
    TargetImpl, World, integer, number, number, number, number, number, number, number, number, number
)

local function fieldsFrom(field: string | {string}): {string}
    if field is string then
        return {field}
    end
    return field as {string}
end

local function componentByName(name: string): Component
    local component = internalComponents.registeredComponents[name]
    if not component then
        error("Unknown tween component " .. name)
    end
    return component
end

local function resolveTarget(t: TargetImpl): TargetImpl
    if not t.component and t.componentName then
        t.component = componentByName(t.componentName)
    end
    return t
end

local function newTarget(component: Component, fields: {string}, mode?: TargetMode, id?: string): TargetImpl
    local parts = component.componentName
    for i = 1, #fields do
        parts = parts .. "." .. fields[i]
    end
    local t: TargetImpl = setmetatable({
        id = id or parts,
        component = component,
        componentName = component.componentName,
        fields = fields,
        mode = mode or (#fields == 2 and "field2" or "field"),
    }, TARGET_MT)
    t.init = function(
        world: World, entity: integer, relative: boolean, t1: number, t2: number, t3: number, t4: number
    ): (number, number, number, number, number, number, number, number)
        return targetInit(t, world, entity, relative, t1, t2, t3, t4)
    end
    t.apply = function(
        world: World,
        entity: integer,
        tv: number,
        s1: number,
        s2: number,
        s3: number,
        s4: number,
        d1: number,
        d2: number,
        d3: number,
        d4: number
    )
        targetApply(t, world, entity, tv, s1, s2, s3, s4, d1, d2, d3, d4)
    end
    return t
end

targetInit = function(
    self: TargetImpl, world: World, entity: integer, relative: boolean, t1: number, t2: number, t3: number, t4: number
): number, number, number, number, number, number, number, number
    resolveTarget(self)
    local c = world:get(entity, self.component)
    if not c then
        return 0, 0, 0, 0, 0, 0, 0, 0
    end
    local cany = c as {string: number}
    local f <const> = self.fields
    local mode <const> = self.mode
    if mode == "color" then
        local r, g, b, a <const> = cany[f[1]], cany[f[2]], cany[f[3]], cany[f[4]]
        if relative then
            return r, g, b, a, t1, t2, t3, t4
        end
        return r, g, b, a, t1 - r, t2 - g, t3 - b, t4 - a
    elseif mode == "field2" then
        local a, b <const> = cany[f[1]], cany[f[2]]
        if relative then
            return a, b, 0, 0, t1, t2, 0, 0
        end
        return a, b, 0, 0, t1 - a, t2 - b, 0, 0
    elseif mode == "angle" then
        local startVal <const> = cany[f[1]]
        local delta: number
        if relative then
            delta = t1
        else
            local twoPi <const> = mathPi * 2
            local diff <const> = (t1 - startVal) % twoPi
            delta = 2 * diff % twoPi - diff
        end
        return startVal, 0, 0, 0, delta, 0, 0, 0
    end
    local startVal <const> = cany[f[1]]
    local delta <const> = relative and t1 or (t1 - startVal)
    return startVal, 0, 0, 0, delta, 0, 0, 0
end

targetApply = function(
    self: TargetImpl,
    world: World,
    entity: integer,
    t: number,
    s1: number,
    s2: number,
    s3: number,
    s4: number,
    d1: number,
    d2: number,
    d3: number,
    d4: number
)
    resolveTarget(self)
    local c = world:getMut(entity, self.component)
    if not c then
        return
    end
    local cany = c as {string: number}
    local f <const> = self.fields
    local mode <const> = self.mode
    cany[f[1]] = s1 + d1 * t
    if mode == "field2" or mode == "color" then
        cany[f[2]] = s2 + d2 * t
    end
    if mode == "color" then
        cany[f[3]] = s3 + d3 * t
        cany[f[4]] = s4 + d4 * t
    end
end

local targets: Targets = {}

function targets.field(component: Component, fieldName: string): Target
    return newTarget(component, {fieldName}, "field")
end

function targets.field2(component: Component, fieldA: string, fieldB: string): Target
    return newTarget(component, {fieldA, fieldB}, "field2")
end

function targets.angle(component: Component, fieldName: string): Target
    return newTarget(component, {fieldName}, "angle")
end

function targets.of(component: Component, field: string | {string}): Target
    local fields <const> = fieldsFrom(field)
    assert(#fields >= 1 and #fields <= 2, "tween.target supports one or two fields")
    return newTarget(component, fields)
end

local function newSource(
    kind: TrackSourceKind, component: Component, field: string | {string}, key?: string, relationship?: Component
): TrackSource
    return {
        kind = kind,
        key = key,
        relationship = relationship,
        relationshipName = relationship and relationship.componentName or nil,
        component = component,
        componentName = component.componentName,
        fields = fieldsFrom(field),
    } as TrackSourceImpl
end

local source: Sources = {}

function source.own(component: Component, field: string | {string}): TrackSource
    return newSource("self", component, field)
end

function source.key(key: string, component: Component, field: string | {string}): TrackSource
    return newSource("key", component, field, key)
end

function source.tracking(component: Component, field: string | {string}): TrackSource
    return newSource("trackingTarget", component, field)
end

function source.related(relationship: Component, component: Component, field: string | {string}): TrackSource
    return newSource("relationship", component, field, nil, relationship)
end

local Transform <const> = ecs.Transform
targets.translateX = newTarget(Transform, {"x"}, "field", "transform.x")
targets.translateY = newTarget(Transform, {"y"}, "field", "transform.y")
targets.translateXY = newTarget(Transform, {"x", "y"}, "field2", "transform.xy")
targets.rotation = newTarget(Transform, {"rotation"}, "field", "transform.rotation")
targets.rotationShortest = newTarget(Transform, {"rotation"}, "angle", "transform.rotationShortest")
targets.scaleX = newTarget(Transform, {"scaleX"}, "field", "transform.scaleX")
targets.scaleY = newTarget(Transform, {"scaleY"}, "field", "transform.scaleY")
targets.scaleXY = newTarget(Transform, {"scaleX", "scaleY"}, "field2", "transform.scaleXY")

local Tint <const> = components.Tint as Component
targets.alpha = newTarget(Tint, {"a"}, "field", "color.a")
targets.color = newTarget(Tint, {"r", "g", "b", "a"}, "color", "color.rgba")

local BUILTIN_TARGETS: {TargetName: TargetImpl} = {
    ["transform.x"] = targets.translateX as TargetImpl,
    ["transform.y"] = targets.translateY as TargetImpl,
    ["transform.xy"] = targets.translateXY as TargetImpl,
    ["transform.rotation"] = targets.rotation as TargetImpl,
    ["transform.rotationShortest"] = targets.rotationShortest as TargetImpl,
    ["transform.scaleX"] = targets.scaleX as TargetImpl,
    ["transform.scaleY"] = targets.scaleY as TargetImpl,
    ["transform.scaleXY"] = targets.scaleXY as TargetImpl,
    ["color.a"] = targets.alpha as TargetImpl,
    ["color.rgba"] = targets.color as TargetImpl,
}

tweeneval.TrackingTarget = ecs.newComponent({
    name = "TweenTrackingTarget",
    container = TrackingTarget,
    fields = {"entity", "key"},
    defaults = {0, ""},
})

-------------------------------------------------------------------------------
-- Authoring resolution and the target/source codec
-------------------------------------------------------------------------------

function tweeneval.resolveEasing(value: any): EasingName, EasingFunction
    if value is string then
        local name <const> = value as EasingName
        return name, assert(EASINGS[name], "Unknown tween easing " .. value)
    end
    local easingFn <const> = value as EasingFunction
    return assert(EASING_NAMES[easingFn], "Tween easing must be a built-in easing name or value"), easingFn
end

function tweeneval.resolveTargetValue(value: any): TargetImpl
    if value is string then
        return assert(BUILTIN_TARGETS[value as TargetName], "Unknown tween target " .. value)
    end
    return value as TargetImpl
end

function tweeneval.serializeTarget(t: Target): {string: any}
    local impl <const> = t as TargetImpl
    return {
        id = impl.id,
        component = impl.componentName or (impl.component and impl.component.componentName),
        fields = impl.fields,
        mode = impl.mode,
    }
end

function tweeneval.deserializeTarget(data: {string: any}): TargetImpl
    local id = data.id as string
    local builtin = id and BUILTIN_TARGETS[id as TargetName]
    if builtin then
        return builtin
    end
    return newTarget(
        componentByName(data.component as string), data.fields as {string}, (data.mode as TargetMode) or "field", id
    )
end

function tweeneval.serializeSource(s: TrackSource): {string: any}
    if not s then
        return nil
    end
    local impl <const> = s as TrackSourceImpl
    return {
        kind = impl.kind,
        key = impl.key,
        relationship = impl.relationshipName or (impl.relationship and impl.relationship.componentName),
        component = impl.componentName or (impl.component and impl.component.componentName),
        fields = impl.fields,
    }
end

function tweeneval.deserializeSource(data: {string: any}): TrackSourceImpl
    if not data then
        return nil
    end
    local relName = data.relationship as string
    return {
        kind = data.kind as TrackSourceKind,
        key = data.key as string,
        relationshipName = relName,
        relationship = relName and componentByName(relName) or nil,
        componentName = data.component as string,
        component = componentByName(data.component as string),
        fields = data.fields as {string},
    } as TrackSourceImpl
end

-------------------------------------------------------------------------------
-- The compiled timeline, and its codec
-------------------------------------------------------------------------------

local TIMELINE_MT <const>: metatable<TimelineImpl> = {}

function tweeneval.asTimeline(tl: TimelineImpl): Timeline
    return setmetatable(tl, TIMELINE_MT) as Timeline
end

function tweeneval.serializeTimeline(tl: Timeline): {string: any}
    local impl <const> = tl as TimelineImpl
    local slots: {{string: any}} = {}
    for i = 1, #(impl.slots or {}) do
        local s <const> = impl.slots[i]
        slots[i] = {
            kind = s.kind,
            target = tweeneval.serializeTarget(s.target),
            source = tweeneval.serializeSource(s.source),
            easing = s.easingName,
            t1 = s.t1,
            t2 = s.t2,
            t3 = s.t3,
            t4 = s.t4,
            relative = s.relative,
            startTime = s.startTime,
            endTime = s.endTime,
            duration = s.duration,
            stateIndex = s.stateIndex,
        }
    end
    local runs: {{string: any}} = nil
    if impl.runs then
        runs = {}
        for i = 1, #impl.runs do
            local r <const> = impl.runs[i]
            runs[i] = {
                timelineId = r.timelineId,
                timeline = r.timeline and tweeneval.serializeTimeline(r.timeline) or nil,
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

function tweeneval.deserializeTimeline(data: {string: any}): TimelineImpl
    local slots: {Slot} = {}
    local savedSlots = data.slots as {{string: any}}
    for i = 1, #(savedSlots or {}) do
        local s <const> = savedSlots[i]
        local easingName <const> = s.easing as EasingName
        slots[i] = {
            kind = (s.kind as OperationKind) or "to",
            target = tweeneval.deserializeTarget(s.target as {string: any}),
            source = tweeneval.deserializeSource(s.source as {string: any}),
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
    local savedRuns = data.runs as {{string: any}}
    if savedRuns then
        runs = {}
        for i = 1, #savedRuns do
            local r <const> = savedRuns[i]
            runs[i] = {
                timeline = r.timeline and tweeneval.deserializeTimeline(r.timeline as {string: any}) or nil,
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
-- Authoring and compilation
--
-- A node is a plain array the compiler writes its resolved form into, so an
-- authored timeline becomes a compiled one in place rather than in a copy.
-------------------------------------------------------------------------------

function tweeneval.playbackMode(mode?: PlaybackMode, count?: integer, finite?: boolean): PlaybackMode, integer
    local resolved <const> = mode or "once"
    assert(
        resolved == "once" or resolved == "loop" or resolved == "pingPong", "Tween mode must be once, loop, or pingPong"
    )
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

local function numericValue(value: any, position: integer): number
    if value == nil then
        return 0
    end
    assert(value is number, "Tween value at position " .. tostring(position) .. " must be a number")
    return value as number
end

function tweeneval.to(
    duration: number,
    curve: EasingName | EasingFunction,
    target: TargetName | Target,
    t1: number,
    t2?: number,
    t3?: number,
    t4?: number
): TimelineNode
    return {"to", duration, curve, target, t1, t2, t3, t4}
end

function tweeneval.adjust(
    duration: number,
    curve: EasingName | EasingFunction,
    target: TargetName | Target,
    t1: number,
    t2?: number,
    t3?: number,
    t4?: number
): TimelineNode
    return {"adjust", duration, curve, target, t1, t2, t3, t4}
end

function tweeneval.track(
    duration: number, curve: EasingName | EasingFunction, target: TargetName | Target, from: TrackSource
): TimelineNode
    return {"track", duration, curve, target, from}
end

function tweeneval.wait(duration: number): TimelineNode
    return {"wait", duration}
end

function tweeneval.emit(name: string): TimelineNode
    return {"emit", name}
end

function tweeneval.run(timeline: any, options?: RunOptions): TimelineNode
    return {"run", timeline, options}
end

function tweeneval.parallel(...: TimelineNode): TimelineNode
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
    local compiled <const> = (node as any) as {any: any}
    local authoredKind <const> = compiled[1] as OperationKind
    local duration <const> = compiled[2] as number
    assert(duration and duration > 0, "Tween duration must be greater than 0")
    local easingName, easingFn = tweeneval.resolveEasing(compiled[3])
    local target <const> = tweeneval.resolveTargetValue(compiled[4])
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
    local data <const> = (node as any) as {any: any}
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
        return startTime + 0
    elseif kind == "run" then
        -- A nested timeline is given either already compiled or as its own
        -- spec. The second form is what authoring reaches for, since a
        -- nested timeline needs no name of its own.
        local nested <const> = data[2] as {any: any}
        assert(nested, "Tween run requires a timeline")
        local child = nested as TimelineImpl
        if child.totalDuration == nil then
            child = tweeneval.compile(nested as TimelineSpec) as TimelineImpl
        end
        local options <const> = data[3] as RunOptions
        local mode, passCount = tweeneval.playbackMode(options and options.mode, options and options.count, true)
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
            if childEnd > endTime then
                endTime = childEnd
            end
        end
        return endTime
    end
    error("Unknown tween operation " .. kind)
end

function tweeneval.compile(spec: TimelineSpec): Timeline
    local authored <const> = spec as {any: any}
    assert(authored.sequence == nil, "Tween timelines use an implicit sequence")
    local tl <const> = spec as TimelineImpl
    tl.slots = {}
    tl.runs = {}
    tl.emits = {}
    tl.totalDuration = compileBlock(spec, 0, tl)
    tl.stateSize = #tl.slots
    if #tl.runs == 0 then
        tl.runs = nil
    end
    if #tl.emits == 0 then
        tl.emits = nil
    else
        table.sort(
            tl.emits,
            function(a: EmitSlot, b: EmitSlot): boolean
                return a.time < b.time or (a.time == b.time and a.order < b.order)
            end
        )
    end
    return tweeneval.asTimeline(tl)
end

-------------------------------------------------------------------------------
-- Evaluation
-------------------------------------------------------------------------------

local TrackingTargetComponent <const> = tweeneval.TrackingTarget

function tweeneval.valuesFromSource(world: World, entity: integer, src: TrackSourceImpl): number, number, number, number
    if not src then
        return 0, 0, 0, 0
    end
    if not src.component and src.componentName then
        src.component = componentByName(src.componentName)
    end
    local sourceEntity = entity
    if src.kind == "key" then
        sourceEntity = world:requireKey(src.key)
    elseif src.kind == "trackingTarget" then
        local tt = world:get(entity, TrackingTargetComponent)
        if not tt then
            return 0, 0, 0, 0
        end
        if tt.entity and tt.entity ~= 0 then
            sourceEntity = tt.entity
        elseif tt.key and tt.key ~= "" then
            sourceEntity = world:requireKey(tt.key)
        else
            return 0, 0, 0, 0
        end
    elseif src.kind == "relationship" then
        if not src.relationship and src.relationshipName then
            src.relationship = componentByName(src.relationshipName)
        end
        local rel = world:get(entity, src.relationship)
        if not rel then
            return 0, 0, 0, 0
        end
        sourceEntity = (rel as RelationshipValue).target
    end
    local c = world:get(sourceEntity, src.component)
    if not c then
        return 0, 0, 0, 0
    end
    local cany = c as {string: number}
    local f <const> = src.fields
    return cany[f[1]] or 0, cany[f[2]] or 0, cany[f[3]] or 0, cany[f[4]] or 0
end

local valuesFromSource <const> = tweeneval.valuesFromSource

function tweeneval.evaluateSlots(slots: {Slot}, state: {TweenSlotState}, world: World, target: integer, elapsed: number)
    for i = 1, #(slots or {}) do
        local slot <const> = slots[i]
        local ss <const> = state[slot.stateIndex]
        local shouldEvaluate = false
        local active = false
        local localT: number = 0
        if elapsed >= slot.startTime and elapsed <= slot.endTime then
            shouldEvaluate = true
            active = true
            localT = (elapsed - slot.startTime) / slot.duration
        elseif elapsed > slot.endTime then
            shouldEvaluate = true
            localT = 1
        elseif ss.init ~= 0 then
            shouldEvaluate = true
            localT = 0
        end

        if shouldEvaluate then
            if ss.init == 0 then
                local t1, t2, t3, t4 = slot.t1, slot.t2, slot.t3, slot.t4
                if slot.kind == "track" then
                    t1, t2, t3, t4 = valuesFromSource(world, target, slot.source)
                end
                ss.s1, ss.s2, ss.s3, ss.s4, ss.d1, ss.d2, ss.d3, ss.d4 = slot.target.init(
                    world, target, slot.relative, t1, t2, t3, t4
                )
                ss.init = 1
            end
            if localT < 0 then
                localT = 0
            end
            if localT > 1 then
                localT = 1
            end
            if slot.kind == "track" and active then
                local t1, t2, t3, t4 = valuesFromSource(world, target, slot.source)
                ss.d1 = t1 - ss.s1
                ss.d2 = t2 - ss.s2
                ss.d3 = t3 - ss.s3
                ss.d4 = t4 - ss.s4
            end
            if ss.applied == 0 or ss.lastT ~= localT or (slot.kind == "track" and active) then
                slot.target.apply(
                    world, target, slot.easing(localT), ss.s1, ss.s2, ss.s3, ss.s4, ss.d1, ss.d2, ss.d3, ss.d4
                )
                ss.applied = 1
                ss.lastT = localT
            end
        end
    end
end

local STATE_BYTES <const> = ffi.sizeof("TweenSlotState")

function tweeneval.newState(count: integer): {TweenSlotState}
    return ffi.new("TweenSlotState[?]", count) as {TweenSlotState}
end

function tweeneval.clearState(state: {TweenSlotState}, count: integer)
    ffi.fill(state as ffi.CData, STATE_BYTES * count, 0)
end

tweeneval.easing = easing
tweeneval.target = targets
tweeneval.source = source
tweeneval.easings = EASINGS

return tweeneval
