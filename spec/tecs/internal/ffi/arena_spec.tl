local ffi <const> = require("ffi")
local Arena <const> = require("tecs.internal.ffi.EpochArena")

describe(
    "Arena",
    function()
        describe(
            "new",
            function()
                it(
                    "creates an empty arena",
                    function()
                        local arena = Arena.new("int32_t")
                        assert.equals(0, arena.currentPage)
                        assert.equals(0, arena.usedPages)
                    end
                )

                it(
                    "accepts custom page size",
                    function() local arena = Arena.new("int32_t", 128); assert.equals(128, arena.pageAllocSize) end
                )

                it(
                    "rejects page sizes larger than the row budget",
                    function() assert.has_error(function() Arena.new("int32_t", 4097) end) end
                )
            end
        )

        describe(
            "clear",
            function()
                it(
                    "resets only used pages",
                    function()
                        local arena = Arena.new("int32_t", 2)
                        arena:allocate()
                        arena:allocate()
                        arena:allocate()
                        arena:allocate()
                        assert.equals(2, arena.currentPage)
                        assert.equals(2, arena.usedPages)

                        arena:clear()
                        assert.equals(1, arena.currentPage)
                        assert.equals(0, arena.usedPages)
                        assert.equals(0, arena.pages[1].count)
                        assert.equals(0, arena.pages[2].count)
                    end
                )

                it(
                    "does not touch pages beyond usedPages",
                    function()
                        local arena = Arena.new("int32_t", 2)
                        for _ = 1, 6 do
                            arena:allocate()
                        end
                        arena:clear()

                        arena:allocate()
                        assert.equals(1, arena.usedPages)
                        arena:clear()
                        assert.equals(0, arena.pages[1].count)
                    end
                )
            end
        )

        describe(
            "allocate",
            function()
                it(
                    "returns data and a 1-based index",
                    function()
                        local arena = Arena.new("int32_t", 16)
                        local data, idx = arena:allocate()
                        assert.is_not_nil(data)
                        assert.equals(1, idx)
                    end
                )

                it(
                    "returns sequential indices on the same page",
                    function()
                        local arena = Arena.new("int32_t", 16)
                        local _, idx1 = arena:allocate()
                        local _, idx2 = arena:allocate()
                        assert.equals(1, idx1)
                        assert.equals(2, idx2)
                    end
                )

                it(
                    "crosses page boundaries",
                    function()
                        local arena = Arena.new("int32_t", 2)
                        local d1, i1 = arena:allocate()
                        local d2, i2 = arena:allocate()
                        local d3, i3 = arena:allocate()
                        assert.equals(1, i1)
                        assert.equals(2, i2)
                        assert.equals(1, i3)
                        assert.equals(d1, d2)
                        assert.not_equals(d1, d3)
                    end
                )

                it(
                    "writes are readable through the returned pointer",
                    function()
                        local arena = Arena.new("int32_t", 16)
                        local data, idx = arena:allocate()
                        data[idx] = 99
                        assert.equals(99, data[idx])
                    end
                )

                it(
                    "tracks usedPages",
                    function()
                        local arena = Arena.new("int32_t", 2)
                        arena:allocate()
                        arena:allocate()
                        assert.equals(1, arena.usedPages)
                        arena:allocate()
                        assert.equals(2, arena.usedPages)
                    end
                )

                it(
                    "rejects page growth past the encodable range",
                    function()
                        local arena = Arena.new("int32_t", 1)
                        for _ = 1, 4096 do
                            arena:allocate()
                        end

                        assert.has_error(function() arena:allocate() end)
                    end
                )
            end
        )

        describe(
            "struct types",
            function()
                it(
                    "works with FFI structs",
                    function()
                        ffi.cdef("typedef struct { float x; float y; } ArenaTestVec2;")
                        local arena = Arena.new("ArenaTestVec2", 16)
                        local data, idx = arena:allocate()
                        data[idx].x = 3.0
                        data[idx].y = 4.0
                        assert.near(3.0, tonumber(data[idx].x), 0.001)
                        assert.near(4.0, tonumber(data[idx].y), 0.001)
                    end
                )
            end
        )
    end
)
