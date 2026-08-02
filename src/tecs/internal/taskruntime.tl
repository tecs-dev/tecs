-- Coroutine scheduler for resumable systems and structured internal work.
--
-- This stays internal because suspension is an implementation detail of direct
-- engine calls. Games register ordinary systems and do not manage tasks.

local type Completion = require("tecs.internal.completion")
local zones <const> = require("tecs.internal.zones")

local record TaskImpl<T>
    status: string
    value: T
    error: string
    thread: thread
    scheduler: any
    scope: any
    ownerScope: any
    ownerIndex: integer
    waiter: TaskImpl<any>
    waitingOn: any
    waitKind: string
    resumeTag: any
    resumeValue: any
    resumeReason: string
    started: boolean
    queued: boolean
    cancelRequested: boolean
    cancelReason: string
    reusable: boolean
    dead: boolean
    context: any
    zoneNames: {string}
    zoneCount: integer
    zoneGeneration: integer
    _onSettle: function(TaskImpl<any>)
    join: function(self: TaskImpl<T>): T
    cancel: function(self: TaskImpl<T>, reason?: string)
end

local record ScopeImpl
    scheduler: any
    owner: TaskImpl<any>
    active: boolean
    children: {TaskImpl<any>}
    childCount: integer
    spawn: function<T>(self: ScopeImpl, body: function(ScopeImpl): T...): TaskImpl<T>
end

local record SchedulerImpl
    current: TaskImpl<any>
    ready: {TaskImpl<any>}
    next: {TaskImpl<any>}
    readyCount: integer
    nextCount: integer
    stepping: boolean
    spawn: function<T>(self: SchedulerImpl, body: function(ScopeImpl): T...): TaskImpl<T>
    spawnImmediate: function<T>(self: SchedulerImpl, body: function(ScopeImpl): T...): TaskImpl<T>
    spawnReusableImmediate: function<T>(
        self: SchedulerImpl, body: function(ScopeImpl): T..., context?: any
    ): TaskImpl<T>
    restartImmediate: function<T>(self: SchedulerImpl, task: TaskImpl<T>): TaskImpl<T>
    step: function(self: SchedulerImpl): integer
end

local record GateImpl
    ready: boolean
    value: any
    reason: string
    waiter: TaskImpl<any>
    cancelWait: function()
    wait: function(self: GateImpl): any, string
    complete: function(self: GateImpl, value: any)
    fail: function(self: GateImpl, reason: string)
    reset: function(self: GateImpl)
end

local TASK_MT <const> = {__index = TaskImpl}
local SCOPE_MT <const>: metatable<ScopeImpl> = {__index = ScopeImpl}
local SCHEDULER_MT <const>: metatable<SchedulerImpl> = {__index = SchedulerImpl}
local GATE_MT <const>: metatable<GateImpl> = {__index = GateImpl}

-- Coroutine yields are a private protocol. A task that yields anything else
-- has bypassed the runtime and fails instead of becoming permanently parked.
local WAIT <const> = {}
local YIELD <const> = {}
local RESUME <const> = {}
local CANCEL <const> = {}
local CYCLE <const> = {}

local enum WaitMode
    "cooperative"
    "blocking"
    "forbidden"
end

local activeScheduler: SchedulerImpl = nil

local function currentTask(): TaskImpl<any>
    local scheduler <const> = activeScheduler
    if scheduler == nil or scheduler.current == nil then
        error("tecs: suspending operation needs a task", 3)
    end
    return scheduler.current
end

local function checkCanSuspend(task: TaskImpl<any>, operation: string)
    local scope <const> = task.scope as ScopeImpl
    local barrier <const> = (scope as {string: any}).barrier
    if barrier ~= nil then
        error(("tecs: %s cannot suspend while %s is active"):format(operation, barrier), 3)
    end
end

