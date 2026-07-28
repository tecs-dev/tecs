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
local passscope = require("tecs.gpu.passscope")
local ComputePass = require("tecs.gpu.ComputePass")

local FIXTURE = "spec/fixtures/split.png"

--- An application with a window small enough to be cheap and no log file.
local function build(config)
    config.window = { title = "application", width = 64, height = 64 }
    config.logFile = ""
    return Application.create(config)
end

describe("Application", function()
    it("resolves asset handles without the game pumping them", function()
        local handle
        local app = build({
            plugin = function()
                assets.install()
                handle = assets.loadImage(FIXTURE)
            end,
        })
        assert.is_true(app:_init())
        assert.are.equal("loading", handle.status)

        -- Nothing in this application draws text or plays a sound, so the two
        -- subsystems with pumps of their own never run. Only the loop's own
        -- call can move this handle.
        for _ = 1, 200 do
            if handle.status ~= "loading" then
                break
            end
            app:_iterate(nil, 0, nil)
        end

        assert.are.equal("ready", handle.status, "the loop never drained the loading worker")
        assert.is_not_nil(handle.pixels)
        handle:release()

        app:_shutdown()
    end)

    it("stops the loading worker at shutdown", function()
        local app = build({
            plugin = function()
                assets.install()
            end,
        })
        assert.is_true(app:_init())
        assert.is_true(assets.installed())

        app:_shutdown()
        assert.is_false(assets.installed(), "the decoding thread outlived the application")
    end)

    it("shuts down cleanly when nothing ever loaded an asset", function()
        local app = build({})
        assert.is_true(app:_init())
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
        assert.is_false(packed.renderer:reservesRuns())
        packed:_shutdown()

        local reserved = build({ reserveRuns = true })
        assert.is_true(reserved:_init())
        assert.is_true(reserved.renderer:reservesRuns(), "a game asking for reserved runs gets them")
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

            app:_receive({ kind = "keyDown", scancode = 44, down = true })

            assert.are.equal(1, keys)
            assert.are.equal(0, drops, "an observer was called for a kind it did not ask for")
            app:_shutdown()
        end)

        it("hands the observer the record itself rather than a copy", function()
            -- Delivery costs one field store and no copy, which is what makes
            -- a device-rate stream affordable. The borrow rule that follows
            -- from it is the one this vocabulary already had.
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
            app:_receive(sent)

            assert.is_true(rawequal(sent, received), "the event was copied on its way to the observer")
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

            app:_receive({
                kind = "keyDown",
                scancode = app.input:scancode("space"),
                down = true,
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

        it("survives an observer that throws", function()
            local app = build({
                plugin = function(world)
                    world:observe(0, events.on.keyDown, function()
                        error("observer boom")
                    end)
                end,
            })
            assert.is_true(app:_init())

            app:_receive({ kind = "keyDown", scancode = 44, down = true })

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
                components.Transform(32, 32, 0, 1, 0, 16, 16),
                components.Tint(1, 0, 0, 1),
                components.Renderable()
            )
        end

        it("unwinds the scope a system threw out of", function()
            local explode = true
            local query
            local app = build({
                plugin = function(world)
                    scene(world)
                    query = world:query({ name = "spec.Recovered", include = { components.Tint } })
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
            assert.are.equal(0, app.world._scopeDepth, "the world was left deferred")
            assert.are.equal(open, passscope.openCount())

            -- Applied rather than staged, which is the difference a deferred
            -- world hides. Nothing has been unwound by hand here: the guard
            -- did it.
            local spawned = app.world:spawn(components.Tint(0, 1, 0, 1))
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
            -- Submitted rather than cancelled: a swapchain texture had been
            -- acquired on it, and SDL documents cancelling after that as an
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
                    self.renderer:addComputeStage({
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
                    self.renderer:addProducer({
                        count = function()
                            return 4
                        end,
                        takeDirty = function()
                            return explode and { 1, 4 } or {}
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
            assert.are.equal(0, app.world._scopeDepth)
            assert.are.equal(open, passscope.openCount())

            explode = false
            app:_simulate(1 / 60)
            assert.are.equal("submitted", app._frame.state)
            app:_shutdown()
        end)
    end)
end)
