--[=[
Profiling tools for Tecs.

Two independent channels share the LuaJIT zone stack for attribution:

  * `profile.sample` -- statistical (timer-based) sampler. Emits collapsed-stack
    text consumed by speedscope.app, FlameGraph.pl, inferno, etc. Tells you
    where time is spent.
  * `profile.trace` -- JIT trace event hook. Aggregates trace aborts so you
    can spot blacklisted hot code, repeated NYI bailouts, and trace size
    cliffs that silently demote work to the interpreter. Tells you whether
    the JIT is actually compiling your hot code.

Each call returns a session handle. `:stop()` returns the report and ends
the session; calling `:stop()` twice errors. Only one sample session and
one trace session may be active at a time.

Both channels rely on `jit.zone` push/pop for attribution. `jit.zone` is
a no-op (`__call` is a no-op) until a session enables it; multiple live
sessions refcount, so the zone stack is on whenever any channel needs it.
]=]

local string_format <const> = string.format
local table_concat <const> = table.concat
local table_sort <const> = table.sort

local log <const> = require("tecs.log")
local zones <const> = require("tecs.internal.zones")
local LOGGER <const> = log.get("tecs.profile")

--- Profiling tools for Tecs.
---
--- Two channels, `sample` for where time goes and `trace` for whether the JIT is compiling
--- the code it went into. Both are process-wide rather than per world, both attribute work
--- through the `jit.zone` stack, and at most one session of each kind may be running.
--- Neither is free: a session left running costs on every sample or every trace abort, so
--- stop one when the question it was opened for is answered.
local record profile
    --- Options for `profile.sample`. Every field is optional.
    record SampleOptions
        --- Sampler interval in ms. Default 10 (100 samples/sec). Raise for
        --- longer low-overhead sessions; don't go below 10 unless you've
        --- confirmed your callback can keep up, or the timer will steal real
        --- time from the main thread.
        intervalMs: integer
        --- Per-sample stack depth. Default 16. The walk cost is linear in
        --- depth, so raise only if a specific investigation needs more.
        stackDepth: integer
        --- Restrict output to samples whose zone path starts with this
        --- prefix, e.g. "afterFixed/Render" keeps only the render subtree.
        zone: string
    end

    --- Options for `profile.trace`. Every field is optional.
    record TraceOptions
        --- Include benign trace-formation events ("leaving loop",
        --- "down-recursion", "up-recursion", "inner loop") in the report.
        --- Default false; useful when investigating why a trace failed to form.
        includeBenign: boolean
    end

    --- One place the JIT gave up, and how often it did.
    ---
    --- A row of a `TraceReport`, not a live object: it is built at `stop` and nothing writes
    --- to it afterwards.
    record AbortSite
        --- "blacklist", "warn", or "info".
        severity: string
        --- Number of times this exact (severity, reason, location, zone)
        --- combination fired during the session.
        count: integer
        --- Human-readable reason from `jit.vmdef.traceerr`. NYI bytecode
        --- aborts are rendered with the opcode name when available.
        reason: string
        --- "<file>:<line>" of the function being recorded at abort time.
        location: string
        --- Active zone path at abort time, e.g.
        --- "afterFixed/Render/gfx.sprite". Empty string if no zone was active.
        zone: string
    end

    --- What a trace session saw, as `TraceSession:stop` returns it.
    ---
    --- `tostring` on it renders `sites` as RFC 4180 CSV, so it prints and diffs directly.
    record TraceReport
        --- Wallclock seconds the session was active.
        --- Whole seconds: it comes from `os.time`, so a session shorter than one reads as
        --- zero and dividing by it is a caller's problem.
        durationSec: number
        --- Total abort events recorded. Excludes benign trace-formation
        --- events unless `includeBenign` was set.
        totalAborts: integer
        --- Trace blacklist events. Always actionable: a blacklisted trace is
        --- permanently demoted to the interpreter for the remainder of the run.
        blacklisted: integer
        --- One entry per unique (severity, reason, location, zone). Sorted
        --- by severity (blacklist > warn > info), then count desc.
        sites: {AbortSite}
    end

    --- A running sampler, as `profile.sample` returns it.
    ---
    --- Live until `stop`, and there is at most one of these at a time. Dropping the handle
    --- without stopping leaves the timer running for the rest of the process.
    record SampleSession
        --- Stop the session and return the collapsed-stack text. If `filename`
        --- is given, the text is also written to that path as a side effect.
        --- Errors if called twice.
        ---
        --- One line per distinct stack, semicolon-separated frames then a space then the
        --- sample count, no trailing newline. The empty string when nothing was sampled,
        --- which a short session or a narrow `zone` prefix both produce. Writing raises
        --- when the path cannot be opened, after the session has already been stopped.
        stop: function(SampleSession, ?string): string
        --- Skip recording samples until `:resume()` is called. The timer
        --- keeps firing (cost: one boolean check per sample); the data
        --- captured on either side of the pause window is preserved. Useful
        --- for excluding setup / teardown from a benchmark harness.
        --- Idempotent; errors if the session has been stopped.
        pause: function(SampleSession)
        --- Resume recording. Idempotent; errors if stopped.
        resume: function(SampleSession)
    end

    --- A running trace-abort collector, as `profile.trace` returns it.
    ---
    --- Live until `stop`, and there is at most one of these at a time. Dropping the handle
    --- without stopping leaves the JIT event hook attached for the rest of the process.
    record TraceSession
        --- Stop the session and return the TraceReport. `tostring(report)`
        --- renders the `sites` table as RFC 4180 CSV (suitable for
        --- spreadsheets, `sort`, `diff`, etc.); the top-level
        --- `durationSec` / `totalAborts` / `blacklisted` fields stay on the
        --- returned object. If `filename` is given, the same CSV is also
        --- written to that path as a side effect. Errors if called twice.
        stop: function(TraceSession, ?string): TraceReport
        --- Skip aggregating aborts until `:resume()` is called. Event
        --- registration stays active (cost: one boolean check per abort);
        --- counts captured on either side of the pause window are preserved.
        --- Useful for excluding setup / teardown from a benchmark harness.
        --- Idempotent; errors if the session has been stopped.
        pause: function(TraceSession)
        --- Resume aggregating. Idempotent; errors if stopped.
        resume: function(TraceSession)
    end

    --- Start a sampling session. Returns a handle whose `:stop()` returns
    --- collapsed-stack text. Errors if a sample session is already active.
    ---
    --- `zone` filtering is applied at `stop`, not while sampling, so narrowing it costs
    --- nothing at runtime and widening it later is not possible: what was outside the
    --- prefix was still collected, but the prefix is fixed when the session starts.
    ---
    --- @param opts Omitted samples every zone at 10 ms to a depth of 16.
    sample: function(opts?: SampleOptions): SampleSession

    --- Start a trace abort session. Returns a handle whose `:stop()` returns
    --- a TraceReport (with `__tostring` for direct printing). Errors if a
    --- trace session is already active.
    ---
    --- @param opts Omitted leaves benign trace-formation events out of the report.
    trace: function(opts?: TraceOptions): TraceSession
