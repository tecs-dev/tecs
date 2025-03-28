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

function Greet.new(name: string): Greet
    return { name = name }
end

local record Depart is Event
    name: string
    metamethod __call: function(self, name: string): Depart
end

function Depart.new(name: string): Depart
    return { name = name }
end

-- Register events
tecs.newEvent(Greet, Greet.new)
tecs.newEvent(Depart, Depart.new)

-------------------------------------------------------------------------------------------------------------------------
-- Test cases
-------------------------------------------------------------------------------------------------------------------------

describe("Emitter", function()
    describe("new", function()
        it("works", function()
            tecs.newEmitter()
        end)
    end)

    describe("subscribe", function()
        it("emits in order", function()
            local messages: {string} = {}
            local emitter = tecs.newEmitter()
            emitter:observe(Greet, function(greet: Greet)
                table.insert(messages, greet.name .. " 1")
            end)
            emitter:observe(Greet, function(greet: Greet)
                table.insert(messages, greet.name .. " 2")
            end)
            emitter:observe(Depart, function(depart: Depart)
                table.insert(messages, "Depart: " .. depart.name)
            end)
            emitter:emit(Greet("Hi"))
            luassert.is_equal(2, #messages, "Expected 2 elements")
            luassert.is_equal("Hi 1", messages[1], "Expected first message to be 'Hi 1'")
            luassert.is_equal("Hi 2", messages[2], "Expected second message to be 'Hi 2'")

            emitter:emit(Depart("Bye"))
            luassert.is_equal(3, #messages, "Expected 3 elements")
            luassert.is_equal("Depart: Bye", messages[3], "Expected third message to be 'Depart: Bye'")
        end)
    end)

    describe("unsubscribe", function()
        it("emits once", function()
            local messages: {string} = {}
            local emitter = tecs.newEmitter()
            emitter:observeOnce(Greet, function(greet: Greet)
                table.insert(messages, greet.name .. " 1")
            end)
            emitter:observeOnce(Greet, function(greet: Greet)
                table.insert(messages, greet.name .. " 2")
            end)

            emitter:emit(Greet("Hi"))
            luassert.is_equal(2, #messages, "Expected 2 elements")
            luassert.is_equal("Hi 1", messages[1], "Expected first message to be 'Hi 1'")
            luassert.is_equal("Hi 2", messages[2], "Expected second message to be 'Hi 2'")

            emitter:emit(Greet("Hi"))
            luassert.is_equal(2, #messages, "Expected 2 elements after second emit")
        end)

        it("can unsubscribe by receiver", function()
            local messages: {string} = {}
            local emitter = tecs.newEmitter()
            local listener = function(greet: Greet)
                table.insert(messages, greet.name)
            end
            emitter:observe(Greet, listener)
            emitter:emit(Greet("Hi"))
            luassert.is_equal(1, #messages, "Expected 1 element")
            luassert.is_equal("Hi", messages[1], "Expected first message to be 'Hi'")

            emitter:stopObserving(Greet, listener)
            emitter:emit(Greet("Hi"))
            luassert.is_equal(1, #messages, "Expected 1 element after second emit")
        end)

        it("can unsubscribe by id", function()
            local messages: {string} = {}
            local emitter = tecs.newEmitter()
            local listener = function(greet: Greet)
                table.insert(messages, greet.name)
            end
            emitter:observe(Greet, listener, "id")
            emitter:emit(Greet("Hi"))
            luassert.is_equal(1, #messages, "Expected 1 element")
            luassert.is_equal("Hi", messages[1], "Expected first message to be 'Hi'")

            emitter:stopObserving(Greet, "id")
            emitter:emit(Greet("Hi"))
            luassert.is_equal(1, #messages, "Expected 1 element after second emit")
        end)
    end)

    describe("performance optimizations", function()
        it("handles single observer fast path", function()
            local count = 0
            local emitter = tecs.newEmitter()
            emitter:observe(Greet, function()
                count = count + 1
            end)

            emitter:emit(Greet("test"))
            luassert.is_equal(1, count)
        end)

        it("handles small observer count fast path", function()
            local counts = {0, 0, 0}
            local emitter = tecs.newEmitter()

            for i = 1, 3 do
                local idx = i
                emitter:observe(Greet, function()
                    counts[idx] = counts[idx] + 1
                end)
            end

            emitter:emit(Greet("test"))
            luassert.is_equal(1, counts[1])
            luassert.is_equal(1, counts[2])
            luassert.is_equal(1, counts[3])
        end)

        it("maintains order after swap-and-pop removal", function()
            local messages: {string} = {}
            local emitter = tecs.newEmitter()

            local listener1 = function() table.insert(messages, "1") end
            local listener2 = function() table.insert(messages, "2") end
            local listener3 = function() table.insert(messages, "3") end
            local listener4 = function() table.insert(messages, "4") end

            emitter:observe(Greet, listener1)
            emitter:observe(Greet, listener2)
            emitter:observe(Greet, listener3)
            emitter:observe(Greet, listener4)

            -- Remove middle observer (tests swap-and-pop)
            emitter:stopObserving(Greet, listener2)

            messages = {}
            emitter:emit(Greet("test"))

            -- Order should be: 1, 4, 3 (4 was swapped into position 2)
            luassert.is_equal(3, #messages)
            luassert.is_true(messages[1] == "1")
            luassert.is_true(messages[2] == "4")
            luassert.is_true(messages[3] == "3")
        end)

        it("handles multiple IDs for same callback", function()
            local count = 0
            local emitter = tecs.newEmitter()
            local listener = function() count = count + 1 end

            emitter:observe(Greet, listener, "id1")
            emitter:observe(Greet, listener, "id2")
            emitter:observe(Depart, listener, "id3")

            emitter:emit(Greet("test"))
            luassert.is_equal(2, count)

            -- Remove by callback should remove all IDs
            emitter:stopObserving(Greet, listener)
            count = 0
            emitter:emit(Greet("test"))
            luassert.is_equal(0, count)

            -- But not affect other event types
            emitter:emit(Depart("test"))
            luassert.is_equal(1, count)

            -- Verify IDs were cleaned up
            emitter:stopObserving(Depart, "id1") -- Should do nothing
            emitter:stopObserving(Depart, "id2") -- Should do nothing
            count = 0
            emitter:emit(Depart("test"))
            luassert.is_equal(1, count) -- Still called

            emitter:stopObserving(Depart, "id3") -- Should remove it
            count = 0
            emitter:emit(Depart("test"))
            luassert.is_equal(0, count)
        end)

        it("correctly cleans up reverse mappings", function()
            local emitter = tecs.newEmitter()
            local listener1 = function() end
            local listener2 = function() end

            emitter:observe(Greet, listener1, "id1")
            emitter:observe(Greet, listener1, "id2")
            emitter:observe(Greet, listener2, "id3")

            -- Remove one ID for listener1
            emitter:stopObserving(Greet, "id1")

            -- listener1 should still be registered with id2
            luassert.is_true(emitter:hasObservers(Greet))

            -- Remove by callback should clean remaining IDs
            emitter:stopObserving(Greet, listener1)

            -- Only listener2 should remain
            luassert.is_true(emitter:hasObservers(Greet))

            emitter:stopObserving(Greet, "id3")
            luassert.is_false(emitter:hasObservers(Greet))
        end)

        it("handles removing during emission", function()
            local messages: {string} = {}
            local emitter = tecs.newEmitter()

            local listener2: function(Greet)
            local listener1 = function(_: Greet)
                table.insert(messages, "1")
                emitter:stopObserving(Greet, listener2)
            end
            listener2 = function(_: Greet)
                table.insert(messages, "2")
            end
            local listener3 = function(_: Greet)
                table.insert(messages, "3")
            end

            emitter:observe(Greet, listener1)
            emitter:observe(Greet, listener2)
            emitter:observe(Greet, listener3)

            emitter:emit(Greet("test"))

            -- All should be called despite removal during iteration
            luassert.is_equal(3, #messages)
            luassert.is_equal("1", messages[1])
            luassert.is_equal("2", messages[2])
            luassert.is_equal("3", messages[3])

            -- Second emit should not call listener2
            messages = {}
            emitter:emit(Greet("test"))
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
            tecs.newEvent(Foo, function(): Foo
                return {hi = "there"}
            end)

            luassert.is_not_nil(getmetatable(Foo), "Expected Foo to have a metatable")

            local instance = Foo("hi")
            luassert.is_not_nil(instance.eventId, "Expected instance to have an eventId")
            luassert.is_equal(instance.hi, "there", "Expected instance hi to be 'there'")
        end)

        it("Fails when a constructor does not return an instance", function()
            local record Foo is Event
                hi: string
                metamethod __call: function(self: Foo, hi: string): Foo
            end

            tecs.newEvent(Foo, function(): Foo end)

            luassert.has_error(function()
                Foo("hi")
            end, nil, "Event constructor must return an instance of the event")
        end)
    end)
end)
