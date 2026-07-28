--- Physics as part of the world.
---
--- A body is four components. `Body` and `Collider` are the declaration, what
--- a game asked for; `Motion` is the one piece of simulation state that has to
--- survive a body being taken out of the solve; `RigidBody` is the live Box2D
--- handle. Box2D 3 handles are small value structs rather than pointers to C++
--- objects, so the handle lives directly in an archetype column: no userdata,
--- no finalizers, and no boundary crossing to read one back.
---
--- The description is in columns rather than in a side table keyed by entity,
--- for four reasons that a side table gives up. The snapshot writer already
--- walks columns, so putting a body's shape in one finishes the save side with
--- no code. The MCP world tools read the component registry, so a `Collider`
--- is queryable, describable and editable the moment it is a component, and a
--- body that falls through the floor is exactly the bug an agent should be
--- able to look at. `batchSpawn` has a column path and no side-table path, so
--- a thousand bodies can be one archetype transition. And a module-level table
--- keyed by entity is the defect class the engine is working its way out of,
--- not one to add to.
---
--- Four components rather than one, because the fields have different Box2D
--- surfaces (`b2Body_*` against `b2Shape_*`), different owners, and different
--- lifetimes, and because one body can eventually carry more than one shape.
---
--- Stepping happens in FixedUpdate. Box2D's solver is not robust to a varying
--- timestep and a variable one makes replay diverge, so the fixed phase is not
--- a preference here, it is a requirement.
---
--- The simulation is per world, reached through `physics.of`. Two worlds each
--- installing the plugin get a Box2D world each and neither sees the other's
--- bodies. The solver's thread pool goes the other way and is shared: threads
--- are the machine, and worlds step serially on the game thread.

local ecs <const> = require("tecs.ecs")
local loader <const> = require("tecs.ffi.loader")
local World <const> = require("tecs.physics.World")
local box2d <const> = require("tecs.ffi.box2d")
local components <const> = require("tecs.components")
local timing <const> = require("tecs.timing")
local table_clear <const> = require("table.clear")

local atan2 <const> = math.atan2

local B <const> = box2d.C
local Transform <const> = components.Transform

local type Component = ecs.Component

--- Pixels per simulated metre.
---
--- Box2D is tuned for objects roughly 0.1 to 10 units across, so simulating
--- directly in pixels puts every body far outside the range its solver
--- tolerances were chosen for.
local PIXELS_PER_METRE <const> = 32.0

--- Body kinds, matching Box2D's `b2BodyType` and `World.tl`'s own map.
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

--- What a game asked a body to be: the fields Box2D applies through `b2Body_*`.
---
--- Requiring `Transform` is what makes a body without a pose unrepresentable
--- rather than a nil test. The pose has to come from somewhere, and the sync
--- writes back into `Transform` unconditionally, so a body with no `Transform`
--- would be a body nothing can see. Setting `Body` on an entity without one
--- gains it a default at the origin.
---
--- Requiring `Motion` means every body carries that column from creation,
--- which is the point: filling it at save time must not add a component to
--- four thousand entities in the middle of serializing them.
local record Body is Component
    --- 0 static, 1 kinematic, 2 dynamic.
    kind: number
    fixedRotation: number
    isBullet: number
    sleepEnabled: number
    gravityScale: number
    linearDamping: number
    angularDamping: number
end

--- A body's geometry and surface: the fields Box2D applies through `b2Shape_*`.
---
--- One record with a shape discriminant rather than a record per shape,
--- because a component per shape would make "anything with a collider" a union
--- across three archetypes.
---
--- The filter bits are 32 wide here and 64 wide in Box2D's `b2Filter`. A
--- 64-bit column does not survive the table snapshot format, which carries a
--- field as a Lua number, and thirty-two categories is what a game can express
--- through a number anyway.
local record Collider is Component
    --- 0 box, 1 circle, 2 capsule.
    shape: number
    halfWidth: number
    halfHeight: number
    radius: number
    --- Capsule only: the distance between its two end centres.
    length: number
    --- The shape's centre in the body frame.
    offsetX: number
    offsetY: number
    density: number
    friction: number
    restitution: number
    categoryBits: number
    maskBits: number
    groupIndex: number
    isSensor: number
end

--- Collider shape kinds, matching `Collider.shape`.
local COLLIDER_SHAPES <const>: {string: integer} = {
    box = 0,
    circle = 1,
    capsule = 2,
}

--- A body's velocity, in pixels and radians per second.
---
--- A store, not a mirror. It is written at two moments, a pause and a save,
--- and read at two, a resume and a load. Nothing writes it per step, so
--- reading it mid-frame gives whatever the last of those four events left
--- there. `physics.velocity` is the live read and stays the only way to ask
--- what a body is doing right now.
---
--- Mirroring it per step is the one large per-frame cost this design could
--- have taken on. It would be a write over every body every fixed step, and it
--- would dirty the column for consumers gated on that bit even for a world
--- whose bodies have all gone to sleep.
local record Motion is Component
    vx: number
    vy: number
    omega: number
end

ecs.newFFIComponent({
    name = "Motion",
    container = Motion,
    fields = {
        {"vx", "float"},
        {"vy", "float"},
        {"omega", "float"},
    },
    defaults = {0, 0, 0},
})

ecs.newFFIComponent({
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
})

ecs.newFFIComponent({
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
        {"groupIndex", "int32_t"},
        {"isSensor", "uint8_t"},
    },
    -- The material defaults are Box2D's own, from `b2DefaultShapeDef`.
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
        0,
    },
})

