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

local tecs <const> = require("tecs")
local ffi <const> = require("ffi")
local components <const> = require("tecs.internal.components")

local mathPi, mathSin, mathCos, mathPow <const> = math.pi, math.sin, math.cos, math.pow

local type World = tecs.World
local type Component = tecs.Component

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
ffi.cdef[[
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
]]

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
local interface Target end

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
        world: World, entity: integer, relative: boolean,
        t1: number, t2: number, t3: number, t4: number
    ): number, number, number, number, number, number, number, number

    apply: function(
        world: World, entity: integer, t: number,
        s1: number, s2: number, s3: number, s4: number,
        d1: number, d2: number, d3: number, d4: number
    )
end

--- A live component-field tracking source.
local interface TrackSource end

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

--- Selects another entity as a dynamic tracking source.
local record TrackingTarget is tecs.Component
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
    related: function(
        relationship: Component, component: Component, field: string | {string}
    ): TrackSource
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

    --- Component selecting a dynamic tracking source entity.
    TrackingTarget: TrackingTarget

    --- The built-in easing curves, by name.
    easing: Easings

    --- The built-in targets, and the constructors for new ones.
    target: Targets

    --- The tracking-source constructors.
    source: Sources

    --- Every built-in easing keyed by its name, and the reverse lookup that
    --- turns a curve back into the name a program can carry.
    easings: {EasingName: EasingFunction}
    easingNames: {EasingFunction: EasingName}

    --- Every built-in target keyed by its stable serialized id.
    builtinTargets: {TargetName: TargetImpl}

    --- Resolve an authored easing, given either as a name or as one of the
    --- built-in functions, to both.
    resolveEasing: function(value: any): EasingName, EasingFunction

    --- Resolve an authored target, given either as a built-in name or as a
    --- target value.
    resolveTargetValue: function(value: any): TargetImpl

    --- Turn a target or source into plain data, and back. This is the codec a
    --- compiled program's const pool carries.
    serializeTarget: function(t: Target): {string:any}
    deserializeTarget: function(data: {string:any}): TargetImpl
    serializeSource: function(s: TrackSource): {string:any}
    deserializeSource: function(data: {string:any}): TrackSourceImpl

    --- Read the four numbers a `track` slot is currently chasing.
    valuesFromSource: function(
        world: World, entity: integer, src: TrackSourceImpl
    ): number, number, number, number

    --- Advance every slot to `elapsed`, writing the components they target.
    ---
    --- The whole loop is one instruction body rather than one per slot, so
    --- dispatch amortizes across the slots a timeline holds.
    evaluateSlots: function(
        slots: {Slot}, state: {TweenSlotState},
        world: World, target: integer, elapsed: number
    )

    --- A zeroed state buffer for `count` slots.
    newState: function(count: integer): {TweenSlotState}

    --- Zero an existing state buffer, which restarts every slot.
    clearState: function(state: {TweenSlotState}, count: integer)
end

-------------------------------------------------------------------------------
-- Easing
-------------------------------------------------------------------------------

local easing: Easings = {}

function easing.linear(t: number): number return t end

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
        if t < 0.5 then return 0.5 * inFn(2 * t) end
        return 1 - 0.5 * inFn(2 - 2 * t)
    end
    e[name .. "OutIn"] = function(t: number): number
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
    easing.bounceIn = bounceIn
    easing.bounceOut = bounceOut
    easing.bounceInOut = function(t: number): number
        if t < 0.5 then return 0.5 * bounceIn(2 * t) end
        return 0.5 * bounceOut(2 * t - 1) + 0.5
    end
    easing.bounceOutIn = function(t: number): number
        if t < 0.5 then return 0.5 * bounceOut(2 * t) end
        return 0.5 * bounceIn(2 * t - 1) + 0.5
    end
end

