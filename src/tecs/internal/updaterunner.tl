-- One primary coroutine for an update, with pooled spill runners on waits.
--
-- The primary runner crosses the coroutine boundary once, then scans systems
-- and phase barriers for the whole update. If a system waits, that continuation
-- stays pinned and a pooled runner continues the current phase. The runner that
-- finishes scanning waits at the phase barrier, commits after every pinned
-- continuation settles, and becomes the primary runner for the remaining
-- phases.

local taskruntime <const> = require("tecs.internal.taskruntime")

local record Runner
    pool: any
    task: taskruntime.Task<boolean>
    activeIndex: integer
    phaseIndex: integer
    systemIndex: integer
    waitingBarrier: boolean
    marker: any
end

local record PoolImpl
    scheduler: taskruntime.Scheduler
    barrier: taskruntime.Gate
    idle: {Runner}
    active: {Runner}
    idleCount: integer
    activeCount: integer
    createdCount: integer
    peakActive: integer
    running: boolean
    phaseCount: integer
    phaseIndex: integer
    nextSystem: integer
    systemCounts: {integer}
    runSystem: function(integer, integer)
    commitPhase: function(integer)
    primary: Runner
    coordinator: Runner
    start: function(
        self: PoolImpl,
        phaseCount: integer,
        systemCounts: {integer},
        runSystem: function(integer, integer),
        commitPhase: function(integer)
    ): boolean
    poll: function(self: PoolImpl): boolean
    cancel: function(self: PoolImpl, reason?: string)
end

local POOL_MT <const>: metatable<PoolImpl> = {__index = PoolImpl}
local RUNNER_MARKER <const> = {}

local function addActive(pool: PoolImpl, runner: Runner)
    pool.activeCount = pool.activeCount + 1
    runner.activeIndex = pool.activeCount
    pool.active[pool.activeCount] = runner
    if pool.activeCount > pool.peakActive then
        pool.peakActive = pool.activeCount
    end
end

local function releaseAt(pool: PoolImpl, index: integer)
    local runner <const> = pool.active[index]
    local lastIndex <const> = pool.activeCount
    local last <const> = pool.active[lastIndex]
    pool.active[lastIndex] = nil
    pool.activeCount = lastIndex - 1
    if index < lastIndex then
        pool.active[index] = last
        last.activeIndex = index
    end

    runner.activeIndex = 0
    runner.waitingBarrier = false
    if runner == pool.primary then
        return
    end
    pool.idleCount = pool.idleCount + 1
    pool.idle[pool.idleCount] = runner
end

local function finish(pool: PoolImpl)
    pool.running = false
    pool.coordinator = nil
end

local function runLease(_scope: taskruntime.Scope, runner: Runner): boolean
    local pool <const> = runner.pool as PoolImpl
    local phaseCount <const> = pool.phaseCount
    local systemCounts <const> = pool.systemCounts
    local runSystem <const> = pool.runSystem
    local commitPhase <const> = pool.commitPhase

    -- Keep the system scan as its own inner loop. LuaJIT records that hot loop
    -- independently; flattening both cursors makes it blacklist the reusable
    -- runner entry and leaves the complete scan in the interpreter.
    while pool.phaseIndex <= phaseCount do
        local phaseIndex <const> = pool.phaseIndex
        local systemCount <const> = systemCounts[phaseIndex]
        if runner.phaseIndex ~= phaseIndex then
            runner.phaseIndex = phaseIndex
        end

        while pool.nextSystem <= systemCount do
            local systemIndex <const> = pool.nextSystem
            -- Claim before entering the system. A spill runner therefore starts
            -- at the next system when this continuation suspends.
            pool.nextSystem = systemIndex + 1
            runner.systemIndex = systemIndex
            runSystem(phaseIndex, systemIndex)
            runner.systemIndex = 0
        end

        if pool.activeCount == 1 then
            -- The primary fast path crosses no internal barrier and retains
            -- the same coroutine throughout the update.
            commitPhase(phaseIndex)
            pool.phaseIndex = phaseIndex + 1
            pool.nextSystem = 1
        elseif pool.coordinator ~= nil then
            -- Another runner finished the scan while this continuation was
            -- parked. Its only remaining job is to settle at the barrier.
            return true
        else
            pool.coordinator = runner
            runner.waitingBarrier = true
            pool.barrier:wait()
            runner.waitingBarrier = false
            pool.coordinator = nil
            commitPhase(phaseIndex)
            pool.phaseIndex = phaseIndex + 1
            pool.nextSystem = 1
        end
    end

    return true
end

local function acquire(pool: PoolImpl): Runner
    local runner: Runner
    if pool.idleCount > 0 then
        runner = pool.idle[pool.idleCount]
        pool.idle[pool.idleCount] = nil
        pool.idleCount = pool.idleCount - 1
        addActive(pool, runner)
        pool.scheduler:restartImmediate(runner.task)
        return runner
    end

    runner = {
        pool = pool,
        task = nil,
        activeIndex = 0,
        phaseIndex = 0,
        systemIndex = 0,
        waitingBarrier = false,
        marker = RUNNER_MARKER,
    } as Runner
    pool.createdCount = pool.createdCount + 1
    addActive(pool, runner)
    runner.task = pool.scheduler:spawnReusableImmediate(
        function(scope: taskruntime.Scope): boolean return runLease(scope, runner) end, runner
    )
    return runner
end

