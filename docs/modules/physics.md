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
<!-- @generated by `cargo xtask docs-reference` from src/tecs/physics/init.tl. Do not edit below this line. -->

## Reference

Every function and type this module carries, rendered from `src/tecs/physics/init.tl`.

<a id="tecs.physics.Body"></a>

### tecs.physics.Body

<pre><code v-pre><a href="#tecs.physics.Body">tecs.physics.Body</a>: Body
</code></pre>

<a id="tecs.physics.Collider"></a>

### tecs.physics.Collider

<pre><code v-pre><a href="#tecs.physics.Collider">tecs.physics.Collider</a>: Collider
</code></pre>

<a id="tecs.physics.ColliderOf"></a>

### tecs.physics.ColliderOf

<pre><code v-pre><a href="#tecs.physics.ColliderOf">tecs.physics.ColliderOf</a>: Component
</code></pre>

<a id="tecs.physics.ContactBegin"></a>

### tecs.physics.ContactBegin

<pre><code v-pre><a href="#tecs.physics.ContactBegin">tecs.physics.ContactBegin</a>: ContactBegin
</code></pre>

<a id="tecs.physics.ContactEnd"></a>

### tecs.physics.ContactEnd

<pre><code v-pre><a href="#tecs.physics.ContactEnd">tecs.physics.ContactEnd</a>: ContactEnd
</code></pre>

<a id="tecs.physics.Motion"></a>

### tecs.physics.Motion

<pre><code v-pre><a href="#tecs.physics.Motion">tecs.physics.Motion</a>: Motion
</code></pre>

<a id="tecs.physics.RigidBody"></a>

### tecs.physics.RigidBody

<pre><code v-pre><a href="#tecs.physics.RigidBody">tecs.physics.RigidBody</a>: RigidBody
</code></pre>

<a id="tecs.physics.SensorBegin"></a>

### tecs.physics.SensorBegin

<pre><code v-pre><a href="#tecs.physics.SensorBegin">tecs.physics.SensorBegin</a>: SensorBegin
</code></pre>

<a id="tecs.physics.SensorEnd"></a>

### tecs.physics.SensorEnd

<pre><code v-pre><a href="#tecs.physics.SensorEnd">tecs.physics.SensorEnd</a>: SensorEnd
</code></pre>

<a id="tecs.physics.angularVelocity"></a>

### tecs.physics.angularVelocity

<pre><code v-pre>function <a href="#tecs.physics.angularVelocity">tecs.physics.angularVelocity</a>(world: types.World, entity: integer): number
</code></pre>

Reads angular velocity in radians per second.

Radians need no conversion, so this is the same number Rapier holds, unlike
the linear velocity beside it.

#### Parameters

| Type                           | Name                      | Description                                                            |
| ------------------------------ | ------------------------- | ---------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code>  | The world holding the entity.                                          |
| <code v-pre>integer</code>     | <code v-pre>entity</code> | An entity with no live body reads as not spinning rather than raising. |

#### Returns

| Type                      | Description                                                                                                          |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>number</code> | Radians per second, in the direction a rising `Transform.rotation` turns. Live from Rapier, not the `Motion` column. |

<a id="tecs.physics.applyForce"></a>

### tecs.physics.applyForce

<pre><code v-pre>function <a href="#tecs.physics.applyForce">tecs.physics.applyForce</a>(world: types.World, entity: integer, x: number, y: number)
</code></pre>

Applies a continuous force at the body's center and wakes it.

Cleared by Rapier at the end of every step, so holding a body up against
gravity means calling this every fixed step rather than once.

#### Parameters

| Type                           | Name                      | Description                                                                                                                  |
| ------------------------------ | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code>  | The world holding the entity.                                                                                                |
| <code v-pre>integer</code>     | <code v-pre>entity</code> | Does nothing for one with no live body.                                                                                      |
| <code v-pre>number</code>      | <code v-pre>x</code>      | Pixel-scaled force along x. Dividing it by the body's mass in kilograms gives the acceleration in pixels per second squared. |
| <code v-pre>number</code>      | <code v-pre>y</code>      | The same along y, positive downward. Applied at the center of mass, so neither component imparts spin.                       |

<a id="tecs.physics.applyForceAt"></a>

### tecs.physics.applyForceAt

