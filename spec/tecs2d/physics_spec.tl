require("busted")

local love2dMock <const> = require("spec.love2d.love2d_mock")
rawset(_G, "love", love2dMock)

local physics <const> = require("tecs2d.physics")
local luassert <const> = require("luassert")

describe("tecs2d.physics", function()
    describe("categories", function()
        it("builds a Box2D category mask", function()
            luassert.equals(0x8005, physics.categories(1, 3, 16))
        end)

        it("rejects values outside the Box2D category range", function()
            luassert.has_error(function() physics.categories(0) end)
            luassert.has_error(function() physics.categories(17) end)
        end)

        it("rejects fractional category numbers", function()
            luassert.has_error(function() physics.categories(1.5 as integer) end)
        end)
    end)
end)
