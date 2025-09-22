require("busted")

-- Set up love mock before requiring tecs2d.gfx modules
rawset(_G, "love", require("spec.love2d.love2d_mock"))

-- Skip if Love2D 12 GPU features aren't available (mock doesn't support full GPU)
if not love.graphics.newComputeShader then
    pending("Polygon tests require Love2D 12 GPU features")
    return
end

local luassert <const> = require("luassert")
local gfx <const> = require("tecs2d.gfx")

local Polygon <const> = gfx.Polygon

describe("tecs2d.gfx.Polygon", function()
    describe("constructor", function()
        describe("positional arguments", function()
            it("creates polygon with points array", function()
                local poly = Polygon({0, 0, 100, 0, 50, 50})

                luassert.is_not_nil(poly)
                luassert.is_equal(6, #poly.points)
                luassert.is_equal(0, poly.points[1])
                luassert.is_equal(0, poly.points[2])
                luassert.is_equal(100, poly.points[3])
                luassert.is_equal(0, poly.points[4])
                luassert.is_equal(50, poly.points[5])
                luassert.is_equal(50, poly.points[6])
            end)

            it("defaults closed to true", function()
                local poly = Polygon({0, 0, 100, 0, 50, 50})

                luassert.is_true(poly.closed)
            end)

            it("defaults line to true", function()
                local poly = Polygon({0, 0, 100, 0, 50, 50})

                luassert.is_true(poly.line)
            end)

            it("accepts closed parameter", function()
                local closedPoly = Polygon({0, 0, 100, 0}, true)
                local openPoly = Polygon({0, 0, 100, 0}, false)

                luassert.is_true(closedPoly.closed)
                luassert.is_false(openPoly.closed)
            end)

            it("accepts line parameter", function()
                local linePoly = Polygon({0, 0, 100, 0}, true, true)
                local filledPoly = Polygon({0, 0, 100, 0}, true, false)

                luassert.is_true(linePoly.line)
                luassert.is_false(filledPoly.line)
            end)

            it("creates filled closed polygon", function()
                local poly = Polygon({0, 0, 100, 0, 50, 50}, true, false)

                luassert.is_true(poly.closed)
                luassert.is_false(poly.line)
            end)

            it("creates open polyline", function()
                local poly = Polygon({0, 0, 50, 25, 100, 0}, false)

                luassert.is_false(poly.closed)
                luassert.is_true(poly.line)  -- polylines are always lines
            end)
        end)

        describe("table-based constructor", function()
            it("creates polygon from table with points field", function()
                local poly = Polygon({points = {0, 0, 100, 0, 50, 50}} as {number})

                luassert.is_not_nil(poly)
                luassert.is_equal(6, #poly.points)
            end)

            it("accepts closed field", function()
                local closedPoly = Polygon({points = {0, 0, 100, 0}, closed = true} as {number})
                local openPoly = Polygon({points = {0, 0, 100, 0}, closed = false} as {number})

                luassert.is_true(closedPoly.closed)
                luassert.is_false(openPoly.closed)
            end)

            it("accepts line field", function()
                local linePoly = Polygon({points = {0, 0, 100, 0}, line = true} as {number})
                local filledPoly = Polygon({points = {0, 0, 100, 0}, line = false} as {number})

                luassert.is_true(linePoly.line)
                luassert.is_false(filledPoly.line)
            end)

            it("defaults closed and line to true", function()
                local poly = Polygon({points = {0, 0, 100, 0}} as {number})

                luassert.is_true(poly.closed)
                luassert.is_true(poly.line)
            end)
        end)

        describe("edge cases", function()
            it("handles empty points array", function()
                local poly = Polygon({})

                luassert.is_not_nil(poly)
                luassert.is_equal(0, #poly.points)
            end)

            it("handles minimal points (one point)", function()
                local poly = Polygon({50, 50})

                luassert.is_equal(2, #poly.points)
            end)
        end)
    end)

    describe("getRect", function()
        it("calculates bounding box for triangle", function()
            local poly = Polygon({0, 0, 100, 0, 50, 50})

            local ox, oy, w, h = poly:getRect()

            luassert.is_equal(0, ox)
            luassert.is_equal(0, oy)
            luassert.is_equal(100, w)
            luassert.is_equal(50, h)
        end)

        it("calculates bounding box for polygon with negative coordinates", function()
            local poly = Polygon({-50, -25, 50, -25, 50, 25, -50, 25})

            local ox, oy, w, h = poly:getRect()

            luassert.is_equal(-50, ox)
            luassert.is_equal(-25, oy)
            luassert.is_equal(100, w)
            luassert.is_equal(50, h)
        end)

        it("calculates bounding box for single point", function()
            local poly = Polygon({10, 20})

            local ox, oy, w, h = poly:getRect()

            luassert.is_equal(10, ox)
            luassert.is_equal(20, oy)
            luassert.is_equal(0, w)
            luassert.is_equal(0, h)
        end)

        it("returns zero bounds for empty points", function()
            local poly = Polygon({})

            local ox, oy, w, h = poly:getRect()

            luassert.is_equal(0, ox)
            luassert.is_equal(0, oy)
            luassert.is_equal(0, w)
            luassert.is_equal(0, h)
        end)

        it("handles complex polygon shape", function()
            -- Star-like shape
            local poly = Polygon({0, -40, 10, -10, 40, 0, 10, 10, 0, 40, -10, 10, -40, 0, -10, -10})

            local ox, oy, w, h = poly:getRect()

            luassert.is_equal(-40, ox)
            luassert.is_equal(-40, oy)
            luassert.is_equal(80, w)
            luassert.is_equal(80, h)
        end)
    end)

    describe("setPoints", function()
        it("updates points array", function()
            local poly = Polygon({0, 0, 10, 10})

            poly:setPoints({0, 0, 100, 0, 100, 100, 0, 100})

            luassert.is_equal(8, #poly.points)
            luassert.is_equal(100, poly.points[3])
        end)

        it("recalculates bounding box", function()
            local poly = Polygon({0, 0, 10, 10})

            -- Initial bounds
            local ox1, oy1, w1, h1 = poly:getRect()
            luassert.is_equal(0, ox1)
            luassert.is_equal(0, oy1)
            luassert.is_equal(10, w1)
            luassert.is_equal(10, h1)

            -- Update to larger shape
            poly:setPoints({-50, -50, 50, -50, 50, 50, -50, 50})

            local ox2, oy2, w2, h2 = poly:getRect()
            luassert.is_equal(-50, ox2)
            luassert.is_equal(-50, oy2)
            luassert.is_equal(100, w2)
            luassert.is_equal(100, h2)
        end)

        it("handles empty points", function()
            local poly = Polygon({0, 0, 100, 100})

            poly:setPoints({})

            luassert.is_equal(0, #poly.points)
            local ox, oy, w, h = poly:getRect()
            luassert.is_equal(0, ox)
            luassert.is_equal(0, oy)
            luassert.is_equal(0, w)
            luassert.is_equal(0, h)
        end)
    end)

    describe("Rect interface", function()
        it("has getRect method", function()
            local poly = Polygon({0, 0, 100, 100})

            luassert.is_function(poly.getRect)
        end)

        it("returns four values from getRect", function()
            local poly = Polygon({0, 0, 100, 50})

            local ox, oy, w, h = poly:getRect()

            luassert.is_number(ox)
            luassert.is_number(oy)
            luassert.is_number(w)
            luassert.is_number(h)
        end)
    end)
end)
