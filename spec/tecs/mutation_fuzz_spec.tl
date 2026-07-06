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
despawn cancellation, staged-spawn mutation).

Soak knobs: TECS_FUZZ_SEEDS and TECS_FUZZ_OPS deepen the run without
changing the fast defaults `make test` uses, e.g.
`TECS_FUZZ_SEEDS=100 TECS_FUZZ_OPS=1000 make test`.
]]

local FUZZ_SEEDS <const> = (tonumber(os.getenv("TECS_FUZZ_SEEDS")) or 5) as integer
local FUZZ_OPS <const> = (tonumber(os.getenv("TECS_FUZZ_OPS")) or 200) as integer

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

-- Ops draw from these; canonical reads also cover FzHealth (pulled in
-- via requires, never set directly).
local opComps: {tecs.Component} = {FzA, FzB, FzArmor, FzTag}
local readComps: {tecs.Component} = {FzA, FzB, FzArmor, FzHealth, FzTag}

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

-- Canonical observable state: one sorted line per live entity listing
-- its id and component values.
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

describe("mutation differential fuzz", function()
    it("instant and staged execution converge over random op sequences", function()
        for seed = 1, FUZZ_SEEDS do
            local rng = newRng(seed * 7919)
            local wa = tecs.newWorld()
            local wb = tecs.newWorld()
            local alive: {integer} = {}
            local dead: {integer} = {}

            local function pickAlive(): integer
                return alive[rng(#alive)]
            end

            local function killEntry(idx: integer)
                dead[#dead + 1] = alive[idx]
                alive[idx] = alive[#alive]
                alive[#alive] = nil
            end

            for step = 1, FUZZ_OPS do
                local roll = rng(100)
                if #alive == 0 or roll <= 20 then
                    -- spawn
                    local compIdx = rng(#opComps)
                    local value = rng(1000)
                    local id = bothWorlds(wa, wb, function(w: tecs.World): integer
                        return w:spawn(instanceOf(compIdx, value))
                    end)
                    alive[#alive + 1] = id
                elseif roll <= 40 then
                    -- set
                    local id = pickAlive()
                    local compIdx = rng(#opComps)
                    local value = rng(1000)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:set(id, instanceOf(compIdx, value))
                        return nil
                    end)
                elseif roll <= 52 then
                    -- remove
                    local id = pickAlive()
                    local compIdx = rng(#opComps)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:remove(id, opComps[compIdx])
                        return nil
                    end)
                elseif roll <= 62 then
                    -- despawn
                    local idx = rng(#alive)
                    local id = alive[idx]
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:despawn(id)
                        return nil
                    end)
                    killEntry(idx)
                elseif roll <= 72 then
                    -- remove-then-set of the same component in one scope
                    local id = pickAlive()
                    local compIdx = rng(#opComps)
                    local value = rng(1000)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:remove(id, opComps[compIdx])
                        w:set(id, instanceOf(compIdx, value))
                        return nil
                    end)
                elseif roll <= 80 then
                    -- set-then-remove of the same component in one scope
                    local id = pickAlive()
                    local compIdx = rng(#opComps)
                    local value = rng(1000)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:set(id, instanceOf(compIdx, value))
                        w:remove(id, opComps[compIdx])
                        return nil
                    end)
                elseif roll <= 86 then
                    -- repeated sets: last write wins
                    local id = pickAlive()
                    local compIdx = rng(#opComps)
                    local v1 = rng(1000)
                    local v2 = rng(1000)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:set(id, instanceOf(compIdx, v1))
                        w:set(id, instanceOf(compIdx, v2))
                        return nil
                    end)
                elseif roll <= 93 then
                    -- spawn plus mutations on the new id in one scope
                    local compIdx = rng(#opComps)
                    local otherIdx = rng(#opComps)
                    local v0 = rng(1000)
                    local value = rng(1000)
                    local id = bothWorlds(wa, wb, function(w: tecs.World): integer
                        local spawned = w:spawn(instanceOf(compIdx, v0))
                        w:set(spawned, instanceOf(otherIdx, value))
                        return spawned
                    end)
                    alive[#alive + 1] = id
                elseif roll <= 97 then
                    -- mutate then despawn in one scope: despawn wins
                    local idx = rng(#alive)
                    local id = alive[idx]
                    local compIdx = rng(#opComps)
                    local value = rng(1000)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:set(id, instanceOf(compIdx, value))
                        w:despawn(id)
                        return nil
                    end)
                    killEntry(idx)
                elseif #dead > 0 then
                    -- dead-handle ops are no-ops on both paths
                    local id = dead[rng(#dead)]
                    local compIdx = rng(#opComps)
                    bothWorlds(wa, wb, function(w: tecs.World): integer
                        w:remove(id, opComps[compIdx])
                        w:despawn(id)
                        return nil
                    end)
                end

                if step % 25 == 0 then
                    luassert.equals(canonicalState(wa), canonicalState(wb),
                        "state diverged at seed " .. seed .. " step " .. step)
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
