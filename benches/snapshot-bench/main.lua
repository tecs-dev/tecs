#!/usr/bin/env luajit
-- Snapshot Save/Load Benchmark (LuaJIT string.buffer format)
--
-- Usage: `make snapshot-bench` or `luajit main.lua`
--
-- Measures throughput of `saveSnapshot` + `loadSnapshot` against the binary
-- buffer format. FFI components only -- no GPU, no Love2D. Case parameter
-- `count` ∈ {1K, 10K, 100K} sweeps entity counts; the bench harness expands
-- each base case into one runtime case per value.
--
-- Targeted runs:
--   make snapshot-bench CASE=2
--   make snapshot-bench PARAMS='count=10000'

local home = os.getenv("HOME") or ""

package.path = package.path
        .. ";../../build/?.lua;../../build/?/init.lua;../../build/tecs/?.lua;"
        .. "../../build/tecs/?/init.lua;"
        .. "../?.lua;../?/init.lua;"
        .. home .. "/.luarocks/share/lua/5.1/?.lua;"
        .. home .. "/.luarocks/share/lua/5.1/?/init.lua"
package.cpath = package.cpath .. ";" .. home .. "/.luarocks/lib/lua/5.1/?.so"

assert(jit, "LuaJIT is required to run this benchmark")
print("LuaJIT version:", jit.version)

-- Stub love2d timer so tecs can initialize without Love2D loaded
love = love or {timer = {getTime = os.clock}}

local bench = require("lib.bench")
local tecs = require("tecs")
local buffer = require("string.buffer")


-------------------------------------------------------------------------------
-- FFI-only component set
-------------------------------------------------------------------------------

local Position = tecs.newFFIComponent({
    name = "SnapPosition",
    container = {},
    fields = {
        {"x", "double"},
        {"y", "double"},
    },
})

local Velocity = tecs.newFFIComponent({
    name = "SnapVelocity",
    container = {},
    fields = {
        {"vx", "double"},
        {"vy", "double"},
    },
})

local Health = tecs.newFFIComponent({
    name = "SnapHealth",
    container = {},
    fields = {
        {"hp", "int32_t"},
        {"maxHp", "int32_t"},
    },
})

-------------------------------------------------------------------------------
-- World builder
-------------------------------------------------------------------------------
--
-- Spreads entities across three archetype shapes so the snapshot hits
-- multiple archetype boundaries (stresses per-archetype prelude/footer
-- work, not just the per-entity fast path).

local function buildWorld(count)
    local world = tecs.newWorld()
    -- Three groups, sizes ~1/3 each. Using explicit floor to avoid off-by-one
    -- at small counts (e.g. 1K → 334 + 333 + 333 = 1000).
    local third = math.floor(count / 3)
    local rest = count - 2 * third

    world:batchSpawn(third, {Position, Velocity, Health},
        function(arch, startRow, n)
            local positions = arch[Position]
            local velocities = arch[Velocity]
            local healths = arch[Health]
            for i = startRow, startRow + n - 1 do
                positions[i].x = i * 1.5
                positions[i].y = i * 2.5
                velocities[i].vx = i * 0.1
                velocities[i].vy = i * 0.2
                healths[i].hp = 100
                healths[i].maxHp = 100
            end
        end)

    world:batchSpawn(third, {Position, Velocity},
        function(arch, startRow, n)
            local positions = arch[Position]
            local velocities = arch[Velocity]
            for i = startRow, startRow + n - 1 do
                positions[i].x = i * 3.5
                positions[i].y = i * 4.5
                velocities[i].vx = i * 0.3
                velocities[i].vy = i * 0.4
            end
        end)

    world:batchSpawn(rest, {Position},
        function(arch, startRow, n)
            local positions = arch[Position]
            for i = startRow, startRow + n - 1 do
                positions[i].x = i * 5.5
                positions[i].y = i * 6.5
            end
        end)

    world:commit()
    return world
end

-------------------------------------------------------------------------------
-- Per-count lazy caches -- fork-per-pair isolation means each (case, variant)
-- runs in its own LuaJIT process. The cache lookup ensures world construction
-- happens exactly once per child, and only for the count the child is asked
-- to measure.
-------------------------------------------------------------------------------

local saveCache = {}
local function getSaveResources(count)
    local r = saveCache[count]
    if not r then
        r = {world = buildWorld(count), buf = buffer.new()}
        saveCache[count] = r
    end
    return r
end

local loadCache = {}
local function getLoadResources(count)
    local r = loadCache[count]
    if not r then
        local srcWorld = buildWorld(count)
        local srcBuf = tecs.saveSnapshot(srcWorld)
        -- loadSnapshot despawns existing entities before refilling, so the
        -- same world ping-pongs full → empty → full across iterations. This
        -- matches the realistic "save game" pattern.
        r = {bytes = srcBuf:tostring(), world = tecs.newWorld()}
        loadCache[count] = r
    end
    return r
end

-------------------------------------------------------------------------------
-- Save suite: time saveSnapshot against a reused world. The buffer is reset
-- (length zeroed; underlying allocation retained) each iteration so we measure
-- a cold serialize without re-paying buffer growth.
-------------------------------------------------------------------------------

bench.suite({
    name = "Snapshot Save (LuaJIT buffer, FFI components)",
    warmupIterations = 30,
    minDuration = 2.0,
    variants = {
        {
            name = "tecs.saveSnapshot",
            setup = function(case) return getSaveResources(case.params.count) end,
            run = function(state)
                tecs.saveSnapshot(state.world, {buffer = state.buf})
            end,
        },
    },
    cases = {
        {name = "snapshot save", parameters = {count = {1000, 10000, 100000}}},
    },
})

-------------------------------------------------------------------------------
-- Load suite: time loadSnapshot from pre-serialised bytes.
-------------------------------------------------------------------------------

bench.suite({
    name = "Snapshot Load (LuaJIT buffer, FFI components)",
    warmupIterations = 30,
    minDuration = 2.0,
    variants = {
        {
            name = "tecs.loadSnapshot",
            setup = function(case) return getLoadResources(case.params.count) end,
            run = function(state)
                -- Pass bytes (Lua string) directly; loadSnapshot handles
                -- the buffer creation + put internally.
                tecs.loadSnapshot(state.world, state.bytes)
            end,
        },
    },
    cases = {
        {name = "snapshot load", parameters = {count = {1000, 10000, 100000}}},
    },
})
