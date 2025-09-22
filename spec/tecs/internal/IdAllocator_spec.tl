local IdAllocator <const> = require("tecs.internal.IdAllocator")
local WorldImpl <const> = require("tecs.internal.world")

describe("IdAllocator", function()

    describe("allocSlot / freeSlot", function()
        it("allocates sequential fresh slots", function()
            local allocator = IdAllocator.new()
            local s1 = IdAllocator.allocSlot(allocator)
            local s2 = IdAllocator.allocSlot(allocator)
            assert.equals(1, s1)
            assert.equals(2, s2)
        end)

        it("reserves slot 0 as the null sentinel", function()
            local allocator = IdAllocator.new()
            assert.equals(1, allocator.nextFreshSlot)
        end)

        it("reuses freed slots via the stack (LIFO)", function()
            local allocator = IdAllocator.new()
            local s1 = IdAllocator.allocSlot(allocator)
            local s2 = IdAllocator.allocSlot(allocator)
            local s3 = IdAllocator.allocSlot(allocator)
            IdAllocator.freeSlot(allocator, s1)
            IdAllocator.freeSlot(allocator, s2)
            IdAllocator.freeSlot(allocator, s3)
            -- LIFO: last freed is first reused.
            local r1 = IdAllocator.allocSlot(allocator)
            local r2 = IdAllocator.allocSlot(allocator)
            local r3 = IdAllocator.allocSlot(allocator)
            assert.equals(s3, r1)
            assert.equals(s2, r2)
            assert.equals(s1, r3)
        end)

        it("zeros archetypeId on free", function()
            local allocator = IdAllocator.new()
            local s = IdAllocator.allocSlot(allocator)
            local slots = allocator.slots as {integer: {string: integer}}
            slots[s].archetypeId = 5
            slots[s].row = 7
            IdAllocator.freeSlot(allocator, s)
            -- archetypeId is the liveness sentinel and must be zeroed.
            -- row is not zeroed because nothing reads row when
            -- archetypeId == 0, and drain overwrites it on reuse.
            assert.equals(0, slots[s].archetypeId)
        end)

        it("bumps generation in the sidecar on free", function()
            local allocator = IdAllocator.new()
            local s = IdAllocator.allocSlot(allocator)
            local before = IdAllocator.generationOf(allocator, s)
            IdAllocator.freeSlot(allocator, s)
            local after = IdAllocator.generationOf(allocator, s)
            assert.equals(before + 1, after)
        end)
    end)

    describe("preallocated capacity", function()
        it("allocates maxSlotCount slots upfront with default", function()
            local allocator = IdAllocator.new()
            assert.equals(IdAllocator.DEFAULT_MAX_SLOT_COUNT, allocator.maxSlotCount)
            -- Allocate well past any old incremental-growth boundary; no grow
            -- path exists so this must simply succeed.
            for _ = 1, 10000 do
                IdAllocator.allocSlot(allocator)
            end
            assert.equals(10001, allocator.nextFreshSlot)
        end)

        it("respects a custom maxSlotCount", function()
            local allocator = IdAllocator.new(1024)
            assert.equals(1024, allocator.maxSlotCount)
        end)

        it("errors when maxSlotCount is exhausted", function()
            local allocator = IdAllocator.new(64)
            allocator.nextFreshSlot = 64
            assert.has_error(function()
                IdAllocator.allocSlot(allocator)
            end)
        end)

        it("rejects maxSlotCount above the format cap", function()
            assert.has_error(function()
                IdAllocator.new(IdAllocator.ABSOLUTE_MAX_SLOT_COUNT * 2)
            end)
        end)
    end)

    describe("free stack under churn", function()
        it("handles thousands of free/alloc pairs", function()
            local allocator = IdAllocator.new()
            local freedOrder: {integer} = {}
            for _ = 1, 5000 do
                local s = IdAllocator.allocSlot(allocator)
                freedOrder[#freedOrder + 1] = s
            end
            for i = 1, #freedOrder do
                IdAllocator.freeSlot(allocator, freedOrder[i])
            end
            -- LIFO: pop in reverse order of frees.
            for i = #freedOrder, 1, -1 do
                local reused = IdAllocator.allocSlot(allocator)
                assert.equals(freedOrder[i], reused)
            end
        end)
    end)

    describe("allocContiguousSlots", function()
        it("returns consecutive slots", function()
            local allocator = IdAllocator.new()
            local first = IdAllocator.allocContiguousSlots(allocator, 5)
            local nextSlot = IdAllocator.allocSlot(allocator)
            assert.equals(first + 5, nextSlot)
        end)

        it("ignores the free stack to guarantee contiguity", function()
            local allocator = IdAllocator.new()
            local s1 = IdAllocator.allocSlot(allocator)
            local s2 = IdAllocator.allocSlot(allocator)
            IdAllocator.freeSlot(allocator, s1)
            IdAllocator.freeSlot(allocator, s2)
            local first = IdAllocator.allocContiguousSlots(allocator, 3)
            assert.is_true(first > s2)
        end)

        it("rejects non-positive counts", function()
            local allocator = IdAllocator.new()
            assert.has_error(function()
                IdAllocator.allocContiguousSlots(allocator, 0)
            end)
            assert.has_error(function()
                IdAllocator.allocContiguousSlots(allocator, -1)
            end)
        end)
    end)

    describe("reset", function()
        it("wipes state and rewinds nextFreshSlot", function()
            local allocator = IdAllocator.new()
            for _ = 1, 10 do
                IdAllocator.allocSlot(allocator)
            end
            IdAllocator.reset(allocator)
            assert.equals(1, allocator.nextFreshSlot)
            assert.equals(0, allocator.freeCount)
        end)

        it("invalidates stale handles before a slot is reused", function()
            local world = WorldImpl.new({maxEntities = 8})
            local stale = world:spawn()
            world:commit()

            world:clearEntities()

            local fresh = world:spawn()
            world:commit()

            assert.is_false(world:isAlive(stale))
            assert.is_true(world:isAlive(fresh))
            assert.not_equals(stale, fresh)
        end)
    end)
end)