local function enqueue(scheduler: SchedulerImpl, task: TaskImpl<any>)
    if task.status ~= "pending" or task.queued then
        return
    end
    scheduler.nextCount = scheduler.nextCount + 1
    scheduler.next[scheduler.nextCount] = task
    task.queued = true
end

local function removeFromOwner(task: TaskImpl<any>)
    local owner = task.ownerScope as ScopeImpl
    if owner == nil then
        return
    end
    local index <const> = task.ownerIndex
    local lastIndex <const> = owner.childCount
    local last = owner.children[lastIndex]
    owner.children[lastIndex] = nil
    owner.childCount = lastIndex - 1
    if index < lastIndex then
        owner.children[index] = last
        last.ownerIndex = index
    end
    task.ownerScope = nil
    task.ownerIndex = 0
end

local function settle(task: TaskImpl<any>, status: string, value: any, reason?: string): string
    if task.status ~= "pending" then
        return
    end
    task.status = status
    task.value = value
    task.error = reason
    task.waitingOn = nil
    task.waitKind = nil
    for index = 1, task.zoneCount do
        task.zoneNames[index] = nil
    end
    task.zoneCount = 0
    task.zoneGeneration = 0
    if task.ownerScope ~= nil then
        removeFromOwner(task)
    end

    local waiter = task.waiter
    task.waiter = nil
    if waiter ~= nil then
        waiter.waitingOn = nil
        waiter.waitKind = nil
        waiter.resumeTag = RESUME
        enqueue(task.scheduler as SchedulerImpl, waiter)
    end

    local observer = task._onSettle
    task._onSettle = nil
    if observer ~= nil then
        local ok <const>, failure = xpcall(observer, debug.traceback, task) as (boolean, string)
        if not ok then
            return failure
        end
    end
    return nil
end

local function caught(reason: any): any
    if reason == CANCEL then
        return reason
    end
    return debug.traceback(tostring(reason), 2)
end

local function park(): any, string
    local tag <const>, value, reason = coroutine.yield(WAIT)
    if tag == CANCEL then
        error(CANCEL, 0)
    end
    return value, reason as string
end

local function awaitSettlement(task: TaskImpl<any>)
    if task.status ~= "pending" then
        return
    end
    local waiter <const> = currentTask()
    if task.waiter ~= nil and task.waiter ~= waiter then
        error("tecs: a pending task can have only one joiner", 3)
    end
    task.waiter = waiter
    waiter.waitingOn = task
    waiter.waitKind = "task"
    park()
end

local function cancelChildren(scope: ScopeImpl)
    scope.active = false
    while scope.childCount > 0 do
        local child <const> = scope.children[scope.childCount]
        if child.status == "pending" then
            child:cancel("owner scope ended")
            if child.status == "pending" then
                awaitSettlement(child)
            end
        else
            removeFromOwner(child)
        end
    end
end

local function runBody(task: TaskImpl<any>, body: function(ScopeImpl): any...): any
    local ok <const>, result = xpcall(body, caught, task.scope as ScopeImpl)
    cancelChildren(task.scope as ScopeImpl)
    -- Cancellation is sticky. User code may use pcall for ordinary cleanup,
    -- but catching the private unwind signal cannot turn a canceled task into
    -- a successful one.
    if task.cancelRequested then
        error(CANCEL, 0)
    end
    if not ok then
        error(result, 0)
    end
    return result
end

local function runReusable(task: TaskImpl<any>, body: function(ScopeImpl): any...)
    local scope <const> = task.scope as ScopeImpl
    while true do
        -- A reusable root already owns the protected cycle boundary. Calling
        -- `runBody` through another pcall doubled that boundary on every frame.
        local ok <const>, result = xpcall(body, caught, scope) as (boolean, any)
        if scope.childCount == 0 then
            scope.active = false
        else
            cancelChildren(scope)
        end
        if task.cancelRequested or result == CANCEL then
            coroutine.yield(CYCLE, "canceled", nil, task.cancelReason or "task canceled")
        elseif ok then
            coroutine.yield(CYCLE, "ready", result)
        else
            coroutine.yield(CYCLE, "failed", nil, tostring(result))
        end
    end
