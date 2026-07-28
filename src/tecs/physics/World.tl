--- A Box2D simulation world.
---
--- Bodies are returned as `b2BodyId` value handles. They are plain data: copy
--- them, store them in a component column, pass them across a boundary. The
--- world owns the simulation; destroying it invalidates every handle it
--- issued, which is why `destroy` is explicit rather than a finalizer.

local ffi <const> = require("ffi")
local box2d <const> = require("tecs.ffi.box2d")
local loader <const> = require("tecs.ffi.loader")
local TaskPool <const> = require("tecs.physics.TaskPool")

local C <const> = box2d.C

local record Vec2
    x: number
    y: number
end

local record BodyOptions
    --- "static", "kinematic", or "dynamic". Defaults to static, matching
    --- Box2D, so an unconfigured body cannot silently fall out of the world.
    type: string
    position: Vec2
    --- Radians.
    angle: number
    fixedRotation: boolean
    gravityScale: number
    linearDamping: number
    angularDamping: number
    sleepEnabled: boolean
    isBullet: boolean
    entity: integer
end

local record ShapeOptions
    density: number
    friction: number
    restitution: number
    offsetX: number
    offsetY: number
    categoryBits: number
    maskBits: number
    groupIndex: integer
    isSensor: boolean
    entity: integer
end

local record WorldOptions
    gravity: Vec2
    --- Simulation substeps per step. Box2D's solver default is 4.
    subStepCount: integer
    --- Worker slots the solver runs across, counting the thread that steps
    --- the world. One is single threaded. Defaults to a count derived from
    --- the machine.
    workerCount: integer
end

--- One Box2D simulation, in Box2D's own units.
---
--- **Everything here is metres, radians and seconds**, unlike `tecs.physics`
--- above it, which takes and returns pixels and converts at its own boundary.
--- A caller that reaches this directly is responsible for the conversion, and
--- `physics.scale` is the factor.
---
--- Nothing here is thread safe. A world is created, stepped and destroyed from
--- the game thread; the solver's own threads are inside `step` and are gone
--- again before it returns.
local record World
    --- The `b2WorldId`. Nil once `destroy` has run, which is what makes a
    --- second `destroy` a no-op.
    handle: loader.CValue

    --- Solver substeps per `step`, fixed at creation. Read by `step` on every
    --- call, so writing it changes later steps.
    subStepCount: integer

    --- The threads the solver runs on. Shared with every other simulation in
    --- the process and held by reference for the world's lifetime.
    taskPool: TaskPool

    --- Private. Whether the Box2D world has been destroyed and the pool
    --- reference given back.
    _destroyed: boolean

    --- The last step's movement, indexed by body. See `World:beginMoves`.
    _moves: loader.CValue

    --- Private. Entries in `_moves`, which is how many bodies the last step
    --- moved, not how many the world holds.
    _moveCount: integer

    --- Private. Body slot to one-based index into `_moves`, zero for a body
    --- that did not move. Owned by this world and reused between steps.
    _moveOf: loader.CArray

    --- Private. Slots `_moveOf` has room for. It grows by doubling and never
    --- shrinks, so it settles at the highest body slot the session has seen.
    _moveOfCapacity: integer
end

local WorldMT <const>: metatable<World> = {__index = World}

local BODY_TYPES <const>: {string: integer} = {
    static = 0,
    kinematic = 1,
    dynamic = 2,
}

--- Builds the internal shape options without exposing Box2D definitions.
---
--- Positional rather than a table, because the caller is the per-body sync and
--- a table literal there is an allocation per shape per rebuild.
---
--- @param density Mass per unit area.
--- @param friction Coulomb friction, mixed with the other shape's as their
---     geometric mean.
--- @param restitution Bounce, mixed with the other shape's as the larger of
---     the two.
--- @param offsetX The shape's centre in the body's frame, in metres.
--- @param offsetY The same along y.
--- @param categoryBits The categories this shape belongs to.
--- @param maskBits The categories it collides with. Two shapes touch only when
---     each one's mask names the other's category.
--- @param groupIndex Overrides the bits between shapes sharing a non-zero
---     value: positive always collides, negative never does.
--- @param isSensor Whether the shape reports overlaps instead of colliding. A
---     sensor is built with contact and hit events off and sensor events on.
--- @param entity Stored as the shape's user data, which is how a contact names
---     an entity without a lookup.
--- @return A fresh table, so the caller may keep it. Every field is passed
---     through as given, nil included, and `addBox` and its siblings are where
---     the defaults land.
function World.shapeOptions(
    density: number,
    friction: number,
    restitution: number,
    offsetX: number,
    offsetY: number,
    categoryBits: number,
    maskBits: number,
    groupIndex: integer,
    isSensor: boolean,
    entity: integer
): ShapeOptions
    return {
        density = density,
        friction = friction,
        restitution = restitution,
        offsetX = offsetX,
        offsetY = offsetY,
        categoryBits = categoryBits,
        maskBits = maskBits,
        groupIndex = groupIndex,
        isSensor = isSensor,
        entity = entity,
    }
