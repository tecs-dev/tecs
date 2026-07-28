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
    serialize = function(_instance: RigidBody): {string: any}
        -- The handle stays out of the file. It is this run's numbering:
        -- Box2D keeps `index1` dense and reuses it, so a saved one names
        -- whichever body the loading run happens to have put in that slot,
        -- and the sync would write a stranger's pose into this entity's
        -- Transform with nothing to signal it.
        return {}
    end,
    deserialize = function(_world: ecs.World, _data: {string: any}): RigidBody
        -- Restored as the null handle, which is inert everywhere: the sync
        -- reads no movement for it, the impulse and velocity calls refuse
        -- it, and `physics.hasBody` answers false. The file does carry the
        -- description now, in `Body` and `Collider`, so a rebuild has what it
        -- needs; nothing rebuilds yet, so an entity that simulated before a
        -- load does not simulate after it until something attaches again.
        return RigidBody(0, 0, 0)
    end,
})

local record BodyOptions
    --- "static", "kinematic", or "dynamic".
    type: string
    --- Half-extents in pixels.
    halfWidth: number
    halfHeight: number
    --- Radius in pixels. Takes precedence over the box extents.
    radius: number
    density: number
    friction: number
    restitution: number
    fixedRotation: boolean
end

local record PhysicsOptions
    --- Gravity in pixels per second squared, matching world units.
    gravity: {number}
    --- Solver substeps per step.
    subStepCount: integer
    --- Worker slots the solver runs across, counting the thread that steps
    --- the world. One is single threaded. Defaults to a count derived from
    --- the machine.
    workerCount: integer
end

local record physics
    RigidBody: RigidBody
    Body: Body
    Collider: Collider
    Motion: Motion
    --- Pixels per simulated metre.
    scale: number

    applyImpulseTo: function(row: RigidBody, x: number, y: number)
end

physics.RigidBody = RigidBody
physics.Body = Body
physics.Collider = Collider
physics.Motion = Motion
physics.scale = PIXELS_PER_METRE

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
function physics.of(world: ecs.World): World
    return world.resources[simulationKey]
end

local function toMetres(pixels: number): number
    return pixels / PIXELS_PER_METRE
end

local function toPixels(metres: number): number
    return metres * PIXELS_PER_METRE
end

--- Declares a body on `entity` and creates it in the world's simulation.
---
--- Writes `Body` and `Collider`, which are the description a snapshot and a
--- rebuild read, and `Motion`, which `Body` requires. The pose comes from the
--- entity's Transform, so an entity is positioned the same way whether or not
--- it simulates.
function physics.attach(world: ecs.World, entity: integer, options: BodyOptions): loader.CValue
    options = options or {}

    local simulation = physics.of(world)
    if simulation == nil then
        error("tecs: this world has no physics simulation; add physics.plugin to it first", 2)
    end

    local kind = BODY_KINDS[options.type or "dynamic"]
    if kind == nil then
        error(("tecs: unknown body type %q; expected static, kinematic or dynamic"):format(options.type), 2)
    end
    local round = options.radius ~= nil

    -- The declaration goes on first, and `Body` requires `Transform`, so an
    -- entity that had no pose has a default one at the origin by the time the
    -- pose is read below. That is what closes the case rather than a nil test:
    -- the sync writes back into `Transform` unconditionally, so a body with
    -- none would be a body nothing can see.
    world:set(entity, Body(kind, options.fixedRotation and 1 or 0))
    world:set(
        entity,
        Collider(
            round and COLLIDER_SHAPES.circle or COLLIDER_SHAPES.box,
            options.halfWidth or 8.0,
            options.halfHeight or 8.0,
            round and options.radius or 0.0,
            -- length, offsetX, offsetY: reserved, and not reachable through
            -- the options table until the capsule and offset shapes are.
            0.0,
            0.0,
            0.0,
            options.density,
            options.friction,
            options.restitution
        )
    )

    local transform = world:get(entity, Transform)
    local body = simulation:createBody({
        type = options.type or "dynamic",
        position = {x = toMetres(transform.x), y = toMetres(transform.y)},
        angle = transform.rotation,
        fixedRotation = options.fixedRotation,
    })

    if round then
        World.addCircle(
            body,
            toMetres(options.radius),
            {
                density = options.density,
                friction = options.friction,
                restitution = options.restitution,
            }
        )
    else
        World.addBox(
            body,
            toMetres(options.halfWidth or 8.0),
            toMetres(options.halfHeight or 8.0),
            {
                density = options.density,
                friction = options.friction,
                restitution = options.restitution,
            }
        )
    end

    local handle = body as loader.CStruct
    world:set(entity, RigidBody(handle.index1 as number, handle.world0 as number, handle.generation as number))

    -- Seeded from where the body starts, so the first frame interpolates
    -- between a real position and a real position rather than from the
    -- origin. A body advances in fixed steps while frames arrive whenever the
    -- display asks, so without this it steps visibly instead of moving.
    world:set(entity, components.PreviousTransform(transform.x, transform.y, transform.rotation))

    return body
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

