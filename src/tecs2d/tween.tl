local tecs <const> = require("tecs")
local ffi <const> = require("ffi")
local components <const> = require("tecs.internal.components")

local mathPi, mathSin, mathCos, mathPow <const> = math.pi, math.sin, math.cos, math.pow

local type World = tecs.World
local type Component = tecs.Component
local type ControlSelector = string | Timeline

ffi.cdef[[
    typedef struct {
        double init;
        double s1;
        double s2;
        double s3;
        double s4;
        double d1;
        double d2;
        double d3;
        double d4;
    } TweenSlotState;
]]

local record TweenSlotState
    init: number
    s1: number
    s2: number
    s3: number
    s4: number
    d1: number
    d2: number
    d3: number
    d4: number
end

local type EasingFunction = function(t: number): number

local record Target
    id: string
    component: Component
    componentName: string
    fields: {string}
    mode: string

    init: function(
        world: World, entity: integer, relative: boolean,
        t1: number, t2: number, t3: number, t4: number
    ): number, number, number, number, number, number, number, number

    apply: function(
        world: World, entity: integer, t: number,
        s1: number, s2: number, s3: number, s4: number,
        d1: number, d2: number, d3: number, d4: number
    )
end

local record TrackSource
    kind: string
    key: string
    relationship: Component
    relationshipName: string
    component: Component
    componentName: string
    fields: {string}
end

local record Slot
    kind: string
    target: Target
    source: TrackSource
    easingName: string
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

local record EmitSlot
    time: number
    name: string
end

local record RunSlot
    timeline: Timeline
    timelineId: integer
    startTime: number
    effectiveDuration: number
    repeatCount: integer
    pingPong: boolean
end

local record Timeline
    slots: {Slot}
    runs: {RunSlot}
    emits: {EmitSlot}
    totalDuration: number
    effectiveDuration: number
    stateSize: integer
    repeatCount: integer
    pingPong: boolean
    channel: string
    presetName: string
    pinned: boolean

    apply: function(self: Timeline, world: World, entity: integer, speed?: number, delay?: number)
    play: function(self: Timeline, world: World, entity: integer, speed?: number, delay?: number)
end

local record Cursor
    timelineId: integer
    stateSize: integer
    state: {TweenSlotState}
    children: {Cursor}
    elapsed: number
    direction: integer
    repeatCount: integer
    nextEmit: integer
    rate: number
    paused: boolean
    delay: number
    completed: boolean
    cancelled: boolean
    _lastCycleIndex: integer
end

local record TweenPlayback is tecs.Component
    cursors: {Cursor}
end

local record TrackingTarget is tecs.Component
    entity: integer
    key: string
end

local record TweenEvent is tecs.Event
    entity: integer
    name: string
    channel: string
    timelineId: integer

    init: function(self: TweenEvent, entity: integer, name: string, channel: string, timelineId: integer)
end

local record TweenComplete is tecs.Event
    entity: integer
    channel: string
    timelineId: integer

    init: function(self: TweenComplete, entity: integer, channel: string, timelineId: integer)
end

function TweenEvent.init(e: TweenEvent, entity: integer, name: string, channel: string, timelineId: integer)
    e.entity = entity
    e.name = name
    e.channel = channel
    e.timelineId = timelineId
end

function TweenComplete.init(e: TweenComplete, entity: integer, channel: string, timelineId: integer)
    e.entity = entity
    e.channel = channel
    e.timelineId = timelineId
end

local record Registry
    nextId: integer
    byId: {integer: Timeline}
    refcounts: {integer: integer}
    objectIds: {Timeline: integer}
    named: {string: integer}
end

local record TimelineBuilder
    _slots: {Slot}
    _runs: {RunSlot}
    _emits: {EmitSlot}
    _currentOffset: number
    _currentGroupMaxEnd: number
    _frozen: boolean
    _channel: string

    channel: function(self: TimelineBuilder, name: string): TimelineBuilder
    to: function(self: TimelineBuilder, duration: number, easingFn: EasingFunction, target: Target, t1?: number, t2?: number, t3?: number, t4?: number): TimelineBuilder
    adjust: function(self: TimelineBuilder, duration: number, easingFn: EasingFunction, target: Target, t1: number, t2?: number, t3?: number, t4?: number): TimelineBuilder
    track: function(self: TimelineBuilder, duration: number, easingFn: EasingFunction, target: Target, source: TrackSource): TimelineBuilder
    step: function(self: TimelineBuilder, pause?: number): TimelineBuilder
    emit: function(self: TimelineBuilder, name: string): TimelineBuilder
    run: function(self: TimelineBuilder, timeline: Timeline, count?: integer): TimelineBuilder
    once: function(self: TimelineBuilder): Timeline
    loop: function(self: TimelineBuilder, count?: integer): Timeline
    pingPong: function(self: TimelineBuilder, count?: integer): Timeline
end

local REGISTRY <const>: tecs.Key<Registry> = tecs.newKey()
local SNAPSHOT_DATA_KEY <const> = "tecs2d.tween.registry"

