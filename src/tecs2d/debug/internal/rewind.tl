--- Time-travel snapshot ring for the debugger's `rewind` command: captures
--- world snapshots at a fixed wall-clock interval into a bounded, disk-backed
--- ring under the save directory's debug-rewind/ folder.
---
--- Capture never runs while the freeze controller is held (debugger open,
--- MCP pause, recording countdowns), so freezing to investigate cannot churn
--- the ring and evict the pre-bug history. Loading an entry pauses capture
--- (reason "loaded") until an explicit resume. `start` refuses to destroy a
--- stopped ring; only `clear` deletes it.

local tecs <const> = require("tecs")
local debugcontext <const> = require("tecs2d.debug.internal.debugcontext")
local replaytape <const> = require("tecs2d.debug.internal.replaytape")

local record rewind
    DIR: string

    --- Begin a new session. Sweeps stale files from a previous process and
    --- refuses when a session (or its preserved ring) already exists.
    start: function(ctx: debugcontext.Context, now: number, interval: number, cap: integer): boolean, string

    stop: function(ctx: debugcontext.Context): boolean, string
    pause: function(ctx: debugcontext.Context): boolean, string
    resume: function(ctx: debugcontext.Context, now: number): boolean, string

    --- Delete every ring file and reset to idle. Returns the removed count.
    clear: function(ctx: debugcontext.Context): integer

    --- Capture when due. Called every frame with the monotonic clock and the
    --- freeze state; does nothing unless running, unfrozen, and past due.
    tick: function(ctx: debugcontext.Context, w: tecs.World, now: number, frozen: boolean)

    --- Force one capture (used by tick and tests). Returns false + reason on
    --- failure, after moving the session to paused with reason "error".
    capture: function(ctx: debugcontext.Context, w: tecs.World, now: number): boolean, string

    --- Resolve a ring entry: ref is a newest-first list index or "latest"
    --- (nil = latest); ago picks the newest entry at least that many seconds
    --- old. Returns the entry and its newest-first index, or nil + reason.
    findEntry: function(ctx: debugcontext.Context, ref: string, ago: number): debugcontext.Context.RewindEntry, integer, string
end

rewind.DIR = "debug-rewind"

local function state(ctx: debugcontext.Context): debugcontext.Context.RewindState
    return ctx.rewind
end

