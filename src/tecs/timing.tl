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
---
--- Event to photon is reported as stages too, through the same table. Frame
--- time cannot see input latency, and a pipeline change moves the two in
--- opposite directions often enough that they have to be read together.

local ffi <const> = require("ffi")
local time <const> = require("tecs.platform.time")

--- Per-stage frame timing, for judging a change to the frame's structure.
---
--- Recording is process-wide, not per world, and off unless `TECS_TIMING` is set or a caller
--- calls `enable`. Everything is recorded in seconds and reported in milliseconds, and the
--- clock behind it is monotonic with an arbitrary origin, so a sample is an interval and
--- never a time of day.
local record timing
    --- Whether anything is being recorded. Read it before doing work that
    --- exists only to be measured.
    enabled: boolean

    --- True when recording was asked for through the environment rather than
    --- by a caller. The frame loop reports at shutdown only in that case: a
    --- benchmark turns recording on itself and prints its own block, and two
    --- copies of the same table is worse than none.
    auto: boolean

    --- One named thing being timed, and the frames recorded for it.
    ---
    --- Held by the caller and handed back to `mark` and `finish`, so neither has to look a
    --- name up per frame. There is one stage per name for the life of the process.
    record Stage
        --- The name it was registered under, which is what `report` labels the row with.
        name: string

        --- A `double[?]` of `capacity` seconds values, indexed from 0, holding the first
        --- `count` of them. Nil while nothing has ever been recorded, because a stage
        --- registered with timing off allocates nothing until `enable` gives it storage.
        samples: any

        --- How many frames are recorded, and the index the next one goes at.
        count: integer

        --- How many samples `samples` holds. Zero when the stage has no storage.
        capacity: integer
    end

    --- One stage's distribution over the frames it recorded, as `report` returns it.
    ---
    --- Every duration is milliseconds, not the seconds that went in. Percentiles are
    --- nearest-rank off the sorted samples, so each is a sample that was actually
    --- observed and none is interpolated.
    record Report
        --- The stage's name.
        name: string
        --- Milliseconds.
        p50: number
        --- Milliseconds.
        p95: number
        --- Milliseconds.
        p99: number
        --- Milliseconds. The arithmetic mean over every recorded frame.
        mean: number
        --- Milliseconds. The slowest frame recorded, not a percentile.
        max: number
        --- Frames the row is computed from, which is at least one and is capped by the
        --- stage's capacity, so a run longer than that describes its beginning.
        frames: integer
    end
end

--- Frames retained per stage. A bench measures hundreds; the ceiling exists so
--- a long session cannot grow without bound.
local CAPACITY <const> = math.floor(tonumber(os.getenv("TECS_TIMING_SAMPLES")) or 65536) as integer

timing.enabled = os.getenv("TECS_TIMING") ~= nil
timing.auto = timing.enabled

local stages: {timing.Stage} = {}
local byName: {string: timing.Stage} = {}

--- Names a stage and returns the handle `mark` takes.
---
--- Registering an unknown stage while disabled is still allowed and still
--- returns a handle, so a caller holds one unconditionally and branches on
--- `timing.enabled` at the point of measurement rather than at setup.
---
--- @param name What a report row is labelled with. Registering a name twice returns the
---     first stage rather than making a second, so two callers timing the same thing share
---     one distribution.
--- @return The same object on every call for a name, and it lives as long as the process.
function timing.stage(name: string): timing.Stage
    local existing = byName[name]
    if existing ~= nil then
        return existing
    end

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
    if timing.enabled then
        return
    end
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
---
--- @param seconds A duration in seconds, which the report scales to milliseconds. Nothing
---     checks the sign, so a subtraction done the wrong way round is recorded as given.
function timing.mark(stage: timing.Stage, seconds: number)
    if not timing.enabled then
        return
    end
    local count = stage.count
    if count >= stage.capacity then
        return
    end
    (stage.samples as {integer: number})[count] = seconds
    stage.count = count + 1
end

--- Starts a span. Returns the value `finish` subtracts from.
---
--- @return A monotonic reading in seconds, whose origin means nothing on its own. Zero
---     while recording is off, which `finish` then ignores rather than reading as a moment.
function timing.begin(): number
    if not timing.enabled then
        return 0.0
    end
    return time.now()
end

--- Ends a span opened by `begin`, records it, and returns its seconds.
---
--- The return exists for a caller that needs the value as well as the record,
--- such as one stage that has to be subtracted out of another.
---
--- @param started What `begin` returned. A value from anywhere else is not comparable.
--- @return The span in seconds, and zero while recording is off, where nothing was
---     measured and nothing was recorded either.
function timing.finish(stage: timing.Stage, started: number): number
    if not timing.enabled then
        return 0.0
    end
    local elapsed = time.now() - started
    timing.mark(stage, elapsed)
    return elapsed
end

-------------------------------------------------------------------------------
-- Event to photon
-------------------------------------------------------------------------------