local record tween
    type Target = Target
    type TrackSource = TrackSource
    type Timeline = Timeline
    type TimelineBuilder = TimelineBuilder
    TweenPlayback: TweenPlayback
    TrackingTarget: TrackingTarget
    TweenEvent: TweenEvent
    TweenComplete: TweenComplete

    linear: EasingFunction
    quadIn: EasingFunction
    quadOut: EasingFunction
    quadInOut: EasingFunction
    quadOutIn: EasingFunction
    cubicIn: EasingFunction
    cubicOut: EasingFunction
    cubicInOut: EasingFunction
    cubicOutIn: EasingFunction
    quartIn: EasingFunction
    quartOut: EasingFunction
    quartInOut: EasingFunction
    quartOutIn: EasingFunction
    quintIn: EasingFunction
    quintOut: EasingFunction
    quintInOut: EasingFunction
    quintOutIn: EasingFunction
    sineIn: EasingFunction
    sineOut: EasingFunction
    sineInOut: EasingFunction
    sineOutIn: EasingFunction
    expoIn: EasingFunction
    expoOut: EasingFunction
    expoInOut: EasingFunction
    expoOutIn: EasingFunction
    backIn: EasingFunction
    backOut: EasingFunction
    backInOut: EasingFunction
    backOutIn: EasingFunction
    elasticIn: EasingFunction
    elasticOut: EasingFunction
    elasticInOut: EasingFunction
    elasticOutIn: EasingFunction
    bounceIn: EasingFunction
    bounceOut: EasingFunction
    bounceInOut: EasingFunction
    bounceOutIn: EasingFunction

    field: function(component: Component, fieldName: string): Target
    field2: function(component: Component, fieldA: string, fieldB: string): Target
    angle: function(component: Component, fieldName: string): Target
    target: function(component: Component, field: string | {string}): Target
    sourceSelf: function(component: Component, field: string | {string}): TrackSource
    sourceKey: function(key: string, component: Component, field: string | {string}): TrackSource
    sourceTrackingTarget: function(component: Component, field: string | {string}): TrackSource
    sourceRelationship: function(relationship: Component, component: Component, field: string | {string}): TrackSource

    translateX: Target
    translateY: Target
    translateXY: Target
    rotation: Target
    rotationShortest: Target
    scaleX: Target
    scaleY: Target
    scaleXY: Target
    alpha: Target
    color: Target

    timeline: function(): TimelineBuilder
    registerPreset: function(name: string, timeline: Timeline): Timeline
    play: function(world: World, entity: integer, timelineOrName: Timeline | string, speed?: number, delay?: number)
    cancel: function(world: World, entity: integer, selector?: ControlSelector)
    pause: function(world: World, entity: integer, selector?: ControlSelector)
    resume: function(world: World, entity: integer, selector?: ControlSelector)
    plugin: function(world: World)
end

-------------------------------------------------------------------------------
-- Easing
-------------------------------------------------------------------------------

function tween.linear(t: number): number return t end

local EASING_NAMES: {EasingFunction: string} = {}
local EASINGS: {string: EasingFunction} = {}

local function registerEasing(name: string, fn: EasingFunction)
    EASING_NAMES[fn] = name
    EASINGS[name] = fn
end

local function makeVariants(name: string, inFn: EasingFunction)
    local tw = tween as {string: EasingFunction}
    tw[name .. "In"] = inFn
    tw[name .. "Out"] = function(t: number): number return 1 - inFn(1 - t) end
    tw[name .. "InOut"] = function(t: number): number
        if t < 0.5 then return 0.5 * inFn(2 * t) end
        return 1 - 0.5 * inFn(2 - 2 * t)
    end
    tw[name .. "OutIn"] = function(t: number): number
        if t < 0.5 then return 0.5 - 0.5 * inFn(1 - 2 * t) end
        return 0.5 + 0.5 * inFn(2 * t - 1)
    end
end

makeVariants("quad", function(t: number): number return t * t end)
makeVariants("cubic", function(t: number): number return t * t * t end)
makeVariants("quart", function(t: number): number return t * t * t * t end)
makeVariants("quint", function(t: number): number return t * t * t * t * t end)
makeVariants("sine", function(t: number): number return 1 - mathCos(t * mathPi * 0.5) end)
makeVariants("expo", function(t: number): number
    if t == 0 then return 0 end
    return mathPow(2, 10 * (t - 1))
end)
makeVariants("back", function(t: number): number
    local s <const> = 1.70158
    return t * t * ((s + 1) * t - s)
end)
makeVariants("elastic", function(t: number): number
    if t == 0 then return 0 end
    if t == 1 then return 1 end
    local p <const> = 0.3
    return -mathPow(2, 10 * (t - 1)) * mathSin((t - 1 - p / 4) * (2 * mathPi) / p)
end)

do
    local function bounceOut(t: number): number
        if t < 1 / 2.75 then return 7.5625 * t * t
        elseif t < 2 / 2.75 then local u <const> = t - 1.5 / 2.75; return 7.5625 * u * u + 0.75
        elseif t < 2.5 / 2.75 then local u <const> = t - 2.25 / 2.75; return 7.5625 * u * u + 0.9375 end
        local u <const> = t - 2.625 / 2.75; return 7.5625 * u * u + 0.984375
    end
    local function bounceIn(t: number): number return 1 - bounceOut(1 - t) end
    tween.bounceIn = bounceIn
    tween.bounceOut = bounceOut
    tween.bounceInOut = function(t: number): number
        if t < 0.5 then return 0.5 * bounceIn(2 * t) end
        return 0.5 * bounceOut(2 * t - 1) + 0.5
    end
    tween.bounceOutIn = function(t: number): number
        if t < 0.5 then return 0.5 * bounceOut(2 * t) end
        return 0.5 * bounceIn(2 * t - 1) + 0.5
    end
