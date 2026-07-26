--- A clock the sequencer schedules against.
---
--- A clock owns a counter, a monotonic sequence number for breaking ties, and
--- the heap of playbacks waiting on it. What the counter *means* is the
--- clock's business and nothing else's: the heap does not care whether it
--- counts fixed steps or gameplay frames.
---
--- Playbacks parked on a signal, a query, a join, or a tween are not here.
--- They have no wake time and live in their own index until whatever they are
--- waiting on releases them.

local wakeheap <const> = require("tecs2d.internal.wakeheap")

local record clock
    record Clock
        --- Ticks counted so far.
        step: integer

        --- Monotonic, incremented per scheduling. Two playbacks due on the
        --- same tick run in the order they were scheduled.
        seq: integer

        --- Waiting playbacks, ordered by (wakeAt, seq), carrying the packed
        --- handle so a reused slot cannot be woken by the entry the previous
        --- playback left behind.
        waiting: wakeheap.Heap

        --- Playbacks evaluating rather than waiting, as a dense array of
        --- slots walked every tick. They never enter the heap: there is no
        --- wake time to order them by, and paying log n per tick to schedule
        --- something that runs every tick anyway is the cost this avoids.
        active: {integer}
    end

    --- A clock at step zero with nothing waiting.
    new: function(): Clock

    --- Reset to step zero and drop everything waiting. Used by a snapshot
    --- load, which restores its own counters afterwards.
    clear: function(c: Clock)

    --- Schedule `handle` to wake at `wakeAt`, returning the sequence number
    --- it was given.
    schedule: function(c: Clock, wakeAt: integer, handle: integer): integer

    --- Re-queue an already-numbered entry, for a snapshot load rebuilding the
    --- heap from restored cursors.
    requeue: function(c: Clock, wakeAt: integer, seq: integer, handle: integer)

    --- The earliest wake time, or nil when nothing is waiting.
    next: function(c: Clock): integer

    --- Remove the earliest entry, returning its seq and handle.
    take: function(c: Clock): integer, integer

    --- Add a slot to the evaluating set. Safe to call twice.
    activate: function(c: Clock, slot: integer)

    --- Drop a slot from the evaluating set.
    deactivate: function(c: Clock, slot: integer)
end

function clock.new(): clock.Clock
    return {step = 0, seq = 0, waiting = wakeheap.new(), active = {}}
end

function clock.clear(c: clock.Clock)
    c.step = 0
    c.seq = 0
    wakeheap.clear(c.waiting)
    local active <const> = c.active
    for i = #active, 1, -1 do active[i] = nil end
end

function clock.activate(c: clock.Clock, slot: integer)
    local active <const> = c.active
    for i = 1, #active do
        if active[i] == slot then return end
    end
    active[#active + 1] = slot
end

function clock.deactivate(c: clock.Clock, slot: integer)
    local active <const> = c.active
    for i = 1, #active do
        if active[i] == slot then
            -- Order among evaluating playbacks is not observable -- they all
            -- run every tick -- so the last one fills the hole.
            active[i] = active[#active]
            active[#active] = nil
            return
        end
    end
end

function clock.schedule(c: clock.Clock, wakeAt: integer, handle: integer): integer
    local seq <const> = c.seq + 1
    c.seq = seq
    wakeheap.push(c.waiting, wakeAt, seq, handle)
    return seq
end

function clock.requeue(c: clock.Clock, wakeAt: integer, seq: integer, handle: integer)
    wakeheap.push(c.waiting, wakeAt, seq, handle)
end

function clock.next(c: clock.Clock): integer
    return wakeheap.peek(c.waiting)
end

function clock.take(c: clock.Clock): integer, integer
    local _, seq, handle = wakeheap.pop(c.waiting)
    return seq, handle as integer
end

return clock
