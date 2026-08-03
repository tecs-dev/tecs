-- The lifecycle the host drives.
--
-- Everything here goes through the same four methods `host.c` calls, because
-- the interesting failures are the ones where a subsystem is never told a
-- frame happened. Asset loading is the case that motivated this: a handle is
-- resolved by a pump, and a game that loads an image and nothing else has no
-- other reason for anything to call one.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Application = require("tecs.Application")
local assets = require("tecs.assets")
local events = require("tecs.platform.events")
local phases = require("tecs.internal.phases")
local components = require("tecs.components")
local tecs = require("tecs")
local ecs = require("tecs.ecs")
local passscope = require("tecs.gpu.passscope")
local ComputePass = require("tecs.gpu.ComputePass")
local time = require("tecs.platform.time")
local files = require("tecs.io.files")
local tecsIO = require("tecs.io")
local log = require("tecs.log")
local mcp = require("tecs.io.mcp")
local runtime = require("tecs.internal.runtime")
local task = require("tecs.internal.taskruntime")

local FIXTURE = "spec/fixtures/split.png"

--- A checkpoint name nothing else in the suite writes.
local CHECKPOINT = "spec-checkpoint.bin"

--- An application with a window small enough to be cheap. It sets no log file
--- and no `debug`, so nothing here writes one.
local function build(config)
    config.window = { title = "application", width = 64, height = 64 }
    return Application.newApplication(config)
end

local function iterateEvents(app, batch)
    local original = events.source
    events.source = function(emit)
        for index = 1, #batch do
            emit(batch[index])
        end
    end
    local ok, result = pcall(app._iterate, app, nil, 0, nil)
    events.source = original
    assert.is_true(ok, result)
    return result
end

