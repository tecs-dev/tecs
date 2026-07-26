local types <const> = require("tecs.types")
local phases <const> = require("tecs.internal.phases")
local fixedtracking <const> = require("tecs.internal.fixedtracking")
local EMPTY <const> = require("tecs.utils.pool").EMPTY

local table_new <const> = require("table.new") as function(integer, integer): {any}

local type World = types.World
local type System = types.System
local type Pipeline = types.Pipeline
local type Phase = types.Phase
local type SystemConfig = types.SystemConfig

-- Pipeline-owned fields are kept off the public SystemConfig contract.
local record RegisteredSystem is SystemConfig
    id: string
end

-- `jit.zone` has no Teal type declarations; go through an opaque require.
local function loadUntyped(modName: string): any
    return require(modName)
end
local zone = loadUntyped("jit.zone") as function(?string): string

-- Flattened parallel arrays for a group of systems. Avoids per-system
-- hash reads in the hot loop.
local record FlatGroup
    runs: {System}
    runIfs: {function(number, World, string): boolean}
    ids: {string}
    names: {string}
    count: integer
end

-- Internal pipeline factory.
local record pipeline
    new: function(fixedTimestep: number): Pipeline
end

-- Concrete state behind the public Pipeline interface.
local record PipelineImpl is Pipeline
    dirty: boolean

    systems: {{RegisteredSystem}}

    phaseStates: {boolean}

    fixedTimestep: number

    fixedAccumulator: number

    count: integer

    beforeFixedGroup: FlatGroup
    fixedGroup: FlatGroup
    afterFixedGroup: FlatGroup

    -- Per-phase flat caches for run(phase). Group phases contain the
    -- concatenated flat lists of their children.
    phaseGroups: {integer: FlatGroup}

    -- Global registry of system names to phase positions.
    systemNameRegistry: {string: integer}

    anonymousSystemCount: integer
end

-- The maximum number of iterations for the fixed update loop.
-- This is used to prevent infinite loops, death spirals, and to provide predictable performance.
local MAX_ITERATIONS <const> = 10

-- Empty flat group singleton for phases with no systems.
local EMPTY_GROUP <const>: FlatGroup = {
    runs = {},
    runIfs = {},
    ids = {},
    names = {},
    count = 0,
}

-- The list of phases for each span of flatSystems.
local BEFORE_FIXED_PHASES <const> = {phases.First, phases.PreUpdate}
local FIXED_PHASES <const> = phases.FixedUpdateGroup.children
local AFTER_FIXED_PHASES <const> = {phases.Update, phases.PostUpdate, phases.RenderFirst,
    phases.PreRender, phases.Render, phases.PostRender, phases.RenderLast, phases.Last}

