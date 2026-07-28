require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

describe(
    "Context",
    function()
        it(
            "creates a new context and keys",
            function()
                local ctx = tecs.ecs.newContext()
                luassert.is_not_nil(ctx, "newContext() should return a non-nil value")

                local key: tecs.ecs.Key<integer> = tecs.ecs.newKey("spec.context.create")
                luassert.is_not_nil(key, "newKey() should return a non-nil value")
            end
        )

        it(
            "stores and retrieves values using keys",
            function()
                local ctx = tecs.ecs.newContext()
                local STRING_KEY: tecs.ecs.Key<string> = tecs.ecs.newKey("spec.context.string")
                local NUMBER_KEY: tecs.ecs.Key<number> = tecs.ecs.newKey("spec.context.number")

                ctx[STRING_KEY] = "test"
                ctx[NUMBER_KEY] = 42

                luassert.is_equal("test", ctx[STRING_KEY], "String value should be retrievable with its key")
                luassert.is_equal(42, ctx[NUMBER_KEY], "Number value should be retrievable with its key")
                luassert.is_equal(nil, ctx[tecs.ecs.newKey("spec.context.unset")], "Unset key should return nil")
            end
        )

        it(
            "maintains key separation",
            function()
                local ctx1 = tecs.ecs.newContext()
                local ctx2 = tecs.ecs.newContext()
                local SHARED_KEY: tecs.ecs.Key<string> = tecs.ecs.newKey("spec.context.shared")

                ctx1[SHARED_KEY] = "context1"
                ctx2[SHARED_KEY] = "context2"

                luassert.is_equal("context1", ctx1[SHARED_KEY], "ctx1 should have its own value")
                luassert.is_equal("context2", ctx2[SHARED_KEY], "ctx2 should have its own value")
            end
        )

        it(
            "updates and removes values",
            function()
                local ctx = tecs.ecs.newContext()
                local KEY: tecs.ecs.Key<string> = tecs.ecs.newKey("spec.context.updates")

                ctx[KEY] = "original"
                luassert.is_equal("original", ctx[KEY], "Initial value should be set")

                ctx[KEY] = "updated"
                luassert.is_equal("updated", ctx[KEY], "Value should be updated")

                ctx[KEY] = nil
                luassert.is_equal(nil, ctx[KEY], "Value should be nil after removal")
            end
        )

        it(
            "still creates distinct keys without a name",
            function()
                local a: tecs.ecs.Key<string> = tecs.ecs.newKey()
                local b: tecs.ecs.Key<string> = tecs.ecs.newKey()
                luassert.is_not_nil(a)
                luassert.is_not_nil(b)
                luassert.is_not_equal(a, b, "Unnamed keys are fresh identities")
            end
        )

        it(
            "finds named keys and returns the same identity on re-creation",
            function()
                local KEY: tecs.ecs.Key<string> = tecs.ecs.newKey("spec.context.findable")
                luassert.is_equal(
                    KEY,
                    tecs.ecs.findKey("spec.context.findable"),
                    "findKey should return the key created under that name"
                )
                luassert.is_equal(
                    KEY,
                    tecs.ecs.newKey("spec.context.findable"),
                    "newKey with a known name is idempotent (hot-reload safe)"
                )
                luassert.is_equal(
                    nil, tecs.ecs.findKey("spec.context.no-such-key"), "findKey on an unknown name returns nil"
                )

                -- The stored value is reachable through the re-created key.
                local ctx = tecs.ecs.newContext()
                ctx[KEY] = "kept"
                local again: tecs.ecs.Key<string> = tecs.ecs.newKey("spec.context.findable")
                luassert.is_equal(
                    "kept", ctx[again], "values survive module re-execution because the identity is stable"
                )
            end
        )

        it(
            "lists named keys with their ids",
            function()
                local KEY = tecs.ecs.newKey("spec.context.listed") as integer
                local listed = tecs.ecs.listKeys()
                luassert.is_equal(KEY, listed["spec.context.listed"], "listKeys maps the name to the key id")

                -- The returned table is a copy: mutating it does not affect the registry.
                listed["spec.context.listed"] = nil
                luassert.is_not_nil(
                    tecs.ecs.findKey("spec.context.listed"), "mutating the listKeys result must not unregister the key"
                )
            end
        )
    end
)
