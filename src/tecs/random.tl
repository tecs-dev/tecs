--[=[
Seeded generation, in named streams a snapshot carries.

```teal
tecs.ecs.random.seed(world, 20260726)

local loot <const> = tecs.ecs.random.stream(world, "game.loot")
local spawns <const> = tecs.ecs.random.stream(world, "game.spawns")
local roll <const> = loot:integer(1, 20)
```

## Streams

The world seed and stream name determine each
[`Random`](tealdoc:tecs.random.Random) sequence. Drawing from `loot` never
advances `spawns`, so adding a stream leaves existing consumers unchanged.
Use namespaced, nonempty names and call `seed` during world setup. Calling it
later restarts every stream.

Use `newRandom` for tools, tests, and benchmarks that need a generator
outside a world. Do not share a generator between threads.

## Snapshots

The first `seed` or `stream` call installs the snapshot handler. Make that
call before loading a snapshot. A load updates existing generators in place,
so systems that captured a stream during setup retain the same object.

## Ranges

```teal
local unit <const> = loot:next()           -- [0, 1)
local d20 <const> = loot:integer(20)       -- [1, 20]
local offset <const> = loot:integer(-3, 3) -- [-3, 3]
local speed <const> = loot:range(2.0, 5.0) -- [2, 5)
```

`integer` includes both ends and rejects an empty range. `range` excludes its
upper end.

]=]

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

