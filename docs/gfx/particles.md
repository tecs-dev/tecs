---
description: "GPU particle effects, emitter playback, pool sizing and snapshots."
---

# Particles

An entity represents an emitter. The GPU owns individual particles, so game
code controls an effect and its emitter rather than inspecting particles one
at a time. The [particle API](tecs.gfx.particles) carries the original effect
recipe, schedule, spawn shapes, curves, gradients, playback and pool guidance.

```sh
nupp task ex-particles
```

Space pauses the field, B adds a burst, R restarts with the same seed and C
clears existing particles. The emitter moves while world-space particles stay
where they were born.

Each emitter reserves its effect's capacity from the world pool. A pool supports
up to 4,000,000 particles. Capacity is GPU storage, not four million ECS entities
or CPU tables. The host receives one short record per emitter and dispatches the
original emit, spawn and simulate algorithms. Paused fields retain their GPU
state; removing an emitter lets its live particles drain before releasing its
range. Removing the last field releases the native pool.

Snapshots store effect names and emitter playback. Register those effects before
loading a snapshot. Individual GPU particles are not saved: a restored field
starts empty and refills from the saved schedule.

Alpha and additive particles draw as emitter groups in pool-slot order. They
are depth-tested against opaque geometry, but particles within one effect are
not individually depth-sorted. Use layers to separate effects that need a
particular depth relationship. Particles do not cast 2D shadows.

<img src="/images/gfx-particles.png" alt="GPU-simulated embers with a color gradient and additive blending." />
