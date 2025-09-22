require("busted")
-- This spec tests the SparseRelationshipStore impl which lives inside the
-- unified RelationshipStore module. Constructing with sparse=true returns the
-- Sparse impl directly.
local RelationshipStore <const> = require("tecs.internal.RelationshipStore")
local luassert <const> = require("luassert")
local describe <const> = describe
local it <const> = it

local function newSparseStore(cfg: {string: any}): any
    cfg.sparse = true
    return RelationshipStore.create(cfg as {any: any})
end

describe("SparseStore", function()

    describe("exclusive store", function()
        it("should set and get a value", function()
            local store = newSparseStore({exclusive = true})
            store:set(1, {target = 10})
            local val = store:get(1) as {string: integer}
            luassert.is_not_nil(val)
            luassert.equals(10, val.target)
        end)

        it("should return nil for missing entity", function()
            local store = newSparseStore({exclusive = true})
            luassert.is_nil(store:get(999))
        end)

        it("should replace value on second set", function()
            local store = newSparseStore({exclusive = true})
            store:set(1, {target = 10})
            local old = store:set(1, {target = 20}) as {string: integer}
            luassert.is_not_nil(old)
            luassert.equals(10, old.target)
            local val = store:get(1) as {string: integer}
            luassert.equals(20, val.target)
        end)

        it("should remove a value", function()
            local store = newSparseStore({exclusive = true})
            store:set(1, {target = 10})
            local old = store:remove(1) as {string: integer}
            luassert.is_not_nil(old)
            luassert.equals(10, old.target)
            luassert.is_nil(store:get(1))
        end)

        it("should return nil when removing non-existent entity", function()
            local store = newSparseStore({exclusive = true})
            luassert.is_nil(store:remove(999))
        end)

        it("should report has correctly", function()
            local store = newSparseStore({exclusive = true})
            luassert.is_false(store:has(1))
            store:set(1, {target = 10})
            luassert.is_true(store:has(1))
            store:remove(1)
            luassert.is_false(store:has(1))
        end)

        it("should getTarget for matching target", function()
            local store = newSparseStore({exclusive = true})
            store:set(1, {target = 10})
            local val = store:getTarget(1, 10) as {string: integer}
            luassert.is_not_nil(val)
            luassert.equals(10, val.target)
        end)

        it("should return nil from getTarget for wrong target", function()
            local store = newSparseStore({exclusive = true})
            store:set(1, {target = 10})
            luassert.is_nil(store:getTarget(1, 99))
        end)

        it("should removeOne for matching target", function()
            local store = newSparseStore({exclusive = true})
            store:set(1, {target = 10})
            local old, hasRemaining = store:removeOne(1, 10)
            luassert.is_not_nil(old)
            luassert.is_false(hasRemaining)
            luassert.is_nil(store:get(1))
        end)

        it("should not removeOne for wrong target", function()
            local store = newSparseStore({exclusive = true})
            store:set(1, {target = 10})
            local old, hasRemaining = store:removeOne(1, 99)
            luassert.is_nil(old)
            luassert.is_true(hasRemaining)
            luassert.is_not_nil(store:get(1))
        end)
    end)

    describe("non-exclusive store", function()
        it("should store multiple targets per entity", function()
            local store = newSparseStore({exclusive = false})
            store:set(1, {target = 10})
            store:set(1, {target = 20})
            luassert.is_not_nil(store:getTarget(1, 10))
            luassert.is_not_nil(store:getTarget(1, 20))
        end)

        it("should replace value for same target", function()
            local store = newSparseStore({exclusive = false})
            store:set(1, {target = 10, data = "old"})
            local old = store:set(1, {target = 10, data = "new"}) as {string: any}
            luassert.is_not_nil(old)
            luassert.equals("old", old.data)
            local val = store:getTarget(1, 10) as {string: any}
            luassert.equals("new", val.data)
        end)

        it("should removeOne specific target", function()
            local store = newSparseStore({exclusive = false})
            store:set(1, {target = 10})
            store:set(1, {target = 20})
            local old, hasRemaining = store:removeOne(1, 10)
            luassert.is_not_nil(old)
            luassert.is_true(hasRemaining, "should have remaining entries")
            luassert.is_nil(store:getTarget(1, 10))
            luassert.is_not_nil(store:getTarget(1, 20))
        end)

        it("should clear entity when last target removed via removeOne", function()
            local store = newSparseStore({exclusive = false})
            store:set(1, {target = 10})
            local _, hasRemaining = store:removeOne(1, 10)
            luassert.is_false(hasRemaining)
            luassert.is_false(store:has(1))
        end)

        it("should remove all targets with remove", function()
            local store = newSparseStore({exclusive = false})
            store:set(1, {target = 10})
            store:set(1, {target = 20})
            store:set(1, {target = 30})
            store:remove(1)
            luassert.is_false(store:has(1))
            luassert.is_nil(store:getTarget(1, 10))
            luassert.is_nil(store:getTarget(1, 20))
            luassert.is_nil(store:getTarget(1, 30))
        end)

        it("should return nil from getTarget for non-existent entity", function()
            local store = newSparseStore({exclusive = false})
            luassert.is_nil(store:getTarget(999, 10))
        end)
    end)

    describe("pairs iterator", function()
        it("should iterate all entries", function()
            local store = newSparseStore({exclusive = true})
            store:set(1, {target = 10})
            store:set(2, {target = 20})
            store:set(3, {target = 30})

            local found: {integer: boolean} = {}
            for entityId in store:pairs() do
                found[entityId] = true
            end
            luassert.is_true(found[1])
            luassert.is_true(found[2])
            luassert.is_true(found[3])
        end)

        it("should return empty iterator for empty store", function()
            local store = newSparseStore({exclusive = true})
            local count = 0
            for _ in store:pairs() do
                count = count + 1
            end
            luassert.equals(0, count)
        end)
    end)

    describe("reverseIndex (inverse index)", function()
        it("should track sources per target", function()
            local store = newSparseStore({exclusive = true, reverseIndex = true})
            store:set(1, {target = 100})
            store:set(2, {target = 100})
            store:set(3, {target = 200})

            local sources100: {integer} = {}
            store:forEachSource(100, function(src: integer)
                sources100[#sources100 + 1] = src
            end)
            luassert.equals(2, #sources100)

            local sources200: {integer} = {}
            store:forEachSource(200, function(src: integer)
                sources200[#sources200 + 1] = src
            end)
            luassert.equals(1, #sources200)
        end)

        it("should return empty iterator for unknown target", function()
            local store = newSparseStore({exclusive = true, reverseIndex = true})
            local count = 0
            store:forEachSource(999, function(_: integer)
                count = count + 1
            end)
            luassert.equals(0, count)
        end)

        it("should unlink from inverse on remove", function()
            local store = newSparseStore({exclusive = true, reverseIndex = true})
            store:set(1, {target = 100})
            store:set(2, {target = 100})
            store:remove(1)

            local sources: {integer} = {}
            store:forEachSource(100, function(src: integer)
                sources[#sources + 1] = src
            end)
            luassert.equals(1, #sources)
            luassert.equals(2, sources[1])
        end)

        it("should unlink old target on exclusive replace", function()
            local store = newSparseStore({exclusive = true, reverseIndex = true})
            store:set(1, {target = 100})
            store:set(1, {target = 200})

            local sources100: {integer} = {}
            store:forEachSource(100, function(src: integer)
                sources100[#sources100 + 1] = src
            end)
            luassert.equals(0, #sources100, "old target should have no sources")

            local sources200: {integer} = {}
            store:forEachSource(200, function(src: integer)
                sources200[#sources200 + 1] = src
            end)
            luassert.equals(1, #sources200, "new target should have the source")
        end)

        it("should unlink from inverse on removeOne", function()
            local store = newSparseStore({exclusive = false, reverseIndex = true})
            store:set(1, {target = 100})
            store:set(1, {target = 200})
            store:removeOne(1, 100)

            local sources100: {integer} = {}
            store:forEachSource(100, function(src: integer)
                sources100[#sources100 + 1] = src
            end)
            luassert.equals(0, #sources100)

            local sources200: {integer} = {}
            store:forEachSource(200, function(src: integer)
                sources200[#sources200 + 1] = src
            end)
            luassert.equals(1, #sources200)
        end)

        it("should unlink all targets on remove for non-exclusive", function()
            local store = newSparseStore({exclusive = false, reverseIndex = true})
            store:set(1, {target = 100})
            store:set(1, {target = 200})
            store:remove(1)

            local count = 0
            store:forEachSource(100, function(_: integer) count = count + 1 end)
            store:forEachSource(200, function(_: integer) count = count + 1 end)
            luassert.equals(0, count, "all inverse entries should be cleared")
        end)
    end)

    describe("removeTarget", function()
        it("should remove all sources targeting an entity (exclusive)", function()
            local store = newSparseStore({exclusive = true, reverseIndex = true})
            store:set(1, {target = 100})
            store:set(2, {target = 100})
            store:set(3, {target = 200})

            -- removeTarget returns a {[sourceId] = true} set of fully-cleared sources
            local cleared = store:removeTarget(100)
            local count = 0
            for _ in pairs(cleared) do count = count + 1 end
            luassert.equals(2, count)
            luassert.is_true(cleared[1] as boolean)
            luassert.is_true(cleared[2] as boolean)
            luassert.is_false(store:has(1))
            luassert.is_false(store:has(2))
            luassert.is_true(store:has(3), "entity targeting different target should survive")
        end)

        it("should return empty set for unknown target", function()
            local store = newSparseStore({exclusive = true, reverseIndex = true})
            local cleared = store:removeTarget(999)
            luassert.is_nil(next(cleared as {integer:boolean}), "should be an empty set")
        end)

        it("should only fully clear sources with no remaining targets (non-exclusive)", function()
            local store = newSparseStore({exclusive = false, reverseIndex = true})
            store:set(1, {target = 100})
            store:set(1, {target = 200})  -- entity 1 has two targets
            store:set(2, {target = 100})  -- entity 2 has one target

            local cleared = store:removeTarget(100)
            -- Entity 2 was fully cleared (only had target 100)
            -- Entity 1 still has target 200
            local count = 0
            for _ in pairs(cleared) do count = count + 1 end
            luassert.equals(1, count, "only entity 2 should be fully cleared")
            luassert.is_true(cleared[2] as boolean)
            luassert.is_true(store:has(1), "entity 1 should still exist (has target 200)")
            luassert.is_false(store:has(2), "entity 2 should be cleared")
        end)

        it("should clean up inverse entry for removed target", function()
            local store = newSparseStore({exclusive = true, reverseIndex = true})
            store:set(1, {target = 100})
            store:removeTarget(100)

            local count = 0
            store:forEachSource(100, function(_: integer) count = count + 1 end)
            luassert.equals(0, count, "inverse should be empty after removeTarget")
        end)
    end)

    describe("without reverseIndex", function()
        it("should work without inverse index", function()
            local store = newSparseStore({exclusive = true, reverseIndex = false})
            store:set(1, {target = 10})
            luassert.is_not_nil(store:get(1))
            store:remove(1)
            luassert.is_nil(store:get(1))
        end)

        it("should call nothing from forEachSource on unknown target", function()
            local store = newSparseStore({exclusive = true, reverseIndex = false})
            store:set(1, {target = 10})
            local count = 0
            store:forEachSource(10, function(_: integer) count = count + 1 end)
            luassert.equals(0, count)
        end)

        it("should return empty array from removeTarget", function()
            local store = newSparseStore({exclusive = true, reverseIndex = false})
            store:set(1, {target = 10})
            local cleared = store:removeTarget(10)
            luassert.equals(0, #cleared)
            luassert.is_true(store:has(1), "forward entry should still exist without inverse")
        end)
    end)
end)
