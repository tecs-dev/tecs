










local tecs = require("tecs")
local loader = require("tecs2d.ffi.loader")
local World = require("tecs2d.physics.World")
local components = require("tecs2d.components")

local Transform2D = components.Transform2D








local PIXELS_PER_METRE = 32.0





local RigidBody = {}





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
























local physics = {}






physics.RigidBody = RigidBody
physics.scale = PIXELS_PER_METRE

local function toMetres(pixels)
   return pixels / PIXELS_PER_METRE
end

local function toPixels(metres)
   return metres * PIXELS_PER_METRE
end





function physics.attach(world, entity,
   options)
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

   local handle = body
   world:set(entity, RigidBody(
   handle.index1,
   handle.world0,
   handle.generation))

   return body
end




local scratchHandle = loader.newStruct("b2BodyId")
local scratchFields = scratchHandle





local function handleOf(row)
   scratchFields.index1 = row.index1
   scratchFields.world0 = row.world0
   scratchFields.generation = row.generation
   return scratchHandle
end


function physics.plugin(options)
   options = options or {}
   local gravity = options.gravity or { 0.0, 980.0 }
   local timeStep = options.timeStep or 1.0 / 60.0

   return function(world)
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
