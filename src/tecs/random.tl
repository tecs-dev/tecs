--- Seeded generation, in named streams a snapshot carries.
---
--- **Nothing here reads a clock.** A generator produces the same sequence from
--- the same seed on every machine this runs on, which is what lets a replay,
--- a snapshot and a bug report all describe the same run. `math.random` cannot:
--- its state is a process-wide global with no way to read it back, so anything
--- built on it is reproducible only by accident.
---
--- **Streams are named, and independent.** A stream's own seed is hashed from
--- the world's seed and the stream's name, so a name that did not exist before
--- gets a seed of its own without moving any other name's. That is the property
--- a replay needs: adding a system, or having one draw a different number of
--- values this run, changes nothing about what any other system sees. Splitting
--- one generator between consumers has the opposite property, where the order
--- consumers happen to run in decides what each of them gets.
---
--- **The state is four integers.** `world:saveSnapshot` writes every stream's
--- four words under `tecs.random`, and a load puts them back into the same
--- generator objects, so a caller that took a stream at startup keeps drawing
--- from the restored sequence rather than the one this run was on.
---
--- **Noise is not in the snapshot, because it has no state.** A noise field is
--- a pure function of its seed and its coordinates; a game rebuilds the same
--- field by asking for the same seed, so there is nothing for a save to carry.
---
---     local rng <const> = tecs.ecs.random.stream(world, "loot")
---     local roll <const> = rng:integer(1, 20)
---
---     local field <const> = tecs.ecs.random.noise(1234)
---     local height <const> = field:fbm2(x * 0.01, y * 0.01, 4)

local type types = require("tecs.types")

local bit <const> = require("bit")

local band <const> = bit.band
local bxor <const> = bit.bxor
local lshift <const> = bit.lshift
local rshift <const> = bit.rshift
local rol <const> = bit.rol
local tobit <const> = bit.tobit
local floor <const> = math.floor
local byte <const> = string.byte

--- 2^-32: the scale from a 32-bit word to a fraction of one.
local INV32 <const> = 1.0 / 4294967296.0

--- The 32-bit golden-ratio constant SplitMix32 walks its counter by.
local GOLDEN <const> = 0x9E3779B9

--- The seed a generator gets when none is named. A constant rather than
--- something read off a clock: a run that did not ask for a seed is still
--- reproducible, and a game that wants a different one each launch is stating
--- so where anyone reading it can see.
local DEFAULT_SEED <const> = 0x5EED1234

--- How much finer each fBm octave is than the one before it, and how much
--- quieter. The usual pair, fixed rather than exposed: a caller who wants
--- others is composing octaves by hand anyway.
local LACUNARITY <const> = 2.0
local GAIN <const> = 0.5

--- Perlin's bound on 2D and 3D gradient noise is +/- sqrt(N)/2 for unit
--- gradients, so these put the result in [-1, 1] with both ends reachable.
local NORM2 <const> = 1.4142135623730951
local NORM3 <const> = 1.1547005383792515

--- The eight compass directions, as unit vectors. Held as two flat arrays
--- rather than one array of pairs, so a lookup is two loads and no indirection.
local GRAD2X <const>: {number} = {
    1.0,
    0.7071067811865476,
    0.0,
    -0.7071067811865476,
    -1.0,
    -0.7071067811865476,
    0.0,
    0.7071067811865476,
}
local GRAD2Y <const>: {number} = {
    0.0,
    0.7071067811865476,
    1.0,
    0.7071067811865476,
    0.0,
    -0.7071067811865476,
    -1.0,
    -0.7071067811865476,
}

--- The twelve edge midpoints of a cube, normalised. Sixteen entries, because
--- a 4-bit hash indexes them and rounding one down to twelve would favour the
--- first four; the four repeats are Perlin's, chosen so the repetition adds no
--- direction the set does not already have.
local R2 <const> = 0.7071067811865476
local GRAD3X <const>: {number} = {
    R2,
    -R2,
    R2,
    -R2,
    R2,
    -R2,
    R2,
    -R2,
    0.0,
    0.0,
    0.0,
    0.0,
    R2,
    0.0,
    -R2,
    0.0,
}
local GRAD3Y <const>: {number} = {
    R2,
    R2,
    -R2,
    -R2,
    0.0,
    0.0,
    0.0,
    0.0,
    R2,
    -R2,
    R2,
    -R2,
    R2,
    R2,
    R2,
    -R2,
}
local GRAD3Z <const>: {number} = {
    0.0,
    0.0,
    0.0,
    0.0,
    R2,
    R2,
    -R2,
    -R2,
    R2,
    R2,
    -R2,
    -R2,
    0.0,
    -R2,
    0.0,
    -R2,
}

