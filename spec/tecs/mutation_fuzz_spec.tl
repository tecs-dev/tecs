require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local WorldImpl <const> = require("tecs.internal.world")

--[[
Differential fuzz over the mutation model: the same seeded op sequence
runs against two worlds, one applying every op on the instant path and
one staging every op through defer/commit. After each block of ops the
canonical world states must match and both worlds must pass the
structural integrity validator.

Composite ops stage several mutations in ONE scope on the staged world
while the instant world applies them back to back; these hunt for
staging bugs that single ops cannot reach (remove-then-set self-moves,
despawn cancellation, staged-spawn mutation). The op universe also
covers sparse relationships (builtin ChildOf: exclusive, reverseIndex,
cascadeDelete), a dense exclusive reverse-indexed relationship, a
non-exclusive sparse reverse-indexed relationship (multi-target,
removeOne), an FFI component, Key claiming and release, spawnAt (fresh
high ids and dead-id revival), batchSpawn / batchSpawnAt with callback
fills, bundle spawns, batchSet / batchRemove / batchDespawn, TTL plus
world:update ticks, state push/pop (auto-tagging, despawn-on-exit
policy), clearEntities, compact, and mid-sequence snapshot save/load
round-trips. Even seeds install an OnSpawn observer actor that mutates
every third spawn (and forces the staged spawn regime); odd seeds keep
the instant paths hot. A query-callback ledger asserts added minus
removed equals the currently matching count per world, and each seed
ends with a snapshot fidelity check: table and binary saves restore
into fresh worlds with identical observable state, and a save of the
restored world round-trips stably.

Determinism rules: rng is consumed only OUTSIDE the shared op closure
(it runs once per world); component instances are constructed INSIDE
the closure so the two worlds never share a mutable value.

Id parity: ops address entities by id, so both worlds must allocate
identical ids. Row order inside an archetype is NOT part of the
observable contract and legitimately differs between instant and staged
execution, which reorders slot frees (despawns free in row order). The
harness therefore sorts both worlds' free stacks after every op: the
free SET must match (asserted at checkpoints; a mismatch is a slot
leak), while free ORDER is canonicalized so recycling stays in
lockstep.

Soak knobs: TECS_FUZZ_SEEDS and TECS_FUZZ_OPS deepen the run without
changing the fast defaults `cargo xtask test` uses, e.g.
`TECS_FUZZ_SEEDS=100 TECS_FUZZ_OPS=1000 cargo xtask test`.
TECS_FUZZ_SEED_OFFSET shifts the seed window so scheduled runs explore
fresh seeds each night; failure messages report the absolute seed, so
a red nightly reproduces locally with the same offset.
]]

local FUZZ_SEEDS <const> = (tonumber(os.getenv("TECS_FUZZ_SEEDS")) or 5) as integer
local FUZZ_OPS <const> = (tonumber(os.getenv("TECS_FUZZ_OPS")) or 200) as integer
local FUZZ_SEED_OFFSET <const> = (tonumber(os.getenv("TECS_FUZZ_SEED_OFFSET")) or 0) as integer
-- Debug knobs: checkpoint stride (1 pinpoints the diverging op) and an
-- op trace printed per step.
local FUZZ_CHECK_EVERY <const> = (tonumber(os.getenv("TECS_FUZZ_CHECK_EVERY")) or 25) as integer
local FUZZ_TRACE <const> = os.getenv("TECS_FUZZ_TRACE") ~= nil

-- Id packing mirrors IdAllocator: slot + generation * 2^22.
local GEN_STRIDE <const> = 4194304

local ChildOf <const> = tecs.ecs.ChildOf
local Key <const> = tecs.ecs.EntityKey
local Transform <const> = tecs.Transform

-- Fuzz components: one numeric field each so canonical state is cheap.
local FzA = tecs.ecs.newComponent(
    {
        name = "FuzzA",
        container = {},
        fields = {"v"},
        defaults = {0},
    }
)
local FzB = tecs.ecs.newComponent(
    {
        name = "FuzzB",
        container = {},
        fields = {"v"},
        defaults = {0},
    }
)
local FzHealth = tecs.ecs.newComponent(
    {
        name = "FuzzHealth",
        container = {},
        fields = {"v"},
        defaults = {100},
    }
)
local FzArmor = tecs.ecs.newComponent(
    {
        name = "FuzzArmor",
        container = {},
        fields = {"v"},
        defaults = {1},
        requires = {FzHealth},
    }
)
local FzTag = tecs.ecs.newTagComponent({name = "FuzzTag"})

-- FFI component: cdata columns through moves, batch bulk copies, and
-- snapshot memcpy paths.
local FzF = tecs.ecs.newFFIComponent(
    {
        name = "FuzzF",
        container = {},
        fields = {{"v", "double"}},
    }
)

-- Raw-value scalar columns; string scalars ride builtin Key.
local FzNum = tecs.ecs.newScalarComponent(
    {
        name = "FuzzNum",
        kind = "number",
        default = 0,
    }
)
local FzBool = tecs.ecs.newScalarComponent(
    {
        name = "FuzzBool",
        kind = "boolean",
        default = false,
    }
)

-- Dense exclusive reverse-indexed relationship (ChildOf covers the
-- sparse + cascadeDelete axis).
local FzLink = tecs.ecs.newRelationship(
    {
        name = "FuzzLink",
        exclusive = true,
        reverseIndex = true,
    }
)