--- A body in the simulation.
---
--- The three fields are Box2D's own handle layout. They are written by
--- `attach` and read back by the sync; nothing else should touch them.
local record RigidBody is Component
    index1: number
    world0: number
    generation: number
end

ecs.newFFIComponent({
    name = "RigidBody",
    container = RigidBody,
    fields = {
        {"index1", "int32_t"},
        {"world0", "uint16_t"},
        {"generation", "uint16_t"},
    },
    defaults = {0, 0, 0},
    transient = true,
})

--- Marks a paused body that has been changed to static and had its motion
--- stored. Engine-owned and transient.
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
ecs.newFFIComponent({
    name = "ColliderShape",
    container = ColliderShape,
    fields = {
        {"index1", "int32_t"},
        {"world0", "uint16_t"},
        {"generation", "uint16_t"},
    },
    defaults = {0, 0, 0},
    transient = true,
})

--- A secondary collider's owning body. The relationship is sparse so adding
--- shapes does not split body archetypes, reverse-indexed for inspection, and
--- cascade-deleted with the body.
local ColliderOf <const> = ecs.newRelationship({
    name = "ColliderOf",
    exclusive = true,
    sparse = true,
    reverseIndex = true,
    cascadeDelete = true,
})

--- What `attach` and `attachCollider` are given. Every field is optional, and
--- one left out takes the default named on it rather than keeping whatever a
--- previous call set: this describes a body outright.
---
--- `attachCollider` reads only the shape, material, filter and offset fields.
--- The body-level ones are ignored there, because a secondary collider is a
--- shape on somebody else's body and has no damping or gravity of its own.
local record BodyOptions
    --- "static", "kinematic", or "dynamic". Defaults to dynamic, and an
    --- unrecognised string raises rather than falling back, so a typo is
    --- caught at the call rather than found later as a body that will not
    --- move.
    type: string
    --- Half-extents in pixels, so a 32-pixel square is 16 by 16 here. Both
    --- default to 8, and both are ignored unless the shape is a box.
    halfWidth: number
    halfHeight: number
    --- Radius in pixels. Naming it at all selects a circle over the box
    --- extents, so there is no way to ask for a box and a radius together.
    --- Required, and positive, when `capsuleLength` is given.
    radius: number
    --- Mass per unit area. Defaults to Box2D's 1.0. Zero leaves a dynamic body
    --- with no mass, and Box2D reads no mass as infinite mass: it stops
    --- falling and stops answering impulses, which looks like a static body
    --- that was declared dynamic.
    density: number
    --- Coulomb friction, defaulting to Box2D's 0.6. A contact takes the
    --- geometric mean of the two shapes', so zero on either one is a
    --- frictionless slide however rough the other is.
    friction: number
    --- Bounce, defaulting to Box2D's 0.0. One is a perfectly elastic bounce,
    --- and above one a body gains energy on every contact. A contact takes the
    --- larger of the two shapes', so the bouncier surface decides and a
    --- deadened one cannot damp it.
    restitution: number
    --- Locks the body's angle, so contacts and torque no longer spin it.
    --- Defaults to false.
    fixedRotation: boolean
    --- Scales the world's gravity for this body alone. Defaults to 1. Zero
    --- floats, and negative falls upward.
    gravityScale: number
    --- Velocity lost per second to drag, defaulting to 0. Not a physical
    --- quantity: it is the solver's own damping term.
    linearDamping: number
    angularDamping: number
    --- Whether the body may sleep when it comes to rest. Defaults to true, and
    --- only an explicit `false` disables it. A sleeping body stops being
    --- solved until something touches it or it is woken.
    sleepEnabled: boolean
    --- Continuous collision, for a body fast enough to pass through a wall
    --- between two steps. Defaults to false, because it costs more to solve.
    isBullet: boolean
    --- The categories this shape belongs to, defaulting to 1. Thirty-two bits
    --- here against Box2D's sixty-four: a wider column does not survive the
    --- table snapshot format, which carries a field as a Lua number.
    categoryBits: number
    --- The categories this shape collides with, defaulting to all of them. Two
    --- shapes touch only when each one's mask names the other's category, so
    --- filtering one direction alone filters both.
    maskBits: number
    --- Overrides the category and mask between two shapes sharing it: positive
    --- always collides, negative never does, and zero, the default, defers to
    --- the bits.
    groupIndex: integer
    --- Reports overlaps as `SensorBegin` and `SensorEnd` without a collision
    --- response. Defaults to false. A sensor emits no contact or hit events.
    isSensor: boolean
    --- The shape's centre in the body's own frame, in pixels, so it turns with
    --- the body. Both default to 0, which centres the shape on the body's
    --- origin.
    offsetX: number
    offsetY: number
    --- Selects a vertical capsule, and is the distance between its two end
    --- centres, excluding the caps, so the full height is this plus twice the
    --- radius. `radius` stays the cap radius and has to be positive.
    capsuleLength: number
end

--- What a raycast is allowed to hit.
local record QueryOptions
    --- The ray's own categories, defaulting to all. A shape whose mask
    --- excludes every one of these is skipped.
    categoryBits: number
    --- The categories the ray may hit, defaulting to all.
    maskBits: number
end

--- Where a ray first met a collider. A fresh table per hit, and the caller's
--- to keep.
local record RaycastHit
    --- The entity owning the shape that was hit, which is the secondary
    --- collider's own entity when the ray met one of those rather than the
    --- body's.
    entity: integer
    --- The contact point in world pixels.
    x: number
    y: number
    --- The surface normal at the point, pointing out of the shape. A unit
    --- vector, so it is not scaled to pixels.
    normalX: number
    normalY: number
    --- How far along the segment the hit is, from 0 at the start to 1 at the
    --- end.
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

