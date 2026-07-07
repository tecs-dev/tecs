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
end)
