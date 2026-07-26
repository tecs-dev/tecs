--- Event polling, with an injectable source.
---
--- The source fills a caller-owned `SDL_Event` and reports whether it
--- produced one, mirroring `SDL_PollEvent` exactly. A replay driver can
--- therefore substitute recorded input by writing the same 128 bytes back,
--- with no separate event representation to keep in sync and no per-event
--- allocation on either path.

local sdl <const> = require("tecs2d.ffi.sdl3")
local loader <const> = require("tecs2d.ffi.loader")

local C <const> = sdl.C

local record events
    --- Installed by a replay driver. Fills the event and returns true when
    --- one was produced, false when the queue is drained for this frame.
    source: function(event: loader.CValue): boolean
end

-- One event struct for the lifetime of the process. SDL_Event is a 128 byte
-- union; reusing it keeps the poll loop allocation-free.
local scratch <const> = loader.newArray("SDL_Event[1]")
local scratchEvent <const> = scratch[0] as loader.CValue

local function pollReal(event: loader.CValue): boolean
    return C.SDL_PollEvent(event) as boolean
end

--- Drains the queue, invoking `handler` once per event.
---
--- The event passed to `handler` is reused between calls. Handlers that need
--- to retain one must copy it.
function events.poll(handler: function(event: loader.CValue))
    local source = events.source or pollReal
    while source(scratchEvent) do
        handler(scratchEvent)
    end
end

--- Pushes a quit request onto the real SDL queue.
function events.quit()
    local holder = loader.newArray("SDL_Event[1]")
    local event = holder[0] as loader.CStruct
    event.type = C.SDL_EVENT_QUIT
    C.SDL_PushEvent(holder[0])
end

return events
