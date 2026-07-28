---
description: "GPU-simulated particle emitters: effects, curves and gradients, the ParticleEmitter component, and the pool plugin"
outline: deep
---

# tecs.gfx.particles

`tecs.gfx.particles` simulates particles on the GPU and draws them as ordinary instances. An entity is an
emitter, not a particle. Per-particle state lives in a buffer the CPU never reads and the vertex
shader never sees, and it outlives the frame: a slot is handed out once, at spawn, and held until the
particle expires. What crosses back to the host is nothing at all.

Three things share the work. An `Effect` is immutable data describing how particles spawn and evolve,
registered once and shared by every emitter naming it. A `ParticleEmitter` component names an effect
and carries playback state and a few per-instance scales. A pool owns one run of the
[renderer](/modules/gfx/)'s instance buffer, sub-allocates a contiguous slot range to each
emitter, and records the three compute passes that fill it.

Drawing is not new work. A particle written into the instance buffer is an instance: the same sixteen
floats, the same four bound floats, the same mark, scan and compact, and the same one indirect draw.
The emitter presents no bound at all, because the emitter is not in the instance stream; its particles
each present their own, written by the same pass that writes the instance beside it. So culling is exact
and per particle rather than conservative around an emitter, and a slot with no live particle in it
writes a hidden bound that costs a bounds read and never reaches the draw.

::: warning Particles are opaque
The forward blended lane exists and nothing particle-shaped reaches it: a row is routed forward by
extraction negating the first half extent of its cull bound, and the simulate pass writes every
particle's bound with both extents positive. So a particle goes to the G-buffer, which is written
with replace, and a color's alpha channel reaches the swapchain having blended against nothing. A
gradient ending at transparent black writes opaque black over whatever was behind it, which is worse
than not fading at all. Alpha is carried, and it is inert.

What works today is debris, chunks, gibs, snow, rain, confetti and hard-edged sparks; the only fade
available is the size curve going to zero. Fire, smoke, glow and soft dust want the blended lane and
do not yet reach it.
:::

What is deliberately unavailable, and structurally rather than because nobody wrote it: no particle
can be inspected, moved, killed or counted individually, and no save can round-trip a field.
`finished` and `estimatedCount` answer from the schedule instead, exactly and as a prediction
respectively.

## Registering an effect

```teal
function particles.effect(options: EffectOptions): Effect
```

An effect is registered once, is immutable afterwards, and is shared by every emitter naming it.

**Top-level options:**

| Field      | Default     | What it is                                                                                            |
| ---------- | ----------- | ----------------------------------------------------------------------------------------------------- |
| `capacity` | `256`       | Live particles one emitter of this effect can hold. At least one                                      |
| `overflow` | `"replace"` | `"drop"` or `"replace"`: an emission with no free slot gives way, or takes the oldest live particle's |
| `schedule` | `{}`        | When particles are emitted                                                                            |
| `spawn`    | `{}`        | How particles are placed as they spawn                                                                |
| `initial`  | `{}`        | What a particle starts with                                                                           |
| `update`   | `{}`        | How a particle evolves over its life                                                                  |
| `render`   | `{}`        | How particles are drawn                                                                               |

A steady-state emitter needs at least `rate * maxLifetime` slots or emissions are lost, which is
checked here and warned about by the log rather than discovered as a thin spray.

**Example:**

```teal
local sparks <const> = particles.effect({
    capacity = 512,
    schedule = { rate = 256, duration = 0.4, bursts = { { time = 0.0, count = 64 } } },
    spawn = { shape = "disc", width = 12.0, spread = math.pi * 2.0, space = "world" },
    initial = {
        lifetime = { min = 0.4, max = 1.2 },
        speed = { min = 40.0, max = 180.0 },
        size = { min = 2.0, max = 6.0 },
        accelerationY = { min = 200.0, max = 320.0 },
        color = "#ffd080",
    },
    update = {
        drag = 0.6,
        size = particles.curve({ { 0.0, 0.4 }, { 0.15, 1.0 }, { 1.0, 0.0 } }),
        color = particles.gradient({ { 0.0, "#fff4c0" }, { 1.0, "#ff8020" } }),
    },
    render = { layer = 2 },
})
```

