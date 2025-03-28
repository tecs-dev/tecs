require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

describe("relationships", function()
    local world: tecs.World

    before_each(function()
        world = tecs.newWorld()
    end)

    describe("relationship hooks - onAdd", function()
        it("should work with relationships", function()
            local addedCount = 0
            local receivedComponent: tecs.Component = nil

            local Follows = tecs.newRelationship({
                name = "FollowsHookTest1",
                onAdd = function(self: tecs.Relationship, _world: tecs.World, _entityId: integer, _changes: tecs.ChangeView)
                    addedCount = addedCount + 1
                    receivedComponent = self
                end
            })

            local leader = world:spawn(tecs.builtins.Emitter())
            local _follower = world:spawn(Follows(leader) as tecs.Component)

            -- Commit the spawns to trigger hooks
            world:update(0)

            luassert.equals(1, addedCount, "onAdd should have been called once")
            luassert.is_not_nil(receivedComponent, "Should have received component")
            luassert.equals(leader, (receivedComponent as tecs.Relationship).target, "Should have correct target")
        end)
    end)

    describe("relationship hooks - onRemove", function()
        it("should receive correct component with target", function()
            local removedCount = 0
            local receivedComponent: tecs.Component = nil

            local ChildOf = tecs.newRelationship({
                name = "ChildOfHookTest1",
                exclusive = true,
                onRemove = function(self: tecs.Relationship, _w: tecs.World, _entityId: integer, _changes: tecs.ChangeView)
                    removedCount = removedCount + 1
                    receivedComponent = self
                end
            })

            local parent = world:spawn(tecs.builtins.Emitter())
            local child = world:spawn(ChildOf(parent) as tecs.Component)

            -- Commit the spawns first (spawn immutability rule)
            world:update(0)

            world:remove(child, ChildOf(parent) as tecs.Component)
            world:update(0)  -- Commit the removal

            luassert.equals(1, removedCount, "onRemove should have been called once")
            luassert.is_not_nil(receivedComponent, "Should have received component")
            luassert.equals(parent, (receivedComponent as tecs.Relationship).target, "Should have correct target")
        end)

        it("should cascade delete when parent is despawned", function()
            local ChildOf = tecs.newRelationship({
                name = "ChildOfCascadeTest",
                exclusive = true,
                onRemove = function(self: tecs.Relationship, w: tecs.World, entityId: integer, _changes: tecs.ChangeView)
                    local rel = self
                    -- Now we can detect if the parent was despawned
                    if not w:isAlive(rel.target) then
                        -- Parent was despawned, cascade delete
                        w:despawn(entityId)
                    end
                end
            })

            local parent = world:spawn(tecs.builtins.Emitter())
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
        end)

        it("should not cascade delete when relationship is just removed", function()
            local ChildOf = tecs.newRelationship({
                name = "ChildOfNoCascadeTest",
                exclusive = true,
                onRemove = function(self: tecs.Relationship, w: tecs.World, entityId: integer, _changes: tecs.ChangeView)
                    local rel = self
                    if not w:isAlive(rel.target) then
                        -- Only cascade if parent was despawned
                        w:despawn(entityId)
                    end
                end
            })

            local parent = world:spawn(tecs.builtins.Emitter())
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
        end)

        it("should not cascade delete when reparenting", function()
            local ChildOf = tecs.newRelationship({
                name = "ChildOfReparentTest",
                exclusive = true,
                onRemove = function(self: tecs.Relationship, w: tecs.World, entityId: integer, _changes: tecs.ChangeView)
                    local rel = self
                    if not w:isAlive(rel.target) then
                        w:despawn(entityId)
                    end
                end
            })

            local parent1 = world:spawn(tecs.builtins.Emitter())
            local parent2 = world:spawn(tecs.builtins.Emitter())
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
            luassert.equals(parent2, (childOfRel as tecs.Relationship).target, "Child should be child of parent2")
        end)
    end)

    describe("hook with data relationships", function()
        it("should work with relationships that have data", function()
            local record FollowsType is tecs.Relationship
                delay: number
            end

            local receivedDelay: number = nil

            local Follows = tecs.newRelationship({
                name = "FollowsDataTest",
                container = FollowsType,
                constructor = function(id: integer, ...: any): tecs.Relationship
                    local delay = (... as number) or 1.0
                    return {target = id, delay = delay, componentType = FollowsType as any} as FollowsType
                end,
                onAdd = function(self: FollowsType, _world: tecs.World, _entityId: integer, _changes: tecs.ChangeView)
                    local follows = self
                    receivedDelay = follows.delay
                end
            })

            local leader = world:spawn(tecs.builtins.Emitter())
            local _follower = world:spawn((Follows as function(integer, number): FollowsType)(leader, 2.5))

            -- Commit the spawns to trigger hooks
            world:update(0)

            luassert.equals(2.5, receivedDelay, "Should receive relationship data in hook")
        end)
    end)

    describe("relationship creation methods", function()
        local components = require("tecs.internal.components")
        local types = require("tecs.types")
        local type Relationship = types.Relationship

        before_each(function()
            -- Clear registered components to prevent conflicts
            for k in pairs(components.registeredComponents) do
                components.registeredComponents[k] = nil
            end
        end)

        describe("newTagRelationship", function()
            it("should create a basic tag relationship", function()
                local TagFollows = components.newTagRelationship({
                    name = "TagFollows"
                })

                luassert.is_not_nil(TagFollows)
                luassert.is_equal("TagFollows", TagFollows.componentName)
                luassert.is_not_nil(TagFollows.componentType)
                luassert.is_not_nil(TagFollows.exclusiveRelationship)
            end)

            it("should support exclusive option", function()
                local ExclusiveTag = components.newTagRelationship({
                    name = "ExclusiveTag",
                    exclusive = true
                })

                luassert.is_true(ExclusiveTag.exclusiveRelationship)
            end)

            it("should work with targeting method", function()
                local TagFollows2 = components.newTagRelationship({
                    name = "TagFollows2"
                })

                local entity1 = world:spawn()
                local entity2 = world:spawn()

                local targetingResult = TagFollows2:targeting(entity2)
                luassert.is_not_nil(targetingResult)
            end)
        end)

        describe("newFFIRelationship", function()
            it("should create an FFI relationship with data fields", function()
                local record TestFFIRel is Relationship
                    delay: number
                    power: integer
                end

                local FFIRel = components.newFFIRelationship({
                    name = "FFIRel",
                    container = TestFFIRel,
                    fields = {
                        {"delay", "float"},
                        {"power", "int32_t"}
                    }
                })

                luassert.is_not_nil(FFIRel)
                luassert.is_equal("FFIRel", FFIRel.componentName)
                luassert.is_equal(TestFFIRel, FFIRel.componentType)
                luassert.is_not_nil(FFIRel.exclusiveRelationship)
            end)

            it("should support exclusive option and targeting", function()
                local record ExclusiveFFIRel is Relationship
                    value: integer
                end

                local FFIRel = components.newFFIRelationship({
                    name = "ExclusiveFFIRel",
                    container = ExclusiveFFIRel,
                    fields = {{"value", "int32_t"}},
                    exclusive = true
                })

                luassert.is_true(FFIRel.exclusiveRelationship)

                local entity1 = world:spawn()
                local entity2 = world:spawn()

                local targetingResult = FFIRel:targeting(entity2)
                luassert.is_not_nil(targetingResult)
            end)
        end)

        describe("Integration test", function()
            it("should create both types without conflicts", function()
                local TagRel = components.newTagRelationship({
                    name = "PerfTagRel"
                })

                local record DataFFIRel is Relationship
                    value: number
                end

                local FFIDataRel = components.newFFIRelationship({
                    name = "PerfFFIDataRel",
                    container = DataFFIRel,
                    fields = {{"value", "double"}}
                })

                local TableRel = components.newRelationship({
                    name = "PerfTableRel"
                })

                luassert.is_not_nil(TagRel)
                luassert.is_not_nil(FFIDataRel)
                luassert.is_not_nil(TableRel)

                luassert.is_not_nil(TagRel.componentName)
                luassert.is_not_nil(FFIDataRel.componentName)
                luassert.is_not_nil(TableRel.componentName)
            end)
        end)
    end)
end)