-- The no-wait path owns one distinguished runner. It avoids the generic
-- active/idle bookkeeping entirely; only a suspension publishes it into the
-- active set and starts acquiring spill runners.
local function startPrimary(pool: PoolImpl): Runner
    local runner = pool.primary
    if runner == nil then
        runner = {
            pool = pool,
            task = nil,
            activeIndex = 1,
            phaseIndex = 0,
            systemIndex = 0,
            waitingBarrier = false,
            marker = RUNNER_MARKER,
        } as Runner
        pool.primary = runner
        pool.createdCount = pool.createdCount + 1
        pool.peakActive = math.max(pool.peakActive, 1)
        pool.activeCount = 1
        runner.task = pool.scheduler:spawnReusableImmediate(
            function(scope: taskruntime.Scope): boolean return runLease(scope, runner) end, runner
        )
    else
        runner.activeIndex = 1
        pool.activeCount = 1
        pool.scheduler:restartImmediate(runner.task)
    end
    return runner
end

local function cancelAndDrain(pool: PoolImpl, reason: string)
    for index = 1, pool.activeCount do
        local runner <const> = pool.active[index]
        if runner.task.status == "pending" then
            runner.task:cancel(reason)
        end
    end

    while pool.activeCount > 0 do
        pool.scheduler:step()
        local index = 1
        while index <= pool.activeCount do
            if pool.active[index].task.status == "pending" then
                index = index + 1
            else
                releaseAt(pool, index)
            end
        end
    end
end

local function fail(pool: PoolImpl, reason: string)
    cancelAndDrain(pool, "another system in the update failed")
    finish(pool)
    error(reason, 3)
end

local function reap(pool: PoolImpl)
    local index = 1
    while index <= pool.activeCount do
        local runner <const> = pool.active[index]
        local status <const> = runner.task.status
        if status == "pending" then
            index = index + 1
        elseif status == "failed" then
            fail(pool, runner.task.error)
        elseif status == "canceled" then
            fail(pool, runner.task.error or "update runner was canceled")
        else
            releaseAt(pool, index)
        end
    end
end

-- Starts spill runners until one reaches the current phase barrier. Every
-- runner that returns pending before then is necessarily blocked inside a
-- claimed system.
local function scan(pool: PoolImpl)
    while pool.phaseIndex <= pool.phaseCount and pool.coordinator == nil do
        local runner <const> = acquire(pool)
        local status <const> = runner.task.status
        if status == "failed" then
            fail(pool, runner.task.error)
        elseif status == "canceled" then
            fail(pool, runner.task.error or "update runner was canceled")
        elseif status ~= "pending" then
            releaseAt(pool, runner.activeIndex)
        end
    end
end

local function completeIfDone(pool: PoolImpl): boolean
    if pool.phaseIndex > pool.phaseCount and pool.activeCount == 0 then
        finish(pool)
        return true
    end
    return false
end

function PoolImpl:start(
    phaseCount: integer, systemCounts: {integer}, runSystem: function(integer, integer), commitPhase: function(integer)
): boolean
    if self.running then
        error("tecs: cannot start an update while its previous run is pending", 2)
    end

    self.running = true
    self.phaseCount = phaseCount
    self.phaseIndex = 1
    self.nextSystem = 1
    self.systemCounts = systemCounts
    self.runSystem = runSystem
    self.commitPhase = commitPhase
    self.coordinator = nil

    local primary <const> = startPrimary(self)
    local status <const> = primary.task.status
    if status == "ready" then
        primary.activeIndex = 0
        self.activeCount = 0
        finish(self)
        return true
    end

    self.active[1] = primary
    if status == "failed" then
        fail(self, primary.task.error)
    elseif status == "canceled" then
        fail(self, primary.task.error or "update runner was canceled")
    end

    scan(self)
    return completeIfDone(self)
end

function PoolImpl:poll(): boolean
    if not self.running then
        return true
    end

    self.scheduler:step()
    reap(self)

    while self.running do
        local coordinator <const> = self.coordinator
        if coordinator ~= nil and coordinator.waitingBarrier and self.activeCount == 1 then
            self.barrier:complete(true)
            self.scheduler:step()
            reap(self)
        elseif self.phaseIndex <= self.phaseCount and coordinator == nil then
            scan(self)
        else
            break
        end
    end

    return completeIfDone(self)
end

function PoolImpl:cancel(reason?: string)
    if not self.running then
        return
    end
    if reason ~= nil and reason == "" then
        error("tecs: update cancellation reason cannot be empty", 2)
    end
    cancelAndDrain(self, reason or "update canceled")
    finish(self)
end

local record updaterunner
    type Pool = PoolImpl

    new: function(): PoolImpl
    currentPhase: function(): integer
    currentSystem: function(): integer
end

function updaterunner.new(): PoolImpl
    return setmetatable(
        {
            scheduler = taskruntime.newScheduler(),
            barrier = taskruntime.newGate(),
            idle = {},
            active = {},
            idleCount = 0,
            activeCount = 0,
            createdCount = 0,
            peakActive = 0,
            running = false,
            phaseCount = 0,
            phaseIndex = 1,
            nextSystem = 1,
            systemCounts = nil,
            runSystem = nil,
            commitPhase = nil,
            primary = nil,
            coordinator = nil,
        } as PoolImpl,
        POOL_MT
    )
end

local function currentRunner(): Runner
    local context <const> = taskruntime.context()
    if context == nil or (context as {string: any}).marker ~= RUNNER_MARKER then
        return nil
    end
    return context as Runner
end

function updaterunner.currentPhase(): integer
    local runner <const> = currentRunner()
    if runner == nil then
        return 0
    end
    return runner.phaseIndex
end

function updaterunner.currentSystem(): integer
    local runner <const> = currentRunner()
    if runner == nil then
        return 0
    end
    return runner.systemIndex
end

return updaterunner