function pipeline.new(fixedTimestep: number): Pipeline
    local result: PipelineImpl = setmetatable({
        dirty = true,
        systems = {},
        phaseStates = table_new(#phases.index, 0) as {boolean},
        fixedTimestep = fixedTimestep or (1 / 60), -- Default to 60 FPS if not provided
        fixedAccumulator = 0,
        count = 0,
        beforeFixedGroup = EMPTY_GROUP,
        fixedGroup = EMPTY_GROUP,
        afterFixedGroup = EMPTY_GROUP,
        phaseGroups = {},
        systemNameRegistry = {},
        anonymousSystemCount = 0,
    }, { __index = PipelineImpl })

    -- Initialize each phase.
    for i = 1, #phases.index do
        result.systems[i] = {}
        result.phaseStates[i] = true
    end

    return result
end

-- Perform a stable topological sort on the systems based on their
-- before/after constraints. Keyed by config so two systems sharing one run
-- function stay distinct; unconstrained systems keep registration order.
local function topologicalSort(systems: {RegisteredSystem}): {RegisteredSystem}
    local n = #systems
    if n < 2 then return systems end

    local systemNameMap: {string: RegisteredSystem} = {}
    for i = 1, n do
        local name = systems[i].name
        if name then
            systemNameMap[name] = systems[i]
        end
    end

    -- Normalize before/after into forward edges (first runs before second),
    -- deduplicated so a redundant pair ("A before B" plus "B after A")
    -- counts once instead of reading as a cycle.
    local succs: {RegisteredSystem: {RegisteredSystem}} = {}
    local edgeSeen: {RegisteredSystem: {RegisteredSystem: boolean}} = {}
    local indegree: {RegisteredSystem: integer} = {}
    for i = 1, n do
        indegree[systems[i]] = 0
    end

    local function addEdge(first: RegisteredSystem, second: RegisteredSystem)
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

    -- Kahn's algorithm; each pass emits ready systems in registration
    -- order, independent of which side declared the constraint.
    local sorted: {RegisteredSystem} = table_new(n, 0) as {RegisteredSystem}
    local emitted: {RegisteredSystem: boolean} = {}
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

-- Build a FlatGroup from a list of registered systems.
local function buildFlatGroup(configs: {RegisteredSystem}): FlatGroup
    local n = #configs
    if n == 0 then return EMPTY_GROUP end

    local runs: {System} = table_new(n, 0) as {System}
    local runIfs: {function(number, World, string): boolean} = table_new(n, 0) as {function(number, World, string): boolean}
    local ids: {string} = table_new(n, 0) as {string}
    local names: {string} = table_new(n, 0) as {string}

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

-- Collect systems from a list of phases into one flat registered-system list.
local function collectPhaseSystems(
    self: PipelineImpl,
    phaseList: {Phase}
): {RegisteredSystem}
    local result: {RegisteredSystem} = {}
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

local function recreatePipeline(self: PipelineImpl)
    -- Topologically sort the systems in each phase. `phases.index` is shared
    -- across pipelines; positions registered only on another pipeline have no
    -- local systems array and are skipped.
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

    -- Build flat groups for the three update regions.
    self.beforeFixedGroup = buildFlatGroup(collectPhaseSystems(self, BEFORE_FIXED_PHASES))
    self.fixedGroup = buildFlatGroup(collectPhaseSystems(self, FIXED_PHASES))
    self.afterFixedGroup = buildFlatGroup(collectPhaseSystems(self, AFTER_FIXED_PHASES))

    -- Build per-phase flat caches for run(phase).
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

-- Execute a flat group of systems. Each system runs inside its own jit.zone
-- so profiling can attribute samples. This does not commit the world.
local function runGroup(group: FlatGroup, dt: number, world: World)
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

-- Execute fixed timestep systems with death-spiral protection. This does
-- not commit between iterations.
local function runFixedLoop(self: PipelineImpl, dt: number, world: World)
    local fixedTimestep = self.fixedTimestep
    self.fixedAccumulator = self.fixedAccumulator + dt

    -- don't enter loop if insufficient time
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

function PipelineImpl:removeSystem(systemName: string)
    -- Look up which phase this system is in
    local phasePosition = self.systemNameRegistry[systemName]
    if not phasePosition then
        error("System '" .. systemName .. "' not found in pipeline")
    end

    -- Remove from the phase's systems array
    local phaseSystems <const> = self.systems[phasePosition]
    if phaseSystems then
        for i = 1, #phaseSystems do
            if phaseSystems[i].name == systemName then
                table.remove(phaseSystems, i)
                self.count = self.count - 1
                self.dirty = true
                -- Remove from name registry
                self.systemNameRegistry[systemName] = nil
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

    -- Synthesize a name for unnamed systems so self-removing runIf predicates
    -- (e.g. runIf.after) always have a handle to pass back to removeSystem.
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
    local registered = config as RegisteredSystem
    registered.id = phaseName .. ":" .. name
    -- runIf left nil when absent; dispatch loops use a nil check instead of calling ALWAYS_RUN
    config.before = config.before or EMPTY as {string}
    config.after = config.after or EMPTY as {string}
    self.systems[phase.position][#self.systems[phase.position] + 1] = registered
    self.count = self.count + 1
    self.dirty = true
end

-- Recursive phase dispatch. Never commits.
local function runPhaseNoCommit(self: PipelineImpl, phase: Phase, dt: number, world: World)
    if not phase.children then
        -- Leaf phase: use cached flat group, honoring the phase state like
        -- group dispatch does.
        if self.phaseStates[phase.position] then
            local group = self.phaseGroups[phase.position]
            if group then
                runGroup(group, dt, world)
            end
        end
    else
        -- Group phase: run each child's flat cache in order
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

function PipelineImpl:run(phase: Phase, dt: number, world: World)
    if self.dirty then
        recreatePipeline(self)
    end

    runPhaseNoCommit(self, phase, dt, world)
end

function PipelineImpl:registerPhase(phase: Phase)
    -- Assign position if not already assigned
    if not phase.position then
        phases.index[#phases.index + 1] = phase
        phase.position = #phases.index
    end

    -- Initialize systems array and phase state for this phase
    if not self.systems[phase.position] then
        self.systems[phase.position] = {}
        self.phaseStates[phase.position] = true
    end

    self.dirty = true
end

return pipeline
