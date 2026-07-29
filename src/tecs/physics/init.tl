--[=[
Rapier 2D as part of the world.

Install the plugin, spawn an entity with a
[`Transform`](/modules/ecs/#tecs.ecs.Transform), and attach a body:

```teal
world:addPlugin(tecs.physics.plugin({gravity = {0.0, 980.0}}))

local ground <const> = world:spawn(tecs.Transform(320, 460))
tecs.physics.attach(world, ground, {["type"] = "static", halfWidth = 320, halfHeight = 20})

local crate <const> = world:spawn(tecs.Transform(320, 100))
tecs.physics.attach(world, crate, {halfWidth = 16, halfHeight = 16, friction = 0.4})

tecs.physics.applyImpulse(world, crate, 400.0, 0.0)
```

The solver writes each body's [`Transform`](/modules/ecs/#tecs.ecs.Transform) back, so
nothing else has to move the entity. `detach` takes a body out of the solve
without despawning its entity.

Public positions, extents, linear velocities, impulses, forces, and gravity
use pixels. Angles and angular velocities use radians. Rapier solves in
meters through the `pixelsPerMeter` conversion.

[`Body`](tealdoc:tecs.physics.Body) and
[`Collider`](tealdoc:tecs.physics.Collider) declare what the game requested.
[`Motion`](tealdoc:tecs.physics.Motion) preserves simulation state across
pauses. Engine-owned [`RigidBody`](tealdoc:tecs.physics.RigidBody) keeps the
attachment visible to tools; ordinary game code should ignore it. A secondary
collider lives on its own entity and relates back through
[`ColliderOf`](/modules/physics/#tecs.physics.ColliderOf).

`FixedUpdate` steps each ECS world's simulation from `physics.of`. A fixed
timestep makes replay and snapshot continuation deterministic, and snapshots
preserve the complete Rapier state.
]=]

-- Implementation details:
-- Body descriptions live in component columns instead of a side table. That
-- lets snapshots, queries, debug tools, and batch spawning use the same data
-- model. Body and collider fields use separate components because they have
-- different owners and lifetimes, and one body may carry several shapes.
--
-- Each ECS world owns a Rapier world. The solver thread pool is process-wide,
-- while worlds step serially on the game thread.

local ecs <const> = require("tecs.ecs")
local type types = require("tecs.types")
local loader <const> = require("tecs.ffi.loader")
local World <const> = require("tecs.physics.World")
local type Handle = World.Handle
local components <const> = require("tecs.components")
local timing <const> = require("tecs.timing")
local table_clear <const> = require("table.clear")

local atan2 <const> = math.atan2

local Transform <const> = ecs.Transform

local type Component = ecs.Component

--- Pixels per simulated meter.
---
--- The conversion keeps game coordinates in pixels and solver coordinates in
--- meter-sized values.
local PIXELS_PER_METER <const> = 32.0

--- Body kinds, matching the Rust bridge and `World.tl`'s own map.
---
--- The integer is what the column holds. The string form stays on the options
--- table a game writes, so a query over bodies never compares strings.
local BODY_KINDS <const>: {string: integer} = {
    static = 0,
    kinematic = 1,
    dynamic = 2,
}
local BODY_NAMES <const>: {integer: string} = {
    [0] = "static",
    [1] = "kinematic",
    [2] = "dynamic",
}

-- Implementation details: Body requires Transform so every Rapier body has a
-- pose, and requires Motion so snapshots never add storage during serialization.

--- `Body` declares a body's simulation behavior.
local record Body is Component
    --- Caller-writable. The caller sets `kind` to 0 for static, 1 for
    --- kinematic or 2 for dynamic through `getMut`. Physics applies the change
    --- during the next fixed update.
    kind: number
    --- Caller-writable. The caller sets `fixedRotation` to 1 to lock rotation
    --- or 0 to unlock it. Physics applies the change during the next fixed
    --- update.
    fixedRotation: number
    --- Caller-writable. The caller sets `isBullet` to 1 for continuous
    --- collision or 0 for discrete collision. Physics applies the change
    --- during the next fixed update.
    isBullet: number
    --- Caller-writable. The caller sets `sleepEnabled` to 1 to permit sleeping
    --- or 0 to keep solving. Physics applies the change during the next fixed
    --- update.
    sleepEnabled: number
    --- Caller-writable. The caller sets `gravityScale` through `getMut`.
    --- Physics applies it during the next fixed update.
    gravityScale: number
    --- Caller-writable. The caller sets `linearDamping` through `getMut`.
    --- Physics applies it during the next fixed update.
    linearDamping: number
    --- Caller-writable. The caller sets `angularDamping` through `getMut`.
    --- Physics applies it during the next fixed update.
    angularDamping: number
end

-- Implementation details: one shape discriminant keeps all colliders in one
-- component, and its 32-bit filters match Rapier collision groups.

--- `Collider` declares a body's geometry, material and collision filtering.
--- Write its fields through `getMut`; physics applies changes during the next
--- fixed update.
local record Collider is Component
    --- Caller-writable. The caller sets `shape` to 0 for box, 1 for circle or 2
    --- for capsule through `getMut`. Physics applies the change during the next
    --- fixed update.
    shape: number
    --- Caller-writable. The caller sets `halfWidth` in pixels for a box.
    halfWidth: number
    --- Caller-writable. The caller sets `halfHeight` in pixels for a box.
    halfHeight: number
    --- Caller-writable. The caller sets `radius` in pixels for a circle or
    --- capsule.
    radius: number
    --- Caller-writable. The caller sets `length` to the pixel distance between
    --- capsule end centers.
    length: number
    --- Caller-writable. The caller sets `offsetX` in body-frame pixels.
    offsetX: number
    --- Caller-writable. The caller sets `offsetY` in body-frame pixels.
    offsetY: number
    --- Caller-writable. The caller sets `density` as mass per unit area.
    density: number
    --- Caller-writable. The caller sets `friction` as Coulomb friction.
    friction: number
    --- Caller-writable. The caller sets `restitution` for bounce.
    restitution: number
    --- Caller-writable. The caller sets `categoryBits` to the shape's
    --- collision categories.
    categoryBits: number
    --- Caller-writable. The caller sets `maskBits` to categories this shape
    --- may contact.
    maskBits: number
    --- Caller-writable. The caller sets `isSensor` to 1 for overlap events
    --- without collision response, or 0 for a solid shape.
    isSensor: number
end

--- Collider shape kinds, matching `Collider.shape`.
local COLLIDER_SHAPES <const>: {string: integer} = {
    box = 0,
    circle = 1,
    capsule = 2,
}

-- Implementation details: Motion stores pause and snapshot state instead of
-- mirroring every body each step, which avoids a full-column dirty write.

--- `Motion` preserves a body's saved velocity in pixels and radians per second.
local record Motion is Component
    --- Read-only. Physics stores horizontal velocity in pixels per second
    --- during pause, snapshot and restore operations. Use `velocity` for live
    --- state.
    vx: number
    --- Read-only. Physics stores vertical velocity in pixels per second with
    --- `vx`.
    vy: number
    --- Read-only. Physics stores angular velocity in radians per second with
    --- `vx`.
    omega: number
end

ecs.newFFIComponent(
    {
        name = "Motion",
        container = Motion,
        fields = {
            {"vx", "float"},
            {"vy", "float"},
            {"omega", "float"},
        },
        defaults = {0, 0, 0},
    }
)

ecs.newFFIComponent(
    {
        name = "Body",
        container = Body,
        requires = {Transform, Motion},
        fields = {
            {"kind", "uint8_t"},
            {"fixedRotation", "uint8_t"},
            {"isBullet", "uint8_t"},
            {"sleepEnabled", "uint8_t"},
            {"gravityScale", "float"},
            {"linearDamping", "float"},
            {"angularDamping", "float"},
        },
        defaults = {BODY_KINDS.dynamic, 0, 0, 1, 1.0, 0.0, 0.0},
    }
)

ecs.newFFIComponent(
    {
        name = "Collider",
        container = Collider,
        fields = {
            {"shape", "uint8_t"},
            {"halfWidth", "float"},
            {"halfHeight", "float"},
            {"radius", "float"},
            {"length", "float"},
            {"offsetX", "float"},
            {"offsetY", "float"},
            {"density", "float"},
            {"friction", "float"},
            {"restitution", "float"},
            {"categoryBits", "uint32_t"},
            {"maskBits", "uint32_t"},
            {"isSensor", "uint8_t"},
        },
        -- Geometry, material, filtering, and sensor defaults.
        defaults = {
            COLLIDER_SHAPES.box,
            8.0,
            8.0,
            0.0,
            0.0,
            0.0,
            0.0,
            1.0,
            0.6,
            0.0,
            1,
            0xFFFFFFFF,
            0,
        },
    }
)

--- A `RigidBody` identifies one live body in a Rapier simulation.
---
--- Engine-owned and transient. Ordinary game code should use
--- [`Body`](tealdoc:tecs.physics.Body),
--- [`Motion`](tealdoc:tecs.physics.Motion), and the functions on
--- `tecs.physics`.
local record RigidBody is Component
    --- Engine-owned. Identifies the body slot; ordinary game code should
    --- ignore it.
    index1: number
    --- Engine-owned. Identifies the simulation; ordinary game code should
    --- ignore it.
    world0: number
    --- Engine-owned. Rejects stale body slots; ordinary game code should
    --- ignore it.
    generation: number
end

ecs.newFFIComponent(
    {
        name = "RigidBody",
        container = RigidBody,
        fields = {
            {"index1", "int32_t"},
            {"world0", "uint16_t"},
            {"generation", "uint32_t"},
        },
        defaults = {0, 0, 0},
        transient = true,
    }
)

--- Engine-owned and transient. Marks a paused body after the solver changes it
--- to static and stores its motion.
local record PhysicsHeld is Component
end
ecs.newComponent({name = "PhysicsHeld", container = PhysicsHeld, transient = true})

local record PhysicsDisabled is Component
end
ecs.newComponent({name = "PhysicsDisabled", container = PhysicsDisabled, transient = true})

--- The live shape owned by a secondary collider entity.
local record ColliderShape is Component
    index1: number
    world0: number
    generation: number
end
ecs.newFFIComponent(
    {
        name = "ColliderShape",
        container = ColliderShape,
        fields = {
            {"index1", "int32_t"},
            {"world0", "uint16_t"},
            {"generation", "uint32_t"},
        },
        defaults = {0, 0, 0},
        transient = true,
    }
)

--- A secondary collider's owning body. The relationship is sparse so adding
--- shapes does not split body archetypes, reverse-indexed for inspection, and
--- cascade-deleted with the body.
local ColliderOf <const> = ecs.newRelationship(
    {
        name = "ColliderOf",
        exclusive = true,
        sparse = true,
        reverseIndex = true,
        cascadeDelete = true,
    }
)

--- `BodyOptions` describes one complete body or secondary collider declaration.
---
--- `attachCollider` reads only the shape, material, filter and offset fields.
--- It ignores body-level fields because a secondary collider has no damping
--- or gravity of its own.
local record BodyOptions
    --- Caller-writable. The caller sets `type` before `attach` reads it to
    --- `"static"`, `"kinematic"` or `"dynamic"`. It defaults to dynamic, and an
    --- unrecognized string raises.
    type: string
    --- Caller-writable. The caller sets `halfWidth` in pixels before `attach`
    --- reads it. A 32-pixel square uses 16. It defaults to 8.
    halfWidth: number
    --- Caller-writable. The caller sets `halfHeight` in pixels with
    --- `halfWidth`. It defaults to 8.
    halfHeight: number
    --- Caller-writable. The caller sets `radius` in pixels before `attach`
    --- reads it. Naming it selects a circle over box extents. A capsule
    --- requires a positive value.
    radius: number
    --- Caller-writable. The caller sets `density` as mass per unit area before
    --- `attach` reads it. It defaults to Rapier's 1.0. Rapier treats zero mass
    --- as infinite mass.
    density: number
    --- Caller-writable. The caller sets `friction` before `attach` reads it. It
    --- defaults to Rapier's 0.6. A contact takes the
    --- geometric mean of the two shapes', so zero on either one is a
    --- frictionless slide however rough the other is.
    friction: number
    --- Caller-writable. The caller sets `restitution` before `attach` reads it.
    --- It defaults to Rapier's 0.0. One produces a perfectly elastic bounce,
    --- and above one a body gains energy on every contact. A contact takes the
    --- larger of the two shapes', so the bouncier surface decides and a
    --- deadened one cannot damp it.
    restitution: number
    --- Caller-writable. The caller sets `fixedRotation` before `attach` reads
    --- it. True locks the angle; it defaults to false.
    fixedRotation: boolean
    --- Caller-writable. The caller sets `gravityScale` before `attach` reads
    --- it. It defaults to 1. Zero
    --- floats, and negative falls upward.
    gravityScale: number
    --- Caller-writable. The caller sets `linearDamping` before `attach` reads
    --- it. It defaults to 0 and uses Rapier's damping term.
    linearDamping: number
    --- Caller-writable. The caller sets `angularDamping` before `attach` reads
    --- it. It defaults to 0 and uses Rapier's damping term.
    angularDamping: number
    --- Caller-writable. The caller sets `sleepEnabled` before `attach` reads
    --- it. It defaults to true, and
    --- only an explicit false disables it. Rapier stops solving a sleeping
    --- body until contact or an explicit wake.
    sleepEnabled: boolean
    --- Caller-writable. The caller sets `isBullet` before `attach` reads it to
    --- enable continuous collision. It defaults to false.
    isBullet: boolean
    --- Caller-writable. The caller sets `categoryBits` before `attach` reads
    --- it. It defaults to 1 and uses the low 32 Rapier collision-group bits.
    categoryBits: number
    --- Caller-writable. The caller sets `maskBits` before `attach` reads it. It
    --- defaults to every category. Two shapes touch only when each mask names
    --- the other category.
    maskBits: number
    --- Caller-writable. The caller sets `isSensor` before `attach` reads it.
    --- True reports overlap events without collision response. It defaults to
    --- false.
    isSensor: boolean
    --- Caller-writable. The caller sets `offsetX` in body-frame pixels before
    --- `attach` reads it, so it turns with the body. It defaults to 0.
    offsetX: number
    --- Caller-writable. The caller sets `offsetY` with `offsetX` before
    --- `attach` reads it. It defaults to 0.
    offsetY: number
    --- Caller-writable. The caller sets `capsuleLength` before `attach` reads
    --- it. It selects a vertical capsule and gives the distance between end
    --- centers, excluding the caps. `radius` supplies the positive cap radius.
    capsuleLength: number
end

--- `QueryOptions` filters the shapes a raycast may hit.
local record QueryOptions
    --- Caller-writable. The caller sets `categoryBits` before `raycast` reads
    --- it. It defaults to all categories. The ray skips a shape whose mask
    --- excludes every ray category.
    categoryBits: number
    --- Caller-writable. The caller sets `maskBits` before `raycast` reads it.
    --- It defaults to all categories.
    maskBits: number
end

--- `RaycastHit` reports where a ray first met a collider.
local record RaycastHit
    --- Read-only. `raycast` sets `entity` to the shape owner. A secondary
    --- collider reports its own entity rather than its body's.
    entity: integer
    --- Read-only. `raycast` sets `x` to the contact point in world pixels.
    x: number
    --- Read-only. `raycast` sets `y` with `x`, positive downward.
    y: number
    --- Read-only. `raycast` sets `normalX` to the outward unit normal. It does
    --- not scale this value to pixels.
    normalX: number
    --- Read-only. `raycast` sets `normalY` with `normalX`.
    normalY: number
    --- Read-only. `raycast` sets `fraction` from 0 at the segment start to 1 at
    --- the segment end.
    fraction: number
end

local record PendingCreation
    entity: integer
    transform: Transform
    body: Body
    collider: Collider
    motion: Motion
end

local record PendingShape
    entity: integer
    owner: integer
    collider: Collider
end

--- `ContactBegin` reports the start of contact between two bodies.
local record ContactBegin is ecs.Event
    --- Read-only. Physics sets `entityA` to one contact body before emitting
    --- the event.
    entityA: integer
    --- Read-only. Physics sets `entityB` to the other contact body.
    entityB: integer
end
--- `ContactEnd` reports the end of contact between two bodies.
local record ContactEnd is ecs.Event
    --- Read-only. Physics sets `entityA` to one former contact body before
    --- emitting the event.
    entityA: integer
    --- Read-only. Physics sets `entityB` to the other former contact body.
    entityB: integer
end
--- `SensorBegin` reports a body entering a sensor.
local record SensorBegin is ecs.Event
    --- Read-only. Physics sets `sensor` to the sensor entity before emitting
    --- the event.
    sensor: integer
    --- Read-only. Physics sets `visitor` to the entering entity.
    visitor: integer
end
--- `SensorEnd` reports a body leaving a sensor.
local record SensorEnd is ecs.Event
    --- Read-only. Physics sets `sensor` to the sensor entity before emitting
    --- the event.
    sensor: integer
    --- Read-only. Physics sets `visitor` to the leaving entity.
    visitor: integer
end

--- `PhysicsOptions` configures a Rapier world before plugin installation.
local record PhysicsOptions
    --- Caller-writable. The caller sets `gravity` before the plugin reads it.
    --- It contains x then y in pixels per second squared and defaults to 980
    --- downward.
    gravity: {number}
    --- Caller-writable. The caller sets `subStepCount` before plugin
    --- installation. It defaults to Rapier's 4.
    subStepCount: integer
    --- Caller-writable. The caller sets `workerCount` before the first physics
    --- world initializes the process-wide Rapier pool. Later worlds must use
    --- the same value.
    workerCount: integer
end

local record physics
    --- Engine-owned. [`RigidBody`](tealdoc:tecs.physics.RigidBody) exposes live
    --- attachment state for tools.
    --- Ordinary game code ignores it.
    RigidBody: RigidBody
    --- Read-only. [`Body`](tealdoc:tecs.physics.Body) names the caller-writable
    --- body component.
    Body: Body
    --- Read-only. [`Collider`](tealdoc:tecs.physics.Collider) names the
    --- caller-writable collider component.
    Collider: Collider
    --- Read-only. [`ColliderOf`](/modules/physics/#tecs.physics.ColliderOf) relates a
    --- secondary collider to its owning body.
    ColliderOf: Component
    --- Read-only. [`Motion`](tealdoc:tecs.physics.Motion) names the
    --- engine-updated pause and snapshot state.
    Motion: Motion
    --- Read-only. `ContactBegin` names the contact-start event.
    ContactBegin: ContactBegin
    --- Read-only. `ContactEnd` names the contact-end event.
    ContactEnd: ContactEnd
    --- Read-only. `SensorBegin` names the sensor-enter event.
    SensorBegin: SensorBegin
    --- Read-only. `SensorEnd` names the sensor-exit event.
    SensorEnd: SensorEnd
    --- Read-only. `pixelsPerMeter` reports the fixed conversion between public
    --- pixels and Rapier meters.
    pixelsPerMeter: number

    --- Applies a center-of-mass impulse to a
    --- [`RigidBody`](tealdoc:tecs.physics.RigidBody) row.
    ---
    --- @param row The caller supplies a row from a
    ---     [`RigidBody`](tealdoc:tecs.physics.RigidBody) column. A stale or null
    ---     row does nothing.
    --- @param x The caller supplies pixel-scaled impulse along x.
    --- @param y The caller supplies pixel-scaled impulse along y, positive
    ---     downward.
    applyImpulseTo: function(row: RigidBody, x: number, y: number)
end

physics.RigidBody = RigidBody
physics.Body = Body
physics.Collider = Collider
physics.ColliderOf = ColliderOf
physics.Motion = Motion
physics.ContactBegin = ContactBegin
physics.ContactEnd = ContactEnd
physics.SensorBegin = SensorBegin
physics.SensorEnd = SensorEnd
physics.pixelsPerMeter = PIXELS_PER_METER

ContactBegin.init = function(event: ContactBegin, a: integer, b: integer) event.entityA, event.entityB = a, b end
ContactEnd.init = function(event: ContactEnd, a: integer, b: integer) event.entityA, event.entityB = a, b end
SensorBegin.init = function(event: SensorBegin, sensor: integer, visitor: integer)
    event.sensor, event.visitor = sensor, visitor
end
SensorEnd.init = function(event: SensorEnd, sensor: integer, visitor: integer)
    event.sensor, event.visitor = sensor, visitor
end
ecs.newEvent(ContactBegin)
ecs.newEvent(ContactEnd)
ecs.newEvent(SensorBegin)
ecs.newEvent(SensorEnd)

-- Implementation details:
-- The context key stores a world's simulation. Debug tools and snapshots use
-- this stable name, while physics.of keeps the storage private.
local simulationKey <const> = ecs.newKey("tecs.physics", nil as World)

--- Returns the Rapier simulation installed in `world`.
---
--- @param world The caller supplies a world with or without the plugin.
--- @return Returns the world's live Rapier simulation, or nil before
---     installation and after shutdown.
function physics.of(world: types.World): World
    return world.resources[simulationKey]
end

local function toMeters(pixels: number): number
    return pixels / PIXELS_PER_METER
end

local function toPixels(meters: number): number
    return meters * PIXELS_PER_METER
end

local function colliderFrom(options: BodyOptions): Collider
    local shape = COLLIDER_SHAPES.box
    if options.capsuleLength ~= nil then
        shape = COLLIDER_SHAPES.capsule
        if options.radius == nil or options.radius <= 0 then
            error("tecs: a capsule needs a positive radius", 3)
        end
    elseif options.radius ~= nil then
        shape = COLLIDER_SHAPES.circle
    end
    return Collider(
        shape,
        options.halfWidth or 8.0,
        options.halfHeight or 8.0,
        options.radius or 0.0,
        options.capsuleLength or 0.0,
        options.offsetX or 0.0,
        options.offsetY or 0.0,
        options.density,
        options.friction,
        options.restitution,
        options.categoryBits or 1,
        options.maskBits or 0xFFFFFFFF,
        options.isSensor and 1 or 0
    )
end

--- Declares a body on `entity`.
---
--- Physics creates the Rapier body during the next fixed update.
---
--- @param world The caller supplies a world with `physics.plugin`; otherwise
---     the call raises.
--- @param entity The caller supplies the entity that gains
---     [`Body`](tealdoc:tecs.physics.Body),
---     [`Collider`](tealdoc:tecs.physics.Collider),
---     [`Transform`](/modules/ecs/#tecs.ecs.Transform), and
---     [`Motion`](tealdoc:tecs.physics.Motion) as needed.
--- @param options The caller supplies the initial body and collider settings.
---     Unknown body types and invalid capsules raise.
function physics.attach(world: types.World, entity: integer, options: BodyOptions)
    options = options or {}

    if physics.of(world) == nil then
        error("tecs: this world has no physics simulation; add physics.plugin to it first", 2)
    end

    local kind = BODY_KINDS[options.type or "dynamic"]
    if kind == nil then
        error(("tecs: unknown body type %q; expected static, kinematic or dynamic"):format(options.type), 2)
    end
    world:defer()
    world:set(
        entity,
        Body(
            kind,
            options.fixedRotation and 1 or 0,
            options.isBullet and 1 or 0,
            options.sleepEnabled == false and 0 or 1,
            options.gravityScale or 1.0,
            options.linearDamping or 0.0,
            options.angularDamping or 0.0
        )
    )
    world:set(entity, colliderFrom(options))
    world:commit()
end

--- Adds another collider to a declared body. The collider is its own entity,
--- which makes each shape independently inspectable and mutable.
---
--- @param world The caller supplies the world that owns both entities.
--- @param entity The caller supplies the secondary collider entity, which
---     gains [`Collider`](tealdoc:tecs.physics.Collider) and
---     [`ColliderOf`](/modules/physics/#tecs.physics.ColliderOf).
--- @param body The caller supplies an entity with
---     [`Body`](tealdoc:tecs.physics.Body); otherwise the call raises.
--- @param options The caller supplies shape, material, filter and offset
---     settings. Body-level fields have no effect.
function physics.attachCollider(world: types.World, entity: integer, body: integer, options: BodyOptions)
    options = options or {}
    if world:get(body, Body) == nil then
        error("tecs: ColliderOf target has no Body", 2)
    end
    world:defer()
    world:set(entity, colliderFrom(options))
    world:set(entity, ColliderOf(body))
    world:commit()
end

--- Removes a body's declaration. Physics destroys its Rapier body during the
--- next fixed update.
---
--- @param world The caller supplies the world holding the entity.
--- @param entity The caller supplies the entity that loses
---     [`Body`](tealdoc:tecs.physics.Body). Other physics declaration
---     components remain.
function physics.detach(world: types.World, entity: integer)
    world:remove(entity, Body)
end

-- One handle for the lifetime of the process. The sync rebuilds a handle per
-- body per step, so allocating here would put a GC allocation in the hottest
-- loop physics has.
--- Rebuilds a Rapier handle from a stored RigidBody row.
local function handleOf(row: RigidBody): Handle
    return World.wrapHandle((row.index1 as integer) - 1, row.generation as integer, row.world0 as integer)
end

local function shapeOf(row: ColliderShape): Handle
    return World.wrapHandle((row.index1 as integer) - 1, row.generation as integer, row.world0 as integer)
end

--- Returns whether Rapier is still solving a body for `entity`.
---
--- False for an entity whose RigidBody came out of a snapshot. A load
--- restores the row as the null handle rather than a body id this run never
--- issued, so this is how a game tells "was simulating and is not any more"
--- from "never had a body", and the two are worth telling apart: nothing
--- rebuilds a body on load.
---
--- @param world The caller supplies the world holding the entity.
--- @param entity The caller supplies any entity.
--- @return Returns true only while Rapier holds a valid live body. It returns
---     false before the first fixed update and after destruction.
function physics.hasBody(world: types.World, entity: integer): boolean
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return false
    end
    -- Rapier's own check, which covers the generation and the world as well
    -- as the slot, so a handle left over from a destroyed world answers
    -- false rather than addressing whatever took its place.
    return World.isBodyValid(handleOf(row))
end

--- Pushes a body once, at its center of mass.
---
--- An impulse rather than a force, so the effect does not depend on how long
--- the step happened to be. Wakes the body: Rapier lets a resting island sleep,
--- and pushing a sleeping body without waking it does nothing.
---
--- @param world The caller supplies the world holding the entity.
--- @param entity The caller supplies the target entity. A missing live body
---     makes the call a no-op.
--- @param x The caller supplies pixel-scaled impulse along x.
--- @param y The caller supplies pixel-scaled impulse along y, positive
---     downward.
function physics.applyImpulse(world: types.World, entity: integer, x: number, y: number)
    local row = world:get(entity, RigidBody)
    if row == nil then
        return
    end
    physics.applyImpulseTo(row, x, y)
end

function physics.applyImpulseTo(row: RigidBody, x: number, y: number)
    -- The null handle is what a snapshot load leaves behind, and Rapier
    -- indexes its body array from the slot without checking it, so passing
    -- one through would read off the front of that array.
    if row.index1 == 0 then
        return
    end
    World.applyImpulse(handleOf(row), toMeters(x), toMeters(y))
end

--- Applies an impulse at a world-space point, so it spins the body as well as
--- moving it.
---
--- @param world The caller supplies the world holding the entity.
--- @param entity The caller supplies the target entity. A missing live body
---     makes the call a no-op.
--- @param x The caller supplies pixel-scaled impulse along x.
--- @param y The caller supplies pixel-scaled impulse along y, positive
---     downward.
--- @param pointX The caller supplies the world-pixel impact position along x.
--- @param pointY The caller supplies the world-pixel impact position along y.
function physics.applyImpulseAt(
    world: types.World, entity: integer, x: number, y: number, pointX: number, pointY: number
)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    World.applyImpulseAt(handleOf(row), toMeters(x), toMeters(y), toMeters(pointX), toMeters(pointY))
end

--- Reads a body's velocity, live from Rapier, in pixels per second.
---
--- Pixels match every other linear number this module accepts and returns:
--- extents, radius, impulse components and plugin
--- gravity. A caller that wants meters divides by `physics.pixelsPerMeter`.
---
--- This reports what a body does now. [`Motion`](tealdoc:tecs.physics.Motion)
--- stores velocity only at a pause or save; it does not mirror live motion.
---
--- @param world The caller supplies the world holding the entity.
--- @param entity The caller supplies the target entity.
--- @return Returns horizontal velocity in pixels per second, or zero without a
---     live body.
--- @return Returns vertical velocity in pixels per second, positive downward,
---     or zero without a live body.
function physics.velocity(world: types.World, entity: integer): number, number
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return 0.0, 0.0
    end
    local vx, vy = World.getVelocity(handleOf(row))
    return toPixels(vx), toPixels(vy)
end

--- Sets a body's velocity, in pixels per second, and wakes it.
---
--- Does nothing for an entity with no live body, which matches the zero value
--- returned by `physics.velocity`.
---
--- @param world The caller supplies the world holding the entity.
--- @param entity The caller supplies the target entity. A missing live body
---     makes the call a no-op.
--- @param vx The caller supplies horizontal velocity in pixels per second.
--- @param vy The caller supplies vertical velocity in pixels per second,
---     positive downward.
function physics.setVelocity(world: types.World, entity: integer, vx: number, vy: number)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    World.setVelocity(handleOf(row), toMeters(vx), toMeters(vy))
end

--- Applies a continuous force at the body's center and wakes it.
---
--- Cleared by Rapier at the end of every step, so holding a body up against
--- gravity means calling this every fixed step rather than once.
---
--- @param world The caller supplies the world holding the entity.
--- @param entity The caller supplies the target entity. A missing live body
---     makes the call a no-op.
--- @param x The caller supplies pixel-scaled force along x.
--- @param y The caller supplies pixel-scaled force along y, positive downward.
function physics.applyForce(world: types.World, entity: integer, x: number, y: number)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    World.applyForce(handleOf(row), toMeters(x), toMeters(y))
end

--- Applies a continuous force at a world-space point and wakes the body.
---
--- Cleared at the end of every step, like `applyForce`.
---
--- @param world The caller supplies the world holding the entity.
--- @param entity The caller supplies the target entity. A missing live body
---     makes the call a no-op.
--- @param x The caller supplies pixel-scaled force along x.
--- @param y The caller supplies pixel-scaled force along y, positive downward.
--- @param pointX The caller supplies the world-pixel application point along x.
--- @param pointY The caller supplies the world-pixel application point along y.
function physics.applyForceAt(world: types.World, entity: integer, x: number, y: number, pointX: number, pointY: number)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    World.applyForceAt(handleOf(row), toMeters(x), toMeters(y), toMeters(pointX), toMeters(pointY))
end

--- Applies torque and wakes the body.
---
--- Cleared at the end of every step, like the two forces above.
---
--- @param world The caller supplies the world holding the entity.
--- @param entity The caller supplies the target entity. A missing live body
---     makes the call a no-op.
--- @param torque The caller supplies Newton-meters in Rapier's native torque
---     units. Positive values raise angular velocity.
function physics.applyTorque(world: types.World, entity: integer, torque: number)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    World.applyTorque(handleOf(row), torque)
end

--- Reads angular velocity in radians per second.
---
--- Radians need no conversion, so this is the same number Rapier holds, unlike
--- the linear velocity beside it.
---
--- @param world The caller supplies the world holding the entity.
--- @param entity The caller supplies the target entity.
--- @return Returns live Rapier angular velocity in radians per second, or zero
---     without a live body.
function physics.angularVelocity(world: types.World, entity: integer): number
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return 0.0
    end
    return World.angularVelocity(handleOf(row))
end

--- Sets angular velocity in radians per second and wakes the body.
---
--- @param world The caller supplies the world holding the entity.
--- @param entity The caller supplies the target entity. A missing live body
---     makes the call a no-op.
--- @param omega The caller supplies angular velocity in radians per second.
function physics.setAngularVelocity(world: types.World, entity: integer, omega: number)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    World.setAngularVelocity(handleOf(row), omega)
end

--- Returns whether Rapier currently considers the body awake.
---
--- @param world The caller supplies the world holding the entity.
--- @param entity The caller supplies any entity.
--- @return Returns true while Rapier actively solves the body, or false when
---     it sleeps or does not exist.
function physics.isAwake(world: types.World, entity: integer): boolean
    local row = world:get(entity, RigidBody)
    return row ~= nil and row.index1 ~= 0 and World.isAwake(handleOf(row))
end

--- Wakes or sleeps a body.
---
--- @param world The caller supplies the world holding the entity.
--- @param entity The caller supplies the target entity. A missing live body
---     makes the call a no-op.
--- @param awake The caller passes true to wake the body or false to sleep it
---     immediately.
function physics.setAwake(world: types.World, entity: integer, awake: boolean)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    World.setAwake(handleOf(row), awake)
end

--- Teleports a body and immediately updates its Transform.
---
--- A move rather than a push: velocity is left exactly as it was, so a falling
--- body carries on falling from wherever it lands.
---
--- Teleportation leaves
--- [`PreviousTransform`](tealdoc:tecs.components.PreviousTransform) unchanged.
--- `FixedFirst` snapshots
--- that column and the renderer interpolates from it, so a teleport in any
--- phase after that is drawn as one frame of travel between the two positions
--- rather than as a jump. Teleporting before `FixedFirst`, or accepting the
--- one frame, are the two ways round it.
---
--- @param world The caller supplies the world holding the entity.
--- @param entity The caller supplies the target entity. A missing live body
---     makes the call a no-op, including
---     [`Transform`](/modules/ecs/#tecs.ecs.Transform).
--- @param x The caller supplies the body's origin in world pixels along x.
--- @param y The caller supplies the body's origin in world pixels along y,
---     positive downward.
--- @param angle The caller supplies radians or nil to keep the current
---     `Transform.rotation`. Teleportation does not sweep the gap.
function physics.teleport(world: types.World, entity: integer, x: number, y: number, angle: number)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    local rotation = angle or world:get(entity, Transform).rotation
    World.setTransform(handleOf(row), toMeters(x), toMeters(y), rotation)
    local transform = world:getMut(entity, Transform)
    transform.x, transform.y, transform.rotation = x, y, rotation
end

--- Casts a segment and returns its nearest collider, in pixels.
---
--- The cast tests one segment and ignores everything beyond `x2, y2`, so a
--- miss may indicate insufficient length.
---
--- @param world The caller supplies a world. A world without physics returns
---     nil.
--- @param x1 The caller supplies the segment start in world pixels along x.
--- @param y1 The caller supplies the segment start in world pixels along y.
--- @param x2 The caller supplies the segment end in world pixels along x.
--- @param y2 The caller supplies the segment end in world pixels along y.
--- @param options The caller supplies collision filters or nil to test every
---     shape, including sensors.
--- @return Returns a fresh caller-owned nearest hit, or nil on a miss.
function physics.raycast(
    world: types.World, x1: number, y1: number, x2: number, y2: number, options: QueryOptions
): RaycastHit
    local simulation = physics.of(world)
    if simulation == nil then
        return nil
    end
    options = options or {}
    local entity, x, y, nx, ny, fraction = simulation:raycast(
        toMeters(x1), toMeters(y1), toMeters(x2), toMeters(y2), options.categoryBits, options.maskBits
    )
    if entity == nil then
        return nil
    end
    return {
        entity = entity,
        x = toPixels(x),
        y = toPixels(y),
        normalX = nx,
        normalY = ny,
        fraction = fraction,
    }
end

--- Installs the simulation and its sync.
---
--- @param options The caller supplies Rapier settings or nil for Earth-like
---     downward gravity and Rapier's default substep count.
--- @return Returns a plugin for `world:addPlugin`. Each world receives an
---     independent Rapier simulation; all worlds share one worker pool.
function physics.plugin(options: PhysicsOptions): function(types.World)
    options = options or {}
    local gravity = options.gravity or {0.0, 980.0}

    return function(world: types.World)
        -- Per world, so two worlds each installing this get a simulation each
        -- and neither sees the other's bodies. Hoisted into a local here and
        -- closed over by the systems below, so a step costs no resource lookup.
        local simulation <const> = World.create(
            {
                gravity = {
                    x = toMeters(gravity[1]),
                    y = toMeters(gravity[2]),
                },
                subStepCount = options.subStepCount,
                workerCount = options.workerCount,
            }
        )
        world.resources[simulationKey] = simulation

        local function addShape(body: Handle, entity: integer, collider: Collider): Handle
            local shapeSettings = World.shapeOptions(
                collider.density,
                collider.friction,
                collider.restitution,
                toMeters(collider.offsetX),
                toMeters(collider.offsetY),
                collider.categoryBits,
                collider.maskBits,
                collider.isSensor ~= 0,
                entity
            )
            if collider.shape == COLLIDER_SHAPES.circle then
                return World.addCircle(body, toMeters(collider.radius), shapeSettings)
            elseif collider.shape == COLLIDER_SHAPES.capsule then
                return World.addCapsule(body, toMeters(collider.radius), toMeters(collider.length), shapeSettings)
            else
                return World.addBox(body, toMeters(collider.halfWidth), toMeters(collider.halfHeight), shapeSettings)
            end
        end

        local function createBody(entity: integer, transform: Transform, declared: Body, collider: Collider): Handle
            local body = simulation:createBody(
                {
                    type = BODY_NAMES[declared.kind as integer] or "dynamic",
                    position = {x = toMeters(transform.x), y = toMeters(transform.y)},
                    angle = transform.rotation,
                    fixedRotation = declared.fixedRotation ~= 0,
                    gravityScale = declared.gravityScale,
                    linearDamping = declared.linearDamping,
                    angularDamping = declared.angularDamping,
                    sleepEnabled = declared.sleepEnabled ~= 0,
                    isBullet = declared.isBullet ~= 0,
                    entity = entity,
                }
            )
            addShape(body, entity, collider)
            return body
        end

        local pendingBodies = world:query(
            {
                name = "tecs.PendingBodies",
                include = {Transform, Body, Collider},
                exclude = {RigidBody},
            }
        )
        local detachedBodies = world:query(
            {
                name = "tecs.DetachedBodies",
                include = {RigidBody},
                exclude = {Body},
            }
        )
        local detachedDisabledBodies = world:query(
            {
                name = "tecs.DetachedDisabledBodies",
                include = {RigidBody, ecs.Disabled},
                exclude = {Body},
            }
        )
        local pausedBodies = world:query(
            {
                name = "tecs.PausedBodies",
                include = {Body, Motion, RigidBody, ecs.Paused},
                exclude = {PhysicsHeld},
            }
        )
        local resumedBodies = world:query(
            {
                name = "tecs.ResumedBodies",
                include = {Body, Motion, RigidBody, PhysicsHeld},
                exclude = {ecs.Paused},
            }
        )
        local disabledBodies = world:query(
            {
                name = "tecs.DisabledBodies",
                include = {RigidBody, ecs.Disabled},
                exclude = {PhysicsDisabled},
            }
        )
        local enabledBodies = world:query(
            {
                name = "tecs.EnabledBodies",
                include = {RigidBody, PhysicsDisabled},
                exclude = {ecs.Disabled},
            }
        )
        local declaredBodies = world:query(
            {
                name = "tecs.LiveBodyDeclarations",
                include = {Body, RigidBody},
                exclude = {PhysicsHeld, PhysicsDisabled},
            }
        )
        local colliders = world:query(
            {
                name = "tecs.LiveColliders",
                include = {Collider, RigidBody},
            }
        )
        local pendingSecondary = world:query(
            {
                name = "tecs.PendingSecondaryColliders",
                include = {Collider, ColliderOf},
                exclude = {ColliderShape},
            }
        )
        local secondaryColliders = world:query(
            {
                name = "tecs.LiveSecondaryColliders",
                include = {Collider, ColliderOf, ColliderShape},
            }
        )
        local createQueue: {PendingCreation} = {}
        local shapeQueue: {PendingShape} = {}
        local createdBodies: {integer: Handle} = {}

        local bodies = world:query(
            {
                name = "tecs.SimulatedBodies",
                type = "logic",
                include = {Transform, RigidBody},
            }
        )
        local snapshotBodies = world:query(
            {
                name = "tecs.SnapshotBodies",
                include = {Motion, RigidBody},
                exclude = {PhysicsHeld},
            }
        )

        -- A body outlives its entity otherwise. Rapier owns it until something
        -- says so, and nothing else knows the entity is gone, so it keeps
        -- being solved for the rest of the session.
        world:observe(
            0,
            ecs.OnDespawn,
            function(event: ecs.OnDespawn)
                local colliderShape = world:get(event.entity, ColliderShape)
                if colliderShape ~= nil and colliderShape.index1 ~= 0 then
                    local shape = shapeOf(colliderShape)
                    if World.isShapeValid(shape) then
                        World.destroyShape(shape)
                    end
                end
                local row = world:get(event.entity, RigidBody)
                if row == nil or row.index1 == 0 then
                    return
                end
                local body = handleOf(row)
                -- The handle names its own world, so this reaches the right
                -- one without going back through the entity's world at all.
                -- The validity check is what makes a row restored from a
                -- snapshot, or one whose world has been destroyed, safe to
                -- meet here.
                if not World.isBodyValid(body) then
                    return
                end
                World.destroyBody(body)
            end
        )

        -- The fixed phases, always. A simulation that advanced by the frame
        -- would take a different number of steps on every machine and produce
        -- a different result from the same inputs, which is the whole reason
        -- the fixed phases exist.
        -- The solve and the write-back, apart. They are different work with
        -- different fixes, and one number cannot say which of them is the
        -- cost.
        local STEP <const> = timing.stage("physics.step")
        local SYNC <const> = timing.stage("physics.sync")

        world:addSystem(
            {
                name = "tecs.ReconcileBodies",
                phase = ecs.phases.FixedFirst,
                run = function()
                    for archetype, length, entities in detachedBodies:iter() do
                        local rows = archetype:get(RigidBody)
                        for row = 1, length do
                            local body = handleOf(rows[row])
                            if World.isBodyValid(body) then
                                World.destroyBody(body)
                            end
                            world:remove(entities[row], RigidBody)
                        end
                    end
                    for archetype, length, entities in detachedDisabledBodies:iter() do
                        local rows = archetype:get(RigidBody)
                        for row = 1, length do
                            local body = handleOf(rows[row])
                            if World.isBodyValid(body) then
                                World.destroyBody(body)
                            end
                            world:remove(entities[row], RigidBody)
                        end
                    end

                    table_clear(createQueue)
                    table_clear(createdBodies)
                    for archetype, length, entities in pendingBodies:iter() do
                        local transforms = archetype:get(Transform)
                        local declarations = archetype:get(Body)
                        local shapes = archetype:get(Collider)
                        local motions = archetype:get(Motion)
                        for row = 1, length do
                            createQueue[#createQueue + 1] = {
                                entity = entities[row],
                                transform = transforms[row],
                                body = declarations[row],
                                collider = shapes[row],
                                motion = motions[row],
                            }
                        end
                    end
                    table.sort(
                        createQueue,
                        function(a: PendingCreation, b: PendingCreation): boolean return a.entity < b.entity end
                    )
                    world:defer()
                    for index = 1, #createQueue do
                        local pending = createQueue[index]
                        local native = createBody(pending.entity, pending.transform, pending.body, pending.collider)
                        createdBodies[pending.entity] = native
                        World.setVelocity(native, toMeters(pending.motion.vx), toMeters(pending.motion.vy))
                        World.setAngularVelocity(native, pending.motion.omega)
                        local wrapped = native as {string: any}
                        local handle = wrapped.native as loader.CStruct
                        local nativeWorld = wrapped.world as {string: any}
                        world:set(
                            pending.entity,
                            RigidBody(
                                (handle.index as number) + 1, nativeWorld._id as number, handle.generation as number
                            )
                        )
                        world:set(
                            pending.entity,
                            components.PreviousTransform(
                                pending.transform.x, pending.transform.y, pending.transform.rotation
                            )
                        )
                    end
                    table_clear(createQueue)

                    table_clear(shapeQueue)
                    for archetype, length, entities in pendingSecondary:iter() do
                        local shapes = archetype:get(Collider)
                        for row = 1, length do
                            local entity = entities[row]
                            local relationship = world:getFirstRelationship(entity, ColliderOf)
                            if relationship ~= nil then
                                local owner = world:get(relationship.target, RigidBody)
                                if
                                    createdBodies[relationship.target] ~= nil or (owner ~= nil and owner.index1 ~= 0)
                                then
                                    shapeQueue[#shapeQueue + 1] = {
                                        entity = entity,
                                        owner = relationship.target,
                                        collider = shapes[row],
                                    }
                                end
                            end
                        end
                    end
                    table.sort(
                        shapeQueue, function(a: PendingShape, b: PendingShape): boolean return a.entity < b.entity end
                    )
                    for index = 1, #shapeQueue do
                        local pending = shapeQueue[index]
                        local owner = createdBodies[pending.owner]
                        if owner == nil then
                            owner = handleOf(world:get(pending.owner, RigidBody))
                        end
                        local wrapped = addShape(owner, pending.entity, pending.collider) as {string: any}
                        local shape = wrapped.native as loader.CStruct
                        local nativeWorld = wrapped.world as {string: any}
                        world:set(
                            pending.entity,
                            ColliderShape(
                                (shape.index as number) + 1, nativeWorld._id as number, shape.generation as number
                            )
                        )
                    end
                    table_clear(shapeQueue)
                    table_clear(createdBodies)
                    world:commit()
                end,
            }
        )

        world:addSystem(
            {
                name = "tecs.HoldPausedBodies",
                phase = ecs.phases.FixedFirst,
                run = function()
                    for archetype, length, entities in pausedBodies:iter() do
                        local rows = archetype:get(RigidBody)
                        local motions = archetype:getMut(Motion)
                        for row = 1, length do
                            local body = handleOf(rows[row])
                            local vx, vy = World.getVelocity(body)
                            motions[row].vx, motions[row].vy = toPixels(vx), toPixels(vy)
                            motions[row].omega = World.angularVelocity(body)
                            World.setVelocity(body, 0.0, 0.0)
                            World.setAngularVelocity(body, 0.0)
                            World.setBodyType(body, 0)
                            world:set(entities[row], PhysicsHeld)
                        end
                    end
                end,
            }
        )

        world:addSystem(
            {
                name = "tecs.ReleasePausedBodies",
                phase = ecs.phases.FixedFirst,
                run = function()
                    for archetype, length, entities in resumedBodies:iter() do
                        local declarations = archetype:get(Body)
                        local rows = archetype:get(RigidBody)
                        local motions = archetype:get(Motion)
                        for row = 1, length do
                            local body = handleOf(rows[row])
                            World.setBodyType(body, declarations[row].kind as integer)
                            World.setVelocity(body, toMeters(motions[row].vx), toMeters(motions[row].vy))
                            World.setAngularVelocity(body, motions[row].omega)
                            world:remove(entities[row], PhysicsHeld)
                        end
                    end
                end,
            }
        )

        world:addSystem(
            {
                name = "tecs.ApplyColliderChanges",
                phase = ecs.phases.FixedFirst,
                run = function()
                    for archetype, length, entities in colliders:iter() do
                        if archetype:isComponentDirty(Collider) then
                            local shapes = archetype:get(Collider)
                            local rows = archetype:get(RigidBody)
                            for row = 1, length do
                                local body = handleOf(rows[row])
                                World.removeShape(body, entities[row])
                                addShape(body, entities[row], shapes[row])
                            end
                        end
                    end
                    for archetype, length, entities in secondaryColliders:iter() do
                        if archetype:isComponentDirty(Collider) then
                            local collidersInArchetype = archetype:get(Collider)
                            local rows = archetype:getMut(ColliderShape)
                            for row = 1, length do
                                local old = shapeOf(rows[row])
                                local body = World.bodyOfShape(old)
                                World.destroyShape(old)
                                local wrapped = addShape(
                                    body, entities[row], collidersInArchetype[row]
                                ) as {string: any}
                                local shape = wrapped.native as loader.CStruct
                                local nativeWorld = wrapped.world as {string: any}
                                rows[row].index1 = (shape.index as number) + 1
                                rows[row].world0 = nativeWorld._id as number
                                rows[row].generation = shape.generation as number
                            end
                        end
                    end
                end,
            }
        )

        world:addSystem(
            {
                name = "tecs.ApplyBodyChanges",
                phase = ecs.phases.FixedFirst,
                run = function()
                    for archetype, length in declaredBodies:iter() do
                        if archetype:isComponentDirty(Body) then
                            local declarations = archetype:get(Body)
                            local rows = archetype:get(RigidBody)
                            for row = 1, length do
                                local declared = declarations[row]
                                local body = handleOf(rows[row])
                                World.applyBodyDefinition(
                                    body,
                                    declared.kind as integer,
                                    declared.fixedRotation ~= 0,
                                    declared.isBullet ~= 0,
                                    declared.sleepEnabled ~= 0,
                                    declared.gravityScale,
                                    declared.linearDamping,
                                    declared.angularDamping
                                )
                            end
                        end
                    end
                end,
            }
        )

        world:addSystem(
            {
                name = "tecs.DisablePhysicsBodies",
                phase = ecs.phases.FixedFirst,
                run = function()
                    for archetype, length, entities in disabledBodies:iter() do
                        local rows = archetype:get(RigidBody)
                        for row = 1, length do
                            World.setEnabled(handleOf(rows[row]), false)
                            world:set(entities[row], PhysicsDisabled)
                        end
                    end
                end,
            }
        )

        world:addSystem(
            {
                name = "tecs.EnablePhysicsBodies",
                phase = ecs.phases.FixedFirst,
                run = function()
                    for archetype, length, entities in enabledBodies:iter() do
                        local rows = archetype:get(RigidBody)
                        for row = 1, length do
                            World.setEnabled(handleOf(rows[row]), true)
                            world:remove(entities[row], PhysicsDisabled)
                        end
                    end
                end,
            }
        )

        world:addSystem(
            {
                name = "tecs.StepPhysics",
                phase = ecs.phases.FixedUpdate,
                run = function()
                    local started = timing.begin()
                    -- The rate comes from the world rather than from an option
                    -- here. Two numbers that have to agree and can disagree is a
                    -- simulation that integrates at one rate while the phase
                    -- driving it runs at another.
                    simulation:step((world:getFixedTiming()))

                    -- Rapier's narrow phase is drained through a native buffer, so
                    -- no Rust callback ever enters LuaJIT.
                    simulation:beginPairEvents()
                    for index = 0, simulation:pairEventCount() - 1 do
                        local entityA, entityB, collisionStarted, sensor = simulation:pairEvent(index)
                        if sensor then
                            world:emit(0, collisionStarted and SensorBegin or SensorEnd, entityA, entityB)
                        else
                            world:emit(0, collisionStarted and ContactBegin or ContactEnd, entityA, entityB)
                        end
                    end
                    timing.finish(STEP, started)
                end,
            }
        )

        world:addSystem(
            {
                name = "tecs.SyncBodyTransforms",
                phase = ecs.phases.FixedPostUpdate,
                run = function()
                    local started = timing.begin()
                    simulation:beginMoves()

                    for archetype, length in bodies:iter() do
                        local rows = archetype:get(RigidBody)

                        -- Taken mutable on the first body that actually moved, and
                        -- not at all otherwise. Taking it up front would mark the
                        -- column dirty every frame for every archetype holding a
                        -- body, which defeats every consumer gated on that: a
                        -- world whose bodies have gone to sleep would still
                        -- re-upload each of their instances.
                        local transforms: {any} = nil

                        for row = 1, length do
                            local px, py, cosine, sine = simulation:moveOf(rows[row].index1 as integer)
                            if px ~= nil then
                                if transforms == nil then
                                    transforms = archetype:getMut(Transform) as {any}
                                end
                                local transform = transforms[row] as Transform
                                transform.x = toPixels(px)
                                transform.y = toPixels(py)
                                transform.rotation = atan2(sine, cosine)
                            end
                        end
                    end

                    simulation:endMoves()
                    timing.finish(SYNC, started)
                end,
            }
        )

        world:addSnapshotHandler(
            {
                -- This name is part of the persisted snapshot format.
                name = "tecs.physics",
                save = function(_world: types.World): any
                    for archetype, length in snapshotBodies:iter() do
                        local rows = archetype:get(RigidBody)
                        local motions = archetype:getMut(Motion)
                        for row = 1, length do
                            local body = handleOf(rows[row])
                            local vx, vy = World.getVelocity(body)
                            motions[row].vx, motions[row].vy = toPixels(vx), toPixels(vy)
                            motions[row].omega = World.angularVelocity(body)
                        end
                    end
                    return {
                        engine = "rapier2d-0.34",
                        state = simulation:snapshot(),
                        workerCount = simulation.taskPool.workerCount,
                        subStepCount = simulation.subStepCount,
                    }
                end,
                load = function(_world: types.World, value: any)
                    local saved = value as {string: any}
                    if saved.engine ~= "rapier2d-0.34" or saved.state == nil then
                        return
                    end
                    simulation:restore(saved.state as string)
                    world:defer()
                    for _, length, entities in pendingBodies:iter() do
                        for row = 1, length do
                            local entity = entities[row]
                            local wrapped = simulation:bodyByEntity(entity) as {string: any}
                            if wrapped ~= nil then
                                local handle = wrapped.native as loader.CStruct
                                world:set(
                                    entity,
                                    RigidBody(
                                        (handle.index as number) + 1,
                                        simulation._id as number,
                                        handle.generation as number
                                    )
                                )
                            end
                        end
                    end
                    for _, length, entities in pendingSecondary:iter() do
                        for row = 1, length do
                            local entity = entities[row]
                            local wrapped = simulation:colliderByEntity(entity) as {string: any}
                            if wrapped ~= nil then
                                local handle = wrapped.native as loader.CStruct
                                world:set(
                                    entity,
                                    ColliderShape(
                                        (handle.index as number) + 1,
                                        simulation._id as number,
                                        handle.generation as number
                                    )
                                )
                            end
                        end
                    end
                    world:commit()
                end,
            }
        )

        -- Where the release goes, because there is no `world:destroy` in the
        -- ECS: what exists is `world:shutdown`, which an application calls
        -- first and deliberately, while what a system might give back still
        -- exists. A world a spec built with no application gets the same
        -- system and the same teardown from the same call.
        --
        -- A world simply dropped instead leaks its simulation and its hold on
        -- the thread pool. Nothing at this layer can act on one nobody shuts
        -- down; what it can do is leave the leak visible, and
        -- `TaskPool.liveThreadCount` is where it shows.
        world:addSystem(
            {
                name = "tecs.ShutdownPhysics",
                phase = ecs.phases.Shutdown,
                run = function() world.resources[simulationKey] = nil; simulation:destroy() end,
            }
        )
    end
end

return physics
