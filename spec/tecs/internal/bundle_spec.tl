require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

describe("bundle", function()
    describe("builder pattern", function()
        it("creates a bundle builder", function()
            local builder = tecs.newBundle()
            luassert.is_not_nil(builder, "Builder should not be nil")
            luassert.is_function(builder.add, "Builder should have add method")
            luassert.is_function(builder.build, "Builder should have build method")
        end)

        it("chains add calls", function()
            local Tag1 = tecs.newTagComponent({name = "BundleTag1"})
            local Tag2 = tecs.newTagComponent({name = "BundleTag2"})

            local builder = tecs.newBundle()
                :add(Tag1, function(): tecs.Component
                    return Tag1()
                end)
                :add(Tag2, function(): tecs.Component
                    return Tag2()
                end)

            luassert.is_not_nil(builder, "Builder should chain properly")
            luassert.is_function(builder.build, "Chained builder should have build method")
        end)

        it("builds a bundle function", function()
            local Tag3 = tecs.newTagComponent({name = "BundleTag3"})

            local bundle = tecs.newBundle()
                :add(Tag3, function(): tecs.Component
                    return Tag3()
                end)
                :build()

            luassert.is_function(bundle, "Bundle should be a function")
        end)
    end)

    describe("bundle functionality", function()
        it("calls factories when no overrides provided", function()
            local record TestComponent is tecs.Component
                value: number
            end

            local TC = tecs.newComponent({
                name = "TestComponent",
                container = TestComponent,
                constructor = function(value: number): TestComponent
                    return {value = value or 0}
                end
            })

            local Tag4 = tecs.newTagComponent({name = "BundleTag4"})

            local factoryCalled = 0
            local bundle = tecs.newBundle()
                :add(TC, function(): TestComponent
                    factoryCalled = factoryCalled + 1
                    return TC(42)
                end)
                :add(Tag4, function(): tecs.Component
                    return Tag4()
                end)
                :build()

            local result = {bundle()}

            luassert.is_not_nil(result, "Bundle result should not be nil")
            luassert.is_equal(#result, 2, "Bundle should return all components")
            luassert.is_equal(factoryCalled, 1, "Factory should be called once")

            -- Check that components were created
            local hasTC = false
            local hasTag4 = false
            for i = 1, #result do
                if result[i].componentName == "TestComponent" then
                    hasTC = true
                    luassert.is_equal((result[i] as TestComponent).value, 42, "Component should have correct value")
                elseif result[i].componentName == "BundleTag4" then
                    hasTag4 = true
                end
            end
            luassert.is_true(hasTC, "Should have TestComponent")
            luassert.is_true(hasTag4, "Should have Tag4")
        end)

        it("skips factories for overridden components", function()
            local record TestComponent2 is tecs.Component
                name: string
            end

            local TC2 = tecs.newComponent({
                name = "TestComponent2",
                container = TestComponent2,
                constructor = function(name: string): TestComponent2
                    return {name = name or ""}
                end
            })

            local Tag5 = tecs.newTagComponent({name = "BundleTag5"})
            local Tag6 = tecs.newTagComponent({name = "BundleTag6"})

            local tc2FactoryCalled = false
            local tag5FactoryCalled = false

            local bundle = tecs.newBundle()
                :add(TC2, function(): TestComponent2
                    tc2FactoryCalled = true
                    return TC2("default")
                end)
                :add(Tag5, function(): tecs.Component
                    tag5FactoryCalled = true
                    return Tag5()
                end)
                :build()

            local result = {
                bundle(
                    TC2("overridden"),  -- Override TC2
                    Tag6() as tecs.Component  -- Add additional component
                )
            }

            luassert.is_not_nil(result, "Bundle result with overrides should not be nil")
            luassert.is_equal(#result, 3, "Bundle should have overrides plus non-overridden defaults")
            luassert.is_false(tc2FactoryCalled, "TC2 factory should not be called when overridden")
            luassert.is_true(tag5FactoryCalled, "Tag5 factory should be called when not overridden")

            -- Check components
            local hasTC2 = false
            local hasTag5 = false
            local hasTag6 = false
            for i = 1, #result do
                if result[i].componentName == "TestComponent2" then
                    hasTC2 = true
                    luassert.is_equal((result[i] as TestComponent2).name, "overridden", "Should use override value")
                elseif result[i].componentName == "BundleTag5" then
                    hasTag5 = true
                elseif result[i].componentName == "BundleTag6" then
                    hasTag6 = true
                end
            end
            luassert.is_true(hasTC2, "Should have TC2 component")
            luassert.is_true(hasTag5, "Should have Tag5 component")
            luassert.is_true(hasTag6, "Should have Tag6 component")
        end)

        it("creates fresh instances on each call", function()
            local record TestComponent3 is tecs.Component
                id: integer
            end

            local TC3 = tecs.newComponent({
                name = "TestComponent3",
                container = TestComponent3,
                constructor = function(id: integer): TestComponent3
                    return {id = id or 0}
                end
            })

            local callCount = 0
            local bundle = tecs.newBundle()
                :add(TC3, function(): TestComponent3
                    callCount = callCount + 1
                    return TC3(callCount)
                end)
                :build()

            local result1 = {bundle()}
            local result2 = {bundle()}

            luassert.is_equal(callCount, 2, "Factory should be called twice")
            luassert.is_not_equal(result1[1], result2[1], "Should create different instances")
            luassert.is_equal((result1[1] as TestComponent3).id, 1, "First call should have id 1")
            luassert.is_equal((result2[1] as TestComponent3).id, 2, "Second call should have id 2")
        end)

        it("handles empty bundle", function()
            local bundle = tecs.newBundle():build()
            local result = {bundle()}

            luassert.is_not_nil(result, "Empty bundle should handle no overrides")
            luassert.is_equal(#result, 0, "Empty bundle should return empty array")
        end)

        it("handles only overrides with empty bundle", function()
            local Tag7 = tecs.newTagComponent({name = "BundleTag7"})
            local Tag8 = tecs.newTagComponent({name = "BundleTag8"})

            local bundle = tecs.newBundle():build()
            local result = {
                bundle(
                    Tag7() as tecs.Component,
                    Tag8() as tecs.Component
                )
            }

            luassert.is_not_nil(result, "Bundle should handle only overrides")
            luassert.is_equal(#result, 2, "Bundle should return all overrides")
            luassert.is_equal(result[1].componentName, "BundleTag7", "Should have first override")
            luassert.is_equal(result[2].componentName, "BundleTag8", "Should have second override")
        end)
    end)

    describe("type safety", function()
        it("enforces type-safe factories", function()
            local record TypedComponent is tecs.Component
                x: number
                y: number
            end

            local TC = tecs.newComponent({
                name = "TypedComponent",
                container = TypedComponent,
                constructor = function(x: number, y: number): TypedComponent
                    return {x = x or 0, y = y or 0}
                end
            })

            -- This demonstrates type safety - the factory must return the correct type
            local bundle = tecs.newBundle()
                :add(TC, function(): TypedComponent
                    return TC(10, 20)
                end)
                :build()

            local result = {bundle()}
            luassert.is_equal((result[1] as TypedComponent).x, 10, "Should have correct x")
            luassert.is_equal((result[1] as TypedComponent).y, 20, "Should have correct y")
        end)
    end)

    describe("required components", function()
        it("allows marking components as required", function()
            local Tag1 = tecs.newTagComponent({name = "RequiredTag1"})
            local Tag2 = tecs.newTagComponent({name = "RequiredTag2"})

            local builder = tecs.newBundle()
                :require(Tag1)
                :require(Tag2)

            luassert.is_not_nil(builder, "Builder should handle require calls")
            luassert.is_function(builder.build, "Builder should still have build method")
        end)

        it("validates all required components are provided", function()
            local record TestComponent is tecs.Component
                value: number
            end

            local TC = tecs.newComponent({
                name = "RequiredTestComponent",
                container = TestComponent,
                constructor = function(value: number): TestComponent
                    return {value = value or 0}
                end
            })

            local Tag3 = tecs.newTagComponent({name = "RequiredTag3"})

            local bundle = tecs.newBundle()
                :require(TC)
                :require(Tag3)
                :build()

            -- This should work - all requirements satisfied
            local result = {bundle(TC(42), Tag3() as tecs.Component)}
            luassert.is_not_nil(result, "Bundle should work with all required components")
            luassert.is_equal(#result, 2, "Bundle should return all required components")

            -- Check components are present
            local hasTC = false
            local hasTag3 = false
            for i = 1, #result do
                if result[i].componentName == "RequiredTestComponent" then
                    hasTC = true
                    luassert.is_equal((result[i] as TestComponent).value, 42, "Required component should have correct value")
                elseif result[i].componentName == "RequiredTag3" then
                    hasTag3 = true
                end
            end
            luassert.is_true(hasTC, "Should have required TestComponent")
            luassert.is_true(hasTag3, "Should have required Tag3")
        end)

        it("errors when required components are missing", function()
            local record TestComponent2 is tecs.Component
                name: string
            end

            local TC2 = tecs.newComponent({
                name = "RequiredTestComponent2",
                container = TestComponent2,
                constructor = function(name: string): TestComponent2
                    return {name = name or ""}
                end
            })

            local Tag4 = tecs.newTagComponent({name = "RequiredTag4"})
            local bundle = tecs.newBundle()
                :require(TC2)
                :require(Tag4)
                :build()

            luassert.has_error(function()
                bundle(Tag4() as tecs.Component)
            end, "Required component missing: RequiredTestComponent2")
        end)

        it("works with mixed required and optional components", function()
            local record RequiredComp is tecs.Component
                id: integer
            end

            local RC = tecs.newComponent({
                name = "RequiredComp",
                container = RequiredComp,
                constructor = function(id: integer): RequiredComp
                    return {id = id or 0}
                end
            })

            local record OptionalComp is tecs.Component
                name: string
            end

            local OC = tecs.newComponent({
                name = "OptionalComp",
                container = OptionalComp,
                constructor = function(name: string): OptionalComp
                    return {name = name or "default"}
                end
            })

            local Tag6 = tecs.newTagComponent({name = "OptionalTag6"})

            local bundle = tecs.newBundle()
                :require(RC)  -- Required
                :add(OC, function(): OptionalComp
                    return OC("default_name")
                end)  -- Optional with default
                :add(Tag6, function(): tecs.Component
                    return Tag6()
                end)  -- Optional with default
                :build()

            -- Test 1: Required + defaults
            local result1 = {bundle(RC(100))}
            luassert.is_equal(#result1, 3, "Should have required + optional defaults")

            local hasRC, hasOC, hasTag6 = false, false, false
            for i = 1, #result1 do
                local comp = result1[i]
                if comp.componentName == "RequiredComp" then
                    hasRC = true
                    luassert.is_equal((comp as RequiredComp).id, 100, "Required component should have provided value")
                elseif comp.componentName == "OptionalComp" then
                    hasOC = true
                    luassert.is_equal((comp as OptionalComp).name, "default_name", "Optional component should use default")
                elseif comp.componentName == "OptionalTag6" then
                    hasTag6 = true
                end
            end
            luassert.is_true(hasRC, "Should have required component")
            luassert.is_true(hasOC, "Should have optional component with default")
            luassert.is_true(hasTag6, "Should have optional tag with default")

            -- Test 2: Required + some overrides
            local result2 = {
                bundle(
                    RC(200),
                    OC("custom_name")  -- Override the optional component
                )
            }
            luassert.is_equal(#result2, 3, "Should have required + overridden optional + default tag")

            hasRC, hasOC, hasTag6 = false, false, false
            for i = 1, #result2 do
                local comp = result2[i]
                if comp.componentName == "RequiredComp" then
                    hasRC = true
                    luassert.is_equal((comp as RequiredComp).id, 200, "Required component should have provided value")
                elseif comp.componentName == "OptionalComp" then
                    hasOC = true
                    luassert.is_equal((comp as OptionalComp).name, "custom_name", "Optional component should use override")
                elseif comp.componentName == "OptionalTag6" then
                    hasTag6 = true
                end
            end
            luassert.is_true(hasRC, "Should have required component")
            luassert.is_true(hasOC, "Should have overridden optional component")
            luassert.is_true(hasTag6, "Should have optional tag with default")
        end)

        it("supports chaining require and add calls", function()
            local Tag7 = tecs.newTagComponent({name = "ChainTag7"})
            local Tag8 = tecs.newTagComponent({name = "ChainTag8"})
            local Tag9 = tecs.newTagComponent({name = "ChainTag9"})

            local bundle = tecs.newBundle()
                :require(Tag7)
                :add(Tag8, function(): tecs.Component
                    return Tag8()
                end)
                :require(Tag9)
                :build()

            -- Should work with all required provided
            local result = {bundle(Tag7() as tecs.Component, Tag9() as tecs.Component)}
            luassert.is_equal(#result, 3, "Should have both required + optional default")

            -- Should error if required missing
            luassert.has_error(function()
                bundle(Tag7() as tecs.Component)  -- Tag9 missing
            end, "Required component missing: ChainTag9")
        end)

        it("handles empty bundles with required components", function()
            local Tag10 = tecs.newTagComponent({name = "EmptyBundleTag"})

            local bundle = tecs.newBundle()
                :require(Tag10)
                :build()

            -- Should work when required is provided
            local result = {bundle(Tag10() as tecs.Component)}
            luassert.is_equal(#result, 1, "Should have just the required component")
            luassert.is_equal(result[1].componentName, "EmptyBundleTag", "Should have the right component")

            -- Should error when required is missing
            luassert.has_error(function()
                bundle()
            end, "Required component missing: EmptyBundleTag")
        end)

        it("preserves unknown components not in bundle", function()
            local record TestComponent is tecs.Component
                value: number
            end

            local testContainer = {} as TestComponent
            local TestComp = tecs.newComponent({
                name = "UnknownTestComponent",
                container = testContainer,
                constructor = function(value: number): TestComponent
                    return {value = value or 0, componentType = testContainer}
                end
            })

            local KnownTag = tecs.newTagComponent({name = "KnownTag"})
            local UnknownTag1 = tecs.newTagComponent({name = "UnknownTag1"})
            local UnknownTag2 = tecs.newTagComponent({name = "UnknownTag2"})

            -- Bundle only includes TestComp and KnownTag
            local bundle = tecs.newBundle()
                :add(TestComp, function(): TestComponent
                    return TestComp(42)
                end)
                :add(KnownTag, function(): tecs.Component
                    return KnownTag()
                end)
                :build()

            -- Pass unknown components that aren't in the bundle
            local result = {
                bundle(
                    UnknownTag1() as tecs.Component,  -- Unknown - should be preserved
                    TestComp(100),                    -- Known - should override factory
                    UnknownTag2() as tecs.Component   -- Unknown - should be preserved
                )
            }

            luassert.is_equal(#result, 4, "Should have 2 unknown + 1 override + 1 default")

            -- Verify all components are present
            local hasTestComp = false
            local hasKnownTag = false
            local hasUnknownTag1 = false
            local hasUnknownTag2 = false

            for i = 1, #result do
                local comp = result[i]
                if comp.componentName == "UnknownTestComponent" then
                    hasTestComp = true
                    luassert.is_equal((comp as TestComponent).value, 100, "Should use override value")
                elseif comp.componentName == "KnownTag" then
                    hasKnownTag = true
                elseif comp.componentName == "UnknownTag1" then
                    hasUnknownTag1 = true
                elseif comp.componentName == "UnknownTag2" then
                    hasUnknownTag2 = true
                end
            end

            luassert.is_true(hasTestComp, "Should have TestComponent (overridden)")
            luassert.is_true(hasKnownTag, "Should have KnownTag (from factory)")
            luassert.is_true(hasUnknownTag1, "Should preserve UnknownTag1")
            luassert.is_true(hasUnknownTag2, "Should preserve UnknownTag2")
        end)

        it("handles only unknown components", function()
            local KnownTag = tecs.newTagComponent({name = "KnownOnlyTag"})
            local UnknownTag = tecs.newTagComponent({name = "UnknownOnlyTag"})

            -- Bundle with only one component
            local bundle = tecs.newBundle()
                :add(KnownTag, function(): tecs.Component
                    return KnownTag()
                end)
                :build()

            -- Pass only unknown components
            local result = {bundle(UnknownTag() as tecs.Component)}

            luassert.is_equal(#result, 2, "Should have 1 unknown + 1 from factory")

            local hasKnownTag = false
            local hasUnknownTag = false

            for i = 1, #result do
                local comp = result[i]
                if comp.componentName == "KnownOnlyTag" then
                    hasKnownTag = true
                elseif comp.componentName == "UnknownOnlyTag" then
                    hasUnknownTag = true
                end
            end

            luassert.is_true(hasKnownTag, "Should have KnownOnlyTag from factory")
            luassert.is_true(hasUnknownTag, "Should preserve UnknownOnlyTag")
        end)
    end)
end)