end

-------------------------------------------------------------------------------
-- Shared zone wiring (refcounted across channels)
-------------------------------------------------------------------------------

local function loadUntyped(modName: string): any
    return require(modName)
end

local zone <const> = zones.stack

local function activeZpath(): string
    local d = #zone
    if d == 0 then
        return ""
    end
    local buf: {string} = {}
    for i = 1, d do
        buf[i] = zone[i]
    end
    return table_concat(buf, "/", 1, d)
end

-------------------------------------------------------------------------------
-- Sample channel
-------------------------------------------------------------------------------

local jitProfile = loadUntyped("jit.profile") as {string: any}
local dumpstack <const> = jitProfile.dumpstack as function(any, string, integer): string
local profileStart <const> = jitProfile.start as function(string, function(any, integer, string))
local profileStop <const> = jitProfile.stop as function()

local ROOT <const> = "<root>"

local record SampleRecord
    n: integer
    N: integer
    I: integer
    C: integer
    G: integer
    J: integer
    zpath: string
    stack: string
end

local function sanitize(s: string): string
    return (s:gsub("[;\n\r]", "_"))
end

local function dominantVm(r: SampleRecord): string
    local best = "N"
    local bestCount = r.N
    if r.I > bestCount then
        best, bestCount = "I", r.I
    end
    if r.C > bestCount then
        best, bestCount = "C", r.C
    end
    if r.G > bestCount then
        best, bestCount = "G", r.G
    end
    if r.J > bestCount then
        best, bestCount = "J", r.J
    end
    return best