local record ContactBegin is ecs.Event
    entityA: integer
    entityB: integer
end
local record ContactEnd is ecs.Event
    entityA: integer
    entityB: integer
end
local record ContactHit is ecs.Event
    entityA: integer
    entityB: integer
    x: number
    y: number
    normalX: number
    normalY: number
    approachSpeed: number
end
local record SensorBegin is ecs.Event
    sensor: integer
    visitor: integer
end
local record SensorEnd is ecs.Event
    sensor: integer
    visitor: integer
end

--- What `physics.plugin` is built with. Every field is optional.
local record PhysicsOptions
    --- Gravity as x then y, in pixels per second squared, matching world
    --- units. Defaults to 980 downward, which is roughly Earth at this
    --- module's 32 pixels to the metre. Positive y is down, like `Transform`.
    gravity: {number}
    --- Solver substeps per step, defaulting to Box2D's 4. More costs time
    --- linearly and buys stability in stacks and fast contacts; fewer makes a
    --- tall stack sink into itself.
    subStepCount: integer
    --- Worker slots the solver runs across, counting the thread that steps
    --- the world. One is single threaded. Defaults to a count derived from
    --- the machine.
    ---
    --- Process-wide rather than per world, because the threads are the
    --- machine: the first world to ask sizes the shared pool, and a later one
    --- naming a different count raises rather than being ignored.
    workerCount: integer
end

local record physics
    RigidBody: RigidBody
    Body: Body
    Collider: Collider
    ColliderOf: Component
    Motion: Motion
    ContactBegin: ContactBegin
    ContactEnd: ContactEnd
    ContactHit: ContactHit
    SensorBegin: SensorBegin
    SensorEnd: SensorEnd
    --- Pixels per simulated metre.
    scale: number

    --- The same as `applyImpulse`, given a `RigidBody` row already in hand.
    ---
    --- For a system walking a column, where going back through the entity
    --- would cost a lookup per body per frame.
    ---
    --- @param row A row read straight off a `RigidBody` column. The null row a
    ---     snapshot load leaves behind is ignored rather than passed on: Box2D
    ---     indexes its body array from the slot without checking it, so a null
    ---     handle reads off the front of that array.
    --- @param x Pixel-scaled impulse along x. Dividing it by the body's mass in
    ---     kilograms gives the change in velocity in pixels per second.
    --- @param y The same along y, positive downward. Applied at the centre of
    ---     mass, so neither component imparts spin.
    applyImpulseTo: function(row: RigidBody, x: number, y: number)
end

physics.RigidBody = RigidBody
physics.Body = Body
physics.Collider = Collider
physics.ColliderOf = ColliderOf
physics.Motion = Motion
physics.ContactBegin = ContactBegin
physics.ContactEnd = ContactEnd
physics.ContactHit = ContactHit
physics.SensorBegin = SensorBegin
physics.SensorEnd = SensorEnd
physics.scale = PIXELS_PER_METRE

ContactBegin.init = function(event: ContactBegin, a: integer, b: integer) event.entityA, event.entityB = a, b end
ContactEnd.init = function(event: ContactEnd, a: integer, b: integer) event.entityA, event.entityB = a, b end
ContactHit.init = function(
    event: ContactHit, a: integer, b: integer, x: number, y: number, nx: number, ny: number, speed: number
)
    event.entityA, event.entityB = a, b
    event.x, event.y = x, y
    event.normalX, event.normalY = nx, ny
    event.approachSpeed = speed
end
SensorBegin.init = function(event: SensorBegin, sensor: integer, visitor: integer)
    event.sensor, event.visitor = sensor, visitor
end
SensorEnd.init = function(event: SensorEnd, sensor: integer, visitor: integer)
    event.sensor, event.visitor = sensor, visitor
end
ecs.newEvent(ContactBegin)
ecs.newEvent(ContactEnd)
ecs.newEvent(ContactHit)
ecs.newEvent(SensorBegin)
ecs.newEvent(SensorEnd)

--- The simulation installed into a world, or nil when none has been.
---
--- Module-private, because `physics.of` is the door: an accessor reads better
--- than a table index, and one door is what lets this module change how it
--- stores the simulation later. What is published is the name, because
--- `Context.listKeys` reverse-maps names to ids, so a debug tool can answer
--- what is installed into a world without every module exporting its key.
local simulationKey <const> = ecs.newKey("tecs.physics", nil as World)

--- The simulation installed into `world`, or nil when none has been.
---
--- What lets something holding only the ECS world reach the Box2D one, which
--- is what the debug tools have and what a game writing its own systems often
--- has too.
---
--- @param world A world with or without the plugin. A world without one is not
---     an error here, which is what makes this the test for whether physics is
---     installed at all.
--- @return The world's own live simulation, not a copy, so stepping or
---     destroying what comes back acts on the one the plugin's systems drive.
---     Nil before the plugin is added and again after `Shutdown` has run.
function physics.of(world: ecs.World): World
    return world.resources[simulationKey]
end

local function toMetres(pixels: number): number
    return pixels / PIXELS_PER_METRE
end

local function toPixels(metres: number): number
    return metres * PIXELS_PER_METRE
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
        options.groupIndex or 0,
        options.isSensor and 1 or 0
    )
end

