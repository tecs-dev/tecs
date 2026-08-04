local IdAllocator <const> = require("tecs.internal.IdAllocator")
local WorldImpl <const> = require("tecs.internal.world")

describe(
    "IdAllocator",
    function()
        describe(
            "allocSlot / freeSlot",
            function()
                it(
                    "allocates sequential fresh slots",
                    function()
                        local allocator = IdAllocator.new()
                        local s1 = IdAllocator.allocSlot(allocator)
                        local s2 = IdAllocator.allocSlot(allocator)
                        assert.equals(1, s1)
                        assert.equals(2, s2)
                    end
                )

                it(
                    "reserves slot 0 as the null sentinel",
                    function() local allocator = IdAllocator.new(); assert.equals(1, allocator.nextFreshSlot) end
                )

                it(
                    "reuses freed slots via the stack (LIFO)",
                    function()
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
                    end
                )

                it(
                    "zeros archetypeId on free",
                    function()
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
                    end
                )

                it(
                    "bumps generation in the sidecar on free",
                    function()
                        local allocator = IdAllocator.new()
                        local s = IdAllocator.allocSlot(allocator)
                        local before = allocator.slots[s].generation
                        IdAllocator.freeSlot(allocator, s)
                        local after = allocator.slots[s].generation
                        assert.equals(before + 1, after)
                    end
                )
            end
        )

        describe(
            "preallocated capacity",
            function()
                it(
                    "allocates maxSlotCount slots upfront with default",
                    function()
                        local allocator = IdAllocator.new()
                        assert.equals(IdAllocator.DEFAULT_MAX_SLOT_COUNT, allocator.maxSlotCount)
                        -- Every configured slot is available without growing.
                        for _ = 1, 10000 do
                            IdAllocator.allocSlot(allocator)
                        end
                        assert.equals(10001, allocator.nextFreshSlot)
                    end
                )

                it(
                    "respects a custom maxSlotCount",
                    function() local allocator = IdAllocator.new(1024); assert.equals(1024, allocator.maxSlotCount) end
                )

                it(
                    "errors when maxSlotCount is exhausted",
                    function()
                        local allocator = IdAllocator.new(64)
                        allocator.nextFreshSlot = 65
                        assert.has_error(function() IdAllocator.allocSlot(allocator) end)
                    end
                )

                it(
                    "allocates exactly maxSlotCount usable slots",
                    function()
                        local allocator = IdAllocator.new(3)
                        assert.equals(1, IdAllocator.allocSlot(allocator))
                        assert.equals(2, IdAllocator.allocSlot(allocator))
                        assert.equals(3, IdAllocator.allocSlot(allocator))
                        assert.has_error(function() IdAllocator.allocSlot(allocator) end)
                    end
                )

                it(
                    "rejects maxSlotCount above the format cap",
                    function()
                        assert.has_error(function() IdAllocator.new(IdAllocator.ABSOLUTE_MAX_SLOT_COUNT * 2) end)
                    end
                )
            end
        )

        describe(
            "free stack under churn",
            function()
                it(
                    "handles thousands of free/alloc pairs",
                    function()
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
                    end
                )
            end
        )

        describe(
            "allocContiguousSlots",
            function()
                it(
                    "returns consecutive slots",
                    function()
                        local allocator = IdAllocator.new()
                        local first = IdAllocator.allocContiguousSlots(allocator, 5)
                        local nextSlot = IdAllocator.allocSlot(allocator)
                        assert.equals(first + 5, nextSlot)
                    end
                )

                it(
                    "ignores the free stack to guarantee contiguity",
                    function()
                        local allocator = IdAllocator.new()
                        local s1 = IdAllocator.allocSlot(allocator)
                        local s2 = IdAllocator.allocSlot(allocator)
                        IdAllocator.freeSlot(allocator, s1)
                        IdAllocator.freeSlot(allocator, s2)
                        local first = IdAllocator.allocContiguousSlots(allocator, 3)
                        assert.is_true(first > s2)
                    end
                )

                it(
                    "rejects non-positive counts",
                    function()
                        local allocator = IdAllocator.new()
                        assert.has_error(function() IdAllocator.allocContiguousSlots(allocator, 0) end)
                        assert.has_error(function() IdAllocator.allocContiguousSlots(allocator, -1) end)
                    end
                )
            end
        )

        describe(
            "reset",
            function()
                it(
                    "wipes state and rewinds nextFreshSlot",
                    function()
                        local allocator = IdAllocator.new()
                        for _ = 1, 10 do
                            IdAllocator.allocSlot(allocator)
                        end
                        IdAllocator.reset(allocator)
                        assert.equals(1, allocator.nextFreshSlot)
                        assert.equals(0, allocator.freeCount)
                    end
                )

                it(
                    "invalidates stale handles before a slot is reused",
                    function()
                        local world = WorldImpl.new({maxEntities = 8})
                        local stale = world:spawn()
                        world:enqueueCommit()

                        world:clearEntities()

                        local fresh = world:spawn()
                        world:enqueueCommit()

                        assert.is_false(world:isAlive(stale))
                        assert.is_true(world:isAlive(fresh))
                        assert.not_equals(stale, fresh)
                    end
                )

                it(
                    "raises the generation past one a spawnAt staked",
                    function()
                        -- `spawnAt` writes the caller's generation into the slot,
                        -- so the wipe has to clear that one as well as the ones
                        -- the allocator issued.
                        local world = WorldImpl.new({maxEntities = 8})
                        -- Encoding matches IdAllocator.encodeId, which is a
                        -- macroexp and so has no runtime function to call.
                        local stale = 1 + 1 * 2 ^ 22
                        world:spawnAt(stale)
                        world:enqueueCommit()

                        world:clearEntities()

                        local fresh = world:spawn()
                        world:enqueueCommit()

                        assert.equals(1, fresh % 2 ^ 22)
                        assert.not_equals(stale, fresh)
                        assert.is_false(world:isAlive(stale))
                        assert.is_true(world:isAlive(fresh))
                    end
                )

                it(
                    "raises the generation past one a batched spawnAt staked",
                    function()
                        local world = WorldImpl.new({maxEntities = 8})
                        local stale = 1 + 1 * 2 ^ 22
                        world:batchSpawnAt({stale}, {}, function() end)
                        world:enqueueCommit()

                        world:clearEntities()

                        local fresh = world:spawn()
                        world:enqueueCommit()

                        assert.equals(1, fresh % 2 ^ 22)
                        assert.not_equals(stale, fresh)
                        assert.is_false(world:isAlive(stale))
                        assert.is_true(world:isAlive(fresh))
                    end
                )

                it(
                    "raises the generation past one a despawn bumped",
                    function()
                        local world = WorldImpl.new({maxEntities = 8})
                        local first = world:spawn()
                        world:enqueueCommit()
                        world:despawn(first)
                        world:enqueueCommit()
                        local second = world:spawn()
                        world:enqueueCommit()

                        world:clearEntities()

                        local fresh = world:spawn()
                        world:enqueueCommit()

                        assert.is_false(world:isAlive(first))
                        assert.is_false(world:isAlive(second))
                        assert.is_true(world:isAlive(fresh))
                        assert.not_equals(first, fresh)
                        assert.not_equals(second, fresh)
                    end
                )
            end
        )
    end
)
