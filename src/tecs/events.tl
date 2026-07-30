--[=[
Typed events and address-based message buses.

Define a record, initialize it in place, and register it once:

```teal
local record Damaged is tecs.events.Event
    amount: number

    metamethod __call: function(self, amount: number): Damaged
end

Damaged.init = function(event: Damaged, amount: number)
    event.amount = amount
end

tecs.events.newEvent(Damaged)
```

Worlds use the same event definitions and address routing as a standalone
[`MessageBus`](tealdoc:tecs.events.MessageBus). Address `0` conventionally
names a whole world, while entity IDs address individual entities.

Event delivery is synchronous. The emitter owns an event instance during
dispatch, so observers treat its fields as read-only and copy values they need
to retain. A table event constructed directly, such as `Damaged(10)`, is an
independent value the caller may keep.
]=]

local internal <const> = require("tecs.internal.events")
local types <const> = require("tecs.types")

local record events
    --- `Event` names a registered event definition or one of its instances.
    type Event = types.events.Event

    --- `EventListener` synchronously receives an event of its declared type.
    type EventListener = types.events.EventListener

    --- `EventInit` initializes an event instance from constructor arguments.
    type EventInit = types.events.EventInit

    --- `MessageBus` routes typed events by integer address.
    type MessageBus = types.events.MessageBus

    --- Configures a table event with a callable constructor.
    ---
    --- Registration mutates the supplied definition by assigning its event ID
    --- and constructor metatable. Register each definition once.
    ---
    --- @param event The caller supplies the event record to configure in
    ---     place.
    newEvent: function<E is Event>(event: E)

    --- Configures an FFI event with a callable constructor.
    ---
    --- Registration mutates the supplied definition. Field names must be
    --- unique C identifiers. `eventId` and `typeId` are reserved. Use
    --- `double` for entity IDs so their packed slot and generation remain
    --- exact.
    ---
    --- @param event The caller supplies the event record to configure in
    ---     place.
    --- @param fields The caller supplies each field name and C type in
    ---     constructor order.
    --- @param structName The caller supplies a shared C struct name or omits
    ---     it to generate one.
    newFFIEvent: function<E is Event>(event: E, fields: {{string, string}}, structName?: string)

    --- Creates an independent address-based event message bus.
    ---
    --- @return Returns an empty message bus with no observers.
    newMessageBus: function(): MessageBus
end

events.newEvent = internal.newEvent
events.newFFIEvent = internal.newFFIEvent
events.newMessageBus = internal.MessageBus.new

return events
