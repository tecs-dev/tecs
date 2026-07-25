local record types
    --- A typed description of one function exported by a worker-loadable
    --- module. Only the module and function names cross the thread channel.
    interface Job<I, O>
        --- Require path resolved inside the worker Lua state.
        moduleName: string
        --- Exported function to invoke. `newJob` defaults this to `run`.
        functionName: string
    end

    --- Contract exported by a module named by Job. Worker states require the
    --- module and invoke the selected function (normally `run`).
    interface JobModule<I, O>
        run: function(I): O
    end

    --- A composable result produced by a worker queue.
    interface Handle<T>
        --- Whether the job or derived operation has settled.
        isComplete: boolean
        --- Failure message, or nil before settlement and after success.
        err: string | nil
        --- Blocks by pumping the owning queue until the operation settles.
        --- Raises when the operation failed.
        value: T

        --- Invoke `listener` on the main thread after settlement.
        observe: function(self, listener: function(Handle<T>))
        --- Transform a successful value and propagate failures.
        map: function<U>(self, transform: function(T): U): Handle<U>
        --- Chain a handle owned by the same queue.
        flatMap: function<U>(self, transform: function(T): Handle<U>): Handle<U>
        --- Transform either a value or its failure message.
        handle: function<U>(self, fn: function(T | nil, string | nil): U): Handle<U>
    end

    record Config
        --- Number of worker threads. Defaults to min(4, processor count).
        threadCount: integer
    end

    record Stats
        --- Jobs currently awaiting a worker result.
        runningCount: integer
        --- Jobs settled since the queue was created, including failures.
        completedCount: integer
        --- Failed jobs included in `completedCount`.
        failedCount: integer
    end

    --- An asynchronous queue backed by isolated Love worker threads.
    interface Queue
        --- Submit one module-defined job.
        submit: function<I, O>(self, job: Job<I, O>, input: I): Handle<O>
        --- Combine same-queue handles while preserving input order.
        all: function<T>(self, handles: {Handle<T>}): Handle<{T}>
        --- Settle available results; returns whether jobs remain.
        update: function(self): boolean
        --- Pump the queue until idle or `timeout` seconds elapse.
        --- Returns every job error accumulated by the queue.
        wait: function(self, timeout?: number): {string}
        --- Whether the queue has jobs awaiting results.
        isBusy: function(self): boolean
        --- Return a snapshot of queue counters.
        getStats: function(self): Stats
        --- Idempotently reject new work, fail pending jobs, and stop workers.
        shutdown: function(self)
    end
end

return types
