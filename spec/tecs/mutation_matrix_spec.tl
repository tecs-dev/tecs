require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local WorldImpl <const> = require("tecs.internal.world")

-- Structural integrity check on the committed world; errors on violation.
local function validate(w: tecs.World)
    local wi = w as WorldImpl
    wi:_validateIntegrity()
end

--[[
Mutation mode matrix: every mutation execution path must converge on the
same observable post-commit state (docs/tecs/mutation-model.md). Each
scenario runs once per mode on a fresh world and asserts identical
results.
]]

-- Components exclusive to this spec to avoid cross-spec collisions.
local MatHealth = tecs.newComponent({
    name = "MatrixHealth",
    container = {},
    fields = {"hp"},
    defaults = {100},
})

local MatArmor = tecs.newComponent({
    name = "MatrixArmor",
    container = {},
    fields = {"ar"},
    defaults = {1},
    requires = {MatHealth},
})

local MatPos = tecs.newComponent({
    name = "MatrixPos",
    container = {},
    fields = {"x"},
    defaults = {0},
})

local MatVel = tecs.newComponent({
    name = "MatrixVel",
    container = {},
    fields = {"dx"},
    defaults = {0},
})

local MatMarker = tecs.newTagComponent({name = "MatrixMarker"})
local MatBatchTag = tecs.newTagComponent({name = "MatrixBatchTag"})

-- Dense exclusive reverse-indexed relationship (compact FFI layout).
local MatLink = tecs.newRelationship({
    name = "MatrixLink",
    exclusive = true,
    reverseIndex = true,
})

local type Ops = function(tecs.World)

local record Mode
    name: string
    run: function(tecs.World, Ops)
end

-- Execution contexts. "instant" applies at depth 0; the others stage
-- through a scope (explicit, query iteration, observer dispatch).
local modes: {Mode} = {
    {
        name = "instant",
        run = function(w: tecs.World, ops: Ops) ops(w) end,
    },
    {
        name = "defer/commit",
        run = function(w: tecs.World, ops: Ops) w:defer(); ops(w); w:commit() end,
    },
    {
        name = "query iteration",
        run = function(w: tecs.World, ops: Ops)
            w:spawn(MatMarker)
            local q = w:query({include = {MatMarker}})
            for _arch, _len in q:iter() do
                ops(w)
            end
        end,
    },
    {
        name = "observer",
        run = function(w: tecs.World, ops: Ops)
            local ran = false
            w:observe(
                0,
                tecs.builtins.OnSpawn,
                function(_ev: tecs.builtins.OnSpawn)
                    if not ran then
                        ran = true
                        ops(w)
                    end
                end
            )
            w:spawn(MatMarker)
        end,
    },
}

-- Run one scenario across every mode: fresh world, setup returns the
-- subject entity, ops mutates it inside the mode's context, verify
-- asserts the post-commit state. `mode` names the failing context.
local function forEachMode(
    setup: function(tecs.World): integer,
    ops: function(tecs.World, integer),
    verify: function(tecs.World, integer, string)
)
    for i = 1, #modes do
        local mode = modes[i]
        local w = tecs.newWorld()
        local e = setup(w)
        mode.run(w, function(world: tecs.World) ops(world, e) end)
        validate(w)
        verify(w, e, mode.name)
    end
end

local function countMatching(w: tecs.World, component: tecs.Component): integer
    local q = w:query({include = {component}})
    local n = 0
    for _arch, len in q:iter() do
        n = n + len
    end
    return n
end

