require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")
local libffi = require("tecs.internal.ffi.libffi")

describe("FFI fallback behavior", function()

    describe("FFI availability detection", function()
        it("should detect FFI availability correctly", function()
            local available = libffi.isFFIAvailable()
            luassert.is_true(type(available) == "boolean")

            -- FFI availability depends on runtime and environment variable
            local success, jitModule: any = pcall(require, "jit" as string)
            if success and jitModule and not os.getenv("TECS_DISABLE_FFI") then
                -- On LuaJIT without TECS_DISABLE_FFI, FFI should be available
                luassert.is_true(available)
            elseif os.getenv("TECS_DISABLE_FFI") then
                -- When explicitly disabled, FFI should not be available
                luassert.is_false(available)
            else
                -- On pure Lua, FFI should not be available
                luassert.is_false(available)
            end
        end)
    end)

    describe("Component creation with fallback", function()
        it("should create FFI components on LuaJIT", function()
            if not libffi.isFFIAvailable() then
                pending("FFI not available, skipping FFI test")
            end

            local Position = tecs.newFFIComponent({
                name = "Position",
                container = {},
                fields = {
                    {"x", "float"},
                    {"y", "float"}
                }
            })

            luassert.is_not_nil(Position)
            luassert.is_equal("Position", Position.componentName)

            -- Test component creation
            local pos = Position({x = 10, y = 20}) as {string:any}
            luassert.is_equal(10, pos.x)
            luassert.is_equal(20, pos.y)
        end)

        it("should create table-based components when FFI unavailable", function()
            -- This test would require mocking FFI availability
            -- For now, just ensure the component system works
            local container: tecs.Component = {}
            local TestComponent = tecs.newComponent({
                name = "TestComponent",
                container = container,
                constructor = function(data: any): tecs.Component
                    return (data or {}) as tecs.Component
                end
            })

            luassert.is_not_nil(TestComponent)
            luassert.is_equal("TestComponent", TestComponent.componentName)
        end)
    end)

    describe("Array type fallbacks", function()
        it("should create arrays regardless of FFI availability", function()
            local ffi = require("tecs.internal.ffi")

            -- Test Int32Array creation
            local intArray = ffi.newInt32(10)
            luassert.is_not_nil(intArray)

            -- Test Float32Array creation
            local floatArray = ffi.newFloat32(10)
            luassert.is_not_nil(floatArray)

            -- Test basic operations
            ffi.setIntArraySize(intArray, 5)
            luassert.is_equal(5, intArray[0])

            ffi.setFloat32ArraySize(floatArray, 3)
            luassert.is_equal(3, floatArray[0])
        end)

        it("should handle capacity management", function()
            local ffi = require("tecs.internal.ffi")

            local intArray = ffi.newInt32(10)
            local expandedArray = ffi.ensureCapacityInt32(intArray, 20)
            luassert.is_not_nil(expandedArray)

            local floatArray = ffi.newFloat32(10)
            local expandedFloatArray = ffi.ensureCapacityFloat32(floatArray, 20)
            luassert.is_not_nil(expandedFloatArray)
        end)
    end)

    describe("Storage with automatic fallback", function()
        it("should create storage types with automatic fallback", function()
            local storage = require("tecs.internal.storage")

            -- Test FFI storage with fallback
            local ffiStorage = storage.newFFIStorage({
                name = "TestComponent",
                fields = {{"x", "float"}, {"y", "float"}},
                recycle = true,
                recyclePoolSize = 32
            })
            luassert.is_not_nil(ffiStorage)

            -- Test simple table storage
            local simpleStorage = storage.newTableStorage()
            luassert.is_not_nil(simpleStorage)
        end)
    end)

    describe("FFI events fallback", function()
        it("should create events with proper defaults when FFI is unavailable", function()
            local record DamageEvent is tecs.Event
                damage: number
                entityId: integer
                metamethod __call: function(self, damage: number, entityId: integer): DamageEvent
            end

            tecs.newFFIEvent(DamageEvent, {
                {"damage", "float"},
                {"entityId", "int32_t"}
            }, "Test_DamageEvent_Unique")

            local event1 = DamageEvent(15.5, 42)
            luassert.is_equal(15.5, event1.damage)
            luassert.is_equal(42, event1.entityId)
            luassert.is_not_nil(event1.eventId)

            local event2 = DamageEvent(0, 0)
            luassert.is_equal(0, event2.damage)
            luassert.is_equal(0, event2.entityId)
            luassert.is_not_nil(event2.eventId)

            luassert.is_not_equal(event1, event2)
        end)

        it("should work with emitters", function()
            local record CollisionEvent is tecs.Event
                x: number
                y: number
                force: number
                metamethod __call: function(self, x: number, y: number, force: number): CollisionEvent
            end

            tecs.newFFIEvent(CollisionEvent, {
                {"x", "float"},
                {"y", "float"},
                {"force", "float"}
            }, "Test_CollisionEvent")

            local emitter = tecs.newEmitter()
            local receivedEvent: CollisionEvent = nil

            emitter:observe(CollisionEvent, function(e: CollisionEvent)
                receivedEvent = e
            end)

            local testEvent = CollisionEvent(10.0, 20.0, 5.5)
            emitter:emit(testEvent)

            luassert.is_not_nil(receivedEvent)
            luassert.is_equal(10.0, receivedEvent.x)
            luassert.is_equal(20.0, receivedEvent.y)
            luassert.is_equal(5.5, receivedEvent.force)
        end)

        it("should reject eventId field in schema", function()
            local record BadEvent is tecs.Event
                value: number
                metamethod __call: function(self, value: number): BadEvent
            end

            luassert.has_error(function()
                tecs.newFFIEvent(BadEvent, {
                    {"eventId", "int32_t"},
                    {"value", "float"}
                })
            end, "eventId field is automatically injected and should not be specified manually")
        end)

        it("should handle boolean fields correctly", function()
            local record BoolEvent is tecs.Event
                active: boolean
                visible: boolean
                metamethod __call: function(self, active: boolean, visible: boolean): BoolEvent
            end

            tecs.newFFIEvent(BoolEvent, {
                {"active", "bool"},
                {"visible", "bool"}
            })

            local event = BoolEvent(true, false)
            luassert.is_equal(true, event.active)
            luassert.is_equal(false, event.visible)
        end)
    end)
end)