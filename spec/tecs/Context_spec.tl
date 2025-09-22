require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

describe("Context", function()
    it("creates a new context and keys", function()
        local ctx = tecs.newContext()
        luassert.is_not_nil(ctx, "newContext() should return a non-nil value")

        local key: tecs.Key<integer> = tecs.newKey()
        luassert.is_not_nil(key, "newKey() should return a non-nil value")
    end)

    it("stores and retrieves values using keys", function()
        local ctx = tecs.newContext()
        local STRING_KEY: tecs.Key<string> = tecs.newKey()
        local NUMBER_KEY: tecs.Key<number> = tecs.newKey()

        ctx[STRING_KEY] = "test"
        ctx[NUMBER_KEY] = 42

        luassert.is_equal("test", ctx[STRING_KEY], "String value should be retrievable with its key")
        luassert.is_equal(42, ctx[NUMBER_KEY], "Number value should be retrievable with its key")
        luassert.is_equal(nil, ctx[tecs.newKey()], "Unset key should return nil")
    end)

    it("maintains key separation", function()
        local ctx1 = tecs.newContext()
        local ctx2 = tecs.newContext()
        local SHARED_KEY: tecs.Key<string> = tecs.newKey()

        ctx1[SHARED_KEY] = "context1"
        ctx2[SHARED_KEY] = "context2"

        luassert.is_equal("context1", ctx1[SHARED_KEY], "ctx1 should have its own value")
        luassert.is_equal("context2", ctx2[SHARED_KEY], "ctx2 should have its own value")
    end)

    it("updates and removes values", function()
        local ctx = tecs.newContext()
        local KEY: tecs.Key<string> = tecs.newKey()

        ctx[KEY] = "original"
        luassert.is_equal("original", ctx[KEY], "Initial value should be set")

        ctx[KEY] = "updated"
        luassert.is_equal("updated", ctx[KEY], "Value should be updated")

        ctx[KEY] = nil
        luassert.is_equal(nil, ctx[KEY], "Value should be nil after removal")
    end)
end)
