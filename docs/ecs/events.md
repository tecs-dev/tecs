---
description: "Address-based ECS events: observe, emit, hasObservers, newEvent and typed payloads"
outline: deep
---

# Events

An observer subscribes to one event type at one integer address. Address `0`
belongs to the world; an entity ID addresses that entity.

The entry plugin below watches every despawn at the world address:

```nupp
world:observe(0, tecs.ecs.OnDespawn, function(event: tecs.ecs.EntityLifecycle, exclusive world: tecs.ecs.World): nil
    local transform = world:get(event.entity, tecs.ecs.Transform2D)
    if transform then
        spawnDebrisAt(world, transform.x, transform.y)
    end
end, "debris")
```

The platform event stream uses the same bus. The host emits each platform kind
at address `0`; [`tecs.platform.events`](tecs.platform.events) defines those event types.

## World and entity addresses

Use address `0` for messages that belong to the world:

```nupp
world:observe(0, GamePaused, onGamePaused)
world:emit(0, GamePaused())
```

Use an entity ID for a subscription tied to that entity:

```nupp
world:observe(player, DamageReceived, function(event: DamageReceived)
    applyDamage(player, event.amount)
end)

world:emit(player, DamageReceived(15))
```

When an entity despawns, the world clears every observer at that address before
the slot can belong to another entity. World-address observers remain.

## Observer timing

`world:emit` invokes matching observers before it returns. The observer runs in
the emitter's phase and joins that phase's structural transaction.

Platform events arrive before `world:update`, so their observers run outside
the phase tree. They do not receive fixed-step timing, phase order, or state
gating. Fold an event into state when a reaction needs those properties.
[`Input`](tecs.input) follows that pattern for keyboard, pointer, and
gamepad events.

Observers suit immediate notification. Systems suit ordered frame work.

## Subscription lifetime

`world:observe` accepts an optional string ID. Remove a subscription by ID:

```nupp
world:observe(0, GamePaused, onGamePaused, "pause-ui")
world:stopObserving(0, GamePaused, "pause-ui")
```

`world:clearObservers(address)` clears an address that game code manages.
Entity despawn handles entity addresses automatically. `world:hasObservers`
matters when building the payload itself costs work; check it before calling
a costly event constructor.

## Table events

Define a payload record, then register its constructor:

```nupp
local record Damage
    amount: number
    source: string
end
local PlayerDamaged = tecs.events.newEvent({
    name = "game.PlayerDamaged",
    construct = function(amount: number, source: string): Damage
        return new Damage(amount = amount, source = source)
    end,
})
world:observe(player, PlayerDamaged, function(event: Damage): nil
    print(event.amount, event.source)
end, "damage-log")
world:emit(player, PlayerDamaged(10, "fire"))
```

Registration assigns the event type its identity. Register each type once.
The constructor creates an envelope; `world:emit` passes its payload to observers.
Observers receive the world as their second argument.
