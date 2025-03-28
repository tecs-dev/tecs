local types = require("tecs.types")
local phases = require("tecs.internal.phases")
local compat = require("tecs.internal.utils.compat")
local EMPTY = require("tecs.internal.utils.pool").EMPTY

local table_new = compat.new

local type World = types.World
local type System = types.System
local type RunAfter = function(world: World)
local type Pipeline = types.Pipeline
local type Phase = types.Phase
local type SystemConfig = types.SystemConfig

--- Pipeline for executing ECS systems in dependency order.
---
--- Executes in three phases: BeforeFixed -> FixedLoop -> AfterFixed.
--- Optimized for hot path performance with flattened execution, cached ranges, and lazy rebuilding.
local record pipeline
    --- Creates a new pipeline with optimized execution paths.
    ---
    --- @param fixedTimestep Fixed timestep for physics/game logic (defaults to 1/60 = 60 FPS)
    --- @param runAfter Callback executed after each system (typically for committing changes)
    --- @return Optimized pipeline instance
    new: function(fixedTimestep: number, runAfter: RunAfter): Pipeline
end

--- Private implementation of the pipeline.
local record PipelineImpl is Pipeline
    --- Set to true when the pipeline needs to be recreated.
    dirty: boolean

    --- Index of phase ID to system configurations (array index is the phase position).
    systems: {{SystemConfig}}

    --- Index of phase ID to whether a phase is enabled or disabled (array index is the phase position).
    phaseStates: {boolean}

    --- Fixed timestep to use (defaults to 1/60 or 60 FPS).
    fixedTimestep: number

    --- Accumulator for fixed update loop.
    fixedAccumulator: number

    --- Commits any changes to the world after each system.
    runAfter: RunAfter

    --- The number of systems in the pipeline.
    count: integer

    -- The computed flattened list of sorted systems.
    flatSystems: {SystemConfig}

    -- These systems are the ordered section of systems run before the fixed update loop.
    beforeFixedSystems: {integer, integer}

    -- These are the fixed update systems.
    fixedSystems: {integer, integer}

    -- These are the systems called after the update system, including rendering systems.
    afterFixedSystems: {integer, integer}
end

local ALWAYS_RUN <const> = function(_dt: number, _world: World): boolean return true end
local NO_OP_RUN_AFTER <const>: RunAfter = function(_world: World) end

-- The maximum number of iterations for the fixed update loop.
-- This is used to prevent infinite loops, death spirals, and to provide predictable performance.
local MAX_ITERATIONS <const> = 10

-- The list of phases for each span of flatSystems.
local BEFORE_FIXED_PHASES <const> = {phases.First, phases.PreUpdate}
local FIXED_PHASES <const> = phases.FixedUpdateGroup.children
local AFTER_FIXED_PHASES <const> = {phases.Update, phases.PostUpdate, phases.RenderFirst,
    phases.PreRender, phases.Render, phases.PostRender, phases.RenderLast, phases.Last}

