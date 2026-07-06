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
cascadeDelete), a dense exclusive reverse-indexed relationship, Key
claiming and release, spawnAt (fresh high ids and dead-id revival),
batchSet / batchRemove / batchDespawn, and mid-sequence snapshot
save/load round-trips.

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
changing the fast defaults `make test` uses, e.g.
`TECS_FUZZ_SEEDS=100 TECS_FUZZ_OPS=1000 make test`.
]]

local FUZZ_SEEDS <const> = (tonumber(os.getenv("TECS_FUZZ_SEEDS")) or 5) as integer
local FUZZ_OPS <const> = (tonumber(os.getenv("TECS_FUZZ_OPS")) or 200) as integer

-- Id packing mirrors IdAllocator: slot + generation * 2^22.
local GEN_STRIDE <const> = 4194304

local ChildOf <const> = tecs.builtins.ChildOf
local Key <const> = tecs.builtins.Key

-- Fuzz components: one numeric field each so canonical state is cheap.
local FzA = tecs.newComponent({
    name = "FuzzA", container = {}, fields = {"v"}, defaults = {0},
})
local FzB = tecs.newComponent({
    name = "FuzzB", container = {}, fields = {"v"}, defaults = {0},
})
local FzHealth = tecs.newComponent({
    name = "FuzzHealth", container = {}, fields = {"v"}, defaults = {100},
})
local FzArmor = tecs.newComponent({
    name = "FuzzArmor", container = {}, fields = {"v"}, defaults = {1},
    requires = {FzHealth},
})
local FzTag = tecs.newTagComponent({ name = "FuzzTag" })

-- Dense exclusive reverse-indexed relationship (ChildOf covers the
-- sparse + cascadeDelete axis).
local FzLink = tecs.newRelationship({
    name = "FuzzLink",
    exclusive = true,
    reverseIndex = true,
})

-- Ops draw from these; canonical reads also cover FzHealth (pulled in
-- via requires, never set directly).
local opComps: {tecs.Component} = {FzA, FzB, FzArmor, FzTag}
local readComps: {tecs.Component} = {FzA, FzB, FzArmor, FzHealth, FzTag}
local batchRemoveComps: {tecs.Component} = {FzB, FzTag, FzArmor, ChildOf}

-- Park-Miller LCG: multiplier small enough that state * 16807 stays
-- exact in a double, so sequences reproduce everywhere.
local function newRng(seed: integer): function(integer): integer
    local state = seed % 2147483646 + 1
    return function(n: integer): integer
        state = (state * 16807) % 2147483647
        return (state % n) + 1
    end
end

