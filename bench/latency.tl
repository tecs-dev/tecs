--- Event to photon, with nobody at the keyboard.
---
--- Frame time says nothing about how long a player waits for a key press to
--- appear on screen, and the two move independently: anything that pipelines a
--- frame buys throughput and pays for it here. So this measures the other half.
---
--- Input is injected through `SDL_PushEvent` rather than through
--- `events.source`. A replay source is deterministic but skips the host
--- entirely: the event would never pass through `SDL_AppEvent`, so the harness
--- would be measuring its own call rather than the path a key press takes.
--- Pushed events go around the same loop as a real one, so the only thing
--- synthetic about them is which key was pressed and when.
---
--- Which stamp the measurement starts from matters here more than anywhere,
--- and it is SDL's own: the nanosecond stamp SDL puts on an event as it is
--- produced, which the host converts onto the clock the rest of the engine
--- measures with. That interval includes the wait for the next pump, which is
--- most of it. A main thread inside `SDL_WaitAndAcquireGPUSwapchainTexture` is
--- not pumping and cannot be made to; dating an event from the pump that
--- eventually found it would price that wait at zero and report a floor rather
--- than a measurement.
---
--- So the number here is not the average press. Injection happens at a fixed
--- point in the frame, just after the previous drain, which is the furthest an
--- event can be from the pump that will take it: a real press arriving at a
--- uniformly random moment waits about half as long for that pump. This is the
--- worst case for the phase it is injected at, deliberately, because the point
--- of the instrument is to catch the frames a player notices.
---
--- One event every few frames, so each sample is a batch of its own and no
--- sample overlaps the one before it. The reaction is a real one: a system in
--- Update moves an entity, which dirties a column, which the renderer syncs
--- and draws. A harness whose input changed nothing would time a frame that
--- had no reason to be produced.
---
--- Presentation is submission, not scanout: the engine knows when it handed a
--- frame over and cannot see the display. `BENCH_PRESENT=vsync` puts the
--- display's own wait back into `latencyDraw`, where it lands as a block in
--- acquire. The default is `immediate`, which measures the part the engine is
--- answerable for.

local root = os.getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tecs <const> = require("tecs")
local events <const> = require("tecs.platform.events")
local timing <const> = require("tecs.timing")
local Transform <const> = tecs.Transform
local Tint <const> = tecs.gfx.Tint
local Renderable <const> = tecs.gfx.Renderable

--- A scene, so the frame being waited on is a real one. Small enough that the
--- number is about the loop rather than about the field.
local COUNT <const> = math.floor(tonumber(os.getenv("BENCH_SHAPES")) or 20000)
local WARMUP <const> = math.floor(tonumber(os.getenv("BENCH_WARMUP")) or 120)
local FRAMES <const> = math.floor(tonumber(os.getenv("BENCH_FRAMES")) or 600)

--- Frames between injections.
local INTERVAL <const> = math.floor(tonumber(os.getenv("BENCH_INTERVAL")) or 4)

local WIDTH <const> = 960
local HEIGHT <const> = 540
local TOTAL <const> = WARMUP + FRAMES

--- The key the harness presses. Anything unbound would do; this one is easy to
--- recognize in a log.
local KEY <const> = "space"

local function spawnField(world: tecs.World)
    local golden <const> = 2.39996
    local extent <const> = math.min(WIDTH, HEIGHT) * 0.46

    world:batchSpawn(
        COUNT,
        {Transform, Tint, Renderable},
        function(archetype: tecs.ecs.Archetype, firstRow: integer, lastRow: integer)
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
        end
    )
end

-- Measuring is the whole point of this file, so it does not wait to be asked.
timing.enable()

--- Injections whose reaction can still be presented before the run ends, and
--- samples the accounting completed. They match when the only input in the run
--- is this harness's own; anything else on the desktop reaching the window
--- adds samples that nothing here injected.
local injected = 0
local reactions = 0

