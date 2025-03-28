require("busted")
local luassert <const> = require("luassert")

describe("FFI Fallback", function()
    local tecs <const> = require("tecs")

    -- Note: This test must be run with TECS_DISABLE_FFI=1 environment variable set

    describe("FFI detection", function()
        it("should respect TECS_DISABLE_FFI environment variable", function()
            local libffi = require("tecs.internal.ffi.libffi")
            if os.getenv("TECS_DISABLE_FFI") then
                luassert.is_false(libffi.isFFIAvailable())
            else
                -- Check if we're on LuaJIT (where FFI would be available)
                local success, jitModule = pcall(require, "jit" as string)
                if success and jitModule then
                    -- On LuaJIT without TECS_DISABLE_FFI, FFI should be available
                    luassert.is_true(libffi.isFFIAvailable())
                else
                    -- On regular Lua, FFI is never available
                    luassert.is_false(libffi.isFFIAvailable())
                end
            end
        end)

        it("should throw error when trying to get FFI when unavailable", function()
            local libffi = require("tecs.internal.ffi.libffi")
            if not libffi.isFFIAvailable() then
                luassert.has_error(function()
                    libffi.getFFI()
                end, "FFI is not available - this function should only be called when FFI is available")
            else
                -- When FFI is available, getFFI should work
                luassert.is_not_nil(libffi.getFFI())
            end
        end)
    end)

    describe("Component creation", function()
        it("should create FFI components (with fallback when disabled)", function()
            local Position = tecs.newFFIComponent({
                name = "FallbackPosition",
                container = {},
                fields = {
                    {"x", "float"},
                    {"y", "float"},
                    {"z", "float"}
                }
            })

            luassert.is_not_nil(Position)
            luassert.is_equal("FallbackPosition", Position.componentName)
        end)

        it("should create component instances with correct defaults", function()
            local Health = tecs.newFFIComponent({
                name = "FallbackHealth",
                container = {},
                fields = {
                    {"current", "int32_t"},
                    {"max", "int32_t"},
                    {"regeneration", "float"}
                }
            })

            local instance = Health()
            local instanceAny = instance as {string: any}
            luassert.is_equal(0, instanceAny.current)
            luassert.is_equal(0, instanceAny.max)
            luassert.is_equal(0.0, instanceAny.regeneration)
        end)

        it("should create component instances with provided values", function()
            local Transform = tecs.newFFIComponent({
                name = "FallbackTransform",
                container = {},
                fields = {
                    {"x", "float"},
                    {"y", "float"},
                    {"rotation", "float"}
                }
            })

            local instance = Transform(10.5, 20.5, 45.0)
            local instanceAny = instance as {string: any}
            luassert.is_equal(10.5, instanceAny.x)
            luassert.is_equal(20.5, instanceAny.y)
            luassert.is_equal(45.0, instanceAny.rotation)
        end)

        it("should create component instances from table", function()
            local Velocity = tecs.newFFIComponent({
                name = "FallbackVelocity",
                container = {},
                fields = {
                    {"dx", "float"},
                    {"dy", "float"}
                }
            })

            local instance = Velocity({dx = 5.0, dy = -3.0})
            local instanceAny = instance as {string: any}
            luassert.is_equal(5.0, instanceAny.dx)
            luassert.is_equal(-3.0, instanceAny.dy)
        end)

        it("should support boolean fields", function()
            local Flags = tecs.newFFIComponent({
                name = "FallbackFlags",
                container = {},
                fields = {
                    {"active", "bool"},
                    {"visible", "bool"}
                }
            })

            local instance = Flags()
            local instanceAny = instance as {string: any}
            luassert.is_false(instanceAny.active)
            luassert.is_false(instanceAny.visible)

            local instance2 = Flags(true, false)
            local instance2Any = instance2 as {string: any}
            luassert.is_true(instance2Any.active)
            luassert.is_false(instance2Any.visible)
        end)
    end)

    describe("Relationship creation", function()
        it("should create FFI relationships (with fallback when disabled)", function()
            local ChildOf = tecs.newFFIRelationship({
                name = "FallbackChildOf",
                container = {},
                fields = {
                    {"depth", "int32_t"}
                }
            })

            luassert.is_not_nil(ChildOf)
            luassert.is_equal("FallbackChildOf", ChildOf.componentName)
        end)

        it("should create tag relationships (with fallback when disabled)", function()
            local Following = tecs.newTagRelationship({
                name = "FallbackFollowing"
            })

            luassert.is_not_nil(Following)
            luassert.is_equal("FallbackFollowing", Following.componentName)
        end)
    end)

    describe("Storage fallback", function()
        it("should handle FFI storage requests (with fallback when disabled)", function()
            local storage = require("tecs.internal.storage")

            local ffiStorage = storage.newFFIStorage({
                name = "FallbackTestComponent",
                fields = {
                    {"x", "float"},
                    {"y", "float"}
                }
            })

            luassert.is_not_nil(ffiStorage)
            luassert.is_function(ffiStorage.new)
            luassert.is_function(ffiStorage.clear)
        end)

        it("should handle recycling in storage (with fallback when disabled)", function()
            local storage = require("tecs.internal.storage")

            local recyclingStorage = storage.newFFIStorage({
                name = "FallbackRecyclingComponent",
                fields = {{"value", "int32_t"}},
                recycle = true,
                recyclePoolSize = 10
            })

            luassert.is_not_nil(recyclingStorage)
        end)
    end)

    describe("Compatibility layer", function()
        it("should provide working compat functions", function()
            luassert.is_not_nil(tecs.compat)
            luassert.is_function(tecs.compat.clear)
            luassert.is_function(tecs.compat.new)
            luassert.is_function(tecs.compat.bor)
            luassert.is_function(tecs.compat.band)
            luassert.is_function(tecs.compat.bxor)
        end)

        it("should work with table operations", function()
            local t = tecs.compat.new(5, 0)
            t[1] = "test"
            luassert.is_equal("test", t[1])

            tecs.compat.clear(t)
            luassert.is_nil(t[1])
        end)

        it("should work with bit operations", function()
            luassert.is_equal(7, tecs.compat.bor(3, 4))
            luassert.is_equal(0, tecs.compat.band(3, 4))
            luassert.is_equal(7, tecs.compat.bxor(3, 4))
        end)
    end)
end)