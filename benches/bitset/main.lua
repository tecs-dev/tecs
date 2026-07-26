#!/usr/bin/env luajit
-- Bitset benchmark suite
-- Usage: `make bitset-bench` or `luajit main.lua`
--
-- The suite is split by operation family so future Bitset implementations can
-- be dropped into the `implementations` table and compared on the same
-- workloads:
--   * mutation: set / setRange / clear-heavy churn on fresh instances
--   * scan:     nextSetBit on scatter and zero-gap layouts
--   * relation: containsAll / overlaps over positive and negative pairs
--
-- Targeted runs:
--   make bitset-bench CASE=3
--   make bitset-bench VARIANTS=current
--   make bitset-bench PARAMS='bits=65536,setCount=1024'

local home = os.getenv("HOME") or ""

package.path = package.path
        .. ";../../out/macos-arm64-dev/lua/?.lua;../../out/macos-arm64-dev/lua/?/init.lua;"
        .. "../?.lua;../?/init.lua;"
        .. home .. "/.luarocks/share/lua/5.1/?.lua;"
        .. home .. "/.luarocks/share/lua/5.1/?/init.lua"
package.cpath = package.cpath .. ";" .. home .. "/.luarocks/lib/lua/5.1/?.so"

assert(jit, "LuaJIT is required to run this benchmark")
local _isBenchChild = os.getenv("BENCH_CHILD") == "1"
if not _isBenchChild then
    print("LuaJIT version:", jit.version)
end

local bench = require("lib.bench")

local sink = 0
local benchParamsEnv = os.getenv("PARAMS") or os.getenv("BENCH_PARAMS") or ""

local implementations = {
    {name = "current", module = "tecs.utils.Bitset"},
}

local function loadBitset(moduleName)
    package.loaded[moduleName] = nil
    return require(moduleName)
end

local function cloneArray(src)
    local dst = {}
    for i = 1, #src do
        dst[i] = src[i]
    end
    return dst
end

local function fixtureKey(bits, setCount, layout)
    return tostring(bits) .. ":" .. tostring(setCount) .. ":" .. tostring(layout or "scatter")
end

local fixtureCache = {}
local relationCache = {}