--- Declares a body on `entity`.
---
--- Creation happens at the next fixed step. Keeping it declarative makes the
--- same path work for spawn, batch spawn, snapshots and debug tools, and no
--- raw Box2D handle escapes the module.
---
--- @param world Raises when `physics.plugin` was never added to it, because a
---     body declared into a world with no simulation is components nothing
---     will ever read.
--- @param entity Gains `Body` and `Collider`, and `Transform` and `Motion`
---     with them when it has neither, since `Body` requires both. The two sets
---     are deferred together, so this is one archetype move rather than two.
--- @param options Read once, here. Later changes go through `world:getMut` on
---     `Body` or `Collider`, which the fixed step reapplies to the live body.
---     An unrecognised `type` raises, and so does a `capsuleLength` without a
---     positive `radius`; both blame the caller's line rather than this one.
function physics.attach(world: ecs.World, entity: integer, options: BodyOptions)
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
--- @param world Not checked for a simulation, unlike `attach`: the body named
---     below cannot have been declared without one.
--- @param entity The collider's own entity, which gains `Collider` and
---     `ColliderOf`. It is not the body, carries no pose of its own, and is
---     placed by the shape's offset within the body's frame. `ColliderOf` is
---     cascade-deleted, so despawning the body despawns this too.
--- @param body The entity to attach to. Raises when it has no `Body`, which
---     includes the case of a body already detached. Its live shape need not
---     exist yet: a collider declared in the same frame as its body waits and
---     is created after it, in the same fixed step.
--- @param options Only the shape, material, filter and offset fields are read.
---     `type`, damping, gravity and the sleep and bullet flags belong to the
---     body and are ignored here.
function physics.attachCollider(world: ecs.World, entity: integer, body: integer, options: BodyOptions)
    options = options or {}
    if world:get(body, Body) == nil then
        error("tecs: ColliderOf target has no Body", 2)
    end
    world:defer()
    world:set(entity, colliderFrom(options))
    world:set(entity, ColliderOf(body))
    world:commit()
end

--- Removes a body's declaration. Its native body is destroyed at the next
--- fixed step.
---
--- @param world The world holding the entity. Not checked for a simulation:
---     removing a component from a world that never had one is harmless.
--- @param entity Loses `Body` only. `Collider`, `Motion` and `Transform` stay,
---     so what the body was is still readable and `attach` can declare it
---     again. Not an error for an entity that never had a body.
function physics.detach(world: ecs.World, entity: integer)
    world:remove(entity, Body)
end

-- One handle for the lifetime of the process. The sync rebuilds a handle per
-- body per step, so allocating here would put a GC allocation in the hottest
-- loop physics has.
local scratchHandle <const> = loader.newStruct("b2BodyId")
local scratchFields <const> = scratchHandle as loader.CStruct

--- Rebuilds a Box2D handle from a stored RigidBody row.
---
--- The returned handle is reused between calls; it is passed straight to
--- Box2D and never retained.
local function handleOf(row: RigidBody): loader.CValue
    scratchFields.index1 = row.index1
    scratchFields.world0 = row.world0
    scratchFields.generation = row.generation
    return scratchHandle
end

local scratchShape <const> = loader.newStruct("b2ShapeId")
local scratchShapeFields <const> = scratchShape as loader.CStruct

local function shapeOf(row: ColliderShape): loader.CValue
    scratchShapeFields.index1 = row.index1
    scratchShapeFields.world0 = row.world0
    scratchShapeFields.generation = row.generation
    return scratchShape
end

--- Whether `entity` has a body Box2D is still solving.
---
--- False for an entity whose RigidBody came out of a snapshot. A load
--- restores the row as the null handle rather than a body id this run never
--- issued, so this is how a game tells "was simulating and is not any more"
--- from "never had a body", and the two are worth telling apart: nothing
--- rebuilds a body on load.
---
--- @param world The world holding the entity.
--- @param entity Any entity. One with no `RigidBody` at all answers false
---     rather than raising.
--- @return False for the whole window between `attach` and the fixed step that
---     acts on it, so this is not a way to check a declaration landed. False
---     too for a handle whose world has since been destroyed, because the
---     check covers the generation and the world as well as the slot.
function physics.hasBody(world: ecs.World, entity: integer): boolean
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return false
    end
    -- Box2D's own check, which covers the generation and the world as well
    -- as the slot, so a handle left over from a destroyed world answers
    -- false rather than addressing whatever took its place.
    return B.b2Body_IsValid(handleOf(row)) as boolean
end

--- Pushes a body once, at its centre of mass.
---
--- An impulse rather than a force, so the effect does not depend on how long
--- the step happened to be. Wakes the body: Box2D lets a resting island sleep,
--- and pushing a sleeping body without waking it does nothing.
---
--- @param world The world holding the entity.
--- @param entity Does nothing for one with no live body, which is the answer
---     every control here gives.
--- @param x Pixel-scaled impulse along x. Dividing it by the body's mass in
---     kilograms gives the change in velocity in pixels per second, so the
---     same push moves a light body further than a heavy one.
--- @param y The same along y, positive downward. Applied at the centre of
---     mass, so neither component imparts spin; `applyImpulseAt` is the one
---     that does.
function physics.applyImpulse(world: ecs.World, entity: integer, x: number, y: number)
    local row = world:get(entity, RigidBody)
    if row == nil then
        return
    end
    physics.applyImpulseTo(row, x, y)
end

function physics.applyImpulseTo(row: RigidBody, x: number, y: number)
    -- The null handle is what a snapshot load leaves behind, and Box2D
    -- indexes its body array from the slot without checking it, so passing
    -- one through would read off the front of that array.
    if row.index1 == 0 then
        return
    end
    local body = handleOf(row)
    local impulse = loader.newStruct("b2Vec2")
    local fields = impulse as loader.CStruct
    fields.x = toMetres(x)
    fields.y = toMetres(y)
    B.b2Body_ApplyLinearImpulseToCenter(body, impulse, true)
end

