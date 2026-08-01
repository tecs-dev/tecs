--- Steady-state operations on the ECS bitset.
---
--- This is the focused complement to the ECS and frame benchmarks: it keeps
--- the primitive that archetype signatures and query filters use honest on
--- its own. Construction belongs in the mutation rows; scan and relation rows
--- build their inputs before the measured window.
---
---   BENCH_BITSET_BITS       Addressable bits. Defaults to 65536.
---   BENCH_BITSET_SET_COUNT  Bits set in each fixture. Defaults to 4096.
---   BENCH_BITSET_WARMUP     Untimed repetitions. Defaults to 20.
---   BENCH_BITSET_SAMPLES    Timed repetitions. Defaults to 61.

local getenv <const> = os.getenv
local format <const> = string.format
local sort <const> = table.sort
local ceil <const> = math.ceil
local floor <const> = math.floor
local max <const> = math.max

local root = getenv("TECS_LUA") or (_G as {string: any})["__tecsContent"] as string or "out/macos-arm64-dev/lua"
if root:sub(-1) == "/" then
    root = root:sub(1, -2)
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local type Bitset = require("tecs.utils.Bitset")
local BitsetModule <const> = require("tecs.utils.Bitset")
local now <const> = require("tecs.platform.time").now

local function positiveInteger(name: string, default: integer): integer
    local text <const> = getenv(name)
    if text == nil then
        return default
    end
    local value <const> = tonumber(text)
    if value == nil or value ~= floor(value) or value < 1 then
        error(format("bench: %s must be a positive integer", name), 0)
    end
    return floor(value)
end

local BITS <const> = positiveInteger("BENCH_BITSET_BITS", 65536)
local SET_COUNT <const> = positiveInteger("BENCH_BITSET_SET_COUNT", 4096)
local WARMUP <const> = positiveInteger("BENCH_BITSET_WARMUP", 20)
local SAMPLES <const> = positiveInteger("BENCH_BITSET_SAMPLES", 61)
if SET_COUNT > BITS then
    error("bench: BENCH_BITSET_SET_COUNT cannot exceed BENCH_BITSET_BITS", 0)
end

local record Range
    lo: integer
    hi: integer
end

--- Builds a repeatable non-contiguous set without allocating during a timed
--- row. The step is coprime with each default capacity, so it visits no index
--- twice before the fixture is full.
local function indices(salt: integer): {integer}
    local values: {integer} = {}
    local step <const> = BITS - 1
    local value = (17 + salt * 131) % BITS
    for _ = 1, SET_COUNT do
        values[#values + 1] = value
        value = (value + step) % BITS
    end
    sort(values)
    return values
end

local function ranges(): {Range}
    local output: {Range} = {}
    local left = SET_COUNT
    local lo = 0
    while left > 0 do
        local width <const> = math.min(left, 31)
        output[#output + 1] = {lo = lo, hi = lo + width - 1}
        left = left - width
        local availableGap <const> = BITS - (lo + width) - left
        lo = lo + width + math.min(17, math.max(0, availableGap))
    end
    return output
end

local PRIMARY <const> = indices(1)
local DISJOINT <const> = indices(2)
local RANGES <const> = ranges()

local function populated(values: {integer}): Bitset
    local set <const> = BitsetModule.new(BITS)
    for _, index in ipairs(values) do
        set:set(index)
    end
    return set
end

local function percentile(samples: {number}, fraction: number): number
    return samples[max(1, ceil(#samples * fraction))]
end

local function measure(name: string, operations: integer, run: function(): integer)
    for _ = 1, WARMUP do
        run()
    end
    local samples: {number} = {}
    for sample = 1, SAMPLES do
        local started <const> = now()
        run()
        samples[sample] = now() - started
    end
    sort(samples)
    local p50 <const> = percentile(samples, 0.50)
    local p95 <const> = percentile(samples, 0.95)
    print(
        format(
            "bitset %-13s %d bits, %d set  p50 %.3f ms  p95 %.3f ms  %.1f ns/op",
            name,
            BITS,
            SET_COUNT,
            p50 * 1000.0,
            p95 * 1000.0,
            p50 * 1000000000.0 / operations
        )
    )
end

measure("set", SET_COUNT, function(): integer
    local set <const> = BitsetModule.new(BITS)
    for _, index in ipairs(PRIMARY) do
        set:set(index)
    end
    if set.count ~= SET_COUNT then
        error("bench: set lost bits", 0)
    end
    return set.count
end)

measure("setRange", SET_COUNT, function(): integer
    local set <const> = BitsetModule.new(BITS)
    for _, range in ipairs(RANGES) do
        set:setRange(range.lo, range.hi)
    end
    if set.count ~= SET_COUNT then
        error("bench: setRange lost bits", 0)
    end
    return set.count
end)

measure("clear", SET_COUNT, function(): integer
    local set <const> = populated(PRIMARY)
    for _, index in ipairs(PRIMARY) do
        set:clear(index)
    end
    if set.count ~= 0 then
        error("bench: clear left bits", 0)
    end
    return set.count
end)

local scanSet <const> = populated(PRIMARY)
measure("scan", SET_COUNT, function(): integer
    local count = 0
    local index = scanSet:beginScan(0)
    while index do
        count = count + 1
        index = scanSet:nextScan()
    end
    if count ~= SET_COUNT then
        error("bench: scan skipped bits", 0)
    end
    return count
end)

local subset: {integer} = {}
for index = 1, #PRIMARY, 2 do
    subset[#subset + 1] = PRIMARY[index]
end
local containsLeft <const> = populated(PRIMARY)
local containsRight <const> = populated(subset)
measure("containsAll", #subset, function(): integer
    if not containsLeft:containsAll(containsRight) then
        error("bench: containsAll rejected a subset", 0)
    end
    return 1
end)

local overlapLeft <const> = populated(PRIMARY)
local overlapRight <const> = populated(DISJOINT)
for index = 1, #PRIMARY, 4 do
    overlapRight:set(PRIMARY[index])
end
measure("overlaps", SET_COUNT, function(): integer
    if not overlapLeft:overlaps(overlapRight) then
        error("bench: overlaps missed shared bits", 0)
    end
    return 1
end)
