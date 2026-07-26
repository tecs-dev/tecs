local components = require("tecs.internal.components")
local events = require("tecs.internal.events")
local internal = require("tecs.internal.types")
local behavior = require("tecs.internal.behavior")
local phases = require("tecs.internal.phases")
local types = require("tecs.types")
local table_clear = require("table.clear")




local math_sin = math.sin
local math_cos = math.cos


local builtins = { Transform = {}, TTL = {}, OnSpawn = {}, OnDespawn = {}, ArchetypeCreated = {}, StateEnter = {}, StateExit = {}, StateBlur = {}, StateFocus = {}, OnSnapshotSave = {}, StartSnapshotLoad = {}, FinishSnapshotLoad = {}, RelativeTransform = {} }





































































































































































































































































builtins.ChildOf = components.newRelationship({
   name = "ChildOf",
   exclusive = true,
   sparse = true,
   reverseIndex = true,
   cascadeDelete = true,
})





events.newFFIEvent(builtins.OnSpawn, {
   { "entity", "double" },
}, "Tecs_OnSpawn")

events.newFFIEvent(builtins.OnDespawn, {
   { "entity", "double" },
}, "Tecs_OnDespawn")

builtins.ArchetypeCreated.init = function(e, archetype)
   e.archetype = archetype
end
events.newEvent(builtins.ArchetypeCreated)





builtins.StateEnter.init = function(e, state)
   e.state = state
end
events.newEvent(builtins.StateEnter)

builtins.StateExit.init = function(e, state)
   e.state = state
end
events.newEvent(builtins.StateExit)

builtins.StateBlur.init = function(e, state, pushed)
   e.state = state
   e.pushed = pushed
end
events.newEvent(builtins.StateBlur)

builtins.StateFocus.init = function(e, state, popped)
   e.state = state
   e.popped = popped
end
events.newEvent(builtins.StateFocus)





builtins.OnSnapshotSave.init = function(_e) end
builtins.StartSnapshotLoad.init = function(_e) end
builtins.FinishSnapshotLoad.init = function(_e) end
events.newEvent(builtins.OnSnapshotSave)
events.newEvent(builtins.StartSnapshotLoad)
events.newEvent(builtins.FinishSnapshotLoad)





builtins.Name = components.newScalarComponent({
   name = "Name",
   kind = "string",
})

builtins.Key = components.newScalarComponent({
   name = "Key",
   kind = "string",
})

do
   local Key = builtins.Key
   local keyI = Key
   keyI.frameworkBehavior = behavior.Key
   keyI.frameworkBehaviorBits = behavior.keyBits()
end

components.newFFIComponent({
   name = "Transform",
   container = builtins.Transform,
   fields = {
      { "x", "float" },
      { "y", "float" },
      { "z", "float" },
      { "layer", "int32_t" },
      { "rotation", "float" },
      { "scaleX", "float" },
      { "scaleY", "float" },
   },
   defaults = { 0, 0, 0, 1, 0, 1, 1 },
   init = function(instance)
      if instance.layer < 1 then
         error("Transform layer must be greater than 0, got: " .. tostring(instance.layer))
      end
   end,
})

local function percentComplete(self)
   return 1 - (self.remaining / self.startingTime)
end

components.newComponent({
   name = "TTL",
   container = builtins.TTL,
   fields = { "remaining", "startingTime" },
   init = function(instance, remaining, startingTime)
      assert(remaining > 0, "TTL must be greater than 0")
      if startingTime ~= nil then
         assert(startingTime > 0, "TTL startingTime must be greater than 0")
         assert(startingTime >= remaining, "TTL startingTime must be >= remaining")
      end
      instance.remaining = remaining
      instance.startingTime = startingTime or remaining
      instance.percentComplete = percentComplete
   end,
})

builtins.Disabled = components.newTagComponent({
   name = "Disabled",
})

builtins.Paused = components.newTagComponent({
   name = "Paused",
})

components.newFFIComponent({
   name = "RelativeTransform",
   container = builtins.RelativeTransform,
   fields = {
      { "x", "float" },
      { "y", "float" },
      { "z", "float" },
      { "rotation", "float" },
      { "scaleX", "float" },
      { "scaleY", "float" },
      { "originX", "float" },
      { "originY", "float" },
   },
   defaults = { 0, 0, 0, 0, 1, 1, 0, 0 },




   requires = { builtins.Transform },
})







