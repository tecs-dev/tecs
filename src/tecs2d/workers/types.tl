local record types
    --- A typed description of one function exported by a worker-loadable
    --- module. Only the module and function names cross the thread channel.
    interface Job<I, O>
        moduleName: string
        functionName: string
    end

    --- Contract exported by a module named by Job. Worker states require the
    --- module and invoke the selected function (normally `run`).
    interface JobModule<I, O>
        run: function(I): O
    end

    --- A composable result produced by a worker queue.
    interface Handle<T>
        isComplete: boolean
        err: string
        --- Blocks by pumping the owning queue until the operation settles.
        --- Raises when the operation failed.
        value: T

        observe: function(self, listener: function(Handle<T>))
        map: function<U>(self, transform: function(T): U): Handle<U>
        flatMap: function<U>(self, transform: function(T): Handle<U>): Handle<U>
        handle: function<U>(self, fn: function(T, any): U): Handle<U>
    end

    record Config
        --- Number of worker threads. Defaults to min(4, processor count).
        threadCount: integer
    end

    record Stats
        runningCount: integer
        completedCount: integer
        failedCount: integer
    end

    interface Queue
        submit: function<I, O>(self, job: Job<I, O>, input: I): Handle<O>
        all: function<T>(self, handles: {Handle<T>}): Handle<{T}>
        update: function(self): boolean
        wait: function(self, timeout?: number): {string}
        isBusy: function(self): boolean
        getStats: function(self): Stats
        shutdown: function(self)
    end
end

return types
