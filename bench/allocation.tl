--- Bytes allocated per frame in steady state, and where they come from.
---
--- Frame time says how long a frame took. It does not say whether the frame
--- left rubbish behind, and a frame that allocates has bought a collection it
--- will pay for later, in some other frame: the cost is real, it lands
--- somewhere other than where it was incurred, and in a timing bench it shows
--- up as a tail nobody can attribute. So this measures the other thing.
---
--- Three things decide whether a number here is worth anything, and each of
--- them is a way of being wrong that this file is built out of avoiding.
---
--- **The collector.** `collectgarbage("count")` reports the current heap, not
--- what was allocated, so a collection inside the window eats the delta and
--- more work can measure as less. The collector is stopped for every window
--- here. With it stopped the heap only rises and the rise is the bytes.
---
--- **The probe.** `collectgarbage` is not compiled by LuaJIT, so a call to it
--- inside the frame aborts every trace that would have covered the frame, and
--- the compiler spends the rest of the run recording, flushing and
--- recompiling. Trace objects are heap objects, so that lands in the
--- measurement as if it were the frame's. It is not a small effect: with four
--- probes a frame this bench measures 8 to 11 KB and varies by 40% between
--- runs of one binary, and with none it measures 5.6 KB and barely varies at
--- all. So every regime is measured twice. The `total` column comes from a
--- window with two heap reads in the whole of it, one before the first frame
--- and one after the last, and it is the authoritative number. The breakdown
--- comes from a second window that does carry probes.
---
--- **The compiler.** Even without probes the compiler occasionally decides to
--- recompile, and while it is doing that the frames it touches allocate
--- several kilobytes each that are nothing to do with the frame path. Both
--- windows therefore watch `jit.attach`'s trace events and count only the
--- frames the compiler did not touch. A frame it did not touch allocates the
--- same number every time, which is what makes the two windows agree and what
--- makes a change of a hundred bytes visible.
---
--- The breakdown comes from four probes at phase boundaries:
---
---   sim      `First` to `PostUpdate`: the fixed steps, gameplay, and the
---            engine's own simulation systems.
---   extract  `PostUpdate` to `PreRender`: `RenderFirst`, which is where
---            `tecs.SyncRenderState` turns the world into a frame packet.
---   render   `PreRender` to `Last`: the remaining render phases.
---   submit   `Last` to the next frame's `First`: everything outside
---            `world:update`. Frame acquisition, `Backend:consume` with its
---            flush and its cull, the pass graph, submission, and the host
---            loop's own event drain around all of it.
---
--- The four sum to a frame, and `submit` carries the frame edges with it: a
--- `First`-phase engine system registered before this file's probe runs on the
--- far side of the boundary and lands there. That is stated rather than
--- corrected, since correcting it would mean a probe claiming an ordering the
--- pipeline does not promise.
---
--- Four regimes, run in sequence in one process so they share a scene and
--- differ only in what runs over it:
---
---   bare     No gameplay system at all. What a frame costs when the world is
---            asked to do nothing.
---   empty    One system whose body returns immediately. The marginal cost of
---            a system existing.
---   query    One system that iterates the renderable query and reads a column
---            per row. The marginal cost of iteration.
---   moving   One system that writes every transform, so the extraction's
---            dirty gate opens, every instance is rewritten, and the staging
---            flush encodes the upload. The frame a scene in motion has.
---
--- dt is pinned, so every frame runs exactly one fixed step and the regimes
--- are comparable rather than each being measured at whatever frame rate it
--- happened to run at.

local root = os.getenv("TECS_LUA")
    or (_G as {string: any})["__tecsContent"] as string
    or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then root = root:sub(1, -2) end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. package.path

local tecs <const> = require("tecs")
local clock <const> = require("tecs.platform.clock")
local Transform <const> = tecs.components.Transform
local Tint <const> = tecs.components.Tint
local Renderable <const> = tecs.components.Renderable

--- Entities in the scene. Allocation per frame is load independent where the
--- frame path is allocation free and load dependent where it is not, so a
--- count this size makes a per-row allocation obvious and still runs quickly.
local COUNT <const> = math.floor(tonumber(os.getenv("BENCH_ALLOC_COUNT")) or 20000)

--- Frames each window warms for, and frames it is then measured over.
---
--- The warmup has to be long enough for the regime's own traces to compile,
--- since a trace object is a heap object and a window still compiling reports
--- the compiler rather than the frame. The measured run has to be long enough
--- to contain a useful number of frames the compiler left alone.
local WARMUP <const> = math.floor(tonumber(os.getenv("BENCH_ALLOC_WARMUP")) or 240)
local FRAMES <const> = math.floor(tonumber(os.getenv("BENCH_ALLOC_FRAMES")) or 600)

local WIDTH <const> = 960
local HEIGHT <const> = 540

--- The system each regime installs, in the order they are measured.
local REGIMES <const>: {string} = { "bare", "empty", "query", "moving" }

