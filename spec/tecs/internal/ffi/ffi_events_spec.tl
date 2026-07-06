local FFIEvents <const> = require("tecs.internal.ffi.FFIEvents")

describe("FFIEvents", function()

    describe("new", function()
        it("creates a manager with initial state", function()
            local mgr = FFIEvents.new()
            assert.equals(1, mgr.nextTypeId)
            assert.equals(1, mgr.nextSliceId)
        end)
    end)

    describe("registerEvent", function()
        it("assigns a type ID", function()
            local mgr = FFIEvents.new()
            local event = {}
            local typeId = mgr:registerEvent(event, {{"value", "float"}})
            assert.equals(1, typeId)
        end)

        it("assigns sequential type IDs", function()
            local mgr = FFIEvents.new()
            local e1, e2 = {}, {}
            local id1 = mgr:registerEvent(e1, {{"a", "int32_t"}})
            local id2 = mgr:registerEvent(e2, {{"b", "int32_t"}})
            assert.equals(1, id1)
            assert.equals(2, id2)
        end)

        it("returns existing ID for duplicate registration", function()
            local mgr = FFIEvents.new()
            local event = {}
            local id1 = mgr:registerEvent(event, {{"x", "float"}})
            local id2 = mgr:registerEvent(event, {{"x", "float"}})
            assert.equals(id1, id2)
            assert.equals(2, mgr.nextTypeId) -- only incremented once
        end)

        it("accepts custom struct name", function()
            local mgr = FFIEvents.new()
            local event = {}
            local typeId = mgr:registerEvent(event, {{"hp", "float"}}, "FFIEvSpecCustom")
            assert.is_true(typeId > 0)
            local reg = mgr.registrationsById[typeId]
            assert.equals("FFIEvSpecCustom", reg.structName)
        end)

        it("errors on struct name collision with different layout", function()
            local mgr = FFIEvents.new()
            local e1, e2 = {}, {}
            mgr:registerEvent(e1, {{"a", "float"}}, "FFIEvSpecCollide")
            assert.has_error(function()
                mgr:registerEvent(e2, {{"b", "int32_t"}}, "FFIEvSpecCollide")
            end)
        end)

        it("allows same struct name with identical layout", function()
            local mgr1 = FFIEvents.new()
            local mgr2 = FFIEvents.new()
            local e1, e2 = {}, {}
            mgr1:registerEvent(e1, {{"val", "double"}}, "FFIEvSpecSame")
            -- Same name, same fields on a different manager; should not error
            assert.has_no.errors(function()
                mgr2:registerEvent(e2, {{"val", "double"}}, "FFIEvSpecSame")
            end)
        end)
    end)

    describe("slices", function()
        it("acquires sequential slice IDs", function()
            local mgr = FFIEvents.new()
            assert.equals(1, mgr:acquireSlice())
            assert.equals(2, mgr:acquireSlice())
        end)

        it("reuses released slice IDs", function()
            local mgr = FFIEvents.new()
            local slice1 = mgr:acquireSlice()
            local slice2 = mgr:acquireSlice()
            mgr:releaseSlice(slice1)
            assert.equals(slice1, mgr:acquireSlice())
            assert.equals(3, mgr:acquireSlice())
            assert.equals(2, slice2)
        end)
    end)

    describe("vendEvent", function()
        it("returns an event with typeId set", function()
            local mgr = FFIEvents.new()
            local event = {}
            local sliceId = mgr:acquireSlice()
            local typeId = mgr:registerEvent(event, {{"x", "float"}, {"y", "float"}})
            local instance = mgr:vendEvent(sliceId, event) as {string: any}
            assert.equals(typeId, instance.typeId)
        end)

        it("returns writable FFI struct", function()
            local mgr = FFIEvents.new()
            local event = {}
            local sliceId = mgr:acquireSlice()
            mgr:registerEvent(event, {{"x", "float"}, {"y", "float"}})
            local instance = mgr:vendEvent(sliceId, event) as {string: any}
            instance.x = 3.0
            instance.y = 4.0
            assert.near(3.0, tonumber(instance.x), 0.001)
            assert.near(4.0, tonumber(instance.y), 0.001)
        end)

        it("vends multiple independent events", function()
            local mgr = FFIEvents.new()
            local event = {}
            local sliceId = mgr:acquireSlice()
            mgr:registerEvent(event, {{"val", "int32_t"}})
            local a = mgr:vendEvent(sliceId, event) as {string: any}
            local b = mgr:vendEvent(sliceId, event) as {string: any}
            a.val = 10
            b.val = 20
            assert.equals(10, a.val)
            assert.equals(20, b.val)
        end)

        it("errors for unregistered event type", function()
            local mgr = FFIEvents.new()
            local sliceId = mgr:acquireSlice()
            assert.has_error(function()
                mgr:vendEvent(sliceId, {})
            end)
        end)
    end)

    describe("clearSlice", function()
        it("allows reuse after clear", function()
            local mgr = FFIEvents.new()
            local event = {}
            local sliceId = mgr:acquireSlice()
            mgr:registerEvent(event, {{"n", "int32_t"}})
            local a = mgr:vendEvent(sliceId, event) as {string: any}
            a.n = 42
            mgr:clearSlice(sliceId)
            -- After clear, can vend again (old references are stale)
            local b = mgr:vendEvent(sliceId, event) as {string: any}
            assert.is_not_nil(b)
        end)

        it("zeroes reused slots before vending again", function()
            local mgr = FFIEvents.new()
            local event = {}
            local sliceId = mgr:acquireSlice()
            mgr:registerEvent(event, {{"a", "int32_t"}, {"b", "int32_t"}})

            local first = mgr:vendEvent(sliceId, event) as {string: any}
            first.a = 10
            first.b = 20

            mgr:clearSlice(sliceId)

            local second = mgr:vendEvent(sliceId, event) as {string: any}
            assert.equals(0, second.a)
            assert.equals(0, second.b)
        end)

        it("keeps slices isolated", function()
            local mgr = FFIEvents.new()
            local event = {}
            local sliceA = mgr:acquireSlice()
            local sliceB = mgr:acquireSlice()
            mgr:registerEvent(event, {{"n", "int32_t"}})

            local a = mgr:vendEvent(sliceA, event) as {string: any}
            local b = mgr:vendEvent(sliceB, event) as {string: any}
            a.n = 11
            b.n = 22

            mgr:clearSlice(sliceA)

            local a2 = mgr:vendEvent(sliceA, event) as {string: any}
            local b2 = mgr:vendEvent(sliceB, event) as {string: any}
            assert.equals(0, a2.n)
            assert.equals(22, b.n)
            assert.equals(0, b2.n)
        end)
    end)

    describe("getTypeId", function()
        it("returns type ID for registered event", function()
            local mgr = FFIEvents.new()
            local event = {}
            local typeId = mgr:registerEvent(event, {{"v", "float"}})
            assert.equals(typeId, mgr:getTypeId(event))
        end)

        it("returns 0 for unregistered event", function()
            local mgr = FFIEvents.new()
            assert.equals(0, mgr:getTypeId({}))
        end)
    end)
end)