local function buildIndices(bits, setCount, salt)
    local out = {}
    local step = 8191 + salt * 2
    local offset = 17 + salt * 131
    local used = {}

    local value = offset % bits
    while #out < setCount do
        if not used[value] then
            used[value] = true
            out[#out + 1] = value
        end
        value = (value + step) % bits
    end

    table.sort(out)
    return out
end

local function buildRanges(bits, setCount)
    local ranges = {}
    local remaining = setCount
    local lo = 0
    local span = 31
    local gap = 17

    while remaining > 0 and lo < bits do
        local width = remaining < span and remaining or span
        local hi = lo + width - 1
        if hi >= bits then
            hi = bits - 1
            width = hi - lo + 1
        end
        ranges[#ranges + 1] = {lo = lo, hi = hi}
        remaining = remaining - width
        lo = hi + 1 + gap
        span = span == 31 and 19 or 31
        gap = gap == 17 and 43 or 17
    end

    return ranges
end

local function buildZeroGapIndices(bits, setCount)
    local out = {}
    local wordCount = math.max(1, math.floor(bits / 32))
    local gap = math.max(1, math.floor(wordCount / math.max(1, setCount)))
    local word = 0
    for _ = 1, setCount do
        out[#out + 1] = math.min(bits - 1, word * 32)
        word = math.min(wordCount - 1, word + gap)
    end
    return out
end

local function getFixture(bits, setCount, layout)
    local key = fixtureKey(bits, setCount, layout)
    local fixture = fixtureCache[key]
    if fixture then
        return fixture
    end

    local indices
    if layout == "zero_gaps" then
        indices = buildZeroGapIndices(bits, setCount)
    else
        indices = buildIndices(bits, setCount, 1)
    end

    fixture = {
        bits = bits,
        setCount = setCount,
        layout = layout or "scatter",
        sparseIndices = indices,
        disjointIndices = buildIndices(bits, setCount, 11),
        ranges = buildRanges(bits, setCount),
    }

    fixtureCache[key] = fixture
    return fixture
end

local function buildPopulatedBitset(Bitset, indices, bits)
    local bs = Bitset.new(bits)
    for i = 1, #indices do
        bs:set(indices[i])
    end
    return bs
end

local function getRelationPair(Bitset, bits, setCount, mode)
    local key = table.concat({tostring(Bitset), bits, setCount, mode}, ":")
    local pair = relationCache[key]
    if pair then
        return pair
    end

    local fixture = getFixture(bits, setCount)
    if mode == "contains_yes" then
        local left = buildPopulatedBitset(Bitset, fixture.sparseIndices, bits)
        local subset = {}
        for i = 1, #fixture.sparseIndices, 2 do
            subset[#subset + 1] = fixture.sparseIndices[i]
        end
        pair = {a = left, b = buildPopulatedBitset(Bitset, subset, bits)}
    elseif mode == "contains_no" then
        pair = {
            a = buildPopulatedBitset(Bitset, fixture.sparseIndices, bits),
            b = buildPopulatedBitset(Bitset, fixture.disjointIndices, bits),
        }
    elseif mode == "overlap_yes" then
        local overlap = {}
        local shared = fixture.sparseIndices
        local other = cloneArray(fixture.disjointIndices)
        for i = 1, #shared, 4 do
            overlap[#overlap + 1] = shared[i]
        end
        for i = 1, #overlap do
            other[i] = overlap[i]
        end
        table.sort(other)
        pair = {
            a = buildPopulatedBitset(Bitset, shared, bits),
            b = buildPopulatedBitset(Bitset, other, bits),
        }
    elseif mode == "overlap_no" then
        pair = {
            a = buildPopulatedBitset(Bitset, fixture.sparseIndices, bits),
            b = buildPopulatedBitset(Bitset, fixture.disjointIndices, bits),
        }
    else
        error("unknown relation mode: " .. tostring(mode))
    end

    relationCache[key] = pair
    return pair
end

local function makeVariants(configure)
    local variants = {}
    for i = 1, #implementations do
        local impl = implementations[i]
        local Bitset = loadBitset(impl.module)
        variants[#variants + 1] = configure(impl, Bitset)
    end
    return variants
end

local function requestedParam(name)
    if benchParamsEnv == "" then
        return nil
    end

    for pair in benchParamsEnv:gmatch("[^,]+") do
        local k, v = pair:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k == name then
            return v
        end
    end

    return nil
end

local requestedOp = requestedParam("op")
local function shouldRunSuite(validOps)
    if not requestedOp then
        return true
    end
    for i = 1, #validOps do
        if validOps[i] == requestedOp then
            return true
        end
    end
    return false
end

if shouldRunSuite({"set_sparse", "setRange_runs", "clear_sparse"}) then
    bench.suite({
        name = "Bitset Mutation",
        warmupIterations = 40,
        minDuration = 1.5,
        variants = makeVariants(function(impl, Bitset)
            return {
                name = impl.name,
                run = function(_, case)
                    local fixture = getFixture(case.params.bits, case.params.setCount, case.params.layout)
                    if case.params.op == "set_sparse" then
                        local bs = Bitset.new(case.params.bits)
                        for i = 1, #fixture.sparseIndices do
                            bs:set(fixture.sparseIndices[i])
                        end
                        sink = sink + bs.count
                    elseif case.params.op == "setRange_runs" then
                        local bs = Bitset.new(case.params.bits)
                        for i = 1, #fixture.ranges do
                            local range = fixture.ranges[i]
                            bs:setRange(range.lo, range.hi)
                        end
                        sink = sink + bs.usedWordCount
                    elseif case.params.op == "clear_sparse" then
                        local bs = buildPopulatedBitset(Bitset, fixture.sparseIndices, case.params.bits)
                        for i = 1, #fixture.sparseIndices do
                            bs:clear(fixture.sparseIndices[i])
                        end
                        sink = sink + bs.count
                    else
                        error("unknown mutation op: " .. tostring(case.params.op))
                    end
                end,
            }
        end),
        cases = {
            {
                name = "mutation",
                parameters = {
                    op = {"set_sparse", "setRange_runs", "clear_sparse"},
                    bits = {4096, 65536},
                    setCount = {256, 4096},
                },
            },
        },
    })
end

if shouldRunSuite({"nextSetBit"}) then
    bench.suite({
        name = "Bitset Scan",
        warmupIterations = 60,
        minDuration = 1.5,
        variants = makeVariants(function(impl, Bitset)
            local cache = {}
            return {
                name = impl.name,
                setup = function(case)
                    local key = fixtureKey(case.params.bits, case.params.setCount, case.params.layout)
                    local bs = cache[key]
                    if not bs then
                        local fixture = getFixture(case.params.bits, case.params.setCount, case.params.layout)
                        bs = buildPopulatedBitset(Bitset, fixture.sparseIndices, case.params.bits)
                        cache[key] = bs
                    end
                    return bs
                end,
                run = function(bs, case)
                    if case.params.op == "nextSetBit" then
                        local sum = 0
                        local idx = bs:nextSetBit(0)
                        while idx do
                            sum = sum + idx
                            idx = bs:nextSetBit(idx + 1)
                        end
                        sink = sink + sum
                    else
                        error("unknown scan op: " .. tostring(case.params.op))
                    end
                end,
            }
        end),
        cases = {
            {
                name = "scan small/medium",
                parameters = {
                    op = {"nextSetBit"},
                    layout = {"scatter"},
                    bits = {4096, 65536},
                    setCount = {64, 1024},
                },
            },
            {
                name = "scan large",
                parameters = {
                    op = {"nextSetBit"},
                    layout = {"scatter"},
                    bits = {65536, 1048576},
                    setCount = {16384},
                },
            },
            {
                name = "scan nextSetBit zero gaps",
                parameters = {
                    op = {"nextSetBit"},
                    layout = {"zero_gaps"},
                    bits = {65536, 1048576},
                    setCount = {64, 1024},
                },
            },
        },
    })
end

if shouldRunSuite({"contains_yes", "contains_no", "overlap_yes", "overlap_no"}) then
    bench.suite({
        name = "Bitset Relations",
        warmupIterations = 80,
        minDuration = 1.5,
        microIterations = 4,
        variants = makeVariants(function(impl, Bitset)
            local cache = {}
            return {
                name = impl.name,
                setup = function(case)
                    local key = fixtureKey(case.params.bits, case.params.setCount) .. ":" .. case.params.op
                    local pair = cache[key]
                    if not pair then
                        pair = getRelationPair(Bitset, case.params.bits, case.params.setCount, case.params.op)
                        cache[key] = pair
                    end
                    return pair
                end,
                run = function(pair, case)
                    if case.params.op == "contains_yes" or case.params.op == "contains_no" then
                        sink = sink + (pair.a:containsAll(pair.b) and 1 or 0)
                    elseif case.params.op == "overlap_yes" or case.params.op == "overlap_no" then
                        sink = sink + (pair.a:overlaps(pair.b) and 1 or 0)
                    else
                        error("unknown relation op: " .. tostring(case.params.op))
                    end
                end,
            }
        end),
        cases = {
            {
                name = "relations",
                parameters = {
                    op = {"contains_yes", "contains_no", "overlap_yes", "overlap_no"},
                    bits = {4096, 65536},
                    setCount = {256, 4096},
                },
            },
        },
    })
end

if sink == 0x7fffffff then
    print("sink:", sink)
end