--- Applies an impulse at a world-space point, so it spins the body as well as
--- moving it.
---
--- @param world The world holding the entity.
--- @param entity Does nothing for one with no live body.
--- @param x Pixel-scaled impulse along x, read as `applyImpulse` reads it.
--- @param y The same along y, positive downward.
--- @param pointX Where the push lands, in world pixels rather than in the
---     body's frame. The further it is from the centre of mass, the more of
---     the impulse becomes spin and the less becomes travel.
--- @param pointY The same along y. A point at the centre of mass makes this
---     exactly `applyImpulse`.
function physics.applyImpulseAt(world: ecs.World, entity: integer, x: number, y: number, pointX: number, pointY: number)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    World.applyImpulseAt(handleOf(row), toMetres(x), toMetres(y), toMetres(pointX), toMetres(pointY))
end

--- Reads a body's velocity, live from Box2D, in pixels per second.
---
--- Pixels, like every other number this module takes and returns: the extents
--- and radius `attach` is given, the impulse components, and the plugin's
--- gravity. A caller that wants metres divides by `physics.scale`.
---
--- This rather than the `Motion` column is what a body is doing right now.
--- `Motion` is a store written at a pause and a save, not a mirror.
---
--- @param world The world holding the entity.
--- @param entity An entity with no live body reads as stopped rather than
---     raising, so a caller cannot tell that case from a body genuinely at
---     rest; `hasBody` is what tells them apart.
--- @return X in pixels per second, then y, positive downward. Linear only: a
---     body that is only spinning reads zero on both, and
---     `physics.angularVelocity` is where that shows.
function physics.velocity(world: ecs.World, entity: integer): number, number
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return 0.0, 0.0
    end
    local vx, vy = World.getVelocity(handleOf(row))
    return toPixels(vx), toPixels(vy)
end

--- Sets a body's velocity, in pixels per second, and wakes it.
---
--- Does nothing for an entity with no live body, which is the same answer
--- `physics.velocity` gives for one: a null handle indexes Box2D's body array
--- without being checked, so it never reaches Box2D.
---
--- @param world The world holding the entity.
--- @param entity Does nothing for one with no live body.
--- @param vx Pixels per second along x, set outright rather than added to.
---     Discarded by Box2D for a static body, which reads back zero.
--- @param vy The same along y, positive downward. Angular velocity is left
---     alone, and the `Motion` column is not written: it is a store for pauses
---     and saves, so it still holds whatever the last of those left.
function physics.setVelocity(world: ecs.World, entity: integer, vx: number, vy: number)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    World.setVelocity(handleOf(row), toMetres(vx), toMetres(vy))
end

--- Applies a continuous force at the body's centre and wakes it.
---
--- Cleared by Box2D at the end of every step, so holding a body up against
--- gravity means calling this every fixed step rather than once.
---
--- @param world The world holding the entity.
--- @param entity Does nothing for one with no live body.
--- @param x Pixel-scaled force along x. Dividing it by the body's mass in
---     kilograms gives the acceleration in pixels per second squared.
--- @param y The same along y, positive downward. Applied at the centre of
---     mass, so neither component imparts spin.
function physics.applyForce(world: ecs.World, entity: integer, x: number, y: number)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    World.applyForce(handleOf(row), toMetres(x), toMetres(y))
end

--- Applies a continuous force at a world-space point and wakes the body.
---
--- Cleared at the end of every step, like `applyForce`.
---
--- @param world The world holding the entity.
--- @param entity Does nothing for one with no live body.
--- @param x Pixel-scaled force along x, read as `applyForce` reads it.
--- @param y The same along y, positive downward.
--- @param pointX Where the force is applied, in world pixels rather than in
---     the body's frame. Off the centre of mass it produces torque as well as
---     acceleration.
--- @param pointY The same along y.
function physics.applyForceAt(world: ecs.World, entity: integer, x: number, y: number, pointX: number, pointY: number)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    World.applyForceAt(handleOf(row), toMetres(x), toMetres(y), toMetres(pointX), toMetres(pointY))
end

--- Applies torque and wakes the body.
---
--- Cleared at the end of every step, like the two forces above.
---
--- @param world The world holding the entity.
--- @param entity Does nothing for one with no live body.
--- @param torque Newton-metres, in Box2D's own units. This is the one quantity
---     the module passes through unscaled, because a torque is a force times a
---     distance and so would need `physics.scale` squared rather than the
---     single factor everything else takes. Positive raises the body's angular
---     velocity, and so the `Transform.rotation` the sync writes.
function physics.applyTorque(world: ecs.World, entity: integer, torque: number)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    World.applyTorque(handleOf(row), torque)
end

--- Reads angular velocity in radians per second.
---
--- Radians need no conversion, so this is the same number Box2D holds, unlike
--- the linear velocity beside it.
---
--- @param world The world holding the entity.
--- @param entity An entity with no live body reads as not spinning rather than
---     raising.
--- @return Radians per second, in the direction a rising `Transform.rotation`
---     turns. Live from Box2D, not the `Motion` column.
function physics.angularVelocity(world: ecs.World, entity: integer): number
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return 0.0
    end
    return World.angularVelocity(handleOf(row))
end

--- Sets angular velocity in radians per second and wakes the body.
---
--- @param world The world holding the entity.
--- @param entity Does nothing for one with no live body.
--- @param omega Radians per second, set outright rather than added to.
---     Discarded by Box2D for a static body and for one declared with
---     `fixedRotation`, so those two read back zero rather than the value just
---     written.
function physics.setAngularVelocity(world: ecs.World, entity: integer, omega: number)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    World.setAngularVelocity(handleOf(row), omega)
end

