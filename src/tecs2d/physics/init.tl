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

local tecs <const> = require("tecs")
local loader <const> = require("tecs2d.ffi.loader")
local World <const> = require("tecs2d.physics.World")
local components <const> = require("tecs2d.components")

local Transform2D <const> = components.Transform2D

local type Component = tecs.Component

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

tecs.newFFIComponent({
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
end

local record physics
    RigidBody: RigidBody
    --- Pixels per simulated metre.
    scale: number
    world: World
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
function physics.attach(world: tecs.World, entity: integer,
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

--- Installs the simulation and its sync.
function physics.plugin(options: PhysicsOptions): function(tecs.World)
    options = options or {}
    local gravity = options.gravity or { 0.0, 980.0 }
    local timeStep = options.timeStep or 1.0 / 60.0

    return function(world: tecs.World)
        physics.world = World.create({
            gravity = {
                x = toMetres(gravity[1]),
                y = toMetres(gravity[2]),
            },
            subStepCount = options.subStepCount,
        })

        local bodies = world:query({ include = { Transform2D, RigidBody } })

        world:addSystem({
            name = "tecs2d.StepPhysics",
            phase = tecs.phases.FixedUpdate,
            run = function()
                physics.world:step(timeStep)
            end,
        })

        world:addSystem({
            name = "tecs2d.SyncBodyTransforms",
            phase = tecs.phases.FixedPostUpdate,
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
