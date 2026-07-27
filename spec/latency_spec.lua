-- Event to photon.
--
-- The accounting is checked against arithmetic done by hand rather than
-- against a number being positive. A latency measurement that only proves it
-- measured something would survive every mistake worth catching: an off-by-one
-- batch, a segment attributed to the wrong side of the boundary, a frame with
-- no input averaged in.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. package.path

local sdl = require("tecs.ffi.sdl3")
local loader = require("tecs.ffi.loader")
local events = require("tecs.platform.events")
local timing = require("tecs.timing")

local C = sdl.C

--- Stages by name, for the frames that recorded one. A stage that recorded
--- nothing is absent, which is how "no sample" is asserted.
local function stages()
    local byName = {}
    for _, row in ipairs(timing.report()) do byName[row.name] = row end
    return byName
end

--- Milliseconds, to a tolerance that catches an accounting mistake and not the
--- last bits of a subtraction of two large seconds values.
local function isMs(expected, actual, what)
    assert.is_true(math.abs(expected - actual) < 1e-6,
        ("%s: expected %.9f ms, got %.9f ms"):format(what, expected, actual))
end

describe("input latency", function()
    local wasEnabled

    before_each(function()
        wasEnabled = timing.enabled
        timing.enable()
        timing.reset()
    end)

    after_each(function()
        timing.reset()
        timing.enabled = wasEnabled
    end)

    it("splits one event's wait into segments that sum to the whole", function()
        -- Arrival at 100.000, the step that took it starts at 100.010, ends
        -- and starts drawing at 100.014, and submits at 100.020.
        timing.inputArrived(100.000)
        timing.inputConsumed(100.010)
        timing.inputPresented(100.014, 100.020)

        local report = stages()
        isMs(10.0, report.latencyWait.mean, "arrival to the step taking it")
        isMs(4.0, report.latencyStep.mean, "the step itself")
        isMs(6.0, report.latencyDraw.mean, "drawing what the step produced")
        isMs(20.0, report.latency.mean, "the whole interval")

        -- Attribution is only worth anything if the parts account for all of
        -- it, so the sum is part of the contract rather than a coincidence.
        isMs(report.latency.mean,
            report.latencyWait.mean + report.latencyStep.mean
                + report.latencyDraw.mean, "the segments")

        assert.are.equal(1, report.latency.frames)
    end)

    it("measures from the oldest event in the batch", function()
        -- A batch held back an extra step shows up in its oldest event first,
        -- so that is the one the frame is charged for.
        timing.inputArrived(50.000)
        timing.inputArrived(50.004)
        timing.inputArrived(50.002)
        timing.inputConsumed(50.008)
        timing.inputPresented(50.009, 50.010)

        local report = stages()
        isMs(8.0, report.latencyWait.mean, "the oldest event's wait")
        isMs(10.0, report.latency.mean, "the whole interval")
    end)

    it("records nothing for a frame that consumed no event", function()
        timing.inputConsumed(10.000)
        timing.inputPresented(10.004, 10.008)

        -- A frame nobody was waiting on has no latency. Recording a zero for
        -- it would pull every percentile down and mean nothing.
        assert.is_nil(stages().latency)
    end)

    it("charges each event to exactly one frame", function()
        timing.inputArrived(1.000)
        timing.inputConsumed(1.002)
        timing.inputPresented(1.003, 1.006)

        -- The next step took no new input, so the event already accounted for
        -- is not counted again.
        timing.inputConsumed(1.020)
        timing.inputPresented(1.021, 1.024)

        timing.inputArrived(1.030)
        timing.inputConsumed(1.034)
        timing.inputPresented(1.035, 1.040)

        local report = stages()
        assert.are.equal(2, report.latency.frames)
        isMs(8.0, report.latency.mean, "6 ms and 10 ms, averaged")
        isMs(6.0, report.latency.p50, "the smaller of two samples")
        isMs(10.0, report.latency.max, "the larger of two samples")
    end)

    it("drops a sample whose frame never reached the display", function()
        -- No swapchain image, so nothing was presented and the step that took
        -- the event produced no frame to measure to.
        timing.inputArrived(2.000)
        timing.inputConsumed(2.001)

        timing.inputArrived(2.020)
        timing.inputConsumed(2.021)
        timing.inputPresented(2.022, 2.025)

        local report = stages()
        assert.are.equal(1, report.latency.frames)
        isMs(5.0, report.latency.mean,
            "the presented frame's own event, not the dropped one")
    end)

    it("carries the host's arrival stamp onto every drained event", function()
        -- The host stamps the performance counter as SDL hands each event
        -- over, in an array beside the queue. What the engine sees has to be
        -- those readings in the units the clock reports, or nothing above can
        -- subtract one from the other.
        local frequency = tonumber(C.SDL_GetPerformanceFrequency())
        local base = tonumber(C.SDL_GetPerformanceCounter())

        local queue = loader.newArray("SDL_Event[?]", 2)
        queue[0].type = C.SDL_EVENT_KEY_DOWN
        queue[0].key.scancode = 44
        queue[1].type = C.SDL_EVENT_KEY_UP
        queue[1].key.scancode = 44

        local arrivals = loader.newArray("uint64_t[?]", 2)
        arrivals[0] = base
        arrivals[1] = base + frequency / 1000

        local seen = {}
        events.drain(queue, 2, function(event)
            seen[#seen + 1] = event.arrival
        end, arrivals)

        assert.are.equal(2, #seen)
        assert.are.equal(base / frequency, seen[1])
        -- One millisecond of counter ticks later, whatever the counter's rate.
        isMs(1.0, (seen[2] - seen[1]) * 1000.0, "the gap between two arrivals")
    end)

    it("leaves arrival unset when no stamps came with the queue", function()
        -- A replayed or hand-built event has no host stamp, and reporting one
        -- anyway would put a fabricated number in the distribution.
        local queue = loader.newArray("SDL_Event[?]", 1)
        queue[0].type = C.SDL_EVENT_KEY_DOWN

        local seen
        events.drain(queue, 1, function(event) seen = event.arrival end)
        assert.is_nil(seen)
    end)

    it("counts player input as input and the platform as not", function()
        assert.is_true(events.isInput("keyDown"))
        assert.is_true(events.isInput("mouseMotion"))
        assert.is_true(events.isInput("controllerAxis"))
        assert.is_true(events.isInput("fingerDown"))

        -- Nobody is waiting on these, so a frame that only saw one has no
        -- latency to report.
        assert.is_false(events.isInput("windowExposed"))
        assert.is_false(events.isInput("quit"))
        assert.is_false(events.isInput("clipboardUpdate"))
        assert.is_false(events.isInput("unknown"))
    end)
end)
