-- Allocation-free vector math through the public surface.

local root = os.getenv("TECS_LUA") or "out/macos-arm64-dev/lua"
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local vector = require("tecs").math

local function near(actual, expected)
    assert.is_true(math.abs(actual - expected) <= 1e-12, ("expected %.17g, got %.17g"):format(expected, actual))
end

local function nearPair(expectedX, expectedY, actualX, actualY)
    near(actualX, expectedX)
    near(actualY, expectedY)
end

describe("tecs.math", function()
    it("uses separate coordinates and multiple returns", function()
        nearPair(6, 5, vector.add(2, -3, 4, 8))
        nearPair(-2, -11, vector.subtract(2, -3, 4, 8))
        nearPair(-4, 6, vector.scale(2, -3, -2))
        assert.are.equal(2, select("#", vector.add(1, 2, 3, 4)))
        assert.are.equal(-7, vector.dot(2, 3, 4, -5))
        assert.are.equal(1, vector.cross(1, 0, 0, 1))
    end)

    it("computes lengths and distances with squared forms", function()
        assert.are.equal(25, vector.lengthSquared(3, 4))
        assert.are.equal(5, vector.length(3, 4))
        assert.are.equal(25, vector.distanceSquared(2, 3, 5, 7))
        assert.are.equal(5, vector.distance(2, 3, 5, 7))
    end)

    it("defines normalization of zero without NaN", function()
        nearPair(0.6, 0.8, vector.normalize(3, 4))
        nearPair(0, 0, vector.normalize(0, 0))
    end)

    it("interpolates without clamping", function()
        nearPair(2, 4, vector.lerp(2, 4, 10, 20, 0))
        nearPair(10, 20, vector.lerp(2, 4, 10, 20, 1))
        nearPair(14, 28, vector.lerp(2, 4, 10, 20, 1.5))
    end)

    it("moves toward a point without overshooting", function()
        nearPair(1.2, 1.6, vector.moveTowards(0, 0, 3, 4, 2))
        nearPair(3, 4, vector.moveTowards(0, 0, 3, 4, 5))
        nearPair(3, 4, vector.moveTowards(0, 0, 3, 4, 50))
        nearPair(3, 4, vector.moveTowards(3, 4, 3, 4, 2))
        nearPair(0, 0, vector.moveTowards(0, 0, 3, 4, -1))
    end)

    it("uses radians and Transform's positive rotation sense", function()
        nearPair(0, 1, vector.rotate(1, 0, math.pi / 2))
        near(vector.angle(0, 1), math.pi / 2)
        assert.are.equal(0, vector.angle(0, 0))
    end)

    it("computes unsigned and signed angles", function()
        near(vector.angleBetween(1, 0, 0, 1), math.pi / 2)
        near(vector.angleBetween(0, 1, 1, 0), math.pi / 2)
        near(vector.angleBetween(1, 0, -1, 0), math.pi)
        assert.are.equal(0, vector.angleBetween(0, 0, 1, 0))

        near(vector.signedAngleBetween(1, 0, 0, 1), math.pi / 2)
        near(vector.signedAngleBetween(0, 1, 1, 0), -math.pi / 2)
        near(vector.signedAngleBetween(1, 0, -1, 0), -math.pi)
        assert.are.equal(0, vector.signedAngleBetween(0, 0, 1, 0))
    end)

    it("wraps angles and computes the shortest turn", function()
        near(vector.wrapAngle(0), 0)
        near(vector.wrapAngle(math.pi), -math.pi)
        near(vector.wrapAngle(-3 * math.pi), -math.pi)
        near(vector.deltaAngle(math.rad(350), math.rad(10)), math.rad(20))
        near(vector.deltaAngle(math.rad(10), math.rad(350)), math.rad(-20))
        near(vector.deltaAngle(0, math.pi), -math.pi)
    end)

    it("projects onto non-unit axes and defines a zero axis", function()
        nearPair(3, 0, vector.project(3, 4, 2, 0))
        nearPair(3.5, 3.5, vector.project(3, 4, 1, 1))
        nearPair(0, 0, vector.project(3, 4, 0, 0))
    end)

    it("reflects across non-unit normals and defines a zero normal", function()
        nearPair(3, 4, vector.reflect(3, -4, 0, 2))
        nearPair(-1, -2, vector.reflect(2, 1, 1, 1))
        nearPair(3, 4, vector.reflect(3, 4, 0, 0))
    end)
end)
