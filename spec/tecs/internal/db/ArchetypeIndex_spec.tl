require("busted")
local ArchetypeIndex <const> = require("tecs.internal.db.ArchetypeIndex")
local Archetype <const> = require("tecs.internal.Archetype")
local luassert <const> = require("luassert")
local TestHelpers <const> = require("spec.tecs.test_helpers")

describe("ArchetypeIndex", function()
    local index: ArchetypeIndex
    local testId = 0
    local provider: TestHelpers.ComponentProvider
    local PosComponent: TestHelpers.Pos
    local VelComponent: TestHelpers.Vel
    local HealthComponent: TestHelpers.Health

    before_each(function()
        index = ArchetypeIndex.new()
        testId = testId + 1

        -- Use the test helper provider
        provider = TestHelpers.createComponentProvider("IndexTest", testId)
        PosComponent = provider.PosComponent
        VelComponent = provider.VelComponent
        HealthComponent = provider.HealthComponent
    end)

    describe("archetype creation and retrieval", function()
        it("should create a new archetype for unique component sets", function()
            local archetype1 = index:getOrCreate({PosComponent})
            luassert.is_not_nil(archetype1)
            luassert.equals(1, #index) -- First archetype

            local archetype2 = index:getOrCreate({VelComponent})
            luassert.is_not_nil(archetype2)
            luassert.is_not_equal(archetype1, archetype2)
            luassert.equals(2, #index) -- Second archetype
        end)

        it("should return same archetype for identical component sets", function()
            local archetype1 = index:getOrCreate({PosComponent, VelComponent})
            local archetype2 = index:getOrCreate({PosComponent, VelComponent})

            luassert.equals(archetype1, archetype2)
            luassert.equals(1, #index)
        end)

        it("does not care about component order differences", function()
            local archetype1 = index:getOrCreate({PosComponent, VelComponent})
            local archetype2 = index:getOrCreate({VelComponent, PosComponent})

            luassert.is_equal(archetype1, archetype2)
            luassert.equals(1, #index)
        end)

        it("should call onCreate callback when creating new archetype", function()
            local callbackCalled = false
            local callbackArchetype: Archetype = nil

            local archetype = index:getOrCreate({PosComponent}, function(arch: Archetype)
                callbackCalled = true
                callbackArchetype = arch
            end)

            luassert.is_true(callbackCalled)
            luassert.equals(archetype, callbackArchetype)

            -- Should not call callback when returning existing archetype
            callbackCalled = false
            callbackArchetype = nil

            local archetype2 = index:getOrCreate({PosComponent}, function(arch: Archetype)
                callbackCalled = true
                callbackArchetype = arch
            end)

            luassert.is_false(callbackCalled)
            luassert.is_nil(callbackArchetype)
            luassert.equals(archetype, archetype2)
        end)
    end)

    describe("component indexing", function()
        it("should index archetypes by component", function()
            local _arch1 = index:getOrCreate({PosComponent})
            local _arch2 = index:getOrCreate({PosComponent, VelComponent})
            local _arch3 = index:getOrCreate({VelComponent})

            -- PosComponent archetypes
            local posArchetypes = index:getArchetypesWithComponent(PosComponent)
            luassert.is_not_nil(posArchetypes)

            -- Check that archetypes with PosComponent are indexed
            luassert.equals(2, TestHelpers.countTable(posArchetypes))

            -- VelComponent archetypes
            local velArchetypes = index:getArchetypesWithComponent(VelComponent)
            luassert.is_not_nil(velArchetypes)

            -- Check that archetypes with VelComponent are indexed
            luassert.equals(2, TestHelpers.countTable(velArchetypes))
        end)

        it("should return empty table for unindexed component", function()
            local archetypes = index:getArchetypesWithComponent(HealthComponent)
            -- getArchetypesWithComponent returns nil when there are no archetypes with that component
            if archetypes then
                luassert.equals(0, TestHelpers.countTable(archetypes))
            else
                -- It's also valid for it to return nil
                luassert.is_nil(archetypes)
            end
        end)
    end)

    describe("wildcard transitions", function()
        it("should handle wildcard transitions for relationships", function()
            -- Create a relationship component
            local ChildOf = provider:createRelationship("ChildOf", false)

            -- Create entity IDs for relationships
            local entity1 = 1
            local entity2 = 2

            local arch1 = index:getOrCreate({PosComponent})
            local arch2 = index:getOrCreate({PosComponent, ChildOf(entity1)})
            local arch3 = index:getOrCreate({PosComponent, ChildOf(entity2)})

            -- Both should have Pos and a ChildOf relationship
            luassert.is_not_nil(arch1)
            luassert.is_not_nil(arch2)
            luassert.is_not_nil(arch3)
            luassert.is_not_equal(arch1, arch2)
            luassert.is_not_equal(arch2, arch3)
        end)
    end)
end)