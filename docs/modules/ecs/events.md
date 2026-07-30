---
description: "Address-based ECS events: observe, emit, hasObservers, newEvent, newFFIEvent, and the MessageBus router"
outline: deep
---

# Events

An observer subscribes to one event type at one integer address. Address `0`
belongs to the world; an entity ID addresses that entity.

The entry plugin below watches every despawn at the world address:

```teal
local Transform <const> = tecs.Transform

return tecs.newApplication({
    plugin = function(world: tecs.World)
        world:observe(0, tecs.ecs.OnDespawn, function(
            event: tecs.ecs.OnDespawn
        )
            -- OnDespawn runs before commit removes the row.
            local transform <const> = world:get(event.entity, Transform)
            if transform then
                spawnDebrisAt(world, transform.x, transform.y)
            end
        end)
    end,
})
```

The platform event stream uses the same bus. The host emits each platform kind
at address `0`; [`tecs.platform.events`](/modules/platform/events) defines those event types.

## World and entity addresses

Use address `0` for messages that belong to the world:

```teal
world:observe(0, GamePaused, onGamePaused)
world:emit(0, GamePaused)
```

Use an entity ID for a subscription tied to that entity:

```teal
world:observe(player, DamageReceived, function(event: DamageReceived)
    applyDamage(player, event.amount)
end)

world:emit(player, DamageReceived, 15)
```

When an entity despawns, the world clears every observer at that address before
the slot can belong to another entity. World-address observers remain.

## Observer timing

`world:emit` invokes matching observers before it returns. The observer runs in
the emitter's phase and deferred scope.

Platform events arrive before `world:update`, so their observers run outside
the phase tree. They do not receive fixed-step timing, phase order, or state
gating. Fold an event into state when a reaction needs those properties.
[`Input`](/modules/input) follows that pattern for keyboard, pointer, and
gamepad events.

Observers suit immediate notification. Systems suit ordered frame work.

## Subscription lifetime

`world:observe` accepts an optional string ID. Remove a subscription with its
callback or ID:

```teal
world:observe(0, GamePaused, onGamePaused, "pause-ui")

world:stopObserving(0, GamePaused, onGamePaused)
world:stopObserving(0, GamePaused, "pause-ui")
```

Passing a function removes every matching registration of that function.
Passing an ID removes the first matching registration. When an observer
unsubscribes during dispatch, the bus waits until the current dispatch unwinds
before changing its list.

`world:clearObservers(address)` clears an address that game code manages.
Entity despawn handles entity addresses automatically.

`world:hasObservers` matters when building the payload itself costs work:

```teal
if world:hasObservers(enemy, PathChanged) then
    world:emit(enemy, PathChanged, buildPathSnapshot(enemy))
end
```

For ordinary constructor arguments, call
`world:emit(address, EventType, ...)` directly. The world checks for observers
before it constructs an event.

## Table events

Define a record, give it an in-place initializer, then register it:

```teal
local record PlayerDamaged is tecs.events.Event
    amount: number
    source: string

    metamethod __call: function(
        self,
        amount: number,
        source: string
    ): PlayerDamaged
end

PlayerDamaged.init = function(
    event: PlayerDamaged,
    amount: number,
    source: string
)
    event.amount = amount
    event.source = source
end

tecs.events.newEvent(PlayerDamaged)

world:emit(player, PlayerDamaged, 10, "fire")
```

Registration assigns the event type its ID. Register each type once.

`PlayerDamaged(10, "fire")` allocates an independent instance. Use that form
when code must retain the value or send it through a standalone `MessageBus`.

`world:emit(player, PlayerDamaged, 10, "fire")` leases pooled backing storage
and returns it after dispatch. Do not retain the instance passed to an
observer. The emitter owns the payload during dispatch, so observers should
treat its fields as read-only and copy any values that must outlive the
callback.

## FFI events

`newFFIEvent` stores fixed-size fields in a C struct:

```teal
local record DamageEvent is tecs.events.Event
    amount: number
    entity: integer

    metamethod __call: function(
        self,
        amount: number,
        entity: integer
    ): DamageEvent
end

tecs.events.newFFIEvent(DamageEvent, {
    {"amount", "float"},
    {"entity", "double"},
}, "Game_DamageEvent")

world:emit(0, DamageEvent, 15.5, enemy)
```

Without a custom `init`, the generated initializer follows field order. Field
names must form unique C identifiers. `eventId` and `typeId` belong to Tecs and
cannot appear in `fields`.

Use `double` for an entity ID. The packed slot and generation do not fit in a
32-bit integer. FFI events cannot carry Lua strings, tables, functions, or
userdata; table events can.

`OnSpawn` and `OnDespawn` use FFI storage with a `double entity` field.

## Standalone message buses

Each world owns a `MessageBus`. `tecs.events.newMessageBus()` creates the same
address router without a world.

A standalone bus dispatches an event instance that the caller constructs. It
also exposes `observeOnce`, per-address clearing, entity-address clearing, and
a full reset. World methods add lazy construction, pooled emission, and
automatic cleanup when entities die.
