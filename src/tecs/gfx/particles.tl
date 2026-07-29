--[=[
GPU particle effects, emitter playback, pool sizing, and rendering limits.

An entity represents an emitter. The GPU owns individual particles, so game
code controls an effect and its emitter rather than inspecting particles one
at a time.

```teal
local sparks <const> = tecs.gfx.particles.effect({
    name = "game.sparks",
    capacity = 256,
    schedule = {rate = 120, duration = 0.3},
    spawn = {shape = "disc", width = 4, outward = true},
    initial = {
        lifetime = {min = 0.2, max = 0.5},
        speed = {min = 40, max = 120},
        size = 3,
    },
    update = {
        drag = 2.0,
        size = tecs.gfx.particles.curve({
            {0.0, 1.0},
            {1.0, 0.0},
        }),
    },
})

world:addPlugin(tecs.gfx.particles.plugin({
    renderer = app.renderer,
    capacity = 4096,
}))

world:spawn(
    tecs.Transform(120, 80, 0, 1, 0, 1, 1),
    tecs.gfx.particles.ParticleEmitter({effect = sparks})
)
```

An immutable [`Effect`](tealdoc:tecs.gfx.particles.Effect) describes schedule,
spawn, initial state, updates, and rendering. A
[`ParticleEmitter`](tealdoc:tecs.gfx.particles.ParticleEmitter) names the
effect and carries playback state. Effect names form a snapshot compatibility
surface.

## Emission and motion

Schedules combine rate, delay, duration, looping, and timed bursts.
`duration = 0` keeps a cycle open. An emission that finds no free effect slot
either drops the new particle or replaces the oldest, according to `overflow`.

Spawn shapes include point, line, rectangle, rectangle edge, disc, ring, and
cone. World-space particles detach from later emitter movement. Local-space
particles follow the emitter for their full life. `inheritVelocity` applies
only in world space.

Curves and gradients sample normalized age from zero to one. Numeric properties
accept a constant or a `{min, max}` range.

## Playback

`play` starts or resumes emission. `stop` resets the schedule while live
particles drain. `pause` holds the schedule and live field. `clear` kills the
field without changing emission. `restart` resets schedule and randomness.
`burst` queues a count for the next step.

`finished` derives its answer from the schedule and maximum lifetime.
`estimatedCount` predicts a count and may differ after overflow or a truncated
burst. Game code cannot inspect, move, kill, or count individual particles.

## Pool and snapshots

The plugin fixes world capacity and maximum emitters at installation. Each
emitter reserves its effect capacity. An emitter that cannot fit draws nothing
and logs the refusal.

Snapshots store effect name, seed, configuration, and playback state. They do
not store individual particles, so a restored emitter starts empty and refills.

Particles currently use the opaque lane. Color alpha does not blend. Use a size
curve that reaches zero for disappearance. Debris, rain, snow, confetti, and
hard-edged sparks fit this system; smoke, glow, fire, and soft dust do not.
]=]
-- Implementation details:
-- The pool sub-allocates one contiguous particle and renderer-instance range
-- per emitter. Three compute passes simulate, spawn, and write instances before
-- culling. No per-particle state crosses back to the CPU.
--
-- Particle bounds always select the deferred lane. The pool implements both
-- `InstanceProducer` and `Backend.ComputeStage`, so host instance uploads never
-- overwrite the ranges that compute owns.

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local sdl <const> = require("tecs.ffi.sdl3")
local loader <const> = require("tecs.ffi.loader")
local Buffer <const> = require("tecs.gpu.Buffer")
local ComputePass <const> = require("tecs.gpu.ComputePass")
local ComputePipeline <const> = require("tecs.gpu.ComputePipeline")
local components <const> = require("tecs.components")
local frametable <const> = require("tecs.gfx.frametable")
local layers <const> = require("tecs.gfx.layers")
local materials <const> = require("tecs.gpu.materials")
local sheet <const> = require("tecs.gfx.sheet")
local instancelayout <const> = require("tecs.gpu.instancelayout")
local log <const> = require("tecs.log")

local type World = types.World
local type Frame = require("tecs.gpu.Frame")
local type Renderer = require("tecs.Renderer")
local type Sheet = sheet.Sheet
local type Sprite = components.Sprite

local C <const> = sdl.C
local Transform <const> = ecs.Transform

local floor <const> = math.floor
local max <const> = math.max
local min <const> = math.min

local logger <const> = log.get("tecs.gfx")

-------------------------------------------------------------------------------
-- The record layouts, which the shaders state again
-------------------------------------------------------------------------------

--- Floats per effect record. `PARTICLE_EFFECT_FLOATS` in
--- `assets/shaders/include/particle.glsl` is the same number, as is every
--- offset below, and the pair only works while they agree.
local EFFECT_FLOATS <const> = 64

--- Bursts one effect's schedule holds.
local MAX_BURSTS <const> = 4

--- Where each field sits within one effect record. A table rather than a
--- constant apiece because the function that fills one touches nearly every
--- offset, and fifty upvalues in one closure is past what LuaJIT allows.
local EFFECT <const>: {string: integer} = {
    RATE = 0,
    DURATION = 1,
    LOOPING = 2,
    DELAY = 3,
    OVERFLOW = 4,
    BURST_COUNT = 5,
    SHAPE = 6,
    SHAPE_WIDTH = 7,
    SHAPE_HEIGHT = 8,
    SHAPE_ARC = 9,
    SHAPE_ROTATION = 10,
    DISTRIBUTION = 11,
    DIRECTION = 12,
    SPREAD = 13,
    SPACE = 14,
    INHERIT = 15,
    BURSTS = 16,
    LIFETIME_MIN = 24,
    LIFETIME_MAX = 25,
    SPEED_MIN = 26,
    SPEED_MAX = 27,
    SIZE_MIN = 28,
    SIZE_MAX = 29,
    ROTATION_MIN = 30,
    ROTATION_MAX = 31,
    ANGULAR_MIN = 32,
    ANGULAR_MAX = 33,
    ACCEL_X_MIN = 34,
    ACCEL_X_MAX = 35,
    ACCEL_Y_MIN = 36,
    ACCEL_Y_MAX = 37,
    DRAG = 38,
    RADIAL_MIN = 39,
    RADIAL_MAX = 40,
    TANGENTIAL_MIN = 41,
    TANGENTIAL_MAX = 42,
    SIZE_CURVE = 43,
    COLOR_GRADIENT = 44,
    COLOR_R = 45,
    COLOR_G = 46,
    COLOR_B = 47,
    COLOR_A = 48,
    U0 = 49,
    V0 = 50,
    U1 = 51,
    V1 = 52,
    SLOT = 53,
    MATERIAL = 54,
    DEPTH = 55,
    UNBOUNDED = 56,
    PLAYBACK = 57,
    PLAYBACK_TICKS = 58,
    PIVOT_X = 59,
    PIVOT_Y = 60,
    ALIGNMENT = 61,
    STRETCH = 62,
    OUTWARD = 63,
}

--- Floats per emitter record, and where each field sits.
local EMITTER_FLOATS <const> = 24

--- Where each field sits within one emitter record.
local EMITTER <const>: {string: integer} = {
    EFFECT = 0,
    SLOT_BASE = 1,
    SLOT_COUNT = 2,
    PLAYING = 3,
    SEED = 4,
    GENERATION = 5,
    START_STEP = 6,
    CLEAR_STEP = 7,
    PREV_X = 8,
    PREV_Y = 9,
    X = 10,
    Y = 11,
    ROTATION = 12,
    RATE_SCALE = 13,
    SIZE_SCALE = 14,
    TIME_SCALE = 15,
    TINT_R = 16,
    TINT_G = 17,
    TINT_B = 18,
    TINT_A = 19,
    BURST = 20,
    CLOCK = 21,
    STEPS = 22,
}

--- Floats of per-particle state, and uints of per-emitter runtime state.
local STATE_FLOATS <const> = 8
local RUNTIME_UINTS <const> = 8

--- Samples a compiled curve or gradient holds.
---
--- Thirty-two, which removes both the eight-key cap and the even spacing a CPU
--- particle system's ramps have, for the same trade the frame table already
--- made: the public surface stays a curve with keys wherever the author put
--- them, and the shader does one lookup rather than walking a graph per
--- particle per frame.
local CURVE_SAMPLES <const> = 32

--- Threads per workgroup, matching the local size the three shaders declare.
local GROUP <const> = 64

--- Fixed steps one frame is allowed to advance an emitter by.
---
--- A ceiling on the integration loop rather than a policy: a frame that fell
--- far behind catches a particle up by this much and no more, which bounds the
--- work rather than letting a stall compound into a longer one.
local MAX_STEPS <const> = 8

--- Floats the effect table is sized for.
---
--- A ceiling rather than a hint, for the reason the frame table's is one:
--- growing it would mean a second device buffer while a frame in flight is
--- still reading the first. A quarter of a megabyte holds several hundred
--- effects, since one costs sixty-four floats plus thirty-two per curve and a
--- hundred and twenty-eight per gradient.
local EFFECT_TABLE_FLOATS <const> = 65536

--- Emitters one pool holds, unless the plugin was told otherwise.
local DEFAULT_EMITTERS <const> = 256

--- Live particles one pool holds, unless the plugin was told otherwise.
local DEFAULT_CAPACITY <const> = 16384

-------------------------------------------------------------------------------
-- Authoring
-------------------------------------------------------------------------------

--- Defines a uniform distribution between two bounds.
local record Range
    --- Caller-writable. Sets the inclusive lower bound.
    min: number
    --- Caller-writable. Sets the inclusive upper bound.
    max: number
end

--- A property that takes either a constant or a range. `300` and
--- `{ min = 180, max = 420 }` are both accepted everywhere one of these is,
--- and cost the same: the shader draws between two bounds either way, and
--- equal bounds are a constant.
local type Value = number | Range

--- Stores a curve over normalized age as a compiled lookup table.
local record Curve
    --- Read-only. Provides evenly spaced samples over normalized age from zero
    --- to one.
    samples: {number}
end

--- Stores a color gradient over normalized age as a compiled lookup table.
---
--- The table retains alpha, but the opaque particle lane cannot use it yet.
local record Gradient
    --- Read-only. Provides evenly spaced RGBA samples over normalized age,
    --- with four floats per sample.
    samples: {number}
end

--- A color, as `#rrggbb`, `#rrggbbaa`, `0xrrggbbaa`, or four numbers in zero
--- to one.
local type Color = string | number | {number}