<pre><code v-pre>function <a href="#tecs.physics.applyForceAt">tecs.physics.applyForceAt</a>(world: types.World, entity: integer, x: number, y: number, pointX: number, pointY: number)
</code></pre>

Applies a continuous force at a world-space point and wakes the body.

Cleared at the end of every step, like `applyForce`.

#### Parameters

| Type                           | Name                      | Description                                                                                                                                     |
| ------------------------------ | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code>  | The world holding the entity.                                                                                                                   |
| <code v-pre>integer</code>     | <code v-pre>entity</code> | Does nothing for one with no live body.                                                                                                         |
| <code v-pre>number</code>      | <code v-pre>x</code>      | Pixel-scaled force along x, read as `applyForce` reads it.                                                                                      |
| <code v-pre>number</code>      | <code v-pre>y</code>      | The same along y, positive downward.                                                                                                            |
| <code v-pre>number</code>      | <code v-pre>pointX</code> | Where the force is applied, in world pixels rather than in the body's frame. Off the center of mass it produces torque as well as acceleration. |
| <code v-pre>number</code>      | <code v-pre>pointY</code> | The same along y.                                                                                                                               |

<a id="tecs.physics.applyImpulse"></a>

### tecs.physics.applyImpulse

<pre><code v-pre>function <a href="#tecs.physics.applyImpulse">tecs.physics.applyImpulse</a>(world: types.World, entity: integer, x: number, y: number)
</code></pre>

Pushes a body once, at its center of mass.

An impulse rather than a force, so the effect does not depend on how long
the step happened to be. Wakes the body: Rapier lets a resting island sleep,
and pushing a sleeping body without waking it does nothing.

#### Parameters

| Type                           | Name                      | Description                                                                                                                                                                                |
| ------------------------------ | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <code v-pre>types.World</code> | <code v-pre>world</code>  | The world holding the entity.                                                                                                                                                              |
| <code v-pre>integer</code>     | <code v-pre>entity</code> | Does nothing for one with no live body, which is the answer every control here gives.                                                                                                      |
| <code v-pre>number</code>      | <code v-pre>x</code>      | Pixel-scaled impulse along x. Dividing it by the body's mass in kilograms gives the change in velocity in pixels per second, so the same push moves a light body further than a heavy one. |
| <code v-pre>number</code>      | <code v-pre>y</code>      | The same along y, positive downward. Applied at the center of mass, so neither component imparts spin; `applyImpulseAt` is the one that does.                                              |

<a id="tecs.physics.applyImpulseAt"></a>

### tecs.physics.applyImpulseAt

<pre><code v-pre>function <a href="#tecs.physics.applyImpulseAt">tecs.physics.applyImpulseAt</a>(world: types.World, entity: integer, x: number, y: number, pointX: number, pointY: number)
</code></pre>

Applies an impulse at a world-space point, so it spins the body as well as
moving it.

#### Parameters

| Type                           | Name                      | Description                                                                                                                                                                         |
| ------------------------------ | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code>  | The world holding the entity.                                                                                                                                                       |
| <code v-pre>integer</code>     | <code v-pre>entity</code> | Does nothing for one with no live body.                                                                                                                                             |
| <code v-pre>number</code>      | <code v-pre>x</code>      | Pixel-scaled impulse along x, read as `applyImpulse` reads it.                                                                                                                      |
| <code v-pre>number</code>      | <code v-pre>y</code>      | The same along y, positive downward.                                                                                                                                                |
| <code v-pre>number</code>      | <code v-pre>pointX</code> | Where the push lands, in world pixels rather than in the body's frame. The further it is from the center of mass, the more of the impulse becomes spin and the less becomes travel. |
| <code v-pre>number</code>      | <code v-pre>pointY</code> | The same along y. A point at the center of mass makes this exactly `applyImpulse`.                                                                                                  |

<a id="tecs.physics.applyImpulseTo"></a>

### tecs.physics.applyImpulseTo

<pre><code v-pre>function <a href="#tecs.physics.applyImpulseTo">tecs.physics.applyImpulseTo</a>(row: <a href="#tecs.physics.RigidBody">RigidBody</a>, x: number, y: number)
</code></pre>

The same as `applyImpulse`, given a `RigidBody` row already in hand.

For a system walking a column, where going back through the entity
would cost a lookup per body per frame.