end

--- Creates a simulation world.
---
--- @param options May be nil, which takes Box2D's own world defaults for
---     everything but the substep count. Gravity is metres per second squared,
---     so a caller working in pixels divides by `physics.scale` first.
--- @return A world the caller owns and has to `destroy`. It takes a reference
---     on the process-wide thread pool, so dropping it without destroying it
---     keeps those threads alive for the rest of the run.
function World.create(options: WorldOptions): World
    options = options or {}

    local def = ffi.new("b2WorldDef[1]") as loader.CArray
    def[0] = C.b2DefaultWorldDef()

    local settings = def[0] as loader.CStruct
    local gravity = settings.gravity as loader.CStruct
    if options.gravity ~= nil then
        gravity.x = options.gravity.x or 0.0
        gravity.y = options.gravity.y or 0.0
    end

    -- Box2D creates no threads of its own; it solves across the ones the
    -- executor already has, so the pool exists before the world does. It is
    -- the process's one pool rather than this world's: see `TaskPool.acquire`
    -- for why threads are shared and simulations are not.
    local pool = TaskPool.acquire(options.workerCount)
    pool:install(settings)

    local self = setmetatable({} as World, WorldMT)
    self.handle = C.b2CreateWorld(def) as loader.CValue
    self.subStepCount = options.subStepCount or 4
    self.taskPool = pool
    self._destroyed = false
    self._moveCount = 0
    self._moveOfCapacity = 0
    return self
end

--- Advances the simulation by `dt` seconds.
---
--- Callers are responsible for feeding a fixed timestep; Box2D's solver is
--- not robust to a varying one, and a variable step makes replay diverge.
---
--- Body handles survive a step: Box2D keeps a body's id stable for its whole
--- life, and only destroying the body or the world invalidates one. What does
--- not survive is the movement array, which `beginMoves` reads and which the
--- next step replaces.
---
--- The solver runs on the pool's threads for the duration of this call and
--- has rejoined by the time it returns, so no callback of the caller's runs
--- off the game thread and nothing is in flight afterwards.
---
--- @param dt Seconds. Zero is accepted by Box2D and advances nothing.
function World:step(dt: number)
    C.b2World_Step(self.handle, dt, self.subStepCount)
end

--- Indexes the bodies the last step moved, so a caller can ask about one by
--- its id rather than by calling into Box2D for every body it owns.
---
--- Box2D reports movement as a contiguous array covering only the bodies that
--- moved, which is both fewer bodies and, more importantly, no call per body:
--- reading a position through the C API returns a struct by value, and every
--- one of those is a cdata allocation. A thousand bodies is a thousand
--- allocations a frame that this avoids entirely.
---
--- Valid until the next step, which is Box2D's guarantee about the array.
---
--- Pair it with `endMoves`; leaving the index built leaves last step's answers
--- in it, so a later `moveOf` reports movement that has already been consumed.
function World:beginMoves()
    local events = C.b2World_GetBodyEvents(self.handle) as loader.CStruct
    local count = events.moveCount as integer
    self._moves = events.moveEvents as loader.CValue
    self._moveCount = count

    -- Indexed by `b2BodyId.index1`, which Box2D keeps dense and reuses, so a
    -- plain array stays small rather than growing with the session.
    local highest = 0
    for index = 0, count - 1 do
        local id = (self._moves as {integer: loader.CStruct})[index].bodyId as loader.CStruct
        local slot = id.index1 as integer
        if slot > highest then
            highest = slot
        end
    end

    if highest >= self._moveOfCapacity then
        local capacity = self._moveOfCapacity
        if capacity < 64 then
            capacity = 64
        end
        while capacity <= highest do
            capacity = capacity * 2
        end
        self._moveOf = ffi.new("int32_t[?]", capacity) as loader.CArray
        self._moveOfCapacity = capacity
    end

    local moveOf = self._moveOf as {integer: integer}
    for index = 0, count - 1 do
        local id = (self._moves as {integer: loader.CStruct})[index].bodyId as loader.CStruct
        moveOf[id.index1 as integer] = index + 1
    end
