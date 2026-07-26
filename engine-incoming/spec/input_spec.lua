-- Input state, layers, and fixed-step latching.
--
-- Latching is the part that earns its complexity. A key pressed and released
-- between two fixed steps is invisible to frame events, and losing it produces
-- dropped input that varies with frame timing and so cannot be reproduced on
-- demand. These tests drive the state with synthetic events, which is the same
-- path a recorded session replays through.

-- The build directory is the build system's to choose, so it is passed in.
-- Our tree comes first, so it wins over the ECS repo's own engine tree.
local root = os.getenv("TECS2D_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;"
    .. "../tecs/build/?.lua;../tecs/build/?/init.lua;" .. package.path

local Input = require("tecs2d.platform.Input")

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

local function axisEvent(axis, value)
    -- Already scaled: the converter turns SDL's signed 16-bit into -1..1.
    return { kind = "controllerAxis", axis = axis, value = value }
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

        assert.is_true(input:isKeyDown("space"))
        assert.is_true(input:isKeyPressed("space"))
        assert.is_false(input:isKeyReleased("space"))

        -- A new frame clears edges but not the held state.
        input:beginFrame()
        assert.is_true(input:isKeyDown("space"))
        assert.is_false(input:isKeyPressed("space"))

        input:handleEvent(keyEvent(SPACE, false))
        assert.is_false(input:isKeyDown("space"))
        assert.is_true(input:isKeyReleased("space"))
    end)

    it("does not treat key repeats as presses", function()
        input:beginFrame()
        input:handleEvent(keyEvent(SPACE, true))
        input:beginFrame()
        input:handleEvent(keyEvent(SPACE, true, true))

        assert.is_true(input:isKeyDown("space"), "the key is still held")
        assert.is_false(input:isKeyPressed("space"),
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
        assert.is_false(input:isKeyPressed("space"))

        input:enterFixedPhase()
        assert.is_true(input:isKeyPressed("space"),
            "the fixed step must see the press it would otherwise miss")
        assert.is_true(input:isKeyReleased("space"))
        input:exitFixedPhase()

        -- Consumed: the next fixed step starts clean.
        input:enterFixedPhase()
        assert.is_false(input:isKeyPressed("space"))
        input:exitFixedPhase()
    end)

    it("hides input from layers beneath a blocking one", function()
        input:beginFrame()
        input:handleEvent(keyEvent(SPACE, true))
        assert.is_true(input:isKeyDown("space"), "base reads by default")

        local menu = input:pushLayer("menu")
        assert.is_true(input:isKeyDown("space", menu), "the top layer reads")
        assert.is_false(input:isKeyDown("space"),
            "gameplay goes quiet without knowing a menu exists")

        input:popLayer()
        assert.is_true(input:isKeyDown("space"), "and comes back when it closes")
    end)

    it("lets a non-blocking overlay observe without consuming", function()
        input:beginFrame()
        input:handleEvent(keyEvent(SPACE, true))

        local overlay = input:pushLayer("debug", false)
        assert.is_true(input:isKeyDown("space", overlay))
        assert.is_true(input:isKeyDown("space"),
            "a passthrough layer must not suppress what is under it")
    end)

    it("tracks mouse buttons on the same three tiers", function()
        local buttons = Input.buttons()
        input:beginFrame()
        input:handleEvent(mouseEvent(buttons.left, true))

        assert.is_true(input:isMouseDown(buttons.left))
        assert.is_true(input:isMousePressed(buttons.left))
        assert.is_false(input:isMouseDown(buttons.right))

        input:beginFrame()
        input:handleEvent(mouseEvent(buttons.left, false))
        assert.is_false(input:isMouseDown(buttons.left))
        assert.is_true(input:isMouseReleased(buttons.left))
    end)

    it("applies a deadzone to axes", function()
        input:beginFrame()
        input:handleEvent(axisEvent(0, 1.0))
        assert.is_true(math.abs(input:axis(0) - 1.0) < 0.001)

        input:handleEvent(axisEvent(0, 0.0305))
        assert.are.equal(0.0, input:axis(0),
            "stick drift is hardware, not gameplay, so it is filtered here")
        assert.is_true(input:axis(0, 0.01) > 0.0,
            "an explicit smaller deadzone still sees it")
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
end)
