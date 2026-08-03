local types <const> = require("tecs.types")
local internal <const> = require("tecs.internal.types")
local phases <const> = require("tecs.internal.phases")
local fixedtracking <const> = require("tecs.internal.fixedtracking")
local zones <const> = require("tecs.internal.zones")
local EMPTY <const> = require("tecs.utils.pool").EMPTY

local table_new <const> = require("table.new") as function(integer, integer): {any}

-- `debug.traceback` returns a message that is not a string unchanged, which is
-- how the task runtime's private unwind sentinel survives a phase boundary.
-- Teal's definition types the message as a string, so it is bound here at the
-- type this file relies on.
local traceback <const> = debug.traceback as function(message: any, level?: number): any

local type World = types.World
local type System = types.System
local type Pipeline = types.Pipeline
local type Phase = types.Phase
local type SystemConfig = types.SystemConfig
local type FixedOverload = types.FixedOverload

-- Pipeline-owned fields are kept off the public SystemConfig contract.
local record RegisteredSystem is SystemConfig
    id: string
end

-- Flattened parallel arrays for a group of systems. Avoids per-system
-- hash reads in the hot loop.
local record FlatGroup
    runs: {System}
    runIfs: {function(number, World, string): boolean}
    ids: {string}
    names: {string}
    commitBefores: {boolean}
    commitAfters: {boolean}
    count: integer
end

-- Only enabled, nonempty phases enter an update span. Rebuilding this cache
-- when the pipeline changes removes empty-phase scans from every frame while
-- preserving one commit boundary per phase.
local record PhaseSpan
    groups: {FlatGroup}
    count: integer
end

local record ActiveState
    worlds: {internal.WorldImpl}
    systemZones: {integer}
    depth: integer
end

-- Internal pipeline factory.
local record pipeline
    new: function(fixedTimestep: number, fixedMaxSteps?: integer, fixedOverload?: FixedOverload): Pipeline
    recover: function(subject: Pipeline, world: World)
end

-- Concrete state behind the public Pipeline interface.
local record PipelineImpl is Pipeline
    dirty: boolean

    systems: {{RegisteredSystem}}

    phaseStates: {boolean}

    fixedTimestep: number

    fixedAccumulator: number

    -- Fixed steps run since the world was made. The clock anything advancing
    -- on the simulation rather than on frame time reads, which is why it counts
    -- steps rather than accumulating seconds: two runs fed the same steps read
    -- the same number however many frames either drew, and a whole number of
    -- steps stays exact in a float far longer than a sum of them would.
    fixedStepCount: integer

    fixedMaxSteps: integer

    fixedOverload: FixedOverload

    fixedTimeDropped: number

    fixedStepsDropped: integer

    -- The next total of `fixedStepsDropped` that warrants a log line, doubling
    -- from one. A machine dropping on every frame has one problem and does not
    -- need it named sixty times a second, but the first drop and every doubling
    -- past it are worth saying out loud, because a counter nobody reads is the
    -- same silence this replaces.
    nextDropReport: integer

    count: integer

    beforeFixedSpan: PhaseSpan
    fixedSpan: PhaseSpan
    afterFixedSpan: PhaseSpan

    -- Per-phase flat caches for run(phase). Group phases contain the
    -- concatenated flat lists of their children.
    phaseGroups: {integer: FlatGroup}

    -- Global registry of system names to phase positions.
    systemNameRegistry: {string: integer}

    anonymousSystemCount: integer

    activeState: ActiveState
    phaseFailure: function(any): any
end

-- The most fixed steps one update runs before the overload policy decides what
-- becomes of the rest. Bounds the work a single frame can be asked for, so a
-- stall does not turn into a death spiral where every frame owes more than the
-- last. Ten steps is a sixth of a second at 60Hz: long enough to absorb an
-- ordinary hitch, short enough that a frame recovering from one still draws.
local DEFAULT_MAX_STEPS <const> = 10

-- What happens to the catch-up that did not fit. Dropping it is the safe
-- default because it is the only one with a bound on it: `accumulate` is exact
-- but hands an overloaded machine an accumulator that grows every frame, and a
-- process that cannot draw cannot report what went wrong either. Dropping is a
-- lie about how much time passed, so it is counted and said out loud rather
-- than swallowed, and a simulation that would rather stall than lie asks for
-- `accumulate`.
local DEFAULT_OVERLOAD <const>: FixedOverload = "drop"

local DEFAULT_TIMESTEP <const> = 1 / 60

-- Empty flat group singleton for phases with no systems.
local EMPTY_GROUP <const>: FlatGroup = {
    runs = {},
    runIfs = {},
    ids = {},
    names = {},
    commitBefores = {},
    commitAfters = {},
    count = 0,
}

