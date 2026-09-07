---
description: "Address-based ECS events: declare an event, observe, emit, deliver, and the storage a world reuses"
outline: deep
---

# Events

An event is a record marked `@derive(nupp.events.Event)`. An observer
subscribes to one event type at one integer address: address `0` belongs to
the world, and an entity ID addresses that entity. The world constructs the
event into storage it already owns, and only when something is observing, then
hands it to each observer as a borrow for the call.

Observers receive only that event. Capture other state in the callback when it
already belongs to the surrounding scope. `OnDespawn` also provides `get` and
`despawn` operations for the narrow teardown work that must happen before the
entity is removed.

The entry plugin below watches every despawn at the world address:

```nupp
world:observe(0, tecs.ecs.OnDespawn, function(event: tecs.ecs.OnDespawn): nil
    local transform = event:get(tecs.ecs.Transform2D)
    if transform then
        spawnDebrisAt(world, transform.x, transform.y)
    end
end, "debris")
```

The platform event stream uses the same bus. The host delivers each platform
kind at address `0`; [`tecs.platform.events`](tecs.platform.events) declares
one event type per kind.

## Declaring an event

A payload record is the event. Its fields, defaults, and constructor are the
ones the language already checks, and `@event(name = ...)` sets the name tools
see when the declaration's own name is not the surface you want to pin:

```nupp
local events = require("nupp.events")

@derive(events.Event)
@event(name = "game.PlayerDamaged")
local record PlayerDamaged
    amount: number
    source: string = "unknown"
end
```

Every declaration is its own event identity, so two events with the same
fields are two declarations. A declaration with several constructors, an
affine field, or a generic parameter is refused, because none of those can be
constructed into storage the world reuses.

## World and entity addresses

Use address `0` for messages that belong to the world:

```nupp
world:observe(0, GamePaused, onGamePaused)
world:emit(0, GamePaused)
```

Use an entity ID for a subscription tied to that entity. `emit` takes the
event's fields after the declaration, positional or named, and applies a field
default where an argument is left out:

```nupp
world:observe(player, PlayerDamaged, function(event: PlayerDamaged)
    applyDamage(player, event.amount)
end)

world:emit(player, PlayerDamaged, amount = 15)
world:emit(player, PlayerDamaged, 15, "fire")
```

When an entity despawns, the world clears every observer at that address before
the slot can belong to another entity. World-address observers remain, and
`world:clearEntities` keeps them too.

## Observer timing

`world:emit` invokes matching observers before it returns, in registration
order, and each sees what the earlier ones wrote to the event. The observer
runs in the emitter's phase and joins that phase's structural transaction. A
delivery reads the observer list when it starts: an observer added during it
joins the next emission, and one removed during it does not run if the
delivery had not reached it yet.

Platform events arrive before `world:update`, so their observers run outside
the phase tree. They do not receive fixed-step timing, phase order, or state
gating. Fold an event into state when a reaction needs those properties.
[`Input`](tecs.input) follows that pattern for keyboard, pointer, and
gamepad events.

Observers suit immediate notification. Systems suit ordered frame work.

## What an observer may do with the event

The event is borrowed for the call. An observer may read it and write to it,
and cannot store it, return it, or hand it to anything that keeps it: the
checker refuses those, because the storage is the world's and the next
emission reuses it. Copy the fields out when something has to outlive the
delivery.

An observer may suspend through any waiting library call, such as a timer or
an asset load; the world keeps the event's storage leased until it resumes.

## Subscription lifetime

`world:observe` accepts an optional string ID. Remove a subscription by ID, or
by the callback it was registered with, which removes every registration of
that callback:

```nupp
world:observe(0, GamePaused, onGamePaused, "pause-ui")
world:stopObserving(0, GamePaused, "pause-ui")
world:stopObserving(0, GamePaused, onGamePaused)
```

`world:observeOnce` registers an observer that is consumed before its first
delivery, so nothing nested or interleaved reaches it twice.
`world:clearObservers(address)` clears an address that game code manages.
Entity despawn handles entity addresses automatically. `world:hasObservers`
answers whether anything is registered; an emission nobody observes already
costs nothing beyond the argument expressions, so the check is for deciding
whether to do other work.

## Delivering an instance you hold

`world:deliver` hands observers an event the caller built, without acquiring
or releasing anything. What observers write to it is there when the call
returns, which is how the UI bubbles one interaction through its ancestors and
reads `consumed` back after each hop:

```nupp
local hit = new PlayerDamaged(amount = 3)
world:deliver(player, PlayerDamaged, hit)
print(hit.amount)
```

## Storage

A record event draws from a per-world [`nupp.mem.pool`](nupp.mem.pool) and a
struct event from a per-world [`nupp.mem.arena`](nupp.mem.arena), each made
the first time that event type is emitted. Pooled storage is cleared between
uses, so a field not set by an emission reads nil rather than the previous
value. `world:setAllocator(EventType, allocator)` installs storage you own
instead, sized how you like, for an event type you emit in volume.