local function composeTransforms(
   parentTransform,
   relativeTransform,
   outputTransform)

   local pRot, pScaleX, pScaleY = parentTransform.rotation, parentTransform.scaleX, parentTransform.scaleY


   local cosRot = math_cos(pRot)
   local sinRot = math_sin(pRot)
   local scaledX = relativeTransform.x * pScaleX
   local scaledY = relativeTransform.y * pScaleY
   local rotatedX = scaledX * cosRot - scaledY * sinRot
   local rotatedY = scaledX * sinRot + scaledY * cosRot


   outputTransform.x = parentTransform.x + rotatedX
   outputTransform.y = parentTransform.y + rotatedY
   outputTransform.z = parentTransform.z + relativeTransform.z
   outputTransform.layer = parentTransform.layer
   outputTransform.rotation = pRot + relativeTransform.rotation
   outputTransform.scaleX = pScaleX * relativeTransform.scaleX
   outputTransform.scaleY = pScaleY * relativeTransform.scaleY
end

function builtins.plugin(w)
   local TTL = builtins.TTL
   local Transform = builtins.Transform
   local RelativeTransform = builtins.RelativeTransform
   local ChildOf = builtins.ChildOf


   do
      local ttlQuery = w:query({ include = { TTL }, type = "logic" })
      w:addSystem({
         name = "ttl",
         phase = phases.FixedUpdate,
         run = function(dt)
            for archetype, len, entities in ttlQuery:iter() do
               local ttls = archetype:getMut(TTL)
               for row = 1, len do
                  local ttl = ttls[row]
                  ttl.remaining = ttl.remaining - dt
                  if ttl.remaining <= 0 then
                     w:despawn(entities[row])
                  end
               end
            end
         end,
      })
   end


   do




      local scratchTransform = Transform(0, 0)




      local worldTransformCache = {}
      setmetatable(worldTransformCache, {
         __index = function(self, entityId)
            local transform = w:get(entityId, Transform)
            if not transform then
               return nil
            end

            local relTransform = w:get(entityId, RelativeTransform)
            if not relTransform then

               self[entityId] = transform
               return transform
            end

            local childOf = w:getFirstRelationship(entityId, ChildOf)
            if not childOf then
               self[entityId] = transform
               return transform
            end


            local parentWorldTransform = self[childOf.target]
            if parentWorldTransform then
               local scratch = scratchTransform
               composeTransforms(parentWorldTransform, relTransform, scratch)
               if transform.x ~= scratch.x or transform.y ~= scratch.y or
                  transform.z ~= scratch.z or
                  transform.layer ~= scratch.layer or
                  transform.rotation ~= scratch.rotation or
                  transform.scaleX ~= scratch.scaleX or
                  transform.scaleY ~= scratch.scaleY then
                  transform.x = scratch.x
                  transform.y = scratch.y
                  transform.z = scratch.z
                  transform.layer = scratch.layer
                  transform.rotation = scratch.rotation
                  transform.scaleX = scratch.scaleX
                  transform.scaleY = scratch.scaleY




                  w:markComponentDirty(entityId, Transform)
               end
            end

            self[entityId] = transform
            return transform
         end,
      })

      local hierarchyQuery = w:query({
         name = "RelativeTransform",
         include = { RelativeTransform, ChildOf, Transform },
      })

      local wImpl = w
      local function hierarchyStateDirty()
         for arch in wImpl:dirtyArchetypes() do
            local cols = arch.columns
            if cols[Transform] or cols[RelativeTransform] or cols[ChildOf] then
               return true
            end
         end
         return false
      end






      local pendingHierarchyDirty = false
      w:addSystem({
         name = "RelativeTransformDirtySampler",
         phase = phases.RenderLast,
         run = function()
            pendingHierarchyDirty = hierarchyStateDirty()
         end,
      })

      w:addSystem({
         name = "RelativeTransform",
         phase = phases.PostUpdate,
         run = function()




            if not pendingHierarchyDirty and not hierarchyStateDirty() then
               return
            end
            pendingHierarchyDirty = false

            table_clear(worldTransformCache)
            for _archetype, len, entities in hierarchyQuery:iter() do


               for row = 1, len do

                  local _ = worldTransformCache[entities[row]]
               end
            end
         end,
      })
   end
end

return builtins