--- Whether Box2D currently considers the body awake.
---
--- @param world The world holding the entity.
--- @param entity Any entity. One with no live body answers false rather than
---     raising, so this does not tell asleep from absent.
--- @return Whether the body is still being solved. Bodies sleep as an island
---     rather than one at a time, so a body at rest touching a moving one
---     stays awake.
function physics.isAwake(world: ecs.World, entity: integer): boolean
    local row = world:get(entity, RigidBody)
    return row ~= nil and row.index1 ~= 0 and World.isAwake(handleOf(row))
end

--- Wakes or sleeps a body.
---
--- @param world The world holding the entity.
--- @param entity Does nothing for one with no live body.
--- @param awake True wakes it. False puts it to sleep at once rather than
---     waiting for it to come to rest, so a body still moving stops where it
---     is until something touches it or it is woken again.
function physics.setAwake(world: ecs.World, entity: integer, awake: boolean)
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
--- `PreviousTransform` is not moved with it. That column is snapshotted in
--- `FixedFirst` and the renderer interpolates from it, so a teleport in any
--- phase after that is drawn as one frame of travel between the two positions
--- rather than as a jump. Teleporting before `FixedFirst`, or accepting the
--- one frame, are the two ways round it.
---
--- @param world The world holding the entity.
--- @param entity Does nothing at all for one with no live body, `Transform`
---     included, so this is not a way to move an entity physics is not
---     simulating.
--- @param x Where to put the body's origin, in world pixels. This is the pose
---     the shapes are placed relative to, not the centre of mass, so an
---     offset collider lands offset.
--- @param y The same along y, positive downward.
--- @param angle Radians. Nil keeps the entity's current `Transform.rotation`,
---     which is what makes this usable as a move that does not turn anything.
---     Nothing sweeps the gap: a body put across a wall is through it, and a
---     bullet body does not catch that.
function physics.teleport(world: ecs.World, entity: integer, x: number, y: number, angle: number)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    local rotation = angle or world:get(entity, Transform).rotation
    World.setTransform(handleOf(row), toMetres(x), toMetres(y), rotation)
    local transform = world:getMut(entity, Transform)
    transform.x, transform.y, transform.rotation = x, y, rotation
end

