--- Physics as part of the world.
---
--- A `RigidBody` holds a Box2D body handle. Box2D 3 handles are small value
--- structs rather than pointers to C++ objects, so the handle lives directly
--- in an archetype column: no userdata, no finalizers, and no boundary
--- crossing to read one back.
---
--- Stepping happens in FixedUpdate. Box2D's solver is not robust to a varying
--- timestep and a variable one makes replay diverge, so the fixed phase is not
--- a preference here, it is a requirement.

local ecs <const> = require("tecs.ecs")
local loader <const> = require("tecs.ffi.loader")
local World <const> = require("tecs.physics.World")
local box2d <const> = require("tecs.ffi.box2d")
local components <const> = require("tecs.components")

local B <const> = box2d.C
local Transform2D <const> = components.Transform2D

local type Component = ecs.Component

--- Pixels per simulated metre.
---
--- Box2D is tuned for objects roughly 0.1 to 10 units across, so simulating
--- directly in pixels puts every body far outside the range its solver
--- tolerances were chosen for.
local PIXELS_PER_METRE <const> = 32.0

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
        { "index1", "int32_t" },
        { "world0", "uint16_t" },
        { "generation", "uint16_t" },
    },
    defaults = { 0, 0, 0 },
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
    --- Fixed timestep in seconds.
    timeStep: number
    --- "fixed" steps in the fixed phases, which is what a game wants: the
    --- simulation advances at a constant rate however fast frames are.
    --- "frame" steps exactly once per frame instead. That decouples the work
    --- done from the frame rate it produces, which a benchmark needs and a
    --- game does not.
    stepping: string
end

local record physics
    RigidBody: RigidBody
    --- Pixels per simulated metre.
    scale: number
    world: World

    applyImpulseTo: function(row: RigidBody, x: number, y: number)
end

physics.RigidBody = RigidBody
physics.scale = PIXELS_PER_METRE

local function toMetres(pixels: number): number
    return pixels / PIXELS_PER_METRE
end

local function toPixels(metres: number): number
    return metres * PIXELS_PER_METRE
end

--- Creates a body for `entity` and attaches a RigidBody to it.
---
--- Reads the entity's Transform2D for the initial pose, so an entity is
--- positioned the same way whether or not it simulates.
function physics.attach(world: ecs.World, entity: integer,
                        options: BodyOptions): loader.CValue
    options = options or {}

    local transform = world:get(entity, Transform2D)
    local x, y, angle = 0.0, 0.0, 0.0
    if transform ~= nil then
        x, y, angle = transform.x, transform.y, transform.rotation
    end

    local body = physics.world:createBody({
        type = options.type or "dynamic",
        position = { x = toMetres(x), y = toMetres(y) },
        angle = angle,
        fixedRotation = options.fixedRotation,
    })

    if options.radius ~= nil then
        World.addCircle(body, toMetres(options.radius), {
            density = options.density,
            friction = options.friction,
            restitution = options.restitution,
        })
    else
        World.addBox(body,
            toMetres(options.halfWidth or 8.0),
            toMetres(options.halfHeight or 8.0), {
                density = options.density,
                friction = options.friction,
                restitution = options.restitution,
            })
    end

    local handle = body as loader.CStruct
    world:set(entity, RigidBody(
        handle.index1 as number,
        handle.world0 as number,
        handle.generation as number))

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

--- Pushes a body, in pixels per second squared applied at its centre.
---
--- An impulse rather than a force, so the effect does not depend on how long
--- the step happened to be. Wakes the body: Box2D lets a resting island sleep,
--- and pushing a sleeping body without waking it does nothing.
function physics.applyImpulse(world: ecs.World, entity: integer,
                              x: number, y: number)
    local row = world:get(entity, RigidBody)
    if row == nil then return end
    physics.applyImpulseTo(row, x, y)
end

--- The same, given a RigidBody row already in hand.
---
--- For a system walking a column, where going back through the entity would
--- cost a lookup per body per frame.
function physics.applyImpulseTo(row: RigidBody, x: number, y: number)
    local body = handleOf(row)
    local impulse = loader.newStruct("b2Vec2")
    local fields = impulse as loader.CStruct
    fields.x = toMetres(x)
    fields.y = toMetres(y)
    B.b2Body_ApplyLinearImpulseToCenter(body, impulse, true)
end

--- Reads a body's velocity, in pixels per second.
function physics.velocity(world: ecs.World, entity: integer): number, number
    local row = world:get(entity, RigidBody)
    if row == nil then return 0.0, 0.0 end
    return World.getVelocity(handleOf(row))
end

--- Installs the simulation and its sync.
function physics.plugin(options: PhysicsOptions): function(ecs.World)
    options = options or {}
    local gravity = options.gravity or { 0.0, 980.0 }
    local timeStep = options.timeStep or 1.0 / 60.0

    return function(world: ecs.World)
        physics.world = World.create({
            gravity = {
                x = toMetres(gravity[1]),
                y = toMetres(gravity[2]),
            },
            subStepCount = options.subStepCount,
        })

        local bodies = world:query({ include = { Transform2D, RigidBody } })

        local perFrame <const> = options.stepping == "frame"

        world:addSystem({
            name = "tecs.StepPhysics",
            phase = perFrame and ecs.phases.Update or ecs.phases.FixedUpdate,
            run = function()
                physics.world:step(timeStep)
            end,
        })

        world:addSystem({
            name = "tecs.SyncBodyTransforms",
            phase = perFrame and ecs.phases.PostUpdate
                or ecs.phases.FixedPostUpdate,
            run = function()
                for archetype, length in bodies:iter() do
                    -- Transforms are written from the simulation, so the
                    -- column is taken mutable. The body column is only read.
                    local transforms = archetype:getMut(Transform2D)
                    local rows = archetype:get(RigidBody)
                    for row = 1, length do
                        local body = handleOf(rows[row])
                        local px, py = World.getPosition(body)
                        transforms[row].x = toPixels(px)
                        transforms[row].y = toPixels(py)
                        transforms[row].rotation = World.getAngle(body)
                    end
                end
            end,
        })
    end
end

return physics
