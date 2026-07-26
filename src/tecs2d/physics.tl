--- tecs2d.physics: Box2D physics integration for Love2D games.
---
--- Uses Love's built-in love.physics (Box2D) for collision detection and response.
---
--- Example usage:
--- ```
--- local physics = require("tecs2d.physics")
---
--- love.physics.setMeter(64)
--- local physicsWorld = love.physics.newWorld(0, 300, true)
--- world:addPlugin(physics.new({
---     world = physicsWorld
--- }))
---
--- world:spawn(
---     Transform(100, 100),
---     physics.Collider.new({ shape = "circle", radius = 16 }),
---     physics.RigidBody.new({ mass = 1 })
--- )
---
--- -- Listen for collisions on a specific entity
--- world:observe(id, physics.BeginContact, function(e)
---     print("Collided with", e.other)
--- end)
--- ```

local tecs <const> = require("tecs")
local bit <const> = require("bit")

local band <const> = bit.band
local type World = tecs.World
local Transform <const> = tecs.builtins.Transform

-------------------------------------------------------------------------------
-- Component Definitions
-------------------------------------------------------------------------------

local record physics_components
    --- Supported primitive collider shapes.
    enum ShapeType
        "circle"
        "rectangle"
    end

    --- One shape in a multi-shape collider.
    record ShapeConfig
        --- Primitive shape type.
        type: ShapeType
        --- Circle radius. Defaults to 16.
        radius: number        -- for circle
        --- Rectangle width. Defaults to 32.
        width: number         -- for rectangle
        --- Rectangle height. Defaults to 32.
        height: number        -- for rectangle
        --- Horizontal offset from the body origin. Defaults to 0.
        offsetX: number       -- offset from body center
        --- Vertical offset from the body origin. Defaults to 0.
        offsetY: number       -- offset from body center
        --- Whether this shape detects contacts without collision response.
        sensor: boolean
        --- Optional name copied into contact shape data.
        name: string          -- optional name for the shape
    end

    --- Collider construction options.
    record ColliderConfig
        --- Primitive shape used when shapes is omitted. Defaults to "circle".
        shape: ShapeType
        --- Circle radius. Defaults to 16.
        radius: number
        --- Rectangle width. Defaults to 32.
        width: number
        --- Rectangle height. Defaults to 32.
        height: number
        --- Whether the single primitive shape is a sensor.
        sensor: boolean
        --- Box2D collision group index. Defaults to 0.
        groupIndex: integer
        --- Category bit mask. Defaults to all 16 categories.
        categories: integer
        --- Collision mask. Defaults to all 16 categories.
        mask: integer
        --- Static-body restitution. Defaults to 0.
        restitution: number
        --- Static-body friction. Defaults to 0.3.
        friction: number
        --- Explicit shapes sharing one body; replaces the primitive fields.
        shapes: {ShapeConfig}
    end

    --- Collision geometry and its runtime Box2D state.
    record Collider is tecs.Component
        -- Primary shape (for simple single-shape case)
        shapeType: ShapeType
        radius: number
        halfWidth: number
        halfHeight: number
        sensor: boolean
        -- Filtering
        groupIndex: integer
        categories: integer
        mask: integer
        -- Physics properties (used for static bodies, or as defaults)
        restitution: number
        friction: number
        -- Box2D references
        body: love.physics.Body
        shape: love.physics.Shape
        shapeList: {love.physics.Shape}  -- for multi-shape colliders
        -- Multi-shape config (stored for body creation)
        shapes: {ShapeConfig}
        -- Snapshot-restored runtime velocity. Box2D bodies are recreated
        -- after load, so these fields bridge saved body state into
        -- physics.createBodies.
        runtimeVx: number
        runtimeVy: number
        runtimeAngularVelocity: number
        hasRuntimeVelocity: boolean

        --- Create a Collider from primitive or multi-shape configuration.
        metamethod __call: function(self, config: ColliderConfig): Collider
    end

    --- Dynamic-body construction options.
    record RigidBodyConfig
        --- Box2D body type. Defaults to "dynamic".
        bodyType: love.physics.BodyType
        --- Optional explicit total mass; density-derived when omitted.
        mass: number
        --- Shape density. Defaults to 1.
        density: number
        --- Shape restitution. Defaults to 0.
        restitution: number
        --- Shape friction. Defaults to 0.3.
        friction: number
        --- Linear damping. Defaults to 0.
        drag: number
        --- Angular damping. Defaults to 0.
        angularDrag: number
        --- Initial horizontal velocity.
        vx: number
        --- Initial vertical velocity.
        vy: number
        --- Whether continuous collision detection is enabled.
        bullet: boolean
        --- Whether rotation is locked.
        fixedRotation: boolean
    end

    --- Configures a Collider as a dynamic Box2D body.
    record RigidBody is tecs.Component
        bodyType: love.physics.BodyType
        mass: number
        density: number
        restitution: number
        friction: number
        drag: number
        angularDrag: number
        initialVx: number
        initialVy: number
        bullet: boolean
        fixedRotation: boolean

        --- Create dynamic-body configuration for a Collider.
        metamethod __call: function(self, config: RigidBodyConfig): RigidBody
    end

    --- Marks a Collider as a static Box2D body.
    record StaticBody is tecs.Component
        metamethod __call: function(self): StaticBody
    end
