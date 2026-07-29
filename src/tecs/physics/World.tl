--[=[
One Rapier 2D simulation.

Rapier remains entirely Rust-owned. This wrapper only translates Lua
tables into the stable C ABI and keeps the opaque world pointer alive.
]=]

local ffi <const> = require("ffi")
local loader <const> = require("tecs.ffi.loader")
local TaskPool <const> = require("tecs.physics.TaskPool")
local rust <const> = require("tecs.ffi.rust")

local C <const> = rust.C

local record Vec2
    x: number
    y: number
end

local record BodyOptions
    type: string
    position: Vec2
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
    isSensor: boolean
    entity: integer
end

local record WorldOptions
    gravity: Vec2
    subStepCount: integer
    workerCount: integer
end

local record World
    record Handle
        native: loader.CValue
        world: World
    end

    handle: loader.CPtr
    subStepCount: integer
    taskPool: TaskPool
    _id: integer
    _destroyed: boolean
    _moves: loader.CValue
    _moveCount: integer
    _moveOf: {integer: integer}
    _events: loader.CValue
    _eventCount: integer
end

local type Handle = World.Handle

local WorldMT <const>: metatable<World> = {__index = World}
local worlds: {integer: World} = {}
local nextWorldId = 1

local BODY_TYPES <const>: {string: integer} = {
    static = 0,
    kinematic = 1,
    dynamic = 2,
}

local function nativeHandle(index: integer, generation: integer): loader.CValue
    local value = ffi.new("TecsPhysicsHandle") as loader.CStruct
    value.index = index
    value.generation = generation
    return value as loader.CValue
end

--- Rebuilds a live handle from its component fields.
---
--- @param index Rapier arena index, zero based.
--- @param generation Rapier arena generation.
--- @param worldId Simulation id stored in the transient component.
--- @return Nil for a stale world id, otherwise a handle accepted by this
---     module's static operations.
function World.wrapHandle(index: integer, generation: integer, worldId: integer): Handle
    local world = worlds[worldId]
    if world == nil then
        return nil
    end
    return {
        native = nativeHandle(index, generation),
        world = world,
    }
end

function World.shapeOptions(
    density: number,
    friction: number,
    restitution: number,
    offsetX: number,
    offsetY: number,
    categoryBits: number,
    maskBits: number,
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
        isSensor = isSensor,
        entity = entity,
    }
end

--- Creates a Rapier simulation.
---
--- @param options Gravity is in meters per second squared. Substeps default
---     to four.
--- @return An owned simulation. Call `destroy` when the ECS world shuts down.
function World.create(options: WorldOptions): World
    options = options or {}
    local gravity = options.gravity or {x = 0.0, y = 0.0}
    local pool = TaskPool.acquire(options.workerCount)
    local substeps = options.subStepCount or 4
    local handle = C.tecsPhysicsWorldCreate(gravity.x or 0.0, gravity.y or 0.0, substeps, pool.workerCount)
    if handle == nil then
        pool:release()
        error("tecs: cannot create the Rapier physics world", 2)
    end
    local self = setmetatable({} as World, WorldMT)
    self.handle = handle
    self.subStepCount = substeps
    self.taskPool = pool
    self._id = nextWorldId
    nextWorldId = nextWorldId + 1
    self._destroyed = false
    self._moveCount = 0
    self._moveOf = {}
    self._eventCount = 0
    worlds[self._id] = self
    return self
end

--- Advances the fixed-step simulation.
---
--- @param dt Seconds.
function World:step(dt: number)
    C.tecsPhysicsWorldStep(self.handle, dt)
end

function World:beginMoves()
    local count = ffi.new("size_t[1]") as loader.CArray
    self._moves = C.tecsPhysicsMoves(self.handle, count)
    self._moveCount = tonumber(count[0]) as integer
    for index = 0, self._moveCount - 1 do
        local move = (self._moves as {integer: loader.CStruct})[index as integer]
        local body = move.body as loader.CStruct
        self._moveOf[(body.index as integer) + 1] = index + 1
    end
end

function World:endMoves()
    for index = 0, self._moveCount - 1 do
        local move = (self._moves as {integer: loader.CStruct})[index as integer]
        local body = move.body as loader.CStruct
        self._moveOf[(body.index as integer) + 1] = nil
    end
    self._moveCount = 0
end

function World:moveOf(index1: integer): number, number, number, number
    local slot = self._moveOf[index1]
    if slot == nil then
        return nil
    end
    local move = (self._moves as {integer: loader.CStruct})[slot - 1]
    return move.x as number, move.y as number, move.cosine as number, move.sine as number
end

