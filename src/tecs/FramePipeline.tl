--- The frame coordinator between the thread that simulates and the thread that
--- owns the window.
---
--- Two slots behind one lock. The producer takes a slot, fills its payload,
--- and publishes it; the consumer takes the oldest published slot, reads it,
--- and releases it. Both acquire calls block, and blocking is the point: the
--- producer waits when it has already run a frame ahead rather than dropping
--- the frame it was about to build, so no packet is ever lost.
---
--- The payload is opaque to the pipeline. `acquireWrite` and `acquireRead`
--- return the address of a block of the size given at creation, and what goes
--- in it is the caller's business.
---
--- The state machine, the waiting and the memory ordering are native, because
--- LuaJIT gives each thread its own state with no mutable heap between them:
--- the lock, the condition variables and the packets all have to live outside
--- every `lua_State`. What is left here is the handle and the translation of
--- the two enums.

local ffi <const> = require("ffi")
local loader <const> = require("tecs.ffi.loader")

loader.declare("framepipeline")

--- The coordinator shares the worker library.
local C <const> = loader.library("tecsworker", "tecs",
    "TECS_WORKER_PATH", "framepipeline")

local constants <const> = loader.constants("framepipeline")

local record FramePipeline
    --- Where a slot is in its cycle. A slot is `free`, becomes `writing` when
    --- the producer takes it, `ready` when the producer publishes it,
    --- `reading` when the consumer takes it, and `free` again when the
    --- consumer releases it.
    enum SlotState
        "free"
        "writing"
        "ready"
        "reading"
    end

    --- What the pipeline as a whole is doing. A caller that woke from a
    --- blocking acquire with nothing to show for it reads this to find out
    --- whether the other thread quit or died.
    enum State
        "running"
        "crashed"
        "shuttingDown"
    end

    --- Bytes each packet carries.
    payloadSize: integer
    --- Slots the pipeline has, which is what bounds how far ahead the producer
    --- can run.
    slotCount: integer
    handle: loader.CPtr
    _owned: boolean
    _sequence: loader.CArray
end

local type SlotState = FramePipeline.SlotState
local type State = FramePipeline.State

local FramePipelineMT <const>: metatable<FramePipeline> = {
    __index = FramePipeline,
}

FramePipeline.slotCount = constants.TECS_FRAME_SLOTS

--- Read from C rather than repeated here, so the two orderings cannot drift.
local slotStates <const>: {integer: SlotState} = {
    [tonumber(C.TECS_FRAME_SLOT_FREE) as integer] = "free",
    [tonumber(C.TECS_FRAME_SLOT_WRITING) as integer] = "writing",
    [tonumber(C.TECS_FRAME_SLOT_READY) as integer] = "ready",
    [tonumber(C.TECS_FRAME_SLOT_READING) as integer] = "reading",
}

local states <const>: {integer: State} = {
    [tonumber(C.TECS_FRAME_PIPELINE_RUNNING) as integer] = "running",
    [tonumber(C.TECS_FRAME_PIPELINE_CRASHED) as integer] = "crashed",
    [tonumber(C.TECS_FRAME_PIPELINE_SHUTTING_DOWN) as integer] = "shuttingDown",
}

--- Wraps a handle, owning it or not.
local function adopt(handle: loader.CPtr, owned: boolean): FramePipeline
    local self = setmetatable({} as FramePipeline, FramePipelineMT)
    self.handle = handle
    self.payloadSize =
        tonumber(C.tecsFramePipelinePayloadSize(handle)) as integer
    self._owned = owned
    -- Per pipeline rather than per module, so a state holding two of them
    -- cannot have one overwrite the other's sequence out-parameter.
    self._sequence = loader.newArray("uint64_t[1]")
    return self
end

--- Creates a pipeline whose packets carry `payloadSize` bytes each.
function FramePipeline.create(payloadSize: integer): FramePipeline
    local handle = C.tecsFramePipelineCreate(payloadSize)
    if handle == nil then
        error(("tecs: cannot create a frame pipeline carrying %d bytes")
            :format(payloadSize), 2)
    end
    return adopt(handle, true)
end