local record random
    --- Represents a generator through four 32-bit words of xoshiro128** state
    --- and the number of draws taken from it.
    ---
    --- Not thread-safe, and not meant to be: a generator shared across threads
    --- would produce an order that depends on which one got there first, which
    --- is the whole thing this module exists to avoid. Give each thread a
    --- stream of its own.
    record Random
        --- Engine-owned. Stores the first of four xoshiro128** state words as a
        --- 32-bit two's-complement integer, so it is often negative and it is
        --- not the unsigned value a C implementation would print. Ordinary
        --- game code should ignore this field.
        _s0: integer

        --- Engine-owned. Stores the second state word. Ordinary game code
        --- should ignore this field; use `state` and `setState`.
        _s1: integer

        --- Engine-owned. Stores the third state word. Ordinary game code
        --- should ignore this field; use `state` and `setState`.
        _s2: integer

        --- Engine-owned. Stores the fourth state word. The four words never
        --- all equal zero, which is the one state xoshiro cannot leave.
        --- Ordinary game code should ignore this field.
        _s3: integer

        --- Returns the next value and advances the generator by one round.
        ---
        --- @return A multiple of 2^-32 in [0, 1). Zero is a value it takes; one is not.
        next: function(self: Random): number

        --- Returns the next integer in [1, m], or in [m, n] when both are
        --- given. It includes both ends and advances the generator.
        ---
        --- Errors on an empty range, because a caller asking for a number
        --- between 5 and 3 has a bug and a silent 5 hides it.
        ---
        --- @param m The upper end when it is the only argument, and the lower end when `n`
        ---     follows it. The one-argument form counts from 1, so `integer(0)` is the
        ---     empty range [1, 0] and raises.
        --- @param n The upper end, included. Nil takes the one-argument form.
        --- @return An integer in the range from one draw whatever the range is.
        ---     The method scales and floors instead of resampling, so a width
        ---     that does not divide 2^32 has a bias of about one part in 2^32.
        integer: function(self: Random, m: integer, n?: integer): integer

        --- Returns the next value in [lo, hi) and advances the generator.
        ---
        --- @param lo The included end, whether or not it is the smaller of the two.
        --- @param hi The excluded end. A reversed pair is not an error and is not swapped
        ---     either: the draw is `lo + next() * (hi - lo)` and `next` never reaches one,
        ---     so `range(7, 3)` draws from (3, 7] rather than [3, 7).
        --- @return A value between the two ends, and `lo` exactly when the two are equal.
        range: function(self: Random, lo: number, hi: number): number

        --- Shuffles a table in place with Fisher-Yates and returns the same
        --- table. It advances the generator once per element past the first.
        ---
        --- @param self The generator advances once per element after the first.
        --- @param list The method reorders this list over `1..#list`. A list of
        ---     one or none stays unchanged and draws nothing, so its length
        ---     determines how far a shared generator advances.
        --- @return `list` itself rather than a copy, so the caller's own reference is
        ---     already shuffled and the return is a convenience.
        shuffle: function<T>(self: Random, list: {T}): {T}

        --- Restarts the sequence from `seed` in place. The generator retains
        --- its identity, so existing holders draw from the restart.
        ---
        --- @param seed Read as a 32-bit word, as `newRandom` reads one, so 2^31 and -2^31 restart
        ---     the same sequence. Zero is a seed like any other; the generator
        ---     expands it instead of rejecting it.
        reseed: function(self: Random, seed: integer)

        --- Returns the four state words as plain integers that a snapshot,
        --- log line, or bug report can carry.
        ---
        --- @return A fresh four-element array each call, and a copy: writing to
        ---     it does not move the generator, and the generator moving does
        ---     not change it.
        state: function(self: Random): {integer}

        --- Puts four state words back, in place, so anything already holding
        --- this generator draws from what was put back.
        ---
        --- @param words Exactly four, in the order `state` gives them, and each read as a
        ---     32-bit word, so a `state` result round-trips unchanged. Any other length
        ---     raises, as does nil, as does all four being zero.
        setState: function(self: Random, words: {integer})
    end

    --- Creates a generator outside every world and snapshot. Tools,
    --- benchmarks, and tests use this; games usually use `stream`.
    ---
    --- A seed is read as a 32-bit word, so 2^31 and -2^31 name the same one.
    ---
    --- @param seed Omitted takes a fixed constant, not a clock, so an unseeded
    ---     generator still repeats run to run.
    --- @return A generator nothing else holds and nothing else knows about: two calls on one
    ---     seed give two objects that draw the same sequence, each at its own pace.
    newRandom: function(seed?: integer): Random

    --- Returns the generator named `name` in `world`, creating it on the first
    --- call and returning the same object afterwards.
    ---
    --- Names use dot namespaces like snapshot data keys. The engine uses
    --- `tecs.audio` and `tecs.runif`, so game names should carry their own
    --- prefix.
    ---
    --- @param world The first ask installs a snapshot handler named `tecs.random` on it. A
    ---     world that loads a snapshot before anything has asked for a stream has no
    ---     handler yet and drops the saved seed, which `random.seed` during setup avoids.
    --- @param name Nil or empty raises. The module compares names byte for
    ---     byte, so two spellings of the same idea create independent streams.
    --- @return The world's generator for this name, not a copy: two callers
    ---     asking for one name draw from the same sequence, in the order they
    ---     happen to ask.
    stream: function(world: types.World, name: string): Random

    --- Sets the world's seed and restarts every stream in it from that seed.
    ---
    --- Call it during setup. Calling it mid-run is well defined and rewinds
    --- everything, which is rarely what a caller means.
    ---
    --- @param world The call reseeds each existing stream in place, so a holder
    ---     keeps the object. It also installs the snapshot handler, which is why
    ---     games that load snapshots call it during setup.
    --- @param seed Read as a 32-bit word, as `newRandom` reads one. There is no way
    ---     to ask a world for its seed back; take it from a snapshot instead.
    seed: function(world: types.World, seed: integer)
end

local RandomMT <const>: metatable<random.Random> = {__index = random.Random}

local type Random = random.Random

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

--- SplitMix32's finalizer: one word in, one avalanched word out.
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

function random.newRandom(seed?: integer): Random
    local self <const> = setmetatable({} as Random, RandomMT)
    self._s0, self._s1, self._s2, self._s3 = expand(seed or DEFAULT_SEED)
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
local registries <const>: {types.World: Registry} = setmetatable(
    {}, {__mode = "k"} as metatable<{types.World: Registry}>
)

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
                local generator <const> = random.newRandom()
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
        -- This persisted handler key is an externally typed string. It remains
        -- `tecs.random` across module layout changes because a missing value
        -- makes restore reseed silently from the world seed.
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

    local generator <const> = random.newRandom(streamSeed(registry.seed, name))
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
