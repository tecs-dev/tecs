---
url: /ecs/random.md
description: >-
  Seeded generation in named, independent streams a snapshot carries, plus
  standalone generators and Perlin noise
---

# tecs.ecs.random

`tecs.ecs.random` is seeded generation, in named streams a snapshot carries. Nothing here reads a clock. A
generator produces the same sequence from the same seed on every machine this runs on, which is what lets a
replay, a snapshot and a bug report all describe the same run. `math.random` cannot: its state is a
process-wide global with no way to read it back, so anything built on it is reproducible only by accident.

Streams are named, and independent. A stream's own seed is hashed from the world's seed and the stream's name,
so a name that did not exist before gets a seed of its own without moving any other name's. That is the
property a replay needs: adding a system, or having one draw a different number of values this run, changes
nothing about what any other system sees. Splitting one generator between consumers has the opposite property,
where the order consumers happen to run in decides what each of them gets.

```teal
local rng <const> = tecs.ecs.random.stream(world, "loot")
local roll <const> = rng:integer(1, 20)

local field <const> = tecs.ecs.random.noise(1234)
local height <const> = field:fbm2(x * 0.01, y * 0.01, 4)
```

## Streams

A stream belongs to a world. The first ask makes it; every ask after returns the same object, so a system that
took its stream at startup goes on holding the right one across a snapshot load.

### stream

The generator named `name` in `world`.

```teal
function random.stream(world: ecs.World, name: string): Random
```

**Parameters:**

* `world`: the world the stream belongs to. Its streams go away with it.
* `name`: a non-empty name. Names are namespaced by dots the way snapshot data keys are; the engine uses
  `tecs.audio` and `tecs.ecs.runif`, so a game's own names should carry its own prefix.

**Returns:** the `Random` for that name, seeded by hashing the name against the world's seed.

Raises on a name that is `nil` or empty.

**Example:**

```teal
local world <const> = tecs.ecs.newWorld()
tecs.ecs.random.seed(world, 20260726)

local loot <const> = tecs.ecs.random.stream(world, "game.loot")
local spawns <const> = tecs.ecs.random.stream(world, "game.spawns")
```

Drawing from `loot` moves nothing in `spawns`, and adding a third stream later moves neither.

### seed

Sets the world's seed and restarts every stream in it from that seed.

```teal
function random.seed(world: ecs.World, seed: integer)
```

**Parameters:**

* `world`: the world.
* `seed`: read as a 32-bit word.

Call it during setup. Calling it mid-run is well defined and rewinds everything, which is rarely what a caller
means.

::: tip Seed during setup, before a load
The snapshot handler is installed on the first ask for a stream, so nothing has to be added to a world for
`stream` to work. The consequence is that a world that loads a snapshot before anything has asked for a stream
drops the saved seed on the floor. `random.seed` installs the handler too, which is what a game that cares
calls during setup anyway.
:::

## Snapshots

The state is four integers. Saving a world writes every stream's four words, and the world's seed, under the
`tecs.ecs.random` key; loading puts them back. See [save games](/ecs/save-games) for the snapshot API itself.

A load updates each generator in place rather than replacing it, so a caller that took its stream at startup
keeps drawing from the restored sequence rather than the one this run was on. A stream the file does not name
is restarted from the restored seed, which is what it would have had if the save had been taken before it
existed. A stream the file names that this run has not asked for yet is made during the load, so asking for it
afterwards continues the saved sequence.

Noise is not in the snapshot, because it has no state. A noise field is a pure function of its seed and its
coordinates, so a game rebuilds the same field by asking for the same seed and there is nothing for a save to
carry.

## Random

A generator: four 32-bit words of xoshiro128\*\* state, and the draws taken off it. The arithmetic stays
inside LuaJIT's `bit` library, which is two's-complement 32-bit whatever the host word size is, so a sequence
is the same on a 64-bit desktop and a 32-bit phone.

::: warning Not thread-safe, and not meant to be
A generator shared across threads would produce an order that depends on which one got there first, which is
the whole thing this module exists to avoid. Give each thread a stream of its own.
:::

### new

A generator of its own, outside any world and outside any snapshot. What a tool, a benchmark or a test wants;
a game usually wants `stream`.

```teal
function random.new(seed?: integer): Random
```

**Parameters:**

* `seed`: read as a 32-bit word, so 2^31 and -2^31 name the same one. Omitted takes a fixed default seed
  rather than something read off a clock: a run that did not ask for a seed is still reproducible, and a game
  that wants a different one each launch is stating so where anyone reading it can see.

**Returns:** a `Random`.

### Random:next

The next value, in \[0, 1). Advances the generator.

```teal
function Random:next(): number
```

### Random:integer

The next integer in \[1, m], or in \[m, n] when both are given. Both ends are included. Advances the generator.

```teal
function Random:integer(m: integer, n?: integer): integer
```

Raises on an empty range, because a caller asking for a number between 5 and 3 has a bug and a silent 5 hides
it.

**Example:**

```teal
local d20 <const> = rng:integer(20)        -- 1 to 20
local offset <const> = rng:integer(-3, 3)  -- -3 to 3
```

### Random:range

The next value in \[lo, hi). Advances the generator.

```teal
function Random:range(lo: number, hi: number): number
```

A reversed pair is not an error here; it draws from \[hi, lo).

### Random:shuffle

Fisher-Yates, in place, returning the same table.

```teal
function Random:shuffle<T>(list: {T}): {T}
```

Advances the generator once per element past the first.

### Random:reseed

Restarts the sequence from `seed`, in place.

```teal
function Random:reseed(seed: integer)
```

### Random:state

The four state words.

```teal
function Random:state(): {integer}
```

**Returns:** four plain integers, so a snapshot, a log line or a bug report can all carry them.

### Random:setState

Puts four state words back, in place, so anything already holding this generator draws from what was put back.

```teal
function Random:setState(words: {integer})
```

Raises on anything other than four words, and on the all-zero state, which is the one xoshiro cannot leave.

## Noise

A noise field: Perlin gradient noise over a permutation of 0..255 that the seed decides. Stateless once built.
Asking for the same coordinates twice gives the same answer, and nothing here advances anything, so a field is
safe to share and needs nothing from a snapshot.

### noise

A noise field from `seed`, read the same way `new` reads one.

```teal
function random.noise(seed?: integer): Noise
```

### Noise:noise2

Noise at (x, y), in \[-1, 1].

```teal
function Noise:noise2(x: number, y: number): number
```

Exactly zero at integer coordinates, which is a property of gradient noise rather than a quirk here. Scale the
coordinates down to get features larger than one unit.

### Noise:noise3

Noise at (x, y, z), in \[-1, 1]. Zero at integer coordinates.

```teal
function Noise:noise3(x: number, y: number, z: number): number
```

### Noise:fbm2

Fractional Brownian motion: `octaves` layers of `noise2`, each twice as fine and half as loud, normalised back
into \[-1, 1].

```teal
function Noise:fbm2(x: number, y: number, octaves: integer): number
```

Raises on fewer than one octave.

**Example:**

```teal
local field <const> = tecs.ecs.random.noise(seed)
for y = 0, height - 1 do
    for x = 0, width - 1 do
        local h <const> = field:fbm2(x * 0.02, y * 0.02, 5)
        tiles[y * width + x] = h > 0.1 and "rock" or "grass"
    end
end
```

### Noise:fbm3

The same, over `noise3`.

```teal
function Noise:fbm3(x: number, y: number, z: number, octaves: integer): number
```