-- Data-carrying dense relationship: payload fields ride the instance.
-- Dense instances are cached one per target (weak values), so the fuzz
-- always derives `w` from the target: a cache hit and a rebuilt
-- instance then agree, keeping both worlds and snapshot round-trips
-- deterministic.
local FzRope = tecs.ecs.newRelationship(
    {
        name = "FuzzRope",
        exclusive = true,
        reverseIndex = true,
        fields = {"w"},
    }
)

-- Non-exclusive sparse reverse-indexed relationship: multi-target
-- stores and the removeOne path. Transient: multi-target sparse stores
-- do not fit the snapshot row format (one value per entity/container),
-- so marks drop through snapshot round-trips in both worlds alike.
local FzMark = tecs.ecs.newRelationship(
    {
        name = "FuzzMark",
        sparse = true,
        reverseIndex = true,
        transient = true,
    }
)

-- Pre-register the state tag so `createState("fuzzState")` reuses one
-- global component across worlds and seeds.
local FzState = tecs.ecs.newTagComponent({name = "fuzzStateState"})
local TTL <const> = tecs.ecs.TTL

-- Ops draw from these; canonical reads also cover FzHealth (pulled in
-- via requires, never set directly).
local opComps: {tecs.ecs.Component} = {FzA, FzB, FzArmor, FzTag, FzF, FzNum, FzBool}
local readComps: {tecs.ecs.Component} = {FzA, FzB, FzArmor, FzHealth, FzTag, FzF, FzNum, FzBool}
local batchRemoveComps: {tecs.ecs.Component} = {FzB, FzTag, FzArmor, ChildOf, FzF, FzNum}
local batchSpawnSets: {{tecs.ecs.Component}} = {{FzA}, {FzA, FzTag}, {FzF, FzB}}

-- Park-Miller LCG: multiplier small enough that state * 16807 stays
-- exact in a double, so sequences reproduce everywhere.
local function newRng(seed: integer): function(integer): integer
    local state = seed % 2147483646 + 1
    return function(n: integer): integer state = (state * 16807) % 2147483647; return (state % n) + 1 end
end

local function instanceOf(compIdx: integer, value: integer): tecs.ecs.Component
    local comp = opComps[compIdx]
    if comp == FzTag then
        return FzTag
    end
    if comp == FzBool then
        return (FzBool as function(boolean): tecs.ecs.Component)(value % 2 == 0)
    end
    return (comp as function(integer): tecs.ecs.Component)(value)
end

local function validate(w: tecs.World)
    local wi = w as WorldImpl
    wi:_validateIntegrity()
end

-- Sort the allocator's free stack ascending. Free order is an
-- implementation detail; canonicalizing it keeps both worlds' slot
-- recycling in lockstep so entity ids stay comparable.
local function sortFreeStack(w: tecs.World)
    local alloc = (w as WorldImpl).allocator
    local n = alloc.freeCount
    if n < 2 then
        return
    end
    local stack = alloc.freeStack
    local tmp: {integer} = {}
    for i = 0, n - 1 do
        tmp[i + 1] = stack[i]
    end
    table.sort(tmp)
    for i = 0, n - 1 do
        stack[i] = tmp[i + 1]
    end
end

