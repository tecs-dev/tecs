require("busted")

local luassert <const> = require("luassert")
local tecs <const> = require("tecs")

-- Installs the love global used by the input handlers
require("spec.love2d.love2d_mock")

local input <const> = require("tecs2d.input")
local events <const> = require("tecs2d.events")
local handlers <const> = require("tecs2d.internal.handlers")

local lazyInitCount = 0
local record LazyInputEvent is tecs.Event
    value: integer
    metamethod __call: function(self, value: integer): LazyInputEvent
end
LazyInputEvent.init = function(event: LazyInputEvent, value: integer)
    lazyInitCount = lazyInitCount + 1
    event.value = value
end
tecs.newEvent(LazyInputEvent)

describe("tecs2d.input handlers", function()
    before_each(function()
        input.update()
    end)

    describe("wheelmoved", function()
        it("accumulates multiple wheel events within one frame", function()
            local wheelmoved <const> = handlers.handlers["wheelmoved"]
            wheelmoved(nil, 0, 1, "standard")
            wheelmoved(nil, 1, 2, "standard")
            wheelmoved(nil, 0, -0.5, "standard")

            local x, y, direction = input.getMouseWheelMovement()
            luassert.equals(1, x)
            luassert.equals(2.5, y)
            luassert.equals("standard", direction)
        end)

        it("resets accumulated movement on update", function()
            local wheelmoved <const> = handlers.handlers["wheelmoved"]
            wheelmoved(nil, 3, 4, "standard")
            input.update()

            local x, y = input.getMouseWheelMovement()
            luassert.equals(0, x)
            luassert.equals(0, y)
        end)
    end)

    describe("input layers", function()
        after_each(function()
            while input.topLayer() ~= input.base do
                input.popLayer(input.topLayer())
            end
        end)

        it("suppresses the game while a layer is pushed and restores on pop", function()
            input.keysPressed["f"] = true
            luassert.is_true(input.isKeyPressed("f"))            -- game sees it

            local layer = input.newLayer("menu")
            input.pushLayer(layer)
            input.keysPressed["g"] = true                        -- input during the layer
            luassert.is_false(input.isKeyPressed("g"))           -- game (base) dark
            luassert.is_true(layer.view.isKeyPressed("g"))       -- the layer sees it

            input.popLayer(layer)
            input.keysPressed["h"] = true                        -- input after handing back
            luassert.is_true(input.isKeyPressed("h"))            -- game reads it again
        end)

        it("gives real input only to the top layer", function()
            local a = input.newLayer("top-a")
            local b = input.newLayer("top-b")
            input.pushLayer(a)
            input.pushLayer(b)
            input.keysPressed["f"] = true

            luassert.is_true(b.view.isKeyPressed("f"))           -- top sees real
            luassert.is_false(a.view.isKeyPressed("f"))          -- lower layer dark
            luassert.is_false(input.isKeyPressed("f"))           -- game dark

            input.popLayer(b)
            input.keysPressed["f"] = true
            luassert.is_true(a.view.isKeyPressed("f"))           -- a is now top
        end)

        it("pops a middle layer by stable handle and rewires its child", function()
            local a = input.newLayer("middle-a")
            local b = input.newLayer("middle-b")
            input.pushLayer(a)
            input.pushLayer(b)

            luassert.is_true(input.popLayer(a))
            luassert.equals(input.base, b.parent)
            luassert.equals(b, input.topLayer())
            luassert.equals(1, input.layerCount())
            luassert.is_false(a:isActive())
            luassert.is_true(b:isTop())
        end)

        it("consumes latched input taken while a layer was up", function()
            -- Reproduces the fullscreen-on-close bug: an "f" release recorded
            -- while the debugger layer was up must not fire for the game when the
            -- layer pops and a fixed-update phase reads it.
            local layer = input.newLayer("latched-modal")
            input.pushLayer(layer)
            input.keysLatchedReleased["f"] = true
            input.popLayer(layer)

            input.enterFixedPhase()
            local released = input.isKeyReleased("f")
            input.exitFixedPhase()
            luassert.is_false(released)
        end)

        it("rejects duplicate pushes and makes repeated pops harmless", function()
            local layer = input.newLayer("duplicate-modal")
            input.pushLayer(layer)
            luassert.has_error(function() input.pushLayer(layer) end)
            luassert.is_true(input.popLayer(layer))
            luassert.is_false(input.popLayer(layer))
        end)

        it("requires a non-empty unique layer name", function()
            input.bindWorld(tecs.newWorld())
            local newLayer = input.newLayer as function(any, input.LayerOptions): input.Layer
            luassert.has_error(function() newLayer(nil, nil) end)
            luassert.has_error(function() newLayer("", nil) end)

            input.newLayer("unique-layer")
            luassert.has_error(function() input.newLayer("unique-layer") end)
            luassert.has_error(function() input.newLayer("base") end)
            luassert.has_error(function() input.newLayer("raw") end)
        end)

        it("keeps runtime layers above snapshot-managed game layers", function()
            input.bindWorld(tecs.newWorld())
            local game = input.newLayer("lane-game")
            local tool = input.newLayer("lane-tool", {snapshot = false})
            local toolLost = 0
            tool:observe(events.InputCaptureLost, function()
                toolLost = toolLost + 1
            end)

            input.pushLayer(tool)
            input.pushLayer(game)

            luassert.equals(tool, input.topLayer())
            luassert.equals(game, tool.parent)
            luassert.equals(input.base, game.parent)
            luassert.is_false(game.view.isKeyDown("space"))
            luassert.equals(0, toolLost)

            input.popLayer(tool)
            luassert.equals(game, input.topLayer())
            luassert.is_true(game:isTop())
        end)

        it("round-trips nested game-layer topology through snapshots", function()
            local world = tecs.newWorld()
            input.bindWorld(world)
            local menu = input.newLayer("snapshot-menu")
            local dialog = input.newLayer("snapshot-dialog")
            input.pushLayer(menu)
            input.pushLayer(dialog)
            local snapshot = world:saveSnapshot({format = "table"}).snapshot

            input.popLayer(dialog)
            input.popLayer(menu)
            luassert.equals(input.base, input.topLayer())

            world:loadSnapshot(snapshot)
            luassert.equals(dialog, input.topLayer())
            luassert.equals(menu, dialog.parent)
            luassert.equals(input.base, menu.parent)
            luassert.is_true(menu:isActive())
            luassert.is_true(dialog:isActive())
        end)

        it("round-trips game layers through the default binary snapshot", function()
            local world = tecs.newWorld()
            input.bindWorld(world)
            local inventory = input.newLayer("binary-inventory")
            input.pushLayer(inventory)
            local buffer = world:saveSnapshot().buffer

            input.popLayer(inventory)
            world:loadSnapshot(buffer)

            luassert.equals(inventory, input.topLayer())
            luassert.is_true(inventory:isActive())
        end)

        it("does not restore runtime-only layers saved while open", function()
            local world = tecs.newWorld()
            input.bindWorld(world)
            local tool = input.newLayer("unsaved-runtime-tool", {snapshot = false})
            input.pushLayer(tool)
            local snapshot = world:saveSnapshot({format = "table"}).snapshot

            input.popLayer(tool)
            world:loadSnapshot(snapshot)

            luassert.equals(input.base, input.topLayer())
            luassert.is_false(tool:isActive())
        end)

        it("restores game layers beneath a live runtime overlay", function()
            local world = tecs.newWorld()
            input.bindWorld(world)
            local pause = input.newLayer("snapshot-pause")
            local debugger = input.newLayer("snapshot-debugger", {snapshot = false})
            input.pushLayer(pause)
            local pausedSnapshot = world:saveSnapshot({format = "table"}).snapshot
            input.popLayer(pause)
            input.pushLayer(debugger)

            world:loadSnapshot(pausedSnapshot)
            luassert.equals(debugger, input.topLayer())
            luassert.equals(pause, debugger.parent)
            luassert.equals(input.base, pause.parent)
            luassert.is_true(pause:isActive())

            input.popLayer(debugger)
            luassert.equals(pause, input.topLayer())
        end)

        it("removes stale game layers without disturbing a runtime overlay", function()
            local world = tecs.newWorld()
            input.bindWorld(world)
            local game = input.newLayer("snapshot-stale-game")
            local tool = input.newLayer("snapshot-stale-tool", {snapshot = false})
            local gameplaySnapshot = world:saveSnapshot({format = "table"}).snapshot
            input.pushLayer(game)
            input.pushLayer(tool)

            world:loadSnapshot(gameplaySnapshot)
            luassert.equals(tool, input.topLayer())
            luassert.equals(input.base, tool.parent)
            luassert.is_false(game:isActive())
        end)

        it("resolves saved names to handles created for a new world", function()
            local oldWorld = tecs.newWorld()
            input.bindWorld(oldWorld)
            local oldLayer = input.newLayer("cross-world-menu")
            input.pushLayer(oldLayer)
            local snapshot = oldWorld:saveSnapshot({format = "table"}).snapshot

            local newWorld = tecs.newWorld()
            input.bindWorld(newWorld)
            local restoredLayer = input.newLayer("cross-world-menu")
            newWorld:loadSnapshot(snapshot)

            luassert.is_false(oldLayer:isActive())
            luassert.is_true(restoredLayer:isActive())
            luassert.equals(restoredLayer, input.topLayer())
        end)

        it("fails clearly when a saved layer was not registered", function()
            local oldWorld = tecs.newWorld()
            input.bindWorld(oldWorld)
            local layer = input.newLayer("missing-after-load")
            input.pushLayer(layer)
            local snapshot = oldWorld:saveSnapshot({format = "table"}).snapshot

            local newWorld = tecs.newWorld()
            input.bindWorld(newWorld)
            luassert.has_error(function()
                newWorld:loadSnapshot(snapshot)
            end, "tecs2d.input snapshot references an unregistered layer: missing-after-load")
        end)

        it("defers snapshot topology changes until input dispatch finishes", function()
            local world = tecs.newWorld()
            input.bindWorld(world)
            local game = input.newLayer("dispatch-restored-game")
            local tool = input.newLayer("dispatch-runtime-tool", {snapshot = false})
            input.pushLayer(game)
            local snapshot = world:saveSnapshot({format = "table"}).snapshot
            input.popLayer(game)

            local activeDuringDispatch = true
            tool:observe(events.KeyPressed, function()
                world:loadSnapshot(snapshot)
                activeDuringDispatch = game:isActive()
            end)
            input.pushLayer(tool)

            handlers.handlers["keypressed"](world, "space", "space", false)
            luassert.is_false(activeDuringDispatch)
            luassert.is_true(game:isActive())
            luassert.equals(tool, input.topLayer())
            luassert.equals(game, tool.parent)
        end)

        it("defers snapshot topology changes through the lazy base route", function()
            local world = tecs.newWorld()
            input.bindWorld(world)
            local game = input.newLayer("base-dispatch-restored-game")
            input.pushLayer(game)
            local snapshot = world:saveSnapshot({format = "table"}).snapshot
            input.popLayer(game)

            local activeDuringDispatch = true
            world:observe(0, events.KeyPressed, function()
                world:loadSnapshot(snapshot)
                activeDuringDispatch = game:isActive()
            end)

            handlers.handlers["keypressed"](world, "space", "space", false)
            luassert.is_false(activeDuringDispatch)
            luassert.is_true(game:isActive())
            luassert.equals(game, input.topLayer())
        end)

        it("defers snapshot topology changes until a capture transition finishes", function()
            local world = tecs.newWorld()
            input.bindWorld(world)
            local menu = input.newLayer("capture-restored-menu")
            local trigger = input.newLayer("capture-restore-trigger")
            input.pushLayer(menu)
            local snapshot = world:saveSnapshot({format = "table"}).snapshot
            input.popLayer(menu)

            local loaded = false
            world:observe(0, events.InputCaptureLost, function()
                if loaded then return end
                loaded = true
                world:loadSnapshot(snapshot)
                luassert.is_false(menu:isActive())
            end)

            input.pushLayer(trigger)

            luassert.is_true(loaded)
            luassert.is_false(trigger:isActive())
            luassert.is_true(menu:isActive())
            luassert.equals(menu, input.topLayer())
        end)

        it("routes to the top only and forwards explicitly to its parent", function()
            local world = tecs.newWorld()
            input.bindWorld(world)
            local layer = input.newLayer("forward-overlay")
            local topCount, baseCount = 0, 0
            world:observe(0, events.KeyPressed, function()
                baseCount = baseCount + 1
            end)
            layer:observe(events.KeyPressed, function(event)
                topCount = topCount + 1
                layer.parent:emit(event)
            end)
            input.pushLayer(layer)

            handlers.handlers["keypressed"](world, "space", "space", false)
            luassert.equals(1, topCount)
            luassert.equals(1, baseCount)
        end)

        it("delivers each physical event to a forwarded target at most once", function()
            local world = tecs.newWorld()
            input.bindWorld(world)
            local layer = input.newLayer("dedupe-overlay")
            local baseCount = 0
            world:observe(0, events.KeyPressed, function()
                baseCount = baseCount + 1
            end)
            layer:observe(events.KeyPressed, function(event)
                layer.parent:emit(event)
            end)
            layer:observe(events.KeyPressed, function(event)
                layer.parent:emit(event)
            end)
            input.pushLayer(layer)

            handlers.handlers["keypressed"](world, "space", "space", false)
            luassert.equals(1, baseCount)
        end)

        it("can pop itself and still forward through its dispatch-stable parent", function()
            local world = tecs.newWorld()
            input.bindWorld(world)
            local layer = input.newLayer("popover")
            local baseCount = 0
            world:observe(0, events.MousePressed, function()
                baseCount = baseCount + 1
            end)
            layer:observe(events.MousePressed, function(event)
                input.popLayer(layer)
                layer.parent:emit(event)
            end)
            input.pushLayer(layer)

            handlers.handlers["mousepressed"](world, 1, 2, 1, false, 1)
            luassert.equals(1, baseCount)
            luassert.equals(input.base, input.topLayer())
        end)

        it("does not construct an event when no reachable target observes it", function()
            local world = tecs.newWorld()
            local layer = input.newLayer("empty-modal")
            input.pushLayer(layer)
            lazyInitCount = 0

            input.route(world, LazyInputEvent, 42)
            luassert.equals(0, lazyInitCount)

            local value = 0
            layer:observe(LazyInputEvent, function(event)
                value = event.value
            end)
            input.route(world, LazyInputEvent, 42)
            luassert.equals(1, lazyInitCount)
            luassert.equals(42, value)
        end)

        it("intercepts by omitting the parent emit", function()
            local world = tecs.newWorld()
            input.bindWorld(world)
            local layer = input.newLayer("intercept-modal")
            local topCount, baseCount = 0, 0
            world:observe(0, events.MousePressed, function()
                baseCount = baseCount + 1
            end)
            layer:observe(events.MousePressed, function()
                topCount = topCount + 1
            end)
            input.pushLayer(layer)

            handlers.handlers["mousepressed"](world, 12, 34, 1, false, 1)
            luassert.equals(1, topCount)
            luassert.equals(0, baseCount)
        end)

        it("delivers raw input regardless of the top layer", function()
            local world = tecs.newWorld()
            local layer = input.newLayer("raw-modal")
            local rawCount = 0
            local callback = function(_event: events.KeyPressed)
                rawCount = rawCount + 1
            end
            input.raw:observe(events.KeyPressed, callback)
            input.pushLayer(layer)

            handlers.handlers["keypressed"](world, "r", "r", false)
            luassert.equals(1, rawCount)
            input.raw:stopObserving(events.KeyPressed, callback)
        end)

        it("emits capture lifecycle events only when the top changes", function()
            local world = tecs.newWorld()
            input.bindWorld(world)
            local a = input.newLayer("lifecycle-a")
            local b = input.newLayer("lifecycle-b")
            local transitions: {string} = {}
            world:observe(0, events.InputCaptureLost, function(event)
                transitions[#transitions + 1] = "lost:" .. event.from .. ">" .. event.to
            end)
            world:observe(0, events.InputCaptureGained, function(event)
                transitions[#transitions + 1] = "gained:" .. event.from .. ">" .. event.to
            end)
            a:observe(events.InputCaptureGained, function(event)
                transitions[#transitions + 1] = "a+:" .. event.from .. ">" .. event.to
            end)
            a:observe(events.InputCaptureLost, function(event)
                transitions[#transitions + 1] = "a-:" .. event.from .. ">" .. event.to
            end)
            b:observe(events.InputCaptureGained, function(event)
                transitions[#transitions + 1] = "b+:" .. event.from .. ">" .. event.to
            end)
            b:observe(events.InputCaptureLost, function(event)
                transitions[#transitions + 1] = "b-:" .. event.from .. ">" .. event.to
            end)

            input.pushLayer(a)
            input.pushLayer(b)
            input.popLayer(a) -- middle pop does not change capture
            input.popLayer(b)

            luassert.same({
                "lost:base>lifecycle-a", "a+:base>lifecycle-a",
                "a-:lifecycle-a>lifecycle-b", "b+:lifecycle-a>lifecycle-b",
                "b-:lifecycle-b>base", "gained:lifecycle-b>base",
            }, transitions)
        end)

        it("routes text, motion, wheel, controller, joystick, and touch callbacks", function()
            local world = tecs.newWorld()
            local layer = input.newLayer("device-events")
            local seen: {string: boolean} = {}
            local joystick = {} as love.joystick.Joystick
            layer:observe(events.TextInput, function(event)
                seen.text = event.text == "x"
            end)
            layer:observe(events.MouseMoved, function(event)
                seen.motion = event.x == 10 and event.dx == 2
            end)
            layer:observe(events.WheelMoved, function(event)
                seen.wheel = event.y == -1 and event.direction == "flick"
            end)
            layer:observe(events.GamepadAxis, function(event)
                seen.axis = event.joystick == joystick and event.axis == "leftx" and event.value == 0.5
            end)
            layer:observe(events.GamepadPressed, function(event)
                seen.gamepad = event.button == "a"
            end)
            layer:observe(events.JoystickPressed, function(event)
                seen.joystick = event.button == 3
            end)
            layer:observe(events.JoystickHat, function(event)
                seen.hat = event.hat == 1 and event.direction == "u"
            end)
            layer:observe(events.TouchPressed, function(event)
                seen.touch = event.id == 7 and event.deviceType == "touchscreen"
            end)
            input.pushLayer(layer)

            handlers.handlers["textinput"](world, "x")
            handlers.handlers["mousemoved"](world, 10, 20, 2, 3, false)
            handlers.handlers["wheelmoved"](world, 0, -1, "flick")
            handlers.handlers["gamepadaxis"](world, joystick, "leftx", 0.5)
            handlers.handlers["gamepadpressed"](world, joystick, "a")
            handlers.handlers["joystickpressed"](world, joystick, 3)
            handlers.handlers["joystickhat"](world, joystick, 1, "u")
            handlers.handlers["touchpressed"](
                world, 7, 0.2, 0.3, 0, 0, 1, "touchscreen", false
            )

            luassert.same({
                text = true,
                motion = true,
                wheel = true,
                axis = true,
                gamepad = true,
                joystick = true,
                hat = true,
                touch = true,
            }, seen)
        end)
    end)
end)