local EMPTY_SPAN <const>: PhaseSpan = {
    groups = {},
    count = 0,
}

-- The list of phases for each span of flatSystems.
local BEFORE_FIXED_PHASES <const> = {phases.Ingress, phases.First, phases.PreUpdate}
local FIXED_PHASES <const> = phases.FixedUpdateGroup.children
local AFTER_FIXED_PHASES <const> = {
    phases.Update,
    phases.PostUpdate,
    phases.RenderFirst,
    phases.PreRender,
    phases.Render,
    phases.PostRender,
    phases.RenderLast,
    phases.Last,
}

function pipeline.new(fixedTimestep: number, fixedMaxSteps?: integer, fixedOverload?: FixedOverload): Pipeline
    -- Validated here rather than on the first overloaded frame, which may be
    -- an hour in and on somebody else's machine.
    if fixedTimestep ~= nil and (fixedTimestep <= 0 or fixedTimestep ~= fixedTimestep) then
        error("tecs: timestep must be greater than zero, got " .. tostring(fixedTimestep), 2)
    end
    if fixedMaxSteps ~= nil and (fixedMaxSteps < 1 or fixedMaxSteps % 1 ~= 0) then
        error("tecs: fixedMaxSteps must be a positive integer, got " .. tostring(fixedMaxSteps), 2)
    end
    if fixedOverload ~= nil and fixedOverload ~= "drop" and fixedOverload ~= "accumulate" then
        error("tecs: fixedOverload must be 'drop' or 'accumulate', got " .. tostring(fixedOverload), 2)
    end

    local result: PipelineImpl = setmetatable(
        {
            dirty = true,
            systems = {},
            phaseStates = table_new(#phases.index, 0) as {boolean},
            fixedTimestep = fixedTimestep or DEFAULT_TIMESTEP,
            fixedAccumulator = 0,
            fixedStepCount = 0,
            fixedMaxSteps = fixedMaxSteps or DEFAULT_MAX_STEPS,
            fixedOverload = fixedOverload or DEFAULT_OVERLOAD,
            fixedTimeDropped = 0,
            fixedStepsDropped = 0,
            nextDropReport = 1,
            count = 0,
            beforeFixedSpan = EMPTY_SPAN,
            fixedSpan = EMPTY_SPAN,
            afterFixedSpan = EMPTY_SPAN,
            phaseGroups = {},
            systemNameRegistry = {},
            anonymousSystemCount = 0,
            activeState = {worlds = {}, systemZones = {}, depth = 0},
            phaseFailure = nil,
        },
        {__index = PipelineImpl}
    )

    result.phaseFailure = function(failure: any): any
        local state <const> = result.activeState
        local depth <const> = state.depth
        local world = state.worlds[depth]
        if world then
            world._runningSystem = false
            world._commitRequested = false
        end
        zones.leave(state.systemZones[depth] or 0)
        state.systemZones[depth] = nil
        -- A failure the task runtime raises to unwind a phase is a private
        -- sentinel rather than a message, and `traceback` returns it unchanged,
        -- so it survives instead of reaching a reader as a table address.
        return traceback(failure, 2)
    end

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
    if n < 2 then
        return systems
    end

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
        if first == second then
            return
        end
        local seen = edgeSeen[first]
        if not seen then
            seen = {}
            edgeSeen[first] = seen
        end
        if seen[second] then
            return
        end
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
                if dep then
                    addEdge(dep, config)
                end
            end
        end
        local before = config.before
        if before then
            for j = 1, #before do
                local target = systemNameMap[before[j]]
                if target then
                    addEdge(config, target)
                end
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
    if n == 0 then
        return EMPTY_GROUP
    end

    local runs: {System} = table_new(n, 0) as {System}
    local runIfs: {function(number, World, string): boolean} = table_new(n, 0) as {function(
        number, World, string
    ): boolean}
    local ids: {string} = table_new(n, 0) as {string}
    local names: {string} = table_new(n, 0) as {string}
    local commitBefores: {boolean} = table_new(n, 0) as {boolean}
    local commitAfters: {boolean} = table_new(n, 0) as {boolean}

    for i = 1, n do
        local config = configs[i]
        runs[i] = config.run
        runIfs[i] = config.runIf
        ids[i] = config.id
        names[i] = config.name
        commitBefores[i] = config.commitBefore or false
        commitAfters[i] = config.commitAfter or false
    end

    return {
        runs = runs,
        runIfs = runIfs,
        ids = ids,
        names = names,
        commitBefores = commitBefores,
        commitAfters = commitAfters,
        count = n,
    }
end

local function buildPhaseSpan(self: PipelineImpl, phaseList: {Phase}): PhaseSpan
    local groups: {FlatGroup} = table_new(#phaseList, 0) as {FlatGroup}
    local count = 0
    for i = 1, #phaseList do
        local phase = phaseList[i]
        if self.phaseStates[phase.position] then
            local group = self.phaseGroups[phase.position]
            if group ~= nil and group.count > 0 then
                count = count + 1
                groups[count] = group
            end
        end
    end
    return {groups = groups, count = count}
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

    self.beforeFixedSpan = buildPhaseSpan(self, BEFORE_FIXED_PHASES)
    self.fixedSpan = buildPhaseSpan(self, FIXED_PHASES)
    self.afterFixedSpan = buildPhaseSpan(self, AFTER_FIXED_PHASES)

    self.dirty = false
end

-- Execute one phase's systems. Each system runs inside its own jit.zone so
-- profiling can attribute samples. The caller owns the phase barrier.
--
-- A suspended world leaves this frame live on its coroutine. Each world owns
-- its pipeline, so the pipeline-owned stack isolates overlapping stalled
-- worlds without a coroutine lookup in every system dispatch.

local function runGroupBody(group: FlatGroup, dt: number, world: World, state: ActiveState)
    local n = group.count
    local runs = group.runs
    local runIfArr = group.runIfs
    local idArr = group.ids
    local nameArr = group.names
    local commitBefores = group.commitBefores
    local commitAfters = group.commitAfters
    local worldImpl = world as internal.WorldImpl

    for i = 1, n do
        if commitBefores[i] then
            worldImpl:_commit()
        end
        worldImpl._runningSystem = true
        local runIf = runIfArr[i]
        if not runIf or runIf(dt, world, nameArr[i]) then
            local zoneGeneration <const> = zones.enter(idArr[i])
            if zoneGeneration ~= 0 then
                state.systemZones[state.depth] = zoneGeneration
            end
            runs[i](dt, world)
            zones.leave(zoneGeneration)
            state.systemZones[state.depth] = nil
        end
        worldImpl._runningSystem = false
        if commitAfters[i] or worldImpl._commitRequested then
            worldImpl._commitRequested = false
            worldImpl:_commit()
        end
    end
end

-- Direct phase runs own one protected boundary. Scheduled world updates use
-- the reusable root's existing boundary and recover the same pipeline state
-- when that root reports failure. A stack preserves nested direct phase runs.
local function runGroup(self: PipelineImpl, group: FlatGroup, dt: number, world: World)
    if group.count == 0 then
        return
    end

    local state <const> = self.activeState
    local depth <const> = state.depth + 1
    state.depth = depth
    state.worlds[depth] = world as internal.WorldImpl
    runGroupBody(group, dt, world, state)
    state.worlds[depth] = nil
    state.systemZones[depth] = nil
    state.depth = depth - 1
end

function pipeline.recover(subject: Pipeline, world: World)
    local self = subject as PipelineImpl
    local state <const> = self.activeState
    for depth = state.depth, 1, -1 do
        local activeWorld = state.worlds[depth]
        if activeWorld ~= nil then
            activeWorld._runningSystem = false
            activeWorld._commitRequested = false
        end
        state.worlds[depth] = nil
        state.systemZones[depth] = nil
    end
    state.depth = 0
    local worldImpl = world as internal.WorldImpl
    worldImpl._runningSystem = false
    worldImpl._commitRequested = false
end

local function runProfiled(name: string, body: function(any, number, World), subject: any, dt: number, world: World)
    local zoneGeneration <const> = zones.enter(name)
    local ok, failure = xpcall(body, traceback, subject, dt, world) as (boolean, string)
    zones.leave(zoneGeneration)
    if not ok then
        error(failure, 0)
    end
end

-- Execute cached nonempty leaf phases in order, publishing once after each
-- phase. Systems within one phase batch together and intentionally do not
-- observe one another's structural changes unless configured with another
-- barrier.
local function runPhaseSpan(self: PipelineImpl, span: PhaseSpan, dt: number, world: World)
    local groups = span.groups
    local worldImpl = world as internal.WorldImpl
    for index = 1, span.count do
        runGroup(self, groups[index], dt, world)
        worldImpl:_commit()
    end
end

-- Abandon the steps that did not fit, and say by how much.
--
-- Whole steps only. The sub-step remainder is what the interpolation alpha is
-- computed from, so taking it as well would jolt every interpolated transform
-- on a frame that was already late, and it is not a step's worth of simulation
-- in any case.
local function dropCatchUp(self: PipelineImpl, fixedTimestep: number)
    local owed = self.fixedAccumulator
    local dropped = owed - (owed % fixedTimestep)
    if dropped <= 0 then
        return
    end

    self.fixedAccumulator = owed - dropped
    self.fixedTimeDropped = self.fixedTimeDropped + dropped
    -- Rounded rather than floored: `dropped` is a multiple of the timestep up
    -- to the error in one subtraction, and flooring that turns an exact three
    -- into a two.
    self.fixedStepsDropped = self.fixedStepsDropped + math.floor(dropped / fixedTimestep + 0.5)

    if self.fixedStepsDropped < self.nextDropReport then
        return
    end
    while self.nextDropReport <= self.fixedStepsDropped do
        self.nextDropReport = self.nextDropReport * 2
    end
    -- Required here rather than at the top. Logging is SDL's, reached through
    -- the FFI, and this module loads with the ECS: a tool that only wants
    -- worlds and queries would be made to find SDL to build one. Overload is a
    -- cold path by construction, so the lookup costs nothing that matters.
    --
    -- At error priority rather than warn, because warn is under where SDL
    -- leaves a custom category: a game losing simulated time has to hear about
    -- it without first knowing to turn the category up.
    local log <const> = require("tecs.log")
    log.get("tecs.pipeline"):error(
        "Fixed step fell behind: %d step(s) dropped this update, %d and %.3fs "
            .. "in total. The simulation is now that far behind wall time. "
            .. "Raise fixedMaxSteps, lower the timestep cost, or set "
            .. "fixedOverload to 'accumulate' to keep the time instead.",
        math.floor(dropped / fixedTimestep + 0.5),
        self.fixedStepsDropped,
        self.fixedTimeDropped
    )
end

-- Execute fixed timestep systems with death-spiral protection. System
-- barriers inside each group also separate fixed iterations.
local function runFixedLoop(self: PipelineImpl, dt: number, world: World)
    local fixedTimestep = self.fixedTimestep
    self.fixedAccumulator = self.fixedAccumulator + dt

    -- don't enter loop if insufficient time
    if self.fixedAccumulator < fixedTimestep then
        return
    end

    local hasWork = self.fixedSpan.count > 0
    local maxSteps = self.fixedMaxSteps
    local steps = 0

    repeat
        steps = steps + 1
        -- Counted whether or not any system runs, because it is a clock and not
        -- a measure of work: playback advances on a world with no fixed systems
        -- in it exactly as it does on one with many.
        self.fixedStepCount = self.fixedStepCount + 1
        fixedtracking.beginStep(world)
        if hasWork then
            runPhaseSpan(self, self.fixedSpan, fixedTimestep, world)
        end
        fixedtracking.finishStep(world)
        self.fixedAccumulator = self.fixedAccumulator - fixedTimestep
        if self.fixedAccumulator < fixedTimestep or steps >= maxSteps then
            break
        end
    until false

    -- Still a whole step in hand means the loop stopped on the limit rather
    -- than on the work running out, which is the only case a policy applies
    -- to. `accumulate` leaves it there for the frames after this one.
    if self.fixedAccumulator >= fixedTimestep and self.fixedOverload == "drop" then
        dropCatchUp(self, fixedTimestep)
    end
end

function PipelineImpl:update(dt: number, world: World)
    if self.dirty then
        recreatePipeline(self)
    end

    if not zones.active then
        runPhaseSpan(self, self.beforeFixedSpan, dt, world)
        runFixedLoop(self, dt, world)
        runPhaseSpan(self, self.afterFixedSpan, dt, world)
        return
    end

    runProfiled("beforeFixed", runPhaseSpan as function(any, number, World), self.beforeFixedSpan, dt, world)
    runProfiled("fixedLoop", runFixedLoop as function(any, number, World), self, dt, world)
    runProfiled("afterFixed", runPhaseSpan as function(any, number, World), self.afterFixedSpan, dt, world)
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

-- Recursive phase dispatch. Each leaf phase is one transaction.
local function runPhaseCommitted(self: PipelineImpl, phase: Phase, dt: number, world: World)
    if not phase.children then
        -- Leaf phase: use cached flat group, honoring the phase state like
        -- group dispatch does.
        if self.phaseStates[phase.position] then
            local group = self.phaseGroups[phase.position]
            if group then
                runGroup(self, group, dt, world)
                (world as internal.WorldImpl):_commit()
            end
        end
    else
        -- Group phase: run each child's flat cache in order
        for i = 1, #phase.children do
            local child = phase.children[i]
            if child.position and child.position > 0 and self.phaseStates[child.position] then
                if child.children then
                    runPhaseCommitted(self, child, dt, world)
                else
                    local group = self.phaseGroups[child.position]
                    if group then
                        runGroup(self, group, dt, world)
                        (world as internal.WorldImpl):_commit()
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

    local ok <const>, failure = xpcall(runPhaseCommitted, self.phaseFailure, self, phase, dt, world) as (boolean, any)
    if not ok then
        pipeline.recover(self, world)
        error(failure, 0)
    end
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