return tecs.newApplication(
    {
        window = {title = "latency", width = WIDTH, height = HEIGHT},
        presentMode = os.getenv("BENCH_PRESENT") or "immediate",
        ambientLight = {1.0, 1.0, 1.0},
        capacity = COUNT + 64,
        debugMaxFrames = TOTAL,

        plugin = function(world: tecs.World, app: tecs.Application)
            local input = app.input
            spawnField(world)

            -- The entity the press moves. One entity, so the reaction costs
            -- nothing worth measuring and the latency reported is the loop's.
            local marker = world:spawn(
                Transform(WIDTH * 0.5, HEIGHT * 0.5, 0, 1, 0, 24, 24), Tint(1.0, 0.3, 0.2, 1.0), Renderable()
            )

            -- Iterations completed. Incremented in `Last`, so the injector in
            -- `First` and the reaction in `Update` read the same number within one
            -- iteration.
            local frame = 0
            world:addSystem(
                {
                    name = "bench.Frame",
                    phase = tecs.ecs.phases.Last,
                    run = function() frame = frame + 1 end,
                }
            )

            world:addSystem(
                {
                    name = "bench.React",
                    phase = tecs.ecs.phases.Update,
                    run = function()
                        -- Inside the step, because the step is what the measurement
                        -- brackets. A reaction deferred to the next frame would be a
                        -- frame of latency this harness could not see.
                        if not input:keyPressed(KEY) and not input:keyReleased(KEY) then
                            return
                        end
                        if frame >= WARMUP then
                            reactions = reactions + 1
                        end
                        local transform = world:getMut(marker, Transform)
                        transform.y = HEIGHT * (input:keyDown(KEY) and 0.6 or 0.4)
                    end,
                }
            )

            -- Injection is a system like any other. It writes to SDL's queue
            -- rather than to the world, which is the case the callbacks existed
            -- for, and it turns out to need nothing a callback had: the queue is
            -- process state and a system can reach it from anywhere in the frame.
            --
            -- `First` rather than `Update`, so it stays where the loop used to
            -- call it from and the press still lands one iteration ahead of the
            -- step that reacts to it. The one behavioral difference is that the
            -- warmup reset now happens after this iteration's arrival stamp was
            -- taken rather than before, so the sample straddling the cut is
            -- dropped instead of being counted against a cleared table. One of a
            -- hundred and fifty, and dropping it is the more honest of the two.
            world:addSystem(
                {
                    name = "bench.Inject",
                    phase = tecs.ecs.phases.First,
                    run = function()
                        -- Warmup frames built and first uploaded the scene, and are
                        -- also what gets the reaction compiled. Dropping them here
                        -- leaves a distribution of the steady state.
                        if frame == WARMUP then
                            timing.reset()
                        end

                        -- An event pushed here is delivered to the host before the
                        -- next iteration, so the step that reacts is the next one.
                        -- Injecting stops early enough that every press still gets a
                        -- frame to be presented in, which is what makes the two counts
                        -- comparable.
                        if frame % INTERVAL ~= 0 or frame + 1 >= TOTAL then
                            return
                        end

                        local down = (frame / INTERVAL) % 2 < 1
                        events.push(down and "keyDown" or "keyUp", {scancode = input:scancode(KEY)} as events.Event)
                        if frame >= WARMUP then
                            injected = injected + 1
                        end
                    end,
                }
            )

            world:addSystem(
                {
                    name = "bench.Report",
                    phase = tecs.ecs.phases.Shutdown,
                    run = function()
                        print(("%d presses injected, %d reacted to"):format(injected, reactions))
                        local report = timing.format()
                        if report ~= "" then
                            print(report)
                        end
                    end,
                }
            )

            print(
                ("latency: %d shapes, one %s press every %d frames, %s present"):format(
                    COUNT, KEY, INTERVAL, os.getenv("BENCH_PRESENT") or "immediate"
                )
            )
        end,
    }
)
