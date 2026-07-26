#!/usr/bin/env luajit
-- ECS benchmarks
-- Usage: make ecs-bench or luajit main.lua
--
-- evolved.lua is loaded from EVOLVED_PATH (default: ~/projects/evolved.lua). It is not vendored;
-- clone https://github.com/BlackMATov/evolved.lua and point EVOLVED_PATH at the checkout root.
--
-- Case declarations are parameterized: a case with `parameters = {count = {1000, 2000},
-- defer = {false, true}}` is expanded into the Cartesian product (4 runtime cases).
-- Scenarios read params as `case.params.count`, `case.params.defer`, etc.
--
-- Targeted runs:
--   make ecs-bench CASE=12
--   make ecs-bench PARAMS='count=1000,defer=true'
--   make ecs-bench CASE=12 PARAMS='count=1000,defer=true' VARIANTS=tecs
--
-- Notes on fairness:
--   * Mutation loops wrap in their respective deferred regions when `defer` is
--     true; when false, ops apply eagerly. `world:commit` on tecs (not
--     world:update) is used to match evolved's commit scope.
--
--   * evolved teardown uses batch_destroy followed by collect_garbage(true).
--     Removing the GC call produces substantially higher run-to-run variance
--     in spawn-heavy cases; we keep it as a variance-control workaround.
--
--   * FFI-component cases bench two evolved variants: an AoS semantic match
--     (cdata stored per entity in evolved's ordinary component columns) and an
--     evolved SoA variant that splits each struct field into its own fragment.
--     The SoA variant is evolved's fastest FFI-style path, but it changes the
--     component model relative to tecs.

local home = os.getenv("HOME") or ""
local evolvedPath = os.getenv("EVOLVED_PATH") or (home .. "/projects/evolved.lua")

package.path = package.path
        .. ";../../out/macos-arm64-dev/lua/?.lua;../../out/macos-arm64-dev/lua/?/init.lua;"
        .. "../?.lua;../?/init.lua;"
        .. ";" .. evolvedPath .. "/?.lua;"
        .. home .. "/.luarocks/share/lua/5.1/?.lua;"
        .. home .. "/.luarocks/share/lua/5.1/?/init.lua"
package.cpath = package.cpath .. ";" .. home .. "/.luarocks/lib/lua/5.1/?.so"

assert(jit, "LuaJIT is required to run this benchmark")

local _isBenchChild = os.getenv("BENCH_CHILD") == "1"
if not _isBenchChild then print("LuaJIT version:", jit.version) end


local bench = require("lib.bench")
local tecs = require("tecs")

local ok, evo = pcall(require, "evolved")
if not ok then
    error("evolved.lua not found at " .. evolvedPath
        .. "\n  Clone https://github.com/BlackMATov/evolved.lua and either"
        .. "\n  symlink it to ~/projects/evolved.lua, or set EVOLVED_PATH."
        .. "\n  Underlying error: " .. tostring(evo))
end
if not _isBenchChild then print("evolved.lua version:", evo.__VERSION) end
evo.debug_mode(false)

-------------------------------------------------------------------------------
-- Tecs components
-------------------------------------------------------------------------------
--
-- Position/Velocity use Lua-table storage (newComponent) rather than FFI: for
-- spawn-with-value cases, the table path is one allocation (the constructor
-- returns `{x=i, y=i}` referenced directly by the archetype column), while
-- FFI goes through createInstance (two allocations + memcpy per spawn).
-- FFI remains the better fit for update-heavy cases that write into
-- existing columns in place.
--
-- TagA/B/C and Chain tags are bitset-backed: add/remove is a single bit flip
-- with no per-entity allocation.
--
-- Counter is a Lua-table component because it needs an onReplace hook to
-- mirror evolved's ON_ASSIGN. newFFIComponent only forwards onAdd/onRemove.

local Position = tecs.newComponent({name = "VsEvoPosition", container = {}, fields = {"x", "y"}})
local Velocity = tecs.newComponent({name = "VsEvoVelocity", container = {}, fields = {"vx", "vy"}})
local ScalarPosX = tecs.newScalarComponent({
    name = "VsEvoScalarPosX",
    container = {},
    kind = "number",
    default = 0,
})
local ScalarVelX = tecs.newScalarComponent({
    name = "VsEvoScalarVelX",
    container = {},
    kind = "number",
    default = 0,
})
local FFIPosition = tecs.newFFIComponent({
    name = "VsEvoFFIPosition", container = {},
    fields = {{"x", "double"}, {"y", "double"}},
})
local FFIVelocity = tecs.newFFIComponent({
    name = "VsEvoFFIVelocity", container = {},
    fields = {{"vx", "double"}, {"vy", "double"}},
})
local Health = tecs.newComponent({name = "VsEvoHealth", container = {}, fields = {"hp"}})
local Damage = tecs.newComponent({name = "VsEvoDamage", container = {}, fields = {"dmg"}})
local FFIHealth = tecs.newFFIComponent({
    name = "VsEvoFFIHealth", container = {}, fields = {{"hp", "double"}},
})
local FFIDamage = tecs.newFFIComponent({
    name = "VsEvoFFIDamage", container = {}, fields = {{"dmg", "double"}},
})

local TagA = tecs.newTagComponent({name = "VsEvoTagA"})
local TagB = tecs.newTagComponent({name = "VsEvoTagB"})
local TagC = tecs.newTagComponent({name = "VsEvoTagC"})

-- Components for the "component/tag add/remove" batch tests. World layout at
-- setup: N tracked entities carry (Position, Velocity, Alive); 4N background
-- entities carry (Health, BenchName, Aggro). Query `{Position}` matches only
-- the tracked archetype.
local BenchName = tecs.newComponent({name = "VsEvoBenchName", container = {}, fields = {"value"}})
local Alive = tecs.newTagComponent({name = "VsEvoAlive"})
local Aggro = tecs.newTagComponent({name = "VsEvoAggro"})
local BENCH_NAME_MONSTER = BenchName("monster")

-- 20 unique tags for the multi-archetype query/churn tests.
local ArchTags = {}
for i = 1, 20 do
    ArchTags[i] = tecs.newTagComponent({name = "VsEvoArchTag" .. i})
end

-- Three-level hook chain tags. Observer-based: each query's onEntitiesAdded
-- adds the next tag in the chain. Mirrors evolved's hook-chain dispatch
-- (per-write, not atomic-resolve).
local ChainC = tecs.newTagComponent({name = "VsEvoChainC"})
local ChainB = tecs.newTagComponent({name = "VsEvoChainB"})
local ChainA = tecs.newTagComponent({name = "VsEvoChainA"})

local Counter = tecs.newComponent({
    name = "VsEvoCounter", container = {}, fields = {"n"},
    onReplace = function(_new, _w, _e, _changes) end,
})

-------------------------------------------------------------------------------
-- Cases
-------------------------------------------------------------------------------
--
-- `scenario` keys into tecsScenarios / evolvedScenarios below.
-- `parameters` is a map of param-name → list of values; the bench harness
-- expands each case to the Cartesian product and makes each combo available
-- as `case.params` during setup/run.
--
-- Conventions:
--   count: universal workload size (default to a single value per case)
--   defer: wraps the run body in defer()/commit() when true (eager when false)
--   op:    which batch op to run on the tracked archetype (batchOp scenario)

local cases = {
    -- Spawn (table storage)
    {name = "spawn (no hooks)",                 scenario = "spawnLoop1",     parameters = {count = {2000}, defer = {false, true}}},
    {name = "spawn 2 components",               scenario = "spawnLoop2",     parameters = {count = {2000}, defer = {false, true}}},
    {name = "spawn 4 components",               scenario = "spawnLoop4",     parameters = {count = {2000, 10000}, defer = {false, true}}},
    {name = "spawn 3-level onAdd hook chain",   scenario = "spawnHookChain", parameters = {count = {10000}}},
    {name = "batch spawn 2 components",         scenario = "batchSpawn2",    parameters = {count = {10000}}},
    {name = "bundle/prefab spawn 4 components", scenario = "bundleSpawn4",   parameters = {count = {10000}, defer = {false, true}}},
    -- Spawn (FFI storage)
    {name = "spawn 2 FFI components",           scenario = "spawnLoop2FFI",   parameters = {count = {2000}, defer = {false, true}}},
    {name = "batch spawn 4 FFI components",     scenario = "batchSpawn4FFI",  parameters = {count = {10000}, defer = {false, true}}},
    -- Reference: evolved uses split scalar columns instead of one typed struct per entity.
    {name = "batch spawn 4 FFI (evolved SoA)",  scenario = "batchSpawn4FFISoA", parameters = {count = {10000}, defer = {false, true}}},
    -- Despawn
    {name = "despawn",                          scenario = "despawn",         parameters = {count = {10000}, defer = {false, true}}},
    {name = "batch despawn",                    scenario = "batchDespawn",    parameters = {count = {10000}, defer = {false, true}}},
    -- Mutation
    {name = "add component",                    scenario = "addComp",         parameters = {count = {1000}, defer = {false, true}}},
    {name = "remove component",                 scenario = "removeComp",      parameters = {count = {1000}, defer = {false, true}}},
    {name = "value-only update",                scenario = "valueUpdate",     parameters = {count = {1000}, defer = {false, true}}},
    {name = "value-only update (onReplace)",    scenario = "valueUpdateHook", parameters = {count = {1000}, defer = {false, true}}},
    {name = "shuffle through archetypes",       scenario = "shuffle",         parameters = {count = {1000}}},
    {name = "churn across 20 archetypes",       scenario = "churn",           parameters = {count = {2500}}},
    -- Query / iteration
    {name = "query iterate",                    scenario = "queryIter",       parameters = {count = {50000}}},
    {name = "query iterate (scalar)",           scenario = "queryIterScalar", parameters = {count = {50000}}},
    {name = "query iterate (ffi)",              scenario = "queryIterFFI",    parameters = {count = {50000}}},
    {name = "query iterate (ffi, evolved SoA)", scenario = "queryIterFFISoA", parameters = {count = {50000}}},
    {name = "query across 20 archetypes",       scenario = "queryMulti",      parameters = {count = {5000}}},
    {name = "query first result (include + exclude)", scenario = "queryBuild", parameters = {count = {100}}},
    {name = "system update (pos += vel)",       scenario = "sysUpdate",       parameters = {count = {50000}}},
    {name = "system update (scalar += scalar)", scenario = "sysUpdateScalar", parameters = {count = {50000}}},
    {name = "system update ffi (pos += vel)",   scenario = "sysUpdateFFI",    parameters = {count = {50000}}},
    {name = "system update ffi (evolved SoA)",  scenario = "sysUpdateFFISoA", parameters = {count = {50000}}},
    {name = "dispatch 200 systems",             scenario = "dispatch200",     parameters = {count = {5000}}},
    -- Getter
    {name = "random get",                       scenario = "randomGet",       parameters = {count = {100000}}},
    -- Populated-world cases (1k tracked + 4k background)
    {name = "create_with_components (populated)", scenario = "createWithComponents", parameters = {count = {100}}},
    {name = "batch op (populated)",             scenario = "batchOp",
        parameters = {
            count = {1000},
            op = {"setName", "removeVelocity", "setAggro", "removeAlive"},
        }},
    -- Multi-add inside a deferred scope: tecs coalesces all 4 writes per
    -- entity into one archetype transition; archetype-graph frameworks that
    -- don't coalesce pay for 4 transitions per entity.
    {name = "defer + add 4 components",         scenario = "deferMultiAdd",   parameters = {count = {100}}},
}

-------------------------------------------------------------------------------
-- Tecs: shared helpers
-------------------------------------------------------------------------------

local _cachedWorld
local function freshTecsWorld()
    if not _cachedWorld then
        _cachedWorld = tecs.newWorld()
    else
        _cachedWorld:clearEntities()
    end
    return _cachedWorld
end

-- Populate `n` entities with the given components via batchSpawn; returns
-- the entities array (1..n → entity id). Used by every setup that needs a
-- pre-populated tracked set.
local function populateBatch(world, n, components, populator)
    local firstId = world:batchSpawn(n, components, populator)
    world:commit()
    local entities = {}
    for i = 1, n do entities[i] = firstId + i - 1 end
    return entities
end

-- Common populators.
local function fillPosition(arch, startRow, lastRow)
    local ps = arch:getMut(Position)
    for i = startRow, lastRow do ps[i] = Position(i, i) end
end
local function fillPositionVelocity(arch, startRow, lastRow)
    local ps = arch:getMut(Position)
    local vs = arch:getMut(Velocity)
    for i = startRow, lastRow do
        ps[i] = {x = i, y = i}
        vs[i] = {vx = 1, vy = 1}
    end
end
local function fillFFIPosition(arch, startRow, lastRow)
    local ps = arch:getMut(FFIPosition)
    for i = startRow, lastRow do
        ps[i].x = i; ps[i].y = i
    end
end
local function fillFFIPositionVelocity(arch, startRow, lastRow)
    local ps = arch:getMut(FFIPosition); local vs = arch:getMut(FFIVelocity)
    for i = startRow, lastRow do
        ps[i].x = i; ps[i].y = i
        vs[i].vx = 1; vs[i].vy = 1
    end
end

local function populateQueryBuildTecsWorld(world, count)
    for arch = 1, 20 do
        local components = {Position, ArchTags[arch]}
        if arch % 2 == 0 then components[#components + 1] = Velocity end
        if arch % 3 == 0 then components[#components + 1] = Health end
        if arch % 4 == 0 then components[#components + 1] = Damage end
        if arch % 5 == 0 then components[#components + 1] = Alive end
        if arch % 6 == 0 then components[#components + 1] = Aggro end

        world:batchSpawn(count, components, function(archetype, startRow, lastRow)
            local ps = archetype:getMut(Position)
            local vs = archetype:getMut(Velocity)
            local hs = archetype:getMut(Health)
            local ds = archetype:getMut(Damage)

            for i = startRow, lastRow do
                ps[i] = Position(i, i)
                if vs then vs[i] = Velocity(1, 1) end
                if hs then hs[i] = Health(100) end
                if ds then ds[i] = Damage(10) end
            end
        end)
    end
    world:commit()
end

-- Case 5 observers: install once per cached world.
local _chainObserversInstalled = false
local function ensureChainObservers(world)
    if _chainObserversInstalled then return end
    world:query({
        name = "ChainAObserver",
        include = {ChainA},
        onEntitiesAdded = function(archetype, firstRow, lastRow)
            local entities = archetype.entities
            for row = firstRow, lastRow do world:set(entities[row], ChainB) end
        end,
    })
    world:query({
        name = "ChainBObserver",
        include = {ChainB},
        onEntitiesAdded = function(archetype, firstRow, lastRow)
            local entities = archetype.entities
            for row = firstRow, lastRow do world:set(entities[row], ChainC) end
        end,
    })
    _chainObserversInstalled = true
end

-- Batch-op setup helper: 1k tracked (Position, Velocity, Alive) + 4k background
-- (Health, BenchName, Aggro). The tracked query matches only Position.
-- The query is cached at module scope because world:query registers as an
-- archetype observer -- fresh queries per iteration would leak observers and
-- dominate timing.
local _batchBenchQuery
local function setupBatchBenchWorld(case)
    local world = freshTecsWorld()
    local n = case.params.count
    world:batchSpawn(n * 4, {Health, BenchName, Aggro}, function(arch, startRow, lastRow)
        local hs = arch:getMut(Health); local ns = arch:getMut(BenchName)
        for i = startRow, lastRow do
            hs[i] = Health(100)
            ns[i] = BenchName("bg")
        end
    end)
    local firstId = world:batchSpawn(n, {Position, Velocity, Alive}, function(arch, startRow, lastRow)
        local ps = arch:getMut(Position); local vs = arch:getMut(Velocity)
        for i = startRow, lastRow do
            ps[i] = Position(i, i); vs[i] = Velocity(1, 1)
        end
    end)
    world:commit()
    local entities = {}
    for i = 1, n do entities[i] = firstId + i - 1 end
    if not _batchBenchQuery then
        _batchBenchQuery = world:query({include = {Position}})
    end
    return {world = world, query = _batchBenchQuery, entities = entities}
end

-------------------------------------------------------------------------------
-- Tecs scenarios
-------------------------------------------------------------------------------

local tecsScenarios = {}

-- Spawn cases: freshTecsWorld setup; run body toggles defer.
tecsScenarios.spawnLoop1 = {
    setup = function() return freshTecsWorld() end,
    run = function(world, case)
        if case.params.defer then world:defer() end
        for i = 1, case.params.count do
            world:spawn(Position(i, i))
        end
        world:commit()
    end,
}
tecsScenarios.spawnLoop2 = {
    setup = function() return freshTecsWorld() end,
    run = function(world, case)
        if case.params.defer then world:defer() end
        for i = 1, case.params.count do
            world:spawn(Position(i, i), Velocity(1, 1))
        end
        world:commit()
    end,
}
tecsScenarios.spawnLoop4 = {
    setup = function() return freshTecsWorld() end,
    run = function(world, case)
        if case.params.defer then world:defer() end
        for i = 1, case.params.count do
            world:spawn(Position(i, i), Velocity(1, 1), Health(100), Damage(10))
        end
        world:commit()
    end,
}
tecsScenarios.spawnLoop2FFI = {
    setup = function() return freshTecsWorld() end,
    run = function(world, case)
        if case.params.defer then world:defer() end
        for i = 1, case.params.count do
            world:spawn(FFIPosition(i, i), FFIVelocity(1, 1))
        end
        world:commit()
    end,
}

-- Hook chain: per-write dispatch chain via observers.
tecsScenarios.spawnHookChain = {
    setup = function()
        local world = freshTecsWorld()
        ensureChainObservers(world)
        return world
    end,
    run = function(world, case)
        world:defer()
        for _ = 1, case.params.count do
            world:spawn(ChainA)
        end
        world:commit()
    end,
}

tecsScenarios.batchSpawn2 = {
    setup = function() return freshTecsWorld() end,
    run = function(world, case)
        world:batchSpawn(case.params.count, {Position, Velocity}, fillPositionVelocity)
        world:commit()
    end,
}

tecsScenarios.bundleSpawn4 = {
    setup = function()
        local world = freshTecsWorld()
        local bundle = world:getBundle("BenchPrefab")
        if not bundle then
            bundle = world:newBundle("BenchPrefab", {
                with = {
                    [Position] = function() return Position(0, 0) end,
                    [Velocity] = function() return Velocity(1, 1) end,
                    [Health] = function() return Health(100) end,
                    [Damage] = function() return Damage(10) end,
                },
            })
        end
        return {world = world, bundle = bundle}
    end,
    run = function(state, case)
        local bundle = state.bundle
        for _ = 1, case.params.count do bundle:spawn() end
        state.world:commit()
    end,
}

tecsScenarios.batchSpawn4FFI = {
    setup = function() return freshTecsWorld() end,
    run = function(world, case)
        world:batchSpawn(case.params.count,
            {FFIPosition, FFIVelocity, FFIHealth, FFIDamage},
            function(arch, startRow, lastRow)
                local ps = arch:getMut(FFIPosition); local vs = arch:getMut(FFIVelocity)
                local hs = arch:getMut(FFIHealth); local ds = arch:getMut(FFIDamage)
                for i = startRow, lastRow do
                    ps[i].x = i; ps[i].y = i
                    vs[i].vx = 1; vs[i].vy = 1
                    hs[i].hp = 100; ds[i].dmg = 10
                end
            end)
        world:commit()
    end,
}
-- Tecs side of the SoA comparison is identical to the AoS case; the evolved
-- side diverges to use scalar-split columns.
tecsScenarios.batchSpawn4FFISoA = tecsScenarios.batchSpawn4FFI

tecsScenarios.despawn = {
    setup = function(case)
        local world = freshTecsWorld()
        local entities = populateBatch(world, case.params.count, {Position}, fillPosition)
        return {world = world, entities = entities}
    end,
    run = function(state, case)
        local world = state.world
        local entities = state.entities
        if case.params.defer then world:defer() end
        for i = 1, case.params.count do
            world:despawn(entities[i])
        end
        world:commit()
    end,
}

tecsScenarios.batchDespawn = {
    setup = function(case)
        local world = freshTecsWorld()
        world:batchSpawn(case.params.count, {Position, Velocity}, fillPositionVelocity)
        world:commit()
        -- Batch ops require a Query object, built once and reused.
        local query = world:query({include = {Position, Velocity}})
        return {world = world, query = query}
    end,
    run = function(state)
        state.world:batchDespawn(state.query)
        state.world:commit()
    end,
}

tecsScenarios.addComp = {
    setup = function(case)
        local world = freshTecsWorld()
        local entities = populateBatch(world, case.params.count, {Position}, fillPosition)
        return {world = world, entities = entities}
    end,
    run = function(state, case)
        local world = state.world
        local entities = state.entities
        if case.params.defer then world:defer() end
        for i = 1, case.params.count do
            world:set(entities[i], Velocity(1, 1))
        end
        world:commit()
    end,
}

tecsScenarios.removeComp = {
    setup = function(case)
        local world = freshTecsWorld()
        local entities = populateBatch(world, case.params.count, {Position, Velocity}, fillPositionVelocity)
        return {world = world, entities = entities}
    end,
    run = function(state, case)
        local world = state.world
        local entities = state.entities
        if case.params.defer then world:defer() end
        for i = 1, case.params.count do
            world:remove(entities[i], Velocity)
        end
        world:commit()
    end,
}

tecsScenarios.valueUpdate = {
    setup = function(case)
        local world = freshTecsWorld()
        local entities = populateBatch(world, case.params.count, {Position}, fillPosition)
        return {world = world, entities = entities}
    end,
    run = function(state, case)
        local world = state.world
        local entities = state.entities
        if case.params.defer then world:defer() end
        for i = 1, case.params.count do
            world:set(entities[i], Position(i * 2, i * 2))
        end
        world:commit()
    end,
}

tecsScenarios.valueUpdateHook = {
    setup = function(case)
        local world = freshTecsWorld()
        local entities = populateBatch(world, case.params.count, {Counter}, function(arch, startRow, lastRow)
            local cs = arch:getMut(Counter)
            for i = startRow, lastRow do cs[i] = Counter(i) end
        end)
        return {world = world, entities = entities}
    end,
    run = function(state, case)
        local world = state.world
        local entities = state.entities
        if case.params.defer then world:defer() end
        for i = 1, case.params.count do
            world:set(entities[i], Counter(i + 1))
        end
        world:commit()
    end,
}

tecsScenarios.shuffle = {
    setup = function(case)
        local world = freshTecsWorld()
        local entities = populateBatch(world, case.params.count, {Position}, fillPosition)
        return {world = world, entities = entities}
    end,
    run = function(state, case)
        local world = state.world
        local entities = state.entities
        local n = case.params.count
        for i = 1, n do world:set(entities[i], TagA) end
        world:commit()
        for i = 1, n do
            world:set(entities[i], TagB)
            world:remove(entities[i], TagA)
        end
        world:commit()
        for i = 1, n do
            world:set(entities[i], TagC)
            world:remove(entities[i], TagB)
        end
        world:commit()
    end,
}

tecsScenarios.churn = {
    setup = function(case)
        local world = freshTecsWorld()
        local allEntities = {}
        for arch = 1, 20 do
            local tag = ArchTags[arch]
            local firstId = world:batchSpawn(case.params.count, {Position, tag}, function(a, startRow, lastRow)
                local ps = a:getMut(Position)
                for i = startRow, lastRow do ps[i] = Position(i, i) end
            end)
            for i = 0, case.params.count - 1 do
                allEntities[#allEntities + 1] = {firstId + i, arch}
            end
        end
        world:commit()
        return {world = world, entities = allEntities}
    end,
    run = function(state)
        local world = state.world
        local entities = state.entities
        for i = 1, #entities do
            local e = entities[i]
            local id = e[1]
            local archIdx = e[2]
            local step = (i - 1) % 4
            if step == 0 then
                world:remove(id, ArchTags[archIdx])
            elseif step == 1 then
                world:remove(id, ArchTags[archIdx])
                local nextArch = (archIdx % 20) + 1
                world:set(id, ArchTags[nextArch])
                e[2] = nextArch
            elseif step == 2 then
                world:set(id, Health(100))
                world:set(id, Damage(10))
            else
                world:remove(id, ArchTags[archIdx])
                world:set(id, TagC)
            end
        end
        world:commit()
    end,
}

-- Cached-setup helper for read-only / idempotent cases.
local function cachedSetup(build)
    local cached
    return function(case)
        if not cached then cached = build(case) end
        return cached
    end
end

tecsScenarios.queryIter = {
    setup = cachedSetup(function(case)
        local world = freshTecsWorld()
        world:batchSpawn(case.params.count, {Position}, fillPosition)
        world:commit()
        return {world = world, query = world:query({include = {Position}})}
    end),
    run = function(state)
        local sum = 0
        for archetype, len in state.query:iter() do
            local ps = archetype:get(Position)
            for i = 1, len do sum = sum + ps[i].x end
        end
        return sum
    end,
}

tecsScenarios.queryIterScalar = {
    setup = cachedSetup(function(case)
        local world = freshTecsWorld()
        world:batchSpawn(case.params.count, {ScalarPosX}, function(arch, startRow, lastRow)
            local xs = arch:getMut(ScalarPosX)
            for i = startRow, lastRow do xs[i] = i end
        end)
        world:commit()
        return {world = world, query = world:query({include = {ScalarPosX}})}
    end),
    run = function(state)
        local sum = 0
        for archetype, len in state.query:iter() do
            local xs = archetype:get(ScalarPosX)
            for i = 1, len do sum = sum + xs[i] end
        end
        return sum
    end,
}

tecsScenarios.queryIterFFI = {
    setup = cachedSetup(function(case)
        local world = freshTecsWorld()
        world:batchSpawn(case.params.count, {FFIPosition}, fillFFIPosition)
        world:commit()
        return {world = world, query = world:query({include = {FFIPosition}})}
    end),
    run = function(state)
        local sum = 0
        for archetype, len in state.query:iter() do
            local ps = archetype:get(FFIPosition)
            for i = 1, len do sum = sum + ps[i].x end
        end
        return sum
    end,
}
tecsScenarios.queryIterFFISoA = tecsScenarios.queryIterFFI

tecsScenarios.queryMulti = {
    setup = cachedSetup(function(case)
        local world = freshTecsWorld()
        for arch = 1, 20 do
            local tag = ArchTags[arch]
            world:batchSpawn(case.params.count, {Position, tag}, function(a, startRow, lastRow)
                local ps = a:getMut(Position)
                for i = startRow, lastRow do ps[i] = Position(i, i) end
            end)
        end
        world:commit()
        return {world = world, query = world:query({include = {Position}})}
    end),
    run = function(state)
        local sum = 0
        for archetype, len in state.query:iter() do
            local ps = archetype:get(Position)
            for i = 1, len do sum = sum + ps[i].x end
        end
        return sum
    end,
}

tecsScenarios.queryBuild = {
    setup = function(case)
        local world = tecs.newWorld()
        populateQueryBuildTecsWorld(world, case.params.count)
        return {world = world}
    end,
    run = function(state)
        local query = state.world:query({
            include = {Position, Velocity},
            exclude = {Damage, Aggro},
            temp = true,
        })
        for archetype, len in query:iter() do
            return archetype, len
        end
        return nil, 0
    end,
    teardown = function(state)
        state.world:clearEntities()
    end,
}

tecsScenarios.sysUpdate = {
    setup = cachedSetup(function(case)
        local world = freshTecsWorld()
        world:batchSpawn(case.params.count, {Position, Velocity}, fillPositionVelocity)
        world:commit()
        return {world = world, query = world:query({include = {Position, Velocity}})}
    end),
    run = function(state)
        for archetype, len in state.query:iter() do
            local ps = archetype:getMut(Position); local vs = archetype:getMut(Velocity)
            for i = 1, len do
                local p = ps[i]; local v = vs[i]
                p.x = p.x + v.vx; p.y = p.y + v.vy
            end
        end
    end,
}

tecsScenarios.sysUpdateScalar = {
    setup = cachedSetup(function(case)
        local world = freshTecsWorld()
        world:batchSpawn(case.params.count, {ScalarPosX, ScalarVelX}, function(arch, startRow, lastRow)
            local xs = arch:getMut(ScalarPosX)
            local vxs = arch:getMut(ScalarVelX)
            for i = startRow, lastRow do
                xs[i] = i
                vxs[i] = 1
            end
        end)
        world:commit()
        return {world = world, query = world:query({include = {ScalarPosX, ScalarVelX}})}
    end),
    run = function(state)
        for archetype, len in state.query:iter() do
            local xs = archetype:getMut(ScalarPosX)
            local vxs = archetype:getMut(ScalarVelX)
            for i = 1, len do
                xs[i] = xs[i] + vxs[i]
            end
        end
    end,
}

tecsScenarios.sysUpdateFFI = {
    setup = cachedSetup(function(case)
        local world = freshTecsWorld()
        world:batchSpawn(case.params.count, {FFIPosition, FFIVelocity}, fillFFIPositionVelocity)
        world:commit()
        return {world = world, query = world:query({include = {FFIPosition, FFIVelocity}})}
    end),
    run = function(state)
        for archetype, len in state.query:iter() do
            local ps = archetype:getMut(FFIPosition); local vs = archetype:getMut(FFIVelocity)
            for i = 1, len do
                local p = ps[i]; local v = vs[i]
                p.x = p.x + v.vx; p.y = p.y + v.vy
            end
        end
    end,
}
tecsScenarios.sysUpdateFFISoA = tecsScenarios.sysUpdateFFI

tecsScenarios.dispatch200 = (function()
    -- freshTecsWorld does not remove systems on clearEntities, so this case
    -- keeps its own world and installs the 200 systems once.
    local dispatchWorld
    return {
        setup = function()
            if not dispatchWorld then
                dispatchWorld = tecs.newWorld()
                local counter = 0
                for i = 1, 200 do
                    dispatchWorld:addSystem({
                        name = "BenchSystem" .. i,
                        phase = tecs.phases.Update,
                        run = function() counter = counter + 1 end,
                    })
                end
            end
            return {world = dispatchWorld}
        end,
        run = function(state)
            state.world:runPhase(tecs.phases.Update, 1/60)
        end,
    }
end)()

tecsScenarios.randomGet = {
    setup = cachedSetup(function(case)
        local world = freshTecsWorld()
        local firstId = world:batchSpawn(case.params.count, {Position}, fillPosition)
        world:commit()
        local shuffled = {}
        for i = 1, case.params.count do shuffled[i] = firstId + i - 1 end
        for i = case.params.count, 2, -1 do
            local j = math.random(1, i)
            shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
        end
        return {world = world, shuffled = shuffled}
    end),
    run = function(state, case)
        local world = state.world
        local shuffled = state.shuffled
        local sum = 0
        for i = 1, case.params.count do
            local p = world:get(shuffled[i], Position)
            sum = sum + p.x
        end
        return sum
    end,
}

-- Create_with_components (bundle spawn in populated world). Bundle is created
-- once per process.
tecsScenarios.createWithComponents = {
    setup = function(case)
        local world = freshTecsWorld()
        local n = case.params.count
        world:batchSpawn(n * 4, {Health, BenchName, Aggro}, function(arch, startRow, lastRow)
            local hs = arch:getMut(Health); local ns = arch:getMut(BenchName)
            for i = startRow, lastRow do hs[i] = Health(100); ns[i] = BenchName("bg") end
        end)
        world:batchSpawn(n, {Position, Velocity, Alive}, function(arch, startRow, lastRow)
            local ps = arch:getMut(Position); local vs = arch:getMut(Velocity)
            for i = startRow, lastRow do ps[i] = Position(i, i); vs[i] = Velocity(1, 1) end
        end)
        world:commit()
        local bundle = world:getBundle("CreateWithComponents100")
        if not bundle then
            bundle = world:newBundle("CreateWithComponents100", {
                with = {
                    [Position] = function() return Position(0, 0) end,
                    [Alive] = function() return Alive end,
                },
            })
        end
        return {world = world, bundle = bundle}
    end,
    run = function(state, case)
        local bundle = state.bundle
        for _ = 1, case.params.count do bundle:spawn() end
        state.world:commit()
    end,
}

-- Single scenario for the four batch-op variants; `op` param selects which.
tecsScenarios.batchOp = {
    setup = setupBatchBenchWorld,
    run = function(state, case)
        local world = state.world
        local q = state.query
        local op = case.params.op
        if op == "setName" then
            world:batchSet(q, BENCH_NAME_MONSTER)
        elseif op == "removeVelocity" then
            world:batchRemove(q, Velocity)
        elseif op == "setAggro" then
            world:batchSet(q, Aggro)
        elseif op == "removeAlive" then
            world:batchRemove(q, Alive)
        else
            error("batchOp: unknown op '" .. tostring(op) .. "'")
        end
        world:commit()
    end,
}

tecsScenarios.deferMultiAdd = (function()
    local VELOCITY_11 = Velocity(1, 1)
    local HEALTH_100 = Health(100)
    local DAMAGE_10 = Damage(10)
    return {
        setup = function(case)
            local world = freshTecsWorld()
            local entities = populateBatch(world, case.params.count, {Position}, fillPosition)
            return {world = world, entities = entities}
        end,
        run = function(state, case)
            local world = state.world
            local entities = state.entities
            local n = case.params.count
            world:defer()
            for i = 1, n do
                local e = entities[i]
                world:set(e, VELOCITY_11)
                world:set(e, HEALTH_100)
                world:set(e, DAMAGE_10)
                world:set(e, TagA)
            end
            world:commit()
        end,
    }
end)()

-------------------------------------------------------------------------------
-- Evolved: entities and helpers
-------------------------------------------------------------------------------

local PositionE = evo.id()
local VelocityE = evo.id()
local HealthE = evo.id()
local DamageE = evo.id()

local TagAE = evo.builder():tag():build()
local TagBE = evo.builder():tag():build()
local TagCE = evo.builder():tag():build()

local AliveE = evo.builder():tag():build()
local AggroE = evo.builder():tag():build()

local ArchTagsE = {}
for i = 1, 20 do ArchTagsE[i] = evo.builder():tag():build() end

-- Hook chain: each set triggers ON_INSERT which sets the next tag.
local ChainAE = evo.builder():tag():build()
local ChainBE = evo.builder():tag():build()
local ChainCE = evo.builder():tag():build()
evo.set(ChainBE, evo.ON_INSERT, function(e) evo.set(e, ChainCE) end)
evo.set(ChainAE, evo.ON_INSERT, function(e) evo.set(e, ChainBE) end)

local CounterE = evo.id()
evo.set(CounterE, evo.ON_ASSIGN, function(_e, _f, _new, _old) end)

-- Prefab mirroring the tecs bundle. `:duplicate` returns fresh tables per
-- clone (evolved.clone() otherwise shares the prefab reference; tecs bundle
-- factories allocate fresh tables per spawn).
local PrefabPosE = evo.builder():duplicate(function() return {x = 0, y = 0} end):build()
local PrefabVelE = evo.builder():duplicate(function() return {vx = 1, vy = 1} end):build()
local PrefabHealthE = evo.builder():duplicate(function() return {hp = 100} end):build()
local PrefabDamageE = evo.builder():duplicate(function() return {dmg = 10} end):build()

local BenchPrefabE = evo.builder()
    :prefab()
    :set(PrefabPosE, {x = 0, y = 0})
    :set(PrefabVelE, {vx = 1, vy = 1})
    :set(PrefabHealthE, {hp = 100})
    :set(PrefabDamageE, {dmg = 10})
    :build()

local ffi = require("ffi")
local FFI_DOUBLE_TYPEOF = ffi.typeof("double")
local FFI_DOUBLE_SIZEOF = ffi.sizeof(FFI_DOUBLE_TYPEOF)
local FFI_DOUBLE_STORAGE_TYPEOF = ffi.typeof("double[?]")

ffi.cdef[[
    struct EvoPos { double x; double y; };
    struct EvoVel { double vx; double vy; };
    struct EvoHealth { double hp; };
    struct EvoDmg { double dmg; };
]]
local EvoPosType = ffi.typeof("struct EvoPos")
local EvoVelType = ffi.typeof("struct EvoVel")
local EvoHealthType = ffi.typeof("struct EvoHealth")
local EvoDmgType = ffi.typeof("struct EvoDmg")

local function FFI_DOUBLE_REALLOC(src, src_size, dst_size)
    if dst_size == 0 then return end
    local dst = ffi.new(FFI_DOUBLE_STORAGE_TYPEOF, dst_size + 1)
    if src and src_size > 0 then
        ffi.copy(dst + 1, src + 1, math.min(src_size, dst_size) * FFI_DOUBLE_SIZEOF)
    end
    return dst
end
local function FFI_DOUBLE_COMPMOVE(src, f, e, t, dst)
    ffi.copy(dst + t, src + f, (e - f + 1) * FFI_DOUBLE_SIZEOF)
end

local function ffiDoubleFragment()
    return evo.builder()
        :default(0)
        :realloc(FFI_DOUBLE_REALLOC)
        :compmove(FFI_DOUBLE_COMPMOVE)
        :build()
end

local PositionXE = ffiDoubleFragment()
local PositionYE = ffiDoubleFragment()
local VelocityXE = ffiDoubleFragment()
local VelocityYE = ffiDoubleFragment()
local HealthHpE = ffiDoubleFragment()
local DamageDmgE = ffiDoubleFragment()
local ScalarPosXE = evo.builder():default(0):build()
local ScalarVelXE = evo.builder():default(0):build()

-- Scalar-split fragments for the batch-op cases (matches the lua-ecs-benchmark
-- evolved adapter shape). BatchNameValueE stores a plain string per entity.
local BatchPositionXE = ffiDoubleFragment()
local BatchPositionYE = ffiDoubleFragment()
local BatchVelocityXE = ffiDoubleFragment()
local BatchVelocityYE = ffiDoubleFragment()
local BatchHealthHpE = ffiDoubleFragment()
local BatchNameValueE = evo.id()
local BATCH_NAME_MONSTER_E = "monster"

-- Cached cleanup queries.
local QPosition = evo.builder():include(PositionE):spawn()
local QPositionX = evo.builder():include(PositionXE):spawn()
local QChainA = evo.builder():include(ChainAE):spawn()
local QCounter = evo.builder():include(CounterE):spawn()
local QBatchPosition = evo.builder():include(BatchPositionXE):build()
local QBatchBg = evo.builder():include(BatchHealthHpE):build()

local function evoCleanup(query)
    return function(_state)
        evo.batch_destroy(query)
        evo.collect_garbage(true)
    end
end

-- Spawn entities into `entities` table via a fragment populator.
local function evoPopulate(count, fragments, populator)
    local entities = {}
    evo.multi_spawn_to(entities, 1, count, fragments, populator)
    return entities
end

local function evoPopulateQueryBuild(count)
    for arch = 1, 20 do
        local fragments = {[PositionE] = true, [ArchTagsE[arch]] = true}
        if arch % 2 == 0 then fragments[VelocityE] = true end
        if arch % 3 == 0 then fragments[HealthE] = true end
        if arch % 4 == 0 then fragments[DamageE] = true end
        if arch % 5 == 0 then fragments[AliveE] = true end
        if arch % 6 == 0 then fragments[AggroE] = true end

        evo.multi_spawn_nr(count, fragments, function(chunk, b, e)
            local ps = chunk:components(PositionE)
            local vs = fragments[VelocityE] and chunk:components(VelocityE) or nil
            local hs = fragments[HealthE] and chunk:components(HealthE) or nil
            local ds = fragments[DamageE] and chunk:components(DamageE) or nil

            for i = b, e do
                ps[i] = {x = i, y = i}
                if vs then vs[i] = {vx = 1, vy = 1} end
                if hs then hs[i] = {hp = 100} end
                if ds then ds[i] = {dmg = 10} end
            end
        end)
    end
end

-- Populate the 1k tracked + 4k background layout used by the batch-op cases.
local function evoPopulateBatchBench(n)
    evo.multi_spawn_nr(n * 4,
        {[BatchHealthHpE] = true, [BatchNameValueE] = true, [AggroE] = true},
        function(chunk, b, e)
            local hps = chunk:components(BatchHealthHpE)
            local ns = chunk:components(BatchNameValueE)
            for i = b, e do hps[i] = 100; ns[i] = "bg" end
        end)
    evo.multi_spawn_nr(n,
        {[BatchPositionXE] = true, [BatchPositionYE] = true,
         [BatchVelocityXE] = true, [BatchVelocityYE] = true, [AliveE] = true},
        function(chunk, b, e)
            local pxs, pys = chunk:components(BatchPositionXE, BatchPositionYE)
            local vxs, vys = chunk:components(BatchVelocityXE, BatchVelocityYE)
            for i = b, e do
                pxs[i] = i; pys[i] = i
                vxs[i] = 1; vys[i] = 1
            end
        end)
end

local function evoBatchBenchCleanup()
    evo.batch_destroy(QBatchPosition)
    evo.batch_destroy(QBatchBg)
end

-------------------------------------------------------------------------------
-- Evolved scenarios
-------------------------------------------------------------------------------

local evolvedScenarios = {}

evolvedScenarios.spawnLoop1 = {
    setup = function() return {} end,
    run = function(_state, case)
        evo.defer()
        for i = 1, case.params.count do
            evo.spawn({[PositionE] = {x = i, y = i}})
        end
        evo.commit()
    end,
    teardown = evoCleanup(QPosition),
}

evolvedScenarios.spawnLoop2 = {
    setup = function() return {} end,
    run = function(_state, case)
        evo.defer()
        for i = 1, case.params.count do
            evo.spawn({
                [PositionE] = {x = i, y = i},
                [VelocityE] = {vx = 1, vy = 1},
            })
        end
        evo.commit()
    end,
    teardown = evoCleanup(QPosition),
}

evolvedScenarios.spawnLoop4 = {
    setup = function() return {} end,
    run = function(_state, case)
        evo.defer()
        for i = 1, case.params.count do
            evo.spawn({
                [PositionE] = {x = i, y = i},
                [VelocityE] = {vx = 1, vy = 1},
                [HealthE] = {hp = 100},
                [DamageE] = {dmg = 10},
            })
        end
        evo.commit()
    end,
    teardown = evoCleanup(QPosition),
}

evolvedScenarios.spawnLoop2FFI = {
    setup = function() return {} end,
    run = function(_state, case)
        evo.defer()
        for i = 1, case.params.count do
            evo.spawn({
                [PositionE] = EvoPosType(i, i),
                [VelocityE] = EvoVelType(1, 1),
            })
        end
        evo.commit()
    end,
    teardown = evoCleanup(QPosition),
}

evolvedScenarios.spawnHookChain = {
    setup = function() return {} end,
    run = function(_state, case)
        evo.defer()
        for _ = 1, case.params.count do
            evo.spawn({[ChainAE] = true})
        end
        evo.commit()
    end,
    teardown = evoCleanup(QChainA),
}

evolvedScenarios.batchSpawn2 = {
    setup = function() return {} end,
    run = function(_state, case)
        evo.multi_spawn_nr(case.params.count,
            {[PositionE] = true, [VelocityE] = true},
            function(chunk, b, e)
                local ps, vs = chunk:components(PositionE, VelocityE)
                for i = b, e do
                    ps[i] = {x = i, y = i}
                    vs[i] = {vx = 1, vy = 1}
                end
            end)
    end,
    teardown = evoCleanup(QPosition),
}

evolvedScenarios.bundleSpawn4 = {
    setup = function() return {} end,
    run = function(_state, case)
        evo.defer()
        for _ = 1, case.params.count do evo.clone(BenchPrefabE) end
        evo.commit()
    end,
    teardown = function()
        evo.batch_destroy(evo.builder():include(PrefabPosE):build())
    end,
}

evolvedScenarios.batchSpawn4FFI = {
    setup = function() return {} end,
    run = function(_state, case)
        evo.multi_spawn_nr(case.params.count,
            {[PositionE] = true, [VelocityE] = true, [HealthE] = true, [DamageE] = true},
            function(chunk, b, e)
                local ps, vs = chunk:components(PositionE, VelocityE)
                local hs, ds = chunk:components(HealthE, DamageE)
                for i = b, e do
                    ps[i] = EvoPosType(i, i)
                    vs[i] = EvoVelType(1, 1)
                    hs[i] = EvoHealthType(100)
                    ds[i] = EvoDmgType(10)
                end
            end)
    end,
    teardown = evoCleanup(QPosition),
}

-- SoA variant: evolved splits each field into its own scalar fragment.
evolvedScenarios.batchSpawn4FFISoA = {
    setup = function() return {} end,
    run = function(_state, case)
        evo.multi_spawn_nr(case.params.count,
            {[PositionXE] = true, [PositionYE] = true, [VelocityXE] = true, [VelocityYE] = true,
             [HealthHpE] = true, [DamageDmgE] = true},
            function(chunk, b, e)
                local pxs, pys = chunk:components(PositionXE, PositionYE)
                local vxs, vys = chunk:components(VelocityXE, VelocityYE)
                local hps = chunk:components(HealthHpE)
                local dmgs = chunk:components(DamageDmgE)
                for i = b, e do
                    pxs[i] = i; pys[i] = i
                    vxs[i] = 1; vys[i] = 1
                    hps[i] = 100; dmgs[i] = 10
                end
            end)
    end,
    teardown = evoCleanup(QPositionX),
}

evolvedScenarios.despawn = {
    setup = function(case)
        return {entities = evoPopulate(case.params.count, {[PositionE] = true},
            function(chunk, b, e)
                local ps = chunk:components(PositionE)
                for i = b, e do ps[i] = {x = i, y = i} end
            end)}
    end,
    run = function(state, case)
        evo.defer()
        for i = 1, case.params.count do
            evo.destroy(state.entities[i])
        end
        evo.commit()
    end,
}

evolvedScenarios.batchDespawn = {
    setup = function(case)
        local destroyQuery = evo.builder():include(PositionE, VelocityE):build()
        evo.multi_spawn_nr(case.params.count, {[PositionE] = true, [VelocityE] = true},
            function(chunk, b, e)
                local ps, vs = chunk:components(PositionE, VelocityE)
                for i = b, e do ps[i] = {x = i, y = i}; vs[i] = {vx = 1, vy = 1} end
            end)
        return {destroyQuery = destroyQuery}
    end,
    run = function(state)
        evo.batch_destroy(state.destroyQuery)
    end,
}

evolvedScenarios.addComp = {
    setup = function(case)
        return {entities = evoPopulate(case.params.count, {[PositionE] = true},
            function(chunk, b, e)
                local ps = chunk:components(PositionE)
                for i = b, e do ps[i] = {x = i, y = i} end
            end)}
    end,
    run = function(state, case)
        evo.defer()
        for i = 1, case.params.count do
            evo.set(state.entities[i], VelocityE, {vx = 1, vy = 1})
        end
        evo.commit()
    end,
    teardown = evoCleanup(QPosition),
}

evolvedScenarios.removeComp = {
    setup = function(case)
        return {entities = evoPopulate(case.params.count, {[PositionE] = true, [VelocityE] = true},
            function(chunk, b, e)
                local ps, vs = chunk:components(PositionE, VelocityE)
                for i = b, e do ps[i] = {x = i, y = i}; vs[i] = {vx = 1, vy = 1} end
            end)}
    end,
    run = function(state, case)
        evo.defer()
        for i = 1, case.params.count do
            evo.remove(state.entities[i], VelocityE)
        end
        evo.commit()
    end,
    teardown = evoCleanup(QPosition),
}

evolvedScenarios.valueUpdate = {
    setup = function(case)
        return {entities = evoPopulate(case.params.count, {[PositionE] = true},
            function(chunk, b, e)
                local ps = chunk:components(PositionE)
                for i = b, e do ps[i] = {x = i, y = i} end
            end)}
    end,
    run = function(state, case)
        evo.defer()
        for i = 1, case.params.count do
            evo.set(state.entities[i], PositionE, {x = i * 2, y = i * 2})
        end
        evo.commit()
    end,
    teardown = evoCleanup(QPosition),
}

evolvedScenarios.valueUpdateHook = {
    setup = function(case)
        return {entities = evoPopulate(case.params.count, {[CounterE] = true},
            function(chunk, b, e)
                local cs = chunk:components(CounterE)
                for i = b, e do cs[i] = {n = i} end
            end)}
    end,
    run = function(state, case)
        evo.defer()
        for i = 1, case.params.count do
            evo.set(state.entities[i], CounterE, {n = i + 1})
        end
        evo.commit()
    end,
    teardown = evoCleanup(QCounter),
}

evolvedScenarios.shuffle = {
    setup = function(case)
        return {entities = evoPopulate(case.params.count, {[PositionE] = true},
            function(chunk, b, e)
                local ps = chunk:components(PositionE)
                for i = b, e do ps[i] = {x = i, y = i} end
            end)}
    end,
    run = function(state, case)
        local entities = state.entities
        local n = case.params.count
        evo.defer()
        for i = 1, n do evo.set(entities[i], TagAE) end
        evo.commit()
        evo.defer()
        for i = 1, n do
            evo.set(entities[i], TagBE)
            evo.remove(entities[i], TagAE)
        end
        evo.commit()
        evo.defer()
        for i = 1, n do
            evo.set(entities[i], TagCE)
            evo.remove(entities[i], TagBE)
        end
        evo.commit()
    end,
    teardown = evoCleanup(QPosition),
}

evolvedScenarios.churn = {
    setup = function(case)
        local allEntities = {}
        for arch = 1, 20 do
            local tag = ArchTagsE[arch]
            evo.defer()
            for i = 1, case.params.count do
                local id = evo.spawn({[PositionE] = {x = i, y = i}, [tag] = true})
                allEntities[#allEntities + 1] = {id, arch}
            end
            evo.commit()
        end
        return {entities = allEntities}
    end,
    run = function(state)
        local entities = state.entities
        local n = #entities
        evo.defer()
        for i = 1, n do
            local e = entities[i]
            local id = e[1]
            local archIdx = e[2]
            local step = (i - 1) % 4
            if step == 0 then
                evo.remove(id, ArchTagsE[archIdx])
            elseif step == 1 then
                evo.remove(id, ArchTagsE[archIdx])
                local nextArch = (archIdx % 20) + 1
                evo.set(id, ArchTagsE[nextArch])
                e[2] = nextArch
            elseif step == 2 then
                evo.set(id, HealthE, {hp = 100})
                evo.set(id, DamageE, {dmg = 10})
            else
                evo.remove(id, ArchTagsE[archIdx])
                evo.set(id, TagCE)
            end
        end
        evo.commit()
    end,
    teardown = evoCleanup(QPosition),
}

evolvedScenarios.queryIter = {
    setup = cachedSetup(function(case)
        local q = evo.builder():include(PositionE):spawn()
        evo.multi_spawn_nr(case.params.count, {[PositionE] = true},
            function(chunk, b, e)
                local ps = chunk:components(PositionE)
                for i = b, e do ps[i] = {x = i, y = i} end
            end)
        return {query = q}
    end),
    run = function(state)
        local sum = 0
        for chunk, _, entity_count in evo.execute(state.query) do
            local ps = chunk:components(PositionE)
            for i = 1, entity_count do sum = sum + ps[i].x end
        end
        return sum
    end,
}

evolvedScenarios.queryIterScalar = {
    setup = cachedSetup(function(case)
        local q = evo.builder():include(ScalarPosXE):spawn()
        evo.multi_spawn_nr(case.params.count, {[ScalarPosXE] = true},
            function(chunk, b, e)
                local xs = chunk:components(ScalarPosXE)
                for i = b, e do xs[i] = i end
            end)
        return {query = q}
    end),
    run = function(state)
        local sum = 0
        for chunk, _, entity_count in evo.execute(state.query) do
            local xs = chunk:components(ScalarPosXE)
            for i = 1, entity_count do sum = sum + xs[i] end
        end
        return sum
    end,
}

evolvedScenarios.queryIterFFI = {
    setup = cachedSetup(function(case)
        local q = evo.builder():include(PositionE):spawn()
        evo.multi_spawn_nr(case.params.count, {[PositionE] = true},
            function(chunk, b, e)
                local ps = chunk:components(PositionE)
                for i = b, e do ps[i] = EvoPosType(i, i) end
            end)
        return {query = q}
    end),
    run = function(state)
        local sum = 0
        for chunk, _, entity_count in evo.execute(state.query) do
            local ps = chunk:components(PositionE)
            for i = 1, entity_count do sum = sum + ps[i].x end
        end
        return sum
    end,
}

evolvedScenarios.queryIterFFISoA = {
    setup = cachedSetup(function(case)
        local q = evo.builder():include(PositionXE, PositionYE):spawn()
        evo.builder()
            :set(PositionXE):set(PositionYE)
            :multi_spawn(case.params.count, function(chunk, b_place, e_place)
                local xs = chunk:components(PositionXE)
                for place = b_place, e_place do xs[place] = place end
            end)
        return {query = q}
    end),
    run = function(state)
        local sum = 0
        for chunk, _, entity_count in evo.execute(state.query) do
            local xs = chunk:components(PositionXE)
            for i = 1, entity_count do sum = sum + xs[i] end
        end
        return sum
    end,
}

evolvedScenarios.queryMulti = {
    setup = cachedSetup(function(case)
        local q = evo.builder():include(PositionE):spawn()
        for arch = 1, 20 do
            local tag = ArchTagsE[arch]
            evo.multi_spawn_nr(case.params.count, {[PositionE] = true, [tag] = true},
                function(chunk, b, e)
                    local ps = chunk:components(PositionE)
                    for i = b, e do ps[i] = {x = i, y = i} end
                end)
        end
        return {query = q}
    end),
    run = function(state)
        local sum = 0
        for chunk, _, entity_count in evo.execute(state.query) do
            local ps = chunk:components(PositionE)
            for i = 1, entity_count do sum = sum + ps[i].x end
        end
        return sum
    end,
}

evolvedScenarios.queryBuild = {
    setup = function(case)
        evoPopulateQueryBuild(case.params.count)
        return true
    end,
    run = function()
        local query = evo.builder()
            :include(PositionE, VelocityE)
            :exclude(DamageE, AggroE)
            :build()
        for chunk, _, entity_count in evo.execute(query) do
            return chunk, entity_count
        end
        return nil, 0
    end,
    teardown = evoCleanup(QPosition),
}

evolvedScenarios.sysUpdate = {
    setup = cachedSetup(function(case)
        local q = evo.builder():include(PositionE, VelocityE):spawn()
        evo.multi_spawn_nr(case.params.count, {[PositionE] = true, [VelocityE] = true},
            function(chunk, b, e)
                local ps, vs = chunk:components(PositionE, VelocityE)
                for i = b, e do ps[i] = {x = i, y = i}; vs[i] = {vx = 1, vy = 1} end
            end)
        return {query = q}
    end),
    run = function(state)
        for chunk, _, entity_count in evo.execute(state.query) do
            local ps, vs = chunk:components(PositionE, VelocityE)
            for i = 1, entity_count do
                local p = ps[i]; local v = vs[i]
                p.x = p.x + v.vx; p.y = p.y + v.vy
            end
        end
    end,
}

evolvedScenarios.sysUpdateScalar = {
    setup = cachedSetup(function(case)
        local q = evo.builder():include(ScalarPosXE, ScalarVelXE):spawn()
        evo.multi_spawn_nr(case.params.count, {[ScalarPosXE] = true, [ScalarVelXE] = true},
            function(chunk, b, e)
                local xs, vxs = chunk:components(ScalarPosXE, ScalarVelXE)
                for i = b, e do
                    xs[i] = i
                    vxs[i] = 1
                end
            end)
        return {query = q}
    end),
    run = function(state)
        for chunk, _, entity_count in evo.execute(state.query) do
            local xs, vxs = chunk:components(ScalarPosXE, ScalarVelXE)
            for i = 1, entity_count do
                xs[i] = xs[i] + vxs[i]
            end
        end
    end,
}

evolvedScenarios.sysUpdateFFI = {
    setup = cachedSetup(function(case)
        local q = evo.builder():include(PositionE, VelocityE):spawn()
        evo.multi_spawn_nr(case.params.count, {[PositionE] = true, [VelocityE] = true},
            function(chunk, b, e)
                local ps, vs = chunk:components(PositionE, VelocityE)
                for i = b, e do
                    ps[i] = EvoPosType(i, i)
                    vs[i] = EvoVelType(1, 1)
                end
            end)
        return {query = q}
    end),
    run = function(state)
        for chunk, _, entity_count in evo.execute(state.query) do
            local ps, vs = chunk:components(PositionE, VelocityE)
            for i = 1, entity_count do
                local p = ps[i]; local v = vs[i]
                p.x = p.x + v.vx; p.y = p.y + v.vy
            end
        end
    end,
}

evolvedScenarios.sysUpdateFFISoA = {
    setup = cachedSetup(function(case)
        local q = evo.builder():include(PositionXE, PositionYE, VelocityXE, VelocityYE):spawn()
        evo.builder()
            :set(PositionXE):set(PositionYE)
            :set(VelocityXE):set(VelocityYE)
            :multi_spawn(case.params.count, function(chunk, b_place, e_place)
                local pxs, pys = chunk:components(PositionXE, PositionYE)
                local vxs, vys = chunk:components(VelocityXE, VelocityYE)
                for place = b_place, e_place do
                    pxs[place] = place; pys[place] = place
                    vxs[place] = 1; vys[place] = 1
                end
            end)
        return {query = q}
    end),
    run = function(state)
        for chunk, _, entity_count in evo.execute(state.query) do
            local pxs, pys = chunk:components(PositionXE, PositionYE)
            local vxs, vys = chunk:components(VelocityXE, VelocityYE)
            for i = 1, entity_count do
                pxs[i] = pxs[i] + vxs[i]
                pys[i] = pys[i] + vys[i]
            end
        end
    end,
}

evolvedScenarios.dispatch200 = {
    setup = function()
        local stage = evo.builder():build()
        local counter = 0
        local systems = {}
        for i = 1, 200 do
            systems[i] = evo.builder()
                :group(stage)
                :prologue(function() counter = counter + 1 end)
                :build()
        end
        return {stage = stage, systems = systems}
    end,
    run = function(state)
        evo.process_with(state.stage, 1/60)
    end,
    teardown = function(state)
        for i = 1, #state.systems do evo.destroy(state.systems[i]) end
        evo.destroy(state.stage)
    end,
}

evolvedScenarios.randomGet = {
    setup = cachedSetup(function(case)
        local entities = {}
        evo.multi_spawn_to(entities, 1, case.params.count, {[PositionE] = true},
            function(chunk, b, e)
                local ps = chunk:components(PositionE)
                for i = b, e do ps[i] = {x = i, y = i} end
            end)
        local shuffled = {}
        for i = 1, case.params.count do shuffled[i] = entities[i] end
        for i = case.params.count, 2, -1 do
            local j = math.random(1, i)
            shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
        end
        return {shuffled = shuffled}
    end),
    run = function(state, case)
        local shuffled = state.shuffled
        local sum = 0
        for i = 1, case.params.count do
            local p = evo.get(shuffled[i], PositionE)
            sum = sum + p.x
        end
        return sum
    end,
}

evolvedScenarios.createWithComponents = {
    setup = function(case)
        local n = case.params.count
        evoPopulateBatchBench(n)
        local builder = evo.builder()
        builder:set(BatchPositionXE, 0)
        builder:set(BatchPositionYE, 0)
        builder:set(AliveE, true)
        return {builder = builder}
    end,
    run = function(state, case)
        local b = state.builder
        for _ = 1, case.params.count do b:build() end
    end,
    teardown = evoBatchBenchCleanup,
}

-- Single scenario for the four evolved batch-op variants.
evolvedScenarios.batchOp = {
    setup = function(case)
        evoPopulateBatchBench(case.params.count)
        return {query = QBatchPosition}
    end,
    run = function(state, case)
        local op = case.params.op
        if op == "setName" then
            evo.batch_set(state.query, BatchNameValueE, BATCH_NAME_MONSTER_E)
        elseif op == "removeVelocity" then
            evo.batch_remove(state.query, BatchVelocityXE, BatchVelocityYE)
        elseif op == "setAggro" then
            evo.batch_set(state.query, AggroE)
        elseif op == "removeAlive" then
            evo.batch_remove(state.query, AliveE)
        else
            error("batchOp: unknown op '" .. tostring(op) .. "'")
        end
    end,
    teardown = evoBatchBenchCleanup,
}

evolvedScenarios.deferMultiAdd = {
    setup = function(case)
        local n = case.params.count
        local entities = evoPopulate(n, {[PositionE] = true}, function(chunk, b, e)
            local ps = chunk:components(PositionE)
            for i = b, e do ps[i] = {x = i, y = i} end
        end)
        return {entities = entities, n = n}
    end,
    run = function(state)
        local entities = state.entities
        local n = state.n
        evo.defer()
        for i = 1, n do
            local e = entities[i]
            evo.set(e, VelocityE, {vx = 1, vy = 1})
            evo.set(e, HealthE, {hp = 100})
            evo.set(e, DamageE, {dmg = 10})
            evo.set(e, TagAE)
        end
        evo.commit()
    end,
    teardown = evoCleanup(QPosition),
}

-------------------------------------------------------------------------------
-- Variant adapter
-------------------------------------------------------------------------------

-- The harness calls measure() once per (variant, case) pair and loops
-- iterations internally with the case fixed. A variant adapter stashes the
-- current scenario in an upvalue at setup time, then dispatches teardown
-- through it even though the harness only passes `state`.
local function makeVariant(name, scenarios)
    local currentScenario
    return {
        name = name,
        setup = function(case)
            local s = scenarios[case.scenario]
            if not s then
                error("missing scenario '" .. tostring(case.scenario) .. "' for case: " .. case.name)
            end
            currentScenario = s
            return s.setup(case)
        end,
        run = function(state, case)
            currentScenario.run(state, case)
        end,
        teardown = function(state)
            if currentScenario and currentScenario.teardown then
                currentScenario.teardown(state)
            end
        end,
    }
end

bench.suite({
    name = "ECS benchmarks",
    warmupIterations = 50,
    minDuration = 0.5,
    baseline = "tecs",
    variants = {
        makeVariant("tecs", tecsScenarios),
        makeVariant("evolved", evolvedScenarios),
    },
    cases = cases,
})
