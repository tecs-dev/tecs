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
end)