--- Seeded generation, in named streams a snapshot carries.
---
--- Nothing here reads a clock, so the same seed gives the same sequence on every machine.
--- A game usually wants `stream`, which ties a generator to a world and to a name and puts
--- its state in the world's snapshots; `new` and `noise` stand outside any world.
local record random
    --- A generator. Four 32-bit words of xoshiro128** state, and the draws
    --- taken off it.
    ---
    --- Not thread-safe, and not meant to be: a generator shared across threads
    --- would produce an order that depends on which one got there first, which
    --- is the whole thing this module exists to avoid. Give each thread a
    --- stream of its own.
    record Random
        --- Private. The first of the four xoshiro128** state words, held as a
        --- 32-bit two's-complement integer, so it is often negative and it is
        --- not the unsigned value a C implementation would print.
        _s0: integer

        --- Private. See `_s0`.
        _s1: integer

        --- Private. See `_s0`.
        _s2: integer

        --- Private. See `_s0`. The four are never all zero at once, which is
        --- the one state xoshiro cannot leave.
        _s3: integer

        --- The next value, in [0, 1). Advances the generator.
        next: function(self: Random): number

        --- The next integer in [1, m], or in [m, n] when both are given.
        --- Both ends are included. Advances the generator.
        ---
        --- Errors on an empty range, because a caller asking for a number
        --- between 5 and 3 has a bug and a silent 5 hides it.
        integer: function(self: Random, m: integer, n?: integer): integer

        --- The next value in [lo, hi). Advances the generator.
        --- A reversed pair is not an error here; it draws from [hi, lo).
        range: function(self: Random, lo: number, hi: number): number

        --- Fisher-Yates, in place, returning the same table. Advances the
        --- generator once per element past the first.
        shuffle: function<T>(self: Random, list: {T}): {T}

        --- Restarts the sequence from `seed`, in place.
        reseed: function(self: Random, seed: integer)

        --- The four state words. Plain integers, so a snapshot, a log line or
        --- a bug report can all carry them.
        ---
        --- @return A fresh four-element array each call, and a copy: writing to
        ---     it does not move the generator, and the generator moving does
        ---     not change it.
        state: function(self: Random): {integer}

        --- Puts four state words back, in place, so anything already holding
        --- this generator draws from what was put back.
        ---
        --- @param words Exactly four, in the order `state` gives them. Any
        ---     other length raises, as does all four being zero.
        setState: function(self: Random, words: {integer})
    end

    --- A noise field: Perlin gradient noise over a permutation of 0..255 that
    --- the seed decides.
    ---
    --- Stateless once built. Asking for the same coordinates twice gives the
    --- same answer, and nothing here advances anything, so a field is safe to
    --- share and needs nothing from a snapshot.
    record Noise
        --- Private. Perlin's permutation table: a shuffle of 0..255 followed by
        --- a second copy of itself, so 512 entries from index 1, and a lattice
        --- lookup that steps one past the end wraps without a mask.
        _perm: {integer}

        --- Noise at (x, y), in [-1, 1]. Exactly zero at integer coordinates,
        --- which is a property of gradient noise rather than a quirk here.
        noise2: function(self: Noise, x: number, y: number): number

        --- Noise at (x, y, z), in [-1, 1]. Zero at integer coordinates.
        noise3: function(self: Noise, x: number, y: number, z: number): number

        --- Fractional Brownian motion: `octaves` layers of `noise2`, each
        --- twice as fine and half as loud, normalised back into [-1, 1].
        ---
        --- @param octaves One or more. Zero or a negative count raises rather
        ---     than returning a flat field, since it has no meaning here.
        fbm2: function(self: Noise, x: number, y: number, octaves: integer): number

        --- The same, over `noise3`.
        ---
        --- @param octaves One or more, as for `fbm2`.
        fbm3: function(self: Noise, x: number, y: number, z: number, octaves: integer): number
    end

    --- A generator of its own, outside any world and outside any snapshot.
    --- What a tool, a benchmark or a test wants; a game usually wants `stream`.
    ---
    --- A seed is read as a 32-bit word, so 2^31 and -2^31 name the same one.
    ---
    --- @param seed Omitted takes a fixed constant, not a clock, so an unseeded
    ---     generator still repeats run to run.
    new: function(seed?: integer): Random

    --- A noise field from `seed`, read the same way `new` reads one.
    ---
    --- @param seed Omitted takes the same fixed constant `new` does, so two
    ---     unseeded fields are the same field.
    noise: function(seed?: integer): Noise

    --- The generator named `name` in `world`, made on the first ask and the
    --- same object on every ask after.
    ---
    --- Names are namespaced by dots the way snapshot data keys are; the engine
    --- uses `tecs.audio` and `tecs.runif`, so a game's own names should carry
    --- its own prefix.
    ---
    --- @param name Nil or empty raises. Names are compared byte for byte, so
    ---     two spellings of the same idea are two independent streams.
    --- @return The world's generator for this name, not a copy: two callers
    ---     asking for one name draw from the same sequence, in the order they
    ---     happen to ask.
    stream: function(world: types.World, name: string): Random

    --- Sets the world's seed and restarts every stream in it from that seed.
    ---
    --- Call it during setup. Calling it mid-run is well defined and rewinds
    --- everything, which is rarely what a caller means.
    ---
    --- @param seed Read as a 32-bit word, as `new` reads one. There is no way
    ---     to ask a world for its seed back; take it from a snapshot instead.
    seed: function(world: types.World, seed: integer)