local SYSTEM <const> = "bench.AllocRegime"

--- Trace events since the last frame boundary. A frame with any is a frame the
--- compiler was working during, and its bytes are the compiler's as much as
--- the frame's.
local traceEvents = 0

--- `jit` has no Teal declarations; go through an opaque require, as the
--- pipeline does for `jit.zone`.
local function loadUntyped(name: string): any
    return require(name)
end
local jit <const> = loadUntyped("jit") as {string: any}
local attach <const> = jit.attach as function(function(string), string)
attach(function(_what: string) traceEvents = traceEvents + 1 end, "trace")

--- Heap in bytes.
---
--- `collectgarbage("count")` answers in kilobytes as a double, and LuaJIT's
--- byte total is far below the 2^53 a double carries exactly, so multiplying
--- back recovers the byte count rather than approximating it.
local function heapBytes(): number
    return (collectgarbage("count") as number) * 1024.0
end

local record Window
    name: string
    --- Frames measured, and of those the ones the compiler left alone.
    frames: integer
    quiet: integer
    total: number
    sim: number
    extract: number
    render: number
    submit: number
end

local function spawnField(world: tecs.World)
    local golden <const> = 2.39996
    local extent <const> = math.min(WIDTH, HEIGHT) * 0.46

    world:batchSpawn(COUNT, { Transform, Tint, Renderable },
        function(archetype: tecs.Archetype, firstRow: integer, lastRow: integer)
            -- batchSpawn skips FFI defaults, so every field is written here.
            local transforms = archetype:getMut(Transform)
            local tints = archetype:getMut(Tint)

            for row = firstRow, lastRow do
                local index = row - firstRow
                local angle = index * golden
                local radius = math.sqrt(index / COUNT) * extent

                local transform = transforms[row]
                transform.x = WIDTH * 0.5 + math.cos(angle) * radius
                transform.y = HEIGHT * 0.5 + math.sin(angle) * radius
                transform.z = 0.0
                transform.layer = 1
                transform.rotation = angle
                transform.scaleX = 8.0
                transform.scaleY = 8.0

                local tint = tints[row]
                tint.r = 0.6
                tint.g = 0.6
                tint.b = 0.7
                tint.a = 1.0
            end
        end)
end

--- One frame's dt, so every frame runs exactly one fixed step.
---
--- The accumulator takes the step back out by subtracting the same value it
--- added, so this is exact rather than nearly exact and no frame runs two
--- steps or none.
clock.provider = function(_real: number): number
    return 1.0 / 60.0
end

--- Per regime, the probe-free window and the probed one.
local plainWindows: {Window} = {}
local probedWindows: {Window} = {}

