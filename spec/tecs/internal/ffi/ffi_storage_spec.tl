require("busted")
local FFIStorage <const> = require("tecs.internal.ffi.FFIStorage")
local luassert <const> = require("luassert")

describe(
    "FFIStorage",
    function()
        describe(
            "struct name binding",
            function()
                it(
                    "rejects binding a second component to a bound struct name",
                    function()
                        local structName = "BindGuardStruct" .. math.random(1, 1000000)
                        local s1 = FFIStorage.new({name = structName, fields = {{"x", "float"}}})
                        local a = {componentName = "BindGuardA"} as any
                        s1:createComponent(a)

                        -- Same-layout reuse of the struct name is allowed for storage,
                        -- but a second component must not steal the shared metatype:
                        -- instances resolve componentType through it, so world:set
                        -- would route the first component's data into the second.
                        local s2 = FFIStorage.new({name = structName, fields = {{"x", "float"}}})
                        local b = {componentName = "BindGuardB"} as any
                        luassert.error_matches(function() s2:createComponent(b) end, "already bound")
                    end
                )

                it(
                    "allows re-binding the same component",
                    function()
                        local structName = "BindGuardSame" .. math.random(1, 1000000)
                        local s = FFIStorage.new({name = structName, fields = {{"x", "float"}}})
                        local a = {componentName = "BindGuardSameA"} as any
                        s:createComponent(a)
                        s:createComponent(a)
                    end
                )

                it(
                    "updates metatype metadata after the storage module reloads",
                    function()
                        local structName = "ReloadedStorageStruct" .. math.random(1, 1000000)
                        local bindingName = "ReloadedStorageComponent" .. math.random(1, 1000000)
                        local s1 = FFIStorage.new({
                            name = structName,
                            bindingName = bindingName,
                            fields = {{"x", "float"}},
                        })
                        local a = {componentName = bindingName} as any
                        s1:createComponent(a)

                        local moduleName <const> = "tecs.internal.ffi.FFIStorage"
                        package.loaded[moduleName] = nil
                        local ReloadedFFIStorage = require(moduleName) as any
                        package.loaded[moduleName] = FFIStorage

                        local s2 = ReloadedFFIStorage.new({
                            name = structName,
                            bindingName = bindingName,
                            fields = {{"x", "float"}},
                        }) as any
                        local b = {componentName = bindingName} as any
                        local allocate = s2:createComponent(b) as function(): any
                        local instance = allocate()

                        luassert.is_equal(b, instance.componentType)
                    end
                )
            end
        )
    end
)