end

local function newTask<T>(
    scheduler: SchedulerImpl, owner: ScopeImpl, body: function(ScopeImpl): T..., reusable?: boolean, context?: any
): TaskImpl<T>
    local scope <const> = setmetatable(
        {
            scheduler = scheduler,
            owner = nil,
            active = true,
            children = {},
            childCount = 0,
        } as ScopeImpl,
        SCOPE_MT
    )
    local task = setmetatable(
        {
            status = "pending",
            value = nil,
            error = nil,
            thread = nil,
            scheduler = scheduler,
            scope = scope,
            ownerScope = owner,
            ownerIndex = 0,
            waiter = nil,
            waitingOn = nil,
            waitKind = nil,
            resumeTag = RESUME,
            resumeValue = nil,
            resumeReason = nil,
            started = false,
            queued = false,
            cancelRequested = false,
            cancelReason = nil,
            reusable = reusable == true,
            dead = false,
            context = context,
            zoneNames = nil,
            zoneCount = 0,
            zoneGeneration = 0,
            _onSettle = nil,
        } as TaskImpl<T>,
        TASK_MT
    )
    scope.owner = task as TaskImpl<any>
    if reusable then
        task.thread = coroutine.create(function()
            runReusable(task as TaskImpl<any>, body as function(ScopeImpl): any...)
        end)
    else
        task.thread = coroutine.create(function(): any
            return runBody(task as TaskImpl<any>, body as function(ScopeImpl): any...)
        end)
    end

    if owner ~= nil then
        if not owner.active then
            error("tecs: task scope is no longer active", 3)
        end
        owner.childCount = owner.childCount + 1
        owner.children[owner.childCount] = task as TaskImpl<any>
        task.ownerIndex = owner.childCount
    end
    enqueue(scheduler, task as TaskImpl<any>)
    return task
end

function ScopeImpl:spawn<T>(body: function(ScopeImpl): T...): TaskImpl<T>
    if not self.active then
        error("tecs: task scope is no longer active", 2)
    end
    if type(body) ~= "function" then
        error("tecs: spawn needs a function", 2)
    end
    return newTask(self.scheduler as SchedulerImpl, self, body)
end

function SchedulerImpl:spawn<T>(body: function(ScopeImpl): T...): TaskImpl<T>
    if self.stepping then
        error("tecs: scheduler roots cannot be spawned from a task", 2)
    end
    if type(body) ~= "function" then
        error("tecs: spawn needs a function", 2)
    end
    return newTask(self, nil, body)
end

