local ffi <const> = require("ffi")
local ChunkedArray <const> = require("tecs.internal.ffi.StableChunkedArray")

ffi.cdef("typedef struct { float x; float y; } ChunkedArrayTestVec2;")

describe(
    "ChunkedArray",
    function()
        describe(
            "new",
            function()
                it(
                    "creates an empty chunked array",
                    function()
                        local arr = ChunkedArray.new("int32_t")
                        assert.equals(1, arr.nextId)
                        assert.equals(256, arr.chunkSize)
                    end
                )

                it(
                    "accepts custom chunk size",
                    function() local arr = ChunkedArray.new("int32_t", 64); assert.equals(64, arr.chunkSize) end
                )

                it(
                    "rejects non-positive chunk sizes",
                    function()
                        assert.has_error(function() ChunkedArray.new("int32_t", 0) end)
                        assert.has_error(function() ChunkedArray.new("int32_t", -1) end)
                    end
                )
            end
        )

        describe(
            "alloc",
            function()
                it(
                    "returns sequential ids starting at 1",
                    function()
                        local arr = ChunkedArray.new("int32_t", 16)
                        assert.equals(1, arr:alloc())
                        assert.equals(2, arr:alloc())
                        assert.equals(3, arr:alloc())
                    end
                )

                it(
                    "allocates chunks on demand",
                    function()
                        local arr = ChunkedArray.new("int32_t", 4)
                        for _ = 1, 4 do
                            arr:alloc()
                        end
                        assert.equals(1, #arr.chunks)
                        arr:alloc() -- triggers second chunk
                        assert.equals(2, #arr.chunks)
                    end
                )

                it(
                    "reuses freed ids",
                    function()
                        local arr = ChunkedArray.new("int32_t", 16)
                        local id1 = arr:alloc()
                        local id2 = arr:alloc()
                        arr:free(id1)
                        local id3 = arr:alloc()
                        assert.equals(id1, id3)
                        -- id2 is still alive
                        assert.is_true(arr.alive[id2] == true)
                    end
                )
            end
        )

        describe(
            "free",
            function()
                it(
                    "marks slot as not alive",
                    function()
                        local arr = ChunkedArray.new("int32_t", 16)
                        local id = arr:alloc()
                        assert.is_true(arr.alive[id] == true)
                        arr:free(id)
                        assert.is_nil(arr.alive[id])
                    end
                )

                it(
                    "prevents double-free",
                    function()
                        local arr = ChunkedArray.new("int32_t", 16)
                        local id = arr:alloc()
                        arr:free(id)
                        arr:free(id) -- should be no-op
                        -- Only one entry in freeIds
                        assert.equals(1, #arr.freeIds)
                    end
                )

                it(
                    "ignores invalid ids",
                    function()
                        local arr = ChunkedArray.new("int32_t", 16)
                        arr:free(0) -- below range
                        arr:free(999) -- never allocated
                        assert.equals(0, #arr.freeIds)
                    end
                )

                it(
                    "ignores negative ids",
                    function()
                        local arr = ChunkedArray.new("int32_t", 16)
                        arr:free(-1)
                        assert.equals(0, #arr.freeIds)
                    end
                )
            end
        )

        describe(
            "get",
            function()
                it(
                    "returns element for live slot",
                    function()
                        local arr = ChunkedArray.new("ChunkedArrayTestVec2", 16)
                        local id = arr:alloc()
                        local elem = arr:get(id)
                        assert.is_not_nil(elem)
                        elem.x = 3.0
                        elem.y = 4.0
                        -- Re-get returns same data
                        local elem2 = arr:get(id)
                        assert.near(3.0, tonumber(elem2.x), 0.001)
                        assert.near(4.0, tonumber(elem2.y), 0.001)
                    end
                )

                it(
                    "returns nil for freed slot",
                    function()
                        local arr = ChunkedArray.new("int32_t", 16)
                        local id = arr:alloc()
                        arr:free(id)
                        assert.is_nil(arr:get(id))
                    end
                )

                it(
                    "returns nil for never-allocated slot",
                    function() local arr = ChunkedArray.new("int32_t", 16); assert.is_nil(arr:get(5)) end
                )

                it(
                    "works across chunk boundaries",
                    function()
                        local arr = ChunkedArray.new("ChunkedArrayTestVec2", 4)
                        local ids: {integer} = {}
                        for i = 1, 12 do
                            ids[i] = arr:alloc()
                            local elem = arr:get(ids[i])
                            elem.x = i * 1.0
                            elem.y = i * 2.0
                        end
                        assert.equals(3, #arr.chunks)
                        for i = 1, 12 do
                            local elem = arr:get(ids[i])
                            assert.near(i * 1.0, tonumber(elem.x), 0.001)
                            assert.near(i * 2.0, tonumber(elem.y), 0.001)
                        end
                    end
                )
            end
        )

        describe(
            "alloc/free cycle",
            function()
                it(
                    "reused id gets fresh alive status",
                    function()
                        local arr = ChunkedArray.new("ChunkedArrayTestVec2", 16)
                        local id = arr:alloc()
                        local elem = arr:get(id)
                        elem.x = 99.0
                        arr:free(id)
                        assert.is_nil(arr:get(id))

                        local id2 = arr:alloc()
                        assert.equals(id, id2)
                        -- Slot is alive again, old data still present (no reset on reuse)
                        local elem2 = arr:get(id2)
                        assert.is_not_nil(elem2)
                    end
                )
            end
        )
    end
)
