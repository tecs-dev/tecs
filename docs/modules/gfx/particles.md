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
registered once under a name and shared by every emitter naming it. A `ParticleEmitter` component names an effect
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
| `name`     | required    | What this effect is called, and unique across the process                                             |
| `capacity` | `256`       | Live particles one emitter of this effect can hold. At least one                                      |
| `overflow` | `"replace"` | `"drop"` or `"replace"`: an emission with no free slot gives way, or takes the oldest live particle's |
| `schedule` | `{}`        | When particles are emitted                                                                            |
| `spawn`    | `{}`        | How particles are placed as they spawn                                                                |
| `initial`  | `{}`        | What a particle starts with                                                                           |
| `update`   | `{}`        | How a particle evolves over its life                                                                  |
| `render`   | `{}`        | How particles are drawn                                                                               |

`name` is the only required field, and it is the whole of an effect's identity: an emitter's snapshot
carries it, so an effect without one could not be saved and two under one name could not be told apart
again. A nil or empty name raises, and so does a name already registered, both before any of the other
fields are read.

A steady-state emitter needs at least `rate * maxLifetime` slots or emissions are lost, which is
checked here and warned about by the log rather than discovered as a thin spray.

**Example:**

```teal
local sparks <const> = particles.effect({
    name = "muzzleSparks",
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

### Effect record

| Field         | What it is                                                                                |
| ------------- | ----------------------------------------------------------------------------------------- |
| `name`        | What it is called, as registered. The only thing about it that outlives the process       |
| `index`       | Where its record sits in the assembled effect table, counting from one                    |
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

The name is what an effect is, and `index` is only how this process reaches it: a position in
registration order means nothing outside the process that assigned it, and nothing stores one.

### The registry

```teal
function particles.find(name: string): Effect
function particles.names(): {string}
function particles.reset()
```

Registration is process-wide, so an effect registered anywhere is reachable from every world.

- `find` answers the effect registered under `name`, or nil when nothing has that name. It is the
  non-raising lookup, for a caller with somewhere better to put the refusal than an error raised from
  here; a nil name answers nil rather than raising, so a restore holding no name takes the same path
  as one holding an unknown name. What comes back is the registered effect itself, not a copy.
- `names` answers every registered effect's name in registration order, as a fresh table each call
  that the caller may keep and modify.
- `reset` forgets every registered effect, so a spec can register a set again. Every handle already
  handed out goes stale with it.

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

## ParticleEmitter component

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
an ambient one comes back empty and refills over a lifetime.

The effect crosses as its name, the way a `Sprite` carries its image and an `Animation` its sheet. An
index would be a position in registration order, so a saved one would name whichever effect the
loading process happened to put there, and one conditional registration or one plugin installed
earlier is enough to play a different effect and say nothing about it. A name means the same thing in
both processes or means nothing in one of them, and the second is a case that can be caught.

So it is caught. A snapshot naming no effect raises, and so does one naming an effect this build does
not have, with a message listing the names it does. Neither loads the first effect nor drops the
component: both of those load without a word and leave the scene playing something nobody asked for.

## Plugin

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

## Pool

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