return tecs.application({
    window = { title = "allocation", width = WIDTH, height = HEIGHT },
    presentMode = "immediate",
    ambient = { 1.0, 1.0, 1.0 },
    capacity = COUNT + 64,
    maxEntities = COUNT + 1024,
    -- Two windows per regime, and one frame after each to close the last
    -- measured frame's `submit` bracket.
    maxFrames = #REGIMES * 2 * (WARMUP + FRAMES + 1) + 1,

    plugin = function(world: tecs.World, _app: tecs.Application)
        spawnField(world)

        local moving = world:query({
            name = "bench.AllocMoving",
            include = { Transform, Renderable },
        })

        -- One body per regime, built once, so installing a regime is a lookup
        -- and never a closure a measured window would have to pay for.
        local bodies <const>: {string: function(number)} = {
            empty = function(_dt: number) end,
            query = function(_dt: number)
                local total = 0.0
                for archetype, length in moving:iter() do
                    local transforms = archetype:get(Transform)
                    for row = 1, length do
                        total = total + transforms[row].x
                    end
                end
                -- Kept so the loop cannot be optimised away entirely.
                if total ~= total then error("unreachable") end
            end,
            moving = function(dt: number)
                local step = dt * 40.0
                for archetype, length in moving:iter() do
                    local transforms = archetype:getMut(Transform)
                    for row = 1, length do
                        local transform = transforms[row]
                        local x = transform.x + step
                        if x > WIDTH then x = x - WIDTH end
                        transform.x = x
                    end
                end
            end,
        }

        local regime = 0
        local installed: string = nil
        local frame = 0
        local window: Window = nil
        --- True in the window that carries the phase probes, false in the one
        --- that carries only the pair bracketing the whole window.
        local probing = false
        local measuring = false
        local closing = false
        local windowBase = 0.0

        -- The four probe readings, carried between phases of one frame.
        local atFirst = 0.0
        local atPostUpdate = 0.0
        local atPreRender = 0.0
        local atLast = 0.0

        local function install(name: string)
            if installed ~= nil then
                world:removeSystem(SYSTEM)
                installed = nil
            end
            local body = bodies[name]
            if body == nil then return end
            world:addSystem({
                name = SYSTEM,
                phase = tecs.phases.Update,
                run = body,
            })
            installed = name
        end

        --- Starts the next window, or answers false when there are none left.
        ---
        --- Each regime gets two: the probe-free one that reports `total`, then
        --- the probed one that reports the breakdown.
        local function advance(): boolean
            if window == nil or probing then
                regime = regime + 1
                if regime > #REGIMES then return false end
                install(REGIMES[regime])
                probing = false
            else
                probing = true
            end
            window = {
                name = REGIMES[regime], frames = 0, quiet = 0, total = 0.0,
                sim = 0.0, extract = 0.0, render = 0.0, submit = 0.0,
            }
            if probing then
                probedWindows[regime] = window
            else
                plainWindows[regime] = window
            end
            frame = 0
            measuring = false
            closing = false
            return true
        end

        advance()

        -- First, and registered first among this file's own systems so the
        -- three below are inside the bracket it opens.
        world:addSystem({
            name = "bench.AllocFirst",
            phase = tecs.phases.First,
            run = function()
                local now = probing and heapBytes() or 0.0
                local touched <const> = traceEvents > 0
                traceEvents = 0

                if measuring then
                    window.frames = window.frames + 1
                    if not touched then
                        window.quiet = window.quiet + 1
                        if probing then
                            window.sim = window.sim + (atPostUpdate - atFirst)
                            window.extract = window.extract
                                + (atPreRender - atPostUpdate)
                            window.render = window.render + (atLast - atPreRender)
                            window.submit = window.submit + (now - atLast)
                        end
                    end

                    if closing then
                        if not probing then
                            -- One reading for the whole window, divided by the
                            -- frames it held. The compiler-touched frames are
                            -- in it, so this and the sum of the brackets agree
                            -- only when it left the window alone; the counts
                            -- printed beside them say how much to trust each.
                            window.total = heapBytes() - windowBase
                        end
                        collectgarbage("restart")
                        collectgarbage("collect")
                        measuring = false
                        if not advance() then return end
                        now = probing and heapBytes() or 0.0
                    end
                end

                frame = frame + 1
                if frame == WARMUP then
                    -- Everything this regime will compile has compiled. Clear
                    -- the heap, stop the collector, and measure a window in
                    -- which nothing can be freed.
                    collectgarbage("collect")
                    collectgarbage("stop")
                    measuring = true
                    windowBase = heapBytes()
                    now = probing and windowBase or 0.0
                elseif measuring and frame == WARMUP + FRAMES - 1 then
                    -- Measured frames are complete after this one, whose
                    -- `submit` bracket the next `First` closes. The window is
                    -- the frames from `WARMUP` to here inclusive, which is
                    -- `FRAMES` of them.
                    closing = true
                end

                atFirst = now
            end,
        })

        world:addSystem({
            name = "bench.AllocPostUpdate",
            phase = tecs.phases.PostUpdate,
            run = function()
                if probing then atPostUpdate = heapBytes() end
            end,
        })

        world:addSystem({
            name = "bench.AllocPreRender",
            phase = tecs.phases.PreRender,
            run = function()
                if probing then atPreRender = heapBytes() end
            end,
        })

        world:addSystem({
            name = "bench.AllocLast",
            phase = tecs.phases.Last,
            run = function()
                if probing then atLast = heapBytes() end
            end,
        })

        world:addSystem({
            name = "bench.AllocReport",
            phase = tecs.phases.Shutdown,
            run = function()
                collectgarbage("restart")
                print(("%-8s %9s %9s %9s %9s %9s %9s %11s")
                    :format("regime", "sim", "extract", "render", "submit",
                            "sum", "total", "quiet/frames"))
                print(("%s %s %s %s %s %s %s %s"):format(("-"):rep(8),
                    ("-"):rep(9), ("-"):rep(9), ("-"):rep(9), ("-"):rep(9),
                    ("-"):rep(9), ("-"):rep(9), ("-"):rep(11)))
                for index = 1, #REGIMES do
                    local plain = plainWindows[index]
                    local probed = probedWindows[index]
                    if plain ~= nil and probed ~= nil and probed.quiet > 0 then
                        local n <const> = probed.quiet
                        local sum <const> = probed.sim + probed.extract
                            + probed.render + probed.submit
                        print(("%-8s %9.0f %9.0f %9.0f %9.0f %9.0f %9.0f %5d/%-5d")
                            :format(plain.name, probed.sim / n,
                                    probed.extract / n, probed.render / n,
                                    probed.submit / n, sum / n,
                                    plain.total / plain.frames,
                                    plain.quiet, plain.frames))
                    end
                end
                print("\nsum is the four brackets, measured on the frames the "
                    .. "compiler left alone.\ntotal is a probe-free window, "
                    .. "every frame in it. They agree when quiet is close\nto "
                    .. "frames; where they do not, total is carrying the "
                    .. "compiler's own allocation.")
            end,
        })

        print(("allocation: %d entities, %d warmup + %d measured frames per "
            .. "window, two windows per regime, bytes per frame")
            :format(COUNT, WARMUP, FRAMES))
    end,
})
