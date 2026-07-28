require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

-- Dense tag relationship: no sparse flag, creates per-target archetype columns.
local Follows = tecs.ecs.newRelationship({
    name = "CompactTestFollows",
    reverseIndex = true,
})

-- Simple tag component for non-ephemeral archetype tests.
local Tag = tecs.ecs.newTagComponent({name = "CompactTestTag"})

describe(
    "world:compact()",
    function()
        local world: tecs.World

        before_each(function() world = tecs.ecs.newWorld() end)

        describe(
            "archetype pruning",
            function()
                it(
                    "should prune dead archetypes whose relationship target was despawned",
                    function()
                        local target = world:spawn()
                        local follower = world:spawn(Follows(target) as tecs.Component)
                        world:commit()

                        world:despawn(follower)
                        world:despawn(target)
                        world:commit()

                        local archCountBefore = world:getStats().archetypes

                        local pruned, _ = world:compact()
                        luassert.is_true(pruned >= 1, "should prune at least one dead archetype")

                        local archCountAfter = world:getStats().archetypes
                        luassert.is_true(
                            archCountAfter < archCountBefore, "archetype count should decrease after pruning"
                        )
                    end
                )

                it(
                    "should not prune non-ephemeral empty archetypes",
                    function()
                        local e = world:spawn(Tag)
                        world:commit()
                        world:despawn(e)
                        world:commit()

                        local archCountBefore = world:getStats().archetypes
                        local pruned, _ = world:compact()
                        luassert.equals(0, pruned, "should not prune non-ephemeral archetypes")
                        luassert.equals(archCountBefore, world:getStats().archetypes)
                    end
                )

                it(
                    "should not prune ephemeral archetypes whose target is still alive",
                    function()
                        local target = world:spawn()
                        local _follower = world:spawn(Follows(target) as tecs.Component)
                        world:commit()

                        local pruned, _ = world:compact()
                        luassert.equals(0, pruned, "should not prune while target is alive")
                    end
                )

                it(
                    "should preserve the empty sentinel archetype",
                    function()
                        local pruned, _ = world:compact()
                        luassert.equals(0, pruned)
                        -- World should still function
                        local e = world:spawn()
                        world:commit()
                        luassert.is_true(world:isAlive(e))
                    end
                )

                it(
                    "should be idempotent",
                    function()
                        local target = world:spawn()
                        local follower = world:spawn(Follows(target) as tecs.Component)
                        world:commit()
                        world:despawn(follower)
                        world:despawn(target)
                        world:commit()

                        local pruned1, _ = world:compact()
                        luassert.is_true(pruned1 >= 1)

                        local pruned2, _ = world:compact()
                        luassert.equals(0, pruned2, "second compact should prune nothing")
                    end
                )

                it(
                    "should maintain correct archetype index after compaction",
                    function()
                        -- Create several archetypes, then prune one in the middle
                        local t1 = world:spawn()
                        local _f1 = world:spawn(Follows(t1) as tecs.Component)
                        world:commit()

                        local e2 = world:spawn(Tag)
                        world:commit()

                        world:despawn(_f1)
                        world:despawn(t1)
                        world:commit()

                        world:compact()

                        -- Surviving entities should still be accessible
                        luassert.is_true(world:isAlive(e2))
                    end
                )

                it(
                    "should maintain query coherence across compact",
                    function()
                        local target = world:spawn()
                        local follower = world:spawn(Follows(target) as tecs.Component)
                        world:commit()

                        local query = world:query({include = {Follows}})
                        local count = 0
                        for _ in query:iter() do
                            count = count + 1
                        end
                        luassert.equals(1, count, "query should find one entity before despawn")

                        world:despawn(follower)
                        world:despawn(target)
                        world:commit()
                        world:compact()

                        count = 0
                        for _ in query:iter() do
                            count = count + 1
                        end
                        luassert.equals(0, count, "query should find zero entities after compact")

                        -- New entities should be picked up by the query
                        local t2 = world:spawn()
                        local _f2 = world:spawn(Follows(t2) as tecs.Component)
                        world:commit()
                        count = 0
                        for _ in query:iter() do
                            count = count + 1
                        end
                        luassert.equals(1, count, "query should pick up new entities after compact")
                    end
                )

                it(
                    "should reuse destroyed archetype ids for new archetypes",
                    function()
                        -- Freelist regression: after destroy, the next archetype
                        -- creation should grab the freed id before bumping maxId.
                        local t1 = world:spawn()
                        local _f1 = world:spawn(Follows(t1) as tecs.Component)
                        world:commit()

                        local index = (world as {string: any}).archetypeIndex as {string: integer}
                        local maxIdBeforeDestroy = index.maxId

                        world:despawn(_f1)
                        world:despawn(t1)
                        world:commit()
                        local pruned, _ = world:compact()
                        luassert.is_true(pruned >= 1)

                        -- Spawn a new ephemeral-arch entity. Should reuse the freed id.
                        local t2 = world:spawn()
                        local _f2 = world:spawn(Follows(t2) as tecs.Component)
                        world:commit()

                        luassert.equals(
                            maxIdBeforeDestroy, index.maxId, "maxId should not advance when a freed id is reused"
                        )
                    end
                )
            end
        )

        describe(
            "storage compaction",
            function()
                it(
                    "should shrink archetype capacity after mass despawn",
                    function()
                        local ids: {integer} = {}
                        for i = 1, 5000 do
                            ids[i] = world:spawn(Tag)
                        end
                        world:commit()

                        for i = 11, 5000 do
                            world:despawn(ids[i])
                        end
                        world:commit()

                        local _, compacted = world:compact()
                        luassert.is_true(compacted >= 1, "should compact at least one archetype")

                        for i = 1, 10 do
                            luassert.is_true(world:isAlive(ids[i]), "entity " .. tostring(i) .. " should be alive")
                        end
                    end
                )

                it(
                    "should allow new spawns after compaction",
                    function()
                        local ids: {integer} = {}
                        for i = 1, 5000 do
                            ids[i] = world:spawn(Tag)
                        end
                        world:commit()

                        for i = 11, 5000 do
                            world:despawn(ids[i])
                        end
                        world:commit()
                        world:compact()

                        local newId = world:spawn(Tag)
                        world:commit()
                        luassert.is_true(world:isAlive(newId))
                    end
                )
            end
        )

        describe(
            "isAlive across compact",
            function()
                it(
                    "should preserve isAlive correctness",
                    function()
                        local alive: {integer} = {}
                        local dead: {integer} = {}
                        for i = 1, 100 do
                            alive[i] = world:spawn(Tag)
                        end
                        for i = 1, 100 do
                            dead[i] = world:spawn(Tag)
                        end
                        world:commit()

                        for i = 1, 100 do
                            world:despawn(dead[i])
                        end
                        world:commit()
                        world:compact()

                        for i = 1, 100 do
                            luassert.is_true(
                                world:isAlive(alive[i]), "alive entity " .. tostring(i) .. " should still be alive"
                            )
                        end
                        for i = 1, 100 do
                            luassert.is_false(
                                world:isAlive(dead[i]), "dead entity " .. tostring(i) .. " should be dead"
                            )
                        end
                    end
                )
            end
        )

        describe(
            "preconditions",
            function()
                it(
                    "should error if world has pending mutations inside a defer scope",
                    function()
                        world:defer()
                        world:spawn()
                        -- Inside defer, the spawn is staged but uncommitted.
                        luassert.has_error(function() world:compact() end, "compact requires a committed world")
                        world:commit()
                    end
                )
            end
        )
    end
)