end

local RandomMT <const>: metatable<random.Random> = {__index = random.Random}
local NoiseMT <const>: metatable<random.Noise> = {__index = random.Noise}

local type Random = random.Random
local type Noise = random.Noise

-------------------------------------------------------------------------------
-- 32-bit arithmetic
-------------------------------------------------------------------------------
--
-- Everything below stays inside the `bit` library, whose operations LuaJIT
-- defines as two's-complement 32-bit whatever the host word size is. That is
-- what makes a sequence the same on a 64-bit desktop and a 32-bit phone. The
-- one place a double is relied on is a product small enough to be exact in
-- one, which is stated at each site.

--- The low 32 bits of a 32-by-32 multiply.
---
--- `tobit(a * b)` is only right while the product fits a double exactly, which
--- a full 32-by-32 does not. Splitting the left operand into halves keeps both
--- partial products under 2^48, where a double is still exact, and the shift
--- and the sum truncate to 32 bits on their own.
local function mul32(a: integer, b: integer): integer
    local hi <const> = rshift(a, 16)
    local lo <const> = band(a, 0xffff)
    return tobit(lshift(hi * b, 16) + lo * b)
end

--- SplitMix32's finaliser: one word in, one avalanched word out.
local function mix32(z: integer): integer
    local r = mul32(bxor(z, rshift(z, 16)), 0x21F0AAAD)
    r = mul32(bxor(r, rshift(r, 15)), 0x735A2D97)
    return bxor(r, rshift(r, 15))
end

--- Expands one seed into four state words.
---
--- Four SplitMix32 draws rather than four copies of the seed, because
--- xoshiro's recovery from a low-entropy state is slow and a seed of 1 would
--- otherwise take thousands of draws to look random. The all-zero state is the
--- one xoshiro cannot leave, so it is replaced.
local function expand(seed: integer): integer, integer, integer, integer
    local z = tobit(seed)
    z = tobit(z + GOLDEN)
    local s0 <const> = mix32(z)
    z = tobit(z + GOLDEN)
    local s1 <const> = mix32(z)
    z = tobit(z + GOLDEN)
    local s2 <const> = mix32(z)
    z = tobit(z + GOLDEN)
    local s3 <const> = mix32(z)
    if s0 == 0 and s1 == 0 and s2 == 0 and s3 == 0 then
        return GOLDEN, 0, 0, 0
    end
    return s0, s1, s2, s3