describe(
    "mutation mode matrix",
    function()
        it(
            "set applies the requires closure in every mode",
            function()
                forEachMode(function(w: tecs.World): integer return w:spawn(MatPos(1)) end, function(
                    w: tecs.World, e: integer
                )
                    w:set(e, MatArmor(5))
                end,
                function(w: tecs.World, e: integer, mode: string)
                    luassert.is_true(w:has(e, MatArmor), "armor present, mode: " .. mode)
                    luassert.equals(5, w:get(e, MatArmor).ar, "armor value, mode: " .. mode)
                    luassert.is_true(w:has(e, MatHealth), "required health present, mode: " .. mode)
                    luassert.equals(100, w:get(e, MatHealth).hp, "required default, mode: " .. mode)
                end)
            end
        )

        it(
            "remove-then-set of one component converges in every mode",
            function()
                forEachMode(function(w: tecs.World): integer return w:spawn(MatPos(1)) end, function(
                    w: tecs.World, e: integer
                )
                    w:remove(e, MatPos)
                    w:set(e, MatPos(8))
                end,
                function(w: tecs.World, e: integer, mode: string)
                    luassert.is_true(w:isAlive(e), "alive, mode: " .. mode)
                    luassert.is_true(w:has(e, MatPos), "has, mode: " .. mode)
                    luassert.equals(8, w:get(e, MatPos).x, "value, mode: " .. mode)
                    luassert.equals(1, countMatching(w, MatPos), "queryable, mode: " .. mode)
                end)
            end
        )

        it(
            "set-then-remove leaves the component absent in every mode",
            function()
                forEachMode(function(w: tecs.World): integer return w:spawn(MatPos(1)) end, function(
                    w: tecs.World, e: integer
                )
                    w:set(e, MatVel(9))
                    w:remove(e, MatVel)
                end,
                function(w: tecs.World, e: integer, mode: string)
                    luassert.is_false(w:has(e, MatVel), "removed, mode: " .. mode)
                    luassert.is_true(w:has(e, MatPos), "untouched survives, mode: " .. mode)
                    luassert.equals(1, w:get(e, MatPos).x, "untouched value, mode: " .. mode)
                end)
            end
        )

        it(
            "last write wins in every mode",
            function()
                forEachMode(function(w: tecs.World): integer return w:spawn(MatPos(1)) end, function(
                    w: tecs.World, e: integer
                )
                    w:set(e, MatPos(2))
                    w:set(e, MatVel(9))
                    w:set(e, MatPos(3))
                    w:set(e, MatPos(4))
                end,
                function(w: tecs.World, e: integer, mode: string)
                    luassert.equals(4, w:get(e, MatPos).x, "last set wins, mode: " .. mode)
                    luassert.equals(9, w:get(e, MatVel).dx, "structural add value, mode: " .. mode)
                end)
            end
        )

        it(
            "despawn cancels staged operations in every mode",
            function()
                forEachMode(function(w: tecs.World): integer return w:spawn(MatPos(1)) end, function(
                    w: tecs.World, e: integer
                )
                    w:set(e, MatVel(9))
                    w:despawn(e)
                end,
                function(w: tecs.World, e: integer, mode: string)
                    luassert.is_false(w:isAlive(e), "despawned, mode: " .. mode)
                    luassert.is_nil(w:get(e, MatPos), "no reads, mode: " .. mode)
                end)
            end
        )

        it(
            "explicit values for required components win over defaults in every mode",
            function()
                for i = 1, #modes do
                    local mode = modes[i]
                    local w = tecs.newWorld()
                    local id: integer = nil
                    mode.run(w, function(world: tecs.World) id = world:spawn(MatArmor(5), MatHealth(50)) end)
                    luassert.equals(50, w:get(id, MatHealth).hp, "mode: " .. mode.name)
                    luassert.equals(5, w:get(id, MatArmor).ar, "mode: " .. mode.name)
                end
            end
        )

        it(
            "bundle spawn converges in every mode",
            function()
                for i = 1, #modes do
                    local mode = modes[i]
                    local w = tecs.newWorld()
                    w:newBundle("matrixModes", {required = {MatArmor}})
                    local id: integer = nil
                    mode.run(w, function(world: tecs.World) id = world:spawnBundle("matrixModes", MatArmor(3)) end)
                    luassert.is_true(w:isAlive(id), "alive, mode: " .. mode.name)
                    luassert.equals(3, w:get(id, MatArmor).ar, "value, mode: " .. mode.name)
                    luassert.equals(100, w:get(id, MatHealth).hp, "required default, mode: " .. mode.name)
                end
            end
        )
    end
)