local function instanceOf(compIdx: integer, value: integer): tecs.Component
    local comp = opComps[compIdx]
    if comp == FzTag then
        return FzTag
    end
    return (comp as function(integer): tecs.Component)(value)
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
    if n < 2 then return end
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
local function canonicalState(w: tecs.World): string
    local lines: {string} = {}
    w:forEachArchetype(function(arch: tecs.Archetype)
        local entities = arch.entities
        for row = 1, entities[0] as integer do
            local id = entities[row] as integer
            local piece: {string} = {tostring(id)}
            for c = 1, #readComps do
                local comp = readComps[c]
                if w:has(id, comp) then
                    if comp == FzTag then
                        piece[#piece + 1] = "Tag"
                    else
                        local inst = w:get(id, comp) as {string: any}
                        piece[#piece + 1] = (comp as {string: any}).componentName as string
                            .. "=" .. tostring(inst.v)
                    end
                end
            end
            if w:has(id, Key) then
                piece[#piece + 1] = "Key=" .. tostring(w:get(id, Key))
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
            lines[#lines + 1] = table.concat(piece, ",")
        end
    end)
    table.sort(lines)
    return table.concat(lines, "\n")
end

local type OpFn = function(tecs.World): integer

-- Apply the same ops to both worlds: instant on `wa`, one staged scope
-- on `wb`. Spawning ops return the new id from each world; slot
-- allocation happens at call time on both paths so the ids must match.
local function bothWorlds(wa: tecs.World, wb: tecs.World, opsFn: OpFn): integer
    local ra = opsFn(wa)
    wb:defer()
    local rb = opsFn(wb)
    wb:commit()
    if ra ~= nil or rb ~= nil then
        luassert.equals(ra, rb, "spawned ids diverged between worlds")
    end
    return ra
end

local record FuzzOp
    weight: integer
    run: function()
end

describe("mutation differential fuzz", function()
    it("instant and staged execution converge over random op sequences", function()
        for seed = 1, FUZZ_SEEDS do
            local rng = newRng(seed * 7919)
            local wa = tecs.newWorld()
            local wb = tecs.newWorld()
            local alive: {integer} = {}
            local dead: {integer} = {}
            local keyN = 0

            -- Per-world persistent queries for the batch ops.
            local qs: {tecs.World: {string: tecs.Query}} = {
                [wa] = {
                    tag = wa:query({ include = {FzTag} }),
                    a = wa:query({ include = {FzA} }),
                },
                [wb] = {
                    tag = wb:query({ include = {FzTag} }),
                    a = wb:query({ include = {FzA} }),
                },
            }

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
                { weight = 10, run = function()  -- spawn
                    local compIdx = rng(#opComps)
                    local v = rng(1000)
                    local id = bothWorlds(wa, wb, function(w: tecs.World): integer
                        return w:spawn(instanceOf(compIdx, v))
                    end)
                    alive[#alive + 1] = id
                end },
                { weight = 10, run = function()  -- set
                    local idx = pickAliveIdx()
                    if not idx then return end
                    local id = alive[idx]
                    local compIdx = rng(#opComps)
                    local v = rng(1000)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:set(id, instanceOf(compIdx, v))
                        return nil
                    end)
                end },
                { weight = 7, run = function()  -- remove
                    local idx = pickAliveIdx()
                    if not idx then return end
                    local id = alive[idx]
                    local compIdx = rng(#opComps)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:remove(id, opComps[compIdx])
                        return nil
                    end)
                end },
                { weight = 6, run = function()  -- despawn
                    local idx = pickAliveIdx()
                    if not idx then return end
                    local id = alive[idx]
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:despawn(id)
                        return nil
                    end)
                    killEntry(idx)
                end },
                { weight = 6, run = function()  -- remove-then-set, one scope
                    local idx = pickAliveIdx()
                    if not idx then return end
                    local id = alive[idx]
                    local compIdx = rng(#opComps)
                    local v = rng(1000)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:remove(id, opComps[compIdx])
                        w:set(id, instanceOf(compIdx, v))
                        return nil
                    end)
                end },
                { weight = 6, run = function()  -- set-then-remove, one scope
                    local idx = pickAliveIdx()
                    if not idx then return end
                    local id = alive[idx]
                    local compIdx = rng(#opComps)
                    local v = rng(1000)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:set(id, instanceOf(compIdx, v))
                        w:remove(id, opComps[compIdx])
                        return nil
                    end)
                end },
                { weight = 3, run = function()  -- repeated sets: last write wins
                    local idx = pickAliveIdx()
                    if not idx then return end
                    local id = alive[idx]
                    local compIdx = rng(#opComps)
                    local v1 = rng(1000)
                    local v2 = rng(1000)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:set(id, instanceOf(compIdx, v1))
                        w:set(id, instanceOf(compIdx, v2))
                        return nil
                    end)
                end },
                { weight = 5, run = function()  -- spawn plus set on the new id, one scope
                    local compIdx = rng(#opComps)
                    local otherIdx = rng(#opComps)
                    local v0 = rng(1000)
                    local v = rng(1000)
                    local id = bothWorlds(wa, wb, function(w: tecs.World): integer
                        local spawned = w:spawn(instanceOf(compIdx, v0))
                        w:set(spawned, instanceOf(otherIdx, v))
                        return spawned
                    end)
                    alive[#alive + 1] = id
                end },
                { weight = 4, run = function()  -- mutate then despawn, one scope
                    local idx = pickAliveIdx()
                    if not idx then return end
                    local id = alive[idx]
                    local compIdx = rng(#opComps)
                    local v = rng(1000)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:set(id, instanceOf(compIdx, v))
                        w:despawn(id)
                        return nil
                    end)
                    killEntry(idx)
                end },
                { weight = 2, run = function()  -- dead-handle no-ops
                    if #dead == 0 then return end
                    local id = dead[rng(#dead)]
                    local compIdx = rng(#opComps)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:remove(id, opComps[compIdx])
                        w:despawn(id)
                        return nil
                    end)
                end },
                { weight = 8, run = function()  -- set sparse ChildOf (exclusive replace)
                    -- Capture each id right after its pick: the second
                    -- pick can purge entries and shift indices.
                    local si = pickAliveIdx()
                    if not si then return end
                    local src = alive[si]
                    local ti = pickAliveIdx()
                    if not ti then return end
                    local tgt = alive[ti]
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:set(src, ChildOf(tgt))
                        return nil
                    end)
                end },
                { weight = 3, run = function()  -- remove ChildOf, container or instance form
                    local si = pickAliveIdx()
                    if not si then return end
                    local src = alive[si]
                    if rng(2) == 1 then
                        bothWorlds(wa, wb, function(w: tecs.World): integer
                            w:remove(src, ChildOf)
                            return nil
                        end)
                    else
                        local rel = wa:getFirstRelationship(src, ChildOf)
                        if rel == nil then return end
                        local tgt = rel.target
                        bothWorlds(wa, wb, function(w: tecs.World): integer
                            w:remove(src, ChildOf(tgt))
                            return nil
                        end)
                    end
                end },
                { weight = 6, run = function()  -- set dense FzLink (exclusive replace)
                    local si = pickAliveIdx()
                    if not si then return end
                    local src = alive[si]
                    local ti = pickAliveIdx()
                    if not ti then return end
                    local tgt = alive[ti]
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:set(src, FzLink(tgt))
                        return nil
                    end)
                end },
                { weight = 3, run = function()  -- remove dense FzLink instance
                    local si = pickAliveIdx()
                    if not si then return end
                    local src = alive[si]
                    local rel = wa:getFirstRelationship(src, FzLink)
                    if rel == nil then return end
                    local tgt = rel.target
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:remove(src, FzLink(tgt))
                        return nil
                    end)
                end },
                { weight = 4, run = function()  -- spawn with a fresh unique Key
                    keyN = keyN + 1
                    local name = "fz" .. seed .. "_" .. keyN
                    local v = rng(1000)
                    local id = bothWorlds(wa, wb, function(w: tecs.World): integer
                        return w:spawn(FzA(v), Key(name))
                    end)
                    alive[#alive + 1] = id
                end },
                { weight = 2, run = function()  -- set a fresh Key on an existing entity
                    local idx = pickAliveIdx()
                    if not idx then return end
                    keyN = keyN + 1
                    local name = "fz" .. seed .. "_" .. keyN
                    local id = alive[idx]
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:set(id, Key(name))
                        return nil
                    end)
                end },
                { weight = 2, run = function()  -- remove Key
                    local idx = pickAliveIdx()
                    if not idx then return end
                    local id = alive[idx]
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:remove(id, Key)
                        return nil
                    end)
                end },
                { weight = 3, run = function()  -- spawnAt a fresh untouched slot
                    -- Slots at or above nextFreshSlot were never
                    -- allocated, so the id cannot collide with a live
                    -- entity; the allocators stay in lockstep so both
                    -- worlds derive the same slot. The small gap
                    -- exercises the fresh-range reconciliation.
                    local alloc = (wa as WorldImpl).allocator
                    local slot = alloc.nextFreshSlot + 7
                    if slot >= alloc.maxSlotCount then return end
                    local id = slot + GEN_STRIDE
                    local compIdx = rng(#opComps)
                    local v = rng(1000)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:spawnAt(id, instanceOf(compIdx, v))
                        return nil
                    end)
                    alive[#alive + 1] = id
                end },
                { weight = 2, run = function()  -- spawnAt revives a dead id
                    if #dead == 0 then return end
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
                            bothWorlds(wa, wb, function(w: tecs.World): integer
                                w:spawnAt(id, instanceOf(compIdx, v))
                                return nil
                            end)
                            dead[di] = dead[#dead]
                            dead[#dead] = nil
                            alive[#alive + 1] = id
                            return
                        end
                    end
                end },
                { weight = 3, run = function()  -- batchSet constant form
                    local qk = rng(2) == 1 and "a" or "tag"
                    if rng(10) <= 7 then
                        local v = rng(1000)
                        bothWorlds(wa, wb, function(w: tecs.World): integer
                            w:batchSet(qs[w][qk], (FzB as function(integer): tecs.Component)(v))
                            return nil
                        end)
                    else
                        -- Sparse relationship constant: per-entity slow path.
                        local ti = pickAliveIdx()
                        if not ti then return end
                        local tgt = alive[ti]
                        bothWorlds(wa, wb, function(w: tecs.World): integer
                            w:batchSet(qs[w][qk], ChildOf(tgt))
                            return nil
                        end)
                    end
                end },
                { weight = 2, run = function()  -- batchRemove
                    local qk = rng(2) == 1 and "a" or "tag"
                    local ci = rng(#batchRemoveComps)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:batchRemove(qs[w][qk], batchRemoveComps[ci])
                        return nil
                    end)
                end },
                { weight = 2, run = function()  -- batchDespawn tagged entities
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:batchDespawn(qs[w].tag)
                        return nil
                    end)
                end },
                { weight = 1, run = function()  -- snapshot save/load round-trip
                    local binary = rng(2) == 1
                    if binary then
                        local outA = wa:saveSnapshot()
                        wa:loadSnapshot(outA.buffer)
                        local outB = wb:saveSnapshot()
                        wb:loadSnapshot(outB.buffer)
                    else
                        local outA = wa:saveSnapshot({ format = "table" })
                        wa:loadSnapshot(outA.snapshot)
                        local outB = wb:saveSnapshot({ format = "table" })
                        wb:loadSnapshot(outB.snapshot)
                    end
                end },
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
                        ops[k].run()
                        break
                    end
                end

                sortFreeStack(wa)
                sortFreeStack(wb)

                if step % 25 == 0 then
                    luassert.equals(canonicalState(wa), canonicalState(wb),
                        "state diverged at seed " .. seed .. " step " .. step)
                    luassert.equals(freeSetString(wa), freeSetString(wb),
                        "free slot sets diverged at seed " .. seed .. " step " .. step)
                    validate(wa)
                    validate(wb)
                end
            end

            luassert.equals(canonicalState(wa), canonicalState(wb),
                "final state diverged at seed " .. seed)
            validate(wa)
            validate(wb)
        end
    end)
end)
