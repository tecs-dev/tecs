-- Steady state stays allocation free, to a stated bar.
--
-- A frame that allocates has bought a collection it will pay for later, in
-- some other frame, and the bill arrives as a tail nobody can attribute. The
-- requirement is therefore not "fast enough" but "allocates nothing it does
-- not have to", and a requirement stated that way needs a number and a test
-- that holds it.
--
-- Measuring it is mostly a matter of not being fooled, and each of the
-- following is a way of being wrong that this spec is built out of avoiding.
--
-- **The collector.** `collectgarbage("count")` reports the *heap*, not what
-- was allocated. A collection inside the window frees more than the window
-- allocated and the delta comes back small, or negative, or occasionally
-- smaller for more work. So the collector is stopped for every window here.
-- With it stopped the heap only rises, and the rise is the bytes.
--
-- **The probe.** `collectgarbage` is not compiled by LuaJIT, so a call to it
-- inside the frame aborts the trace that would have covered the frame, and the
-- compiler then spends the run recording and recompiling. Trace objects are
-- heap objects, so that lands in the reading as if it were the frame's. Every
-- window below therefore has both of its heap reads outside every frame it
-- measures.
--
-- **The compiler.** Even with no probe in the frame, this process compiles
-- continuously. Under `busted` the engine runs on a plain `luajit`, which does
-- not reserve the machine-code arena the engine's own binary reserves at
-- startup, so LuaJIT cannot place mcode near the interpreter, flushes its whole
-- trace cache every few dozen frames, and starts again. Measured here: three
-- flushes in a hundred and twenty frames, and eighteen of those frames
-- untouched by the compiler. The frames it did touch carry several kilobytes
-- each of its allocation, and there are far too many of them to discard.
--
-- That last one is what decides the shape of this spec. A frame under `busted`
-- reads thousands of bytes against a true cost of a few hundred, and no
-- arrangement of probes separates the two. So:
--
--  * The frame assertion is a **ceiling**, set well above the true figure, and
--    a check that the figure does not **grow with the world**, which is the
--    part a per-row allocation cannot hide from: a byte a row would be 3.5 KB
--    a frame at the larger count and a hundred times that for a table.
--  * Each piece of the frame path is then measured **on its own**, over enough
--    runs that the compiler's roughly fixed contribution to the window divides
--    away while a per-call allocation survives division unchanged. Extraction
--    and the hierarchy dirty sampler run several thousand times a reading; a
--    two-pass render graph and a compute pass are heavier and run sixty times,
--    with the smallest of four readings kept.
--  * The buffer assertions are exact, because a single call can be read
--    exactly and a one-off recording can be dropped by taking the smallest of
--    three readings.
--  * Three things are **counted rather than weighed**, because each is a
--    single object a frame and would sit under the compiler's noise: the query
--    cursor, the frame object, and the closure the event drain is handed.
--
-- What this deliberately does *not* do is turn the compiler off, which would
-- make every reading here exact. On a process that has already run a device
-- and a scene, `jit.off()` followed by `jit.flush()` leaves LuaJIT reporting
-- `jit.status() == true` and unable to compile anything for the rest of the
-- run: a hot loop in a later spec then measures 23 seconds instead of 0.03 and
-- allocates enough to fail the specs that watch the process size. An exact
-- number is not worth handing the rest of the suite an interpreter.
--
-- `cargo xtask bench alloc` is where the exact figures live. It runs under the
-- engine's own binary, which does reserve the arena, so the compiler settles
-- and better than nine frames in ten come out untouched by it.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs = require("tecs")
local Application = require("tecs.Application")
local Buffer = require("tecs.gpu.Buffer")
local ComputePass = require("tecs.gpu.ComputePass")
local Frame = require("tecs.gpu.Frame")
local PassGraph = require("tecs.gpu.PassGraph")
local time = require("tecs.platform.time")
local components = require("tecs.components")
local ecs = require("tecs.ecs")
local events = require("tecs.platform.events")
local sdl = require("tecs.ffi.sdl3")

local C = sdl.C

local Transform = tecs.Transform
local Tint = components.Tint
local Renderable = components.Renderable

