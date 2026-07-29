---
description: "Entity-first Rapier 2D rigid bodies, colliders, queries, contacts, sensors, and snapshots"
outline: deep
---

# tecs.physics

`tecs.physics` adds Rapier 2D rigid-body simulation to an ECS world. The public
interface remains entities and components: native handles are transient and
solved poses are written back to `Transform`.

## Install

```teal
local tecs <const> = require("tecs")
local world = tecs.ecs.newWorld()
world:addPlugin(tecs.physics.plugin({
    gravity = {0, 980},
    subStepCount = 4,
}))
```

The simulation is scoped to its ECS world and is available through
`tecs.physics.of(world)`. `workerCount` is retained as a process-wide
configuration option and conflicting explicit values on two live worlds
raise. Rapier currently executes parallel work on Rayon's global executor,
so the requested count is not yet applied to the executor itself.

Public positions, extents, linear velocities, impulses, forces, and gravity
use pixels. Angles and angular velocities use radians.
`tecs.physics.pixelsPerMeter` is 32 and is the conversion already applied at
the public boundary. Rapier solves in meters.

## Bodies

`attach` declares a body. Its Rapier body is created at the next fixed step:

```teal
local entity = world:spawn(tecs.Transform(100, 80))
tecs.physics.attach(world, entity, {
    type = "dynamic",
    radius = 12,
    density = 1,
    friction = 0.6,
    restitution = 0.1,
})
```

`Body` stores kind, damping, gravity, continuous-collision, rotation, and
sleep options. `Collider` stores geometry, material, filtering, and sensor
state. `Motion` is the serializable velocity store used by pauses.
`RigidBody` is an engine-owned transient Rapier arena handle.

`Body` requires `Transform` and `Motion`. `hasBody` is false between a new
declaration and its first fixed step. `detach(world, entity)` removes the
declaration and destroys the native body at the next fixed step. Despawning
the entity destroys it immediately.

Body options are `type` (`"static"`, `"kinematic"`, or `"dynamic"`),
`fixedRotation`, `isBullet`, `sleepEnabled`, `gravityScale`,
`linearDamping`, and `angularDamping`. Editing `Body` through `world:getMut`
reapplies the declaration at the next fixed step.

## Colliders

No radius selects a box using `halfWidth` and `halfHeight`, both defaulting to 8. A `radius` selects a circle. Supplying `radius` and `capsuleLength`
selects a vertical capsule; the length is the distance between end centers,
excluding the caps. `offsetX` and `offsetY` move a shape in the body frame.

Material options are `density`, `friction`, and `restitution`. Filtering uses
32-bit `categoryBits` and `maskBits`, and both shapes must allow the pair.
Give a cohort its own category bit and omit that bit from its mask when its
members must not collide with each other. Give each cohort a bit and list the
allowed bits in its mask when only selected cohorts may collide.
`isSensor = true` reports overlaps without collision response.

Editing `Collider` through `world:getMut` replaces its live shape at the next
fixed step.

### Multiple colliders

Additional shapes are separate entities related to their body:

```teal
local hurtbox = world:spawn()
tecs.physics.attachCollider(world, hurtbox, player, {
    radius = 18,
    offsetY = -6,
    isSensor = true,
    categoryBits = 0x04,
})
```

The shape entity receives `Collider` and `ColliderOf(player)`. It is
independently inspectable and mutable. `ColliderOf` is exclusive,
reverse-indexed, sparse, and cascade-deleted with the body.

The public geometry set is box, circle, and vertical capsule. Segments,
chains, arbitrary polygons, and joints are not exposed.

## Motion and controls

```teal
local vx, vy = tecs.physics.velocity(world, entity)
tecs.physics.setVelocity(world, entity, 200, -100)
local omega = tecs.physics.angularVelocity(world, entity)
tecs.physics.setAngularVelocity(world, entity, 2)
tecs.physics.applyImpulse(world, entity, 100, 0)
tecs.physics.applyImpulseAt(world, entity, 100, 0, hitX, hitY)
tecs.physics.applyForce(world, entity, 500, 0)
tecs.physics.applyForceAt(world, entity, 500, 0, hitX, hitY)
tecs.physics.applyTorque(world, entity, 4)
tecs.physics.setAwake(world, entity, false)
tecs.physics.teleport(world, entity, 320, 180, math.pi / 2)
```

Controls on an entity without a live body do nothing. Setters and applied
forces wake sleeping bodies. `teleport` also updates `Transform`.

`Paused` stores velocity in `Motion` and changes the live body to fixed,
leaving it solid and immovable. Removing it restores its declared kind and
motion. `Disabled` removes a live body from collision and query processing
until it is enabled again.

## Raycasts

`raycast` returns Rapier's nearest intersection:

```teal
local hit = tecs.physics.raycast(world, x1, y1, x2, y2, {
    categoryBits = 0x01,
    maskBits = 0x04,
})
```

A hit has `entity`, `x`, `y`, `normalX`, `normalY`, and `fraction`. It names
the secondary collider entity when that shape was hit.

## Contacts and sensors

After each fixed step the plugin drains a Rust-owned event buffer and emits
`ContactBegin`, `ContactEnd`, `SensorBegin`, and `SensorEnd` at address zero.
No callback enters LuaJIT from Rust or from a worker thread.

Use `ContactBegin` as the impact edge. Read each entity's `Transform` and
`physics.velocity` there to derive relative speed for gameplay effects.
Contact points, normals, and impulses are not exposed; code that needs them
should add a narrow native query instead of inferring them from the begin
event.

```teal
world:observe(0, tecs.physics.SensorBegin, function(event)
    print(event.sensor, event.visitor)
end)
```

## Snapshots

Snapshots include the complete serializable Rapier state: bodies, colliders,
islands, broad and narrow phases, joints, CCD state, integration parameters,
and active contact pairs. The snapshot handler uses the persistent key
`"tecs.physics"`.

Restoring installs that state directly and reconnects the transient
`RigidBody` and secondary-collider handles by entity. This retains sleeping
islands and warm-start state rather than merely rebuilding bodies from their
declarations. Physics snapshots are tagged for Rapier 0.34; a snapshot from a
different native format falls back to the component declarations.
