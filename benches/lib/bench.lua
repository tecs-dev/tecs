-- bench.lua - Minimal benchmark harness shared across tecs benches.
--
-- Usage:
--   local bench = require("lib.bench")
--   bench.suite({
--       name = "Mutation Pipeline",
--       warmupIterations = 100,
--       iterations = 1000,
--       baseline = "current",  -- optional: variant name for ratio comparisons
--       variants = {
--           {
--               name = "current",
--               setup = function(case) return tecs.ecs.newWorld() end,  -- optional, not measured
--               run = function(state, case) ... end,                -- the measured function
--               teardown = function(state) end,                     -- optional, not measured
--           },
--       },
--       cases = {
--           {name = "1k spawn + commit", data = {count = 1000}},
--       },
--   })
--
-- Each variant is timed against each case. Per-case results show the fastest variant in bold.
-- The summary table shows geometric mean ratios against the baseline variant.

local ffi = require("ffi")

-- High-resolution monotonic clock via clock_gettime. os.clock() has ~1μs resolution
-- on macOS which is too coarse for small iteration measurements. clock_gettime gives
-- ~40ns resolution on typical hardware.
ffi.cdef [[
struct bench_timespec { int64_t tv_sec; long tv_nsec; };
int clock_gettime(int clk_id, struct bench_timespec *tp);
]]
-- CLOCK_MONOTONIC_RAW = 4 on both Linux and macOS, and is more stable than
-- CLOCK_MONOTONIC (not subject to NTP adjustment).
local CLOCK_ID = 4
local _tsBuf = ffi.new("struct bench_timespec")
local function now()
    ffi.C.clock_gettime(CLOCK_ID, _tsBuf)
    return tonumber(_tsBuf.tv_sec) + tonumber(_tsBuf.tv_nsec) / 1e9
end

-- Pre-allocated FFI double array for timing samples -- zero table churn, zero GC
-- pressure. Sized for the max expected iteration count; reused across variants/cases.
local MAX_TIMING_SAMPLES = 100000
local _timesBuf = ffi.new("double[?]", MAX_TIMING_SAMPLES)
local _sortBuf = {} -- plain Lua table for sorting; table.sort works on Lua arrays

local bench = {}

-- Adaptive measurement: runs iterations until at least `minDuration` seconds
-- of sample time have accumulated, giving fast cases many more samples
-- (tighter stats) and slow cases fewer. `maxWall` is the upper bound on total
-- wall time spent in this call, including setup/teardown/GC between iterations
-- -- prevents a case with expensive setup from blocking the whole suite.
-- Returns stats including a 95% confidence interval on the median.
local function measure(variant, case, minDuration, maxWall, microIterations, traceSession)
    local setup = variant.setup
    local run = variant.run
    local teardown = variant.teardown

    local iterations = 0
    local elapsed = 0
    local walltimeStart = now()
    while elapsed < minDuration and (now() - walltimeStart) < maxWall and iterations < MAX_TIMING_SAMPLES do
        local state
        if setup then
            state = setup(case)
        end

        -- Drain garbage from prior iterations (and the setup just above) so
        -- the timed window only pays GC costs that this iteration's own
        -- allocations cause. Without this, p99 is dominated by the roulette
        -- of which iteration happens to trip the GC's allocation threshold
        -- while cleaning up the previous iteration's leftovers.
        collectgarbage("collect")

        -- Bracket the trace session around just the timed window so setup,
        -- GC cleanup, and teardown don't contribute abort events. Caller
        -- passes a paused session; we resume just before the clock starts
        -- and pause again immediately after.
        if traceSession then
            traceSession:resume()
        end
        local startTime = now()
        for _ = 1, microIterations do
            run(state, case)
        end
        local endTime = now()
        if traceSession then
            traceSession:pause()
        end

        if teardown then
            teardown(state)
        end

        _timesBuf[iterations] = (endTime - startTime) / microIterations
        iterations = iterations + 1
        elapsed = elapsed + (endTime - startTime)
    end

    -- Copy FFI samples into a Lua array for sorting, then sort for percentiles.
    -- This allocation is outside the timed region, so it doesn't affect measurements.
    for i = 1, iterations do
        _sortBuf[i] = _timesBuf[i - 1]
    end
    for i = iterations + 1, #_sortBuf do
        _sortBuf[i] = nil
    end
    table.sort(_sortBuf)

    -- Compute mean via Welford-style pass (stable for many samples)
    local mean = 0.0
    local m2 = 0.0
    for i = 1, iterations do
        local sample = _sortBuf[i]
        local delta = sample - mean
        mean = mean + delta / i
        m2 = m2 + delta * (sample - mean)
    end
    local variance = iterations > 1 and m2 / iterations or 0
    local stdev = math.sqrt(variance)

    -- 95% confidence interval on the median: ±1.96 * σ / √n.
    -- Tells the reader "the true p50 is within this range with 95%
    -- probability". Shrinks with √n, so more iterations → tighter CI.
    local ci95 = 1.96 * stdev / math.sqrt(iterations)

    -- Percentile index: ceil(p * n), clamped to [1, n]
    local function pct(p)
        local idx = math.ceil(p * iterations)
        if idx < 1 then
            idx = 1
        end
        if idx > iterations then
            idx = iterations
        end
        return _sortBuf[idx]
    end

    return {
        mean = mean,
        stdev = stdev,
        ci95 = ci95,
        iterations = iterations,
        min = _sortBuf[1],
        max = _sortBuf[iterations],
        p50 = pct(0.50),
        p90 = pct(0.90),
        p99 = pct(0.99),
    }