end

--- Clears the index. Paired with `beginMoves` around a pass over the bodies,
--- and clearing only what was set keeps the cost proportional to what moved
--- rather than to the highest body id ever seen.
function World:endMoves()
    local moveOf = self._moveOf as {integer: integer}
    for index = 0, self._moveCount - 1 do
        local id = (self._moves as {integer: loader.CStruct})[index].bodyId as loader.CStruct
        moveOf[id.index1 as integer] = 0
    end
    self._moveCount = 0
end

--- The last step's transform for the body with this id, or nil if it did not
--- move. Position in metres, rotation as its cosine and sine.
---
--- The rotation is not converted to an angle here: a caller that only needs
--- the pair should not pay for an inverse tangent it throws away.
---
--- Slot zero is the null handle and always reads as "did not move", with no
--- test of its own: Box2D numbers bodies from one, so nothing ever writes
--- that slot, and a `RigidBody` restored from a snapshot lands here rather
--- than on a body it does not own.
---
--- @param index1 A body's `index1`, which Box2D numbers from one and reuses
---     once a body is destroyed. Only meaningful for this world's bodies: an
---     index from another world reads whatever this one has in that slot.
--- @return X in metres, or nil alone when the body did not move.
--- @return Y in metres.
--- @return Cosine of the rotation.
--- @return Sine of the rotation. Take `atan2(sine, cosine)` for an angle in
---     radians, and only if you need one.
function World:moveOf(index1: integer): number, number, number, number
    if index1 >= self._moveOfCapacity then
        return nil
    end
    local slot = (self._moveOf as {integer: integer})[index1]
    if slot == 0 then
        return nil
    end
    local transform = (self._moves as {integer: loader.CStruct})[slot - 1].transform as loader.CStruct
    local position = transform.p as loader.CStruct
    local rotation = transform.q as loader.CStruct
    return position.x as number, position.y as number, rotation.c as number, rotation.s as number
end

--- Creates a body and returns its handle.
---
--- The body has no shape yet, so it has no mass and collides with nothing
--- until `addBox` or `addCircle` is called on it.
---
--- @param options May be nil. Position is metres and angle is radians. An
---     unrecognised `type` string is read as static rather than raising.
--- @return A `b2BodyId`, a value struct that is safe to copy and store. It
---     stays valid across steps and is invalidated only by destroying the body
---     or this world.
function World:createBody(options: BodyOptions): loader.CValue
    options = options or {}

    local def = ffi.new("b2BodyDef[1]") as loader.CArray
    def[0] = C.b2DefaultBodyDef()

    local settings = def[0] as loader.CStruct
    settings.type = BODY_TYPES[options.type or "static"] or 0

    if options.position ~= nil then
        local position = settings.position as loader.CStruct
        position.x = options.position.x or 0.0
        position.y = options.position.y or 0.0
    end
    if options.angle ~= nil then
        -- b2MakeRot is a header-only inline with no exported symbol, and a
        -- b2Rot is just the cosine/sine pair. Computing it here avoids an FFI
        -- call the JIT cannot inline through.
        local rotation = settings.rotation as loader.CStruct
        rotation.c = math.cos(options.angle)
        rotation.s = math.sin(options.angle)
    end
    if options.fixedRotation ~= nil then
        settings.fixedRotation = options.fixedRotation
    end
    if options.gravityScale ~= nil then
        settings.gravityScale = options.gravityScale
    end
    if options.linearDamping ~= nil then
        settings.linearDamping = options.linearDamping
    end
    if options.angularDamping ~= nil then
        settings.angularDamping = options.angularDamping
    end
    if options.sleepEnabled ~= nil then
        settings.enableSleep = options.sleepEnabled
    end
    if options.isBullet ~= nil then
        settings.isBullet = options.isBullet
    end
    if options.entity ~= nil then
        settings.userData = ffi.cast("void *", options.entity)
    end

    return C.b2CreateBody(self.handle, def) as loader.CValue