end

-- Register components with tecs
tecs.newComponent({
    name = "PhysicsCollider",
    container = physics_components.Collider,
    new = function(data: {string: any}): physics_components.Collider
        local config = (data or {}) as physics_components.ColliderConfig
        return {
            shapeType = config.shape or "circle",
            radius = config.radius or 16,
            halfWidth = (config.width or 32) / 2,
            halfHeight = (config.height or 32) / 2,
            sensor = config.sensor or false,
            groupIndex = config.groupIndex or 0,
            categories = config.categories or 0xFFFF,
            mask = config.mask or 0xFFFF,
            restitution = config.restitution or 0,
            friction = config.friction or 0.3,
            body = nil,
            shape = nil,
            shapeList = nil,
            shapes = config.shapes,
            runtimeVx = (config as {string: number}).runtimeVx or 0,
            runtimeVy = (config as {string: number}).runtimeVy or 0,
            runtimeAngularVelocity = (config as {string: number}).runtimeAngularVelocity or 0,
            hasRuntimeVelocity = ((config as {string: boolean}).hasRuntimeVelocity or false) as boolean,
        } as physics_components.Collider
    end,
    serialize = function(c: physics_components.Collider): {string: any}
        local vx = c.runtimeVx
        local vy = c.runtimeVy
        local av = c.runtimeAngularVelocity
        local hasRuntimeVelocity = c.hasRuntimeVelocity
        if c.body then
            vx, vy = c.body:getLinearVelocity()
            av = c.body:getAngularVelocity()
            hasRuntimeVelocity = true
        end
        return {
            shape      = c.shapeType,
            radius     = c.radius,
            width      = c.halfWidth * 2,
            height     = c.halfHeight * 2,
            sensor     = c.sensor,
            groupIndex = c.groupIndex,
            categories = c.categories,
            mask       = c.mask,
            restitution = c.restitution,
            friction   = c.friction,
            shapes     = c.shapes,
            runtimeVx = vx,
            runtimeVy = vy,
            runtimeAngularVelocity = av,
            hasRuntimeVelocity = hasRuntimeVelocity,
        }
    end,
    -- Body teardown on remove is handled by a query observer
    -- registered in `physics.new`'s plugin -- see the
    -- `physics.ColliderLifecycle` observer below.
})

tecs.newComponent({
    name = "PhysicsRigidBody",
    container = physics_components.RigidBody,
    new = function(data: {string: any}): physics_components.RigidBody
        local config = (data or {}) as physics_components.RigidBodyConfig
        return {
            bodyType = config.bodyType or "dynamic",
            mass = config.mass,
            density = config.density or 1,
            restitution = config.restitution or 0,
            friction = config.friction or 0.3,
            drag = config.drag or 0,
            angularDrag = config.angularDrag or 0,
            initialVx = config.vx or 0,
            initialVy = config.vy or 0,
            bullet = config.bullet or false,
            fixedRotation = config.fixedRotation
        } as physics_components.RigidBody
    end,
    serialize = function(rb: physics_components.RigidBody): {string: any}
        return {
            bodyType      = rb.bodyType,
            mass          = rb.mass,
            density       = rb.density,
            restitution   = rb.restitution,
            friction      = rb.friction,
            drag          = rb.drag,
            angularDrag   = rb.angularDrag,
            vx            = rb.initialVx,
            vy            = rb.initialVy,
            bullet        = rb.bullet,
            fixedRotation = rb.fixedRotation,
        }
    end,
})

