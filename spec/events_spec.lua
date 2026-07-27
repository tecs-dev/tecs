-- The typed event stream.
--
-- This is the conversion every platform shares, so a mistake here is a mistake
-- everywhere. The tests build real SDL_Event values and check what the engine
-- reports for them, because the whole point of the layer is that nothing above
-- it ever sees the union.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. package.path

local sdl = require("tecs.ffi.sdl3")
local loader = require("tecs.ffi.loader")
local events = require("tecs.platform.events")

local C = sdl.C

-- A queue the host would have filled, so drain sees what it sees live.
local function queueOf(fill, count)
    local queue = loader.newArray("SDL_Event[?]", count or 1)
    fill(queue)
    return queue, count or 1
end

local function drainOne(queue, count)
    local seen = {}
    events.drain(queue, count, function(event)
        seen[#seen + 1] = events.copy(event)
    end)
    return seen
end

describe("platform.events", function()
    after_each(function()
        events.source = nil
    end)

    it("names every kind it recognises", function()
        local kinds = {}
        for _, kind in ipairs(events.kinds()) do kinds[kind] = true end

        -- Desktop and mobile lifecycle share one vocabulary.
        assert.is_true(kinds.quit)
        assert.is_true(kinds.keyDown)
        assert.is_true(kinds.mouseMotion)
        assert.is_true(kinds.gamepadAxis)
        assert.is_true(kinds.appWillEnterBackground)
        assert.is_true(kinds.appDidEnterForeground)
        assert.is_true(kinds.lowMemory)
        assert.is_true(kinds.fingerDown)
        assert.is_true(kinds.textInput)
        assert.is_true(kinds.penMotion)
        assert.is_true(kinds.gamepadTouchpadDown)

        -- Named after the device rather than after the interface SDL retired.
        assert.is_nil(kinds.controllerAxis)
    end)

    it("converts a key press, including the repeat flag", function()
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_KEY_DOWN
            q[0].key.scancode = 44
            q[0].key.down = true
            q[0].key["repeat"] = true
        end)

        local seen = drainOne(queue, count)
        assert.are.equal(1, #seen)
        assert.are.equal("keyDown", seen[1].kind)
        assert.are.equal(44, seen[1].scancode)
        assert.is_true(seen[1].repeated,
            "a repeat must be distinguishable from a fresh press")
    end)

    it("converts mouse motion with its delta", function()
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_MOUSE_MOTION
            q[0].motion.x = 120.0
            q[0].motion.y = 80.0
            q[0].motion.xrel = -4.0
            q[0].motion.yrel = 2.0
        end)

        local event = drainOne(queue, count)[1]
        assert.are.equal("mouseMotion", event.kind)
        assert.are.equal(120.0, event.x)
        assert.are.equal(80.0, event.y)
        assert.are.equal(-4.0, event.dx)
        assert.are.equal(2.0, event.dy)
    end)

    it("scales a gamepad axis into minus one to one", function()
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_GAMEPAD_AXIS_MOTION
            q[0].gaxis.axis = 1
            q[0].gaxis.value = -32767
            q[0].gaxis.which = 3
        end)

        local event = drainOne(queue, count)[1]
        assert.are.equal("gamepadAxis", event.kind)
        assert.are.equal(1, event.axis)
        assert.is_true(math.abs(event.value + 1.0) < 0.001)
        assert.are.equal(3, event.which)
    end)

    it("says which pad a button came from", function()
        -- Without this a two-player game has one set of buttons, and pad A
        -- releasing one releases pad B's.
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_GAMEPAD_BUTTON_DOWN
            q[0].gbutton.button = 3
            q[0].gbutton.which = 17
            q[0].gbutton.down = true
        end)

        local event = drainOne(queue, count)[1]
        assert.are.equal("gamepadButtonDown", event.kind)
        assert.are.equal(3, event.button)
        assert.are.equal(17, event.which)
        assert.is_true(event.down)
    end)

    it("converts a gamepad sensor reading and a touchpad finger", function()
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_GAMEPAD_SENSOR_UPDATE
            q[0].gsensor.which = 5
            q[0].gsensor.sensor = 3
            q[0].gsensor.data[0] = 1.5
            q[0].gsensor.data[1] = -2.5
            q[0].gsensor.data[2] = 0.25
            q[1].type = C.SDL_EVENT_GAMEPAD_TOUCHPAD_MOTION
            q[1].gtouchpad.which = 5
            q[1].gtouchpad.touchpad = 1
            q[1].gtouchpad.finger = 2
            q[1].gtouchpad.x = 0.75
            q[1].gtouchpad.y = 0.5
            q[1].gtouchpad.pressure = 1.0
        end, 2)

        local seen = drainOne(queue, count)
        assert.are.equal("gamepadSensor", seen[1].kind)
        assert.are.equal(3, seen[1].sensor)
        assert.are.equal(1.5, seen[1].sensorX)
        assert.are.equal(-2.5, seen[1].sensorY)
        assert.are.equal(0.25, seen[1].sensorZ)

        assert.are.equal("gamepadTouchpadMotion", seen[2].kind)
        assert.are.equal(1, seen[2].touchpad)
        assert.are.equal(2, seen[2].fingerIndex)
        assert.are.equal(0.75, seen[2].normalX)
    end)

    it("carries a key's layout and its physical position, plus modifiers",
        function()
            -- A movement binding wants the position and a text binding wants
            -- the layout, so neither can stand in for the other.
            local queue, count = queueOf(function(q)
                q[0].type = C.SDL_EVENT_KEY_DOWN
                q[0].key.scancode = 4
                q[0].key.key = 97
                q[0].key.mod = sdl.K.SDL_KMOD_LSHIFT
                q[0].key.which = 6
                q[0].key.down = true
            end)

            local event = drainOne(queue, count)[1]
            assert.are.equal(4, event.scancode)
            assert.are.equal(97, event.keycode)
            assert.are.equal(sdl.K.SDL_KMOD_LSHIFT, event.modifiers)
            assert.are.equal(6, event.which, "and which keyboard produced it")
        end)

    it("marks a mouse event the platform made from a touch or a pen", function()
        -- These arrive alongside the finger events they were made from, so a
        -- game that handles both would act on one gesture twice.
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_MOUSE_BUTTON_DOWN
            q[0].button.button = 1
            q[0].button.which = sdl.K.SDL_TOUCH_MOUSEID
            q[1].type = C.SDL_EVENT_MOUSE_BUTTON_DOWN
            q[1].button.button = 1
            q[1].button.which = sdl.K.SDL_PEN_MOUSEID
            q[2].type = C.SDL_EVENT_MOUSE_BUTTON_DOWN
            q[2].button.button = 1
            q[2].button.which = 0
        end, 3)

        local seen = drainOne(queue, count)
        assert.is_true(seen[1].synthetic, "a touch-generated click")
        assert.is_true(seen[2].synthetic, "a pen-generated click")
        assert.is_false(seen[3].synthetic, "and a real mouse is not one")
    end)

    it("converts text and composition into Lua strings", function()
        -- A recognised kind has to mean a usable payload. The pointer is only
        -- valid where it was read, so what arrives above is a copy.
        local typed = "hi"
        local composing = "ni"
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_TEXT_INPUT
            q[0].text.text = typed
            q[1].type = C.SDL_EVENT_TEXT_EDITING
            q[1].edit.text = composing
            q[1].edit.start = 1
            q[1].edit.length = 2
        end, 2)

        local seen = drainOne(queue, count)
        assert.are.equal("textInput", seen[1].kind)
        assert.are.equal("hi", seen[1].text)
        assert.are.equal("textEditing", seen[2].kind)
        assert.are.equal("ni", seen[2].text)
        assert.are.equal(1, seen[2].start)
        assert.are.equal(2, seen[2].length)
    end)

    it("clears a string payload rather than carrying it to the next event",
        function()
            -- The record is reused, and a handler that checks `text ~= nil`
            -- would otherwise act on the previous event's text.
            local typed = "hi"
            local queue, count = queueOf(function(q)
                q[0].type = C.SDL_EVENT_TEXT_INPUT
                q[0].text.text = typed
                q[1].type = C.SDL_EVENT_KEY_DOWN
                q[1].key.scancode = 44
            end, 2)

            local seen = drainOne(queue, count)
            assert.are.equal("hi", seen[1].text)
            assert.is_nil(seen[2].text)
        end)

    it("converts a pen through its whole vocabulary", function()
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_PEN_DOWN
            q[0].ptouch.which = 9
            q[0].ptouch.x = 40.0
            q[0].ptouch.y = 60.0
            q[0].ptouch.eraser = true
            q[0].ptouch.down = true
            q[1].type = C.SDL_EVENT_PEN_AXIS
            q[1].paxis.which = 9
            q[1].paxis.x = 41.0
            q[1].paxis.y = 61.0
            q[1].paxis.axis = 0
            q[1].paxis.value = 0.5
        end, 2)

        local seen = drainOne(queue, count)
        assert.are.equal("penDown", seen[1].kind)
        assert.are.equal(9, seen[1].which)
        assert.are.equal(40.0, seen[1].x)
        assert.is_true(seen[1].eraser)

        assert.are.equal("penAxis", seen[2].kind)
        assert.are.equal(0, seen[2].axis)
        assert.are.equal(0.5, seen[2].value)
        assert.is_false(seen[2].eraser,
            "the eraser flag must not carry over from the press before it")
    end)

    it("reports a drop with its path and its origin", function()
        local dropped = "/tmp/hero.png"
        local from = "explorer"
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_DROP_FILE
            q[0].drop.data = dropped
            q[0].drop.source = from
            q[0].drop.x = 12.0
            q[0].drop.y = 34.0
        end)

        local event = drainOne(queue, count)[1]
        assert.are.equal("dropFile", event.kind)
        assert.are.equal("/tmp/hero.png", event.text)
        assert.are.equal("explorer", event.source)
        assert.are.equal(12.0, event.x)
    end)

    it("reports lifecycle events with their own kinds", function()
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_WILL_ENTER_BACKGROUND
        end)
        assert.are.equal("appWillEnterBackground", drainOne(queue, count)[1].kind)
    end)

    it("carries a touch finger as an exact opaque identity", function()
        -- A finger id is 64 bits. Reporting it as a number would round, and two
        -- distinct fingers could collapse into one.
        events.setTouchScale(800, 600)
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_FINGER_DOWN
            q[0].tfinger.fingerID = 9007199254740995ULL
            q[0].tfinger.touchID = 42ULL
            q[0].tfinger.x = 0.5
            q[0].tfinger.y = 0.25
            q[0].tfinger.pressure = 0.75
        end)

        local event = drainOne(queue, count)[1]
        assert.are.equal("fingerDown", event.kind)
        assert.is_string(event.finger)
        assert.is_truthy(event.finger:find("9007199254740995"),
            "the identity must survive exactly, not as a rounded double")
        assert.is_truthy(event.touchDevice:find("42"),
            "and so must the device it belongs to")
        -- Touch arrives normalised and is reported in window units as well,
        -- since a window coordinate does not survive a resize and the
        -- normalised one does.
        assert.are.equal(0.5, event.normalX)
        assert.are.equal(0.25, event.normalY)
        assert.are.equal(400.0, event.x)
        assert.are.equal(150.0, event.y)
        assert.is_true(math.abs(event.pressure - 0.75) < 0.001)
    end)

    it("scales touch by the window size it was told, not by pixels", function()
        -- Mouse positions are in window coordinates. Scaling touch by the
        -- drawable size instead would put the two pointers a device-density
        -- factor apart on every high-density display.
        events.setTouchScale(800, 600)
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_FINGER_DOWN
            q[0].tfinger.x = 0.5
            q[0].tfinger.y = 0.5
        end)
        assert.are.equal(400.0, drainOne(queue, count)[1].x)

        events.setTouchScale(1600, 1200)
        assert.are.equal(800.0, drainOne(queue, count)[1].x)
        events.setTouchScale(800, 600)
    end)

    it("surfaces an unrecognised SDL event rather than dropping it", function()
        -- Upgrading SDL must not silently discard new input.
        local queue, count = queueOf(function(q)
            q[0].type = 0x7FFE
        end)

        local event = drainOne(queue, count)[1]
        assert.are.equal("unknown", event.kind)
        assert.are.equal(0x7FFE, event.sdlType)
    end)

    it("delivers a queue in arrival order", function()
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_KEY_DOWN
            q[0].key.scancode = 1
            q[1].type = C.SDL_EVENT_KEY_DOWN
            q[1].key.scancode = 2
            q[2].type = C.SDL_EVENT_KEY_UP
            q[2].key.scancode = 1
        end, 3)

        local seen = drainOne(queue, count)
        assert.are.equal(3, #seen)
        assert.are.equal(1, seen[1].scancode)
        assert.are.equal(2, seen[2].scancode)
        assert.are.equal("keyUp", seen[3].kind)
    end)

    it("reuses one record, so retaining requires a copy", function()
        local queue, count = queueOf(function(q)
            q[0].type = C.SDL_EVENT_KEY_DOWN
            q[0].key.scancode = 10
            q[1].type = C.SDL_EVENT_KEY_DOWN
            q[1].key.scancode = 20
        end, 2)

        local held = {}
        events.drain(queue, count, function(event) held[#held + 1] = event end)

        -- Both references are the same pooled record, which is why copy exists.
        assert.are.equal(held[1], held[2])
        assert.are.equal(20, held[1].scancode,
            "the retained reference shows the last event, not the first")
    end)

    it("lets a replay driver stand in for the queue", function()
        -- Replay substitutes the source rather than synthesising SDL unions,
        -- which is what keeps a recorded session reproducible.
        events.source = function(handler)
            handler({ kind = "keyDown", scancode = 99, repeated = false })
            handler({ kind = "quit" })
        end

        local seen = {}
        events.drain(nil, 0, function(event) seen[#seen + 1] = event.kind end)
        assert.are.same({ "keyDown", "quit" }, seen)
    end)

    it("pushes a synthetic event in the engine's own vocabulary", function()
        assert(C.SDL_Init(sdl.K.SDL_INIT_VIDEO))
        C.SDL_PumpEvents()
        C.SDL_FlushEvents(0, 0xFFFFFFFF)

        events.push("keyDown", { scancode = 77 })

        -- Read back through SDL to confirm it really entered the queue.
        local holder = loader.newArray("SDL_Event[1]")
        assert.is_true(C.SDL_PollEvent(holder) ~= false)
        assert.are.equal(tonumber(C.SDL_EVENT_KEY_DOWN), tonumber(holder[0].type))
        assert.are.equal(77, tonumber(holder[0].key.scancode))

        assert.is_false(pcall(function() events.push("notAKind", {}) end))
        C.SDL_Quit()
    end)
end)