#### Parameters

| Type                                                               | Name                   | Description                                                                                                                                                                                                                                     |
| ------------------------------------------------------------------ | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre><a href="#tecs.physics.RigidBody">RigidBody</a></code> | <code v-pre>row</code> | A row read straight off a `RigidBody` column. The null row a snapshot load leaves behind is ignored rather than passed on: Rapier indexes its body array from the slot without checking it, so a null handle reads off the front of that array. |
| <code v-pre>number</code>                                          | <code v-pre>x</code>   | Pixel-scaled impulse along x. Dividing it by the body's mass in kilograms gives the change in velocity in pixels per second.                                                                                                                    |
| <code v-pre>number</code>                                          | <code v-pre>y</code>   | The same along y, positive downward. Applied at the center of mass, so neither component imparts spin.                                                                                                                                          |

<a id="tecs.physics.applyTorque"></a>

### tecs.physics.applyTorque

<pre><code v-pre>function <a href="#tecs.physics.applyTorque">tecs.physics.applyTorque</a>(world: types.World, entity: integer, torque: number)
</code></pre>

Applies torque and wakes the body.

Cleared at the end of every step, like the two forces above.

#### Parameters

| Type                           | Name                      | Description                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------ | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code>  | The world holding the entity.                                                                                                                                                                                                                                                                                                                         |
| <code v-pre>integer</code>     | <code v-pre>entity</code> | Does nothing for one with no live body.                                                                                                                                                                                                                                                                                                               |
| <code v-pre>number</code>      | <code v-pre>torque</code> | Newton-meters, in Rapier's own units. This is the one quantity the module passes through unscaled, because a torque is a force times a distance and so would need `physics.pixelsPerMeter` squared rather than the single factor everything else takes. Positive raises the body's angular velocity, and so the `Transform.rotation` the sync writes. |

<a id="tecs.physics.attach"></a>

### tecs.physics.attach

<pre><code v-pre>function <a href="#tecs.physics.attach">tecs.physics.attach</a>(world: types.World, entity: integer, options: BodyOptions)
</code></pre>

Declares a body on `entity`.

Creation happens at the next fixed step. Keeping it declarative makes the
same path work for spawn, batch spawn, snapshots and debug tools, and no
raw Rapier handle escapes the module.

#### Parameters

| Type                           | Name                       | Description                                                                                                                                                                                                                                                                     |
| ------------------------------ | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code>   | Raises when `physics.plugin` was never added to it, because a body declared into a world with no simulation is components nothing will ever read.                                                                                                                               |
| <code v-pre>integer</code>     | <code v-pre>entity</code>  | Gains `Body` and `Collider`, and `Transform` and `Motion` with them when it has neither, since `Body` requires both. The two sets are deferred together, so this is one archetype move rather than two.                                                                         |
| <code v-pre>BodyOptions</code> | <code v-pre>options</code> | Read once, here. Later changes go through `world:getMut` on `Body` or `Collider`, which the fixed step reapplies to the live body. An unrecognized `type` raises, and so does a `capsuleLength` without a positive `radius`; both blame the caller's line rather than this one. |

<a id="tecs.physics.attachCollider"></a>

### tecs.physics.attachCollider

<pre><code v-pre>function <a href="#tecs.physics.attachCollider">tecs.physics.attachCollider</a>(world: types.World, entity: integer, body: integer, options: BodyOptions)
</code></pre>

Adds another collider to a declared body. The collider is its own entity,
which makes each shape independently inspectable and mutable.

#### Parameters

| Type                           | Name                       | Description                                                                                                                                                                                                                                                 |
| ------------------------------ | -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code>   | Not checked for a simulation, unlike `attach`: the body named below cannot have been declared without one.                                                                                                                                                  |
| <code v-pre>integer</code>     | <code v-pre>entity</code>  | The collider's own entity, which gains `Collider` and `ColliderOf`. It is not the body, carries no pose of its own, and is placed by the shape's offset within the body's frame. `ColliderOf` is cascade-deleted, so despawning the body despawns this too. |
| <code v-pre>integer</code>     | <code v-pre>body</code>    | The entity to attach to. Raises when it has no `Body`, which includes the case of a body already detached. Its live shape need not exist yet: a collider declared in the same frame as its body waits and is created after it, in the same fixed step.      |
| <code v-pre>BodyOptions</code> | <code v-pre>options</code> | Only the shape, material, filter and offset fields are read. `type`, damping, gravity and the sleep and bullet flags belong to the body and are ignored here.                                                                                               |

