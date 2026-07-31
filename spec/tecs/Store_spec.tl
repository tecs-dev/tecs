require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

describe(
    "Store",
    function()
        it(
            "creates a new store and keys",
            function()
                local store = tecs.data.newStore()
                luassert.is_not_nil(store, "newStore() should return a non-nil value")

                local key: tecs.data.Key<integer> = tecs.data.newKey("spec.context.create")
                luassert.is_not_nil(key, "newKey() should return a non-nil value")
            end
        )

        it(
            "stores and retrieves values using keys",
            function()
                local store = tecs.data.newStore()
                local STRING_KEY: tecs.data.Key<string> = tecs.data.newKey("spec.context.string")
                local NUMBER_KEY: tecs.data.Key<number> = tecs.data.newKey("spec.context.number")

                store[STRING_KEY] = "test"
                store[NUMBER_KEY] = 42

                luassert.is_equal("test", store[STRING_KEY], "String value should be retrievable with its key")
                luassert.is_equal(42, store[NUMBER_KEY], "Number value should be retrievable with its key")
                luassert.is_equal(nil, store[tecs.data.newKey("spec.context.unset")], "Unset key should return nil")
            end
        )

        it(
            "maintains key separation",
            function()
                local first = tecs.data.newStore()
                local second = tecs.data.newStore()
                local SHARED_KEY: tecs.data.Key<string> = tecs.data.newKey("spec.context.shared")

                first[SHARED_KEY] = "first"
                second[SHARED_KEY] = "second"

                luassert.is_equal("first", first[SHARED_KEY], "The first store should have its own value")
                luassert.is_equal("second", second[SHARED_KEY], "The second store should have its own value")
            end
        )

        it(
            "updates and removes values",
            function()
                local store = tecs.data.newStore()
                local KEY: tecs.data.Key<string> = tecs.data.newKey("spec.context.updates")

                store[KEY] = "original"
                luassert.is_equal("original", store[KEY], "Initial value should be set")

                store[KEY] = "updated"
                luassert.is_equal("updated", store[KEY], "Value should be updated")

                store[KEY] = nil
                luassert.is_equal(nil, store[KEY], "Value should be nil after removal")
            end
        )

        it(
            "still creates distinct keys without a name",
            function()
                local a: tecs.data.Key<string> = tecs.data.newKey()
                local b: tecs.data.Key<string> = tecs.data.newKey()
                luassert.is_not_nil(a)
                luassert.is_not_nil(b)
                luassert.is_not_equal(a, b, "Unnamed keys are fresh identities")
            end
        )

        it(
            "finds named keys and returns the same identity on re-creation",
            function()
                local KEY: tecs.data.Key<string> = tecs.data.newKey("spec.context.findable")
                luassert.is_equal(
                    KEY,
                    tecs.data.findKey("spec.context.findable"),
                    "findKey should return the key created under that name"
                )
                luassert.is_equal(
                    KEY,
                    tecs.data.newKey("spec.context.findable"),
                    "newKey with a known name is idempotent (hot-reload safe)"
                )
                luassert.is_equal(
                    nil, tecs.data.findKey("spec.context.no-such-key"), "findKey on an unknown name returns nil"
                )

                -- The stored value is reachable through the re-created key.
                local store = tecs.data.newStore()
                store[KEY] = "kept"
                local again: tecs.data.Key<string> = tecs.data.newKey("spec.context.findable")
                luassert.is_equal(
                    "kept", store[again], "values survive module re-execution because the identity is stable"
                )
            end
        )

        it(
            "lists named keys with their ids",
            function()
                tecs.data.newKey("spec.context.listed")
                local listed = tecs.data.Key.listKeys()
                luassert.is_not_nil(listed["spec.context.listed"], "listKeys maps the name to the key id")

                -- The returned table is a copy: mutating it does not affect the registry.
                listed["spec.context.listed"] = nil
                luassert.is_not_nil(
                    tecs.data.findKey("spec.context.listed"), "mutating the listKeys result must not unregister the key"
                )
            end
        )
    end
)
