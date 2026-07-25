local types <const> = require("tecs2d.workers.types")
local logging <const> = require("tecs.utils.logging")

local LOGGER <const> = logging.getLogger("tecs2d.workers")

-- Example builds expose the compiled worker at this stable Love filesystem
-- path. The source is cached after the first queue is constructed.
local WORKER_PATH <const> = "internal/worker.lua"
local WORKER_CODE: string = nil

local function getWorkerCode(): string
    if WORKER_CODE then return WORKER_CODE end
    WORKER_CODE = love.filesystem.read(WORKER_PATH)
    if not WORKER_CODE then
        error("Could not load Tecs2D worker from '" .. WORKER_PATH .. "'. " ..
              "Copy build/tecs2d/workers/internal/worker.lua to your game's internal/ folder.")
    end
    return WORKER_CODE
end

local record threaded
    record Queue is types.Queue
        _pushChannel: love.thread.Channel
        _pullChannel: love.thread.Channel
        _threads: {love.thread.Thread}
        _running: {integer: HandleImpl<any>}
        _nextId: integer
        _runningCount: integer
        _completedCount: integer
        _failedCount: integer
        _errors: {string}
        _closed: boolean
        _shutdown: boolean
        _fatalError: string

        _nextHandleId: function(self): integer
        _newDerived: function<T>(self): HandleImpl<T>
        _settle: function<T>(self, handle: HandleImpl<T>, value: T, err: string | nil)
    end

    new: function(config?: types.Config): types.Queue
end

local type Queue = threaded.Queue

local record HandleImpl<T> is types.Handle<T>
    id: integer
    isComplete: boolean
    err: string | nil

    _value: T
    _queue: Queue
    _listeners: {function(types.Handle<T>)}
end

local HANDLE_MT: metatable<HandleImpl>

local function observeSafely<T>(listener: function(types.Handle<T>), handle: types.Handle<T>)
    local ok, err = pcall(listener, handle) as (boolean, any)
    if not ok then
        LOGGER:error("Worker handle observer failed: %s", tostring(err))
    end
end