local function resumeTask(scheduler: SchedulerImpl, task: TaskImpl<any>): string
    local profiling = zones.active
    local zoneBase = 0
    local zoneGeneration = 0
    if profiling then
        zoneBase = #zones.stack
        zoneGeneration = zones.generation
    end
    local parkedZones <const> = task.zoneCount
    if parkedZones > 0 then
        if profiling and task.zoneGeneration == zoneGeneration then
            for index = 1, task.zoneCount do
                zones.push(task.zoneNames[index])
            end
        end
        for index = 1, task.zoneCount do
            task.zoneNames[index] = nil
        end
        task.zoneCount = 0
        task.zoneGeneration = 0
    end

    scheduler.current = task
    activeScheduler = scheduler

    local ok: boolean
    local first: any
    local second: any
    local third: any
    local fourth: any
    if not task.started then
        task.started = true
        ok, first, second, third, fourth = coroutine.resume(task.thread)
    else
        local tag <const> = task.resumeTag
        local value <const> = task.resumeValue
        local reason <const> = task.resumeReason
        if tag ~= RESUME then
            task.resumeTag = RESUME
        end
        if value ~= nil then
            task.resumeValue = nil
        end
        if reason ~= nil then
            task.resumeReason = nil
        end
        if value == nil and reason == nil then
            ok, first, second, third, fourth = coroutine.resume(task.thread, tag)
        else
            ok, first, second, third, fourth = coroutine.resume(task.thread, tag, value, reason)
        end
    end

    activeScheduler = nil
    scheduler.current = nil

    profiling = zones.active
    if profiling then
        local currentGeneration <const> = zones.generation
        if currentGeneration ~= zoneGeneration then
            zoneBase = 0
        end
        local count <const> = #zones.stack - zoneBase
        if count > 0 then
            local names = task.zoneNames
            if names == nil then
                names = {}
                task.zoneNames = names
            end
            for index = 1, count do
                names[index] = zones.stack[zoneBase + index]
            end
            for _ = 1, count do
                zones.push()
            end
            task.zoneCount = count
            task.zoneGeneration = currentGeneration
        end
    end

    if not ok then
        task.dead = true
        if first == CANCEL then
            return settle(task, "canceled", nil, task.cancelReason or "task canceled")
        else
            return settle(task, "failed", nil, tostring(first))
        end
    elseif first == CYCLE and task.reusable then
        return settle(task, second as string, third, fourth as string)
    elseif coroutine.status(task.thread) == "dead" then
        task.dead = true
        return settle(task, "ready", first)
    elseif first == YIELD then
        enqueue(scheduler, task)
    elseif first ~= WAIT then
        return settle(task, "failed", nil, "tecs: task yielded outside the task runtime")
    end
    return nil
end

function SchedulerImpl:spawnImmediate<T>(body: function(ScopeImpl): T...): TaskImpl<T>
    if self.stepping or activeScheduler ~= nil then
        error("tecs: an immediate root cannot start from another task", 2)
    end
    if type(body) ~= "function" then
        error("tecs: spawnImmediate needs a function", 2)
    end

    local task <const> = newTask(self, nil, body)
    -- `newTask` appended this root. Remove that one slot before running it so a
    -- synchronous completion never enters either scheduler queue.
    self.next[self.nextCount] = nil
    self.nextCount = self.nextCount - 1
    task.queued = false

    self.stepping = true
    local failure <const> = resumeTask(self, task as TaskImpl<any>)
    self.stepping = false
    if failure ~= nil then
        error(failure, 0)
    end
    return task
end

function SchedulerImpl:spawnReusableImmediate<T>(body: function(ScopeImpl): T..., context?: any): TaskImpl<T>
    if self.stepping or activeScheduler ~= nil then
        error("tecs: an immediate reusable root cannot start from another task", 2)
    end
    if type(body) ~= "function" then
        error("tecs: spawnReusableImmediate needs a function", 2)
    end

    local task <const> = newTask(self, nil, body, true, context)
    self.next[self.nextCount] = nil
    self.nextCount = self.nextCount - 1
    task.queued = false

    self.stepping = true
    local failure <const> = resumeTask(self, task as TaskImpl<any>)
    self.stepping = false
    if failure ~= nil then
        error(failure, 0)
    end
    return task
end

function SchedulerImpl:restartImmediate<T>(task: TaskImpl<T>): TaskImpl<T>
    if self.stepping or activeScheduler ~= nil then
        error("tecs: an immediate reusable root cannot start from another task", 2)
    end
    if task.scheduler ~= self or not task.reusable then
        error("tecs: restartImmediate needs a reusable root from this scheduler", 2)
    end
    if task.status == "pending" then
        error("tecs: cannot restart a pending reusable root", 2)
    end
    if task.dead then
        error("tecs: cannot restart a dead reusable root", 2)
    end

    local scope <const> = task.scope as ScopeImpl
    scope.active = true
    task.status = "pending"
    task.value = nil
    task.error = nil
    task.cancelRequested = false
    task.cancelReason = nil

    self.stepping = true
    local failure <const> = resumeTask(self, task as TaskImpl<any>)
    self.stepping = false
    if failure ~= nil then
        error(failure, 0)
    end
    return task
end

