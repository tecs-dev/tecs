local tecs <const> = require("tecs")
local ffi <const> = require("ffi")

local math_pi, math_sin, math_cos, math_pow <const> = math.pi, math.sin, math.cos, math.pow

local type World = tecs.World
local type Component = tecs.Component

local type EasingFunction = function(t: number): number
local type StepCallback = function(world: World, entity: integer, handle: TweenHandle)
local type TrackTargetFn = function(world: World, entity: integer): number, number, number, number

--- FFI struct for per-slot tween state.
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

--- Interpolator interface: init captures starting state, apply writes the interpolated value.
local record Interpolator
    --- Called once on first tick. Returns s1-s4 (start values) and d1-d4 (deltas).
    init: function(
        world: World, entity: integer, relative: boolean,
        t1: number, t2: number, t3: number, t4: number
    ): number, number, number, number, number, number, number, number

    --- Called every frame. s1-s4 are start values, d1-d4 are deltas.
    apply: function(
        world: World, entity: integer, t: number,
        s1: number, s2: number, s3: number, s4: number,
        d1: number, d2: number, d3: number, d4: number
    )
end

--- A single tween interpolation positioned on the schedule.
local record TweenSlot
    interpolator: Interpolator
    easing: EasingFunction
    t1: number
    t2: number
    t3: number
    t4: number
    relative: boolean
    startTime: number
    endTime: number
    duration: number
    stateIndex: integer  -- 0-based index into the FFI TweenSlotState array
end

--- A nested sub-schedule positioned on the parent schedule.
local record RunSlot
    schedule: Timeline
    startTime: number
    effectiveDuration: number
    repeatCount: integer
    pingPong: boolean
end

--- Immutable schedule: the template produced by the builder. Shared across all entities.
local record Timeline
    slots: {TweenSlot}
    runs: {RunSlot}
    callbacks: {{number, StepCallback}}
    totalDuration: number
    effectiveDuration: number
    stateSize: integer      -- number of TweenSlotState structs needed
    repeatCount: integer
    pingPong: boolean
    channel: string
    onComplete: function(world: World, entity: integer, handle: TweenHandle)

    apply: function(self: Timeline, world: World, entity: integer, speed?: number, delay?: number): TweenHandle
end

--- Public handle interface returned by apply().
local interface TweenHandle
    cancel: function(self: TweenHandle)
    pause: function(self: TweenHandle)
    resume: function(self: TweenHandle)
    getElapsed: function(self: TweenHandle): number
    getRate: function(self: TweenHandle): number
    getDirection: function(self: TweenHandle): integer
end

--- Unified mutable playback state. Used for both root timelines and nested runs.
--- Root playbacks implement TweenHandle.
local record Playback is TweenHandle
    target: integer
    schedule: Timeline
    state: {TweenSlotState}  -- FFI TweenSlotState[?] array
    children: {Playback}    -- per-run playback (nil if no runs)
    elapsed: number
    direction: integer
    repeatCount: integer    -- mutable copy (decrements)
    nextCallback: integer
    rate: number            -- only used on root
    paused: boolean         -- when true, playback doesn't advance
    delay: number           -- seconds to wait before starting
    completed: boolean      -- true after onComplete has fired (for nested runs)

    cancelled: boolean      -- flag for deferred removal by the system
    _lastCycleIndex: integer -- tracks cycle boundary crossings for nested runs
end

local record TimelineBuilder
    _slots: {TweenSlot}
    _runs: {RunSlot}
    _callbacks: {{number, StepCallback}}
    _currentOffset: number
    _currentGroupMaxEnd: number
    _frozen: boolean
    _channel: string
    _onComplete: function(world: World, entity: integer, handle: TweenHandle)

    channel: function(self: TimelineBuilder, name: string): TimelineBuilder

    to: function(
        self: TimelineBuilder,
        duration: number,
        easingFn: EasingFunction,
        interpolator: Interpolator,
        t1?: number, t2?: number, t3?: number, t4?: number
    ): TimelineBuilder

    adjust: function(
        self: TimelineBuilder,
        duration: number,
        easingFn: EasingFunction,
        interpolator: Interpolator,
        t1: number, t2?: number, t3?: number, t4?: number
    ): TimelineBuilder

    step: function(self: TimelineBuilder, pauseOrCallback?: number | StepCallback, callback?: StepCallback): TimelineBuilder
    run: function(self: TimelineBuilder, schedule: Timeline, count?: integer): TimelineBuilder
    onComplete: function(self: TimelineBuilder, fn: function(world: World, entity: integer, handle: TweenHandle)): TimelineBuilder
    once: function(self: TimelineBuilder): Timeline
    loop: function(self: TimelineBuilder, count?: integer): Timeline
    pingPong: function(self: TimelineBuilder, count?: integer): Timeline
