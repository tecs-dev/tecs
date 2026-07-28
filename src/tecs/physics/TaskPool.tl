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

--- A pool of solver threads, and the two native callbacks Box2D drives it
--- through.
---
--- One is normally `acquire`d rather than created: the whole process shares a
--- single pool, because threads are a property of the machine and not of any
--- one simulation. Nothing here is safe across threads itself; a pool is
--- created, installed and destroyed from the game thread, and the only code
--- that runs on its workers is Box2D's own, inside `b2World_Step`.
local record TaskPool
    --- Worker slots, counting the thread that steps the world. This is what
    --- Box2D is told, and it is what the pool reached rather than what was
    --- asked for.
    workerCount: integer

    --- The native pool, which Box2D receives as its `userTaskContext`. Nil
    --- once `destroy` has run, which is what makes a second `destroy` a no-op.
    handle: loader.CPtr

    --- Private. Box2D's enqueue callback, taken from C once at creation
    --- because a Lua one would be entered from a thread the VM never made.
    _enqueue: loader.CValue

    --- Private. Box2D's finish callback, the other half of `_enqueue`.
    _finish: loader.CValue

    --- Private. Whether the threads have been joined and the pool freed.
    _destroyed: boolean
    --- What `acquire` was asked for, which is what a later `acquire` has to
    --- agree with. Nil on a pool built through `create`.
    _requested: integer
    --- Outstanding `acquire` calls. Nil on a pool built through `create`,
    --- which is owned by whoever made it.
    _refs: integer
end

local TaskPoolMT <const>: metatable<TaskPool> = {__index = TaskPool}

--- Creates a pool.
---
--- `workerCount` counts the thread that steps the world, so one starts no
--- threads and every task runs inline, which is what a world given no executor
--- does. Defaults to a count derived from the machine.
---
--- @param workerCount Total slots including the calling thread, so the pool
---     starts `workerCount - 1` threads. Clamped to at least 1 and at most 64,
---     and clamped again to what actually started if a thread failed to, so
---     read `workerCount` off the result rather than assuming it. Omit for
---     `defaultWorkerCount`.
--- @return A pool the caller owns and has to `destroy`. It is not the shared
---     one and does not participate in `acquire`'s reference count, so prefer
---     `acquire` unless a test needs a pool of its own.
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
---
--- @param definition A `b2WorldDef`, mutated in place: four fields are written
---     and the rest are left alone. Box2D copies the definition at world
---     creation, so the definition need not outlive the call, but the pool has
---     to outlive the world.
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

--- The pool every simulation in this process shares, or nil when none is held.
local shared: TaskPool = nil

--- The pool the simulations in this process share, creating it on the first
--- call and handing back the same one after.
---
--- Threads are the machine rather than the simulation. There is physically one
--- CPU, and sizing two worlds' pools sanely would mean comparing their worker
--- counts against each other, so there is one pool and it is shared. Three
--- worlds on an eight-core machine would otherwise start twenty-one solver
--- threads for eight cores, of which at most seven ever have work at once:
--- idle threads only reserve stacks, but a step turns them into contention,
--- which is the shape that moves p95 and leaves p50 alone.
---
--- Sharing is safe because worlds step serially on the game thread. Box2D
--- enqueues chunks, the pool's workers drain them, and the finish callback
--- waits for the last one before `b2World_Step` returns, so the free list is
--- never held by two in-flight steps. Nothing in this module survives
--- simulation moving off the game thread, or two worlds stepping at once.
---
--- `workerCount` is therefore first-acquire-wins. A later caller naming a
--- different one raises rather than being silently ignored: two numbers that
--- have to agree and can disagree is a defect waiting.
---
--- @param workerCount Honoured only by the first `acquire`. A later one may
---     omit it, and passing a different value raises rather than resizing.
--- @return The process-wide pool, with one more outstanding reference. Pair
---     every call with `release`, not `destroy`.
function TaskPool.acquire(workerCount?: integer): TaskPool
    if shared ~= nil then
        if workerCount ~= nil and workerCount ~= shared._requested then
            error(
                (
                    "tecs: the physics thread pool is shared and already sized for %d worker(s); "
                    .. "cannot also size it for %d"
                ):format(shared._requested, workerCount),
                2
            )
        end
        shared._refs = shared._refs + 1
        return shared
    end

    local pool = TaskPool.create(workerCount)
    pool._requested = workerCount or pool.workerCount
    pool._refs = 1
    shared = pool
    return pool
end

--- Gives back one `acquire`, joining the threads when the last one goes.
---
--- The world using it has to be destroyed first, and any other live
--- simulation keeps the count above zero, so the pool cannot be joined while
--- a step could be in flight anywhere.
function TaskPool:release()
    if self._refs == nil then
        self:destroy()
        return
    end
    self._refs = self._refs - 1
    if self._refs > 0 then
        return
    end
    if shared == self then
        shared = nil
    end
    self:destroy()
end

--- Pool threads running in this process, across every pool.
---
--- Zero once every pool is destroyed. Exposed so a test can observe that
--- shutdown joined rather than infer it from a clean exit.
---
--- @return Threads the pools started, so the game thread is not counted even
---     though `workerCount` counts it. A pool of one worker contributes zero.
function TaskPool.liveThreadCount(): integer
    return tonumber(C.tecsTaskPoolLiveThreadCount()) as integer
end

--- The worker count a pool created without one uses.
---
--- @return Derived from the machine's performance core count, falling back to
---     its logical CPU count, and capped at 8: the solver's stages are short
---     enough that past a handful of workers the coordination costs more than
---     the work. Includes the calling thread, and is never below 1.
function TaskPool.defaultWorkerCount(): integer
    return tonumber(C.tecsTaskPoolDefaultWorkerCount()) as integer
end

return TaskPool