--- The interval between SDL handing an event over and the frame that reacted
--- to it being submitted, and the three parts it divides into. They sum to the
--- whole exactly, so a regression is attributable rather than merely visible.
---
--- Moving simulation onto its own thread costs about a frame of `latencyWait`
--- by construction. That is the point of measuring it before the move: frame
--- time does not see the cost at all.
local LATENCY <const> = timing.stage("latency")
--- Arrival to the beginning of the step that took the batch.
local LATENCY_WAIT <const> = timing.stage("latencyWait")
--- That step, up to where the frame it produced starts being drawn.
local LATENCY_STEP <const> = timing.stage("latencyStep")
--- Drawing that frame, up to its submission.
local LATENCY_DRAW <const> = timing.stage("latencyDraw")

--- Arrival of the oldest event no step has taken yet, or nil when no input is
--- pending. The oldest is the batch's worst case, and a batch held back an
--- extra step lengthens it first.
local pendingArrival: number = nil
--- Arrival of the batch the running step took, held until that step's frame is
--- submitted and the sample can be completed.
local takenArrival: number = nil
local consumedAt = 0.0

--- Records an input event arriving, in `time.now` seconds.
---
--- Stamped where the platform handed the event over, not where a step picked
--- it up: the interval between those two is what the measurement exists for.
---
--- @param at A `timing.begin` reading, in seconds. Only the earliest arrival since the last
---     step is kept, so calling this for every event in a burst costs nothing extra.
function timing.inputArrived(at: number)
    if not timing.enabled then
        return
    end
    if pendingArrival == nil or at < pendingArrival then
        pendingArrival = at
    end
end

--- Records a simulation step beginning with the pending batch in hand.
---
--- The pending batch is cleared, so the next step measures the events that
--- arrived after this one rather than counting these twice. A step that takes
--- no input records nothing: a frame nobody was waiting on has no latency, and
--- averaging it in only makes the number smaller.
---
--- @param at A `timing.begin` reading, in seconds, taken where the step starts.
function timing.inputConsumed(at: number)
    if not timing.enabled then
        return
    end
    takenArrival = pendingArrival
    pendingArrival = nil
    consumedAt = at
end

--- Records the frame that step produced being submitted, and completes the
--- sample. `drawStarted` is where simulation ended and drawing began.
---
--- Records nothing at all when the step it belongs to took no input, which is not an error
--- and is the common case in a run nobody is touching.
---
--- @param drawStarted A `timing.begin` reading, in seconds, between the step and the draw.
--- @param at A `timing.begin` reading, in seconds, at submission.
function timing.inputPresented(drawStarted: number, at: number)
    if not timing.enabled then
        return
    end
    local arrival = takenArrival
    if arrival == nil then
        return
    end
    takenArrival = nil

    timing.mark(LATENCY_WAIT, consumedAt - arrival)
    timing.mark(LATENCY_STEP, drawStarted - consumedAt)
    timing.mark(LATENCY_DRAW, at - drawStarted)
    timing.mark(LATENCY, at - arrival)
end

--- Drops the sample a step began and its frame never finished.
---
--- A frame that threw was never submitted, so there is no moment to measure it
--- against. Left in place, the batch it took would be completed by the next
--- frame that did submit and reported as a wait nobody had.
function timing.abandonInput()
    takenArrival = nil
end

--- Discards what has been recorded. A bench calls this after warmup, so the
--- frames that built the scene are not in the distribution of frames that ran
--- it.
function timing.reset()
    for index = 1, #stages do
        stages[index].count = 0
    end
    pendingArrival = nil
    takenArrival = nil
    consumedAt = 0.0
end

local sorted: {number} = {}

--- Reads a percentile from an already sorted list.
local function percentile(count: integer, fraction: number): number
    local at = math.floor(count * fraction)
    if at < 1 then
        at = 1
    end
    if at > count then
        at = count
    end
    return sorted[at]
end

--- Every stage that recorded a frame, in registration order.
---
--- @return A fresh array each call, the caller's to keep. A stage with no frames is left
---     out entirely rather than reported as zeroes, so the array is usually shorter than
---     the number of registered stages and may be empty.
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
            for extra = count + 1, #sorted do
                sorted[extra] = nil
            end
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
---
--- @return A header, a rule and one row per stage, with no trailing newline. The empty
---     string when nothing was recorded, so it can be printed unconditionally.
function timing.format(): string
    local report = timing.report()
    if #report == 0 then
        return ""
    end

    local lines: {string} = {
        ("%-12s %8s %8s %8s %8s %8s %7s"):format("stage", "p50", "p95", "p99", "mean", "max", "frames"),
        ("%s %s %s %s %s %s %s"):format(
            ("-"):rep(12), ("-"):rep(8), ("-"):rep(8), ("-"):rep(8), ("-"):rep(8), ("-"):rep(8), ("-"):rep(7)
        ),
    }
    for index = 1, #report do
        local row = report[index]
        lines[#lines + 1] = ("%-12s %8.3f %8.3f %8.3f %8.3f %8.3f %7d"):format(
            row.name, row.p50, row.p95, row.p99, row.mean, row.max, row.frames
        )
    end
    return table.concat(lines, "\n")
end

return timing