<a id="tecs.physics.detach"></a>

### tecs.physics.detach

<pre><code v-pre>function <a href="#tecs.physics.detach">tecs.physics.detach</a>(world: types.World, entity: integer)
</code></pre>

Removes a body's declaration. Its native body is destroyed at the next
fixed step.

#### Parameters

| Type                           | Name                      | Description                                                                                                                                                                               |
| ------------------------------ | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code>  | The world holding the entity. Not checked for a simulation: removing a component from a world that never had one is harmless.                                                             |
| <code v-pre>integer</code>     | <code v-pre>entity</code> | Loses `Body` only. `Collider`, `Motion` and `Transform` stay, so what the body was is still readable and `attach` can declare it again. Not an error for an entity that never had a body. |

<a id="tecs.physics.hasBody"></a>

### tecs.physics.hasBody

<pre><code v-pre>function <a href="#tecs.physics.hasBody">tecs.physics.hasBody</a>(world: types.World, entity: integer): boolean
</code></pre>

Whether `entity` has a body Rapier is still solving.

False for an entity whose RigidBody came out of a snapshot. A load
restores the row as the null handle rather than a body id this run never
issued, so this is how a game tells "was simulating and is not any more"
from "never had a body", and the two are worth telling apart: nothing
rebuilds a body on load.

#### Parameters

| Type                           | Name                      | Description                                                                   |
| ------------------------------ | ------------------------- | ----------------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code>  | The world holding the entity.                                                 |
| <code v-pre>integer</code>     | <code v-pre>entity</code> | Any entity. One with no `RigidBody` at all answers false rather than raising. |

#### Returns

| Type                       | Description                                                                                                                                                                                                                                                                 |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | False for the whole window between `attach` and the fixed step that acts on it, so this is not a way to check a declaration landed. False too for a handle whose world has since been destroyed, because the check covers the generation and the world as well as the slot. |

<a id="tecs.physics.isAwake"></a>

### tecs.physics.isAwake

<pre><code v-pre>function <a href="#tecs.physics.isAwake">tecs.physics.isAwake</a>(world: types.World, entity: integer): boolean
</code></pre>

Whether Rapier currently considers the body awake.

#### Parameters

| Type                           | Name                      | Description                                                                                                    |
| ------------------------------ | ------------------------- | -------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code>  | The world holding the entity.                                                                                  |
| <code v-pre>integer</code>     | <code v-pre>entity</code> | Any entity. One with no live body answers false rather than raising, so this does not tell asleep from absent. |

#### Returns

| Type                       | Description                                                                                                                                       |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>boolean</code> | Whether the body is still being solved. Bodies sleep as an island rather than one at a time, so a body at rest touching a moving one stays awake. |

<a id="tecs.physics.of"></a>

### tecs.physics.of

<pre><code v-pre>function <a href="#tecs.physics.of">tecs.physics.of</a>(world: types.World): World
</code></pre>

The simulation installed into `world`, or nil when none has been.

What lets something holding only the ECS world reach the Rapier one, which
is what the debug tools have and what a game writing its own systems often
has too.

#### Parameters

| Type                           | Name                     | Description                                                                                                                                              |
| ------------------------------ | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code> | A world with or without the plugin. A world without one is not an error here, which is what makes this the test for whether physics is installed at all. |

#### Returns

| Type                     | Description                                                                                                                                                                                           |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>World</code> | The world's own live simulation, not a copy, so stepping or destroying what comes back acts on the one the plugin's systems drive. Nil before the plugin is added and again after `Shutdown` has run. |

<a id="tecs.physics.pixelsPerMeter"></a>

### tecs.physics.pixelsPerMeter

<pre><code v-pre><a href="#tecs.physics.pixelsPerMeter">tecs.physics.pixelsPerMeter</a>: number
</code></pre>

Pixels per simulated meter, and the conversion every public number on
this module has already had applied to it. Multiply meters by it,
divide pixels by it. Named for the units rather than `scale`, which
says neither what is being converted nor which way round it goes, and
a caller guessing wrong is off by a factor of a thousand with nothing
to raise.

