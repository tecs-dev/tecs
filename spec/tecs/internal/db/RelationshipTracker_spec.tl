require("busted")
local RelationshipTracker <const> = require("tecs.internal.db.RelationshipTracker")
local types <const> = require("tecs.types")
local luassert <const> = require("luassert")
local TestHelpers <const> = require("spec.tecs.test_helpers")

describe("RelationshipTracker", function()
    local tracker: RelationshipTracker
    local testId = 0
    local provider: TestHelpers.ComponentProvider
    local relCounter = 0
    local nextEntityId = 1

    local function getNextId(): integer
        local id = nextEntityId
        nextEntityId = nextEntityId + 1
        return id
    end

    -- Helper to create a test relationship and instance
    local function createRel(target: integer, exclusive: boolean): types.Relationship
        relCounter = relCounter + 1
        local RelType = provider:createRelationship("Rel" .. relCounter, exclusive or false)
        return RelType(target) as types.Relationship
    end

    -- Helper to verify relationship exists in reverse dependencies
    local function assertRelationshipTracked(target: integer, rel: types.Relationship, source: integer)
        local reverseDeps = tracker:getReverseDependencies(target)
        luassert.is_not_nil(reverseDeps, "No reverse dependencies found for target")
        luassert.is_not_nil(reverseDeps[rel], "Relationship not found in reverse dependencies")
        luassert.is_true(reverseDeps[rel][source], "Source not tracked for relationship")
    end

    -- Helper to verify relationship doesn't exist
    local function assertRelationshipNotTracked(target: integer, rel: types.Relationship, source: integer)
        local reverseDeps = tracker:getReverseDependencies(target)
        if reverseDeps and reverseDeps[rel] then
            luassert.is_nil(reverseDeps[rel][source], "Source should not be tracked")
        end
    end

    -- Helper to create and track a relationship
    local function addRelationship(source: integer, target: integer, exclusive: boolean): types.Relationship
        local rel = createRel(target, exclusive)
        tracker:add(source, rel)
        return rel
    end

    before_each(function()
        tracker = RelationshipTracker.new()
        testId = testId + 1
        provider = TestHelpers.createComponentProvider("TrackerTest", testId)
        relCounter = 0
        nextEntityId = 1
    end)

    describe("relationship tracking", function()
        it("should track relationships from source to target", function()
            local source = getNextId()
            local target = getNextId()

            local rel = addRelationship(source, target, false)

            assertRelationshipTracked(target, rel, source)
        end)

        it("should track multiple relationships from same source", function()
            local source = getNextId()
            local target1 = getNextId()
            local target2 = getNextId()

            local rel1 = addRelationship(source, target1, false)
            local rel2 = addRelationship(source, target2, false)

            assertRelationshipTracked(target1, rel1, source)
            assertRelationshipTracked(target2, rel2, source)
        end)

        it("should track multiple sources for same target", function()
            local source1 = getNextId()
            local source2 = getNextId()
            local target = getNextId()

            local rel1 = addRelationship(source1, target, false)
            local rel2 = addRelationship(source2, target, false)

            assertRelationshipTracked(target, rel1, source1)
            assertRelationshipTracked(target, rel2, source2)
        end)
    end)

    describe("relationship removal", function()
        it("should remove relationships", function()
            local source = getNextId()
            local target = getNextId()

            local rel = addRelationship(source, target, false)
            tracker:remove(source, rel)

            assertRelationshipNotTracked(target, rel, source)
        end)

        it("should clean up empty entries", function()
            local source = getNextId()
            local target = getNextId()

            local rel = addRelationship(source, target, false)
            tracker:remove(source, rel)

            local reverseDeps = tracker:getReverseDependencies(target)
            if reverseDeps then
                luassert.is_nil(reverseDeps[rel], "Relationship should be cleaned up")
            end
        end)
    end)


    describe("entity cleanup", function()
        it("should clean up all relationships for an entity", function()
            local source1 = getNextId()
            local source2 = getNextId()
            local target = getNextId()

            addRelationship(source1, target, false)
            addRelationship(source2, target, false)

            tracker:cleanupEntity(target)

            local reverseDeps = tracker:getReverseDependencies(target)
            if reverseDeps then
                for _, sources in pairs(reverseDeps) do
                    if sources and next(sources as {integer: boolean}) then
                        error("Entity cleanup should remove all relationships")
                    end
                end
            end
        end)

        it("should handle cleanup of non-existent entity", function()
            local target = getNextId()

            -- Should not error
            luassert.has_no_errors(function()
                tracker:cleanupEntity(target)
            end, nil)
        end)
    end)
end)