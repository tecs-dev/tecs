local Bitset <const> = require("tecs.utils.Bitset")
local bit <const> = require("bit")

describe(
    "Bitset",
    function()
        describe(
            "new",
            function()
                it(
                    "creates a bitset with default capacity",
                    function()
                        local bs = Bitset.new()
                        assert.equals(0, bs.count)
                        assert.equals(0, bs.usedWordCount)
                        assert.is_true(bs.wordCount >= 2) -- 64 bits = 2 words
                    end
                )

                it(
                    "creates a bitset with custom capacity",
                    function()
                        local bs = Bitset.new(128)
                        assert.equals(4, bs.wordCount) -- 128 / 32 = 4
                    end
                )

                it(
                    "rounds up capacity to word boundary",
                    function()
                        local bs = Bitset.new(33)
                        assert.equals(2, bs.wordCount) -- ceil(33/32) = 2
                    end
                )
            end
        )

        describe(
            "set and get",
            function()
                it(
                    "sets and gets individual bits",
                    function()
                        local bs = Bitset.new(64)
                        bs:set(0)
                        bs:set(31)
                        bs:set(32)
                        assert.is_true(bs:get(0))
                        assert.is_true(bs:get(31))
                        assert.is_true(bs:get(32))
                        assert.is_false(bs:get(1))
                        assert.equals(3, bs.count)
                    end
                )

                it(
                    "auto-grows when setting beyond capacity",
                    function()
                        local bs = Bitset.new(32)
                        assert.equals(1, bs.wordCount)
                        bs:set(64)
                        assert.is_true(bs:get(64))
                        assert.is_true(bs.wordCount > 2)
                    end
                )

                it(
                    "tracks usedWordCount",
                    function()
                        local bs = Bitset.new(128)
                        bs:set(0)
                        assert.equals(1, bs.usedWordCount)
                        bs:set(96)
                        assert.equals(4, bs.usedWordCount) -- word 3 (bits 96-127)
                    end
                )
            end
        )

        describe(
            "clear",
            function()
                it(
                    "clears individual bits",
                    function()
                        local bs = Bitset.new(64)
                        bs:set(5)
                        bs:set(10)
                        assert.equals(2, bs.count)
                        bs:clear(5)
                        assert.is_false(bs:get(5))
                        assert.is_true(bs:get(10))
                        assert.equals(1, bs.count)
                    end
                )

                it(
                    "shrinks usedWordCount when top word becomes zero",
                    function()
                        local bs = Bitset.new(128)
                        bs:set(0)
                        bs:set(96)
                        assert.equals(4, bs.usedWordCount)
                        bs:clear(96)
                        assert.equals(1, bs.usedWordCount)
                    end
                )

                it(
                    "shrinks usedWordCount to zero when the last bit is cleared",
                    function()
                        local bs = Bitset.new(64)
                        bs:set(5)
                        assert.equals(1, bs.usedWordCount)
                        bs:clear(5)
                        assert.equals(0, bs.usedWordCount)
                        assert.equals(0, bs.count)
                    end
                )

                it(
                    "shrinks past multiple trailing zero words",
                    function()
                        local bs = Bitset.new(128)
                        bs:set(5)
                        bs:set(33)
                        bs:set(96)
                        assert.equals(4, bs.usedWordCount)
                        -- Clear bits in word 3 and word 1, leaving only word 0
                        bs:clear(96)
                        assert.equals(2, bs.usedWordCount) -- word 1 still has bit 33
                        bs:clear(33)
                        assert.equals(1, bs.usedWordCount) -- only word 0 has bit 5
                    end
                )

                it(
                    "does not shrink when non-top word is cleared",
                    function()
                        local bs = Bitset.new(128)
                        bs:set(5)
                        bs:set(96)
                        assert.equals(4, bs.usedWordCount)
                        bs:clear(5)
                        assert.equals(4, bs.usedWordCount) -- word 3 still active
                    end
                )
            end
        )

        describe(
            "clearAll",
            function()
                it(
                    "resets all state",
                    function()
                        local bs = Bitset.new(64)
                        bs:set(0)
                        bs:set(31)
                        bs:set(32)
                        bs:clearAll()
                        assert.equals(0, bs.count)
                        assert.equals(0, bs.usedWordCount)
                        assert.is_false(bs:get(0))
                        assert.is_false(bs:get(31))
                    end
                )

                it(
                    "invalidates active scans",
                    function()
                        local bs = Bitset.new(64)
                        bs:set(5)
                        bs:set(10)
                        assert.equals(5, bs:beginScan(0))
                        bs:clearAll()
                        assert.is_nil(bs:nextScan())
                    end
                )
            end
        )

        describe(
            "helper methods",
            function()
                it(
                    "setOnly resets then sets one bit",
                    function()
                        local bs = Bitset.new(128)
                        bs:set(3)
                        bs:set(90)
                        bs:setOnly(31)
                        assert.equals(1, bs.count)
                        assert.equals(1, bs.usedWordCount)
                        assert.is_true(bs:get(31))
                        assert.is_false(bs:get(3))
                        assert.is_false(bs:get(90))
                    end
                )

                it(
                    "copyFrom clones shape and count",
                    function()
                        local src = Bitset.new(128)
                        local dst = Bitset.new(32)
                        src:set(1)
                        src:set(65)
                        src:set(96)
                        dst:set(5)
                        dst:copyFrom(src)
                        assert.equals(src.count, dst.count)
                        assert.equals(src.usedWordCount, dst.usedWordCount)
                        assert.is_true(dst:get(1))
                        assert.is_true(dst:get(65))
                        assert.is_true(dst:get(96))
                        assert.is_false(dst:get(5))
                    end
                )

                it(
                    "orWith unions bits in place",
                    function()
                        local a = Bitset.new(128)
                        local b = Bitset.new(128)
                        a:set(1)
                        a:set(64)
                        b:set(64)
                        b:set(95)
                        a:orWith(b)
                        assert.same(3, a.count)
                        assert.is_true(a:get(1))
                        assert.is_true(a:get(64))
                        assert.is_true(a:get(95))
                    end
                )

                it(
                    "andWith intersects bits in place",
                    function()
                        local a = Bitset.new(128)
                        local b = Bitset.new(128)
                        a:set(1)
                        a:set(64)
                        a:set(95)
                        b:set(64)
                        b:set(96)
                        a:andWith(b)
                        assert.equals(1, a.count)
                        assert.equals(3, a.usedWordCount)
                        assert.is_false(a:get(1))
                        assert.is_true(a:get(64))
                        assert.is_false(a:get(95))
                    end
                )

                it(
                    "andNotWith subtracts bits in place",
                    function()
                        local a = Bitset.new(128)
                        local b = Bitset.new(128)
                        a:set(1)
                        a:set(64)
                        a:set(95)
                        b:set(64)
                        b:set(96)
                        a:andNotWith(b)
                        assert.equals(2, a.count)
                        assert.is_true(a:get(1))
                        assert.is_false(a:get(64))
                        assert.is_true(a:get(95))
                    end
                )

                it(
                    "isEmpty and raw word access reflect contents",
                    function()
                        local bs = Bitset.new(128)
                        assert.is_true(bs:isEmpty())
                        assert.equals(0, bs:getWordCount())
                        assert.equals(0, bs:getWord(0))
                        bs:set(0)
                        bs:set(63)
                        assert.is_false(bs:isEmpty())
                        assert.equals(2, bs:getWordCount())
                        assert.equals(1, bs:getWord(0))
                        assert.equals(bit.lshift(1, 31), bs:getWord(1))
                    end
                )
            end
        )

        describe(
            "setRange",
            function()
                it(
                    "tracks exact count for overlapping single-word ranges",
                    function()
                        local bs = Bitset.new(64)
                        bs:setRange(3, 7)
                        assert.equals(5, bs.count)
                        bs:setRange(5, 9)
                        assert.equals(7, bs.count)
                    end
                )

                it(
                    "tracks exact count for overlapping multi-word ranges",
                    function()
                        local bs = Bitset.new(128)
                        bs:setRange(16, 95)
                        assert.equals(80, bs.count)
                        bs:setRange(32, 111)
                        assert.equals(96, bs.count)
                    end
                )
            end
        )

        describe(
            "set comparisons",
            function()
                it(
                    "containsAll returns true when superset",
                    function()
                        local a = Bitset.new(128)
                        local b = Bitset.new(128)
                        a:set(1)
                        a:set(31)
                        a:set(32)
                        a:set(100)
                        b:set(1)
                        b:set(32)
                        assert.is_true(a:containsAll(b))
                    end
                )

                it(
                    "containsAll returns false when missing bits",
                    function()
                        local a = Bitset.new(128)
                        local b = Bitset.new(128)
                        a:set(1)
                        a:set(32)
                        b:set(1)
                        b:set(64)
                        assert.is_false(a:containsAll(b))
                    end
                )

                it(
                    "containsAll treats empty other as true",
                    function()
                        local a = Bitset.new(64)
                        local b = Bitset.new(64)
                        a:set(5)
                        assert.is_true(a:containsAll(b))
                    end
                )

                it(
                    "overlaps/disjoint on shared bits",
                    function()
                        local a = Bitset.new(128)
                        local b = Bitset.new(128)
                        a:set(2)
                        a:set(63)
                        b:set(63)
                        b:set(90)
                        assert.is_true(a:overlaps(b))
                        assert.is_false(a:disjoint(b))
                    end
                )

                it(
                    "overlaps/disjoint on non-shared bits",
                    function()
                        local a = Bitset.new(128)
                        local b = Bitset.new(128)
                        a:set(2)
                        a:set(63)
                        b:set(64)
                        b:set(90)
                        assert.is_false(a:overlaps(b))
                        assert.is_true(a:disjoint(b))
                    end
                )
            end
        )

        describe(
            "nextSetBit",
            function()
                it(
                    "finds the first set bit",
                    function() local bs = Bitset.new(64); bs:set(5); bs:set(10); assert.equals(5, bs:nextSetBit(0)) end
                )

                it(
                    "finds bits from a given start",
                    function() local bs = Bitset.new(64); bs:set(5); bs:set(10); assert.equals(10, bs:nextSetBit(6)) end
                )

                it(
                    "returns the start bit if it is set",
                    function() local bs = Bitset.new(64); bs:set(7); assert.equals(7, bs:nextSetBit(7)) end
                )

                it(
                    "returns nil when no bits are set at or after start",
                    function() local bs = Bitset.new(64); bs:set(5); assert.is_nil(bs:nextSetBit(6)) end
                )

                it(
                    "returns nil for empty bitset",
                    function() local bs = Bitset.new(64); assert.is_nil(bs:nextSetBit(0)) end
                )

                it(
                    "skips zero words",
                    function() local bs = Bitset.new(256); bs:set(200); assert.equals(200, bs:nextSetBit(0)) end
                )

                it(
                    "finds bits across word boundaries",
                    function()
                        local bs = Bitset.new(128)
                        bs:set(31)
                        bs:set(32)
                        bs:set(63)
                        bs:set(64)
                        assert.equals(31, bs:nextSetBit(0))
                        assert.equals(32, bs:nextSetBit(32))
                        assert.equals(63, bs:nextSetBit(33))
                        assert.equals(64, bs:nextSetBit(64))
                    end
                )

                it(
                    "masks off lower bits in first word",
                    function()
                        local bs = Bitset.new(64)
                        bs:set(2)
                        bs:set(5)
                        bs:set(10)
                        -- Starting at 3 should skip bit 2
                        assert.equals(5, bs:nextSetBit(3))
                        -- Starting at 6 should skip bits 2 and 5
                        assert.equals(10, bs:nextSetBit(6))
                    end
                )

                it(
                    "works as a while-loop iterator",
                    function()
                        local bs = Bitset.new(128)
                        bs:set(1)
                        bs:set(15)
                        bs:set(32)
                        bs:set(99)
                        local collected: {integer} = {}
                        local i = bs:nextSetBit(0)
                        while i do
                            collected[#collected + 1] = i
                            i = bs:nextSetBit(i + 1)
                        end
                        assert.same({1, 15, 32, 99}, collected)
                    end
                )

                it(
                    "returns nil when start is beyond usedWordCount",
                    function() local bs = Bitset.new(64); bs:set(5); assert.is_nil(bs:nextSetBit(64)) end
                )
            end
        )

        describe(
            "a negative index",
            function()
                -- The shifts that turn an index into a word are unsigned, so a
                -- negative one names a word near 2^27 while the growth is
                -- sized from a bit count of zero. The two calls that would act
                -- on that write outside the array; the rest see it as past the
                -- end and answer with nothing.
                it(
                    "raises on set rather than writing outside the array",
                    function()
                        local bs = Bitset.new(64)
                        assert.has_error(function() bs:set(-1) end)
                        assert.has_error(function() bs:set(-33) end)
                        assert.are.equal(0, bs.count)
                    end
                )

                it(
                    "raises on setRange, where the head word is the one written",
                    function()
                        local bs = Bitset.new(64)
                        assert.has_error(function() bs:setRange(-1, 5) end)
                        assert.are.equal(0, bs.count)
                    end
                )

                it(
                    "raises through setOnly, which sets through set",
                    function() local bs = Bitset.new(64); bs:set(3); assert.has_error(function() bs:setOnly(-1) end) end
                )

                it(
                    "is answered as past the end by everything that reads",
                    function()
                        local bs = Bitset.new(64)
                        bs:set(5)
                        assert.is_false(bs:get(-1))
                        bs:clear(-1)
                        assert.are.equal(1, bs.count, "clear reached a word it does not own")
                    end
                )
            end
        )
    end
)
