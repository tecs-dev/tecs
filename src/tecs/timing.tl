--- Per-stage frame timing, for judging a change to the frame's structure.
---
--- Off unless `TECS_TIMING` is set, and one boolean test per stage when it is,
--- so the default path is the path that ships.
---
--- Samples are retained per frame rather than accumulated, because a mean
--- cannot support a claim about a tail and the tail is usually half of what a
--- frame-structure change is argued about. They live in an FFI array sized
--- once, so a measured run allocates nothing per frame.
---
--- Stages are registered rather than enumerated here, so the threaded pipeline
--- adds `packetWait` where it happens rather than in a list somewhere else.

local ffi <const> = require("ffi")
local clock <const> = require("tecs.platform.clock")

local record timing
    --- Whether anything is being recorded. Read it before doing work that
    --- exists only to be measured.
    enabled: boolean

    --- True when recording was asked for through the environment rather than
    --- by a caller. The frame loop reports at shutdown only in that case: a
    --- benchmark turns recording on itself and prints its own block, and two
    --- copies of the same table is worse than none.
    auto: boolean

    record Stage
        name: string
        samples: any
        count: integer
        capacity: integer
    end

    record Report
        name: string
        --- Milliseconds.
        p50: number
        p95: number
        p99: number
        mean: number
        max: number
        frames: integer
    end
end

--- Frames retained per stage. A bench measures hundreds; the ceiling exists so
--- a long session cannot grow without bound.
local CAPACITY <const> = math.floor(
    tonumber(os.getenv("TECS_TIMING_SAMPLES")) or 65536) as integer

timing.enabled = os.getenv("TECS_TIMING") ~= nil
timing.auto = timing.enabled

local stages: {timing.Stage} = {}
local byName: {string: timing.Stage} = {}

--- Names a stage and returns the handle `mark` takes.
---
--- Registering an unknown stage while disabled is still allowed and still
--- returns a handle, so a caller holds one unconditionally and branches on
--- `timing.enabled` at the point of measurement rather than at setup.
function timing.stage(name: string): timing.Stage
    local existing = byName[name]
    if existing ~= nil then return existing end

    local stage: timing.Stage = {
        name = name,
        samples = timing.enabled and ffi.new("double[?]", CAPACITY) or nil,
        count = 0,
        capacity = timing.enabled and CAPACITY or 0,
    }
    stages[#stages + 1] = stage
    byName[name] = stage
    return stage
end

--- Turns recording on, for a caller whose whole purpose is to measure.
---
--- Stages registered while it was off hold no storage, so they are given some
--- here. A benchmark calls this rather than requiring its runner to remember
--- an environment variable.
function timing.enable()
    if timing.enabled then return end
    timing.enabled = true
    for index = 1, #stages do
        local stage = stages[index]
        stage.samples = ffi.new("double[?]", CAPACITY)
        stage.capacity = CAPACITY
        stage.count = 0
    end
end

--- Records one frame's seconds for a stage.
---
--- Past capacity the sample is dropped rather than wrapping, so a long run
--- reports its beginning honestly instead of an arbitrary window of it.
function timing.mark(stage: timing.Stage, seconds: number)
    if not timing.enabled then return end
    local count = stage.count
    if count >= stage.capacity then return end
    (stage.samples as {integer: number})[count] = seconds
    stage.count = count + 1
end

--- Starts a span. Returns the value `finish` subtracts from.
function timing.begin(): number
    if not timing.enabled then return 0.0 end
    return clock.now()
end

--- Ends a span opened by `begin`, records it, and returns its seconds.
---
--- The return exists for a caller that needs the value as well as the record,
--- such as one stage that has to be subtracted out of another.
function timing.finish(stage: timing.Stage, started: number): number
    if not timing.enabled then return 0.0 end
    local elapsed = clock.now() - started
    timing.mark(stage, elapsed)
    return elapsed
end

--- Discards what has been recorded. A bench calls this after warmup, so the
--- frames that built the scene are not in the distribution of frames that ran
--- it.
function timing.reset()
    for index = 1, #stages do stages[index].count = 0 end
end

local sorted: {number} = {}

--- Reads a percentile from an already sorted list.
local function percentile(count: integer, fraction: number): number
    local at = math.floor(count * fraction)
    if at < 1 then at = 1 end
    if at > count then at = count end
    return sorted[at]
end

--- Every stage that recorded a frame, in registration order.
function timing.report(): {timing.Report}
    local out: {timing.Report} = {}
    for index = 1, #stages do
        local stage = stages[index]
        local count = stage.count
        if count > 0 then
            local samples = stage.samples as {integer: number}
            local total = 0.0
            for sample = 1, count do
                local value = samples[sample - 1]
                sorted[sample] = value
                total = total + value
            end
            for extra = count + 1, #sorted do sorted[extra] = nil end
            table.sort(sorted)

            out[#out + 1] = {
                name = stage.name,
                p50 = percentile(count, 0.50) * 1000.0,
                p95 = percentile(count, 0.95) * 1000.0,
                p99 = percentile(count, 0.99) * 1000.0,
                mean = total / count * 1000.0,
                max = sorted[count] * 1000.0,
                frames = count,
            }
        end
    end
    return out
end

--- The report as fixed-width columns, in milliseconds.
---
--- One block from one place, so two runs of a bench diff against each other
--- rather than being read side by side and compared by eye.
function timing.format(): string
    local report = timing.report()
    if #report == 0 then return "" end

    local lines: {string} = {
        ("%-12s %8s %8s %8s %8s %8s %7s")
            :format("stage", "p50", "p95", "p99", "mean", "max", "frames"),
        ("%s %s %s %s %s %s %s"):format(("-"):rep(12), ("-"):rep(8),
            ("-"):rep(8), ("-"):rep(8), ("-"):rep(8), ("-"):rep(8), ("-"):rep(7)),
    }
    for index = 1, #report do
        local row = report[index]
        lines[#lines + 1] = ("%-12s %8.3f %8.3f %8.3f %8.3f %8.3f %7d")
            :format(row.name, row.p50, row.p95, row.p99, row.mean, row.max,
                    row.frames)
    end
    return table.concat(lines, "\n")
end

return timing