end

local function splitInto(s: string, sep: string, out: {string}, offset: integer): integer
    local n = offset
    if s == "" or s == ROOT then
        return n
    end
    local start = 1
    local len = #s
    for i = 1, len do
        if s:sub(i, i) == sep then
            if i > start then
                n = n + 1
                out[n] = sanitize(s:sub(start, i - 1))
            end
            start = i + 1
        end
    end
    if start <= len then
        n = n + 1
        out[n] = sanitize(s:sub(start))
    end
    return n
end

-- Two-level aggregate: `agg[zpath][stack] = SampleRecord`. Splitting the
-- key avoids a `zpath .. "|" .. stack` concat per sample, and the outer
-- Zpath lookup is cached via the shared zone version so in steady-state hot loops
-- each sample is a single table access on the inner map.
local type SampleAgg = {string: {string: SampleRecord}}

local function encodeCollapsed(agg: SampleAgg): string
    local entries: {SampleRecord} = {}
    local count = 0
    for _, inner in pairs(agg) do
        for _, rec in pairs(inner) do
            count = count + 1
            entries[count] = rec
        end
    end
    if count == 0 then
        return ""
    end

    table_sort(
        entries,
        function(a: SampleRecord, b: SampleRecord): boolean
            if a.n ~= b.n then
                return a.n > b.n
            end
            if a.zpath ~= b.zpath then
                return a.zpath < b.zpath
            end
            return a.stack < b.stack
        end
    )

    local lines: {string} = {}
    local frames: {string} = {}
    for i = 1, count do
        local rec = entries[i]
        for k = #frames, 1, -1 do
            frames[k] = nil
        end
        local n = splitInto(rec.zpath, "/", frames, 0)
        n = splitInto(rec.stack, ";", frames, n)
        if n == 0 then
            n = 1
            frames[1] = ROOT
        end
        frames[n] = frames[n] .. "_[" .. dominantVm(rec) .. "]"
        lines[i] = table_concat(frames, ";", 1, n) .. " " .. string_format("%d", rec.n)
    end
    return table_concat(lines, "\n")
end

local function filterByZone(agg: SampleAgg, prefix: string): SampleAgg
    if not prefix or prefix == "" then
        return agg
    end
    local out: SampleAgg = {}
    local plen = #prefix
    for zpath, inner in pairs(agg) do
        if zpath:sub(1, plen) == prefix then
            out[zpath] = inner
        end
    end
    return out
end

local sampleActive = false

local SAMPLE_MT <const>: metatable<profile.SampleSession> = {
    __index = profile.SampleSession,
}

