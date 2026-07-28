require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

describe(
    "relationships",
    function()
        local world: tecs.World

        before_each(function() world = tecs.ecs.newWorld() end)

        describe(
            "relationship teardown (cascade)",
            function()
                it(
                    "should cascade delete when parent is despawned",
                    function()
                        local ChildOf = tecs.ecs.newRelationship({
                            name = "ChildOfCascadeTest",
                            exclusive = true,
                            sparse = true,
                            reverseIndex = true,
                            cascadeDelete = true,
                        })

                        local parent = world:spawn()
                        local child1 = world:spawn(ChildOf(parent) as tecs.Component)
                        local child2 = world:spawn(ChildOf(parent) as tecs.Component)

                        -- Commit spawns
                        world:update(0)

                        luassert.is_true(world:isAlive(parent), "Parent should be alive initially")
                        luassert.is_true(world:isAlive(child1), "Child1 should be alive")
                        luassert.is_true(world:isAlive(child2), "Child2 should be alive")

                        -- Despawn parent should cascade to children
                        world:despawn(parent)

                        -- Force changes to be committed
                        world:update(0)

                        luassert.is_false(world:isAlive(parent), "Parent should be despawned")
                        luassert.is_false(world:isAlive(child1), "Child1 should be cascade deleted")
                        luassert.is_false(world:isAlive(child2), "Child2 should be cascade deleted")
                    end
                )

                it(
                    "cascade-deletes children that carry many unrelated components",
                    function()
                        -- Mirrors a real pattern (bubble + label-child with several
                        -- rendering components). If cascade misbehaves when the child has
                        -- non-trivial component baggage, this catches it.
                        local record Marker is tecs.Component
                        end
                        local record Pos is tecs.Component
                            x: number
                            y: number
                            metamethod __call: function(self, x: number, y: number): Pos
                        end
                        local record Tint is tecs.Component
                            r: number
                            g: number
                            b: number
                            metamethod __call: function(self, r: number, g: number, b: number): Tint
                        end
                        local MarkerComp = tecs.ecs.newTagComponent({
                            name = "CascadeMarker" .. math.random(1, 1000000),
                            container = Marker,
                        })
                        local PosComp: Pos = tecs.ecs.newComponent({
                            name = "CascadePos" .. math.random(1, 1000000),
                            container = Pos,
                            fields = {"x", "y"},
                        })
                        local TintComp: Tint = tecs.ecs.newComponent({
                            name = "CascadeTint" .. math.random(1, 1000000),
                            container = Tint,
                            fields = {"r", "g", "b"},
                        })
                        local ChildOf = tecs.ecs.newRelationship({
                            name = "CascadeChildOf" .. math.random(1, 1000000),
                            exclusive = true,
                            sparse = true,
                            reverseIndex = true,
                            cascadeDelete = true,
                        })

                        local parent = world:spawn(PosComp(1, 2), TintComp(0.5, 0.5, 0.5), MarkerComp)
                        local labels: {integer} = {}
                        for i = 1, 5 do
                            labels[i] = world:spawn(
                                ChildOf(parent) as tecs.Component, PosComp(i, i * 2), TintComp(1, 1, 1), MarkerComp
                            )
                        end
                        world:update(0)

                        luassert.is_true(world:isAlive(parent))
                        for i = 1, 5 do
                            luassert.is_true(world:isAlive(labels[i]), "Label " .. i .. " alive pre-despawn")
                        end

                        world:despawn(parent)
                        world:update(0)

                        luassert.is_false(world:isAlive(parent))
                        for i = 1, 5 do
                            luassert.is_false(
                                world:isAlive(labels[i]), "Label " .. i .. " should have cascade-despawned"
                            )
                        end
                    end
                )

                it(
                    "should not cascade delete when relationship is just removed",
                    function()
                        local ChildOf = tecs.ecs.newRelationship({
                            name = "ChildOfNoCascadeTest",
                            exclusive = true,
                        })

                        local parent = world:spawn()
                        local child = world:spawn(ChildOf(parent) as tecs.Component)

                        -- Commit spawns
                        world:update(0)

                        luassert.is_true(world:isAlive(parent), "Parent should be alive")
                        luassert.is_true(world:isAlive(child), "Child should be alive")

                        -- Remove relationship (orphan the child)
                        world:remove(child, ChildOf(parent) as tecs.Component)

                        -- Force changes to be committed
                        world:update(0)

                        luassert.is_true(world:isAlive(parent), "Parent should still be alive")
                        luassert.is_true(world:isAlive(child), "Child should still be alive (orphaned, not deleted)")
                        -- For exclusive relationships, passing the wildcard should work
                        -- But currently it returns the wildcard container instead of nil
                        -- This might be a separate bug to fix
                        local childOfRel = world:get(child, ChildOf(parent) as tecs.Component)
                        luassert.is_nil(childOfRel, "Child should no longer have specific ChildOf(parent)")
                    end
                )

                it(
                    "should not cascade delete when reparenting",
                    function()
                        local ChildOf = tecs.ecs.newRelationship({
                            name = "ChildOfReparentTest",
                            exclusive = true,
                        })

                        local parent1 = world:spawn()
                        local parent2 = world:spawn()
                        local child = world:spawn(ChildOf(parent1) as tecs.Component)

                        -- Commit spawns
                        world:update(0)

                        luassert.is_true(world:isAlive(child), "Child should be alive")

                        -- Reparent to parent2 (exclusive relationship replaces parent1)
                        world:set(child, ChildOf(parent2) as tecs.Component)

                        -- Force changes to be committed
                        world:update(0)

                        luassert.is_true(world:isAlive(parent1), "Parent1 should still be alive")
                        luassert.is_true(world:isAlive(parent2), "Parent2 should still be alive")
                        luassert.is_true(world:isAlive(child), "Child should still be alive after reparenting")

                        local childOfRel = world:get(child, ChildOf(parent2) as tecs.Component)
                        luassert.is_not_nil(childOfRel, "Child should have ChildOf(parent2)")
                        luassert.equals(
                            parent2, (childOfRel as tecs.Relationship).target, "Child should be child of parent2"
                        )

                        -- Exclusive relationship should have removed the old ChildOf(parent1)
                        local oldRel = world:get(child, ChildOf(parent1) as tecs.Component)
                        luassert.is_nil(oldRel, "Child should no longer have ChildOf(parent1) after reparenting")
                    end
                )
            end
        )

        describe(
            "relationship creation methods",
            function()
                local components = require("tecs.internal.components")
                local types = require("tecs.types")
                local type Relationship = types.components.Relationship

                describe(
                    "newRelationship",
                    function()
                        it(
                            "should create a basic target-only relationship",
                            function()
                                local TagFollows = components.newRelationship({name = "TagFollows"})

                                luassert.is_not_nil(TagFollows)
                                luassert.is_equal("TagFollows", TagFollows.componentName)
                                luassert.is_not_nil(TagFollows.componentType)
                                luassert.is_not_nil(TagFollows.exclusiveRelationship)
                            end
                        )

                        it(
                            "backs a target-only relationship with an FFI instance",
                            function()
                                -- A name-only relationship carries no data beyond the target,
                                -- so it folds onto the compact FFI layout: instances are cdata,
                                -- not Lua tables.
                                local Likes = components.newRelationship({name = "FoldedLikes"})
                                local target = world:spawn()
                                local instance = Likes(target)

                                luassert.is_equal("cdata", type(instance), "target-only instance should be FFI cdata")
                                luassert.is_equal(target, (instance as Relationship).target)
                            end
                        )

                        it(
                            "should support exclusive option",
                            function()
                                local ExclusiveTag = components.newRelationship({
                                    name = "ExclusiveTag", exclusive = true
                                })

                                luassert.is_true(ExclusiveTag.exclusiveRelationship)
                            end
                        )

                        it(
                            "should work with targeting method",
                            function()
                                local TagFollows2 = components.newRelationship({name = "TagFollows2"})

                                local entity1 = world:spawn()
                                local entity2 = world:spawn()

                                local targetingResult = TagFollows2:targeting(entity2)
                                luassert.is_not_nil(targetingResult)
                            end
                        )
                    end
                )

                describe(
                    "newFFIRelationship",
                    function()
                        it(
                            "should create an FFI relationship with data fields",
                            function()
                                local record TestFFIRel is Relationship
                                    delay: number
                                    power: integer
                                end

                                local FFIRel = components.newFFIRelationship({
                                    name = "FFIRel",
                                    container = TestFFIRel,
                                    fields = {{"delay", "float"}, {"power", "int32_t"}},
                                })

                                luassert.is_not_nil(FFIRel)
                                luassert.is_equal("FFIRel", FFIRel.componentName)
                                luassert.is_equal(TestFFIRel, FFIRel.componentType)
                                luassert.is_not_nil(FFIRel.exclusiveRelationship)
                            end
                        )

                        it(
                            "should support exclusive option and targeting",
                            function()
                                local record ExclusiveFFIRel is Relationship
                                    value: integer
                                end

                                local FFIRel = components.newFFIRelationship({
                                    name = "ExclusiveFFIRel",
                                    container = ExclusiveFFIRel,
                                    fields = {{"value", "int32_t"}},
                                    exclusive = true,
                                })

                                luassert.is_true(FFIRel.exclusiveRelationship)

                                local entity1 = world:spawn()
                                local entity2 = world:spawn()

                                local targetingResult = FFIRel:targeting(entity2)
                                luassert.is_not_nil(targetingResult)
                            end
                        )

                        it(
                            "should run custom __call for FFI relationships",
                            function()
                                local callCount = 0

                                local record CustomCallFFIRel is Relationship
                                    value: integer
                                    doubled: integer
                                end

                                local FFIRel = components.newFFIRelationship({
                                    name = "CustomCallFFIRel",
                                    container = CustomCallFFIRel,
                                    fields = {{"value", "int32_t"}, {"doubled", "int32_t"}},
                                    __call = function(instance: CustomCallFFIRel, target: integer, value: integer)
                                        callCount = callCount + 1
                                        instance.target = target
                                        instance.value = value
                                        instance.doubled = value * 2
                                    end,
                                })

                                local inst = FFIRel(world:spawn(), 21) as CustomCallFFIRel
                                luassert.is_equal(1, callCount)
                                luassert.is_equal(21, inst.value)
                                luassert.is_equal(42, inst.doubled)
                            end
                        )

                        it(
                            "should apply the provided metatable to FFI relationship instances",
                            function()
                                local record MetaFFIRel is Relationship
                                    value: integer
                                end

                                local mt = {
                                    __index = {bonus = function(self: MetaFFIRel): integer return self.value + 5 end}
                                }

                                local FFIRel = components.newFFIRelationship({
                                    name = "MetaFFIRel",
                                    container = MetaFFIRel,
                                    fields = {{"value", "int32_t"}},
                                    metatable = mt,
                                    init = function(instance: MetaFFIRel, target: integer, value: integer)
                                        instance.target = target
                                        instance.value = value
                                    end,
                                })

                                local inst = FFIRel(world:spawn(), 9) as any
                                luassert.is_equal(14, inst:bonus())
                            end
                        )
                    end
                )

                describe(
                    "Integration test",
                    function()
                        it(
                            "should create both types without conflicts",
                            function()
                                local TagRel = components.newRelationship({name = "PerfTagRel"})

                                local record DataFFIRel is Relationship
                                    value: number
                                end

                                local FFIDataRel = components.newFFIRelationship({
                                    name = "PerfFFIDataRel", container = DataFFIRel, fields = {{"value", "double"}}
                                })

                                local TableRel = components.newRelationship({name = "PerfTableRel"})

                                luassert.is_not_nil(TagRel)
                                luassert.is_not_nil(FFIDataRel)
                                luassert.is_not_nil(TableRel)

                                luassert.is_not_nil(TagRel.componentName)
                                luassert.is_not_nil(FFIDataRel.componentName)
                                luassert.is_not_nil(TableRel.componentName)
                            end
                        )
                    end
                )
            end
        )

        describe(
            "wildcard relationship queries",
            function()
                it(
                    "should allow querying for any entity with a relationship via wildcard",
                    function()
                        local Likes = tecs.ecs.newRelationship({name = "LikesWildcardTest"})

                        local target1 = world:spawn()
                        local target2 = world:spawn()
                        local entity1 = world:spawn(Likes(target1) as tecs.Component)
                        local entity2 = world:spawn(Likes(target2) as tecs.Component)
                        local entityNoRel = world:spawn()

                        world:update(0)

                        -- Query using the wildcard relationship (no specific target)
                        local query = world:query({include = {Likes}})
                        local foundEntities: {integer: boolean} = {}
                        for archetype, len, entities in query:iter() do
                            for row = 1, len do
                                foundEntities[entities[row]] = true
                            end
                        end

                        luassert.is_true(foundEntities[entity1], "entity1 should be found with wildcard query")
                        luassert.is_true(foundEntities[entity2], "entity2 should be found with wildcard query")
                        luassert.is_nil(foundEntities[entityNoRel], "entityNoRel should NOT be found")
                        luassert.is_nil(
                            foundEntities[target1], "target1 should NOT be found (it's a target, not a source)"
                        )
                        luassert.is_nil(
                            foundEntities[target2], "target2 should NOT be found (it's a target, not a source)"
                        )
                    end
                )

                it(
                    "should allow querying for specific target with :targeting()",
                    function()
                        local Follows = tecs.ecs.newRelationship({name = "FollowsTargetingTest"})

                        local leader1 = world:spawn()
                        local leader2 = world:spawn()
                        local follower1 = world:spawn(Follows(leader1) as tecs.Component)
                        local follower2 = world:spawn(Follows(leader2) as tecs.Component)
                        local followerBoth = world:spawn(
                            Follows(leader1) as tecs.Component, Follows(leader2) as tecs.Component
                        )

                        world:update(0)

                        -- Query for entities following leader1 specifically
                        local query = world:query({include = {Follows:targeting(leader1)}})
                        local foundEntities: {integer: boolean} = {}
                        for archetype, len, entities in query:iter() do
                            for row = 1, len do
                                foundEntities[entities[row]] = true
                            end
                        end

                        luassert.is_true(foundEntities[follower1], "follower1 should be found")
                        luassert.is_true(foundEntities[followerBoth], "followerBoth should be found")
                        luassert.is_nil(foundEntities[follower2], "follower2 should NOT be found (follows leader2)")
                    end
                )

                it(
                    "should work with FFI tag relationships and componentHash propagation",
                    function()
                        local components = require("tecs.internal.components")

                        local ChildOf = components.newRelationship({name = "ChildOfHashTest"})

                        local parent = world:spawn()
                        world:update(0)

                        -- Spawn child with ChildOf - this tests componentHash propagation
                        -- The FFI instance needs componentHash for archetype hashing
                        local child = world:spawn(ChildOf(parent) as tecs.Component)
                        world:update(0)

                        -- Query using wildcard should find the child
                        local query = world:query({include = {ChildOf}})
                        local foundEntities: {integer: boolean} = {}
                        for archetype, len, entities in query:iter() do
                            for row = 1, len do
                                foundEntities[entities[row]] = true
                            end
                        end

                        luassert.is_true(foundEntities[child], "child should be found with wildcard query")
                        luassert.is_nil(foundEntities[parent], "parent should NOT be found")
                    end
                )

                it(
                    "should give per-entity FFI relationships unique componentId",
                    function()
                        local components = require("tecs.internal.components")

                        local ChildOf = components.newRelationship({name = "ChildOfUniqueIdTest"})

                        local instance1 = ChildOf(100)
                        local instance2 = ChildOf(200)
                        local instance1Again = ChildOf(100)

                        -- Same target should return same cached instance
                        luassert.equals(instance1, instance1Again)

                        -- Different targets should have different IDs
                        luassert.not_equals(instance1.componentId, instance2.componentId)

                        -- tostring should include target for disambiguation
                        luassert.matches("100", tostring(instance1))
                        luassert.matches("200", tostring(instance2))
                    end
                )

                it(
                    "should correctly group entities with different relationship targets",
                    function()
                        local components = require("tecs.internal.components")

                        local ChildOf = components.newRelationship({name = "ChildOfGroupingTest"})

                        local parent1 = world:spawn()
                        local parent2 = world:spawn()
                        world:update(0)

                        -- Spawn children with different parents
                        local child1 = world:spawn(ChildOf(parent1) as tecs.Component)
                        local child2 = world:spawn(ChildOf(parent2) as tecs.Component)
                        world:update(0)

                        -- Query for children of parent1
                        local query1 = world:query({include = {ChildOf:targeting(parent1)}})
                        local found1: {integer: boolean} = {}
                        for archetype, len, entities in query1:iter() do
                            for row = 1, len do
                                found1[entities[row]] = true
                            end
                        end

                        luassert.is_true(found1[child1], "child1 should be found targeting parent1")
                        luassert.is_nil(found1[child2], "child2 should NOT be found (targets parent2)")
                    end
                )
            end
        )

        describe(
            "world:getFirstRelationship",
            function()
                it(
                    "should return the relationship instance with correct target",
                    function()
                        local ChildOf = tecs.ecs.newRelationship({name = "ChildOfGetFirstTest", exclusive = true})

                        local parent = world:spawn()
                        local child = world:spawn(ChildOf(parent) as tecs.Component)
                        world:update(0)

                        local rel = world:getFirstRelationship(child, ChildOf)
                        luassert.is_not_nil(rel, "should return relationship instance")
                        luassert.equals(parent, rel.target, "should have correct target")
                    end
                )

                it(
                    "last exclusive sibling wins when multiple passed to spawn",
                    function()
                        local ChildOf = tecs.ecs.newRelationship({name = "ChildOfExclusiveSpawnTest", exclusive = true})

                        local parent1 = world:spawn()
                        local parent2 = world:spawn()
                        local parent3 = world:spawn()

                        -- Spawn with three exclusive siblings: only the last should win
                        local child = world:spawn(
                            ChildOf(parent1) as tecs.Component,
                            ChildOf(parent2) as tecs.Component,
                            ChildOf(parent3) as tecs.Component
                        )
                        world:update(0)

                        local rel = world:getFirstRelationship(child, ChildOf)
                        luassert.is_not_nil(rel, "should return relationship instance")
                        luassert.equals(parent3, rel.target, "last exclusive sibling should win")
                    end
                )

                it(
                    "interleaved exclusive containers resolve independently in spawn",
                    function()
                        local ChildOf = tecs.ecs.newRelationship({name = "ChildOfInterleavedTest", exclusive = true})
                        local MemberOf = tecs.ecs.newRelationship({name = "MemberOfInterleavedTest", exclusive = true})

                        local parentA = world:spawn()
                        local parentB = world:spawn()
                        local groupA = world:spawn()
                        local groupB = world:spawn()

                        -- Interleave two different exclusive containers in the same spawn.
                        -- Pattern: ChildOf(A), MemberOf(A), ChildOf(B), MemberOf(B)
                        -- Expected: only ChildOf(B) and MemberOf(B) survive.
                        local entity = world:spawn(
                            ChildOf(parentA) as tecs.Component,
                            MemberOf(groupA) as tecs.Component,
                            ChildOf(parentB) as tecs.Component,
                            MemberOf(groupB) as tecs.Component
                        )
                        world:update(0)

                        local childRel = world:getFirstRelationship(entity, ChildOf)
                        local memberRel = world:getFirstRelationship(entity, MemberOf)
                        luassert.is_not_nil(childRel, "should have ChildOf relationship")
                        luassert.is_not_nil(memberRel, "should have MemberOf relationship")
                        luassert.equals(parentB, childRel.target, "ChildOf should resolve to last B")
                        luassert.equals(groupB, memberRel.target, "MemberOf should resolve to last B")
                    end
                )

                it(
                    "should return nil for entities without the relationship",
                    function()
                        local ChildOf = tecs.ecs.newRelationship({name = "ChildOfGetFirstNilTest", exclusive = true})

                        local entity = world:spawn()
                        world:update(0)

                        local rel = world:getFirstRelationship(entity, ChildOf)
                        luassert.is_nil(rel, "should return nil for entity without relationship")
                    end
                )

                it(
                    "should return correct target after reparenting",
                    function()
                        local ChildOf = tecs.ecs.newRelationship({
                            name = "ChildOfGetFirstReparentTest", exclusive = true
                        })

                        local parent1 = world:spawn()
                        local parent2 = world:spawn()
                        local child = world:spawn(ChildOf(parent1) as tecs.Component)
                        world:update(0)

                        -- Reparent
                        world:set(child, ChildOf(parent2) as tecs.Component)
                        world:update(0)

                        local rel = world:getFirstRelationship(child, ChildOf)
                        luassert.is_not_nil(rel, "should return relationship after reparent")
                        luassert.equals(parent2, rel.target, "should have new parent as target")
                    end
                )

                it(
                    "should work with non-exclusive relationships",
                    function()
                        local Likes = tecs.ecs.newRelationship({name = "LikesGetFirstTest"})

                        local target1 = world:spawn()
                        local target2 = world:spawn()
                        local entity = world:spawn(Likes(target1) as tecs.Component, Likes(target2) as tecs.Component)
                        world:update(0)

                        local rel = world:getFirstRelationship(entity, Likes)
                        luassert.is_not_nil(rel, "should return a relationship instance")
                        -- Should be one of the two targets
                        local target = rel.target
                        luassert.is_true(
                            target == target1 or target == target2, "should return one of the relationship targets"
                        )
                    end
                )
            end
        )

        describe(
            "high-generation targets (int32 -> double)",
            function()
                -- Recycle a single slot until its generation pushes the packed id past
                -- the signed-int32 boundary (2^31). The packed id is
                -- slot + generation * 2^22, so generation must climb past ~512. An
                -- int32 target field truncates here; a double round-trips exactly.
                local function churnHighGenEntity(): integer
                    local id: integer
                    for i = 1, 600 do
                        id = world:spawn()
                        if i < 600 then
                            world:despawn(id)
                            world:update(0)
                        end
                    end
                    return id
                end

                it(
                    "round-trips a relationship target past the int32 boundary",
                    function()
                        local Likes = tecs.ecs.newRelationship({name = "LikesHighGen"})

                        local target = churnHighGenEntity()
                        luassert.is_true(target > 2 ^ 31, "churn should drive the target id past the int32 boundary")

                        local liker = world:spawn(Likes(target) as tecs.Component)
                        world:update(0)

                        local rel = world:getFirstRelationship(liker, Likes)
                        luassert.is_not_nil(rel, "should return a relationship instance")
                        luassert.equals(target, rel.target, "target must round-trip without int32 truncation")
                    end
                )

                it(
                    "cascade-deletes children of a high-generation parent",
                    function()
                        local ChildOf = tecs.ecs.newRelationship({
                            name = "ChildOfHighGen",
                            exclusive = true,
                            sparse = true,
                            reverseIndex = true,
                            cascadeDelete = true,
                        })

                        local parent = churnHighGenEntity()
                        luassert.is_true(parent > 2 ^ 31, "churn should drive the parent id past the int32 boundary")

                        local child = world:spawn(ChildOf(parent) as tecs.Component)
                        world:update(0)
                        luassert.is_true(world:isAlive(child), "child should be alive")

                        world:despawn(parent)
                        world:update(0)
                        luassert.is_false(world:isAlive(child), "child of a high-gen parent should cascade delete")
                    end
                )
            end
        )

        describe(
            "dense table relationship component ids",
            function()
                local record OwesRec is tecs.Component
                    amount: number
                end

                local Owes = tecs.ecs.newRelationship({
                    name = "DenseRelIdOwes",
                    container = OwesRec,
                    fields = {"amount"},
                })

                it(
                    "allocates a distinct id per instance",
                    function()
                        local t1 = world:spawn()
                        local t2 = world:spawn()
                        world:commit()

                        local containerId = (Owes as {any: any}).componentId as integer
                        local a = Owes:targeting(t1) as {any: any}
                        local b = Owes:targeting(t2) as {any: any}

                        luassert.not_equals(containerId, a.componentId as integer)
                        luassert.not_equals(containerId, b.componentId as integer)
                        luassert.not_equals(a.componentId as integer, b.componentId as integer)

                        -- The container must keep its own by-id entry.
                        local componentsInternal = require("tecs.internal.components")
                        local byId = componentsInternal.componentsById as {integer: any}
                        luassert.equals(Owes, byId[containerId])
                    end
                )

                it(
                    "matches only the queried target after new archetypes appear",
                    function()
                        local t1 = world:spawn()
                        local t2 = world:spawn()
                        world:commit()

                        local q = world:query({include = {Owes:targeting(t1) as tecs.Component}})

                        local e1 = world:spawn(Owes(t1) as tecs.Component)
                        world:commit()
                        -- Creates a new archetype after the query exists; it must not
                        -- match through a signature bit shared with the container.
                        local e2 = world:spawn(Owes(t2) as tecs.Component)
                        world:commit()

                        local count = 0
                        local seen: {integer: boolean} = {}
                        for _, len, entities in q:iter() do
                            for r = 1, len do
                                count = count + 1
                                seen[entities[r]] = true
                            end
                        end

                        luassert.equals(1, count)
                        luassert.is_true(seen[e1])
                        luassert.is_nil(seen[e2])
                    end
                )
            end
        )

        describe(
            "target-only relationship options",
            function()
                it(
                    "forwards serialize and deserialize through the FFI redirect",
                    function()
                        local testId = math.random(1, 1000000)
                        local myS = function(value: any): {string: any}
                            return {target = (value as {string: any}).target as integer}
                        end
                        local myD = function(_w: tecs.World, data: {string: any}): any return data end
                        local Rel = tecs.ecs.newRelationship({
                            name = "RedirectForward" .. testId,
                            serialize = (myS as any),
                            deserialize = (myD as any),
                        })

                        luassert.equals(
                            myS,
                            (Rel as {string: any}).serialize,
                            "target-only redirect must not drop a custom serialize"
                        )
                        luassert.equals(
                            myD,
                            (Rel as {string: any}).deserialize,
                            "target-only redirect must not drop a custom deserialize"
                        )
                    end
                )
            end
        )
    end
)
