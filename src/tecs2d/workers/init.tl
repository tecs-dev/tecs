local types <const> = require("tecs2d.workers.types")
local threaded <const> = require("tecs2d.workers.internal.threaded")

--- Process-wide asynchronous worker queue for Tecs2D. `tecs2d.run` installs
--- the normal global queue; independent queues remain constructible.
local record workers
    type Queue = types.Queue
    type Handle<T> = types.Handle<T>
    type Job<I, O> = types.Job<I, O>
    type JobModule<I, O> = types.JobModule<I, O>
    type Config = types.Config
    type Stats = types.Stats

    --- Active process queue. Assignment performs no lifecycle work.
    queue: types.Queue

    --- Create an independent worker queue.
    new: function(config?: types.Config): types.Queue
    --- Create a typed module/function job descriptor.
    newJob: function<I, O>(moduleName: string, functionName?: string): types.Job<I, O>
    --- Submit to the active process queue.
    submit: function<I, O>(job: types.Job<I, O>, input: I): types.Handle<O>
    --- Combine handles from the active process queue.
    all: function<T>(handles: {types.Handle<T>}): types.Handle<{T}>
    --- Settle available results on the active process queue.
    update: function(): boolean
    --- Pump the active queue until idle or the timeout elapses.
    wait: function(timeout?: number): {string}
    --- Whether the active process queue has pending jobs.
    isBusy: function(): boolean
    --- Return a snapshot of the active queue's counters.
    getStats: function(): types.Stats
    --- Shut down the active process queue.
    shutdown: function()
end

local function current(): types.Queue
    return assert(workers.queue, "tecs2d.workers.queue is not initialized")
end

function workers.new(config?: types.Config): types.Queue
    return threaded.new(config)
end

function workers.newJob<I, O>(moduleName: string, functionName?: string): types.Job<I, O>
    assert(moduleName and moduleName ~= "", "worker job requires a module name")
    return {moduleName = moduleName, functionName = functionName or "run"} as types.Job<I, O>
end

function workers.submit<I, O>(job: types.Job<I, O>, input: I): types.Handle<O>
    return current():submit(job, input)
end

function workers.all<T>(handles: {types.Handle<T>}): types.Handle<{T}>
    return current():all(handles)
end

function workers.update(): boolean return current():update() end
function workers.wait(timeout?: number): {string} return current():wait(timeout) end
function workers.isBusy(): boolean return current():isBusy() end
function workers.getStats(): types.Stats return current():getStats() end
function workers.shutdown() current():shutdown() end

return workers