do
    local names <const>: {EasingName} = {
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
    local e = easing as {string: EasingFunction}
    for i = 1, #names do
        registerEasing(names[i], e[names[i]])
    end
end

-------------------------------------------------------------------------------
-- Targets and tracking sources
-------------------------------------------------------------------------------

local TARGET_MT <const>: metatable<TargetImpl> = { __index = TargetImpl }
local targetInit: function(
    TargetImpl, World, integer, boolean, number, number, number, number
): (number, number, number, number, number, number, number, number)
local targetApply: function(
    TargetImpl, World, integer, number, number, number, number, number, number, number, number, number
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
        world: World, entity: integer, relative: boolean,
        t1: number, t2: number, t3: number, t4: number
    ): (number, number, number, number, number, number, number, number)
        return targetInit(t, world, entity, relative, t1, t2, t3, t4)
    end
    t.apply = function(
        world: World, entity: integer, tv: number,
        s1: number, s2: number, s3: number, s4: number,
        d1: number, d2: number, d3: number, d4: number
    )
        targetApply(t, world, entity, tv, s1, s2, s3, s4, d1, d2, d3, d4)
    end
    return t
end

targetInit = function(self: TargetImpl,
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

targetApply = function(self: TargetImpl,
    world: World, entity: integer, t: number,
    s1: number, s2: number, s3: number, s4: number,
    d1: number, d2: number, d3: number, d4: number
)
    resolveTarget(self)
    local c = world:getMut(entity, self.component)
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
    kind: TrackSourceKind, component: Component, field: string | {string},
    key?: string, relationship?: Component
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

function source.related(
    relationship: Component, component: Component, field: string | {string}
): TrackSource
    return newSource("relationship", component, field, nil, relationship)
end

local Transform <const> = tecs.builtins.Transform
targets.translateX = newTarget(Transform, {"x"}, "field", "transform.x")
targets.translateY = newTarget(Transform, {"y"}, "field", "transform.y")
targets.translateXY = newTarget(Transform, {"x", "y"}, "field2", "transform.xy")
targets.rotation = newTarget(Transform, {"rotation"}, "field", "transform.rotation")
targets.rotationShortest = newTarget(Transform, {"rotation"}, "angle", "transform.rotationShortest")
targets.scaleX = newTarget(Transform, {"scaleX"}, "field", "transform.scaleX")
targets.scaleY = newTarget(Transform, {"scaleY"}, "field", "transform.scaleY")
targets.scaleXY = newTarget(Transform, {"scaleX", "scaleY"}, "field2", "transform.scaleXY")

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
    targets.alpha = newTarget(color(), {"a"}, "field", "color.a")
    targets.color = newTarget(colorComponent, {"r", "g", "b", "a"}, "color", "color.rgba")
end

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

tweeneval.TrackingTarget = tecs.newComponent({
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
    return assert(EASING_NAMES[easingFn],
        "Tween easing must be a built-in easing name or value"), easingFn
end

function tweeneval.resolveTargetValue(value: any): TargetImpl
    if value is string then
        return assert(BUILTIN_TARGETS[value as TargetName], "Unknown tween target " .. value)
    end
    return value as TargetImpl
end

function tweeneval.serializeTarget(t: Target): {string:any}
    local impl <const> = t as TargetImpl
    return {
        id = impl.id,
        component = impl.componentName or (impl.component and impl.component.componentName),
        fields = impl.fields,
        mode = impl.mode,
    }
end

function tweeneval.deserializeTarget(data: {string:any}): TargetImpl
    local id = data.id as string
    local builtin = id and BUILTIN_TARGETS[id as TargetName]
    if builtin then return builtin end
    return newTarget(
        componentByName(data.component as string),
        data.fields as {string},
        (data.mode as TargetMode) or "field",
        id
    )
end

function tweeneval.serializeSource(s: TrackSource): {string:any}
    if not s then return nil end
    local impl <const> = s as TrackSourceImpl
    return {
        kind = impl.kind,
        key = impl.key,
        relationship = impl.relationshipName or (impl.relationship and impl.relationship.componentName),
        component = impl.componentName or (impl.component and impl.component.componentName),
        fields = impl.fields,
    }
end

function tweeneval.deserializeSource(data: {string:any}): TrackSourceImpl
    if not data then return nil end
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
-- Evaluation
-------------------------------------------------------------------------------

local TrackingTargetComponent <const> = tweeneval.TrackingTarget

function tweeneval.valuesFromSource(
    world: World, entity: integer, src: TrackSourceImpl
): number, number, number, number
    if not src then return 0, 0, 0, 0 end
    if not src.component and src.componentName then
        src.component = componentByName(src.componentName)
    end
    local sourceEntity = entity
    if src.kind == "key" then
        sourceEntity = world:requireKey(src.key)
    elseif src.kind == "trackingTarget" then
        local tt = world:get(entity, TrackingTargetComponent)
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
        sourceEntity = (rel as RelationshipValue).target
    end
    local c = world:get(sourceEntity, src.component)
    if not c then return 0, 0, 0, 0 end
    local cany = c as {string:number}
    local f <const> = src.fields
    return cany[f[1]] or 0, cany[f[2]] or 0, cany[f[3]] or 0, cany[f[4]] or 0
end

local valuesFromSource <const> = tweeneval.valuesFromSource

function tweeneval.evaluateSlots(
    slots: {Slot}, state: {TweenSlotState},
    world: World, target: integer, elapsed: number
)
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
                ss.s1, ss.s2, ss.s3, ss.s4, ss.d1, ss.d2, ss.d3, ss.d4 =
                    slot.target.init(world, target, slot.relative, t1, t2, t3, t4)
                ss.init = 1
            end
            if localT < 0 then localT = 0 end
            if localT > 1 then localT = 1 end
            if slot.kind == "track" and active then
                local t1, t2, t3, t4 = valuesFromSource(world, target, slot.source)
                ss.d1 = t1 - ss.s1
                ss.d2 = t2 - ss.s2
                ss.d3 = t3 - ss.s3
                ss.d4 = t4 - ss.s4
            end
            if ss.applied == 0 or ss.lastT ~= localT or (slot.kind == "track" and active) then
                slot.target.apply(
                    world, target, slot.easing(localT),
                    ss.s1, ss.s2, ss.s3, ss.s4,
                    ss.d1, ss.d2, ss.d3, ss.d4
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
tweeneval.easingNames = EASING_NAMES
tweeneval.builtinTargets = BUILTIN_TARGETS

return tweeneval
