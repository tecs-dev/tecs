require("busted")
local tecs <const> = require("tecs")
local internal <const> = require("tecs.internal.types")
local luassert <const> = require("luassert")
local describe <const> = describe
local it <const> = it
local before_each <const> = before_each

local type ComponentInternal = internal.ComponentInternal

describe("Sparse Relationships", function()
    local world: tecs.World

    before_each(function()
        world = tecs.newWorld()
    end)

    describe("registration", function()
        it("should create a sparse relationship with reverseIndex and cascadeDelete", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseReg1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
                cascadeDelete = true,
            })
            luassert.is_true((ChildOf as ComponentInternal).isSparse)
            luassert.is_true((ChildOf as ComponentInternal).cascadeDelete)
            luassert.is_true((ChildOf as ComponentInternal).reverseIndex)
        end)

        it("should error if cascadeDelete without reverseIndex", function()
            luassert.error_matches(function()
                tecs.newRelationship({
                    name = "SparseRegBad1",
                    exclusive = true,
                    sparse = true,
                    cascadeDelete = true,
                })
            end, "reverseIndex")
        end)

        it("should error if cascadeDelete without exclusive", function()
            luassert.error_matches(function()
                tecs.newRelationship({
                    name = "SparseRegBad2",
                    sparse = true,
                    reverseIndex = true,
                    cascadeDelete = true,
                })
            end, "exclusive")
        end)

        it("should allow reverseIndex on dense relationships", function()
            local Dense = tecs.newRelationship({
                name = "SparseRegDense",
                exclusive = true,
                reverseIndex = true,
            })
            luassert.is_true((Dense as ComponentInternal).reverseIndex)
            luassert.is_false((Dense as ComponentInternal).isSparse)
        end)

        it("should isolate sparse data between worlds reusing the same relationship", function()
            -- Regression: previously the SparseStore lived on the relationship container
            -- (module-level), so creating a fresh world after using one would inherit the
            -- prior world's sparse entries. With per-world stores, each world starts empty.
            local ChildOf = tecs.newRelationship({
                name = "SparseWorldIsolation",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local worldA = tecs.newWorld()
            local parentA = worldA:spawn()
            local childA = worldA:spawn(ChildOf(parentA) as tecs.Component)
            worldA:update(0)
            luassert.is_not_nil(worldA:get(childA, ChildOf), "worldA should see its own child")

            -- Fresh world reusing the same component definition
            local worldB = tecs.newWorld()
            -- An entity ID from worldB that matches a worldA entity ID -- this is the
            -- exact case that previously corrupted: reused IDs across worlds inherited
            -- the leftover sparse mapping.
            local probe = worldB:spawn()
            luassert.is_nil(
                worldB:get(probe, ChildOf),
                "fresh worldB should not see sparse entries from worldA"
            )
        end)
    end)

    describe("world:get and world:set", function()
        it("should set and get a sparse relationship", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseGet1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local parent = world:spawn()
            local child = world:spawn(ChildOf(parent) as tecs.Component)
            world:update(0)

            local rel = world:get(child, ChildOf)
            luassert.is_not_nil(rel, "should return the relationship")
            luassert.equals(parent, (rel as tecs.Relationship).target)
        end)

        it("should get sparse relationship by target instance", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseGetTarget1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local parent = world:spawn()
            local child = world:spawn(ChildOf(parent) as tecs.Component)
            world:update(0)

            local rel = world:get(child, ChildOf(parent) as tecs.Component)
            luassert.is_not_nil(rel, "should return specific target relationship")
            luassert.equals(parent, (rel as tecs.Relationship).target)
        end)

        it("should return nil for non-existent target", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseGetNil1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local parent = world:spawn()
            local other = world:spawn()
            local child = world:spawn(ChildOf(parent) as tecs.Component)
            world:update(0)

            local rel = world:get(child, ChildOf(other) as tecs.Component)
            luassert.is_nil(rel, "should return nil for wrong target")
        end)

        it("should not read pending sparse value inside a defer scope", function()
            local ChildOf = tecs.newRelationship({
                name = "SparsePending1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local parent = world:spawn()
            world:defer()
            local child = world:spawn(ChildOf(parent) as tecs.Component)

            local rel = world:get(child, ChildOf)
            luassert.is_nil(rel, "should not read pending sparse value inside defer")

            world:commit()
            rel = world:get(child, ChildOf)
            luassert.is_not_nil(rel, "should read sparse value after commit")
        end)

        it("should replace exclusive sparse relationship on set", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseReplace1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local parent1 = world:spawn()
            local parent2 = world:spawn()
            local child = world:spawn(ChildOf(parent1) as tecs.Component)
            world:update(0)

            world:set(child, ChildOf(parent2) as tecs.Component)
            world:update(0)

            local rel = world:get(child, ChildOf)
            luassert.is_not_nil(rel)
            luassert.equals(parent2, (rel as tecs.Relationship).target,
                "should have new parent after reparenting")
        end)
    end)

    describe("world:remove", function()
        it("should remove all targets with container removal", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseRemoveAll1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local parent = world:spawn()
            local child = world:spawn(ChildOf(parent) as tecs.Component)
            world:update(0)

            world:remove(child, ChildOf)
            world:update(0)

            local rel = world:get(child, ChildOf)
            luassert.is_nil(rel, "should have no relationship after container removal")
        end)

        it("should remove specific target with instance removal", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseRemoveOne1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local parent = world:spawn()
            local child = world:spawn(ChildOf(parent) as tecs.Component)
            world:update(0)

            world:remove(child, ChildOf(parent) as tecs.Component)
            world:update(0)

            local rel = world:get(child, ChildOf)
            luassert.is_nil(rel, "should have no relationship after instance removal")
        end)

        it("should remove wildcard from archetype when no entries remain", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseRemoveWild1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local parent = world:spawn()
            local child = world:spawn(ChildOf(parent) as tecs.Component)
            world:update(0)

            -- Child should be in ChildOf query
            local query = world:query({include = {ChildOf}})
            local found = false
            for _, len, entities in query:iter() do
                for i = 1, len do
                    if entities[i] == child then found = true end
                end
            end
            luassert.is_true(found, "child should be in ChildOf query before removal")

            world:remove(child, ChildOf)
            world:update(0)

            -- Child should no longer be in ChildOf query
            found = false
            for _, len, entities in query:iter() do
                for i = 1, len do
                    if entities[i] == child then found = true end
                end
            end
            luassert.is_false(found, "child should NOT be in ChildOf query after removal")
        end)
    end)

    describe("wildcard queries", function()
        it("should match entities with sparse relationships in queries", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseQuery1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local parent = world:spawn()
            local child1 = world:spawn(ChildOf(parent) as tecs.Component)
            local child2 = world:spawn(ChildOf(parent) as tecs.Component)
            local orphan = world:spawn()
            world:update(0)

            local query = world:query({include = {ChildOf}})
            local found: {integer: boolean} = {}
            for _, len, entities in query:iter() do
                for i = 1, len do
                    found[entities[i]] = true
                end
            end

            luassert.is_true(found[child1], "child1 should match")
            luassert.is_true(found[child2], "child2 should match")
            luassert.is_nil(found[orphan], "orphan should not match")
            luassert.is_nil(found[parent], "parent should not match")
        end)
    end)

    describe("archetype column proxy", function()
        it("should allow row-indexed access to sparse data", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseProxy1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local parent = world:spawn()
            local child = world:spawn(ChildOf(parent) as tecs.Component)
            world:update(0)

            local query = world:query({include = {ChildOf}})
            for archetype, len in query:iter() do
                local children = archetype:get(ChildOf)
                for row = 1, len do
                    local rel = children[row]
                    luassert.is_not_nil(rel, "proxy should return value at row")
                    luassert.equals(parent, (rel as tecs.Relationship).target)
                end
            end
        end)
    end)

    describe("world:targets", function()
        it("should return children of an entity", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseTargets1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local parent = world:spawn()
            local child1 = world:spawn(ChildOf(parent) as tecs.Component)
            local child2 = world:spawn(ChildOf(parent) as tecs.Component)
            world:update(0)

            local found: {integer: boolean} = {}
            world:targets(parent, ChildOf, function(childId: integer)
                found[childId] = true
            end)

            luassert.is_true(found[child1], "child1 should be a target")
            luassert.is_true(found[child2], "child2 should be a target")
        end)

        it("should call nothing for entity with no children", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseTargetsEmpty1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local entity = world:spawn()
            world:update(0)

            local count = 0
            world:targets(entity, ChildOf, function(_: integer)
                count = count + 1
            end)
            luassert.equals(0, count)
        end)
    end)

    describe("world:walkUp", function()
        it("should walk up the parent chain calling the callback per ancestor", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseWalkUp1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local root = world:spawn()
            local mid = world:spawn(ChildOf(root) as tecs.Component)
            local leaf = world:spawn(ChildOf(mid) as tecs.Component)
            world:update(0)

            local visited: {integer} = {}
            local depths: {integer} = {}
            world:walkUp(leaf, ChildOf, function(ancestorId: integer, depth: integer, _ctx: any): boolean
                visited[#visited + 1] = ancestorId
                depths[#depths + 1] = depth
                return true
            end)

            luassert.equals(2, #visited)
            luassert.equals(mid, visited[1])
            luassert.equals(1, depths[1])
            luassert.equals(root, visited[2])
            luassert.equals(2, depths[2])
        end)

        it("should stop early when callback returns false", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseWalkUp2",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local root = world:spawn()
            local mid = world:spawn(ChildOf(root) as tecs.Component)
            local leaf = world:spawn(ChildOf(mid) as tecs.Component)
            world:update(0)

            local visited: {integer} = {}
            world:walkUp(leaf, ChildOf, function(ancestorId: integer, _d: integer, _ctx: any): boolean
                visited[#visited + 1] = ancestorId
                return false  -- stop after first ancestor
            end)

            luassert.equals(1, #visited)
            luassert.equals(mid, visited[1])
        end)

        it("should pass through the context argument", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseWalkUp3",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local root = world:spawn()
            local leaf = world:spawn(ChildOf(root) as tecs.Component)
            world:update(0)

            local ctx = {count = 0}
            world:walkUp(leaf, ChildOf, function(_a: integer, _d: integer, c: any): boolean
                local typed = c as {count: integer}
                typed.count = typed.count + 1
                return true
            end, ctx)

            luassert.equals(1, ctx.count)
        end)

        it("should be a no-op for entities with no parent", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseWalkUp4",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local lonely = world:spawn()
            world:update(0)

            local calls = 0
            world:walkUp(lonely, ChildOf, function(_a: integer, _d: integer, _c: any): boolean
                calls = calls + 1
                return true
            end)

            luassert.equals(0, calls)
        end)

        it("should error when maxDepth is exceeded (cycle)", function()
            -- A real cycle is hard to construct since ChildOf is exclusive,
            -- but a low maxDepth on a legitimate deep chain proves the guard.
            local ChildOf = tecs.newRelationship({
                name = "SparseWalkUp5",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local root = world:spawn()
            local a = world:spawn(ChildOf(root) as tecs.Component)
            local b = world:spawn(ChildOf(a) as tecs.Component)
            local c = world:spawn(ChildOf(b) as tecs.Component)
            world:update(0)

            luassert.has_error(function()
                world:walkUp(c, ChildOf, function(_a: integer, _d: integer, _c: any): boolean
                    return true
                end, nil, 2)
            end)
        end)
    end)

    describe("world:traverse", function()
        it("should DFS traverse a hierarchy", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseTraverse1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local root = world:spawn()
            local child1 = world:spawn(ChildOf(root) as tecs.Component)
            local child2 = world:spawn(ChildOf(root) as tecs.Component)
            local grandchild = world:spawn(ChildOf(child1) as tecs.Component)
            world:update(0)

            local visited: {integer} = {}
            local depths: {integer} = {}
            for depth, entityId in world:traverse(root, ChildOf) do
                visited[#visited + 1] = entityId
                depths[#depths + 1] = depth
            end

            luassert.equals(3, #visited, "should visit all descendants")

            -- child1 and child2 are depth 0, grandchild is depth 1
            local foundGrandchild = false
            for i = 1, #visited do
                if visited[i] == grandchild then
                    luassert.equals(1, depths[i], "grandchild should be depth 1")
                    foundGrandchild = true
                elseif visited[i] == child1 or visited[i] == child2 then
                    luassert.equals(0, depths[i], "children should be depth 0")
                end
            end
            luassert.is_true(foundGrandchild, "should have visited grandchild")
        end)
    end)

    describe("cascade delete", function()
        it("should despawn children when parent is despawned", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseCascade1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
                cascadeDelete = true,
            })

            local parent = world:spawn()
            local child1 = world:spawn(ChildOf(parent) as tecs.Component)
            local child2 = world:spawn(ChildOf(parent) as tecs.Component)
            world:update(0)

            world:despawn(parent)
            world:update(0)

            luassert.is_false(world:isAlive(parent))
            luassert.is_false(world:isAlive(child1), "child1 should be cascade deleted")
            luassert.is_false(world:isAlive(child2), "child2 should be cascade deleted")
        end)

        it("should cascade delete recursively through hierarchy", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseCascadeDeep1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
                cascadeDelete = true,
            })

            local root = world:spawn()
            local child = world:spawn(ChildOf(root) as tecs.Component)
            local grandchild = world:spawn(ChildOf(child) as tecs.Component)
            world:update(0)

            world:despawn(root)
            world:update(0)

            luassert.is_false(world:isAlive(root))
            luassert.is_false(world:isAlive(child), "child should be cascade deleted")
            luassert.is_false(world:isAlive(grandchild), "grandchild should be cascade deleted")
        end)

        it("should not cascade when relationship is removed (not parent despawned)", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseCascadeNoOrphan1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
                cascadeDelete = true,
            })

            local parent = world:spawn()
            local child = world:spawn(ChildOf(parent) as tecs.Component)
            world:update(0)

            -- Remove the relationship, don't despawn parent
            world:remove(child, ChildOf)
            world:update(0)

            luassert.is_true(world:isAlive(parent), "parent should be alive")
            luassert.is_true(world:isAlive(child), "child should be alive (orphaned, not deleted)")
        end)

        it("should not despawn unrelated entities", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseCascadeUnrelated1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
                cascadeDelete = true,
            })

            local parent = world:spawn()
            local child = world:spawn(ChildOf(parent) as tecs.Component)
            local unrelated = world:spawn()
            world:update(0)

            world:despawn(parent)
            world:update(0)

            luassert.is_false(world:isAlive(child), "child should be cascade deleted")
            luassert.is_true(world:isAlive(unrelated), "unrelated entity should survive")
        end)
    end)

    describe("archetype fragmentation", function()
        it("should not create per-target archetypes for sparse relationships", function()
            local ChildOf = tecs.newRelationship({
                name = "SparseNoFrag1",
                exclusive = true,
                sparse = true,
                reverseIndex = true,
            })

            local Transform = tecs.builtins.Transform

            -- Create many parents
            local parents: {integer} = {}
            for i = 1, 50 do
                parents[i] = world:spawn()
            end
            world:update(0)

            -- Count archetypes before spawning children
            local archetypesBefore = 0
            for _ in world:query({include = {Transform}}):iter() do
                archetypesBefore = archetypesBefore + 1
            end

            -- Spawn children with different parents
            for i = 1, 50 do
                world:spawn(Transform(0, 0), ChildOf(parents[i]) as tecs.Component)
            end
            world:update(0)

            -- Count archetypes after -- should be at most 1 new archetype (Transform + ChildOf wildcard)
            local archetypesAfter = 0
            for _ in world:query({include = {Transform}}):iter() do
                archetypesAfter = archetypesAfter + 1
            end

            -- At most 1 new archetype for all 50 children (they all share Transform + ChildOf wildcard)
            local newArchetypes = archetypesAfter - archetypesBefore
            luassert.is_true(newArchetypes <= 1,
                "sparse relationships should not create per-target archetypes, got " .. newArchetypes .. " new")
        end)
    end)

    describe("staged value lifecycle", function()
        it("set then remove of the same target in one scope leaves nothing", function()
            local Follows = tecs.newRelationship({
                name = "SparseStagedFollows1",
                sparse = true,
            })
            local target = world:spawn()
            local e = world:spawn()
            world:commit()

            world:defer()
            world:set(e, Follows(target) as tecs.Component)
            world:remove(e, Follows(target) as tecs.Component)
            world:commit()

            luassert.is_false(world:has(e, Follows),
                "the container marker must not survive the remove")
            luassert.is_nil(world:getFirstRelationship(e, Follows),
                "the staged value must not resurrect at commit")
        end)

        it("removing one staged target keeps the other staged target", function()
            local Follows = tecs.newRelationship({
                name = "SparseStagedFollows2",
                sparse = true,
            })
            local t1 = world:spawn()
            local t2 = world:spawn()
            local e = world:spawn()
            world:commit()

            world:defer()
            world:set(e, Follows(t1) as tecs.Component)
            world:set(e, Follows(t2) as tecs.Component)
            world:remove(e, Follows(t1) as tecs.Component)
            world:commit()

            luassert.is_true(world:has(e, Follows))
            luassert.is_nil(world:get(e, Follows(t1) as tecs.Component),
                "the removed target must not resurrect")
            luassert.is_not_nil(world:get(e, Follows(t2) as tecs.Component),
                "the surviving staged target must commit")
        end)

        it("staged values die with a same-transaction despawn and slot reuse", function()
            local Marker = tecs.newComponent({
                name = "SparseStagedMarker",
                container = {},
                fields = {"v"},
                defaults = {0},
            })
            local Follows = tecs.newRelationship({
                name = "SparseStagedFollows3",
                sparse = true,
            })
            local target = world:spawn()
            local e1 = world:spawn(Marker(1))
            local e2 = world:spawn(Marker(2))
            -- Survivor keeps the archetype off the whole-archetype truncate
            -- path, so removals notify per row.
            local e3 = world:spawn(Marker(3))
            world:commit()

            -- Fires per removal during the despawn drain; the second
            -- removal runs after e1's slot was freed, so the spawn
            -- recycles it inside the same transaction.
            local removals = 0
            local recycled: integer = nil
            world:query({
                name = "SparseSlotReuseWatcher",
                include = {Marker},
                onEntitiesRemoved = function(_arch: tecs.Archetype, _first: integer, _last: integer, _count: integer)
                    removals = removals + 1
                    if removals == 2 and not recycled then
                        recycled = world:spawn()
                    end
                end,
            })

            world:defer()
            world:set(e1, Follows(target) as tecs.Component)
            world:despawn(e1)
            world:despawn(e2)
            world:commit()

            luassert.is_not_nil(recycled)
            luassert.is_true(world:isAlive(recycled))
            luassert.is_true(world:isAlive(e3))
            luassert.is_nil(world:getFirstRelationship(recycled, Follows),
                "a dead entity's staged relationship must not attach to the recycled slot")
        end)
    end)
end)