--- Wraps a pipeline created in another thread's state, without owning it.
---
--- A worker shares no Lua heap with the state that spawned it, so a handle
--- cannot cross as cdata. Its address can, as a plain number from `address`,
--- and this turns that back into a pipeline. The state that created it is
--- still the one that destroys it.
function FramePipeline.wrap(address: integer): FramePipeline
    local handle = ffi.cast("TecsFramePipeline *", address) as loader.CPtr
    if handle == nil then
        error("tecs: a frame pipeline cannot be wrapped from a null address", 2)
    end
    return adopt(handle, false)
end

--- The pipeline's address, which is what crosses to another thread.
function FramePipeline:address(): integer
    return tonumber(ffi.cast("uintptr_t", self.handle)) as integer
end

--- Takes a slot for writing and returns the address to fill.
---
--- Blocks while the producer has already run a frame ahead. Returns nil once
--- the pipeline has stopped, and when this caller already holds a slot.
function FramePipeline:acquireWrite(): loader.CValue
    local payload = C.tecsFramePipelineAcquireWrite(self.handle)
    -- A null pointer compares equal to nil but is not nil, so the refusal is
    -- turned into one here rather than left for every caller to know about.
    if payload == nil then return nil end
    return payload
end

--- Publishes the slot held for writing, making it visible to the consumer.
---
--- Never blocks. False when no slot is held for writing, and when the pipeline
--- has stopped, in which case the slot is given back unpublished.
function FramePipeline:publish(): boolean
    return C.tecsFramePipelinePublish(self.handle) as boolean
end

--- Takes the oldest published slot and returns its address and frame number.
---
--- Blocks until a packet has been published. Returns nil once the pipeline has
--- stopped, and when this caller already holds a slot.
function FramePipeline:acquireRead(): loader.CValue, integer
    local payload = C.tecsFramePipelineAcquireRead(self.handle, self._sequence)
    if payload == nil then return nil, 0 end
    return payload, tonumber(self._sequence[0]) as integer
end

--- Releases the slot held for reading, which is what lets the producer reuse
--- it. Never blocks. False when no slot is held for reading.
function FramePipeline:releaseRead(): boolean
    return C.tecsFramePipelineReleaseRead(self.handle) as boolean
end

--- Asks the pipeline to stop and wakes everything blocked in it. A pipeline
--- that has already stopped keeps the reason it stopped for.
function FramePipeline:shutdown()
    C.tecsFramePipelineShutdown(self.handle)
end

--- Stops the pipeline because this thread failed, and wakes everything blocked
--- in it. Takes precedence over an orderly shutdown.
function FramePipeline:crash()
    C.tecsFramePipelineCrash(self.handle)
end

--- What the pipeline is doing.
function FramePipeline:state(): State
    return states[tonumber(C.tecsFramePipelineGetState(self.handle)) as integer]
end

--- Where the slot at `slot` is in its cycle, counting from one.
function FramePipeline:slotState(slot: integer): SlotState
    local value = C.tecsFramePipelineGetSlotState(self.handle, slot - 1)
    return slotStates[tonumber(value) as integer]
end

--- Callers parked inside the pipeline waiting for a slot.
---
--- What `destroy` waits to reach zero. Also how another thread can tell that a
--- caller is parked rather than about to park, which is the difference between
--- a pipeline that is safe to release and one that is not.
function FramePipeline:blockedCount(): integer
    return tonumber(C.tecsFramePipelineBlockedCount(self.handle)) as integer
end

--- Stops the pipeline, waits for every blocked caller to leave it, and
--- releases it. Safe to call more than once, and on a wrapped pipeline, where
--- it does nothing.
---
--- Callers have to be finished with it: waking a parked thread is handled, a
--- thread that starts a new operation afterwards is not.
function FramePipeline:destroy()
    if not self._owned then return end
    self._owned = false
    C.tecsFramePipelineDestroy(self.handle)
    self.handle = nil
end

--- Pipelines live in this process, across every state. Zero once each one is
--- destroyed, which is how a test observes that destroy released rather than
--- inferring it from a clean exit.
function FramePipeline.liveCount(): integer
    return tonumber(C.tecsFramePipelineLiveCount()) as integer
end

return FramePipeline