--- Whether `entity` has a body Box2D is still solving.
---
--- False for an entity whose RigidBody came out of a snapshot. A load
--- restores the row as the null handle rather than a body id this run never
--- issued, so this is how a game tells "was simulating and is not any more"
--- from "never had a body", and the two are worth telling apart: nothing
--- rebuilds a body on load.
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

--- Pushes a body, in pixels per second squared applied at its centre.
---
--- An impulse rather than a force, so the effect does not depend on how long
--- the step happened to be. Wakes the body: Box2D lets a resting island sleep,
--- and pushing a sleeping body without waking it does nothing.
function physics.applyImpulse(world: ecs.World, entity: integer, x: number, y: number)
    local row = world:get(entity, RigidBody)
    if row == nil then
        return
    end
    physics.applyImpulseTo(row, x, y)
end

--- The same, given a RigidBody row already in hand.
---
--- For a system walking a column, where going back through the entity would
--- cost a lookup per body per frame.
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

--- Reads a body's velocity, live from Box2D, in pixels per second.
---
--- Pixels, like every other number this module takes and returns: the extents
--- and radius `attach` is given, the impulse components, and the plugin's
--- gravity. A caller that wants metres divides by `physics.scale`.
---
--- This rather than the `Motion` column is what a body is doing right now.
--- `Motion` is a store written at a pause and a save, not a mirror.
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
function physics.setVelocity(world: ecs.World, entity: integer, vx: number, vy: number)
    local row = world:get(entity, RigidBody)
    if row == nil or row.index1 == 0 then
        return
    end
    World.setVelocity(handleOf(row), toMetres(vx), toMetres(vy))
end

--- Installs the simulation and its sync.
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

        -- A logic query, so a paused entity keeps its Transform where it was
        -- instead of being followed around by its body. This gates the
        -- write-back and not the solve: Box2D steps a world rather than a
        -- body, so a paused body is still in the pile, still colliding, and
        -- still moving, and unpausing snaps its Transform to wherever it got
        -- to. Taking it out of the solve properly means putting its type and
        -- its velocity somewhere they survive the pause, which is a decision
        -- about what a RigidBody holds rather than a change to this query.
        local bodies = world:query({
            name = "tecs.SimulatedBodies",
            type = "logic",
            include = {Transform, RigidBody},
        })

        -- A body outlives its entity otherwise. Box2D owns it until something
        -- says so, and nothing else knows the entity is gone, so it keeps
        -- being solved for the rest of the session.
        world:observe(
            0,
            ecs.builtins.OnDespawn,
            function(event: ecs.builtins.OnDespawn)
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
            name = "tecs.StepPhysics",
            phase = ecs.phases.FixedUpdate,
            run = function()
                local started = timing.begin()
                -- The rate comes from the world rather than from an option
                -- here. Two numbers that have to agree and can disagree is a
                -- simulation that integrates at one rate while the phase
                -- driving it runs at another.
                simulation:step((world:getFixedTiming()))
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