-- The allocator's observable shape (fresh cursor + freed-slot set), as
-- a string for checkpoint comparison. Call after sortFreeStack so equal
-- sets stringify identically.
local function freeSetString(w: tecs.World): string
    local alloc = (w as WorldImpl).allocator
    local parts: {string} = {"nf=" .. alloc.nextFreshSlot}
    for i = 0, alloc.freeCount - 1 do
        parts[#parts + 1] = tostring(alloc.freeStack[i])
    end
    return table.concat(parts, ",")
end

-- Canonical observable state: one sorted line per live entity listing
-- its id, component values, key, and relationship targets.
-- `skipTransient` omits transient pieces (FzMark) for comparisons
-- across a snapshot boundary, which legitimately drops them. `keep`
-- filters entities, mirroring a partial save's expected subset.
local function canonicalState(
    w: tecs.World, skipTransient?: boolean, keep?: function(tecs.World, integer): boolean
): string
    local lines: {string} = {}
    w:forEachArchetype(
        function(arch: tecs.ecs.Archetype)
            local entities = arch.entities
            for row = 1, entities[0] as integer do
                local id = entities[row] as integer
                if keep == nil or keep(w, id) then
                    local piece: {string} = {tostring(id)}
                    for c = 1, #readComps do
                        local comp = readComps[c]
                        if w:has(id, comp) then
                            if comp == FzTag then
                                piece[#piece + 1] = "Tag"
                            elseif comp == FzNum or comp == FzBool then
                                -- Scalar columns hold raw values.
                                piece[#piece + 1] = (comp as {string: any}).componentName as string
                                    .. "="
                                    .. tostring(w:get(id, comp))
                            else
                                local inst = w:get(id, comp) as {string: any}
                                piece[#piece + 1] = (comp as {string: any}).componentName as string
                                    .. "="
                                    .. tostring(inst.v)
                            end
                        end
                    end
                    if w:has(id, Key) then
                        piece[#piece + 1] = "Key=" .. tostring(w:get(id, Key))
                    end
                    local tr = w:get(id, Transform) as {string: any}
                    if tr then
                        piece[#piece + 1] = "T=" .. tostring(tr.x) .. ";" .. tostring(tr.y) .. ";" .. tostring(tr.layer)
                    end
                    -- Sparse targets read from the store; `has` reads the
                    -- archetype's container marker. Encode both so a
                    -- marker-vs-store divergence is visible at its origin.
                    if w:has(id, ChildOf) then
                        piece[#piece + 1] = "ChildOfMark"
                    end
                    local parent = w:getFirstRelationship(id, ChildOf)
                    if parent then
                        piece[#piece + 1] = "ChildOf=" .. tostring(parent.target)
                    end
                    if w:has(id, FzLink) then
                        piece[#piece + 1] = "LinkMark"
                    end
                    local link = w:getFirstRelationship(id, FzLink)
                    if link then
                        piece[#piece + 1] = "Link=" .. tostring(link.target)
                    end
                    if w:has(id, FzRope) then
                        piece[#piece + 1] = "RopeMark"
                    end
                    local rope = w:getFirstRelationship(id, FzRope)
                    if rope then
                        piece[#piece + 1] = "Rope="
                            .. tostring(rope.target)
                            .. ":"
                            .. tostring((rope as {string: any}).w)
                    end
                    if not skipTransient then
                        if w:has(id, FzMark) then
                            piece[#piece + 1] = "MarkMark"
                        end
                        local markSources: {string} = {}
                        w:targets(
                            id,
                            FzMark,
                            function(sourceId: integer, _ctx: nil)
                                markSources[#markSources + 1] = tostring(sourceId)
                            end,
                            nil
                        )
                        if #markSources > 0 then
                            table.sort(markSources)
                            piece[#piece + 1] = "MarkSrcs=" .. table.concat(markSources, ";")
                        end
                    end
                    if w:has(id, TTL) then
                        piece[#piece + 1] = "TTL=" .. tostring((w:get(id, TTL) as {string: any}).remaining)
                    end
                    if w:has(id, FzState) then
                        piece[#piece + 1] = "St"
                    end
                    lines[#lines + 1] = table.concat(piece, ",")
                end
            end
        end
    )
    table.sort(lines)
    return table.concat(lines, "\n")
end

local type OpFn = function(tecs.World): integer

-- Failure context for inline asserts (set by the main loop).
local curSeed = 0
local curStep = 0
local curOp = ""

-- Apply the same ops to both worlds: instant on `wa`, one staged scope
-- on `wb`. Spawning ops return the new id from each world; slot
-- allocation happens at call time on both paths so the ids must match.
local function bothWorlds(wa: tecs.World, wb: tecs.World, opsFn: OpFn): integer
    local ra = opsFn(wa)
    wb:defer()
    local rb = opsFn(wb)
    wb:commit()
    if ra ~= nil or rb ~= nil then
        luassert.equals(
            ra, rb, "spawned ids diverged between worlds at seed " .. curSeed .. " step " .. curStep .. " op " .. curOp
        )
    end
    return ra
end

local record FuzzOp
    weight: integer
    name: string
    run: function()
end

describe(
    "mutation differential fuzz",
    function()
        it(
            "instant and staged execution converge over random op sequences",
            function()
                for seedIndex = 1, FUZZ_SEEDS do
                    local seed = FUZZ_SEED_OFFSET + seedIndex
                    local rng = newRng(seed * 7919)
                    local wa = tecs.ecs.newWorld()
                    local wb = tecs.ecs.newWorld()
                    local alive: {integer} = {}
                    local dead: {integer} = {}
                    local keyN = 0
                    local statePushed = false

                    wa:newBundle("fuzzBundle", {required = {FzArmor}, with = {[FzB] = true}})
                    wb:newBundle("fuzzBundle", {required = {FzArmor}, with = {[FzB] = true}})
                    wa:createState("fuzzState")
                    wb:createState("fuzzState")

                    -- Observer actors on even seeds: an OnSpawn observer that
                    -- mutates a subset of spawned entities. Its presence also
                    -- forces every spawn through the staged route, so odd seeds
                    -- keep fuzzing the instant spawn paths. Two rules keep this
                    -- deterministic: never allocate inside an observer (a spawn
                    -- fires at different points on the two paths and desyncs
                    -- ids), and decide from the ENTITY ID, never from arrival
                    -- order (snapshot loads re-emit OnSpawn in row order, which
                    -- is not part of the observable contract).
                    if seed % 2 == 0 then
                        local function installSpawnObserver(w: tecs.World)
                            w:observe(
                                0,
                                tecs.ecs.OnSpawn,
                                function(ev: tecs.ecs.OnSpawn)
                                    if ev.entity % 3 == 0 then
                                        w:set(
                                            ev.entity,
                                            (FzB as function(integer): tecs.ecs.Component)(ev.entity % 997 + 1)
                                        )
                                    end
                                end
                            )
                        end
                        installSpawnObserver(wa)
                        installSpawnObserver(wb)
                    end

                    -- Query-callback ledger: per world, entities reported added
                    -- minus reported removed must equal the entities currently
                    -- matching. Note per-range counts are path-dependent (net-zero
                    -- composites fire no callbacks on the staged path), so only
                    -- this per-world ledger is a valid invariant.
                    local addedCount: {tecs.World: integer} = {[wa] = 0, [wb] = 0}
                    local removedCount: {tecs.World: integer} = {[wa] = 0, [wb] = 0}

                    -- Per-world persistent queries for the batch ops.
                    local function makeQueries(w: tecs.World): {string: tecs.Query}
                        return {
                            tag = w:query(
                                {
                                    include = {FzTag},
                                    onEntitiesAdded = function(
                                        _a: tecs.ecs.Archetype, _f: integer, _l: integer, count: integer
                                    )
                                        addedCount[w] = addedCount[w] + count
                                    end,
                                    onEntitiesRemoved = function(
                                        _a: tecs.ecs.Archetype, _f: integer, _l: integer, count: integer
                                    )
                                        removedCount[w] = removedCount[w] + count
                                    end,
                                }
                            ),
                            a = w:query({include = {FzA}}),
                        }
                    end
                    local qs: {tecs.World: {string: tecs.Query}} = {
                        [wa] = makeQueries(wa),
                        [wb] = makeQueries(wb),
                    }

                    local function countTagged(w: tecs.World): integer
                        local n = 0
                        for _arch, len in qs[w].tag:iter() do
                            n = n + len
                        end
                        return n
                    end

                    -- Wipe-style ops (clearEntities, in-place snapshot load) may
                    -- not notify removals for rows they drop; rebase the ledger
                    -- to the post-op reality.
                    local function rebaseLedger()
                        addedCount[wa] = countTagged(wa)
                        removedCount[wa] = 0
                        addedCount[wb] = countTagged(wb)
                        removedCount[wb] = 0
                    end

                    -- Pick a live entity, lazily purging entries killed by
                    -- cascades or batchDespawn into the dead list. Purging
                    -- depends only on state the two worlds share, so rng use
                    -- here stays deterministic.
                    local function pickAliveIdx(): integer
                        while #alive > 0 do
                            local idx = rng(#alive)
                            if wa:isAlive(alive[idx]) then
                                return idx
                            end
                            dead[#dead + 1] = alive[idx]
                            alive[idx] = alive[#alive]
                            alive[#alive] = nil
                        end
                        return nil
                    end

                    local function killEntry(idx: integer)
                        dead[#dead + 1] = alive[idx]
                        alive[idx] = alive[#alive]
                        alive[#alive] = nil
                    end

                    local ops: {FuzzOp} = {
                        {
                            weight = 10,
                            name = "spawn",
                            run = function()
                                local compIdx = rng(#opComps)
                                local v = rng(1000)
                                local id = bothWorlds(
                                    wa, wb, function(w: tecs.World): integer return w:spawn(instanceOf(compIdx, v)) end
                                )
                                alive[#alive + 1] = id
                            end,
                        },
                        {
                            weight = 10,
                            name = "set",
                            run = function()
                                local idx = pickAliveIdx()
                                if not idx then
                                    return
                                end
                                local id = alive[idx]
                                local compIdx = rng(#opComps)
                                local v = rng(1000)
                                bothWorlds(
                                    wa,
                                    wb,
                                    function(w: tecs.World): integer w:set(id, instanceOf(compIdx, v)); return nil end
                                )
                            end,
                        },
                        {
                            weight = 7,
                            name = "remove",
                            run = function()
                                local idx = pickAliveIdx()
                                if not idx then
                                    return
                                end
                                local id = alive[idx]
                                local compIdx = rng(#opComps)
                                bothWorlds(
                                    wa,
                                    wb,
                                    function(w: tecs.World): integer w:remove(id, opComps[compIdx]); return nil end
                                )
                            end,
                        },
                        {
                            weight = 6,
                            name = "despawn",
                            run = function()
                                local idx = pickAliveIdx()
                                if not idx then
                                    return
                                end
                                local id = alive[idx]
                                bothWorlds(wa, wb, function(w: tecs.World): integer w:despawn(id); return nil end)
                                killEntry(idx)
                            end,
                        },
                        {
                            weight = 6,
                            name = "remove-then-set, one scope",
                            run = function()
                                local idx = pickAliveIdx()
                                if not idx then
                                    return
                                end
                                local id = alive[idx]
                                local compIdx = rng(#opComps)
                                local v = rng(1000)
                                bothWorlds(
                                    wa,
                                    wb,
                                    function(w: tecs.World): integer
                                        w:remove(id, opComps[compIdx])
                                        w:set(id, instanceOf(compIdx, v))
                                        return nil
                                    end
                                )
                            end,
                        },
                        {
                            weight = 6,
                            name = "set-then-remove, one scope",
                            run = function()
                                local idx = pickAliveIdx()
                                if not idx then
                                    return
                                end
                                local id = alive[idx]
                                local compIdx = rng(#opComps)
                                local v = rng(1000)
                                bothWorlds(
                                    wa,
                                    wb,
                                    function(w: tecs.World): integer
                                        w:set(id, instanceOf(compIdx, v))
                                        w:remove(id, opComps[compIdx])
                                        return nil
                                    end
                                )
                            end,
                        },
                        {
                            weight = 3,
                            name = "repeated sets: last write wins",
                            run = function()
                                local idx = pickAliveIdx()
                                if not idx then
                                    return
                                end
                                local id = alive[idx]
                                local compIdx = rng(#opComps)
                                local v1 = rng(1000)
                                local v2 = rng(1000)
                                bothWorlds(
                                    wa,
                                    wb,
                                    function(w: tecs.World): integer
                                        w:set(id, instanceOf(compIdx, v1))
                                        w:set(id, instanceOf(compIdx, v2))
                                        return nil
                                    end
                                )
                            end,
                        },
                        {
                            weight = 5,
                            name = "spawn plus set on the new id, one scope",
                            run = function()
                                local compIdx = rng(#opComps)
                                local otherIdx = rng(#opComps)
                                local v0 = rng(1000)
                                local v = rng(1000)
                                local id = bothWorlds(
                                    wa,
                                    wb,
                                    function(w: tecs.World): integer
                                        local spawned = w:spawn(instanceOf(compIdx, v0))
                                        w:set(spawned, instanceOf(otherIdx, v))
                                        return spawned
                                    end
                                )
                                alive[#alive + 1] = id
                            end,
                        },
                        {
                            weight = 4,
                            name = "mutate then despawn, one scope",
                            run = function()
                                local idx = pickAliveIdx()
                                if not idx then
                                    return
                                end
                                local id = alive[idx]
                                local compIdx = rng(#opComps)
                                local v = rng(1000)
                                bothWorlds(
                                    wa,
                                    wb,
                                    function(w: tecs.World): integer
                                        w:set(id, instanceOf(compIdx, v))
                                        w:despawn(id)
                                        return nil
                                    end
                                )
                                killEntry(idx)
                            end,
                        },
                        {
                            weight = 2,
                            name = "dead-handle no-ops",
                            run = function()
                                if #dead == 0 then
                                    return
                                end
                                local id = dead[rng(#dead)]
                                local compIdx = rng(#opComps)
                                bothWorlds(
                                    wa,
                                    wb,
                                    function(w: tecs.World): integer
                                        w:remove(id, opComps[compIdx])
                                        w:despawn(id)
                                        return nil
                                    end
                                )
                            end,
                        },
                        {
                            weight = 8,
                            name = "set sparse ChildOf (exclusive replace)",
                            run = function()
                                -- Capture each id right after its pick: the second
                                -- pick can purge entries and shift indices.
                                local si = pickAliveIdx()
                                if not si then
                                    return
                                end
                                local src = alive[si]
                                local ti = pickAliveIdx()
                                if not ti then
                                    return
                                end
                                local tgt = alive[ti]
                                bothWorlds(
                                    wa, wb, function(w: tecs.World): integer w:set(src, ChildOf(tgt)); return nil end
                                )
                            end,
                        },
                        {
                            weight = 3,
                            name = "remove ChildOf, container or instance form",
                            run = function()
                                local si = pickAliveIdx()
                                if not si then
                                    return
                                end
                                local src = alive[si]
                                if rng(2) == 1 then
                                    bothWorlds(
                                        wa, wb, function(w: tecs.World): integer w:remove(src, ChildOf); return nil end
                                    )
                                else
                                    local rel = wa:getFirstRelationship(src, ChildOf)
                                    if rel == nil then
                                        return
                                    end
                                    local tgt = rel.target
                                    bothWorlds(
                                        wa,
                                        wb,
                                        function(w: tecs.World): integer w:remove(src, ChildOf(tgt)); return nil end
                                    )
                                end
                            end,
                        },
                        {
                            weight = 6,
                            name = "set dense FzLink (exclusive replace)",
                            run = function()
                                local si = pickAliveIdx()
                                if not si then
                                    return
                                end
                                local src = alive[si]
                                local ti = pickAliveIdx()
                                if not ti then
                                    return
                                end
                                local tgt = alive[ti]
                                bothWorlds(
                                    wa, wb, function(w: tecs.World): integer w:set(src, FzLink(tgt)); return nil end
                                )
                            end,
                        },
                        {
                            weight = 3,
                            name = "set data-carrying FzRope",
                            run = function()
                                local si = pickAliveIdx()
                                if not si then
                                    return
                                end
                                local src = alive[si]
                                local ti = pickAliveIdx()
                                if not ti then
                                    return
                                end
                                local tgt = alive[ti]
                                -- Payload derives from the target: dense instances
                                -- are cached per target, so any construction yields
                                -- the same payload deterministically.
                                local wv = tgt % 1000 + 1
                                bothWorlds(
                                    wa,
                                    wb,
                                    function(w: tecs.World): integer
                                        w:set(src, (FzRope as function(integer, integer): tecs.ecs.Component)(tgt, wv))
                                        return nil
                                    end
                                )
                            end,
                        },
                        {
                            weight = 2,
                            name = "remove FzRope instance",
                            run = function()
                                local si = pickAliveIdx()
                                if not si then
                                    return
                                end
                                local src = alive[si]
                                local rel = wa:getFirstRelationship(src, FzRope)
                                if rel == nil then
                                    return
                                end
                                local tgt = rel.target
                                local wv = tgt % 1000 + 1
                                bothWorlds(
                                    wa,
                                    wb,
                                    function(w: tecs.World): integer
                                        w:remove(
                                            src, (FzRope as function(integer, integer): tecs.ecs.Component)(tgt, wv)
                                        )
                                        return nil
                                    end
                                )
                            end,
                        },
                        {
                            weight = 3,
                            name = "set Transform with layer",
                            run = function()
                                local si = pickAliveIdx()
                                if not si then
                                    return
                                end
                                local id = alive[si]
                                local x = rng(1000)
                                local y = rng(1000)
                                local layer = rng(3)
                                bothWorlds(
                                    wa,
                                    wb,
                                    function(w: tecs.World): integer
                                        w:set(
                                            id,
                                            (
                                                Transform as function(
                                                    number, number, number, integer
                                                ): tecs.ecs.Component
                                            )(x, y, 0, layer)
                                        )
                                        return nil
                                    end
                                )
                            end,
                        },
                        {
                            weight = 3,
                            name = "remove dense FzLink instance",
                            run = function()
                                local si = pickAliveIdx()
                                if not si then
                                    return
                                end
                                local src = alive[si]
                                local rel = wa:getFirstRelationship(src, FzLink)
                                if rel == nil then
                                    return
                                end
                                local tgt = rel.target
                                bothWorlds(
                                    wa, wb, function(w: tecs.World): integer w:remove(src, FzLink(tgt)); return nil end
                                )
                            end,
                        },
                        {
                            weight = 4,
                            name = "spawn with a fresh unique Key",
                            run = function()
                                keyN = keyN + 1
                                local name = "fz" .. seed .. "_" .. keyN
                                local v = rng(1000)
                                local id = bothWorlds(
                                    wa, wb, function(w: tecs.World): integer return w:spawn(FzA(v), Key(name)) end
                                )
                                alive[#alive + 1] = id
                            end,
                        },
                        {
                            weight = 2,
                            name = "set a fresh Key on an existing entity",
                            run = function()
                                local idx = pickAliveIdx()
                                if not idx then
                                    return
                                end
                                keyN = keyN + 1
                                local name = "fz" .. seed .. "_" .. keyN
                                local id = alive[idx]
                                bothWorlds(
                                    wa, wb, function(w: tecs.World): integer w:set(id, Key(name)); return nil end
                                )
                            end,
                        },
                        {
                            weight = 2,
                            name = "remove Key",
                            run = function()
                                local idx = pickAliveIdx()
                                if not idx then
                                    return
                                end
                                local id = alive[idx]
                                bothWorlds(wa, wb, function(w: tecs.World): integer w:remove(id, Key); return nil end)
                            end,
                        },
                        {
                            weight = 3,
                            name = "spawnAt a fresh untouched slot",
                            run = function()
                                -- Slots at or above nextFreshSlot were never
                                -- allocated, so the id cannot collide with a live
                                -- entity; the allocators stay in lockstep so both
                                -- worlds derive the same slot. The small gap
                                -- exercises the fresh-range reconciliation.
                                local alloc = (wa as WorldImpl).allocator
                                local slot = alloc.nextFreshSlot + 7
                                if slot > alloc.maxSlotCount then
                                    return
                                end
                                local id = slot + GEN_STRIDE
                                local compIdx = rng(#opComps)
                                local v = rng(1000)
                                bothWorlds(
                                    wa,
                                    wb,
                                    function(w: tecs.World): integer
                                        w:spawnAt(id, instanceOf(compIdx, v))
                                        return nil
                                    end
                                )
                                alive[#alive + 1] = id
                            end,
                        },
                        {
                            weight = 2,
                            name = "spawnAt revives a dead id",
                            run = function()
                                if #dead == 0 then
                                    return
                                end
                                -- Only revive ids whose slot no other live entity
                                -- occupies; spawnAt on a live slot is caller error.
                                local usedSlots: {integer: boolean} = {}
                                for i = 1, #alive do
                                    usedSlots[alive[i] % GEN_STRIDE] = true
                                end
                                for _try = 1, 3 do
                                    local di = rng(#dead)
                                    local id = dead[di]
                                    if not usedSlots[id % GEN_STRIDE] then
                                        local compIdx = rng(#opComps)
                                        local v = rng(1000)
                                        bothWorlds(
                                            wa,
                                            wb,
                                            function(w: tecs.World): integer
                                                w:spawnAt(id, instanceOf(compIdx, v))
                                                return nil
                                            end
                                        )
                                        dead[di] = dead[#dead]
                                        dead[#dead] = nil
                                        alive[#alive + 1] = id
                                        return
                                    end
                                end
                            end,
                        },
                        {
                            weight = 3,
                            name = "batchSet constant form",
                            run = function()
                                local qk = rng(2) == 1 and "a" or "tag"
                                if rng(10) <= 7 then
                                    local v = rng(1000)
                                    bothWorlds(
                                        wa,
                                        wb,
                                        function(w: tecs.World): integer
                                            w:batchSet(qs[w][qk], (FzB as function(integer): tecs.ecs.Component)(v))
                                            return nil
                                        end
                                    )
                                else
                                    -- Sparse relationship constant: per-entity slow path.
                                    local ti = pickAliveIdx()
                                    if not ti then
                                        return
                                    end
                                    local tgt = alive[ti]
                                    bothWorlds(
                                        wa,
                                        wb,
                                        function(w: tecs.World): integer
                                            w:batchSet(qs[w][qk], ChildOf(tgt))
                                            return nil
                                        end
                                    )
                                end
                            end,
                        },
                        {
                            weight = 2,
                            name = "batchRemove",
                            run = function()
                                local qk = rng(2) == 1 and "a" or "tag"
                                local ci = rng(#batchRemoveComps)
                                bothWorlds(
                                    wa,
                                    wb,
                                    function(w: tecs.World): integer
                                        w:batchRemove(qs[w][qk], batchRemoveComps[ci])
                                        return nil
                                    end
                                )
                            end,
                        },
                        {
                            weight = 2,
                            name = "batchDespawn tagged entities",
                            run = function()
                                bothWorlds(
                                    wa, wb, function(w: tecs.World): integer w:batchDespawn(qs[w].tag); return nil end
                                )
                            end,
                        },
                        {
                            weight = 3,
                            name = "batchSpawn with callback fill",
                            run = function()
                                local n = rng(4)
                                local compSet = batchSpawnSets[rng(#batchSpawnSets)]
                                local v0 = rng(1000)
                                local function doBatch(w: tecs.World): {integer}
                                    local out: {integer} = {}
                                    local firstId, ids = w:batchSpawn(
                                        n,
                                        compSet,
                                        function(
                                            arch: tecs.ecs.Archetype, firstRow: integer, lastRow: integer, _c: integer
                                        )
                                            for ci = 1, #compSet do
                                                local comp = compSet[ci]
                                                if comp ~= FzTag then
                                                    local col = arch:getMut(comp)
                                                    for r = firstRow, lastRow do
                                                        col[r] = (comp as function(integer): tecs.ecs.Component)(
                                                            v0 + r - firstRow + ci
                                                        )
                                                    end
                                                end
                                            end
                                        end
                                    )
                                    if firstId then
                                        for i = 0, n - 1 do
                                            out[#out + 1] = firstId + i
                                        end
                                    else
                                        local list = ids as {integer}
                                        for i = 1, n do
                                            out[#out + 1] = list[i]
                                        end
                                    end
                                    return out
                                end
                                local ra = doBatch(wa)
                                wb:defer()
                                local rb = doBatch(wb)
                                wb:commit()
                                for i = 1, n do
                                    luassert.equals(ra[i], rb[i], "batchSpawn ids diverged, seed " .. seed)
                                    alive[#alive + 1] = ra[i]
                                end
                            end,
                        },
                        {
                            weight = 2,
                            name = "batchSpawnAt with fresh explicit ids",
                            run = function()
                                local alloc = (wa as WorldImpl).allocator
                                local base = alloc.nextFreshSlot + 11
                                local n = rng(3)
                                if base + n > alloc.maxSlotCount then
                                    return
                                end
                                local idsList: {integer} = {}
                                for i = 1, n do
                                    idsList[i] = (base + i) + GEN_STRIDE
                                end
                                local v0 = rng(1000)
                                local function doBatchAt(w: tecs.World)
                                    w:batchSpawnAt(
                                        idsList,
                                        {FzA},
                                        function(
                                            arch: tecs.ecs.Archetype, firstRow: integer, lastRow: integer, _c: integer
                                        )
                                            local col = arch:getMut(FzA)
                                            for r = firstRow, lastRow do
                                                col[r] = (FzA as function(integer): tecs.ecs.Component)(
                                                    v0 + r - firstRow
                                                )
                                            end
                                        end
                                    )
                                end
                                doBatchAt(wa)
                                wb:defer()
                                doBatchAt(wb)
                                wb:commit()
                                for i = 1, n do
                                    alive[#alive + 1] = idsList[i]
                                end
                            end,
                        },
                        {
                            weight = 3,
                            name = "bundle spawn",
                            run = function()
                                local v = rng(1000)
                                local id = bothWorlds(
                                    wa,
                                    wb,
                                    function(w: tecs.World): integer
                                        return w:spawnBundle(
                                            "fuzzBundle", (FzArmor as function(integer): tecs.ecs.Component)(v)
                                        )
                                    end
                                )
                                alive[#alive + 1] = id
                            end,
                        },
                        {
                            weight = 3,
                            name = "spawn with conflicting exclusive relationship args",
                            run = function()
                                local ti1 = pickAliveIdx()
                                if not ti1 then
                                    return
                                end
                                local t1 = alive[ti1]
                                local ti2 = pickAliveIdx()
                                if not ti2 then
                                    return
                                end
                                local t2 = alive[ti2]
                                local compIdx = rng(#opComps)
                                local v = rng(1000)
                                -- Exclusive FzLink passed twice: the later sibling
                                -- evicts the earlier one during spawn staging.
                                local id = bothWorlds(
                                    wa,
                                    wb,
                                    function(w: tecs.World): integer
                                        return w:spawn(instanceOf(compIdx, v), FzLink(t1), FzLink(t2), ChildOf(t1))
                                    end
                                )
                                alive[#alive + 1] = id
                            end,
                        },
                        {
                            weight = 4,
                            name = "add a non-exclusive sparse mark",
                            run = function()
                                local si = pickAliveIdx()
                                if not si then
                                    return
                                end
                                local src = alive[si]
                                local ti = pickAliveIdx()
                                if not ti then
                                    return
                                end
                                local tgt = alive[ti]
                                bothWorlds(
                                    wa, wb, function(w: tecs.World): integer w:set(src, FzMark(tgt)); return nil end
                                )
                            end,
                        },
                        {
                            weight = 2,
                            name = "remove one mark target",
                            run = function()
                                local si = pickAliveIdx()
                                if not si then
                                    return
                                end
                                local src = alive[si]
                                local rel = wa:getFirstRelationship(src, FzMark)
                                if rel == nil then
                                    return
                                end
                                local tgt = rel.target
                                bothWorlds(
                                    wa, wb, function(w: tecs.World): integer w:remove(src, FzMark(tgt)); return nil end
                                )
                            end,
                        },
                        {
                            weight = 1,
                            name = "remove all mark targets",
                            run = function()
                                local si = pickAliveIdx()
                                if not si then
                                    return
                                end
                                local src = alive[si]
                                bothWorlds(
                                    wa, wb, function(w: tecs.World): integer w:remove(src, FzMark); return nil end
                                )
                            end,
                        },
                        {
                            weight = 2,
                            name = "set a TTL",
                            run = function()
                                local si = pickAliveIdx()
                                if not si then
                                    return
                                end
                                local id = alive[si]
                                local ttl = rng(3) * 0.02
                                bothWorlds(wa, wb, function(w: tecs.World): integer w:set(id, TTL(ttl)); return nil end)
                            end,
                        },
                        {
                            weight = 3,
                            name = "frame tick: pipeline + TTL expiry",
                            run = function() local dt = rng(3) * 0.015; wa:update(dt); wb:update(dt) end,
                        },
                        {
                            weight = 2,
                            name = "state push/pop (auto-tag, despawn on exit)",
                            run = function()
                                if statePushed then
                                    wa:popState()
                                    wb:popState()
                                    statePushed = false
                                else
                                    wa:pushState("fuzzState")
                                    wb:pushState("fuzzState")
                                    statePushed = true
                                end
                            end,
                        },
                        {
                            weight = 1,
                            name = "clearEntities wipes both worlds",
                            run = function()
                                wa:clearEntities()
                                wb:clearEntities()
                                for i = #alive, 1, -1 do
                                    alive[i] = nil
                                end
                                for i = #dead, 1, -1 do
                                    dead[i] = nil
                                end
                                rebaseLedger()
                            end,
                        },
                        {weight = 1, name = "compact quiet worlds", run = function() wa:compact(); wb:compact() end},
                        {
                            weight = 1,
                            name = "snapshot save/load round-trip",
                            run = function()
                                local binary = rng(2) == 1
                                if binary then
                                    local outA = wa:saveSnapshot()
                                    wa:loadSnapshot(outA.buffer)
                                    local outB = wb:saveSnapshot()
                                    wb:loadSnapshot(outB.buffer)
                                else
                                    local outA = wa:saveSnapshot({format = "table"})
                                    wa:loadSnapshot(outA.snapshot)
                                    local outB = wb:saveSnapshot({format = "table"})
                                    wb:loadSnapshot(outB.snapshot)
                                end
                                rebaseLedger()
                            end,
                        },
                    }

                    local totalWeight = 0
                    for k = 1, #ops do
                        totalWeight = totalWeight + ops[k].weight
                    end

                    for step = 1, FUZZ_OPS do
                        local roll = rng(totalWeight)
                        local acc = 0
                        for k = 1, #ops do
                            acc = acc + ops[k].weight
                            if roll <= acc then
                                curSeed = seed
                                curStep = step
                                curOp = ops[k].name
                                if FUZZ_TRACE then
                                    print("fuzz seed " .. seed .. " step " .. step .. ": " .. ops[k].name)
                                end
                                ops[k].run()
                                break
                            end
                        end

                        sortFreeStack(wa)
                        sortFreeStack(wb)
                        luassert.equals(
                            freeSetString(wa),
                            freeSetString(wb),
                            "free slot sets diverged at seed " .. seed .. " step " .. step .. " op " .. curOp
                        )

                        if step % FUZZ_CHECK_EVERY == 0 then
                            luassert.equals(
                                canonicalState(wa),
                                canonicalState(wb),
                                "state diverged at seed " .. seed .. " step " .. step
                            )
                            luassert.equals(
                                freeSetString(wa),
                                freeSetString(wb),
                                "free slot sets diverged at seed " .. seed .. " step " .. step
                            )
                            luassert.equals(
                                countTagged(wa),
                                addedCount[wa] - removedCount[wa],
                                "callback ledger drifted in wa at seed " .. seed .. " step " .. step
                            )
                            luassert.equals(
                                countTagged(wb),
                                addedCount[wb] - removedCount[wb],
                                "callback ledger drifted in wb at seed " .. seed .. " step " .. step
                            )
                            validate(wa)
                            validate(wb)
                        end
                    end

                    luassert.equals(canonicalState(wa), canonicalState(wb), "final state diverged at seed " .. seed)
                    validate(wa)
                    validate(wb)

                    -- Snapshot fidelity: both formats restore into fresh worlds
                    -- with identical observable state (transient marks drop by
                    -- design), and a save of the restored world round-trips
                    -- stably. Also exercises state-stack restore when the seed
                    -- ends mid-push.
                    local want = canonicalState(wa, true)

                    local outTable = wa:saveSnapshot({format = "table"})
                    local freshTable = tecs.ecs.newWorld()
                    freshTable:createState("fuzzState")
                    freshTable:loadSnapshot(outTable.snapshot)
                    luassert.equals(want, canonicalState(freshTable, true), "table restore diverged, seed " .. seed)
                    validate(freshTable)

                    local outBinary = wa:saveSnapshot()
                    local freshBinary = tecs.ecs.newWorld()
                    freshBinary:createState("fuzzState")
                    freshBinary:loadSnapshot(outBinary.buffer)
                    luassert.equals(want, canonicalState(freshBinary, true), "binary restore diverged, seed " .. seed)
                    validate(freshBinary)

                    local resaved = freshTable:saveSnapshot()
                    local freshAgain = tecs.ecs.newWorld()
                    freshAgain:createState("fuzzState")
                    freshAgain:loadSnapshot(resaved.buffer)
                    luassert.equals(want, canonicalState(freshAgain, true), "re-save stability diverged, seed " .. seed)
                    validate(freshAgain)

                    -- Layer-filtered binary save restores exactly the matching
                    -- subset; entities without Transform always pass the filter.
                    local outLayers = wa:saveSnapshot({layers = {1, 3}})
                    local freshLayers = tecs.ecs.newWorld()
                    freshLayers:createState("fuzzState")
                    freshLayers:loadSnapshot(outLayers.buffer)
                    local wantLayers = canonicalState(
                        wa,
                        true,
                        function(w2: tecs.World, id: integer): boolean
                            local tr = w2:get(id, Transform) as {string: any}
                            if tr == nil then
                                return true
                            end
                            local layer = tr.layer as integer
                            return layer == 1 or layer == 3
                        end
                    )
                    luassert.equals(
                        wantLayers, canonicalState(freshLayers, true), "layer-filtered restore diverged, seed " .. seed
                    )
                    validate(freshLayers)

                    -- filterQuery save keeps only matching entities.
                    local outQuery = wa:saveSnapshot(
                        {
                            format = "table",
                            filterQuery = {include = {FzTag}},
                        }
                    )
                    local freshQuery = tecs.ecs.newWorld()
                    freshQuery:createState("fuzzState")
                    freshQuery:loadSnapshot(outQuery.snapshot)
                    local wantQuery = canonicalState(
                        wa, true, function(w2: tecs.World, id: integer): boolean return w2:has(id, FzTag) end
                    )
                    luassert.equals(
                        wantQuery, canonicalState(freshQuery, true), "filterQuery restore diverged, seed " .. seed
                    )
                    validate(freshQuery)
                end
            end
        )
    end
)
