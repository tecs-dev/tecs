-- Input state, layers, devices, and fixed-step latching.
--
-- Latching is the part that earns its complexity. A key pressed and released
-- between two fixed steps is invisible to frame events, and losing it produces
-- dropped input that varies with frame timing and so cannot be reproduced on
-- demand. These tests drive the state with synthetic events, which is the same
-- path a recorded session replays through.
--
-- Devices are driven through a substituted backend rather than through
-- hardware. Two pads that do not alias each other, a pad that goes away while
-- something still holds a reference to it, and a text-input session that ends
-- with the menu that started it are all cases no continuous-integration
-- machine can produce by plugging something in.
--
-- What that leaves untested, rather than asserted: whether a real motor
-- rumbles, whether a real input method composes, whether a real pad's SDL
-- handle behaves as the backend contract says, and whether the C host's deep
-- copy of a drop or a clipboard payload holds up under a real drag. Those need
-- a device and a desktop, and the tests here prove the layer above them
-- instead.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. package.path

local Input = require("tecs.platform.Input")
local inputbackend = require("tecs.platform.inputbackend")

-- Input consumes the engine's typed events, so the tests build those. The
-- SDL-to-typed conversion is covered in events_spec; this covers what Input
-- does with the result.
local function keyEvent(scancode, down, isRepeat)
    return {
        kind = down and "keyDown" or "keyUp",
        scancode = scancode,
        repeated = isRepeat or false,
    }
end

local function mouseEvent(button, down)
    return { kind = down and "mouseDown" or "mouseUp", button = button }
end

