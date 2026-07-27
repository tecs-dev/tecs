-- The frame coordinator between the thread that simulates and the thread that
-- owns the window.
--
-- What these tests are about is the sequencing and the blocking, so most of
-- them drive the pipeline from two threads at once. A coordinator whose slot
-- states are stepped through in order on one thread proves nothing: the defects
-- worth catching here are a consumer that reaches a packet before the producer
-- finished writing it, a producer that gets far enough ahead to overwrite one,
-- and a thread left parked when the pipeline stops.
--
-- Threads are real OS threads with their own Lua state, so the pipeline crosses
-- to them as an address and nothing else does. Where a test has to know that a
-- thread is parked rather than merely on its way, it polls the blocked count to
-- a budget instead of waiting a while and assuming.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local ffi = require("ffi")
local sdl = require("tecs.ffi.sdl3")
local workers = require("tecs.workers")
local FramePipeline = require("tecs.FramePipeline")

-- Words a packet carries. Every one of them is stamped with the frame number,
-- so a consumer that reached a slot before publication finished would read a
-- mixture of this frame and the one that used the slot two frames ago.
local WORDS = 16
local PAYLOAD = WORDS * 4

-- Long enough that a wedged thread fails a test rather than hanging the suite.
local ANSWER_MS = 5000
local POLL_MS = 1
local POLLS = ANSWER_MS / POLL_MS

-- Publishes frames as fast as it is allowed to, reporting each one when asked.
local PRODUCER = [[
local ffi = require("ffi")
local workers = require("tecs.workers")
local FramePipeline = require("tecs.FramePipeline")
local self = workers.current()

local task = self:receive()
local pipeline = FramePipeline.wrap(task.address)

local published = 0
for frame = 1, task.frames do
    local payload = pipeline:acquireWrite()
    if payload == nil then
        self:send({ stopped = pipeline:state(), published = published })
        return
    end
    local out = ffi.cast("uint32_t *", payload)
    for word = 0, task.words - 1 do out[word] = frame end
    if not pipeline:publish() then
        self:send({ stopped = pipeline:state(), published = published })
        return
    end
    published = frame
    if task.report then self:send({ published = frame }) end
end
self:send({ done = true, published = published })
]]

-- Takes every packet it is offered and reports what it found in it.
local CONSUMER = [[
local ffi = require("ffi")
local workers = require("tecs.workers")
local FramePipeline = require("tecs.FramePipeline")
local self = workers.current()

local task = self:receive()
local pipeline = FramePipeline.wrap(task.address)

for _ = 1, task.frames do
    local payload, sequence = pipeline:acquireRead()
    if payload == nil then
        self:send({ stopped = pipeline:state() })
        return
    end
    -- Read before the slot is released, because releasing it is what lets the
    -- producer start writing over it.
    local input = ffi.cast("uint32_t *", payload)
    local torn = -1
    for word = 0, task.words - 1 do
        if tonumber(input[word]) ~= sequence then torn = word end
    end
    pipeline:releaseRead()
    self:send({ sequence = sequence, torn = torn })
end
self:send({ done = true })
]]

-- Parks in a blocking read and reports being woken, touching nothing
-- afterwards. What this is for is destroy: a thread that called back into a
-- released pipeline would be testing a use-after-free rather than the wake.
local PARKED = [[
local workers = require("tecs.workers")
local FramePipeline = require("tecs.FramePipeline")
local self = workers.current()

local task = self:receive()
local pipeline = FramePipeline.wrap(task.address)
if pipeline:acquireRead() == nil then
    self:send({ woken = true })
    return
end
self:send({ woken = false })
]]

local function start(source, pipeline, options)
    local worker = workers.spawn({ source = source })
    worker:send({
        address = pipeline:address(),
        words = WORDS,
        frames = options and options.frames or 1,
        report = options and options.report or false,
    })
    return worker
end

-- Waits for `count` callers to be parked inside the pipeline.
--
-- Polled to a budget rather than slept for: what a caller needs to know is
-- that a thread is inside a wait loop, and a thread that has been handed its
-- work but has not reached the pipeline yet is not the same thing.
local function waitUntilBlocked(pipeline, count)
    for _ = 1, POLLS do
        if pipeline:blockedCount() >= count then
            return
        end
        sdl.C.SDL_Delay(POLL_MS)
    end
    error(("only %d of %d callers ever blocked"):format(pipeline:blockedCount(), count))
end

