--- The thread pool Box2D solves across.
---
--- Box2D 3 runs its solver on several threads when a world is given an enqueue
--- and a finish callback, and it calls the task function it hands out from
--- whichever thread picks the work up. Those callbacks are native for that
--- reason: a LuaJIT FFI callback invoked from a thread the VM did not create is
--- unsafe, so an enqueue callback written in Lua would be exactly that.
---
--- What is left here is installation. The pool is created before the world,
--- its two function pointers and its context go into the world definition, and
--- no Lua runs again until the step returns.

local loader <const> = require("tecs.ffi.loader")

loader.declare("taskpool")

--- The pool shares the worker library.
local C <const> = loader.library("tecsworker", "tecs", "TECS_WORKER_PATH", "taskpool")

local record TaskPool
    --- Worker slots, counting the thread that steps the world. This is what
    --- Box2D is told, and it is what the pool reached rather than what was
    --- asked for.
    workerCount: integer
    handle: loader.CPtr
    _enqueue: loader.CValue
    _finish: loader.CValue
    _destroyed: boolean
end

local TaskPoolMT <const>: metatable<TaskPool> = {__index = TaskPool}

--- Creates a pool.
---
--- `workerCount` counts the thread that steps the world, so one starts no
--- threads and every task runs inline, which is what a world given no executor
--- does. Defaults to a count derived from the machine.
function TaskPool.create(workerCount?: integer): TaskPool
    local requested = workerCount or tonumber(C.tecsTaskPoolDefaultWorkerCount()) as integer

    local handle = C.tecsTaskPoolCreate(requested)
    if handle == nil then
        error("tecs: cannot create the physics task pool", 2)
    end

    local self = setmetatable({} as TaskPool, TaskPoolMT)
    self.handle = handle
    self.workerCount = tonumber(C.tecsTaskPoolWorkerCount(handle)) as integer
    self._enqueue = C.tecsTaskPoolEnqueueCallback()
    self._finish = C.tecsTaskPoolFinishCallback()
    self._destroyed = false
    return self
end

--- Installs the pool into a `b2WorldDef`.
---
--- The worker count written is the pool's own. Box2D indexes per-worker state
--- by it, so a definition naming more workers than the pool started would have
--- the solver address state that does not exist.
function TaskPool:install(definition: loader.CStruct)
    definition.workerCount = self.workerCount
    definition.enqueueTask = self._enqueue
    definition.finishTask = self._finish
    definition.userTaskContext = self.handle
end

--- Joins every thread and releases the pool. Safe to call more than once.
---
--- The world that uses it has to be destroyed first: the threads run solver
--- code, so releasing the pool while a step could still be in flight is a
--- use-after-free.
function TaskPool:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    C.tecsTaskPoolDestroy(self.handle)
    self.handle = nil
end

--- Pool threads running in this process, across every pool.
---
--- Zero once every pool is destroyed. Exposed so a test can observe that
--- shutdown joined rather than infer it from a clean exit.
function TaskPool.liveThreadCount(): integer
    return tonumber(C.tecsTaskPoolLiveThreadCount()) as integer
end

--- The worker count a pool created without one uses.
function TaskPool.defaultWorkerCount(): integer
    return tonumber(C.tecsTaskPoolDefaultWorkerCount()) as integer
end

return TaskPool