end

local function shapeDef(options: ShapeOptions): loader.CArray
    options = options or {}
    local def = ffi.new("b2ShapeDef[1]") as loader.CArray
    def[0] = C.b2DefaultShapeDef()

    local settings = def[0] as loader.CStruct
    if options.entity ~= nil then
        settings.userData = ffi.cast("void *", options.entity)
    end
    if options.density ~= nil then
        settings.density = options.density
    end
    if options.friction ~= nil then
        local material = settings.material as loader.CStruct
        material.friction = options.friction
    end
    if options.restitution ~= nil then
        local material = settings.material as loader.CStruct
        material.restitution = options.restitution
    end
    local filter = settings.filter as loader.CStruct
    if options.categoryBits ~= nil then
        filter.categoryBits = options.categoryBits
    end
    if options.maskBits ~= nil then
        filter.maskBits = options.maskBits
    end
    if options.groupIndex ~= nil then
        filter.groupIndex = options.groupIndex
    end
    if options.isSensor ~= nil then
        settings.isSensor = options.isSensor
    end
    -- Events are buffer-backed and are drained after each step. No Lua
    -- callback is crossed from Box2D.
    settings.enableContactEvents = not options.isSensor
    settings.enableHitEvents = not options.isSensor
    -- Box2D requires sensor events enabled on the visitor as well as the
    -- sensor shape, so every public collider opts in.
    settings.enableSensorEvents = true
    return def
end

--- Attaches an axis-aligned box to `body`. Extents are half-widths, matching
--- Box2D's convention.
---
--- Axis aligned in the body's frame, so it turns with the body. Attaching a
--- shape recomputes the body's mass from the shape's density.
---
--- @param body The body to attach to. Not checked, so a stale handle here is
---     Box2D's to reject rather than this function's.
--- @param halfWidth Half the box's full width, in metres.
--- @param halfHeight Half the box's full height, in metres.
--- @param options Required, unlike the definition Box2D builds from it: the
---     offset is read off this before anything is normalized, so nil raises
---     here rather than falling back to the material defaults. Each field
---     within it may be nil.
--- @return A `b2ShapeId`. It is invalidated by destroying the shape, the body
---     or the world.
function World.addBox(body: loader.CValue, halfWidth: number, halfHeight: number, options: ShapeOptions): loader.CValue
    local polygon = ffi.new("b2Polygon[1]") as loader.CArray
    local offset = ffi.new("b2Vec2[1]") as loader.CArray
    local centre = offset[0] as loader.CStruct
    centre.x = options.offsetX or 0.0
    centre.y = options.offsetY or 0.0
    local rotation = ffi.new("b2Rot[1]") as loader.CArray
    local angle = rotation[0] as loader.CStruct
    angle.c, angle.s = 1.0, 0.0
    polygon[0] = C.b2MakeOffsetBox(halfWidth, halfHeight, offset[0], rotation[0])
    return C.b2CreatePolygonShape(body, shapeDef(options), polygon) as loader.CValue
end

--- Attaches a circle, centred by the offset in `options`.
---
--- @param body The body to attach to.
--- @param radius Metres.
--- @param options Required, for the reason `addBox` gives. Its `offsetX` and
---     `offsetY` place the circle's centre in the body's frame, so an
---     off-centre circle needs no body positioned for it.
--- @return A `b2ShapeId`, with the same lifetime as `addBox`'s.
function World.addCircle(body: loader.CValue, radius: number, options: ShapeOptions): loader.CValue
    local circle = ffi.new("b2Circle[1]") as loader.CArray
    local shape = circle[0] as loader.CStruct
    local centre = shape.center as loader.CStruct
    centre.x = options.offsetX or 0.0
    centre.y = options.offsetY or 0.0
    shape.radius = radius
    return C.b2CreateCircleShape(body, shapeDef(options), circle) as loader.CValue
end

