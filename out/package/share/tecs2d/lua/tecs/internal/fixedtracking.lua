






local types = require("tecs.types")

















local fixedtracking = {}














local statesByWorld =
setmetatable({}, { __mode = "k" })
local statesByDirtySet =
setmetatable({}, { __mode = "k" })

local function dirtySetOf(world)
   return ((world)._dirtyArchetypes)
end

local function stateFor(world)
   local state = statesByWorld[world]
   if state then return state end

   state = {
      tracked = {},
      trackedList = {},
      versions = setmetatable({}, { __mode = "k" }),

      fixedWrites = setmetatable({}, { __mode = "k" }),

      structureVersions = setmetatable({}, { __mode = "k" }),

      beforeCallbacks = {},
      callbacks = {},
      step = 0,
      active = false,
   }
   statesByWorld[world] = state
   statesByDirtySet[dirtySetOf(world)] = state
   return state
end

function fixedtracking.track(world, component)
   local state = stateFor(world)
   if state.tracked[component] then return end
   state.tracked[component] = true
   state.trackedList[#state.trackedList + 1] = component
   world:forEachArchetype(function(archetype)
      (archetype)._fixedTracking = true
   end)
end

function fixedtracking.enabled(dirtySet)
   return statesByDirtySet[dirtySet] ~= nil
end

function fixedtracking.beforeStep(world, callback)
   local state = stateFor(world)
   state.beforeCallbacks[#state.beforeCallbacks + 1] = callback
end

function fixedtracking.afterStep(world, callback)
   local state = stateFor(world)
   state.callbacks[#state.callbacks + 1] = callback
end

function fixedtracking.beginStep(world)
   local state = statesByWorld[world]
   if not state then return end
   state.step = state.step + 1
   local callbacks = state.beforeCallbacks
   for i = 1, #callbacks do
      callbacks[i](world)
   end
   state.active = true
end

function fixedtracking.finishStep(world)
   local state = statesByWorld[world]
   if not state then return end
   local callbacks = state.callbacks
   for i = 1, #callbacks do
      callbacks[i](world)
   end
   state.active = false
end

function fixedtracking.mark(archetype, component)
   local dirtySet = (archetype)._dirtySet
   local state = statesByDirtySet[dirtySet]
   if not state or not state.tracked[component] then return end

   local versions = state.versions[archetype]
   if not versions then
      versions = {}
      state.versions[archetype] = versions
   end
   versions[component] = (versions[component] or 0) + 1

   local writes = state.fixedWrites[archetype]
   if state.active then
      if not writes then
         writes = {}
         state.fixedWrites[archetype] = writes
      end
      writes[component] = state.step
   elseif writes then


      writes[component] = -1
   end
end

function fixedtracking.markAll(archetype)
   local dirtySet = (archetype)._dirtySet
   local state = statesByDirtySet[dirtySet]
   if not state then return end

   local columns = (archetype).columns
   local tracked = state.trackedList
   local touched = false
   for i = 1, #tracked do
      local component = tracked[i]
      if rawget(columns, component) ~= nil then
         touched = true
         fixedtracking.mark(archetype, component)
      end
   end
   if touched then
      state.structureVersions[archetype] =
      (state.structureVersions[archetype] or 0) + 1
   end
end

function fixedtracking.version(archetype, component)
   local dirtySet = (archetype)._dirtySet
   local state = statesByDirtySet[dirtySet]
   if not state or not state.tracked[component] then return -1 end
   local versions = state.versions[archetype]
   return versions and (versions[component] or 0) or 0
end

function fixedtracking.structureVersion(archetype)
   local dirtySet = (archetype)._dirtySet
   local state = statesByDirtySet[dirtySet]
   return state and (state.structureVersions[archetype] or 0) or -1
end

function fixedtracking.wroteThisStep(
   world,
   archetype,
   component)

   local state = statesByWorld[world]
   if not state then return false end
   local writes = state.fixedWrites[archetype]
   return writes ~= nil and writes[component] == state.step
end

function fixedtracking.currentStep(world)
   local state = statesByWorld[world]
   return state and state.step or 0
end

return fixedtracking