function SchedulerImpl:step(): integer
    if self.stepping then
        error("tecs: task scheduler is not reentrant", 2)
    end
    if activeScheduler ~= nil then
        error("tecs: a task cannot drive another task scheduler", 2)
    end
    self.stepping = true

    local ready <const> = self.ready
    self.ready = self.next
    self.next = ready
    self.readyCount = self.nextCount
    self.nextCount = 0

    local turns <const> = self.readyCount
    local firstFailure: string
    for index = 1, turns do
        local task <const> = self.ready[index]
        self.ready[index] = nil
        task.queued = false
        if task.status == "pending" then
            local failure <const> = resumeTask(self, task)
            if firstFailure == nil then
                firstFailure = failure
            end
        end
    end
    self.readyCount = 0
    self.stepping = false
    if firstFailure ~= nil then
        error(firstFailure, 0)
    end
    return turns
end

function TaskImpl:join(): T
    local caller <const> = currentTask()
    checkCanSuspend(caller, "Task:join")
    if caller == self as TaskImpl<any> then
        error("tecs: a task cannot join itself", 2)
    end
    awaitSettlement(self as TaskImpl<any>)
    if self.status == "ready" then
        return self.value
    end
    if self.status == "canceled" then
        error("tecs: joined task was canceled: " .. self.error, 2)
    end
    error(self.error, 2)
end

function TaskImpl:cancel(reason?: string)
    if self.status ~= "pending" or self.cancelRequested then
        return
    end
    if reason ~= nil and reason == "" then
        error("tecs: cancellation reason cannot be empty", 2)
    end
    self.cancelRequested = true
    self.cancelReason = reason or "task canceled"

    local scheduler <const> = self.scheduler as SchedulerImpl
    if not self.started then
        local failure <const> = settle(self as TaskImpl<any>, "canceled", nil, self.cancelReason)
        if failure ~= nil then
            error(failure, 0)
        end
        return
    end
    if scheduler.current == self as TaskImpl<any> then
        error(CANCEL, 0)
    end

    local cancelWait: function()
    if self.waitKind == "task" then
        local awaited <const> = self.waitingOn as TaskImpl<any>
        if awaited ~= nil and awaited.waiter == self as TaskImpl<any> then
            awaited.waiter = nil
        end
    elseif self.waitKind == "gate" then
        local gate <const> = self.waitingOn as GateImpl
        if gate ~= nil and gate.waiter == self as TaskImpl<any> then
            gate.waiter = nil
            cancelWait = gate.cancelWait
            gate.cancelWait = nil
        end
    end
    self.waitingOn = nil
    self.waitKind = nil
    self.resumeTag = CANCEL
    self.resumeValue = nil
    self.resumeReason = nil
    enqueue(scheduler, self as TaskImpl<any>)
    if cancelWait ~= nil then
        local ok <const>, failure = xpcall(cancelWait, debug.traceback) as (boolean, string)
        if not ok then
            error(failure, 0)
        end
    end
end

function GateImpl:wait(): any, string
    local task <const> = currentTask()
    checkCanSuspend(task, "I/O wait")
    if self.ready then
        local value <const> = self.value
        local reason <const> = self.reason
        self.ready = false
        self.value = nil
        self.reason = nil
        return value, reason
    end
    if self.waiter ~= nil then
        error("tecs: readiness gate already has a waiter", 2)
    end
    self.waiter = task
    task.waitingOn = self
    task.waitKind = "gate"
    return park()
end

local function finishGate(gate: GateImpl, value: any, reason?: string)
    if gate.ready then
        error("tecs: readiness gate already contains a completion", 3)
    end
    gate.cancelWait = nil
    local waiter = gate.waiter
    if waiter == nil then
        gate.ready = true
        gate.value = value
        gate.reason = reason
        return
    end
    gate.waiter = nil
    waiter.waitingOn = nil
    waiter.waitKind = nil
    waiter.resumeTag = RESUME
    waiter.resumeValue = value
    waiter.resumeReason = reason
    enqueue(waiter.scheduler as SchedulerImpl, waiter)