--- One key of a curve or a gradient. Heterogeneous by design: the first entry
--- is a normalized age and the second is whatever the table is of, so this is
--- one of the few places a list of `any` is the honest declaration rather than
--- a missing one.
local type CurveKey = {any}

--- Configures where particles spawn.
local record SpawnOptions
    --- Caller-writable. Selects `"point"`, `"line"`, `"rectangle"`,
    --- `"rectangleEdge"`, `"disc"`, `"ring"`, or
    --- "cone". Defaults to "point".
    shape: string
    --- Caller-writable. Sets width for a line or rectangle and radius for a
    --- disc, ring, or cone.
    width: number
    --- Caller-writable. Sets height for a rectangle. Every other shape ignores
    --- it.
    height: number
    --- Caller-writable. Sets the sampled sector of a disc, ring, or cone in
    --- radians. It defaults to a full
    --- turn.
    arc: number
    --- Caller-writable. Rotates the sampled area independently of launch
    --- direction.
    rotation: number
    --- Caller-writable. Selects `"uniform"` or `"normal"` sampling. A gaussian spread makes a column read as
    --- a column rather than as a slab. Defaults to "uniform".
    distribution: string
    --- Caller-writable. Sets the launch direction in radians and centers the
    --- full cone on it, so a
    --- particle leaves within plus or minus half of `spread`. Half-angle is the
    --- other plausible reading of `spread` and a mismatch is silent, so it is
    --- said here.
    direction: number
    --- Caller-writable. Sets the full cone width in radians.
    spread: number
    --- Caller-writable. Launches along the shape's outward normal rather than along `direction`.
    --- Meaningful for the shapes that have one: disc, ring, cone and a
    --- rectangle's edge.
    outward: boolean
    --- Caller-writable. Selects `"local"` or `"world"` space. Local particles follow the emitter's transform for
    --- their whole life; world particles read it once, at spawn, and then move
    --- independently. Neither is a good universal default, so it is explicit
    --- and defaults to "world".
    space: string
    --- Caller-writable. Sets how much emitter velocity a particle inherits in
    --- world space, from zero to one.
    inheritVelocity: number
end

--- Configures when particles emit.
local record ScheduleOptions
    --- Caller-writable. Sets the continuous emission rate in particles per
    --- second.
    rate: number
    --- Caller-writable. Sets the emission cycle duration in seconds. Zero
    --- means unbounded.
    duration: number
    --- Caller-writable. Controls whether the emission cycle repeats.
    looping: boolean
    --- Caller-writable. Sets the delay before emission starts in seconds.
    delay: number
    --- Caller-writable. Defines at most four timed burst counts measured from
    --- the start of the cycle. A muzzle flash is one burst at time zero.
    bursts: {ScheduleBurst}
end

--- Defines one scheduled burst.
local record ScheduleBurst
    --- Caller-writable. Sets the burst time in seconds from the cycle start.
    time: number
    --- Caller-writable. Sets how many particles the burst emits.
    count: number
end

--- Configures a particle's initial properties.
local record InitialOptions
    --- Caller-writable. Sets particle lifetime in seconds.
    lifetime: Value
    --- Caller-writable. Sets initial speed in world units per second.
    speed: Value
    --- Caller-writable. Sets initial size in world units.
    size: Value
    --- Caller-writable. Sets initial rotation in radians.
    rotation: Value
    --- Caller-writable. Sets initial angular velocity in radians per second.
    angularVelocity: Value
    --- Caller-writable. Sets constant horizontal acceleration. Independent axes
    --- make a plume drift apart instead of translating as a block.
    accelerationX: Value
    --- Caller-writable. Sets constant vertical acceleration.
    accelerationY: Value
    --- Caller-writable. Sets the color every particle starts with, multiplied by the gradient and by
    --- the emitter's tint.
    color: Color
end

--- Configures how a particle changes over its normalized lifetime.
local record UpdateOptions
    --- Caller-writable. Sets damping in units of one over seconds, applied as
    --- `velocity = velocity / (1 + drag * dt)`, so it composes with any step.
    drag: number
    --- Caller-writable. Sets acceleration away from the emitter.
    --- are the difference between a fountain and a vortex.
    radialAcceleration: Value
    --- Caller-writable. Sets acceleration at right angles to the emitter.
    tangentialAcceleration: Value
    --- Caller-writable. Multiplies each particle's size over its life.
    size: Curve
    --- Caller-writable. Multiplies each particle's color over its life. The
    --- opaque particle lane ignores alpha.
    color: Gradient
end

--- Configures how particles draw.
local record RenderOptions
    --- Caller-writable. Selects the material that shades the quad by name. An
    --- absent value samples the image array
    --- and covers the whole quad.
    material: string
    --- Caller-writable. Passes a value from zero to one to the material.
    materialParam: number
    --- Caller-writable. Selects a registered image from `Renderer:sprite`. An
    --- absent value draws a white quad.
    sprite: Sprite
    --- Caller-writable. Selects a sheet to animate instead of a still region.
    --- The cycle is
    --- played exactly once over each particle's own life and clamps at the
    --- end, so a randomized lifetime randomizes the playback speed.
    ---
    --- Uses the same frame table an animated entity does, so per-frame
    --- durations, reverse and pingpong all arrive already spent.
    sheet: Sheet
    --- Caller-writable. Selects the sheet tag to animate.
    tag: string
    --- Caller-writable. Selects the render layer from one to `layers.MAX`.
    layer: integer
    --- Caller-writable. Sets the horizontal pivot as a fraction of the
    --- frame from its top left. Defaults to the middle.
    pivotX: number
    --- Caller-writable. Sets the vertical pivot as a fraction of the frame
    --- from its top edge. It defaults to the middle.
    pivotY: number
    --- Caller-writable. Selects `"fixed"` or `"velocity"` alignment. Velocity
    --- alignment adds the path's angle to the particle's own rotation, so a
    --- spinning spark aligned to its path still spins.
    alignment: string
    --- Caller-writable. Multiplies the along-path axis when aligned to
    --- velocity.
    stretch: number
    --- Caller-writable. Selects a blend mode. Tecs currently accepts, logs
    --- once, and ignores it because no particle reaches the
    --- forward blended lane, so an effect authored with one today draws opaque
    --- and will draw as written once the simulate pass can pick that lane.
    blend: string
    --- Caller-writable. Selects the clip region that contains the fragments.
    --- Zero disables clipping.
    clip: integer
end

--- Defines a complete effect.
local record EffectOptions
    --- Caller-writable. Sets the required process-wide unique effect name.
    --- Snapshots use this name to identify the effect.
    name: string
    --- Caller-writable. Sets how many live particles one emitter can hold. A
    --- steady-state emitter needs at least `rate * maxLifetime`; otherwise Tecs
    --- drops emissions and logs a warning.
    capacity: integer
    --- Caller-writable. Selects `"drop"` or `"replace"` when an emission
    --- arrives with no
    --- free slot: give way, or take the oldest live particle's. Defaults to
    --- "replace".
    overflow: string
    --- Caller-writable. Configures when the effect emits particles.
    schedule: ScheduleOptions
    --- Caller-writable. Configures where the effect spawns particles.
    spawn: SpawnOptions
    --- Caller-writable. Configures each particle's initial properties.
    initial: InitialOptions
    --- Caller-writable. Configures how particles change over their lifetime.
    update: UpdateOptions
    --- Caller-writable. Configures how particles draw.
    render: RenderOptions
end

--- Represents an immutable registered effect shared by its emitters.
local record Effect
    --- Read-only. Reports the effect name and the only property that outlives the
    --- process. Everything a save, a tool or a person identifies an effect by
    --- is this.
    name: string
    --- Read-only. Reports where its record sits in the assembled effect table, counting from one.
    --- A position in registration order, so it means nothing outside the
    --- process that assigned it and nothing stores one.
    index: integer
    --- Read-only. Reports how many live particles one emitter can hold.
    capacity: integer
    --- Read-only. Reports the longest particle lifetime, which decides when an emitter
    --- that has stopped emitting has finished.
    maxLifetime: number
    --- Read-only. Reports seconds from `play` to the last emission, or -1 for an effect that
    --- never stops emitting.
    emitFor: number
    --- Read-only. Reports the continuous emission rate used by `finished` and
    --- `estimatedCount`.
    rate: number
    --- Read-only. Reports the emission delay in seconds.
    delay: number
    --- Read-only. Reports the emission duration in seconds.
    duration: number
    --- Read-only. Reports whether the emission cycle repeats.
    looping: boolean
    --- Read-only. Provides the compiled burst schedule.
    bursts: {number}
    --- Engine-owned. Stores the compiled effect record. Ordinary game code
    --- should ignore this field.
    _record: {number}
    --- Engine-owned. Stores curve and gradient samples. Ordinary game code
    --- should ignore this field.
    _extra: {number}
    --- Engine-owned. Stores the size-curve offset. Ordinary game code should
    --- ignore this field.
    _sizeCurveAt: integer
    --- Engine-owned. Stores the color-gradient offset. Ordinary game code
    --- should ignore this field.
    _colorGradientAt: integer
end

--- Registered effects by position, the same effects by name, and how many times
--- the registry has changed.
---
--- Two views of one set rather than two sets. The array is what `assemble` lays
--- out and what the shaders index; the map is how a name is resolved back, and
--- an effect is in both or in neither.
local registry: {Effect} = {}
local byName: {string: Effect} = {}
local revision = 0

--- Every registered effect's name, in registration order.
local function effectNames(): {string}
    local names <const>: {string} = {}
    for index = 1, #registry do
        names[index] = registry[index].name
    end
    return names
end

--- The effect registered under `name`, or nil when nothing has that name.
---
--- The non-raising lookup, for a caller with somewhere better to put the
--- refusal than an error raised from here. Restoring a `ParticleEmitter` is
--- that caller: the name it holds is a fact about a file rather than about the
--- call site, and the message it raises says so.
local function findEffect(name: string): Effect
    if name == nil then
        return nil
    end
    return byName[name]
end

--- Fails with a message naming the field, since a bad number in a table of
--- forty of them is otherwise reported against the whole call.
local function checkNumber(value: number, field: string, level: integer): number
    if value ~= value or value == math.huge or value == -math.huge then
        error(("tecs: %s must be a finite number"):format(field), level + 1)
    end
    return value
end