end

local function formatTimeUs(seconds)
    local us = seconds * 1000000
    if us < 1 then
        return string.format("%.3f", us)
    elseif us < 1000 then
        return string.format("%.1f", us)
    else
        return string.format("%.0f", us)
    end
end

-- Approximate display width: counts ASCII as 1 column, 2/3-byte UTF-8 codepoints
-- (CJK, common symbols) as 1 column, and 4-byte UTF-8 codepoints (supplementary
-- plane -- most emoji) as 2 columns. Good enough for our table cells.
local function displayWidth(s)
    local n = 0
    local i = 1
    local len = #s
    while i <= len do
        local b = string.byte(s, i)
        if b < 0x80 then
            n = n + 1
            i = i + 1
        elseif b < 0xC0 then
            -- continuation byte (shouldn't be a leading byte; skip defensively)
            i = i + 1
        elseif b < 0xE0 then
            n = n + 1
            i = i + 2
        elseif b < 0xF0 then
            n = n + 1
            i = i + 3
        else
            -- 4-byte sequence: supplementary plane, render as 2 columns
            n = n + 2
            i = i + 4
        end
    end
    return n
end

-- Print a markdown table with auto-aligned columns. The row at separatorRow
-- (default 2) is rendered as dashes regardless of its content -- so multi-line
-- headers can pass separatorRow=3 (or higher) and supply a placeholder row
-- whose content will be replaced with dashes.
local function printTable(rows, separatorRow)
    if #rows == 0 then
        return
    end
    separatorRow = separatorRow or 2

    local widths = {}
    for _, row in ipairs(rows) do
        for col, cell in ipairs(row) do
            local w = displayWidth(cell)
            if not widths[col] or w > widths[col] then
                widths[col] = w
            end
        end
    end

    for i, row in ipairs(rows) do
        local parts = {}
        for col, cell in ipairs(row) do
            if i == separatorRow then
                parts[col] = string.rep("-", widths[col])
            else
                parts[col] = cell .. string.rep(" ", widths[col] - displayWidth(cell))
            end
        end
        print("| " .. table.concat(parts, " | ") .. " |")
    end
end

-- Sanitize a name for use in a file path.
local function slug(name)
    local s = name:gsub("[^%w%-]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if s == "" then
        return "unnamed"
    end
    return s
end

function bench.suite(config)
    assert(config.name, "suite requires a name")

    -- Fork-per-pair child dispatch: a single main.lua may declare multiple
    -- suites (e.g. benches/json-bench has Parse + Serialize). The child runs
    -- the whole script, so any suite whose name doesn't match the parent's
    -- target must exit early -- otherwise it would emit a second result line
    -- and corrupt the parent's parser.
    if os.getenv("BENCH_CHILD") == "1" then
        local target = os.getenv("BENCH_CHILD_SUITE")
        if target and target ~= "" and target ~= config.name then
            return
        end
    end

    assert(config.variants and #config.variants > 0, "suite requires at least one variant")
    assert(config.cases and #config.cases > 0, "suite requires at least one case")

    -- Expand case declarations into runtime cases via Cartesian product over
    -- `case.parameters`. A base case with `parameters = {count = {1000, 2000},
    -- defer = {false, true}}` expands into 4 runtime cases; param-free cases
    -- pass through as a single expansion with `case.params = {}`. Expansion
    -- is deterministic: parent and child processes derive the same list, so
    -- BENCH_CASE is the index into this expanded list.
    --
    -- `case.params` is the per-expansion combo visible to scenarios; `case.data`
    -- is preserved as-is (scenarios that read `case.data.count` still work).
    -- When `parameters.count` is set, it overrides `case.data.count` per run.
    local function coerce(s)
        if s == "true" then
            return true
        end
        if s == "false" then
            return false
        end
        local n = tonumber(s)
        if n ~= nil then
            return n
        end
        return s
    end

    local function expandCases(rawCases)
        local expanded = {}
        for baseIdx, case in ipairs(rawCases) do
            local params = case.parameters
            local paramKeys = {}
            if params then
                for k in pairs(params) do
                    paramKeys[#paramKeys + 1] = k
                end
                table.sort(paramKeys)
            end

            local combos = { {} }
            for _, key in ipairs(paramKeys) do
                local values = params[key]
                assert(type(values) == "table" and #values > 0, "parameters." .. key .. " must be a non-empty list")
                local next = {}
                for _, combo in ipairs(combos) do
                    for _, v in ipairs(values) do
                        local copy = {}
                        for kk, vv in pairs(combo) do
                            copy[kk] = vv
                        end
                        copy[key] = v
                        next[#next + 1] = copy
                    end
                end
                combos = next
            end

            for _, combo in ipairs(combos) do
                local name = case.name
                if #paramKeys > 0 then
                    local parts = {}
                    for _, k in ipairs(paramKeys) do
                        parts[#parts + 1] = k .. "=" .. tostring(combo[k])
                    end
                    name = name .. " [" .. table.concat(parts, ", ") .. "]"
                end
                -- Merged data: scenarios can still read case.data.count when
                -- nothing sets `count` in parameters.
                local data = {}
                if case.data then
                    for k, v in pairs(case.data) do
                        data[k] = v
                    end
                end
                for k, v in pairs(combo) do
                    data[k] = v
                end
                expanded[#expanded + 1] = {
                    name = name,
                    scenario = case.scenario,
                    params = combo,
                    data = data,
                    baseIdx = baseIdx,
                }
            end
        end
        return expanded
    end

    local allCases = expandCases(config.cases)

    -- Env-var filtering for targeted profiling runs:
    --   CASE=3                    -- run every expansion of base case #3 (all variants, all params)
    --   PARAMS='k=v,k=v'          -- run only expansions whose params match all given values
    --   VARIANTS=a,b              -- run only the named variants (CSV, whitespace-trimmed)
    -- BENCH_CASE / BENCH_VARIANTS / BENCH_PARAMS are accepted as legacy aliases.
    -- Values are coerced: "true"/"false" → boolean, numeric → number, else string.
    -- A case that lacks a requested param is excluded (filter is "must have param=value").
    --
    -- CASE is the index into `config.cases` (the author-facing declaration
    -- list), NOT the position in the expanded list. A base case with
    -- `parameters = {count = {1000, 2000}}` is still just CASE=N; both its
    -- expansions run. Output tables show the base index in the `#` column,
    -- so the value you see matches what you'd pass back in as CASE.
    local caseFilterEnv = os.getenv("CASE") or os.getenv("BENCH_CASE")
    local caseFilter
    if caseFilterEnv ~= nil and caseFilterEnv ~= "" then
        caseFilter = tonumber(caseFilterEnv)
        assert(caseFilter, "CASE must be a number, got: " .. caseFilterEnv)
        assert(
            caseFilter >= 1 and caseFilter <= #config.cases,
            string.format("CASE=%d out of range (1..%d)", caseFilter, #config.cases)
        )
    end

    local paramsFilter
    local paramsFilterEnv = os.getenv("PARAMS") or os.getenv("BENCH_PARAMS")
    if paramsFilterEnv ~= nil and paramsFilterEnv ~= "" then
        paramsFilter = {}
        -- Tolerate surrounding braces/quotes: `PARAMS='{count=1000,defer=true}'`.
        local body = paramsFilterEnv:gsub("^%s*{%s*", ""):gsub("%s*}%s*$", "")
        for pair in body:gmatch("[^,]+") do
            local k, v = pair:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            assert(k, "PARAMS entry not in k=v form: " .. pair)
            paramsFilter[k] = coerce(v)
        end
    end

    local variantFilter
    local variantFilterEnv = os.getenv("VARIANTS") or os.getenv("BENCH_VARIANTS")
    if variantFilterEnv ~= nil and variantFilterEnv ~= "" then
        variantFilter = {}
        for name in variantFilterEnv:gmatch("[^,]+") do
            local trimmed = name:match("^%s*(.-)%s*$")
            if trimmed ~= "" then
                variantFilter[trimmed] = true
            end
        end
    end

    -- Apply CASE / PARAMS filters against the expanded list. caseIdxMap[i]
    -- holds the position in `allCases` (used to dispatch children with
    -- BENCH_CHILD_CASE; CSV logging and output tables use case.baseIdx so
    -- the user-visible `#` stays stable across parameter expansion).
    --
    -- Child mode (BENCH_CHILD=1) bypasses CASE/PARAMS and picks exactly one
    -- expanded case by position via BENCH_CHILD_CASE. The parent resolves
    -- base-case + params to a specific expansion and hands off that index.
    local cases = {}
    local caseIdxMap = {}
    local childCaseEnv = os.getenv("BENCH_CHILD_CASE")
    if os.getenv("BENCH_CHILD") == "1" and childCaseEnv and childCaseEnv ~= "" then
        local idx = tonumber(childCaseEnv)
        assert(idx and idx >= 1 and idx <= #allCases, "BENCH_CHILD_CASE out of range: " .. tostring(childCaseEnv))
        cases[1] = allCases[idx]
        caseIdxMap[1] = idx
    else
        for i, case in ipairs(allCases) do
            local ok = true
            if caseFilter and case.baseIdx ~= caseFilter then
                ok = false
            end
            if ok and paramsFilter then
                for k, v in pairs(paramsFilter) do
                    if case.params[k] ~= v then
                        ok = false
                        break
                    end
                end
            end
            if ok then
                cases[#cases + 1] = case
                caseIdxMap[#cases] = i
            end
        end
    end
    assert(#cases > 0, "no cases to run after CASE / PARAMS filters")

    local variants = {}
    for _, variant in ipairs(config.variants) do
        if not variantFilter or variantFilter[variant.name] then
            variants[#variants + 1] = variant
        end
    end
    assert(#variants > 0, "no variants to run after BENCH_VARIANTS filter")
    if variantFilter then
        for name in pairs(variantFilter) do
            local found = false
            for _, v in ipairs(variants) do
                if v.name == name then
                    found = true
                    break
                end
            end
            assert(found, "BENCH_VARIANTS includes unknown variant: " .. name)
        end
    end

    local warmupIterations = config.warmupIterations or 100
    local minDuration = config.minDuration or 0.5
    -- Upper bound on wall time per (case, variant) measurement. Caps total
    -- time spent iterating even if the sample budget hasn't been reached -- a
    -- case with heavy setup/teardown can easily burn 30s of wall time for 1s
    -- of sample time otherwise. Default generous (20× minDuration or 30s,
    -- whichever is larger) so existing fast suites aren't affected.
    local maxDuration = config.maxDuration or math.max(minDuration * 20, 30)
    local microIterations = config.microIterations or 1

    -- Profiling: if SAMPLE=<path> (or legacy BENCH_PROFILE_DIR) is set,
    -- sample only during run() (not setup/GC) and write collapsed-stack
    -- output. Uses tecs.utils.profile.sample() which tags samples with the
    -- active zone path.
    --
    --   SAMPLE=~/foo.csv + single scheduled pair     -- exact path
    --   SAMPLE=~/out                                 -- dir → <dir>/<variant>__<case>.collapsed per pair
    --   SAMPLE=~/runs/run.csv + multiple pairs       -- suffix inserted before extension per pair
    --
    -- "Single pair" counts expansions too: `CASE=3` on a base case with 4
    -- parameter combinations schedules 4 pairs per variant, so file mode adds
    -- a per-permutation suffix (the slug of the expanded case name, which
    -- includes the `[k=v, k=v]` param stamp).
    local sampleRaw = os.getenv("SAMPLE") or os.getenv("BENCH_PROFILE_DIR")
    if sampleRaw == "" then
        sampleRaw = nil
    end
    if sampleRaw == "true" or sampleRaw == "1" then
        local base = os.tmpname()
        os.remove(base)
        sampleRaw = base .. "-tecs-sample"
    end
    local sampleIntervalMs = tonumber(os.getenv("SAMPLE_INTERVAL_MS") or "1")
    local sampleZone = os.getenv("SAMPLE_ZONE")
    if sampleZone == "" then
        sampleZone = nil
    end

    -- Resolve the output path for the pair currently being profiled. When
    -- SAMPLE is a file path (basename contains a dot), use it directly for a
    -- single pair; otherwise insert "-<variant>__<case>" before the extension.
    -- When SAMPLE is a bare directory, auto-generate .collapsed filenames.
    local sampleIsFile = false
    if sampleRaw then
        local base = sampleRaw:match("([^/]+)$") or sampleRaw
        sampleIsFile = base:find("%.") ~= nil
        if not sampleIsFile then
            os.execute("mkdir -p " .. sampleRaw)
        else
            local parent = sampleRaw:match("^(.*)/[^/]+$")
            if parent and parent ~= "" then
                os.execute("mkdir -p " .. parent)
            end
        end
    end

    local function resolveSamplePath(variantName, caseName, nPairs)
        if not sampleIsFile then
            return sampleRaw .. "/" .. slug(variantName) .. "__" .. slug(caseName) .. ".collapsed"
        end
        if nPairs == 1 then
            return sampleRaw
        end
        -- Multi-pair file mode: insert disambiguator before the final ".ext".
        local stem, ext = sampleRaw:match("^(.*)(%.[^./]+)$")
        if not stem then
            return sampleRaw .. "-" .. slug(variantName) .. "__" .. slug(caseName)
        end
        return stem .. "-" .. slug(variantName) .. "__" .. slug(caseName) .. ext
    end

    -- Fork-per-pair isolation: each (case, variant) runs in a fresh LuaJIT
    -- process so that JIT traces, GC heap growth, and internal pool state from
    -- earlier pairs can't pollute later measurements. BENCH_CHILD=1 selects the
    -- one-shot child path below; the parent re-execs this same script with
    -- BENCH_CHILD / BENCH_CASE / BENCH_VARIANTS set once per pair.
    local isChild = os.getenv("BENCH_CHILD") == "1"

    if isChild then
        assert(#cases == 1, "BENCH_CHILD=1 requires BENCH_CHILD_CASE to resolve to exactly one case")
        assert(#variants == 1, "BENCH_CHILD=1 requires BENCH_VARIANTS to resolve to exactly one variant")

        local case = cases[1]
        local variant = variants[1]

        -- Warmup runs first (no trace diagnostics attached -- warmup is
        -- expected to compile traces, and logging every one would drown out
        -- the measurement-phase events the user actually cares about).
        if os.getenv("TRACE") == "dump-all" then
            require("jit.dump").on(nil, "-")
        end
        for _ = 1, warmupIterations do
            local warmState
            if variant.setup then
                warmState = variant.setup(case)
            end
            variant.run(warmState, case)
            if variant.teardown then
                variant.teardown(warmState)
            end
        end

        -- Optional JIT trace diagnostics, scoped to the measurement phase.
        -- Uses tecs.utils.profile's trace session which aggregates aborts by
        -- (severity, reason, location, zone) -- no repeated "[TRACE 118 start]"
        -- spam, just a sorted report of unique abort sites.
        --
        -- TRACE=1: aborts only (severity: blacklist/warn).
        -- TRACE=v: include benign trace-formation events (leaving loop,
        --   down-recursion, etc) for deeper debugging.
        -- TRACE=dump: jit.dump (full IR + machine code, very noisy).
        local traceMode = os.getenv("TRACE")
        local traceSession
        if traceMode == "1" or traceMode == "v" then
            local profile = require("tecs.utils.profile")
            traceSession = profile.trace({ includeBenign = traceMode == "v" })
            -- Start paused so setup/teardown/GC between measured iterations
            -- don't pollute the aggregated report. measure() resumes and
            -- pauses around each timed run() window.
            traceSession:pause()
        elseif traceMode == "dump" then
            require("jit.dump").on(nil, "-")
        end

        -- Normal measurement pass (not profiled -- profiler overhead would skew timings)
        local r = measure(variant, case, minDuration, maxDuration, microIterations, traceSession)

        -- Stop trace diagnostics before the optional profiling pass below so
        -- its extra iterations don't contaminate the report. Emit the CSV
        -- report to stderr tagged with the case/variant name.
        if traceSession then
            local report = traceSession:stop()
            if report.totalAborts > 0 or report.blacklisted > 0 then
                io.stderr:write(
                    string.format(
                        "--- TRACE report (case '%s', variant '%s'): %d aborts, %d blacklisted in %.2fs ---\n",
                        case.name,
                        variant.name,
                        report.totalAborts,
                        report.blacklisted,
                        report.durationSec
                    )
                )
                io.stderr:write(tostring(report))
                io.stderr:write("--- end TRACE report ---\n")
                io.stderr:flush()
            end
        end
        if traceMode == "dump" then
            require("jit.dump").off()
        end

        -- Optional sampling pass: produce a collapsed-stack profile covering
        -- just the run() windows. Uses profile.sample with pause/resume so
        -- setup/GC/teardown don't contribute samples.
        if sampleRaw then
            local profile = require("tecs.utils.profile")
            local sampleSession = profile.sample({
                intervalMs = sampleIntervalMs,
                zone = sampleZone,
            })
            sampleSession:pause()

            for _ = 1, r.iterations do
                local state
                if variant.setup then
                    state = variant.setup(case)
                end
                -- Match measure()'s behavior so sampling isn't skewed by
                -- cross-iteration GC cleanup.
                collectgarbage("collect")
                sampleSession:resume()
                for _ = 1, microIterations do
                    variant.run(state, case)
                end
                sampleSession:pause()
                if variant.teardown then
                    variant.teardown(state)
                end
            end

            -- Use the parent's total-pair count when running as a child. The
            -- local #cases * #variants is always 1 in child mode, so without
            -- this we'd collapse all permutations to the same output path.
            local nPairs = tonumber(os.getenv("BENCH_TOTAL_PAIRS")) or (#cases * #variants)
            local profilePath = resolveSamplePath(variant.name, case.name, nPairs)
            sampleSession:stop(profilePath)
        end

        -- Memory measurement: one clean setup+run to capture the peak working
        -- set. GC BEFORE run establishes a clean baseline; NO GC after run so
        -- we see the full live set including temporaries (staging buffers,
        -- reallocated columns, etc.) that a real frame would also hold.
        local memKb = 0
        do
            local state
            if variant.setup then
                state = variant.setup(case)
            end
            collectgarbage("collect")
            collectgarbage("collect")
            local memBefore = collectgarbage("count")
            for _ = 1, microIterations do
                variant.run(state, case)
            end
            memKb = collectgarbage("count") - memBefore
            if variant.teardown then
                variant.teardown(state)
            end
        end

        -- Emit result line for the parent via the BENCH_RESULT_FILE the
        -- parent set up. Keeps stdout/stderr free for user output (prints,
        -- jit.v, tracebacks) to pass through to the terminal unmolested.
        -- %.17g preserves full double precision so aggregation in the parent
        -- is bit-identical to what we measured here.
        local resultPath = assert(
            os.getenv("BENCH_RESULT_FILE"),
            "BENCH_CHILD=1 requires BENCH_RESULT_FILE to point at a writable path"
        )
        local rf = assert(io.open(resultPath, "w"))
        rf:write(
            string.format(
                "__BENCH_RESULT__ min=%.17g p50=%.17g p90=%.17g p99=%.17g mean=%.17g stdev=%.17g ci95=%.17g max=%.17g n=%d memKb=%.17g\n",
                r.min,
                r.p50,
                r.p90,
                r.p99,
                r.mean,
                r.stdev,
                r.ci95,
                r.max,
                r.iterations,
                memKb
            )
        )
        rf:close()
        return
    end

    -- Parent mode: print header and orchestrate child processes.
    print("\n## " .. config.name .. "\n")
    print(
        string.format(
            "Warmup: %d iterations | Measured: adaptive (min %.1fs, max %.1fs wall) | Micro: %d run/iter",
            warmupIterations,
            minDuration,
            maxDuration,
            microIterations
        )
    )
    if sampleRaw then
        print(
            string.format(
                "Sampling: %s (interval=%dms%s)",
                sampleRaw,
                sampleIntervalMs,
                sampleZone and (", zone=" .. sampleZone) or ""
            )
        )
    end
    print("Isolation: fresh LuaJIT process per (case, variant)\n")

    -- Locate the LuaJIT binary to re-exec. BENCH_LUAJIT takes precedence; then
    -- arg[-1] (set by LuaJIT to the interpreter name/path used to start this
    -- script); else fall back to "luajit" on PATH.
    local luajit = os.getenv("BENCH_LUAJIT") or arg[-1] or "luajit"

    -- Wrap a string in single quotes with embedded-quote escaping -- the standard
    -- POSIX shell idiom: '…' stays literal, '\'' closes/escapes/reopens.
    local function shellEscape(s)
        return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
    end

    -- results[variantName][caseName] = {min, p50, p90, p99, mean, stdev, max}
    local results = {}
    for _, variant in ipairs(variants) do
        results[variant.name] = {}
    end

    local suiteStart = now()
    local hasMultipleVariants = #variants > 1

    for i, case in ipairs(cases) do
        local expandedIdx = caseIdxMap[i]
        local baseIdx = case.baseIdx

        -- Streaming progress shows "expanded_pos/total_expansions" so the user
        -- sees forward progress through all scheduled runs. The `#` column in
        -- the summary table below uses the BASE case index instead, matching
        -- what the user would pass back as CASE.
        io.write(string.format("%d.%d/%d: ", baseIdx, expandedIdx, #allCases))
        io.flush()

        local first = true
        for _, variant in ipairs(variants) do
            -- Children inherit the parent env (so BENCH_PROFILE_DIR, EVOLVED_PATH,
            -- TRACE, etc. carry through); we only override the selection vars
            -- and hand off a result path via BENCH_RESULT_FILE. BENCH_CHILD_CASE
            -- (the position in the expanded list) is the authoritative selector
            -- for the child -- the child uses it to pick one expanded case and
            -- skips CASE/PARAMS filtering.
            local resultFile = os.tmpname()
            local totalPairs = #cases * #variants
            local cmd = string.format(
                "BENCH_CHILD=1 BENCH_CHILD_SUITE=%s BENCH_CHILD_CASE=%d BENCH_VARIANTS=%s BENCH_RESULT_FILE=%s BENCH_TOTAL_PAIRS=%d %s %s",
                shellEscape(config.name),
                expandedIdx,
                shellEscape(variant.name),
                shellEscape(resultFile),
                totalPairs,
                shellEscape(luajit),
                shellEscape(arg[0])
            )

            local childStart = now()
            local ok = os.execute(cmd)
            local childDuration = now() - childStart

            local rf = io.open(resultFile, "r")
            local line = rf and rf:read("*l") or nil
            if rf then
                rf:close()
            end
            os.remove(resultFile)

            if not line or not line:find("__BENCH_RESULT__", 1, true) then
                io.write("\n")
                io.flush()
                error(
                    string.format(
                        "bench: child did not emit a result line (exit=%s, case='%s', variant='%s')",
                        tostring(ok),
                        case.name,
                        variant.name
                    )
                )
            end

            local r = {}
            for key, val in line:gmatch("([%w_]+)=([%-%+%d%.eE]+)") do
                r[key] = tonumber(val)
            end
            results[variant.name][case.name] = r

            -- Stream this variant's result inline. Winner info is appended
            -- once all variants for the case have reported p50.
            if not first then
                io.write(" | ")
            end
            first = false
            io.write(string.format("%s[p50=%s, t=%.1fs]", variant.name, formatTimeUs(r.p50), childDuration))
            io.flush()
        end

        if hasMultipleVariants then
            local winnerName, winnerP50 = nil, math.huge
            local runnerUpP50 = math.huge
            for _, variant in ipairs(variants) do
                local p = results[variant.name][case.name].p50
                if p < winnerP50 then
                    runnerUpP50 = winnerP50
                    winnerP50 = p
                    winnerName = variant.name
                elseif p < runnerUpP50 then
                    runnerUpP50 = p
                end
            end
            if winnerName and winnerP50 > 0 and runnerUpP50 ~= math.huge and runnerUpP50 > 0 then
                io.write(string.format(" | winner=%s:%.2fx", winnerName, runnerUpP50 / winnerP50))
            elseif winnerName then
                io.write(string.format(" | winner=%s", winnerName))
            end
        end
        io.write("\n")
        io.flush()
    end

    -- Per-case results table. Each cell shows aligned "min / p50 / p99" in μs.
    -- min: noise floor (most stable across runs)
    -- p50: typical case (median, robust to outliers)
    -- p99: tail latency (catches GC pauses, JIT recompilation)
    -- Fastest variant comparison uses p50 since it's the most stable "typical" measure.
    print("\n### Per-case timings μs\n")

    -- Compute per-variant max widths for the three sub-columns so the slashes
    -- and digits line up vertically inside each variant's column.
    local cellWidths = {}
    for _, variant in ipairs(variants) do
        local mw, pw, qw, sw = 3, 3, 3, 1 -- min widths for "min", "p50", "p99", "±ci95"
        for _, case in ipairs(cases) do
            local r = results[variant.name][case.name]
            local ms = formatTimeUs(r.min)
            local ps = formatTimeUs(r.p50)
            local qs = formatTimeUs(r.p99)
            local ss = formatTimeUs(r.ci95 or r.stdev)
            if #ms > mw then
                mw = #ms
            end
            if #ps > pw then
                pw = #ps
            end
            if #qs > qw then
                qw = #qs
            end
            if #ss > sw then
                sw = #ss
            end
        end
        cellWidths[variant.name] = { min = mw, p50 = pw, p99 = qw, ci = sw }
    end

    local function formatCell(variantName, minStr, p50Str, ciStr, p99Str)
        local w = cellWidths[variantName]
        return string.format(
            "%" .. w.min .. "s  %" .. w.p50 .. "s ±%" .. w.ci .. "s  %" .. w.p99 .. "s",
            minStr,
            p50Str,
            ciStr,
            p99Str
        )
    end

    -- Two-row header: variant names, then sub-headers labeling each sub-column.
    -- Leading "#" column holds the ORIGINAL 1-based case index so users can
    -- read it off the table and pass it back via CASE=<n> for targeted re-runs.
    -- Trailing "Winner" column (only when >1 variant) shows the fastest variant
    -- and the percent it beats the runner-up by, e.g. "tecs -37%".
    local header = { "#", "Test" }
    local subHeader = { "", "" }
    for _, variant in ipairs(variants) do
        header[#header + 1] = variant.name
        subHeader[#subHeader + 1] = formatCell(variant.name, "min", "p50", "ci95", "p99")
    end
    if hasMultipleVariants then
        header[#header + 1] = "p50 Winner"
        subHeader[#subHeader + 1] = ""
    end

    local rows = { header, subHeader, {} }
    for i = 1, #header do
        rows[3][i] = ""
    end -- placeholder; printTable replaces with dashes

    for _, case in ipairs(cases) do
        local winnerName, winnerP50 = nil, math.huge
        local runnerUpP50 = math.huge
        if hasMultipleVariants then
            for _, variant in ipairs(variants) do
                local p = results[variant.name][case.name].p50
                if p < winnerP50 then
                    runnerUpP50 = winnerP50
                    winnerP50 = p
                    winnerName = variant.name
                elseif p < runnerUpP50 then
                    runnerUpP50 = p
                end
            end
        end

        local row = { tostring(case.baseIdx), case.name }
        for _, variant in ipairs(variants) do
            local r = results[variant.name][case.name]
            local timeStr = formatCell(
                variant.name,
                formatTimeUs(r.min),
                formatTimeUs(r.p50),
                formatTimeUs(r.ci95 or r.stdev),
                formatTimeUs(r.p99)
            )
            row[#row + 1] = timeStr
        end
        if hasMultipleVariants then
            -- Percent is relative to the runner-up: how much below the
            -- runner-up's p50 the winner's p50 is. Negative by convention
            -- ("tecs -37%" reads as "tecs is 37% below the loser").
            local pct
            if runnerUpP50 > 0 and runnerUpP50 ~= math.huge then
                pct = (winnerP50 - runnerUpP50) / runnerUpP50 * 100
            else
                pct = 0
            end
            row[#row + 1] = string.format("%s %d%%", winnerName, math.floor(pct + 0.5))
        end
        rows[#rows + 1] = row
    end
    printTable(rows, 3)

    -- Summary table (geometric mean against baseline) -- only meaningful with >1 variant
    if hasMultipleVariants and config.baseline then
        local baselineExists = false
        for _, variant in ipairs(variants) do
            if variant.name == config.baseline then
                baselineExists = true
                break
            end
        end
        assert(baselineExists, "baseline variant '" .. config.baseline .. "' not found in variants")

        print("\n### Summary (geometric mean vs " .. config.baseline .. ")\n")

        local summaryRows = { { "Variant", "vs " .. config.baseline }, { "-", "-" } }
        for _, variant in ipairs(variants) do
            if variant.name == config.baseline then
                summaryRows[#summaryRows + 1] = { variant.name, "baseline" }
            else
                -- Group by baseIdx so each base case declaration carries equal
                -- weight regardless of how many parameter expansions it has.
                -- Per base case we geomean across its expansions, then geomean
                -- across base cases for the overall ratio.
                local perBase = {} -- baseIdx → {product, count}
                for _, case in ipairs(cases) do
                    local baselineP50 = results[config.baseline][case.name].p50
                    local variantP50 = results[variant.name][case.name].p50
                    if baselineP50 > 0 and variantP50 > 0 then
                        local b = perBase[case.baseIdx]
                        if not b then
                            b = { product = 1.0, count = 0 }
                            perBase[case.baseIdx] = b
                        end
                        b.product = b.product * (baselineP50 / variantP50)
                        b.count = b.count + 1
                    end
                end
                local outerProduct = 1.0
                local outerCount = 0
                for _, b in pairs(perBase) do
                    outerProduct = outerProduct * (b.product ^ (1.0 / b.count))
                    outerCount = outerCount + 1
                end
                local geomean = outerCount > 0 and outerProduct ^ (1.0 / outerCount) or 1.0
                local label
                if geomean > 1 then
                    label = string.format("%.2fx faster", geomean)
                elseif geomean < 1 then
                    label = string.format("%.2fx slower", 1 / geomean)
                else
                    label = "same"
                end
                summaryRows[#summaryRows + 1] = { variant.name, label }
            end
        end
        printTable(summaryRows)
    end

    -- Memory table: net retained KB per (case, variant) from a single
    -- setup+run cycle. Shown when any result has a non-zero memKb value.
    local hasMemory = false
    for _, variant in ipairs(variants) do
        for _, case in ipairs(cases) do
            if (results[variant.name][case.name].memKb or 0) ~= 0 then
                hasMemory = true
                break
            end
        end
        if hasMemory then
            break
        end
    end

    if hasMemory then
        print("\n### Memory (peak KB allocated by a single run, before GC)\n")

        local function formatMem(kb)
            if kb < 1 then
                return string.format("%.2f", kb)
            elseif kb < 1024 then
                return string.format("%.1f", kb)
            else
                return string.format("%.0f", kb)
            end
        end

        local memHeader = { "#", "Test" }
        for _, variant in ipairs(variants) do
            memHeader[#memHeader + 1] = variant.name
        end
        local memRows = { memHeader, {} }
        for i = 1, #memHeader do
            memRows[2][i] = ""
        end

        for _, case in ipairs(cases) do
            local row = { tostring(case.baseIdx), case.name }
            for _, variant in ipairs(variants) do
                row[#row + 1] = formatMem(results[variant.name][case.name].memKb or 0)
            end
            memRows[#memRows + 1] = row
        end
        printTable(memRows)
    end

    -- Append one row per (case, variant) to benches/results/bench-log.csv so
    -- runs accumulate into a queryable history. LABEL env var tags the run
    -- (defaults to the short git SHA, suffixed with "-dirty" if the working
    -- tree has uncommitted changes). A companion compare.lua diffs two labels
    -- out of this log.
    --
    -- Path override: BENCH_LOG=<path> (useful for pointing at a scratch log
    -- while experimenting). BENCH_LOG=- disables the write entirely.
    local logPath = os.getenv("BENCH_LOG")
    if logPath ~= "-" then
        if not logPath or logPath == "" then
            -- Resolve relative to the script rather than CWD so `cd benches/ecs-bench`
            -- and `luajit benches/ecs-bench/main.lua` both land in the same place.
            local scriptDir = arg[0]:match("^(.*)/[^/]+$") or "."
            logPath = scriptDir .. "/../results/bench-log.csv"
        end

        local function capture(cmd)
            local p = io.popen(cmd .. " 2>/dev/null")
            if not p then
                return nil
            end
            local out = p:read("*a") or ""
            p:close()
            return (out:gsub("%s+$", ""))
        end
        local sha = capture("git rev-parse --short HEAD") or ""
        if sha ~= "" then
            local dirty = capture("git status --porcelain")
            if dirty and dirty ~= "" then
                sha = sha .. "-dirty"
            end
        else
            sha = "unknown"
        end
        local label = os.getenv("LABEL")
        if not label or label == "" then
            label = sha
        end
        local iso = os.date("!%Y-%m-%dT%H:%M:%SZ")

        local parent = logPath:match("^(.*)/[^/]+$")
        if parent and parent ~= "" then
            os.execute("mkdir -p " .. shellEscape(parent))
        end

        local probe = io.open(logPath, "r")
        local needsHeader = probe == nil
        if probe then
            probe:close()
        end

        local logFile, err = io.open(logPath, "a")
        if not logFile then
            io.stderr:write("bench: could not open log file " .. logPath .. ": " .. tostring(err) .. "\n")
        else
            if needsHeader then
                logFile:write(
                    "iso,sha,label,suite,case_idx,case_name,variant,min_us,p50_us,p99_us,ci95_us,stdev_us,mean_us,iterations,mem_kb\n"
                )
            end
            -- Quote fields that might contain commas/quotes (case names, suite
            -- names, labels). RFC 4180-ish: double up embedded quotes.
            local function csv(s)
                s = tostring(s)
                if s:find('[,"\n]') then
                    return '"' .. s:gsub('"', '""') .. '"'
                end
                return s
            end
            local rowCount = 0
            for _, case in ipairs(cases) do
                for _, variant in ipairs(variants) do
                    local r = results[variant.name][case.name]
                    logFile:write(
                        string.format(
                            "%s,%s,%s,%s,%d,%s,%s,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%.3f\n",
                            csv(iso),
                            csv(sha),
                            csv(label),
                            csv(config.name),
                            case.baseIdx,
                            csv(case.name),
                            csv(variant.name),
                            (r.min or 0) * 1e6,
                            (r.p50 or 0) * 1e6,
                            (r.p99 or 0) * 1e6,
                            (r.ci95 or 0) * 1e6,
                            (r.stdev or 0) * 1e6,
                            (r.mean or 0) * 1e6,
                            r.iterations or r.n or 0,
                            r.memKb or 0
                        )
                    )
                    rowCount = rowCount + 1
                end
            end
            logFile:close()
            print(string.format("\nAppended %d rows to %s (label: %s)", rowCount, logPath, label))
        end
    end

    local suiteElapsed = now() - suiteStart
    print(string.format("\nTotal time: %.1fs", suiteElapsed))

    return results
end

return bench