-- Entities the first window draws, and the ones added before the second. The
-- two counts differ by a factor of eight, which is enough that a per-row
-- allocation of a single byte separates them by more than the compiler's own
-- contribution ever does.
local STILL = 512
local EXTRA = 3584

-- Entities that move, in an archetype of their own so only their run is
-- rewritten. One is enough to open the dirty gate, run `writeRun` and make the
-- staging flush encode a copy pass, which is the whole upload path; more would
-- only add rows to a loop this is not measuring.
local MOVERS = 1

-- Frames the reading warms for and then measures over per window. The warmup
-- is long because this file runs after nineteen hundred other specs have
-- filled the trace cache, and the frame path has to be compiled and to stay
-- compiled before a window means anything.
local WARMUP = 150
local FRAMES = 90

-- Windows the frame reading takes, keeping the smallest.
--
-- A trace-cache flush lands wholly inside whichever window it happened in and
-- carries several kilobytes with it, so a single window reads anywhere between
-- the true figure and thirty times it. An allocation the frame makes is in
-- every window and survives the minimum unchanged. Six is what makes a clean
-- window reliable rather than likely, and it is what lets the ceiling above be
-- a number about the engine rather than about the compiler.
local WINDOWS = 6

-- Times extraction's phase is run per reading. Large, because this is what
-- averages the compiler down: its work in a window is roughly fixed, so
-- dividing by four thousand leaves a few bytes a call, while an allocation
-- that happens every call survives division unchanged.
local EXTRACTIONS = 4000

-- Bytes a whole frame may allocate.
--
-- The engine's own figure is 312 to 336 bytes for a still scene, and exactly
-- 144 more for a moving one. Almost none of it is the engine's to give back:
-- SDL hands back nine pointers a frame that have to be held in Lua, and LuaJIT
-- boxes each into 24 bytes of cdata, sinking one or another of them depending
-- on what it has compiled. The 144 is the two staging flushes, which the bar
-- below this one covers exactly. The numbers are in `cargo xtask bench alloc`.
--
-- Under `busted` the same frame reads between 320 bytes and 4 KB as the
-- smallest of `WINDOWS` windows, the difference being the compiler, for the
-- reason in the header. Eight kibibytes is twice the largest reading observed
-- there and below the 9 KB the frame read before the removals this file now
-- covers one at a time. It is not tighter than that because it cannot be: a
-- single window still reads thirty times the truth when a trace-cache flush
-- lands in it, and that is why the assertions after this one measure the frame
-- path a piece at a time rather than leaning on this.
local FRAME_BAR = 8192

-- How much larger the frame is allowed to be at eight times the entities, and
-- the reading the ratio is taken against when the smaller one comes in below
-- it.
--
-- Nothing on the frame path is per-row, so the true answer is one. What stops
-- that being asserted is that both readings are now hundreds of bytes of frame
-- under a few kilobytes of compiler, and the compiler's share does not scale
-- with the world: two readings of 861 and 3223 are the same frame measured
-- twice. So the ratio is taken against a floor rather than against a number
-- that small, which leaves it able to catch what it is for. Anything that
-- walks rows walks 4097 of them at the larger count, and a boxed value on each
-- is a hundred kilobytes.
local LOAD_FACTOR = 2.0
local LOAD_FLOOR = 4096

-- Bytes extraction may allocate per run.
--
-- Extraction allocates nothing: it walks archetype columns, writes into mapped
-- staging, and holds every list it needs across frames. The reading is a few
-- bytes and the bar is not a budget but a margin, set below the smallest thing
-- that could regress it. The query cursor this loop used to allocate every
-- frame reads as 160 here.
local EXTRACT_BAR = 64

-- Bytes the hierarchy dirty sampler may allocate per run.
--
-- `RenderLast` holds one system, the sampler that decides whether relative
-- transforms have to be recomposed. It walks the world's dirty set, and it
-- walks it directly: the iterator `world:dirtyArchetypes` hands out is a
-- closure over three upvalues, built per call, and reads as 208 here. Nothing
-- else in the phase allocates, so the bar is a margin below that rather than a
-- budget.
local SAMPLE_BAR = 64