function HandleImpl:observe(listener: function(types.Handle<T>))
    if self.isComplete then
        observeSafely(listener, self as types.Handle<T>)
    else
        self._listeners[#self._listeners + 1] = listener
    end
end

function HandleImpl:map<U>(transform: function(T): U): types.Handle<U>
    local result = self._queue:_newDerived() as HandleImpl<U>
    self:observe(function(source: types.Handle<T>)
        if source.err then
            self._queue:_settle(result, nil as U, source.err)
            return
        end
        local ok, value = pcall(transform, (source as HandleImpl<T>)._value) as (boolean, any)
        if ok then
            self._queue:_settle(result, value as U, nil)
        else
            self._queue:_settle(result, nil as U, "Transform error: " .. tostring(value))
        end
    end)
    return result as types.Handle<U>
end

function HandleImpl:flatMap<U>(transform: function(T): types.Handle<U>): types.Handle<U>
    local result = self._queue:_newDerived() as HandleImpl<U>
    self:observe(function(source: types.Handle<T>)
        if source.err then
            self._queue:_settle(result, nil as U, source.err)
            return
        end
        local ok, inner = pcall(transform, (source as HandleImpl<T>)._value) as (boolean, any)
        if not ok then
            self._queue:_settle(result, nil as U, "Transform error: " .. tostring(inner))
            return
        end
        local innerImpl = inner as HandleImpl<U>
        if not innerImpl or innerImpl._queue ~= self._queue then
            self._queue:_settle(result, nil as U, "flatMap requires a handle from the same worker queue")
            return
        end
        innerImpl:observe(function(settled: types.Handle<U>)
            local settledImpl = settled as HandleImpl<U>
            self._queue:_settle(result, settledImpl._value, settled.err)
        end)
    end)
    return result as types.Handle<U>
end

function HandleImpl:handle<U>(fn: function(T | nil, string | nil): U): types.Handle<U>
    local result = self._queue:_newDerived() as HandleImpl<U>
    self:observe(function(source: types.Handle<T>)
        local sourceImpl = source as HandleImpl<T>
        local ok, value = pcall(fn, sourceImpl._value, source.err) as (boolean, any)
        if ok then
            self._queue:_settle(result, value as U, nil)
        else
            self._queue:_settle(result, nil as U, "Handle error: " .. tostring(value))
        end
    end)
    return result as types.Handle<U>
end

HANDLE_MT = {
    __index = function(self: HandleImpl<any>, key: string): any
        if key == "value" then
            while not self.isComplete and self._queue:update() do end
            if not self.isComplete then
                self._queue:_settle(self, nil, "worker operation could not complete")
            end
            if self.err then
                error("Worker operation failed: " .. self.err)
            end
            rawset(self as table, "value", self._value)
            return self._value
        elseif key == "err" then
            return rawget(self as table, "err")
        elseif key == "isComplete" then
            return rawget(self as table, "isComplete") == true
        end
        return (HandleImpl as {string: any})[key]
    end,
} as metatable<HandleImpl>

local QUEUE_MT <const>: metatable<Queue> = {__index = threaded.Queue}
local nextQueueId: integer = 0

function threaded.Queue:_nextHandleId(): integer
    self._nextId = self._nextId + 1
    return self._nextId
end

function threaded.Queue:_newDerived<T>(): HandleImpl<T>
    return setmetatable({
        id = self:_nextHandleId(),
        isComplete = false,
        _queue = self,
        _listeners = {},
    } as HandleImpl<T>, HANDLE_MT as metatable<HandleImpl<T>>) as HandleImpl<T>
end

function threaded.Queue:_settle<T>(handle: HandleImpl<T>, value: T, err: string | nil)
    if handle.isComplete then return end
    handle._value = value
    handle.err = err
    handle.isComplete = true
    rawset(handle as table, "err", err)
    rawset(handle as table, "isComplete", true)

    local listeners = handle._listeners
    handle._listeners = {}
    for i = 1, #listeners do
        observeSafely(listeners[i], handle as types.Handle<T>)
    end
end

function threaded.Queue:submit<I, O>(job: types.Job<I, O>, input: I): types.Handle<O>
    assert(not self._closed, self._fatalError or "worker queue is shut down")
    assert(job and job.moduleName and job.moduleName ~= "", "worker job requires a module name")
    local id = self:_nextHandleId()
    local handle = setmetatable({
        id = id,
        isComplete = false,
        _queue = self,
        _listeners = {},
    } as HandleImpl<O>, HANDLE_MT as metatable<HandleImpl<O>>) as HandleImpl<O>
    self._running[id] = handle as HandleImpl<any>
    self._runningCount = self._runningCount + 1
    self._pushChannel:push({id, job.moduleName, job.functionName or "run", input})
    return handle as types.Handle<O>
end

function threaded.Queue:all<T>(handles: {types.Handle<T>}): types.Handle<{T}>
    local result = self:_newDerived() as HandleImpl<{T}>
    if #handles == 0 then
        self:_settle(result, {}, nil)
        return result as types.Handle<{T}>
    end

    local values: {T} = {}
    local remaining = #handles
    local errors: {integer: string} = {}
    for i = 1, #handles do
        local handle = handles[i] as HandleImpl<T>
        assert(handle._queue == self, "workers.all requires handles from the same queue")
        handle:observe(function(settled: types.Handle<T>)
            local impl = settled as HandleImpl<T>
            values[i] = impl._value
            errors[i] = settled.err
            remaining = remaining - 1
            if remaining == 0 then
                local firstError: string = nil
                for j = 1, #handles do
                    if errors[j] then firstError = errors[j]; break end
                end
                self:_settle(result, values, firstError)
            end
        end)
    end
    return result as types.Handle<{T}>
end

local function failPending(self: Queue, message: string)
    for id, handle in pairs(self._running) do
        self._running[id] = nil
        self._runningCount = self._runningCount - 1
        self._failedCount = self._failedCount + 1
        self._completedCount = self._completedCount + 1
        self._errors[#self._errors + 1] = message
        self:_settle(handle, nil, message)
    end
end

function threaded.Queue:update(): boolean
    if self._fatalError then error(self._fatalError) end
    for i = 1, #self._threads do
        local err = self._threads[i]:getError()
        if err then
            self._fatalError = "Worker thread " .. i .. " crashed: " .. tostring(err)
            self._closed = true
            failPending(self, self._fatalError)
            error(self._fatalError)
        end
    end

    while self._pullChannel:getCount() > 0 do
        local message = self._pullChannel:pop() as {any}
        if message then
            local id = message[1] as integer
            local handle = self._running[id]
            if not handle then
                error("Worker result has no pending handle: " .. tostring(id))
            end
            self._running[id] = nil
            self._runningCount = self._runningCount - 1
            self._completedCount = self._completedCount + 1
            local err = message[3] as string
            if err then
                self._failedCount = self._failedCount + 1
                self._errors[#self._errors + 1] = err
            end
            self:_settle(handle, message[2], err)
        end
    end
    return self._runningCount > 0
end

function threaded.Queue:wait(timeout?: number): {string}
    local start = love.timer.getTime()
    while self:update() do
        if timeout and love.timer.getTime() - start >= timeout then break end
    end
    local result: {string} = {}
    for i = 1, #self._errors do result[i] = self._errors[i] end
    return result
end

function threaded.Queue:isBusy(): boolean
    return self._runningCount > 0
end

function threaded.Queue:getStats(): types.Stats
    return {
        runningCount = self._runningCount,
        completedCount = self._completedCount,
        failedCount = self._failedCount,
    }
end

function threaded.Queue:shutdown()
    if self._shutdown then return end
    self._shutdown = true
    self._closed = true
    while self._pushChannel:getCount() > 0 do self._pushChannel:pop() end
    failPending(self, "worker queue shut down before the job completed")
    for _ = 1, #self._threads do self._pushChannel:push(false) end

    local waitedMs = 0
    local allStopped = false
    while waitedMs < 200 and not allStopped do
        allStopped = true
        for i = 1, #self._threads do
            if self._threads[i] and self._threads[i]:isRunning() then allStopped = false end
        end
        if not allStopped then
            love.timer.sleep(0.01)
            waitedMs = waitedMs + 10
        end
    end
    self._threads = {}
end

function threaded.new(config?: types.Config): types.Queue
    nextQueueId = nextQueueId + 1
    local id = nextQueueId
    local taskName = "tecs2d.workers.task." .. id
    local resultName = "tecs2d.workers.result." .. id
    local threadCount = config and config.threadCount or math.min(4, love.system.getProcessorCount())
    assert(threadCount >= 1, "worker threadCount must be at least 1")

    local queue = setmetatable({
        _pushChannel = love.thread.getChannel(taskName),
        _pullChannel = love.thread.getChannel(resultName),
        _threads = {},
        _running = {},
        _nextId = 0,
        _runningCount = 0,
        _completedCount = 0,
        _failedCount = 0,
        _errors = {},
        _closed = false,
        _shutdown = false,
    } as Queue, QUEUE_MT) as Queue

    local code = getWorkerCode()
    for _ = 1, threadCount do
        local thread = love.thread.newThread(code)
        thread:start(taskName, resultName)
        queue._threads[#queue._threads + 1] = thread
    end
    return queue as types.Queue
end

return threaded
