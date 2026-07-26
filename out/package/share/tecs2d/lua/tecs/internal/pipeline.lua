local types = require("tecs.types")
local phases = require("tecs.internal.phases")
local fixedtracking = require("tecs.internal.fixedtracking")
local EMPTY = require("tecs.utils.pool").EMPTY

local table_new = require("table.new")













local function loadUntyped(modName)
   return require(modName)
end
local zone = loadUntyped("jit.zone")












local pipeline = {}




local PipelineImpl = {}




























local MAX_ITERATIONS = 10


local EMPTY_GROUP = {
   runs = {},
   runIfs = {},
   ids = {},
   names = {},
   count = 0,
}


local BEFORE_FIXED_PHASES = { phases.First, phases.PreUpdate }
local FIXED_PHASES = phases.FixedUpdateGroup.children
local AFTER_FIXED_PHASES = { phases.Update, phases.PostUpdate, phases.RenderFirst,
phases.PreRender, phases.Render, phases.PostRender, phases.RenderLast, phases.Last, }

function pipeline.new(fixedTimestep)
   local result = setmetatable({
      dirty = true,
      systems = {},
      phaseStates = table_new(#phases.index, 0),
      fixedTimestep = fixedTimestep or (1 / 60),
      fixedAccumulator = 0,
      count = 0,
      beforeFixedGroup = EMPTY_GROUP,
      fixedGroup = EMPTY_GROUP,
      afterFixedGroup = EMPTY_GROUP,
      phaseGroups = {},
      systemNameRegistry = {},
      anonymousSystemCount = 0,
   }, { __index = PipelineImpl })


   for i = 1, #phases.index do
      result.systems[i] = {}
      result.phaseStates[i] = true
   end

   return result
end




local function topologicalSort(systems)
   local n = #systems
   if n < 2 then return systems end

   local systemNameMap = {}
   for i = 1, n do
      local name = systems[i].name
      if name then
         systemNameMap[name] = systems[i]
      end
   end




   local succs = {}
   local edgeSeen = {}
   local indegree = {}
   for i = 1, n do
      indegree[systems[i]] = 0
   end

   local function addEdge(first, second)
      if first == second then return end
      local seen = edgeSeen[first]
      if not seen then
         seen = {}
         edgeSeen[first] = seen
      end
      if seen[second] then return end
      seen[second] = true
      local list = succs[first]
      if not list then
         list = {}
         succs[first] = list
      end
      list[#list + 1] = second
      indegree[second] = indegree[second] + 1
   end

   for i = 1, n do
      local config = systems[i]
      local after = config.after
      if after then
         for j = 1, #after do
            local dep = systemNameMap[after[j]]
            if dep then addEdge(dep, config) end
         end
      end
      local before = config.before
      if before then
         for j = 1, #before do
            local target = systemNameMap[before[j]]
            if target then addEdge(config, target) end
         end
      end
   end



   local sorted = table_new(n, 0)
   local emitted = {}
   local sortedCount = 0
   while sortedCount < n do
      local progressed = false
      for i = 1, n do
         local config = systems[i]
         if not emitted[config] and indegree[config] == 0 then
            emitted[config] = true
            progressed = true
            sortedCount = sortedCount + 1
            sorted[sortedCount] = config
            local list = succs[config]
            if list then
               for j = 1, #list do
                  local succ = list[j]
                  indegree[succ] = indegree[succ] - 1
               end
            end
         end
      end
      if not progressed then
         error("Cycle detected in system dependencies")
      end
   end

   return sorted
end


local function buildFlatGroup(configs)
   local n = #configs
   if n == 0 then return EMPTY_GROUP end

   local runs = table_new(n, 0)
   local runIfs = table_new(n, 0)
   local ids = table_new(n, 0)
   local names = table_new(n, 0)

   for i = 1, n do
      local config = configs[i]
      runs[i] = config.run
      runIfs[i] = config.runIf
      ids[i] = config.id
      names[i] = config.name
   end

   return {
      runs = runs,
      runIfs = runIfs,
      ids = ids,
      names = names,
      count = n,
   }
end


local function collectPhaseSystems(
   self,
   phaseList)

   local result = {}
   local n = 0
   for i = 1, #phaseList do
      local phase = phaseList[i]
      if self.phaseStates[phase.position] then
         local phaseSystems = self.systems[phase.position]
         if phaseSystems then
            for j = 1, #phaseSystems do
               n = n + 1
               result[n] = phaseSystems[j]
            end
         end
      end
   end
   return result
end

local function recreatePipeline(self)



   local count = 0
   for i = 1, #phases.index do
      local systems = self.systems[i]
      if systems then
         count = count + #systems
         if #systems > 0 then
            self.systems[i] = topologicalSort(systems)
         end
      end
   end
   self.count = count


   self.beforeFixedGroup = buildFlatGroup(collectPhaseSystems(self, BEFORE_FIXED_PHASES))
   self.fixedGroup = buildFlatGroup(collectPhaseSystems(self, FIXED_PHASES))
   self.afterFixedGroup = buildFlatGroup(collectPhaseSystems(self, AFTER_FIXED_PHASES))


   self.phaseGroups = {}
   for i = 1, #phases.index do
      local systems = self.systems[i]
      if systems and #systems > 0 then
         self.phaseGroups[i] = buildFlatGroup(systems)
      else
         self.phaseGroups[i] = EMPTY_GROUP
      end
   end

   self.dirty = false
end



local function runGroup(group, dt, world)
   local n = group.count
   if n == 0 then return end

   local runs = group.runs
   local runIfArr = group.runIfs
   local idArr = group.ids
   local nameArr = group.names

   for i = 1, n do
      local runIf = runIfArr[i]
      if not runIf or runIf(dt, world, nameArr[i]) then
         zone(idArr[i])
         runs[i](dt, world)
         zone()
      end
   end
end



local function runFixedLoop(self, dt, world)
   local fixedTimestep = self.fixedTimestep
   self.fixedAccumulator = self.fixedAccumulator + dt


   if self.fixedAccumulator < fixedTimestep then
      return
   end

   local fixedGroup = self.fixedGroup
   local hasWork = fixedGroup.count > 0
   local iterations = 0

   repeat
      iterations = iterations + 1
      fixedtracking.beginStep(world)
      if hasWork then
         runGroup(fixedGroup, fixedTimestep, world)
      end
      fixedtracking.finishStep(world)
      self.fixedAccumulator = self.fixedAccumulator - fixedTimestep
      if self.fixedAccumulator < fixedTimestep or iterations >= MAX_ITERATIONS then
         break
      end
   until false



   if iterations >= MAX_ITERATIONS then
      self.fixedAccumulator = math.min(self.fixedAccumulator, fixedTimestep * 2)
   end
end

function PipelineImpl:update(dt, world)
   if self.dirty then
      recreatePipeline(self)
   end

   zone("beforeFixed")
   if self.beforeFixedGroup.count > 0 then
      runGroup(self.beforeFixedGroup, dt, world)
   end
   zone()

   zone("fixedLoop")
   runFixedLoop(self, dt, world)
   zone()

   zone("afterFixed")
   if self.afterFixedGroup.count > 0 then
      runGroup(self.afterFixedGroup, dt, world)
   end
   zone()
end

function PipelineImpl:enablePhase(phase)

   if self.phaseStates[phase.position] ~= nil then
      self.phaseStates[phase.position] = true
   end

   if phase.children then
      for i = 1, #phase.children do
         self:enablePhase(phase.children[i])
      end
   end

   self.dirty = true
end

function PipelineImpl:disablePhase(phase)

   if self.phaseStates[phase.position] ~= nil then
      self.phaseStates[phase.position] = false
   end

   if phase.children then
      for i = 1, #phase.children do
         self:disablePhase(phase.children[i])
      end
   end

   self.dirty = true
end

function PipelineImpl:removeSystem(systemName)

   local phasePosition = self.systemNameRegistry[systemName]
   if not phasePosition then
      error("System '" .. systemName .. "' not found in pipeline")
   end


   local phaseSystems = self.systems[phasePosition]
   if phaseSystems then
      for i = 1, #phaseSystems do
         if phaseSystems[i].name == systemName then
            table.remove(phaseSystems, i)
            self.count = self.count - 1
            self.dirty = true

            self.systemNameRegistry[systemName] = nil
            return
         end
      end
   end
end

function PipelineImpl:addSystem(config)
   assert(config.run, "Missing system in phase system")
   local phase = assert(config.phase, "Missing phase in phase system")
   if not phase.position then
      error("Phase does not have a position: " .. (phase.name or tostring(phase)))
   end
   if self.phaseStates[phase.position] == nil then
      error("Phase is not registered in the pipeline: " .. (phase.name or tostring(phase)))
   end



   local name = config.name
   if not name then
      self.anonymousSystemCount = self.anonymousSystemCount + 1
      name = "_anonymousSystem" .. self.anonymousSystemCount
      config.name = name
   end

   if self.systemNameRegistry[name] then
      error("System with name '" .. name .. "' already exists in the pipeline")
   end
   self.systemNameRegistry[name] = phase.position

   local phaseName = phase.name or "Unknown"
   local registered = config
   registered.id = phaseName .. ":" .. name

   config.before = config.before or EMPTY
   config.after = config.after or EMPTY
   self.systems[phase.position][#self.systems[phase.position] + 1] = registered
   self.count = self.count + 1
   self.dirty = true
end


local function runPhaseNoCommit(self, phase, dt, world)
   if not phase.children then


      if self.phaseStates[phase.position] then
         local group = self.phaseGroups[phase.position]
         if group then
            runGroup(group, dt, world)
         end
      end
   else

      for i = 1, #phase.children do
         local child = phase.children[i]
         if child.position and child.position > 0 and self.phaseStates[child.position] then
            if child.children then
               runPhaseNoCommit(self, child, dt, world)
            else
               local group = self.phaseGroups[child.position]
               if group then
                  runGroup(group, dt, world)
               end
            end
         end
      end
   end
end

function PipelineImpl:run(phase, dt, world)
   if self.dirty then
      recreatePipeline(self)
   end

   runPhaseNoCommit(self, phase, dt, world)
end

function PipelineImpl:registerPhase(phase)

   if not phase.position then
      phases.index[#phases.index + 1] = phase
      phase.position = #phases.index
   end


   if not self.systems[phase.position] then
      self.systems[phase.position] = {}
      self.phaseStates[phase.position] = true
   end

   self.dirty = true
end

return pipeline