<a id="tecs.physics.plugin"></a>

### tecs.physics.plugin

<pre><code v-pre>function <a href="#tecs.physics.plugin">tecs.physics.plugin</a>(options: PhysicsOptions): function(types.World)
</code></pre>

Installs the simulation and its sync.

#### Parameters

| Type                              | Name                       | Description                                                                                                                                                                                         |
| --------------------------------- | -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>PhysicsOptions</code> | <code v-pre>options</code> | May be nil, which takes Earth-like gravity downward and Rapier's own substep count. Read when the plugin is built rather than when it is added, so one plugin added to two worlds sizes both alike. |

#### Returns

| Type                                     | Description                                                                                                                                                                                                                                                                                                |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>function(types.World)</code> | A plugin to hand to `world:addPlugin`. Adding it to a second world gives that world a Rapier world of its own, and neither sees the other's bodies; the solver's threads go the other way and are shared, so a second world naming a `workerCount` the first did not raises rather than resizing the pool. |

<a id="tecs.physics.raycast"></a>

### tecs.physics.raycast

<pre><code v-pre>function <a href="#tecs.physics.raycast">tecs.physics.raycast</a>(world: types.World, x1: number, y1: number, x2: number, y2: number, options: QueryOptions): RaycastHit
</code></pre>

Casts a segment and returns its nearest collider, in pixels.

A segment rather than a ray: nothing beyond `x2, y2` is tested, so a cast
that finds nothing may only have been too short.

#### Parameters

| Type                            | Name                       | Description                                                                                                          |
| ------------------------------- | -------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World</code>  | <code v-pre>world</code>   | Answers nil when it has no simulation, which is the same answer a clean miss gives.                                  |
| <code v-pre>number</code>       | <code v-pre>x1</code>      | The start of the segment, in world pixels.                                                                           |
| <code v-pre>number</code>       | <code v-pre>y1</code>      | The same along y, positive downward.                                                                                 |
| <code v-pre>number</code>       | <code v-pre>x2</code>      | The end of the segment, in world pixels.                                                                             |
| <code v-pre>number</code>       | <code v-pre>y2</code>      | The same along y.                                                                                                    |
| <code v-pre>QueryOptions</code> | <code v-pre>options</code> | May be nil, which tests every shape. Sensors are included: the filter is the only thing that keeps a ray out of one. |

#### Returns

| Type                          | Description                                                                                                                                                                        |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>RaycastHit</code> | The nearest hit along the segment, or nil when the ray met nothing. A fresh table each call, so it is the caller's to keep, and a cast in a per-frame loop allocates one per call. |

<a id="tecs.physics.setAngularVelocity"></a>

### tecs.physics.setAngularVelocity

<pre><code v-pre>function <a href="#tecs.physics.setAngularVelocity">tecs.physics.setAngularVelocity</a>(world: types.World, entity: integer, omega: number)
</code></pre>

Sets angular velocity in radians per second and wakes the body.

#### Parameters

| Type                           | Name                      | Description                                                                                                                                                                                             |
| ------------------------------ | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code>  | The world holding the entity.                                                                                                                                                                           |
| <code v-pre>integer</code>     | <code v-pre>entity</code> | Does nothing for one with no live body.                                                                                                                                                                 |
| <code v-pre>number</code>      | <code v-pre>omega</code>  | Radians per second, set outright rather than added to. Discarded by Rapier for a static body and for one declared with `fixedRotation`, so those two read back zero rather than the value just written. |

<a id="tecs.physics.setAwake"></a>

### tecs.physics.setAwake

<pre><code v-pre>function <a href="#tecs.physics.setAwake">tecs.physics.setAwake</a>(world: types.World, entity: integer, awake: boolean)
</code></pre>

Wakes or sleeps a body.

#### Parameters

| Type                           | Name                      | Description                                                                                                                                                                         |
| ------------------------------ | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code>  | The world holding the entity.                                                                                                                                                       |
| <code v-pre>integer</code>     | <code v-pre>entity</code> | Does nothing for one with no live body.                                                                                                                                             |
| <code v-pre>boolean</code>     | <code v-pre>awake</code>  | True wakes it. False puts it to sleep at once rather than waiting for it to come to rest, so a body still moving stops where it is until something touches it or it is woken again. |