-- Delete every file under the ring directory (all of them are ours by
-- construction), returning how many were removed.
local function sweepDir(): integer
    local files = love.filesystem.getDirectoryItems(rewind.DIR)
    local removed = 0
    for i = 1, (files and #files or 0) do
        if love.filesystem.remove(rewind.DIR .. "/" .. files[i]) then
            removed = removed + 1
        end
    end
    return removed
end

function rewind.start(ctx: debugcontext.Context, now: number, interval: number, cap: integer): boolean, string
    local st = state(ctx)
    if st.status == "running" or st.status == "paused" then
        return false, "already " .. st.status .. "; `rewind stop` first"
    end
    if st.status == "stopped" and #st.entries > 0 then
        return false, "a stopped ring with " .. tostring(#st.entries) ..
            " entries exists; `rewind keep` what you need, then `rewind clear`"
    end
    if interval <= 0 then
        return false, "interval must be positive"
    end
    if cap < 1 then
        return false, "cap must be at least 1"
    end
    -- Sweep leftovers from a crashed previous session.
    sweepDir()
    love.filesystem.createDirectory(rewind.DIR)
    st.status = "running"
    st.pauseReason = ""
    st.interval = interval
    st.cap = cap
    st.nextDueAt = now
    st.entries = {}
    st.counter = 0
    st.bytes = 0
    st.lastCaptureMs = 0
    st.lastError = ""
    return true, nil
end

function rewind.stop(ctx: debugcontext.Context): boolean, string
    local st = state(ctx)
    if st.status ~= "running" and st.status ~= "paused" then
        return false, "no session to stop (status: " .. st.status .. ")"
    end
    st.status = "stopped"
    st.pauseReason = ""
    return true, nil
end

function rewind.pause(ctx: debugcontext.Context): boolean, string
    local st = state(ctx)
    if st.status ~= "running" then
        return false, "not running (status: " .. st.status .. ")"
    end
    st.status = "paused"
    st.pauseReason = "manual"
    return true, nil
end

function rewind.resume(ctx: debugcontext.Context, now: number): boolean, string
    local st = state(ctx)
    if st.status ~= "paused" then
        if st.status == "stopped" then
            return false, "session stopped; `rewind keep` then `rewind clear` to start a new one"
        end
        return false, "nothing to resume (status: " .. st.status .. ")"
    end
    st.status = "running"
    st.pauseReason = ""
    st.nextDueAt = now + st.interval
    return true, nil
end

function rewind.clear(ctx: debugcontext.Context): integer
    local st = state(ctx)
    local removed = 0
    for i = 1, #st.entries do
        if love.filesystem.remove(st.entries[i].path) then
            removed = removed + 1
        end
    end
    -- Also sweep files a crashed session left that never made it into entries.
    removed = removed + sweepDir()
    st.status = "idle"
    st.pauseReason = ""
    st.entries = {}
    st.counter = 0
    st.bytes = 0
    st.lastError = ""
    return removed
end

function rewind.capture(ctx: debugcontext.Context, w: tecs.World, now: number): boolean, string
    local st = state(ctx)
    local t0 = love.timer.getTime()
    st.counter = st.counter + 1
    local path = rewind.DIR .. "/rewind-" .. tostring(st.counter) .. ".snapshot"
    local ok, err = pcall(function(): boolean
        local out = w:saveSnapshot()
        local wok, werr = love.filesystem.write(path, tostring(out.buffer))
        if not wok then
            error(werr or "write failed", 0)
        end
        return true
    end)
    if not ok then
        st.status = "paused"
        st.pauseReason = "error"
        st.lastError = tostring(err)
        return false, st.lastError
    end
    local info = love.filesystem.getInfo(path)
    local size = ((info and info.size) or 0) as integer
    local recorder = w.resources[replaytape.KEY]
    st.entries[#st.entries + 1] = {
        path = path,
        size = size,
        time = os.time() as integer,
        entities = w:getStats().entities,
        frame = recorder and recorder.frame or nil,
        held = recorder and recorder:heldRows() or nil,
    }
    st.bytes = st.bytes + size
    while #st.entries > st.cap do
        local oldest = table.remove(st.entries, 1)
        love.filesystem.remove(oldest.path)
        st.bytes = st.bytes - oldest.size
    end
    st.nextDueAt = now + st.interval
    st.lastCaptureMs = (love.timer.getTime() - t0) * 1000
    return true, nil
end

function rewind.tick(ctx: debugcontext.Context, w: tecs.World, now: number, frozen: boolean)
    local st = state(ctx)
    if st.status ~= "running" or frozen then return end
    if now < st.nextDueAt then return end
    rewind.capture(ctx, w, now)
end

function rewind.findEntry(ctx: debugcontext.Context, ref: string, ago: number): debugcontext.Context.RewindEntry, integer, string
    local st = state(ctx)
    local n = #st.entries
    if n == 0 then
        return nil, 0, "the ring is empty"
    end
    if ago ~= nil then
        -- Newest entry at least `ago` seconds old (entries append oldest
        -- first, so walk from the newest backward).
        local nowWall = os.time()
        for i = n, 1, -1 do
            local e = st.entries[i]
            if nowWall - e.time >= ago then
                return e, n - i + 1, nil
            end
        end
        local oldestAge = nowWall - st.entries[1].time
        return nil, 0, "no entry that old (oldest is " .. tostring(oldestAge) .. "s)"
    end
    if ref == nil or ref == "" or ref == "latest" then
        return st.entries[n], 1, nil
    end
    -- "10s" is shorthand for ago=10.
    local secs = ref:match("^(%d+%.?%d*)s$")
    if secs then
        return rewind.findEntry(ctx, nil, tonumber(secs))
    end
    local refNum = tonumber(ref)
    if not refNum then
        return nil, 0, "expected an index, `latest`, `Ns` for seconds back, or ago=N"
    end
    local idx = math.floor(refNum) as integer
    if idx < 1 or idx > n then
        return nil, 0, "index out of range (1-" .. tostring(n) .. ", newest first)"
    end
    return st.entries[n - idx + 1], idx, nil
end

return rewind