--- Casts a segment and returns its nearest collider, in pixels.
---
--- A segment rather than a ray: nothing beyond `x2, y2` is tested, so a cast
--- that finds nothing may only have been too short.
---
--- @param world Answers nil when it has no simulation, which is the same
---     answer a clean miss gives.
--- @param x1 The start of the segment, in world pixels.
--- @param y1 The same along y, positive downward.
--- @param x2 The end of the segment, in world pixels.
--- @param y2 The same along y.
--- @param options May be nil, which tests every shape. Sensors are included:
---     the filter is the only thing that keeps a ray out of one.
--- @return The nearest hit along the segment, or nil when the ray met nothing.
---     A fresh table each call, so it is the caller's to keep, and a cast in a
---     per-frame loop allocates one per call.
function physics.raycast(
    world: ecs.World, x1: number, y1: number, x2: number, y2: number, options: QueryOptions
): RaycastHit
    local simulation = physics.of(world)
    if simulation == nil then
        return nil
    end
    options = options or {}
    local entity, x, y, nx, ny, fraction = simulation:raycast(
        toMetres(x1), toMetres(y1), toMetres(x2), toMetres(y2), options.categoryBits, options.maskBits
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
--- @param options May be nil, which takes Earth-like gravity downward and
---     Box2D's own substep count. Read when the plugin is built rather than
---     when it is added, so one plugin added to two worlds sizes both alike.
--- @return A plugin to hand to `world:addPlugin`. Adding it to a second world
---     gives that world a Box2D world of its own, and neither sees the other's
---     bodies; the solver's threads go the other way and are shared, so a
---     second world naming a `workerCount` the first did not raises rather
---     than resizing the pool.
function physics.plugin(options: PhysicsOptions): function(ecs.World)
    options = options or {}
    local gravity = options.gravity or {0.0, 980.0}

    return function(world: ecs.World)
        -- Per world, so two worlds each installing this get a simulation each
        -- and neither sees the other's bodies. Hoisted into a local here and
        -- closed over by the systems below, so a step costs no resource lookup.
        local simulation <const> = World.create({
            gravity = {
                x = toMetres(gravity[1]),
                y = toMetres(gravity[2]),
            },
            subStepCount = options.subStepCount,
            workerCount = options.workerCount,
        })
        world.resources[simulationKey] = simulation

        local function addShape(body: loader.CValue, entity: integer, collider: Collider): loader.CValue
            local shapeSettings = World.shapeOptions(
                collider.density,
                collider.friction,
                collider.restitution,
                toMetres(collider.offsetX),
                toMetres(collider.offsetY),
                collider.categoryBits,
                collider.maskBits,
                collider.groupIndex as integer,
                collider.isSensor ~= 0,
                entity
            )
            if collider.shape == COLLIDER_SHAPES.circle then
                return World.addCircle(body, toMetres(collider.radius), shapeSettings)
            elseif collider.shape == COLLIDER_SHAPES.capsule then
                return World.addCapsule(body, toMetres(collider.radius), toMetres(collider.length), shapeSettings)
            else
                return World.addBox(body, toMetres(collider.halfWidth), toMetres(collider.halfHeight), shapeSettings)
            end
        end

        local function createBody(
            entity: integer, transform: Transform, declared: Body, collider: Collider
        ): loader.CValue
            local body = simulation:createBody({
                type = BODY_NAMES[declared.kind as integer] or "dynamic",
                position = {x = toMetres(transform.x), y = toMetres(transform.y)},
                angle = transform.rotation,
                fixedRotation = declared.fixedRotation ~= 0,
                gravityScale = declared.gravityScale,
                linearDamping = declared.linearDamping,
                angularDamping = declared.angularDamping,
                sleepEnabled = declared.sleepEnabled ~= 0,
                isBullet = declared.isBullet ~= 0,
                entity = entity,
            })
            addShape(body, entity, collider)
            return body
        end

        local pendingBodies = world:query({
            name = "tecs.PendingBodies",
            include = {Transform, Body, Collider},
            exclude = {RigidBody},
        })
        local detachedBodies = world:query({
            name = "tecs.DetachedBodies",
            include = {RigidBody},
            exclude = {Body},
        })
        local detachedDisabledBodies = world:query({
            name = "tecs.DetachedDisabledBodies",
            include = {RigidBody, ecs.builtins.Disabled},
            exclude = {Body},
        })
        local pausedBodies = world:query({
            name = "tecs.PausedBodies",
            include = {Body, Motion, RigidBody, ecs.builtins.Paused},
            exclude = {PhysicsHeld},
        })
        local resumedBodies = world:query({
            name = "tecs.ResumedBodies",
            include = {Body, Motion, RigidBody, PhysicsHeld},
            exclude = {ecs.builtins.Paused},
        })
        local disabledBodies = world:query({
            name = "tecs.DisabledBodies",
            include = {RigidBody, ecs.builtins.Disabled},
            exclude = {PhysicsDisabled},
        })
        local enabledBodies = world:query({
            name = "tecs.EnabledBodies",
            include = {RigidBody, PhysicsDisabled},
            exclude = {ecs.builtins.Disabled},
        })
        local declaredBodies = world:query({
            name = "tecs.LiveBodyDeclarations",
            include = {Body, RigidBody},
            exclude = {PhysicsHeld, PhysicsDisabled},
        })
        local colliders = world:query({
            name = "tecs.LiveColliders",
            include = {Collider, RigidBody},
        })
        local pendingSecondary = world:query({
            name = "tecs.PendingSecondaryColliders",
            include = {Collider, ColliderOf},
            exclude = {ColliderShape},
        })
        local secondaryColliders = world:query({
            name = "tecs.LiveSecondaryColliders",
            include = {Collider, ColliderOf, ColliderShape},
        })
        local createQueue: {PendingCreation} = {}
        local shapeQueue: {PendingShape} = {}
        local createdBodies: {integer: loader.CValue} = {}

        local bodies = world:query({
            name = "tecs.SimulatedBodies",
            type = "logic",
            include = {Transform, RigidBody},
        })
        local snapshotBodies = world:query({
            name = "tecs.SnapshotBodies",
            include = {Motion, RigidBody},
            exclude = {PhysicsHeld},
        })

        -- A body outlives its entity otherwise. Box2D owns it until something
        -- says so, and nothing else knows the entity is gone, so it keeps
        -- being solved for the rest of the session.
        world:observe(
            0,
            ecs.builtins.OnDespawn,
            function(event: ecs.builtins.OnDespawn)
                local colliderShape = world:get(event.entity, ColliderShape)
                if colliderShape ~= nil and colliderShape.index1 ~= 0 then
                    local shape = shapeOf(colliderShape)
                    if B.b2Shape_IsValid(shape) as boolean then
                        B.b2DestroyShape(shape, true)
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
                if not (B.b2Body_IsValid(body) as boolean) then
                    return
                end
                B.b2DestroyBody(body)
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

        world:addSystem({
            name = "tecs.ReconcileBodies",
            phase = ecs.phases.FixedFirst,
            run = function()
                for archetype, length, entities in detachedBodies:iter() do
                    local rows = archetype:get(RigidBody)
                    for row = 1, length do
                        local body = handleOf(rows[row])
                        if B.b2Body_IsValid(body) as boolean then
                            B.b2DestroyBody(body)
                        end
                        world:remove(entities[row], RigidBody)
                    end
                end
                for archetype, length, entities in detachedDisabledBodies:iter() do
                    local rows = archetype:get(RigidBody)
                    for row = 1, length do
                        local body = handleOf(rows[row])
                        if B.b2Body_IsValid(body) as boolean then
                            B.b2DestroyBody(body)
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
                    World.setVelocity(native, toMetres(pending.motion.vx), toMetres(pending.motion.vy))
                    World.setAngularVelocity(native, pending.motion.omega)
                    local handle = native as loader.CStruct
                    world:set(
                        pending.entity,
                        RigidBody(handle.index1 as number, handle.world0 as number, handle.generation as number)
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
                            if createdBodies[relationship.target] ~= nil or (owner ~= nil and owner.index1 ~= 0) then
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
                    local shape = addShape(owner, pending.entity, pending.collider) as loader.CStruct
                    world:set(
                        pending.entity,
                        ColliderShape(shape.index1 as number, shape.world0 as number, shape.generation as number)
                    )
                end
                table_clear(shapeQueue)
                table_clear(createdBodies)
                world:commit()
            end,
        })

        world:addSystem({
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
                        B.b2Body_SetType(body, 0)
                        world:set(entities[row], PhysicsHeld)
                    end
                end
            end,
        })

        world:addSystem({
            name = "tecs.ReleasePausedBodies",
            phase = ecs.phases.FixedFirst,
            run = function()
                for archetype, length, entities in resumedBodies:iter() do
                    local declarations = archetype:get(Body)
                    local rows = archetype:get(RigidBody)
                    local motions = archetype:get(Motion)
                    for row = 1, length do
                        local body = handleOf(rows[row])
                        B.b2Body_SetType(body, declarations[row].kind)
                        World.setVelocity(body, toMetres(motions[row].vx), toMetres(motions[row].vy))
                        World.setAngularVelocity(body, motions[row].omega)
                        world:remove(entities[row], PhysicsHeld)
                    end
                end
            end,
        })

        world:addSystem({
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
                            local body = B.b2Shape_GetBody(old) as loader.CValue
                            B.b2DestroyShape(old, true)
                            local shape = addShape(body, entities[row], collidersInArchetype[row]) as loader.CStruct
                            rows[row].index1 = shape.index1 as number
                            rows[row].world0 = shape.world0 as number
                            rows[row].generation = shape.generation as number
                        end
                    end
                end
            end,
        })

        world:addSystem({
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
                            B.b2Body_SetType(body, declared.kind)
                            B.b2Body_SetLinearDamping(body, declared.linearDamping)
                            B.b2Body_SetAngularDamping(body, declared.angularDamping)
                            B.b2Body_SetGravityScale(body, declared.gravityScale)
                            B.b2Body_SetFixedRotation(body, declared.fixedRotation ~= 0)
                            B.b2Body_SetBullet(body, declared.isBullet ~= 0)
                            B.b2Body_EnableSleep(body, declared.sleepEnabled ~= 0)
                        end
                    end
                end
            end,
        })

        world:addSystem({
            name = "tecs.DisablePhysicsBodies",
            phase = ecs.phases.FixedFirst,
            run = function()
                for archetype, length, entities in disabledBodies:iter() do
                    local rows = archetype:get(RigidBody)
                    for row = 1, length do
                        B.b2Body_Disable(handleOf(rows[row]))
                        world:set(entities[row], PhysicsDisabled)
                    end
                end
            end,
        })

        world:addSystem({
            name = "tecs.EnablePhysicsBodies",
            phase = ecs.phases.FixedFirst,
            run = function()
                for archetype, length, entities in enabledBodies:iter() do
                    local rows = archetype:get(RigidBody)
                    for row = 1, length do
                        B.b2Body_Enable(handleOf(rows[row]))
                        world:remove(entities[row], PhysicsDisabled)
                    end
                end
            end,
        })

        world:addSystem({
            name = "tecs.StepPhysics",
            phase = ecs.phases.FixedUpdate,
            run = function()
                local started = timing.begin()
                -- The rate comes from the world rather than from an option
                -- here. Two numbers that have to agree and can disagree is a
                -- simulation that integrates at one rate while the phase
                -- driving it runs at another.
                simulation:step((world:getFixedTiming()))

                -- Box2D returns contiguous event buffers valid until the next
                -- step. Draining them here is callback-safe and gives gameplay
                -- observers the fixed-step result before FixedPostUpdate.
                local contacts = B.b2World_GetContactEvents(simulation.handle) as loader.CStruct
                local begins = contacts.beginEvents as {integer: loader.CStruct}
                for index = 0, (contacts.beginCount as integer) - 1 do
                    local event = begins[index]
                    world:emit(
                        0,
                        ContactBegin,
                        World.entityOfShape(event.shapeIdA as loader.CValue),
                        World.entityOfShape(event.shapeIdB as loader.CValue)
                    )
                end
                local ends = contacts.endEvents as {integer: loader.CStruct}
                for index = 0, (contacts.endCount as integer) - 1 do
                    local event = ends[index]
                    world:emit(
                        0,
                        ContactEnd,
                        World.entityOfShape(event.shapeIdA as loader.CValue),
                        World.entityOfShape(event.shapeIdB as loader.CValue)
                    )
                end
                local hits = contacts.hitEvents as {integer: loader.CStruct}
                for index = 0, (contacts.hitCount as integer) - 1 do
                    local event = hits[index]
                    local point = event.point as loader.CStruct
                    local normal = event.normal as loader.CStruct
                    world:emit(
                        0,
                        ContactHit,
                        World.entityOfShape(event.shapeIdA as loader.CValue),
                        World.entityOfShape(event.shapeIdB as loader.CValue),
                        toPixels(point.x as number),
                        toPixels(point.y as number),
                        normal.x as number,
                        normal.y as number,
                        toPixels(event.approachSpeed as number)
                    )
                end

                local sensors = B.b2World_GetSensorEvents(simulation.handle) as loader.CStruct
                local sensorBegins = sensors.beginEvents as {integer: loader.CStruct}
                for index = 0, (sensors.beginCount as integer) - 1 do
                    local event = sensorBegins[index]
                    world:emit(
                        0,
                        SensorBegin,
                        World.entityOfShape(event.sensorShapeId as loader.CValue),
                        World.entityOfShape(event.visitorShapeId as loader.CValue)
                    )
                end
                local sensorEnds = sensors.endEvents as {integer: loader.CStruct}
                for index = 0, (sensors.endCount as integer) - 1 do
                    local event = sensorEnds[index]
                    world:emit(
                        0,
                        SensorEnd,
                        World.entityOfShape(event.sensorShapeId as loader.CValue),
                        World.entityOfShape(event.visitorShapeId as loader.CValue)
                    )
                end
                timing.finish(STEP, started)
            end,
        })

        world:addSystem({
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
        })

        world:addSnapshotHandler({
            name = "tecs.physics",
            save = function(_world: ecs.World): any
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
                    workerCount = simulation.taskPool.workerCount,
                    subStepCount = simulation.subStepCount,
                }
            end,
        })

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
        world:addSystem({
            name = "tecs.ShutdownPhysics",
            phase = ecs.phases.Shutdown,
            run = function() world.resources[simulationKey] = nil; simulation:destroy() end,
        })
    end
end

return physics
