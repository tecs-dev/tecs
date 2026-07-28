require("busted")
local luassert = require("luassert")
local describe <const> = describe
local it <const> = it

describe(
    "pool",
    function()
        local pool = require("tecs.utils.pool")

        describe(
            "newTablePool",
            function()
                it(
                    "acquires and releases tables",
                    function()
                        local p = pool.newTablePool()
                        local t1 = p:acquire() as {any}
                        luassert.is_table(t1)
                        luassert.is_equal(0, #t1)

                        t1[1] = "test"
                        t1[2] = "data"
                        p:release(t1)

                        local t2 = p:acquire() as {any}
                        luassert.is_equal(t1, t2)
                        luassert.is_equal(0, #t2)
                    end
                )

                it(
                    "creates new tables when pool is empty",
                    function()
                        local p = pool.newTablePool()
                        local t1 = p:acquire() as {any}
                        local t2 = p:acquire() as {any}
                        luassert.is_not_equal(t1, t2)
                    end
                )

                it(
                    "reuses released tables",
                    function()
                        local p = pool.newTablePool()
                        local t = p:acquire() as {any}
                        t[1] = "test"
                        p:release(t)
                        local t2 = p:acquire() as {any}
                        luassert.is_equal(t, t2)
                        luassert.is_equal(0, #t2)
                    end
                )

                it(
                    "defaults to clearOn='acquire'",
                    function()
                        local p = pool.newTablePool()
                        local t = p:acquire() as {any}
                        t[1] = "a"
                        t[2] = "b"
                        p:release(t)
                        -- After release, content is still there (acquire-time clear).
                        luassert.is_equal("a", t[1])
                        -- Re-acquire clears it.
                        local t2 = p:acquire() as {any}
                        luassert.is_nil(t2[1])
                        luassert.is_nil(t2[2])
                    end
                )

                it(
                    "clearOn='release' clears immediately on release",
                    function()
                        local p = pool.newTablePool({clearOn = "release"})
                        local t = p:acquire() as {any}
                        t[1] = "a"
                        t[2] = "b"
                        p:release(t)
                        luassert.is_nil(t[1])
                        luassert.is_nil(t[2])
                    end
                )

                it(
                    "clearOn='never' never clears",
                    function()
                        local p = pool.newTablePool({clearOn = "never"})
                        local t = p:acquire() as {any}
                        t[1] = "a"
                        t[2] = "b"
                        p:release(t)
                        local t2 = p:acquire() as {any}
                        luassert.is_equal(t, t2)
                        luassert.is_equal("a", t2[1])
                        luassert.is_equal("b", t2[2])
                    end
                )

                it(
                    "respects maxSize cap",
                    function()
                        local p = pool.newTablePool({maxSize = 4})
                        local acquired: {table} = {}
                        for i = 1, 8 do
                            acquired[i] = p:acquire() as table
                        end
                        -- First 4 releases fit; once pool is full, later releases are
                        -- dropped (table not pooled).
                        for i = 1, 8 do
                            p:release(acquired[i])
                        end
                        -- LIFO acquires: the 4 pooled tables are the first 4 released.
                        for i = 1, 4 do
                            local reused = p:acquire()
                            luassert.is_equal(acquired[5 - i], reused)
                        end
                        -- 5th acquire must be a fresh table (pool empty; the last 4
                        -- releases were dropped).
                        local fresh = p:acquire() as table
                        for i = 1, 8 do
                            luassert.is_not_equal(acquired[i], fresh)
                        end
                    end
                )

                it(
                    "clear() drops all pooled tables",
                    function()
                        local p = pool.newTablePool()
                        local pooled: {table} = {}
                        for i = 1, 5 do
                            pooled[i] = p:acquire() as table
                        end
                        for i = 1, 5 do
                            p:release(pooled[i])
                        end
                        p:clear()
                        local fresh = p:acquire() as table
                        for i = 1, 5 do
                            luassert.is_not_equal(pooled[i], fresh)
                        end
                    end
                )

                it(
                    "isolates pools from each other",
                    function()
                        local a = pool.newTablePool()
                        local b = pool.newTablePool()
                        local ta = a:acquire() as table
                        a:release(ta)
                        -- b has never been released into, so it must not vend a's table.
                        local tb = b:acquire() as table
                        luassert.is_not_equal(ta, tb)
                    end
                )
            end
        )

        describe(
            "sizeHints",
            function()
                it(
                    "passes arrayHint and hashHint to new tables",
                    function()
                        -- We can't directly observe table_new preallocation, but we
                        -- can at least confirm acquisition works with these opts.
                        local p = pool.newTablePool({arrayHint = 16, hashHint = 4})
                        local t = p:acquire() as {any}
                        luassert.is_table(t)
                    end
                )
            end
        )

        describe(
            "EMPTY",
            function()
                it(
                    "is an immutable shared sentinel",
                    function()
                        luassert.is_table(pool.EMPTY)
                        luassert.has_error(function() (pool.EMPTY as {any})[1] = "nope" end)
                    end
                )
            end
        )
    end
)