end

-------------------------------------------------------------------------------
-- The generator
-------------------------------------------------------------------------------
--
-- xoshiro128**, by David Blackman and Sebastiano Vigna, whose reference is a
-- public-domain dedication. Written out here rather than called through the
-- FFI: its whole round is four xors, two shifts and two multiplies by small
-- constants, all of which LuaJIT compiles into the trace that asked for the
-- value, and a call across the FFI does not inline. Measured, a call is a
-- little over twice the cost of the round it would be making.
--
-- Chosen over PCG for the same reason. PCG32's step is a 64-bit multiply,
-- which LuaJIT can only do on boxed cdata, so every value allocates.

function random.Random:next(): number
    local s0, s1, s2, s3 = self._s0, self._s1, self._s2, self._s3
    -- s1 * 5 and (...) * 9 are exact in a double for any 32-bit input, so
    -- `tobit` is doing the truncation and nothing has been lost before it.
    local r <const> = tobit(rol(tobit(s1 * 5), 7) * 9)
    local t <const> = lshift(s1, 9)
    s2 = bxor(s2, s0)
    s3 = bxor(s3, s1)
    s1 = bxor(s1, s2)
    s0 = bxor(s0, s3)
    s2 = bxor(s2, t)
    s3 = rol(s3, 11)
    self._s0, self._s1, self._s2, self._s3 = s0, s1, s2, s3
    -- The unsigned conversion, without the branch a comparison would cost.
    -- `r * 2^-32` is exact and lands in [-0.5, 0.5); floor-mod adds exactly
    -- one to the negative half, which is the same number `r + 2^32` gives.
    return (r * INV32) % 1
end

function random.Random:integer(m: integer, n?: integer): integer
    local lo, hi = 1, m
    if n ~= nil then
        lo = m
        hi = n
    end
    if hi < lo then
        error("random: integer(" .. tostring(lo) .. ", " .. tostring(hi) .. ") has an empty range", 2)
    end
    return lo + floor(self:next() * (hi - lo + 1))
end

function random.Random:range(lo: number, hi: number): number
    return lo + self:next() * (hi - lo)
end

