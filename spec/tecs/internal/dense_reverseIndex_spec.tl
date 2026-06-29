require("busted")
local tecs <const> = require("tecs")
local internal <const> = require("tecs.internal.types")
local luassert <const> = require("luassert")
local describe <const> = describe
local it <const> = it
local before_each <const> = before_each

local type ComponentInternal = internal.ComponentInternal

describe("Dense Relationships with reverseIndex", function()
    local world: tecs.World

    before_each(function()
        world = tecs.newWorld()
    end)

    describe("registration", function()
        it("should create a dense relationship with reverseIndex", function()
            local Follows = tecs.newRelationship({
                name = "DenseRevIdx1",
                exclusive = true,
                reverseIndex = true,
            })
            luassert.is_false((Follows as ComponentInternal).isSparse)
            luassert.is_true((Follows as ComponentInternal).reverseIndex)
        end)

        it("should isolate dense reverse-index data between worlds reusing the same relationship", function()
            -- Same regression as the sparse case: dense reverse indexes used to live on the
            -- relationship container as a module-level singleton, leaking entity links across
            -- worlds. The unified RelationshipStore makes both sparse and dense per-world.
            local Follows = tecs.newRelationship({
                name = "DenseRevIdxIsolation",
                exclusive = true,
                reverseIndex = true,
            })

            local worldA = tecs.newWorld()
            local leaderA = worldA:spawn()
            local followerA = worldA:spawn(Follows(leaderA) as tecs.Component)
            worldA:update(0)
            local foundA: {integer: boolean} = {}
            worldA:targets(leaderA, Follows, function(srcId: integer)
                foundA[srcId] = true
            end)
            luassert.is_true(foundA[followerA], "worldA should see its own follower")

            -- Fresh world reusing the same component definition
            local worldB = tecs.newWorld()
            local probe = worldB:spawn()  -- entity ID likely matches one from worldA
            worldB:update(0)
            local foundB: {integer: boolean} = {}
            worldB:targets(probe, Follows, function(srcId: integer)
                foundB[srcId] = true
            end)
            luassert.is_nil(next(foundB), "fresh worldB should not see follow links from worldA")
        end)
    end)

    describe("world:targets", function()
        it("should return source entities targeting an entity", function()
            local Follows = tecs.newRelationship({
                name = "DenseTargets1",
                exclusive = true,
                reverseIndex = true,
            })

            local leader = world:spawn()
            local f1 = world:spawn(Follows(leader) as tecs.Component)
            local f2 = world:spawn(Follows(leader) as tecs.Component)
            world:update(0)

            local found: {integer: boolean} = {}
            world:targets(leader, Follows, function(srcId: integer)
                found[srcId] = true
            end)
            luassert.is_true(found[f1])
            luassert.is_true(found[f2])
        end)

        it("should update inverse on relationship removal", function()
            local Follows = tecs.newRelationship({
                name = "DenseTargets2",
                exclusive = true,
                reverseIndex = true,
            })

            local leader = world:spawn()
            local follower = world:spawn(Follows(leader) as tecs.Component)
            world:update(0)

            local count = 0
            world:targets(leader, Follows, function(_: integer) count = count + 1 end)
            luassert.equals(1, count)

            world:remove(follower, Follows(leader) as tecs.Component)
            world:update(0)

            count = 0
            world:targets(leader, Follows, function(_: integer) count = count + 1 end)
            luassert.equals(0, count)
        end)

        it("should update inverse on exclusive replace", function()
            local Follows = tecs.newRelationship({
                name = "DenseTargets3",
                exclusive = true,
                reverseIndex = true,
            })

            local leader1 = world:spawn()
            local leader2 = world:spawn()
            local follower = world:spawn(Follows(leader1) as tecs.Component)
            world:update(0)

            -- Reparent
            world:set(follower, Follows(leader2) as tecs.Component)
            world:update(0)

            local count1 = 0
            world:targets(leader1, Follows, function(_: integer) count1 = count1 + 1 end)
            luassert.equals(0, count1, "leader1 should have no followers after reparent")

            local count2 = 0
            world:targets(leader2, Follows, function(_: integer) count2 = count2 + 1 end)
            luassert.equals(1, count2, "leader2 should have the follower")
        end)

        it("should update inverse when source entity is despawned", function()
            local Follows = tecs.newRelationship({
                name = "DenseTargets4",
                exclusive = true,
                reverseIndex = true,
            })

            local leader = world:spawn()
            local follower = world:spawn(Follows(leader) as tecs.Component)
            world:update(0)

            world:despawn(follower)
            world:update(0)

            local count = 0
            world:targets(leader, Follows, function(_: integer) count = count + 1 end)
            luassert.equals(0, count)
        end)

        it("should remove relationship instances when target is despawned", function()
            local Follows = tecs.newRelationship({
                name = "DenseTargets5",
                exclusive = true,
                reverseIndex = true,
            })

            local leader = world:spawn()
            local follower = world:spawn(Follows(leader) as tecs.Component)
            world:update(0)

            world:despawn(leader)
            world:update(0)

            luassert.is_true(world:isAlive(follower), "follower should still be alive (no cascade)")
            local rel = world:get(follower, Follows(leader) as tecs.Component)
            luassert.is_nil(rel, "follower should no longer have Follows(leader)")
        end)
    end)

    describe("world:traverse", function()
        it("should DFS traverse a dense hierarchy", function()
            local OwnedBy = tecs.newRelationship({
                name = "DenseTraverse1",
                exclusive = true,
                reverseIndex = true,
            })

            local root = world:spawn()
            local child1 = world:spawn(OwnedBy(root) as tecs.Component)
            local child2 = world:spawn(OwnedBy(root) as tecs.Component)
            local grandchild = world:spawn(OwnedBy(child1) as tecs.Component)
            world:update(0)

            local visited: {integer: integer} = {}  -- entityId -> depth
            for depth, entityId in world:traverse(root, OwnedBy) do
                visited[entityId] = depth
            end

            luassert.equals(0, visited[child1])
            luassert.equals(0, visited[child2])
            luassert.equals(1, visited[grandchild])
        end)
    end)

    describe("cascade delete with dense", function()
        it("should despawn sources when target is despawned (cascadeDelete)", function()
            local OwnedBy = tecs.newRelationship({
                name = "DenseCascade1",
                exclusive = true,
                reverseIndex = true,
                cascadeDelete = true,
            })

            local owner = world:spawn()
            local item1 = world:spawn(OwnedBy(owner) as tecs.Component)
            local item2 = world:spawn(OwnedBy(owner) as tecs.Component)
            world:update(0)

            world:despawn(owner)
            world:update(0)

            luassert.is_false(world:isAlive(item1), "item1 should be cascade deleted")
            luassert.is_false(world:isAlive(item2), "item2 should be cascade deleted")
        end)

        it("should cascade recursively through dense hierarchy", function()
            local OwnedBy = tecs.newRelationship({
                name = "DenseCascadeDeep1",
                exclusive = true,
                reverseIndex = true,
                cascadeDelete = true,
            })

            local root = world:spawn()
            local child = world:spawn(OwnedBy(root) as tecs.Component)
            local grandchild = world:spawn(OwnedBy(child) as tecs.Component)
            world:update(0)

            world:despawn(root)
            world:update(0)

            luassert.is_false(world:isAlive(root))
            luassert.is_false(world:isAlive(child))
            luassert.is_false(world:isAlive(grandchild))
        end)
    end)

    describe("consistency across mutation kinds", function()
        local function count_sources(w: tecs.World, target: integer, rel: tecs.Component): integer
            local n = 0
            w:targets(target, rel, function(_: integer) n = n + 1 end)
            return n
        end

        it("eager set then eager remove zeroes the reverse index", function()
            local Follows = tecs.newRelationship({
                name = "RevIdx_SetRemove",
                exclusive = true, reverseIndex = true,
            })
            local w = tecs.newWorld()
            local leader = w:spawn()
            local f = w:spawn(Follows(leader) as tecs.Component)
            luassert.equals(1, count_sources(w, leader, Follows))
            w:remove(f, Follows(leader) as tecs.Component)
            luassert.equals(0, count_sources(w, leader, Follows))
        end)

        it("deferred set then deferred remove yields the same terminal state", function()
            local Follows = tecs.newRelationship({
                name = "RevIdx_DeferredRoundtrip",
                exclusive = true, reverseIndex = true,
            })
            local w = tecs.newWorld()
            local leader = w:spawn()
            local follower = w:spawn()
            w:defer()
            w:set(follower, Follows(leader) as tecs.Component)
            w:commit()
            luassert.equals(1, count_sources(w, leader, Follows))
            w:defer()
            w:remove(follower, Follows(leader) as tecs.Component)
            w:commit()
            luassert.equals(0, count_sources(w, leader, Follows))
        end)

        it("instant and deferred mutation sequences converge to identical state (committed entities)", function()
            local function build_world(deferred: boolean): (integer, integer, integer, tecs.World, tecs.Component)
                local Follows = tecs.newRelationship({
                    name = "RevIdx_Parity_" .. (deferred and "Deferred" or "Instant"),
                    exclusive = true, reverseIndex = true,
                })
                local w = tecs.newWorld()
                local l1, l2 = w:spawn(), w:spawn()
                local a = w:spawn(Follows(l1) as tecs.Component)
                local function run()
                    w:set(a, Follows(l2) as tecs.Component)
                end
                if deferred then
                    w:defer(); run(); w:commit()
                else
                    run()
                end
                return l1, l2, a, w, Follows
            end

            local il1, il2, _ia, iw, iFollows = build_world(false)
            local dl1, dl2, _da, dw, dFollows = build_world(true)

            luassert.equals(
                count_sources(iw, il1, iFollows), count_sources(dw, dl1, dFollows),
                "instant vs deferred leader1 source count mismatch")
            luassert.equals(
                count_sources(iw, il2, iFollows), count_sources(dw, dl2, dFollows),
                "instant vs deferred leader2 source count mismatch")
            luassert.equals(0, count_sources(iw, il1, iFollows))
            luassert.equals(1, count_sources(iw, il2, iFollows))
        end)

        it("exclusive replace on STATE_SPAWN entity in same deferred scope", function()
            -- Regression guard for a bug that existed before Phase 4.
            -- Before exclusive-sibling-eviction moved to the `deferSet` hook,
            -- `_deferSetSlow`'s eviction loop lived in the relationship-side
            -- -effects block and was unreachable when the entity was still
            -- in STATE_SPAWN. Phase 4 fires the hook at the dispatcher
            -- regardless of state, so both paths work.
            local Follows = tecs.newRelationship({
                name = "RevIdx_SpawnReparent",
                exclusive = true, reverseIndex = true,
            })
            local w = tecs.newWorld()
            local l1, l2 = w:spawn(), w:spawn()
            w:defer()
            local a = w:spawn()
            w:set(a, Follows(l1) as tecs.Component)
            w:set(a, Follows(l2) as tecs.Component)   -- reparent, same scope
            w:commit()

            luassert.equals(0, count_sources(w, l1, Follows),
                "l1 must not retain a after reparent — sibling eviction must fire on STATE_SPAWN")
            luassert.equals(1, count_sources(w, l2, Follows))
        end)

        it("exclusive replace unlinks old target before linking new", function()
            local Follows = tecs.newRelationship({
                name = "RevIdx_ExclusiveReplace",
                exclusive = true, reverseIndex = true,
            })
            local w = tecs.newWorld()
            local l1, l2 = w:spawn(), w:spawn()
            local f = w:spawn(Follows(l1) as tecs.Component)
            w:set(f, Follows(l2) as tecs.Component)

            luassert.equals(0, count_sources(w, l1, Follows),
                "l1 must not retain f after reparent — bad unlink ordering")
            luassert.equals(1, count_sources(w, l2, Follows))
        end)

        it("many-to-one reverse index stays correct across interleaved ops", function()
            local Follows = tecs.newRelationship({
                name = "RevIdx_ManyToOne",
                exclusive = true, reverseIndex = true,
            })
            local w = tecs.newWorld()
            local leader = w:spawn()
            local followers: {integer} = {}
            for i = 1, 10 do followers[i] = w:spawn(Follows(leader) as tecs.Component) end
            luassert.equals(10, count_sources(w, leader, Follows))

            w:remove(followers[2], Follows(leader) as tecs.Component)
            w:defer()
            w:remove(followers[4], Follows(leader) as tecs.Component)
            w:remove(followers[6], Follows(leader) as tecs.Component)
            w:commit()
            w:despawn(followers[8])
            luassert.equals(6, count_sources(w, leader, Follows))
        end)
    end)

    describe("ordering invariant", function()
        -- If the reverse-index unlink hook fires AFTER row teardown, it reads
        -- nil for the old target and skips the unlink — leaving stale entries
        -- in the inverse. This test catches that regression directly.
        it("onDespawn hook reads old column value before row teardown", function()
            local Follows = tecs.newRelationship({
                name = "RevIdx_Ordering_OnDespawn",
                exclusive = true, reverseIndex = true,
            })
            local w = tecs.newWorld()
            local leader = w:spawn()
            local follower = w:spawn(Follows(leader) as tecs.Component)

            local function count(): integer
                local n = 0
                w:targets(leader, Follows, function() n = n + 1 end)
                return n
            end
            luassert.equals(1, count(), "precondition: follower is linked")

            w:despawn(follower)
            luassert.equals(0, count(), "reverse index must be cleared by onDespawn hook")
        end)
    end)
end)
