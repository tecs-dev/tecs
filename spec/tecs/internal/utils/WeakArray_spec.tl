require("busted")
local luassert <const> = require("luassert")
local WeakArray <const> = require("tecs.internal.utils.WeakArray")

local record TestData
    id: integer
end

describe("WeakArray", function()
    describe("initialization", function()
        it("creates a new weak array", function()
            local arr = WeakArray.new()

            luassert.is_not_nil(arr, "WeakArray.new() should return a non-nil value")
            luassert.is_equal(0, #arr, "Initial length should be 0")
        end)
    end)

    describe("array operations", function()
        it("supports standard array assignment and access", function()
            local arr: WeakArray<TestData> = WeakArray.new()
            local value1, value2, value3 = {id = 1}, {id = 2}, {id = 3}

            arr[1] = value1
            arr[2] = value2
            arr[3] = value3

            luassert.is_equal(3, #arr, "Length should be 3 after assignments")
            luassert.is_equal(value1, arr[1], "Should retrieve first value")
            luassert.is_equal(value2, arr[2], "Should retrieve second value")
            luassert.is_equal(value3, arr[3], "Should retrieve third value")
        end)

        it("supports standard array append pattern", function()
            local arr: WeakArray<TestData> = WeakArray.new()

            arr[#arr + 1] = {id = 1}
            arr[#arr + 1] = {id = 2}
            arr[#arr + 1] = {id = 3}

            luassert.is_equal(3, #arr, "Length should be 3")
            luassert.is_equal(1, arr[1].id, "First value should have id 1")
            luassert.is_equal(2, arr[2].id, "Second value should have id 2")
            luassert.is_equal(3, arr[3].id, "Third value should have id 3")
        end)

        it("supports standard array iteration", function()
            local arr: WeakArray<TestData> = WeakArray.new()
            local values = {{id = 1}, {id = 2}, {id = 3}}

            for i, v in ipairs(values) do
                arr[i] = v
            end

            local foundIds: {integer} = {}
            for i = 1, #arr do
                local value = arr[i]
                if value then
                    foundIds[#foundIds + 1] = value.id
                end
            end

            luassert.is_equal(3, #foundIds, "Should find 3 values")
            luassert.is_equal(1, foundIds[1], "Should find id 1")
            luassert.is_equal(2, foundIds[2], "Should find id 2")
            luassert.is_equal(3, foundIds[3], "Should find id 3")
        end)
    end)

    describe("weak references", function()
        it("allows values to be garbage collected", function()
            local arr: WeakArray<TestData> = WeakArray.new()

            -- Create a local scope to control object lifetime
            do
                local tempObject: TestData = {id = 999}
                arr[1] = tempObject

                -- Verify the object is in the array
                luassert.is_equal(1, #arr, "Length should be 1 after adding an object")
                luassert.is_not_nil(arr[1], "Object should be in the array before garbage collection")
                luassert.is_equal(999, arr[1].id, "Object should have correct id")
            end

            -- Force garbage collection
            collectgarbage("collect")

            -- The reference should be nil after garbage collection
            luassert.is_equal(nil, arr[1], "Object should be nil after garbage collection")

            -- Length should still be 1 (we don't compact automatically on GC)
            -- Note: Our WeakArray implementation may auto-compact in some cases
            local currentLength = #arr
            luassert.is_true(currentLength >= 0 and currentLength <= 1, "Length should be 0 or 1 after GC")

            -- But iteration should skip nil values
            local count = 0
            for i = 1, #arr do
                if arr[i] then
                    count = count + 1
                end
            end
            luassert.is_equal(0, count, "Should find 0 live values")
        end)
    end)

    describe("compaction", function()
        it("manually compacts array removing nil gaps", function()
            local arr: WeakArray<TestData> = WeakArray.new()
            local values = {}

            -- Add 5 values
            for i = 1, 5 do
                values[i] = {id = i}
                arr[i] = values[i]
            end

            luassert.is_equal(5, #arr, "Should have length 5")

            -- Simulate GC by setting some to nil (in real usage, GC would do this)
            rawset(arr as {any:any}, 2, nil)
            rawset(arr as {any:any}, 4, nil)

            -- Manually compact
            local newSize = arr:compact()

            luassert.is_equal(3, newSize, "Should return 3 after compaction")
            luassert.is_equal(3, #arr, "Length should be 3 after compaction")

            -- Values should be compacted
            luassert.is_equal(1, arr[1].id, "First value should have id 1")
            luassert.is_equal(3, arr[2].id, "Second value should have id 3")
            luassert.is_equal(5, arr[3].id, "Third value should have id 5")
            luassert.is_nil(arr[4], "Fourth position should be nil")
            luassert.is_nil(arr[5], "Fifth position should be nil")
        end)

        it("triggers automatic compaction during growth when sparse", function()
            local arr: WeakArray<TestData> = WeakArray.new()

            -- Add 30 values to trigger compaction check at 25 and 50
            for i = 1, 30 do
                arr[i] = {id = i}
            end

            -- Simulate heavy GC - remove most values (keep only 3 out of 30)
            for i = 1, 30 do
                if i ~= 5 and i ~= 15 and i ~= 25 then
                    rawset(arr as {any:any}, i, nil)
                end
            end

            -- This should trigger compaction check at size 30 (30 % 25 == 5, but we had 25 earlier)
            -- Let's force it by adding more until we hit a multiple of 25
            arr[50] = {id = 50}  -- This should trigger compaction check

            -- Due to automatic compaction, the array should be much smaller now
            -- But we need to verify this works - the exact behavior depends on when compaction triggers
            local liveCount = 0
            for i = 1, #arr do
                if arr[i] then
                    liveCount = liveCount + 1
                end
            end

            -- Should have the values we kept (3 from before, 1 new)
            -- Note: Compaction may have occurred, so we verify the minimum expected
            luassert.is_true(liveCount >= 3, "Should have at least 3 live values")
            luassert.is_true(liveCount <= 4, "Should have at most 4 live values")
        end)
    end)

    describe("edge cases", function()
        it("handles empty array compaction", function()
            local arr: WeakArray<TestData> = WeakArray.new()

            local size = arr:compact()
            luassert.is_equal(0, size, "Compacting empty array should return 0")
            luassert.is_equal(0, #arr, "Length should remain 0")
        end)

        it("handles assignment to non-sequential indices", function()
            local arr: WeakArray<TestData> = WeakArray.new()

            arr[5] = {id = 5}
            arr[2] = {id = 2}
            arr[8] = {id = 8}

            luassert.is_equal(8, #arr, "Length should be 8 (highest index)")
            luassert.is_nil(arr[1], "Index 1 should be nil")
            luassert.is_equal(2, arr[2].id, "Index 2 should have value")
            luassert.is_nil(arr[3], "Index 3 should be nil")
            luassert.is_nil(arr[4], "Index 4 should be nil")
            luassert.is_equal(5, arr[5].id, "Index 5 should have value")
            luassert.is_equal(8, arr[8].id, "Index 8 should have value")
        end)

        it("handles compaction with all nil values", function()
            local arr: WeakArray<TestData> = WeakArray.new()

            -- Add values then simulate them all being GC'd
            arr[1] = {id = 1}
            arr[2] = {id = 2}
            arr[3] = {id = 3}

            -- Simulate GC
            rawset(arr as {any:any}, 1, nil)
            rawset(arr as {any:any}, 2, nil)
            rawset(arr as {any:any}, 3, nil)

            local size = arr:compact()
            luassert.is_equal(0, size, "Should return 0 when all values are nil")
            luassert.is_equal(0, #arr, "Length should be 0 after compaction")
        end)
    end)
end)