### Values, colors and ranges

A property typed `Value` takes either a constant or a range: `300` and `{ min = 180, max = 420 }` are
both accepted everywhere one appears, and cost the same, because the shader draws between two bounds
either way and equal bounds are a constant. Bounds arriving the wrong way round are swapped rather
than refused; a non-finite number raises with the field named.

A `Color` is `"#rrggbb"`, `"#rrggbbaa"`, a packed number in `0xrrggbbaa` form, or a list of up to
four numbers in zero to one.

### schedule

| Field      | Default | What it is                                                                     |
| ---------- | ------- | ------------------------------------------------------------------------------ |
| `rate`     | `0`     | Particles per second, emitted continuously                                     |
| `duration` | `0`     | Seconds one emission cycle runs for. Zero means unbounded                      |
| `looping`  | `false` | Whether the cycle repeats                                                      |
| `delay`    | `0`     | Seconds before emission starts                                                 |
| `bursts`   | `{}`    | Timed counts, at most four, each `{ time = , count = }` from the cycle's start |

A muzzle flash is one burst at time zero. More than four bursts raises.

### spawn

| Field             | Default     | What it is                                                                                                          |
| ----------------- | ----------- | ------------------------------------------------------------------------------------------------------------------- |
| `shape`           | `"point"`   | `"point"`, `"line"`, `"rectangle"`, `"rectangleEdge"`, `"disc"`, `"ring"` or `"cone"`                               |
| `width`           | `0`         | Width for a line or rectangle, radius for a disc, ring or cone                                                      |
| `height`          | `0`         | Height for a rectangle. Ignored by every other shape                                                                |
| `arc`             | `2 * pi`    | Sector a disc, ring or cone samples, in radians                                                                     |
| `rotation`        | `0`         | Turns the sampled area, independently of where particles are launched                                               |
| `distribution`    | `"uniform"` | `"uniform"` or `"normal"`. A gaussian spread makes a column read as a column rather than as a slab                  |
| `direction`       | `0`         | Launch direction in radians                                                                                         |
| `spread`          | `0`         | The **full** cone centerd on `direction`, so a particle leaves within plus or minus half of it                      |
| `outward`         | `false`     | Launch along the shape's outward normal instead: disc, ring, cone and a rectangle's edge have one                   |
| `space`           | `"world"`   | `"local"` particles follow the emitter's transform for their whole life; `"world"` particles read it once, at spawn |
| `inheritVelocity` | `0`         | How much of the emitter's own velocity a particle leaves with, zero to one, in world space only                     |

An unknown `shape`, `distribution` or `space` raises.

### initial

| Field             | Default | Type    |
| ----------------- | ------- | ------- |
| `lifetime`        | `1.0`   | `Value` |
| `speed`           | `0.0`   | `Value` |
| `size`            | `1.0`   | `Value` |
| `rotation`        | `0.0`   | `Value` |
| `angularVelocity` | `0.0`   | `Value` |
| `accelerationX`   | `0.0`   | `Value` |
| `accelerationY`   | `0.0`   | `Value` |
| `color`           | white   | `Color` |

Acceleration is randomized per axis, because independent axes are what make a plume drift apart
instead of translating as a block. `color` is multiplied by the update gradient and by the emitter's
tint.

### update

| Field                    | Default | What it is                                                                                                  |
| ------------------------ | ------- | ----------------------------------------------------------------------------------------------------------- |
| `drag`                   | `0`     | Damping in units of one over seconds, applied as `velocity / (1 + drag * dt)`, so it composes with any step |
| `radialAcceleration`     | `0`     | `Value`. Acceleration away from the emitter                                                                 |
| `tangentialAcceleration` | `0`     | `Value`. Acceleration at right angles to that                                                               |
| `size`                   | none    | `Curve` multiplying the particle's own size over its life                                                   |
| `color`                  | none    | `Gradient` multiplying the particle's own color over its life                                               |

