require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local StringBuffer <const> = require("string.buffer")

local random <const> = tecs.random

local function save(world: tecs.World): StringBuffer
    local out <const> = world:saveSnapshot()
    if out.buffer == nil then
        error("saveSnapshot(binary) returned no buffer")
    end
    return out.buffer
end

local function draw(generator: random.Random, count: integer): {number}
    local values: {number} = {}
    for i = 1, count do values[i] = generator:next() end
    return values
end

describe("random", function()
    describe("the generator", function()
        it("gives the same sequence for the same seed", function()
            local a <const> = random.new(42)
            local b <const> = random.new(42)
            for i = 1, 5000 do
                luassert.equal(a:next(), b:next(), "draw " .. tostring(i))
            end
        end)

        it("gives a different sequence for a different seed", function()
            local a <const> = draw(random.new(42), 200)
            local b <const> = draw(random.new(43), 200)
            local shared = 0
            for i = 1, 200 do
                if a[i] == b[i] then shared = shared + 1 end
            end
            luassert.equal(0, shared)
        end)

        it("reads a seed as a 32-bit word", function()
            local a <const> = draw(random.new(2 ^ 31), 20)
            local b <const> = draw(random.new(-(2 ^ 31)), 20)
            luassert.same(a, b)
        end)

        it("recovers from a seed with almost no entropy in it", function()
            -- Four SplitMix32 draws rather than the seed itself, so seeds one
            -- apart do not open with near-identical values.
            local a <const> = draw(random.new(0), 4)
            local b <const> = draw(random.new(1), 4)
            for i = 1, 4 do
                luassert.is_true(math.abs(a[i] - b[i]) > 0.01,
                    "seeds 0 and 1 opened within 0.01 at draw " .. tostring(i))
            end
        end)

        it("stays inside [0, 1) and covers it evenly", function()
            local generator <const> = random.new(7)
            local buckets: {integer} = {}
            for i = 1, 16 do buckets[i] = 0 end
            for _ = 1, 320000 do
                local v <const> = generator:next()
                luassert.is_true(v >= 0.0 and v < 1.0, "out of [0, 1): " .. tostring(v))
                local k <const> = math.floor(v * 16) + 1
                buckets[k] = buckets[k] + 1
            end
            for i = 1, 16 do
                local share <const> = buckets[i] / 320000
                luassert.is_true(math.abs(share - 1 / 16) < 0.004,
                    "bucket " .. tostring(i) .. " held " .. tostring(share))
            end
        end)

        it("reproduces a known sequence bit for bit", function()
            -- The generator is integer arithmetic through LuaJIT's `bit`
            -- library, whose operations are 32-bit two's complement whatever
            -- the host word size is, and the conversion to a fraction is an
            -- exact scale by a power of two. So these are not approximately
            -- the values another machine produces, they are the values.
            local generator <const> = random.new(12345)
            local expected <const>: {number} = {
                0.25454781646840274, 0.047265402274206281,
                0.87110176053829491, 0.88562377681955695,
                0.97293841186910868, 0.18865043367259204,
                0.31380670145153999, 0.94012095988728106,
            }
            for i = 1, 8 do
                luassert.equal(expected[i], generator:next(), "draw " .. tostring(i))
            end
            luassert.same({ 522211826, 1785743282, 676026232, -1112538433 },
                generator:state())
        end)

        it("reproduces a known run of integers", function()
            local generator <const> = random.new(12345)
            local expected <const>: {integer} = {
                26, 5, 88, 89, 98, 19, 32, 95, 87, 90, 75, 51,
            }
            for i = 1, 12 do
                luassert.equal(expected[i], generator:integer(1, 100))
            end
        end)
    end)

    describe("draws", function()
        it("keeps integer inside both ends and reaches each of them", function()
            local generator <const> = random.new(11)
            local seen: {integer: boolean} = {}
            for _ = 1, 20000 do
                local v <const> = generator:integer(-3, 3)
                luassert.is_true(v >= -3 and v <= 3, "out of range: " .. tostring(v))
                luassert.equal(v, math.floor(v))
                seen[v] = true
            end
            for v = -3, 3 do
                luassert.is_true(seen[v] == true, "never drew " .. tostring(v))
            end
        end)

        it("counts a one-argument integer from one", function()
            local generator <const> = random.new(3)
            local seen: {integer: boolean} = {}
            for _ = 1, 20000 do
                local v <const> = generator:integer(4)
                luassert.is_true(v >= 1 and v <= 4, "out of range: " .. tostring(v))
                seen[v] = true
            end
            for v = 1, 4 do
                luassert.is_true(seen[v] == true, "never drew " .. tostring(v))
            end
        end)

        it("refuses an empty integer range", function()
            local generator <const> = random.new(1)
            luassert.has_error(function()
                generator:integer(5, 3)
            end, "random: integer(5, 3) has an empty range")
        end)

        it("keeps range inside its ends", function()
            local generator <const> = random.new(5)
            local low, high = math.huge, -math.huge
            for _ = 1, 50000 do
                local v <const> = generator:range(-2.5, 7.5)
                luassert.is_true(v >= -2.5 and v < 7.5, "out of range: " .. tostring(v))
                if v < low then low = v end
                if v > high then high = v end
            end
            luassert.is_true(low < -2.4 and high > 7.4, "range did not cover its span")
        end)

        it("shuffles into a permutation, and the same one for the same seed", function()
            local first: {integer} = {}
            local second: {integer} = {}
            for i = 1, 200 do
                first[i] = i
                second[i] = i
            end
            random.new(99):shuffle(first)
            random.new(99):shuffle(second)
            luassert.same(first, second)

            local seen: {integer: boolean} = {}
            local moved = 0
            for i = 1, 200 do
                luassert.is_nil(seen[first[i]], "duplicate after shuffle")
                seen[first[i]] = true
                if first[i] ~= i then moved = moved + 1 end
            end
            luassert.equal(200, #first)
            luassert.is_true(moved > 190, "only " .. tostring(moved) .. " moved")
        end)
    end)

    describe("state", function()
        it("carries four words that resume the sequence", function()
            local generator <const> = random.new(5)
            for _ = 1, 1000 do generator:next() end
            local words <const> = generator:state()
            local expected <const> = draw(generator, 50)

            local other <const> = random.new(0)
            other:setState(words)
            luassert.same(expected, draw(other, 50))
        end)

        it("refuses a state that is not four words", function()
            local generator <const> = random.new(1)
            luassert.has_error(function()
                generator:setState({ 1, 2, 3 })
            end, "random: setState needs four state words")
        end)

        it("refuses the all-zero state", function()
            local generator <const> = random.new(1)
            luassert.has_error(function()
                generator:setState({ 0, 0, 0, 0 })
            end, "random: the all-zero state is the one xoshiro cannot leave")
        end)
    end)

    describe("streams", function()
        it("hands the same generator back for the same name", function()
            local world <const> = tecs.newWorld()
            luassert.is_true(random.stream(world, "a") == random.stream(world, "a"))
            luassert.is_false(random.stream(world, "a") == random.stream(world, "b"))
        end)

        it("refuses an unnamed stream", function()
            local world <const> = tecs.newWorld()
            luassert.has_error(function()
                random.stream(world, "")
            end, "random: a stream needs a non-empty name")
        end)

        it("gives a name the same seed however many other streams exist", function()
            -- The claim that makes a replay survive a code change: a stream's
            -- seed comes from its name and the world's, so adding a system,
            -- removing one, or having one draw a different number of values
            -- moves nothing about what any other system sees.
            local alone <const> = tecs.newWorld()
            random.seed(alone, 999)
            local expected <const> = draw(random.stream(alone, "alpha"), 20)

            local crowded <const> = tecs.newWorld()
            random.seed(crowded, 999)
            random.stream(crowded, "beta"):next()
            for _ = 1, 37 do random.stream(crowded, "gamma"):integer(1, 1000) end
            random.stream(crowded, "delta"):shuffle({ 1, 2, 3, 4, 5 })

            luassert.same(expected, draw(random.stream(crowded, "alpha"), 20))
        end)

        it("gives different names different sequences", function()
            local world <const> = tecs.newWorld()
            random.seed(world, 999)
            local a <const> = draw(random.stream(world, "alpha"), 100)
            local b <const> = draw(random.stream(world, "beta"), 100)
            local shared = 0
            for i = 1, 100 do
                if a[i] == b[i] then shared = shared + 1 end
            end
            luassert.equal(0, shared)
        end)

        it("restarts every stream when the world is reseeded", function()
            local world <const> = tecs.newWorld()
            random.seed(world, 4242)
            local stream <const> = random.stream(world, "alpha")
            local expected <const> = draw(stream, 20)

            for _ = 1, 500 do stream:next() end
            random.seed(world, 4242)
            luassert.same(expected, draw(stream, 20))
        end)

        it("gives the same world seed the same streams in a fresh world", function()
            local first <const> = tecs.newWorld()
            random.seed(first, 31337)
            local expected <const> = draw(random.stream(first, "loot"), 40)

            local second <const> = tecs.newWorld()
            random.seed(second, 31337)
            luassert.same(expected, draw(random.stream(second, "loot"), 40))
        end)

        it("gives a different world seed different streams", function()
            local first <const> = tecs.newWorld()
            random.seed(first, 31337)
            local a <const> = draw(random.stream(first, "loot"), 40)

            local second <const> = tecs.newWorld()
            random.seed(second, 31338)
            local b <const> = draw(random.stream(second, "loot"), 40)

            local shared = 0
            for i = 1, 40 do
                if a[i] == b[i] then shared = shared + 1 end
            end
            luassert.equal(0, shared)
        end)
    end)

    describe("a stream in a snapshot", function()
        it("continues the saved sequence rather than restarting it", function()
            local world <const> = tecs.newWorld()
            random.seed(world, 4242)
            local loot <const> = random.stream(world, "loot")
            for _ = 1, 25 do loot:next() end

            local saved <const> = save(world)
            local expected <const> = draw(loot, 20)
            -- Left a long way from where it was saved, so a load that reseeded
            -- from the world's seed instead of the saved words would not match.
            for _ = 1, 500 do loot:next() end

            world:loadSnapshot(saved)
            luassert.same(expected, draw(loot, 20),
                "the generator the caller holds must be the one that was restored")
        end)

        it("puts a stream back that this run has not asked for yet", function()
            local origin <const> = tecs.newWorld()
            random.seed(origin, 4242)
            local loot <const> = random.stream(origin, "loot")
            for _ = 1, 30 do loot:next() end
            local saved <const> = save(origin)
            local expected <const> = draw(loot, 20)

            local restored <const> = tecs.newWorld()
            random.seed(restored, 1)
            restored:loadSnapshot(saved)
            luassert.same(expected, draw(random.stream(restored, "loot"), 20))
        end)

        it("restarts a stream the file does not name", function()
            local origin <const> = tecs.newWorld()
            random.seed(origin, 4242)
            random.stream(origin, "loot"):next()
            local saved <const> = save(origin)

            local restored <const> = tecs.newWorld()
            random.seed(restored, 1)
            local unsaved <const> = random.stream(restored, "weather")
            for _ = 1, 100 do unsaved:next() end
            restored:loadSnapshot(saved)

            -- Reseeded from the restored world seed, which is what it would
            -- have had if the save had been taken before it ever existed.
            local reference <const> = tecs.newWorld()
            random.seed(reference, 4242)
            luassert.same(draw(random.stream(reference, "weather"), 10),
                draw(unsaved, 10))
        end)

        it("carries the world seed, so a later stream derives from it", function()
            local origin <const> = tecs.newWorld()
            random.seed(origin, 8675309)
            random.stream(origin, "loot"):next()
            local saved <const> = save(origin)

            local restored <const> = tecs.newWorld()
            random.seed(restored, 1)
            restored:loadSnapshot(saved)

            local reference <const> = tecs.newWorld()
            random.seed(reference, 8675309)
            luassert.same(draw(random.stream(reference, "spawns"), 20),
                draw(random.stream(restored, "spawns"), 20))
        end)

        it("writes the streams under one named key", function()
            local world <const> = tecs.newWorld()
            random.seed(world, 4242)
            random.stream(world, "loot"):next()

            local out <const> = world:saveSnapshot({ format = "table" })
            local snapshot <const> = out.snapshot
            if snapshot == nil then error("no snapshot") end
            local found: {string: any} = nil
            for _, entry in ipairs(snapshot.data) do
                if entry.key == "tecs.random" then
                    found = entry.value as {string: any}
                end
            end
            luassert.is_not_nil(found, "no tecs.random entry in the data section")
            luassert.equal(4242, found.seed)
            local streams <const> = found.streams as {string: {integer}}
            luassert.equal(4, #streams["loot"])
        end)
    end)

    describe("noise", function()
        it("is exactly zero at integer coordinates", function()
            local field <const> = random.noise(2024)
            for x = -4, 4 do
                for y = -4, 4 do
                    luassert.equal(0, field:noise2(x, y))
                    luassert.equal(0, field:noise3(x, y, x - y))
                end
            end
        end)

        it("stays inside [-1, 1]", function()
            local field <const> = random.noise(2024)
            for i = 0, 400 do
                for j = 0, 400 do
                    local v <const> = field:noise2(i * 0.037, j * 0.037)
                    luassert.is_true(v >= -1.0 and v <= 1.0, "noise2 gave " .. tostring(v))
                end
            end
            for i = 0, 40 do
                for j = 0, 40 do
                    for k = 0, 40 do
                        local v <const> = field:noise3(i * 0.13, j * 0.13, k * 0.13)
                        luassert.is_true(v >= -1.0 and v <= 1.0, "noise3 gave " .. tostring(v))
                    end
                end
            end
        end)

        it("moves smoothly, with no step between neighbours", function()
            local field <const> = random.noise(2024)
            local previous = field:noise2(0.5, 0.5)
            for i = 1, 20000 do
                local v <const> = field:noise2(0.5 + i * 0.0002, 0.5)
                luassert.is_true(math.abs(v - previous) < 0.01,
                    "jumped " .. tostring(math.abs(v - previous)) .. " in one step")
                previous = v
            end
        end)

        it("gives the same field for the same seed", function()
            local a <const> = random.noise(2024)
            local b <const> = random.noise(2024)
            for i = 1, 2000 do
                luassert.equal(a:noise2(i * 0.31, i * 0.17), b:noise2(i * 0.31, i * 0.17))
            end
        end)

        it("gives a different field for a different seed", function()
            local a <const> = random.noise(2024)
            local b <const> = random.noise(2025)
            local shared = 0
            for i = 1, 500 do
                if a:noise2(i * 0.31, i * 0.17) == b:noise2(i * 0.31, i * 0.17) then
                    shared = shared + 1
                end
            end
            luassert.is_true(shared < 20, tostring(shared) .. " of 500 samples matched")
        end)

        it("reproduces known values", function()
            -- Floating-point rather than integer work, so this is held to a
            -- tolerance: a backend free to contract a multiply and an add into
            -- one instruction moves the last bits and nothing more.
            local field <const> = random.noise(777)
            local function near(expected: number, actual: number, what: string)
                luassert.is_true(math.abs(expected - actual) < 1e-12,
                    what .. " gave " .. string.format("%.17g", actual))
            end
            near(-0.25, field:noise2(0.5, 0.5), "noise2(0.5, 0.5)")
            near(0.016073226928710931, field:noise2(1.25, -3.75), "noise2(1.25, -3.75)")
            near(0.15619002330482737, field:noise2(12.125, 7.875), "noise2(12.125, 7.875)")
            near(0.20412414523193151, field:noise3(0.5, 0.5, 0.5), "noise3(0.5, 0.5, 0.5)")
            near(-0.13531608398311654, field:fbm2(0.3, 0.7, 4), "fbm2(0.3, 0.7, 4)")
        end)

        it("stacks octaves and stays inside [-1, 1]", function()
            local field <const> = random.noise(2024)
            local plain, layered = 0.0, 0.0
            for i = 0, 300 do
                for j = 0, 300 do
                    local one <const> = field:fbm2(i * 0.041, j * 0.041, 1)
                    local five <const> = field:fbm2(i * 0.041, j * 0.041, 5)
                    luassert.is_true(five >= -1.0 and five <= 1.0, "fbm2 gave " .. tostring(five))
                    plain = plain + math.abs(one)
                    layered = layered + math.abs(five)
                end
            end
            -- One octave is noise2 itself, and stacking quieter ones on top
            -- pulls the field towards its middle rather than past its ends.
            luassert.is_true(layered < plain, "five octaves were not calmer than one")
            luassert.is_true(layered > plain * 0.3, "five octaves flattened the field")
        end)

        it("refuses an octave count below one", function()
            local field <const> = random.noise(1)
            luassert.has_error(function()
                field:fbm2(0.5, 0.5, 0)
            end, "random: fbm needs at least one octave")
            luassert.has_error(function()
                field:fbm3(0.5, 0.5, 0.5, -1)
            end, "random: fbm needs at least one octave")
        end)
    end)
end)