-- A backend with no hardware behind it. Name resolution still comes from the
-- real one, because a positional name has to resolve to the number the events
-- carry or the test would prove only that it agrees with itself.
local function fakeBackend()
    local calls = {
        opened = {}, closed = {}, rumbles = {}, leds = {},
        textStarted = 0, textStopped = 0, areas = {},
    }
    local attached = {}

    local backend = setmetatable({
        attach = function(...)
            attached = { ... }
        end,
        calls = calls,

        attachedGamepads = function() return attached end,

        openGamepad = function(id)
            calls.opened[#calls.opened + 1] = id
            -- A handle the test can recognise, standing in for a pointer.
            return { device = id }
        end,

        closeGamepad = function(handle)
            calls.closed[#calls.closed + 1] = handle.device
        end,

        gamepadInfo = function(handle, id)
            return {
                id = id,
                name = "pad " .. tostring(id),
                kind = "standard",
                guid = string.format("%032x", id),
                path = "/dev/pad/" .. tostring(id),
                playerIndex = id - 1,
                touchpads = 1,
            }
        end,

        gamepadHasButton = function() return true end,
        gamepadHasAxis = function() return true end,
        gamepadHasSensor = function() return true end,
        gamepadButtonLabel = function() return "cross" end,
        gamepadPower = function() return "onBattery", 42 end,
        setGamepadSensor = function() return true end,
        gamepadSensorEnabled = function() return true end,

        rumble = function(handle, low, high, milliseconds)
            calls.rumbles[#calls.rumbles + 1] = {
                device = handle.device, low = low, high = high,
                milliseconds = milliseconds,
            }
            return true
        end,

        rumbleTriggers = function() return true end,

        setLED = function(handle, red, green, blue)
            calls.leds[#calls.leds + 1] =
                { device = handle.device, red = red, green = green, blue = blue }
            return true
        end,

        setPlayerIndex = function() return true end,

        startTextInput = function()
            calls.textStarted = calls.textStarted + 1
            return true
        end,

        stopTextInput = function()
            calls.textStopped = calls.textStopped + 1
            return true
        end,

        textInputActive = function() return calls.textStarted > calls.textStopped end,

        setTextInputArea = function(_window, x, y, width, height, cursor)
            calls.areas[#calls.areas + 1] =
                { x = x, y = y, width = width, height = height, cursor = cursor }
            return true
        end,
    }, { __index = inputbackend.sdl })

    return backend
end

--- An input state with two pads already attached, as a machine that had them
--- plugged in before the process started would report.
local function withPads(backend, ...)
    backend.attach(...)
    local input = Input.create({ backend = backend })
    input:refreshDevices()
    return input
end

describe("platform.Input", function()
    local input
    local SPACE

    before_each(function()
        input = Input.create()
        SPACE = input:scancode("space")
    end)

    it("resolves key names case-insensitively", function()
        assert.are.equal(input:scancode("space"), input:scancode("Space"))
        assert.is_true(input:scancode("left shift") > 0)
        assert.is_false(pcall(function() input:scancode("not a key") end))
    end)

    it("reports held keys and edges separately", function()
        input:beginFrame()
        input:handleEvent(keyEvent(SPACE, true))

        assert.is_true(input:keyDown("space"))
        assert.is_true(input:keyPressed("space"))
        assert.is_false(input:keyReleased("space"))

        -- A new frame clears edges but not the held state.
        input:beginFrame()
        assert.is_true(input:keyDown("space"))
        assert.is_false(input:keyPressed("space"))

        input:handleEvent(keyEvent(SPACE, false))
        assert.is_false(input:keyDown("space"))
        assert.is_true(input:keyReleased("space"))
    end)

    it("does not treat key repeats as presses", function()
        input:beginFrame()
        input:handleEvent(keyEvent(SPACE, true))
        input:beginFrame()
        input:handleEvent(keyEvent(SPACE, true, true))

        assert.is_true(input:keyDown("space"), "the key is still held")
        assert.is_false(input:keyPressed("space"),
            "holding a key must not read as pressing it again")
    end)

    it("keeps a press that began and ended between fixed steps", function()
        -- This is the case frame events lose. Two frames pass, the key goes
        -- down in one and up in the next, and the fixed step must still see
        -- both edges.
        input:beginFrame()
        input:handleEvent(keyEvent(SPACE, true))
        input:beginFrame()
        input:handleEvent(keyEvent(SPACE, false))

        -- By frame events alone the press is gone.
        assert.is_false(input:keyPressed("space"))

        input:enterFixedPhase()
        assert.is_true(input:keyPressed("space"),
            "the fixed step must see the press it would otherwise miss")
        assert.is_true(input:keyReleased("space"))
        input:exitFixedPhase()

        -- Consumed: the next fixed step starts clean.
        input:enterFixedPhase()
        assert.is_false(input:keyPressed("space"))
        input:exitFixedPhase()
    end)

    it("hides input from layers beneath a blocking one", function()
        input:beginFrame()
        input:handleEvent(keyEvent(SPACE, true))
        assert.is_true(input:keyDown("space"), "base reads by default")

        local menu = input:pushLayer("menu")
        assert.is_true(input:keyDown("space", menu), "the top layer reads")
        assert.is_false(input:keyDown("space"),
            "gameplay goes quiet without knowing a menu exists")

        input:popLayer()
        assert.is_true(input:keyDown("space"), "and comes back when it closes")
    end)

    it("lets a non-blocking overlay observe without consuming", function()
        input:beginFrame()
        input:handleEvent(keyEvent(SPACE, true))

        local overlay = input:pushLayer("debug", false)
        assert.is_true(input:keyDown("space", overlay))
        assert.is_true(input:keyDown("space"),
            "a passthrough layer must not suppress what is under it")
    end)

    it("tracks mouse buttons on the same three tiers", function()
        input:beginFrame()
        input:handleEvent(mouseEvent(1, true))

        assert.is_true(input:mouseDown("left"))
        assert.is_true(input:mousePressed("left"))
        assert.is_false(input:mouseDown("right"))
        assert.is_true(input:mouseDown(1), "a numeric button works too")

        input:beginFrame()
        input:handleEvent(mouseEvent(1, false))
        assert.is_false(input:mouseDown("left"))
        assert.is_true(input:mouseReleased("left"))

        assert.is_false(pcall(function() input:mouseDown("thumb") end))
    end)

    it("accumulates wheel and motion within a frame, then clears", function()
        local wheel = { kind = "mouseWheel", wheelX = 0.0, wheelY = 1.0 }

        input:beginFrame()
        input:handleEvent(wheel)
        input:handleEvent(wheel)
        assert.are.equal(2.0, input.wheelY, "two notches in one frame is two")

        input:beginFrame()
        assert.are.equal(0.0, input.wheelY)
    end)

    it("distinguishes a mouse event the platform made from a touch", function()
        -- A game that handles touch itself would otherwise act on one tap
        -- twice: once as a finger and once as the virtual click the platform
        -- synthesises from it.
        input:beginFrame()
        input:handleEvent({
            kind = "mouseDown", button = 1, x = 10, y = 20,
            which = 4294967295, synthetic = true,
        })
        assert.is_true(input:mouseDown("left"))
        assert.is_true(input.mouseSynthetic,
            "a touch-generated click must be recognisable as one")

        input:beginFrame()
        input:handleEvent({
            kind = "mouseMotion", x = 11, y = 21, dx = 1, dy = 1,
            which = 0, synthetic = false,
        })
        assert.is_false(input.mouseSynthetic, "a real mouse is not synthetic")
    end)

    it("releases everything held when the window loses focus", function()
        -- No release ever arrives for a key held as focus goes, so without
        -- this the key reads as held until the player presses it again
        -- somewhere the application can see.
        input:beginFrame()
        input:handleEvent(keyEvent(SPACE, true))
        input:handleEvent(mouseEvent(1, true))
        assert.is_true(input:keyDown("space"))

        input:beginFrame()
        input:handleEvent({ kind = "windowFocusLost" })

        assert.is_false(input:keyDown("space"), "the key must not stay held")
        assert.is_true(input:keyReleased("space"),
            "and the release has to be reported, not merely implied")
        assert.is_false(input:mouseDown("left"))
    end)

    it("tracks touches by device and finger, keeping normalised positions",
        function()
            input:handleEvent({
                kind = "fingerDown", touchDevice = "7", finger = "1",
                x = 400, y = 150, normalX = 0.5, normalY = 0.25, pressure = 0.8,
            })
            input:handleEvent({
                kind = "fingerDown", touchDevice = "7", finger = "2",
                x = 80, y = 60, normalX = 0.1, normalY = 0.1, pressure = 0.4,
            })

            assert.are.equal(2, #input:touches())

            input:handleEvent({
                kind = "fingerUp", touchDevice = "7", finger = "1",
            })
            local remaining = input:touches()
            assert.are.equal(1, #remaining)
            assert.are.equal("2", remaining[1].finger)
            assert.are.equal(0.1, remaining[1].normalX,
                "the normalised position survives, since a window coordinate "
                    .. "does not survive a resize")
        end)

    it("follows a pen through the surface", function()
        input:handleEvent({
            kind = "penDown", which = 3, x = 40, y = 60, eraser = true,
        })
        assert.is_true(input.penTouching)
        assert.is_true(input.penEraser)
        assert.are.equal(3, input.penWhich)

        input:handleEvent({ kind = "penUp", which = 3, x = 41, y = 61 })
        assert.is_false(input.penTouching)
        assert.are.equal(41, input.penX)
    end)

    it("folds the pen axes it names into the pen state", function()
        -- A pen reports pressure the way a pad reports a stick: one axis event
        -- per reading, numbered by the platform. The numbers come from the
        -- backend rather than being written here, so the test cannot agree
        -- with itself about a number SDL has moved.
        local axis = inputbackend.sdl.penAxisFromName

        input:handleEvent({ kind = "penDown", which = 3, x = 40, y = 60 })
        assert.are.equal(0.0, input.penPressure,
            "nothing has been reported yet")

        input:handleEvent({
            kind = "penAxis", which = 3, x = 40, y = 60,
            axis = axis("pressure"), value = 0.75,
        })
        assert.are.equal(0.75, input.penPressure)

        input:handleEvent({
            kind = "penAxis", which = 3, x = 40, y = 60,
            axis = axis("tiltX"), value = -30.0,
        })
        input:handleEvent({
            kind = "penAxis", which = 3, x = 40, y = 60,
            axis = axis("tiltY"), value = 12.5,
        })
        input:handleEvent({
            kind = "penAxis", which = 3, x = 40, y = 60,
            axis = axis("rotation"), value = 90.0,
        })
        assert.are.equal(-30.0, input.penTiltX)
        assert.are.equal(12.5, input.penTiltY)
        assert.are.equal(90.0, input.penRotation)
        assert.are.equal(0.75, input.penPressure,
            "one axis per event, so the others keep what they held")

        -- A pen carried out of range is pressing on nothing, and a stroke that
        -- reads as still under way is what a drawing tool would draw.
        input:handleEvent({ kind = "penProximityOut", which = 3 })
        assert.are.equal(0.0, input.penPressure)
    end)

    it("says which device a wheel event came from", function()
        -- The platform scrolls by synthesising wheel events from a touch, and
        -- a game handling touch itself has to recognise those or act on one
        -- gesture twice. Reading the last button event's device instead is
        -- exactly the confusion these two fields exist to prevent.
        input:handleEvent({
            kind = "mouseDown", button = 1, which = 1, synthetic = false,
        })
        input:handleEvent({
            kind = "mouseWheel", which = 12, synthetic = true,
            wheelX = 0, wheelY = 1,
        })

        assert.are.equal(12, input.mouseWhich)
        assert.is_true(input.mouseSynthetic)
        assert.are.equal(1, input.wheelY)
    end)
end)

describe("platform.Input gamepads", function()
    local backend

    before_each(function()
        backend = fakeBackend()
    end)

    it("opens what is already attached rather than waiting for an event",
        function()
            -- A pad plugged in before the process started produces no
            -- addition, so a registry that only listens would never see it.
            local input = withPads(backend, 11, 12)
            assert.are.equal(2, #input:gamepads())
            assert.are.same({ 11, 12 }, backend.calls.opened)
            assert.are.equal("pad 11", input:gamepad(1).name)
            assert.are.equal(11, input:gamepad(1).id)
            assert.are.equal("standard", input:gamepad(1).kind)
            assert.are.equal("/dev/pad/12", input:gamepad(2).path)
        end)

    it("keeps two pads from answering for each other", function()
        -- One shared button set is the defect this exists to prevent: pad A
        -- releasing a button would release pad B's.
        local input = withPads(backend, 11, 12)
        local first, second = input:gamepad(1), input:gamepad(2)
        local SOUTH = 0

        input:beginFrame()
        input:handleEvent({ kind = "gamepadButtonDown", which = 11, button = SOUTH })
        input:handleEvent({ kind = "gamepadButtonDown", which = 12, button = SOUTH })
        assert.is_true(first:buttonDown("south"))
        assert.is_true(second:buttonDown("south"))

        input:beginFrame()
        input:handleEvent({ kind = "gamepadButtonUp", which = 11, button = SOUTH })
        assert.is_false(first:buttonDown("south"))
        assert.is_true(second:buttonDown("south"),
            "one pad releasing must not release the other's")
        assert.is_true(first:buttonReleased("south"))
        assert.is_false(second:buttonReleased("south"))
    end)

    it("keeps two pads' axes apart and applies a deadzone", function()
        local input = withPads(backend, 11, 12)
        local first, second = input:gamepad(1), input:gamepad(2)

        input:handleEvent({ kind = "gamepadAxis", which = 11, axis = 0, value = 1.0 })
        input:handleEvent({ kind = "gamepadAxis", which = 12, axis = 0, value = -0.5 })

        assert.is_true(math.abs(first:axis("leftX") - 1.0) < 0.001)
        assert.is_true(math.abs(second:axis("leftX") + 0.5) < 0.001)

        input:handleEvent({ kind = "gamepadAxis", which = 11, axis = 0, value = 0.0305 })
        assert.are.equal(0.0, first:axis("leftX"),
            "stick drift is hardware, not gameplay, so it is filtered here")
        assert.is_true(first:axis("leftX", 0.01) > 0.0,
            "an explicit smaller deadzone still sees it")
    end)

    it("names buttons positionally and reports the printed label apart",
        function()
            -- "south" is the button nearest the player on every pad; "a" is
            -- that button on some and the one to its right on others, which is
            -- why a binding is positional and a prompt is not.
            local input = withPads(backend, 11)
            local pad = input:gamepad(1)

            assert.is_false(pcall(function() pad:buttonDown("a") end),
                "an Xbox-only name is not the vocabulary")
            assert.is_false(pad:buttonDown("leftShoulder"))
            assert.are.equal("cross", pad:label("south"))
            assert.is_true(pad:hasButton("north"))
        end)

    it("latches a gamepad press for the fixed step, like a key", function()
        local input = withPads(backend, 11)
        local pad = input:gamepad(1)

        input:beginFrame()
        input:handleEvent({ kind = "gamepadButtonDown", which = 11, button = 0 })
        input:beginFrame()
        input:handleEvent({ kind = "gamepadButtonUp", which = 11, button = 0 })

        assert.is_false(pad:buttonPressed("south"))
        input:enterFixedPhase()
        assert.is_true(pad:buttonPressed("south"))
        assert.is_true(pad:buttonReleased("south"))
        input:exitFixedPhase()
    end)

    it("answers a pad query through the layer it was asked from", function()
        local input = withPads(backend, 11)
        local pad = input:gamepad(1)

        input:beginFrame()
        input:handleEvent({ kind = "gamepadButtonDown", which = 11, button = 0 })
        assert.is_true(pad:buttonDown("south"))

        local menu = input:pushLayer("menu")
        assert.is_true(pad:buttonDown("south", menu))
        assert.is_false(pad:buttonDown("south"),
            "a pad is gated by the same stack as the keyboard")
    end)

    it("connects and disconnects on the platform's own events", function()
        local input = Input.create({ backend = backend })
        assert.are.equal(0, #input:gamepads())

        input:handleEvent({ kind = "gamepadAdded", which = 21 })
        assert.are.equal(1, #input:gamepads())
        assert.are.equal(21, input:gamepadById(21).id)

        -- A second addition for a device already open is not a second device.
        input:handleEvent({ kind = "gamepadAdded", which = 21 })
        assert.are.equal(1, #input:gamepads())

        input:handleEvent({ kind = "gamepadAdded", which = 22 })
        input:handleEvent({ kind = "gamepadRemoved", which = 21 })

        assert.are.equal(1, #input:gamepads())
        assert.are.equal(22, input:gamepad(1).id)
        assert.is_nil(input:gamepadById(21))
        assert.are.same({ 21 }, backend.calls.closed,
            "the handle has to be given back, not merely forgotten")
    end)

    it("leaves a retained reference to a removed pad safe to call", function()
        -- The reference outlives the device on purpose here. Nothing it does
        -- may reach the closed handle, and it must answer rather than raise:
        -- a game holding a pad through a disconnect is normal, not a bug.
        local input = withPads(backend, 11)
        local pad = input:gamepad(1)

        input:beginFrame()
        input:handleEvent({ kind = "gamepadButtonDown", which = 11, button = 0 })
        assert.is_true(pad:buttonDown("south"))

        input:handleEvent({ kind = "gamepadRemoved", which = 11 })

        assert.is_false(pad.connected)
        assert.is_false(pad:buttonDown("south"),
            "a button cannot stay held on a device that is gone")
        assert.is_true(pad:buttonReleased("south"),
            "and the release is reported, so a held action ends")
        assert.are.equal(0.0, pad:axis("leftX"))
        assert.is_false(pad:rumble(1.0, 1.0, 0.2))
        assert.is_false(pad:setLED(1.0, 0.0, 0.0))
        assert.is_false(pad:hasButton("south"))
        assert.is_false(pad:hasSensor("gyro"))
        assert.is_false(pad:enableSensor("gyro"))
        assert.are.equal("unknown", pad:label("south"))
        local state, percent = pad:power()
        assert.are.equal("unknown", state)
        assert.are.equal(-1, percent)

        -- Reconnecting the same instance id produces a new object, so the old
        -- reference never comes back to life holding a handle it did not open.
        input:handleEvent({ kind = "gamepadAdded", which = 11 })
        assert.is_false(pad.connected)
        assert.are_not.equal(pad, input:gamepad(1))
        assert.is_true(input:gamepad(1).connected)
    end)

    it("drops what a pad was holding when focus goes", function()
        local input = withPads(backend, 11)
        local pad = input:gamepad(1)

        input:beginFrame()
        input:handleEvent({ kind = "gamepadButtonDown", which = 11, button = 0 })
        input:beginFrame()
        input:handleEvent({ kind = "windowFocusLost" })

        assert.is_false(pad:buttonDown("south"))
        assert.is_true(pad:buttonReleased("south"))
        assert.is_true(pad.connected, "focus loss is not a disconnection")
    end)

    it("re-reads a pad's description when the platform remaps it", function()
        local input = withPads(backend, 11)
        local pad = input:gamepad(1)
        assert.are.equal("cross", pad:label("south"))

        backend.gamepadButtonLabel = function() return "a" end
        input:handleEvent({ kind = "gamepadRemapped", which = 11 })
        assert.are.equal("a", pad:label("south"),
            "a remap changes what is printed on the button")
    end)

    it("routes rumble and the LED to the device that asked", function()
        local input = withPads(backend, 11, 12)
        input:gamepad(2):rumble(0.5, 1.0, 0.25)
        input:gamepad(1):setLED(1.0, 0.0, 0.5)

        assert.are.equal(1, #backend.calls.rumbles)
        assert.are.equal(12, backend.calls.rumbles[1].device)
        assert.are.equal(250, backend.calls.rumbles[1].milliseconds)
        assert.are.equal(11, backend.calls.leds[1].device)
    end)

    it("folds a sensor reading only for the pad that produced it", function()
        local input = withPads(backend, 11, 12)
        assert.is_true(input:gamepad(1):enableSensor("gyro"))

        input:handleEvent({
            kind = "gamepadSensor", which = 11, sensor = 3,
            sensorX = 0.1, sensorY = 0.2, sensorZ = 0.3,
        })

        local x, y, z = input:gamepad(1):sensor(3)
        assert.is_true(math.abs(x - 0.1) < 0.001)
        assert.is_true(math.abs(y - 0.2) < 0.001)
        assert.is_true(math.abs(z - 0.3) < 0.001)
        assert.are.equal(0.0, (input:gamepad(2):sensor(3)))
    end)

    it("tracks touchpad fingers per pad", function()
        local input = withPads(backend, 11)
        local pad = input:gamepad(1)

        input:handleEvent({
            kind = "gamepadTouchpadDown", which = 11, touchpad = 0,
            fingerIndex = 0, normalX = 0.25, normalY = 0.75, pressure = 1.0,
            down = true,
        })
        local fingers = pad:touchpadFingers(0)
        assert.are.equal(1, #fingers)
        assert.are.equal(0.25, fingers[1].x)

        input:handleEvent({
            kind = "gamepadTouchpadUp", which = 11, touchpad = 0,
            fingerIndex = 0, normalX = 0.25, normalY = 0.75, pressure = 0.0,
            down = false,
        })
        assert.are.equal(0, #pad:touchpadFingers(0))
    end)

    it("closes every open device when the application ends", function()
        local input = withPads(backend, 11, 12)
        input:destroy()
        assert.are.same({ 11, 12 }, backend.calls.closed)
        assert.are.equal(0, #input:gamepads())
    end)
end)

describe("platform.Input text", function()
    local backend
    local input

    before_each(function()
        backend = fakeBackend()
        input = Input.create({ backend = backend })
    end)

    it("delivers characters only once a session is started", function()
        local menu = input:pushLayer("menu")
        assert.is_false(input:textInputActive())

        assert.is_true(input:startTextInput(menu, {
            area = { x = 20, y = 20, width = 400, height = 40, cursor = 8 },
        }))
        assert.is_true(input:textInputActive())
        assert.are.equal(1, backend.calls.textStarted)
        assert.are.same({ x = 20, y = 20, width = 400, height = 40, cursor = 8 },
            backend.calls.areas[1],
            "the platform needs the rectangle or it puts its keyboard over it")

        input:beginFrame()
        input:handleEvent({ kind = "textInput", text = "h" })
        input:handleEvent({ kind = "textInput", text = "i" })
        assert.are.equal("hi", input.text,
            "two characters in one frame are both delivered")

        input:beginFrame()
        assert.are.equal("", input.text, "and the frame's text clears")
    end)

    it("reports what an input method is composing before it commits", function()
        input:startTextInput()
        input:handleEvent({
            kind = "textEditing", text = "にほん", start = 3, length = 0,
        })
        assert.are.equal("にほん", input.composition)
        assert.are.equal(3, input.compositionStart)

        input:beginFrame()
        input:handleEvent({ kind = "textInput", text = "日本" })
        assert.are.equal("日本", input.text)
        assert.are.equal("", input.composition,
            "committing ends the composition, so a field draws it once")
    end)

    it("stops the session with the layer that started it", function()
        -- The case nobody remembers: a menu closes and leaves the on-screen
        -- keyboard up, or leaves key events being eaten by an input method.
        local menu = input:pushLayer("menu")
        input:startTextInput(menu)
        input:handleEvent({ kind = "textEditing", text = "ab", start = 2 })

        input:popLayer()

        assert.is_false(input:textInputActive())
        assert.are.equal(1, backend.calls.textStopped)
        assert.are.equal("", input.composition,
            "what was being composed goes with the session")
    end)

    it("leaves a session alone when an unrelated layer pops", function()
        local menu = input:pushLayer("menu")
        input:startTextInput(menu)
        local tooltip = input:pushLayer("tooltip", false)
        assert.are.equal(tooltip, input:popLayer())

        assert.is_true(input:textInputActive())
        assert.are.equal(0, backend.calls.textStopped)
    end)

    it("stops a session the application ends with", function()
        input:startTextInput()
        input:destroy()
        assert.are.equal(1, backend.calls.textStopped)
    end)
end)