end

do
    local names <const> = {
        "linear",
        "quadIn", "quadOut", "quadInOut", "quadOutIn",
        "cubicIn", "cubicOut", "cubicInOut", "cubicOutIn",
        "quartIn", "quartOut", "quartInOut", "quartOutIn",
        "quintIn", "quintOut", "quintInOut", "quintOutIn",
        "sineIn", "sineOut", "sineInOut", "sineOutIn",
        "expoIn", "expoOut", "expoInOut", "expoOutIn",
        "backIn", "backOut", "backInOut", "backOutIn",
        "elasticIn", "elasticOut", "elasticInOut", "elasticOutIn",
        "bounceIn", "bounceOut", "bounceInOut", "bounceOutIn",
    }
    local tw = tween as {string: EasingFunction}
    for i = 1, #names do
        registerEasing(names[i], tw[names[i]])
    end
end

-------------------------------------------------------------------------------
-- Components and events
-------------------------------------------------------------------------------

local function serializeState(state: {TweenSlotState}, count: integer): {{number}}
    local out: {{number}} = {}
    for i = 0, count - 1 do
        local s <const> = state[i]
        out[i + 1] = {s.init, s.s1, s.s2, s.s3, s.s4, s.d1, s.d2, s.d3, s.d4}
    end
    return out
end

local function deserializeState(rows: {{number}}): {TweenSlotState}
    local count = rows and #rows or 0
    local state = ffi.new("TweenSlotState[?]", count) as {TweenSlotState}
    for i = 1, count do
        local row <const> = rows[i]
        local s <const> = state[i - 1]
        s.init = row[1] or 0
        s.s1 = row[2] or 0
        s.s2 = row[3] or 0
        s.s3 = row[4] or 0
        s.s4 = row[5] or 0
        s.d1 = row[6] or 0
        s.d2 = row[7] or 0
        s.d3 = row[8] or 0
        s.d4 = row[9] or 0
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
        timelineId = c.timelineId,
        elapsed = c.elapsed,
        direction = c.direction,
        repeatCount = c.repeatCount,
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
        timelineId = data.timelineId as integer,
        stateSize = (data.stateSize as integer) or #(data.state as {{number}} or {}),
        state = deserializeState(data.state as {{number}}),
        children = children,
        elapsed = (data.elapsed as number) or 0,
        direction = (data.direction as integer) or 1,
        repeatCount = (data.repeatCount as integer) or 0,
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
    container = TweenPlayback,
    new = function(data: {string:any}): TweenPlayback
        local cursors: {Cursor} = {}
        local saved = data and (data.cursors as {{string:any}})
        if saved then
            for i = 1, #saved do
                cursors[i] = deserializeCursor(saved[i])
            end
        end
        return { cursors = cursors } as TweenPlayback
    end,
    serialize = function(instance: TweenPlayback): {string:any}
        local cursors: {{string:any}} = {}
        for i = 1, #(instance.cursors or {}) do
            cursors[i] = serializeCursor(instance.cursors[i])
        end
        return { cursors = cursors }
    end,
})

tween.TrackingTarget = tecs.newComponent({
    name = "TweenTrackingTarget",
    container = TrackingTarget,
    fields = {"entity", "key"},
    defaults = {0, ""},
})

tween.TweenEvent = TweenEvent
tween.TweenComplete = TweenComplete
tecs.newEvent(TweenEvent)
tecs.newEvent(TweenComplete)

-------------------------------------------------------------------------------
-- Targets and tracking sources
-------------------------------------------------------------------------------

local TARGET_MT <const>: metatable<Target> = { __index = Target }
local targetInit: function(
    Target, World, integer, boolean, number, number, number, number
): (number, number, number, number, number, number, number, number)
local targetApply: function(
    Target, World, integer, number, number, number, number, number, number, number, number, number
)

local function fieldsFrom(field: string | {string}): {string}
    if field is string then
        return { field }
    end
    return field as {string}
end

local function componentByName(name: string): Component
    local component = components.registeredComponents[name]
    if not component then error("Unknown tween component " .. name) end
    return component
end

local function resolveTarget(t: Target): Target
    if not t.component and t.componentName then
        t.component = componentByName(t.componentName)
    end
    return t
end