-- Bytes one execution of a two-pass graph may allocate.
--
-- The floor is three boxed pointers: the command buffer SDL hands back and one
-- handle per begun pass, at 24 bytes each. Everything else a pass is run out of
-- is allocated when the pass is declared. Building it per frame instead is the
-- attachment array, an attachment record per output, the context table, the
-- sampler binding array and the pass object, which for two passes reads as
-- about 700.
local GRAPH_BAR = 192

-- Bytes beginning and ending one compute pass may allocate.
--
-- The floor is two boxed pointers, the command buffer and the pass handle, and
-- it reads as 48. The read-write binding array and the pass object are held
-- rather than allocated, and allocating them instead reads as about 250. The
-- bar sits between the two rather than close to the floor, because a recording
-- that lands in a window this short is worth tens of bytes on its own.
local COMPUTE_BAR = 160

-- Bytes a staging flush may allocate.
--
-- The flush encodes a copy pass and one upload per recorded range. What it is
-- allowed is the cdata SDL's own returns are boxed into, which is 72 and is
-- what it costs today. What it is not allowed is a descriptor allocated per
-- call, which is two more cdata objects every frame for every buffer the
-- renderer owns and reads as 136. The bar is one box above the first and well
-- below the second.
local FLUSH_BAR = 96

local Mover = tecs.ecs.newTagComponent({ name = "AllocationSpecMover" })

--- Fills a freshly spawned archetype with drawable entities.
local function fill(archetype, firstRow, lastRow)
    -- batchSpawn skips FFI defaults, so every field is written here.
    local transforms = archetype:getMut(Transform)
    local tints = archetype:getMut(Tint)
    for row = firstRow, lastRow do
        local transform = transforms[row]
        transform.x = (row % 17) * 8.0
        transform.y = (row % 13) * 8.0
        transform.z = 0.0
        transform.layer = 1
        transform.rotation = 0.0
        transform.scaleX = 4.0
        transform.scaleY = 4.0

        local tint = tints[row]
        tint.r, tint.g, tint.b, tint.a = 1.0, 1.0, 1.0, 1.0
    end
end

--- Bytes the heap holds. Exact: LuaJIT's byte total is far below the 2^53 a
--- double carries exactly, so the kilobytes it answers in multiply back.
local function heapBytes()
    return collectgarbage("count") * 1024.0
end

--- Runs `body` `count` times with the collector stopped and answers the bytes
--- that cost per run. Both heap reads are outside every run.
local function perRun(count, body)
    collectgarbage("collect")
    collectgarbage("stop")
    local before = heapBytes()
    for _ = 1, count do
        body()
    end
    local after = heapBytes()
    collectgarbage("restart")
    return (after - before) / count
end

--- Builds an application over a still scene with one moving entity.
local function scene()
    return Application.newApplication({
        window = { title = "allocation", width = 320, height = 240 },
        presentMode = "immediate",
        ambientLight = { 1.0, 1.0, 1.0 },
        capacity = STILL + EXTRA + MOVERS + 64,
        maxEntities = STILL + EXTRA + MOVERS + 1024,
        plugin = function(world)
            world:batchSpawn(STILL, { Transform, Tint, Renderable }, fill)
            world:batchSpawn(MOVERS, { Transform, Tint, Renderable, Mover }, fill)

            local movers = world:query({
                name = "AllocationSpecMovers",
                include = { Transform, Mover },
            })
            world:addSystem({
                name = "AllocationSpecMove",
                phase = tecs.ecs.phases.Update,
                run = function()
                    for archetype, length in movers:iter() do
                        local transforms = archetype:getMut(Transform)
                        for row = 1, length do
                            local transform = transforms[row]
                            transform.x = transform.x + 1.0
                            if transform.x > 320.0 then
                                transform.x = 0.0
                            end
                        end
                    end
                end,
            })
        end,
    })
end