-- How many slots are in each state.
local function census(pipeline)
    local counts = {}
    for slot = 1, pipeline.slotCount do
        local state = pipeline:slotState(slot)
        counts[state] = (counts[state] or 0) + 1
    end
    return counts
end

-- The frame number every word of a packet carries, or nil when they disagree,
-- which is what a packet read before its publication finished looks like.
local function stampOf(payload)
    local input = ffi.cast("uint32_t *", payload)
    local stamp = tonumber(input[0])
    for word = 1, WORDS - 1 do
        if tonumber(input[word]) ~= stamp then
            return nil
        end
    end
    return stamp
end

describe("FramePipeline", function()
    describe("creation", function()
        it("refuses a pipeline whose packets carry nothing", function()
            assert.is_false(pcall(FramePipeline.create, 0))
        end)

        it("reports what it was built to carry", function()
            local pipeline = FramePipeline.create(PAYLOAD)
            assert.are.equal(PAYLOAD, pipeline.payloadSize)
            assert.are.equal(2, pipeline.slotCount)
            pipeline:destroy()
        end)

        it("crosses to another state as an address", function()
            local pipeline = FramePipeline.create(PAYLOAD)
            -- The only thing that can cross: a worker shares no Lua heap with
            -- the state that spawned it, so a handle cannot be sent as cdata.
            local wrapped = FramePipeline.wrap(pipeline:address())
            assert.are.equal(pipeline:address(), wrapped:address())
            assert.are.equal(PAYLOAD, wrapped.payloadSize)

            -- A wrapped pipeline does not own what it points at.
            wrapped:destroy()
            assert.are.equal("running", pipeline:state())
            pipeline:destroy()
        end)
    end)

    describe("slot transitions", function()
        -- Every call in this block is one that cannot block: a slot is free, a
        -- packet is waiting, or the call is one the pipeline refuses outright.
        -- The blocking paths are driven from real threads further down.
        local pipeline

        before_each(function()
            pipeline = FramePipeline.create(PAYLOAD)
        end)

        after_each(function()
            pipeline:destroy()
        end)

        it("walks a slot from free to writing to ready to reading", function()
            assert.are.equal("free", pipeline:slotState(1))
            assert.are.equal("free", pipeline:slotState(2))

            assert.is_not_nil(pipeline:acquireWrite())
            assert.are.equal("writing", pipeline:slotState(1))

            assert.is_true(pipeline:publish())
            assert.are.equal("ready", pipeline:slotState(1))

            local payload, sequence = pipeline:acquireRead()
            assert.is_not_nil(payload)
            assert.are.equal(1, sequence)
            assert.are.equal("reading", pipeline:slotState(1))

            assert.is_true(pipeline:releaseRead())
            assert.are.equal("free", pipeline:slotState(1))
        end)

        it("numbers frames from one, without reusing a number", function()
            for frame = 1, 6 do
                assert.is_not_nil(pipeline:acquireWrite())
                assert.is_true(pipeline:publish())
                local _, sequence = pipeline:acquireRead()
                assert.are.equal(frame, sequence)
                assert.is_true(pipeline:releaseRead())
            end
        end)

        it("writes the second slot while the first is being read", function()
            pipeline:acquireWrite()
            pipeline:publish()
            pipeline:acquireRead()

            -- The point of a second slot: the producer has somewhere to build
            -- the next frame while the consumer still holds this one.
            assert.is_not_nil(pipeline:acquireWrite())
            assert.are.equal("reading", pipeline:slotState(1))
            assert.are.equal("writing", pipeline:slotState(2))
        end)

        it("refuses a second slot for writing", function()
            assert.is_not_nil(pipeline:acquireWrite())
            assert.is_nil(pipeline:acquireWrite(), "a producer holding two frames cannot say which it published")
            assert.are.equal("writing", pipeline:slotState(1))
            assert.are.equal("free", pipeline:slotState(2))
        end)

        it("refuses a second slot for reading", function()
            pipeline:acquireWrite()
            pipeline:publish()

            assert.is_not_nil(pipeline:acquireRead())
            -- Refused rather than waited on, which is why this can be asked on
            -- the one thread at all.
            assert.is_nil((pipeline:acquireRead()))
            assert.are.equal("reading", pipeline:slotState(1))
            assert.are.equal("free", pipeline:slotState(2))
        end)

        it("refuses to publish a slot nobody is writing", function()
            assert.is_false(pipeline:publish())
            assert.are.equal("free", pipeline:slotState(1))

            pipeline:acquireWrite()
            assert.is_true(pipeline:publish())
            assert.is_false(pipeline:publish(), "it was already published")
            assert.are.equal("ready", pipeline:slotState(1))
        end)

        it("refuses to release a slot nobody is reading", function()
            assert.is_false(pipeline:releaseRead())

            pipeline:acquireWrite()
            pipeline:publish()
            pipeline:acquireRead()
            assert.is_true(pipeline:releaseRead())
            assert.is_false(pipeline:releaseRead(), "it was already released")
            assert.are.equal("free", pipeline:slotState(1))
        end)

        it("reports a slot it does not have as free", function()
            assert.are.equal("free", pipeline:slotState(0))
            assert.are.equal("free", pipeline:slotState(99))
        end)
    end)

    describe("stopping", function()
        it("refuses both acquires once it has stopped", function()
            local pipeline = FramePipeline.create(PAYLOAD)
            assert.are.equal("running", pipeline:state())

            pipeline:shutdown()
            assert.are.equal("shuttingDown", pipeline:state())
            assert.is_nil(pipeline:acquireWrite())
            assert.is_nil((pipeline:acquireRead()))
            pipeline:destroy()
        end)

        it("gives back an unpublished slot when it stops mid frame", function()
            local pipeline = FramePipeline.create(PAYLOAD)
            assert.is_not_nil(pipeline:acquireWrite())
            pipeline:shutdown()

            -- Nothing will consume it, so the producer is told rather than left
            -- holding a frame the pipeline has no use for.
            assert.is_false(pipeline:publish())
            assert.are.equal("free", pipeline:slotState(1))
            pipeline:destroy()
        end)

        it("keeps the first reason it stopped for", function()
            local pipeline = FramePipeline.create(PAYLOAD)
            pipeline:shutdown()
            pipeline:shutdown()
            assert.are.equal("shuttingDown", pipeline:state())
            pipeline:destroy()
        end)

        it("lets a crash outrank an orderly shutdown", function()
            local pipeline = FramePipeline.create(PAYLOAD)
            pipeline:shutdown()
            pipeline:crash()
            -- The failure is the part the other thread has to know about.
            assert.are.equal("crashed", pipeline:state())

            pipeline:shutdown()
            assert.are.equal("crashed", pipeline:state())
            pipeline:destroy()
        end)
    end)

    describe("under two threads", function()
        it("delivers every frame in order and none torn", function()
            -- Both sides run flat out, so the producer spends most of the run
            -- back-pressured and the consumer most of it waiting. A packet read
            -- before its publication finished shows up as a torn word, and a
            -- packet dropped or reordered shows up as a sequence that is not
            -- the one expected next.
            local frames = 400
            local pipeline = FramePipeline.create(PAYLOAD)
            local consumer = start(CONSUMER, pipeline, { frames = frames })
            local producer = start(PRODUCER, pipeline, { frames = frames })

            for expected = 1, frames do
                local report = consumer:receive(ANSWER_MS)
                assert.is_not_nil(report, ("nothing arrived for frame %d"):format(expected))
                assert.are.equal(expected, report.sequence, "frames are consumed in the order they were produced")
                assert.are.equal(-1, report.torn, ("frame %d was read part written"):format(expected))
            end

            assert.is_true(consumer:receive(ANSWER_MS).done)
            local finished = producer:receive(ANSWER_MS)
            assert.is_true(finished.done)
            assert.are.equal(frames, finished.published, "the producer blocks rather than dropping a frame")

            assert.are.equal(0, consumer:stop())
            assert.are.equal(0, producer:stop())
            pipeline:destroy()
        end)

        it("lets the producer run exactly one frame ahead", function()
            -- Stepped rather than raced. The producer is told to publish more
            -- frames than are taken from it, and each round asserts that it is
            -- parked, that taking a packet releases exactly one more publish,
            -- and that only one published packet is ever waiting.
            local rounds = 6
            local pipeline = FramePipeline.create(PAYLOAD)
            local producer = start(PRODUCER, pipeline, { frames = rounds + 4, report = true })

            assert.are.equal(1, producer:receive(ANSWER_MS).published)

            for frame = 1, rounds do
                waitUntilBlocked(pipeline, 1)

                local payload, sequence = pipeline:acquireRead()
                assert.is_not_nil(payload)
                assert.are.equal(frame, sequence)
                assert.are.equal(frame, stampOf(payload), "a published packet is complete or invisible")

                local report = producer:receive(ANSWER_MS)
                assert.is_not_nil(report, "taking a packet frees the producer")
                assert.are.equal(frame + 1, report.published, "one packet taken releases one frame, not more")

                -- One slot holds the frame being read, the other holds the only
                -- packet allowed to be waiting behind it.
                local counts = census(pipeline)
                assert.are.equal(1, counts.reading)
                assert.are.equal(1, counts.ready)

                assert.is_true(pipeline:releaseRead())
            end

            pipeline:shutdown()
            assert.are.equal("shuttingDown", producer:receive(ANSWER_MS).stopped)
            assert.are.equal(0, producer:stop())
            pipeline:destroy()
        end)

        it("wakes a producer parked for a slot when it shuts down", function()
            local pipeline = FramePipeline.create(PAYLOAD)
            local producer = start(PRODUCER, pipeline, { frames = 8, report = true })

            assert.are.equal(1, producer:receive(ANSWER_MS).published)
            waitUntilBlocked(pipeline, 1)

            pipeline:shutdown()
            local report = producer:receive(ANSWER_MS)
            assert.is_not_nil(report, "a parked producer has to be woken")
            assert.are.equal("shuttingDown", report.stopped)
            assert.are.equal(1, report.published)

            assert.are.equal(0, producer:stop())
            pipeline:destroy()
        end)

        it("wakes a consumer parked for a packet when it shuts down", function()
            local pipeline = FramePipeline.create(PAYLOAD)
            local consumer = start(CONSUMER, pipeline, { frames = 8 })
            waitUntilBlocked(pipeline, 1)

            pipeline:shutdown()
            local report = consumer:receive(ANSWER_MS)
            assert.is_not_nil(report, "a parked consumer has to be woken")
            assert.are.equal("shuttingDown", report.stopped)

            assert.are.equal(0, consumer:stop())
            pipeline:destroy()
        end)

        it("wakes a producer parked for a slot when it crashes", function()
            local pipeline = FramePipeline.create(PAYLOAD)
            local producer = start(PRODUCER, pipeline, { frames = 8, report = true })

            assert.are.equal(1, producer:receive(ANSWER_MS).published)
            waitUntilBlocked(pipeline, 1)

            pipeline:crash()
            assert.are.equal("crashed", producer:receive(ANSWER_MS).stopped)
            assert.are.equal(0, producer:stop())
            pipeline:destroy()
        end)

        it("wakes a consumer parked for a packet when it crashes", function()
            local pipeline = FramePipeline.create(PAYLOAD)
            local consumer = start(CONSUMER, pipeline, { frames = 8 })
            waitUntilBlocked(pipeline, 1)

            pipeline:crash()
            assert.are.equal("crashed", consumer:receive(ANSWER_MS).stopped)
            assert.are.equal(0, consumer:stop())
            pipeline:destroy()
        end)

        it("wakes every waiter, not only the first", function()
            -- Two threads waiting on the same packet. Waking one of them and
            -- leaving the other parked is the failure this is here for, and it
            -- is invisible with a single waiter.
            local pipeline = FramePipeline.create(PAYLOAD)
            local first = start(PARKED, pipeline)
            local second = start(PARKED, pipeline)
            waitUntilBlocked(pipeline, 2)

            pipeline:shutdown()
            assert.is_true(first:receive(ANSWER_MS).woken)
            assert.is_true(second:receive(ANSWER_MS).woken)

            assert.are.equal(0, first:stop())
            assert.are.equal(0, second:stop())
            pipeline:destroy()
        end)

        it("creates and destroys many without leaving a thread parked", function()
            -- A delta rather than an absolute count: other suites hold
            -- pipelines of their own, and what this asserts is that these
            -- ones went. Each round destroys with a thread parked inside,
            -- which is the case that has to wake it and wait for it to
            -- leave before releasing anything it is standing on.
            local before = FramePipeline.liveCount()

            for round = 1, 16 do
                local pipeline = FramePipeline.create(PAYLOAD)
                assert.are.equal(before + 1, FramePipeline.liveCount())

                local parked = start(PARKED, pipeline)
                waitUntilBlocked(pipeline, 1)

                pipeline:destroy()
                local report = parked:receive(ANSWER_MS)
                assert.is_not_nil(report, ("round %d left a thread parked"):format(round))
                assert.is_true(report.woken)
                assert.are.equal(0, parked:stop())
                assert.are.equal(before, FramePipeline.liveCount())
            end
        end)

        it("destroys once however often it is asked", function()
            local before = FramePipeline.liveCount()
            local pipeline = FramePipeline.create(PAYLOAD)
            pipeline:destroy()
            pipeline:destroy()
            assert.are.equal(before, FramePipeline.liveCount())
        end)
    end)
end)
