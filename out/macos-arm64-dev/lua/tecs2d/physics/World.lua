






local ffi = require("ffi")
local box2d = require("tecs2d.ffi.box2d")
local loader = require("tecs2d.ffi.loader")

local C = box2d.C





























local World = {}





local WorldMT = { __index = World }

local BODY_TYPES = {
   static = 0,
   kinematic = 1,
   dynamic = 2,
}


function World.create(options)
   options = options or {}

   local def = ffi.new("b2WorldDef[1]")
   def[0] = C.b2DefaultWorldDef()

   local settings = def[0]
   local gravity = settings.gravity
   if options.gravity ~= nil then
      gravity.x = options.gravity.x or 0.0
      gravity.y = options.gravity.y or 0.0
   end

   local self = setmetatable({}, WorldMT)
   self.handle = C.b2CreateWorld(def)
   self.subStepCount = options.subStepCount or 4
   self._destroyed = false
   return self
end





function World:step(dt)
   C.b2World_Step(self.handle, dt, self.subStepCount)
end


function World:createBody(options)
   options = options or {}

   local def = ffi.new("b2BodyDef[1]")
   def[0] = C.b2DefaultBodyDef()

   local settings = def[0]
   settings.type = BODY_TYPES[options.type or "static"] or 0

   if options.position ~= nil then
      local position = settings.position
      position.x = options.position.x or 0.0
      position.y = options.position.y or 0.0
   end
   if options.angle ~= nil then



      local rotation = settings.rotation
      rotation.c = math.cos(options.angle)
      rotation.s = math.sin(options.angle)
   end
   if options.fixedRotation ~= nil then
      settings.fixedRotation = options.fixedRotation
   end
   if options.gravityScale ~= nil then
      settings.gravityScale = options.gravityScale
   end

   return C.b2CreateBody(self.handle, def)
end

local function shapeDef(options)
   options = options or {}
   local def = ffi.new("b2ShapeDef[1]")
   def[0] = C.b2DefaultShapeDef()

   local settings = def[0]
   if options.density ~= nil then settings.density = options.density end
   if options.friction ~= nil then
      local material = settings.material
      material.friction = options.friction
   end
   if options.restitution ~= nil then
      local material = settings.material
      material.restitution = options.restitution
   end
   return def
end



function World.addBox(body, halfWidth, halfHeight,
   options)
   local polygon = ffi.new("b2Polygon[1]")
   polygon[0] = C.b2MakeBox(halfWidth, halfHeight)
   return C.b2CreatePolygonShape(body, shapeDef(options), polygon)
end


function World.addCircle(body, radius,
   options)
   local circle = ffi.new("b2Circle[1]")
   local shape = circle[0]
   local centre = shape.center
   centre.x = 0.0
   centre.y = 0.0
   shape.radius = radius
   return C.b2CreateCircleShape(body, shapeDef(options), circle)
end


function World.getPosition(body)
   local position = C.b2Body_GetPosition(body)
   return position.x, position.y
end





function World.getAngle(body)
   local rotation = C.b2Body_GetRotation(body)
   return math.atan2(rotation.s, rotation.c)
end


function World.getVelocity(body)
   local velocity = C.b2Body_GetLinearVelocity(body)
   return velocity.x, velocity.y
end


function World:destroy()
   if self._destroyed then return end
   self._destroyed = true
   C.b2DestroyWorld(self.handle)
   self.handle = nil
end

return World