tecs.newComponent({
    name = "PhysicsStaticBody",
    container = physics_components.StaticBody,
})

-------------------------------------------------------------------------------
-- Collision Events
-------------------------------------------------------------------------------

local record physics_events
    --- Data attached to each shape for collision callbacks.
    record ShapeData
        entity: integer
        layer: integer            -- from transform.layer, entities in different layers don't collide
        categories: integer
        mask: integer
        name: string
    end

    --- Emitted when two shapes begin touching.
    record BeginContact is tecs.Event
        other: integer          -- The other entity
        shape: love.physics.Shape
        otherShape: love.physics.Shape
        contact: love.physics.Contact
        normalX: number
        normalY: number

        metamethod __call: function(
            self,
            other: integer,
            shape: love.physics.Shape,
            otherShape: love.physics.Shape,
            contact: love.physics.Contact,
            nx: number,
            ny: number
        ): BeginContact
    end

    --- Emitted when two shapes stop touching.
    record EndContact is tecs.Event
        other: integer
        shape: love.physics.Shape
        otherShape: love.physics.Shape
        contact: love.physics.Contact
        normalX: number
        normalY: number

        metamethod __call: function(
            self,
            other: integer,
            shape: love.physics.Shape,
            otherShape: love.physics.Shape,
            contact: love.physics.Contact,
            nx: number,
            ny: number
        ): EndContact
    end

    --- Emitted before collision response is calculated (can disable contact).
    record PreSolve is tecs.Event
        other: integer
        shape: love.physics.Shape
        otherShape: love.physics.Shape
        contact: love.physics.Contact

        metamethod __call: function(
            self,
            other: integer,
            shape: love.physics.Shape,
            otherShape: love.physics.Shape,
            contact: love.physics.Contact
        ): PreSolve
    end

    --- Emitted after collision response with impulse data.
    record PostSolve is tecs.Event
        other: integer
        shape: love.physics.Shape
        otherShape: love.physics.Shape
        contact: love.physics.Contact
        normalImpulse: number
        tangentImpulse: number

        metamethod __call: function(
            self,
            other: integer,
            shape: love.physics.Shape,
            otherShape: love.physics.Shape,
            contact: love.physics.Contact,
            normalImpulse: number,
            tangentImpulse: number
        ): PostSolve
    end
end

physics_events.BeginContact.init = function(
    e: physics_events.BeginContact,
    other: integer,
    shape: love.physics.Shape,
    otherShape: love.physics.Shape,
    contact: love.physics.Contact,
    nx: number,
    ny: number
)
    e.other, e.shape, e.otherShape, e.contact, e.normalX, e.normalY = other, shape, otherShape, contact, nx, ny
end
tecs.newEvent(physics_events.BeginContact)

physics_events.EndContact.init = function(
    e: physics_events.EndContact,
    other: integer,
    shape: love.physics.Shape,
    otherShape: love.physics.Shape,
    contact: love.physics.Contact,
    nx: number,
    ny: number
)
    e.other, e.shape, e.otherShape, e.contact, e.normalX, e.normalY = other, shape, otherShape, contact, nx, ny
end
tecs.newEvent(physics_events.EndContact)

physics_events.PreSolve.init = function(
    e: physics_events.PreSolve,
    other: integer,
    shape: love.physics.Shape,
    otherShape: love.physics.Shape,
    contact: love.physics.Contact
)
    e.other, e.shape, e.otherShape, e.contact = other, shape, otherShape, contact
end
tecs.newEvent(physics_events.PreSolve)

physics_events.PostSolve.init = function(
    e: physics_events.PostSolve,
    other: integer,
    shape: love.physics.Shape,
    otherShape: love.physics.Shape,
    contact: love.physics.Contact,
    normalImpulse: number,
    tangentImpulse: number
)
    e.other, e.shape, e.otherShape, e.contact = other, shape, otherShape, contact
    e.normalImpulse, e.tangentImpulse = normalImpulse, tangentImpulse
end
tecs.newEvent(physics_events.PostSolve)

-------------------------------------------------------------------------------
-- Module
-------------------------------------------------------------------------------