--- Attaches a vertical capsule. `length` is the distance between the two end
--- centres, excluding the caps.
---
--- @param body The body to attach to.
--- @param radius The cap radius, in metres. It is also the capsule's
---     half-width, so the full width is twice this.
--- @param length Metres between the two end centres, so the full height is
---     this plus twice the radius. Zero makes a circle of `radius`.
--- @param options Required, for the reason `addBox` gives. The offset places
---     the capsule's midpoint, and the two ends are put half a length either
---     side of it along y.
--- @return A `b2ShapeId`, with the same lifetime as `addBox`'s.
function World.addCapsule(body: loader.CValue, radius: number, length: number, options: ShapeOptions): loader.CValue
    local capsule = ffi.new("b2Capsule[1]") as loader.CArray
    local shape = capsule[0] as loader.CStruct
    local centre1 = shape.center1 as loader.CStruct
    local centre2 = shape.center2 as loader.CStruct
    local x = options.offsetX or 0.0
    local y = options.offsetY or 0.0
    centre1.x, centre1.y = x, y - length * 0.5
    centre2.x, centre2.y = x, y + length * 0.5
    shape.radius = radius
    return C.b2CreateCapsuleShape(body, shapeDef(options), capsule) as loader.CValue
end

local shapeScratch <const> = ffi.new("b2ShapeId[1]") as loader.CArray

--- Destroys the first shape Box2D lists for a body, and nothing when it has
--- none.
---
--- @param body Its shape list is read one entry deep, and Box2D links a new
---     shape at the head, so the entry that comes back is the most recently
---     attached rather than the first. On a body carrying only the shape it
---     was declared with, those are the same one; on a body that has since
---     gained a secondary collider, they are not.
function World.removeShape(body: loader.CValue)
    if (tonumber(C.b2Body_GetShapes(body, shapeScratch, 1)) as integer) > 0 then
        C.b2DestroyShape(shapeScratch[0], true)
    end
end

--- Returns the entity stored on a body, or zero when none was.
---
--- @param body A live handle. The user data is read without validating it, so
---     a destroyed body's handle is the caller's problem.
--- @return The entity `createBody` was given, or zero for a body created
---     without one. Zero is not a valid entity, so it doubles as "none".
function World.entityOfBody(body: loader.CValue): integer
    return tonumber(ffi.cast("intptr_t", C.b2Body_GetUserData(body))) as integer
end

--- Returns the entity owning a shape, or zero when none was.
---
--- @param shape Validated first, unlike `entityOfBody`'s body, because the
---     contact and sensor buffers name shapes that a later event in the same
---     drain may already have destroyed.
--- @return The shape's own entity where it has one, which is how a secondary
---     collider reports itself rather than its body. Falls back to the body's
---     entity, so a shape declared with its body answers with that body. Zero
---     when the shape is invalid or neither carries an entity.
function World.entityOfShape(shape: loader.CValue): integer
    if not (C.b2Shape_IsValid(shape) as boolean) then
        return 0
    end
    local entity = tonumber(ffi.cast("intptr_t", C.b2Shape_GetUserData(shape))) as integer
    if entity ~= 0 then
        return entity
    end
    return World.entityOfBody(C.b2Shape_GetBody(shape))
end

local queryFilterScratch <const> = ffi.new("b2QueryFilter[1]") as loader.CArray
local rayOriginScratch <const> = ffi.new("b2Vec2[1]") as loader.CArray
local rayTranslationScratch <const> = ffi.new("b2Vec2[1]") as loader.CArray
local forceScratch <const> = ffi.new("b2Vec2[1]") as loader.CArray
local forcePointScratch <const> = ffi.new("b2Vec2[1]") as loader.CArray

--- Casts a segment and returns the nearest hit. All positions are metres.
---
--- Closest-hit only, and callback-free: Box2D's all-hits and overlap queries
--- report through a function pointer, which is what keeps them out of this
--- module.
---
--- @param x1 The start of the segment, in metres.
--- @param y1 The same along y.
--- @param x2 The end of the segment. Nothing past it is tested, so a miss may
---     only mean the segment was short.
--- @param y2 The same along y.
--- @param categoryBits The ray's own categories, nil for all of them. A shape
---     whose mask names none of these is skipped.
--- @param maskBits The categories the ray may hit, nil for all of them.
--- @return The entity owning the nearest shape, or nil alone on a miss.
---     Sensors are eligible: only the filter keeps a ray out of one.
--- @return The contact x in metres.
--- @return The contact y in metres.
--- @return The x of the surface normal, a unit vector pointing out of the
---     shape and so unscaled.
--- @return The y of the surface normal.
--- @return How far along the segment the hit is, 0 at the start and 1 at the
---     end.
function World:raycast(
    x1: number, y1: number, x2: number, y2: number, categoryBits: number, maskBits: number
): integer, number, number, number, number, number
    queryFilterScratch[0] = C.b2DefaultQueryFilter()
    local filter = queryFilterScratch[0] as loader.CStruct
    filter.categoryBits = categoryBits or 0xFFFFFFFF
    filter.maskBits = maskBits or 0xFFFFFFFF
    local origin = rayOriginScratch[0] as loader.CStruct
    origin.x, origin.y = x1, y1
    local translation = rayTranslationScratch[0] as loader.CStruct
    translation.x, translation.y = x2 - x1, y2 - y1
    local hit = C.b2World_CastRayClosest(
        self.handle, rayOriginScratch[0], rayTranslationScratch[0], queryFilterScratch[0]
    ) as loader.CStruct
    if not (hit.hit as boolean) then
        return nil
    end
    local point = hit.point as loader.CStruct
    local normal = hit.normal as loader.CStruct
    return World.entityOfShape(
        hit.shapeId as loader.CValue
    ), point.x as number, point.y as number, normal.x as number, normal.y as number, hit.fraction as number