end

function GateImpl:complete(value: any)
    finishGate(self, value)
end

function GateImpl:fail(reason: string)
    if type(reason) ~= "string" or reason == "" then
        error("tecs: readiness failure needs a reason", 2)
    end
    finishGate(self, nil, reason)
end

function GateImpl:reset()
    if self.waiter ~= nil then
        error("tecs: cannot reset a readiness gate with a waiter", 2)
    end
    self.ready = false
    self.value = nil
    self.reason = nil
end

local record taskruntime
    type Task<T> = TaskImpl<T>
    type Scope = ScopeImpl
    type Scheduler = SchedulerImpl
    type Gate = GateImpl

    newScheduler: function(): SchedulerImpl
    newGate: function(cancelWait?: function()): GateImpl
    onSettle: function<T>(task: TaskImpl<T>, observer: function(TaskImpl<T>))
    awaitCallback: function<T>(subscribe: function(resume: function(T)): function()): T
    awaitCompletion: function<T>(completion: Completion<T>, operation: string): T
    run: function<T>(body: function(ScopeImpl): T...): T
    yield: function()
    waitMode: function(): WaitMode
    checkWait: function(operation: string): WaitMode
    checkSuspension: function(operation: string)
    active: function(): boolean
    current: function(): TaskImpl<any>
    context: function(): any
    enterBarrier: function(subject: string)
    leaveBarrier: function()
end

function taskruntime.newScheduler(): SchedulerImpl
    return setmetatable(
        {
            current = nil,
            ready = {},
            next = {},
            readyCount = 0,
            nextCount = 0,
            stepping = false,
        } as SchedulerImpl,
        SCHEDULER_MT
    )
end

function taskruntime.newGate(cancelWait?: function()): GateImpl
    return setmetatable(
        {
            ready = false,
            value = nil,
            reason = nil,
            waiter = nil,
            cancelWait = cancelWait,
        } as GateImpl,
        GATE_MT
    )
end

function taskruntime.onSettle<T>(task: TaskImpl<T>, observer: function(TaskImpl<T>))
    if task == nil or type(observer) ~= "function" then
        error("tecs: onSettle needs a task and an observer", 2)
    end
    if task._onSettle ~= nil then
        error("tecs: a task can have only one settlement observer", 2)
    end
    if task.status ~= "pending" then
        observer(task)
        return
    end
    task._onSettle = observer as function(TaskImpl<any>)
end

-- Parks on the runtime's smallest asynchronous boundary. The operation owns
-- completion and calls `resume` once; the returned function releases this
-- consumer if its Task is canceled first. Producer completions adapt to the
-- same Gate protocol rather than imposing an execution model on operations.
function taskruntime.awaitCallback<T>(subscribe: function(resume: function(T)): function()): T
    taskruntime.checkSuspension("asynchronous operation")
    if type(subscribe) ~= "function" then
        error("tecs: asynchronous operation needs a subscription", 2)
    end

    local cancelSubscription: function() = function() end
    local gate <const> = taskruntime.newGate(function() cancelSubscription() end)
    cancelSubscription = subscribe(function(value: T) gate:complete(value) end)
    if type(cancelSubscription) ~= "function" then
        error("tecs: asynchronous subscription needs a cancellation function", 2)
    end

    local value, reason <const> = gate:wait()
    if reason ~= nil then
        error(reason, 2)
    end
    return value as T
end