function World:createBody(options: BodyOptions): Handle
    options = options or {}
    local position = options.position or {x = 0.0, y = 0.0}
    local definition = ffi.new("TecsPhysicsBodyDef[1]") as loader.CArray
    local fields = definition[0] as loader.CStruct
    fields.kind = BODY_TYPES[options.type or "static"] or 0
    fields.fixed_rotation = options.fixedRotation and 1 or 0
    fields.bullet = options.isBullet and 1 or 0
    fields.sleep_enabled = options.sleepEnabled == false and 0 or 1
    fields.x = position.x or 0.0
    fields.y = position.y or 0.0
    fields.angle = options.angle or 0.0
    fields.gravity_scale = options.gravityScale or 1.0
    fields.linear_damping = options.linearDamping or 0.0
    fields.angular_damping = options.angularDamping or 0.0
    fields.entity = options.entity or 0
    return {native = C.tecsPhysicsBodyCreate(self.handle, definition), world = self}
end

local function colliderDefinition(shape: integer, a: number, b: number, options: ShapeOptions): loader.CArray
    options = options or {}
    local definition = ffi.new("TecsPhysicsColliderDef[1]") as loader.CArray
    local fields = definition[0] as loader.CStruct
    fields.shape = shape
    fields.sensor = options.isSensor and 1 or 0
    if shape == 0 then
        fields.half_width, fields.half_height = a, b
    elseif shape == 1 then
        fields.radius = a
    else
        fields.radius, fields.length = a, b
    end
    fields.offset_x = options.offsetX or 0.0
    fields.offset_y = options.offsetY or 0.0
    fields.density = options.density or 1.0
    fields.friction = options.friction or 0.6
    fields.restitution = options.restitution or 0.0
    fields.category_bits = options.categoryBits or 1
    fields.mask_bits = options.maskBits or 0xFFFFFFFF
    fields.entity = options.entity or 0
    return definition
end

local function addCollider(body: Handle, definition: loader.CArray): Handle
    return {native = C.tecsPhysicsColliderCreate(body.world.handle, body.native, definition), world = body.world}
end

function World.addBox(body: Handle, halfWidth: number, halfHeight: number, options: ShapeOptions): Handle
    return addCollider(body, colliderDefinition(0, halfWidth, halfHeight, options))
end

function World.addCircle(body: Handle, radius: number, options: ShapeOptions): Handle
    return addCollider(body, colliderDefinition(1, radius, 0.0, options))
end

function World.addCapsule(body: Handle, radius: number, length: number, options: ShapeOptions): Handle
    return addCollider(body, colliderDefinition(2, radius, length, options))
end

function World.removeShape(body: Handle, entity: integer)
    if body ~= nil then
        C.tecsPhysicsRemoveColliderByEntity(body.world.handle, body.native, entity)
    end
end

function World.destroyBody(body: Handle)
    if body ~= nil then
        C.tecsPhysicsBodyDestroy(body.world.handle, body.native)
    end
end

function World.destroyShape(shape: Handle)
    if shape ~= nil then
        C.tecsPhysicsColliderDestroy(shape.world.handle, shape.native)
    end
end

function World.bodyOfShape(shape: Handle): Handle
    if shape == nil then
        return nil
    end
    return {native = C.tecsPhysicsColliderBody(shape.world.handle, shape.native), world = shape.world}
end

function World.isBodyValid(body: Handle): boolean
    return body ~= nil and C.tecsPhysicsBodyIsValid(body.world.handle, body.native) as boolean
end

function World.isShapeValid(shape: Handle): boolean
    return shape ~= nil and C.tecsPhysicsColliderIsValid(shape.world.handle, shape.native) as boolean
end

function World:raycast(
    x1: number, y1: number, x2: number, y2: number, categoryBits: number, maskBits: number
): integer, number, number, number, number, number
    local hit = ffi.new("TecsPhysicsRayHit[1]") as loader.CArray
    local found = C.tecsPhysicsRaycast(
        self.handle, x1, y1, x2, y2, categoryBits or 0xFFFFFFFF, maskBits or 0xFFFFFFFF, hit
    ) as boolean
    if not found then
        return nil
    end
    local value = hit[0] as loader.CStruct
    return value.entity as integer, value.x as number, value.y as number, value.normal_x as number, value.normal_y as number, value.fraction as number
end

function World.applyForce(body: Handle, x: number, y: number)
    C.tecsPhysicsBodyAddForce(body.world.handle, body.native, x, y)
end

function World.applyForceAt(body: Handle, x: number, y: number, pointX: number, pointY: number)
    C.tecsPhysicsBodyAddForceAt(body.world.handle, body.native, x, y, pointX, pointY)
end

function World.applyImpulse(body: Handle, x: number, y: number)
    C.tecsPhysicsBodyApplyImpulse(body.world.handle, body.native, x, y)
end

function World.applyImpulseAt(body: Handle, x: number, y: number, pointX: number, pointY: number)
    C.tecsPhysicsBodyApplyImpulseAt(body.world.handle, body.native, x, y, pointX, pointY)
end

function World.applyTorque(body: Handle, torque: number)
    C.tecsPhysicsBodyAddTorque(body.world.handle, body.native, torque)
end

local scalar = ffi.new("float[1]") as loader.CArray
local vectorX = ffi.new("float[1]") as loader.CArray
local vectorY = ffi.new("float[1]") as loader.CArray

function World.angularVelocity(body: Handle): number
    if not C.tecsPhysicsBodyVelocity(body.world.handle, body.native, nil, nil, scalar) as boolean then
        return 0.0
    end
    return scalar[0] as number