function profile.sample(opts?: profile.SampleOptions): profile.SampleSession
    if sampleActive then
        error("profile.sample: a sample session is already active; call :stop() first", 2)
    end
    opts = opts or {}
    local intervalMs = opts.intervalMs or 10
    local stackDepth = -(opts.stackDepth or 16)
    local zoneFilter = opts.zone

    local agg: SampleAgg = {}
    local zbuf: {string} = {}
    local paused = false

    -- Zpath cache: only rebuild the slash-joined path when the zone stack
    -- actually changes. The zone controller bumps its version on every push
    -- or pop, so a
    -- constant zone context across samples costs one integer compare.
    -- cachedInner rides alongside cachedZpath so we skip the outer agg
    -- lookup too once the zpath is stable.
    local cachedVersion = -1
    local cachedZpath = ROOT
    local cachedInner: {string: SampleRecord} = nil

    local function callback(th: any, n: integer, vmstate: string)
        if paused then
            return
        end
        local zpath: string
        local inner: {string: SampleRecord}
        if zones.version == cachedVersion then
            zpath = cachedZpath
            inner = cachedInner
        else
            local d = #zone
            if d == 0 then
                zpath = ROOT
            else
                for i = 1, d do
                    zbuf[i] = zone[i]
                end
                zpath = table_concat(zbuf, "/", 1, d)
            end
            inner = agg[zpath]
            if not inner then
                inner = {}
                agg[zpath] = inner
            end
            cachedVersion = zones.version
            cachedZpath = zpath
            cachedInner = inner
        end
        local stack: string
        if th then
            stack = dumpstack(th, "lZ;", stackDepth)
        else
            stack = ""
        end
        local r = inner[stack]
        if not r then
            r = {n = 0, N = 0, I = 0, C = 0, G = 0, J = 0, zpath = zpath, stack = stack}
            inner[stack] = r
        end
        r.n = r.n + n
        if vmstate == "N" then
            r.N = r.N + n
        elseif vmstate == "I" then
            r.I = r.I + n
        elseif vmstate == "C" then
            r.C = r.C + n
        elseif vmstate == "G" then
            r.G = r.G + n
        elseif vmstate == "J" then
            r.J = r.J + n
        end
    end

    zones.acquire()
    profileStart("li" .. string_format("%d", intervalMs), callback)
    sampleActive = true

    LOGGER:info("sample session started (intervalMs=%d, zone=%s)", intervalMs, zoneFilter or "*")

    local session = setmetatable(
        {
            _agg = agg,
            _zoneFilter = zoneFilter,
            _stopped = false,
            _setPaused = function(v: boolean) paused = v end,
        } as profile.SampleSession,
        SAMPLE_MT
    )
    return session
end

function profile.SampleSession:pause()
    local s = self as {string: any}
    if s._stopped then
        error("SampleSession:pause: session already stopped", 2)
    end
    (s._setPaused as function(boolean))(true)
end

function profile.SampleSession:resume()
    local s = self as {string: any}
    if s._stopped then
        error("SampleSession:resume: session already stopped", 2)
    end
    (s._setPaused as function(boolean))(false)
end

local function writeToFile(path: string, text: string)
    local f, err = io.open(path, "w")
    if not f then
        error("profile: cannot write '" .. path .. "': " .. (err or "unknown"), 3)
    end
    local ok, writeErr = f:write(text)
    if not ok then
        f:close()
        error("profile: cannot write '" .. path .. "': " .. (writeErr or "unknown"), 3)
    end
    local closeOk, closeErr = f:close()
    if not closeOk then
        error("profile: cannot close '" .. path .. "': " .. (closeErr or "unknown"), 3)
    end
end