Radial and tangential acceleration are the difference between a fountain and a vortex. An absent
curve multiplies by one and an absent gradient by white, so leaving either out costs nothing.

### render

| Field           | Default   | What it is                                                                                                                                      |
| --------------- | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `material`      | none      | The material shading the quad, by name. Absent samples the image array and covers the whole quad                                                |
| `materialParam` | `0`       | Passed to the material, zero to one, clamped                                                                                                    |
| `sprite`        | none      | A registered image, from `Renderer:sprite`. Absent draws a white quad                                                                           |
| `sheet`         | none      | A sheet to animate instead of a still region                                                                                                    |
| `tag`           | none      | Which tag of that sheet to play                                                                                                                 |
| `layer`         | `1`       | Which render layer the particles land on, one to `layers.MAX`                                                                                   |
| `pivotX`        | `0.5`     | Where the quad hangs off the particle's position, as a fraction of the frame from its top left                                                  |
| `pivotY`        | `0.5`     | As `pivotX`                                                                                                                                     |
| `alignment`     | `"fixed"` | `"velocity"` adds the path's angle to the particle's own rotation rather than replacing it, so a spinning spark aligned to its path still spins |
| `stretch`       | `1.0`     | Multiplies the along-path axis when aligned to velocity                                                                                         |
| `blend`         | none      | Accepted, logged once per name, and ignored                                                                                                     |
| `clip`          | `0`       | Which clip region the fragments are kept inside. Zero is no clipping                                                                            |

An animated effect plays its cycle exactly once over each particle's own life and clamps at the end,
so a randomized lifetime randomizes the playback speed. Per-frame durations, reverse and pingpong
all arrive already spent, because this uses the same frame table an animated entity does; see
[animation](/modules/gfx/animation). A `layer` outside one to [`layers.MAX`](/modules/gfx/layers), and an `alignment`
that is neither of the two, both raise.

One depth is taken for the whole effect rather than one per particle: an effect names one layer, so
its band and sort mode are constant, and what a per-particle depth would buy is sorting within the
band, which is a separate feature.

### The Effect record

| Field         | What it is                                                                                |
| ------------- | ----------------------------------------------------------------------------------------- |
| `index`       | Index in the registry, counting from one                                                  |
| `capacity`    | Live particles one emitter of this effect holds                                           |
| `maxLifetime` | The longest a particle can live, which decides when a stopped emitter has finished        |
| `emitFor`     | Seconds from `play` to the last emission, or `-1` for an effect that never stops emitting |
| `rate`        | As authored                                                                               |
| `delay`       | As authored                                                                               |
| `duration`    | As authored                                                                               |
| `looping`     | As authored                                                                               |
| `bursts`      | The schedule's bursts, as flat time and count pairs                                       |

The schedule is kept so `finished` and `estimatedCount` can answer from it without asking the GPU
anything.

## Curves and gradients

### curve

Compiles keyframes into a curve over normalized age.

```teal
function particles.curve(keys: {CurveKey}): Curve
```

**Parameters:**

- `keys`: a list of `{ age, value }`, with age in zero to one. Keys may sit anywhere in that range
  and need not be sorted. At least one key is required.

**Returns:** the piecewise-linear curve through those keys, sampled onto `particles.CURVE_SAMPLES`
evenly spaced values the shader indexes without searching.

### gradient

Compiles keyframes into a color gradient over normalized age.

```teal
function particles.gradient(keys: {CurveKey}): Gradient
```

**Parameters:**

- `keys`: a list of `{ age, color }`, where the color is any `Color`.

**Returns:** the gradient, sampled at the same resolution, four floats a sample.

Thirty-two samples removes both the eight-key cap and the even spacing a CPU particle system's ramps
have, for the same trade the frame table already made: what an author writes stays a curve with keys
wherever the author put them, and the shader does one lookup rather than walking a graph per particle
per frame.

## The ParticleEmitter component

