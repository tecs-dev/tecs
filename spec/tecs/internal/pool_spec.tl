require("busted")
local tecs = require("tecs")
local luassert = require("luassert")
local describe <const> = describe
local it <const> = it
local after_each <const> = after_each

describe("pool", function()
    local pool = tecs.pool

    after_each(function()
        -- Clear pools after each test to ensure clean state
        pool.clear()
    end)

    describe("array pooling", function()
        it("should acquire and release arrays", function()
            local array1: {any} = pool.acquireArray()
            luassert.is_table(array1)
            luassert.is_equal(0, #array1)

            -- Add some data
            array1[1] = "test"
            array1[2] = "data"

            -- Release it
            pool.releaseArray(array1)

            -- Acquire again, should get the same table cleared
            local array2: {any} = pool.acquireArray()
            luassert.is_equal(array1, array2) -- Same table reference
            luassert.is_equal(0, #array2) -- But cleared
        end)

        it("should create new arrays when pool is empty", function()
            local array1: {any} = pool.acquireArray()
            local array2: {any} = pool.acquireArray()
            luassert.is_not_equal(array1, array2)
        end)

        it("should not pool arrays larger than 2000 entries", function()
            local largeArray: {any} = pool.acquireArray()

            -- Fill with 2001 entries
            for i = 1, 2001 do
                largeArray[i] = i
            end

            pool.releaseArray(largeArray)

            -- Should get a new array, not the large one
            local newArray: {any} = pool.acquireArray()
            luassert.is_not_equal(largeArray, newArray)
            luassert.is_equal(0, #newArray)
        end)

        it("should respect maximum pool size of 32", function()
            -- Create and release 40 arrays (more than max pool size)
            for _ = 1, 40 do
                local arr: {any} = pool.acquireArray()
                pool.releaseArray(arr)
            end

            -- The pool should now have 32 arrays (the maximum)
            -- When we acquire arrays, we should get pooled ones (cleared)
            local acquired: {table} = {}
            for i = 1, 32 do
                acquired[i] = pool.acquireArray()
                luassert.is_equal(0, #(acquired[i] as {any}), "Pooled array should be empty")
            end

            -- The 33rd should be a new array
            local newArray: {any} = pool.acquireArray()
            luassert.is_equal(0, #newArray, "New array should be empty")

            -- Just verify it's distinct from the others
            for i = 1, 32 do
                luassert.is_not_equal(acquired[i], newArray)
            end
        end)

        it("should clear arrays when releasing", function()
            local array: {any} = pool.acquireArray()
            array[1] = "value1"
            array[2] = "value2"
            array[3] = "value3"

            pool.releaseArray(array)

            -- Check that the array was cleared
            luassert.is_nil(array[1])
            luassert.is_nil(array[2])
            luassert.is_nil(array[3])
            luassert.is_equal(0, #array)
        end)
    end)

    describe("map pooling", function()
        it("should acquire and release maps", function()
            local map1: {any:any} = pool.acquireMap()
            luassert.is_table(map1)

            -- Add some data
            map1["key1"] = "value1"
            map1["key2"] = "value2"

            -- Release it
            pool.releaseMap(map1)

            -- Acquire again, should get the same table cleared
            local map2: {any:any} = pool.acquireMap()
            luassert.is_equal(map1, map2) -- Same table reference
            luassert.is_nil(map2["key1"]) -- But cleared
            luassert.is_nil(map2["key2"])
        end)

        it("should create new maps when pool is empty", function()
            local map1: {any:any} = pool.acquireMap()
            local map2: {any:any} = pool.acquireMap()
            luassert.is_not_equal(map1, map2)
        end)

        it("should respect maximum pool size of 32 for maps", function()
            -- Create and release 40 maps (more than max pool size)
            for _ = 1, 40 do
                local m: {any:any} = pool.acquireMap()
                pool.releaseMap(m)
            end

            -- The pool should now have 32 maps (the maximum)
            -- When we acquire maps, we should get pooled ones (cleared)
            local acquired: {table} = {}
            for i = 1, 32 do
                acquired[i] = pool.acquireMap()
                -- Check it's empty
                local count = 0
                for _ in pairs(acquired[i] as {any:any}) do
                    count = count + 1
                end
                luassert.is_equal(0, count, "Pooled map should be empty")
            end

            -- The 33rd should be a new map
            local newMap: {any:any} = pool.acquireMap()
            local count = 0
            for _ in pairs(newMap) do
                count = count + 1
            end
            luassert.is_equal(0, count, "New map should be empty")

            -- Just verify it's distinct from the others
            for i = 1, 32 do
                luassert.is_not_equal(acquired[i], newMap)
            end
        end)

        it("should clear maps when releasing", function()
            local map: {any:any} = pool.acquireMap()
            map["key1"] = "value1"
            map["key2"] = "value2"
            map[123] = "value3"

            pool.releaseMap(map)

            -- Check that the map was cleared
            luassert.is_nil(map["key1"])
            luassert.is_nil(map["key2"])
            luassert.is_nil(map[123])
        end)
    end)

    describe("clear function", function()
        it("should clear all pools", function()
            -- Fill both pools
            local arrays: {table} = {}
            local maps: {table} = {}

            for i = 1, 10 do
                local arr: {any} = pool.acquireArray()
                arrays[i] = arr
                local m: {any:any} = pool.acquireMap()
                maps[i] = m
            end

            for i = 1, 10 do
                pool.releaseArray(arrays[i])
                pool.releaseMap(maps[i])
            end

            -- Clear all pools
            pool.clear()

            -- New acquisitions should be new tables
            local newArray: {any} = pool.acquireArray()
            local newMap: {any:any} = pool.acquireMap()

            for i = 1, 10 do
                luassert.is_not_equal(arrays[i], newArray)
                luassert.is_not_equal(maps[i], newMap)
            end
        end)
    end)

    describe("type safety", function()
        it("should work with typed arrays", function()
            local stringArray: {string} = pool.acquireArray()
            stringArray[1] = "hello"
            stringArray[2] = "world"

            pool.releaseArray(stringArray)

            local reacquired: {string} = pool.acquireArray()
            luassert.is_equal(stringArray, reacquired)
        end)

        it("should work with typed maps", function()
            local numberMap: {string: number} = pool.acquireMap()
            numberMap["one"] = 1
            numberMap["two"] = 2

            pool.releaseMap(numberMap)

            local reacquired: {string: number} = pool.acquireMap()
            luassert.is_equal(numberMap, reacquired)
        end)
    end)
end)