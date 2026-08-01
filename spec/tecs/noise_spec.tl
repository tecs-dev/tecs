require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

local noise <const> = tecs.math.noise

local function near(expected: number, actual: number, what: string)
    luassert.is_true(math.abs(expected - actual) < 1e-6, what .. " gave " .. string.format("%.17g", actual))
end

describe(
    "math noise",
    function()
        it(
            "reproduces known samples",
            function()
                -- The implementation returns f32 values. The tolerance admits the
                -- last bits changing when a backend contracts floating-point work.
                local field <const> = noise.new({seed = 777, frequency = 1})
                near(0.19981878, field:sample2(0.5, 0.5), "sample2(0.5, 0.5)")
                near(0.39056084, field:sample2(1.25, -3.75), "sample2(1.25, -3.75)")
                near(0.20810865, field:sample2(12.125, 7.875), "sample2(12.125, 7.875)")
                near(-0.24123035, field:sample3(0.5, 0.5, 0.5), "sample3(0.5, 0.5, 0.5)")
            end
        )

        it(
            "uses zero as a seed and frequency rather than their defaults",
            function()
                local zeroSeed <const> = noise.new({seed = 0, frequency = 1})
                local defaultSeed <const> = noise.new({frequency = 1})
                luassert.not_equal(zeroSeed:sample2(0.5, 0.5), defaultSeed:sample2(0.5, 0.5))

                local constant <const> = noise.new({seed = 12, frequency = 0})
                luassert.equal(constant:sample2(1, 2), constant:sample2(300, -900))
            end
        )

        it(
            "supports every algorithm and fractal mode",
            function()
                local algorithms <const> = {
                    "perlin",
                    "simplex",
                    "simplexSmooth",
                    "cellular",
                    "value",
                    "valueCubic",
                } as {noise.Algorithm}
                local fractals <const> = {"none", "fbm", "ridged", "pingPong"} as {noise.Fractal}
                for _, algorithm in ipairs(algorithms) do
                    for _, fractal in ipairs(fractals) do
                        local field <const> = noise.new({
                            algorithm = algorithm,
                            fractal = fractal,
                            seed = 2024,
                            frequency = 0.041,
                            octaves = 4,
                        })
                        for index = 1, 32 do
                            local value2 <const> = field:sample2(index * 0.37, index * -0.19)
                            local value3 <const> = field:sample3(index * 0.11, index * 0.23, index * -0.29)
                            luassert.is_true(value2 >= -1.0 and value2 <= 1.0, algorithm .. " " .. fractal)
                            luassert.is_true(value3 >= -1.0 and value3 <= 1.0, algorithm .. " " .. fractal)
                        end
                    end
                end
            end
        )

        it(
            "fills a reusable table in row-major order",
            function()
                local field <const> = noise.new({seed = 91, frequency = 0.17, fractal = "fbm", octaves = 4})
                local values <const>: {number} = {99, 99, 99, 99, 99, 99, 99, 99, 99, 99}
                local returned <const> = field:fill2(values, 3, 2, -2.5, 7.25, 0.5, -0.25)
                luassert.is_true(returned == values)
                luassert.equal(6, #values)
                local index = 1
                for row = 0, 1 do
                    for column = 0, 2 do
                        near(field:sample2(-2.5 + column * 0.5, 7.25 - row * 0.25), values[index], "fill2")
                        index = index + 1
                    end
                end

                field:fill2(values, 1, 1, 4, 5)
                luassert.equal(1, #values)
                near(field:sample2(4, 5), values[1], "reused fill2")
                luassert.is_true(field:fill2(values, 0, 4) == values)
                luassert.equal(0, #values)
            end
        )

        it(
            "rejects invalid options and coordinates",
            function()
                luassert.has_error(
                    function() noise.new({octaves = 0}) end,
                    "noise: octaves must be an integer from 1 through 32"
                )
                luassert.has_error(
                    function() noise.new({algorithm = "missing" as noise.Algorithm}) end,
                    "noise: unknown algorithm missing"
                )
                luassert.has_error(
                    function() noise.new({fractal = "missing" as noise.Fractal}) end,
                    "noise: unknown fractal missing"
                )
                luassert.has_error(
                    function() noise.new({weightedStrength = 1.1}) end,
                    "noise: weightedStrength must be from zero through one"
                )

                local field <const> = noise.new()
                luassert.has_error(function() field:sample2(0 / 0, 0) end, "noise: x must be finite")
                luassert.has_error(
                    function() field:fill2({}, -1, 2) end,
                    "noise: width must be an integer from zero through 2147483647"
                )
                luassert.has_error(function() field:fill2({}, 1073741824, 2) end, "noise: the grid dimensions are too large")
            end
        )
    end
)
