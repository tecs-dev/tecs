---
url: /modules/box2d.md
description: 'Entity-first Box2D 3 rigid bodies, colliders, queries, contacts, and sensors'
---

# tecs.box2d

`tecs.box2d` adds Box2D 3 rigid-body simulation to a world. Its public interface is entities and components:
native handles stay transient, solved poses are written to `Transform`, and snapshots carry the declaration needed
to rebuild the simulation.

The module is named for the library rather than for the subject, because Box2D's model is part of what this
module promises. `Body`, `Collider`, the filter bits, the substep count and the solver's tolerances are its
vocabulary, and reading [Box2D's own documentation](https://box2d.org/documentation/) is how to understand what
they do. Swapping the solver underneath is not an intended abstraction, so the name says which one is there. The
major version lives here rather than in the name: this is Box2D 3.

## Install

```teal
local tecs <const> = require("tecs")
local world = tecs.ecs.newWorld()
world:addPlugin(tecs.box2d.plugin({
    gravity = {0, 980},
    subStepCount = 4,
}))
```

The simulation is world-scoped and available as `tecs.box2d.of(world)`. Solver threads are process-shared.
Conflicting `workerCount` values on two worlds raise.

Public positions, extents, linear velocities, impulses, forces, gravity, and hit speeds use pixels. Angles and
angular velocities use radians. `tecs.box2d.pixelsPerMeter` is the conversion the module has already applied to
every number above: multiply meters by it, divide pixels by it. Box2D itself solves in meters, and simulating
directly in pixels would put every body far outside the size range its solver tolerances were chosen for.

## Bodies

`attach` declares a body; Box2D creation happens at the next fixed step:

```teal
local entity = world:spawn(tecs.Transform(100, 80))
tecs.box2d.attach(world, entity, {
    type = "dynamic",
    radius = 12,
    density = 1,
    friction = 0.6,
    restitution = 0.1,
})
```

`Body` stores kind, damping, gravity, bullet, rotation, and sleep options. `Collider` stores geometry, material,
filtering, and sensor state. `Motion` stores velocity for snapshots and pauses; it is not a live mirror.
`RigidBody` is the engine-owned transient handle and must not be set or removed by a game.

`Body` requires `Transform` and `Motion`, so setting one on a bare entity supplies both. `hasBody` is false between
declaration and the next fixed step. `detach(world, entity)` removes the declaration and destroys the native body
at the next fixed step. Despawning the entity destroys it through the despawn observer.

Body options are `type` (`"static"`, `"kinematic"`, or `"dynamic"`), `fixedRotation`, `isBullet`, `sleepEnabled`,
`gravityScale`, `linearDamping`, and `angularDamping`. Editing `Body` through `world:getMut` reapplies those fields
to the live body at the next fixed step.

## Colliders

No radius selects a box using `halfWidth` and `halfHeight`, both defaulting to 8. A `radius` selects a circle.
Supplying `radius` and `capsuleLength` selects a vertical capsule; the length is the distance between end centres,
excluding the caps. `offsetX` and `offsetY` move any shape in the body's local frame.

Material options are `density`, `friction`, and `restitution`. Filtering uses `categoryBits`, `maskBits`, and
`groupIndex`; defaults are category 1, all mask bits, and group 0. `isSensor = true` reports overlaps without
collision response.

Editing `Collider` through `world:getMut` replaces its live shape at the next fixed step, including geometry,
material, filter, and sensor changes.

### Multiple colliders

Additional shapes are separate entities related to their body:

```teal
local hurtbox = world:spawn()
tecs.box2d.attachCollider(world, hurtbox, player, {
    radius = 18,
    offsetY = -6,
    isSensor = true,
    categoryBits = 0x04,
})
```

The shape entity receives `Collider` and `ColliderOf(player)`. It is independently inspectable and mutable.
`ColliderOf` is exclusive, reverse-indexed, sparse, and cascade-deleted with the body.

The public geometry set is box, circle, and vertical capsule. Segments, chains, arbitrary polygons, and joints are
not exposed.

## Motion and controls

```teal
local vx, vy = tecs.box2d.velocity(world, entity)
tecs.box2d.setVelocity(world, entity, 200, -100)
local omega = tecs.box2d.angularVelocity(world, entity)
tecs.box2d.setAngularVelocity(world, entity, 2)
tecs.box2d.applyImpulse(world, entity, 100, 0)
tecs.box2d.applyImpulseAt(world, entity, 100, 0, hitX, hitY)
tecs.box2d.applyForce(world, entity, 500, 0)
tecs.box2d.applyForceAt(world, entity, 500, 0, hitX, hitY)
tecs.box2d.applyTorque(world, entity, 4)
tecs.box2d.setAwake(world, entity, false)
tecs.box2d.teleport(world, entity, 320, 180, math.pi / 2)
```

Controls on an entity without a live body do nothing. Setters and applied forces wake sleeping bodies. `teleport`
also updates `Transform`. `isAwake` reads the current sleep state.

`Paused` stores velocity in `Motion` and changes the live body to static, leaving it solid and immovable. Removing
it restores the declared kind and motion. `Disabled` removes a live body from the broad phase; removing it
enables the body again. Box2D does not preserve velocity across disable and enable.

## Raycasts

`raycast` uses Box2D's callback-free closest-hit result:

```teal
local hit = tecs.box2d.raycast(world, x1, y1, x2, y2, {
    categoryBits = 0x01,
    maskBits = 0x04,
})
```

A hit has `entity`, `x`, `y`, `normalX`, `normalY`, and `fraction`. It names a secondary collider entity when that
shape was hit, and the body entity for a primary shape.

Overlap and all-hit queries remain absent because Box2D exposes them only through callbacks. They need a native
result-buffer bridge before they are safe on a traced LuaJIT path.

## Contacts and sensors

After each fixed step the plugin drains Box2D's buffers and emits these typed events at address zero:

* `ContactBegin(entityA, entityB)`
* `ContactEnd(entityA, entityB)`
* `ContactHit(entityA, entityB, x, y, normalX, normalY, approachSpeed)`
* `SensorBegin(sensor, visitor)`
* `SensorEnd(sensor, visitor)`

```teal
world:observe(0, tecs.box2d.SensorBegin, function(event)
    print(event.sensor, event.visitor)
end)
```

No Lua callback is passed to Box2D.

## Snapshots

`Body`, `Collider`, `Motion`, and `Transform` are saved. Immediately before the column walk, physics reads live
linear and angular velocity into `Motion`. Native handles are transient. After load, the normal fixed-step
reconcile system rebuilds bodies and secondary shapes and restores motion.

Contact warm-start impulses are unavailable through Box2D's C API and are not saved, so a restored resting stack
can settle briefly. Restore is suitable for save games, not bit-exact replay continuation.