--- A constant or a range, as two bounds.
local function boundsOf(value: Value, lo: number, hi: number, field: string, level: integer): number, number
    if value == nil then
        return lo, hi
    end
    if value is number then
        checkNumber(value, field, level + 1)
        return value, value
    end
    local low = value.min
    local high = value.max
    if low == nil or high == nil then
        error(("tecs: %s is a number or { min = , max = }"):format(field), level + 1)
    end
    checkNumber(low, field .. ".min", level + 1)
    checkNumber(high, field .. ".max", level + 1)
    if high < low then
        low, high = high, low
    end
    return low, high
end

--- One hex pair of a color string, as a channel in zero to one.
local function channelAt(body: string, at: integer): number
    return (tonumber(body:sub(at, at + 1), 16) as number) / 255.0
end

--- A color as four channels in zero to one.
local function colorOf(value: Color, field: string, level: integer): number, number, number, number
    if value == nil then
        return 1.0, 1.0, 1.0, 1.0
    end
    if value is string then
        local body = value:match("^#?(%x+)$")
        if body == nil or (#body ~= 6 and #body ~= 8) then
            error(("tecs: %s is #rrggbb or #rrggbbaa, not '%s'"):format(field, value), level + 1)
        end
        return channelAt(body, 1), channelAt(body, 3), channelAt(body, 5), #body == 8 and channelAt(body, 7) or 1.0
    end
    if value is number then
        local packed = floor(value)
        return floor(packed / 0x1000000) % 256 / 255.0,
            floor(packed / 0x10000) % 256 / 255.0,
            floor(packed / 0x100) % 256 / 255.0,
            packed % 256 / 255.0
    end
    return value[1] or 1.0, value[2] or 1.0, value[3] or 1.0, value[4] or 1.0
end

--- Samples a list of keys onto an evenly spaced table.
---
--- Keys may sit anywhere in zero to one and need not be sorted; what comes out
--- is the piecewise-linear curve through them, sampled at a fixed resolution
--- the shader indexes without searching.
local function sampleKeys(
    keys: {CurveKey}, width: integer, read: function(key: CurveKey, into: {number}), level: integer
): {number}
    if keys == nil or #keys == 0 then
        error("tecs: a curve needs at least one key", level + 1)
    end

    local sorted: {CurveKey} = {}
    for index = 1, #keys do
        sorted[index] = keys[index]
    end
    table.sort(sorted, function(a: CurveKey, b: CurveKey): boolean return (a[1] as number) < (b[1] as number) end)

    local values: {number} = {}
    local scratch: {number} = {}
    local samples: {number} = {}
    for index = 1, #sorted do
        read(sorted[index], scratch)
        local base = (index - 1) * width
        for lane = 1, width do
            values[base + lane] = scratch[lane]
        end
    end

    local count <const> = #sorted
    for sample = 0, CURVE_SAMPLES - 1 do
        local t <const> = sample / (CURVE_SAMPLES - 1)
        local upper = count
        for index = 1, count do
            if (sorted[index][1] as number) >= t then
                upper = index
                break
            end
        end
        local lower = upper > 1 and upper - 1 or 1
        local t0 <const> = sorted[lower][1] as number
        local t1 <const> = sorted[upper][1] as number
        local mix = t1 > t0 and (t - t0) / (t1 - t0) or 0.0
        if mix < 0.0 then
            mix = 0.0
        elseif mix > 1.0 then
            mix = 1.0
        end
        for lane = 1, width do
            local a <const> = values[(lower - 1) * width + lane]
            local b <const> = values[(upper - 1) * width + lane]
            samples[sample * width + lane] = a + (b - a) * mix
        end
    end
    return samples
end

--- Compiles keyframes into a scalar curve.
---
--- Keys are `{ age, value }` with age in zero to one, placed wherever the
--- author wants them rather than spaced evenly.
local function newCurve(keys: {CurveKey}): Curve
    return {
        samples = sampleKeys(
            keys,
            1,
            function(key: CurveKey, into: {number}) into[1] = checkNumber(key[2] as number, "a curve value", 4) end,
            3
        ),
    }
end

--- Compiles keyframes into a color gradient.
---
--- Keys are `{ age, color }`. The alpha channel is carried and is inert until
--- a particle can be routed into the forward blended lane: today a fade to
--- transparent writes opaque, and the only fade that works is the size curve
--- going to zero.
local function newGradient(keys: {CurveKey}): Gradient
    return {
        samples = sampleKeys(
            keys,
            4,
            function(key: CurveKey, into: {number})
                into[1], into[2], into[3], into[4] = colorOf(key[2] as Color, "a gradient color", 4)
            end,
            3
        ),
    }
end

--- Spawn shapes, as the record holds them.
local SHAPES <const>: {string: number} = {
    point = 0.0,
    line = 1.0,
    rectangle = 2.0,
    rectangleEdge = 3.0,
    disc = 4.0,
    ring = 5.0,
    cone = 6.0,
}

--- Blend modes named so far, so the note about them being inert is logged once
--- per name rather than once per effect.
local blendNoted: {string: boolean} = {}

--- Registers an effect and answers the handle an emitter names it by.
local function newEffect(options: EffectOptions): Effect
    if options == nil then
        error("tecs: an effect needs options", 2)
    end

    -- Before any of the forty fields are worked out, so a nameless or a
    -- duplicated effect is refused where it was written rather than after the
    -- capacity warning has already been logged about it.
    local name <const> = options.name
    if name == nil or name == "" then
        error(
            "tecs: an effect needs a name; it is what a snapshot names it "
                .. "by, and there is nothing else about an effect that survives "
                .. "the process that registered it",
            2
        )
    end
    if byName[name] ~= nil then
        error(
            (
                "tecs: an effect named '%s' is already registered; two under "
                .. "one name cannot be told apart again by anything that saved "
                .. "either"
            ):format(name),
            2
        )
    end

    local schedule <const> = options.schedule or {}
    local spawn <const> = options.spawn or {}
    local initial <const> = options.initial or {}
    local update <const> = options.update or {}
    local render <const> = options.render or {}

    local fields: {number} = {}
    for index = 0, EFFECT_FLOATS - 1 do
        fields[index] = 0.0
    end

    -- Schedule.
    local rate <const> = schedule.rate or 0.0
    fields[EFFECT.RATE] = checkNumber(rate, "schedule.rate", 2)
    fields[EFFECT.DURATION] = schedule.duration or 0.0
    fields[EFFECT.LOOPING] = schedule.looping and 1.0 or 0.0
    fields[EFFECT.DELAY] = schedule.delay or 0.0

    local bursts <const>: {number} = {}
    local list <const> = schedule.bursts or {}
    if #list > MAX_BURSTS then
        error(("tecs: an effect schedules at most %d bursts, not %d"):format(MAX_BURSTS, #list), 2)
    end
    fields[EFFECT.BURST_COUNT] = #list
    for index = 1, #list do
        local burst <const> = list[index]
        local at <const> = EFFECT.BURSTS + (index - 1) * 2
        fields[at] = burst.time or 0.0
        fields[at + 1] = burst.count or 0.0
        bursts[#bursts + 1] = fields[at]
        bursts[#bursts + 1] = fields[at + 1]
    end

    -- Spawn.
    local shape <const> = spawn.shape or "point"
    if SHAPES[shape] == nil then
        error(("tecs: '%s' is not a spawn shape"):format(tostring(shape)), 2)
    end
    fields[EFFECT.SHAPE] = SHAPES[shape]
    fields[EFFECT.SHAPE_WIDTH] = spawn.width or 0.0
    fields[EFFECT.SHAPE_HEIGHT] = spawn.height or 0.0
    fields[EFFECT.SHAPE_ARC] = spawn.arc or math.pi * 2.0
    fields[EFFECT.SHAPE_ROTATION] = spawn.rotation or 0.0
    if spawn.distribution ~= nil and spawn.distribution ~= "uniform" and spawn.distribution ~= "normal" then
        error(("tecs: '%s' is not a distribution; use uniform or normal"):format(tostring(spawn.distribution)), 2)
    end
    fields[EFFECT.DISTRIBUTION] = spawn.distribution == "normal" and 1.0 or 0.0
    fields[EFFECT.DIRECTION] = spawn.direction or 0.0
    fields[EFFECT.SPREAD] = spawn.spread or 0.0
    fields[EFFECT.OUTWARD] = spawn.outward and 1.0 or 0.0
    if spawn.space ~= nil and spawn.space ~= "local" and spawn.space ~= "world" then
        error(("tecs: '%s' is not a simulation space; use local or world"):format(tostring(spawn.space)), 2)
    end
    fields[EFFECT.SPACE] = spawn.space == "local" and 0.0 or 1.0
    fields[EFFECT.INHERIT] = spawn.inheritVelocity or 0.0

    -- Initial state.
    fields[EFFECT.LIFETIME_MIN], fields[EFFECT.LIFETIME_MAX] = boundsOf(
        initial.lifetime, 1.0, 1.0, "initial.lifetime", 2
    )
    fields[EFFECT.SPEED_MIN], fields[EFFECT.SPEED_MAX] = boundsOf(initial.speed, 0.0, 0.0, "initial.speed", 2)
    fields[EFFECT.SIZE_MIN], fields[EFFECT.SIZE_MAX] = boundsOf(initial.size, 1.0, 1.0, "initial.size", 2)
    fields[EFFECT.ROTATION_MIN], fields[EFFECT.ROTATION_MAX] = boundsOf(
        initial.rotation, 0.0, 0.0, "initial.rotation", 2
    )
    fields[EFFECT.ANGULAR_MIN], fields[EFFECT.ANGULAR_MAX] = boundsOf(
        initial.angularVelocity, 0.0, 0.0, "initial.angularVelocity", 2
    )
    fields[EFFECT.ACCEL_X_MIN], fields[EFFECT.ACCEL_X_MAX] = boundsOf(
        initial.accelerationX, 0.0, 0.0, "initial.accelerationX", 2
    )
    fields[EFFECT.ACCEL_Y_MIN], fields[EFFECT.ACCEL_Y_MAX] = boundsOf(
        initial.accelerationY, 0.0, 0.0, "initial.accelerationY", 2
    )
    fields[EFFECT.COLOR_R], fields[EFFECT.COLOR_G], fields[EFFECT.COLOR_B], fields[EFFECT.COLOR_A] = colorOf(
        initial.color, "initial.color", 2
    )

    -- Evolution.
    fields[EFFECT.DRAG] = update.drag or 0.0
    fields[EFFECT.RADIAL_MIN], fields[EFFECT.RADIAL_MAX] = boundsOf(
        update.radialAcceleration, 0.0, 0.0, "update.radialAcceleration", 2
    )
    fields[EFFECT.TANGENTIAL_MIN], fields[EFFECT.TANGENTIAL_MAX] = boundsOf(
        update.tangentialAcceleration, 0.0, 0.0, "update.tangentialAcceleration", 2
    )

    -- A negative base is what the shader reads as "no table", answering one
    -- for a curve and white for a gradient, so the multiply is unconditional.
    local extra: {number} = {}
    local sizeCurveAt = -1
    local colorGradientAt = -1
    if update.size ~= nil then
        sizeCurveAt = #extra
        for index = 1, #update.size.samples do
            extra[#extra + 1] = update.size.samples[index]
        end
    end
    if update.color ~= nil then
        colorGradientAt = #extra
        for index = 1, #update.color.samples do
            extra[#extra + 1] = update.color.samples[index]
        end
    end

    -- Rendering.
    if render.material ~= nil then
        local param = render.materialParam or 0.0
        if param < 0.0 then
            param = 0.0
        elseif param > 0.999 then
            param = 0.999
        end
        fields[EFFECT.MATERIAL] = materials.id(render.material) + param
    end

    local layer <const> = render.layer or 1
    if layer < 1 or layer > layers.MAX then
        error(("tecs: render.layer is 1 to %d, not %d"):format(layers.MAX, layer), 2)
    end
    -- One depth for the effect rather than one per particle. An effect names
    -- one layer, so its band and sort mode are constant, and what a per
    -- particle depth would buy is sorting within the band, which is a
    -- separate feature and not implied by this one.
    fields[EFFECT.DEPTH] = layers.depthOf(layer, 0.0, 0.0, 0.0)
    fields[EFFECT.UNBOUNDED] = layers.viewCulled(layer) and 0.0 or 1.0

    -- An effect that names no image keeps the region it was zeroed with, which
    -- is a degenerate rect at the origin of array layer zero. That is where the
    -- backend puts its white pixel, and the sampler is nearest, so every corner
    -- of the quad reads that one texel and an untextured particle is white.
    -- The effect registry has no renderer to ask for the pixel's real extent,
    -- and does not need one: a rect with no width cannot reach past it.
    local arrayLayer = 0.0
    if render.sprite ~= nil then
        local sprite <const> = render.sprite
        fields[EFFECT.U0] = sprite.u0
        fields[EFFECT.V0] = sprite.v0
        fields[EFFECT.U1] = sprite.u1
        fields[EFFECT.V1] = sprite.v1
        arrayLayer = sprite.slot >= 0.0 and sprite.slot or 0.0
    end
    fields[EFFECT.SLOT] = instancelayout.packSlot(render.clip or 0, arrayLayer)

    if render.sheet ~= nil then
        local tag <const> = render.sheet:tagId(render.tag)
        local playback <const> = frametable.register(render.sheet, tag)
        fields[EFFECT.PLAYBACK] = playback
        fields[EFFECT.PLAYBACK_TICKS] = frametable.tickCount(playback)
    end

    fields[EFFECT.PIVOT_X] = render.pivotX or 0.5
    fields[EFFECT.PIVOT_Y] = render.pivotY or 0.5
    if render.alignment ~= nil and render.alignment ~= "fixed" and render.alignment ~= "velocity" then
        error(("tecs: '%s' is not an alignment; use fixed or velocity"):format(tostring(render.alignment)), 2)
    end
    fields[EFFECT.ALIGNMENT] = render.alignment == "velocity" and 1.0 or 0.0
    fields[EFFECT.STRETCH] = render.stretch or 1.0

    if render.blend ~= nil and not blendNoted[render.blend] then
        blendNoted[render.blend] = true
        logger:warn(
            "particle blend '%s' is accepted and ignored: nothing "
                .. "particle-shaped reaches the forward blended lane, so "
                .. "particles draw opaque and a color's alpha reaches the "
                .. "target unblended",
            render.blend
        )
    end

    if options.overflow ~= nil and options.overflow ~= "drop" and options.overflow ~= "replace" then
        error(("tecs: '%s' is not an overflow policy; use drop or replace"):format(tostring(options.overflow)), 2)
    end
    fields[EFFECT.OVERFLOW] = options.overflow == "drop" and 0.0 or 1.0

    local capacity <const> = options.capacity or 256
    if capacity < 1 then
        error("tecs: an effect's capacity is at least one particle", 2)
    end

    local maxLifetime <const> = fields[EFFECT.LIFETIME_MAX]
    -- Checked here, where every number is in hand, rather than left to be
    -- discovered as a spray that is thinner than it was authored to be. A CPU
    -- system drops the emission with no diagnostic and that is the single most
    -- common way one of them is quietly wrong.
    local needed <const> = rate * maxLifetime
    if capacity < needed then
        logger:warn(
            "a particle effect emitting %g a second for up to %g "
                .. "seconds needs %d slots at steady state and was given %d, so "
                .. "emissions are lost",
            rate,
            maxLifetime,
            math.ceil(needed),
            capacity
        )
    end

    local duration <const> = fields[EFFECT.DURATION]
    local emitFor = -1.0
    if not schedule.looping then
        emitFor = fields[EFFECT.DELAY] + (duration > 0.0 and duration or 0.0)
    end

    local effect <const>: Effect = {
        name = name,
        index = #registry + 1,
        capacity = capacity,
        maxLifetime = maxLifetime,
        emitFor = emitFor,
        rate = rate,
        delay = fields[EFFECT.DELAY],
        duration = duration,
        looping = schedule.looping == true,
        bursts = bursts,
        _record = fields,
        _extra = extra,
        _sizeCurveAt = sizeCurveAt,
        _colorGradientAt = colorGradientAt,
    }
    registry[effect.index] = effect
    byName[name] = effect
    revision = revision + 1
    return effect
end

--- Forgets every registered effect.
---
--- For a spec that needs to register a set again, which is the only way to put
--- a differently ordered registry in front of a snapshot from inside one
--- process. Every handle already handed out goes stale with it: the indices
--- start over, so an emitter still holding one reads another effect's record.
local function resetEffects()
    registry = {}
    byName = {}
    revision = revision + 1
end

--- The assembled effect buffer, and what it was assembled from.
local assembled: loader.CArray = nil
local assembledCapacity = 0
local assembledFloats = 0
local assembledAt = -1

--- Lays the records out, then the curves they name, and patches the bases.
---
--- One buffer rather than two, for the reason the frame table is one: a lookup
--- table belongs beside the record that names it, and a second buffer would be
--- a second binding in every pass that reads either.
local function assemble()
    local count <const> = #registry
    local total = count * EFFECT_FLOATS
    for index = 1, count do
        total = total + #registry[index]._extra
    end
    if total < 1 then
        total = 1
    end

    if total > assembledCapacity then
        assembledCapacity = total * 2
        assembled = loader.newArray("float[?]", assembledCapacity)
    end

    local at = count * EFFECT_FLOATS
    for index = 1, count do
        local effect <const> = registry[index]
        local base <const> = (index - 1) * EFFECT_FLOATS
        local record <const> = effect._record
        for lane = 0, EFFECT_FLOATS - 1 do
            assembled[base + lane] = record[lane]
        end
        assembled[base + EFFECT.SIZE_CURVE] = effect._sizeCurveAt >= 0 and at + effect._sizeCurveAt or -1.0
        assembled[base + EFFECT.COLOR_GRADIENT] = effect._colorGradientAt >= 0 and at + effect._colorGradientAt or -1.0

        local extra <const> = effect._extra
        for lane = 1, #extra do
            assembled[at + lane - 1] = extra[lane]
        end
        at = at + #extra
    end

    assembledFloats = total
end

-------------------------------------------------------------------------------
-- The emitter component
-------------------------------------------------------------------------------

--- Selects what an emitter does. Three states replace one boolean because a
--- game that cannot tell a paused emitter from a stopped one cannot resume the
--- right ones.
local enum EmitterState
    --- Read-only. Emits particles according to the effect schedule.
    "playing"
    --- Read-only. Holds the emitter clock and its live particles.
    "paused"
    --- Read-only. Stops emission and resets the cycle.
    "stopped"
end

--- Controls an effect's playback state and per-instance scales.
---
--- Deliberately small. If an instance could override every effect field then
--- effects would stop being reusable GPU data and every emitter would grow
--- to hold a copy. The effect owns capacity because it determines the pool
--- slot range when the emitter starts.
local record ParticleEmitter is ecs.Component
    --- Caller-writable. Selects the effect before spawning the emitter. It
    --- cannot change after spawn because the
    --- slot range is the effect's capacity, and changing it would mean
    --- reallocating. Despawn and spawn again, which is cheap.
    effect: Effect
    --- Caller-writable. Controls whether the emitter plays, pauses, or stops.
    state: EmitterState
    --- Caller-writable. Selects the random sequence. Two emitters with one seed
    --- produce one field.
    seed: number
    --- Caller-writable. Multiplies the effect's emission rate.
    rateScale: number
    --- Caller-writable. Multiplies every particle's size.
    sizeScale: number
    --- Caller-writable. Multiplies the speed of the effect clock.
    timeScale: number
    --- Caller-writable. Multiplies every particle's color. The opaque particle
    --- lane ignores alpha.
    tint: Color

    --- Engine-owned. Stores the emitter's pool index. Ordinary game code
    --- should ignore this field.
    _index: integer
    --- Engine-owned. Stores the emitter's first particle slot. Ordinary game
    --- code should ignore this field.
    _slotBase: integer
    --- Engine-owned. Stores how many particle slots the emitter owns. Ordinary
    --- game code should ignore this field.
    _slotCount: integer
    --- Engine-owned. Tracks fixed steps this emitter has run. Ordinary game
    --- code should ignore this field. The clock stands still while paused,
    --- held, or stopped. The simulation measures every age from it.
    _clock: number
    --- Engine-owned. Stores the step at which the current cycle began.
    --- Ordinary game code should ignore this field.
    _startStep: number
    --- Engine-owned. Stores the step that requested a clear. Ordinary game code
    --- should ignore this field.
    _clearStep: number
    --- Engine-owned. Selects the current random sequence generation. Ordinary
    --- game code should ignore this field.
    _generation: number
    --- Engine-owned. Stores particles requested outside the schedule. Ordinary
    --- game code should use `burst`. Tecs consumes the count at the
    --- next step boundary that passes.
    _burst: number
    --- Engine-owned. Stores the world step when the pool last saw this emitter.
    --- Ordinary game code should ignore this field.
    --- question asked between frames answers against the frame it saw, and the
    --- fixed step in seconds as it stood then, so `finished` can convert its
    --- own clock without holding a world.
    _worldStep: number
    --- Engine-owned. Stores the fixed-step duration last seen by the emitter.
    --- Ordinary game code should ignore this field.
    _stepSeconds: number
end

--- Starts or resumes emission.
---
--- From stopped this begins the cycle again; from paused it carries on from
--- where it was, with the steps spent paused not counted against the schedule.
function ParticleEmitter:play()
    if self.state == "playing" then
        return
    end
    if self.state == "stopped" then
        self._startStep = self._clock
        self._generation = self._generation + 1
    end
    self.state = "playing"
end

--- Stops emission and resets the schedule. Live particles drain.
---
--- The next `play` starts the cycle from its beginning with a fresh random
--- sequence, which is what makes it reproducible. Killing the field instead is
--- `clear`, and the two are deliberately separate.
function ParticleEmitter:stop()
    if self.state == "stopped" then
        return
    end
    self.state = "stopped"
    self._startStep = self._clock
    self._generation = self._generation + 1
end

--- Stops emission and holds. The schedule and the particles both keep their
--- state, and neither ages while this is on.
function ParticleEmitter:pause()
    if self.state == "stopped" then
        return
    end
    self.state = "paused"
end

--- Kills every live particle immediately.
---
--- Use this for teardown and state transitions. It leaves emission unchanged,
--- so a playing emitter starts filling again on the next step.
function ParticleEmitter:clear()
    self._clearStep = self._clock + 1
end

--- Resets the schedule and the random sequence, and starts playing.
---
--- Reproducible: a restart of an emitter with the same seed produces the same
--- field, because every particle's draws are a pure function of the seed, the
--- generation, the serial and the property, and all four start over.
function ParticleEmitter:restart()
    self._startStep = self._clock
    self._generation = self._generation + 1
    self.state = "playing"
end

--- Emits `count` particles at the next step boundary.
---
--- A stopped emitter ignores the call. The emitter truncates a count beyond
--- its free capacity to the number that fits.
function ParticleEmitter:burst(count: number)
    if self.state ~= "playing" then
        return
    end
    self._burst = (self._burst or 0.0) + (count or 0.0)
end

--- Returns whether this emitter has stopped emitting and its last particle has
--- died.
---
--- Exact, and it costs nothing: it is the schedule plus the longest lifetime
--- against the emitter's own clock, all of which the host holds. This is what
--- almost every "has the explosion finished" question is actually asking, and
--- unlike a count it needs nothing read back from the GPU.
function ParticleEmitter:finished(): boolean
    local effect <const> = self.effect
    if effect == nil then
        return true
    end
    if self.state == "playing" and effect.emitFor < 0.0 then
        return false
    end
    if self.state == "paused" then
        return false
    end
    local seconds <const> = (self._clock - self._startStep) * self._stepSeconds * self.timeScale
    local last <const> = (self.state == "playing" and effect.emitFor or 0.0) + effect.maxLifetime
    return seconds >= last
end

--- How many particles the schedule says had been emitted by a time.
---
--- The integral of the emission rate plus every burst whose time has passed,
--- counted once per cycle a loop has been through.
local function emittedBy(item: ParticleEmitter, effect: Effect, at: number): number
    if at <= effect.delay then
        return 0.0
    end
    local into = at - effect.delay
    if effect.duration > 0.0 and not effect.looping and into > effect.duration then
        into = effect.duration
    end

    local total = effect.rate * item.rateScale * into
    local bursts <const> = effect.bursts
    for index = 1, #bursts, 2 do
        local cycles = 1.0
        if effect.looping and effect.duration > 0.0 then
            cycles = floor((into - bursts[index]) / effect.duration) + 1.0
            if cycles < 0.0 then
                cycles = 0.0
            end
        elseif into < bursts[index] then
            cycles = 0.0
        end
        total = total + bursts[index + 1] * cycles
    end
    return total
end

--- Returns an estimate of how many particles remain alive.
---
--- Integrates the schedule over the latest lifetime and subtracts expired
--- emissions. The result is exact when no burst truncates and no overflow
--- occurs. Reading the exact GPU count would stall the pipeline.
function ParticleEmitter:estimatedCount(): integer
    local effect <const> = self.effect
    if effect == nil then
        return 0
    end
    local now <const> = (self._clock - self._startStep) * self._stepSeconds * self.timeScale
    -- Averaged rather than the longest, since half the particles emitted a
    -- lifetime ago are gone and half are not.
    local mean <const> = effect.maxLifetime * 0.5
    local alive <const> = emittedBy(self, effect, now) - emittedBy(self, effect, now - mean)

    if alive <= 0.0 then
        return 0
    end
    return floor(min(alive, effect.capacity) + 0.5)
end

-------------------------------------------------------------------------------
-- The pool
-------------------------------------------------------------------------------

--- One emitter's place in the pool, as the pool remembers it.
local record Holding
    item: ParticleEmitter
    index: integer
    base: integer
    count: integer
    --- The tint as it was last read, and what it parsed to. Parsing a color
    --- string per emitter per frame would be the one allocation in a loop that
    --- otherwise has none, and a tint changes rarely.
    tint: Color
    tintR: number
    tintG: number
    tintB: number
    tintA: number
end

--- A slot range whose emitter is gone, held until its last particle can no
--- longer be alive.
local record Draining
    base: integer
    count: integer
    releaseAt: number
end

--- Configures a
--- [`ParticleEmitter`](tealdoc:tecs.gfx.particles.ParticleEmitter). Requires
--- only `effect`.
local record EmitterOptions
    --- Caller-writable. Selects the required effect.
    effect: Effect
    --- Caller-writable. Sets the initial playback state.
    state: EmitterState
    --- Caller-writable. Sets the random seed.
    seed: number
    --- Caller-writable. Multiplies the effect's emission rate.
    rateScale: number
    --- Caller-writable. Multiplies every particle's size.
    sizeScale: number
    --- Caller-writable. Multiplies the speed of the effect clock.
    timeScale: number
    --- Caller-writable. Multiplies every particle's color.
    tint: Color
end

--- Fills a fresh emitter in, and refuses one that names no effect.
local function initEmitter(item: ParticleEmitter, options: EmitterOptions)
    if options == nil or options.effect == nil then
        error("tecs: a ParticleEmitter needs an effect", 3)
    end
    local state <const> = options.state or "playing"
    if state ~= "playing" and state ~= "paused" and state ~= "stopped" then
        error(("tecs: '%s' is not an emitter state; use playing, paused or " .. "stopped"):format(tostring(state)), 3)
    end

    item.effect = options.effect
    item.state = state
    item.seed = options.seed or 1
    item.rateScale = options.rateScale or 1.0
    item.sizeScale = options.sizeScale or 1.0
    item.timeScale = options.timeScale or 1.0
    item.tint = options.tint
    item._index = -1
    item._slotBase = -1
    item._slotCount = 0
    item._clock = 0.0
    item._startStep = 0.0
    item._clearStep = 0.0
    item._generation = 0.0
    item._burst = 0.0
    item._worldStep = 0.0
    item._stepSeconds = 0.0
end

--- Manages every emitter's particles in one world as one renderer run and
--- instance buffer plus the three compute passes that fill it.
local record Pool
    --- Read-only. Reports how many live particles the pool can hold.
    capacity: integer
    --- Engine-owned. Stores the renderer used by the pool. Ordinary game code
    --- should ignore this field.
    _renderer: Renderer
    --- Engine-owned. Stores the graphics device. Ordinary game code should
    --- ignore this field.
    _device: loader.CPtr
    --- Engine-owned. Stores the emitter limit. Ordinary game code should
    --- ignore this field.
    _maxEmitters: integer

    --- Engine-owned. Stores the first instance index used by the pool.
    --- Ordinary game code should ignore this field. The extractor updates it
    --- when layout changes. It remains negative until the first update.
    _base: integer

    --- Engine-owned. Stores the highest particle slot handed out. Ordinary game
    --- code should ignore this field.
    _high: integer
    --- Engine-owned. Stores free particle ranges. Ordinary game code should
    --- ignore this field.
    _free: {integer: {integer}}
    --- Engine-owned. Stores particle ranges waiting for release. Ordinary game
    --- code should ignore this field.
    _draining: {Draining}
    --- Engine-owned. Stores live emitter allocations. Ordinary game code
    --- should ignore this field.
    _holdings: {ParticleEmitter: Holding}
    --- Emitters this frame's walk reached, reused across frames so the walk
    --- allocates nothing.
    _seen: {ParticleEmitter: boolean}
    --- Engine-owned. Stores reusable emitter indices. Ordinary game code
    --- should ignore this field.
    _indexFree: {integer}
    --- Engine-owned. Stores the highest emitter index handed out. Ordinary game
    --- code should ignore this field.
    _indexHigh: integer
    --- Engine-owned. Stores the number of live emitters. Ordinary game code
    --- should ignore this field.
    _live: integer

    --- Engine-owned. Tracks frames that still require a dispatch. Ordinary
    --- game code should ignore this field. It remains positive while an emitter is
    --- running, and held one frame past the last of them so the pass that
    --- hides their slots actually runs.
    _settle: integer

    --- Engine-owned. Stores the current world step. Ordinary game code should
    --- ignore this field.
    _step: number
    --- Engine-owned. Stores the current fixed-step duration. Ordinary game
    --- code should ignore this field.
    _timestep: number
    --- Engine-owned. Stores frame interpolation alpha. Ordinary game code
    --- should ignore this field.
    _alpha: number

    --- Engine-owned. Stores compiled effect data. Ordinary game code should
    --- ignore this field.
    _effects: Buffer
    --- Engine-owned. Stores emitter data. Ordinary game code should ignore
    --- this field.
    _emitters: Buffer
    --- Engine-owned. Stores emitter runtime data. Ordinary game code should
    --- ignore this field.
    _runtime: Buffer
    --- Engine-owned. Stores particle owners. Ordinary game code should ignore
    --- this field.
    _owners: Buffer
    --- Engine-owned. Stores particle state. Ordinary game code should ignore
    --- this field.
    _states: Buffer
    --- Engine-owned. Stores the emission pipeline. Ordinary game code should
    --- ignore this field.
    _emit: ComputePipeline
    --- Engine-owned. Stores the spawn pipeline. Ordinary game code should
    --- ignore this field.
    _spawn: ComputePipeline
    --- Engine-owned. Stores the simulation pipeline. Ordinary game code should
    --- ignore this field.
    _simulate: ComputePipeline
    --- Engine-owned. Stores emitter staging data. Ordinary game code should
    --- ignore this field.
    _emitterData: loader.CArray
    --- Staging slot the next frame's emitter records go into, rotated after
    --- each flush so a write never lands in memory a frame is still copying.
    _emitterSlot: integer
    --- Engine-owned. Stores particle-owner staging data. Ordinary game code
    --- should ignore this field.
    _ownerData: loader.CArray
    --- Engine-owned. Tracks whether particle owners need uploading. Ordinary
    --- game code should ignore this field.
    _ownersDirty: boolean
    --- Engine-owned. Stores pass uniforms. Ordinary game code should ignore
    --- this field.
    _uniform: loader.CArray
    --- Engine-owned. Stores the installed effect revision. Ordinary game code
    --- should ignore this field.
    _effectsAt: integer
    --- Engine-owned. Records whether `destroy` has released the pool. Ordinary
    --- game code should ignore this field.
    _destroyed: boolean
end

local PoolMT <const>: metatable<Pool> = {__index = Pool}

--- Nothing changed, ever. The instance region is written by compute rather
--- than through staging, so the run this producer holds is one the host flush
--- never covers. Returning an empty list every time is what arranges that.
local NOTHING <const>: {integer} = {}

local function newPool(renderer: Renderer, capacity: integer, maxEmitters: integer): Pool
    local self = setmetatable({} as Pool, PoolMT)
    local device <const> = renderer:device()
    self.capacity = capacity
    self._renderer = renderer
    self._device = device
    self._maxEmitters = maxEmitters
    self._base = -1
    self._high = 0
    self._free = {}
    self._draining = {}
    self._holdings = {}
    self._seen = {}
    self._indexFree = {}
    self._indexHigh = 0
    self._live = 0
    self._settle = 0
    self._step = 0.0
    self._timestep = 0.0
    self._alpha = 0.0
    self._effectsAt = -1
    self._ownersDirty = true
    self._destroyed = false

    self._effects = Buffer.create(
        device,
        {
            usage = {"computeRead"},
            size = EFFECT_TABLE_FLOATS * 4,
            name = "tecs.particle.effects",
        }
    )
    self._emitters = Buffer.create(
        device,
        {
            usage = {"computeRead"},
            size = maxEmitters * EMITTER_FLOATS * 4,
            name = "tecs.particle.emitters",
        }
    )
    self._runtime = Buffer.create(
        device,
        {
            usage = {"computeRead", "computeWrite"},
            size = maxEmitters * RUNTIME_UINTS * 4,
            name = "tecs.particle.runtime",
        }
    )
    self._owners = Buffer.create(
        device,
        {
            usage = {"computeRead"},
            size = capacity * 4,
            name = "tecs.particle.owners",
        }
    )
    self._states = Buffer.create(
        device,
        {
            usage = {"computeRead", "computeWrite"},
            size = capacity * STATE_FLOATS * 4,
            name = "tecs.particle.states",
        }
    )

    self._emitterSlot = 0
    self._emitterData = loader.newArray("float[?]", maxEmitters * EMITTER_FLOATS)
    self._ownerData = loader.newArray("uint32_t[?]", capacity)
    self._uniform = loader.newArray("float[8]")

    -- A device buffer's contents are undefined until something writes them, so
    -- the two the shaders read before they write are zeroed once here. Without
    -- it the first frame reads whatever the driver left and draws a field
    -- nothing emitted.
    local zeros <const> = loader.newArray("uint32_t[?]", max(capacity * STATE_FLOATS, maxEmitters * RUNTIME_UINTS))
    for index = 0, capacity * STATE_FLOATS - 1 do
        zeros[index] = 0
    end
    self._states:upload(zeros, capacity * STATE_FLOATS * 4)
    self._runtime:upload(zeros, maxEmitters * RUNTIME_UINTS * 4)
    for index = 0, capacity - 1 do
        self._ownerData[index] = 0
    end

    self._emit = ComputePipeline.load(device, "particle.emit.comp", {})
    self._spawn = ComputePipeline.load(device, "particle.spawn.comp", {})
    self._simulate = ComputePipeline.load(device, "particle.simulate.comp", {})
    return self
end

--- Takes a contiguous range of `count` slots, or -1 when the pool is full.
---
--- Exact sizes only. A range is the effect's capacity and an effect is named by
--- however many emitters name it, so the sizes that come back are the sizes
--- that go out again, and a free list keyed by size finds one in a lookup
--- rather than a walk.
local function allocate(self: Pool, count: integer): integer
    local free <const> = self._free[count]
    if free ~= nil and #free > 0 then
        local base <const> = free[#free]
        free[#free] = nil
        return base
    end
    if self._high + count > self.capacity then
        return -1
    end
    local base <const> = self._high
    self._high = base + count
    return base
end

--- Hands a range back.
local function release(self: Pool, base: integer, count: integer)
    local free = self._free[count]
    if free == nil then
        free = {}
        self._free[count] = free
    end
    free[#free + 1] = base
end

--- Points every slot of a range at an emitter, or at nobody.
local function own(self: Pool, base: integer, count: integer, owner: integer)
    local data <const> = self._ownerData
    for slot = base, base + count - 1 do
        data[slot] = owner
    end
    self._ownersDirty = true
end

--- Gives an emitter a place in the pool, or leaves it without one.
local function admit(self: Pool, item: ParticleEmitter): Holding
    local effect <const> = item.effect
    if effect == nil then
        return nil
    end

    local base <const> = allocate(self, effect.capacity)
    if base < 0 then
        logger:warn(
            "a particle pool of %d slots has no room for an effect " .. "needing %d; the emitter draws nothing",
            self.capacity,
            effect.capacity
        )
        return nil
    end

    local index: integer
    local reused <const> = self._indexFree[#self._indexFree]
    if reused ~= nil then
        self._indexFree[#self._indexFree] = nil
        index = reused
    else
        if self._indexHigh >= self._maxEmitters then
            release(self, base, effect.capacity)
            logger:warn(
                "a particle pool holds %d emitters and a %dth was " .. "spawned; it draws nothing",
                self._maxEmitters,
                self._maxEmitters + 1
            )
            return nil
        end
        index = self._indexHigh
        self._indexHigh = index + 1
    end

    own(self, base, effect.capacity, index + 1)

    item._index = index
    item._slotBase = base
    item._slotCount = effect.capacity
    -- Anchored on the step it arrives at, so an emitter spawned into a world
    -- that has been running for an hour does not read that hour as a backlog
    -- and discharge it on its first frame.
    item._worldStep = self._step
    item._startStep = item._clock
    -- Whatever the last tenant of these slots left behind was born before now,
    -- so one comparison in the simulate pass throws all of it away and nothing
    -- has to walk the range to zero it.
    item._clearStep = item._clock
    item._generation = item._generation + 1

    local r, g, b, a = colorOf(item.tint, "tint", 2)
    local holding <const>: Holding = {
        item = item,
        index = index,
        base = base,
        count = effect.capacity,
        tint = item.tint,
        tintR = r,
        tintG = g,
        tintB = b,
        tintA = a,
    }
    self._holdings[item] = holding
    self._live = self._live + 1
    return holding
end

--- Gives up an emitter's place, holding its slots until they must be empty.
---
--- The range is not reusable the moment the emitter goes: its particles are
--- still alive and still being drawn, which is what "despawning stops emission
--- and lets the field drain" means. What decides when is the effect's own
--- longest lifetime, which is the same number `finished` answers from.
local function retire(self: Pool, holding: Holding, step: number)
    local item <const> = holding.item
    self._holdings[item] = nil
    self._live = self._live - 1
    self._indexFree[#self._indexFree + 1] = holding.index

    local effect <const> = item.effect
    local seconds <const> = effect ~= nil and effect.maxLifetime or 0.0
    local steps <const> = self._timestep > 0.0 and math.ceil(seconds / self._timestep) or 0.0
    self._draining[#self._draining + 1] = {
        base = holding.base,
        count = holding.count,
        releaseAt = step + steps + 1,
    }
    -- Unowned from now, so the simulate pass hides the slots as their
    -- particles expire and stops touching them once they all have.
    own(self, holding.base, holding.count, 0)

    -- And the record itself put beyond use. The buffer is uploaded up to the
    -- high-water mark rather than to the live count, so a freed index whose
    -- record still said it was playing would go on advancing a schedule and
    -- reserving slots nobody would ever fill.
    local data <const> = self._emitterData
    local base <const> = holding.index * EMITTER_FLOATS
    data[base + EMITTER.SLOT_COUNT] = 0.0
    data[base + EMITTER.PLAYING] = 0.0
end

--- Frees the ranges whose particles can no longer be alive.
local function drain(self: Pool, step: number)
    local held <const> = self._draining
    local kept = 0
    for index = 1, #held do
        local entry <const> = held[index]
        if step >= entry.releaseAt then
            release(self, entry.base, entry.count)
        else
            kept = kept + 1
            held[kept] = entry
        end
    end
    for index = #held, kept + 1, -1 do
        held[index] = nil
    end
end

--- Writes one emitter's record into the staging the record pass uploads.
local function writeEmitter(
    self: Pool,
    holding: Holding,
    x: number,
    y: number,
    previousX: number,
    previousY: number,
    rotation: number,
    steps: number
)
    local item <const> = holding.item
    local data <const> = self._emitterData
    local base <const> = holding.index * EMITTER_FLOATS

    data[base + EMITTER.EFFECT] = item.effect.index - 1
    data[base + EMITTER.SLOT_BASE] = holding.base
    data[base + EMITTER.SLOT_COUNT] = holding.count
    data[base + EMITTER.PLAYING] = item.state == "playing" and 1.0 or 0.0
    data[base + EMITTER.SEED] = item.seed
    data[base + EMITTER.GENERATION] = item._generation
    data[base + EMITTER.START_STEP] = item._startStep
    data[base + EMITTER.CLEAR_STEP] = item._clearStep
    data[base + EMITTER.PREV_X] = previousX
    data[base + EMITTER.PREV_Y] = previousY
    data[base + EMITTER.X] = x
    data[base + EMITTER.Y] = y
    data[base + EMITTER.ROTATION] = rotation
    data[base + EMITTER.RATE_SCALE] = item.rateScale
    data[base + EMITTER.SIZE_SCALE] = item.sizeScale
    data[base + EMITTER.TIME_SCALE] = item.timeScale
    if holding.tint ~= item.tint then
        holding.tint = item.tint
        holding.tintR, holding.tintG, holding.tintB, holding.tintA = colorOf(item.tint, "tint", 2)
    end
    data[base + EMITTER.TINT_R] = holding.tintR
    data[base + EMITTER.TINT_G] = holding.tintG
    data[base + EMITTER.TINT_B] = holding.tintB
    data[base + EMITTER.TINT_A] = holding.tintA
    data[base + EMITTER.BURST] = item._burst
    data[base + EMITTER.CLOCK] = item._clock
    data[base + EMITTER.STEPS] = steps
end

-------------------------------------------------------------------------------
-- The producer and the stage
-------------------------------------------------------------------------------

function Pool:count(): integer
    return self.capacity
end

function Pool:takeDirty(): {integer}
    return NOTHING
end

--- Hides the run and remembers where it landed.
---
--- Only ever called on a frame the layout moved, since nothing else is ever
--- dirty. What it writes is the hidden slot every reserved run writes, and the
--- simulate pass overwrites the live ones later on the same frame: the flush is
--- recorded before the dispatch, so a relayout cannot lose a particle.
function Pool:write(floats: loader.CArray, bounds: loader.CArray, base: integer, first: integer, last: integer)
    self._base = base
    local instanceFloats <const> = instancelayout.FLOATS
    local boundFloats <const> = instancelayout.BOUND_FLOATS
    for slot = base + first - 1, base + last - 1 do
        local at <const> = slot * instanceFloats
        for lane = 0, instanceFloats - 1 do
            floats[at + lane] = 0.0
        end
        floats[at + 3] = instancelayout.HIDDEN_DEPTH
        local bound <const> = slot * boundFloats
        bounds[bound] = instancelayout.HIDDEN
        bounds[bound + 1] = instancelayout.HIDDEN
        bounds[bound + 2] = 0.0
        bounds[bound + 3] = 0.0
    end
end

--- Whether there is anything to dispatch over.
---
--- Published rather than derived, and this is the hazard the design named: an
--- emitter dirties nothing, ever, while its whole field moves every frame.
--- There is no archetype bit to read and no component write to observe, so a
--- gate written as "nothing is dirty" would conclude wrongly every frame an
--- emitter was running. The pool counts its own live emitters instead, and
--- holds the gate open one frame past the last of them so the pass that hides
--- their slots is the one that actually runs.
function Pool:active(): boolean
    return self._base >= 0 and self._settle > 0
end

function Pool:record(frame: Frame, instances: Buffer, bounds: Buffer)
    local commandBuffer <const> = frame.commandBuffer

    -- Content rather than per-frame data, so it moves when an effect is
    -- registered and not when one is read.
    local current <const> = revision
    if current ~= self._effectsAt then
        self._effectsAt = current
        if current ~= assembledAt then
            assembledAt = current
            assemble()
        end
        local bytes <const> = assembledFloats * 4
        if bytes > self._effects.size then
            error(
                ("tecs: the particle effect table needs %d bytes and the " .. "buffer holds %d"):format(
                    bytes, self._effects.size
                ),
                2
            )
        end
        self._effects:write(0, assembled as loader.CValue, bytes)
        self._effects:flush(commandBuffer)
    end

    if self._ownersDirty then
        self._ownersDirty = false
        self._owners:write(0, self._ownerData as loader.CValue, self.capacity * 4)
        self._owners:flush(commandBuffer)
    end

    -- Rotated rather than cycled. The emitter records are rewritten every
    -- frame, and cycling a slot asks the driver for a fresh allocation each
    -- time, which the driver has to reclaim while the previous frame is still
    -- copying out of it. Writing a slot the GPU is not reading gives the same
    -- guarantee and allocates nothing, which is what the instance staging
    -- already does for the same reason.
    local slot <const> = self._emitterSlot
    self._emitterSlot = (slot + 1) % Buffer.slotCount
    local bytes <const> = self._indexHigh * EMITTER_FLOATS * 4
    if bytes > 0 then
        local target <const> = self._emitters:mapSlot(slot, false)
        loader.copyTo(target, self._emitterData as loader.CValue, bytes)
        self._emitters:markSlotDirty(slot, 0, bytes)
        self._emitters:flushSlot(slot, commandBuffer)
    end

    local uniform <const> = self._uniform
    uniform[0] = self._step
    uniform[1] = MAX_STEPS
    uniform[2] = self._timestep
    uniform[3] = self._alpha
    uniform[4] = self._base
    uniform[5] = self.capacity
    uniform[6] = self._indexHigh
    uniform[7] = 0.0

    local slots <const> = math.ceil(self.capacity / GROUP)

    -- Three passes rather than two. The schedule is per emitter and the work
    -- it decides on is per particle, so a burst of four thousand is four
    -- thousand threads here instead of one thread going round four thousand
    -- times. Each pass reads what the one before it wrote, and SDL orders them
    -- because each declares what it writes.
    local emitters <const> = math.ceil(self._indexHigh / GROUP)
    if emitters > 0 then
        local emit <const> = ComputePass.begin(commandBuffer, {self._runtime.handle})
        emit:bindPipeline(self._emit.handle)
        emit:bindStorageBuffers(0, {self._effects.handle, self._emitters.handle})
        C.SDL_PushGPUComputeUniformData(commandBuffer, 0, uniform, 32)
        emit:dispatch(emitters)
        emit:finish()
    end

    local spawn <const> = ComputePass.begin(commandBuffer, {self._states.handle})
    spawn:bindPipeline(self._spawn.handle)
    spawn:bindStorageBuffers(
        0, {self._effects.handle, self._emitters.handle, self._owners.handle, self._runtime.handle}
    )
    C.SDL_PushGPUComputeUniformData(commandBuffer, 0, uniform, 32)
    spawn:dispatch(slots)
    spawn:finish()

    local simulate <const> = ComputePass.begin(commandBuffer, {self._states.handle, instances.handle, bounds.handle})
    simulate:bindPipeline(self._simulate.handle)
    simulate:bindStorageBuffers(0, {self._effects.handle, self._emitters.handle, self._owners.handle})
    C.SDL_PushGPUComputeUniformData(commandBuffer, 0, uniform, 32)
    simulate:dispatch(slots)
    simulate:finish()
end

--- Releases everything the pool owns. Safe to call more than once.
function Pool:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    self._effects:destroy()
    self._emitters:destroy()
    self._runtime:destroy()
    self._owners:destroy()
    self._states:destroy()
    self._emit:destroy()
    self._spawn:destroy()
    self._simulate:destroy()
end

-------------------------------------------------------------------------------
-- The plugin
-------------------------------------------------------------------------------

--- Configures the particle pool installed by `plugin`.
local record PoolOptions
    --- Caller-writable. Selects the renderer whose instance buffer the pool
    --- uses and whose
    --- device its buffers and pipelines are built on.
    renderer: Renderer
    --- Caller-writable. Sets how many live particles the pool holds across the
    --- world. The value remains fixed
    --- at install: changing it would move the run, and moving the run lays out
    --- the whole scene again.
    capacity: integer
    --- Caller-writable. Sets how many emitters the pool holds at once.
    maxEmitters: integer
end

--- Pools installed per world, so a second install is a no-op and a debugger
--- has somewhere to ask.
local pools: {World: Pool} = setmetatable({}, {__mode = "k"} as metatable<{World: Pool}>)

--- Walks the emitters, keeps the pool's bookkeeping in step, and writes their
--- records.
---
--- A full walk every frame rather than a dirty gate, and deliberately: an
--- emitter's fields are read by the GPU every frame whatever the world thinks
--- changed, its transform moves without touching the component, and its
--- schedule advances without anything writing anything. Emitters are counted
--- in tens, so the walk is cheaper than any arrangement that tried to avoid it
--- would be to get right.
local function walkEmitters(self: Pool, query: types.Query, advancing: boolean): integer
    local seen <const> = self._seen
    local step <const> = self._step
    local timestep <const> = self._timestep
    local live = 0

    for archetype, length in query:iter() do
        local column = archetype:get(ParticleEmitter)
        local transforms = archetype:get(Transform)
        -- Absent on an emitter nothing interpolates, which is one test for
        -- the whole archetype rather than anything per row.
        local previous = archetype:get(components.PreviousTransform)
        for row = 1, length do
            local item = column[row]
            seen[item] = true
            local holding = self._holdings[item] or admit(self, item)
            if holding ~= nil then
                local transform = transforms[row]
                local beforeX, beforeY = transform.x, transform.y
                if previous ~= nil then
                    beforeX = previous[row].x
                    beforeY = previous[row].y
                end

                -- The emitter's own clock, advanced only on the frames it is
                -- running. Held, paused or stopped it stands still, and every
                -- age measured from it holds where it was rather than ageing
                -- through the frames the world went on drawing.
                local steps = 0.0
                if advancing and item.state == "playing" then
                    steps = step - item._worldStep
                    if steps < 0.0 then
                        steps = 0.0
                    end
                    if steps > MAX_STEPS then
                        steps = MAX_STEPS
                    end
                    item._clock = item._clock + steps
                end
                item._worldStep = step
                item._stepSeconds = timestep

                writeEmitter(self, holding, transform.x, transform.y, beforeX, beforeY, transform.rotation, steps)
                -- Taken by the step boundary that just passed, so a burst
                -- asked for between two of them waits for one rather than
                -- being emitted twice or not at all.
                if steps > 0.0 then
                    item._burst = 0.0
                end
                live = live + 1
            end
        end
    end
    return live
end

local function sync(self: Pool, world: World, running: types.Query, held: types.Query)
    local timestep, accumulator = world:getFixedTiming()
    self._timestep = timestep
    self._alpha = timestep > 0.0 and accumulator / timestep or 1.0
    if self._alpha > 1.0 then
        self._alpha = 1.0
    end
    self._step = world:fixedStepCount()

    local seen <const> = self._seen
    for item in pairs(seen) do
        seen[item] = nil
    end

    local live = walkEmitters(self, running, true) + walkEmitters(self, held, false)

    -- An emitter that lost its component or its entity leaves a range nothing
    -- points at, and nothing reports either. Comparing what was walked against
    -- what is held is what finds them, and identity is what it compares, so a
    -- component replaced rather than removed is caught too.
    if self._live > live then
        for item, holding in pairs(self._holdings) do
            if not seen[item] then
                retire(self, holding, self._step)
            end
        end
    end
    drain(self, self._step)

    -- One frame past the last live emitter, so the pass that hides the slots
    -- a retired emitter left behind is the one that actually runs.
    if live > 0 or #self._draining > 0 then
        self._settle = 2
    elseif self._settle > 0 then
        self._settle = self._settle - 1
    end
end

--- Installs the pool on a world.
---
--- A world that never calls this adds no producer, reserves no slots,
--- allocates no buffers, builds no pipelines and dispatches nothing. The
--- plugin is the entire switch.
local function plugin(options: PoolOptions): function(World)
    if options == nil or options.renderer == nil then
        error("tecs: the particle plugin needs a `renderer`", 2)
    end
    local renderer <const> = options.renderer
    local capacity <const> = options.capacity or DEFAULT_CAPACITY
    local maxEmitters <const> = options.maxEmitters or DEFAULT_EMITTERS

    return function(world: World)
        if pools[world] ~= nil then
            return
        end
        local self <const> = newPool(renderer, capacity, maxEmitters)
        pools[world] = self

        -- Not a logic query: an emitter whose entity is paused still has to be
        -- told it is holding, or its clock would carry on and its field would
        -- age through the pause. Which of the two it is decides whether the
        -- clock advances, so they are two queries rather than one and a test
        -- per row.
        local running <const> = world:query(
            {
                name = "tecs.ParticleEmitters",
                include = {ParticleEmitter, Transform},
                exclude = {ecs.Paused},
            }
        )
        local held <const> = world:query(
            {
                name = "tecs.PausedParticleEmitters",
                include = {ParticleEmitter, Transform, ecs.Paused},
            }
        )

        renderer:addProducer(self as Renderer.InstanceProducer)
        renderer:addComputeStage(self as Renderer.ComputeStage)

        -- `PostUpdate`, after `RelativeTransform`, for the reason text is: a
        -- parented emitter's world transform is composed in that phase, and
        -- reading it earlier would use the transform the previous frame left.
        world:addSystem(
            {
                name = "tecs.ParticleEmitterSync",
                phase = ecs.phases.PostUpdate,
                after = {"RelativeTransform"},
                run = function() sync(self, world, running, held) end,
            }
        )
    end
end

-------------------------------------------------------------------------------
-- The surface
-------------------------------------------------------------------------------

local record particles
    --- The handle `effect` returns and a
    --- [`ParticleEmitter`](tealdoc:tecs.gfx.particles.ParticleEmitter) names.
    type Effect = Effect
    --- Configures `effect`.
    type EffectOptions = EffectOptions
    --- Stores a compiled scalar curve.
    type Curve = Curve
    --- Stores a compiled color gradient.
    type Gradient = Gradient
    --- The two-bound form of a `Value`.
    type Range = Range
    --- Accepted wherever a property may vary per particle.
    type Value = Value
    --- Represents a color accepted by particle authoring fields.
    type Color = Color
    --- Represents a world's installed particle pool.
    type Pool = Pool
    --- Configures `plugin`.
    type PoolOptions = PoolOptions
    --- Configures a
    --- [`ParticleEmitter`](tealdoc:tecs.gfx.particles.ParticleEmitter).
    type EmitterOptions = EmitterOptions
    --- The three values an emitter's `state` takes.
    type EmitterState = EmitterState

    --- Read-only. Reports how many samples one compiled curve or gradient
    --- holds.
    CURVE_SAMPLES: integer
    --- Read-only. Reports how many floats each effect record contains.
    EFFECT_FLOATS: integer
    --- Read-only. Reports how many floats each emitter record contains. An
    --- emitter record is
    --- much the smaller of the two.
    EMITTER_FLOATS: integer
    --- Read-only. Reports how many GPU state floats one particle carries.
    STATE_FLOATS: integer

    --- Read-only. Reports each field's offset within an effect record.
    ---
    --- Published because the shaders state the same offsets and a
    --- disagreement between the two is silent: it draws something, just not
    --- the right thing. `spec/particles_spec.lua` reads both and holds them to
    --- each other, which is the only reason this is on the surface.
    EFFECT: {string: integer}
    --- Read-only. Reports each field's float offset within an emitter record,
    --- counting from zero.
    EMITTER: {string: integer}

    --- Read-only. Exposes the particle-emitter component.
    ParticleEmitter: ParticleEmitter

    --- Registers an immutable effect under `options.name` and shares it among
    --- every emitter using that name. The function requires a unique name.
    ---
    --- @param options Every section but `name` is optional and defaults to
    ---     something drawable.
    --- @return Returns a handle that stays valid until `reset`. The process-wide
    ---     registry makes it reachable from every world.
    effect: function(options: EffectOptions): Effect

    --- Returns the effect registered under `name`, or nil when none exists.
    ---
    --- @param name Nil answers nil rather than raising, so a restore holding no
    ---     name takes the same path as one holding an unknown name.
    --- @return The registered effect itself, not a copy, so two callers finding
    ---     one name share it. Nil when nothing has that name.
    find: function(name: string): Effect

    --- Returns every registered effect name in registration order.
    ---
    --- @return A fresh table each call, the caller's to keep and to modify.
    names: function(): {string}

    --- Forgets every registered effect, so a spec can register a set again.
    --- Every handle already handed out goes stale with it.
    reset: function()

    --- Compiles keyframes into a curve over normalized age.
    ---
    --- @param keys Supplies `{age, value}` pairs with age from zero through one,
    ---     in any order. Empty or nil raises, and one key defines a constant.
    --- @return Returns the piecewise-linear curve resampled at `CURVE_SAMPLES`
    ---     points. Ages outside zero through one read as the nearest endpoint.
    curve: function(keys: {CurveKey}): Curve

    --- Compiles keyframes into a color gradient over normalized age.
    ---
    --- @param keys Supplies `{age, color}` pairs under the same rules as
    ---     `curve`. The table retains alpha, but the opaque lane ignores it.
    --- @return A gradient resampled like a curve, interpolating each channel
    ---     separately, so two colors blend through whatever lies between them
    ---     componentwise rather than around a color wheel.
    gradient: function(keys: {CurveKey}): Gradient

    --- Installs the pool on a world. Without it, Tecs allocates and dispatches
    --- no particle work.
    ---
    --- @param options Requires `renderer`; both capacities have defaults.
    --- @return Returns the plugin to install on a world. Installing it on a world
    ---     that already has a pool does nothing, and installing it on two
    ---     worlds gives each its own run of the one renderer's buffer.
    plugin: function(options: PoolOptions): function(World)

    --- Returns the pool installed on a world, or nil. Tests and tooling use
    --- this function.
    ---
    --- @param world Accepts a world with or without the plugin.
    --- @return Returns the world's live pool, or nil when the plugin was never
    ---     installed. The function does not copy the pool.
    poolOf: function(world: World): Pool
end

particles.CURVE_SAMPLES = CURVE_SAMPLES
particles.EFFECT_FLOATS = EFFECT_FLOATS
particles.EMITTER_FLOATS = EMITTER_FLOATS
particles.STATE_FLOATS = STATE_FLOATS
particles.EFFECT = EFFECT
particles.EMITTER = EMITTER
particles.effect = newEffect
particles.find = findEffect
particles.names = effectNames
particles.reset = resetEffects
particles.curve = newCurve
particles.gradient = newGradient
particles.plugin = plugin

function particles.poolOf(world: World): Pool
    return pools[world]
end

particles.ParticleEmitter = ecs.newComponent(
    {
        name = "ParticleEmitter",
        container = ParticleEmitter,
        -- An emitter is a position and an effect. Requiring the position means one
        -- is never accidentally left off, which would leave the emitter out of the
        -- pool's query and quietly emitting nothing.
        requires = {Transform},
        -- One options table rather than seven positional arguments. Six of the
        -- seven are scales a caller almost never sets, and the one that matters is
        -- named: `ParticleEmitter({ effect = sparks })` says what it is, and
        -- `ParticleEmitter(sparks, nil, nil, 1, 1, 1)` does not.
        __call = function(item: ParticleEmitter, options: EmitterOptions) initEmitter(item, options) end,
        new = function(data: {string: any}): ParticleEmitter
            local item <const> = {} as ParticleEmitter
            initEmitter(item, data as EmitterOptions)
            return item
        end,
        serialize = function(item: ParticleEmitter): {string: any}
            -- The configuration and nothing else. Not one particle of the field
            -- can cross, for the reason the mixer's voices cannot: it lives where
            -- a snapshot cannot reach, and what a restore rebuilds is the emitter.
            -- A burst effect nobody notices; an ambient one comes back empty and
            -- refills over a lifetime.
            --
            -- The effect crosses as its name, the way a Sprite carries its image
            -- and an Animation its sheet. Its index is a position in registration
            -- order, so a saved one names whichever effect the loading process put
            -- there: one conditional registration or one plugin installed earlier
            -- is enough to play a different effect and say nothing about it.
            -- The tint crosses whole rather than as the four numbers it parses
            -- to. A `Color` is a name, a packed number or a table, and the parsed
            -- form is a cache on the pool's own record; writing the parsed one back
            -- would turn every named color into an anonymous quadruple that no
            -- longer follows the palette it was named from.
            return {
                state = item.state,
                seed = item.seed,
                rateScale = item.rateScale,
                sizeScale = item.sizeScale,
                timeScale = item.timeScale,
                tint = item.tint,
                effect = item.effect ~= nil and item.effect.name or nil,
            }
        end,
        deserialize = function(_world: World, data: {string: any}): ParticleEmitter
            local name <const> = data.effect as string
            if name == nil or name == "" then
                error("loadSnapshot: snapshot holds a ParticleEmitter that names " .. "no effect", 0)
            end
            -- Neither the first effect nor a dropped component. Both of those load
            -- without a word and leave the scene playing something nobody asked
            -- for, which is the failure the name is written to prevent; refusing
            -- is the only answer here that is not a guess.
            local effect <const> = findEffect(name)
            if effect == nil then
                local known <const> = effectNames()
                error(
                    (
                        "loadSnapshot: snapshot references particle effect '%s' "
                        .. "which this build does not have; found %s"
                    ):format(name, #known > 0 and table.concat(known, ", ") or "none"),
                    0
                )
            end
            return particles.ParticleEmitter(
                {
                    effect = effect,
                    state = data.state as EmitterState,
                    seed = data.seed as number,
                    rateScale = data.rateScale as number,
                    sizeScale = data.sizeScale as number,
                    timeScale = data.timeScale as number,
                    tint = data.tint as Color,
                }
            )
        end,
    }
)

return particles