end

function World.setAngularVelocity(body: Handle, omega: number)
    C.tecsPhysicsBodySetAngularVelocity(body.world.handle, body.native, omega)
end

function World.setAwake(body: Handle, awake: boolean)
    C.tecsPhysicsBodySetAwake(body.world.handle, body.native, awake)
end

function World.isAwake(body: Handle): boolean
    return C.tecsPhysicsBodyIsAwake(body.world.handle, body.native) as boolean
end

function World.setEnabled(body: Handle, enabled: boolean)
    C.tecsPhysicsBodySetEnabled(body.world.handle, body.native, enabled)
end

function World.setTransform(body: Handle, x: number, y: number, angle: number)
    C.tecsPhysicsBodySetTransform(body.world.handle, body.native, x, y, angle)
end

function World.getPosition(body: Handle): number, number
    C.tecsPhysicsBodyPosition(body.world.handle, body.native, vectorX, vectorY, nil)
    return vectorX[0] as number, vectorY[0] as number
end

function World.getAngle(body: Handle): number
    C.tecsPhysicsBodyPosition(body.world.handle, body.native, nil, nil, scalar)
    return scalar[0] as number
end

function World.getVelocity(body: Handle): number, number
    C.tecsPhysicsBodyVelocity(body.world.handle, body.native, vectorX, vectorY, nil)
    return vectorX[0] as number, vectorY[0] as number
end

function World.setVelocity(body: Handle, x: number, y: number)
    C.tecsPhysicsBodySetVelocity(body.world.handle, body.native, x, y)
end

function World.setBodyType(body: Handle, kind: integer)
    local definition = ffi.new("TecsPhysicsBodyDef[1]") as loader.CArray
    local fields = definition[0] as loader.CStruct
    fields.kind = kind
    fields.gravity_scale = 1.0
    fields.sleep_enabled = 1
    C.tecsPhysicsBodyApplyDefinition(body.world.handle, body.native, definition)
end

function World.applyBodyDefinition(
    body: Handle,
    kind: integer,
    fixedRotation: boolean,
    isBullet: boolean,
    sleepEnabled: boolean,
    gravityScale: number,
    linearDamping: number,
    angularDamping: number
)
    local definition = ffi.new("TecsPhysicsBodyDef[1]") as loader.CArray
    local fields = definition[0] as loader.CStruct
    fields.kind = kind
    fields.fixed_rotation = fixedRotation and 1 or 0
    fields.bullet = isBullet and 1 or 0
    fields.sleep_enabled = sleepEnabled and 1 or 0
    fields.gravity_scale = gravityScale
    fields.linear_damping = linearDamping
    fields.angular_damping = angularDamping
    C.tecsPhysicsBodyApplyDefinition(body.world.handle, body.native, definition)
end

function World:bodyCount(): integer
    return tonumber(C.tecsPhysicsBodyCount(self.handle)) as integer
end

function World:bodyByEntity(entity: integer): Handle
    local native = ffi.new("TecsPhysicsHandle[1]") as loader.CArray
    if not C.tecsPhysicsBodyByEntity(self.handle, entity, native) as boolean then
        return nil
    end
    return {
        native = native[0] as loader.CValue,
        world = self,
    }
end

function World:colliderByEntity(entity: integer): Handle
    local native = ffi.new("TecsPhysicsHandle[1]") as loader.CArray
    if not C.tecsPhysicsColliderByEntity(self.handle, entity, native) as boolean then
        return nil
    end
    return {
        native = native[0] as loader.CValue,
        world = self,
    }
end

function World:beginPairEvents()
    local count = ffi.new("size_t[1]") as loader.CArray
    self._events = C.tecsPhysicsPairEvents(self.handle, count)
    self._eventCount = tonumber(count[0]) as integer
end

function World:pairEvent(index: integer): integer, integer, boolean, boolean
    local event = (self._events as {integer: loader.CStruct})[index]
    return event.entity_a as integer, event.entity_b as integer, event.started ~= 0, event.sensor ~= 0
end

function World:pairEventCount(): integer
    return self._eventCount
end

function World:snapshot(): string
    local snapshot = C.tecsPhysicsSnapshotCreate(self.handle)
    if snapshot == nil then
        error("tecs: cannot snapshot Rapier: " .. loader.toString(C.tecsRustError()), 2)
    end
    local length = tonumber(C.tecsPhysicsSnapshotLength(snapshot)) as integer
    local bytes = loader.toBytes(C.tecsPhysicsSnapshotData(snapshot), length)
    C.tecsPhysicsSnapshotDestroy(snapshot)
    return bytes
end

function World:restore(snapshot: string)
    if not C.tecsPhysicsSnapshotRestore(self.handle, snapshot, #snapshot) as boolean then
        error("tecs: cannot restore Rapier: " .. loader.toString(C.tecsRustError()), 2)
    end
end

function World:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    worlds[self._id] = nil
    C.tecsPhysicsWorldDestroy(self.handle)
    self.handle = nil
    self.taskPool:release()
end

return World