local record physics is tecs.Key<physics.PhysicsState>
    --- Collision geometry component.
    Collider: physics_components.Collider
    --- Dynamic-body configuration component.
    RigidBody: physics_components.RigidBody
    --- Static-body tag component.
    StaticBody: physics_components.StaticBody

    --- Event emitted when contact begins.
    BeginContact: physics_events.BeginContact
    --- Event emitted when contact ends.
    EndContact: physics_events.EndContact
    --- Event emitted before Box2D resolves a contact.
    PreSolve: physics_events.PreSolve
    --- Event emitted after Box2D resolves a contact.
    PostSolve: physics_events.PostSolve

    --- Metadata stored on plugin-owned Box2D shapes.
    type ShapeData = physics_events.ShapeData
    --- Configuration for one shape in a multi-shape collider.
    type ShapeConfig = physics_components.ShapeConfig
    --- Contact filter invoked with both shapes and their Tecs metadata.
    type ContactFilterFn = function(
        shapeA: love.physics.Shape,
        shapeB: love.physics.Shape,
        dataA: ShapeData,
        dataB: ShapeData
    ): boolean

    record Config
        --- The Box2D world. Create with love.physics.newWorld(gx, gy, allowSleep).
        world: love.physics.World
        --- Custom contact filter. If provided, replaces the default filter entirely.
        contactFilter: ContactFilterFn
        --- Default for RigidBody.fixedRotation when not specified. Defaults to false.
        defaultFixedRotation: boolean
    end

    record PhysicsState
        --- The Box2D world owned by this plugin.
        world: love.physics.World
        --- Default used for RigidBody values that omit fixedRotation.
        defaultFixedRotation: boolean
    end

    --- Create a physics plugin for a Box2D world.
    new: function(config: Config): tecs.Plugin

    --- Helper to create category bitmask from category numbers (1-16).
    --- Errors when a category is not an integer in that range.
    categories: function(...: integer): integer
end

physics.Collider = physics_components.Collider
physics.RigidBody = physics_components.RigidBody
physics.StaticBody = physics_components.StaticBody
physics.BeginContact = physics_events.BeginContact
physics.EndContact = physics_events.EndContact
physics.PreSolve = physics_events.PreSolve
physics.PostSolve = physics_events.PostSolve


function physics.categories(...: integer): integer
    local result = 0
    for i = 1, select("#", ...) do
        local cat = select(i, ...)
        assert(cat == math.floor(cat) and cat >= 1 and cat <= 16,
            "physics.categories expects integer category numbers from 1 to 16")
        result = bit.bor(result, bit.lshift(1, cat - 1))
    end
    return result
end

-------------------------------------------------------------------------------
-- Default Contact Filter
-------------------------------------------------------------------------------

local function defaultContactFilter(
    _shapeA: love.physics.Shape,
    _shapeB: love.physics.Shape,
    dataA: physics_events.ShapeData,
    dataB: physics_events.ShapeData
): boolean
    if dataA.layer ~= dataB.layer then
        return false
    end

    if band(dataA.categories, dataB.mask) == 0 then
        return false
    end
    if band(dataB.categories, dataA.mask) == 0 then
        return false
    end

    return true
end

-------------------------------------------------------------------------------
-- Plugin
-------------------------------------------------------------------------------

