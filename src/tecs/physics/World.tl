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

local record World
    handle: loader.CValue
    subStepCount: integer
    --- The threads the solver runs on. Shared with every other simulation in
    --- the process and held by reference for the world's lifetime.
    taskPool: TaskPool
    _destroyed: boolean

    --- The last step's movement, indexed by body. See `World:beginMoves`.
    _moves: loader.CValue
    _moveCount: integer
    _moveOf: loader.CArray
    _moveOfCapacity: integer
end

local WorldMT <const>: metatable<World> = {__index = World}

local BODY_TYPES <const>: {string: integer} = {
    static = 0,
    kinematic = 1,
    dynamic = 2,
}

--- Builds the internal shape options without exposing Box2D definitions.
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

--- Attaches a circle centred on the body's origin.
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

--- Removes a body's single primary shape.
function World.removeShape(body: loader.CValue)
    if (tonumber(C.b2Body_GetShapes(body, shapeScratch, 1)) as integer) > 0 then
        C.b2DestroyShape(shapeScratch[0], true)
    end
end

--- Returns the entity stored on a body, or zero when none was.
function World.entityOfBody(body: loader.CValue): integer
    return tonumber(ffi.cast("intptr_t", C.b2Body_GetUserData(body))) as integer
end

--- Returns the entity owning a shape, or zero when none was.
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
function World.applyForce(body: loader.CValue, x: number, y: number)
    local vector = forceScratch[0] as loader.CStruct
    vector.x, vector.y = x, y
    C.b2Body_ApplyForceToCenter(body, forceScratch[0], true)
end

function World.applyForceAt(body: loader.CValue, x: number, y: number, pointX: number, pointY: number)
    local vector = forceScratch[0] as loader.CStruct
    vector.x, vector.y = x, y
    local point = forcePointScratch[0] as loader.CStruct
    point.x, point.y = pointX, pointY
    C.b2Body_ApplyForce(body, forceScratch[0], forcePointScratch[0], true)
end

function World.applyImpulseAt(body: loader.CValue, x: number, y: number, pointX: number, pointY: number)
    local vector = forceScratch[0] as loader.CStruct
    vector.x, vector.y = x, y
    local point = forcePointScratch[0] as loader.CStruct
    point.x, point.y = pointX, pointY
    C.b2Body_ApplyLinearImpulse(body, forceScratch[0], forcePointScratch[0], true)
end

function World.applyTorque(body: loader.CValue, torque: number)
    C.b2Body_ApplyTorque(body, torque, true)
end

function World.angularVelocity(body: loader.CValue): number
    return C.b2Body_GetAngularVelocity(body) as number
end

function World.setAngularVelocity(body: loader.CValue, omega: number)
    C.b2Body_SetAngularVelocity(body, omega)
    C.b2Body_SetAwake(body, true)
end

function World.setAwake(body: loader.CValue, awake: boolean)
    C.b2Body_SetAwake(body, awake)
end

function World.isAwake(body: loader.CValue): boolean
    return C.b2Body_IsAwake(body) as boolean
end

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
function World:bodyCount(): integer
    local counters = C.b2World_GetCounters(self.handle) as loader.CStruct
    return counters.bodyCount as integer
end

--- Returns a body's world position.
function World.getPosition(body: loader.CValue): number, number
    local position = C.b2Body_GetPosition(body)
    return position.x as number, position.y as number
end

--- Returns a body's rotation in radians.
---
--- b2Rot_GetAngle is header-only, so the conversion from the stored
--- cosine/sine pair happens here.
function World.getAngle(body: loader.CValue): number
    local rotation = C.b2Body_GetRotation(body)
    return math.atan2(rotation.s as number, rotation.c as number)
end

--- Returns a body's linear velocity.
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