end

--- Applies a force at the centre. Force uses Box2D's metre-based units.
---
--- Box2D clears the accumulator at the end of every step, so a force has to be
--- reapplied each step to keep acting.
---
--- @param body The body to push. Wakes it, because a sleeping body accumulates
---     force and never moves.
--- @param x Newtons along x, applied at the centre of mass so it imparts no
---     spin.
--- @param y Newtons along y.
function World.applyForce(body: loader.CValue, x: number, y: number)
    local vector = forceScratch[0] as loader.CStruct
    vector.x, vector.y = x, y
    C.b2Body_ApplyForceToCenter(body, forceScratch[0], true)
end

--- Applies a force at a world point, which spins the body as well as pushing
--- it. Cleared each step, like `applyForce`.
---
--- @param body The body to push, which this wakes.
--- @param x Newtons along x.
--- @param y Newtons along y.
--- @param pointX Where the force acts, in world metres rather than the body's
---     frame.
--- @param pointY The same along y. A point at the centre of mass makes this
---     `applyForce`.
function World.applyForceAt(body: loader.CValue, x: number, y: number, pointX: number, pointY: number)
    local vector = forceScratch[0] as loader.CStruct
    vector.x, vector.y = x, y
    local point = forcePointScratch[0] as loader.CStruct
    point.x, point.y = pointX, pointY
    C.b2Body_ApplyForce(body, forceScratch[0], forcePointScratch[0], true)
end

--- Applies a linear impulse at a world point, changing velocity at once rather
--- than over the step.
---
--- @param body The body to push, which this wakes.
--- @param x The x impulse, in kilogram-metres per second.
--- @param y The y impulse.
--- @param pointX Where the impulse lands, in world metres. Off the centre of
---     mass it becomes spin as well as travel.
--- @param pointY The same along y.
function World.applyImpulseAt(body: loader.CValue, x: number, y: number, pointX: number, pointY: number)
    local vector = forceScratch[0] as loader.CStruct
    vector.x, vector.y = x, y
    local point = forcePointScratch[0] as loader.CStruct
    point.x, point.y = pointX, pointY
    C.b2Body_ApplyLinearImpulse(body, forceScratch[0], forcePointScratch[0], true)
end

--- Applies torque about the centre of mass. Cleared each step, like the forces
--- above.
---
--- @param body The body to turn, which this wakes.
--- @param torque Newton-metres. Positive raises the angular velocity, and a
---     body with `fixedRotation` takes it and still does not turn.
function World.applyTorque(body: loader.CValue, torque: number)
    C.b2Body_ApplyTorque(body, torque, true)
end

--- Reads a body's angular velocity.
---
--- @param body The body to read.
--- @return Radians per second, in the direction a rising angle turns. Zero for
---     a static body and for one with `fixedRotation`.
function World.angularVelocity(body: loader.CValue): number
    return C.b2Body_GetAngularVelocity(body) as number
end

--- Sets a body's angular velocity and wakes it.
---
--- @param body The body to spin.
--- @param omega Radians per second, set outright. Box2D discards it for a
---     static body and for one with `fixedRotation`, which read back zero; the
---     wake still happens either way.
function World.setAngularVelocity(body: loader.CValue, omega: number)
    C.b2Body_SetAngularVelocity(body, omega)
    C.b2Body_SetAwake(body, true)