end

local ACTIVE_TWEENS <const>: tecs.Key<{Playback}> = tecs.newKey()
local CHANNEL_MAP <const>: tecs.Key<{integer: {string: Playback}}> = tecs.newKey()

local record tween
    type Interpolator = Interpolator
    type TweenHandle = TweenHandle
    type Timeline = Timeline
    type TimelineBuilder = TimelineBuilder
    type Playback = Playback

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

    field: function(component: Component, fieldName: string): Interpolator
    field2: function(component: Component, fieldA: string, fieldB: string): Interpolator
    angle: function(component: Component, fieldName: string): Interpolator
    track: function(base: Interpolator, getTargetFn: TrackTargetFn): Interpolator

    translateX: Interpolator
    translateY: Interpolator
    translateXY: Interpolator
    rotation: Interpolator
    rotationShortest: Interpolator
    scaleX: Interpolator
    scaleY: Interpolator
    scaleXY: Interpolator

    alpha: Interpolator
    color: Interpolator

    timeline: function(): TimelineBuilder

    plugin: function(world: World)
end

-------------------------------------------------------------------------------
-- Easing functions
-------------------------------------------------------------------------------

function tween.linear(t: number): number return t end

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
makeVariants("sine", function(t: number): number return 1 - math_cos(t * math_pi * 0.5) end)
makeVariants("expo", function(t: number): number
    if t == 0 then return 0 end
    return math_pow(2, 10 * (t - 1))
end)
makeVariants("back", function(t: number): number
    local s <const> = 1.70158
    return t * t * ((s + 1) * t - s)
end)
makeVariants("elastic", function(t: number): number
    if t == 0 then return 0 end
    if t == 1 then return 1 end
    local p <const> = 0.3
    return -math_pow(2, 10 * (t - 1)) * math_sin((t - 1 - p / 4) * (2 * math_pi) / p)
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

-------------------------------------------------------------------------------
-- Playback methods (Handle interface)
-------------------------------------------------------------------------------

local PLAYBACK_MT <const>: metatable<Playback> = { __index = Playback }

function Playback:pause()
    self.paused = true
end

function Playback:resume()
    self.paused = false
end

function Playback:getElapsed(): number
    return self.elapsed
end

function Playback:getRate(): number
    return self.rate
end

function Playback:getDirection(): integer
    return self.direction
end

function Playback:cancel()
    self.cancelled = true
end

-------------------------------------------------------------------------------
-- Timeline (apply)
-------------------------------------------------------------------------------

--- Create a Playback from a Timeline, recursively for nested runs.
local function createPlayback(sched: Timeline, target: integer, rate: number, delay: number): Playback
    local state = ffi.new("TweenSlotState[?]", sched.stateSize) as {TweenSlotState}

    local children: {Playback} = nil
    if sched.runs and #sched.runs > 0 then
        children = {}
        for i = 1, #sched.runs do
            local runSlot <const> = sched.runs[i]
            children[i] = createPlayback(runSlot.schedule, target, 1, 0)
            children[i].repeatCount = runSlot.repeatCount
        end
    end

    return setmetatable({
        target = target,
        schedule = sched,
        state = state,
        children = children,
        elapsed = 0,
        direction = 1,
        repeatCount = sched.repeatCount,
        nextCallback = 1,
        rate = rate,
        delay = delay or 0,
        _lastCycleIndex = 0,
    }, PLAYBACK_MT)
end

function Timeline:apply(world: World, entity: integer, speed?: number, delay?: number): TweenHandle
    local activeTweens = world.resources[ACTIVE_TWEENS]
    assert(activeTweens, "Tween plugin not added. Call world:addPlugin(tween.plugin)")

    -- Cancel existing tween on same entity+channel
    if self.channel then
        local channels = world.resources[CHANNEL_MAP]
        local entityChannels = channels[entity]
        if entityChannels then
            local existing = entityChannels[self.channel]
            if existing then
                existing.cancelled = true
            end
        else
            entityChannels = {}
            channels[entity] = entityChannels
        end
        local pb <const> = createPlayback(self, entity, speed or 1, delay or 0)
        entityChannels[self.channel] = pb
        activeTweens[#activeTweens + 1] = pb
        return pb
    end

    local pb <const> = createPlayback(self, entity, speed or 1, delay or 0)
    activeTweens[#activeTweens + 1] = pb
    return pb
end

-------------------------------------------------------------------------------
-- Interpolator factories
-------------------------------------------------------------------------------

function tween.field(component: Component, fieldName: string): Interpolator
    return {
        init = function(
            world: World, entity: integer, relative: boolean, t1: number
        ): number, number, number, number, number, number, number, number
            local c = world:get(entity, component)
            if c then
                local cany = c as {string: number}
                local startVal <const> = cany[fieldName]
                local delta <const> = relative and t1 or (t1 - startVal)
                return startVal, 0, 0, 0, delta, 0, 0, 0
            end
            return 0, 0, 0, 0, 0, 0, 0, 0
        end,
        apply = function(world: World, entity: integer, t: number, s1: number, _s2: number, _s3: number, _s4: number, d1: number)
            local c = world:get(entity, component)
            if c then
                (c as {string: number})[fieldName] = s1 + d1 * t
                world:markComponentDirty(entity, component)
            end
        end
    }
end

function tween.angle(component: Component, fieldName: string): Interpolator
    local TWO_PI <const> = math_pi * 2
    return {
        init = function(
            world: World, entity: integer, relative: boolean, t1: number
        ): number, number, number, number, number, number, number, number
            local c = world:get(entity, component)
            if c then
                local cany = c as {string: number}
                local startVal <const> = cany[fieldName]
                local delta: number
                if relative then
                    delta = t1
                else
                    local diff <const> = (t1 - startVal) % TWO_PI
                    delta = 2 * diff % TWO_PI - diff
                end
                return startVal, 0, 0, 0, delta, 0, 0, 0
            end
            return 0, 0, 0, 0, 0, 0, 0, 0
        end,
        apply = function(
            world: World, entity: integer, t: number, s1: number, _s2: number, _s3: number, _s4: number, d1: number
        )
            local c = world:get(entity, component)
            if c then
                (c as {string: number})[fieldName] = s1 + d1 * t
                world:markComponentDirty(entity, component)
            end
        end
    }
end

function tween.field2(component: Component, fieldA: string, fieldB: string): Interpolator
    return {
        init = function(
            world: World, entity: integer, relative: boolean, t1: number, t2: number
        ): number, number, number, number, number, number, number, number
            local c = world:get(entity, component)
            if c then
                local cany = c as {string: number}
                local a <const> = cany[fieldA]
                local b <const> = cany[fieldB]
                if relative then
                    return a, b, 0, 0, t1, t2, 0, 0
                else
                    return a, b, 0, 0, t1 - a, t2 - b, 0, 0
                end
            end
            return 0, 0, 0, 0, 0, 0, 0, 0
        end,
        apply = function(world: World, entity: integer, t: number, s1: number, s2: number,
                _s3: number, _s4: number, d1: number, d2: number)
            local c = world:get(entity, component)
            if c then
                local cany = c as {string: number}
                cany[fieldA] = s1 + d1 * t
                cany[fieldB] = s2 + d2 * t
                world:markComponentDirty(entity, component)
            end
        end
    }
end

local Transform <const> = tecs.builtins.Transform

tween.translateX = tween.field(Transform, "x")
tween.translateY = tween.field(Transform, "y")
tween.translateXY = tween.field2(Transform, "x", "y")
tween.rotation = tween.field(Transform, "rotation")
tween.rotationShortest = tween.angle(Transform, "rotation")
tween.scaleX = tween.field(Transform, "scaleX")
tween.scaleY = tween.field(Transform, "scaleY")
tween.scaleXY = tween.field2(Transform, "scaleX", "scaleY")

do
    local _resolved = false
    local _alpha: Interpolator = nil
    local _colorComponent: Component = nil
    local function resolveColor()
        if not _resolved then
            _resolved = true
            local ok, mod = pcall(require, "tecs2d.gfx.internal.Color")
            assert(ok, "tween.alpha/color requires tecs2d.gfx (Color component)")
            _colorComponent = mod as Component
            _alpha = tween.field(_colorComponent, "a")
        end
    end
    tween.alpha = {
        init = function(
            world: World, entity: integer, relative: boolean, t1: number, t2: number, t3: number, t4: number
        ): number, number, number, number, number, number, number, number
            resolveColor()
            return _alpha.init(world, entity, relative, t1, t2, t3, t4)
        end,
        apply = function(world: World, entity: integer, t: number,
                s1: number, s2: number, s3: number, s4: number, d1: number, d2: number, d3: number, d4: number)
            _alpha.apply(world, entity, t, s1, s2, s3, s4, d1, d2, d3, d4)
        end
    }

    tween.color = {
        init = function(
            world: World, entity: integer, relative: boolean, t1: number, t2: number, t3: number, t4: number
        ): number, number, number, number, number, number, number, number
            resolveColor()
            local c = world:get(entity, _colorComponent)
            if c then
                local cany = c as {string: number}
                local r, g, b, a = cany.r, cany.g, cany.b, cany.a
                if relative then
                    return r, g, b, a, t1, t2, t3, t4
                else
                    return r, g, b, a, t1 - r, t2 - g, t3 - b, t4 - a
                end
            end
            return 0, 0, 0, 0, 0, 0, 0, 0
        end,
        apply = function(world: World, entity: integer, t: number,
                s1: number, s2: number, s3: number, s4: number, d1: number, d2: number, d3: number, d4: number)
            local c = world:get(entity, _colorComponent)
            if c then
                local cany = c as {string: number}
                cany.r = s1 + d1 * t
                cany.g = s2 + d2 * t
                cany.b = s3 + d3 * t
                cany.a = s4 + d4 * t
                world:markComponentDirty(entity, _colorComponent)
            end
        end
    }
end

function tween.track(base: Interpolator, getTargetFn: TrackTargetFn): Interpolator
    return {
        init = function(
            world: World, entity: integer, _relative: boolean, _t1: number, _t2: number, _t3: number, _t4: number
        ): number, number, number, number, number, number, number, number
            return base.init(world, entity, false, 0, 0, 0, 0)
        end,
        apply = function(
            world: World, entity: integer, t: number,
            s1: number, s2: number, s3: number, s4: number,
            d1: number, d2: number, d3: number, d4: number
        )
            local t1, t2, t3, t4 = getTargetFn(world, entity)
            local nd1 = t1 and (t1 - s1) or d1
            local nd2 = t2 and (t2 - s2) or d2
            local nd3 = t3 and (t3 - s3) or d3
            local nd4 = t4 and (t4 - s4) or d4
            base.apply(world, entity, t, s1, s2, s3, s4, nd1, nd2, nd3, nd4)
        end
    }
end

-------------------------------------------------------------------------------
-- Builder
-------------------------------------------------------------------------------

local BUILDER_MT <const>: metatable<TimelineBuilder> = { __index = TimelineBuilder }

function tween.timeline(): TimelineBuilder
    return setmetatable({
        _slots = {},
        _runs = {},
        _callbacks = {},
        _currentOffset = 0,
        _currentGroupMaxEnd = 0,
        _frozen = false
    }, BUILDER_MT)
end

function TimelineBuilder:to(
    duration: number,
    easingFn: EasingFunction,
    interpolator: Interpolator,
    t1?: number, t2?: number, t3?: number, t4?: number
): TimelineBuilder
    assert(not self._frozen, "Cannot add entries to a finalized timeline")
    assert(duration > 0, "Tween duration must be greater than 0")

    local startTime <const> = self._currentOffset
    local endTime <const> = startTime + duration

    self._slots[#self._slots + 1] = {
        interpolator = interpolator,
        easing = easingFn,
        t1 = t1, t2 = t2 or 0, t3 = t3 or 0, t4 = t4 or 0,
        startTime = startTime,
        endTime = endTime,
        duration = duration,
        stateIndex = 0  -- computed in finalize
    }

    if endTime > self._currentGroupMaxEnd then
        self._currentGroupMaxEnd = endTime
    end

    return self
end

function TimelineBuilder:adjust(
    duration: number,
    easingFn: EasingFunction,
    interpolator: Interpolator,
    t1: number, t2?: number, t3?: number, t4?: number
): TimelineBuilder
    assert(not self._frozen, "Cannot add entries to a finalized timeline")
    assert(duration > 0, "Tween duration must be greater than 0")

    local startTime <const> = self._currentOffset
    local endTime <const> = startTime + duration

    self._slots[#self._slots + 1] = {
        interpolator = interpolator,
        easing = easingFn,
        t1 = t1, t2 = t2 or 0, t3 = t3 or 0, t4 = t4 or 0,
        relative = true,
        startTime = startTime,
        endTime = endTime,
        duration = duration,
        stateIndex = 0  -- computed in finalize
    }

    if endTime > self._currentGroupMaxEnd then
        self._currentGroupMaxEnd = endTime
    end

    return self
end

function TimelineBuilder:step(pauseOrCallback?: number | StepCallback, callback?: StepCallback): TimelineBuilder
    assert(not self._frozen, "Cannot add entries to a finalized timeline")

    local pause: number = 0
    local cb: StepCallback = nil

    if pauseOrCallback is number then
        pause = pauseOrCallback
        cb = callback
    elseif pauseOrCallback then
        cb = pauseOrCallback as StepCallback
    end

    if cb then
        self._callbacks[#self._callbacks + 1] = {self._currentGroupMaxEnd, cb}
    end

    self._currentOffset = self._currentGroupMaxEnd + pause
    self._currentGroupMaxEnd = self._currentOffset
    return self
end

function TimelineBuilder:run(schedule: Timeline, count?: integer): TimelineBuilder
    assert(not self._frozen, "Cannot add entries to a finalized timeline")

    local effectiveDuration: number
    local repeatCount <const> = schedule.repeatCount
    local isPingPong <const> = schedule.pingPong

    if schedule.effectiveDuration == -1 then
        assert(count, "run() with infinite timeline requires a count parameter")
        effectiveDuration = schedule.totalDuration * count
    elseif count then
        effectiveDuration = schedule.totalDuration * count
    else
        effectiveDuration = schedule.effectiveDuration
    end

    local runRepeatCount: integer
    if count then
        runRepeatCount = count - 1
    elseif repeatCount == -1 then
        error("run() with infinite timeline requires a count parameter")
    else
        runRepeatCount = repeatCount
    end

    local startTime <const> = self._currentOffset
    local endTime <const> = startTime + effectiveDuration

    self._runs[#self._runs + 1] = {
        schedule = schedule,
        startTime = startTime,
        effectiveDuration = effectiveDuration,
        repeatCount = runRepeatCount,
        pingPong = isPingPong
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

function TimelineBuilder:onComplete(fn: function(world: World, entity: integer, handle: TweenHandle)): TimelineBuilder
    assert(not self._frozen, "Cannot modify a finalized timeline")
    self._onComplete = fn
    return self
end

local TIMELINE_MT <const>: metatable<Timeline> = { __index = Timeline }

local function finalize(builder: TimelineBuilder, repeatCount: integer, isPingPong: boolean): Timeline
    assert(not builder._frozen, "Timeline already finalized")
    builder._frozen = true

    -- Compute state offsets for each slot
    local slots <const> = builder._slots
    for i = 1, #slots do
        slots[i].stateIndex = i - 1
    end

    local totalDuration <const> = builder._currentGroupMaxEnd
    local effectiveDuration: number
    if repeatCount == -1 then
        effectiveDuration = -1
    else
        effectiveDuration = totalDuration * (repeatCount + 1)
    end

    local runs: {RunSlot} = nil
    if #builder._runs > 0 then
        runs = builder._runs
    end

    local callbacks: {{number, StepCallback}} = nil
    if #builder._callbacks > 0 then
        callbacks = builder._callbacks
    end

    return setmetatable({
        slots = slots,
        runs = runs,
        callbacks = callbacks,
        totalDuration = totalDuration,
        effectiveDuration = effectiveDuration,
        stateSize = #slots,
        repeatCount = repeatCount,
        pingPong = isPingPong,
        channel = builder._channel,
        onComplete = builder._onComplete
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

-------------------------------------------------------------------------------
-- System
-------------------------------------------------------------------------------

--- Evaluate all tween slots at the given elapsed time.
local function evaluateSlots(
    slots: {TweenSlot},
    state: {TweenSlotState},
    world: World,
    target: integer,
    elapsed: number
)
    for i = 1, #slots do
        local slot <const> = slots[i]
        local ss <const> = state[slot.stateIndex]
        if elapsed >= slot.startTime and elapsed <= slot.endTime then
            if ss.init == 0 then
                ss.s1, ss.s2, ss.s3, ss.s4, ss.d1, ss.d2, ss.d3, ss.d4 =
                    slot.interpolator.init(world, target, slot.relative, slot.t1, slot.t2, slot.t3, slot.t4)
                ss.init = 1
            end
            local localT = (elapsed - slot.startTime) / slot.duration
            if localT < 0 then localT = 0 end
            if localT > 1 then localT = 1 end
            local easedT <const> = slot.easing(localT)
            slot.interpolator.apply(world, target, easedT, ss.s1, ss.s2, ss.s3, ss.s4, ss.d1, ss.d2, ss.d3, ss.d4)
        elseif elapsed > slot.endTime then
            if ss.init == 0 then
                ss.s1, ss.s2, ss.s3, ss.s4, ss.d1, ss.d2, ss.d3, ss.d4 =
                    slot.interpolator.init(world, target, slot.relative, slot.t1, slot.t2, slot.t3, slot.t4)
                ss.init = 1
            end
            slot.interpolator.apply(world, target, slot.easing(1), ss.s1, ss.s2, ss.s3, ss.s4, ss.d1, ss.d2, ss.d3, ss.d4)
        elseif elapsed < slot.startTime and ss.init ~= 0 then
            slot.interpolator.apply(world, target, slot.easing(0), ss.s1, ss.s2, ss.s3, ss.s4, ss.d1, ss.d2, ss.d3, ss.d4)
        end
    end
end

--- Fire step callbacks that have been reached.
local function fireCallbacks(pb: Playback, world: World, target: integer, elapsed: number)
    local cbs <const> = pb.schedule.callbacks
    if not cbs then return end
    while pb.nextCallback <= #cbs do
        local sc <const> = cbs[pb.nextCallback]
        if elapsed >= sc[1] then
            pb.nextCallback = pb.nextCallback + 1
            sc[2](world, target, pb as TweenHandle)
        else
            break
        end
    end
end

--- Evaluate a playback at its current elapsed time (shared by root and nested runs).
local function evaluatePlayback(pb: Playback, world: World, target: integer)
    local sched <const> = pb.schedule

    -- Evaluate tween slots
    evaluateSlots(sched.slots, pb.state, world, target, pb.elapsed)

    -- Fire step callbacks
    fireCallbacks(pb, world, target, pb.elapsed)

    -- Evaluate nested runs
    if sched.runs and pb.children then
        for i = 1, #sched.runs do
            local runSlot <const> = sched.runs[i]
            local child <const> = pb.children[i]
            local runStart <const> = runSlot.startTime
            local runEnd <const> = runStart + runSlot.effectiveDuration

            if pb.elapsed >= runStart and pb.elapsed <= runEnd then
                local localElapsed = pb.elapsed - runStart
                local cycleDuration <const> = child.schedule.totalDuration
                if cycleDuration > 0 then
                    local cyclePos = localElapsed % cycleDuration
                    local cycleIndex = math.floor(localElapsed / cycleDuration)

                    -- Reset child state on cycle boundary crossing
                    if child._lastCycleIndex ~= cycleIndex then
                        ffi.fill(child.state as ffi.CData, ffi.sizeof("TweenSlotState") * child.schedule.stateSize, 0)
                        child.nextCallback = 1
                        child._lastCycleIndex = cycleIndex
                    end

                    if cycleIndex > child.repeatCount and child.repeatCount >= 0 then
                        cyclePos = cycleDuration
                    elseif runSlot.pingPong and cycleIndex % 2 == 1 then
                        cyclePos = cycleDuration - cyclePos
                    end
                    child.elapsed = cyclePos
                    evaluatePlayback(child, world, target)
                end
            elseif pb.elapsed > runEnd then
                -- Run completed: clamp to final state (once)
                if not child.completed then
                    if runSlot.pingPong and child.repeatCount % 2 == 0 then
                        child.elapsed = 0
                    else
                        child.elapsed = child.schedule.totalDuration
                    end
                    evaluatePlayback(child, world, target)
                    if child.schedule.onComplete then
                        child.schedule.onComplete(world, target, child as TweenHandle)
                    end
                    child.completed = true
                end
            end
        end
    end
end

--- Returns true if the playback is finished and should be removed.
local function advancePlayback(pb: Playback, dt: number, world: World): boolean
    if pb.paused then return false end

    if pb.delay > 0 then
        pb.delay = pb.delay - dt
        if pb.delay > 0 then return false end
        dt = -pb.delay
        pb.delay = 0
    end

    local target <const> = pb.target
    pb.elapsed = pb.elapsed + dt * pb.direction * pb.rate

    evaluatePlayback(pb, world, target)

    -- Check cycle completion
    local totalDuration <const> = pb.schedule.totalDuration
    local cycleComplete = false
    if pb.direction == 1 and pb.elapsed >= totalDuration then
        cycleComplete = true
    elseif pb.direction == -1 and pb.elapsed <= 0 then
        cycleComplete = true
    end

    if cycleComplete then
        if pb.repeatCount == -1 or pb.repeatCount > 0 then
            if pb.repeatCount > 0 then
                pb.repeatCount = pb.repeatCount - 1
            end

            if pb.schedule.pingPong then
                pb.direction = -pb.direction
                if pb.direction == 1 then
                    -- Flipping back to forward: reset state for fresh capture
                    ffi.fill(pb.state as ffi.CData, ffi.sizeof("TweenSlotState") * pb.schedule.stateSize, 0)
                    pb.nextCallback = 1
                    pb.elapsed = -pb.elapsed
                else
                    pb.elapsed = totalDuration - (pb.elapsed - totalDuration)
                end
            else
                -- Non-pingPong loop: reset state for fresh init on next cycle
                ffi.fill(pb.state as ffi.CData, ffi.sizeof("TweenSlotState") * pb.schedule.stateSize, 0)
                pb.nextCallback = 1
                pb.elapsed = pb.elapsed - totalDuration
            end
        else
            -- Final clamp
            if pb.direction == 1 then
                pb.elapsed = totalDuration
            else
                pb.elapsed = 0
            end
            evaluatePlayback(pb, world, target)

            if pb.schedule.onComplete then
                pb.schedule.onComplete(world, target, pb as TweenHandle)
            end
            return true  -- finished
        end
    end

    return false
end

-------------------------------------------------------------------------------
-- Plugin
-------------------------------------------------------------------------------

function tween.plugin(world: World)
    if world.resources[ACTIVE_TWEENS] then return end
    world.resources[ACTIVE_TWEENS] = {}
    world.resources[CHANNEL_MAP] = {}

    world:addSystem({
        name = "tween.Update",
        phase = tecs.phases.Update,
        run = function(dt: number)
            local activeTweens <const> = world.resources[ACTIVE_TWEENS]
            local channels <const> = world.resources[CHANNEL_MAP]
            for i = #activeTweens, 1, -1 do
                local pb <const> = activeTweens[i]
                local remove = false

                if pb.cancelled or not world:isAlive(pb.target) then
                    remove = true
                elseif advancePlayback(pb, dt, world) then
                    remove = true
                end

                if remove then
                    local ch <const> = pb.schedule.channel
                    if ch then
                        local ec = channels[pb.target]
                        if ec and ec[ch] == pb then
                            ec[ch] = nil
                        end
                    end
                    table.remove(activeTweens, i)
                end
            end
        end
    })

end

return tween