describe("allocation", function()
    local app
    local previousProvider

    setup(function()
        app = scene()

        -- Pinned, so every frame runs exactly one fixed step. Left to the real
        -- clock the step count per frame would vary with the machine and so
        -- would the work, which is a difference none of this can see past.
        previousProvider = time.provider
        time.provider = function()
            return time.nominal
        end

        assert.is_true(app:_init())
    end)

    teardown(function()
        time.provider = previousProvider
        collectgarbage("restart")
        if app then
            app:_shutdown()
        end
    end)

    it("holds a steady-state frame under the ceiling, whatever the world holds", function()
        local function iterate()
            app:_iterate(nil, 0, nil)
        end

        local function frameBytes()
            for _ = 1, WARMUP do
                iterate()
            end
            local least
            for _ = 1, WINDOWS do
                local window = perRun(FRAMES, iterate)
                if least == nil or window < least then
                    least = window
                end
            end
            return least
        end

        local small = frameBytes()
        app.world:batchSpawn(EXTRA, { Transform, Tint, Renderable }, fill)
        local large = frameBytes()

        if os.getenv("TECS_ALLOCATION_REPORT") ~= nil then
            print(("\nframe %.0f / %.0f"):format(small, large))
        end

        assert.is_true(
            small <= FRAME_BAR and large <= FRAME_BAR,
            (
                "a steady-state frame allocates %.0f bytes at %d entities and %.0f at %d, "
                .. "over the %d byte ceiling. Run `cargo xtask bench alloc` for the breakdown "
                .. "by stage."
            ):format(small, STILL + MOVERS, large, STILL + EXTRA + MOVERS, FRAME_BAR)
        )

        assert.is_true(
            large <= math.max(small, LOAD_FLOOR) * LOAD_FACTOR,
            (
                "allocation per frame grew with the world: %d entities cost %.0f bytes a frame "
                .. "and %d cost %.0f. Something on the frame path allocates per row."
            ):format(STILL + MOVERS, small, STILL + EXTRA + MOVERS, large)
        )
    end)

    it("draws a frame without opening a query cursor", function()
        -- The allocation reading below cannot be relied on to catch this one.
        -- A cursor does not escape the loop that opens it, so once LuaJIT has
        -- compiled the traversal it removes the allocation entirely and the
        -- reading comes back at zero with the cursor still there. Counting the
        -- calls is exact and says the same thing: a cursor is a table and a
        -- table per frame is a table per frame whether or not the compiler
        -- happens to be able to sink it today.
        --
        -- This covers the whole frame rather than extraction alone, which is
        -- deliberate. `iter` is the traversal for a loop that runs to
        -- exhaustion and a cursor is for one that may leave early; a frame
        -- path that needs to leave early needs a cursor and needs this
        -- assertion rewritten to say which system may open one and why.
        -- Reached through a query rather than through the module, which
        -- exports a constructor and keeps the implementation table private.
        -- Every query shares the one metatable, so this counts them all.
        local methods = getmetatable(app.world:query({ include = { Transform } })).__index
        local original = methods.cursor
        assert.is_function(original)

        local opened = 0
        methods.cursor = function(self)
            opened = opened + 1
            return original(self)
        end
        finally(function()
            methods.cursor = original
        end)

        for _ = 1, 10 do
            app:_iterate(nil, 0, nil)
        end

        assert.are.equal(
            0,
            opened,
            (
                "the frame path opened %d query cursors in ten frames. A cursor is "
                .. "allocated per call; `iter` is the traversal for a loop that runs "
                .. "to exhaustion."
            ):format(opened)
        )
    end)

    it("extracts a frame packet without allocating", function()
        -- The world's own phase, so this is the extraction the frame runs and
        -- not a reconstruction of it. The moving archetype stays dirty across
        -- these, since only `world:update` clears the bits, so every run does
        -- the work of a frame that changed rather than the work of a still one.
        local world = app.world
        local function extractBytes()
            for _ = 1, 200 do
                world:runPhase(tecs.ecs.phases.RenderFirst, time.nominal)
            end
            return perRun(EXTRACTIONS, function()
                world:runPhase(tecs.ecs.phases.RenderFirst, time.nominal)
            end)
        end

        local cost = extractBytes()

        if os.getenv("TECS_ALLOCATION_REPORT") ~= nil then
            print(("\nextract %.2f"):format(cost))
        end

        assert.is_true(
            cost <= EXTRACT_BAR,
            (
                "extraction allocates %.1f bytes a run, over the %d byte bar. "
                .. "Something in Extractor allocates per frame again."
            ):format(cost, EXTRACT_BAR)
        )
    end)

    it("samples hierarchy dirtiness without allocating", function()
        -- The whole of `RenderLast`, which is the sampler and nothing else, so
        -- this is the system the frame runs rather than a reconstruction of it.
        -- Averaged over thousands of runs for the reason extraction is: the
        -- compiler's work in the window is roughly fixed and divides away,
        -- while a closure built per call does not.
        local world = app.world
        for _ = 1, 200 do
            world:runPhase(tecs.ecs.phases.RenderLast, time.nominal)
        end
        local cost = perRun(EXTRACTIONS, function()
            world:runPhase(tecs.ecs.phases.RenderLast, time.nominal)
        end)

        if os.getenv("TECS_ALLOCATION_REPORT") ~= nil then
            print(("\nsample %.2f"):format(cost))
        end

        assert.is_true(
            cost <= SAMPLE_BAR,
            (
                "the hierarchy dirty sampler allocates %.1f bytes a run, over the %d "
                .. "byte bar. It runs twice a frame on every world."
            ):format(cost, SAMPLE_BAR)
        )
    end)

    -- The two below are counted rather than weighed, for the reason the cursor
    -- test above is: each is a single object a frame, small enough to sit under
    -- the compiler's own noise here and just as real for it. Each is one object
    -- reused, so two iterations have to be handed the same one.

    it("acquires one frame object for every iteration", function()
        local frames = {}
        local recorded = app.renderer.render
        app.renderer.render = function(renderer, frame)
            frames[#frames + 1] = frame
            return recorded(renderer, frame)
        end
        finally(function()
            app.renderer.render = recorded
        end)

        for _ = 1, 3 do
            app:_iterate(nil, 0, nil)
        end

        assert.is_true(#frames >= 2, "the iterations drew no frames")
        assert.is_true(rawequal(frames[1], frames[#frames]), "the device allocated a frame object per acquisition")
    end)

    it("drains events through one handler for every iteration", function()
        local handlers = {}
        local drain = events.drain
        events.drain = function(queue, count, handler, arrivals)
            handlers[#handlers + 1] = handler
            return drain(queue, count, handler, arrivals)
        end
        finally(function()
            events.drain = drain
        end)

        for _ = 1, 3 do
            app:_iterate(nil, 0, nil)
        end

        assert.is_true(#handlers >= 2, "the iterations drained no events")
        assert.is_true(
            rawequal(handlers[1], handlers[#handlers]),
            "the loop allocated a closure per iteration to receive events with"
        )
    end)

    it("hands back the same staging view when the slot has not moved", function()
        local buffer = Buffer.create(app.renderer:device(), { size = 4096 })
        finally(function()
            buffer:destroy()
        end)

        -- The first map casts and the second must not: the slot has not been
        -- cycled, so it is the same memory and the same view answers for it.
        -- Asserted as bytes rather than as identity because bytes are the
        -- property: two cdata pointers to one address compare equal whether or
        -- not a second one was allocated.
        --
        -- Read three times and the smallest kept, because `collectgarbage`
        -- beside the call can provoke a recording whose own allocation lands in
        -- the reading. A recording happens once; a second view would be
        -- allocated every time.
        local function mapAgainCost()
            buffer:mapSlotAs(0, "float *", false)
            local view
            local cost = perRun(1, function()
                view = buffer:mapSlotAs(0, "float *", false)
            end)
            -- Still the right memory, which is what the caching could break.
            view[0] = 1.5
            assert.are.equal(1.5, view[0])
            return cost
        end

        local mapped = math.min(mapAgainCost(), mapAgainCost(), mapAgainCost())

        -- The flush encodes a copy pass over the marked ranges, and it does it
        -- out of descriptors it holds rather than a pair allocated per call.
        -- Only the flush is inside the reading: acquiring a command buffer,
        -- mapping, marking and submitting all allocate, and so does every
        -- assertion luassert makes.
        local device = app.renderer:device()
        local function flushCost(measured)
            buffer:mapSlotAs(0, "float *", false)
            buffer:markSlotDirty(0, 0, 64)
            local commands = C.SDL_AcquireGPUCommandBuffer(device)
            local cost = 0.0
            if measured then
                cost = perRun(1, function()
                    buffer:flushSlot(0, commands)
                end)
            else
                buffer:flushSlot(0, commands)
            end
            C.SDL_SubmitGPUCommandBuffer(commands)
            return cost
        end

        -- Once to warm it, since the first flush creates the transfer buffer
        -- behind the slot, then the smallest of three for the reason above.
        flushCost(false)
        local flushed = math.min(flushCost(true), flushCost(true), flushCost(true))

        if os.getenv("TECS_ALLOCATION_REPORT") ~= nil then
            print(("\nsecond map %.0f, flush %.0f"):format(mapped, flushed))
        end

        assert.are.equal(0, mapped, "mapping an unmoved slot allocated a second view")

        assert.is_true(
            flushed <= FLUSH_BAR,
            ("a staging flush allocated %.0f bytes, over the %d byte bar"):format(flushed, FLUSH_BAR)
        )
    end)

    -- Last, because both build their own device resources and record hundreds
    -- of command buffers, and the readings above are quieter for not having
    -- that behind them.

    it("runs a pass graph without allocating per pass", function()
        -- A graph of its own rather than the renderer's, because the
        -- renderer's last pass writes the swapchain and acquiring one per run
        -- would measure the presenter's wait rather than the graph. Two passes
        -- over graph-owned targets exercise everything `execute` builds:
        -- attachments for one output and for two, a declared input bound as a
        -- fragment sampler, and a context per pass.
        local device = app.renderer:device()
        local graph = PassGraph.create(device, app.device:getSwapchainFormat())
        finally(function()
            graph:destroy()
        end)

        graph:target({ name = "first", clear = { r = 0, g = 0, b = 0, a = 1 } })
        graph:target({ name = "second" })
        graph:pass({ name = "one", outputs = { "first" }, execute = function() end })
        graph:pass({
            name = "two",
            inputs = { "first" },
            outputs = { "second" },
            execute = function() end,
        })

        -- Wrapped once and refilled per run, so the frame object is not what is
        -- being measured. No swapchain texture: neither pass writes one.
        local frame = Frame.wrap(nil, nil, 64, 64)
        local function execute()
            frame.commandBuffer = C.SDL_AcquireGPUCommandBuffer(device)
            frame.state = "recording"
            graph:execute(frame)
            frame:submit()
        end

        for _ = 1, 20 do
            execute()
        end
        -- The smallest of four, for the reason the flush reading above is read
        -- that way: a recording that happens once lands wholly in whichever
        -- window it happened in, and a real allocation lands in all of them.
        local cost = math.min(perRun(60, execute), perRun(60, execute), perRun(60, execute), perRun(60, execute))

        if os.getenv("TECS_ALLOCATION_REPORT") ~= nil then
            print(("\ngraph %.0f"):format(cost))
        end

        assert.is_true(
            cost <= GRAPH_BAR,
            (
                "a two-pass graph allocated %.0f bytes an execution, over the %d byte "
                .. "bar. Something in PassGraph is built per frame rather than per "
                .. "declaration."
            ):format(cost, GRAPH_BAR)
        )
    end)

    it("begins a compute pass without allocating its arguments", function()
        local device = app.renderer:device()
        local buffer = Buffer.create(device, {
            usage = { "storage", "computeWrite" },
            size = 256,
        })
        finally(function()
            buffer:destroy()
        end)

        -- Held rather than built per run, so what is measured is the pass and
        -- not this spec's own argument list.
        local writes = { buffer.handle }
        local pass
        local function record()
            local commands = C.SDL_AcquireGPUCommandBuffer(device)
            pass = ComputePass.begin(commands, writes, pass)
            pass:finish()
            C.SDL_SubmitGPUCommandBuffer(commands)
        end

        for _ = 1, 20 do
            record()
        end
        local cost = math.min(perRun(60, record), perRun(60, record), perRun(60, record), perRun(60, record))

        if os.getenv("TECS_ALLOCATION_REPORT") ~= nil then
            print(("\ncompute %.0f"):format(cost))
        end

        assert.is_true(
            cost <= COMPUTE_BAR,
            (
                "beginning a compute pass allocated %.0f bytes, over the %d byte bar. "
                .. "Its binding array or its pass object is being allocated per call."
            ):format(cost, COMPUTE_BAR)
        )
    end)
end)
