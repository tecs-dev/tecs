require("busted")

local luassert <const> = require("luassert")

-- Installs the love global used by the input handlers
require("spec.love2d.love2d_mock")

local input <const> = require("tecs2d.input")
local handlers <const> = require("tecs2d.internal.handlers")

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

    describe("input stack", function()
        after_each(function()
            while input.stackDepth() > 0 do
                input.popStack(input.stackDepth())
            end
        end)

        it("suppresses the game while a layer is pushed and restores on pop", function()
            input.keysPressed["f"] = true
            luassert.is_true(input.isKeyPressed("f"))            -- game sees it

            local token = input.pushStack()
            input.keysPressed["g"] = true                        -- input during the layer
            luassert.is_false(input.isKeyPressed("g"))           -- game (base) dark
            luassert.is_true(input.stack[token].isKeyPressed("g"))  -- the layer sees it

            input.popStack(token)
            input.keysPressed["h"] = true                        -- input after handing back
            luassert.is_true(input.isKeyPressed("h"))            -- game reads it again
        end)

        it("gives real input only to the top layer", function()
            local a = input.pushStack()
            local b = input.pushStack()
            input.keysPressed["f"] = true

            luassert.is_true(input.stack[b].isKeyPressed("f"))   -- top sees real
            luassert.is_false(input.stack[a].isKeyPressed("f"))  -- lower layer dark
            luassert.is_false(input.isKeyPressed("f"))           -- game dark

            input.popStack(b)
            input.keysPressed["f"] = true
            luassert.is_true(input.stack[a].isKeyPressed("f"))   -- a is now top
        end)

        it("only allows popping the top layer", function()
            local a = input.pushStack()
            local b = input.pushStack()

            luassert.has_error(function() input.popStack(a) end)  -- a is not the top
            input.popStack(b)
            input.popStack(a)
            luassert.equals(0, input.stackDepth())
        end)

        it("consumes latched input taken while a layer was up", function()
            -- Reproduces the fullscreen-on-close bug: an "f" release recorded
            -- while the debugger layer was up must not fire for the game when the
            -- layer pops and a fixed-update phase reads it.
            local token = input.pushStack()
            input.keysLatchedReleased["f"] = true
            input.popStack(token)

            input.enterFixedPhase()
            local released = input.isKeyReleased("f")
            input.exitFixedPhase()
            luassert.is_false(released)
        end)
    end)
end)
