--[=[
View of Rapier's process-wide parallel executor.

Rapier owns its Rayon workers in Rust. The Lua object keeps the requested
worker count stable across worlds and exposes lifecycle accounting without
native callbacks.
]=]

local rust <const> = require("tecs.ffi.rust")
local C <const> = rust.C

local record TaskPool
    workerCount: integer
    _requested: integer
    _refs: integer
    _destroyed: boolean
end

local TaskPoolMT <const>: metatable<TaskPool> = {__index = TaskPool}
local shared: TaskPool = nil
local liveWorkers = 0

function TaskPool.defaultWorkerCount(): integer
    local configured = tonumber(os.getenv("TECS_PHYSICS_WORKERS") or "")
    if configured ~= nil then
        return math.max(1, math.min(64, math.floor(configured))) as integer
    end
    return tonumber(C.tecsPhysicsDefaultWorkerCount()) as integer
end

function TaskPool.create(workerCount?: integer): TaskPool
    local count = math.max(1, math.min(64, workerCount or TaskPool.defaultWorkerCount())) as integer
    local self = setmetatable({} as TaskPool, TaskPoolMT)
    self.workerCount = count
    self._requested = count
    self._refs = nil
    self._destroyed = false
    liveWorkers = liveWorkers + count - 1
    return self
end

function TaskPool:destroy()
    if self._destroyed then
        return
    end
    self._destroyed = true
    liveWorkers = liveWorkers - self.workerCount + 1
end

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

function TaskPool:release()
    if self._refs == nil then
        self:destroy()
        return
    end
    self._refs = self._refs - 1
    if self._refs > 0 then
        return
    end
    shared = nil
    self:destroy()
end

function TaskPool.liveThreadCount(): integer
    return liveWorkers
end

return TaskPool