local function newTarget(component: Component, fields: {string}, mode?: string, id?: string): Target
    local parts = component.componentName
    for i = 1, #fields do
        parts = parts .. "." .. fields[i]
    end
    local t: Target = setmetatable({
        id = id or parts,
        component = component,
        componentName = component.componentName,
        fields = fields,
        mode = mode or (#fields == 2 and "field2" or "field"),
    }, TARGET_MT)
    t.init = function(
        world: World, entity: integer, relative: boolean,
        t1: number, t2: number, t3: number, t4: number
    ): (number, number, number, number, number, number, number, number)
        return targetInit(t, world, entity, relative, t1, t2, t3, t4)
    end
    t.apply = function(world: World, entity: integer, tv: number, s1: number, s2: number, s3: number, s4: number, d1: number, d2: number, d3: number, d4: number)
        targetApply(t, world, entity, tv, s1, s2, s3, s4, d1, d2, d3, d4)
    end
    return t
end

targetInit = function(self: Target,
    world: World, entity: integer, relative: boolean,
    t1: number, t2: number, t3: number, t4: number
): number, number, number, number, number, number, number, number
    resolveTarget(self)
    local c = world:get(entity, self.component)
    if not c then
        return 0, 0, 0, 0, 0, 0, 0, 0
    end
    local cany = c as {string:number}
    local f <const> = self.fields
    local mode <const> = self.mode
    if mode == "color" then
        local r, g, b, a <const> = cany[f[1]], cany[f[2]], cany[f[3]], cany[f[4]]
        if relative then return r, g, b, a, t1, t2, t3, t4 end
        return r, g, b, a, t1 - r, t2 - g, t3 - b, t4 - a
    elseif mode == "field2" then
        local a, b <const> = cany[f[1]], cany[f[2]]
        if relative then return a, b, 0, 0, t1, t2, 0, 0 end
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

targetApply = function(self: Target,
    world: World, entity: integer, t: number,
    s1: number, s2: number, s3: number, s4: number,
    d1: number, d2: number, d3: number, d4: number
)
    resolveTarget(self)
    local c = world:get(entity, self.component)
    if not c then return end
    local cany = c as {string:number}
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
    world:markComponentDirty(entity, self.component)
end

function tween.field(component: Component, fieldName: string): Target
    return newTarget(component, {fieldName}, "field")
end

function tween.field2(component: Component, fieldA: string, fieldB: string): Target
    return newTarget(component, {fieldA, fieldB}, "field2")
end

function tween.angle(component: Component, fieldName: string): Target
    return newTarget(component, {fieldName}, "angle")
end

function tween.target(component: Component, field: string | {string}): Target
    local fields <const> = fieldsFrom(field)
    assert(#fields >= 1 and #fields <= 2, "tween.target supports one or two fields")
    return newTarget(component, fields)
end

local function source(kind: string, component: Component, field: string | {string}, key?: string, relationship?: Component): TrackSource
    return {
        kind = kind,
        key = key,
        relationship = relationship,
        relationshipName = relationship and relationship.componentName or nil,
        component = component,
        componentName = component.componentName,
        fields = fieldsFrom(field),
    }
end

function tween.sourceSelf(component: Component, field: string | {string}): TrackSource
    return source("self", component, field)
end

function tween.sourceKey(key: string, component: Component, field: string | {string}): TrackSource
    return source("key", component, field, key)
end

function tween.sourceTrackingTarget(component: Component, field: string | {string}): TrackSource
    return source("trackingTarget", component, field)
end

function tween.sourceRelationship(relationship: Component, component: Component, field: string | {string}): TrackSource
    return source("relationship", component, field, nil, relationship)
end

local Transform <const> = tecs.builtins.Transform
tween.translateX = newTarget(Transform, {"x"}, "field", "transform.x")
tween.translateY = newTarget(Transform, {"y"}, "field", "transform.y")
tween.translateXY = newTarget(Transform, {"x", "y"}, "field2", "transform.xy")
tween.rotation = newTarget(Transform, {"rotation"}, "field", "transform.rotation")
tween.rotationShortest = newTarget(Transform, {"rotation"}, "angle", "transform.rotationShortest")
tween.scaleX = newTarget(Transform, {"scaleX"}, "field", "transform.scaleX")
tween.scaleY = newTarget(Transform, {"scaleY"}, "field", "transform.scaleY")
tween.scaleXY = newTarget(Transform, {"scaleX", "scaleY"}, "field2", "transform.scaleXY")

do
    local colorComponent: Component = nil
    local function color(): Component
        if not colorComponent then
            local ok, mod = pcall(require, "tecs2d.gfx.internal.Color")
            assert(ok, "tween.alpha/color requires tecs2d.gfx (Color component)")
            colorComponent = mod as Component
        end
        return colorComponent
    end
    tween.alpha = newTarget(color(), {"a"}, "field", "color.a")
    tween.color = newTarget(colorComponent, {"r", "g", "b", "a"}, "color", "color.rgba")
end

local BUILTIN_TARGETS: {string: Target} = {
    ["transform.x"] = tween.translateX,
    ["transform.y"] = tween.translateY,
    ["transform.xy"] = tween.translateXY,
    ["transform.rotation"] = tween.rotation,
    ["transform.rotationShortest"] = tween.rotationShortest,
    ["transform.scaleX"] = tween.scaleX,
    ["transform.scaleY"] = tween.scaleY,
    ["transform.scaleXY"] = tween.scaleXY,
    ["color.a"] = tween.alpha,
    ["color.rgba"] = tween.color,
}

-------------------------------------------------------------------------------
-- Template serialization
-------------------------------------------------------------------------------

local function serializeTarget(t: Target): {string:any}
    return {
        id = t.id,
        component = t.componentName or (t.component and t.component.componentName),
        fields = t.fields,
        mode = t.mode,
    }
end

local function deserializeTarget(data: {string:any}): Target
    local id = data.id as string
    local builtin = id and BUILTIN_TARGETS[id]
    if builtin then return builtin end
    return newTarget(
        componentByName(data.component as string),
        data.fields as {string},
        (data.mode as string) or "field",
        id
    )
end

local function serializeSource(s: TrackSource): {string:any}
    if not s then return nil end
    return {
        kind = s.kind,
        key = s.key,
        relationship = s.relationshipName or (s.relationship and s.relationship.componentName),
        component = s.componentName or (s.component and s.component.componentName),
        fields = s.fields,
    }
end

local function deserializeSource(data: {string:any}): TrackSource
    if not data then return nil end
    local relName = data.relationship as string
    return {
        kind = data.kind as string,
        key = data.key as string,
        relationshipName = relName,
        relationship = relName and componentByName(relName) or nil,
        componentName = data.component as string,
        component = componentByName(data.component as string),
        fields = data.fields as {string},
    }
end

local function serializeTimeline(tl: Timeline): {string:any}
    local slots: {{string:any}} = {}
    for i = 1, #(tl.slots or {}) do
        local s <const> = tl.slots[i]
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
    if tl.runs then
        runs = {}
        for i = 1, #tl.runs do
            local r <const> = tl.runs[i]
            runs[i] = {
                timelineId = r.timelineId,
                timeline = r.timeline and serializeTimeline(r.timeline) or nil,
                startTime = r.startTime,
                effectiveDuration = r.effectiveDuration,
                repeatCount = r.repeatCount,
                pingPong = r.pingPong,
            }
        end
    end
    return {
        slots = slots,
        runs = runs,
        emits = tl.emits,
        totalDuration = tl.totalDuration,
        effectiveDuration = tl.effectiveDuration,
        stateSize = tl.stateSize,
        repeatCount = tl.repeatCount,
        pingPong = tl.pingPong,
        channel = tl.channel,
        presetName = tl.presetName,
        pinned = tl.pinned,
    }
end

local TIMELINE_MT <const>: metatable<Timeline> = { __index = Timeline }

local function deserializeTimeline(data: {string:any}): Timeline
    local slots: {Slot} = {}
    local savedSlots = data.slots as {{string:any}}
    for i = 1, #(savedSlots or {}) do
        local s <const> = savedSlots[i]
        local easingName <const> = s.easing as string
        slots[i] = {
            kind = (s.kind as string) or "to",
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
                repeatCount = (r.repeatCount as integer) or 0,
                pingPong = r.pingPong == true,
            }
        end
    end
    return setmetatable({
        slots = slots,
        runs = runs,
        emits = data.emits as {EmitSlot},
        totalDuration = (data.totalDuration as number) or 0,
        effectiveDuration = (data.effectiveDuration as number) or 0,
        stateSize = (data.stateSize as integer) or #slots,
        repeatCount = (data.repeatCount as integer) or 0,
        pingPong = data.pingPong == true,
        channel = data.channel as string,
        presetName = data.presetName as string,
        pinned = data.pinned == true,
    }, TIMELINE_MT)
end

-------------------------------------------------------------------------------
-- Registry
-------------------------------------------------------------------------------

local function newRegistry(): Registry
    return {
        nextId = 1,
        byId = {},
        refcounts = {},
        objectIds = setmetatable({} as {Timeline: integer}, { __mode = "k" }),
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

local function internTimeline(world: World, tl: Timeline): integer
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
    world.resources[REGISTRY] = reg
end

-------------------------------------------------------------------------------
-- Cursor methods and playback creation
-------------------------------------------------------------------------------

local function createCursor(world: World, tl: Timeline, target: integer, rate: number, delay: number): Cursor
    local id <const> = internTimeline(world, tl)
    local state = ffi.new("TweenSlotState[?]", tl.stateSize) as {TweenSlotState}
    local children: {Cursor} = nil
    if tl.runs then
        children = {}
        for i = 1, #tl.runs do
            children[i] = createCursor(world, tl.runs[i].timeline, target, 1, 0)
            children[i].repeatCount = tl.runs[i].repeatCount
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
        repeatCount = tl.repeatCount,
        nextEmit = 1,
        rate = rate,
        delay = delay or 0,
        _lastCycleIndex = 0,
    }
end

local function playbackFor(world: World, entity: integer): TweenPlayback
    local pb = world:getMut(entity, TweenPlayback)
    if pb then return pb end
    -- Inside a deferred scope (query iteration, observers) the set is queued,
    -- so a re-fetch would return nil; return the instance handed to set. It is
    -- a Lua-table component, so mutations before commit land in the same table.
    local created <const> = TweenPlayback.new({})
    world:set(entity, created)
    return created
end

local function cursorTimeline(world: World, c: Cursor): Timeline
    return registry(world).byId[c.timelineId]
end

local function addCursor(world: World, entity: integer, tl: Timeline, speed?: number, delay?: number): Cursor
    local pb <const> = playbackFor(world, entity)
    if tl.channel then
        for i = 1, #(pb.cursors or {}) do
            local existing <const> = pb.cursors[i]
            local etl <const> = cursorTimeline(world, existing)
            if etl and etl.channel == tl.channel then
                existing.cancelled = true
            end
        end
    end
    local c <const> = createCursor(world, tl, entity, speed or 1, delay or 0)
    pb.cursors[#pb.cursors + 1] = c
    return c
end

function Timeline:play(world: World, entity: integer, speed?: number, delay?: number)
    addCursor(world, entity, self, speed, delay)
end

function Timeline:apply(world: World, entity: integer, speed?: number, delay?: number)
    self:play(world, entity, speed, delay)
end

function tween.play(world: World, entity: integer, timelineOrName: Timeline | string, speed?: number, delay?: number)
    if timelineOrName is string then
        local id = registry(world).named[timelineOrName]
        if not id then error("Unknown tween preset " .. timelineOrName) end
        addCursor(world, entity, registry(world).byId[id], speed, delay)
        return
    end
    (timelineOrName as Timeline):play(world, entity, speed, delay)
end

local function selectorTimelineId(world: World, selector: Timeline): integer
    local reg <const> = registry(world)
    local id = reg.objectIds[selector]
    if id then return id end
    if selector.presetName then return reg.named[selector.presetName] end
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
    local pb = world:getMut(entity, TweenPlayback)
    if not pb then return end
    for i = 1, #(pb.cursors or {}) do
        if matchesCursor(world, pb.cursors[i], selector) then
            pb.cursors[i].cancelled = true
        end
    end
end

function tween.pause(world: World, entity: integer, selector?: ControlSelector)
    local pb = world:getMut(entity, TweenPlayback)
    if not pb then return end
    for i = 1, #(pb.cursors or {}) do
        if matchesCursor(world, pb.cursors[i], selector) then
            pb.cursors[i].paused = true
        end
    end
end

function tween.resume(world: World, entity: integer, selector?: ControlSelector)
    local pb = world:getMut(entity, TweenPlayback)
    if not pb then return end
    for i = 1, #(pb.cursors or {}) do
        if matchesCursor(world, pb.cursors[i], selector) then
            pb.cursors[i].paused = false
        end
    end
end

-------------------------------------------------------------------------------
-- Builder
-------------------------------------------------------------------------------

local BUILDER_MT <const>: metatable<TimelineBuilder> = { __index = TimelineBuilder }

function tween.timeline(): TimelineBuilder
    return setmetatable({
        _slots = {},
        _runs = {},
        _emits = {},
        _currentOffset = 0,
        _currentGroupMaxEnd = 0,
        _frozen = false,
    }, BUILDER_MT)
end

local function addSlot(builder: TimelineBuilder, kind: string, duration: number, easingFn: EasingFunction, target: Target, trackSource: TrackSource, relative: boolean, t1?: number, t2?: number, t3?: number, t4?: number): TimelineBuilder
    assert(not builder._frozen, "Cannot add entries to a finalized timeline")
    assert(duration > 0, "Tween duration must be greater than 0")
    local easingName <const> = assert(EASING_NAMES[easingFn], "Tween easing must be one of tecs2d.tween's built-in easing values")
    local startTime <const> = builder._currentOffset
    local endTime <const> = startTime + duration
    builder._slots[#builder._slots + 1] = {
        kind = kind,
        target = target,
        source = trackSource,
        easingName = easingName,
        easing = easingFn,
        t1 = t1 or 0, t2 = t2 or 0, t3 = t3 or 0, t4 = t4 or 0,
        relative = relative,
        startTime = startTime,
        endTime = endTime,
        duration = duration,
        stateIndex = 0,
    }
    if endTime > builder._currentGroupMaxEnd then
        builder._currentGroupMaxEnd = endTime
    end
    return builder
end

function TimelineBuilder:to(duration: number, easingFn: EasingFunction, target: Target, t1?: number, t2?: number, t3?: number, t4?: number): TimelineBuilder
    return addSlot(self, "to", duration, easingFn, target, nil, false, t1, t2, t3, t4)
end

function TimelineBuilder:adjust(duration: number, easingFn: EasingFunction, target: Target, t1: number, t2?: number, t3?: number, t4?: number): TimelineBuilder
    return addSlot(self, "to", duration, easingFn, target, nil, true, t1, t2, t3, t4)
end

function TimelineBuilder:track(duration: number, easingFn: EasingFunction, target: Target, trackSource: TrackSource): TimelineBuilder
    return addSlot(self, "track", duration, easingFn, target, trackSource, false, 0, 0, 0, 0)
end

function TimelineBuilder:step(pause?: number): TimelineBuilder
    assert(not self._frozen, "Cannot add entries to a finalized timeline")
    self._currentOffset = self._currentGroupMaxEnd + (pause or 0)
    self._currentGroupMaxEnd = self._currentOffset
    return self
end

function TimelineBuilder:emit(name: string): TimelineBuilder
    assert(not self._frozen, "Cannot add entries to a finalized timeline")
    self._emits[#self._emits + 1] = { time = self._currentGroupMaxEnd, name = name }
    return self
end

function TimelineBuilder:run(timeline: Timeline, count?: integer): TimelineBuilder
    assert(not self._frozen, "Cannot add entries to a finalized timeline")
    local effectiveDuration: number
    if timeline.effectiveDuration == -1 then
        assert(count, "run() with infinite timeline requires a count parameter")
        effectiveDuration = timeline.totalDuration * count
    elseif count then
        effectiveDuration = timeline.totalDuration * count
    else
        effectiveDuration = timeline.effectiveDuration
    end
    local runRepeatCount: integer
    if count then
        runRepeatCount = count - 1
    elseif timeline.repeatCount == -1 then
        error("run() with infinite timeline requires a count parameter")
    else
        runRepeatCount = timeline.repeatCount
    end
    local startTime <const> = self._currentOffset
    local endTime <const> = startTime + effectiveDuration
    self._runs[#self._runs + 1] = {
        timeline = timeline,
        startTime = startTime,
        effectiveDuration = effectiveDuration,
        repeatCount = runRepeatCount,
        pingPong = timeline.pingPong,
    }
    if endTime > self._currentGroupMaxEnd then
        self._currentGroupMaxEnd = endTime
    end
    return self
end

function TimelineBuilder:channel(name: string): TimelineBuilder
    assert(not self._frozen, "Cannot modify a finalized timeline")
    self._channel = name
    return self
end

local function finalize(builder: TimelineBuilder, repeatCount: integer, isPingPong: boolean): Timeline
    assert(not builder._frozen, "Timeline already finalized")
    builder._frozen = true
    for i = 1, #builder._slots do
        builder._slots[i].stateIndex = i - 1
    end
    local runs: {RunSlot} = nil
    if #builder._runs > 0 then runs = builder._runs end
    local emits: {EmitSlot} = nil
    if #builder._emits > 0 then emits = builder._emits end
    local totalDuration <const> = builder._currentGroupMaxEnd
    local effectiveDuration: number
    if repeatCount == -1 then
        effectiveDuration = -1
    else
        effectiveDuration = totalDuration * (repeatCount + 1)
    end
    return setmetatable({
        slots = builder._slots,
        runs = runs,
        emits = emits,
        totalDuration = totalDuration,
        effectiveDuration = effectiveDuration,
        stateSize = #builder._slots,
        repeatCount = repeatCount,
        pingPong = isPingPong,
        channel = builder._channel,
    }, TIMELINE_MT)
end

function TimelineBuilder:once(): Timeline
    return finalize(self, 0, false)
end

function TimelineBuilder:loop(count?: integer): Timeline
    if count then return finalize(self, count, false) end
    return finalize(self, -1, false)
end

function TimelineBuilder:pingPong(count?: integer): Timeline
    if count then return finalize(self, count, true) end
    return finalize(self, -1, true)
end

function tween.registerPreset(name: string, timeline: Timeline): Timeline
    timeline.presetName = name
    timeline.pinned = true
    return timeline
end

-------------------------------------------------------------------------------
-- Evaluation
-------------------------------------------------------------------------------

local function targetValuesFromSource(world: World, entity: integer, src: TrackSource): number, number, number, number
    if not src then return 0, 0, 0, 0 end
    if not src.component and src.componentName then
        src.component = componentByName(src.componentName)
    end
    local sourceEntity = entity
    if src.kind == "key" then
        sourceEntity = world:requireKey(src.key)
    elseif src.kind == "trackingTarget" then
        local tt = world:get(entity, TrackingTarget)
        if not tt then return 0, 0, 0, 0 end
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
        if not rel then return 0, 0, 0, 0 end
        sourceEntity = (rel as {string:any}).target as integer
    end
    local c = world:get(sourceEntity, src.component)
    if not c then return 0, 0, 0, 0 end
    local cany = c as {string:number}
    local f <const> = src.fields
    return cany[f[1]] or 0, cany[f[2]] or 0, cany[f[3]] or 0, cany[f[4]] or 0
end

local function evaluateSlots(slots: {Slot}, state: {TweenSlotState}, world: World, target: integer, elapsed: number)
    for i = 1, #(slots or {}) do
        local slot <const> = slots[i]
        local ss <const> = state[slot.stateIndex]
        if elapsed >= slot.startTime and elapsed <= slot.endTime then
            if ss.init == 0 then
                local t1, t2, t3, t4 = slot.t1, slot.t2, slot.t3, slot.t4
                if slot.kind == "track" then
                    t1, t2, t3, t4 = targetValuesFromSource(world, target, slot.source)
                end
                ss.s1, ss.s2, ss.s3, ss.s4, ss.d1, ss.d2, ss.d3, ss.d4 =
                    slot.target.init(world, target, slot.relative, t1, t2, t3, t4)
                ss.init = 1
            end
            local localT = (elapsed - slot.startTime) / slot.duration
            if localT < 0 then localT = 0 end
            if localT > 1 then localT = 1 end
            if slot.kind == "track" then
                local t1, t2, t3, t4 = targetValuesFromSource(world, target, slot.source)
                ss.d1 = t1 - ss.s1
                ss.d2 = t2 - ss.s2
                ss.d3 = t3 - ss.s3
                ss.d4 = t4 - ss.s4
            end
            slot.target.apply(world, target, slot.easing(localT), ss.s1, ss.s2, ss.s3, ss.s4, ss.d1, ss.d2, ss.d3, ss.d4)
        elseif elapsed > slot.endTime then
            if ss.init == 0 then
                local t1, t2, t3, t4 = slot.t1, slot.t2, slot.t3, slot.t4
                if slot.kind == "track" then
                    t1, t2, t3, t4 = targetValuesFromSource(world, target, slot.source)
                end
                ss.s1, ss.s2, ss.s3, ss.s4, ss.d1, ss.d2, ss.d3, ss.d4 =
                    slot.target.init(world, target, slot.relative, t1, t2, t3, t4)
                ss.init = 1
            end
            if slot.kind == "track" then
                local t1, t2, t3, t4 = targetValuesFromSource(world, target, slot.source)
                ss.d1 = t1 - ss.s1
                ss.d2 = t2 - ss.s2
                ss.d3 = t3 - ss.s3
                ss.d4 = t4 - ss.s4
            end
            slot.target.apply(world, target, slot.easing(1), ss.s1, ss.s2, ss.s3, ss.s4, ss.d1, ss.d2, ss.d3, ss.d4)
        elseif elapsed < slot.startTime and ss.init ~= 0 then
            slot.target.apply(world, target, slot.easing(0), ss.s1, ss.s2, ss.s3, ss.s4, ss.d1, ss.d2, ss.d3, ss.d4)
        end
    end
end

local function fireEmits(c: Cursor, tl: Timeline, world: World, target: integer, elapsed: number)
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
                local localElapsed = c.elapsed - runStart
                local cycleDuration <const> = childTl.totalDuration
                if cycleDuration > 0 then
                    local cyclePos = localElapsed % cycleDuration
                    local cycleIndex = math.floor(localElapsed / cycleDuration)
                    if child._lastCycleIndex ~= cycleIndex then
                        ffi.fill(child.state as ffi.CData, ffi.sizeof("TweenSlotState") * childTl.stateSize, 0)
                        if runSlot.pingPong and cycleIndex % 2 == 1 then
                            -- Reverse pass: elapsed runs high-to-low, so
                            -- every emit time reads as already passed;
                            -- suppress instead of firing them all at once.
                            child.nextEmit = (childTl.emits and #childTl.emits or 0) + 1
                        else
                            child.nextEmit = 1
                        end
                        child._lastCycleIndex = cycleIndex
                    end
                    if cycleIndex > child.repeatCount and child.repeatCount >= 0 then
                        cyclePos = cycleDuration
                    elseif runSlot.pingPong and cycleIndex % 2 == 1 then
                        cyclePos = cycleDuration - cyclePos
                    end
                    child.elapsed = cyclePos
                    evaluateCursor(child, world, target)
                end
            elseif childTl and c.elapsed > runEnd and not child.completed then
                child.elapsed = childTl.totalDuration
                evaluateCursor(child, world, target)
                child.completed = true
            end
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
    c.elapsed = c.elapsed + dt * c.direction * c.rate
    evaluateCursor(c, world, target)
    local totalDuration <const> = tl.totalDuration
    local cycleComplete = (c.direction == 1 and c.elapsed >= totalDuration) or (c.direction == -1 and c.elapsed <= 0)
    if cycleComplete then
        if c.repeatCount == -1 or c.repeatCount > 0 then
            if c.repeatCount > 0 then c.repeatCount = c.repeatCount - 1 end
            if tl.pingPong then
                c.direction = -c.direction
                if c.direction == 1 then
                    ffi.fill(c.state as ffi.CData, ffi.sizeof("TweenSlotState") * tl.stateSize, 0)
                    c.nextEmit = 1
                    c.elapsed = -c.elapsed
                else
                    c.elapsed = totalDuration - (c.elapsed - totalDuration)
                end
            else
                ffi.fill(c.state as ffi.CData, ffi.sizeof("TweenSlotState") * tl.stateSize, 0)
                c.nextEmit = 1
                c.elapsed = c.elapsed - totalDuration
            end
        else
            c.elapsed = c.direction == 1 and totalDuration or 0
            evaluateCursor(c, world, target)
            world:emit(0, TweenComplete, target, tl.channel, c.timelineId)
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
    for archetype, len in playbackQuery:iter() do
        local playbacks = archetype:get(TweenPlayback)
        for i = 1, len do
            local pb = playbacks[i]
            for j = 1, #(pb.cursors or {}) do
                local function mark(c: Cursor)
                    live[c.timelineId] = true
                    if c.children then
                        for k = 1, #c.children do mark(c.children[k]) end
                    end
                end
                mark(pb.cursors[j])
            end
        end
    end
    local reg = registry(world)
    for id, tl in pairs(reg.byId) do
        if tl.pinned and (reg.refcounts[id] or 0) > 0 then
            live[id] = true
        end
    end
    return live
end

function tween.plugin(world: World)
    if world.resources[REGISTRY] then return end
    world.resources[REGISTRY] = newRegistry()

    local playbackQuery = world:query({
        name = "tween.Playbacks",
        include = {TweenPlayback},
        onEntitiesRemoved = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
            local reg = registry(world)
            local playbacks = archetype:get(TweenPlayback)
            for row = firstRow, lastRow do
                local pb = playbacks[row]
                if pb then
                    for i = 1, #(pb.cursors or {}) do
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
            local playbacks = archetype:getMut(TweenPlayback)
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

    world:addSystem({
        name = "tween.Update",
        phase = tecs.phases.Update,
        run = function(dt: number)
            local reg <const> = registry(world)
            local emptyEntities: {integer} = {}
            for archetype, len, entities in playbackQuery:iter() do
                local playbacks = archetype:getMut(TweenPlayback)
                for i = 1, len do
                    local entity <const> = entities[i]
                    local pb = playbacks[i]
                    local cursors = pb.cursors
                    for cidx = #cursors, 1, -1 do
                        local c = cursors[cidx]
                        local remove = c.cancelled or not world:isAlive(entity)
                        if not remove then
                            remove = advanceCursor(c, dt, world, entity)
                        end
                        if remove then
                            releaseCursor(reg, c)
                            table.remove(cursors, cidx)
                        end
                    end
                    if #cursors == 0 then
                        emptyEntities[#emptyEntities + 1] = entity
                    end
                end
            end
            for i = 1, #emptyEntities do
                if world:isAlive(emptyEntities[i]) then
                    world:remove(emptyEntities[i], TweenPlayback)
                end
            end
        end
    })
end

return tween
