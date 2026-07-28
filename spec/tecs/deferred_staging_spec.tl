require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

-- Components exclusive to this spec to avoid cross-spec collisions.
local Shared = tecs.newComponent({
    name = "DeferStageShared",
    container = {},
    fields = {"v"},
    defaults = {0},
})

local Extra = tecs.newComponent({
    name = "DeferStageExtra",
    container = {},
    fields = {"e"},
    defaults = {0},
})

local Absent = tecs.newComponent({
    name = "DeferStageAbsent",
    container = {},
    fields = {"a"},
    defaults = {0},
})

describe(
    "deferred staging",
    function()
        describe(
            "set-path column cache",
            function()
                it(
                    "routes a set correctly after a remove touched another archetype",
                    function()
                        local w = tecs.newWorld()
                        -- e1 lives in archetype {Shared}; e2 in archetype {Shared, Extra}.
                        local e1 = w:spawn(Shared(11))
                        local e2 = w:spawn(Shared(22), Extra(1))
                        w:commit()

                        w:defer()
                        -- Caches ( {Shared} archetype, Shared, its column ).
                        w:set(e1, Shared(100))
                        -- Remove of a component e2's archetype lacks; must not pair the
                        -- {Shared, Extra} archetype with the cached {Shared} column.
                        w:remove(e2, Absent)
                        -- Same-archetype value update for e2.
                        w:set(e2, Shared(200))
                        w:commit()

                        luassert.equals(100, w:get(e1, Shared).v)
                        luassert.equals(200, w:get(e2, Shared).v)
                    end
                )

                it(
                    "routes a set correctly after a remove staged a structural move",
                    function()
                        local w = tecs.newWorld()
                        local e1 = w:spawn(Shared(11))
                        local e2 = w:spawn(Shared(22), Extra(1))
                        w:commit()

                        w:defer()
                        w:set(e1, Shared(100))
                        -- Structural remove staging a move out of {Shared, Extra}.
                        w:remove(e2, Extra)
                        w:set(e2, Shared(200))
                        w:commit()

                        luassert.equals(100, w:get(e1, Shared).v)
                        luassert.equals(200, w:get(e2, Shared).v)
                        luassert.is_nil(w:get(e2, Extra))
                    end
                )
            end
        )

        describe(
            "pendingWrites accounting",
            function()
                local WorldImpl <const> = require("tecs.internal.world")

                -- pendingWrites reserves destination capacity for staged moves of
                -- committed entities; after a commit every counter must be zero.
                local function assertSettled(w: tecs.World)
                    local idx = (w as WorldImpl).archetypeIndex as {any: any}
                    for i = 1, idx.maxId as integer do
                        local arch = idx[i]
                        if arch then
                            local pw = (arch as {any: any}).pendingWrites as integer
                            luassert.equals(0, pw, "pendingWrites settled for archetype " .. i)
                        end
                    end
                end

                it(
                    "settles after deferred spawns",
                    function()
                        local w = tecs.newWorld()
                        w:defer()
                        for i = 1, 50 do
                            w:spawn(Shared(i))
                        end
                        w:commit()
                        assertSettled(w)
                    end
                )

                it(
                    "settles after a committed move",
                    function()
                        local w = tecs.newWorld()
                        local e = w:spawn(Shared(1))
                        w:commit()

                        w:defer()
                        w:set(e, Extra(2))
                        w:commit()

                        luassert.equals(2, w:get(e, Extra).e)
                        assertSettled(w)
                    end
                )

                it(
                    "settles when a staged spawn migrates and despawns",
                    function()
                        local w = tecs.newWorld()
                        w:defer()
                        local id = w:spawn(Shared(1))
                        w:set(id, Extra(2))
                        w:despawn(id)
                        w:commit()

                        luassert.is_false(w:isAlive(id))
                        assertSettled(w)
                    end
                )

                it(
                    "settles when a committed staged move despawns",
                    function()
                        local w = tecs.newWorld()
                        local e = w:spawn(Shared(1))
                        w:commit()

                        w:defer()
                        w:set(e, Extra(2))
                        w:despawn(e)
                        w:commit()

                        luassert.is_false(w:isAlive(e))
                        assertSettled(w)
                    end
                )

                it(
                    "settles when a batch-spawned entity is removed in the same scope",
                    function()
                        local w = tecs.newWorld()
                        w:defer()
                        local firstId = w:batchSpawn(10, {Shared}, function(_arch, _first, _last, _count) end)
                        luassert.is_not_nil(firstId)
                        w:remove(firstId as integer, Shared)
                        w:commit()
                        assertSettled(w)
                    end
                )

                it(
                    "tolerates repeated sets on a batch-staged id",
                    function()
                        local w = tecs.newWorld()
                        w:defer()
                        local firstId = w:batchSpawn(
                            5,
                            {Shared},
                            function(arch: tecs.Archetype, first: integer, last: integer, _count: integer)
                                local col = arch:getMut(Shared)
                                for r = first, last do
                                    col[r] = Shared(r)
                                end
                            end
                        )
                        local id = firstId as integer
                        -- The second set promotes the staged id through the pending-arch
                        -- branch, which has no committed source archetype.
                        w:set(id, Extra(1))
                        w:set(id, Extra(2))
                        w:commit()

                        luassert.is_true(w:isAlive(id))
                        luassert.is_not_nil(w:get(id, Shared))
                        assertSettled(w)
                    end
                )

                it(
                    "settles across repeated spawn scopes into one archetype",
                    function()
                        local w = tecs.newWorld()
                        for _ = 1, 5 do
                            w:defer()
                            for i = 1, 20 do
                                w:spawn(Shared(i), Extra(i))
                            end
                            w:commit()
                        end
                        assertSettled(w)

                        -- A later move into the same archetype must still settle.
                        local e = w:spawn(Shared(0))
                        w:commit()
                        w:defer()
                        w:set(e, Extra(1))
                        w:commit()
                        luassert.equals(1, w:get(e, Extra).e)
                        assertSettled(w)
                    end
                )
            end
        )

        describe(
            "drain ordering",
            function()
                it(
                    "re-entrant despawn from a deferred OnDespawn observer despawns once",
                    function()
                        local w = tecs.newWorld()
                        local ids: {integer} = {}
                        for i = 1, 4 do
                            ids[i] = w:spawn(Shared(i))
                        end
                        w:commit()

                        w:observe(
                            0, tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn) w:despawn(e.entity) end
                        )

                        w:defer()
                        w:despawn(ids[2])
                        w:commit()

                        luassert.is_false(w:isAlive(ids[2]))
                        luassert.is_true(w:isAlive(ids[1]))
                        luassert.is_true(w:isAlive(ids[3]))
                        luassert.is_true(w:isAlive(ids[4]))
                    end
                )

                it(
                    "re-entrant despawn during a top-level despawn despawns once",
                    function()
                        local w = tecs.newWorld()
                        local a = w:spawn(Shared(1))
                        local b = w:spawn(Shared(2))
                        local c = w:spawn(Shared(3))
                        w:commit()

                        w:observe(
                            0, tecs.builtins.OnDespawn, function(e: tecs.builtins.OnDespawn) w:despawn(e.entity) end
                        )

                        w:despawn(a)

                        luassert.is_false(w:isAlive(a))
                        luassert.is_true(w:isAlive(b))
                        luassert.is_true(w:isAlive(c))
                        luassert.equals(2, w:get(b, Shared).v)
                        luassert.equals(3, w:get(c, Shared).v)
                    end
                )

                it(
                    "a despawn staged during drain cancels the entity's staged move",
                    function()
                        local w = tecs.newWorld()
                        local e1 = w:spawn(Shared(1))
                        local e2 = w:spawn(Shared(2))
                        w:commit()

                        -- Fires during the spawn phase of the drain, before the move
                        -- phase relocates e1's staged move.
                        local fired = false
                        w:query({
                            name = "DrainMoveCancelWatcher",
                            include = {Extra},
                            onEntitiesAdded = function(
                                _arch: tecs.Archetype, _first: integer, _last: integer, _count: integer
                            )
                                if not fired then
                                    fired = true
                                    w:despawn(e1)
                                end
                            end,
                        })

                        w:defer()
                        w:set(e1, Extra(1))
                        w:spawn(Shared(9), Extra(9))
                        w:commit()

                        luassert.is_true(fired)
                        luassert.is_false(w:isAlive(e1), "the drain-staged despawn must win")
                        luassert.is_true(w:isAlive(e2), "an unrelated entity must survive")
                        luassert.equals(2, w:get(e2, Shared).v)
                    end
                )

                it(
                    "despawns staged while draining despawns still apply",
                    function()
                        local w = tecs.newWorld()
                        local ids: {integer} = {}
                        for i = 1, 3 do
                            ids[i] = w:spawn(Shared(i))
                        end
                        w:commit()

                        local cascaded = false
                        w:query({
                            name = "DespawnCascadeWatcher",
                            include = {Shared},
                            onEntitiesRemoved = function(
                                _arch: tecs.Archetype, _first: integer, _last: integer, _count: integer
                            )
                                if not cascaded then
                                    cascaded = true
                                    w:despawn(ids[3])
                                end
                            end,
                        })

                        w:defer()
                        w:despawn(ids[1])
                        w:commit()

                        luassert.is_true(cascaded)
                        luassert.is_false(w:isAlive(ids[1]))
                        luassert.is_false(w:isAlive(ids[3]), "observer-staged despawn must not be discarded")
                        luassert.is_true(w:isAlive(ids[2]))
                    end
                )

                it(
                    "batch mutations staged by one-shot-phase observers still apply",
                    function()
                        local w = tecs.newWorld()
                        local e1 = w:spawn(Shared(1))
                        local s1 = w:spawn(Absent(1))
                        w:commit()

                        local sharedQuery = w:query({include = {Shared}})
                        local absentQuery = w:query({include = {Absent}})
                        local staged = false
                        w:query({
                            name = "OneShotBatchWatcher",
                            include = {Extra},
                            onEntitiesAdded = function(
                                _arch: tecs.Archetype, _first: integer, _last: integer, _count: integer
                            )
                                if not staged then
                                    staged = true
                                    -- Targets an archetype untouched by the running
                                    -- mutation, so the snapshot is stable.
                                    w:batchSet(absentQuery, Absent(77))
                                end
                            end,
                        })

                        w:defer()
                        -- Applied in the one-shot phase; its onEntitiesAdded stages a
                        -- second batch mutation that must run in a later round.
                        w:batchSet(sharedQuery, Extra(5))
                        w:commit()

                        luassert.is_true(staged)
                        luassert.equals(5, w:get(e1, Extra).e)
                        luassert.equals(
                            77, w:get(s1, Absent).a, "the observer-staged batch mutation must not be dropped"
                        )
                    end
                )
            end
        )
    end
)