function profile.SampleSession:stop(filename?: string): string
    local s = self as {string: any}
    if s._stopped then
        error("SampleSession:stop: session already stopped", 2)
    end
    s._stopped = true
    profileStop()
    sampleActive = false
    zones.release()
    local filtered = filterByZone(s._agg as SampleAgg, s._zoneFilter as string)
    local text = encodeCollapsed(filtered)
    if filename then
        writeToFile(filename, text)
        LOGGER:info("sample session stopped, %d bytes written to %s", #text, filename)
    else
        LOGGER:info("sample session stopped, %d bytes of collapsed-stack text", #text)
    end
    return text
end

-------------------------------------------------------------------------------
-- Trace channel
-------------------------------------------------------------------------------

local jitAttach <const> = ((_G as {string: any}).jit as {string: any}).attach as function(any, ?string)

-- traceerr (error code -> reason) and bcnames (packed opcode name string) come from jit.vmdef
local vmdef <const> = loadUntyped("jit.vmdef") as {string: any}
local traceerr <const> = vmdef.traceerr as {integer: string}
local bcnames <const> = vmdef.bcnames as string

local funcinfo: function(any, integer): {string: any}
do
    local ok, util = pcall(loadUntyped, "jit.util")
    if ok and util then
        funcinfo = (util as {string: any}).funcinfo as function(any, integer): {string: any}
    end
end

local function bcName(opcode: integer): string
    if not bcnames then
        return string_format("op%d", opcode)
    end
    local idx = opcode * 6 + 1
    local s = bcnames:sub(idx, idx + 5)
    return (s:gsub("%s+$", ""))
end

local function reasonText(otr: integer, oex: any): string
    if not otr then
        return "abort"
    end
    local fmt = traceerr[otr]
    if not fmt then
        return string_format("error %d", otr)
    end
    if fmt:find("NYI: bytecode", 1, true) and type(oex) == "number" then
        return "NYI: bytecode " .. bcName(oex as integer)
    end
    if oex == nil then
        return fmt
    end
    local ok, s = pcall(string_format, fmt, oex)
    if ok then
        return s as string
    end
    return fmt
end

local function classify(reason: string): string
    if reason:find("blacklist", 1, true) then
        return "blacklist"
    end
    if reason:find("leaving loop", 1, true) then
        return "info"
    end
    if reason:find("inner loop", 1, true) then
        return "info"
    end
    if reason:find("down%-recursion") then
        return "info"
    end
    if reason:find("up%-recursion") then
        return "info"
    end
    return "warn"
end

local function severityRank(s: string): integer
    if s == "blacklist" then
        return 0
    end
    if s == "warn" then
        return 1
    end
    return 2
end

-- Lua's short_src prefixes file paths with '@'; debug.getinfo inherits this
-- for function sources. Strip it so report rows read as 'path:line', not
-- '@path:line'. Leaves non-file sources (e.g. '=[C]', '[string "..."]')
-- untouched since those don't start with '@'.
local function trimAt(src: string): string
    if src:sub(1, 1) == "@" then
        return src:sub(2)
    end
    return src
end

local function describeLocation(func: any, pc: integer): string
    if funcinfo and func then
        local ok, fi = pcall(funcinfo, func, pc)
        if ok and fi then
            local src = (fi as {string: any}).short_src or (fi as {string: any}).source or "?"
            local line = (fi as {string: any}).currentline or (fi as {string: any}).linedefined or 0
            return string_format("%s:%d", trimAt(src as string), line as integer)
        end
    end
    if type(func) == "function" then
        local info = debug.getinfo(func as function, "S")
        local src = (info and info.short_src) or "?"
        local line = (info and info.linedefined) or 0
        return string_format("%s:%d", trimAt(src), line)
    end
    return "?:0"
end

-- RFC 4180: quote fields containing comma, quote, CR, or LF; escape embedded quotes by doubling.
-- Only `reason` strings realistically need this.
local function csvField(s: string): string
    if s:find("[,\"\n\r]") then
        return "\"" .. s:gsub("\"", "\"\"") .. "\""
    end
    return s
end

local function serializeTraceReport(r: profile.TraceReport): string
    local lines: {string} = {"severity,count,reason,location,zone"}
    for i = 1, #r.sites do
        local s = r.sites[i]
        lines[#lines + 1] = table_concat(
            {
                s.severity,
                string_format("%d", s.count),
                csvField(s.reason),
                csvField(s.location),
                csvField(s.zone),
            },
            ","
        )
    end
    return table_concat(lines, "\n")
end

local TRACE_REPORT_MT <const>: metatable<profile.TraceReport> = {
    __tostring = function(self: profile.TraceReport): string return serializeTraceReport(self) end,
}

local TRACE_MT <const>: metatable<profile.TraceSession> = {
    __index = profile.TraceSession,
}

local traceActive = false

function profile.trace(opts?: profile.TraceOptions): profile.TraceSession
    if traceActive then
        error("profile.trace: a trace session is already active; call :stop() first", 2)
    end
    opts = opts or {}
    local includeBenign = opts.includeBenign or false

    local sites: {string: profile.AbortSite} = {}
    local counters = {total = 0, black = 0}
    local startTime = os.time()
    local paused = false

    local function callback(what: string, _tr: integer, func: any, pc: integer, otr: integer, oex: any)
        if what ~= "abort" or paused then
            return
        end
        local reason = reasonText(otr, oex)
        local sev = classify(reason)
        if not includeBenign and sev == "info" then
            return
        end

        counters.total = counters.total + 1
        if sev == "blacklist" then
            counters.black = counters.black + 1
        end

        local location = describeLocation(func, pc)
        local zpath = activeZpath()
        local key = sev .. "|" .. reason .. "|" .. location .. "|" .. zpath
        local site = sites[key]
        if site then
            site.count = site.count + 1
        else
            sites[key] = {
                severity = sev,
                count = 1,
                reason = reason,
                location = location,
                zone = zpath,
            }
        end
    end

    zones.acquire()
    jitAttach(callback, "trace")
    traceActive = true

    LOGGER:info("trace session started (includeBenign=%s)", tostring(includeBenign))

    local session = setmetatable(
        {
            _callback = callback,
            _sites = sites,
            _counters = counters,
            _startTime = startTime,
            _stopped = false,
            _setPaused = function(v: boolean) paused = v end,
        } as profile.TraceSession,
        TRACE_MT
    )
    return session
end

function profile.TraceSession:pause()
    local s = self as {string: any}
    if s._stopped then
        error("TraceSession:pause: session already stopped", 2)
    end
    (s._setPaused as function(boolean))(true)
end

function profile.TraceSession:resume()
    local s = self as {string: any}
    if s._stopped then
        error("TraceSession:resume: session already stopped", 2)
    end
    (s._setPaused as function(boolean))(false)
end

function profile.TraceSession:stop(filename?: string): profile.TraceReport
    local s = self as {string: any}
    if s._stopped then
        error("TraceSession:stop: session already stopped", 2)
    end
    s._stopped = true
    jitAttach(s._callback)
    traceActive = false
    zones.release()

    local sites: {profile.AbortSite} = {}
    for _, site in pairs(s._sites as {string: profile.AbortSite}) do
        sites[#sites + 1] = site
    end
    table_sort(
        sites,
        function(a: profile.AbortSite, b: profile.AbortSite): boolean
            local ra, rb = severityRank(a.severity), severityRank(b.severity)
            if ra ~= rb then
                return ra < rb
            end
            if a.count ~= b.count then
                return a.count > b.count
            end
            if a.reason ~= b.reason then
                return a.reason < b.reason
            end
            return a.location < b.location
        end
    )

    local counters = s._counters as {string: integer}
    local report = setmetatable(
        {
            durationSec = os.time() - (s._startTime as number),
            totalAborts = counters.total,
            blacklisted = counters.black,
            sites = sites,
        } as profile.TraceReport,
        TRACE_REPORT_MT
    )
    if filename then
        writeToFile(filename, tostring(report))
        LOGGER:info(
            "trace session stopped (%.2fs, %d aborts, %d blacklisted), report written to %s",
            report.durationSec,
            report.totalAborts,
            report.blacklisted,
            filename
        )
    else
        LOGGER:info(
            "trace session stopped (%.2fs, %d aborts, %d blacklisted)",
            report.durationSec,
            report.totalAborts,
            report.blacklisted
        )
    end
    return report
end

return profile