--- Bridges an internal producer completion to the direct-return API model.
function taskruntime.awaitCompletion<T>(completion: Completion<T>, operation: string): T
    if completion == nil then
        error("tecs: " .. operation .. " has no completion", 2)
    end
    local settled = completion
    if completion.status == "pending" and taskruntime.checkWait(operation) == "cooperative" then
        local gate <const> = taskruntime.newGate(function() completion:cancel() end)
        completion:onSettle(function(done: Completion<T>) gate:complete(done) end)
        local value, reason <const> = gate:wait()
        if reason ~= nil then
            error(reason, 2)
        end
        settled = value as Completion<T>
    elseif completion.status == "pending" then
        settled:wait()
    end
    if settled.status == "ready" then
        return settled.value
    end
    if settled.status == "failed" then
        error(("tecs: %s failed: %s"):format(operation, settled.error or "failed"), 2)
    end
    if settled.status == "pending" then
        error(("tecs: %s did not complete within its wait budget"):format(operation), 2)
    end
    error(("tecs: %s was canceled: %s"):format(operation, settled.error or "canceled"), 2)
end

function taskruntime.run<T>(body: function(ScopeImpl): T...): T
    local scheduler <const> = taskruntime.newScheduler()
    local root <const> = scheduler:spawn(body)
    while root.status == "pending" do
        local resumed <const> = scheduler:step()
        if resumed == 0 then
            error("tecs: task runtime deadlocked with no ready task", 2)
        end
    end
    if root.status == "ready" then
        return root.value
    end
    if root.status == "canceled" then
        error("tecs: root task was canceled: " .. root.error, 2)
    end
    error(root.error, 2)
end

function taskruntime.yield()
    local task <const> = currentTask()
    checkCanSuspend(task, "task.yield")
    local tag <const> = coroutine.yield(YIELD)
    if tag == CANCEL then
        error(CANCEL, 0)
    end
end

-- Chooses how one unresolved finite operation waits. Callers attempt their
-- immediate path first, so cache hits and already-buffered bytes never touch
-- this branch.
function taskruntime.waitMode(): WaitMode
    local scheduler <const> = activeScheduler
    if scheduler == nil or scheduler.current == nil then
        return "blocking"
    end
    local scope <const> = scheduler.current.scope as {string: any}
    if scope.barrier ~= nil then
        return "forbidden"
    end
    return "cooperative"
end

function taskruntime.checkWait(operation: string): WaitMode
    if type(operation) ~= "string" or operation == "" then
        error("tecs: wait check needs an operation", 2)
    end
    local mode <const> = taskruntime.waitMode()
    if mode == "forbidden" then
        local task <const> = currentTask()
        local barrier <const> = ((task.scope as ScopeImpl) as {string: any}).barrier as string
        error(("tecs: %s cannot wait while %s is active"):format(operation, barrier), 2)
    end
    return mode
end

function taskruntime.checkSuspension(operation: string)
    if type(operation) ~= "string" or operation == "" then
        error("tecs: suspension check needs an operation", 2)
    end
    checkCanSuspend(currentTask(), operation)
end

function taskruntime.active(): boolean
    return activeScheduler ~= nil and activeScheduler.current ~= nil
end

function taskruntime.current(): TaskImpl<any>
    local scheduler <const> = activeScheduler
    return scheduler ~= nil and scheduler.current or nil
end

-- Attaches scheduler-owned metadata to the currently executing continuation.
-- It lives on the reusable task so suspension cannot confuse it with whichever
-- continuation runs next.
function taskruntime.context(): any
    local scheduler <const> = activeScheduler
    if scheduler == nil or scheduler.current == nil then
        return nil
    end
    return scheduler.current.context
end

function taskruntime.enterBarrier(subject: string)
    local task <const> = currentTask()
    if type(subject) ~= "string" or subject == "" then
        error("tecs: suspension barrier needs a subject", 2)
    end
    local scope <const> = task.scope as {string: any}
    if scope.barrier ~= nil then
        error("tecs: suspension barriers cannot nest", 2)
    end
    scope.barrier = subject
end

function taskruntime.leaveBarrier()
    local task <const> = currentTask()
    local scope <const> = task.scope as {string: any}
    if scope.barrier == nil then
        error("tecs: no suspension barrier is active", 2)
    end
    scope.barrier = nil
end

return taskruntime