function random.Random:shuffle<T>(list: {T}): {T}
    for i = #list, 2, -1 do
        local j <const> = 1 + floor(self:next() * i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

function random.Random:reseed(seed: integer)
    self._s0, self._s1, self._s2, self._s3 = expand(seed)
end

function random.Random:state(): {integer}
    return {self._s0, self._s1, self._s2, self._s3}
end

function random.Random:setState(words: {integer})
    if words == nil or #words ~= 4 then
        error("random: setState needs four state words", 2)
    end
    local s0 <const> = tobit(words[1])
    local s1 <const> = tobit(words[2])
    local s2 <const> = tobit(words[3])
    local s3 <const> = tobit(words[4])
    if s0 == 0 and s1 == 0 and s2 == 0 and s3 == 0 then
        error("random: the all-zero state is the one xoshiro cannot leave", 2)
    end
    self._s0 = s0
    self._s1 = s1
    self._s2 = s2
    self._s3 = s3
end

function random.new(seed?: integer): Random
    local self <const> = setmetatable({} as Random, RandomMT)
    self._s0, self._s1, self._s2, self._s3 = expand(seed or DEFAULT_SEED)
    return self
end

-------------------------------------------------------------------------------
-- Noise
-------------------------------------------------------------------------------

local function fade(t: number): number
    return t * t * t * (t * (t * 6 - 15) + 10)
end

local function grad2(hash: integer, x: number, y: number): number
    local i <const> = band(hash, 7) + 1
    return GRAD2X[i] * x + GRAD2Y[i] * y
end

local function grad3(hash: integer, x: number, y: number, z: number): number
    local i <const> = band(hash, 15) + 1
    return GRAD3X[i] * x + GRAD3Y[i] * y + GRAD3Z[i] * z
end

function random.Noise:noise2(x: number, y: number): number
    local p <const> = self._perm
    local fx <const> = floor(x)
    local fy <const> = floor(y)
    local xi <const> = band(fx, 255)
    local yi <const> = band(fy, 255)
    local xf <const> = x - fx
    local yf <const> = y - fy
    local u <const> = fade(xf)
    local v <const> = fade(yf)

    local a <const> = p[xi + 1] + yi
    local b <const> = p[xi + 2] + yi
    local n00 <const> = grad2(p[a + 1], xf, yf)
    local n10 <const> = grad2(p[b + 1], xf - 1, yf)
    local n01 <const> = grad2(p[a + 2], xf, yf - 1)
    local n11 <const> = grad2(p[b + 2], xf - 1, yf - 1)

    local nx0 <const> = n00 + u * (n10 - n00)
    local nx1 <const> = n01 + u * (n11 - n01)
    return (nx0 + v * (nx1 - nx0)) * NORM2
end

function random.Noise:noise3(x: number, y: number, z: number): number
    local p <const> = self._perm
    local fx <const> = floor(x)
    local fy <const> = floor(y)
    local fz <const> = floor(z)
    local xi <const> = band(fx, 255)
    local yi <const> = band(fy, 255)
    local zi <const> = band(fz, 255)
    local xf <const> = x - fx
    local yf <const> = y - fy
    local zf <const> = z - fz
    local u <const> = fade(xf)
    local v <const> = fade(yf)
    local w <const> = fade(zf)

    local a <const> = p[xi + 1] + yi
    local b <const> = p[xi + 2] + yi
    local aa <const> = p[a + 1] + zi
    local ab <const> = p[a + 2] + zi
    local ba <const> = p[b + 1] + zi
    local bb <const> = p[b + 2] + zi

    local n000 <const> = grad3(p[aa + 1], xf, yf, zf)
    local n100 <const> = grad3(p[ba + 1], xf - 1, yf, zf)
    local n010 <const> = grad3(p[ab + 1], xf, yf - 1, zf)
    local n110 <const> = grad3(p[bb + 1], xf - 1, yf - 1, zf)
    local n001 <const> = grad3(p[aa + 2], xf, yf, zf - 1)
    local n101 <const> = grad3(p[ba + 2], xf - 1, yf, zf - 1)
    local n011 <const> = grad3(p[ab + 2], xf, yf - 1, zf - 1)
    local n111 <const> = grad3(p[bb + 2], xf - 1, yf - 1, zf - 1)

    local x00 <const> = n000 + u * (n100 - n000)
    local x10 <const> = n010 + u * (n110 - n010)
    local x01 <const> = n001 + u * (n101 - n001)
    local x11 <const> = n011 + u * (n111 - n011)
    local y0 <const> = x00 + v * (x10 - x00)
    local y1 <const> = x01 + v * (x11 - x01)
    return (y0 + w * (y1 - y0)) * NORM3
end

--- Rejects an octave count that would divide by zero or loop forever.
local function checkOctaves(octaves: integer)
    if octaves == nil or octaves < 1 then
        error("random: fbm needs at least one octave", 3)
    end
end

function random.Noise:fbm2(x: number, y: number, octaves: integer): number
    checkOctaves(octaves)
    local total, amplitude, frequency, norm = 0.0, 1.0, 1.0, 0.0
    for _ = 1, octaves do
        total = total + self:noise2(x * frequency, y * frequency) * amplitude
        norm = norm + amplitude
        frequency = frequency * LACUNARITY
        amplitude = amplitude * GAIN
    end
    return total / norm
end

function random.Noise:fbm3(x: number, y: number, z: number, octaves: integer): number
    checkOctaves(octaves)
    local total, amplitude, frequency, norm = 0.0, 1.0, 1.0, 0.0
    for _ = 1, octaves do
        total = total + self:noise3(x * frequency, y * frequency, z * frequency) * amplitude
        norm = norm + amplitude
        frequency = frequency * LACUNARITY
        amplitude = amplitude * GAIN
    end
    return total / norm
end

function random.noise(seed?: integer): Noise
    local self <const> = setmetatable({} as Noise, NoiseMT)
    local generator <const> = random.new(seed)
    local perm: {integer} = {}
    for i = 0, 255 do
        perm[i + 1] = i
    end
    generator:shuffle(perm)
    -- Doubled, so a lattice lookup that walks one past 255 reads the wrap
    -- instead of masking for it.
    for i = 1, 256 do
        perm[256 + i] = perm[i]
    end
    self._perm = perm
    return self
end

-------------------------------------------------------------------------------
-- Streams, and the snapshot that carries them
-------------------------------------------------------------------------------

local record Registry
    seed: integer
    streams: {string: Random}
end

--- The streams each world has. Weak, so a world that has gone takes its
--- streams with it.
local registries <const>: {types.World: Registry} = setmetatable({}, {
    __mode = "k"
} as metatable<{types.World: Registry}>)

--- Derives a stream's seed from the world's seed and the stream's name.
---
--- FNV-1a over the name's bytes, mixed with the world's seed. Hashed rather
--- than drawn in turn from a parent generator, which is the property that
--- keeps streams independent: the seed a name gets depends on the name and
--- nothing else, so adding a stream, or removing one, moves no other.
local function streamSeed(worldSeed: integer, name: string): integer
    local h = tobit(0x811C9DC5)
    for i = 1, #name do
        h = mul32(bxor(h, byte(name, i)), 0x01000193)
    end
    return mix32(bxor(h, mix32(tobit(worldSeed))))
end

--- Puts a saved registry back.
---
--- Every generator already handed out is updated in place rather than
--- replaced, because a caller that took its stream at startup holds the object
--- and would otherwise go on drawing from the sequence this run was on. A
--- stream the file does not name is restarted from the restored seed, which is
--- what it would have had if the save had been taken before it existed.
local function restore(registry: Registry, value: {string: any})
    local savedSeed <const> = value ~= nil and value.seed as integer or nil
    registry.seed = savedSeed ~= nil and tobit(savedSeed) or DEFAULT_SEED

    local saved <const> = (value ~= nil and value.streams or nil) as {string: {integer}}
    for name, generator in pairs(registry.streams) do
        local words <const> = saved ~= nil and saved[name] or nil
        if words ~= nil then
            generator:setState(words)
        else
            generator:reseed(streamSeed(registry.seed, name))
        end
    end

    -- A stream the file names that this run has not asked for yet is made
    -- here, so asking for it after the load continues the saved sequence
    -- rather than starting the run's own.
    if saved ~= nil then
        for name, words in pairs(saved) do
            if registry.streams[name] == nil then
                local generator <const> = random.new()
                generator:setState(words)
                registry.streams[name] = generator
            end
        end
    end
end

--- The world's registry, installing the snapshot handler on the first ask.
---
--- Lazy rather than a plugin, so nothing has to be added to a world for
--- `stream` to work. The consequence is that a world that loads a snapshot
--- before anything has asked for a stream drops the saved seed on the floor;
--- `random.seed` installs it too, which is what a game that cares calls during
--- setup anyway.
local function ensure(world: types.World): Registry
    local existing <const> = registries[world]
    if existing ~= nil then
        return existing
    end

    local registry <const>: Registry = {seed = DEFAULT_SEED, streams = {}}
    registries[world] = registry

    world:addSnapshotHandler({
        name = "tecs.random",
        save = function(_world: types.World): any
            local streams: {string: {integer}} = {}
            for name, generator in pairs(registry.streams) do
                streams[name] = generator:state()
            end
            return {seed = registry.seed, streams = streams}
        end,
        load = function(_world: types.World, value: any) restore(registry, value as {string: any}) end,
    })
    return registry
end

function random.stream(world: types.World, name: string): Random
    if name == nil or name == "" then
        error("random: a stream needs a non-empty name", 2)
    end
    local registry <const> = ensure(world)
    local existing <const> = registry.streams[name]
    if existing ~= nil then
        return existing
    end

    local generator <const> = random.new(streamSeed(registry.seed, name))
    registry.streams[name] = generator
    return generator
end

function random.seed(world: types.World, seed: integer)
    local registry <const> = ensure(world)
    registry.seed = tobit(seed)
    for name, generator in pairs(registry.streams) do
        generator:reseed(streamSeed(registry.seed, name))
    end
end

return random