function physics.new(config: physics.Config): tecs.Plugin
    assert(config and config.world, "physics.new requires config.world (create with love.physics.newWorld)")
    local physicsWorld = config.world
    local defaultFixedRotation: boolean = false
    if config.defaultFixedRotation ~= nil then
        defaultFixedRotation = config.defaultFixedRotation
    end
    local contactFilterFn = config.contactFilter or defaultContactFilter
    return function(world: World)
        local state: physics.PhysicsState = {
            world = physicsWorld,
            defaultFixedRotation = defaultFixedRotation
        }
        world.resources[physics] = state

        local Collider = physics_components.Collider
        local RigidBody = physics_components.RigidBody
        local StaticBody = physics_components.StaticBody

        -----------------------------------------------------------------------
        -- Collider lifecycle
        -----------------------------------------------------------------------
        -- Destroy the Box2D body when Collider leaves an entity. Reads
        -- the pre-removal column so `collider.body` is still valid at
        -- notification time.
        world:query({
            name = "physics.ColliderLifecycle",
            include = {Collider},
            onEntitiesRemoved = function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
                local colliders = archetype:getMut(Collider) as {physics_components.Collider}
                for row = firstRow, lastRow do
                    local c = colliders[row]
                    if c and c.body then
                        c.body:destroy()
                        c.body = nil
                    end
                end
            end,
        })

        -----------------------------------------------------------------------
        -- Contact Filter
        -----------------------------------------------------------------------
        local function collisionFilter(fixtureA: love.physics.Fixture, fixtureB: love.physics.Fixture): boolean
            -- In Love2D 12, Shape and Fixture are merged - fixtures ARE shapes
            local shapeA = fixtureA as love.physics.Shape
            local shapeB = fixtureB as love.physics.Shape
            local dataA = fixtureA:getUserData() as physics_events.ShapeData
            local dataB = fixtureB:getUserData() as physics_events.ShapeData

            if not dataA or not dataB then
                return true  -- No data = default Box2D behavior
            end

            return contactFilterFn(shapeA, shapeB, dataA, dataB)
        end

        physicsWorld:setContactFilter(collisionFilter)

        -----------------------------------------------------------------------
        -- Contact Callbacks
        -----------------------------------------------------------------------
        -- Shared preamble for the contact callbacks. In Love2D 12, Shape and
        -- Fixture are merged, so the fixtures ARE shapes. Tile-collision
        -- shapes (and any other shapes spawned without going through the
        -- physics plugin) carry no user data; entity resolves to 0 in that
        -- direction so contact handlers can still fire for the entity-bound
        -- side.
        local function resolveContact(
            fixtureA: love.physics.Fixture,
            fixtureB: love.physics.Fixture
        ): love.physics.Shape, love.physics.Shape, physics_events.ShapeData, physics_events.ShapeData, integer, integer
            local shapeA = fixtureA as love.physics.Shape
            local shapeB = fixtureB as love.physics.Shape
            local dataA = shapeA:getUserData() as physics_events.ShapeData
            local dataB = shapeB:getUserData() as physics_events.ShapeData
            local entityA = dataA and dataA.entity or 0
            local entityB = dataB and dataB.entity or 0
            return shapeA, shapeB, dataA, dataB, entityA, entityB
        end

        local function beginContact(
            fixtureA: love.physics.Fixture,
            fixtureB: love.physics.Fixture,
            contact: love.physics.Contact
        )
            local shapeA, shapeB, dataA, dataB, entityA, entityB = resolveContact(fixtureA, fixtureB)
            local nx, ny = contact:getNormal()

            if dataA then
                world:emit(dataA.entity, physics_events.BeginContact, entityB, shapeA, shapeB, contact, nx, ny)
            end

            if dataB then
                -- Flip normal for entity B
                world:emit(dataB.entity, physics_events.BeginContact, entityA, shapeB, shapeA, contact, -nx, -ny)
            end
        end

        local function endContact(
            fixtureA: love.physics.Fixture,
            fixtureB: love.physics.Fixture,
            contact: love.physics.Contact
        )
            local shapeA, shapeB, dataA, dataB, entityA, entityB = resolveContact(fixtureA, fixtureB)
            local nx, ny = contact:getNormal()

            if dataA then
                world:emit(dataA.entity, physics_events.EndContact, entityB, shapeA, shapeB, contact, nx, ny)
            end

            if dataB then
                world:emit(dataB.entity, physics_events.EndContact, entityA, shapeB, shapeA, contact, -nx, -ny)
            end
        end

        local function preSolve(
            fixtureA: love.physics.Fixture,
            fixtureB: love.physics.Fixture,
            contact: love.physics.Contact
        )
            local shapeA, shapeB, dataA, dataB, entityA, entityB = resolveContact(fixtureA, fixtureB)

            if dataA then
                world:emit(dataA.entity, physics_events.PreSolve, entityB, shapeA, shapeB, contact)
            end

            if dataB then
                world:emit(dataB.entity, physics_events.PreSolve, entityA, shapeB, shapeA, contact)
            end
        end

        local function postSolve(
            fixtureA: love.physics.Fixture,
            fixtureB: love.physics.Fixture,
            contact: love.physics.Contact,
            normalImpulse: number,
            tangentImpulse: number
        )
            local shapeA, shapeB, dataA, dataB, entityA, entityB = resolveContact(fixtureA, fixtureB)

            if dataA then
                world:emit(dataA.entity, physics_events.PostSolve,
                    entityB, shapeA, shapeB, contact, normalImpulse, tangentImpulse
                )
            end

            if dataB then
                world:emit(dataB.entity, physics_events.PostSolve,
                    entityA, shapeB, shapeA, contact, normalImpulse, tangentImpulse
                )
            end
        end

        physicsWorld:setCallbacks(beginContact, endContact, preSolve, postSolve)

        -----------------------------------------------------------------------
        -- Helper: Configure a shape (already attached to body) with user data.
        -- In Love 12, shapes are created attached to bodies and carry the
        -- fixture methods (friction, restitution, filtering).
        -----------------------------------------------------------------------
        local function configureShape(
            shape: love.physics.Shape,
            density: number,
            entityId: integer,
            collider: physics_components.Collider,
            transform: tecs.builtins.Transform,
            shapeName: string,
            isSensor: boolean
        ): love.physics.Shape
            shape:setDensity(density)
            shape:setSensor(isSensor)

            if collider.groupIndex ~= 0 then
                shape:setGroupIndex(collider.groupIndex)
            end

            shape:setUserData({
                entity = entityId,
                layer = transform.layer,
                categories = collider.categories,
                mask = collider.mask,
                name = shapeName
            } as physics_events.ShapeData)

            return shape
        end

        -----------------------------------------------------------------------
        -- Queries
        -----------------------------------------------------------------------
        local colliderQuery = world:query({
            name = "physics.colliders",
            include = { Transform, Collider },
        })

        local dynamicQuery = world:query({
            name = "physics.dynamic",
            include = { Transform, Collider, RigidBody },
            exclude = { StaticBody },
        })

        local staticQuery = world:query({
            name = "physics.static",
            include = { Transform, Collider, StaticBody },
        })

        -----------------------------------------------------------------------
        -- Helper: Create shapes for a collider (Love2D 12 API)
        -- Shapes are created attached to the body and configured in place.
        -----------------------------------------------------------------------
        local function setupColliderShapes(
            body: love.physics.Body,
            c: physics_components.Collider,
            t: tecs.builtins.Transform,
            entityId: integer,
            restitution: number,
            friction: number,
            density: number
        )
            if c.shapes then
                -- Explicit shapes array: create only what's listed (empty = body only, no shapes)
                c.shapeList = {}
                for _, shapeConfig in ipairs(c.shapes) do
                    local shape: love.physics.Shape
                    local ox = shapeConfig.offsetX or 0
                    local oy = shapeConfig.offsetY or 0
                    if shapeConfig.type == "circle" then
                        local radius = shapeConfig.radius or 16
                        shape = love.physics.newCircleShape(body, ox, oy, radius)
                    else
                        local w = shapeConfig.width or 32
                        local h = shapeConfig.height or 32
                        shape = love.physics.newRectangleShape(body, ox, oy, w, h, 0)
                    end

                    local name = shapeConfig.name or ""
                    local sensor = shapeConfig.sensor or false
                    configureShape(shape, density, entityId, c, t, name, sensor)
                    shape:setRestitution(restitution)
                    shape:setFriction(friction)

                    c.shapeList[#c.shapeList + 1] = shape
                end
            else
                local shape: love.physics.Shape
                if c.shapeType == "circle" then
                    shape = love.physics.newCircleShape(body, 0, 0, c.radius)
                else
                    shape = love.physics.newRectangleShape(body, 0, 0, c.halfWidth * 2, c.halfHeight * 2, 0)
                end

                configureShape(shape, density, entityId, c, t, "", c.sensor)
                shape:setRestitution(restitution)
                shape:setFriction(friction)

                c.shape = shape
            end
        end

        -----------------------------------------------------------------------
        -- System: Create Box2D bodies
        -----------------------------------------------------------------------
        world:addSystem({
            name = "physics.createBodies",
            phase = tecs.phases.FixedPreUpdate,
            run = function(_dt: number)
                for archetype, len, entities in dynamicQuery:iter() do
                    local transforms = archetype:get(Transform)
                    local colliders = archetype:get(Collider)
                    local mutColliders: {physics_components.Collider} = nil
                    local rigidBodies = archetype:get(RigidBody)

                    for i = 1, len do
                        local c = colliders[i]
                        if not c.body then
                            -- Body creation is a one-time transition. Avoid
                            -- dirtying every settled Collider column on every
                            -- fixed step.
                            if not mutColliders then
                                mutColliders = archetype:getMut(Collider)
                            end
                            c = mutColliders[i]
                            local t = transforms[i]
                            local rb = rigidBodies[i]
                            local entityId = entities[i]

                            local bodyType = (rb.bodyType or "dynamic") as love.physics.BodyType
                            local body = love.physics.newBody(physicsWorld, t.x, t.y, bodyType)
                            -- newBody starts at angle 0; carry over the entity's
                            -- rotation (e.g. restored from a snapshot) so physics
                            -- doesn't reset it on the next transform sync.
                            body:setAngle(t.rotation)

                            body:setLinearDamping(rb.drag)
                            body:setAngularDamping(rb.angularDrag)
                            local fixedRot: boolean = defaultFixedRotation
                            if rb.fixedRotation ~= nil then
                                fixedRot = rb.fixedRotation
                            end
                            body:setFixedRotation(fixedRot)

                            if rb.bullet then
                                body:setBullet(true)
                            end

                            if c.hasRuntimeVelocity then
                                body:setLinearVelocity(c.runtimeVx, c.runtimeVy)
                                body:setAngularVelocity(c.runtimeAngularVelocity)
                            elseif rb.initialVx ~= 0 or rb.initialVy ~= 0 then
                                body:setLinearVelocity(rb.initialVx, rb.initialVy)
                            end

                            setupColliderShapes(body, c, t, entityId, rb.restitution, rb.friction, rb.density)

                            if rb.mass then
                                local cx, cy, _, inertia = body:getMassData()
                                body:setMassData(cx, cy, rb.mass, inertia)
                            end

                            c.body = body
                        end
                    end
                end

                for archetype, len, entities in staticQuery:iter() do
                    local transforms = archetype:get(Transform)
                    local colliders = archetype:get(Collider)
                    local mutColliders: {physics_components.Collider} = nil

                    for i = 1, len do
                        local c = colliders[i]
                        if not c.body then
                            if not mutColliders then
                                mutColliders = archetype:getMut(Collider)
                            end
                            c = mutColliders[i]
                            local t = transforms[i]
                            local entityId = entities[i]

                            local body = love.physics.newBody(physicsWorld, t.x, t.y, "static")
                            body:setAngle(t.rotation)
                            setupColliderShapes(body, c, t, entityId, c.restitution, c.friction, 1.0)
                            c.body = body
                        end
                    end
                end
            end
        })

        -----------------------------------------------------------------------
        -- System: Step Box2D world
        -----------------------------------------------------------------------
        world:addSystem({
            name = "physics.step",
            phase = tecs.phases.FixedUpdate,
            run = function(dt: number)
                world:defer()
                physicsWorld:update(dt, 8, 3)
                world:commit()
            end
        })

        -----------------------------------------------------------------------
        -- System: Apply authoritative transforms after each physics step
        -----------------------------------------------------------------------
        world:addSystem({
            -- Keep Transform at the latest completed fixed-step pose. Visual
            -- interpolation belongs to render consumers, not physics.
            name = "physics.applyTransform",
            phase = tecs.phases.FixedPostUpdate,
            run = function(_dt: number)
                for archetype, len in colliderQuery:iter() do
                    local transforms = archetype:get(Transform)
                    local mutTransforms: {tecs.builtins.Transform} = nil
                    local colliders = archetype:get(Collider)

                    for i = 1, len do
                        local c = colliders[i]
                        if c.body then
                            local t = transforms[i]
                            local x, y = c.body:getPosition()
                            local rotation = c.body:getAngle()

                            -- Static and sleeping bodies often produce the
                            -- same transform for thousands of fixed steps.
                            -- Mark Transform dirty only when physics actually
                            -- changes one of the synchronized fields.
                            if t.x ~= x or t.y ~= y or t.rotation ~= rotation then
                                if not mutTransforms then
                                    mutTransforms = archetype:getMut(Transform)
                                end
                                local mut = mutTransforms[i]
                                mut.x, mut.y, mut.rotation = x, y, rotation
                            end
                        end
                    end
                end
            end
        })

    end
end

return physics