An emitter is an effect, its playback state, and a few per-instance scales. It is deliberately small:
if an instance could override every effect field then effects would stop being reusable GPU data and
every emitter would grow to hold a copy of one.

| Field       | Default     | What it is                                                        |
| ----------- | ----------- | ----------------------------------------------------------------- |
| `effect`    | required    | The effect this plays. Cannot change after the emitter is spawned |
| `state`     | `"playing"` | `"playing"`, `"paused"` or `"stopped"`                            |
| `seed`      | `1`         | The random sequence. Two emitters with one seed produce one field |
| `rateScale` | `1.0`       | Multiplies the effect's rate                                      |
| `sizeScale` | `1.0`       | Multiplies the effect's sizes                                     |
| `timeScale` | `1.0`       | Multiplies how fast it runs                                       |
| `tint`      | white       | `Color` multiplying every particle's color                        |

Constructing one without an effect raises, as does an unknown `state`. The component carries no
capacity of its own: that belongs to the effect, because it decides a slot range in the pool and the
range has to be fixed when the emitter is created. Changing effects means despawning and spawning
again, which is cheap.

`ParticleEmitter` requires `Transform`, so an emitter is never left out of the pool's query by having
no position.

**Example:**

```teal
world:spawn(
    Transform(x, y),
    particles.ParticleEmitter({ effect = sparks, seed = index, tint = "#ffffff" })
)
```

### Playback

```teal
function ParticleEmitter:play()
function ParticleEmitter:stop()
function ParticleEmitter:pause()
function ParticleEmitter:clear()
function ParticleEmitter:restart()
function ParticleEmitter:burst(count: number)
```

- `play` starts or resumes emission. From stopped it begins the cycle again; from paused it carries
  on from where it was, with the steps spent paused not counted against the schedule.
- `stop` stops emission and resets the schedule. Live particles drain, and the next `play` starts the
  cycle from its beginning with a fresh random sequence.
- `pause` stops emission and holds. The schedule and the particles both keep their state and neither
  ages. A stopped emitter is not paused by it.
- `clear` kills every live particle immediately and leaves emission untouched, so a playing emitter
  starts filling again on the next step. Killing the field and stopping the schedule are deliberately
  separate.
- `restart` resets the schedule and the random sequence and starts playing. It is reproducible: every
  particle's draws are a pure function of the seed, the generation, the serial and the property, and
  all four start over.
- `burst` emits `count` particles at the next step boundary. A no-op on an emitter that is not
  playing, and more than the emitter's own free capacity is truncated to what fits rather than
  refused.

An entity carrying the `Paused` builtin holds its emitter too: the clock stands still, so the field
does not age through the pause while the world goes on drawing.

Each randomized property draws from a lane of its own, which is what makes an effect safe to edit.
Adding a range to a property that had a constant does not shift what every other property chose, so an
effect edited to randomize its rotation keeps the sizes and the lifetimes it already had.

### finished

Whether this emitter has stopped emitting and its last particle has died.

```teal
function ParticleEmitter:finished(): boolean
```

Exact, and it costs nothing: it is the schedule plus the longest lifetime against the emitter's own
clock, all of which the host holds. A paused emitter is never finished, and neither is a playing one
whose effect never stops emitting. This is what almost every "has the explosion finished" question is
actually asking, and unlike a count it needs nothing read back from the GPU.

### estimatedCount

About how many particles are alive.

```teal
function ParticleEmitter:estimatedCount(): integer
```

A prediction rather than a measurement, and the name carries the caveat: it integrates the schedule
over the last lifetime's worth of steps and subtracts what has expired, then clamps to the effect's
capacity. Exact whenever no burst was truncated and no overflow fired, which is the case a caller
checking against the cap is checking for. Reading the real number would mean a pipeline stall, which
is the thing this design refuses.

### Snapshots

A snapshot carries the configuration, the seed and the playback state, and not one particle. The
field lives where a snapshot cannot reach, so a burst effect is gone by the time anybody notices and
an ambient one comes back empty and refills over a lifetime. Restoring an emitter whose effect this
process has not registered raises, because the effect is named by its registry index.

