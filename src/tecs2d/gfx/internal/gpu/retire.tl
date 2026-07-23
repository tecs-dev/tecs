--- Deferred release for GPU objects replaced mid-frame (buffer growth,
--- mesh reallocation). Draw and dispatch commands already recorded this
--- frame, and GPU work still in flight from the previous frame, may
--- reference the old object; dropping the last reference lets the
--- driver free memory the GPU is reading (observed on Metal as
--- malloc "Incorrect checksum for freed object" crashes). Every grow
--- path pushes the replaced object here instead; tick() runs once per
--- frame from Renderer:upload and releases objects two ticks later,
--- after in-flight work has drained.

local devicestate <const> = require("tecs2d.gfx.internal.gpu.devicestate")

local record retire
    --- Queue a replaced GPU object (love.graphics.Buffer, Mesh, ...)
    --- for release two frames from now. nil is ignored.
    push: function(obj: any)

    --- Advance one frame and release objects whose hold expired.
    --- Called once per frame from Renderer:upload.
    tick: function()

    --- Number of objects currently held (for tests/diagnostics).
    heldCount: function(): integer
end

local record Releasable
    release: function(self: Releasable): boolean
end

local record Entry
    obj: Releasable
    frames: integer
end

local entries <const> = devicestate.get().retiredObjects as {Entry}

function retire.push(obj: any)
    if obj == nil then return end
    entries[#entries + 1] = { obj = obj as Releasable, frames = 2 }
end

function retire.tick()
    local n = #entries
    if n == 0 then return end
    local kept = 0
    for i = 1, n do
        local e = entries[i]
        e.frames = e.frames - 1
        if e.frames <= 0 then
            -- Objects without release() (test doubles) are just dropped.
            local rel = e.obj.release
            if rel then rel(e.obj) end
        else
            kept = kept + 1
            entries[kept] = e
        end
    end
    for i = kept + 1, n do
        entries[i] = nil
    end
end

function retire.heldCount(): integer
    return #entries
end

return retire
