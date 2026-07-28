---
description: "Rigid-body simulation on Box2D 3, solved across a shared thread pool and written back to Transform"
outline: deep
---

# tecs.physics

`tecs.physics` is rigid-body simulation on Box2D 3. Bodies are attached to entities, the solver runs across a
shared thread pool, and the solved pose is written back onto the entity's `Transform` so the rest of the engine
never has to know a body exists.

::: warning This page is pending
The public surface is being replaced. The replacement makes a body's description live in the world rather than
inside Box2D, as `Body`, `Collider` and `Motion` components, and scopes the simulation to a world rather than to
the process. Both changes move everything a reference page would name, so this page describes only what will still
be true afterwards.

Read `src/tecs/physics/init.tl` and `src/tecs/physics/World.tl` for the current surface.
:::

## Requiring it

```teal
local tecs <const> = require("tecs")
```

## What is settled

- Bodies are entities. Attaching a body to an entity gives it the same lifetime as the entity naming it, and
  despawning the entity destroys the body.
- The solved pose lands on the entity's `Transform`, so anything that reads a transform, including the renderer,
  reads physics results without a physics dependency. See [`/ecs/builtins`](/ecs/builtins) for `Transform`.
- `Paused` gates the write-back, so a paused entity keeps its pose.
- Box2D solves in metres and the engine draws in pixels, so there is a scale between them and every public
  quantity states which side of it it is on.
- The solver's thread pool is native, and shared. See [Physics threads](https://github.com/tecs-dev/tecs/blob/main/README.md#physics-threads).

## What is changing

- A body's shape, type, filter and velocity move into components, so a snapshot can store them and a load can
  rebuild them.
- The simulation becomes world-scoped rather than a process singleton, reached through `world.resources`.

## Design record

- [Physics threads](https://github.com/tecs-dev/tecs/blob/main/README.md#physics-threads)
- [A body's lifetime](https://github.com/tecs-dev/tecs/blob/main/README.md#a-bodys-lifetime)