describe(
    "batchSet requires closure",
    function()
        it(
            "constant form pulls required components into the transition",
            function()
                local w = tecs.newWorld()
                local e = w:spawn(MatBatchTag)
                local q = w:query({include = {MatBatchTag}})
                w:batchSet(q, MatArmor(2))
                luassert.is_true(w:has(e, MatArmor))
                luassert.equals(2, w:get(e, MatArmor).ar)
                luassert.is_true(w:has(e, MatHealth))
                luassert.equals(100, w:get(e, MatHealth).hp)
                validate(w)
            end
        )

        it(
            "callback form pulls required components into the transition",
            function()
                local w = tecs.newWorld()
                local e = w:spawn(MatBatchTag)
                local q = w:query({include = {MatBatchTag}})
                w:batchSet(
                    q,
                    MatArmor,
                    function(arch: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
                        local col = arch:getMut(MatArmor)
                        for r = firstRow, lastRow do
                            col[r] = MatArmor(9)
                        end
                    end
                )
                luassert.equals(9, w:get(e, MatArmor).ar)
                luassert.is_true(w:has(e, MatHealth))
                luassert.equals(100, w:get(e, MatHealth).hp)
                validate(w)
            end
        )
    end
)

describe(
    "required-default ordering",
    function()
        it(
            "batch spawn callback values win over required defaults",
            function()
                local w = tecs.newWorld()
                local firstId = w:batchSpawn(
                    2,
                    {MatArmor, MatHealth},
                    function(arch: tecs.Archetype, firstRow: integer, lastRow: integer, _count: integer)
                        local armor = arch:getMut(MatArmor)
                        local health = arch:getMut(MatHealth)
                        for r = firstRow, lastRow do
                            armor[r] = MatArmor(5)
                            health[r] = MatHealth(50)
                        end
                    end
                )
                luassert.equals(50, w:get(firstId, MatHealth).hp)
                luassert.equals(50, w:get(firstId + 1, MatHealth).hp)
                validate(w)
            end
        )

        it(
            "bundle values win over required defaults, instant and staged",
            function()
                local w = tecs.newWorld()
                w:newBundle("matrixReqOrder", {required = {MatArmor, MatHealth}})

                local id = w:spawnBundle("matrixReqOrder", MatArmor(5), MatHealth(50))
                luassert.equals(50, w:get(id, MatHealth).hp)

                w:defer()
                local id2 = w:spawnBundle("matrixReqOrder", MatArmor(6), MatHealth(60))
                w:commit()
                luassert.equals(60, w:get(id2, MatHealth).hp)
                validate(w)
            end
        )
    end
)

describe(
    "bundle spawn parity",
    function()
        it(
            "claims Key and rejects duplicate live keys",
            function()
                local w = tecs.newWorld()
                w:newBundle("matrixKeyed", {required = {tecs.builtins.Key, MatPos}})

                local id = w:spawnBundle("matrixKeyed", tecs.builtins.Key("matrixHero"), MatPos(3))
                luassert.equals(id, w:byKey("matrixHero"))
                luassert.equals(3, w:get(id, MatPos).x)

                local ok = pcall(function()
                    w:spawnBundle("matrixKeyed", tecs.builtins.Key("matrixHero"), MatPos(4))
                end)
                luassert.is_false(ok, "duplicate live key must error")

                -- Despawn releases the key for reclaiming.
                w:despawn(id)
                luassert.is_nil(w:byKey("matrixHero"))
                local id2 = w:spawnBundle("matrixKeyed", tecs.builtins.Key("matrixHero"), MatPos(5))
                luassert.equals(id2, w:byKey("matrixHero"))
                validate(w)
            end
        )

        it(
            "emits OnSpawn with staged-entity semantics on the instant path",
            function()
                local w = tecs.newWorld()
                w:newBundle("matrixPlain", {required = {MatPos}})

                local seen: {integer} = {}
                local aliveDuring: boolean = true
                w:observe(
                    0,
                    tecs.builtins.OnSpawn,
                    function(ev: tecs.builtins.OnSpawn)
                        seen[#seen + 1] = ev.entity
                        aliveDuring = w:isAlive(ev.entity)
                        -- Observer mutations stage against the pending entity.
                        w:set(ev.entity, MatVel(7))
                    end
                )

                local id = w:spawnBundle("matrixPlain", MatPos(1))
                luassert.equals(1, #seen)
                luassert.equals(id, seen[1])
                luassert.is_false(aliveDuring, "entity staged while OnSpawn fires")
                luassert.is_true(w:isAlive(id), "committed after the call returns")
                luassert.equals(1, w:get(id, MatPos).x)
                luassert.equals(7, w:get(id, MatVel).dx, "observer-staged set applied")
                validate(w)
            end
        )

        it(
            "emits OnSpawn at stage time inside a scope",
            function()
                local w = tecs.newWorld()
                w:newBundle("matrixPlain2", {required = {MatPos}})

                local seen = 0
                w:observe(0, tecs.builtins.OnSpawn, function(_ev: tecs.builtins.OnSpawn) seen = seen + 1 end)

                w:defer()
                local id = w:spawnBundle("matrixPlain2", MatPos(2))
                luassert.equals(1, seen, "emitted while staged")
                luassert.is_false(w:isAlive(id), "not alive until commit")
                w:commit()
                luassert.is_true(w:isAlive(id))
                luassert.equals(2, w:get(id, MatPos).x)
                validate(w)
            end
        )
    end
)

describe(
    "relationship and snapshot path parity",
    function()
        it(
            "instant set of a dense relationship instance adds the wildcard container",
            function()
                local w = tecs.newWorld()
                local target = w:spawn(MatPos(1))
                local e = w:spawn(MatPos(2))
                w:set(e, MatLink(target))
                luassert.is_true(w:has(e, MatLink), "container marker present on the instant path")
                luassert.equals(target, w:getFirstRelationship(e, MatLink).target)

                local w2 = tecs.newWorld()
                local target2 = w2:spawn(MatPos(1))
                local e2 = w2:spawn(MatPos(2))
                w2:defer()
                w2:set(e2, MatLink(target2))
                w2:commit()
                luassert.is_true(w2:has(e2, MatLink), "staged path agrees")
                validate(w)
                validate(w2)
            end
        )

        it(
            "instant despawn of a sparse relationship source cleans the store",
            function()
                local w = tecs.newWorld()
                local parent = w:spawn(MatPos(1))
                local child = w:spawn(MatPos(2))
                w:set(child, tecs.builtins.ChildOf(parent))

                -- The child is a source, not a target: its despawn takes the
                -- instant path and must still drop its store entry and
                -- reverse-index link.
                w:despawn(child)
                local sources = 0
                w:targets(
                    parent, tecs.builtins.ChildOf, function(_id: integer, _ctx: nil) sources = sources + 1 end, nil
                )
                luassert.equals(0, sources, "reverse index cleaned")

                -- The recycled slot must not inherit the phantom relationship.
                local recycled = w:spawn(MatPos(3))
                luassert.is_nil(w:getFirstRelationship(recycled, tecs.builtins.ChildOf))
                validate(w)
            end
        )

        it(
            "bulk batch moves copy dense FFI relationship instance columns",
            function()
                local w = tecs.newWorld()
                local target = w:spawn(MatPos(1))
                -- Two batches into the same source archetype so the second
                -- batchSet takes the non-empty-destination copy branch.
                local a = w:spawn(MatBatchTag)
                w:set(a, MatLink(target))
                w:set(a, MatVel(1))
                local b = w:spawn(MatBatchTag)
                w:set(b, MatLink(target))

                local q = w:query({include = {MatBatchTag}})
                w:batchSet(q, MatPos(5))

                luassert.equals(5, w:get(a, MatPos).x)
                luassert.equals(5, w:get(b, MatPos).x)
                luassert.equals(target, w:getFirstRelationship(a, MatLink).target, "link survives bulk move")
                luassert.equals(target, w:getFirstRelationship(b, MatLink).target, "link survives bulk move")
                validate(w)
            end
        )

        it(
            "row-major snapshot round-trips scalar values on sparse-marker archetypes",
            function()
                local w = tecs.newWorld()
                local parent = w:spawn(MatPos(1))
                local e = w:spawn(MatPos(2))
                w:set(e, tecs.builtins.ChildOf(parent))
                w:set(e, tecs.builtins.Key("matrixRowMajor"))

                -- Binary form (crashed before the writer fix).
                local out = w:saveSnapshot()
                w:loadSnapshot(out.buffer)
                luassert.equals("matrixRowMajor", w:get(e, tecs.builtins.Key))
                luassert.equals(e, w:byKey("matrixRowMajor"))
                luassert.equals(parent, w:getFirstRelationship(e, tecs.builtins.ChildOf).target)

                -- Table form (silently dropped the Key before the fix).
                local out2 = w:saveSnapshot({format = "table"})
                w:loadSnapshot(out2.snapshot)
                luassert.equals("matrixRowMajor", w:get(e, tecs.builtins.Key))
                luassert.equals(e, w:byKey("matrixRowMajor"))
                luassert.equals(parent, w:getFirstRelationship(e, tecs.builtins.ChildOf).target)
                validate(w)
            end
        )
    end
)

describe(
    "sparse relationship store hygiene",
    function()
        local MatMark = tecs.newRelationship({
            name = "MatrixMark",
            sparse = true,
            reverseIndex = true,
            transient = true,
        })

        it(
            "batchDespawn's bulk path cleans source store entries",
            function()
                local w = tecs.newWorld()
                local target = w:spawn(MatPos(1))
                local src = w:spawn(MatBatchTag)
                w:set(src, MatMark(target))

                local q = w:query({include = {MatBatchTag}})
                w:batchDespawn(q)
                luassert.is_false(w:isAlive(src))

                local sources = 0
                w:targets(target, MatMark, function(_id: integer, _ctx: nil) sources = sources + 1 end, nil)
                luassert.equals(0, sources, "reverse index cleaned by bulk clear")
                validate(w)
            end
        )

        it(
            "getFirstRelationship returns an instance for multi-target sparse stores",
            function()
                local w = tecs.newWorld()
                local t1 = w:spawn(MatPos(1))
                local t2 = w:spawn(MatPos(2))
                local src = w:spawn(MatPos(3))
                w:set(src, MatMark(t1))
                w:set(src, MatMark(t2))

                local rel = w:getFirstRelationship(src, MatMark)
                luassert.is_not_nil(rel)
                local tgt = rel.target
                luassert.is_true(tgt == t1 or tgt == t2, "instance with a real target, not the store map")
                validate(w)
            end
        )
    end
)