## The plugin

```teal
function particles.plugin(options: PoolOptions): function(World)
```

| Option        | Default  | What it is                                                                                                          |
| ------------- | -------- | ------------------------------------------------------------------------------------------------------------------- |
| `renderer`    | required | The renderer whose instance buffer the pool takes a run of, and whose device its buffers and pipelines are built on |
| `capacity`    | `16384`  | Live particles the pool holds, over every emitter in the world                                                      |
| `maxEmitters` | `256`    | Emitters the pool holds at once                                                                                     |

`capacity` is fixed at install: changing it would move the run, and moving the run lays out the whole
scene again. An emitter that arrives when the pool has no room for its effect's capacity, or past
`maxEmitters`, draws nothing and says so in the log.

A world that never adds this plugin adds no producer, reserves no slots, allocates no buffers, builds
no pipelines and dispatches nothing. The plugin is the entire switch, and installing it twice on one
world is a no-op.

**Example:**

```teal
world:addPlugin(particles.plugin({
    renderer = app.renderer,
    capacity = 32768,
    maxEmitters = 64,
}))
```

It adds one system, `tecs.ParticleEmitterSync`, in `PostUpdate` after `RelativeTransform`, for the
reason text has one there: a parented emitter's world transform is composed in that phase, and
reading it earlier would use the transform the previous frame left. The system walks every emitter
every frame rather than gating on a dirty bit. An emitter's fields are read by the GPU every frame
whatever the world thinks changed, its transform moves without touching the component, and its
schedule advances without anything writing anything; emitters are counted in tens, so the walk is
cheaper than any arrangement that tried to avoid it would be to get right.

Integration is whole fixed steps against the emitter's own clock, so two machines fed the same steps
hold the same field however many frames either drew. A frame that fell far behind advances an emitter
by at most eight steps, which bounds the work rather than letting a stall compound into a longer one.
An emitter carrying [`PreviousTransform`](/modules/gfx/) reports where it stood before the
current fixed step as well as where it stands now; without one, both are the same position.

Despawning an emitter stops emission and lets its field drain: the pool holds the slot range until
the effect's longest lifetime has passed and only then hands it back. An emitter that lost its
component rather than its entity is caught the same way, by comparing what the walk saw against what
the pool holds.

## The pool

```teal
function particles.poolOf(world: World): Pool
```

The pool installed on a world, or nil. For tests and tooling. Its `capacity` field is the number it
was installed with, and `Pool:destroy()` releases the buffers and pipelines it owns and is safe to
call more than once. Everything else on it implements the renderer's instance-producer and
compute-stage interfaces, and a game does not call it.

## Constants

| Name                       | Value | What it is                                       |
| -------------------------- | ----- | ------------------------------------------------ |
| `particles.CURVE_SAMPLES`  | `32`  | Samples one compiled curve or gradient holds     |
| `particles.EFFECT_FLOATS`  | `64`  | Floats per effect record                         |
| `particles.EMITTER_FLOATS` | `24`  | Floats per emitter record                        |
| `particles.STATE_FLOATS`   | `8`   | Floats of state one particle carries, on the GPU |