function pipeline.new(fixedTimestep: number, runAfter: RunAfter): Pipeline
    local result: PipelineImpl = setmetatable({
        dirty = true,
        systems = {},
        phaseStates = table_new(#phases.index, 0) as {boolean},
        fixedTimestep = fixedTimestep or (1 / 60), -- Default to 60 FPS if not provided
        fixedAccumulator = 0,
        runAfter = runAfter or NO_OP_RUN_AFTER,
        count = 0
    }, { __index = PipelineImpl })

    -- Initialize each phase.
    for i = 1, #phases.index do
        result.systems[i] = {}
        result.phaseStates[i] = true
    end

    return result
end

-- Perform a topological sort on the systems based on their dependencies.
local function topologicalSort(systems: {SystemConfig}): {SystemConfig}
    local sorted = {}
    local visited = {}

    -- This mark is used to detect cycles by setting the mark before recursing and clearing it after.
    local tempMark = {}

    -- Create a map of system names to their configurations.
    local systemNameMap: {string: SystemConfig} = {}
    local systemConfigMap: {System: SystemConfig} = {}

    -- Build adjacency list for "before" constraints
    local dependents: {System: {System}} = {}

    for i = 1, #systems do
        local config = systems[i]
        systemConfigMap[config.run] = config
        local name = config.name
        if name then
            systemNameMap[name] = config
        end
    end

    -- Process "before" constraints to build reverse dependencies
    for i = 1, #systems do
        local config = systems[i]
        if config.before then
            for j = 1, #config.before do
                local beforeSystem = config.before[j]
                local beforeMapping = systemNameMap[beforeSystem]
                if not beforeMapping then
                    error("System " .. beforeSystem .. " does not exist in phase " .. config.phase.name)
                end
                -- beforeMapping must run after config.run
                dependents[config.run] = dependents[config.run] or {}
                table.insert(dependents[config.run], beforeMapping.run)
            end
        end
    end

    --- Visit a system and its dependencies recursively.
    local function visit(system: System)
        if tempMark[system] then
            error("Cycle detected in system dependencies")
        elseif not visited[system] then
            tempMark[system] = true
            local config = systemConfigMap[system]

            -- Visit all systems that the current system depends on ("after" list)
            if config.after then
                for i = 1, #config.after do
                    local afterSystem = config.after[i]
                    local afterMapping = systemNameMap[afterSystem]
                    if not afterMapping then
                        error("System " .. afterSystem .. " does not exist in phase " .. config.phase.name)
                    end
                    visit(afterMapping.run)
                end
            end

            -- Add current system to sorted list
            table.insert(sorted, config)

            -- Visit all systems that depend on this one (from "before" constraints)
            local deps = dependents[system]
            if deps then
                for i = 1, #deps do
                    visit(deps[i])
                end
            end

            visited[system] = true
            tempMark[system] = nil
        end
    end

    -- Visit each system in the list.
    for i = 1, #systems do
        local system = systems[i].run
        if not visited[system] then
            visit(system)
        end
    end

    return sorted
end

-- Helper function to add systems from a phase to the flat list
local function addPhaseSystems(
    self: PipelineImpl,
    phaseList: {Phase},
    flatList: {SystemConfig}
): {integer, integer}
    local startIndex = #flatList + 1
    local systemCount = 0

    for _, phase in ipairs(phaseList) do
        -- Skip disabled phases
        if self.phaseStates[phase.position] then
            local phaseSystems = self.systems[phase.position]
            if phaseSystems and #phaseSystems > 0 then
                for _, config in ipairs(phaseSystems) do
                    table.insert(flatList, config)
                    systemCount = systemCount + 1
                end
            end
        end
    end

    return {startIndex, #flatList}
end

local function recreatePipeline(self: PipelineImpl)
    -- Topologically sort the systems in each phase.
    local count = 0
    for i = 1, #phases.index do
        local systems = self.systems[i]
        count = count + #systems
        if systems and #systems > 0 then
            self.systems[i] = topologicalSort(systems)
        end
    end
    self.count = count

    -- Recreate the flattened list of systems and compute indices.
    local flatSystems = {}
    self.beforeFixedSystems = addPhaseSystems(self, BEFORE_FIXED_PHASES, flatSystems)
    self.fixedSystems = addPhaseSystems(self, FIXED_PHASES, flatSystems)
    self.afterFixedSystems = addPhaseSystems(self, AFTER_FIXED_PHASES, flatSystems)
    self.flatSystems = flatSystems

    self.dirty = false
end

--- Execute a range of systems from the pre-flattened array.
--- - Cache table lookups (flatSystems, runAfter) outside the loop
--- - Use numeric range iteration for maximum performance
--- - Avoid phase lookup overhead by using pre-computed indices
local function runFlattenedSystems(self: PipelineImpl, systemRange: {integer, integer}, dt: number, world: World)
    local flatSystems = self.flatSystems
    local runAfter = self.runAfter
    for i = systemRange[1], systemRange[2] do
        local config = flatSystems[i]
        if config.runIf(dt, world) then
            config.run(dt, world)
            runAfter(world)
        end
    end
end

local function runSystems(self: PipelineImpl, phase: Phase, dt: number, world: World)
    local systems <const> = self.systems[phase.position]
    if systems then
        local runAfter <const> = self.runAfter
        for i = 1, #systems do
            local config = systems[i]
            if config.runIf(dt, world) then
                config.run(dt, world)
                runAfter(world)
            end
        end
    end
end

--- Execute fixed timestep systems with death spiral protection.
--- Uses accumulator pattern for frame-rate independent physics.
local function runFixedLoop(self: PipelineImpl, dt: number, world: World)
    local fixedTimestep = self.fixedTimestep
    self.fixedAccumulator = self.fixedAccumulator + dt

    -- don't enter loop if insufficient time
    if self.fixedAccumulator < fixedTimestep then
        return
    end

    local fixedSystems = self.fixedSystems
    local iterations = 0

    repeat
        iterations = iterations + 1
        runFlattenedSystems(self, fixedSystems, fixedTimestep, world)
        self.fixedAccumulator = self.fixedAccumulator - fixedTimestep
        if self.fixedAccumulator < fixedTimestep or iterations >= MAX_ITERATIONS then
            break
        end
    until false

    -- clamp accumulator to prevent excessive buildup
    -- while preserving some timing information for smoother recovery
    if iterations >= MAX_ITERATIONS then
        self.fixedAccumulator = math.min(self.fixedAccumulator, fixedTimestep * 2)
    end
end

function PipelineImpl:update(dt: number, world: World)
    if self.dirty then
        recreatePipeline(self)
    end

    runFlattenedSystems(self, self.beforeFixedSystems, dt, world)
    runFixedLoop(self, dt, world)
    runFlattenedSystems(self, self.afterFixedSystems, dt, world)
end

function PipelineImpl:enablePhase(phase: Phase)
    -- Deal with phase groups.
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

function PipelineImpl:disablePhase(phase: Phase)
    -- Deal with phase groups.
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

function PipelineImpl:removeSystem(phase: Phase, system: System | string)
    local phaseSystems <const> = self.systems[phase.position]
    if phaseSystems then
        for i = 1, #phaseSystems do
            local phaseSystem = phaseSystems[i]
            if phaseSystem.run == system or phaseSystem.name == system then
                table.remove(phaseSystems, i)
                self.count = self.count - 1
                self.dirty = true
                return
            end
        end
    end
end

function PipelineImpl:addSystem(config: SystemConfig)
    assert(config.run, "Missing system in phase system")
    local phase <const> = assert(config.phase, "Missing phase in phase system")
    if not phase.position then
        error("Phase does not have a position: " .. (phase.name or tostring(phase)))
    end
    if self.phaseStates[phase.position] == nil then
        error("Phase is not registered in the pipeline: " .. (phase.name or tostring(phase)))
    end
    config.runIf = config.runIf or ALWAYS_RUN
    config.before = config.before or EMPTY as {string}
    config.after = config.after or EMPTY as {string}
    table.insert(self.systems[phase.position], config)
    self.dirty = true
    -- Don't update count here, it will be updated when recreatePipeline is called
end

function PipelineImpl:run(phase: Phase, dt: number, world: World)
    -- Always run the given phase first.
    runSystems(self, phase, dt, world)

    -- Run children that are enabled.
    if phase.children then
        for i = 1, #phase.children do
            local child = phase.children[i]
            if child.position and child.position > 0 then
                if self.phaseStates[child.position] then
                    self:run(child, dt, world)
                end
            end
        end
    end
end

return pipeline