end

--- Wakes a body or puts it to sleep.
---
--- @param body The body to act on.
--- @param awake False sleeps it where it is rather than waiting for it to come
---     to rest, so a body still moving stops until something touches it.
function World.setAwake(body: loader.CValue, awake: boolean)
    C.b2Body_SetAwake(body, awake)
end

--- Whether Box2D is still solving this body.
---
--- @param body The body to read.
--- @return Whether it is awake. Bodies sleep as an island, so one at rest
---     touching a moving body stays awake.
function World.isAwake(body: loader.CValue): boolean
    return C.b2Body_IsAwake(body) as boolean
end

--- Moves a body outright, without sweeping the gap.
---
--- @param body The body to move.
--- @param x The new origin x, in metres. The origin is what shapes are placed
---     relative to, not the centre of mass.
--- @param y The new origin y, in metres.
--- @param angle Radians. Required here, unlike `physics.teleport`, which fills
---     it from the entity's transform.
function World.setTransform(body: loader.CValue, x: number, y: number, angle: number)
    local position = rayOriginScratch[0] as loader.CStruct
    position.x, position.y = x, y
    local rotation = ffi.new("b2Rot[1]") as loader.CArray
    local fields = rotation[0] as loader.CStruct
    fields.c, fields.s = math.cos(angle), math.sin(angle)
    C.b2Body_SetTransform(body, rayOriginScratch[0], rotation[0])
end

--- How many bodies the world currently holds.
---
--- Box2D counts them by walking its solver sets, so this is a diagnostic
--- rather than something to call per frame.
---
--- @return Bodies of every type, static included, and sleeping ones as well as
---     awake ones.
function World:bodyCount(): integer
    local counters = C.b2World_GetCounters(self.handle) as loader.CStruct
    return counters.bodyCount as integer
end

--- Returns a body's world position.
---
--- One call per body, and a `b2Vec2` comes back by value, so this allocates
--- cdata each time. Use `moveOf` over a column of bodies instead.
---
--- @return X in metres.
--- @return Y in metres. The body's origin, which its shapes are placed
---     relative to, not its centre of mass.
function World.getPosition(body: loader.CValue): number, number
    local position = C.b2Body_GetPosition(body)
    return position.x as number, position.y as number
end

--- Returns a body's rotation in radians.
---
--- b2Rot_GetAngle is header-only, so the conversion from the stored
--- cosine/sine pair happens here.
---
--- @return Radians in (-pi, pi]: the stored pair is normalized, so an angle
---     does not accumulate past a full turn and a body spun twice round reads
---     the same as one spun once.
function World.getAngle(body: loader.CValue): number
    local rotation = C.b2Body_GetRotation(body)
    return math.atan2(rotation.s as number, rotation.c as number)
end

--- Returns a body's linear velocity.
---
--- @return X in metres per second.
--- @return Y in metres per second. Linear only: a body that is only spinning
---     reads zero here.
function World.getVelocity(body: loader.CValue): number, number
    local velocity = C.b2Body_GetLinearVelocity(body)
    return velocity.x as number, velocity.y as number
end

-- One vector for the lifetime of the process, filled and handed straight to
-- Box2D. `b2Vec2` is passed by value, so nothing retains it.
local velocityScratch <const> = ffi.new("b2Vec2[1]") as loader.CArray

--- Sets a body's linear velocity and wakes it.
---
--- Waking is not optional: Box2D lets a resting island sleep, and a sleeping
--- body given a velocity keeps sleeping and never moves.
---
--- @param x Metres per second, set outright rather than added to.
--- @param y Metres per second. Angular velocity is left alone.
function World.setVelocity(body: loader.CValue, x: number, y: number)
    local vector = velocityScratch[0] as loader.CStruct
    vector.x = x
    vector.y = y
    C.b2Body_SetLinearVelocity(body, velocityScratch[0])
    C.b2Body_SetAwake(body, true)
end

--- Destroys the world and invalidates every handle it issued.
---
--- The solver threads go after the world, not before: they run solver code, so
--- giving the pool back second is what guarantees none is inside a step when
--- it is joined. The pool is shared, so any other live simulation keeps it
--- above zero references and this releases nothing but its own hold.
function World:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    C.b2DestroyWorld(self.handle)
    self.handle = nil
    self.taskPool:release()
    self.taskPool = nil
end

return World