`particles.EFFECT` and `particles.EMITTER` map a field name to its offset within one of those
records. They are published because the shaders state the same offsets and a disagreement between the
two is silent: it draws something, just not the right thing. The spec suite reads both and holds them
to each other, which is the only reason they are public.
<!-- @generated by docs/scripts/reference.py from src/tecs/gfx/particles.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/gfx/particles.tl`.

<a id="tecs.gfx.particles.CURVE_SAMPLES"></a>

### tecs.gfx.particles.CURVE_SAMPLES

<pre><code v-pre><a href="#tecs.gfx.particles.CURVE_SAMPLES">tecs.gfx.particles.CURVE_SAMPLES</a>: integer
</code></pre>

Samples one compiled curve or gradient holds.
<a id="tecs.gfx.particles.Color"></a>

### tecs.gfx.particles.Color

<pre><code v-pre>type <a href="#tecs.gfx.particles.Color">tecs.gfx.particles.Color</a> = Color
</code></pre>

Accepted wherever a color is asked for.
<a id="tecs.gfx.particles.Curve"></a>

### tecs.gfx.particles.Curve

<pre><code v-pre>type <a href="#tecs.gfx.particles.Curve">tecs.gfx.particles.Curve</a> = Curve
</code></pre>

What `curve` answers with.
<a id="tecs.gfx.particles.EFFECT"></a>

### tecs.gfx.particles.EFFECT

<pre><code v-pre><a href="#tecs.gfx.particles.EFFECT">tecs.gfx.particles.EFFECT</a>: {string : integer}
</code></pre>

Where each field sits within an effect and an emitter record.

Published because the shaders state the same offsets and a
disagreement between the two is silent: it draws something, just not
the right thing. `spec/particles_spec.lua` reads both and holds them to
each other, which is the only reason this is on the surface.
<a id="tecs.gfx.particles.EFFECT_FLOATS"></a>

### tecs.gfx.particles.EFFECT_FLOATS

<pre><code v-pre><a href="#tecs.gfx.particles.EFFECT_FLOATS">tecs.gfx.particles.EFFECT_FLOATS</a>: integer
</code></pre>

Floats per effect and per emitter record, which the shaders state again.
<a id="tecs.gfx.particles.EMITTER"></a>

### tecs.gfx.particles.EMITTER

<pre><code v-pre><a href="#tecs.gfx.particles.EMITTER">tecs.gfx.particles.EMITTER</a>: {string : integer}
</code></pre>

The same for an emitter record. Both are keyed by field name and give a
float offset from the record's start, counting from zero.
<a id="tecs.gfx.particles.EMITTER_FLOATS"></a>

### tecs.gfx.particles.EMITTER_FLOATS

<pre><code v-pre><a href="#tecs.gfx.particles.EMITTER_FLOATS">tecs.gfx.particles.EMITTER_FLOATS</a>: integer
</code></pre>

The second of that pair, and a different number: an emitter record is
much the smaller of the two.
<a id="tecs.gfx.particles.Effect"></a>

### tecs.gfx.particles.Effect

<pre><code v-pre>type <a href="#tecs.gfx.particles.Effect">tecs.gfx.particles.Effect</a> = Effect
</code></pre>

The handle `effect` answers with and a `ParticleEmitter` names.
<a id="tecs.gfx.particles.EffectOptions"></a>

### tecs.gfx.particles.EffectOptions

<pre><code v-pre>type <a href="#tecs.gfx.particles.EffectOptions">tecs.gfx.particles.EffectOptions</a> = EffectOptions
</code></pre>

What `effect` takes.
<a id="tecs.gfx.particles.EmitterOptions"></a>

### tecs.gfx.particles.EmitterOptions

<pre><code v-pre>type <a href="#tecs.gfx.particles.EmitterOptions">tecs.gfx.particles.EmitterOptions</a> = EmitterOptions
</code></pre>

What a `ParticleEmitter` is constructed from.
<a id="tecs.gfx.particles.EmitterState"></a>

### tecs.gfx.particles.EmitterState

<pre><code v-pre>type <a href="#tecs.gfx.particles.EmitterState">tecs.gfx.particles.EmitterState</a> = EmitterState
</code></pre>

The three values an emitter's `state` takes.
<a id="tecs.gfx.particles.Gradient"></a>

### tecs.gfx.particles.Gradient

<pre><code v-pre>type <a href="#tecs.gfx.particles.Gradient">tecs.gfx.particles.Gradient</a> = Gradient
</code></pre>

What `gradient` answers with.
<a id="tecs.gfx.particles.ParticleEmitter"></a>

### tecs.gfx.particles.ParticleEmitter

<pre><code v-pre><a href="#tecs.gfx.particles.ParticleEmitter">tecs.gfx.particles.ParticleEmitter</a>: ParticleEmitter
</code></pre>

The emitter component.
<a id="tecs.gfx.particles.Pool"></a>

### tecs.gfx.particles.Pool

<pre><code v-pre>type <a href="#tecs.gfx.particles.Pool">tecs.gfx.particles.Pool</a> = Pool
</code></pre>

What `poolOf` answers with.
<a id="tecs.gfx.particles.PoolOptions"></a>

### tecs.gfx.particles.PoolOptions

<pre><code v-pre>type <a href="#tecs.gfx.particles.PoolOptions">tecs.gfx.particles.PoolOptions</a> = PoolOptions
</code></pre>

What `plugin` takes.
<a id="tecs.gfx.particles.Range"></a>

### tecs.gfx.particles.Range

<pre><code v-pre>type <a href="#tecs.gfx.particles.Range">tecs.gfx.particles.Range</a> = Range
</code></pre>

The two-bound form of a `Value`.
<a id="tecs.gfx.particles.STATE_FLOATS"></a>

### tecs.gfx.particles.STATE_FLOATS

<pre><code v-pre><a href="#tecs.gfx.particles.STATE_FLOATS">tecs.gfx.particles.STATE_FLOATS</a>: integer
</code></pre>

Floats of state one particle carries, on the GPU and nowhere else.
<a id="tecs.gfx.particles.Value"></a>

### tecs.gfx.particles.Value

<pre><code v-pre>type <a href="#tecs.gfx.particles.Value">tecs.gfx.particles.Value</a> = Value
</code></pre>

Accepted wherever a property may vary per particle.
<a id="tecs.gfx.particles.curve"></a>

### tecs.gfx.particles.curve

<pre><code v-pre>function <a href="#tecs.gfx.particles.curve">tecs.gfx.particles.curve</a>(keys: {CurveKey}): <a href="#tecs.gfx.particles.Curve">Curve</a>
</code></pre>

Compiles keyframes into a curve over normalized age.

#### Parameters

| Type                          | Name                    | Description                                                                                                                                                                                                                               |
| ----------------------------- | ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{CurveKey}</code> | <code v-pre>keys</code> | `{age, value}` pairs with age in zero to one. They may sit anywhere in that span and need not be sorted; what comes out is the piecewise-linear curve through them at a fixed resolution. Empty or nil raises, and one key is a constant. |

#### Returns

| Type                                                             | Description                                                                                                                                                                 |
| ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.gfx.particles.Curve">Curve</a></code> | A resampled curve at `CURVE_SAMPLES` points, so the keys are not kept and the shape between two distant ones is straight. Ages outside zero to one read as the nearest end. |

<a id="tecs.gfx.particles.effect"></a>

### tecs.gfx.particles.effect

<pre><code v-pre>function <a href="#tecs.gfx.particles.effect">tecs.gfx.particles.effect</a>(options: <a href="#tecs.gfx.particles.EffectOptions">EffectOptions</a>): <a href="#tecs.gfx.particles.Effect">Effect</a>
</code></pre>

Registers an effect under `options.name`. Immutable once registered,
and shared by every emitter naming it. A name is required and a name
already taken is refused.

#### Parameters

| Type                                                                             | Name                       | Description                                                              |
| -------------------------------------------------------------------------------- | -------------------------- | ------------------------------------------------------------------------ |
| <code v-pre><a href="#tecs.gfx.particles.EffectOptions">EffectOptions</a></code> | <code v-pre>options</code> | Every section but `name` is optional and defaults to something drawable. |

#### Returns

| Type                                                               | Description                                                                                                   |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.gfx.particles.Effect">Effect</a></code> | A handle that stays valid until `reset`. Registration is process-wide, so this is reachable from every world. |

<a id="tecs.gfx.particles.find"></a>

### tecs.gfx.particles.find

<pre><code v-pre>function <a href="#tecs.gfx.particles.find">tecs.gfx.particles.find</a>(name: string): <a href="#tecs.gfx.particles.Effect">Effect</a>
</code></pre>

The effect registered under `name`, or nil when nothing has that name.

#### Parameters

| Type                      | Name                    | Description                                                                                                           |
| ------------------------- | ----------------------- | --------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>string</code> | <code v-pre>name</code> | Nil answers nil rather than raising, so a restore holding no name takes the same path as one holding an unknown name. |

#### Returns

| Type                                                               | Description                                                                                                         |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.gfx.particles.Effect">Effect</a></code> | The registered effect itself, not a copy, so two callers finding one name share it. Nil when nothing has that name. |

<a id="tecs.gfx.particles.gradient"></a>

### tecs.gfx.particles.gradient

<pre><code v-pre>function <a href="#tecs.gfx.particles.gradient">tecs.gfx.particles.gradient</a>(keys: {CurveKey}): <a href="#tecs.gfx.particles.Gradient">Gradient</a>
</code></pre>

Compiles keyframes into a color gradient over normalized age.

#### Parameters

| Type                          | Name                    | Description                                                                                                     |
| ----------------------------- | ----------------------- | --------------------------------------------------------------------------------------------------------------- |
| <code v-pre>{CurveKey}</code> | <code v-pre>keys</code> | `{age, color}` pairs, on the same terms as `curve` takes its values. The alpha channel is carried and is inert. |

#### Returns

| Type                                                                   | Description                                                                                                                                                                      |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.gfx.particles.Gradient">Gradient</a></code> | A gradient resampled like a curve, interpolating each channel separately, so two colors blend through whatever lies between them componentwise rather than around a color wheel. |

<a id="tecs.gfx.particles.names"></a>

### tecs.gfx.particles.names

<pre><code v-pre>function <a href="#tecs.gfx.particles.names">tecs.gfx.particles.names</a>(): {string}
</code></pre>

Every registered effect's name, in registration order.

#### Returns

| Type                        | Description                                                  |
| --------------------------- | ------------------------------------------------------------ |
| <code v-pre>{string}</code> | A fresh table each call, the caller's to keep and to modify. |

<a id="tecs.gfx.particles.plugin"></a>

### tecs.gfx.particles.plugin

<pre><code v-pre>function <a href="#tecs.gfx.particles.plugin">tecs.gfx.particles.plugin</a>(options: <a href="#tecs.gfx.particles.PoolOptions">PoolOptions</a>): function(World)
</code></pre>

Installs the pool on a world. Nothing is allocated or dispatched
without it.

#### Parameters

| Type                                                                         | Name                       | Description                                         |
| ---------------------------------------------------------------------------- | -------------------------- | --------------------------------------------------- |
| <code v-pre><a href="#tecs.gfx.particles.PoolOptions">PoolOptions</a></code> | <code v-pre>options</code> | `renderer` is required; the two capacities default. |

#### Returns

| Type                               | Description                                                                                                                                                                              |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>function(World)</code> | The plugin, to be handed to a world. Installing it on a world that already has a pool does nothing, and installing it on two worlds gives each its own run of the one renderer's buffer. |

<a id="tecs.gfx.particles.poolOf"></a>

### tecs.gfx.particles.poolOf

<pre><code v-pre>function <a href="#tecs.gfx.particles.poolOf">tecs.gfx.particles.poolOf</a>(world: World): <a href="#tecs.gfx.particles.Pool">Pool</a>
</code></pre>

The pool installed on a world, or nil. For tests and tooling.

#### Parameters

| Type                     | Name                     | Description                                                                                                    |
| ------------------------ | ------------------------ | -------------------------------------------------------------------------------------------------------------- |
| <code v-pre>World</code> | <code v-pre>world</code> | Any world, with or without the plugin, so this doubles as the test for whether particles are installed on one. |

#### Returns

| Type                                                           | Description                                                                                                                   |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.gfx.particles.Pool">Pool</a></code> | Nil when the plugin was never installed on that world. The pool itself, not a copy, so writing through it writes the world's. |

<a id="tecs.gfx.particles.reset"></a>

### tecs.gfx.particles.reset

<pre><code v-pre>function <a href="#tecs.gfx.particles.reset">tecs.gfx.particles.reset</a>()
</code></pre>

Forgets every registered effect, so a spec can register a set again.
Every handle already handed out goes stale with it.
