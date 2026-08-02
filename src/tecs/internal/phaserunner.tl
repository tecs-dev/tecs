-- Reusable coroutine runners for a phase of ordered systems.
--
-- A runner claims systems in order and calls them synchronously until one
-- actually waits. That continuation remains pinned to the runner, while the
-- pool leases another runner to continue scanning the phase. Consequently the
-- synchronous path pays one reusable coroutine boundary per phase, and the
-- pool grows only to the phase's maximum number of simultaneous waits plus the
-- runner that finishes the scan.

local taskruntime <const> = require("tecs.internal.taskruntime")

local record Runner
    pool: any
    task: taskruntime.Task<boolean>
    activeIndex: integer
    systemIndex: integer
    marker: any
end

local record PoolImpl
    scheduler: taskruntime.Scheduler
    idle: {Runner}
    active: {Runner}
    idleCount: integer
    activeCount: integer
    createdCount: integer
    peakActive: integer
    running: boolean
    systemCount: integer
    nextSystem: integer
    runAt: function(integer)
    start: function(self: PoolImpl, systemCount: integer, runAt: function(integer)): boolean
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
    runner.systemIndex = 0
    pool.idleCount = pool.idleCount + 1
    pool.idle[pool.idleCount] = runner
end

local function finish(pool: PoolImpl)
    pool.running = false
    pool.systemCount = 0
    pool.nextSystem = 1
    pool.runAt = nil
end

local function runLease(_scope: taskruntime.Scope, runner: Runner): boolean
    local pool <const> = runner.pool as PoolImpl
    while pool.nextSystem <= pool.systemCount do
        local index <const> = pool.nextSystem
        -- Claim before entering the system. If it suspends, another runner can
        -- continue with the next ordinal without running this system twice.
        pool.nextSystem = index + 1
        runner.systemIndex = index
        pool.runAt(index)
        runner.systemIndex = 0
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
        systemIndex = 0,
        marker = RUNNER_MARKER,
    } as Runner
    pool.createdCount = pool.createdCount + 1
    addActive(pool, runner)
    runner.task = pool.scheduler:spawnReusableImmediate(
        function(scope: taskruntime.Scope): boolean return runLease(scope, runner) end, runner
    )
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
    cancelAndDrain(pool, "another system in the phase failed")
    finish(pool)
    error(reason, 3)
end

function PoolImpl:start(systemCount: integer, runAt: function(integer)): boolean
    if self.running then
        error("tecs: cannot start a phase while its previous run is pending", 2)
    end
    if type(systemCount) ~= "number" or systemCount < 0 or systemCount % 1 ~= 0 then
        error("tecs: phase runner needs a non-negative system count", 2)
    end
    if type(runAt) ~= "function" then
        error("tecs: phase runner needs a system dispatcher", 2)
    end

    self.running = true
    self.systemCount = systemCount
    self.nextSystem = 1
    self.runAt = runAt

    while self.nextSystem <= self.systemCount do
        local runner <const> = acquire(self)
        if runner.task.status == "failed" then
            fail(self, runner.task.error)
        elseif runner.task.status ~= "pending" then
            -- A synchronous runner consumes the entire unclaimed tail.
            releaseAt(self, runner.activeIndex)
        end
    end

    if self.activeCount == 0 then
        finish(self)
        return true
    end
    return false
end

function PoolImpl:poll(): boolean
    if not self.running then
        return true
    end

    self.scheduler:step()
    local index = 1
    while index <= self.activeCount do
        local runner <const> = self.active[index]
        local status <const> = runner.task.status
        if status == "pending" then
            index = index + 1
        elseif status == "failed" then
            fail(self, runner.task.error)
        else
            releaseAt(self, index)
        end
    end

    if self.activeCount == 0 then
        finish(self)
        return true
    end
    return false
end

function PoolImpl:cancel(reason?: string)
    if not self.running then
        return
    end
    if reason ~= nil and reason == "" then
        error("tecs: phase cancellation reason cannot be empty", 2)
    end
    cancelAndDrain(self, reason or "phase canceled")
    finish(self)
end

local record phaserunner
    type Pool = PoolImpl

    new: function(): PoolImpl
    currentSystem: function(): integer
end

function phaserunner.new(): PoolImpl
    return setmetatable(
        {
            scheduler = taskruntime.newScheduler(),
            idle = {},
            active = {},
            idleCount = 0,
            activeCount = 0,
            createdCount = 0,
            peakActive = 0,
            running = false,
            systemCount = 0,
            nextSystem = 1,
            runAt = nil,
        } as PoolImpl,
        POOL_MT
    )
end

-- Returns the stable one-based phase ordinal owned by this continuation.
-- Zero means the caller is not currently inside a pooled phase system.
function phaserunner.currentSystem(): integer
    local context <const> = taskruntime.context()
    if context == nil or (context as {string: any}).marker ~= RUNNER_MARKER then
        return 0
    end
    return (context as Runner).systemIndex
end

return phaserunner