describe("Application", function()
    it("updates an opt-in FPS title at a bounded rate", function()
        local app = build({ showFps = true })
        assert.is_true(app:_init())
        app._fpsStarted = 10
        app._fpsFrames = 29

        app:_refreshFps(10.5)

        assert.are.equal("application | 60 FPS", app.window.title)
        assert.are.equal(0, app._fpsFrames)
        assert.are.equal(10.5, app._fpsStarted)
        app:_shutdown()
    end)

    it("renders while a suspending phase holds simulation time still", function()
        local gate = task.newGate()
        local lastRuns = 0
        local app = build({
            plugin = function(world)
                world:addSystem({
                    name = "BeforeApplicationSuspension",
                    phase = phases.Last,
                    run = function()
                        lastRuns = lastRuns + 1
                    end,
                })
                world:addSystem({
                    name = "ApplicationSuspension",
                    phase = phases.Last,
                    run = function()
                        gate:wait()
                    end,
                })
            end,
        })
        assert.is_true(app:_init())

        assert.is_true(app:_iterate(nil, 0, nil))
        local heldElapsed = app.elapsed
        assert.is_true(app.world._updateStalled)
        assert.are.equal(1, lastRuns)
        assert.is_nil(app:crashed())

        assert.is_true(app:_iterate(nil, 0, nil))
        assert.are.equal(heldElapsed, app.elapsed)
        assert.are.equal(1, lastRuns)
        assert.is_nil(app:crashed())

        gate:complete(true)
        assert.is_true(app:_iterate(nil, 0, nil))
        assert.is_false(app.world._updateStalled)
        assert.are.equal(heldElapsed, app.elapsed)
        assert.are.equal(1, lastRuns)
        assert.is_nil(app:crashed())
        assert.is_true(app:_shutdown())
    end)

    it("starts a fresh logical update after a held system fails", function()
        local gate = task.newGate()
        local attempts = 0
        local app = build({
            debug = true,
            plugin = function(world)
                world:addSystem({
                    name = "FailHeldApplicationUpdateOnce",
                    phase = phases.Last,
                    run = function()
                        attempts = attempts + 1
                        if attempts == 1 then
                            gate:wait()
                            error("held system boom")
                        end
                    end,
                })
            end,
        })
        assert.is_true(app:_init())

        assert.is_true(app:_iterate(nil, 0, nil))
        assert.is_true(app.world._updateStalled)
        gate:complete(true)
        assert.is_true(app:_iterate(nil, 0, nil))
        assert.is_truthy(app:crashed():find("held system boom", 1, true))
        assert.is_false(app.world._updateStalled)

        assert.is_true(app:clearCrash())
        assert.is_true(app:_iterate(nil, 0, nil))
        assert.are.equal(2, attempts)
        assert.is_false(app.world._updateStalled)
        assert.is_nil(app:crashed())
        assert.is_true(app:_shutdown())
    end)

    it("polls the process runtime once per host iteration", function()
        local app = build({})
        assert.is_true(app:_init())

        local original = runtime.poll
        local calls = 0
        runtime.poll = function()
            calls = calls + 1
            return 0
        end
        local ok, reason = pcall(function()
            app:_iterate(nil, 0, nil)
        end)
        runtime.poll = original

        app:_shutdown()
        assert.is_true(ok, reason)
        assert.are.equal(1, calls)
    end)

    -- The two renderer options a game can only reach through this config. A
    -- field declared on Config and not forwarded type-checks, documents itself
    -- and does nothing, which is the failure these catch. The renderer is
    -- built here and never handed to a game before it exists, so there is no
    -- second way in.
    it("turns shadows and image packing on when its config asks", function()
        local app = build({
            capacity = 32,
            packImages = true,
            shadows = { maskScale = 0.5 },
        })
        assert.is_true(app:_init())

        assert.are.equal(32, app.renderer.sprites.capacity)
        assert.is_true(app.renderer.sprites.images.packed)
        assert.is_true(app.renderer.deferred:castsShadows())

        app:_shutdown()
    end)

    it("builds neither when its config says nothing", function()
        local app = build({})
        assert.is_true(app:_init())

        assert.is_false(app.renderer.deferred:castsShadows())
        assert.is_false(app.renderer.sprites.images.packed)

        app:_shutdown()
    end)

    it("returns loaded assets without a Future or a game pump", function()
        local image
        local app = build({
            plugin = function()
                image = assets.loadImage(FIXTURE)
            end,
        })
        assert.is_true(app:_init())
        assert.is_not_nil(image.pixels)
        image:release()

        app:_shutdown()
    end)

    it("returns resolved addresses without a Future or a game poll", function()
        local app = build({})
        assert.is_true(app:_init())

        local address = tecsIO.resolve("127.0.0.1")
        assert.are.equal(0, tecsIO.pending())
        address:close()
        local stopped, reason = tecsIO.shutdown()
        assert.is_true(stopped, reason)

        app:_shutdown()
    end)

    it("stops the loading worker at shutdown", function()
        local app = build({
            plugin = function()
                assert.is_true(assets.installed())
            end,
        })
        assert.is_true(app:_init())
        assert.is_true(assets.installed())

        app:_shutdown()
        assert.is_false(assets.installed(), "the decoding thread outlived the application")
    end)

    it("shuts down the application-owned worker when nothing loaded", function()
        local app = build({})
        assert.is_true(app:_init())
        assert.is_true(assets.installed())
        app:_iterate(nil, 0, nil)
        assert.is_true(app:_shutdown())
        assert.is_false(assets.installed())
    end)

    it("hands the renderer the run reservation it was configured with", function()
        -- The setting decides how extraction lays archetype runs out, and the
        -- only way a game reaches it is through this config: the renderer is
        -- built here and never handed to the game before it exists.
        local packed = build({})
        assert.is_true(packed:_init())
        assert.is_false(packed.renderer.sprites:reservesRuns())
        packed:_shutdown()

        local reserved = build({ reserveRuns = true })
        assert.is_true(reserved:_init())
        assert.is_true(reserved.renderer.sprites:reservesRuns(), "a game asking for reserved runs gets them")
        reserved:_shutdown()
    end)

    it("hands the plugin the world and then the application", function()
        -- The order is the assertion. Every plugin the world takes is
        -- `function(world)`, so this one is that shape with the application
        -- after it, and code that moves between the two must not swap its
        -- arguments silently. The arity is pinned for the same reason.
        local seen = {}
        local app = build({
            plugin = function(...)
                seen.count = select("#", ...)
                seen.world, seen.app = ...
            end,
        })
        assert.is_true(app:_init())

        assert.are.equal(2, seen.count)
        assert.is_true(rawequal(app.world, seen.world))
        assert.is_true(rawequal(app, seen.app))
        -- What a game reaches for before its first frame, and the reason the
        -- application is passed at all: none of it is world state.
        assert.is_true(rawequal(app.renderer, seen.app.renderer))
        assert.is_not_nil(seen.app.window)
        assert.is_not_nil(seen.app.input)
        app:_shutdown()
    end)

    it("lets the one plugin install the rest", function()
        -- One entry point rather than a list, because the world already
        -- composes plugins. A game with several calls `addPlugin` from inside
        -- this one, which is how the engine installs its own.
        local order = {}
        local app = build({
            plugin = function(world)
                order[#order + 1] = "entry"
                world:addPlugin(function()
                    order[#order + 1] = "delegated"
                end)
            end,
        })
        assert.is_true(app:_init())

        assert.are.same({ "entry", "delegated" }, order)
        app:_shutdown()
    end)

    describe("events", function()
        it("requests a clean quit on Escape only when configured", function()
            local defaultApp = build({})
            assert.is_true(defaultApp:_init())
            defaultApp:_receive({
                kind = "keyDown",
                scancode = defaultApp.input:scancode("escape"),
                down = true,
            })
            assert.is_false(defaultApp.quitRequested)
            defaultApp:_shutdown()

            local app = build({ quitOnEscape = true })
            assert.is_true(app:_init())

            app:_receive({
                kind = "keyDown",
                scancode = app.input:scancode("escape"),
                down = true,
            })

            assert.is_true(app.quitRequested)
            app:_shutdown()
        end)

        it("delivers one to an observer of that kind and to no other", function()
            local keys, drops = 0, 0
            local app = build({
                plugin = function(world)
                    world:observe(0, events.on.keyDown, function()
                        keys = keys + 1
                    end)
                    world:observe(0, events.on.dropFile, function()
                        drops = drops + 1
                    end)
                end,
            })
            assert.is_true(app:_init())

            iterateEvents(app, { { kind = "keyDown", scancode = 44, down = true } })

            assert.are.equal(1, keys)
            assert.are.equal(0, drops, "an observer was called for a kind it did not ask for")
            app:_shutdown()
        end)

        it("hands the observer the sealed borrowed event", function()
            -- A replay source is copied once while its logical-update batch is
            -- sealed. Ingress then borrows that retained record without a
            -- second per-observer copy.
            local received
            local app = build({
                plugin = function(world)
                    world:observe(0, events.on.mouseMotion, function(event)
                        received = event
                    end)
                end,
            })
            assert.is_true(app:_init())

            local sent = {
                kind = "mouseMotion",
                x = 4.0,
                y = 8.0,
                dx = 1.0,
                dy = 2.0,
            }
            iterateEvents(app, { sent })

            assert.are.equal("mouseMotion", received.kind)
            assert.are.equal(4.0, received.x)
            assert.are.equal(8.0, received.y)
            assert.are.equal(1.0, received.dx)
            assert.are.equal(2.0, received.dy)
            app:_shutdown()
        end)

        it("folds the event into input before the observer sees it", function()
            local downInHandler
            local app = build({
                plugin = function(world, app)
                    world:observe(0, events.on.keyDown, function()
                        downInHandler = app.input:keyDown("space")
                    end)
                end,
            })
            assert.is_true(app:_init())

            iterateEvents(app, {
                {
                    kind = "keyDown",
                    scancode = app.input:scancode("space"),
                    down = true,
                },
            })

            assert.is_true(downInHandler, "an observer saw the input state from before the event it was told about")
            app:_shutdown()
        end)
    end)

    describe("the crash guard", function()
        it("survives a plugin that throws", function()
            local app = build({
                plugin = function()
                    error("plugin boom")
                end,
            })

            -- True, not false: the process stays up so the traceback is
            -- readable and the debug server keeps answering, which is the
            -- same bargain a system in any phase already gets.
            assert.is_true(app:_init())
            assert.is_truthy(app:crashed())
            assert.is_truthy(app:crashed():match("plugin boom"))
            assert.is_true(app:_shutdown())
        end)

        it("survives a startup system that throws", function()
            local app = build({
                plugin = function(world)
                    world:addSystem({
                        name = "spec.BadStartup",
                        phase = phases.Startup,
                        run = function()
                            error("startup boom")
                        end,
                    })
                end,
            })
            assert.is_true(app:_init())
            assert.is_truthy(app:crashed():match("startup boom"))
            assert.is_true(app:_shutdown())
        end)

        it("records one traceback for a system that throws, not two", function()
            -- The task runtime captures the traceback at the line the system
            -- raised on. A second capture at the guard names only the frames
            -- between the guard and `world:update`, and buries the first.
            local app = build({
                plugin = function(world)
                    world:addSystem({
                        name = "spec.ThrowsOnce",
                        phase = phases.Update,
                        run = function()
                            error("update boom")
                        end,
                    })
                end,
            })
            assert.is_true(app:_init())

            app:_iterate(nil, 0, nil)

            local crashed = app:crashed()
            assert.is_truthy(crashed:match("update boom"))
            local _, tracebacks = crashed:gsub("stack traceback:", "")
            assert.are.equal(1, tracebacks)
            app:_shutdown()
        end)

        it("survives an observer that throws", function()
            local app = build({
                plugin = function(world)
                    world:observe(0, events.on.keyDown, function()
                        error("observer boom")
                    end)
                end,
            })
            assert.is_true(app:_init())

            iterateEvents(app, { { kind = "keyDown", scancode = 44, down = true } })

            assert.is_truthy(app:crashed():match("observer boom"))
            app:_shutdown()
        end)

        it("runs teardown when a startup system threw", function()
            -- The bug this pins: a game that acquires something in the first
            -- half of its startup and throws in the second half still has to
            -- be given the chance to give it back, and this is the run where
            -- nothing else will.
            local releases = 0
            local app = build({
                plugin = function(world)
                    world:addSystem({
                        name = "spec.BadStartup",
                        phase = phases.Startup,
                        run = function()
                            error("startup boom")
                        end,
                    })
                    world:addSystem({
                        name = "spec.Release",
                        phase = phases.Shutdown,
                        run = function()
                            releases = releases + 1
                        end,
                    })
                end,
            })
            assert.is_true(app:_init())
            assert.is_true(app:_shutdown())

            assert.are.equal(1, releases, "a startup that threw took the teardown down with it")
        end)
    end)

    -- What the guard puts back, driven through the four methods the host
    -- calls. The unit-level proofs are in `exceptions_spec`; these are here
    -- because the guard is the only finally the loop has, and a leak is only
    -- real once a whole frame has gone through it.
    describe("recovery", function()
        -- One entity, so extraction has something to write and the frame does
        -- real work rather than returning early.
        local function scene(world)
            world:spawn(
                tecs.Transform2D(32, 32, 0, 1, 0, 16, 16),
                components.Tint(1, 0, 0, 1),
                components.Renderable2D()
            )
        end

        it("settles structural work after a system throws", function()
            local explode = true
            local query
            local app = build({
                plugin = function(world)
                    scene(world)
                    query = world:newQuery({ name = "spec.Recovered", include = { components.Tint } })
                    world:addSystem({
                        name = "spec.ThrowsInIter",
                        phase = phases.Update,
                        run = function()
                            for _ in query:iter() do
                                if explode then
                                    error("iter boom")
                                end
                            end
                        end,
                    })
                end,
            })
            assert.is_true(app:_init())

            local open = passscope.openCount()
            app:_simulate(1 / 60)

            assert.is_truthy(app:crashed():match("iter boom"))
            assert.are.equal(open, passscope.openCount())

            -- Applied rather than staged, which is the difference a deferred
            -- world hides. Nothing has been unwound by hand here: the guard
            -- did it.
            local spawned = app.world:spawn(components.Tint(0, 1, 0, 1))
            app.world:enqueueCommit()
            assert.is_true(app.world:isAlive(spawned))

            explode = false
            app:_simulate(1 / 60)
            assert.are.equal("submitted", app._frame.state, "the frame after the crash did not draw")
            app:_shutdown()
        end)

        it("resolves the frame a throw between acquire and submit left open", function()
            local app = build({ plugin = scene })
            assert.is_true(app:_init())

            local open = passscope.openCount()
            local recorded = app.renderer.render
            app.renderer.render = function()
                error("render boom")
            end

            app:_simulate(1 / 60)

            assert.is_truthy(app:crashed():match("render boom"))
            local crashedFrame = app._frame
            assert.is_not_nil(crashedFrame, "the frame was not reachable from the application")
            -- Submitted rather than canceled: a swapchain texture had been
            -- acquired on it, and SDL documents canceling after that as an
            -- error.
            assert.is_true(crashedFrame.acquired)
            assert.are.equal("submitted", crashedFrame.state)
            assert.is_nil(crashedFrame.commandBuffer)
            assert.are.equal(open, passscope.openCount())

            -- The device holds one frame object and fills it in again per
            -- acquisition, so the next frame is this same table. What must not
            -- carry over is its state: the next iteration has to find it
            -- recording a command buffer of its own rather than still resolved.
            local recording
            app.renderer.render = function(renderer, frame)
                recording = frame.state
                return recorded(renderer, frame)
            end
            app:_simulate(1 / 60)
            assert.are.equal("recording", recording, "the next frame was handed the resolved one")
            assert.are.equal("submitted", app._frame.state)
            app:_shutdown()
        end)

        it("ends a compute pass a stage left open, and draws the frame after", function()
            local explode = true
            local openInside = -1
            local app = build({
                plugin = function(world, self)
                    scene(world)
                    self.renderer.sprites:addComputeStage({
                        active = function()
                            return true
                        end,
                        record = function(_, frame, instances)
                            if not explode then
                                return
                            end
                            ComputePass.begin(frame.commandBuffer, { instances.handle })
                            openInside = passscope.openCount()
                            error("stage boom")
                        end,
                        destroy = function() end,
                    })
                end,
            })
            assert.is_true(app:_init())

            local open = passscope.openCount()
            app:_simulate(1 / 60)

            assert.is_truthy(app:crashed():match("stage boom"))
            assert.are.equal(open + 1, openInside, "the stage's pass was never begun")
            assert.are.equal(open, passscope.openCount(), "the pass outlived the frame")
            assert.are.equal("submitted", app._frame.state)

            explode = false
            app:_simulate(1 / 60)
            assert.are.equal("submitted", app._frame.state)
            assert.are.equal(open, passscope.openCount())
            app:_shutdown()
        end)

        it("recovers from an instance producer that throws", function()
            local explode = true
            local app = build({
                plugin = function(world, self)
                    scene(world)
                    self.renderer.sprites:addProducer({
                        count = function()
                            return 4
                        end,
                        takeDirty = function()
                            return explode and { 1, 4 } or {}
                        end,
                        blended = function()
                            return 0
                        end,
                        casting = function()
                            return 0
                        end,
                        write = function()
                            error("producer boom")
                        end,
                    })
                end,
            })
            assert.is_true(app:_init())

            local open = passscope.openCount()
            app:_simulate(1 / 60)

            -- Extraction runs in RenderFirst, so this throws out of the update
            -- and no frame was ever acquired. What has to survive is the
            -- world, which was inside a query loop when the producer ran.
            assert.is_truthy(app:crashed():match("producer boom"))
            assert.are.equal(open, passscope.openCount())

            explode = false
            app:_simulate(1 / 60)
            assert.are.equal("submitted", app._frame.state)
            app:_shutdown()
        end)
    end)

    ---------------------------------------------------------------------------
    -- Resuming after a crash
    ---------------------------------------------------------------------------

    -- Resumption is a debugging affordance. It is allowed only while the
    -- world, device, and renderer remain healthy.
    describe("clearCrash", function()
        --- An application whose Update system throws until `stop` is called,
        --- and which counts the frames it ran to completion.
        local function crashing(config)
            local ran = 0
            local explode = true
            config.plugin = function(world)
                world:addSystem({
                    name = "spec.ThrowsOnDemand",
                    phase = phases.Update,
                    run = function()
                        if explode then
                            error("gameplay boom")
                        end
                        ran = ran + 1
                    end,
                })
            end
            local app = build(config)
            return app,
                function()
                    return ran
                end,
                function()
                    explode = false
                end
        end

        it("latches for good in a build that is neither debug nor served", function()
            local app, ran = crashing({})
            assert.is_true(app:_init())

            app:_iterate(nil, 0, nil)
            assert.is_truthy(app:crashed():match("gameplay boom"))

            local resumed, reason = app:clearCrash()
            assert.is_false(resumed, "a shipped build resumed after a crash")
            assert.is_truthy(reason:find("none of debug, mcpPort or watch", 1, true))
            assert.is_truthy(app:crashed(), "the traceback was cleared anyway")

            -- And it stays stopped, which is the behavior the gate exists for.
            app:_iterate(nil, 0, nil)
            assert.are.equal(0, ran())
            app:_shutdown()
        end)

        it("resumes a development build, and the loop simulates again", function()
            local app, ran, stop = crashing({ debug = true })
            assert.is_true(app:_init())

            app:_iterate(nil, 0, nil)
            assert.is_truthy(app:crashed():match("gameplay boom"))
            app:_iterate(nil, 0, nil)
            assert.are.equal(0, ran(), "a crashed loop went on simulating")

            stop()
            assert.is_true(app:clearCrash())
            assert.is_nil(app:crashed())
            assert.is_nil(mcp.crashed(), "the debug server was still told it had crashed")

            app:_iterate(nil, 0, nil)
            assert.are.equal(1, ran(), "the loop did not pick up after the fix")
            assert.are.equal("submitted", app._frame.state, "the frame after the resume did not draw")
            app:_shutdown()
        end)

        it("refuses when recovery had to force-end a pass", function()
            -- Severity is a second gate and a narrow one: this is the case
            -- where the device is not in the state the engine intended, so
            -- the next frame would be recorded against something nobody can
            -- describe. A development build makes no difference to it.
            local app = build({
                debug = true,
                plugin = function(world, self)
                    world:spawn(
                        tecs.Transform2D(32, 32, 0, 1, 0, 16, 16),
                        components.Tint(1, 0, 0, 1),
                        components.Renderable2D()
                    )
                    self.renderer.sprites:addComputeStage({
                        active = function()
                            return true
                        end,
                        record = function(_, frame, instances)
                            ComputePass.begin(frame.commandBuffer, { instances.handle })
                            error("stage boom")
                        end,
                        destroy = function() end,
                    })
                end,
            })
            assert.is_true(app:_init())

            local open = passscope.openCount()
            app:_iterate(nil, 0, nil)
            assert.is_truthy(app:crashed():match("stage boom"))
            assert.are.equal(open, passscope.openCount(), "the pass was not ended")

            local resumed, reason = app:clearCrash()
            assert.is_false(resumed, "resumed onto a device recovery had to force")
            assert.is_truthy(reason:find("force-ended", 1, true))
            assert.is_truthy(app:crashed())
            app:_shutdown()
        end)

        -- A watcher is the configuration that most wants to resume: a game
        -- running one is being edited, and reloading the file that threw is
        -- exactly the way back. It counted for neither gate until it did.
        it("resumes a build that only runs the file watcher", function()
            local app, ran, stop = crashing({ watch = { intervalSeconds = 0 } })
            assert.is_true(app:_init())

            app:_iterate(nil, 0, nil)
            assert.is_truthy(app:crashed():match("gameplay boom"))

            stop()
            assert.is_true(app:clearCrash(), "a build running only the watcher refused to carry on")
            app:_iterate(nil, 0, nil)
            assert.is_true(ran() > 0, "the loop did not simulate again")
            app:_shutdown()
        end)

        it("says nothing is wrong when nothing has crashed", function()
            local app = build({ debug = true })
            assert.is_true(app:_init())
            assert.is_true(app:clearCrash(), "a healthy application refused to carry on")
            app:_shutdown()
        end)

        -- A crashed game is not in a state to handle an event either, and an
        -- observer that throws while handling one produces a second traceback
        -- that replaces the first. The first is the one that explained the
        -- fault, and on the run where it happened it is all there is.
        it("delivers no event to game code after a crash, and keeps the first traceback", function()
            local observed = 0
            local app = build({
                debug = true,
                plugin = function(world)
                    world:observe(0, events.on.keyDown, function()
                        observed = observed + 1
                        error("observer boom")
                    end)
                    world:addSystem({
                        name = "spec.ThrowsFirst",
                        phase = phases.Update,
                        run = function()
                            error("system boom")
                        end,
                    })
                end,
            })
            assert.is_true(app:_init())

            app:_iterate(nil, 0, nil)
            assert.is_truthy(app:crashed():match("system boom"))

            iterateEvents(app, { { kind = "keyDown", scancode = 44, down = true } })
            assert.are.equal(0, observed, "an observer ran in a game that had stopped")
            assert.is_truthy(app:crashed():match("system boom"), "a later throw replaced the traceback")

            -- Engine folding is not gated with it, which is what keeps
            -- `send_event` useful after a crash: a window nobody can close is
            -- worse than one that is not drawing.
            app:_receive({ kind = "quit" })
            assert.is_true(app.quitRequested, "quit stopped working after a crash")

            -- And the observer is delivered to again once the crash is cleared.
            -- The host would stop after a real quit; reset this internal flag
            -- because this assertion deliberately keeps the same fixture.
            app.quitRequested = false
            app:clearCrash()
            iterateEvents(app, { { kind = "keyDown", scancode = 44, down = true } })
            assert.are.equal(1, observed, "clearing the crash did not restore delivery")
            app:_shutdown()
        end)

        -- Teardown deliberately runs `world:shutdown` on a crashed world. A
        -- second error there must not replace the gameplay traceback.
        it("keeps the first traceback through a teardown that throws as well", function()
            local app = build({
                plugin = function(world)
                    world:addSystem({
                        name = "spec.ThrowsInUpdate",
                        phase = phases.Update,
                        run = function()
                            error("original boom")
                        end,
                    })
                    world:addSystem({
                        name = "spec.ThrowsInShutdown",
                        phase = phases.Shutdown,
                        run = function()
                            error("teardown boom")
                        end,
                    })
                end,
            })
            assert.is_true(app:_init())

            app:_iterate(nil, 0, nil)
            assert.is_truthy(app:crashed():match("original boom"))

            assert.is_true(app:_shutdown())
            assert.is_truthy(app:crashed():match("original boom"), "the teardown's throw replaced the explanation")
        end)

        it("holds simulated time still while the loop is not simulating", function()
            local app, _, stop = crashing({ debug = true })
            assert.is_true(app:_init())

            app:_iterate(nil, 0, nil)
            local stopped = app.elapsed
            for _ = 1, 5 do
                app:_iterate(nil, 0, nil)
            end
            assert.are.equal(stopped, app.elapsed, "elapsed counted a fix nobody simulated")

            stop()
            app:clearCrash()
            app:_iterate(nil, 0, nil)
            assert.is_true(app.elapsed > stopped, "elapsed stopped advancing after the resume")
            app:_shutdown()
        end)
    end)

    ---------------------------------------------------------------------------
    -- The platform lifecycle
    ---------------------------------------------------------------------------

    -- SDL dispatches these six from its event watcher rather than queueing
    -- them, and the host calls one method per event at the instant it arrives;
    -- `host_spec` covers that dispatch against the real binary. What is here is
    -- what the methods do, which is reachable in process.
    describe("the platform lifecycle", function()
        local function removeCheckpoint()
            local path = files.writablePath(CHECKPOINT)
            files.remove(path)
            files.remove(path .. ".new")
        end

        before_each(removeCheckpoint)
        after_each(removeCheckpoint)

        it("suspends on backgrounding and unsuspends on foregrounding", function()
            local app = build({})
            assert.is_true(app:_init())

            app:_willEnterBackground()
            assert.is_true(app.suspended)

            -- Suspended, so the loop runs without simulating.
            local ran = app.frame
            app:_iterate(nil, 0, nil)
            assert.are.equal(ran + 1, app.frame)
            assert.are.equal(0, app.elapsed, "a suspended iteration advanced simulated time")

            app:_didEnterForeground()
            assert.is_false(app.suspended)
            app:_shutdown()
        end)

        -- On Android the process blocks as soon as backgrounding is
        -- dispatched. Lifecycle hooks therefore update suspension before the
        -- queued events are drained.
        it("does not fold the queued lifecycle events into suspension", function()
            local app = build({})
            assert.is_true(app:_init())

            app:_receive({ kind = "appWillEnterBackground" })
            assert.is_false(app.suspended, "the drain suspended instead of the hook")

            app:_willEnterBackground()
            app:_receive({ kind = "appDidEnterForeground" })
            assert.is_true(app.suspended, "the drain unsuspended instead of the hook")
            app:_shutdown()
        end)

        it("restarts the clock on foregrounding rather than integrating the gap", function()
            local app = build({})
            assert.is_true(app:_init())
            app:_iterate(nil, 0, nil)

            -- A suspension the platform did not tell us the length of, stood in
            -- for by a stall. Without the reset the first step afterwards
            -- carries the whole of it.
            app:_willEnterBackground()
            local until_ = time.now() + 0.05
            while time.now() < until_ do
            end
            app:_didEnterForeground()

            local dt = time.step()
            assert.is_true(dt < 0.02, ("the gap was integrated: dt was %.3f s"):format(dt))
            app:_shutdown()
        end)

        it("collects on low memory", function()
            local app = build({})
            assert.is_true(app:_init())

            -- Garbage the collector has not reached yet, so there is something
            -- for the hook to give back rather than a no-op that always passes.
            local waste = {}
            for index = 1, 20000 do
                waste[index] = { index }
            end
            waste = nil
            local before = collectgarbage("count")
            app:_lowMemory()
            assert.is_true(collectgarbage("count") < before, "low memory gave nothing back")
            app:_shutdown()
        end)

        it("survives a backgrounding and a foregrounding, and draws afterwards", function()
            local app = build({
                plugin = function(world)
                    world:spawn(
                        tecs.Transform2D(32, 32, 0, 1, 0, 16, 16),
                        components.Tint(1, 0, 0, 1),
                        components.Renderable2D()
                    )
                end,
            })
            assert.is_true(app:_init())
            app:_iterate(nil, 0, nil)

            app:_willEnterBackground()
            app:_didEnterBackground()
            app:_didEnterForeground()

            app:_iterate(nil, 0, nil)
            assert.are.equal("submitted", app._frame.state, "the frame after the resume did not draw")
            app:_shutdown()
        end)
    end)

    ---------------------------------------------------------------------------
    -- The checkpoint
    ---------------------------------------------------------------------------

    -- A game could not save state on being backgrounded at all: the host copied
    -- the event and returned, and there was no hook to call. The contract is
    -- the interesting half. At this project's scale a world is not serializable
    -- inside a platform callback, so the surface takes bytes the game already
    -- prepared and cannot be handed a function that would defer the expensive
    -- part into exactly the callback that cannot afford it.
    describe("the checkpoint", function()
        local function removeCheckpoint()
            local path = files.writablePath(CHECKPOINT)
            files.remove(path)
            files.remove(path .. ".new")
        end

        before_each(removeCheckpoint)
        after_each(removeCheckpoint)

        it("writes what a frame staged when the platform backgrounds us", function()
            local app = build({ checkpoint = CHECKPOINT })
            assert.is_true(app:_init())

            assert.is_nil(app:readCheckpoint(), "a first run found a checkpoint")
            app:stageCheckpoint("level=3;hp=41")

            -- Nothing is written until the platform asks, because the frame
            -- that prepared it is not the moment there is a deadline.
            assert.is_false(files.exists(files.writablePath(CHECKPOINT)))

            app:_willEnterBackground()
            assert.are.equal("level=3;hp=41", app:readCheckpoint())
            app:_shutdown()
        end)

        it("hands the next run what the last one left", function()
            local first = build({ checkpoint = CHECKPOINT })
            assert.is_true(first:_init())
            first:stageCheckpoint("carried over")
            first:_willEnterBackground()
            first:_shutdown()

            local restored
            local second = build({
                checkpoint = CHECKPOINT,
                plugin = function(_, app)
                    restored = app:readCheckpoint()
                end,
            })
            assert.is_true(second:_init())
            assert.are.equal("carried over", restored, "the plugin could not read the last run's checkpoint")
            second:_shutdown()
        end)

        it("leaves nothing half written and no scratch file behind", function()
            local app = build({ checkpoint = CHECKPOINT })
            assert.is_true(app:_init())
            app:stageCheckpoint(("x"):rep(4096))
            app:_willEnterBackground()

            assert.are.equal(4096, #app:readCheckpoint())
            assert.is_false(
                files.exists(files.writablePath(CHECKPOINT) .. ".new"),
                "the file the write goes through was left on disk"
            )
            app:_shutdown()
        end)

        -- One write per staging, on the same argument the host deduplicates
        -- backgroundings with: the second write is the one that gets
        -- interrupted, and it had nothing new to say.
        it("writes once for one staging, however many backgroundings", function()
            local app = build({ checkpoint = CHECKPOINT })
            assert.is_true(app:_init())

            app:stageCheckpoint("first")
            app:_willEnterBackground()
            files.remove(files.writablePath(CHECKPOINT))

            app:_willEnterBackground()
            assert.is_nil(app:readCheckpoint(), "a backgrounding with nothing staged wrote again")

            app:stageCheckpoint("second")
            app:_willEnterBackground()
            assert.are.equal("second", app:readCheckpoint())
            app:_shutdown()
        end)

        -- A termination out of the foreground never went through a
        -- backgrounding, so this is the only call a game gets.
        it("flushes on termination as well as on backgrounding", function()
            local app = build({ checkpoint = CHECKPOINT })
            assert.is_true(app:_init())

            app:stageCheckpoint("dying words")
            app:_terminating()
            assert.are.equal("dying words", app:readCheckpoint())
            app:_shutdown()
        end)

        -- Holding bytes that will never be written is the one failure a game
        -- would not notice, so it is the one thing here that raises.
        it("refuses to stage when no checkpoint file was configured", function()
            local app = build({})
            assert.is_true(app:_init())

            assert.is_nil(app:checkpointPath())
            assert.is_nil(app:readCheckpoint())
            local ok, reason = pcall(app.stageCheckpoint, app, "nowhere to put this")
            assert.is_false(ok)
            assert.is_truthy(tostring(reason):find("no checkpoint file is configured", 1, true))
            app:_shutdown()
        end)
    end)

    ---------------------------------------------------------------------------
    -- The configuration surface
    ---------------------------------------------------------------------------

    describe("configuration", function()
        after_each(function()
            log.closeFile()
        end)

        -- The file exists for the debug server: `get_logs` is a seek and a read
        -- because of it. `mcpPort` is opt-in on the rule that a game should not
        -- open a socket nobody asked for, and a file nobody asked for is the
        -- same thing on disk, so the file follows the thing that reads it.
        it("writes no log file for a game that asked for neither a server nor debug", function()
            local app = build({})
            assert.is_true(app:_init())
            assert.is_nil(log.filePath(), "a game got a file on a user's disk without asking")
            app:_shutdown()
        end)

        it("writes one for a debug build", function()
            local app = build({ debug = true })
            assert.is_true(app:_init())
            assert.is_truthy(log.filePath())
            assert.is_truthy(log.filePath():find("log.jsonl", 1, true))
            app:_shutdown()
        end)

        it("writes the one a game named, whatever else is set", function()
            local app = build({ logFile = "spec-named.jsonl" })
            assert.is_true(app:_init())
            assert.is_truthy(log.filePath():find("spec-named.jsonl", 1, true))
            app:_shutdown()
            files.remove(files.writablePath("spec-named.jsonl"))
        end)

        it("sets the log level before anything has had a chance to speak", function()
            local logger = log.get("spec.level")
            logger:setLevel(log.TRACE)
            local app = build({ logLevel = log.ERROR })
            assert.is_true(app:_init())

            assert.is_false(logger:enabled(log.INFO), "an INFO message would still be emitted")
            assert.is_true(logger:enabled(log.ERROR))
            app:_shutdown()
            log.setLevel(log.INFO)
        end)

        -- White preserves each sprite's authored color before lights add to it.
        it("lights an unlit scene at full ambient", function()
            local app = build({})
            assert.is_true(app:_init())
            assert.are.same({ 1.0, 1.0, 1.0 }, app.renderer.deferred.ambient)
            app:_shutdown()
        end)

        it("takes the ambient a game named", function()
            local app = build({ ambientLight = { 0.2, 0.3, 0.4 } })
            assert.is_true(app:_init())
            assert.are.same({ 0.2, 0.3, 0.4 }, app.renderer.deferred.ambient)
            app:_shutdown()
        end)

        -- The world's fixed step had no route through the application at all:
        -- `newWorld` was handed `maxEntities` and nothing else, so a game
        -- could not set its own timestep however much it wanted to. The
        -- absence of a spec is why nobody noticed.
        it("hands the world the fixed step a game configured", function()
            local app = build({
                timestep = 1 / 8,
                fixedMaxSteps = 3,
                fixedOverload = "accumulate",
            })
            assert.is_true(app:_init())

            local timestep = app.world:getFixedTiming()
            assert.are.equal(1 / 8, timestep)
            assert.are.equal(3, app.world.pipeline.fixedMaxSteps)
            assert.are.equal("accumulate", app.world.pipeline.fixedOverload)
            app:_shutdown()
        end)

        it("leaves the fixed step at its defaults when a game says nothing", function()
            local app = build({})
            assert.is_true(app:_init())

            local timestep = app.world:getFixedTiming()
            assert.are.equal(1 / 60, timestep)
            assert.are.equal(10, app.world.pipeline.fixedMaxSteps)
            assert.are.equal("drop", app.world.pipeline.fixedOverload)
            app:_shutdown()
        end)

        it("stops the loop after debugMaxFrames iterations", function()
            local app = build({ debugMaxFrames = 3 })
            assert.is_true(app:_init())

            assert.is_true(app:_iterate(nil, 0, nil))
            assert.is_true(app:_iterate(nil, 0, nil))
            assert.is_false(app:_iterate(nil, 0, nil), "the run did not stop where it was told to")
            app:_shutdown()
        end)
    end)
end)