<a id="tecs.physics.setVelocity"></a>

### tecs.physics.setVelocity

<pre><code v-pre>function <a href="#tecs.physics.setVelocity">tecs.physics.setVelocity</a>(world: types.World, entity: integer, vx: number, vy: number)
</code></pre>

Sets a body's velocity, in pixels per second, and wakes it.

Does nothing for an entity with no live body, which is the same answer
`physics.velocity` gives for one: a null handle indexes Rapier's body array
without being checked, so it never reaches Rapier.

#### Parameters

| Type                           | Name                      | Description                                                                                                                                                                                         |
| ------------------------------ | ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code>  | The world holding the entity.                                                                                                                                                                       |
| <code v-pre>integer</code>     | <code v-pre>entity</code> | Does nothing for one with no live body.                                                                                                                                                             |
| <code v-pre>number</code>      | <code v-pre>vx</code>     | Pixels per second along x, set outright rather than added to. Discarded by Rapier for a static body, which reads back zero.                                                                         |
| <code v-pre>number</code>      | <code v-pre>vy</code>     | The same along y, positive downward. Angular velocity is left alone, and the `Motion` column is not written: it is a store for pauses and saves, so it still holds whatever the last of those left. |

<a id="tecs.physics.teleport"></a>

### tecs.physics.teleport

<pre><code v-pre>function <a href="#tecs.physics.teleport">tecs.physics.teleport</a>(world: types.World, entity: integer, x: number, y: number, angle: number)
</code></pre>

Teleports a body and immediately updates its Transform.

A move rather than a push: velocity is left exactly as it was, so a falling
body carries on falling from wherever it lands.

`PreviousTransform` is not moved with it. That column is snapshotted in
`FixedFirst` and the renderer interpolates from it, so a teleport in any
phase after that is drawn as one frame of travel between the two positions
rather than as a jump. Teleporting before `FixedFirst`, or accepting the
one frame, are the two ways round it.

#### Parameters

| Type                           | Name                      | Description                                                                                                                                                                                                                                 |
| ------------------------------ | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code>  | The world holding the entity.                                                                                                                                                                                                               |
| <code v-pre>integer</code>     | <code v-pre>entity</code> | Does nothing at all for one with no live body, `Transform` included, so this is not a way to move an entity physics is not simulating.                                                                                                      |
| <code v-pre>number</code>      | <code v-pre>x</code>      | Where to put the body's origin, in world pixels. This is the pose the shapes are placed relative to, not the center of mass, so an offset collider lands offset.                                                                            |
| <code v-pre>number</code>      | <code v-pre>y</code>      | The same along y, positive downward.                                                                                                                                                                                                        |
| <code v-pre>number</code>      | <code v-pre>angle</code>  | Radians. Nil keeps the entity's current `Transform.rotation`, which is what makes this usable as a move that does not turn anything. Nothing sweeps the gap: a body put across a wall is through it, and a bullet body does not catch that. |

<a id="tecs.physics.velocity"></a>

### tecs.physics.velocity

<pre><code v-pre>function <a href="#tecs.physics.velocity">tecs.physics.velocity</a>(world: types.World, entity: integer): number, number
</code></pre>

Reads a body's velocity, live from Rapier, in pixels per second.

Pixels, like every other number this module takes and returns: the extents
and radius `attach` is given, the impulse components, and the plugin's
gravity. A caller that wants meters divides by `physics.pixelsPerMeter`.

This rather than the `Motion` column is what a body is doing right now.
`Motion` is a store written at a pause and a save, not a mirror.

#### Parameters

| Type                           | Name                      | Description                                                                                                                                                            |
| ------------------------------ | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>types.World</code> | <code v-pre>world</code>  | The world holding the entity.                                                                                                                                          |
| <code v-pre>integer</code>     | <code v-pre>entity</code> | An entity with no live body reads as stopped rather than raising, so a caller cannot tell that case from a body genuinely at rest; `hasBody` is what tells them apart. |

#### Returns

| Type                      | Description                                                                                                                                                         |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <code v-pre>number</code> | X in pixels per second, then y, positive downward. Linear only: a body that is only spinning reads zero on both, and `physics.angularVelocity` is where that shows. |
| <code v-pre>number</code> |                                                                                                                                                                     |
