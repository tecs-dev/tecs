require("busted")
local tecs <const> = require("tecs")
local luassert <const> = require("luassert")

local type Event = tecs.Event

-------------------------------------------------------------------------------------------------------------------------
-- Test fixtures
-------------------------------------------------------------------------------------------------------------------------

local record Greet is Event
    name: string
    metamethod __call: function(self, name: string): Greet
end

local record Depart is Event
    name: string
    metamethod __call: function(self, name: string): Depart
end

-- Register events with mutate-in-place constructors
Greet.init = function(e: Greet, name: string)
    e.name = name
end
tecs.newEvent(Greet)
Depart.init = function(e: Depart, name: string)
    e.name = name
end
tecs.newEvent(Depart)

-- Test address
local ADDR <const> = 0

-------------------------------------------------------------------------------------------------------------------------
-- Test cases
-------------------------------------------------------------------------------------------------------------------------

describe("MessageBus", function()
    describe("new", function()
        it("works", function()
            tecs.newMessageBus()
        end)
    end)

    describe("subscribe", function()
        it("emits in order", function()
            local messages: {string} = {}
            local bus = tecs.newMessageBus()
            bus:observe(ADDR, Greet, function(greet: Greet)
                table.insert(messages, greet.name .. " 1")
            end)
            bus:observe(ADDR, Greet, function(greet: Greet)
                table.insert(messages, greet.name .. " 2")
            end)
            bus:observe(ADDR, Depart, function(depart: Depart)
                table.insert(messages, "Depart: " .. depart.name)
            end)
            bus:emit(ADDR, Greet("Hi"))
            luassert.is_equal(2, #messages, "Expected 2 elements")
            luassert.is_equal("Hi 1", messages[1], "Expected first message to be 'Hi 1'")
            luassert.is_equal("Hi 2", messages[2], "Expected second message to be 'Hi 2'")

            bus:emit(ADDR, Depart("Bye"))
            luassert.is_equal(3, #messages, "Expected 3 elements")
            luassert.is_equal("Depart: Bye", messages[3], "Expected third message to be 'Depart: Bye'")
        end)
    end)

    describe("unsubscribe", function()
        it("emits once with observeOnce", function()
            local messages: {string} = {}
            local bus = tecs.newMessageBus()
            bus:observeOnce(ADDR, Greet, function(greet: Greet)
                table.insert(messages, greet.name .. " 1")
            end)
            bus:observeOnce(ADDR, Greet, function(greet: Greet)
                table.insert(messages, greet.name .. " 2")
            end)

            bus:emit(ADDR, Greet("Hi"))
            luassert.is_equal(2, #messages, "Expected 2 elements")
            luassert.is_equal("Hi 1", messages[1], "Expected first message to be 'Hi 1'")
            luassert.is_equal("Hi 2", messages[2], "Expected second message to be 'Hi 2'")

            bus:emit(ADDR, Greet("Hi"))
            luassert.is_equal(2, #messages, "Expected 2 elements after second emit")
        end)

        it("can unsubscribe by receiver", function()
            local messages: {string} = {}
            local bus = tecs.newMessageBus()
            local listener = function(greet: Greet)
                table.insert(messages, greet.name)
            end
            bus:observe(ADDR, Greet, listener)
            bus:emit(ADDR, Greet("Hi"))
            luassert.is_equal(1, #messages, "Expected 1 element")
            luassert.is_equal("Hi", messages[1], "Expected first message to be 'Hi'")

            bus:stopObserving(ADDR, Greet, listener)
            bus:emit(ADDR, Greet("Hi"))
            luassert.is_equal(1, #messages, "Expected 1 element after second emit")
        end)

        it("can unsubscribe by id", function()
            local messages: {string} = {}
            local bus = tecs.newMessageBus()
            local listener = function(greet: Greet)
                table.insert(messages, greet.name)
            end
            bus:observe(ADDR, Greet, listener, "id")
            bus:emit(ADDR, Greet("Hi"))
            luassert.is_equal(1, #messages, "Expected 1 element")
            luassert.is_equal("Hi", messages[1], "Expected first message to be 'Hi'")

            bus:stopObserving(ADDR, Greet, "id")
            bus:emit(ADDR, Greet("Hi"))
            luassert.is_equal(1, #messages, "Expected 1 element after second emit")
        end)
    end)

    describe("address isolation", function()
        it("events at different addresses are isolated", function()
            local messages: {string} = {}
            local bus = tecs.newMessageBus()

            bus:observe(1, Greet, function(greet: Greet)
                table.insert(messages, "addr1: " .. greet.name)
            end)
            bus:observe(2, Greet, function(greet: Greet)
                table.insert(messages, "addr2: " .. greet.name)
            end)

            bus:emit(1, Greet("Hi"))
            luassert.is_equal(1, #messages)
            luassert.is_equal("addr1: Hi", messages[1])

            bus:emit(2, Greet("Hello"))
            luassert.is_equal(2, #messages)
            luassert.is_equal("addr2: Hello", messages[2])
        end)

        it("clearAddress removes only that address", function()
            local count1 = 0
            local count2 = 0
            local bus = tecs.newMessageBus()

            bus:observe(1, Greet, function() count1 = count1 + 1 end)
            bus:observe(2, Greet, function() count2 = count2 + 1 end)

            bus:emit(1, Greet("test"))
            bus:emit(2, Greet("test"))
            luassert.is_equal(1, count1)
            luassert.is_equal(1, count2)

            bus:clearAddress(1)

            bus:emit(1, Greet("test"))
            bus:emit(2, Greet("test"))
            luassert.is_equal(1, count1) -- unchanged
            luassert.is_equal(2, count2) -- incremented
        end)
    end)

    describe("performance optimizations", function()
        it("handles single observer fast path", function()
            local count = 0
            local bus = tecs.newMessageBus()
            bus:observe(ADDR, Greet, function()
                count = count + 1
            end)

            bus:emit(ADDR, Greet("test"))
            luassert.is_equal(1, count)
        end)

        it("handles small observer count fast path", function()
            local counts = {0, 0, 0}
            local bus = tecs.newMessageBus()

            for i = 1, 3 do
                local idx = i
                bus:observe(ADDR, Greet, function()
                    counts[idx] = counts[idx] + 1
                end)
            end

            bus:emit(ADDR, Greet("test"))
            luassert.is_equal(1, counts[1])
            luassert.is_equal(1, counts[2])
            luassert.is_equal(1, counts[3])
        end)

        it("maintains order after swap-and-pop removal", function()
            local messages: {string} = {}
            local bus = tecs.newMessageBus()

            local listener1 = function() table.insert(messages, "1") end
            local listener2 = function() table.insert(messages, "2") end
            local listener3 = function() table.insert(messages, "3") end
            local listener4 = function() table.insert(messages, "4") end

            bus:observe(ADDR, Greet, listener1)
            bus:observe(ADDR, Greet, listener2)
            bus:observe(ADDR, Greet, listener3)
            bus:observe(ADDR, Greet, listener4)

            -- Remove middle observer (tests swap-and-pop)
            bus:stopObserving(ADDR, Greet, listener2)

            messages = {}
            bus:emit(ADDR, Greet("test"))

            -- Order should be: 1, 4, 3 (4 was swapped into position 2)
            luassert.is_equal(3, #messages)
            luassert.is_true(messages[1] == "1")
            luassert.is_true(messages[2] == "4")
            luassert.is_true(messages[3] == "3")
        end)

        it("handles multiple IDs for same callback", function()
            local count = 0
            local bus = tecs.newMessageBus()
            local listener = function() count = count + 1 end

            bus:observe(ADDR, Greet, listener, "id1")
            bus:observe(ADDR, Greet, listener, "id2")
            bus:observe(ADDR, Depart, listener, "id3")

            bus:emit(ADDR, Greet("test"))
            luassert.is_equal(2, count)

            -- Remove by callback should remove all IDs
            bus:stopObserving(ADDR, Greet, listener)
            count = 0
            bus:emit(ADDR, Greet("test"))
            luassert.is_equal(0, count)

            -- But not affect other event types
            bus:emit(ADDR, Depart("test"))
            luassert.is_equal(1, count)

            -- Verify IDs were cleaned up
            bus:stopObserving(ADDR, Depart, "id1") -- Should do nothing
            bus:stopObserving(ADDR, Depart, "id2") -- Should do nothing
            count = 0
            bus:emit(ADDR, Depart("test"))
            luassert.is_equal(1, count) -- Still called

            bus:stopObserving(ADDR, Depart, "id3") -- Should remove it
            count = 0
            bus:emit(ADDR, Depart("test"))
            luassert.is_equal(0, count)
        end)

        it("correctly cleans up reverse mappings", function()
            local bus = tecs.newMessageBus()
            local listener1 = function() end
            local listener2 = function() end

            bus:observe(ADDR, Greet, listener1, "id1")
            bus:observe(ADDR, Greet, listener1, "id2")
            bus:observe(ADDR, Greet, listener2, "id3")

            -- Remove one ID for listener1
            bus:stopObserving(ADDR, Greet, "id1")

            -- listener1 should still be registered with id2
            luassert.is_true(bus:hasObservers(ADDR, Greet))

            -- Remove by callback should clean remaining IDs
            bus:stopObserving(ADDR, Greet, listener1)

            -- Only listener2 should remain
            luassert.is_true(bus:hasObservers(ADDR, Greet))

            bus:stopObserving(ADDR, Greet, "id3")
            luassert.is_false(bus:hasObservers(ADDR, Greet))
        end)

        it("handles removing during emission", function()
            local messages: {string} = {}
            local bus = tecs.newMessageBus()

            local listener2: function(Greet)
            local listener1 = function(_: Greet)
                table.insert(messages, "1")
                bus:stopObserving(ADDR, Greet, listener2)
            end
            listener2 = function(_: Greet)
                table.insert(messages, "2")
            end
            local listener3 = function(_: Greet)
                table.insert(messages, "3")
            end

            bus:observe(ADDR, Greet, listener1)
            bus:observe(ADDR, Greet, listener2)
            bus:observe(ADDR, Greet, listener3)

            bus:emit(ADDR, Greet("test"))

            -- All should be called despite removal during iteration
            luassert.is_equal(3, #messages)
            luassert.is_equal("1", messages[1])
            luassert.is_equal("2", messages[2])
            luassert.is_equal("3", messages[3])

            -- Second emit should not call listener2
            messages = {}
            bus:emit(ADDR, Greet("test"))
            luassert.is_equal(2, #messages)
            luassert.is_equal("1", messages[1])
            luassert.is_equal("3", messages[2])
        end)
    end)

    describe("newEvent", function()
        it("creates a new event type", function()
            local record Foo is Event
                hi: string
                metamethod __call: function(self: Foo, hi: string): Foo
            end
            Foo.init = function(e: Foo, hi: string)
                e.hi = hi
            end
            tecs.newEvent(Foo)

            luassert.is_not_nil(getmetatable(Foo), "Expected Foo to have a metatable")

            local instance = Foo("there")
            luassert.is_not_nil(instance.eventId, "Expected instance to have an eventId")
            luassert.is_equal(instance.hi, "there", "Expected instance hi to be 'there'")
        end)

        it("constructors return fresh table instances", function()
            local record Bar is Event
                value: number
                metamethod __call: function(self: Bar, value: number): Bar
            end
            Bar.init = function(e: Bar, value: number)
                e.value = value
            end
            tecs.newEvent(Bar)

            local instance1 = Bar(42)
            local instance2 = Bar(99)

            luassert.not_equal(instance1, instance2, "Expected direct constructors to allocate fresh instances")
            luassert.is_equal(instance2.value, 99, "Expected value to be updated")
        end)

        it("world:emit(address, EventType, ...) clears table event fields before re-init", function()
            local record Baz is Event
                a: number
                b: number
                metamethod __call: function(self: Baz, a: number, b?: number): Baz
            end
            Baz.init = function(e: Baz, a: number, b?: number)
                e.a = a
                if b ~= nil then
                    e.b = b
                end
            end
            tecs.newEvent(Baz)

            local world = tecs.newWorld()
            local first: Baz = nil
            local second: Baz = nil
            world:observe(ADDR, Baz, function(e: Baz)
                if not first then
                    first = e
                else
                    second = e
                end
            end)

            world:emit(ADDR, Baz, 1, 2)
            luassert.is_equal(1, first.a)
            luassert.is_equal(2, first.b)

            world:emit(ADDR, Baz, 3)
            luassert.is_equal(3, second.a)
            luassert.is_nil(second.b)
        end)

        it("world:emit(address, EventType, ...) allocates a distinct table for nested same-type emits", function()
            local record Nested is Event
                value: integer
                metamethod __call: function(self: Nested, value: integer): Nested
            end
            Nested.init = function(e: Nested, value: integer)
                e.value = value
            end
            tecs.newEvent(Nested)

            local world = tecs.newWorld()
            local outer: Nested = nil
            local inner: Nested = nil
            world:observe(ADDR, Nested, function(e: Nested)
                if not outer then
                    outer = e
                    world:emit(ADDR, Nested, 2)
                else
                    inner = e
                end
            end)

            world:emit(ADDR, Nested, 1)
            luassert.not_equal(outer, inner)
            luassert.is_equal(1, outer.value)
            luassert.is_equal(2, inner.value)
        end)

        it("world:emit(address, EventType, ...) skips init when there are no observers", function()
            local record SkipInit is Event
                value: integer
                metamethod __call: function(self: SkipInit, value: integer): SkipInit
            end

            local initCount = 0
            SkipInit.init = function(e: SkipInit, value: integer)
                initCount = initCount + 1
                e.value = value
            end
            tecs.newEvent(SkipInit)

            local world = tecs.newWorld()
            world:emit(ADDR, SkipInit, 7)
            luassert.is_equal(0, initCount)
        end)
    end)

    describe("newFFIEvent", function()
        it("does not partially configure an event when reserved fields are used", function()
            local record FFIReservedField is Event
                value: integer
                metamethod __call: function(self: FFIReservedField, value: integer): FFIReservedField
            end

            assert.has_error(function()
                tecs.newFFIEvent(FFIReservedField, {
                    {"typeId", "int32_t"},
                    {"value", "int32_t"},
                })
            end, "Field #1: 'typeId' is reserved and must not be specified manually")

            luassert.is_nil(FFIReservedField.eventId, "Expected invalid FFI event registration to leave eventId unset")

            tecs.newFFIEvent(FFIReservedField, {
                {"value", "int32_t"},
            }, "FFIReservedFieldRetry")

            local instance = FFIReservedField(42)
            luassert.is_not_nil(FFIReservedField.eventId, "Expected retry registration to succeed")
            luassert.is_equal(FFIReservedField.eventId, instance.eventId)
            luassert.is_equal(42, tonumber(instance.value))
        end)

        it("supports world:emit(address, FFIEventType, ...) with world-local allocation", function()
            local record FFILazyEmit is Event
                value: integer
                metamethod __call: function(self: FFILazyEmit, value: integer): FFILazyEmit
            end

            tecs.newFFIEvent(FFILazyEmit, {
                {"value", "int32_t"},
            }, "FFILazyEmit")

            local world = tecs.newWorld()
            local seen = 0
            world:observe(ADDR, FFILazyEmit, function(ev: FFILazyEmit)
                seen = tonumber(ev.value)
            end)

            world:emit(ADDR, FFILazyEmit, 99)
            luassert.is_equal(99, seen)
        end)
    end)

    describe("address clear during emit", function()
        it("survives an observer despawning its own entity mid-emit", function()
            local world = tecs.newWorld()
            -- A global OnDespawn observer makes despawn clear the entity's
            -- observer address inline.
            world:observe(0, tecs.builtins.OnDespawn, function(_e: tecs.builtins.OnDespawn) end)

            local e = world:spawn()
            world:commit()

            local secondRan = false
            world:observe(e, Greet, function(_g: Greet)
                world:despawn(e)
            end)
            world:observe(e, Greet, function(_g: Greet)
                secondRan = true
            end)

            world:emit(e, Greet, "hi")

            luassert.is_true(secondRan,
                "dispatch must finish over the array being cleared")
            luassert.is_false(world:isAlive(e))

            -- The address is cleared; a later emit finds no observers.
            local ranAfter = false
            world:observe(e, Depart, function(_d: Depart) ranAfter = true end)
            world:emit(e, Greet, "again")
            luassert.is_false(ranAfter)
        end)

        it("supports fresh observers at a cleared address after the emit", function()
            local world = tecs.newWorld()
            world:observe(0, tecs.builtins.OnDespawn, function(_e: tecs.builtins.OnDespawn) end)

            local e = world:spawn()
            world:commit()
            world:observe(e, Greet, function(_g: Greet)
                world:despawn(e)
            end)
            world:emit(e, Greet, "hi")

            local seen: {string} = {}
            world:observe(e, Greet, function(g: Greet) seen[#seen + 1] = g.name end)
            world:emit(e, Greet, "fresh")
            luassert.same({"fresh"}, seen)
        end)
    end)

    describe("observer cleanup on despawn", function()
        local LeakTag = tecs.newTagComponent({name = "ObserverLeakTag"})

        -- Observer addresses are slots; a despawn must clear the address
        -- even when no OnDespawn observer exists, or the slot's next
        -- entity inherits the old entity's observers.
        local function assertNoLeak(world: tecs.World, despawn: function(integer))
            local e1 = world:spawn(LeakTag())
            world:commit()

            local heard = 0
            world:observe(e1, Greet, function(_g: Greet) heard = heard + 1 end)
            world:emit(e1, Greet, "live")
            luassert.equals(1, heard, "observer fires while the entity lives")

            despawn(e1)
            world:commit()

            local e2 = world:spawn()
            world:commit()
            world:emit(e2, Greet, "recycled")
            luassert.equals(1, heard, "stale observer must not fire for the recycled slot")
        end

        it("clears per-entity observers on instant despawn", function()
            local world = tecs.newWorld()
            assertNoLeak(world, function(id: integer) world:despawn(id) end)
        end)

        it("clears per-entity observers on deferred despawn", function()
            local world = tecs.newWorld()
            assertNoLeak(world, function(id: integer)
                world:defer()
                world:despawn(id)
            end)
        end)

        it("clears per-entity observers on batch despawn", function()
            local world = tecs.newWorld()
            local q = world:query({include = {LeakTag}})
            assertNoLeak(world, function(_id: integer) world:batchDespawn(q) end)
        end)
    end)
end)
